# GitOps Cheatsheet

> Mastering k3s Course | [↑ Course Index](../README.md)


[![Course Index](https://img.shields.io/badge/Course-Index-0f766e)](../README.md)
[![License: CC BY-NC-SA 4.0](https://img.shields.io/badge/License-CC%20BY--NC--SA%204.0-lightgrey)](../LICENSE.md)

## Table of Contents

- [Flux CLI](#flux-cli)
- [Flux YAML Snippets](#flux-yaml-snippets)
- [ArgoCD CLI](#argocd-cli)
- [ArgoCD YAML Snippets](#argocd-yaml-snippets)
- [GitOps Repo Structure](#gitops-repo-structure)

---

## Flux CLI

### Install Flux CLI

```bash
# Script install
curl -s https://fluxcd.io/install.sh | sudo bash

# Homebrew
brew install fluxcd/tap/flux

# Binary download
wget https://github.com/fluxcd/flux2/releases/download/v2.3.0/flux_2.3.0_linux_amd64.tar.gz
tar xzf flux_*.tar.gz && sudo mv flux /usr/local/bin/

# Verify
flux version

# Check cluster prerequisites
flux check --pre
```

### Bootstrap

```bash
# Bootstrap with GitHub
flux bootstrap github \
  --owner=my-org \
  --repository=fleet-infra \
  --branch=main \
  --path=clusters/production \
  --personal

# Bootstrap with GitLab
flux bootstrap gitlab \
  --owner=my-group \
  --repository=fleet-infra \
  --branch=main \
  --path=clusters/production \
  --token-auth

# Bootstrap with generic Git
flux bootstrap git \
  --url=ssh://git@git.example.com/org/fleet-infra.git \
  --branch=main \
  --path=clusters/production \
  --private-key-file=./id_ed25519

# Bootstrap existing repo (idempotent)
flux bootstrap github \
  --owner=my-org \
  --repository=fleet-infra \
  --path=clusters/production \
  --personal \
  --components-extra=image-reflector-controller,image-automation-controller
```

### Get Resources

| Command | Description |
|---------|-------------|
| `flux get all` | All Flux resources |
| `flux get sources all` | All sources |
| `flux get sources git` | GitRepository sources |
| `flux get sources helm` | HelmRepository sources |
| `flux get sources oci` | OCI sources |
| `flux get kustomizations` | Kustomizations (ks) |
| `flux get helmreleases` | HelmReleases (hr) |
| `flux get helmreleases -A` | HelmReleases all namespaces |
| `flux get images all` | Image reflectors/automations |
| `flux get receivers` | Webhook receivers |
| `flux get alerts` | Alert configurations |
| `flux get providers` | Notification providers |

### Reconcile

```bash
# Reconcile all sources
flux reconcile source git flux-system

# Reconcile specific kustomization
flux reconcile kustomization flux-system
flux reconcile ks <name>

# Reconcile HelmRelease
flux reconcile helmrelease <name>
flux reconcile hr <name> -n <namespace>

# Force reconcile (ignore git interval)
flux reconcile source git flux-system --with-source

# Reconcile and wait
flux reconcile ks <name> --with-source
```

### Suspend / Resume

```bash
# Suspend (pause reconciliation)
flux suspend kustomization <name>
flux suspend ks <name>
flux suspend helmrelease <name>
flux suspend hr <name> -n <namespace>
flux suspend source git <name>

# Resume
flux resume kustomization <name>
flux resume ks <name>
flux resume helmrelease <name>
flux resume hr <name> -n <namespace>
flux resume source git <name>
```

### Logs

```bash
# Flux controller logs
flux logs
flux logs --all-namespaces
flux logs --level=error
flux logs -f                        # Follow
flux logs --kind=HelmRelease
flux logs --kind=Kustomization

# Specific controller
flux logs --tail=50 --kind=HelmRelease --name=<name>

# Get events
kubectl get events -n flux-system --sort-by=.lastTimestamp
```

### Diagnostics

```bash
# Check flux components
flux check

# Describe resources
flux describe kustomization <name>
flux describe helmrelease <name>
flux describe source git <name>

# Export all flux resources
flux export source git --all > sources.yaml
flux export kustomization --all > kustomizations.yaml
flux export helmrelease --all -A > helmreleases.yaml

# Trace reconciliation
flux trace kustomization <name>

# Uninstall Flux (keep CRDs and namespace by default)
flux uninstall
flux uninstall --namespace=flux-system --keep-namespace=false
```

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

## Flux YAML Snippets

### GitRepository

```yaml
apiVersion: source.toolkit.fluxcd.io/v1
kind: GitRepository
metadata:
  name: my-app
  namespace: flux-system
spec:
  interval: 1m
  url: https://github.com/my-org/my-app
  ref:
    branch: main
  secretRef:           # optional, for private repos
    name: git-credentials
---
# Secret for HTTPS auth
apiVersion: v1
kind: Secret
metadata:
  name: git-credentials
  namespace: flux-system
type: Opaque
stringData:
  username: git
  password: ghp_xxxxxxxxxxxx
```

### Kustomization

```yaml
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: my-app
  namespace: flux-system
spec:
  interval: 5m
  timeout: 2m
  sourceRef:
    kind: GitRepository
    name: my-app
  path: ./kubernetes/overlays/production
  prune: true                     # delete removed resources
  wait: true                      # wait for resources to be ready
  force: false                    # force apply (recreate on conflict)
  postBuild:
    substituteFrom:
      - kind: ConfigMap
        name: cluster-vars
      - kind: Secret
        name: cluster-secrets
  healthChecks:
    - apiVersion: apps/v1
      kind: Deployment
      name: my-app
      namespace: production
```

### HelmRelease

```yaml
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: my-app
  namespace: production
spec:
  interval: 10m
  chart:
    spec:
      chart: my-app
      version: ">=1.0.0 <2.0.0"
      sourceRef:
        kind: HelmRepository
        name: my-charts
        namespace: flux-system
      interval: 1m
  install:
    remediation:
      retries: 3
  upgrade:
    remediation:
      retries: 3
      remediateLastFailure: true
    cleanupOnFail: true
  rollback:
    timeout: 5m
    cleanupOnFail: true
  values:
    replicaCount: 2
    image:
      tag: "1.2.3"
  valuesFrom:
    - kind: Secret
      name: my-app-secrets
      valuesKey: values.yaml
```

### HelmRepository Source

```yaml
apiVersion: source.toolkit.fluxcd.io/v1
kind: HelmRepository
metadata:
  name: bitnami
  namespace: flux-system
spec:
  interval: 1h
  url: https://charts.bitnami.com/bitnami
---
# OCI HelmRepository
apiVersion: source.toolkit.fluxcd.io/v1beta2
kind: HelmRepository
metadata:
  name: my-oci-charts
  namespace: flux-system
spec:
  interval: 1h
  type: oci
  url: oci://registry.example.com/charts
  secretRef:
    name: oci-credentials
```

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

## ArgoCD CLI

### Install

```bash
# Linux
curl -sSL -o argocd https://github.com/argoproj/argo-cd/releases/latest/download/argocd-linux-amd64
chmod +x argocd && sudo mv argocd /usr/local/bin/

# macOS
brew install argocd

# Install ArgoCD to cluster
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# Get initial admin password
kubectl get secret argocd-initial-admin-secret -n argocd \
  -o jsonpath='{.data.password}' | base64 -d

# Login
argocd login localhost:8080 --username admin --password <password> --insecure
# or
kubectl port-forward svc/argocd-server 8080:443 -n argocd &
argocd login localhost:8080 --username admin --insecure
```

### App Management

| Command | Description |
|---------|-------------|
| `argocd app list` | List all apps |
| `argocd app get <name>` | App details and health |
| `argocd app create ...` | Create application |
| `argocd app sync <name>` | Sync (deploy) app |
| `argocd app diff <name>` | Show diff vs live state |
| `argocd app history <name>` | Revision history |
| `argocd app rollback <name> <id>` | Rollback to revision |
| `argocd app delete <name>` | Delete app |
| `argocd app set <name> ...` | Update app settings |
| `argocd app logs <name>` | App pod logs |

```bash
# Create app (CLI)
argocd app create my-app \
  --repo https://github.com/my-org/my-app.git \
  --path kubernetes/overlays/production \
  --dest-server https://kubernetes.default.svc \
  --dest-namespace production \
  --sync-policy automated \
  --auto-prune \
  --self-heal

# Create Helm app
argocd app create nginx \
  --repo https://charts.bitnami.com/bitnami \
  --helm-chart nginx \
  --revision 15.0.0 \
  --dest-server https://kubernetes.default.svc \
  --dest-namespace ingress \
  --helm-set replicaCount=2

# Sync with force (replace conflicts)
argocd app sync <name> --force

# Sync specific resources
argocd app sync <name> --resource apps:Deployment:my-app

# Hard refresh (ignore cache)
argocd app get <name> --hard-refresh

# Terminate running sync
argocd app terminate-op <name>
```

### Server & Cluster Management

```bash
# List clusters
argocd cluster list

# Add cluster
argocd cluster add <context-name>

# Remove cluster
argocd cluster rm <server-url>

# List repos
argocd repo list

# Add repo
argocd repo add https://github.com/my-org/my-app.git \
  --username git --password <token>

# Add private Helm repo
argocd repo add https://charts.example.com \
  --type helm --name my-charts \
  --username user --password pass

# Change admin password
argocd account update-password \
  --current-password <old> \
  --new-password <new>
```

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

## ArgoCD YAML Snippets

### Application

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: my-app
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io   # cascading delete
spec:
  project: default
  source:
    repoURL: https://github.com/my-org/my-app.git
    targetRevision: main
    path: kubernetes/overlays/production
  destination:
    server: https://kubernetes.default.svc
    namespace: production
  syncPolicy:
    automated:
      prune: true        # delete removed resources
      selfHeal: true     # revert manual changes
      allowEmpty: false
    syncOptions:
      - CreateNamespace=true
      - PrunePropagationPolicy=foreground
      - ApplyOutOfSyncOnly=true
    retry:
      limit: 5
      backoff:
        duration: 5s
        factor: 2
        maxDuration: 3m
```

### Helm Application

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: cert-manager
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://charts.jetstack.io
    chart: cert-manager
    targetRevision: v1.14.0
    helm:
      values: |
        installCRDs: true
        replicaCount: 2
      parameters:
        - name: global.logLevel
          value: "2"
  destination:
    server: https://kubernetes.default.svc
    namespace: cert-manager
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

### AppProject

```yaml
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: production
  namespace: argocd
spec:
  description: Production workloads
  sourceRepos:
    - 'https://github.com/my-org/*'
    - 'https://charts.bitnami.com/bitnami'
  destinations:
    - namespace: 'production'
      server: https://kubernetes.default.svc
    - namespace: 'kube-system'
      server: https://kubernetes.default.svc
  clusterResourceWhitelist:
    - group: ''
      kind: Namespace
  namespaceResourceBlacklist:
    - group: ''
      kind: ResourceQuota
  roles:
    - name: read-only
      description: Read-only access
      policies:
        - p, proj:production:read-only, applications, get, production/*, allow
      groups:
        - developers
```

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

## GitOps Repo Structure

```
fleet-infra/
├── clusters/
│   ├── production/
│   │   ├── flux-system/          # Flux bootstrap manifests
│   │   │   ├── gotk-components.yaml
│   │   │   ├── gotk-sync.yaml
│   │   │   └── kustomization.yaml
│   │   ├── apps.yaml             # Kustomization for apps
│   │   └── infrastructure.yaml  # Kustomization for infra
│   └── staging/
│       └── ...
├── apps/
│   ├── base/
│   │   └── my-app/
│   │       ├── deployment.yaml
│   │       ├── service.yaml
│   │       └── kustomization.yaml
│   ├── production/
│   │   └── my-app/
│   │       ├── kustomization.yaml  # extends base
│   │       └── patch-replicas.yaml
│   └── staging/
│       └── my-app/
│           └── kustomization.yaml
└── infrastructure/
    ├── base/
    │   ├── cert-manager/
    │   │   ├── helmrelease.yaml
    │   │   └── kustomization.yaml
    │   └── ingress-nginx/
    │       └── ...
    └── production/
        └── kustomization.yaml
```

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---
*Licensed under [CC BY-NC-SA 4.0](../LICENSE.md) · © 2026 UncleJS*
