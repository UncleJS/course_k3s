# etcd Snapshots
> Module 13 · Lesson 01 | [↑ Course Index](../README.md)

## Table of Contents
1. [What k3s Stores — etcd vs SQLite](#what-k3s-stores--etcd-vs-sqlite)
2. [The `k3s etcd-snapshot` Command](#the-k3s-etcd-snapshot-command)
3. [Scheduled Snapshots](#scheduled-snapshots)
4. [Snapshot Storage — Local and S3-Compatible](#snapshot-storage--local-and-s3-compatible)
5. [Listing Snapshots](#listing-snapshots)
6. [Restoring from a Snapshot](#restoring-from-a-snapshot)
7. [SQLite Backup for Single-Node Clusters](#sqlite-backup-for-single-node-clusters)
8. [Best Practices and RTO/RPO Considerations](#best-practices-and-rtorpo-considerations)

---

## What k3s Stores — etcd vs SQLite

k3s persists all cluster state in a key-value datastore. The choice of datastore depends on how k3s was deployed:

| Topology | Default Datastore | Data Directory |
|---|---|---|
| Single server node | SQLite | `/var/lib/rancher/k3s/server/db/` |
| Embedded etcd (HA) | etcd | `/var/lib/rancher/k3s/server/db/etcd/` |
| External datastore | PostgreSQL / MySQL | External host |

**What is stored in the datastore:**
- All Kubernetes API objects (Pods, Deployments, Services, ConfigMaps, Secrets, …)
- RBAC rules, CRDs, and Custom Resources
- Lease objects and leader election state
- Node and Service Account tokens (as Secrets)

**What is NOT stored in the datastore:**
- Container image layers (stored by containerd)
- Persistent Volume data on host paths or network storage
- Application logs

> **Important:** A snapshot/backup of the datastore restores cluster *state* — it does not restore
> PVC data. You need a separate tool (e.g., Velero + Restic) to back up persistent volume contents.

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

## The `k3s etcd-snapshot` Command

The `k3s etcd-snapshot` subcommand is built in and operates on the embedded etcd datastore. It is only
available when k3s is running in embedded-etcd mode (three or more server nodes, or a single server
started with `--cluster-init`).

### On-Demand Snapshot

```bash
# Save a snapshot to the default location (/var/lib/rancher/k3s/server/db/snapshots/)
sudo k3s etcd-snapshot save

# Save with a custom name prefix
sudo k3s etcd-snapshot save --name pre-upgrade-$(date +%Y%m%d)
```

The resulting file is named `<prefix>-<timestamp>` and stored locally unless S3 is configured.

### Command Reference

```
k3s etcd-snapshot <subcommand> [flags]

Subcommands:
  save    Take an on-demand snapshot
  list    List available snapshots
  delete  Remove a snapshot by name
  prune   Remove snapshots exceeding the configured retention count
  restore Restore cluster state from a snapshot (server must be stopped)
```

### Key Flags

| Flag | Default | Description |
|---|---|---|
| `--name` | `etcd-snapshot` | Prefix for the snapshot filename |
| `--dir` | `/var/lib/rancher/k3s/server/db/snapshots/` | Local storage directory |
| `--s3` | `false` | Enable S3 upload after taking snapshot |
| `--s3-bucket` | — | S3 bucket name |
| `--s3-region` | `us-east-1` | AWS region or compatible endpoint region |
| `--s3-endpoint` | — | Override endpoint URL (for MinIO etc.) |
| `--s3-access-key` | — | S3 access key ID |
| `--s3-secret-key` | — | S3 secret access key |
| `--s3-skip-ssl-verify` | `false` | Skip TLS verification for private endpoints |

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

## Scheduled Snapshots

k3s can take snapshots automatically on a cron schedule. Configure the schedule via the k3s server
configuration file or command-line flags.

### Configuration via `/etc/rancher/k3s/config.yaml`

```yaml
# /etc/rancher/k3s/config.yaml (server node)
etcd-snapshot-schedule-cron: "0 */6 * * *"   # Every 6 hours
etcd-snapshot-retention: 5                    # Keep the 5 most recent snapshots
etcd-snapshot-dir: /var/lib/rancher/k3s/server/db/snapshots
```

### Configuration via Systemd Drop-In

```ini
# /etc/systemd/system/k3s.service.d/snapshot.conf
[Service]
Environment="K3S_ETCD_SNAPSHOT_SCHEDULE_CRON=0 */6 * * *"
Environment="K3S_ETCD_SNAPSHOT_RETENTION=5"
```

After editing, reload and restart:

```bash
sudo systemctl daemon-reload
sudo systemctl restart k3s
```

### Verifying Scheduled Snapshots Are Active

```bash
# Check k3s logs for the snapshot scheduler
sudo journalctl -u k3s -f | grep -i snapshot

# List local snapshots to confirm they are being created
sudo k3s etcd-snapshot list
```

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

## Snapshot Storage — Local and S3-Compatible

### Local Storage

By default, snapshots are saved to the local filesystem of the control-plane node:

```
/var/lib/rancher/k3s/server/db/snapshots/
├── etcd-snapshot-20260301-060000          # compressed snapshot
├── etcd-snapshot-20260301-060000.metadata # JSON metadata sidecar
└── etcd-snapshot-20260301-120000
```

Each snapshot is accompanied by a `.metadata` JSON file containing:
- Snapshot name, timestamp, and size
- k3s version that created the snapshot
- Cluster token hash (for verification at restore time)

### S3-Compatible Storage

k3s can upload snapshots directly to any S3-compatible object store (AWS S3, MinIO, Ceph RADOS GW).

**Inline flags (on-demand):**

```bash
sudo k3s etcd-snapshot save \
  --s3 \
  --s3-bucket my-k3s-backups \
  --s3-region us-east-1 \
  --s3-access-key "$AWS_ACCESS_KEY_ID" \
  --s3-secret-key "$AWS_SECRET_ACCESS_KEY"
```

**Persistent configuration in `/etc/rancher/k3s/config.yaml`:**

```yaml
etcd-s3: true
etcd-s3-bucket: my-k3s-backups
etcd-s3-region: us-east-1
etcd-s3-access-key: AKIAIOSFODNN7EXAMPLE
etcd-s3-secret-key: wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY
etcd-s3-folder: snapshots/prod-cluster/
# For MinIO or other compatible endpoints:
# etcd-s3-endpoint: https://minio.internal:9000
# etcd-s3-skip-ssl-verify: true
```

**Using MinIO as a local S3-compatible target:**

```bash
# Start MinIO (for lab/testing)
docker run -d --name minio \
  -p 9000:9000 -p 9001:9001 \
  -e MINIO_ROOT_USER=minioadmin \
  -e MINIO_ROOT_PASSWORD=minioadmin \
  quay.io/minio/minio server /data --console-address ":9001"
```

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

## Listing Snapshots

```bash
# List local snapshots (tabular output)
sudo k3s etcd-snapshot list

# Example output:
# Name                              Size    Created
# etcd-snapshot-20260301-060000     2.3 MB  2026-03-01T06:00:00Z
# etcd-snapshot-20260301-120000     2.3 MB  2026-03-01T12:00:00Z

# List snapshots stored on S3 (requires S3 flags or config.yaml)
sudo k3s etcd-snapshot list --s3

# Show raw metadata JSON for a specific snapshot
sudo cat /var/lib/rancher/k3s/server/db/snapshots/etcd-snapshot-20260301-060000.metadata | jq .
```

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

## Restoring from a Snapshot

> **Warning:** Restoring from an etcd snapshot is a destructive operation. It replaces the entire
> cluster state with the state at the time of the snapshot. All changes made after the snapshot
> was taken will be lost. Always confirm with all team members before proceeding.

### Snapshot → Restore Flow

```mermaid
sequenceDiagram
    actor Operator
    participant Server1 as k3s Server 1 (leader)
    participant Server2 as k3s Server 2
    participant Server3 as k3s Server 3
    participant Snapshot as Snapshot File

    Operator->>Server1: sudo k3s etcd-snapshot save
    Server1->>Snapshot: Write snapshot + metadata

    Note over Operator: --- Disaster occurs ---

    Operator->>Server1: sudo systemctl stop k3s
    Operator->>Server2: sudo systemctl stop k3s
    Operator->>Server3: sudo systemctl stop k3s

    Operator->>Server1: sudo k3s server --cluster-reset\n--cluster-reset-restore-path=<snapshot>
    Server1->>Server1: Restore state from snapshot
    Server1->>Server1: Reset etcd cluster membership

    Operator->>Server1: sudo systemctl start k3s
    Note over Server1: Comes up as single-node cluster

    Operator->>Server2: Remove /var/lib/rancher/k3s/server/db/
    Operator->>Server3: Remove /var/lib/rancher/k3s/server/db/

    Operator->>Server2: sudo systemctl start k3s
    Operator->>Server3: sudo systemctl start k3s
    Note over Server2,Server3: Re-join the restored cluster
```

### Step-by-Step Restore Procedure

**Prerequisites:**
- You have the snapshot file path (local) or know the snapshot name (S3)
- You have access to all server nodes
- The `K3S_TOKEN` / `--token` value is available (required for HA re-join)

**Step 1 — Stop all k3s server nodes**

```bash
# On EVERY server node (not just the leader):
sudo systemctl stop k3s
```

**Step 2 — Restore on the first server node only**

```bash
# Local snapshot:
sudo k3s server \
  --cluster-reset \
  --cluster-reset-restore-path=/var/lib/rancher/k3s/server/db/snapshots/etcd-snapshot-20260301-060000

# S3 snapshot (k3s downloads it automatically):
sudo k3s server \
  --cluster-reset \
  --cluster-reset-restore-path=etcd-snapshot-20260301-060000 \
  --etcd-s3 \
  --etcd-s3-bucket=my-k3s-backups \
  --etcd-s3-access-key="$AWS_ACCESS_KEY_ID" \
  --etcd-s3-secret-key="$AWS_SECRET_ACCESS_KEY"
```

k3s will print a message like:
```
WARN[...] Cluster reset successful. To rejoin nodes, delete their data directories and restart.
```

**Step 3 — Start the restored server**

```bash
sudo systemctl start k3s

# Wait for it to become Ready:
sudo k3s kubectl get nodes
```

**Step 4 — Re-join other server nodes**

On each additional server node (perform one at a time):

```bash
# Remove the stale etcd data:
sudo rm -rf /var/lib/rancher/k3s/server/db/

# Restart k3s — it will re-join the restored cluster:
sudo systemctl start k3s
```

**Step 5 — Re-join agent nodes**

Agent nodes do not store etcd data. Simply restart them:

```bash
sudo systemctl restart k3s-agent
```

**Step 6 — Verify cluster health**

```bash
sudo k3s kubectl get nodes
sudo k3s kubectl get pods -A
sudo k3s kubectl cluster-info
```

> **Note on tokens:** If you changed `K3S_TOKEN` between the snapshot date and now, agents will fail
> to re-join. Ensure the token on all nodes matches the value at the time of the snapshot.

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

## SQLite Backup for Single-Node Clusters

Single-node k3s installations use SQLite by default (`/var/lib/rancher/k3s/server/db/state.db`).
The `k3s etcd-snapshot` command is **not available** for SQLite clusters.

### Manual SQLite Backup

```bash
# Option 1: Use SQLite's .dump (safe to run while k3s is running)
sudo sqlite3 /var/lib/rancher/k3s/server/db/state.db ".backup /tmp/k3s-backup-$(date +%Y%m%d%H%M%S).db"

# Option 2: Use the SQLite online backup API via sqlite3
sudo sqlite3 /var/lib/rancher/k3s/server/db/state.db \
  "VACUUM INTO '/tmp/k3s-vacuum-$(date +%Y%m%d%H%M%S).db'"

# Option 3: Copy the entire data directory (stop k3s first for consistency)
sudo systemctl stop k3s
sudo tar czf /tmp/k3s-db-backup-$(date +%Y%m%d%H%M%S).tar.gz \
  /var/lib/rancher/k3s/server/db/
sudo systemctl start k3s
```

### SQLite Restore

```bash
# Stop k3s
sudo systemctl stop k3s

# Replace the database
sudo cp /tmp/k3s-backup-20260301120000.db \
       /var/lib/rancher/k3s/server/db/state.db

# Fix permissions
sudo chown root:root /var/lib/rancher/k3s/server/db/state.db
sudo chmod 600 /var/lib/rancher/k3s/server/db/state.db

# Restart
sudo systemctl start k3s
```

### Automating SQLite Backups with Cron

```cron
# /etc/cron.d/k3s-sqlite-backup
# Run every 6 hours, keep 7 days of backups
0 */6 * * * root sqlite3 /var/lib/rancher/k3s/server/db/state.db \
  "VACUUM INTO '/var/lib/rancher/k3s/backups/state-$(date +\%Y\%m\%d-\%H\%M\%S).db'" && \
  find /var/lib/rancher/k3s/backups/ -name "state-*.db" -mtime +7 -delete
```

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

## Best Practices and RTO/RPO Considerations

### RPO (Recovery Point Objective)

RPO defines the maximum acceptable data loss measured in time.

| Snapshot Frequency | RPO | Suitable For |
|---|---|---|
| Hourly | ~1 hour | Production clusters with frequent changes |
| Every 6 hours | ~6 hours | Standard production |
| Daily | ~24 hours | Development/staging |

**Recommendation:** For production clusters, take snapshots every 1–6 hours and ship them off-node
(S3/MinIO) immediately.

### RTO (Recovery Time Objective)

RTO defines the maximum acceptable downtime during a restore.

Typical k3s etcd restore duration:

| Cluster Size | Snapshot Size | Typical Restore Time |
|---|---|---|
| Single server | < 50 MB | 2–5 minutes |
| 3-server HA | < 50 MB | 5–15 minutes (including node re-join) |
| 3-server HA | 100–500 MB | 15–30 minutes |

### Checklist of Best Practices

- **Store snapshots off-node.** A local snapshot is lost if the node's disk fails. Use S3 or a
  remote NFS mount.
- **Test restores regularly.** A backup that has never been tested is of unknown value. Run DR
  drills quarterly (see `03_cluster_restore.md`).
- **Retain at least 5 snapshots.** In case corruption is not noticed immediately, older snapshots
  may be the only clean ones.
- **Snapshot before every upgrade.** Always take a manual snapshot before `k3s upgrade` or
  `system-upgrade-controller` runs.
- **Monitor snapshot age.** Alert if the most recent snapshot is older than 2× the scheduled
  interval.
- **Encrypt secrets in transit and at rest.** If snapshots contain Secrets (they do), ensure S3
  buckets have encryption enabled and access is restricted.
- **Document the token.** The `K3S_TOKEN` / `--token` is required to re-join nodes after a
  restore. Store it in a secrets manager.

### Snapshot Monitoring Alert (Prometheus/Alertmanager example)

```yaml
# PrometheusRule: alert when latest snapshot is too old
groups:
  - name: k3s-backup
    rules:
      - alert: K3sSnapshotTooOld
        expr: time() - k3s_etcd_snapshot_last_created_timestamp_seconds > 43200
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "k3s etcd snapshot is older than 12 hours"
```

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

*Licensed under [CC BY-NC-SA 4.0](../LICENSE.md) · © 2026 UncleJS*
