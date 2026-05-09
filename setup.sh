#!/usr/bin/env bash
# setup.sh — idempotent local deployment helper
#
# Builds the Docker image, applies Terraform, and installs/upgrades the
# Helm release. Exits non-zero if any step fails.
#
# Usage:
#   export TF_VAR_api_token="your-token"
#   ./setup.sh
#
# Requirements:
#   docker, terraform >= 1.5, helm >= 3.12, kubectl (pointing at target cluster)

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
IMAGE_REPO="skybyte/app"
IMAGE_TAG="$(git rev-parse --short HEAD)"
IMAGE="${IMAGE_REPO}:${IMAGE_TAG}"
NAMESPACE="devops-challenge"
RELEASE_NAME="skybyte-app"
HELM_CHART="helm/skybyte-app"

echo "==> Image tag: ${IMAGE_TAG}"

# ---------------------------------------------------------------------------
# Detect kind cluster
# ---------------------------------------------------------------------------
KUBE_CONTEXT=$(kubectl config current-context 2>/dev/null || echo "")
if echo "${KUBE_CONTEXT}" | grep -q "kind"; then
  IS_KIND=true
  PULL_POLICY="Never"
  echo "==> Detected kind cluster (context: ${KUBE_CONTEXT})"
  echo "    Image will be loaded directly into kind — no registry push needed."
else
  IS_KIND=false
  PULL_POLICY="IfNotPresent"
  echo "==> Non-kind cluster detected (context: ${KUBE_CONTEXT})"
fi

# ---------------------------------------------------------------------------
# Step 1 — Build Docker image
# ---------------------------------------------------------------------------
echo ""
echo "==> [1/4] Building Docker image: ${IMAGE}"
docker build --tag "${IMAGE}" .

# ---------------------------------------------------------------------------
# Step 2 — Load image into kind (kind clusters only)
# ---------------------------------------------------------------------------
if [[ "${IS_KIND}" == "true" ]]; then
  echo ""
  echo "==> [2/4] Loading image into kind cluster"
  kind load docker-image "${IMAGE}"
  echo "    Image loaded successfully."
else
  echo ""
  echo "==> [2/4] Skipping kind load (not a kind cluster)"
  echo "    Push the image to your registry before proceeding."
fi

# ---------------------------------------------------------------------------
# Step 3 — Terraform (namespace, ResourceQuota, Secret)
# ---------------------------------------------------------------------------
echo ""
echo "==> [3/4] Applying Terraform"

if [[ -z "${TF_VAR_api_token:-}" ]]; then
  echo ""
  echo "ERROR: TF_VAR_api_token is not set."
  echo "       Export it before running this script:"
  echo "         export TF_VAR_api_token='your-token-here'"
  exit 1
fi

(
  cd terraform
  terraform init -input=false
  terraform apply -auto-approve -input=false
)

# ---------------------------------------------------------------------------
# Step 4 — Helm install/upgrade
# ---------------------------------------------------------------------------
echo ""
echo "==> [4/4] Installing/upgrading Helm release: ${RELEASE_NAME}"

helm upgrade "${RELEASE_NAME}" "${HELM_CHART}" \
  --install \
  --namespace "${NAMESPACE}" \
  --create-namespace \
  --set image.tag="${IMAGE_TAG}" \
  --set image.pullPolicy="${PULL_POLICY}" \
  --wait \
  --timeout 120s

echo ""
echo "==> Done. Release '${RELEASE_NAME}' is running in namespace '${NAMESPACE}'."
echo "    Image: ${IMAGE}"
echo "    Run ./system-checks.sh to verify the deployment."