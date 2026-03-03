# Cluster Restore
> Module 13 · Lesson 03 | [↑ Course Index](../README.md)

## Table of Contents
1. [Disaster Recovery Scenarios](#disaster-recovery-scenarios)
2. [Choosing Your Restore Method](#choosing-your-restore-method)
3. [Restoring from an etcd Snapshot](#restoring-from-an-etcd-snapshot)
4. [Restoring with Velero](#restoring-with-velero)
5. [Partial Restores](#partial-restores)
6. [Verifying Restore Success](#verifying-restore-success)
7. [Post-Restore Checklist](#post-restore-checklist)
8. [Testing Your Backups — DR Drills](#testing-your-backups--dr-drills)
9. [Runbook Template](#runbook-template)

---

## Disaster Recovery Scenarios

Understanding the scenario determines which recovery tool to use and how long recovery will take.

| Scenario | Description | Primary Tool | Secondary Tool |
|---|---|---|---|
| **Node failure** | One server node crashes/lost, HA cluster intact | k3s HA self-heals | etcd snapshot if quorum lost |
| **Data corruption** | etcd data corrupted on disk | etcd snapshot | Velero |
| **Accidental deletion** | Namespace/resource deleted by mistake | Velero | etcd snapshot |
| **Ransomware / full cluster loss** | All nodes unrecoverable | etcd snapshot + Velero | Infrastructure rebuild |
| **Botched upgrade** | Upgrade broke cluster state | etcd snapshot (pre-upgrade) | Velero |
| **Secret / ConfigMap wipe** | Sensitive resources deleted | Velero | etcd snapshot |

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

## Choosing Your Restore Method

```mermaid
flowchart TD
    START([Disaster detected]) --> Q1{Entire cluster state lost?}

    Q1 -->|Yes| Q2{etcd snapshot available?}
    Q1 -->|No| Q3{Individual resources deleted?}

    Q2 -->|Yes| R1[Restore from etcd snapshot]
    Q2 -->|No| Q4{Velero backup available?}

    Q4 -->|Yes| R2[Restore full cluster with Velero]
    Q4 -->|No| R3[Rebuild from IaC / GitOps]

    Q3 -->|Yes| Q5{Need PVC data too?}
    Q3 -->|No| Q6{Node not Ready?}

    Q5 -->|Yes| R4[Velero restore with Kopia/Restic]
    Q5 -->|No| R5[Velero partial restore — resources only]

    Q6 -->|Yes| Q7{Other nodes healthy?}
    Q7 -->|Yes - HA| R6[Remove node, drain & replace]
    Q7 -->|No - single node| R1

    style R1 fill:#d4edda,stroke:#28a745
    style R2 fill:#d4edda,stroke:#28a745
    style R3 fill:#fff3cd,stroke:#ffc107
    style R4 fill:#d4edda,stroke:#28a745
    style R5 fill:#d4edda,stroke:#28a745
    style R6 fill:#cce5ff,stroke:#004085
```

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

## Restoring from an etcd Snapshot

This procedure covers the complete end-to-end restore for an HA cluster (3 server nodes). For a
single-node SQLite cluster, refer to `01_etcd_snapshots.md` § SQLite Restore.

> **STOP.** Before proceeding:
> - Notify all team members. No one should be deploying while a restore is in progress.
> - Confirm you have the correct snapshot name/path.
> - Confirm you have the cluster token (`K3S_TOKEN`).
> - Take a fresh snapshot of the current (broken) state if possible — you may need it for forensics.

### Phase 1 — Assess and Prepare

```bash
# Identify the available snapshots
sudo k3s etcd-snapshot list

# Or list from S3
sudo k3s etcd-snapshot list --s3 --s3-bucket my-k3s-backups

# Note the snapshot name you want to restore, e.g.:
# etcd-snapshot-20260301-060000
```

### Phase 2 — Stop All Server Nodes

Perform this on **every** server node simultaneously (or in quick succession).

```bash
# Server node 1 (and 2, 3...)
sudo systemctl stop k3s

# Confirm the process is gone
ps aux | grep k3s
```

### Phase 3 — Restore on the First Server Node

Choose the node that currently holds the snapshot file, or any node if restoring from S3.

```bash
# --- LOCAL SNAPSHOT ---
sudo k3s server \
  --cluster-reset \
  --cluster-reset-restore-path=/var/lib/rancher/k3s/server/db/snapshots/etcd-snapshot-20260301-060000

# --- S3 SNAPSHOT ---
sudo k3s server \
  --cluster-reset \
  --cluster-reset-restore-path=etcd-snapshot-20260301-060000 \
  --etcd-s3 \
  --etcd-s3-bucket=my-k3s-backups \
  --etcd-s3-region=us-east-1 \
  --etcd-s3-access-key="${AWS_ACCESS_KEY_ID}" \
  --etcd-s3-secret-key="${AWS_SECRET_ACCESS_KEY}"
```

The command exits after printing:
```
WARN[...] Cluster reset successful. To rejoin nodes, delete their data directories and restart.
```

### Phase 4 — Start the Restored Server

```bash
# On the restore node only
sudo systemctl start k3s

# Wait for it to be healthy (may take 60–90s)
watch sudo k3s kubectl get nodes

# Expected output:
# NAME       STATUS   ROLES                  AGE
# server-1   Ready    control-plane,master   2m
```

### Phase 5 — Re-join Remaining Server Nodes

Perform the following **one node at a time**. Do not proceed to the next node until the current one
shows `Ready`.

```bash
# On server-2 (repeat for server-3):
sudo rm -rf /var/lib/rancher/k3s/server/db/
sudo systemctl start k3s

# Watch from server-1 until this node appears:
watch sudo k3s kubectl get nodes
```

### Phase 6 — Re-join Agent Nodes

```bash
# On each agent node:
sudo systemctl restart k3s-agent
```

Agents do not hold etcd data, so no data directory removal is needed.

### Phase 7 — Verify

```bash
# All nodes Ready
sudo k3s kubectl get nodes -o wide

# System pods running
sudo k3s kubectl get pods -n kube-system

# Application pods restoring
sudo k3s kubectl get pods -A

# Cluster-info
sudo k3s kubectl cluster-info
```

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

## Restoring with Velero

### Full-Cluster Restore

```bash
# List available backups
velero backup get

# Restore everything (creates all namespaced resources)
velero restore create full-restore-$(date +%Y%m%d) \
  --from-backup full-cluster-backup-20260301

# Monitor progress
velero restore describe full-restore-20260301 --details
velero restore logs full-restore-20260301

# Check final status (should be "Completed")
velero restore get
```

### Restore to a Fresh Cluster

If restoring to a brand-new cluster after total loss:

```bash
# 1. Install Velero on the new cluster, pointing to the same object store:
velero install \
  --provider aws \
  --plugins velero/velero-plugin-for-aws:v1.9.0 \
  --bucket velero-backups \
  --secret-file /tmp/velero-credentials \
  --backup-location-config region=minio,s3ForcePathStyle=true,s3Url=http://minio.new-cluster:9000 \
  --use-node-agent

# 2. Wait for Velero to sync the backup inventory from the bucket
# (Velero discovers existing backups automatically from the BSL)
sleep 60
velero backup get

# 3. Restore
velero restore create from-old-cluster \
  --from-backup full-cluster-backup-20260301
```

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

## Partial Restores

### Restore a Single Namespace

```bash
velero restore create ns-restore \
  --from-backup full-cluster-backup-20260301 \
  --include-namespaces my-deleted-app

kubectl get all -n my-deleted-app
```

### Restore a Single Resource Type

```bash
# Restore only Secrets across all namespaces
velero restore create secrets-restore \
  --from-backup full-cluster-backup-20260301 \
  --include-resources secrets \
  --include-namespaces "*"

# Restore only a single named resource
velero restore create single-cm \
  --from-backup full-cluster-backup-20260301 \
  --include-resources configmaps \
  --include-namespaces my-app \
  --selector "app=my-api"
```

### Namespace Mapping (Restore to Different Namespace)

```bash
# Restore my-app into my-app-restored (must not exist yet, or use --existing-resource-policy)
velero restore create app-migration \
  --from-backup full-cluster-backup-20260301 \
  --include-namespaces my-app \
  --namespace-mappings my-app:my-app-restored
```

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

## Verifying Restore Success

After any restore operation, work through these verification steps:

```bash
# 1. Node health
kubectl get nodes -o wide

# 2. System pods
kubectl get pods -n kube-system
kubectl get pods -n velero

# 3. All application pods
kubectl get pods -A | grep -v Running | grep -v Completed

# 4. Services and endpoints
kubectl get svc -A
kubectl get endpoints -A | grep "<none>"   # endpoints with no backing pods are a warning

# 5. PVCs
kubectl get pvc -A
# STATUS should be Bound, not Pending or Lost

# 6. Application-level smoke tests
# Run your app's own health checks / integration tests

# 7. Ingress / Traefik
kubectl get ingress -A
curl -sk https://my-app.example.com/healthz

# 8. Certificate validity
kubectl get certificate -A   # (if cert-manager is installed)
kubectl get secret -A | grep tls
```

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

## Post-Restore Checklist

Copy this checklist into your incident ticket and work through it sequentially.

```
CLUSTER RESTORE CHECKLIST
Date/Time: _______________   Operator: _______________
Backup used: _______________  Restore method: etcd / Velero

PRE-RESTORE
[ ] Incident declared and stakeholders notified
[ ] Fresh snapshot taken of current (broken) state (if possible)
[ ] Correct snapshot/backup name confirmed
[ ] K3S_TOKEN / credentials confirmed
[ ] All k3s server processes stopped

RESTORE EXECUTION
[ ] Restore command executed on first server node
[ ] First server node restarted and shows Ready
[ ] All additional server nodes: data dir removed, restarted, Ready
[ ] All agent nodes restarted

VERIFICATION
[ ] All nodes show Ready
[ ] kube-system pods all Running
[ ] Application pods all Running (or appropriate)
[ ] No PVCs in Pending or Lost state
[ ] Services have endpoints
[ ] Ingress/Traefik routes responding
[ ] TLS certificates valid
[ ] Application health endpoints return 200

POST-RESTORE
[ ] Post-mortem ticket created
[ ] Root cause documented
[ ] Backup frequency / retention reviewed
[ ] DR runbook updated if gaps found
[ ] Stakeholders notified of resolution
[ ] Snapshot taken of restored (healthy) state
```

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

## Testing Your Backups — DR Drills

A backup that has never been tested is a backup of unknown quality. Schedule **DR drills** at least
quarterly to ensure your restore procedures are current and your team has muscle memory.

### GameDay / DR Drill Process

```mermaid
flowchart LR
    P([Plan drill]) --> E[Spin up test cluster]
    E --> R[Restore from production backup]
    R --> V[Verify all applications]
    V --> M[Measure RTO actual vs target]
    M --> D[Document gaps & improvements]
    D --> U[Update runbook]
```

### Drill Checklist

```bash
# Step 1: Create an isolated test cluster (k3s in a VM or container)
# Use the same k3s version as production

# Step 2: Install Velero on the test cluster, pointing to the same S3 bucket (read-only)
# OR copy the etcd snapshot to the test cluster

# Step 3: Perform the restore
# For etcd: sudo k3s server --cluster-reset --cluster-reset-restore-path=...
# For Velero: velero restore create test-restore --from-backup latest-backup

# Step 4: Run smoke tests — time how long they take
time kubectl get pods -A

# Step 5: Record actual RTO
# RTO = time from "restore command started" to "all smoke tests pass"

# Step 6: Destroy test cluster
```

### Automating Restore Validation

For critical clusters, automate a weekly restore-and-validate pipeline:

```yaml
# Example: GitHub Actions / CI pipeline step
- name: Test k3s backup restore
  run: |
    ./scripts/spin-up-test-cluster.sh
    velero install ...
    velero restore create ci-test-restore --from-backup latest-production
    ./scripts/wait-for-restore.sh ci-test-restore
    ./scripts/smoke-tests.sh
    ./scripts/teardown-test-cluster.sh
```

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

## Runbook Template

Copy and maintain this runbook in your team's wiki or incident management system.

```markdown
# K3s Cluster Restore Runbook

**Last tested:** YYYY-MM-DD
**Maintained by:** <team name>
**Escalation:** <on-call channel>

## Prerequisites
- SSH access to all server nodes
- `sudo` / root on server nodes
- K3S_TOKEN: stored in <secrets manager path>
- Latest snapshot name: check <S3 bucket / local path>
- AWS credentials: stored in <secrets manager path>

## Step 1 — Declare Incident
- Post in #incidents: "@here k3s cluster restore started"
- Open incident ticket: <link to template>

## Step 2 — Assess
```bash
# Check snapshot availability
sudo k3s etcd-snapshot list --s3 --s3-bucket my-k3s-backups
```

## Step 3 — Stop All Servers
```bash
# server-1, server-2, server-3:
sudo systemctl stop k3s
```

## Step 4 — Restore
```bash
# On server-1 only:
sudo k3s server \
  --cluster-reset \
  --cluster-reset-restore-path=<SNAPSHOT_NAME> \
  --etcd-s3 \
  --etcd-s3-bucket=my-k3s-backups \
  --etcd-s3-access-key="$(vault read -field=access_key secret/k3s/s3)" \
  --etcd-s3-secret-key="$(vault read -field=secret_key secret/k3s/s3)"
```

## Step 5 — Restart Servers
```bash
# server-1: sudo systemctl start k3s
# server-2: sudo rm -rf /var/lib/rancher/k3s/server/db/ && sudo systemctl start k3s
# server-3: sudo rm -rf /var/lib/rancher/k3s/server/db/ && sudo systemctl start k3s
```

## Step 6 — Restart Agents
```bash
# All agent nodes:
sudo systemctl restart k3s-agent
```

## Step 7 — Verify
```bash
kubectl get nodes
kubectl get pods -A | grep -v Running
```

## Step 8 — Communicate Resolution
- Post in #incidents: "k3s cluster restore completed. RTO: X minutes."
- Close incident ticket.

## Contacts
| Role | Name | Contact |
|---|---|---|
| Primary On-Call | | |
| Secondary On-Call | | |
| k3s Admin | | |
| Storage Admin | | |
```

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

*Licensed under [CC BY-NC-SA 4.0](../LICENSE.md) · © 2026 UncleJS*
