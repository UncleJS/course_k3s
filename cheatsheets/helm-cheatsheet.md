# Helm Cheatsheet

> Mastering k3s Course | [↑ Course Index](../README.md)

## Install Helm

```bash
# Script install (Linux/macOS)
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# Specific version
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | DESIRED_VERSION=v3.14.0 bash

# Binary download
wget https://get.helm.sh/helm-v3.14.0-linux-amd64.tar.gz
tar xzf helm-v3.14.0-linux-amd64.tar.gz
sudo mv linux-amd64/helm /usr/local/bin/helm

# Package managers
brew install helm           # macOS Homebrew
scoop install helm          # Windows Scoop
apt install helm            # Debian (after adding repo)

# Verify
helm version
```

## Repo Operations

| Command | Description |
|---------|-------------|
| `helm repo add <name> <url>` | Add a chart repository |
| `helm repo update` | Fetch latest chart info |
| `helm repo list` | List configured repos |
| `helm repo remove <name>` | Remove a repo |
| `helm repo index ./charts/` | Generate repo index |

```bash
# Common repos
helm repo add stable https://charts.helm.sh/stable
helm repo add bitnami https://charts.bitnami.com/bitnami
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo add cert-manager https://charts.jetstack.io
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add grafana https://grafana.github.io/helm-charts
helm repo add longhorn https://charts.longhorn.io
helm repo add argo https://argoproj.github.io/argo-helm
helm repo add flux2 https://fluxcd-community.github.io/helm-charts
```

## Search

| Command | Description |
|---------|-------------|
| `helm search repo <keyword>` | Search configured repos |
| `helm search hub <keyword>` | Search Artifact Hub |
| `helm search repo nginx --versions` | List all available versions |
| `helm show chart <repo>/<chart>` | Show chart metadata |
| `helm show values <repo>/<chart>` | Show default values |
| `helm show readme <repo>/<chart>` | Show README |
| `helm show all <repo>/<chart>` | Show everything |

## Install

```bash
# Basic install
helm install <release> <chart>
helm install my-nginx bitnami/nginx

# Install in namespace (creates ns if it doesn't exist)
helm install my-nginx bitnami/nginx -n ingress --create-namespace

# Install specific version
helm install my-nginx bitnami/nginx --version 15.3.0

# Install with values file
helm install my-nginx bitnami/nginx -f values.yaml

# Install with --set overrides
helm install my-nginx bitnami/nginx \
  --set replicaCount=2 \
  --set service.type=ClusterIP

# Install from local directory
helm install my-app ./my-chart/

# Dry run (server-side validation)
helm install my-nginx bitnami/nginx --dry-run --debug

# Wait until all pods are ready
helm install my-nginx bitnami/nginx --wait --timeout=5m

# Atomic (rollback on failure)
helm install my-nginx bitnami/nginx --atomic --timeout=5m
```

## Upgrade

```bash
# Basic upgrade
helm upgrade <release> <chart>
helm upgrade my-nginx bitnami/nginx

# Upgrade or install (upsert)
helm upgrade --install my-nginx bitnami/nginx

# Upgrade with values file
helm upgrade my-nginx bitnami/nginx -f values.yaml

# Upgrade with specific version
helm upgrade my-nginx bitnami/nginx --version 15.4.0

# Reuse existing values + override
helm upgrade my-nginx bitnami/nginx --reuse-values --set replicaCount=3

# Force resource replacement
helm upgrade my-nginx bitnami/nginx --force

# Cleanup failed upgrade resources
helm upgrade my-nginx bitnami/nginx --cleanup-on-fail
```

## Rollback

```bash
# Rollback to previous revision
helm rollback <release>
helm rollback my-nginx

# Rollback to specific revision
helm rollback my-nginx 3

# Rollback with wait
helm rollback my-nginx --wait

# View history before rollback
helm history my-nginx
```

## Uninstall

```bash
# Uninstall release (removes all resources)
helm uninstall <release>
helm uninstall my-nginx

# Keep history for rollback
helm uninstall my-nginx --keep-history

# Uninstall from specific namespace
helm uninstall my-nginx -n ingress
```

## Inspect Release

| Command | Description |
|---------|-------------|
| `helm list` | List releases in current namespace |
| `helm list -A` | List all releases across namespaces |
| `helm list --failed` | List failed releases |
| `helm status <release>` | Release status and info |
| `helm get values <release>` | Values used in release |
| `helm get values <release> --all` | All values (including defaults) |
| `helm get manifest <release>` | Rendered Kubernetes manifests |
| `helm get hooks <release>` | Release hooks |
| `helm get notes <release>` | Post-install notes |
| `helm history <release>` | Revision history |

## Template / Lint / Package

```bash
# Render templates locally (no cluster needed)
helm template my-release ./my-chart/
helm template my-release ./my-chart/ -f values.yaml
helm template my-release ./my-chart/ --set key=val

# Render specific template file
helm template my-release ./my-chart/ -s templates/deployment.yaml

# Lint chart for issues
helm lint ./my-chart/
helm lint ./my-chart/ -f values.yaml --strict

# Package chart into .tgz
helm package ./my-chart/
helm package ./my-chart/ --version 1.2.3 --app-version 2.0.0

# Create new chart scaffold
helm create my-chart
```

## OCI Registries

```bash
# Login to OCI registry
helm registry login registry.example.com -u user -p password

# Pull chart from OCI
helm pull oci://registry.example.com/charts/my-chart --version 1.0.0

# Push chart to OCI
helm push my-chart-1.0.0.tgz oci://registry.example.com/charts

# Install from OCI directly
helm install my-release oci://registry.example.com/charts/my-chart --version 1.0.0

# Show chart info from OCI
helm show chart oci://registry.example.com/charts/my-chart --version 1.0.0

# Logout
helm registry logout registry.example.com
```

## --set Syntax Examples

| Syntax | YAML Equivalent |
|--------|----------------|
| `--set key=val` | `key: val` |
| `--set a.b=val` | `a: {b: val}` |
| `--set arr[0]=a` | `arr: [a]` |
| `--set arr[0]=a,arr[1]=b` | `arr: [a, b]` |
| `--set "key=v1\,v2"` | `key: "v1,v2"` |
| `--set key={a,b,c}` | `key: [a, b, c]` |
| `--set-string num=42` | Force string type |
| `--set-file key=./file.txt` | Read value from file |
| `--set-json key='{"a":1}'` | Parse as JSON |

## Useful Flags Reference

| Flag | Description |
|------|-------------|
| `--dry-run` | Simulate install/upgrade |
| `--debug` | Verbose output |
| `--wait` | Wait for pods to be ready |
| `--timeout <dur>` | Timeout for --wait (default 5m0s) |
| `--atomic` | Rollback on failure + implies --wait |
| `--cleanup-on-fail` | Delete new resources on upgrade failure |
| `--force` | Force resource updates (may cause downtime) |
| `--reset-values` | Use only new chart defaults on upgrade |
| `--reuse-values` | Reuse last release values on upgrade |
| `--render-subchart-notes` | Show subchart notes |
| `--no-hooks` | Skip chart hooks |
| `--generate-name` | Auto-generate release name |
| `-n, --namespace` | Target namespace |
| `--create-namespace` | Create namespace if not present |
| `--kube-context` | Use specific kubeconfig context |

## HelmChart CRD (k3s Built-in)

k3s includes a `HelmChart` CRD that auto-deploys Helm charts via manifests in `/var/lib/rancher/k3s/server/manifests/`.

```yaml
# /var/lib/rancher/k3s/server/manifests/cert-manager.yaml
apiVersion: helm.cattle.io/v1
kind: HelmChart
metadata:
  name: cert-manager
  namespace: kube-system
spec:
  repo: https://charts.jetstack.io
  chart: cert-manager
  version: v1.14.0
  targetNamespace: cert-manager
  createNamespace: true
  valuesContent: |-
    installCRDs: true
    replicaCount: 1
```

```yaml
# HelmChartConfig — override values separately
apiVersion: helm.cattle.io/v1
kind: HelmChartConfig
metadata:
  name: cert-manager
  namespace: kube-system
spec:
  valuesContent: |-
    replicaCount: 2
    resources:
      limits:
        memory: 256Mi
```

| Field | Description |
|-------|-------------|
| `spec.repo` | Helm repo URL |
| `spec.chart` | Chart name |
| `spec.version` | Chart version |
| `spec.targetNamespace` | Deployment namespace |
| `spec.createNamespace` | Create namespace if missing |
| `spec.valuesContent` | Inline YAML values |
| `spec.set` | Key/value overrides map |
| `spec.jobImage` | Image for helm job pod |
| `spec.helmVersion` | `v3` (default) |
| `spec.authSecret` | Secret for private repos |

---
*Licensed under [CC BY-NC-SA 4.0](../LICENSE.md) · © 2026 UncleJS*
