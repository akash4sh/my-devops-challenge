# AUDIT.md — Starter Repository Defect Report

Audited by: Akash  
Date: 2026-05-07  
Repo: `devops-challenge` (Skybytech starter)

---

## Security

### S1 — Dockerfile runs as root
**File:** `Dockerfile`  
**What's wrong:** No `USER` directive is present. The container process runs as `root` (UID 0) by default.  
**Why it matters:** If the application is compromised, the attacker has root inside the container, making container escapes and privilege escalation significantly easier. Most security benchmarks require non-root containers.  
**Fix:** Add a non-root user in the Dockerfile and switch to it before `CMD`:
```dockerfile
RUN addgroup --system appgroup && adduser --system --ingroup appgroup appuser
USER appuser
```

---

### S2 — Secret hardcoded in `values.yaml`
**File:** `helm/skybyte-app/values.yaml` (line: `apiToken: "sk-skybyte-prod-7f3c9a2b1e8d4a6c"`)  
**What's wrong:** A production API token is committed in plain text to the Helm values file, which lives in version control.  
**Why it matters:** Anyone with read access to the repository — including CI runners, third-party tools, GitHub staff — can read the token. Rotating it requires a code change, creating a paper trail gap. This is a direct credential leak.  
**Fix:** Remove `apiToken` from `values.yaml`. Create a Kubernetes `Secret` managed by Terraform and reference it in the Deployment via `secretKeyRef`. Pass the token value via `terraform.tfvars` (gitignored) or a secrets manager at apply time.

---

### S3 — Secret hardcoded in `terraform/variables.tf`
**File:** `terraform/variables.tf` (line: `default = "sk-skybyte-prod-7f3c9a2b1e8d4a6c"`)  
**What's wrong:** The same production token is also the default value in the Terraform variable, meaning `terraform apply` with no overrides silently uses the real credential.  
**Why it matters:** Same as S2 — plus Terraform state files store this value in plaintext. The `terraform.tfstate` file (often in a shared backend) will contain the token unencrypted unless the state backend is properly encrypted.  
**Fix:** Remove the `default` from `api_token` variable. Require it to be passed explicitly via `TF_VAR_api_token` environment variable or a gitignored `terraform.tfvars` file.

---

### S4 — No `securityContext` on the container or pod
**File:** `helm/skybyte-app/templates/deployment.yaml`  
**What's wrong:** No `securityContext` is defined at either pod or container level. This means:
- `allowPrivilegeEscalation` defaults to `true`
- `readOnlyRootFilesystem` defaults to `false`
- No capabilities are dropped
- No `seccompProfile` is set  

**Why it matters:** Even if the image were non-root, the runtime allows the process to re-acquire privileges. A writable root filesystem allows attackers to install tools or modify binaries post-compromise.  
**Fix:** Add explicit `securityContext` at both pod and container level in the deployment template.

---

### S5 — Base image is unpinned and bloated
**File:** `Dockerfile` (line: `FROM python:3.9`)  
**What's wrong:** `:3.9` is a floating tag pointing to the full Debian-based Python image (~900MB). It contains compilers, package managers, and hundreds of packages not needed at runtime. No SHA digest pin means the base image can change between builds silently.  
**Why it matters:** A larger attack surface increases the number of CVEs present in the image. Unpinned tags mean builds are not reproducible — a supply-chain compromise of the base image would silently affect all future builds.  
**Fix:** Switch to `python:3.12-slim-bookworm` and pin to a SHA digest. Use a multi-stage build to separate build dependencies from the runtime image.

---

### S6 — API token injected as plain environment variable from values
**File:** `helm/skybyte-app/templates/deployment.yaml`  
**What's wrong:** The token is passed as `value: {{ .Values.apiToken | quote }}` — a direct string injection from the values file into the pod environment. This means the token is visible in `kubectl describe pod`, in Helm release history, and in any audit log that records pod specs.  
**Why it matters:** `kubectl describe pod` is a common debugging command run by many engineers. The token is exposed.  
**Fix:** Reference a Kubernetes `Secret` via `secretKeyRef` instead of a raw value.

---

## Reliability

### R1 — Liveness and readiness probes point to `/` (business endpoint)
**File:** `helm/skybyte-app/templates/deployment.yaml`  
**What's wrong:** Both `livenessProbe` and `readinessProbe` use `path: /` — the application's main business endpoint, not a dedicated health check endpoint.  
**Why it matters:** If the `/` handler is slow or temporarily returning errors due to load, Kubernetes will restart the pod unnecessarily (liveness) or remove it from the load balancer (readiness), causing cascading failures. A liveness probe hitting a business endpoint can also cause restart loops under normal traffic spikes.  
**Fix:** Use the existing `/healthz` endpoint for both probes (or create a dedicated `/readyz`). Configure sensible thresholds: `initialDelaySeconds`, `periodSeconds`, `failureThreshold`.

---

### R2 — No `initialDelaySeconds`, `periodSeconds`, or `failureThreshold` on probes
**File:** `helm/skybyte-app/templates/deployment.yaml`  
**What's wrong:** Probes are defined with no threshold configuration — Kubernetes uses its defaults (`initialDelaySeconds: 0`, `periodSeconds: 10`, `failureThreshold: 3`). `initialDelaySeconds: 0` means Kubernetes checks the pod before the Python/Flask process has finished starting up.  
**Why it matters:** For a Python Flask app, startup takes 1–3 seconds. With `initialDelaySeconds: 0`, the first few liveness checks will fail, potentially causing premature restarts before the app is ready.  
**Fix:** Set `initialDelaySeconds: 5`, `periodSeconds: 10`, `failureThreshold: 3`, `timeoutSeconds: 2` as a minimum baseline.

---

### R3 — No resource `requests` or `limits` defined
**File:** `helm/skybyte-app/templates/deployment.yaml`  
**What's wrong:** The container has no `resources` block. Kubernetes has no information about how much CPU or memory this container needs or is allowed to use.  
**Why it matters:** Without `requests`, the scheduler cannot make informed placement decisions — the pod may land on an overloaded node. Without `limits`, a memory leak or traffic spike can cause the container to consume all available node memory, triggering OOM kills of other workloads on the same node. The namespace has a `ResourceQuota` applied by Terraform — without `requests` set, pod creation may fail silently depending on quota scope.  
**Fix:** Add `resources.requests` and `resources.limits` with values appropriate for this lightweight Flask service (e.g., `cpu: 50m/200m`, `memory: 64Mi/128Mi`).

---

### R4 — No graceful shutdown handling in the application
**File:** `app/main.py`  
**What's wrong:** The Flask app is started with `app.run()` which uses the single-threaded Werkzeug development server. There is no `SIGTERM` handler. When Kubernetes sends `SIGTERM` before terminating the pod, the process exits immediately, dropping any in-flight requests.  
**Why it matters:** During rolling updates or pod evictions, users making requests at the moment of termination will receive connection reset errors instead of completed responses.  
**Fix:** Catch `SIGTERM` with Python's `signal` module, stop accepting new connections, allow in-flight requests to drain, then exit. Switch from `app.run()` (Werkzeug dev server) to `gunicorn` with `--graceful-timeout` for production-grade signal handling.

---

### R5 — App listens on port 80 (privileged port) as root
**File:** `app/main.py` (line: `app.run(host="0.0.0.0", port=80)`)  
**What's wrong:** Port 80 is a privileged port (< 1024). Binding to it requires root privileges or the `NET_BIND_SERVICE` capability.  
**Why it matters:** This directly conflicts with fixing S1 (non-root user). A non-root user cannot bind to port 80 without additional capabilities, which in turn conflicts with S4 (dropping all capabilities). This is a compound defect — the root-binding and the privileged port reinforce each other.  
**Fix:** Change the application port to 8080 (unprivileged). Update `containerPort`, the Service `targetPort`, and probe paths accordingly.

---

## Hygiene

### H1 — CI linting is a no-op
**File:** `.github/workflows/ci.yml`  
**What's wrong:** The flake8 lint step runs:
```
flake8 app/ --exclude=app/* --exit-zero
```
`--exclude=app/*` excludes the entire `app/` directory from being linted. `--exit-zero` suppresses all errors. This step always passes regardless of code quality.  
**Why it matters:** CI gives a false green. Engineers trust it and merge broken or non-compliant code believing it has been validated.  
**Fix:** Remove `--exclude=app/*` and `--exit-zero`. Replace `flake8` with `ruff` (faster, modern, single tool). Fail the CI job on lint errors.

---

### H2 — Helm lint and Terraform validate use `|| true`
**File:** `.github/workflows/ci.yml`  
**What's wrong:**
```
helm lint helm/skybyte-app || true
terraform validate || true
```
Both commands suppress non-zero exit codes. A broken Helm chart or invalid Terraform config will still report green CI.  
**Why it matters:** Same as H1 — false confidence. The entire purpose of these steps is to catch breakage; suppressing their exit codes makes them decorative.  
**Fix:** Remove `|| true`. Let failures propagate.

---

### H3 — No `helm template | kubeconform` validation
**File:** `.github/workflows/ci.yml`  
**What's wrong:** `helm lint` only validates chart structure and syntax. It does not validate that the rendered Kubernetes manifests are valid against the Kubernetes API schema.  
**Why it matters:** A chart can pass `helm lint` but produce manifests that Kubernetes will reject at apply time (e.g., wrong API version, missing required fields). This has happened here — the deployment is missing `resources`, which `helm lint` doesn't catch.  
**Fix:** Add `helm template | kubeconform` to validate rendered manifests against the Kubernetes schema.

---

### H4 — `requirements.txt` has unpinned transitive dependencies
**File:** `app/requirements.txt`  
**What's wrong:** Only `flask==2.3.3` is pinned. Flask's dependencies (`Werkzeug`, `Jinja2`, `click`, `itsdangerous`, `MarkupSafe`) are unspecified. `pip install` will resolve the latest compatible versions at build time.  
**Why it matters:** Builds are not reproducible. A transitive dependency update can silently break the application between two identical builds. This has caused production incidents across the industry.  
**Fix:** Generate a full lockfile with `pip-compile` (from `pip-tools`) and commit `requirements.txt` with all transitive dependencies pinned. Or use `pip freeze > requirements.txt` after a successful install.

---

### H5 — Docker image built without multi-stage build
**File:** `Dockerfile`  
**What's wrong:** A single-stage build copies source code and installs dependencies into the same layer. Build tools (`pip`, setuptools, wheel) remain in the final image.  
**Why it matters:** Larger image size, larger attack surface. Build tools are not needed at runtime and represent unnecessary CVE exposure.  
**Fix:** Use a multi-stage build: install dependencies in a `builder` stage, then copy only the installed packages and application code into a minimal runtime image.

---

### H6 — `setup.sh` does not exit on failure
**File:** `setup.sh`  
**What's wrong:** `setup.sh` has no `set -euo pipefail`. If `terraform apply` fails, the script continues and attempts the Helm install against a potentially broken state.  
**Why it matters:** Silent partial deployments are worse than a clean failure. An operator may believe the deployment succeeded when only some steps completed.  
**Fix:** Add `set -euo pipefail` at the top of the script.

---

### H7 — `setup.sh` uses `:latest` tag
**File:** `setup.sh` (line: `docker build -t skybyte/app:latest .`)  
**What's wrong:** The image is tagged and deployed as `:latest`.  
**Why it matters:** Using `:latest` is risky because it is not a fixed version. With `imagePullPolicy: IfNotPresent`, Kubernetes may use old cached images instead of pulling the new one. It also makes rollbacks difficult because there is no specific previous version to return to  
**Fix:** Tag with a deterministic version — git SHA (`$(git rev-parse --short HEAD)`) or a semver tag. Pass this tag through to Helm via `--set image.tag=<sha>`.

---

## Documentation

### D1 — README architecture diagram contradicts actual code
**File:** `README.md (Architecture section)`

**What's wrong:** The diagram shows [Pod:appuser:80] implying the pod runs as a non-root user called appuser. The actual Dockerfile has no USER directive — the process runs as root (UID 0). There is no appuser anywhere in the codebase.

**Why it matters:** The README is usually the first thing an on-call engineer checks during an incident. If the information is incorrect, it can lead to confusion, wrong troubleshooting steps, and loss of trust in the documentation..

**Fix:** After hardening (adding non-root user in Dockerfile), update the diagram to accurately reflect the fixed state.

---

### D2 — README claims CI runs lint — it does not
**File:** README.md (CI section) vs .github/workflows/ci.yml

**What's wrong:** README states "GitHub Actions runs lint, helm lint, terraform validate...". The actual CI lint step is: `flake8 app/ --exclude=app/* --exit-zero`
`--exclude=app/*` excludes the entire target directory. `--exit-zero` suppresses all errors. Nothing is actually linted. Similarly, helm lint and terraform validate both use || true. CI always reports green regardless of code state.

**Why it matters:** Engineers merge code trusting the CI description. It can create confusion and give false confidence that everything is working correctly..

**Fix:** Fix the CI (remove --exclude, --exit-zero, || true) so that the README description becomes accurate.

---
