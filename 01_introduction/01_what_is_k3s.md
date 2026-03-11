# What is k3s?

> Module 01 · Lesson 01 | [↑ Course Index](../README.md)


[![Course Index](https://img.shields.io/badge/Course-Index-0f766e)](../README.md)
[![License: CC BY-NC-SA 4.0](https://img.shields.io/badge/License-CC%20BY--NC--SA%204.0-lightgrey)](../LICENSE.md)

## Table of Contents

- [The Problem k3s Solves](#the-problem-k3s-solves)
- [What k3s Is](#what-k3s-is)
- [What k3s Is Not](#what-k3s-is-not)
- [k3s Origins & History](#k3s-origins--history)
- [Who Uses k3s?](#who-uses-k3s)
- [Key Features at a Glance](#key-features-at-a-glance)
- [The Single Binary Design](#the-single-binary-design)
- [Common Pitfalls](#common-pitfalls)
- [Further Reading](#further-reading)

---

## The Problem k3s Solves

Standard Kubernetes (k8s) is powerful but heavyweight. A minimal k8s control plane requires:

- `etcd` — distributed key-value store
- `kube-apiserver` — REST API for the cluster
- `kube-controller-manager` — control loops
- `kube-scheduler` — pod placement decisions
- `kube-proxy` — network rules
- `kubelet` — node agent
- A container runtime (containerd, CRI-O, etc.)
- A CNI plugin (Flannel, Calico, Cilium…)

That's 7+ separate processes to manage, update, and secure. On a 512 MB Raspberry Pi or an edge device, this is simply too heavy.

k3s was built to solve exactly this problem.

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

## What k3s Is

**k3s** is a certified, lightweight Kubernetes distribution created by Rancher Labs (now part of SUSE). It is:

- A **single binary** under 100 MB that packages the entire Kubernetes control plane, node agent, container runtime (containerd), CNI (Flannel), load balancer (Klipper), ingress (Traefik), CoreDNS, and local storage provisioner
- **100% upstream Kubernetes compliant** — passes the CNCF conformance test suite
- Designed for **resource-constrained environments**: edge, IoT, CI, single-board computers, dev laptops
- Production-ready for **small to medium clusters**

```mermaid
graph LR
    subgraph "Standard Kubernetes (7+ binaries)"
        E[etcd]
        API[kube-apiserver]
        CM[controller-manager]
        SCH[kube-scheduler]
        KP[kube-proxy]
        KL[kubelet]
        CR[containerd]
    end
    subgraph "k3s (1 binary)"
        K3S["k3s binary ───────────── etcd (embedded) kube-apiserver controller-manager kube-scheduler kube-proxy kubelet containerd Flannel CNI Traefik Ingress CoreDNS Klipper LB local-path provisioner"]
    end
    style K3S fill:#22c55e,color:#fff,font-size:12px
```

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

## What k3s Is Not

It is important to understand what k3s does **not** do:

| Not | Explanation |
|-----|-------------|
| Not a managed service | k3s is self-hosted. You manage updates, backups, and HA yourself |
| Not a replacement for large clusters | For 100+ nodes with complex networking, vanilla k8s or managed offerings scale better |
| Not Docker | k3s uses containerd, not the Docker daemon. `docker` CLI commands do not work against k3s |
| Not a development-only tool | k3s is fully production-ready — it just also runs well on small machines |
| Not limited to ARM | k3s runs on x86_64, ARM64, ARMv7, s390x |

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

## k3s Origins & History

```mermaid
timeline
    title k3s Timeline
    2019 : Rancher Labs releases k3s v0.1
         : First Kubernetes distro under 40 MB
    2020 : k3s donated to CNCF as Sandbox project
         : Gains ARM64 and ARMv7 support
    2021 : k3s promoted to CNCF Incubating status
         : Embedded etcd HA introduced
    2022 : SUSE acquires Rancher Labs
         : k3s follows k8s release cadence
    2023 : k3s promoted to CNCF Graduated status
         : Widely adopted for edge and IoT
    2024 : Stable v1.28/v1.29 releases
         : First-class support for ARM SBCs
```

The name "k3s" comes from: if "k8s" is Kubernetes (k + 8 letters + s), then half of Kubernetes would be "k3s" (k + 3 letters + s) — a "5 less than k8s" joke about being lighter.

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

## Who Uses k3s?

k3s is used in a wide variety of scenarios:

| Scenario | Example |
|----------|---------|
| Edge computing | Retail stores, factories, substations running local workloads |
| IoT | Raspberry Pi clusters processing sensor data |
| Home lab | Learning Kubernetes on commodity hardware |
| CI/CD | Ephemeral test clusters in pipelines |
| Developer workstations | Local dev cluster that mirrors production |
| Small production clusters | Startups, internal tools, low-traffic services |
| Air-gapped environments | Secure facilities with no internet access |

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

## Key Features at a Glance

| Feature | Detail |
|---------|--------|
| **Single binary** | `k3s` binary < 100 MB packages everything |
| **Low memory** | Server: ~512 MB RAM minimum; Agent: ~75 MB RAM |
| **SQLite by default** | Uses SQLite instead of etcd for single-node clusters |
| **Embedded HA** | Embedded etcd available for multi-server HA clusters |
| **External DB support** | Can use PostgreSQL, MySQL, or etcd as external datastore |
| **Auto TLS** | Automatically generates and rotates cluster TLS certificates |
| **Helm CRD** | Deploy Helm charts via `HelmChart` CRDs, no Helm CLI needed |
| **Traefik included** | HTTP ingress controller installed by default |
| **Klipper LB** | Built-in service load balancer for bare-metal nodes |
| **Local storage** | `local-path-provisioner` creates PVCs automatically |
| **Air-gap support** | Pre-load images and install without internet |
| **Rootless mode** | Run k3s without root privileges (experimental) |

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

## The Single Binary Design

Understanding how k3s packages everything into one binary helps you reason about how it works:

```mermaid
flowchart TD
    BIN["k3s binary"]
    BIN --> SERVER["k3s server mode (runs control plane + agent)"]
    BIN --> AGENT["k3s agent mode (runs node agent only)"]
    BIN --> KUBECTL["k3s kubectl (built-in kubectl)"]
    BIN --> CRICTL["k3s crictl (CRI debugging tool)"]
    BIN --> CTR["k3s ctr (containerd client)"]
    BIN --> ETCD["k3s etcd-snapshot (backup/restore)"]
    BIN --> CERT["k3s certificate (cert management)"]
    BIN --> TOKEN["k3s token (node join tokens)"]

    SERVER --> CP["Control Plane kube-apiserver kube-scheduler controller-manager"]
    SERVER --> DS["Datastore SQLite (default) or etcd (HA)"]
    SERVER --> AGENT2["Embedded Agent kubelet kube-proxy containerd Flannel"]

    style BIN fill:#6366f1,color:#fff
    style SERVER fill:#22c55e,color:#fff
    style AGENT fill:#f59e0b,color:#fff
```

When you run `k3s server`, a single process starts that embeds all the Kubernetes components. This makes:
- **Installation** trivial — just run the installer script
- **Updates** atomic — replace one binary
- **Debugging** easier — all logs in one systemd unit
- **Resource usage** lower — shared Go runtime, no IPC overhead

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

## Common Pitfalls

| Pitfall | Detail |
|---------|--------|
| Expecting Docker | k3s uses containerd. Use `k3s crictl` or `k3s ctr` instead of `docker` commands |
| Using k3s for very large clusters | k3s works up to ~100 nodes but upstream k8s may scale better beyond that |
| Confusing k3s with k3d | **k3d** runs k3s inside Docker containers for local dev. They are different tools |
| Confusing k3s with microk8s | microk8s is a different lightweight k8s distro by Canonical. k3s is by SUSE/Rancher |
| Assuming all k8s addons work | Most do, but some addons assume Docker or specific CNI features not present in k3s |

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

## Further Reading

- [k3s Official Documentation](https://docs.k3s.io)
- [k3s GitHub Repository](https://github.com/k3s-io/k3s)
- [CNCF k3s Project Page](https://www.cncf.io/projects/k3s/)
- [Rancher k3s Blog](https://www.rancher.com/blog/tags/k3s)

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

*Licensed under [CC BY-NC-SA 4.0](../LICENSE.md) · © 2026 UncleJS*
