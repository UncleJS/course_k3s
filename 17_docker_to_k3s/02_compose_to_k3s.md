# Translating Docker Compose to Kubernetes Manifests
> Module 17 · Lesson 02 | [↑ Course Index](../README.md)


[![Course Index](https://img.shields.io/badge/Course-Index-0f766e)](../README.md)
[![License: CC BY-NC-SA 4.0](https://img.shields.io/badge/License-CC%20BY--NC--SA%204.0-lightgrey)](../LICENSE.md)

## Table of Contents
- [Overview](#overview)
- [A Typical Docker Compose App](#a-typical-docker-compose-app)
- [Docker Compose Syntax Differences from Podman Compose](#docker-compose-syntax-differences-from-podman-compose)
- [Translating the build: Key](#translating-the-build-key)
- [Step 1: Services → Deployments and StatefulSets](#step-1-services--deployments-and-statefulsets)
- [Step 2: Port Mappings → Services and Ingress](#step-2-port-mappings--services-and-ingress)
- [Step 3: Volumes → PersistentVolumeClaims](#step-3-volumes--persistentvolumeclaims)
- [Docker secrets: → Kubernetes Secrets](#docker-secrets--kubernetes-secrets)
- [configs: → ConfigMap](#configs--configmap)
- [Step 4: Environment Variables](#step-4-environment-variables)
- [Step 5: Health Checks → Probes](#step-5-health-checks--probes)
- [Step 6: depends_on → Init Containers](#step-6-depends_on--init-containers)
- [extends: and YAML Anchors → Kustomize](#extends-and-yaml-anchors--kustomize)
- [profiles: → Kustomize Overlays](#profiles--kustomize-overlays)
- [Kompose for Docker Compose](#kompose-for-docker-compose)
- [Complete Before and After Example](#complete-before-and-after-example)
- [Common Pitfalls](#common-pitfalls)
- [Further Reading](#further-reading)
- [Lab](#lab)

---

## Overview

This lesson translates a realistic Docker Compose file (web app + PostgreSQL + Redis) piece-by-piece into Kubernetes manifests. We cover Docker-specific fields that have no Podman equivalent (`build:`, `profiles:`, `secrets:`, `configs:`, Swarm `deploy:`) and show how they map to k3s primitives. Cross-references to Module 16 Lesson 02 point out what is identical between Docker and Podman Compose translations.

> **If you have already read Module 16 Lesson 02**, many translation steps are the same. This lesson focuses on **Docker-specific** fields and the Docker toolchain (Buildx, Docker Hub, Kompose with Docker Compose input). Skip to the Docker-specific sections if you want the deltas only.

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

## A Typical Docker Compose App

The "Taskr" app — a three-tier task management application — used throughout Module 17. The same app is used in Module 16 (Podman path) for cross-reference.

```yaml
# docker-compose.yml (BEFORE)
version: "3.9"

services:
  web:
    build:
      context: ./taskr-web
      dockerfile: Dockerfile
      args:
        NODE_VERSION: "20"
    image: ghcr.io/myorg/taskr-web:2.1.0    # tag for push
    ports:
      - "3000:3000"
    environment:
      NODE_ENV: production
      PORT: "3000"
    env_file:
      - .env.production                       # Docker-specific: env_file
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
      start_period: 20s
    deploy:                                    # Swarm-only — ignored by Compose v2
      replicas: 2
      resources:
        limits:
          cpus: "0.5"
          memory: 512M
        reservations:
          cpus: "0.1"
          memory: 128M
    secrets:
      - db_password
      - session_secret
    profiles:
      - production

  db:
    image: postgres:15-alpine
    environment:
      POSTGRES_DB: taskr
      POSTGRES_USER: taskr
    secrets:
      - db_password
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

  db-admin:
    image: adminer
    ports:
      - "8080:8080"
    profiles:
      - dev                                    # only starts in dev profile

volumes:
  pgdata:
  redisdata:

secrets:
  db_password:
    external: true                             # managed outside compose
  session_secret:
    external: true

configs:
  nginx_config:
    file: ./nginx/nginx.conf
```

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

## Docker Compose Syntax Differences from Podman Compose

Before translating, note Docker-specific fields and their behaviour:

| Docker Compose field | Podman Compose support | k8s equivalent |
|---|---|---|
| `build: context: / dockerfile:` | Supported | Build and push separately — not in manifests |
| `build: args:` | Supported | `--build-arg` at build time — not in manifests |
| `env_file:` | Supported | `envFrom: secretRef / configMapRef` |
| `secrets:` (top-level) | Partial | `kind: Secret` |
| `configs:` (top-level) | Partial | `kind: ConfigMap` |
| `deploy:` (Swarm) | Ignored by Compose v2 | `resources:`, `replicas:`, `strategy:` |
| `profiles:` | Supported | Kustomize overlays |
| `extends:` | Docker Compose v2+ | Kustomize patches |
| `x-*` extensions | Both support | Ignored by k8s |
| `<<: *anchor` YAML merges | Both support | Must flatten before kompose |

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

## Translating the build: Key

The `build:` key in Docker Compose is entirely a build-time instruction. Kubernetes manifests only reference images by tag — they never build images.

```yaml
# Docker Compose
services:
  web:
    build:
      context: ./taskr-web
      dockerfile: Dockerfile
      args:
        NODE_VERSION: "20"
    image: ghcr.io/myorg/taskr-web:2.1.0
```

**Migration steps:**

```bash
# Step 1: Build the image (outside the cluster)
docker buildx build \
  --build-arg NODE_VERSION=20 \
  --tag ghcr.io/myorg/taskr-web:2.1.0 \
  ./taskr-web/

# Step 2: Push to registry
docker push ghcr.io/myorg/taskr-web:2.1.0

# Step 3: Reference in the Deployment (build: key removed)
```

```yaml
# Kubernetes Deployment — no build: key
containers:
- name: web
  image: ghcr.io/myorg/taskr-web:2.1.0    # only the pushed tag
  imagePullPolicy: IfNotPresent
```

> **CI/CD pattern:** Add `docker buildx build && docker push` as a pipeline step before `kubectl apply`. The manifest always references the already-built, already-pushed image.

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

## Step 1: Services → Deployments and StatefulSets

Identical to Module 16 Lesson 02 — each service becomes a Deployment (stateless) or StatefulSet (stateful). The only Docker-specific difference is the `deploy:` block:

```yaml
# Docker Compose — Swarm deploy: block
services:
  web:
    deploy:
      replicas: 2
      resources:
        limits:
          cpus: "0.5"
          memory: 512M
        reservations:
          cpus: "0.1"
          memory: 128M
      update_config:
        parallelism: 1
        delay: 10s
      restart_policy:
        condition: on-failure
```

```yaml
# Kubernetes Deployment — translates all Swarm deploy: fields
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
  namespace: taskr
spec:
  replicas: 2                        # ← deploy.replicas
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: 0              # ← update_config.parallelism=1 → maxUnavailable=0
      maxSurge: 1
  template:
    spec:
      containers:
      - name: web
        image: ghcr.io/myorg/taskr-web:2.1.0
        resources:
          limits:
            cpu: "500m"              # ← deploy.resources.limits.cpus = "0.5"
            memory: "512Mi"          # ← deploy.resources.limits.memory
          requests:
            cpu: "100m"              # ← deploy.resources.reservations.cpus
            memory: "128Mi"
```

> **Kubernetes ignores `deploy:` entirely** when used with `docker-compose up`. It is a Swarm-only field. Kompose reads it and partially translates it — always verify the output.

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

## Step 2: Port Mappings → Services and Ingress

See Module 16 Lesson 02 for the full translation. Docker-specific note: Docker Compose `ports:` with `published` / `target` long-form syntax:

```yaml
# Docker Compose long-form
ports:
  - target: 3000
    published: 3000
    protocol: tcp
    mode: ingress      # Swarm-specific — ignored in single-host Compose

# Kubernetes Service — same result
spec:
  ports:
  - port: 3000
    targetPort: 3000
    protocol: TCP
```

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

## Step 3: Volumes → PersistentVolumeClaims

See Module 16 Lesson 02 for the full translation. Docker-specific note: Docker volumes with `driver_opts` (e.g., NFS):

```yaml
# Docker Compose — NFS volume
volumes:
  shared-data:
    driver: local
    driver_opts:
      type: nfs
      o: addr=nas.example.com,rw
      device: ":/exports/taskr"
```

```yaml
# Kubernetes — NFS PersistentVolume + PVC
apiVersion: v1
kind: PersistentVolume
metadata:
  name: shared-data-nfs
spec:
  capacity:
    storage: 50Gi
  accessModes: [ReadWriteMany]      # NFS supports multiple readers
  nfs:
    server: nas.example.com
    path: /exports/taskr
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: shared-data
  namespace: taskr
spec:
  accessModes: [ReadWriteMany]
  resources:
    requests:
      storage: 50Gi
  volumeName: shared-data-nfs
```

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

## Docker secrets: → Kubernetes Secrets

Docker Compose `secrets:` mounts files at `/run/secrets/<name>` inside the container. Kubernetes Secrets can be mounted as files or injected as env vars.

```yaml
# Docker Compose
secrets:
  db_password:
    external: true    # managed by Docker Swarm secret store
  session_secret:
    external: true

services:
  web:
    secrets:
      - db_password        # mounted as /run/secrets/db_password
      - session_secret     # mounted as /run/secrets/session_secret
```

**Option A: Kubernetes Secret as mounted files** (closest to Docker secrets):
```yaml
# Create the Secret
apiVersion: v1
kind: Secret
metadata:
  name: taskr-secrets
  namespace: taskr
type: Opaque
stringData:
  db_password: "secretpassword"
  session_secret: "my-super-secret"
---
# Mount as files in the pod (exactly like Docker secrets)
volumes:
- name: taskr-secrets
  secret:
    secretName: taskr-secrets

containers:
- name: web
  volumeMounts:
  - name: taskr-secrets
    mountPath: /run/secrets    # same path as Docker secrets
    readOnly: true
```

**Option B: Kubernetes Secret as environment variables** (more common in k8s):
```yaml
env:
- name: DB_PASSWORD
  valueFrom:
    secretKeyRef:
      name: taskr-secrets
      key: db_password
- name: SESSION_SECRET
  valueFrom:
    secretKeyRef:
      name: taskr-secrets
      key: session_secret
```

> **Which option to choose:** If your application reads `/run/secrets/db_password` as a file (common pattern in Docker Swarm apps), use Option A. If it reads `$DB_PASSWORD` as an environment variable (more common), use Option B. Either way, never hardcode values in the manifest.

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

## configs: → ConfigMap

Docker Compose `configs:` mounts configuration files. They map directly to `ConfigMap`:

```yaml
# Docker Compose
configs:
  nginx_config:
    file: ./nginx/nginx.conf

services:
  proxy:
    image: nginx:1.25-alpine
    configs:
      - source: nginx_config
        target: /etc/nginx/nginx.conf
```

```yaml
# Kubernetes ConfigMap
apiVersion: v1
kind: ConfigMap
metadata:
  name: nginx-config
  namespace: taskr
data:
  nginx.conf: |
    worker_processes 1;
    events { worker_connections 1024; }
    http {
      server {
        listen 80;
        location / {
          proxy_pass http://web:3000;
        }
      }
    }
---
# Mount in pod
volumes:
- name: nginx-config
  configMap:
    name: nginx-config

containers:
- name: proxy
  image: nginx:1.25-alpine
  volumeMounts:
  - name: nginx-config
    mountPath: /etc/nginx/nginx.conf
    subPath: nginx.conf    # mount just this file, not the whole directory
```

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

## Step 4: Environment Variables

Docker Compose `env_file:` is common for loading `.env` files. The k3s equivalent uses `envFrom`:

```yaml
# Docker Compose
services:
  web:
    environment:
      NODE_ENV: production
    env_file:
      - .env.production      # loads all KEY=VALUE pairs from file
```

```yaml
# Kubernetes — inline env for non-sensitive, ConfigMap for many vars
# Create ConfigMap from the .env file:
kubectl create configmap web-config \
  --from-env-file=.env.production \
  -n taskr

# Or declaratively:
apiVersion: v1
kind: ConfigMap
metadata:
  name: web-config
  namespace: taskr
data:
  NODE_ENV: production
  LOG_LEVEL: info
  ALLOWED_ORIGINS: "https://taskr.example.com"
---
# Inject all keys as env vars
envFrom:
- configMapRef:
    name: web-config
```

> **Separation rule:** Non-sensitive vars go in `ConfigMap`. Sensitive vars (`DB_PASSWORD`, `SESSION_SECRET`, tokens) go in `Secret`. Never mix them in the same object.

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

## Step 5: Health Checks → Probes

Docker Compose `healthcheck:` has a `start_period:` field that Kubernetes maps to `startupProbe`:

```yaml
# Docker Compose
healthcheck:
  test: ["CMD", "curl", "-f", "http://localhost:3000/healthz"]
  interval: 30s
  timeout: 5s
  retries: 3
  start_period: 20s     # Docker-specific: wait before starting checks
```

```yaml
# Kubernetes — three-probe equivalent
startupProbe:           # replaces start_period — allows slow start
  httpGet:
    path: /healthz
    port: 3000
  failureThreshold: 6   # 6 × 10s = 60s to start (more than start_period=20s)
  periodSeconds: 10

readinessProbe:
  httpGet:
    path: /healthz
    port: 3000
  initialDelaySeconds: 5
  periodSeconds: 10
  timeoutSeconds: 5
  failureThreshold: 3

livenessProbe:
  httpGet:
    path: /healthz
    port: 3000
  initialDelaySeconds: 30
  periodSeconds: 30
  timeoutSeconds: 5
  failureThreshold: 3
```

See Module 16 Lesson 02 for the full probe reference.

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

## Step 6: depends_on → Init Containers

Identical to Module 16 Lesson 02. Docker `depends_on` with `condition: service_healthy` maps to init containers that wait for the dependency:

```yaml
# Docker Compose
depends_on:
  db:
    condition: service_healthy    # wait for healthcheck to pass

# Kubernetes
initContainers:
- name: wait-for-postgres
  image: busybox:1.36
  command: ['sh', '-c', 'until nc -z postgres 5432; do sleep 2; done']
```

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

## extends: and YAML Anchors → Kustomize

Docker Compose `extends:` lets services inherit from a base definition. YAML anchors (`&anchor` / `*anchor`) avoid repetition. Both patterns become **Kustomize patches**:

```yaml
# Docker Compose with extends:
# base.yaml
services:
  _app-base: &app-base
    image: ghcr.io/myorg/taskr-web:2.1.0
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:3000/healthz"]
      interval: 30s

# docker-compose.yml
services:
  web:
    <<: *app-base
    ports:
      - "3000:3000"
    environment:
      NODE_ENV: production
```

```yaml
# Kustomize equivalent — base + overlay patch
# base/deployment.yaml — shared definition
# overlays/production/patch-env.yaml — environment-specific override

# overlays/production/patch-env.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
spec:
  template:
    spec:
      containers:
      - name: web
        env:
        - name: NODE_ENV
          value: production
```

```bash
# Flatten YAML anchors before using kompose
yq eval 'explode(.)' docker-compose.yml > docker-compose-flat.yml
kompose convert -f docker-compose-flat.yml --out ./k8s/
```

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

## profiles: → Kustomize Overlays

Docker Compose `profiles:` lets you activate services selectively (`docker-compose --profile dev up`). Kustomize overlays are the direct replacement:

| Docker Compose profile | Kustomize equivalent |
|---|---|
| `docker-compose up` (no profile) | `kubectl apply -k overlays/base` |
| `docker-compose --profile dev up` | `kubectl apply -k overlays/dev` |
| `docker-compose --profile production up` | `kubectl apply -k overlays/production` |
| Service with `profiles: [dev]` only | Only in `overlays/dev/kustomization.yaml resources:` |

```yaml
# Docker Compose profile example
services:
  web:
    image: ghcr.io/myorg/taskr-web:2.1.0
    profiles:
      - production
      - staging

  db-admin:
    image: adminer
    ports:
      - "8080:8080"
    profiles:
      - dev           # only starts in dev

  db:
    image: postgres:15-alpine
    # No profiles = always included
```

```yaml
# overlays/dev/kustomization.yaml — dev overlay includes db-admin
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: taskr-dev
resources:
- ../../base
- db-admin-deployment.yaml      # extra resource only in dev
patches:
- path: patch-replicas-1.yaml   # dev uses 1 replica
```

```yaml
# overlays/production/kustomization.yaml — no db-admin
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: taskr
resources:
- ../../base
- hpa.yaml                      # HPA only in production
patches:
- path: patch-replicas-2.yaml
- path: patch-resources-prod.yaml
```

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

## Kompose for Docker Compose

Kompose works with Docker Compose files natively. Key Docker-specific kompose behaviours:

```bash
# Install kompose
curl -L https://github.com/kubernetes/kompose/releases/latest/download/kompose-linux-amd64 \
  -o /usr/local/bin/kompose && chmod +x /usr/local/bin/kompose

# Flatten anchors first
yq eval 'explode(.)' docker-compose.yml > flat.yml

# Convert
kompose convert -f flat.yml --out ./k8s/

# Convert with Helm chart output
kompose convert -f flat.yml --chart --out ./charts/taskr/
```

**Docker-specific kompose handling:**

| Docker Compose field | Kompose translation | Manual fix needed? |
|---|---|---|
| `build:` | Ignored — assumes image already pushed | Set `image:` tag before converting |
| `secrets:` | Creates Kubernetes Secret stubs | Fill in actual values |
| `configs:` | Creates ConfigMap stubs | Fill in config file content |
| `deploy.resources:` | Translates to `resources:` in pod spec | Verify CPU/memory format |
| `deploy.replicas:` | Sets `spec.replicas` | Correct |
| `profiles:` | Ignored — all services converted | Remove dev-only services manually |
| `env_file:` | Creates a ConfigMap per env_file | Move sensitive vars to Secret |
| `x-*` extension keys | Ignored | Remove from output |

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

## Complete Before and After Example

See the lab file [`labs/docker-compose-to-k3s.yaml`](labs/docker-compose-to-k3s.yaml) for the complete k3s manifest translation of the Taskr Docker Compose app, including:

- Namespace
- Secrets (SealedSecrets-ready)
- ConfigMap (from `configs:`)
- PVCs for all named volumes
- PostgreSQL StatefulSet with headless Service
- Redis Deployment with Recreate strategy
- Web Deployment with RollingUpdate, init containers, and probes
- ClusterIP Services for all components
- Traefik IngressRoute for HTTPS

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

## Common Pitfalls

| Issue | Symptom | Fix |
|---|---|---|
| `build:` key in manifest | `kompose` generates broken Job | Build and push image first; remove `build:` key |
| `secrets:` mounted as files, app reads env vars | Env var missing in container | Mount secrets as env vars instead of volume files |
| `deploy:` block silently ignored | Resources not applied in k3s | Translate `deploy.resources` to pod `resources:` manually |
| `profiles:` services all deployed | Dev tools (adminer) running in production | Use Kustomize overlays to include dev-only services |
| `env_file:` includes sensitive vars in ConfigMap | Secrets visible in `kubectl describe cm` | Separate sensitive vars into `Secret` |
| YAML anchor `*base` not expanded | Kompose parse error | Run `yq eval 'explode(.)' docker-compose.yml` first |
| Docker Hub rate limits on pulls | `ImagePullBackOff: too many requests` | Set `imagePullSecrets` with Docker Hub credentials |
| `mode: ingress` in ports | Kompose generates wrong Service type | Replace with `type: ClusterIP` + Ingress |
| `configs:` subPath mount | File replaced by directory mount | Use `subPath: filename` in volumeMount |

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

## Further Reading

- [Kompose documentation](https://kompose.io/user-guide/) — Docker Compose conversion
- [Kustomize reference](https://kubectl.docs.kubernetes.io/references/kustomize/) — overlays, profiles
- [Docker Compose file reference](https://docs.docker.com/compose/compose-file/) — secrets, configs, deploy
- [Kubernetes Secrets](https://kubernetes.io/docs/concepts/configuration/secret/) — types and usage
- [ConfigMaps](https://kubernetes.io/docs/concepts/configuration/configmap/) — file and env injection
- Module 16 Lesson 02 — Podman Compose translation (identical for most fields)

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

## Lab

```bash
# ── Prerequisites ──────────────────────────────────────────────────────────
# k3s running, kubectl configured, kompose + yq installed

# Install kompose
curl -L https://github.com/kubernetes/kompose/releases/latest/download/kompose-linux-amd64 \
  -o /usr/local/bin/kompose && chmod +x /usr/local/bin/kompose

# Install yq
curl -L https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 \
  -o /usr/local/bin/yq && chmod +x /usr/local/bin/yq

# ── Part 1: Inspect the Docker Compose example ─────────────────────────────
cat labs/docker-compose-example.yml

# ── Part 2: Flatten anchors and convert with kompose ──────────────────────
yq eval 'explode(.)' labs/docker-compose-example.yml > /tmp/flat.yml
mkdir -p /tmp/kompose-out
kompose convert -f /tmp/flat.yml --out /tmp/kompose-out/
echo "=== Kompose output ===" && ls /tmp/kompose-out/

# Spot the problems in kompose output:
# - Uses Deployment for postgres (should be StatefulSet)
# - Creates NodePort for all services (should be ClusterIP + Ingress)
# - No imagePullSecrets
# - secrets: generates empty Secret stubs

# ── Part 3: Apply the hand-crafted production manifest ─────────────────────
less labs/docker-compose-to-k3s.yaml

kubectl apply -f labs/docker-compose-to-k3s.yaml
kubectl get all -n taskr

# Wait for all pods to be ready
kubectl wait --for=condition=Ready pod -l app.kubernetes.io/part-of=taskr \
  -n taskr --timeout=120s

# ── Part 4: Verify Docker secrets → k8s Secret file mounts ───────────────
# Check that secret files are mounted correctly
kubectl exec -n taskr deploy/web -- ls /run/secrets/ 2>/dev/null || \
  echo "Secret is env-based — check env vars instead"
kubectl exec -n taskr deploy/web -- printenv | grep -E "DB_|SESSION_" | sed 's/=.*/=***/'

# ── Part 5: Test profiles → Kustomize overlay ────────────────────────────
# Dev overlay: adds adminer (db-admin), reduces replicas
mkdir -p /tmp/kustomize-taskr/base
kubectl get deployment web -n taskr -o yaml > /tmp/kustomize-taskr/base/deployment.yaml

cat > /tmp/kustomize-taskr/base/kustomization.yaml <<'EOF'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
- deployment.yaml
EOF

kubectl kustomize /tmp/kustomize-taskr/base

# ── Cleanup ───────────────────────────────────────────────────────────────
kubectl delete namespace taskr
```

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---
*Licensed under [CC BY-NC-SA 4.0](../LICENSE.md) · © 2026 UncleJS*
