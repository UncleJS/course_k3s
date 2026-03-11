# k3s vs Kubernetes

> Module 01 · Lesson 02 | [↑ Course Index](../README.md)


[![Course Index](https://img.shields.io/badge/Course-Index-0f766e)](../README.md)
[![License: CC BY-NC-SA 4.0](https://img.shields.io/badge/License-CC%20BY--NC--SA%204.0-lightgrey)](../LICENSE.md)

## Table of Contents

- [Side-by-Side Comparison](#side-by-side-comparison)
- [What k3s Removes from Upstream k8s](#what-k3s-removes-from-upstream-k8s)
- [What k3s Adds Over Upstream k8s](#what-k3s-adds-over-upstream-k8s)
- [Component Mapping](#component-mapping)
- [API Compatibility](#api-compatibility)
- [Datastore Differences](#datastore-differences)
- [Networking Differences](#networking-differences)
- [When to Choose k3s vs Full k8s](#when-to-choose-k3s-vs-full-k8s)
- [Common Pitfalls](#common-pitfalls)
- [Further Reading](#further-reading)

---

## Side-by-Side Comparison

```mermaid
graph LR
    subgraph K8S["Upstream Kubernetes"]
        k8s_bin["Multiple binaries (7+ processes)"]
        k8s_ram["RAM: 2+ GB recommended"]
        k8s_etcd["etcd required (external or managed)"]
        k8s_cni["CNI: bring your own (Calico, Cilium, Flannel…)"]
        k8s_ing["Ingress: bring your own (nginx, traefik, haproxy…)"]
        k8s_lb["LoadBalancer: cloud or MetalLB"]
        k8s_str["Storage: external provisioner required"]
    end
    subgraph K3S["k3s"]
        k3s_bin["Single binary (< 100 MB)"]
        k3s_ram["RAM: 512 MB minimum"]
        k3s_etcd["SQLite (default) or embedded etcd (HA)"]
        k3s_cni["CNI: Flannel (built-in)"]
        k3s_ing["Ingress: Traefik (built-in)"]
        k3s_lb["LoadBalancer: Klipper (built-in)"]
        k3s_str["Storage: local-path (built-in)"]
    end
    style K3S fill:#dcfce7
    style K8S fill:#fef3c7
```

| Feature | Upstream k8s | k3s |
|---------|-------------|-----|
| Binary size | ~500 MB total | ~100 MB single binary |
| Minimum RAM (server) | ~2 GB | 512 MB |
| Default datastore | etcd (external) | SQLite (embedded) |
| HA datastore | etcd (external) | Embedded etcd or external DB |
| Default CNI | None (must install) | Flannel (built-in) |
| Default Ingress | None (must install) | Traefik v2 (built-in) |
| Default LoadBalancer | None (cloud or MetalLB) | Klipper (built-in) |
| Default Storage | None (must install) | local-path-provisioner |
| Helm support | Helm CLI required | HelmChart CRD + Helm controller |
| Container runtime | containerd / CRI-O | containerd (embedded) |
| TLS management | Manual or cert-manager | Automatic (built-in) |
| Release cadence | Every ~3 months | Follows upstream within days |
| CNCF certified | Yes | Yes |

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

## What k3s Removes from Upstream k8s

k3s is not just "smaller k8s" — it deliberately removes or replaces certain components:

```mermaid
flowchart TD
    K8S[Upstream Kubernetes] --> REMOVE["Removed from k3s"]
    REMOVE --> R1["Alpha/deprecated APIs (cloud provider integrations)"]
    REMOVE --> R2["In-tree volume plugins (replaced by CSI)"]
    REMOVE --> R3["Most cloud-provider specific code"]
    REMOVE --> R4["Legacy admission plugins (only essential ones kept)"]

    K8S --> REPLACED["Replaced in k3s"]
    REPLACED --> P1["etcd → SQLite (single-node default)"]
    REPLACED --> P2["External CNI → Flannel (built-in)"]
    REPLACED --> P3["External Ingress → Traefik (built-in)"]
    REPLACED --> P4["External LB → Klipper (built-in)"]

    style REMOVE fill:#fee2e2
    style REPLACED fill:#fef3c7
```

The removals reduce binary size and complexity. The replacements mean you get a usable cluster immediately after install — no extra addon installation needed.

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

## What k3s Adds Over Upstream k8s

k3s also adds functionality that upstream Kubernetes does not have:

| Addition | Description |
|----------|-------------|
| `HelmChart` CRD | Deploy Helm charts declaratively via Kubernetes manifests — no Helm CLI needed |
| `HelmChartConfig` CRD | Override values of existing `HelmChart` resources without modifying them |
| `AddonsJob` CRD | Run one-time jobs to install manifests at cluster startup |
| Auto-deploying manifests | Drop YAML files in `/var/lib/rancher/k3s/server/manifests/` and they are applied automatically |
| Klipper LoadBalancer | Built-in bare-metal service load balancer — no cloud provider needed |
| Embedded etcd operator | Built-in etcd cluster management for HA without external tooling |
| `k3s etcd-snapshot` | Built-in backup and restore CLI for embedded etcd |
| `k3s token` | Manage node join tokens from the CLI |
| `k3s certificate` | Inspect and rotate cluster TLS certificates |

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

## Component Mapping

When reading k8s documentation, use this map to understand the k3s equivalent:

| Kubernetes Concept | Upstream k8s | k3s Equivalent |
|-------------------|-------------|----------------|
| Datastore | External etcd | SQLite (dev) / Embedded etcd (HA) |
| API Server | `kube-apiserver` process | Embedded in `k3s server` |
| Scheduler | `kube-scheduler` process | Embedded in `k3s server` |
| Controller Manager | `kube-controller-manager` | Embedded in `k3s server` |
| Node Agent | `kubelet` process | Embedded in `k3s server`/`agent` |
| Network proxy | `kube-proxy` process | Embedded in `k3s server`/`agent` |
| Container runtime | Install separately | Embedded containerd |
| CNI plugin | Install separately | Embedded Flannel |
| Ingress controller | Install separately | Embedded Traefik |
| LoadBalancer | Cloud or MetalLB | Embedded Klipper |
| DNS | Install CoreDNS manually | Embedded CoreDNS |
| Storage provisioner | Install separately | Embedded local-path |
| Helm charts | Helm CLI + kubectl | `HelmChart` CRD |
| Kubeconfig | `~/.kube/config` | `/etc/rancher/k3s/k3s.yaml` |

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

## API Compatibility

k3s implements the **full Kubernetes API**. Any valid Kubernetes manifest works with k3s without modification:

```bash
# Apply a standard k8s Deployment — works identically on k3s
kubectl apply -f https://k8s.io/examples/controllers/nginx-deployment.yaml

# All standard API groups are available
kubectl api-versions | grep apps
# apps/v1

kubectl api-resources | grep Deployment
# deployments   deploy   apps/v1   true   Deployment
```

k3s passes the [CNCF Kubernetes Conformance tests](https://www.cncf.io/certification/software-conformance/), meaning any workload certified for Kubernetes will run on k3s.

> **Important exception:** If your workload uses deprecated or alpha APIs that upstream has removed, k3s (which follows upstream closely) will also not support them.

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

## Datastore Differences

This is the most significant architectural difference:

```mermaid
flowchart TD
    subgraph "Single Node k3s (default)"
        A[k3s server] --> B[(SQLite /var/lib/rancher/k3s/server/db/state.db)]
    end
    subgraph "HA k3s (embedded etcd)"
        S1[k3s server 1] --> E1[(etcd member 1)]
        S2[k3s server 2] --> E2[(etcd member 2)]
        S3[k3s server 3] --> E3[(etcd member 3)]
        E1 <--> E2 <--> E3
    end
    subgraph "k3s with external DB"
        S4[k3s server 1] --> PG[(PostgreSQL or MySQL)]
        S5[k3s server 2] --> PG
    end
    subgraph "Upstream k8s"
        K[kube-apiserver] --> EE[(External etcd cluster)]
    end
```

| Mode | Datastore | Use case | Notes |
|------|-----------|---------|-------|
| Default | SQLite | Dev, single-node, edge | Not HA, simple to manage |
| HA embedded | etcd (embedded) | Production HA | Requires 3+ server nodes |
| HA external | PostgreSQL / MySQL | Production HA | Familiar DB tooling, backups |
| Upstream k8s | etcd (external) | Large clusters | More ops overhead |

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

## Networking Differences

k3s uses **Flannel** with VXLAN as the default CNI. This is simpler than most production k8s CNI choices:

```mermaid
graph TD
    subgraph "k3s Networking Stack"
        F[Flannel CNI - VXLAN]
        KP[Kube-proxy - iptables/nftables]
        CD[CoreDNS]
        KL[Klipper LoadBalancer]
        TR[Traefik Ingress]
    end
    subgraph "Upstream k8s Options"
        C[Calico / Cilium / Weave]
        KP2[kube-proxy]
        CD2[CoreDNS]
        M[MetalLB / Cloud LB]
        N[nginx / HAProxy / Traefik]
    end
    style F fill:#22c55e,color:#fff
    style C fill:#6366f1,color:#fff
```

You can **replace** Flannel with Calico or Cilium in k3s if you need:
- Network policies with enforcement (Flannel alone doesn't enforce them)
- eBPF-based networking
- Advanced security features

> **Note:** k3s includes a basic `NetworkPolicy` controller via Flannel + kube-router, but for full NetworkPolicy support, replace Flannel with Calico or Cilium.

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

## When to Choose k3s vs Full k8s

```mermaid
flowchart TD
    Q1{Cluster size?}
    Q1 -->|"< 100 nodes"| Q2
    Q1 -->|"100+ nodes"| FULLK8S[Consider full k8s or managed service]

    Q2{Resource constrained?}
    Q2 -->|"Yes — edge/IoT/Pi"| K3S_YES[k3s ✅]
    Q2 -->|"No"| Q3

    Q3{Need simplicity?}
    Q3 -->|"Yes — minimal ops"| K3S_YES2[k3s ✅]
    Q3 -->|"No — full control"| Q4

    Q4{Air-gapped or on-prem?}
    Q4 -->|"Yes"| K3S_YES3[k3s ✅]
    Q4 -->|"No — cloud native"| Q5

    Q5{Advanced CNI (eBPF/Cilium)?}
    Q5 -->|"Yes — built-in"| MANAGED[EKS / GKE / AKS]
    Q5 -->|"Configurable"| K3S_YES4[k3s + Cilium ✅]

    style K3S_YES fill:#22c55e,color:#fff
    style K3S_YES2 fill:#22c55e,color:#fff
    style K3S_YES3 fill:#22c55e,color:#fff
    style K3S_YES4 fill:#22c55e,color:#fff
    style FULLK8S fill:#f59e0b,color:#fff
    style MANAGED fill:#6366f1,color:#fff
```

**Choose k3s when:**
- You need Kubernetes on resource-constrained hardware
- You want minimal operational overhead
- You're building edge, IoT, or air-gapped deployments
- You're learning Kubernetes or building a dev environment
- You need a quick, production-ready cluster for small workloads

**Consider alternatives when:**
- You need 100+ nodes with advanced networking (Cilium, BGP)
- You require advanced multi-tenancy with strict isolation
- Your team already operates managed k8s (EKS/GKE/AKS)
- You need Windows node support

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

## Common Pitfalls

| Pitfall | Detail |
|---------|--------|
| Assuming Docker commands work | k3s uses containerd. Use `k3s crictl` not `docker` |
| Expecting Calico NetworkPolicy | Flannel's network policy support is limited; install Calico if needed |
| Using k3s in 1000-node clusters | k3s is tested and recommended for up to ~100 nodes |
| Mixing k3s and k8s configs | Keep kubeconfig files separate; use `KUBECONFIG` env var to switch |

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

## Further Reading

- [k3s vs k8s — Official Comparison](https://docs.k3s.io/faq)
- [CNCF Conformance](https://www.cncf.io/certification/software-conformance/)
- [Flannel CNI](https://github.com/flannel-io/flannel)
- [Klipper LoadBalancer](https://github.com/k3s-io/klipper-lb)

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

*Licensed under [CC BY-NC-SA 4.0](../LICENSE.md) · © 2026 UncleJS*
