# Install Rancher on k3s (Helm)
> Module 18 · Lesson 02 | [↑ Course Index](../README.md)


[![Course Index](https://img.shields.io/badge/Course-Index-0f766e)](../README.md)
[![License: CC BY-NC-SA 4.0](https://img.shields.io/badge/License-CC%20BY--NC--SA%204.0-lightgrey)](../LICENSE.md)

## Table of Contents
- [Prerequisites](#prerequisites)
- [Choose a Hostname and TLS Strategy](#choose-a-hostname-and-tls-strategy)
- [Install cert-manager (If Needed)](#install-cert-manager-if-needed)
- [Install Rancher with Helm](#install-rancher-with-helm)
- [Verify the Installation](#verify-the-installation)
- [Lab Scripts](#lab-scripts)
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

> **Tip:** use the [uninstall-rancher.sh](labs/uninstall-rancher.sh) lab script for a guided teardown that also cleans up lingering namespaces and CRDs. See the [Lab Scripts](#lab-scripts) section below.

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

## Lab Scripts

Both scripts live in `18_rancher/labs/` and are executable (`chmod +x` is already set). Every mutating step in both scripts is wrapped in a `run()` helper, meaning `--dry-run` causes the full command to be printed but never executed — making it safe to rehearse on any live cluster.

---

### `install-rancher.sh`

A single script that drives the entire install flow from preflight through to a printed post-install summary, with no manual steps required for a standard lab setup.

#### Preflight checks

The script runs seven checks before touching anything on the cluster. Hard failures exit immediately; warnings let the install continue.

| # | Check | Pass behaviour | Fail behaviour |
|---|---|---|---|
| 1 | Root / sudo | `✔ Root: OK` | Hard fail — `sudo` is required to read `/etc/rancher/k3s/k3s.yaml` |
| 2 | `k3s` systemd service active | `✔ k3s service: active` | Hard fail — prints pointer to `02_installation/labs/install.sh` |
| 3 | At least one Ready node | `✔ Ready nodes: N` | Hard fail — advises waiting for k3s to finish starting |
| 4 | `kubectl` binary on `$PATH` | `✔ kubectl: vX.Y.Z` | Hard fail — notes the symlink k3s creates at `/usr/local/bin/kubectl` |
| 5 | `helm` binary on `$PATH` | `✔ helm: vX.Y.Z` | Hard fail — prints the one-liner Helm install command |
| 6 | Traefik pods running in `kube-system` | `✔ Traefik ingress: N pod(s) running` | **Warning only** — install continues; pointer to Module 07 |
| 7 | `cattle-system` namespace exists | `✔ Namespace cattle-system: not present` | **Warning only** — signals a re-run; `helm upgrade --install` handles it idempotently |

For `--tls letsencrypt` only, an eighth check runs after the namespace check:

| # | Check | Pass behaviour | Fail behaviour |
|---|---|---|---|
| 8 | DNS A record resolves for `--hostname` | `✔ DNS: <host> resolves OK` | **Warning only** — uses `dig` if available, falls back to a `curl` probe; the ACME HTTP-01 challenge will fail at cert issuance time if DNS is wrong |

#### cert-manager handling

cert-manager is required for both `rancher` (self-signed) and `letsencrypt` TLS modes. The script detects the current state and reacts accordingly — no manual cert-manager install is needed for a clean cluster:

- **Already running** — reads the version from the pod label and prints it; the install step is skipped entirely, leaving your existing cert-manager untouched
- **Missing** — adds the `jetstack` Helm repo, creates the `cert-manager` namespace idempotently (via `--dry-run=client | kubectl apply`), installs cert-manager with `--set installCRDs=true`, then blocks until `kubectl rollout status deploy/cert-manager` reports success (2 min timeout) before continuing
- **`--tls secret`** — cert-manager is not needed for BYO certs; the entire step is skipped with an `[INFO]` message
- **`--skip-cert-manager`** — skips both detection and install; use this when cert-manager is managed by a separate process outside this script

#### Hostname auto-detection

If `--hostname` is not supplied, the script resolves the node's primary outbound IPv4 address using `ip -4 route get 1.1.1.1` (falling back to `hostname -I`) and constructs `rancher.<ip>.sslip.io`. The [sslip.io](https://sslip.io) service resolves any hostname of the form `<anything>.<ip>.sslip.io` back to that IP, so this pattern works with zero DNS configuration — ideal for local lab clusters.

#### Confirmation prompt

Before any Helm or `kubectl` commands run, the script prints a plan summary:

```
  Hostname  : rancher.192.168.1.10.sslip.io
  TLS       : rancher
  Replicas  : 1
  Namespace : cattle-system
  Version   : latest stable
```

You must type `YES` to continue. Pass `--force` to skip this in scripts or CI pipelines. `--dry-run` also skips the prompt since no changes will be made.

#### Helm install

Runs `helm upgrade --install rancher rancher-stable/rancher` — idempotent, so re-running on an existing install performs an in-place upgrade rather than failing with a "release already exists" error. All values are passed as `--set` flags; no temporary values file is written to disk. For `letsencrypt` mode, three additional flags are appended automatically: `letsEncrypt.email`, `letsEncrypt.environment=production`, and `letsEncrypt.ingress.class=traefik`.

#### Rollout wait

After Helm returns, the script waits up to 10 minutes on `kubectl -n cattle-system rollout status deploy/rancher --timeout=600s`. This is intentionally generous — on a fresh cluster the Rancher image (~1 GB) may take several minutes to pull. If the timeout is exceeded, a warning is printed with the exact commands to investigate:

```bash
kubectl -n cattle-system describe pods
kubectl -n cattle-system logs -l app=rancher --tail=50
```

#### Post-install summary

On success the script prints a box containing the Rancher URL, username (`admin`), and bootstrap password, followed by a live `kubectl get pods` and `kubectl get ingress` for `cattle-system`. If the default password `changeme` is still in use, a prominent yellow warning is shown reminding you to change it on first login.

#### Flag reference

| Flag | Default | Description |
|---|---|---|
| `--hostname <host>` | `rancher.<node-ip>.sslip.io` | Hostname for the Rancher ingress. Must resolve to this node for Let's Encrypt; sslip.io works out-of-the-box for local labs. |
| `--tls <rancher\|letsencrypt\|secret>` | `rancher` | TLS certificate source. `rancher` = self-signed cert managed by cert-manager (no public DNS required). `letsencrypt` = public ACME certificate via cert-manager HTTP-01 challenge (requires `--le-email` and public DNS). `secret` = bring your own cert stored in a Secret named `tls-rancher-ingress` in `cattle-system` — this Secret must exist before the script runs. |
| `--le-email <email>` | *(none)* | Email address registered with Let's Encrypt for expiry notifications. Mandatory when `--tls letsencrypt`; the script exits with a hard error if omitted. |
| `--bootstrap-password <pw>` | `changeme` | The password presented at the first-login screen at `https://<hostname>`. Rancher forces a password change after first use regardless, but setting a strong value here closes a brief window between pod start and first login. |
| `--replicas <n>` | `1` | Number of Rancher server pod replicas. Use `1` for lab clusters. For production HA, use `3` (requires a multi-node cluster with sufficient capacity). |
| `--rancher-version <version>` | *(latest stable)* | Pins the Helm chart version, e.g. `2.8.3`. Omit to always pull the latest stable release from the `rancher-stable` chart repository. Useful when you need to match a specific Rancher version to your k3s version for support. |
| `--cert-manager-version <ver>` | `v1.14.5` | cert-manager Helm chart version to use when the script auto-installs it. Only has effect when cert-manager is not already present and `--skip-cert-manager` is not set. |
| `--skip-cert-manager` | off | Completely bypasses the cert-manager detection and install step. Use when cert-manager is already installed by a different mechanism (e.g. as part of a platform bootstrap) or when you are managing it separately. |
| `--dry-run` | off | Prints every mutating command (Helm and kubectl) prefixed with `[DRY-RUN]` and does not execute any of them. Preflight checks and cert-manager detection still query the live cluster, so you get an accurate read of what would happen. **Always recommended as a first pass on a new cluster.** |
| `--force` | off | Skips the pre-install confirmation prompt. Safe for CI pipelines and automation; avoid on shared or production clusters where a mis-typed flag could cause an unintended upgrade. |

#### Usage examples

```bash
# 1. Quickstart — zero config, auto-detect hostname, self-signed cert
sudo ./install-rancher.sh

# 2. Dry-run first to review every command that will be executed
sudo ./install-rancher.sh --dry-run

# 3. Explicit hostname with self-signed cert
sudo ./install-rancher.sh --hostname rancher.192.168.1.10.sslip.io

# 4. Let's Encrypt with a real public domain
sudo ./install-rancher.sh \
  --tls letsencrypt \
  --hostname rancher.example.com \
  --le-email you@example.com

# 5. Bring-your-own cert (Secret tls-rancher-ingress must already exist in cattle-system)
sudo ./install-rancher.sh \
  --tls secret \
  --hostname rancher.example.com

# 6. Pin version, 3 replicas, strong password, skip confirmation
sudo ./install-rancher.sh \
  --rancher-version 2.8.3 \
  --replicas 3 \
  --bootstrap-password "MyStr0ngPw!" \
  --force
```

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

### `uninstall-rancher.sh`

Removes Rancher and all cluster resources created during the install. Every step is idempotent — if a resource is already gone (e.g. after a partial or failed install) the step logs a warning and continues rather than exiting.

#### Removal sequence

The script works through eight stages in order:

**1. Preflight** — verifies root, `kubectl` cluster reachability, and `helm` presence. All three are hard failures because the script cannot proceed without them.

**2. Confirmation** — prints a warning describing everything that will be deleted and requires you to type `YES`. Add `--force` to skip, or use `--dry-run` to inspect without being prompted at all.

**3. Helm release** — runs `helm -n cattle-system uninstall rancher`. If the release is not found (e.g. install never completed), a warning is logged and this step is skipped rather than failing.

**4. `cattle-system` namespace** — issues `kubectl delete namespace cattle-system`, then polls every 2 seconds (up to 60 s) waiting for the namespace to fully terminate. If it is still present after 60 s the script warns that finalizers may be stuck and prints the diagnostic command:

```bash
kubectl get namespace cattle-system -o yaml
```

Stuck finalizers most commonly appear when Rancher agents are still connected to downstream clusters. Removing the downstream clusters from Rancher's UI first prevents this.

**5. Lingering Rancher namespaces** — scans the cluster for namespaces matching `cattle-*`, `fleet-*`, `rancher-*`, and `local`. These are created by Rancher agents and Fleet controllers and are not removed by the Helm uninstall. If any are found the script lists them and prompts for confirmation. `--force` removes them without prompting.

**6. Rancher CRDs** — queries for CRDs with `.cattle.io`, `.fleet.cattle.io`, or `.rancher.io` suffixes (Rancher installs dozens of these). The script prints the count and warns explicitly that removing a CRD also permanently deletes every custom resource instance of that type (e.g. all `GitRepo`, `Cluster`, and `Project` objects). A separate `YES` confirmation is required. `--force` removes without prompting.

**7. cert-manager** *(only when `--remove-cert-manager` is passed)* — runs `helm -n cert-manager uninstall cert-manager`, waits for the `cert-manager` namespace to terminate with the same 60 s poll loop, then removes all `*.cert-manager.io` CRDs. Only use this flag if cert-manager was installed exclusively for Rancher and is not used by any other workload (e.g. Traefik TLS issuers, application certificates).

**8. Post-uninstall audit** — re-queries the cluster for leftover `cattle-*`/`fleet-*`/`rancher-*` namespaces, remaining Rancher CRDs, and whether `cattle-system` still exists. Prints a pass/fail summary:

```
✔  Audit: clean — no Rancher artifacts detected.
```

or

```
⚠  Audit found 3 issue(s). Review warnings above.
```

#### Flag reference

| Flag | Description |
|---|---|
| `--remove-cert-manager` | Also uninstalls the `cert-manager` Helm release, its namespace, and all `*.cert-manager.io` CRDs. Only pass this if cert-manager is not shared with other workloads on the cluster. |
| `--dry-run` | Prints every `helm` and `kubectl` command that would be run, prefixed with `[DRY-RUN]`, without executing anything. Preflight checks still run against the live cluster so you can confirm connectivity before a real teardown. |
| `--force` | Skips the initial `YES` confirmation and all mid-script per-step confirmations (lingering namespace deletion, CRD deletion). Use in scripts and CI; be cautious on shared clusters where other teams may rely on Rancher resources. |

#### Usage examples

```bash
# 1. Standard interactive removal — prompts at each destructive step
sudo ./uninstall-rancher.sh

# 2. Dry-run — inspect everything that would be removed
sudo ./uninstall-rancher.sh --dry-run

# 3. Full teardown including cert-manager, no prompts
sudo ./uninstall-rancher.sh --remove-cert-manager --force

# 4. Remove Rancher but keep cert-manager (shared with other workloads)
sudo ./uninstall-rancher.sh --force
```

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

## Common Issues

- **Ingress not reachable**: confirm Traefik is running in `kube-system` and DNS points to the right node/LB.
- **Certificate pending**: check `cert-manager` pods and `Certificate`/`Challenge` objects.
- **PodSecurity issues**: ensure the management cluster policy allows Rancher workloads.
- **Strict agent TLS + private CA**: if using a private CA, set `privateCA: true` and ensure agents trust the CA.

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)


---

*Licensed under [CC BY-NC-SA 4.0](../LICENSE.md) · © 2026 UncleJS*
