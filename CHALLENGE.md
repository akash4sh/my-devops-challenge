# DevOps Engineering Challenge: Inherit & Harden

**Role:** DevOps Engineer
**Time:** 48 hours from when *you* start the clock (tell us when you start; we trust you)
**Deliverables:** Public GitHub repository (your own — see §2; **do not fork**) + 60-minute live walkthrough call

---

## 1. Scenario

You've just joined Skybyte. The DevOps engineer before you left mid-sprint, and you've inherited their work-in-progress repository — a containerized Python service deployed via Helm into Kubernetes, with a Terraform module and a GitHub Actions pipeline.

It mostly works. It is also riddled with the kinds of small, dangerous mistakes that real production codebases collect: misconfigured probes, missing limits, a secret in plain text, a Dockerfile that builds as root, a Helm chart whose values don't match its templates, a CI pipeline that reports green while doing very little.

Your job is to **inherit it, harden it, observe it, and ship it.** You do not need to rewrite it — in fact, we will look at your `git diff` and we will be skeptical of large rewrites.

We've made the starter repo deliberately imperfect. Read it like a real engineer joining a company would: carefully and with suspicion.

> **The Golden Rule (this round):**
> Every change you make must be defensible. We will read your `DECISIONS.md` more carefully than your code. If you cannot explain *why* you chose a config value, an annotation, or a particular Kyverno policy, we will assume you do not actually own it.

---

## 2. The Starter Repository

This repository contains:

```
/
├── app/                  # Python service (intentionally minimal)
├── Dockerfile            # builds, but has hygiene/security issues
├── helm/                 # chart that deploys, but has gaps
├── terraform/            # provisions a namespace + RQ + secret, has issues
├── .github/workflows/    # CI that "passes" but doesn't actually validate much
├── setup.sh              # half-working
└── README.md             # outdated
```

**Don't fork.** Clone this repository, push the contents to a **new public repository under your own GitHub account** (any name you like — `<yourname>-devops-challenge` works), and develop there. We want to read your repo on its own merits, with your own git history, not as a fork branched off ours.

```bash
git clone https://github.com/Skybytech/devops-challenge.git my-devops-challenge
cd my-devops-challenge
rm -rf .git
git init && git add . && git commit -m "Import starter repo"
# create a new public repo on your GitHub (any name), then:
git remote add origin https://github.com/<your-handle>/<your-repo>.git
git branch -M main
git push -u origin main
```

Submit the URL of your new public repository.

---

## 3. What You Must Do

### Part 1 — Audit & defects (`AUDIT.md`)

Read the starter repo and produce an `AUDIT.md` listing every defect you found, categorized as:

- **Security** (e.g. running as root, secret in plain text, missing security context)
- **Reliability** (e.g. missing/incorrect probes, no resource limits, no graceful shutdown)
- **Hygiene** (e.g. CI not actually validating, lockfile missing, Dockerfile layering)
- **Documentation** (e.g. README claims X but code does Y)

For each defect, include: file path, what's wrong, why it matters in production, your fix.

You don't have to find every single one — but you do have to find the obvious ones, and we will ask you about the ones you missed.

### Part 2 — Hardening

Fix the defects. At minimum, the resulting deployment must:

1. Run as a non-root user with `readOnlyRootFilesystem: true`, `allowPrivilegeEscalation: false`, dropped capabilities, and a defined `seccompProfile`.
2. Have `requests`, `limits`, and a working `livenessProbe` and `readinessProbe` (with sensible thresholds — defaults are not sensible).
3. Handle SIGTERM gracefully — the application must stop accepting new requests, drain in-flight ones, and exit within `terminationGracePeriodSeconds`.
4. Move the secret out of the values file. You may use a Kubernetes `Secret` resource (managed via Terraform or sealed/external-secrets — your choice, defend it in DECISIONS.md).
5. Build from a pinned, minimal base image. No `:latest`. Distroless or `*-slim` strongly preferred.

### Part 3 — Observability

Add:

1. A `/metrics` endpoint exposing at least `http_requests_total` (with `method`, `path`, `status` labels) and request duration histogram.
2. The Prometheus scrape annotations or a `ServiceMonitor` (your choice, defend it).
3. One SLO statement in the README — write it as a sentence: "99% of requests to `/` complete in under N ms over a rolling 7-day window." Pick a defensible N for *this* application and explain how you'd know if it broke.

### Part 4 — Policy-as-code

Add at least **two** Kyverno (preferred) or Gatekeeper policies that would have caught the original defects, applied via the Helm install or via `terraform apply`:

1. One must enforce a non-negotiable security baseline (e.g. "containers must not run as root in this namespace").
2. One must catch a regression that bit *you* during this exercise (e.g. "containers must declare resource requests").

Test that the policy actually rejects a bad manifest. Include the rejection output in `DECISIONS.md`.

### Part 5 — CI that earns its green checkmark

The original CI claims to lint and validate. It mostly doesn't. Replace it with a workflow that:

1. Lints Python (`ruff` or `flake8` — defensible choice).
2. Runs Python unit tests against the metric endpoint.
3. Runs `helm lint` *and* `helm template | kubeconform` (or `kubeval`) so you actually catch broken manifests.
4. Runs `terraform fmt -check` and `terraform validate`.
5. Builds the Docker image with a multi-arch buildx setup (amd64 + arm64) and runs `trivy fs` on the source and `trivy image` on the built image. Fail the build on `HIGH` or above.
6. Runs your Kyverno policies in CI against your rendered manifests (`kyverno apply`).

We will reject submissions whose CI pipeline reports green while skipping these checks.

### Part 6 — Deploy & demonstrate

`setup.sh` must build, apply Terraform, install/upgrade Helm, and exit non-zero on any failed step. The script should be idempotent (running it twice should not break anything).

Create `system-checks.sh` that:

1. Prints the in-container UID (proving non-root).
2. Prints the bound port and capabilities.
3. Curls `/` and validates the response body.
4. Curls `/metrics` and greps for `http_requests_total`.
5. Kills the running pod (`kubectl delete pod`) and verifies the deployment recovers within 30s with no failed health checks during the rollout.

### Part 7 — Decisions log (`DECISIONS.md`)

This is the most important file in your submission. For every meaningful choice you made, write one block in this format:

```
### Decision: <short title>
**Context:** what constraint or problem this addresses
**Options considered:** at least 2 alternatives, with one-line trade-off for each
**Chosen:** the option you picked
**Rationale:** why — referencing the constraint, not generic best-practice
**Cost / risk you accepted:** what you knowingly didn't optimise for
```

We expect at least 8 decisions. Vague generalities ("more secure," "industry best practice") will count against you. Specifics ("we chose Kyverno over Gatekeeper because the team is already on Helm and Kyverno's syntax is closer to plain YAML, accepting that we lose Rego's expressivity") will count for you.

### Part 8 — Demo recording

Record an [asciinema](https://asciinema.org/) of you running `setup.sh` from a fresh clone on an empty Minikube/Kind, followed by `system-checks.sh`. Include the asciinema link in the README. (We will run it ourselves too — the recording is not a substitute for working code, it's a proof you've done it end-to-end yourself.)

---

## 4. Submission

Submit your **public GitHub repo URL** (your own repo, not a fork — see §2) before the 48-hour deadline. Final repo structure:

```
/
├── app/
├── helm/
├── terraform/
├── policies/             # NEW — Kyverno/Gatekeeper policies
├── .github/workflows/
├── Dockerfile
├── setup.sh
├── system-checks.sh      # NEW
├── AUDIT.md              # NEW — defects you found
├── DECISIONS.md          # NEW — judgment, in the format above
└── README.md
```

The `README.md` must include:

- Prerequisites (Minikube/Kind/Docker Desktop, versions you tested against).
- A 1-paragraph summary of *what was wrong* with the starter repo and *what you changed*.
- The asciinema link.
- The SLO statement.
- A "Things I would do next with another week" section. We read this carefully — it tells us what you noticed but consciously deferred.

**Commits:** we will read your `git log`. We expect spaced, meaningful commits with messages that explain *why*, not just *what*. A single 48-hour-mark commit dump will count against you.

---

## 5. Live Walkthrough (Mandatory, 60 min)

Once we receive your submission, we will schedule a 60-minute video call. You will:

1. Screen-share and run `setup.sh` from a freshly cloned repo on **your machine**.
2. Walk us through your `AUDIT.md` and `DECISIONS.md`, defending choices.
3. Implement one small live extension we hand you on the call (we will not tell you in advance — it will be a 15-minute task within the scope of what you've already built).
4. Answer follow-up questions about trade-offs.

This stage is non-optional. A working repo with a weak walkthrough is a no.

---

## 6. Evaluation Criteria

| Area | What we're looking for |
|---|---|
| **Reading skill** (Part 1) | Did you actually find the defects, or did you rewrite past them? |
| **Security** (Part 2, 4) | SecurityContext, image hygiene, secret handling, policy enforcement |
| **Reliability** (Part 2, 6) | Probes, resource model, graceful shutdown, recovery from `kubectl delete pod` |
| **Observability** (Part 3) | Useful metrics, sensible SLO, defensible scrape strategy |
| **CI quality** (Part 5) | Does green actually mean green? |
| **Judgment** (`DECISIONS.md`) | Specificity, alternatives considered, costs accepted |
| **Communication** (README, walkthrough) | Can you explain why, on the spot, to a teammate? |
| **Commit hygiene** | Spacing, messages, no last-minute dump |

We do not care whether you used AI assistance — most of us do too. We do care that you can defend every line of code you submit. If you cannot explain a decision live, we will assume the decision is not yours.

---

## 7. What We Will *Not* Hold Against You

- Skipping a stretch goal that you flagged in "Things I would do next."
- Choosing one valid pattern when another would also have worked, *if* you defended your choice in DECISIONS.md.
- A small bug you noticed and documented but ran out of time to fix (better than a hidden one).

> **Ship a cut, don't ship a sprawl.** This brief is intentionally larger than 48 hours of perfect work. A smaller, fully-defended slice with sharp decisions and a working `system-checks.sh` will beat a bloated half-finished pass at every part. In your README's "Things I would do next" section, tell us *what you cut and why* — that is signal, not weakness.

## 8. What We *Will* Hold Against You

- Anything in the README or DECISIONS.md that doesn't match the actual code.
- A green CI pipeline that doesn't actually validate.
- Inability to defend a choice on the live call.
- A single mass commit at hour 47.
- Generic "industry best practice" justifications without specifics.

---

Good luck. We are looking for someone who reads code carefully, makes deliberate choices, and can explain them. The repo is the artifact; your judgment is what we're hiring.
