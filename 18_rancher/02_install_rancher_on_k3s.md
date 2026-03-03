# Install Rancher on k3s (Helm)
> Module 18 · Lesson 02 | [↑ Course Index](../README.md)

## Table of Contents
- [Prerequisites](#prerequisites)
- [Choose a Hostname and TLS Strategy](#choose-a-hostname-and-tls-strategy)
- [Install cert-manager (If Needed)](#install-cert-manager-if-needed)
- [Install Rancher with Helm](#install-rancher-with-helm)
- [Verify the Installation](#verify-the-installation)
- [Uninstall](#uninstall)
- [Common Issues](#common-issues)

---

## Prerequisites

- A working k3s cluster and `kubectl` access (Module 02)
- Ingress controller available (k3s includes Traefik by default; Module 07)
- Helm installed (Module 08)
- DNS name (or a local development hostname pattern)

Recommended: install Rancher on a dedicated management cluster (separate from production workloads).

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

## Choose a Hostname and TLS Strategy

Rancher requires HTTPS.

Common options:
- `ingress.tls.source=rancher` (default): Rancher-generated certs via cert-manager
- `ingress.tls.source=letsEncrypt`: public certs via cert-manager + ACME
- `ingress.tls.source=secret`: bring your own cert in a Kubernetes Secret

For local testing without public DNS, a convenient pattern is `rancher.<node-ip>.sslip.io`.

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

## Install cert-manager (If Needed)

If you use `ingress.tls.source=rancher` or `ingress.tls.source=letsEncrypt`, you need cert-manager.

Follow: `07_ingress_and_tls/03_cert_manager_lets_encrypt.md`

Quick verify:

```bash
kubectl get pods -n cert-manager
```

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

## Install Rancher with Helm

1) Add the Rancher Helm repo and update:

```bash
helm repo add rancher-stable https://releases.rancher.com/server-charts/stable
helm repo update
```

2) Create the Rancher namespace:

```bash
kubectl create namespace cattle-system
```

3) Install using a values file (recommended):

```bash
helm upgrade --install rancher rancher-stable/rancher \
  --namespace cattle-system \
  --values 18_rancher/labs/rancher-values.yaml
```

Notes:
- `hostname` must resolve to your ingress entrypoint.
- `bootstrapPassword` is only for first login; change it after.
- For small clusters, consider `replicas: 1`.

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

## Verify the Installation

Wait for rollout:

```bash
kubectl -n cattle-system rollout status deploy/rancher
kubectl -n cattle-system get pods
```

Check ingress:

```bash
kubectl -n cattle-system get ingress
```

Then browse to `https://<hostname>` and log in as `admin` with your bootstrap password.

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

## Uninstall

```bash
helm -n cattle-system uninstall rancher
kubectl delete namespace cattle-system
```

If you installed cert-manager only for Rancher and no longer need it, remove it separately (Module 07).

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

## Common Issues

- **Ingress not reachable**: confirm Traefik is running in `kube-system` and DNS points to the right node/LB.
- **Certificate pending**: check `cert-manager` pods and `Certificate`/`Challenge` objects.
- **PodSecurity issues**: ensure the management cluster policy allows Rancher workloads.
- **Strict agent TLS + private CA**: if using a private CA, set `privateCA: true` and ensure agents trust the CA.

---

*Licensed under [CC BY-NC-SA 4.0](../LICENSE.md) · © 2026 UncleJS*
