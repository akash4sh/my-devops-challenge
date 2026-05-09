# Skybyte App — DevOps Challenge

## What Was Wrong and What Changed

The inherited repository contained defects across security, reliability,
hygiene, and documentation categories (see [`AUDIT.md`](./AUDIT.md) for the
full list). The most critical: the container ran as root with no security
context, a production API token was hardcoded in `values.yaml` and
`terraform/variables.tf`, both Kubernetes probes pointed at the business
endpoint `/` instead of a dedicated health endpoint, there were no resource
requests or limits, and the CI pipeline always reported green while skipping
every meaningful check (the flake8 step excluded the directory it was supposed
to lint; `helm lint` and `terraform validate` both used `|| true`). This
submission hardens the deployment to run as UID 1000 with all capabilities
dropped, `readOnlyRootFilesystem: true`, and `allowPrivilegeEscalation: false`;
moves the secret into a Kubernetes `Secret` managed by Terraform; adds
`/metrics`, `/healthz`, and `/readyz` endpoints; replaces the CI with six jobs
that each fail on real errors; and adds two Kyverno policies that enforce the
security and reliability baselines at admission time.

---

## Prerequisites

Tested against:

| Tool | Version |
|---|---|
| Docker | 29.0.0 |
| Kind | 0.31.0 |
| kubectl | v1.36.0 |
| Helm | v3.20.2 |
| Terraform | v1.15.2 |
| Python | 3.12.3 |
---

## Quick Start

```bash
# 1. Start a local cluster
kind create cluster

# 2. Set the API token (never commit this value)
export TF_VAR_api_token="your-token-here"

# 3. Build, provision, and deploy
./setup.sh

# 4. Verify the deployment
./system-checks.sh
```

---

## Architecture

```
[Client]
   │
   ▼
[Service: ClusterIP :8080]
   │
   ▼
[Deployment: skybyte-app]
   │
   ├── UID 1000 (non-root)
   ├── readOnlyRootFilesystem: true
   ├── capabilities: drop ALL
   ├── seccompProfile: RuntimeDefault
   ├── /        → JSON greeting
   ├── /healthz → liveness probe target
   ├── /readyz  → readiness probe target
   └── /metrics → Prometheus scrape endpoint
```

Secrets flow:
```
TF_VAR_api_token (env var, never committed)
   │
   ▼ terraform apply
kubernetes_secret "api-token" (in-cluster)
   │
   ▼ secretKeyRef
Pod env: API_TOKEN
```

---

## SLO Statement

**99% of requests to `/` complete in under 300 ms over a rolling 7-day window.**

*Why 300 ms:* This is a stateless in-memory greeting service with no database
or external calls. Measured locally on a single gunicorn worker, p99 latency
is under 5 ms. The 300 ms threshold provides a 60x margin — enough to absorb
cold-start latency, Kubernetes scheduling delays, and moderate network overhead
in a real cluster, while still being tight enough to catch genuine regressions
(a broken upstream dependency, a deadlock, or a runaway GC pause).

*How you'd know if it broke:* The `/metrics` endpoint exposes
`http_request_duration_seconds` as a Prometheus histogram. A PromQL alert rule
would evaluate:

```promql
histogram_quantile(
  0.99,
  sum(rate(http_request_duration_seconds_bucket{path="/"}[7d])) by (le)
) > 0.300
```

This fires when the 7-day p99 exceeds 300 ms. In practice, for a 7-day window
the alert would be paired with a shorter burn-rate alert (e.g. 1-hour window
at 5× the error budget consumption rate) to catch fast-moving regressions before
they exhaust the budget.

---

## Demo Recording

▶ **asciinema:** _[Recording link — https://asciinema.org/a/aM7J9AyjM0RymGMa]_

```bash
# To record your own:
asciinema rec demo.cast
export TF_VAR_api_token="demo-token"
./setup.sh
./system-checks.sh
exit
asciinema upload demo.cast
```

---

## Repository Layout

```
/
├── app/
│   ├── main.py              # Flask service: /, /healthz, /readyz, /metrics
│   ├── requirements.in      # Direct dependencies (source of truth)
│   ├── requirements.txt     # Fully pinned lockfile (pip-compile output)
│   └── tests/
│       ├── conftest.py
│       └── test_main.py     # Unit tests for all endpoints + metrics labels
├── helm/skybyte-app/
│   ├── Chart.yaml
│   ├── values.yaml          # No secrets — apiToken removed
│   └── templates/
│       ├── deployment.yaml  # Hardened: securityContext, probes, resources
│       ├── service.yaml
│       └── _helpers.tpl
├── terraform/
│   ├── main.tf              # Namespace + ResourceQuota + Secret
│   ├── variables.tf         # api_token: no default, marked sensitive
│   └── versions.tf
├── policies/
│   ├── disallow-root-user.yaml      # Kyverno: block root containers
│   ├── require-resource-limits.yaml # Kyverno: require requests + limits
│   └── test-fixtures/
│       └── bad-pod.yaml             # Manifest that should be rejected
├── .github/workflows/
│   └── ci.yml               # 6-job pipeline that actually validates
├── Dockerfile               # Multi-stage, non-root, python:3.12-slim
├── setup.sh                 # Idempotent: build → terraform → helm
├── system-checks.sh         # Proves: non-root, port, caps, metrics, recovery
├── AUDIT.md                 # defects found and documented
└── DECISIONS.md             # decisions with context, options, rationale
```

---

## CI Pipeline

| Job | What it checks |
|---|---|
| `lint-python` | `ruff check app/` — no exclusions, no exit-zero |
| `test-python` | `pytest app/tests/` — all endpoints + metric label correctness |
| `helm-validate` | `helm lint` + `helm template \| kubeconform --strict` |
| `terraform-validate` | `terraform fmt -check` + `terraform validate` |
| `docker-build-scan` | Multi-arch buildx (amd64+arm64) + `trivy fs` + `trivy image`, fail on HIGH/CRITICAL |
| `kyverno-policy-check` | `kyverno apply policies/ --resource rendered/manifests.yaml` |

---

## Things I Would Do Next With Another Week

These items were noticed, consciously deferred due to time constraints, and
documented here as signal — not weakness.

1. **External Secrets Operator** — Replace the Terraform-managed Secret with
   ESO pulling from AWS Secrets Manager or HashiCorp Vault. This removes
   the token from the Terraform state entirely and enables automatic rotation.

2. **NetworkPolicy** — Restrict ingress to the pod to only the Service IP
   and Prometheus scraper. Currently any pod in the cluster can reach the
   app directly.

3. **PodDisruptionBudget** — Ensure at least one replica is always available
   during node maintenance. Requires `replicaCount >= 2`.

4. **Image signing (Cosign)** — Sign the built image in CI and add a Kyverno
   policy that verifies the signature at admission time, preventing unsigned
   images from being deployed.