# Translating Podman Compose to Kubernetes Manifests
> Module 16 · Lesson 02 | [↑ Course Index](../README.md)

## Table of Contents
- [Overview](#overview)
- [A Typical Podman Compose App](#a-typical-podman-compose-app)
- [Step 1: Services → Deployments](#step-1-services--deployments)
- [Step 2: Port Mappings → Kubernetes Services](#step-2-port-mappings--kubernetes-services)
- [Step 3: Volumes → PersistentVolumeClaims](#step-3-volumes--persistentvolumeclaims)
- [Step 4: Environment Variables and Secrets](#step-4-environment-variables-and-secrets)
- [ConfigMap vs Secret Decision Guide](#configmap-vs-secret-decision-guide)
- [Step 5: Health Checks → Probes](#step-5-health-checks--probes)
- [Step 6: Depends-On → Init Containers and Readiness](#step-6-depends-on--init-containers-and-readiness)
- [Step 7: Networking → Services and DNS](#step-7-networking--services-and-dns)
- [Step 8: Ingress for External Access](#step-8-ingress-for-external-access)
- [RollingUpdate Deep Dive](#rollingupdate-deep-dive)
- [Horizontal Pod Autoscaler (HPA)](#horizontal-pod-autoscaler-hpa)
- [Podman Compose YAML Quirks](#podman-compose-yaml-quirks)
- [Kustomize: The Multi-Environment Overlay Pattern](#kustomize-the-multi-environment-overlay-pattern)
- [Using Kompose for Automated Translation](#using-kompose-for-automated-translation)
- [Complete Before and After Example](#complete-before-and-after-example)
- [Common Pitfalls](#common-pitfalls)
- [Further Reading](#further-reading)
- [Lab](#lab)

---

## Overview

This lesson takes a realistic `podman-compose.yml` (web app + database + cache) and translates it piece-by-piece into Kubernetes manifests. By the end you'll have a reusable mental template for any Compose-to-k3s migration, plus the tools (Kustomize, HPA) to manage multiple environments and scale automatically.

```mermaid
graph TD
    subgraph Compose["podman-compose.yml"]
        S1[service: web]
        S2[service: db]
        S3[service: cache]
        V1[volumes:]
        E1[environment:]
        P1[ports:]
        H1[healthcheck:]
        D1[depends_on:]
    end

    subgraph K3s["Kubernetes Manifests"]
        K1[Deployment / StatefulSet]
        K2[Service ClusterIP]
        K3[PersistentVolumeClaim]
        K4[Secret / ConfigMap]
        K5[Ingress / IngressRoute]
        K6[liveness + readinessProbe]
        K7[initContainers]
    end

    S1 --> K1
    S2 --> K1
    S3 --> K1
    P1 --> K2
    V1 --> K3
    E1 --> K4
    H1 --> K6
    D1 --> K7
    K2 --> K5
```

**What this lesson covers:**
- Step-by-step translation of every Compose primitive
- ConfigMap vs Secret — the decision guide
- RollingUpdate strategy parameters explained
- Horizontal Pod Autoscaler for automatic scaling
- Podman Compose YAML quirks you'll hit during migration
- Kustomize overlays as the multi-environment replacement for Compose profiles

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

## A Typical Podman Compose App

Here is the starting point — a three-tier web application ("Taskr"):

```yaml
# podman-compose.yml (BEFORE)
version: "3.9"

services:
  web:
    image: ghcr.io/myorg/taskr-web:2.1.0
    ports:
      - "3000:3000"
    environment:
      NODE_ENV: production
      PORT: "3000"
      DATABASE_URL: postgres://taskr:secret@db:5432/taskr
      REDIS_URL: redis://cache:6379
      SESSION_SECRET: my-super-secret
    depends_on:
      db:
        condition: service_healthy
      cache:
        condition: service_started
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:3000/healthz"]
      interval: 30s
      timeout: 5s
      retries: 3
    volumes:
      - uploads:/app/uploads
    deploy:
      resources:
        limits:
          cpus: "0.5"
          memory: 512M
        reservations:
          cpus: "0.1"
          memory: 128M

  db:
    image: postgres:15-alpine
    environment:
      POSTGRES_DB: taskr
      POSTGRES_USER: taskr
      POSTGRES_PASSWORD: secret
    volumes:
      - pgdata:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U taskr -d taskr"]
      interval: 10s
      timeout: 5s
      retries: 5

  cache:
    image: redis:7-alpine
    command: redis-server --appendonly yes
    volumes:
      - redisdata:/data

volumes:
  uploads:
  pgdata:
  redisdata:
```

We will translate this into ~12 Kubernetes resources across a `taskr` namespace.

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

## Step 1: Services → Deployments

Each `service:` in Compose becomes a `Deployment` (stateless) or `StatefulSet` (stateful) in Kubernetes.

```mermaid
graph LR
    subgraph Compose
        CS[service: web image: ... replicas: 1]
    end
    subgraph Kubernetes
        D[Deployment spec.replicas: 1] --> RS[ReplicaSet] --> P1[Pod] & P2[Pod]
    end
    CS --> D
```

```yaml
# Compose
services:
  web:
    image: ghcr.io/myorg/taskr-web:2.1.0
```

```yaml
# Kubernetes — Deployment
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
  namespace: taskr
  labels:
    app: web
    app.kubernetes.io/part-of: taskr
spec:
  replicas: 2                    # Compose default is 1 — k8s makes scaling explicit
  selector:
    matchLabels:
      app: web
  template:
    metadata:
      labels:
        app: web
        app.kubernetes.io/part-of: taskr
    spec:
      containers:
      - name: web
        image: ghcr.io/myorg/taskr-web:2.1.0
```

> **Rule of thumb:**
> - `web`, `api`, `worker` → `Deployment` (stateless, replicas can be >1)
> - `db`, `redis`, `kafka` → `StatefulSet` (stable network identity, ordered management)
> - One-off DB migrations → `Job`
> - Scheduled tasks (cron) → `CronJob`

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

## Step 2: Port Mappings → Kubernetes Services

```yaml
# Compose
ports:
  - "3000:3000"   # host:container — exposes port on every host
```

In k3s, pod ports are **never** directly exposed to the host. You create a separate `Service` object that routes traffic to matching pods:

```yaml
# ClusterIP — internal cluster access only (pod-to-pod)
apiVersion: v1
kind: Service
metadata:
  name: web
  namespace: taskr
spec:
  selector:
    app: web           # matches pods with label app=web
  ports:
  - name: http
    port: 80           # port the Service listens on
    targetPort: 3000   # port the container listens on
  type: ClusterIP
```

| Service type | Use case | k3s equivalent of Compose `ports:` |
|---|---|---|
| `ClusterIP` | Internal traffic only | No host mapping — pod-to-pod |
| `NodePort` | Direct host port | `ports: "30080:80"` |
| `LoadBalancer` | Cloud LB / MetalLB | Not in basic Compose |
| `Ingress` | HTTP/HTTPS via hostname | Closest to Caddy/nginx proxy sidecar |

**Database and cache services** are internal-only:
```yaml
apiVersion: v1
kind: Service
metadata:
  name: postgres
  namespace: taskr
spec:
  selector:
    app: postgres
  ports:
  - port: 5432
    targetPort: 5432
  clusterIP: None   # headless — required for StatefulSet stable DNS
---
apiVersion: v1
kind: Service
metadata:
  name: redis
  namespace: taskr
spec:
  selector:
    app: redis
  ports:
  - port: 6379
    targetPort: 6379
  type: ClusterIP
```

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

## Step 3: Volumes → PersistentVolumeClaims

Named Compose volumes become PVCs backed by a `StorageClass`.

```yaml
# Compose
volumes:
  pgdata:
  redisdata:
  uploads:
```

```yaml
# Kubernetes — one PVC per volume
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: postgres-data
  namespace: taskr
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: local-path   # k3s built-in default
  resources:
    requests:
      storage: 10Gi
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: redis-data
  namespace: taskr
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: local-path
  resources:
    requests:
      storage: 1Gi
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: uploads
  namespace: taskr
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: local-path
  resources:
    requests:
      storage: 20Gi
```

Mount in the pod spec:
```yaml
# In Deployment/StatefulSet spec.template.spec
volumes:
- name: uploads
  persistentVolumeClaim:
    claimName: uploads

containers:
- name: web
  volumeMounts:
  - name: uploads
    mountPath: /app/uploads
```

**For databases, use `StatefulSet` with `volumeClaimTemplates`** instead of a standalone PVC. This gives each replica its own PVC automatically:
```yaml
kind: StatefulSet
spec:
  volumeClaimTemplates:
  - metadata:
      name: postgres-data
    spec:
      accessModes: [ReadWriteOnce]
      storageClassName: local-path
      resources:
        requests:
          storage: 10Gi
```

> **AccessMode cheat sheet:**
> - `ReadWriteOnce` (RWO) — one node at a time; fine for most stateful workloads
> - `ReadWriteMany` (RWX) — multiple nodes simultaneously; requires NFS or Longhorn
> - `ReadOnlyMany` (ROX) — multiple readers; rare

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

## Step 4: Environment Variables and Secrets

### Plain (non-sensitive) environment variables → ConfigMap or inline `env`

```yaml
# Compose
environment:
  NODE_ENV: production
  PORT: "3000"
```

```yaml
# Option A: inline env (fine for 1-3 vars)
env:
- name: NODE_ENV
  value: production
- name: PORT
  value: "3000"

# Option B: ConfigMap (better for many non-sensitive vars)
# First create a ConfigMap:
apiVersion: v1
kind: ConfigMap
metadata:
  name: web-config
  namespace: taskr
data:
  NODE_ENV: production
  PORT: "3000"
  LOG_LEVEL: info

# Then inject it:
envFrom:
- configMapRef:
    name: web-config
```

### Sensitive values → Kubernetes Secrets

```yaml
# Compose
environment:
  POSTGRES_PASSWORD: secret
  DATABASE_URL: postgres://taskr:secret@db:5432/taskr
  SESSION_SECRET: my-super-secret
```

```yaml
# Kubernetes: create a Secret
# WARNING: Never commit real secrets to git. Use SealedSecrets in production.
apiVersion: v1
kind: Secret
metadata:
  name: taskr-secrets
  namespace: taskr
type: Opaque
stringData:
  postgres-password: "secret"
  database-url: "postgres://taskr:secret@postgres.taskr.svc.cluster.local:5432/taskr"
  redis-url: "redis://redis.taskr.svc.cluster.local:6379"
  session-secret: "my-super-secret"
```

Reference individual keys in the pod:
```yaml
env:
- name: DATABASE_URL
  valueFrom:
    secretKeyRef:
      name: taskr-secrets
      key: database-url
- name: SESSION_SECRET
  valueFrom:
    secretKeyRef:
      name: taskr-secrets
      key: session-secret
```

Or inject all keys at once:
```yaml
envFrom:
- secretRef:
    name: taskr-secrets
```

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

## ConfigMap vs Secret Decision Guide

Use this table to decide whether a value belongs in a `ConfigMap` or a `Secret`:

| Question | ConfigMap | Secret |
|---|---|---|
| Is it sensitive (password, token, API key, cert)? | ✗ | ✅ |
| Is it safe to view in `kubectl describe`? | ✅ | ✗ (base64 encoded, not plaintext) |
| Does it vary per environment? | ✅ often | ✅ always |
| Is it a configuration file (nginx.conf, etc.)? | ✅ | ✗ |
| Is it a TLS certificate or private key? | ✗ | ✅ (`type: kubernetes.io/tls`) |
| Is it a container registry credential? | ✗ | ✅ (`type: kubernetes.io/dockerconfigjson`) |

```mermaid
flowchart TD
    A[New env var / config] --> B{Sensitive?}
    B -->|Yes| C[Secret]
    B -->|No| D{File or key=value?}
    D -->|File| E[ConfigMap with file key]
    D -->|Key=value| F{Many vars?}
    F -->|Yes| G[ConfigMap with envFrom]
    F -->|No| H[Inline env: in pod spec]
    C --> I{Production?}
    I -->|Yes| J[SealedSecret or External Secrets Operator]
    I -->|No / dev| K[Plain Secret do not commit to git]
```

> **SealedSecrets workflow (recommended for production):**
> ```bash
> # Install kubeseal CLI and the controller in the cluster
> kubeseal --format yaml < plain-secret.yaml > sealed-secret.yaml
> # sealed-secret.yaml is safe to commit — only the cluster can decrypt it
> git add sealed-secret.yaml
> ```

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

## Step 5: Health Checks → Probes

Compose has a single `healthcheck:`. Kubernetes has three independent probe types:

```yaml
# Compose
healthcheck:
  test: ["CMD", "curl", "-f", "http://localhost:3000/healthz"]
  interval: 30s
  timeout: 5s
  retries: 3
```

```yaml
# Kubernetes — three probe types
startupProbe:           # Runs FIRST; buys slow-starting containers more time
  httpGet:              # Kill container only if STILL failing after failureThreshold × periodSeconds
    path: /healthz
    port: 3000
  failureThreshold: 30  # allow up to 30 × 10s = 5 minutes to start
  periodSeconds: 10

readinessProbe:         # "Am I ready to receive traffic?"
  httpGet:              # Failing → removed from Service endpoints (no restart)
    path: /healthz
    port: 3000
  initialDelaySeconds: 5
  periodSeconds: 10
  timeoutSeconds: 3
  failureThreshold: 3

livenessProbe:          # "Am I still alive?" (matches Compose healthcheck most closely)
  httpGet:              # Failing → container killed and restarted
    path: /healthz
    port: 3000
  initialDelaySeconds: 30
  periodSeconds: 30
  timeoutSeconds: 5
  failureThreshold: 3
```

For the PostgreSQL `pg_isready` healthcheck:
```yaml
readinessProbe:
  exec:
    command: ["sh", "-c", "pg_isready -U $(POSTGRES_USER) -d $(POSTGRES_DB)"]
  initialDelaySeconds: 5
  periodSeconds: 5
  timeoutSeconds: 3
  failureThreshold: 6
livenessProbe:
  exec:
    command: ["sh", "-c", "pg_isready -U $(POSTGRES_USER) -d $(POSTGRES_DB)"]
  initialDelaySeconds: 30
  periodSeconds: 10
  timeoutSeconds: 5
  failureThreshold: 3
```

| Probe | Failure action | Compose equivalent |
|---|---|---|
| `startupProbe` | Kills container | `start_period` in healthcheck |
| `readinessProbe` | Removes from LB rotation | No equivalent |
| `livenessProbe` | Restarts container | `healthcheck` (closest match) |

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

## Step 6: Depends-On → Init Containers and Readiness

Compose `depends_on` has no direct Kubernetes equivalent. The two patterns:

### Option A: Init Container (explicit wait)
```yaml
initContainers:
- name: wait-for-postgres
  image: busybox:1.36
  command:
    - sh
    - -c
    - |
      echo "Waiting for PostgreSQL at postgres:5432..."
      until nc -z postgres 5432; do sleep 2; done
      echo "PostgreSQL is ready."
- name: wait-for-redis
  image: busybox:1.36
  command:
    - sh
    - -c
    - until nc -z redis 6379; do sleep 2; done
```

### Option B: Readiness Probes only (preferred for mature systems)
Set a `readinessProbe` on the dependency pod. The dependent pod starts immediately, but the `Service` will not route traffic to it until all its `readinessProbe`s pass. Combined with `startupProbe`, this is robust without explicit waiting.

```mermaid
sequenceDiagram
    participant PG as postgres Pod
    participant WEB as web Pod (2 replicas)
    participant SVC as web Service
    participant CLIENT as External Client

    PG->>PG: Start PostgreSQL
    PG->>PG: readinessProbe: pg_isready ✓
    WEB->>WEB: init: wait-for-postgres → nc -z postgres 5432 ✓
    WEB->>WEB: Start Node.js app
    WEB->>WEB: readinessProbe: GET /healthz ✓
    SVC->>WEB: Add both web pods to endpoints
    CLIENT->>SVC: Request → routes to ready web pods
```

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

## Step 7: Networking → Services and DNS

In Compose, services talk to each other by service name (e.g., `db`, `cache`) on the implicit shared network. **Kubernetes CoreDNS works identically** — just with the namespace appended:

| Compose connection string | Kubernetes short form (same namespace) | Fully-qualified |
|---|---|---|
| `postgres://taskr:secret@db:5432/taskr` | `db:5432` ✅ same | `db.taskr.svc.cluster.local:5432` |
| `redis://cache:6379` | `cache:6379` ✅ same | `cache.taskr.svc.cluster.local:6379` |

> **The short form works** because pods are resolved within their namespace by default. Use the FQDN only when connecting across namespaces.

So `DATABASE_URL: postgres://taskr:secret@postgres:5432/taskr` works **unchanged** in Kubernetes — as long as the Service is named `postgres` and is in the same namespace.

**Explicit network names (Compose `networks:`) are not needed** in Kubernetes — all pods in a namespace can reach all services in that namespace by default. Use `NetworkPolicy` to restrict access (covered in Lesson 04).

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

## Step 8: Ingress for External Access

Compose used `ports: "3000:3000"` to punch a hole in the host firewall. In k3s, use Traefik `IngressRoute` instead:

```yaml
# Standard Kubernetes Ingress (works with any ingress controller)
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: taskr-web
  namespace: taskr
  annotations:
    traefik.ingress.kubernetes.io/router.entrypoints: websecure
    cert-manager.io/cluster-issuer: letsencrypt
spec:
  ingressClassName: traefik
  rules:
  - host: taskr.example.com
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: web
            port:
              number: 80
  tls:
  - hosts:
    - taskr.example.com
    secretName: taskr-tls
```

Or the Traefik-native `IngressRoute` CRD (more features — middlewares, TCP routes):
```yaml
apiVersion: traefik.containo.us/v1alpha1
kind: IngressRoute
metadata:
  name: taskr-web
  namespace: taskr
spec:
  entryPoints: [websecure]
  routes:
  - match: Host(`taskr.example.com`)
    kind: Rule
    middlewares:
    - name: security-headers
    services:
    - name: web
      port: 80
  tls:
    certResolver: letsencrypt
```

**This replaces Compose's typical reverse-proxy service** (Caddy, nginx, Traefik as a service): TLS termination, host-based routing, rate limiting, and authentication middleware are all handled by the cluster ingress controller.

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

## RollingUpdate Deep Dive

Compose has no built-in zero-downtime deployment strategy. Kubernetes `RollingUpdate` is the default for Deployments and provides fine-grained control:

```yaml
spec:
  replicas: 3
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: 0    # never remove a pod before a new one is ready
      maxSurge: 1          # allow one extra pod above replicas during rollout
```

```mermaid
gantt
    title RollingUpdate: replicas=3, maxUnavailable=0, maxSurge=1
    dateFormat X
    axisFormat %s

    section Old Pods
    old-pod-1 :active, o1, 0, 8
    old-pod-2 :active, o2, 0, 10
    old-pod-3 :active, o3, 0, 12

    section New Pods
    new-pod-1 :n1, 2, 10
    new-pod-2 :n2, 6, 14
    new-pod-3 :n3, 10, 18
```

**Strategy comparison:**

| Strategy | Zero downtime | Use when |
|---|---|---|
| `RollingUpdate` (maxUnavailable=0) | ✅ | Stateless services — always |
| `RollingUpdate` (maxUnavailable=1) | ✗ but fast | Can tolerate brief reduced capacity |
| `Recreate` | ✗ | Single-replica stateful services with RWO PVC |
| Blue-green (two Deployments) | ✅ | Instant cutover, full rollback in seconds |
| Canary (traffic split) | ✅ | Gradual traffic shift, A/B testing |

**RollingUpdate prerequisites** for zero downtime:
1. Replicas ≥ 2
2. `readinessProbe` defined (gates traffic to new pods)
3. Application handles graceful shutdown (`preStop` hook or `terminationGracePeriodSeconds`)
4. PVCs are `ReadWriteMany` — or the service is stateless (no PVCs)

```yaml
# Graceful shutdown hook — gives the app 15s to drain in-flight requests
containers:
- name: web
  lifecycle:
    preStop:
      exec:
        command: ["sh", "-c", "sleep 5"]   # let LB drain before SIGTERM
  terminationGracePeriodSeconds: 30
```

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

## Horizontal Pod Autoscaler (HPA)

Compose has no autoscaling. Once on k3s, you can add `HorizontalPodAutoscaler` to scale pods based on CPU or memory:

```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: web-hpa
  namespace: taskr
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: web
  minReplicas: 2
  maxReplicas: 10
  metrics:
  - type: Resource
    resource:
      name: cpu
      target:
        type: Utilization
        averageUtilization: 70   # scale up when average CPU > 70%
  - type: Resource
    resource:
      name: memory
      target:
        type: Utilization
        averageUtilization: 80
```

> **HPA requires metrics-server** to be running. k3s bundles it by default.
> ```bash
> kubectl top pods -n taskr          # confirm metrics-server is working
> kubectl get hpa -n taskr -w        # watch HPA in real time
> ```

**HPA + RollingUpdate together:**
- HPA adjusts `spec.replicas` dynamically
- RollingUpdate controls how new versions are rolled out
- They work independently — you can have both on the same Deployment

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

## Podman Compose YAML Quirks

If you are migrating from `podman-compose` (not Docker Compose), watch for these incompatibilities:

| Podman Compose quirk | Kubernetes equivalent / fix |
|---|---|
| `network_mode: host` | Use `hostNetwork: true` in pod spec (rarely appropriate) |
| `userns_mode: keep-id` | Handled at the node level in k3s — no equivalent pod field |
| `security_opt: label=disable` | SELinux labels → `securityContext.seLinuxOptions` |
| `podman_compose_v2` extension keys | Ignored by Kubernetes — remove before migrating |
| `<<: *anchor` YAML merge keys | Kompose does not expand anchors — run `yq` to flatten first |
| `secrets:` top-level (Compose Swarm) | Translate to `kind: Secret` manually |
| `configs:` top-level | Translate to `kind: ConfigMap` manually |
| `x-podman:` extension block | Kubernetes ignores `x-` keys — safe to delete |
| Relative bind-mount paths (`./data:/data`) | Must become PVCs or `hostPath` (with caution) |

### Flatten YAML anchors before using kompose
```bash
# podman-compose uses YAML anchors (&anchor / *anchor) heavily
# kompose cannot expand them — flatten first with yq:
yq eval 'explode(.)' podman-compose.yml > podman-compose-flat.yml
kompose convert -f podman-compose-flat.yml --out ./k8s/
```

### Translate `network_mode: host` carefully
```yaml
# Compose (Podman-specific)
services:
  monitoring:
    network_mode: host

# Kubernetes — only use hostNetwork if truly required
spec:
  hostNetwork: true       # pod shares host network namespace
  dnsPolicy: ClusterFirstWithHostNet   # required when hostNetwork: true
```

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

## Kustomize: The Multi-Environment Overlay Pattern

Compose `profiles:` and multiple compose files (`-f docker-compose.yml -f docker-compose.prod.yml`) are the Compose way to manage environments. **Kustomize overlays** are the Kubernetes equivalent — and far more powerful.

```mermaid
graph TD
    BASE["base/   kustomization.yaml   deployment.yaml   service.yaml   configmap.yaml"]
    DEV["overlays/dev/   kustomization.yaml   patch-replicas.yaml   secret-dev.yaml"]
    PROD["overlays/prod/   kustomization.yaml   patch-replicas.yaml   patch-resources.yaml   secret-prod.yaml"]

    BASE --> DEV
    BASE --> PROD
```

### Base layer (`base/kustomization.yaml`)
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: taskr
resources:
- deployment.yaml
- service.yaml
- configmap.yaml
- ingress.yaml
commonLabels:
  app.kubernetes.io/part-of: taskr
```

### Dev overlay (`overlays/dev/kustomization.yaml`)
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: taskr-dev
namePrefix: dev-
resources:
- ../../base
patches:
- path: patch-replicas.yaml
secretGenerator:
- name: taskr-secrets
  envs:
  - secrets.env   # .env file — never committed to git
```

### Dev replica patch (`overlays/dev/patch-replicas.yaml`)
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
spec:
  replicas: 1      # dev only needs one replica
```

### Production overlay (`overlays/prod/kustomization.yaml`)
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: taskr
resources:
- ../../base
- hpa.yaml        # HPA only in production
patches:
- path: patch-resources.yaml   # higher CPU/memory limits
secretGenerator:
- name: taskr-secrets
  envs:
  - secrets.env   # prod secrets from CI/CD secret store
```

### Deploy to any environment
```bash
# Preview what will be applied
kubectl kustomize overlays/dev | less

# Apply dev
kubectl apply -k overlays/dev

# Apply prod
kubectl apply -k overlays/prod

# Diff before applying
kubectl diff -k overlays/prod
```

**Compose multi-file vs Kustomize comparison:**

| Compose approach | Kustomize equivalent |
|---|---|
| `docker-compose.yml` + `docker-compose.override.yml` | `base/` + `overlays/dev/` |
| `-f docker-compose.yml -f docker-compose.prod.yml` | `kubectl apply -k overlays/prod` |
| `profiles: [dev]` | `overlays/dev/` directory |
| Duplicate YAML with minor edits | Strategic merge patches |
| `${VARIABLE}` substitution | `vars:` in kustomization.yaml |

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

## Using Kompose for Automated Translation

`kompose` is an official CNCF tool that converts `podman-compose.yml` to Kubernetes manifests:

```bash
# Install kompose
curl -L https://github.com/kubernetes/kompose/releases/latest/download/kompose-linux-amd64 \
  -o /usr/local/bin/kompose
chmod +x /usr/local/bin/kompose

# Flatten anchors first (podman-compose quirk)
yq eval 'explode(.)' podman-compose.yml > flat.yml

# Convert to a directory of manifests
kompose convert -f flat.yml --out ./k8s/

# Review the output
ls k8s/

# Or convert and immediately apply (not recommended for production)
kompose up -f flat.yml
```

**What kompose gets right:**
- Creates a Deployment per service
- Converts `ports:` to Services
- Converts `environment:` to env vars
- Creates PVCs for named volumes (approximately)

**What kompose gets wrong — always fix these:**

| Kompose output | What you should do |
|---|---|
| `Deployment` for databases | Convert to `StatefulSet` |
| `hostPath` volumes | Convert to proper `PVC` with `storageClassName: local-path` |
| `NodePort` services | Replace with `ClusterIP` + `Ingress` |
| No resource limits/requests | Add `resources:` to every container |
| No liveness/readiness probes | Add probes from healthcheck |
| All env vars as plain text | Move sensitive vars to `Secret` |
| No `imagePullSecrets` | Add if pulling from private registry |

Use kompose as a **first draft only** — review and improve every file it generates.

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

## Complete Before and After Example

See the lab file [`labs/compose-to-k3s.yaml`](labs/compose-to-k3s.yaml) for the complete production-ready Kubernetes translation of the Taskr app, including:

- Namespace
- SealedSecrets-ready Secret
- PVCs for all volumes
- PostgreSQL StatefulSet with headless Service
- Redis Deployment with `Recreate` strategy (RWO PVC)
- Web Deployment with `RollingUpdate`, init containers, and probes
- ClusterIP Services for all components
- Traefik `IngressRoute` for HTTPS
- Security headers Middleware

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

## Common Pitfalls

| Issue | Symptom | Fix |
|---|---|---|
| `CrashLoopBackOff` on web pod | Logs: `connection refused postgres:5432` | Add `initContainers` wait-for-postgres |
| PVC stuck in `Pending` | `kubectl describe pvc` → `no matching StorageClass` | Set `storageClassName: local-path` |
| Service not routing traffic | Pod shows `0/1 Ready` | Fix `readinessProbe` — probe path or port wrong |
| `ImagePullBackOff` | `kubectl describe pod` → `401 Unauthorized` | Create `imagePullSecrets` with `docker-registry` type |
| RollingUpdate hangs at 50% | New pod stuck in `Pending` | Node out of CPU/memory — add `resources:` limits, check `kubectl top nodes` |
| Env var missing in container | App crashes with `undefined env` | `envFrom` references wrong ConfigMap/Secret name |
| DNS name not resolving | `nslookup db` fails in pod | Service name ≠ DNS name; check `kubectl get svc -n taskr` |
| `ReadWriteOnce` PVC blocks rolling update | Redis new pod `Pending` | Use `strategy: type: Recreate` for single-replica RWO workloads |
| kompose volumes as `hostPath` | Data lost when pod restarts on different node | Replace `hostPath` with PVC and `storageClassName: local-path` |
| YAML anchor `*foo` in kompose input | `kompose: error parsing` | Run `yq eval 'explode(.)' file.yml` before kompose |

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

## Further Reading

- [Kompose documentation](https://kompose.io/user-guide/) — official conversion guide
- [Kustomize reference](https://kubectl.docs.kubernetes.io/references/kustomize/) — overlays, patches, generators
- [Kubernetes Deployments](https://kubernetes.io/docs/concepts/workloads/controllers/deployment/) — RollingUpdate, Recreate
- [HorizontalPodAutoscaler walkthrough](https://kubernetes.io/docs/tasks/run-application/horizontal-pod-autoscale-walkthrough/)
- [Configure liveness, readiness and startup probes](https://kubernetes.io/docs/tasks/configure-pod-container/configure-liveness-readiness-startup-probes/)
- [SealedSecrets](https://github.com/bitnami-labs/sealed-secrets) — encrypt secrets for GitOps
- [k3s local-path-provisioner](https://github.com/rancher/local-path-provisioner) — StorageClass details

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

## Lab

```bash
# ── Prerequisites ──────────────────────────────────────────────────────────
# k3s running, kubectl configured, kompose installed

# Install kompose if not already present
curl -L https://github.com/kubernetes/kompose/releases/latest/download/kompose-linux-amd64 \
  -o /usr/local/bin/kompose && chmod +x /usr/local/bin/kompose

# Install yq for anchor flattening
curl -L https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 \
  -o /usr/local/bin/yq && chmod +x /usr/local/bin/yq

# ── Part 1: Run the Compose app with podman-compose ────────────────────────
podman-compose -f labs/podman-compose-example.yml up -d
podman-compose -f labs/podman-compose-example.yml ps
podman-compose -f labs/podman-compose-example.yml down

# ── Part 2: Auto-convert with kompose ─────────────────────────────────────
yq eval 'explode(.)' labs/podman-compose-example.yml > /tmp/flat.yml
mkdir -p /tmp/kompose-out
kompose convert -f /tmp/flat.yml --out /tmp/kompose-out/
echo "=== kompose output ===" && ls /tmp/kompose-out/

# ── Part 3: Apply the hand-crafted production manifest ─────────────────────
# Review the manifest before applying
less labs/compose-to-k3s.yaml

# Create the pull secret (update values for your registry)
# kubectl create secret docker-registry ghcr-creds \
#   --docker-server=ghcr.io \
#   --docker-username=myorg \
#   --docker-password=<PAT> \
#   -n taskr

kubectl apply -f labs/compose-to-k3s.yaml
kubectl get all -n taskr

# Wait for all pods to be ready
kubectl wait --for=condition=Ready pod -l app.kubernetes.io/part-of=taskr \
  -n taskr --timeout=120s

# ── Part 4: Validate DNS resolution ───────────────────────────────────────
kubectl exec -n taskr deploy/web -- nslookup postgres
kubectl exec -n taskr deploy/web -- nslookup redis

# ── Part 5: Kustomize multi-environment ───────────────────────────────────
# Create a minimal kustomize layout
mkdir -p /tmp/kustomize-demo/base /tmp/kustomize-demo/overlays/dev

kubectl kustomize labs/ 2>/dev/null || echo "No kustomization.yaml in labs/ — see lesson for full example"

# ── Part 6: Test RollingUpdate ────────────────────────────────────────────
# Watch the rollout in real time (open a second terminal)
# kubectl rollout status deployment/web -n taskr -w

# Trigger an image update (simulated with same tag — will update env)
kubectl set env deployment/web -n taskr DEBUG=true
kubectl rollout status deployment/web -n taskr

# Undo the rollout
kubectl rollout undo deployment/web -n taskr
kubectl rollout history deployment/web -n taskr

# ── Part 7: HPA in action ──────────────────────────────────────────────────
kubectl apply -f - <<'EOF'
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: web-hpa
  namespace: taskr
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: web
  minReplicas: 2
  maxReplicas: 5
  metrics:
  - type: Resource
    resource:
      name: cpu
      target:
        type: Utilization
        averageUtilization: 70
EOF

kubectl get hpa -n taskr

# ── Cleanup ───────────────────────────────────────────────────────────────
kubectl delete namespace taskr
```

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---
*Licensed under [CC BY-NC-SA 4.0](../LICENSE.md) · © 2026 UncleJS*
