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
#   docker, terraform >= 1.5, helm >= 3.12, kubectl

# ---------------------------------------------------------------------------
# Strict mode:
#   -e  exit immediately on any command failure
#   -u  treat unset variables as errors
#   -o pipefail  pipeline fails if any command in it fails (not just the last)
# ---------------------------------------------------------------------------
set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
IMAGE_REPO="skybyte/app"
# Use the short git SHA as the image tag for deterministic, traceable builds.
# "latest" is not a version — it provides no rollback capability.
IMAGE_TAG="$(git rev-parse --short HEAD)"
IMAGE="${IMAGE_REPO}:${IMAGE_TAG}"
NAMESPACE="devops-challenge"
RELEASE_NAME="skybyte-app"
HELM_CHART="helm/skybyte-app"

echo "==> Image tag: ${IMAGE_TAG}"

# ---------------------------------------------------------------------------
# Step 1 — Build Docker image
# ---------------------------------------------------------------------------
echo ""
echo "==> [1/3] Building Docker image: ${IMAGE}"
docker build --tag "${IMAGE}" .

# ---------------------------------------------------------------------------
# Step 2 — Terraform (namespace, ResourceQuota, Secret)
# ---------------------------------------------------------------------------
echo ""
echo "==> [2/3] Applying Terraform"

# Check the token is set before entering the terraform directory.
# Failing here with a clear message is better than a cryptic Terraform error.
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
  # -auto-approve: non-interactive for script use.
  # Running twice is safe — Terraform is declarative and idempotent.
  terraform apply -auto-approve -input=false
)

# ---------------------------------------------------------------------------
# Step 3 — Helm install/upgrade
# ---------------------------------------------------------------------------
echo ""
echo "==> [3/3] Installing/upgrading Helm release: ${RELEASE_NAME}"

# --install      : creates the release if it doesn't exist (idempotent)
# --wait         : block until all pods are ready, so failures surface here
# --timeout 120s : give pods 2 minutes to become healthy
# --set image.tag: pass the git SHA so the running version is always traceable
helm upgrade "${RELEASE_NAME}" "${HELM_CHART}" \
  --install \
  --namespace "${NAMESPACE}" \
  --create-namespace \
  --set image.tag="${IMAGE_TAG}" \
  --wait \
  --timeout 120s

echo ""
echo "==> Done. Release '${RELEASE_NAME}' is running in namespace '${NAMESPACE}'."
echo "    Image: ${IMAGE}"