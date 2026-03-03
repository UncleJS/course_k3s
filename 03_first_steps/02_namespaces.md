# Namespaces

> Module 03 · Lesson 02 | [↑ Course Index](../README.md)

## Table of Contents

- [What Are Namespaces?](#what-are-namespaces)
- [Default Namespaces in k3s](#default-namespaces-in-k3s)
- [Creating Namespaces](#creating-namespaces)
- [Working with Namespaces](#working-with-namespaces)
- [Resource Isolation with Namespaces](#resource-isolation-with-namespaces)
- [Cross-Namespace Communication](#cross-namespace-communication)
- [Namespace-Scoped vs Cluster-Scoped Resources](#namespace-scoped-vs-cluster-scoped-resources)
- [Namespace Best Practices](#namespace-best-practices)
- [Common Pitfalls](#common-pitfalls)
- [Further Reading](#further-reading)

---

## What Are Namespaces?

Namespaces are virtual clusters within a physical Kubernetes cluster. They provide a mechanism for:

- **Isolation** — separate teams or environments without separate clusters
- **Resource scoping** — names only need to be unique within a namespace
- **Access control** — RBAC policies are namespace-scoped
- **Resource quotas** — limit CPU/memory per namespace

```mermaid
graph TB
    subgraph "k3s Cluster"
        subgraph "namespace: production"
            P_APP[app deployment]
            P_DB[database statefulset]
            P_SVC[service]
        end
        subgraph "namespace: staging"
            S_APP[app deployment]
            S_DB[database statefulset]
            S_SVC[service]
        end
        subgraph "namespace: kube-system"
            CORE[CoreDNS]
            TR[Traefik]
            LP[local-path-provisioner]
        end
        subgraph "namespace: kube-public"
            CM[cluster-info ConfigMap]
        end
    end
    style production fill:#dcfce7
    style staging fill:#fef3c7
    style kube-system fill:#e0e7ff
```

> **Analogy:** Namespaces are like floors in an office building. Each floor (namespace) has its own rooms (resources). People on different floors can co-exist in the building (cluster) without seeing each other's rooms.

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

## Default Namespaces in k3s

k3s creates these namespaces automatically:

| Namespace | Purpose |
|-----------|---------|
| `default` | Where resources go if you don't specify a namespace |
| `kube-system` | Kubernetes system components (CoreDNS, Traefik, kube-proxy, etc.) |
| `kube-public` | Publicly readable resources (cluster-info ConfigMap) |
| `kube-node-lease` | Node heartbeat lease objects (do not modify) |

```bash
# View all namespaces
kubectl get namespaces
# or shorthand:
kubectl get ns

# Output:
# NAME              STATUS   AGE
# default           Active   1d
# kube-node-lease   Active   1d
# kube-public       Active   1d
# kube-system       Active   1d
```

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

## Creating Namespaces

```bash
# Imperative
kubectl create namespace development
kubectl create namespace staging
kubectl create namespace production

# Declarative (preferred for production — track in git)
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: Namespace
metadata:
  name: production
  labels:
    environment: production
    team: platform
  annotations:
    contact: platform-team@example.com
EOF
```

### Namespace YAML template

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: my-app
  labels:
    # Labels are used for NetworkPolicy selectors and RBAC
    environment: production
    app.kubernetes.io/managed-by: "platform-team"
  annotations:
    # Annotations for documentation/tooling
    description: "Production namespace for my-app"
    contact: "team@example.com"
```

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

## Working with Namespaces

```bash
# Specify namespace with -n flag
kubectl get pods -n production
kubectl apply -f deployment.yaml -n production
kubectl delete pod my-pod -n staging

# View resources across all namespaces
kubectl get pods --all-namespaces
kubectl get pods -A   # shorthand

# Set default namespace for current kubectl context
kubectl config set-context --current --namespace=production

# Now all commands default to 'production'
kubectl get pods     # shows production pods

# Switch back to default
kubectl config set-context --current --namespace=default

# Delete a namespace (WARNING: deletes all resources inside)
kubectl delete namespace staging
```

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

## Resource Isolation with Namespaces

Resources in different namespaces are isolated by name but **not by network by default**:

```mermaid
flowchart LR
    subgraph "namespace: frontend"
        F_POD[frontend pod 10.42.0.5]
        F_SVC[svc: frontend 10.43.0.10]
    end
    subgraph "namespace: backend"
        B_POD[backend pod 10.42.0.6]
        B_SVC[svc: api 10.43.0.20]
    end

    F_POD -->|"Can reach backend api backend.svc.cluster.local"| B_SVC
    B_SVC --> B_POD

    note["Network isolation requires NetworkPolicy resources (see Module 09)"]
    style note fill:#fef3c7
```

- **Name isolation:** A `service` named `api` can exist in both `frontend` and `backend` namespaces independently
- **Network:** Pods in any namespace can reach pods in any other namespace by default (use NetworkPolicy to restrict)
- **RBAC:** Users can be granted access to specific namespaces only

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

## Cross-Namespace Communication

Services in other namespaces are reachable via their full DNS name:

```
Format: <service-name>.<namespace>.svc.cluster.local

Examples:
  api.backend.svc.cluster.local         # 'api' service in 'backend' namespace
  postgres.database.svc.cluster.local   # 'postgres' in 'database' namespace
  my-svc.default.svc.cluster.local      # 'my-svc' in 'default' namespace
```

```bash
# Test cross-namespace DNS from a pod
kubectl run -it --rm debug --image=busybox --restart=Never -- sh

# Inside the pod:
nslookup api.backend.svc.cluster.local
wget -qO- http://api.backend.svc.cluster.local/health

# Short form works within same namespace:
wget -qO- http://api/health

# Short form with namespace:
wget -qO- http://api.backend/health
```

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

## Namespace-Scoped vs Cluster-Scoped Resources

Some Kubernetes resources belong to a namespace; others are cluster-wide:

```bash
# See all API resources and their scope
kubectl api-resources --namespaced=true   # namespace-scoped
kubectl api-resources --namespaced=false  # cluster-scoped
```

| Namespace-Scoped | Cluster-Scoped |
|-----------------|----------------|
| Pod | Node |
| Deployment | PersistentVolume |
| Service | StorageClass |
| ConfigMap | ClusterRole |
| Secret | ClusterRoleBinding |
| PersistentVolumeClaim | Namespace itself |
| ServiceAccount | CustomResourceDefinition |
| Ingress | IngressClass |
| NetworkPolicy | — |

```mermaid
graph TD
    CLUSTER[k3s Cluster]
    CLUSTER --> NODE1[Node: server-01]
    CLUSTER --> NODE2[Node: agent-01]
    CLUSTER --> SC[StorageClass: local-path]
    CLUSTER --> PV[PersistentVolume]
    CLUSTER --> NS1[Namespace: default]
    CLUSTER --> NS2[Namespace: production]
    NS1 --> POD1[Pod: nginx]
    NS1 --> SVC1[Service: nginx]
    NS2 --> POD2[Pod: api]
    NS2 --> PVC[PVC: data]

    style CLUSTER fill:#6366f1,color:#fff
    style NS1 fill:#dcfce7
    style NS2 fill:#fef3c7
```

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

## Namespace Best Practices

```mermaid
flowchart TD
    STRATEGY{Namespace Strategy} --> ENV[By Environment dev / staging / production]
    STRATEGY --> TEAM[By Team platform / frontend / backend]
    STRATEGY --> APP[By Application app-a / app-b / monitoring]
    STRATEGY --> COMBO[Combination team-environment]

    ENV --> ENV_NOTE["✓ Simple ✓ Clear env separation ✗ Multiple teams mix in one env"]
    TEAM --> TEAM_NOTE["✓ Good for multi-team ✓ Clear ownership ✗ Env separation requires naming"]
    APP --> APP_NOTE["✓ App-centric isolation ✓ Easy cost tracking ✗ Lots of namespaces at scale"]
    COMBO --> COMBO_NOTE["✓ Best isolation ✗ Many namespaces ✗ More complex RBAC"]
```

**Recommended patterns:**

```bash
# Small team or single app
kubectl create namespace development
kubectl create namespace staging
kubectl create namespace production

# Multi-team
kubectl create namespace team-alpha-prod
kubectl create namespace team-alpha-staging
kubectl create namespace team-beta-prod

# Always label your namespaces
kubectl label namespace production \
  environment=production \
  pod-security.kubernetes.io/enforce=restricted
```

**Rules of thumb:**
- Never put application workloads in `kube-system` or `default`
- Label namespaces with `environment` and `team` for RBAC and NetworkPolicy selectors
- Use resource quotas on every production namespace (Module 14)
- Apply Pod Security Standards labels at namespace level (Module 09)

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

## Common Pitfalls

| Pitfall | Detail |
|---------|--------|
| Deploying to `default` namespace | Everything piles into `default`; use named namespaces for real workloads |
| Forgetting `-n` flag | `kubectl get pods` shows `default` — add `-n production` for your real pods |
| Assuming network isolation | Without NetworkPolicy, pods in all namespaces can talk to each other |
| Deleting namespace with important data | `kubectl delete namespace` deletes PVCs (and possibly data) — check first |
| Namespace stuck `Terminating` | Usually caused by finalizers; check `kubectl describe namespace <name>` for stuck resources |

```bash
# Fix stuck namespace (remove finalizers)
kubectl patch namespace stuck-ns \
  -p '{"spec":{"finalizers":[]}}' \
  --type=merge
```

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

## Further Reading

- [Kubernetes Namespaces Docs](https://kubernetes.io/docs/concepts/overview/working-with-objects/namespaces/)
- [DNS for Services and Pods](https://kubernetes.io/docs/concepts/services-networking/dns-pod-service/)

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

*Licensed under [CC BY-NC-SA 4.0](../LICENSE.md) · © 2026 UncleJS*
