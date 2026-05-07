# Skybyte API

A small Python service that returns a greeting. Runs in Kubernetes via Helm.

> **Note:** the engineer who set this up is no longer with the team. Some of this README may be out of date. **The challenge brief is in [`CHALLENGE.md`](./CHALLENGE.md) — start there.**

## Prerequisites

- Docker Desktop (or any Docker engine)
- A local Kubernetes cluster (Minikube or Kind)
- Helm 3.x
- Terraform 1.5+
- Python 3.9+ (for running tests locally)

## Quick start

```bash
./setup.sh
```

This script will build the image, apply Terraform, and install the Helm chart.

To verify the deployment:

```bash
kubectl -n devops-challenge get pods
kubectl -n devops-challenge port-forward svc/skybyte-app 8080:80
curl http://localhost:8080/
# expected: {"message": "Hello, Candidate", "version": "1.0.0"}
```

## Architecture

```
[Client] ──► [Service:80] ──► [Pod:appuser:80]
```

The pod runs as a non-root user (appuser) and listens on port 80. Health checks are wired to `/healthz`.

## CI

GitHub Actions runs lint, helm lint, terraform validate, and a Docker build on every push. See `.github/workflows/ci.yml`.

## Layout

```
/
├── app/                  Python service
├── Dockerfile
├── helm/skybyte-app/     Helm chart
├── terraform/            Namespace + ResourceQuota + secret
├── .github/workflows/    CI
├── setup.sh
└── CHALLENGE.md          ← read this
```
