#!/usr/bin/env bash
# system-checks.sh — post-deployment verification
#
# Proves the deployment is hardened and functional:
#   1. Container runs as non-root (UID != 0)
#   2. Bound port is 8080 (unprivileged)
#   3. No capabilities granted
#   4. / returns the expected JSON response
#   5. /metrics exposes http_requests_total
#   6. Pod recovers within 30s after kubectl delete pod
#
# Usage:
#   ./system-checks.sh
#
# Requirements: kubectl (configured for target cluster), curl, jq

set -euo pipefail

NAMESPACE="devops-challenge"
RELEASE="skybyte-app"
MAX_RECOVERY_SECONDS=30

# Colours
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

pass() { echo -e "${GREEN}[PASS]${NC} $*"; }
fail() { echo -e "${RED}[FAIL]${NC} $*"; exit 1; }
info() { echo -e "${YELLOW}[INFO]${NC} $*"; }

echo ""
echo "========================================"
echo "  Skybyte system-checks.sh"
echo "  Namespace: ${NAMESPACE}"
echo "========================================"
echo ""

# ---------------------------------------------------------------------------
# Helper: get the first running pod name for the release
# ---------------------------------------------------------------------------
get_pod() {
  kubectl get pod \
    -n "${NAMESPACE}" \
    -l "app.kubernetes.io/instance=${RELEASE}" \
    --field-selector=status.phase=Running \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null
}

# Wait for at least one Running pod
info "Waiting for pod to be Running..."
for i in $(seq 1 30); do
  POD=$(get_pod || true)
  if [[ -n "${POD}" ]]; then
    info "Found pod: ${POD}"
    break
  fi
  sleep 2
done

if [[ -z "${POD:-}" ]]; then
  fail "No running pod found in namespace ${NAMESPACE} after 60s"
fi

# ---------------------------------------------------------------------------
# Check 1 — In-container UID must not be 0 (root)
# ---------------------------------------------------------------------------
echo ""
info "Check 1: In-container UID (must not be 0)"

CONTAINER_UID=$(kubectl exec -n "${NAMESPACE}" "${POD}" -- id -u)
echo "         Container UID: ${CONTAINER_UID}"

if [[ "${CONTAINER_UID}" -eq 0 ]]; then
  fail "Container is running as root (UID 0). Security hardening failed."
fi
pass "Container is running as UID ${CONTAINER_UID} (non-root)"

# ---------------------------------------------------------------------------
# Check 2 — Bound port must be 8080
#
# python:3.12-slim does not ship ss or netstat.
# We read /proc/net/tcp (IPv4) and /proc/net/tcp6 (IPv6) directly.
# Gunicorn binds 0.0.0.0:8080 which appears in /proc/net/tcp.
# Port 8080 in hex = 1F90.
# local_address format: XXXXXXXX:PPPP (hex ip : hex port)
# ---------------------------------------------------------------------------
echo ""
info "Check 2: Bound port (must be 8080)"

# Read BOTH tcp and tcp6 — gunicorn on 0.0.0.0 uses IPv4 (/proc/net/tcp)
PROC_TCP=$(kubectl exec -n "${NAMESPACE}" "${POD}" -- \
  sh -c "cat /proc/net/tcp 2>/dev/null; cat /proc/net/tcp6 2>/dev/null; true" \
)

echo "         /proc/net/tcp + tcp6 contents:"
echo "${PROC_TCP}" | sed 's/^/         /'

# Port 8080 in hex = 1F90
if echo "${PROC_TCP}" | grep -qi ":1F90"; then
  pass "Port 8080 (0x1F90) is bound"
else
  fail "Port 8080 not found in /proc/net/tcp or /proc/net/tcp6. Check containerPort in deployment."
fi

# ---------------------------------------------------------------------------
# Check 3 — Capabilities must be empty (all dropped)
# ---------------------------------------------------------------------------
echo ""
info "Check 3: Linux capabilities (must be 0 — all dropped)"

CAPS=$(kubectl exec -n "${NAMESPACE}" "${POD}" -- \
  sh -c "grep -i cap /proc/1/status" \
)
echo "         Capability flags from /proc/1/status:"
echo "${CAPS}" | sed 's/^/         /'

CAPEFF=$(echo "${CAPS}" | grep CapEff | awk '{print $2}' || echo "0000000000000000")
if [[ "${CAPEFF}" == "0000000000000000" ]]; then
  pass "No effective capabilities (CapEff: 0000000000000000)"
else
  fail "Container has effective capabilities: ${CAPEFF}. Expected 0000000000000000."
fi

# ---------------------------------------------------------------------------
# Check 4 — GET / returns expected JSON response
# ---------------------------------------------------------------------------
echo ""
info "Check 4: GET / response body"

# Kill any existing port-forward on 18080
pkill -f "port-forward.*18080" 2>/dev/null || true
sleep 1

kubectl port-forward \
  -n "${NAMESPACE}" \
  "svc/${RELEASE}" \
  18080:8080 \
  >/dev/null 2>&1 &
PF_PID=$!
trap "kill ${PF_PID} 2>/dev/null || true" EXIT
sleep 3

RESPONSE=$(curl -sf http://localhost:18080/ \
  || fail "curl / returned non-200 status")
echo "         Response: ${RESPONSE}"

MESSAGE=$(echo "${RESPONSE}" | python3 -c "import sys,json; print(json.load(sys.stdin)['message'])" 2>/dev/null || echo "")
VERSION=$(echo "${RESPONSE}" | python3 -c "import sys,json; print(json.load(sys.stdin)['version'])" 2>/dev/null || echo "")

if [[ "${MESSAGE}" != "Hello, Candidate" ]]; then
  fail "Unexpected message: '${MESSAGE}' (expected 'Hello, Candidate')"
fi
pass "GET / → message='${MESSAGE}' version='${VERSION}'"

# ---------------------------------------------------------------------------
# Check 5 — GET /metrics exposes http_requests_total
# ---------------------------------------------------------------------------
echo ""
info "Check 5: GET /metrics exposes http_requests_total"

METRICS=$(curl -sf http://localhost:18080/metrics \
  || fail "curl /metrics returned non-200 status")

if echo "${METRICS}" | grep -q "http_requests_total"; then
  pass "/metrics contains http_requests_total"
else
  fail "/metrics output does not contain http_requests_total"
fi

if echo "${METRICS}" | grep -q "http_request_duration_seconds"; then
  pass "/metrics contains http_request_duration_seconds histogram"
else
  fail "/metrics output does not contain http_request_duration_seconds"
fi

echo ""
info "Sample metrics output:"
echo "${METRICS}" | grep "http_requests_total" | grep -v "^#" | head -5 \
  | sed 's/^/         /'

# Kill port-forward before recovery test
kill "${PF_PID}" 2>/dev/null || true
trap - EXIT
sleep 1

# ---------------------------------------------------------------------------
# Check 6 — Pod recovers within 30s after kubectl delete pod
# ---------------------------------------------------------------------------
echo ""
info "Check 6: Pod recovery after kubectl delete pod (must recover within ${MAX_RECOVERY_SECONDS}s)"

OLD_POD="${POD}"
info "Deleting pod: ${OLD_POD}"
kubectl delete pod -n "${NAMESPACE}" "${OLD_POD}"

info "Waiting for new pod to become Running..."
ELAPSED=0
NEW_POD=""
while [[ ${ELAPSED} -lt ${MAX_RECOVERY_SECONDS} ]]; do
  sleep 2
  ELAPSED=$((ELAPSED + 2))
  NEW_POD=$(kubectl get pod \
    -n "${NAMESPACE}" \
    -l "app.kubernetes.io/instance=${RELEASE}" \
    --field-selector=status.phase=Running \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)

  if [[ -n "${NEW_POD}" && "${NEW_POD}" != "${OLD_POD}" ]]; then
    break
  fi
done

if [[ -z "${NEW_POD}" || "${NEW_POD}" == "${OLD_POD}" ]]; then
  fail "No new Running pod found within ${MAX_RECOVERY_SECONDS}s after deletion"
fi

pass "New pod '${NEW_POD}' is Running after ${ELAPSED}s"

RESTARTS=$(kubectl get pod -n "${NAMESPACE}" "${NEW_POD}" \
  -o jsonpath='{.status.containerStatuses[0].restartCount}' 2>/dev/null || echo "0")
echo "         Restart count on new pod: ${RESTARTS}"

if [[ "${RESTARTS}" -gt 0 ]]; then
  fail "New pod has ${RESTARTS} restart(s) — probes or startup may be misconfigured"
fi
pass "New pod has 0 restarts — clean startup"

# Final re-check: verify / still responds on the new pod
pkill -f "port-forward.*18080" 2>/dev/null || true
sleep 1

kubectl port-forward \
  -n "${NAMESPACE}" \
  "svc/${RELEASE}" \
  18080:8080 \
  >/dev/null 2>&1 &
PF_PID=$!
trap "kill ${PF_PID} 2>/dev/null || true" EXIT
sleep 3

FINAL_RESPONSE=$(curl -sf http://localhost:18080/ \
  || fail "curl / failed after pod recovery")
pass "Service responding correctly after pod recovery: ${FINAL_RESPONSE}"

kill "${PF_PID}" 2>/dev/null || true
trap - EXIT

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "========================================"
echo -e "  ${GREEN}All checks passed.${NC}"
echo "========================================"
echo ""