# Flux Install and Setup
> Module 11 · Lesson 02 | [↑ Course Index](../README.md)


[![Course Index](https://img.shields.io/badge/Course-Index-0f766e)](../README.md)
[![License: CC BY-NC-SA 4.0](https://img.shields.io/badge/License-CC%20BY--NC--SA%204.0-lightgrey)](../LICENSE.md)

## Table of Contents
- [Overview](#overview)
- [Flux v2 Architecture](#flux-v2-architecture)
- [Flux Component CRD Map](#flux-component-crd-map)
- [Bootstrap Sequence](#bootstrap-sequence)
- [GitRepository to Kustomization Chain](#gitrepository-to-kustomization-chain)
- [Installing the Flux CLI](#installing-the-flux-cli)
- [Bootstrapping with GitHub](#bootstrapping-with-github)
- [Bootstrapping with GitLab](#bootstrapping-with-gitlab)
- [GitRepository and Kustomization Sources](#gitrepository-and-kustomization-sources)
- [Watching for Changes](#watching-for-changes)
- [Useful Flux CLI Commands](#useful-flux-cli-commands)
- [Lab](#lab)

---

## Overview

Flux v2 is a set of CNCF-graduated GitOps controllers for Kubernetes. Unlike Flux v1 (a monolithic daemon), Flux v2 is composed of independent, composable controllers — each managing a specific aspect of the GitOps pipeline.

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

## Flux v2 Architecture

```mermaid
graph TD
    subgraph "Source Layer"
        GR["GitRepository<br/>git clone + watch"]
        HR_SRC["HelmRepository<br/>fetch index.yaml"]
        OCIRepo["OCIRepository<br/>fetch OCI artifact"]
        Bucket["Bucket<br/>S3 / GCS source"]
    end

    subgraph "Flux Controllers"
        SC["source-controller<br/>fetches + archives sources"]
        KC["kustomize-controller<br/>applies Kustomizations"]
        HC["helm-controller<br/>manages HelmReleases"]
        NC["notification-controller<br/>sends alerts + receives webhooks"]
        IC["image-reflector-controller<br/>scans container registries"]
        IAC["image-automation-controller<br/>commits image tag updates"]
    end

    subgraph "Applied to Cluster"
        K8S["Kubernetes Resources"]
        HR_REL["Helm Releases"]
    end

    GR --> SC
    HR_SRC --> SC
    OCIRepo --> SC
    Bucket --> SC

    SC -->|artifact| KC
    SC -->|artifact| HC

    KC -->|"kubectl apply"| K8S
    HC -->|"helm upgrade --install"| HR_REL

    NC -->|"webhook trigger"| SC
    IC -->|"image tags"| IAC
    IAC -->|"git commit"| GR

    style SC fill:#6366f1,color:#fff
    style KC fill:#6366f1,color:#fff
    style HC fill:#6366f1,color:#fff
    style NC fill:#6366f1,color:#fff
```

### Controllers explained

| Controller | API Group | Purpose |
|---|---|---|
| **source-controller** | `source.toolkit.fluxcd.io` | Fetches sources (Git repos, Helm repos, OCI) and makes them available as artifacts |
| **kustomize-controller** | `kustomize.toolkit.fluxcd.io` | Applies `Kustomization` objects — runs `kustomize build` then `kubectl apply` |
| **helm-controller** | `helm.toolkit.fluxcd.io` | Manages `HelmRelease` objects — runs `helm upgrade --install` |
| **notification-controller** | `notification.toolkit.fluxcd.io` | Sends alerts (Slack, GitHub status) and receives webhooks for immediate reconciliation |
| **image-reflector-controller** | `image.toolkit.fluxcd.io` | Scans container registries and reflects tag lists into `ImageRepository` objects |
| **image-automation-controller** | `image.toolkit.fluxcd.io` | Updates image tags in Git based on `ImagePolicy` rules |

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

## Flux Component CRD Map

Each Flux controller owns a set of CRDs. Understanding which controller is responsible for which custom resource helps you know where to look when something goes wrong.

```mermaid
flowchart TD
    subgraph "source-controller"
        SC_CRDS["GitRepository<br/>HelmRepository<br/>OCIRepository<br/>Bucket<br/>HelmChart"]
    end

    subgraph "kustomize-controller"
        KC_CRDS["Kustomization"]
    end

    subgraph "helm-controller"
        HC_CRDS["HelmRelease"]
    end

    subgraph "notification-controller"
        NC_CRDS["Alert<br/>Provider<br/>Receiver"]
    end

    subgraph "image-reflector-controller"
        IC_CRDS["ImageRepository<br/>ImagePolicy"]
    end

    subgraph "image-automation-controller"
        IAC_CRDS["ImageUpdateAutomation"]
    end

    SC_CRDS -->|"produces artifacts consumed by"| KC_CRDS
    SC_CRDS -->|"produces artifacts consumed by"| HC_CRDS
    IC_CRDS -->|"feeds policies into"| IAC_CRDS
    IAC_CRDS -->|"commits tag updates,<br/>triggers"| SC_CRDS
    NC_CRDS -->|"webhook triggers"| SC_CRDS

    style SC_CRDS fill:#6366f1,color:#fff
    style KC_CRDS fill:#0f766e,color:#fff
    style HC_CRDS fill:#0f766e,color:#fff
    style NC_CRDS fill:#7c3aed,color:#fff
    style IC_CRDS fill:#b45309,color:#fff
    style IAC_CRDS fill:#b45309,color:#fff
```

When debugging Flux issues, match the failing resource type to its controller using this map, then check that controller's logs with `flux logs --kind=<controller>`.

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

## Bootstrap Sequence

The `flux bootstrap` command does considerably more than a simple `kubectl apply`. Understanding the full sequence makes it much easier to diagnose failures and reason about what is in your cluster after bootstrap completes.

```mermaid
sequenceDiagram
    participant CLI as "flux CLI<br/>(local machine)"
    participant GH as "GitHub API"
    participant REPO as "Git Repository"
    participant K8S as "k3s API Server"
    participant FC as "Flux Controllers<br/>(flux-system ns)"

    CLI->>GH: Create repo if not exists (PAT auth)
    GH-->>CLI: Repo URL confirmed

    CLI->>K8S: Install Flux CRDs
    K8S-->>CLI: CRDs ready

    CLI->>K8S: Deploy Flux controllers<br/>(source, kustomize, helm, notification)
    K8S-->>CLI: Controllers Running

    CLI->>CLI: Generate deploy key (SSH keypair)
    CLI->>GH: Register SSH deploy key on repository
    GH-->>CLI: Deploy key accepted

    CLI->>REPO: Commit Flux manifests to<br/>clusters/my-cluster/flux-system/
    REPO-->>CLI: Push confirmed

    Note over FC,REPO: Flux controllers now self-manage
    FC->>REPO: GitRepository polls every interval
    REPO-->>FC: Returns latest commit SHA

    FC->>FC: source-controller archives repo
    FC->>FC: kustomize-controller applies<br/>clusters/my-cluster/ path

    FC->>K8S: kubectl apply (idempotent)
    K8S-->>FC: Resources reconciled
```

This is why `flux bootstrap` is idempotent — if you run it twice, it simply re-applies the same manifests. If the deploy key already exists and the controllers are running, bootstrap becomes a no-op.

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

## GitRepository to Kustomization Chain

Once bootstrapped, every application you add to the cluster follows the same reconciliation chain. The diagram below traces a single manifest change from Git commit to running Pod.

```mermaid
graph LR
    GIT[("Git Repo<br/>(GitHub)")]
    GR["GitRepository CR<br/>polls every interval"]
    ART[("Artifact archive<br/>(tar.gz in source-controller)")]
    KZ["Kustomization CR<br/>path: ./deploy/production"]
    KB["kustomize build<br/>(runs in memory)"]
    KA["kubectl apply<br/>(server-side apply)"]
    DEP["Deployment / Service /<br/>ConfigMap in cluster"]
    HC_CHECK["Health check<br/>deployment.status.availableReplicas"]
    READY{{"All healthy?"}}
    SYNC_OK["Kustomization<br/>status: Ready=True"]
    SYNC_FAIL["Kustomization<br/>status: Ready=False"]

    GIT -->|"new commit detected"| GR
    GR -->|"clone + archive"| ART
    ART -->|"sourceRef"| KZ
    KZ -->|"extract + build"| KB
    KB -->|"apply manifests"| KA
    KA -->|"creates/updates"| DEP
    DEP -->|"checked by"| HC_CHECK
    HC_CHECK --> READY
    READY -->|"yes"| SYNC_OK
    READY -->|"no (timeout)"| SYNC_FAIL

    style GIT fill:#24292e,color:#fff
    style SYNC_OK fill:#16a34a,color:#fff
    style SYNC_FAIL fill:#dc2626,color:#fff
```

The key insight: `source-controller` and `kustomize-controller` are decoupled. A `Kustomization` references a `GitRepository` by name — you can have many `Kustomization` objects all pointing at the same `GitRepository` source, applying different paths with different intervals and target namespaces.

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

## Installing the Flux CLI

The Flux CLI (`flux`) is used to bootstrap Flux into your cluster and interact with it.

### Linux / macOS

```bash
# Official install script
curl -s https://fluxcd.io/install.sh | sudo bash

# Verify
flux --version
# flux version 2.x.x
```

### Using Homebrew (macOS)

```bash
brew install fluxcd/tap/flux
```

### Using asdf

```bash
asdf plugin-add flux2 https://github.com/tableflip/asdf-flux2
asdf install flux2 latest
asdf global flux2 latest
```

### Pre-flight check

Before bootstrapping, verify your cluster meets requirements:

```bash
flux check --pre
# ► checking prerequisites
# ✔ Kubernetes 1.28.x >=1.26.0-0
# ✔ prerequisites checks passed
```

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

## Bootstrapping with GitHub

**Bootstrap** installs the Flux controllers into your cluster AND commits the Flux manifests to your Git repository. The cluster then manages itself from Git.

### Prerequisites

1. A GitHub repository (can be empty or existing).
2. A GitHub Personal Access Token (PAT) with `repo` scope.

### Create the PAT

```bash
# GitHub → Settings → Developer settings → Personal access tokens → Tokens (classic)
# Scopes required: repo (full control of private repositories)
export GITHUB_TOKEN=ghp_xxxxxxxxxxxxxxxxxxxx
export GITHUB_USER=my-github-username
```

### Bootstrap

```bash
flux bootstrap github \
  --owner=${GITHUB_USER} \
  # repo name (created if it doesn't exist)
  --repository=fleet-infra \
  --branch=main \
  # where Flux will commit its manifests
  --path=clusters/my-cluster \
  # use personal token (vs org token)
  --personal \
  # use HTTPS with token (vs SSH deploy key)
  --token-auth
```

> **SSH alternative:** Omit `--token-auth` and Flux will generate an SSH deploy key and print the public key. Add it to the repository's deploy keys in GitHub settings.

### What bootstrap does

1. Creates the GitHub repository if it does not exist.
2. Installs Flux CRDs and controllers in the `flux-system` namespace.
3. Generates a `GitRepository` pointing at your repo.
4. Generates a `Kustomization` applying the `clusters/my-cluster/` path.
5. Commits all generated manifests to `clusters/my-cluster/flux-system/`.
6. Pushes to GitHub.
7. The cluster immediately reconciles — Flux is now self-managing.

### Verify bootstrap

```bash
# All Flux pods should be Running
kubectl get pods -n flux-system

# Check the GitRepository source
flux get sources git

# Check the Kustomization
flux get kustomizations
```

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

## Bootstrapping with GitLab

```bash
export GITLAB_TOKEN=glpat-xxxxxxxxxxxxxxxxxxxx

flux bootstrap gitlab \
  --owner=my-gitlab-group \
  --repository=fleet-infra \
  --branch=main \
  --path=clusters/my-cluster \
  --token-auth
```

For self-hosted GitLab:

```bash
flux bootstrap gitlab \
  # self-hosted GitLab URL
  --hostname=gitlab.example.com \
  --owner=my-group \
  --repository=fleet-infra \
  --branch=main \
  --path=clusters/my-cluster \
  --token-auth \
  --ca-file=/path/to/ca.crt             # if using custom TLS CA
```

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

## GitRepository and Kustomization Sources

Once bootstrapped, you add your own application sources by creating Flux objects in the `clusters/my-cluster/` directory.

### GitRepository

Tells source-controller where to fetch code from:

```yaml
apiVersion: source.toolkit.fluxcd.io/v1
kind: GitRepository
metadata:
  name: my-app
  namespace: flux-system
spec:
  interval: 1m          # poll Git every 1 minute
  url: https://github.com/my-org/my-app
  ref:
    branch: main
  # For private repos, reference a Secret:
  secretRef:
    name: my-app-git-credentials
```

The referenced Secret:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: my-app-git-credentials
  namespace: flux-system
type: Opaque
stringData:
  username: git
  password: ghp_xxxxxxxxxxxxxxxxxxxx   # GitHub PAT
```

### Kustomization

Tells kustomize-controller which path to apply from a source:

```yaml
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: my-app
  namespace: flux-system
spec:
  interval: 5m
  path: "./deploy/production"          # path within the GitRepository
  prune: true                          # delete resources removed from Git
  sourceRef:
    kind: GitRepository
    name: my-app
  targetNamespace: production          # deploy into this namespace
  healthChecks:
    - apiVersion: apps/v1
      kind: Deployment
      name: my-app
      namespace: production
  timeout: 2m
```

### HelmRepository + HelmRelease

For deploying Helm charts from a chart repository:

```yaml
---
apiVersion: source.toolkit.fluxcd.io/v1
kind: HelmRepository
metadata:
  name: nginx-stable
  namespace: flux-system
spec:
  interval: 1h
  url: https://helm.nginx.com/stable

---
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: nginx
  namespace: default
spec:
  interval: 5m
  chart:
    spec:
      chart: nginx-ingress
      version: ">=0.18.0 <1.0.0"
      sourceRef:
        kind: HelmRepository
        name: nginx-stable
        namespace: flux-system
  values:
    controller:
      replicaCount: 2
```

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

## Watching for Changes

### Polling (default)

By default Flux polls the Git repository every `interval` (e.g., `1m`). This works everywhere but adds latency.

### Webhook-triggered reconciliation (recommended)

For instant reconciliation on push:

1. Create a Receiver in the cluster:

```yaml
apiVersion: notification.toolkit.fluxcd.io/v1
kind: Receiver
metadata:
  name: github-receiver
  namespace: flux-system
spec:
  type: github
  events:
    - "ping"
    - "push"
  secretRef:
    name: webhook-token
  resources:
    - apiVersion: source.toolkit.fluxcd.io/v1
      kind: GitRepository
      name: fleet-infra
---
apiVersion: v1
kind: Secret
metadata:
  name: webhook-token
  namespace: flux-system
type: Opaque
stringData:
  token: "a-random-secret-token"
```

2. Get the webhook URL:

```bash
kubectl get receiver -n flux-system github-receiver \
  -o jsonpath='{.status.webhookPath}'
# /hook/sha256:<hash>
```

3. Add the webhook in GitHub:
   - Repository → Settings → Webhooks → Add webhook
   - Payload URL: `https://flux.example.com/hook/sha256:<hash>`
   - Content type: `application/json`
   - Secret: your token value
   - Events: Just the push event

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

## Useful Flux CLI Commands

### Viewing status

```bash
# List all GitRepository sources and their status
flux get sources git

# List all HelmRepository sources
flux get sources helm

# List all Kustomizations
flux get kustomizations

# List all HelmReleases
flux get helmreleases --all-namespaces

# Overall status (all Flux objects)
flux get all --all-namespaces
```

### Triggering reconciliation

```bash
# Reconcile a specific GitRepository (pull latest from Git now)
flux reconcile source git fleet-infra

# Reconcile a Kustomization
flux reconcile kustomization my-app

# Reconcile a HelmRelease
flux reconcile helmrelease nginx -n default
```

### Viewing logs

```bash
# Logs from all Flux controllers
flux logs --all-namespaces

# Logs from a specific controller
flux logs --kind=Kustomization --name=my-app

# Follow logs
flux logs -f --level=error
```

### Suspending and resuming

```bash
# Suspend reconciliation (useful during maintenance)
flux suspend kustomization my-app

# Resume
flux resume kustomization my-app

# Suspend all
flux suspend kustomization --all
```

### Debugging

```bash
# Show detailed status and events for a Kustomization
kubectl describe kustomization my-app -n flux-system

# Check conditions
flux get kustomization my-app -v

# Export the current inventory (what Flux thinks is deployed)
flux get all --all-namespaces -o yaml
```

### Uninstalling Flux

```bash
# Remove Flux controllers (keeps CRDs and resources)
flux uninstall --namespace=flux-system

# Remove CRDs too
flux uninstall --namespace=flux-system --crds
```

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

## Lab

```bash
# 1. Install the Flux CLI
curl -s https://fluxcd.io/install.sh | sudo bash
flux --version

# 2. Pre-flight check
flux check --pre

# 3. Set your GitHub credentials
export GITHUB_TOKEN=your-token-here
export GITHUB_USER=your-username

# 4. Bootstrap Flux into your k3s cluster
flux bootstrap github \
  --owner=${GITHUB_USER} \
  --repository=k3s-gitops-demo \
  --branch=main \
  --path=clusters/my-k3s \
  --personal \
  --token-auth

# 5. Verify Flux is running
kubectl get pods -n flux-system
flux get all

# 6. Apply the lab Kustomization from labs/flux-kustomization.yaml
#    (update the GitHub repo URL first)
kubectl apply -f labs/flux-kustomization.yaml

# 7. Watch reconciliation
flux get kustomizations --watch
```

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

*Licensed under [CC BY-NC-SA 4.0](../LICENSE.md) · © 2026 UncleJS*
