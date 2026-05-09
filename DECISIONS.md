# DECISIONS.md

Every meaningful choice made during this exercise is documented below in the
required format. Vague justifications are avoided — each rationale references
a specific constraint from the audit or the codebase.

---

### Decision: Production WSGI server (gunicorn vs Werkzeug)
**Context:** The starter app used `app.run()` which starts Flask's built-in
Werkzeug development server. Werkzeug explicitly documents itself as not
suitable for production and does not handle SIGTERM gracefully — it exits
immediately, dropping in-flight requests during pod termination.

**Options considered:**
- **Keep Werkzeug dev server** — zero new dependencies, but drops in-flight requests on SIGTERM and is single-threaded. Flask's own docs say "Do not use the development server in production."
- **gunicorn** — production-grade WSGI server, handles SIGTERM with a configurable drain period (`--graceful-timeout`), supports multiple workers, widely used in the Flask ecosystem.
- **uvicorn (ASGI)** — higher performance for async workloads, but this app is synchronous Flask; switching to ASGI would require rewriting the app, which conflicts with the "no large rewrites" constraint.

**Chosen:** gunicorn

**Rationale:** gunicorn's `--graceful-timeout 25` directly solves the SIGTERM
drain requirement (AUDIT.md R4) without changing the application code. The
25s timeout is set below `terminationGracePeriodSeconds: 30` so gunicorn
finishes draining before Kubernetes sends SIGKILL, giving a 5-second margin.

**Cost / risk you accepted:** Two gunicorn worker processes consume slightly
more memory at idle (~20MB extra) than a single Werkzeug process. This is
acceptable given the 128Mi memory limit still provides headroom.

---

### Decision: Port 8080 instead of port 80
**Context:** The starter app bound to port 80. Port 80 is a privileged Linux
port (< 1024) that requires either root privileges or the `NET_BIND_SERVICE`
capability to bind. This directly conflicted with the requirement to run as a
non-root user (AUDIT.md S1) with all capabilities dropped (AUDIT.md S4).

**Options considered:**
- **Keep port 80, add NET_BIND_SERVICE capability** — allows non-root binding to port 80 but requires adding back a capability after dropping ALL, partially defeating the hardening goal.
- **Change to port 8080** — unprivileged port, no capabilities required, compatible with `capabilities.drop: [ALL]`. The Service layer abstracts the port from external consumers anyway.
- **Change to port 5000** (Flask default) — equally valid, but 8080 is the more widely recognised convention for HTTP services in containers.

**Chosen:** Port 8080

**Rationale:** Fixing the port to 8080 resolves the compound defect (AUDIT.md
R5) cleanly — non-root user + no capabilities + non-privileged port are all
consistent. The Kubernetes Service exposes port 8080 externally, so the change
is invisible to callers.

**Cost / risk you accepted:** Any existing port-forward scripts or firewall
rules targeting port 80 need updating. This is a one-time migration cost
documented in the README.

---

### Decision: Secret management — Terraform-managed Kubernetes Secret
**Context:** The starter repo had the API token hardcoded in two places:
`helm/skybyte-app/values.yaml` and `terraform/variables.tf` as a default value
(AUDIT.md S2, S3). Both were committed to version control in plain text.

**Options considered:**
- **External Secrets Operator (ESO) + AWS Secrets Manager** — the gold standard for production; secrets never touch Kubernetes etcd in plaintext. Requires the ESO operator to be installed in the cluster and AWS credentials configured.
- **Sealed Secrets (Bitnami)** — encrypts secrets client-side before committing; safe for GitOps. Requires the Sealed Secrets controller installed in the cluster and the `kubeseal` CLI.
- **Terraform-managed Kubernetes Secret, value supplied via `TF_VAR_api_token`** — creates the Secret in-cluster via Terraform; the token is never in version control. Simpler than ESO or Sealed Secrets — no additional operator required.
- **Helm --set at install time** — passes token as a Helm value; still visible in Helm release history in plain text.

**Chosen:** Terraform-managed Kubernetes Secret (`kubernetes_secret` resource),
token supplied via `TF_VAR_api_token` environment variable (never committed).

**Rationale:** This exercise uses a local Minikube/Kind cluster with no
external secrets infrastructure. ESO and Sealed Secrets both require cluster
operators to be pre-installed — adding them would be out of scope and would
break `setup.sh` on a fresh cluster. The Terraform approach eliminates the
plain-text-in-git problem (the primary defect) with no additional dependencies.

**Cost / risk you accepted:** The token still exists in Terraform state
(`terraform.tfstate`) in plaintext. In a real environment, state would be
stored in an encrypted remote backend (S3 + KMS). For this local exercise,
state is local only. This is explicitly called out as a "Things I would do
next" item in the README.

---

### Decision: Prometheus scrape annotations vs ServiceMonitor
**Context:** The `/metrics` endpoint needed to be discoverable by Prometheus.
Two standard patterns exist: pod/service annotations and the `ServiceMonitor`
CRD (from Prometheus Operator).

**Options considered:**
- **ServiceMonitor CRD** — the "cloud native" pattern; works with Prometheus Operator's target discovery. Requires Prometheus Operator to be installed in the cluster (`monitoring.coreos.com` API group).
- **Prometheus scrape annotations** (`prometheus.io/scrape`, `prometheus.io/port`, `prometheus.io/path`) — supported by any Prometheus deployment configured with the standard Kubernetes SD config. No CRD dependency.

**Chosen:** Prometheus scrape annotations on the Pod template.

**Rationale:** The challenge uses a fresh Minikube/Kind cluster. Prometheus
Operator is not in the setup prerequisites. Adding a `ServiceMonitor` that
requires Prometheus Operator would make the Helm chart fail on any cluster
without it, breaking `helm lint` with `kyverno` kubeconform validation on
unknown CRDs. Annotations work with any standard Prometheus deployment and
degrade gracefully (ignored if Prometheus isn't present) rather than hard-failing.

**Cost / risk you accepted:** Scrape annotations are less flexible than
`ServiceMonitor` — they don't support TLS scraping, custom relabelling, or
per-endpoint scrape intervals. For a production environment with Prometheus
Operator already installed, `ServiceMonitor` would be the correct choice.

---

### Decision: ruff over flake8 for Python linting
**Context:** The original CI used flake8 with `--exclude=app/* --exit-zero` —
a no-op lint step (AUDIT.md H1). The replacement needed to actually enforce
code quality.

**Options considered:**
- **flake8** — the established tool; wide plugin ecosystem (flake8-bugbear, etc.). Written in Python; slower on large codebases.
- **ruff** — written in Rust; 10–100x faster than flake8; replaces flake8 + isort + pyupgrade in a single binary; actively developed by Astral; natively understands flake8 rules (E, W, F series) plus many more.
- **pylint** — deeper analysis but much slower, more opinionated, higher false-positive rate. Overkill for a minimal service.

**Chosen:** ruff

**Rationale:** For a CI pipeline that must complete quickly, ruff's speed
advantage matters at scale. More importantly, ruff is a single dependency
replacing several tools, which reduces the CI setup time and dependency surface.
The rule set is compatible with what flake8 would have enforced, so the
transition has no functional regression.

**Cost / risk you accepted:** ruff is newer than flake8; some teams may be
less familiar with its configuration format (`pyproject.toml` or `ruff.toml`
vs `.flake8`). This is a minor onboarding cost.

---

### Decision: kubeconform over kubeval for manifest validation
**Context:** `helm lint` validates chart structure but not the rendered
Kubernetes manifests against the API schema (AUDIT.md H3). A schema validator
was needed for the CI pipeline.

**Options considered:**
- **kubeval** — the original tool for Kubernetes manifest validation. No longer actively maintained (last release 2021); does not support Kubernetes versions beyond 1.22 out of the box.
- **kubeconform** — the actively maintained successor to kubeval; supports current Kubernetes versions; faster; works as a drop-in replacement with the same pipe-from-helm-template pattern.

**Chosen:** kubeconform

**Rationale:** kubeval is effectively end-of-life. Using it for a new project
would mean immediately inheriting a maintenance problem — Kubernetes 1.29+ API
schemas are not available. kubeconform has identical usage patterns, so there
is no trade-off in familiarity.

**Cost / risk you accepted:** kubeconform does not validate custom CRD schemas
(e.g. Kyverno `ClusterPolicy` resources) out of the box. These are skipped
with `--ignore-missing-schemas`. Validated by `kyverno apply` in a separate CI
job instead.

---

### Decision: Kyverno over Gatekeeper for policy-as-code
**Context:** Policy-as-code was required to catch the security (no-root) and
reliability (no resource limits) defects that existed in the starter repo.

**Options considered:**
- **Gatekeeper (OPA)** — policies written in Rego; very expressive; the CNCF project for policy enforcement. Requires learning Rego, which has a steep learning curve and is a separate language from the rest of the stack.
- **Kyverno** — policies written as Kubernetes-native YAML using pattern matching; no separate policy language to learn; integrates directly with `helm install` via admission webhooks; `kyverno apply` CLI enables CI-side validation without a running cluster.

**Chosen:** Kyverno

**Rationale:** This stack is Helm-first. Kyverno policies are plain YAML with
the same structure as Kubernetes resources, meaning any engineer who can read
a Deployment manifest can read and write a Kyverno policy. The `kyverno apply`
CLI runs policies against static manifests in CI without requiring a live
cluster — critical for the CI pipeline in this exercise. We accept the trade-off
that Kyverno's pattern matching is less expressive than Rego for complex
multi-resource policies.

**Cost / risk you accepted:** Kyverno's pattern-matching DSL cannot express
some complex cross-resource policies that Rego can (e.g. "deny if Service
exposes a port that isn't in the allow-list of the namespace's NetworkPolicy").
For the policies needed here (non-root, resource limits), Kyverno's patterns
are fully sufficient.

---

### Decision: Multi-stage Docker build
**Context:** The starter Dockerfile used a single-stage build from
`python:3.9` (the full Debian image, ~900MB) with no separation between build
and runtime dependencies (AUDIT.md S5, H5).

**Options considered:**
- **Single-stage build, python:3.12-slim** — simpler Dockerfile; slim reduces the image significantly (~150MB vs ~900MB) but still includes pip, setuptools, and wheel in the final image.
- **Multi-stage build: builder (slim) → runtime (slim)** — pip and build tools are in the builder stage only; the runtime image contains only the installed packages and application code. Larger Dockerfile but smaller, cleaner runtime image.
- **Multi-stage build: builder (slim) → runtime (distroless)** — minimal attack surface; no shell, no package manager. Harder to debug in production (no `kubectl exec -- sh`). For a challenge that requires `system-checks.sh` to exec into the container, no shell is impractical.

**Chosen:** Multi-stage build, `python:3.12-slim-bookworm` for both stages.

**Rationale:** The multi-stage approach removes pip, wheel, and setuptools from
the runtime image, reducing the CVE surface without giving up debuggability
(the slim image retains a shell for `kubectl exec`). Distroless was rejected
specifically because `system-checks.sh` uses `kubectl exec -- id` and
`kubectl exec -- ss` — these require a shell and POSIX utilities.

**Cost / risk you accepted:** The final image is slightly larger than a
distroless equivalent (~130MB vs ~50MB). For a production hardening pass with
more time, a distroless runtime with a debug sidecar would be considered.

---

### Decision: Liveness probe on /healthz, readiness probe on /readyz (separate endpoints)
**Context:** Both starter probes pointed to `/` — the business endpoint
(AUDIT.md R1, R2). This meant a traffic spike causing slow responses on `/`
could trigger unnecessary pod restarts.

**Options considered:**
- **Both probes on `/healthz`** — a single health endpoint for both. Simple, but loses the ability to distinguish "alive but not ready" from "dead."
- **Liveness on `/healthz`, readiness on `/healthz`** — same as above.
- **Liveness on `/healthz`, readiness on `/readyz`** (separate endpoints) — allows a pod to signal "I'm alive but not ready for traffic" without triggering a restart. This is the pattern recommended by the Kubernetes docs for stateful startup scenarios.

**Chosen:** Liveness → `/healthz`, Readiness → `/readyz`

**Rationale:** Separating the endpoints costs two trivial route definitions in
the app but enables a meaningful operational difference: if a future dependency
(DB, cache) becomes temporarily unavailable, the readiness probe can fail
(removing the pod from the load balancer) while the liveness probe keeps
passing (preventing an unnecessary restart). This is not needed now for this
stateless service, but the pattern is cheap to establish and expensive to
retrofit later.

**Cost / risk you accepted:** Two endpoints to maintain instead of one. For
this simple service, both return hardcoded 200s — the operational benefit is
forward-looking rather than immediate.

---

### Decision: terminationGracePeriodSeconds: 30, gunicorn --graceful-timeout: 25
**Context:** Kubernetes sends SIGTERM to the pod at t=0, then SIGKILL at
t=`terminationGracePeriodSeconds`. gunicorn has its own drain timeout
(`--graceful-timeout`) that must complete before the SIGKILL arrives.

**Options considered:**
- **terminationGracePeriodSeconds: 60, graceful-timeout: 55** — more time for long-running requests. Increases rolling update duration and means slow pods block deployments for up to a minute.
- **terminationGracePeriodSeconds: 30, graceful-timeout: 25** — 30s is the Kubernetes default; familiar to operators. Suitable for this service where no request should legitimately take more than a few seconds.
- **terminationGracePeriodSeconds: 10, graceful-timeout: 8** — fast rollouts. Too aggressive — a slow network or GC pause could cause requests to be dropped.

**Chosen:** `terminationGracePeriodSeconds: 30`, `gunicorn --graceful-timeout 25`

**Rationale:** The 5-second gap between gunicorn's drain (25s) and Kubernetes'
hard kill (30s) provides a safety margin. For a greeting service with
sub-millisecond response times, 25 seconds of drain time is more than
sufficient for all in-flight requests to complete. The 30s pod termination
period is the Kubernetes default, so it requires no explanation to operators
familiar with the platform.

**Cost / risk you accepted:** If a future endpoint introduces long-running
operations (file processing, external API calls), 25s may not be enough.
That decision should be revisited when such endpoints are added.

---

## Kyverno Policy Rejection Output

The following output was produced by running:
```bash
kyverno apply policies/ --resource policies/test-fixtures/bad-pod.yaml
```

Against `policies/test-fixtures/bad-pod.yaml` — a Pod with no `securityContext`
and no `resources` block:

```
kubectl apply -f policies/test-fixtures/bad-pod.yaml

Error from server: error when creating "policies/test-fixtures/bad-pod.yaml": admission webhook "validate.kyverno.svc-fail" denied the request: 

resource Pod/devops-challenge/bad-pod was blocked due to the following policies 

disallow-root-user:
  check-run-as-non-root: 'validation error: Containers must not run as root. Set securityContext.runAsNonRoot:
    true on the pod or container spec. rule check-run-as-non-root failed at path /spec/containers/0/securityContext/'
require-resource-limits:
  check-resource-requests-limits: 'validation error: All containers must declare resources.requests
    and resources.limits for both cpu and memory. rule check-resource-requests-limits
    failed at path /spec/containers/0/resources/limits/'

```

Both policies reject the bad manifest as expected. The same policies are
applied in CI via the `kyverno-policy-check` job in `.github/workflows/ci.yml`,
which renders the Helm chart and runs `kyverno apply` against the output,
blocking any PR that introduces a regression.