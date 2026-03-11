# Full Migration Walkthrough: Podman to k3s
> Module 16 · Lesson 04 | [↑ Course Index](../README.md)


[![Course Index](https://img.shields.io/badge/Course-Index-0f766e)](../README.md)
[![License: CC BY-NC-SA 4.0](https://img.shields.io/badge/License-CC%20BY--NC--SA%204.0-lightgrey)](../LICENSE.md)

## Table of Contents
- [Phase 1: Assess Your Existing Podman Setup](#phase-1-assess-your-existing-podman-setup)
- [Quadlet-to-Manifest Conversion Script](#quadlet-to-manifest-conversion-script)
- [Phase 2: Build and Push Images to a Registry](#phase-2-build-and-push-images-to-a-registry)
- [Phase 3: Write Kubernetes Manifests](#phase-3-write-kubernetes-manifests)
- [Systemd Unit → Kubernetes Job Pattern](#systemd-unit--kubernetes-job-pattern)
- [Database Migration Jobs](#database-migration-jobs)
- [NetworkPolicy Translation](#networkpolicy-translation)
- [Phase 5: Data Migration](#phase-5-data-migration)
- [Phase 6: Cutover](#phase-6-cutover)
- [Canary Deployment Pattern](#canary-deployment-pattern)
- [Phase 7: Post-Migration Validation](#phase-7-post-migration-validation)
- [Post-Migration Runbook Template](#post-migration-runbook-template)
- [Further Reading](#further-reading)
- [Lab](#lab)

---

## Overview
```mermaid
flowchart LR
    P1[Phase 1 Assess] --> P2[Phase 2 Build & Push]
    P2 --> P3[Phase 3 Write Manifests]
    P6 --> P7[Phase 7 Validate]
    P6 -.->|if issues| RB[Rollback]
    RB -.-> P1
```

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---
Throughout this lesson we migrate **"Taskr"** — a task-management web app with:

| Component | Technology | Podman setup |
|---|---|---|
| Reverse proxy | Caddy 2 | `podman run` on port 443 |
| Data volume | `taskr_pgdata` / `taskr_redis` | Podman named volumes |


## Pre-Migration Checklist

Run through this checklist **before** starting any migration work:
[ ] kubectl context is pointing at the correct cluster
[ ] A container registry is accessible (Docker Hub, GHCR, or local)
[ ] Podman is installed on the build host
[ ] You have a tested backup of all Podman volumes
[ ] You know the current DNS name / IP address used to reach the app
[ ] Monitoring / alerting is in place for the new cluster
[ ] A rollback procedure is documented and tested
```

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

## Phase 1: Assess Your Existing Podman Setup

### 1.1 List Running Containers and Their Configuration

```bash
# List all running containers with their full details
podman ps --format "table {{.Names}}\t{{.Image}}\t{{.Ports}}\t{{.Status}}"

# Inspect each container — capture environment vars, mounts, ports
for cname in $(podman ps --format "{{.Names}}"); do
  echo "=== $cname ==="
  podman inspect $cname \
    --format 'Image: {{.Config.Image}}
Env: {{.Config.Env}}
Ports: {{.NetworkSettings.Ports}}
Mounts: {{range .Mounts}}{{.Source}}->{{.Destination}} {{end}}
RestartPolicy: {{.HostConfig.RestartPolicy.Name}}'
  echo
done
```

### 1.2 List and Back Up Named Volumes

```bash
# List all named volumes
podman volume ls

# Inspect a volume to find its mount point
podman volume inspect taskr_pgdata
# Output includes "Mountpoint": "/home/user/.local/share/containers/storage/volumes/taskr_pgdata/_data"

# Back up each volume
podman run --rm \
  -v taskr_pgdata:/data:ro \
  -v /backup:/backup \
  docker.io/library/alpine:3.19 \
  tar czf /backup/taskr_pgdata_$(date +%Y%m%d).tar.gz -C /data .

podman run --rm \
  -v taskr_redis:/data:ro \
  -v /backup:/backup \
  docker.io/library/alpine:3.19 \
  tar czf /backup/taskr_redis_$(date +%Y%m%d).tar.gz -C /data .

ls -lh /backup/
```

### 1.3 Capture Environment Variables

```bash
# Dump all env vars for each container to a file
podman inspect taskr-web --format '{{range .Config.Env}}{{println .}}{{end}}' \
  | sort > /tmp/taskr-web-env.txt

podman inspect taskr-postgres --format '{{range .Config.Env}}{{println .}}{{end}}' \
  | sort > /tmp/taskr-postgres-env.txt

cat /tmp/taskr-web-env.txt
# DATABASE_URL=postgres://taskr:secretpassword@localhost:5432/taskr
# REDIS_URL=redis://localhost:6379
# NODE_ENV=production
# PORT=3000
# SESSION_SECRET=my-super-secret
```

### 1.4 List Custom Networks

```bash
podman network ls
podman network inspect taskr-net
# Note the subnet, gateway, and which containers are connected
```

### 1.5 Inventory Summary

Create a written inventory — you will reference this in Phase 3:

```
Application: Taskr

CONTAINERS:
  taskr-web
    image: myorg/taskr-web:2.1.0   (CUSTOM — needs registry push)
    ports: 3000/tcp
    env: DATABASE_URL, REDIS_URL, NODE_ENV, PORT, SESSION_SECRET
    depends on: taskr-postgres, taskr-redis

  taskr-postgres
    image: docker.io/library/postgres:15-alpine  (PUBLIC)
    ports: 5432/tcp (internal only)
    env: POSTGRES_USER, POSTGRES_PASSWORD, POSTGRES_DB
    volumes: taskr_pgdata -> /var/lib/postgresql/data

  taskr-redis
    image: docker.io/library/redis:7-alpine  (PUBLIC)
    ports: 6379/tcp (internal only)
    volumes: taskr_redis -> /data

  caddy
    image: docker.io/library/caddy:2  (PUBLIC — REPLACING with Traefik IngressRoute)
    ports: 80/tcp, 443/tcp

VOLUMES:
  taskr_pgdata   → will become a PVC (10 Gi)
  taskr_redis    → will become a PVC (1 Gi)

NETWORKS:
  taskr-net (bridge, 10.89.0.0/24) → replaced by k8s cluster DNS
```

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

## Quadlet-to-Manifest Conversion Script

If you are running containers via **Quadlet** (systemd `.container` files), this script extracts the key fields and maps them to Kubernetes manifest stubs. It is not a full converter — treat its output as a starting point.

```bash
#!/usr/bin/env bash
# quadlet-to-manifest.sh
# Usage: ./quadlet-to-manifest.sh taskr-web.container
#
# Reads a Quadlet .container file and prints a rough Kubernetes Deployment stub.

QUADLET_FILE="${1:?Usage: $0 <file.container>}"
NAME=$(basename "$QUADLET_FILE" .container)

# Extract fields
IMAGE=$(grep -i '^Image=' "$QUADLET_FILE" | cut -d= -f2-)
ENVS=$(grep -i '^Environment=' "$QUADLET_FILE")
PORTS=$(grep -i '^PublishPort=' "$QUADLET_FILE")
VOLUMES=$(grep -i '^Volume=' "$QUADLET_FILE")

echo "# === Deployment stub for: $NAME ==="
cat <<YAML
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${NAME}
  namespace: FIXME
spec:
  replicas: 1
  selector:
    matchLabels:
      app: ${NAME}
  template:
    metadata:
      labels:
        app: ${NAME}
    spec:
      containers:
      - name: ${NAME}
        image: ${IMAGE}
        # TODO: add env, ports, volumeMounts from your Quadlet below
        # --- Quadlet Environment lines ---
$(echo "$ENVS" | sed 's/Environment=/        # env: /')
        # --- Quadlet PublishPort lines ---
$(echo "$PORTS" | sed 's/PublishPort=/        # port: /')
        # --- Quadlet Volume lines ---
$(echo "$VOLUMES" | sed 's/Volume=/        # volumeMount: /')
YAML
echo ""
echo "# NEXT STEPS:"
echo "#   1. Replace 'FIXME' namespace"
echo "#   2. Convert env= lines to env: - name: / value: or secretKeyRef:"
echo "#   3. Convert volume= lines to volumeMounts: + PVC"
echo "#   4. Add resource limits, probes, imagePullSecrets"
```

**Example Quadlet file and its manifest output:**

```ini
# taskr-web.container (Quadlet)
[Container]
Image=ghcr.io/myorg/taskr-web:2.1.0
PublishPort=3000:3000
Environment=NODE_ENV=production
Environment=PORT=3000
Environment=DATABASE_URL=postgres://taskr:secret@localhost:5432/taskr
Volume=taskr-uploads:/app/uploads
```

```bash
./quadlet-to-manifest.sh taskr-web.container
```

Produces a stub Deployment you then refine — replacing `localhost` hostnames with k8s service DNS names, moving secrets into `Secret` objects, and converting `Volume=` to `PVC` + `volumeMounts`.

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

## Phase 2: Build and Push Images to a Registry

Only **custom images** need to be pushed. Public images (postgres, redis, caddy) are pulled directly from Docker Hub.

```bash
# Set your registry and org
REGISTRY="ghcr.io"
ORG="myorg"
TAG="2.1.0"

# Build the custom web image
podman build \
  -t ${REGISTRY}/${ORG}/taskr-web:${TAG} \
  -f Containerfile \
  ./taskr-web/

# Log in to GHCR
echo $GITHUB_PAT | podman login ghcr.io -u ${ORG} --password-stdin

# Push
podman push ${REGISTRY}/${ORG}/taskr-web:${TAG}

# Also push a 'latest' tag
podman tag ${REGISTRY}/${ORG}/taskr-web:${TAG} ${REGISTRY}/${ORG}/taskr-web:latest
podman push ${REGISTRY}/${ORG}/taskr-web:latest

echo "Image available at: ${REGISTRY}/${ORG}/taskr-web:${TAG}"
```

> **Always push a specific version tag, never rely on `latest` in production manifests.**

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

## Phase 3: Write Kubernetes Manifests

Based on the inventory from Phase 1, write the full set of manifests. See the `labs/` directory for the complete files. Here is the structure we create:

```
taskr/
├── namespace.yaml
├── secrets.yaml
├── postgres-pvc.yaml
├── redis-pvc.yaml
├── postgres-statefulset.yaml
├── redis-deployment.yaml
├── web-deployment.yaml
├── services.yaml
└── ingressroute.yaml
```

### Namespace

```yaml
# namespace.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: taskr
  labels:
    app.kubernetes.io/part-of: taskr
```

### Secrets

```yaml
# secrets.yaml  (in production: use SealedSecrets or External Secrets Operator)
apiVersion: v1
kind: Secret
metadata:
  name: taskr-secrets
  namespace: taskr
type: Opaque
stringData:
  postgres-user: taskr
  postgres-password: "secretpassword"
  postgres-db: taskr
  session-secret: "my-super-secret"
  database-url: "postgres://taskr:secretpassword@postgres:5432/taskr"
  redis-url: "redis://redis:6379"
```

> **Never commit secrets as plain text.** Use `kubectl create secret` or a secrets management solution. The above is for illustration only.

### PersistentVolumeClaims

```yaml
# postgres-pvc.yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: postgres-data
  namespace: taskr
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: local-path    # k3s default
  resources:
    requests:
      storage: 10Gi
---
# redis-pvc.yaml
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
```

### PostgreSQL StatefulSet

Using a StatefulSet for the database gives stable network identity and ordered pod management:

```yaml
# postgres-statefulset.yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: postgres
  namespace: taskr
spec:
  serviceName: postgres
  replicas: 1
  selector:
    matchLabels:
      app: postgres
  template:
    metadata:
      labels:
        app: postgres
    spec:
      containers:
        - name: postgres
          image: docker.io/library/postgres:15-alpine
          ports:
            - containerPort: 5432
          env:
            - name: POSTGRES_USER
              valueFrom:
                secretKeyRef:
                  name: taskr-secrets
                  key: postgres-user
            - name: POSTGRES_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: taskr-secrets
                  key: postgres-password
            - name: POSTGRES_DB
              valueFrom:
                secretKeyRef:
                  name: taskr-secrets
                  key: postgres-db
            - name: PGDATA
              value: /var/lib/postgresql/data/pgdata
          volumeMounts:
            - name: postgres-data
              mountPath: /var/lib/postgresql/data
          readinessProbe:
            exec:
              command: ["pg_isready", "-U", "taskr", "-d", "taskr"]
            initialDelaySeconds: 5
            periodSeconds: 5
          livenessProbe:
            exec:
              command: ["pg_isready", "-U", "taskr", "-d", "taskr"]
            initialDelaySeconds: 30
            periodSeconds: 10
      volumes:
        - name: postgres-data
          persistentVolumeClaim:
            claimName: postgres-data
```

### Redis Deployment

```yaml
# redis-deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: redis
  namespace: taskr
spec:
  replicas: 1
  selector:
    matchLabels:
      app: redis
  template:
    metadata:
      labels:
        app: redis
    spec:
      containers:
        - name: redis
          image: docker.io/library/redis:7-alpine
          command: ["redis-server", "--appendonly", "yes"]
          ports:
            - containerPort: 6379
          volumeMounts:
            - name: redis-data
              mountPath: /data
          readinessProbe:
            exec:
              command: ["redis-cli", "ping"]
            initialDelaySeconds: 5
            periodSeconds: 5
      volumes:
        - name: redis-data
          persistentVolumeClaim:
            claimName: redis-data
```

### Web Deployment

```yaml
# web-deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
  namespace: taskr
spec:
  replicas: 2
  selector:
    matchLabels:
      app: web
  template:
    metadata:
      labels:
        app: web
    spec:
      imagePullSecrets:
        - name: ghcr-creds
      initContainers:
        # Wait for postgres to be ready before starting the web pod
        - name: wait-for-postgres
          image: docker.io/library/busybox:1.36
          command:
            - sh
            - -c
            - |
              until nc -z postgres 5432; do
                echo "Waiting for postgres..."; sleep 2
              done
      containers:
        - name: web
          image: ghcr.io/myorg/taskr-web:2.1.0
          ports:
            - containerPort: 3000
          env:
            - name: NODE_ENV
              value: production
            - name: PORT
              value: "3000"
            - name: DATABASE_URL
              valueFrom:
                secretKeyRef:
                  name: taskr-secrets
                  key: database-url
            - name: REDIS_URL
              valueFrom:
                secretKeyRef:
                  name: taskr-secrets
                  key: redis-url
            - name: SESSION_SECRET
              valueFrom:
                secretKeyRef:
                  name: taskr-secrets
                  key: session-secret
          readinessProbe:
            httpGet:
              path: /healthz
              port: 3000
            initialDelaySeconds: 10
            periodSeconds: 5
          livenessProbe:
            httpGet:
              path: /healthz
              port: 3000
            initialDelaySeconds: 30
            periodSeconds: 10
          resources:
            requests:
              cpu: 100m
              memory: 128Mi
            limits:
              cpu: 500m
              memory: 512Mi
```

### Services

```yaml
# services.yaml
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
  clusterIP: None    # Headless service for StatefulSet
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
---
apiVersion: v1
kind: Service
metadata:
  name: web
  namespace: taskr
spec:
  selector:
    app: web
  ports:
    - port: 80
      targetPort: 3000
```

### IngressRoute (Traefik — replaces Caddy)

```yaml
# ingressroute.yaml
apiVersion: traefik.containo.us/v1alpha1
kind: IngressRoute
metadata:
  name: taskr-web
  namespace: taskr
spec:
  entryPoints:
    - websecure
  routes:
    - match: Host(`taskr.example.com`)
      kind: Rule
      services:
        - name: web
          port: 80
  tls:
    certResolver: letsencrypt
```

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

## Systemd Unit → Kubernetes Job Pattern

Podman workloads often include one-shot systemd units that run tasks like schema creation, seed data loading, or scheduled exports. These translate to Kubernetes `Job` or `CronJob` resources.

```ini
# taskr-schema-init.service (Podman / systemd one-shot unit)
[Unit]
Description=Taskr DB schema init

[Service]
Type=oneshot
ExecStart=podman run --rm \
  -e DATABASE_URL=postgres://taskr:secret@localhost:5432/taskr \
  ghcr.io/myorg/taskr-web:2.1.0 \
  node dist/scripts/migrate.js
```

```yaml
# Kubernetes equivalent — Job (runs once to completion)
apiVersion: batch/v1
kind: Job
metadata:
  name: taskr-schema-init
  namespace: taskr
spec:
  backoffLimit: 3          # retry up to 3 times on failure
  template:
    spec:
      restartPolicy: OnFailure
      initContainers:
      - name: wait-for-postgres
        image: busybox:1.36
        command: ['sh', '-c', 'until nc -z postgres 5432; do sleep 2; done']
      containers:
      - name: migrate
        image: ghcr.io/myorg/taskr-web:2.1.0
        command: ["node", "dist/scripts/migrate.js"]
        env:
        - name: DATABASE_URL
          valueFrom:
            secretKeyRef:
              name: taskr-secrets
              key: database-url
        resources:
          requests:
            cpu: 50m
            memory: 64Mi
          limits:
            cpu: 200m
            memory: 256Mi
```

For a **recurring** systemd timer (e.g., nightly export), use `CronJob`:
```yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: taskr-nightly-export
  namespace: taskr
spec:
  schedule: "0 2 * * *"   # 02:00 UTC daily — same as the systemd OnCalendar=
  concurrencyPolicy: Forbid
  jobTemplate:
    spec:
      template:
        spec:
          restartPolicy: OnFailure
          containers:
          - name: export
            image: ghcr.io/myorg/taskr-web:2.1.0
            command: ["node", "dist/scripts/export.js"]
            env:
            - name: DATABASE_URL
              valueFrom:
                secretKeyRef:
                  name: taskr-secrets
                  key: database-url
```

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

## Database Migration Jobs

Running DB schema migrations in k3s requires care — the migration must complete before the new app version starts serving traffic.

**Pattern: migration Job as an init step in CI/CD**

```mermaid
flowchart LR
    CI[CI/CD pipeline] -->|kubectl apply| MJ[Migration Job]
    MJ -->|kubectl wait --for=condition=complete| DONE{Complete?}
    DONE -->|Yes| APP[Deploy web Deployment]
    DONE -->|No| FAIL[Pipeline fails rollback]
```

```bash
# In your CI/CD pipeline (Gitea Actions / GitHub Actions)
# 1. Apply the migration Job
kubectl apply -f k8s/migration-job.yaml

# 2. Wait for it to complete (timeout 5 min)
kubectl wait job/taskr-schema-init \
  --for=condition=complete \
  --timeout=300s \
  -n taskr

# 3. Only then deploy the app
kubectl apply -f k8s/web-deployment.yaml
kubectl rollout status deployment/web -n taskr
```

**Migration Job with versioned naming** (prevents re-running old migrations):
```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: taskr-migrate-v2-2-0    # versioned — immutable after apply
  namespace: taskr
  annotations:
    app.kubernetes.io/version: "2.2.0"
spec:
  ttlSecondsAfterFinished: 86400    # auto-delete after 24h
  backoffLimit: 2
  template:
    spec:
      restartPolicy: OnFailure
      containers:
      - name: migrate
        image: ghcr.io/myorg/taskr-web:2.2.0
        command: ["node", "dist/scripts/migrate.js", "--to", "2.2.0"]
        env:
        - name: DATABASE_URL
          valueFrom:
            secretKeyRef:
              name: taskr-secrets
              key: database-url
```

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

## NetworkPolicy Translation

Podman's `--network taskr-net` gives isolation between host and the app, but all containers on `taskr-net` can talk freely. Kubernetes default is similarly open — **all pods can reach all services**. Add `NetworkPolicy` to enforce the least-privilege network model.

```mermaid
graph TD
    subgraph taskr namespace
        WEB[web pods] -->|port 5432| PG[postgres]
        WEB -->|port 6379| REDIS[redis]
        ING[Traefik Ingress] -->|port 80| WEB
    end
    EXTERN[External] -->|HTTPS| ING
    PG -->|blocked ✗| REDIS
    REDIS -->|blocked ✗| PG
```

```yaml
# networkpolicy.yaml — replaces Compose's implicit network isolation

# 1. Default: deny all ingress/egress in the namespace
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: taskr
spec:
  podSelector: {}      # applies to ALL pods
  policyTypes:
  - Ingress
  - Egress
---
# 2. Allow web → postgres
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-web-to-postgres
  namespace: taskr
spec:
  podSelector:
    matchLabels:
      app: postgres
  policyTypes: [Ingress]
  ingress:
  - from:
    - podSelector:
        matchLabels:
          app: web
    ports:
    - port: 5432
---
# 3. Allow web → redis
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-web-to-redis
  namespace: taskr
spec:
  podSelector:
    matchLabels:
      app: redis
  policyTypes: [Ingress]
  ingress:
  - from:
    - podSelector:
        matchLabels:
          app: web
    ports:
    - port: 6379
---
# 4. Allow ingress controller → web
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-ingress-to-web
  namespace: taskr
spec:
  podSelector:
    matchLabels:
      app: web
  policyTypes: [Ingress]
  ingress:
  - from:
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: kube-system
    ports:
    - port: 3000
---
# 5. Allow all pods DNS egress (CoreDNS)
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-dns-egress
  namespace: taskr
spec:
  podSelector: {}
  policyTypes: [Egress]
  egress:
  - ports:
    - port: 53
      protocol: UDP
    - port: 53
      protocol: TCP
```

> **Podman equivalent:** Podman's `--network` flag provides host-level isolation. NetworkPolicy provides intra-cluster, pod-level isolation — much more granular.

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

## SealedSecrets Setup

Plain Kubernetes `Secret` objects are base64-encoded, not encrypted — committing them to git is insecure. **SealedSecrets** encrypts secrets with the cluster's public key so only that cluster can decrypt them.

```bash
# ── Install the SealedSecrets controller ─────────────────────────────────
kubectl apply -f https://github.com/bitnami-labs/sealed-secrets/releases/latest/download/controller.yaml

# Wait for controller
kubectl rollout status deployment/sealed-secrets-controller -n kube-system

# ── Install kubeseal CLI ──────────────────────────────────────────────────
curl -L https://github.com/bitnami-labs/sealed-secrets/releases/latest/download/kubeseal-linux-amd64 \
  -o /usr/local/bin/kubeseal && chmod +x /usr/local/bin/kubeseal

# ── Seal a secret ─────────────────────────────────────────────────────────
# Start from a plain secret file (never committed)
cat > /tmp/taskr-secrets-plain.yaml <<'EOF'
apiVersion: v1
kind: Secret
metadata:
  name: taskr-secrets
  namespace: taskr
type: Opaque
stringData:
  postgres-password: "secretpassword"
  session-secret: "my-super-secret"
  database-url: "postgres://taskr:secretpassword@postgres:5432/taskr"
  redis-url: "redis://redis:6379"
EOF

# Seal it (uses the cluster's public key)
kubeseal --format yaml < /tmp/taskr-secrets-plain.yaml > k8s/taskr-secrets-sealed.yaml

# ✅ SAFE to commit to git
git add k8s/taskr-secrets-sealed.yaml
git commit -m "chore: add sealed secrets for taskr"

# ── Apply the sealed secret ────────────────────────────────────────────────
kubectl apply -f k8s/taskr-secrets-sealed.yaml

# The controller decrypts it and creates a plain Secret in the cluster
kubectl get secret taskr-secrets -n taskr
```

```yaml
# What taskr-secrets-sealed.yaml looks like (safe to commit)
apiVersion: bitnami.com/v1alpha1
kind: SealedSecret
metadata:
  name: taskr-secrets
  namespace: taskr
spec:
  encryptedData:
    postgres-password: AgB3k9...long-base64-ciphertext...==
    session-secret: AgCm2P...long-base64-ciphertext...==
    database-url: AgDw4R...long-base64-ciphertext...==
    redis-url: AgEk8T...long-base64-ciphertext...==
```

> **Re-sealing for a new cluster:** If you set up a fresh k3s cluster, the old SealedSecrets cannot be decrypted. Backup the controller's key pair:
> ```bash
> kubectl get secret -n kube-system \
>   -l sealedsecrets.bitnami.com/sealed-secrets-key \
>   -o yaml > sealed-secrets-master-key.yaml
> # Store this backup SECURELY — not in git
> ```

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

## Phase 4: Test in a Staging Namespace

**Never migrate directly to production.** Test in a separate namespace first.

```bash
# 1. Create the staging namespace
kubectl create namespace taskr-staging

# 2. Create the pull secret in staging
kubectl create secret docker-registry ghcr-creds \
  --docker-server=ghcr.io \
  --docker-username=myorg \
  --docker-password=$GITHUB_PAT \
  -n taskr-staging

# 3. Apply all manifests to staging (using kustomize namespace override)
# Or simply pipe them through sed for a quick test:
for f in namespace.yaml secrets.yaml postgres-pvc.yaml redis-pvc.yaml \
          postgres-statefulset.yaml redis-deployment.yaml \
          web-deployment.yaml services.yaml; do
  kubectl apply -f $f -n taskr-staging
done

# 4. Watch everything come up
kubectl get pods -n taskr-staging -w

# 5. Run smoke tests
kubectl port-forward svc/web 8080:80 -n taskr-staging &
curl -s http://localhost:8080/healthz
curl -s http://localhost:8080/api/tasks

# 6. Check logs for errors
kubectl logs deployment/web -n taskr-staging --tail=50
kubectl logs statefulset/postgres -n taskr-staging --tail=20

# 7. Test database connectivity
kubectl exec -n taskr-staging statefulset/postgres -- \
  psql -U taskr -d taskr -c "\dt"

# 8. Tear down staging when satisfied
kubectl delete namespace taskr-staging
```

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

## Kustomize Promotion Flow

Once staging passes, promote to production using Kustomize overlays — the same manifests, different config.

```
k8s/
├── base/
│   ├── kustomization.yaml
│   ├── namespace.yaml
│   ├── deployment.yaml
│   ├── statefulset.yaml
│   ├── services.yaml
│   └── ingress.yaml
├── overlays/
│   ├── staging/
│   │   ├── kustomization.yaml     # namespace: taskr-staging, replicas: 1
│   │   ├── patch-replicas.yaml
│   │   └── sealed-secret-staging.yaml
│   └── production/
│       ├── kustomization.yaml     # namespace: taskr, replicas: 2
│       ├── patch-replicas.yaml
│       ├── patch-resources.yaml   # higher CPU/memory limits
│       ├── hpa.yaml
│       └── sealed-secret-prod.yaml
```

```bash
# Deploy to staging
kubectl apply -k k8s/overlays/staging
kubectl rollout status deployment/web -n taskr-staging

# Run smoke tests
kubectl port-forward svc/web 8080:80 -n taskr-staging &
curl -sf http://localhost:8080/healthz

# Promote to production (same manifests, production overlay)
kubectl diff -k k8s/overlays/production   # preview changes
kubectl apply -k k8s/overlays/production
kubectl rollout status deployment/web -n taskr
```

**Image tag promotion:** Update the image tag in the base or overlay for each environment, then promote the same tested tag:

```yaml
# overlays/production/kustomization.yaml
images:
- name: ghcr.io/myorg/taskr-web
  newTag: "2.2.0"    # pin to the same tag tested in staging
```

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

## Phase 5: Data Migration

This is the most critical phase. We must move the live data from Podman volumes to Kubernetes PersistentVolumes with minimal downtime.

### Strategy A: Brief Maintenance Window (Simplest)

```bash
# --- Step 1: Stop the Podman app (maintenance window begins) ---
systemctl --user stop taskr-web.service
systemctl --user stop taskr-caddy.service

# --- Step 2: Dump PostgreSQL data ---
podman exec taskr-postgres \
  pg_dump -U taskr -d taskr -F c -f /tmp/taskr.pgdump

podman cp taskr-postgres:/tmp/taskr.pgdump /tmp/taskr.pgdump

# --- Step 3: Dump Redis data ---
# Redis uses RDB snapshots; copy the dump.rdb file
podman exec taskr-redis redis-cli BGSAVE
sleep 2
REDIS_VOL_PATH=$(podman volume inspect taskr_redis \
  --format '{{.Mountpoint}}')
cp ${REDIS_VOL_PATH}/dump.rdb /tmp/taskr-redis.rdb

# --- Step 4: Apply manifests to production namespace ---
kubectl create namespace taskr
kubectl create secret docker-registry ghcr-creds \
  --docker-server=ghcr.io \
  --docker-username=myorg \
  --docker-password=$GITHUB_PAT \
  -n taskr

kubectl apply -f namespace.yaml
kubectl apply -f secrets.yaml
kubectl apply -f postgres-pvc.yaml
kubectl apply -f redis-pvc.yaml
kubectl apply -f postgres-statefulset.yaml
kubectl apply -f redis-deployment.yaml
kubectl apply -f services.yaml

# --- Step 5: Wait for postgres to be ready ---
kubectl rollout status statefulset/postgres -n taskr --timeout=120s

# --- Step 6: Restore PostgreSQL dump ---
# Copy dump into the pod
kubectl cp /tmp/taskr.pgdump taskr/$(kubectl get pod -n taskr -l app=postgres -o name | head -1 | cut -d/ -f2):/tmp/taskr.pgdump

# Restore
kubectl exec -n taskr statefulset/postgres -- \
  pg_restore -U taskr -d taskr --clean --if-exists /tmp/taskr.pgdump

# --- Step 7: Restore Redis data ---
REDIS_POD=$(kubectl get pod -n taskr -l app=redis -o name | cut -d/ -f2)
kubectl cp /tmp/taskr-redis.rdb taskr/${REDIS_POD}:/data/dump.rdb
kubectl exec -n taskr ${REDIS_POD} -- redis-cli DEBUG RELOAD

# --- Step 8: Deploy the web app ---
kubectl apply -f web-deployment.yaml
kubectl apply -f ingressroute.yaml

kubectl rollout status deployment/web -n taskr --timeout=120s
```

### Strategy B: Blue/Green (Zero Downtime)

Keep the Podman stack running while the k3s stack comes up in parallel, then switch DNS:

```mermaid
sequenceDiagram
    participant DNS
    participant Podman as Podman Stack (Blue)
    participant K3s as k3s Stack (Green)
    participant Users

    Users->>DNS: taskr.example.com
    DNS-->>Users: → Podman IP (192.168.1.10)
    Users->>Podman: requests

    Note over K3s: Deploy + migrate data snapshot
    Note over K3s: Green smoke-tested ✓

    DNS-->>Users: → k3s IP (192.168.1.20)  [cutover]
    Users->>K3s: requests

    Note over Podman: Keep running for 24h (fallback)
    Note over Podman: Decommission after validation
```

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

## Phase 6: Cutover

```bash
# 1. Final validation before switching DNS
curl -s https://taskr.example.com/healthz  # still hitting Podman

# 2. Take one last backup before DNS switch
podman exec taskr-postgres pg_dump -U taskr -d taskr \
  -F c -f /tmp/taskr-final.pgdump

# 3. Update DNS
# In your DNS provider (Cloudflare, Route 53, etc.):
# Change taskr.example.com A record from 192.168.1.10 → k3s node IP
# Or update your load balancer / reverse proxy upstream

# 4. Verify the new stack is serving traffic
watch -n 2 curl -s https://taskr.example.com/healthz

# 5. Monitor for errors in k3s logs
kubectl logs deployment/web -n taskr --follow &

# 6. Monitor pod health
watch kubectl get pods -n taskr
```

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

## Canary Deployment Pattern

Instead of a big-bang cutover, route a small percentage of traffic to the new k3s version while the Podman stack serves the majority. Increase traffic incrementally.

```mermaid
flowchart TD
    subgraph Traefik
        IR[IngressRoute taskr.example.com]
    end
    IR -->|90% traffic| OLD[web-stable Podman stack via NodePort]
    IR -->|10% traffic| NEW[web-canary k3s Deployment 1 replica]
    NEW -->|promote| FULL[web-stable k3s Deployment 2 replicas]
```

```yaml
# canary-ingressroute.yaml — weighted traffic split with Traefik
apiVersion: traefik.containo.us/v1alpha1
kind: IngressRoute
metadata:
  name: taskr-canary
  namespace: taskr
spec:
  entryPoints: [websecure]
  routes:
  - match: Host(`taskr.example.com`)
    kind: Rule
    services:
    - name: web-stable
      port: 80
      weight: 90      # 90% of traffic to stable
    - name: web-canary
      port: 80
      weight: 10      # 10% to canary
    middlewares:
    - name: security-headers
  tls:
    certResolver: letsencrypt
```

```bash
# 1. Deploy canary (1 replica)
kubectl apply -f canary-deployment.yaml   # image: ghcr.io/myorg/taskr-web:2.2.0

# 2. Verify canary health
kubectl rollout status deployment/web-canary -n taskr
kubectl logs deployment/web-canary -n taskr --tail=50

# 3. Monitor error rates for 30 min — then increase traffic
# Edit the IngressRoute to weight: 50/50, then 0/100

# 4. Promote: remove canary Service from IngressRoute and point fully to web-stable
kubectl set image deployment/web-stable web=ghcr.io/myorg/taskr-web:2.2.0 -n taskr
kubectl rollout status deployment/web-stable -n taskr

# 5. Delete canary after promotion
kubectl delete deployment web-canary -n taskr
kubectl delete svc web-canary -n taskr
```

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

## Phase 7: Post-Migration Validation

```bash
# --- Functional checks ---
curl -s https://taskr.example.com/healthz
curl -s https://taskr.example.com/api/tasks
# Test user login, task creation, data persistence

# --- Infrastructure checks ---
kubectl get all -n taskr
kubectl top pods -n taskr

# Verify PVCs are bound
kubectl get pvc -n taskr
# NAME            STATUS   VOLUME          CAPACITY   STORAGECLASS
# postgres-data   Bound    pvc-abc...      10Gi       local-path
# redis-data      Bound    pvc-def...      1Gi        local-path

# Check no pods are in CrashLoopBackOff or Error state
kubectl get pods -n taskr
# NAME                     READY   STATUS    RESTARTS   AGE
# postgres-0               1/1     Running   0          1h
# redis-6d9f...            1/1     Running   0          1h
# web-7b8c9...-xxxxx       1/1     Running   0          1h
# web-7b8c9...-yyyyy       1/1     Running   0          1h

# Verify resource usage is within expected bounds
kubectl describe pod -n taskr -l app=web | grep -A 5 "Limits\|Requests"

# Check events for warnings
kubectl get events -n taskr --sort-by='.lastTimestamp' | tail -20

# --- Decommission Podman stack (after 24–48h soak) ---
systemctl --user stop taskr-postgres.service taskr-redis.service
systemctl --user disable taskr-postgres.service taskr-redis.service
```

### Post-Migration Checklist

```
[ ] All pods Running and Ready
[ ] PVCs Bound
[ ] Health endpoints responding
[ ] Application login working
[ ] Data intact (spot-check records in DB)
[ ] Logs show no errors
[ ] Monitoring dashboards (Prometheus/Grafana) show healthy metrics
[ ] TLS certificate issued (cert-manager)
[ ] DNS resolves to k3s IP
[ ] Old Podman services stopped
[ ] Backups of old volumes retained for 30 days
[ ] Runbook updated with new k3s architecture
```

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

## Post-Migration Runbook Template

Copy and fill this template into your team's wiki or ops repository after a successful migration:

```markdown
# Runbook: Taskr on k3s

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)


## Quick Reference
- **Namespace:** taskr
- **Cluster:** k3s-prod (kubectl context: k3s-prod)
- **Registry:** ghcr.io/myorg
- **Ingress:** taskr.example.com (Traefik IngressRoute)
- **Manifests:** https://github.com/myorg/taskr/tree/main/k8s/

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)


## Health Check
kubectl get pods -n taskr
kubectl top pods -n taskr
curl -sf https://taskr.example.com/healthz

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)


## Deploy New Version
1. Push image: podman push ghcr.io/myorg/taskr-web:<new-tag>
2. Update image tag in overlays/production/kustomization.yaml
3. kubectl apply -k k8s/overlays/production
4. kubectl rollout status deployment/web -n taskr

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)


## Rollback
kubectl rollout undo deployment/web -n taskr
kubectl rollout history deployment/web -n taskr

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)


## Database Access
kubectl exec -n taskr statefulset/postgres -- psql -U taskr -d taskr

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)


## Restart a Component
kubectl rollout restart deployment/web -n taskr
kubectl rollout restart deployment/redis -n taskr
kubectl rollout restart statefulset/postgres -n taskr

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)


## View Logs
kubectl logs deployment/web -n taskr --tail=100 --follow
kubectl logs statefulset/postgres -n taskr --tail=50

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)


## Scale Manually
kubectl scale deployment/web --replicas=3 -n taskr

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)


## Backup Database
kubectl exec -n taskr statefulset/postgres -- \
  pg_dump -U taskr -d taskr -F c > /backup/taskr-$(date +%Y%m%d).pgdump

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)


## Secret Rotation
kubectl delete secret taskr-secrets -n taskr
# Update sealed secret, then:
kubectl apply -f k8s/overlays/production/sealed-secret-prod.yaml

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)


## Emergency Contacts
- On-call: @ops-team (PagerDuty)
- Escalation: @platform-lead
```

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

## Rollback Plan

Document and test your rollback BEFORE cutting over. A rollback is fast because the Podman stack remains running during the migration window.

```bash
# --- ROLLBACK PROCEDURE ---

# 1. Switch DNS back to Podman IP
# Change taskr.example.com A record back to 192.168.1.10

# 2. Restart Podman services (if stopped)
systemctl --user start taskr-postgres.service
systemctl --user start taskr-redis.service
systemctl --user start taskr-web.service
systemctl --user start taskr-caddy.service

# 3. Verify Podman stack is healthy
podman ps
curl -s https://taskr.example.com/healthz

# 4. Archive the k3s namespace for post-mortem
kubectl get all,pvc,secrets,configmaps -n taskr -o yaml \
  > /tmp/taskr-k3s-state-$(date +%Y%m%d-%H%M).yaml

# 5. Scale down (but don't delete) the k3s workloads
kubectl scale deployment/web --replicas=0 -n taskr
kubectl scale deployment/redis --replicas=0 -n taskr

# 6. Document what went wrong and re-attempt after fixing
```

> **Rule:** Keep the Podman stack intact for **at least 48 hours** after a successful cutover. This gives you a safe rollback window without needing to restore from backup.

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

## Migration Timeline Diagram

```mermaid
timeline
    title Taskr Migration Timeline
    section Week 1 – Preparation
      Day 1 : Inventory assessment
            : Volume backup
      Day 2 : Build & push custom images
            : Write Kubernetes manifests
      Day 3 : Staging environment test
            : Fix issues found in staging
    section Week 2 – Migration
      Day 8  : Data migration rehearsal (test restore)
             : Final manifest review
      Day 9  : Maintenance window
             : Data migration to k3s PVCs
             : Deploy production workloads
      Day 10 : DNS cutover
             : Post-migration validation
    section Week 3 – Stabilisation
      Day 15 : Soak period monitoring
             : Performance baseline
      Day 21 : Decommission Podman services
             : Archive old volume backups
             : Update runbook
```

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

## Common Pitfalls

| Issue | Symptom | Fix |
|---|---|---|
| Migration Job runs again on redeploy | Duplicate data / schema errors | Use versioned Job names (`taskr-migrate-v2-2-0`) — immutable |
| Rollback wipes migrated DB | Data from k3s session lost | Always restore from pre-migration backup, not live DB |
| SealedSecret decryption fails after cluster rebuild | `secret not found` | Restore the sealed-secrets master key backup before applying |
| NetworkPolicy blocks DNS | All pods: `CrashLoopBackOff`, `nslookup` fails | Add `allow-dns-egress` NetworkPolicy (port 53 UDP/TCP) |
| Caddy → Traefik TLS gap | `ERR_CONNECTION_REFUSED` during cutover | Pre-issue cert with cert-manager before DNS flip |
| `kubectl cp` fails for large dumps | Timeout or partial file | Use `kubectl exec ... pg_dump > /tmp/...` + `kubectl cp` in chunks |
| Canary ingressroute weight not splitting | All traffic goes to stable | Traefik requires both services to be healthy; check canary pod readiness |
| Quadlet `localhost` DB URL in env | `connection refused` — wrong hostname | Replace `localhost` with k8s Service DNS name (e.g., `postgres`) |
| StatefulSet PVC not deleted on `kubectl delete ns` | PVC stuck in Terminating | PVCs have a finalizer — delete them explicitly: `kubectl delete pvc -n taskr --all` |
| Job completes but `kubectl wait` times out | CI hangs | Add `--timeout` and check `kubectl describe job` for events |

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

## Further Reading

- [Kubernetes Jobs](https://kubernetes.io/docs/concepts/workloads/controllers/job/) — one-shot and batch workloads
- [CronJob reference](https://kubernetes.io/docs/concepts/workloads/controllers/cron-jobs/) — scheduled tasks
- [NetworkPolicy](https://kubernetes.io/docs/concepts/services-networking/network-policies/) — pod-level network isolation
- [SealedSecrets](https://github.com/bitnami-labs/sealed-secrets) — encrypted secrets for GitOps
- [Kustomize overlays](https://kubectl.docs.kubernetes.io/references/kustomize/kustomizationref/) — multi-environment promotion
- [Traefik weighted services](https://doc.traefik.io/traefik/routing/services/#weighted-round-robin) — canary traffic splitting
- [k3s local-path-provisioner](https://github.com/rancher/local-path-provisioner) — PVC storage class
- [pg_dump / pg_restore](https://www.postgresql.org/docs/current/app-pgdump.html) — PostgreSQL backup and restore

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

## Lab

**Goal:** Perform a mini end-to-end migration of a single-container Podman workload to k3s.

```bash
# ============================================================
# PART 1: Set up the "existing" Podman workload
# ============================================================

# Run a simple nginx container with a custom index page
mkdir -p /tmp/taskr-html
echo "<h1>Hello from Podman!</h1>" > /tmp/taskr-html/index.html

podman run -d \
  --name legacy-web \
  -p 8080:80 \
  -v /tmp/taskr-html:/usr/share/nginx/html:ro,z \
  docker.io/library/nginx:1.25-alpine

curl http://localhost:8080/
# <h1>Hello from Podman!</h1>

# ============================================================
# PART 2: Assess the workload
# ============================================================

podman inspect legacy-web \
  --format 'Image: {{.Config.Image}}
Ports: {{.NetworkSettings.Ports}}
Mounts: {{range .Mounts}}{{.Source}}->{{.Destination}} {{end}}'

# ============================================================
# PART 3: Write the k3s manifest
# ============================================================

kubectl apply -f - <<'EOF'
apiVersion: v1
kind: Namespace
metadata:
  name: lab-migration
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: nginx-html
  namespace: lab-migration
data:
  index.html: |
    <h1>Hello from k3s!</h1>
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
  namespace: lab-migration
spec:
  replicas: 1
  selector:
    matchLabels:
      app: web
  template:
    metadata:
      labels:
        app: web
    spec:
      containers:
        - name: nginx
          image: docker.io/library/nginx:1.25-alpine
          ports:
            - containerPort: 80
          volumeMounts:
            - name: html
              mountPath: /usr/share/nginx/html
      volumes:
        - name: html
          configMap:
            name: nginx-html
---
apiVersion: v1
kind: Service
metadata:
  name: web
  namespace: lab-migration
spec:
  selector:
    app: web
  ports:
    - port: 80
      targetPort: 80
  type: NodePort
EOF

# ============================================================
# PART 4: Validate the k3s workload
# ============================================================

kubectl rollout status deployment/web -n lab-migration

K3S_PORT=$(kubectl get svc web -n lab-migration \
  -o jsonpath='{.spec.ports[0].nodePort}')

curl http://localhost:${K3S_PORT}/
# <h1>Hello from k3s!</h1>

# ============================================================
# PART 5: Cutover (simulated) and cleanup
# ============================================================

echo "=== k3s serving on port ${K3S_PORT} ==="
echo "=== Podman serving on port 8080 ==="
echo "=== In production: update DNS here ==="

# Stop Podman
podman stop legacy-web && podman rm legacy-web

# Final check
curl http://localhost:${K3S_PORT}/

# Clean up k3s resources
kubectl delete namespace lab-migration
```

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---
*Licensed under [CC BY-NC-SA 4.0](../LICENSE.md) · © 2026 UncleJS*
