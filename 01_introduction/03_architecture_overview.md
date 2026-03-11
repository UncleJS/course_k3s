# Architecture Overview

> Module 01 · Lesson 03 | [↑ Course Index](../README.md)


[![Course Index](https://img.shields.io/badge/Course-Index-0f766e)](../README.md)
[![License: CC BY-NC-SA 4.0](https://img.shields.io/badge/License-CC%20BY--NC--SA%204.0-lightgrey)](../LICENSE.md)

## Table of Contents

- [High-Level Architecture](#high-level-architecture)
- [Server Node (Control Plane)](#server-node-control-plane)
- [Agent Node (Worker)](#agent-node-worker)
- [Embedded Components Deep Dive](#embedded-components-deep-dive)
- [Networking Architecture](#networking-architecture)
- [Storage Architecture](#storage-architecture)
- [Request Lifecycle](#request-lifecycle)
- [HA Architecture](#ha-architecture)
- [Data Flow Diagrams](#data-flow-diagrams)
- [Common Pitfalls](#common-pitfalls)
- [Further Reading](#further-reading)

---

## High-Level Architecture

```mermaid
graph TB
    subgraph "k3s Cluster"
        subgraph "Server Node (Control Plane)"
            API[kube-apiserver]
            SCH[kube-scheduler]
            CM[controller-manager]
            DS[(SQLite / etcd)]
            API <--> DS
            API --> SCH
            API --> CM
        end

        subgraph "Server Node also runs Agent"
            KL1[kubelet]
            KP1[kube-proxy]
            CT1[containerd]
            FL1[Flannel CNI]
        end

        subgraph "Agent Node 1"
            KL2[kubelet]
            KP2[kube-proxy]
            CT2[containerd]
            FL2[Flannel CNI]
        end

        subgraph "Agent Node 2"
            KL3[kubelet]
            KP3[kube-proxy]
            CT3[containerd]
            FL3[Flannel CNI]
        end

        API -->|"Node registration"| KL1 & KL2 & KL3
        KL1 -.->|"Pod scheduling"| CT1
        KL2 -.->|"Pod scheduling"| CT2
        KL3 -.->|"Pod scheduling"| CT3
        FL1 <-->|"VXLAN overlay"| FL2 <-->|"VXLAN overlay"| FL3
    end

    USER[kubectl / User] -->|"HTTPS :6443"| API
    style API fill:#6366f1,color:#fff
    style DS fill:#f59e0b,color:#fff
    style USER fill:#22c55e,color:#fff
```

The k3s cluster has two node types:

1. **Server node** — runs the control plane AND a local agent (can schedule workloads by default)
2. **Agent node** — runs only the agent components, registers with the server, runs workloads

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

## Server Node (Control Plane)

A k3s server node runs these components inside a single `k3s` process:

```mermaid
flowchart TD
    K3S["k3s server process (PID 1)"]
    K3S --> API["kube-apiserver REST API :6443 Validates & stores resources"]
    K3S --> SCH["kube-scheduler Watches unscheduled Pods Assigns to Nodes"]
    K3S --> CM["kube-controller-manager Deployment controller Node controller Endpoint controller etc."]
    K3S --> DS["Datastore SQLite (default) etcd (HA mode)"]
    K3S --> KL["kubelet (local agent) Manages Pods on this node"]
    K3S --> KP["kube-proxy Manages iptables/nftables rules"]
    K3S --> CD["containerd Pulls images Starts containers"]
    K3S --> FL["Flannel CNI Pod network overlay"]
    K3S --> TR["Traefik Ingress (deployed as Pod)"]
    K3S --> DNS["CoreDNS (deployed as Pod)"]
    K3S --> LB["Klipper LoadBalancer (deployed as Pod)"]
    K3S --> SP["local-path-provisioner (deployed as Pod)"]

    style K3S fill:#6366f1,color:#fff
    style DS fill:#f59e0b,color:#fff
```

### Key server paths

| Path | Purpose |
|------|---------|
| `/etc/rancher/k3s/k3s.yaml` | Kubeconfig file for kubectl |
| `/var/lib/rancher/k3s/server/` | Server data (etcd/SQLite, certs, tokens) |
| `/var/lib/rancher/k3s/server/node-token` | Node join token (agents) |
| `/var/lib/rancher/k3s/server/token` | Server join token |
| `/var/lib/rancher/k3s/server/manifests/` | Auto-deploy manifests directory |
| `/var/lib/rancher/k3s/server/tls/` | Cluster TLS certificates |
| `/etc/rancher/k3s/config.yaml` | k3s configuration file |

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

## Agent Node (Worker)

A k3s agent node runs a subset of components:

```mermaid
flowchart TD
    K3SA["k3s agent process"]
    K3SA --> KL["kubelet Registers with API server Manages Pod lifecycle Reports node status"]
    K3SA --> KP["kube-proxy Syncs Service iptables rules Enables ClusterIP routing"]
    K3SA --> CD["containerd Pulls container images Starts/stops containers"]
    K3SA --> FL["Flannel CNI Assigns Pod CIDRs Creates VXLAN tunnel"]

    KL -->|"CRI calls"| CD
    FL -->|"Network setup"| KL

    style K3SA fill:#f59e0b,color:#fff
```

### Agent registration flow

```mermaid
sequenceDiagram
    participant AG as k3s Agent
    participant API as k3s API Server
    participant DS as Datastore

    AG->>API: POST /v1/nodes (with token auth)
    API->>DS: Store Node object
    DS-->>API: ACK
    API-->>AG: 201 Created — Node registered

    loop Every 10s
        AG->>API: PATCH /v1/nodes/<name>/status
        API-->>AG: 200 OK
    end

    API->>AG: Watch Pod assignments
    AG->>AG: Pull image + start container
    AG->>API: Update Pod status (Running)
```

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

## Embedded Components Deep Dive

### containerd

k3s bundles containerd and configures it automatically. The containerd socket is at:

```
/run/k3s/containerd/containerd.sock
```

k3s sets up containerd with:
- Pause image for pod sandboxes
- Registry mirror configuration (if provided)
- Snapshotter (overlayfs by default)

```bash
# Inspect containerd state via k3s
sudo k3s crictl info           # runtime info
sudo k3s crictl ps             # running containers
sudo k3s crictl images         # pulled images
sudo k3s ctr namespaces ls     # containerd namespaces (k8s.io is k3s's)
```

### Flannel CNI

Flannel creates a flat Layer 3 network across all nodes using VXLAN:

```
Pod CIDR (default): 10.42.0.0/16
  Node 1 pods: 10.42.0.0/24
  Node 2 pods: 10.42.1.0/24
  Node 3 pods: 10.42.2.0/24

Service CIDR (default): 10.43.0.0/16
```

### CoreDNS

CoreDNS provides DNS resolution for Service names:

```
Service format:  <service>.<namespace>.svc.cluster.local
Pod format:      <pod-ip-dashes>.<namespace>.pod.cluster.local

Example:
  my-service.default.svc.cluster.local → 10.43.0.25
```

### Traefik

Traefik is deployed as a DaemonSet in the `kube-system` namespace and binds to host ports 80 and 443.

### Klipper LoadBalancer

Klipper assigns the node's IP as the `LoadBalancer` IP for `Service` objects of type `LoadBalancer`. On multi-node clusters, it uses the first available node.

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

## Networking Architecture

```mermaid
graph TB
    subgraph "External"
        CLIENT[Client Browser 203.0.113.1]
    end

    subgraph "Node (192.168.1.10)"
        IPTABLES[iptables / nftables kube-proxy rules]

        subgraph "Pod Network 10.42.0.0/24"
            POD1[Pod A 10.42.0.5]
            POD2[Pod B 10.42.0.6]
        end

        subgraph "Services 10.43.0.0/16"
            SVC[ClusterIP Service 10.43.0.25:80]
        end

        TR[Traefik :80/:443]
        VXLAN[flannel.1 VXLAN interface]
    end

    subgraph "Node 2 (192.168.1.11)"
        subgraph "Pod Network 10.42.1.0/24"
            POD3[Pod C 10.42.1.5]
        end
        VXLAN2[flannel.1 VXLAN interface]
    end

    CLIENT -->|":80"| TR
    TR --> IPTABLES
    IPTABLES --> SVC
    SVC --> POD1 & POD2
    POD1 <-->|"Direct"| POD2
    POD1 <-->|"VXLAN tunnel UDP:8472"| VXLAN
    VXLAN <--> VXLAN2
    VXLAN2 --> POD3
```

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

## Storage Architecture

```mermaid
flowchart TD
    POD[Pod requests PVC]
    PVC[PersistentVolumeClaim]
    SC[StorageClass local-path]
    PROV[local-path-provisioner]
    PV[PersistentVolume]
    DIR["/opt/local-path-provisioner/uuid on node filesystem"]

    POD --> PVC
    PVC --> SC
    SC --> PROV
    PROV --> PV
    PV --> DIR
    DIR -->|"bind mount"| POD

    style POD fill:#6366f1,color:#fff
    style DIR fill:#f59e0b,color:#fff
```

The default `local-path` storage class:
- Creates a directory under `/opt/local-path-provisioner/`
- Binds the PVC to whichever node the pod is scheduled on
- **Not replicated** — if the node fails, data is lost (use Longhorn for HA storage)

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

## Request Lifecycle

Trace what happens when you run `kubectl apply -f deployment.yaml`:

```mermaid
sequenceDiagram
    participant U as kubectl
    participant API as kube-apiserver
    participant DS as SQLite/etcd
    participant CM as controller-manager
    participant SCH as kube-scheduler
    participant KL as kubelet (node)
    participant CT as containerd

    U->>API: POST /apis/apps/v1/deployments
    API->>API: Authenticate + Authorize + Validate
    API->>DS: Write Deployment object
    DS-->>API: ACK

    API-->>CM: Watch event: Deployment created
    CM->>API: POST /v1/pods (create ReplicaSet + Pods)
    API->>DS: Write ReplicaSet + Pod objects (Pending)

    API-->>SCH: Watch event: Unscheduled Pod
    SCH->>SCH: Score nodes, select best fit
    SCH->>API: PATCH Pod.spec.nodeName = "node1"
    API->>DS: Update Pod (Scheduled)

    API-->>KL: Watch event: Pod assigned to this node
    KL->>CT: Pull image + create container
    CT-->>KL: Container running
    KL->>API: PATCH Pod.status = Running
    API->>DS: Update Pod (Running)

    API-->>U: 201 Created
```

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

## HA Architecture

When running k3s in HA mode (3+ server nodes with embedded etcd):

```mermaid
graph TB
    subgraph "Load Balancer (optional)"
        LB[nginx / HAProxy 192.168.1.100:6443]
    end

    subgraph "Server Nodes"
        S1["Server 1 192.168.1.10 Active"]
        S2["Server 2 192.168.1.11 Active"]
        S3["Server 3 192.168.1.12 Active"]
    end

    subgraph "etcd Cluster"
        E1[(etcd 1 Leader)]
        E2[(etcd 2 Follower)]
        E3[(etcd 3 Follower)]
    end

    subgraph "Agent Nodes"
        A1[Agent 1]
        A2[Agent 2]
        A3[Agent 3]
    end

    LB --> S1 & S2 & S3
    S1 <--> E1
    S2 <--> E2
    S3 <--> E3
    E1 <-->|"Raft consensus"| E2 & E3

    A1 & A2 & A3 -->|":6443"| LB

    style S1 fill:#22c55e,color:#fff
    style S2 fill:#22c55e,color:#fff
    style S3 fill:#22c55e,color:#fff
    style E1 fill:#6366f1,color:#fff
    style LB fill:#f59e0b,color:#fff
```

HA requirements:
- Minimum **3 server nodes** (odd number for etcd quorum)
- A **load balancer** or VIP in front of the API servers (k3s can use embedded supervisor LB)
- All servers must be able to reach each other on ports 2379, 2380 (etcd), and 6443 (API)

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

## Common Pitfalls

| Pitfall | Detail |
|---------|--------|
| Server node scheduling workloads | By default, the server node also runs workloads. Taint it if you want a dedicated control plane |
| Single server = single point of failure | SQLite on one server has no HA. Use embedded etcd with 3 servers for production |
| Flannel VXLAN blocked | UDP port 8472 must be open between nodes for pod-to-pod communication |
| API server port blocked | TCP 6443 must be open from agents to servers |
| Node token exposure | `/var/lib/rancher/k3s/server/node-token` (and `/var/lib/rancher/k3s/server/token`) must be kept secret — they allow machines to join the cluster |

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

## Further Reading

- [k3s Architecture Docs](https://docs.k3s.io/architecture)
- [Kubernetes Components](https://kubernetes.io/docs/concepts/overview/components/)
- [etcd Documentation](https://etcd.io/docs/)
- [Flannel Network Documentation](https://github.com/flannel-io/flannel/blob/master/Documentation/backends.md)
- [containerd Architecture](https://containerd.io/docs/getting-started/)

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

*Licensed under [CC BY-NC-SA 4.0](../LICENSE.md) · © 2026 UncleJS*
