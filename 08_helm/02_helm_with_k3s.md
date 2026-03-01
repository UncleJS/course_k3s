# Helm with k3s
> Module 08 · Lesson 02 | [↑ Course Index](../README.md)

## Table of Contents
- [Overview](#overview)
- [k3s Built-in Helm Controller](#k3s-built-in-helm-controller)
- [HelmChart CRD](#helmchart-crd)
- [HelmChartConfig CRD](#helmchartconfig-crd)
- [Auto-deploy Manifests from /server/manifests](#auto-deploy-manifests-from-servermanifests)
- [Helm vs HelmChart CRD: When to Use Each](#helm-vs-helmchart-crd-when-to-use-each)
- [Deploying Applications with Helm in k3s](#deploying-applications-with-helm-in-k3s)
- [Private Chart Repositories](#private-chart-repositories)
- [OCI Chart Registries](#oci-chart-registries)
- [Helm and GitOps](#helm-and-gitops)
- [Lab](#lab)

---

## Overview

k3s ships with a built-in **Helm Controller** that watches for `HelmChart` Custom Resources and automatically installs/upgrades the referenced charts. This is how k3s itself deploys Traefik and other built-in components. This lesson explains how to use both the native Helm CLI and the k3s HelmChart CRD for managing applications.

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

## k3s Built-in Helm Controller

k3s bundles a Helm controller that:
- Watches `HelmChart` and `HelmChartConfig` CRDs
- Automatically installs/upgrades charts when these resources change
- Stores Helm release state as Kubernetes secrets (like standard Helm)
- Runs as a pod in `kube-system`

```bash
# View the Helm controller
kubectl get pods -n kube-system | grep helm

# View all HelmChart resources (k3s-managed charts)
kubectl get helmchart -n kube-system
# NAME               JOB-NAME            CHART                  TARGETNAMESPACE   VERSION
# traefik            helm-install-...    https://...            kube-system       *
# traefik-crd        helm-install-...    https://...            kube-system       *

# View jobs created by the controller
kubectl get jobs -n kube-system | grep helm-install
```

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

## HelmChart CRD

Create a `HelmChart` resource to have k3s automatically install and manage a Helm chart:

```yaml
apiVersion: helm.cattle.io/v1
kind: HelmChart
metadata:
  name: my-nginx
  namespace: kube-system    # Must be kube-system (controller watches here)
spec:
  repo: https://charts.bitnami.com/bitnami
  chart: nginx
  version: "15.3.5"         # Omit for latest
  targetNamespace: web       # Where to install the release
  createNamespace: true
  valuesContent: |-
    replicaCount: 2
    service:
      type: NodePort
```

```bash
# The controller will create a Job that runs helm install
kubectl get jobs -n kube-system -w

# Once done, check the release
kubectl get all -n web
```

> To deploy at k3s startup, place the YAML in `/var/lib/rancher/k3s/server/manifests/`. k3s applies all files in this directory at boot.

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

## HelmChartConfig CRD

`HelmChartConfig` customises an existing `HelmChart` without replacing it. This is how you customise Traefik (a built-in chart) without modifying k3s internals.

```yaml
# Customise the built-in Traefik chart
apiVersion: helm.cattle.io/v1
kind: HelmChartConfig
metadata:
  name: traefik         # Must match HelmChart name
  namespace: kube-system
spec:
  valuesContent: |-
    logs:
      access:
        enabled: true
    ports:
      web:
        redirectTo:
          port: websecure
    resources:
      requests:
        cpu: 100m
        memory: 50Mi
```

The controller merges `HelmChartConfig.valuesContent` with `HelmChart.valuesContent` and re-runs `helm upgrade`.

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

## Auto-deploy Manifests from /server/manifests

k3s watches `/var/lib/rancher/k3s/server/manifests/` and auto-applies any YAML file placed there. This works for both plain manifests and `HelmChart` resources:

```bash
# Drop a HelmChart definition here
sudo tee /var/lib/rancher/k3s/server/manifests/my-app.yaml <<'EOF'
apiVersion: helm.cattle.io/v1
kind: HelmChart
metadata:
  name: my-app
  namespace: kube-system
spec:
  repo: https://charts.bitnami.com/bitnami
  chart: wordpress
  targetNamespace: apps
  createNamespace: true
  valuesContent: |-
    wordpressUsername: admin
    service:
      type: NodePort
EOF
```

k3s will detect the new file and apply it within seconds. Changes to the file trigger an upgrade. Deleting the file does **not** automatically uninstall the release (you must do `helm uninstall` manually).

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

## Helm vs HelmChart CRD: When to Use Each

| Scenario | Use |
|----------|-----|
| Interactive installs during development | `helm install` CLI |
| Scripted CI/CD pipelines | `helm upgrade --install` CLI |
| Declarative GitOps (store state in Git) | `HelmChart` CRD |
| Customising built-in k3s components | `HelmChartConfig` CRD |
| Bootstrapping applications at cluster startup | `/server/manifests/` + `HelmChart` CRD |
| Complex multi-chart deployments | Flux / ArgoCD (Module 11) |

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

## Deploying Applications with Helm in k3s

A complete example deploying the Prometheus stack:

```bash
# Step 1: Add repo
helm repo add prometheus https://prometheus-community.github.io/helm-charts
helm repo update

# Step 2: Create namespace
kubectl create namespace monitoring

# Step 3: Review default values
helm show values prometheus/kube-prometheus-stack | less

# Step 4: Install with custom values
helm install prometheus prometheus/kube-prometheus-stack \
  --namespace monitoring \
  --values labs/values-override.yaml \
  --set grafana.adminPassword=admin123 \
  --wait   # wait until all pods are Ready

# Step 5: Verify
helm status prometheus -n monitoring
kubectl get pods -n monitoring
```

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

## Private Chart Repositories

```bash
# HTTP basic auth
helm repo add myrepo https://charts.company.com \
  --username admin \
  --password secret

# TLS client certificate
helm repo add myrepo https://charts.company.com \
  --cert-file ./client.crt \
  --key-file  ./client.key \
  --ca-file   ./ca.crt

# Using environment variables (for CI/CD)
HELM_REPO_USERNAME=admin HELM_REPO_PASSWORD=secret \
  helm install myapp myrepo/myapp
```

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

## OCI Chart Registries

Helm 3.8+ supports OCI registries (like Docker Hub, GHCR, ECR):

```bash
# Login to an OCI registry
helm registry login ghcr.io \
  --username <github-user> \
  --password <github-token>

# Pull from OCI (no repo add needed)
helm install my-release oci://ghcr.io/myorg/charts/myapp --version 1.2.3

# Push your chart to OCI
helm package ./mychart
helm push mychart-1.0.0.tgz oci://ghcr.io/myorg/charts

# Using HelmChart CRD with OCI
apiVersion: helm.cattle.io/v1
kind: HelmChart
metadata:
  name: myapp
  namespace: kube-system
spec:
  chart: oci://ghcr.io/myorg/charts/myapp
  version: "1.2.3"
  targetNamespace: apps
```

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

## Helm and GitOps

In a GitOps workflow, `HelmRelease` resources (from Flux) or `Application` resources (from ArgoCD) manage Helm charts declaratively. See Module 11 for full GitOps coverage.

```yaml
# Flux HelmRelease example (preview — covered in Module 11)
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: my-app
spec:
  interval: 5m
  chart:
    spec:
      chart: nginx
      version: ">=15.0.0"
      sourceRef:
        kind: HelmRepository
        name: bitnami
  values:
    replicaCount: 3
```

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

## Lab

```bash
# Try the HelmChart CRD approach (k3s-native)
sudo tee /var/lib/rancher/k3s/server/manifests/helm-demo.yaml <<'EOF'
apiVersion: helm.cattle.io/v1
kind: HelmChart
metadata:
  name: helm-demo-nginx
  namespace: kube-system
spec:
  repo: https://charts.bitnami.com/bitnami
  chart: nginx
  version: "15.3.5"
  targetNamespace: helm-demo
  createNamespace: true
  valuesContent: |-
    replicaCount: 1
    service:
      type: NodePort
EOF

# Watch the Helm install Job
kubectl get jobs -n kube-system -w

# Check the release
kubectl get all -n helm-demo

# Modify values — controller auto-upgrades
sudo sed -i 's/replicaCount: 1/replicaCount: 2/' \
  /var/lib/rancher/k3s/server/manifests/helm-demo.yaml

# Clean up
sudo rm /var/lib/rancher/k3s/server/manifests/helm-demo.yaml
helm uninstall helm-demo-nginx -n helm-demo
```

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---
*Licensed under [CC BY-NC-SA 4.0](../LICENSE.md) · © 2026 UncleJS*
