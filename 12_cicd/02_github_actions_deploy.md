# GitHub Actions Deploy
> Module 12 · Lesson 02 | [↑ Course Index](../README.md)


[![Course Index](https://img.shields.io/badge/Course-Index-0f766e)](../README.md)
[![License: CC BY-NC-SA 4.0](https://img.shields.io/badge/License-CC%20BY--NC--SA%204.0-lightgrey)](../LICENSE.md)

## Table of Contents
- [Overview](#overview)
- [GitHub Actions Architecture](#github-actions-architecture)
- [Full Pipeline Flow](#full-pipeline-flow)
- [Deploy-to-k3s Sequence](#deploy-to-k3s-sequence)
- [Runner Options for k3s](#runner-options-for-k3s)
- [Setting Up the KUBECONFIG Secret](#setting-up-the-kubeconfig-secret)
- [Building and Pushing to GHCR](#building-and-pushing-to-ghcr)
- [Deploying to k3s with kubectl and Helm](#deploying-to-k3s-with-kubectl-and-helm)
- [Caching Docker Layers](#caching-docker-layers)
- [Running Tests](#running-tests)
- [Environment Approvals](#environment-approvals)
- [Complete End-to-End Workflow](#complete-end-to-end-workflow)
- [Lab](#lab)

---

## Overview

GitHub Actions is a CI/CD platform built into GitHub. Workflows are YAML files stored in `.github/workflows/` and trigger on repository events (push, PR, release, schedule). Each workflow runs on GitHub-hosted or self-hosted runners.

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

## GitHub Actions Architecture

```mermaid
flowchart TD
    subgraph GitHub
        REPO[("Repository<br/>.github/workflows/")] -->|"on: push"| EVENT["Workflow trigger event"]
        EVENT --> QUEUE["Job queue"]
    end

    subgraph "GitHub-Hosted Runner (ubuntu-latest)"
        QUEUE --> JOB1["Job: test<br/>Run unit tests"]
        JOB1 -->|"needs: test"| JOB2["Job: build<br/>Docker build + push to GHCR"]
        JOB2 -->|"needs: build"| JOB3["Job: deploy<br/>Helm upgrade → k3s"]
        JOB3 --> JOB4["Job: notify<br/>Slack / GitHub status"]
    end

    subgraph "k3s Cluster"
        JOB3 -->|"kubectl / helm via KUBECONFIG secret"| K3S["k3s API Server"]
        K3S --> DEPLOY["Updated Deployment"]
    end

    subgraph Registry
        JOB2 -->|"docker push"| GHCR[("GHCR<br/>ghcr.io")]
        GHCR -->|"imagePullSecrets"| DEPLOY
    end
```

### Key concepts

| Concept | Description |
|---|---|
| **Workflow** | A YAML file defining the full CI/CD process |
| **Event** | What triggers the workflow (`push`, `pull_request`, `schedule`) |
| **Job** | A group of steps running on a single runner |
| **Step** | A single command or action within a job |
| **Action** | A reusable unit (from marketplace or local `./`) |
| **Runner** | The machine that executes jobs |
| **Secret** | Encrypted key/value stored at repo or org level |
| **Environment** | A deployment target with optional protection rules |

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

## Full Pipeline Flow

The architecture diagram above shows infrastructure relationships; this diagram shows the **temporal flow** — what happens in order during a typical production deploy, including failure paths.

```mermaid
flowchart LR
    PUSH["Code push<br/>to main branch"]
    TRIGGER["Workflow trigger<br/>on: push branches: main"]
    TEST["test job<br/>unit + integration tests"]
    TEST_FAIL{{"tests pass?"}}
    BUILD["build job<br/>docker build + push to GHCR"]
    BUILD_FAIL{{"build success?"}}
    DEPLOY["deploy job<br/>helm upgrade --install"]
    ROLLOUT["rollout status<br/>kubectl rollout status --timeout=5m"]
    ROLLOUT_OK{{"rollout healthy?"}}
    NOTIFY_OK["notify job<br/>Slack: deployment succeeded"]
    NOTIFY_FAIL["notify job<br/>Slack: deployment FAILED"]
    CANCEL["workflow cancelled<br/>no deploy"]

    PUSH --> TRIGGER
    TRIGGER --> TEST
    TEST --> TEST_FAIL
    TEST_FAIL -->|"yes"| BUILD
    TEST_FAIL -->|"no"| CANCEL
    BUILD --> BUILD_FAIL
    BUILD_FAIL -->|"yes"| DEPLOY
    BUILD_FAIL -->|"no"| CANCEL
    DEPLOY --> ROLLOUT
    ROLLOUT --> ROLLOUT_OK
    ROLLOUT_OK -->|"yes"| NOTIFY_OK
    ROLLOUT_OK -->|"no — helm --atomic rolls back"| NOTIFY_FAIL

    style NOTIFY_OK fill:#16a34a,color:#fff
    style NOTIFY_FAIL fill:#dc2626,color:#fff
    style CANCEL fill:#6b7280,color:#fff
```

The `--atomic` flag on `helm upgrade` is critical for production pipelines: if the rollout fails its health checks within the timeout, Helm automatically rolls back to the previous release and the job exits with a non-zero status. This guarantees the deploy job only succeeds when the new version is actually healthy.

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

## Deploy-to-k3s Sequence

The deploy step is where most pipeline issues originate. Understanding the exact sequence of operations — and which component is responsible at each stage — accelerates debugging.

```mermaid
sequenceDiagram
    participant GHA as "GitHub Actions Runner"
    participant GHCR as "GHCR (ghcr.io)"
    participant K3S as "k3s API Server"
    participant HELM as "Helm (on runner)"
    participant DEP as "Deployment Controller"
    participant SLACK as "Slack Webhook"

    Note over GHA: deploy job starts after build job succeeds

    GHA->>GHA: decode KUBECONFIG_BASE64 secret
    GHA->>GHA: write ~/.kube/config (chmod 600)

    GHA->>K3S: kubectl cluster-info (connectivity check)
    K3S-->>GHA: cluster reachable

    GHA->>HELM: helm upgrade --install my-app<br/>--set image.tag=<sha><br/>--atomic --timeout 5m --wait

    HELM->>K3S: get current release state
    K3S-->>HELM: current release manifest

    HELM->>K3S: apply new manifests<br/>(Deployment with new image tag)
    K3S->>DEP: trigger rollout

    loop Pod readiness check (--wait)
        DEP->>GHCR: pull new image
        GHCR-->>DEP: image layers
        DEP-->>K3S: pod Running + Ready
        K3S-->>HELM: availableReplicas updated
    end

    alt rollout succeeds within timeout
        HELM-->>GHA: exit 0 (success)
        GHA->>SLACK: POST deployment succeeded
    else rollout fails (CrashLoopBackOff, timeout, etc.)
        HELM->>K3S: helm rollback (--atomic)
        K3S-->>DEP: restore previous Deployment
        HELM-->>GHA: exit 1 (failure)
        GHA->>SLACK: POST deployment FAILED — rolled back
    end
```

Three things to note in this sequence:

1. **Connectivity check first** — a quick `kubectl cluster-info` before the Helm command gives you a clear error message if the KUBECONFIG is wrong or the cluster is unreachable, rather than a confusing Helm timeout.
2. **`--wait` vs `--atomic`** — `--wait` blocks until pods are ready; `--atomic` adds automatic rollback on failure. Always use both in production pipelines.
3. **Image pull happens on the node**, not the runner — if the GHCR image is private, the cluster needs an `imagePullSecret` with GHCR credentials, not just the runner's `GITHUB_TOKEN`.

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

## Runner Options for k3s

Choosing the right runner type for k3s deployments involves trade-offs between cost, network access, and maintenance overhead.

```mermaid
graph TD
    ROOT{{"Which runner<br/>for k3s deploys?"}}

    GH["GitHub-Hosted Runner<br/>(ubuntu-latest)"]
    SH["Self-Hosted Runner<br/>(runs on your infra)"]

    GH_PROS["Pros:<br/>• Zero maintenance<br/>• Fresh environment per job<br/>• Built-in secrets isolation<br/>• Free for public repos"]
    GH_CONS["Cons:<br/>• k3s must be internet-accessible<br/>• Network egress charges<br/>• 6h job timeout<br/>• Slower cold starts"]

    GH_EXPOSE["k3s exposure options:<br/>A) Public IP + firewall rules<br/>B) Tailscale / WireGuard VPN<br/>C) Cloudflare Tunnel (no public port)"]

    SH_PROS["Pros:<br/>• Private network access to k3s<br/>• Faster (no cold start)<br/>• Persistent caches (Docker layers)<br/>• No egress charges"]
    SH_CONS["Cons:<br/>• You maintain the runner VM<br/>• Security: runner has cluster access<br/>• Must handle runner updates<br/>• Shared state between runs"]

    SH_WHERE["Where to run self-hosted:<br/>A) VM on same network as k3s<br/>B) Pod inside k3s itself<br/>C) Raspberry Pi / homelab node"]

    ROOT -->|"k3s is internet-accessible<br/>or simple setup"| GH
    ROOT -->|"k3s is private / on-prem<br/>or high build frequency"| SH

    GH --> GH_PROS
    GH --> GH_CONS
    GH_CONS --> GH_EXPOSE

    SH --> SH_PROS
    SH --> SH_CONS
    SH_CONS --> SH_WHERE

    style GH fill:#1d4ed8,color:#fff
    style SH fill:#0f766e,color:#fff
```

### Installing a self-hosted runner on k3s

The cleanest approach for a private k3s cluster is to run the GitHub Actions runner as a Pod using the `actions-runner-controller` (ARC):

```bash
# Install ARC via Helm
helm repo add actions-runner-controller \
  https://actions-runner-controller.github.io/actions-runner-controller
helm install arc actions-runner-controller/actions-runner-controller \
  --namespace actions-runner-system \
  --create-namespace \
  --set authSecret.create=true \
  --set authSecret.github_token="${GITHUB_TOKEN}"

# Create a RunnerDeployment in your org/repo
kubectl apply -f - <<'EOF'
apiVersion: actions.summerwind.dev/v1alpha1
kind: RunnerDeployment
metadata:
  name: k3s-runner
  namespace: actions-runner-system
spec:
  replicas: 2
  template:
    spec:
      repository: my-org/my-repo
      labels:
        - self-hosted
        - k3s
EOF
```

Then in your workflow, target the self-hosted runner:

```yaml
jobs:
  deploy:
    runs-on: [self-hosted, k3s]
```

The runner pod already has in-cluster access to the k3s API server — no KUBECONFIG secret needed. Use a properly scoped ServiceAccount instead (see the RBAC section in Lesson 01).

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

## Setting Up the KUBECONFIG Secret

### Step 1: Create a dedicated CI ServiceAccount on the k3s cluster

See Module 12 Lesson 01 for RBAC details. Quick summary:

```bash
# Apply the CI RBAC resources
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ci-deployer
  namespace: production
---
apiVersion: v1
kind: Secret
metadata:
  name: ci-deployer-token
  namespace: production
  annotations:
    kubernetes.io/service-account.name: ci-deployer
type: kubernetes.io/service-account-token
EOF

# Wait for the token to be populated
kubectl wait secret ci-deployer-token -n production \
  --for=jsonpath='{.data.token}' --timeout=30s
```

### Step 2: Build and base64-encode the kubeconfig

```bash
K3S_SERVER="https://your-k3s-ip-or-hostname:6443"
K3S_CA=$(kubectl get secret ci-deployer-token -n production \
  -o jsonpath='{.data.ca\.crt}')
CI_TOKEN=$(kubectl get secret ci-deployer-token -n production \
  -o jsonpath='{.data.token}' | base64 -d)

cat <<EOF | base64 -w 0
apiVersion: v1
kind: Config
clusters:
  - cluster:
      certificate-authority-data: ${K3S_CA}
      server: ${K3S_SERVER}
    name: k3s-production
contexts:
  - context:
      cluster: k3s-production
      user: ci-deployer
      namespace: production
    name: ci-context
current-context: ci-context
users:
  - name: ci-deployer
    user:
      token: ${CI_TOKEN}
EOF
```

### Step 3: Add to GitHub repository secrets

1. Repository → Settings → Secrets and variables → Actions → New repository secret.
2. Name: `KUBECONFIG_BASE64`
3. Value: the output from Step 2.

Other secrets to add:

| Secret | Value |
|---|---|
| `SLACK_WEBHOOK_URL` | Slack Incoming Webhook URL |
| `REGISTRY_TOKEN` | (Optional) if using a private registry other than GHCR |

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

## Building and Pushing to GHCR

GitHub Container Registry (GHCR) is built into GitHub and is free for public repositories.

```yaml
- name: Log in to GHCR
  uses: docker/login-action@v3
  with:
    registry: ghcr.io
    username: ${{ github.actor }}
    password: ${{ secrets.GITHUB_TOKEN }}   # automatically available in all workflows

- name: Extract metadata for Docker
  id: meta
  uses: docker/metadata-action@v5
  with:
    images: ghcr.io/${{ github.repository }}
    tags: |
      type=sha,prefix=,suffix=,format=short   # ghcr.io/org/repo:abc1234
      type=ref,event=branch                    # ghcr.io/org/repo:main
      type=semver,pattern={{version}}          # ghcr.io/org/repo:1.2.3 (on tags)
      type=raw,value=latest,enable={{is_default_branch}}

- name: Build and push Docker image
  uses: docker/build-push-action@v5
  with:
    context: .
    push: true
    tags: ${{ steps.meta.outputs.tags }}
    labels: ${{ steps.meta.outputs.labels }}
    cache-from: type=gha            # GitHub Actions cache
    cache-to: type=gha,mode=max
```

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

## Deploying to k3s with kubectl and Helm

### kubectl deploy

```yaml
- name: Set up kubeconfig
  run: |
    mkdir -p $HOME/.kube
    echo "${{ secrets.KUBECONFIG_BASE64 }}" | base64 -d > $HOME/.kube/config
    chmod 600 $HOME/.kube/config

- name: Deploy with kubectl
  run: |
    # Set the new image tag
    kubectl set image deployment/my-app \
      my-app=ghcr.io/${{ github.repository }}:${{ github.sha }} \
      -n production

    # Wait for rollout to complete
    kubectl rollout status deployment/my-app -n production --timeout=5m
```

### Helm deploy

```yaml
- name: Install Helm
  uses: azure/setup-helm@v3
  with:
    version: v3.14.0

- name: Deploy with Helm
  run: |
    helm upgrade --install my-app ./charts/my-app \
      --namespace production \
      --create-namespace \
      --set image.repository=ghcr.io/${{ github.repository }} \
      --set image.tag=${{ github.sha }} \
      --set replicaCount=2 \
      --atomic \
      --timeout 5m \
      --wait
```

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

## Caching Docker Layers

Caching dramatically speeds up image builds (from minutes to seconds for small changes).

### GitHub Actions Cache (recommended)

```yaml
- name: Set up Docker Buildx
  uses: docker/setup-buildx-action@v3

- name: Build and push
  uses: docker/build-push-action@v5
  with:
    context: .
    push: true
    tags: ghcr.io/${{ github.repository }}:${{ github.sha }}
    cache-from: type=gha
    cache-to: type=gha,mode=max   # mode=max caches all layers, not just final
```

### Registry cache (useful for self-hosted runners)

```yaml
- name: Build and push with registry cache
  uses: docker/build-push-action@v5
  with:
    context: .
    push: true
    tags: ghcr.io/${{ github.repository }}:${{ github.sha }}
    cache-from: type=registry,ref=ghcr.io/${{ github.repository }}:buildcache
    cache-to: type=registry,ref=ghcr.io/${{ github.repository }}:buildcache,mode=max
```

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

## Running Tests

### Unit tests

```yaml
- name: Run unit tests
  run: |
    # Python example
    pip install -r requirements-test.txt
    pytest tests/unit/ --junit-xml=test-results/unit.xml

    # Go example
    # go test ./... -v -coverprofile=coverage.out

    # Node example
    # npm ci && npm test

- name: Upload test results
  uses: actions/upload-artifact@v4
  if: always()   # upload even if tests fail
  with:
    name: unit-test-results
    path: test-results/
```

### Container-level integration tests

```yaml
- name: Run integration tests against built image
  run: |
    # Start the container
    docker run -d --name app-test \
      -p 8080:8080 \
      -e DATABASE_URL=sqlite:///:memory: \
      ghcr.io/${{ github.repository }}:${{ github.sha }}

    # Wait for it to be ready
    timeout 30 bash -c 'until curl -sf http://localhost:8080/healthz; do sleep 1; done'

    # Run tests
    curl -sf http://localhost:8080/healthz | grep '"status":"ok"'
    curl -sf http://localhost:8080/api/v1/status

    # Cleanup
    docker rm -f app-test
```

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

## Environment Approvals

GitHub Environments let you require human approval before deploying to sensitive targets.

### Create a protected environment

1. Repository → Settings → Environments → New environment.
2. Name: `production`.
3. Enable **Required reviewers** — add your ops team.
4. Optionally set **Deployment branches** to `main` only.
5. Add environment-specific secrets (e.g., production KUBECONFIG).

### Use the environment in a workflow job

```yaml
jobs:
  deploy-production:
    runs-on: ubuntu-latest
    environment:
      name: production               # must match the environment name in Settings
      url: https://app.example.com   # shown as a link in the GitHub UI
    steps:
      - name: Deploy to production
        run: helm upgrade --install ...
```

When this job runs, GitHub pauses and sends a notification to the required reviewers. The deployment only proceeds after approval.

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

## Complete End-to-End Workflow

The complete workflow is at `labs/github-actions-deploy.yml`. Here is a structural overview:

```yaml
name: Build, Test, and Deploy

on:
  push:
    branches: [main]
  workflow_dispatch:   # allow manual trigger

# Prevent concurrent deploys to the same environment
concurrency:
  group: deploy-${{ github.ref }}
  cancel-in-progress: false

jobs:
  test:      # Run tests first
  build:     # Build and push image (needs: test)
  deploy:    # Helm deploy to k3s (needs: build, environment: production)
  notify:    # Slack notification (if: always(), needs: deploy)
```

Key points:
- `needs:` creates a dependency chain.
- `environment: production` triggers the approval gate.
- `if: always()` in the notify job ensures Slack gets both success and failure messages.
- `concurrency` prevents two deployments running simultaneously.

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

## Lab

```bash
# Prerequisites:
# - A GitHub repository with your application code
# - k3s running and accessible from the internet (or use ngrok for testing)
# - Helm chart in ./charts/my-app

# 1. Create the CI ServiceAccount and token
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: Namespace
metadata:
  name: production
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ci-deployer
  namespace: production
---
apiVersion: v1
kind: Secret
metadata:
  name: ci-deployer-token
  namespace: production
  annotations:
    kubernetes.io/service-account.name: ci-deployer
type: kubernetes.io/service-account-token
EOF

# 2. Apply RBAC (see labs/github-actions-deploy.yml for full example)
# ... (apply Role and RoleBinding as shown in Lesson 01)

# 3. Build and store kubeconfig
# (see "Setting Up the KUBECONFIG Secret" section above)

# 4. Copy labs/github-actions-deploy.yml to your repo
mkdir -p .github/workflows
cp labs/github-actions-deploy.yml .github/workflows/deploy.yml

# 5. Commit and push to trigger the workflow
git add .github/workflows/deploy.yml
git commit -m "ci: add GitHub Actions deploy workflow"
git push origin main

# 6. Watch the workflow run at:
# https://github.com/YOUR_ORG/YOUR_REPO/actions
```

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

*Licensed under [CC BY-NC-SA 4.0](../LICENSE.md) · © 2026 UncleJS*
