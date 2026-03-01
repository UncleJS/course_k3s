# Backup & DR Cheatsheet

> Mastering k3s Course | [↑ Course Index](../README.md)

## Table of Contents

- [etcd-snapshot Commands](#etcd-snapshot-commands)
- [Scheduled Snapshots (config.yaml)](#scheduled-snapshots-configyaml)
- [SQLite Backup Commands](#sqlite-backup-commands)
- [Velero CLI](#velero-cli)
- [Velero YAML Snippets](#velero-yaml-snippets)
- [Pre-Upgrade Backup Checklist](#pre-upgrade-backup-checklist)
- [Post-Restore Verification Commands](#post-restore-verification-commands)

---

## etcd-snapshot Commands

### On-Demand Snapshots

```bash
# Create snapshot (default name: on-demand-<hostname>-<timestamp>)
k3s etcd-snapshot save

# Create with custom name
k3s etcd-snapshot save --name pre-upgrade-v1.28

# Create and save to specific directory
k3s etcd-snapshot save \
  --name pre-upgrade \
  --dir /opt/k3s-snapshots/

# List snapshots
k3s etcd-snapshot list

# List as JSON
k3s etcd-snapshot list --output json | python3 -m json.tool

# Prune old snapshots
k3s etcd-snapshot prune --snapshot-retention 5

# Delete specific snapshot
k3s etcd-snapshot delete --name <snapshot-name>

# Delete all snapshots matching prefix
k3s etcd-snapshot delete --name "on-demand-" --snapshot-retention 0
```

### Restore from Snapshot

```bash
# IMPORTANT: Stop k3s BEFORE restoring

# Step 1: Stop k3s server
sudo systemctl stop k3s

# Step 2: Restore snapshot (resets etcd to snapshot state)
sudo k3s server \
  --cluster-reset \
  --cluster-reset-restore-path=/var/lib/rancher/k3s/server/db/snapshots/<snapshot-name>

# Step 3: Remove the cluster-reset flag and start normally
sudo systemctl start k3s

# Step 4: Verify cluster is healthy
kubectl get nodes
kubectl get pods -A

# If restoring on a different node/path
sudo k3s server \
  --cluster-reset \
  --cluster-reset-restore-path=/opt/k3s-snapshots/<snapshot-name>
```

### S3-Compatible Snapshot Storage

```bash
# Configure S3 in k3s config
cat >> /etc/rancher/k3s/config.yaml <<'EOF'
etcd-s3: true
etcd-s3-endpoint: s3.amazonaws.com
etcd-s3-access-key: AKIAXXXXXXXXXXXXXXXX
etcd-s3-secret-key: xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
etcd-s3-bucket: my-k3s-backups
etcd-s3-region: us-east-1
etcd-s3-folder: cluster1/
EOF

# Save snapshot to S3
k3s etcd-snapshot save --name pre-upgrade --etcd-s3

# List S3 snapshots
k3s etcd-snapshot list --etcd-s3

# Restore from S3
sudo systemctl stop k3s
sudo k3s server \
  --cluster-reset \
  --etcd-s3 \
  --etcd-s3-bucket=my-k3s-backups \
  --cluster-reset-restore-path=cluster1/<snapshot-name>
sudo systemctl start k3s
```

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

## Scheduled Snapshots (config.yaml)

```yaml
# /etc/rancher/k3s/config.yaml
# Embedded etcd snapshot settings
etcd-snapshot-schedule-cron: "0 */6 * * *"   # Every 6 hours
etcd-snapshot-retention: 10                   # Keep 10 snapshots
etcd-snapshot-dir: /opt/k3s-snapshots         # Custom directory
etcd-snapshot-compress: true                  # Compress snapshots

# S3 scheduled snapshots
etcd-s3: true
etcd-s3-endpoint: s3.amazonaws.com
etcd-s3-access-key: AKIAXXXXXXXXXXXXXXXX
etcd-s3-secret-key: xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
etcd-s3-bucket: my-k3s-backups
etcd-s3-region: us-east-1
```

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

## SQLite Backup Commands

```bash
# k3s uses SQLite when NOT using embedded etcd (single-node default)
# SQLite DB location
ls -lh /var/lib/rancher/k3s/server/db/state.db

# Backup SQLite database
# Method 1: Simple copy (stop k3s first for consistency)
sudo systemctl stop k3s
sudo cp /var/lib/rancher/k3s/server/db/state.db \
  /opt/backups/k3s-state-$(date +%Y%m%d-%H%M%S).db
sudo systemctl start k3s

# Method 2: SQLite online backup (no need to stop)
sudo sqlite3 /var/lib/rancher/k3s/server/db/state.db \
  ".backup '/opt/backups/k3s-state-$(date +%Y%m%d-%H%M%S).db'"

# Method 3: Dump to SQL (portable)
sudo sqlite3 /var/lib/rancher/k3s/server/db/state.db .dump \
  > /opt/backups/k3s-dump-$(date +%Y%m%d-%H%M%S).sql

# Verify backup integrity
sqlite3 /opt/backups/k3s-state-*.db "PRAGMA integrity_check;"

# Restore SQLite backup
sudo systemctl stop k3s
sudo cp /opt/backups/k3s-state-<timestamp>.db \
  /var/lib/rancher/k3s/server/db/state.db
sudo systemctl start k3s
```

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

## Velero CLI

### Install

```bash
# Download Velero CLI
wget https://github.com/vmware-tanzu/velero/releases/download/v1.13.0/velero-v1.13.0-linux-amd64.tar.gz
tar xzf velero-*.tar.gz
sudo mv velero-*/velero /usr/local/bin/

# Install Velero to cluster (with AWS S3)
velero install \
  --provider aws \
  --plugins velero/velero-plugin-for-aws:v1.9.0 \
  --bucket my-velero-backups \
  --backup-location-config region=us-east-1 \
  --snapshot-location-config region=us-east-1 \
  --secret-file ./credentials-velero

# Install with MinIO (S3-compatible)
velero install \
  --provider aws \
  --plugins velero/velero-plugin-for-aws:v1.9.0 \
  --bucket velero \
  --backup-location-config \
    region=minio,s3ForcePathStyle=true,s3Url=http://minio.minio-system.svc:9000 \
  --snapshot-location-config region=minio \
  --secret-file ./credentials-velero

# Check installation
kubectl get pods -n velero
velero version
```

### Backup Operations

```bash
# Create full cluster backup
velero backup create full-backup-$(date +%Y%m%d)

# Backup specific namespace
velero backup create prod-backup \
  --include-namespaces production

# Backup multiple namespaces
velero backup create app-backup \
  --include-namespaces production,staging

# Backup with label selector
velero backup create myapp-backup \
  --selector app=myapp

# Backup excluding resources
velero backup create full-backup \
  --exclude-namespaces kube-system,velero

# Backup with TTL (default 720h = 30 days)
velero backup create full-backup --ttl 168h

# List backups
velero backup get

# Describe backup
velero backup describe <name>
velero backup describe <name> --details

# Get backup logs
velero backup logs <name>

# Delete backup
velero backup delete <name>
velero backup delete --all
```

### Restore Operations

```bash
# Restore full backup
velero restore create --from-backup <backup-name>

# Restore to different namespace
velero restore create \
  --from-backup prod-backup \
  --namespace-mappings production:production-restore

# Restore specific resources
velero restore create \
  --from-backup full-backup \
  --include-resources deployments,services,configmaps \
  --include-namespaces production

# Restore excluding namespaces
velero restore create \
  --from-backup full-backup \
  --exclude-namespaces kube-system

# List restores
velero restore get

# Describe restore
velero restore describe <name>
velero restore describe <name> --details

# Get restore logs
velero restore logs <name>
```

### Schedules

```bash
# Create backup schedule
velero schedule create daily-backup \
  --schedule="0 2 * * *" \
  --include-namespaces production,staging \
  --ttl 168h

# Create schedule with Cron expression
velero schedule create hourly-critical \
  --schedule="@every 1h" \
  --include-namespaces production \
  --ttl 24h

# List schedules
velero schedule get

# Describe schedule
velero schedule describe <name>

# Trigger manual backup from schedule
velero backup create --from-schedule daily-backup

# Pause schedule
velero schedule pause <name>

# Unpause schedule
velero schedule unpause <name>

# Delete schedule
velero schedule delete <name>
```

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

## Velero YAML Snippets

### Backup

```yaml
apiVersion: velero.io/v1
kind: Backup
metadata:
  name: pre-upgrade-backup
  namespace: velero
spec:
  includedNamespaces:
    - production
    - staging
  excludedResources:
    - events
    - events.events.k8s.io
  storageLocation: default
  volumeSnapshotLocations:
    - default
  ttl: 720h0m0s
  snapshotVolumes: true
  defaultVolumesToFsBackup: false  # set true for CSI volumes without snapshots
```

### Schedule

```yaml
apiVersion: velero.io/v1
kind: Schedule
metadata:
  name: daily-production-backup
  namespace: velero
spec:
  schedule: "0 2 * * *"
  useOwnerReferencesInBackup: false
  template:
    includedNamespaces:
      - production
    excludedResources:
      - events
      - events.events.k8s.io
    storageLocation: default
    ttl: 168h0m0s
    snapshotVolumes: true
```

### Restore

```yaml
apiVersion: velero.io/v1
kind: Restore
metadata:
  name: restore-from-backup
  namespace: velero
spec:
  backupName: pre-upgrade-backup
  includedNamespaces:
    - production
  excludedResources:
    - nodes
    - events
    - events.events.k8s.io
    - backups.velero.io
    - restores.velero.io
  restorePVs: true
  preserveNodePorts: true
  existingResourcePolicy: update   # or: none (skip existing)
```

### BackupStorageLocation

```yaml
apiVersion: velero.io/v1
kind: BackupStorageLocation
metadata:
  name: secondary
  namespace: velero
spec:
  provider: aws
  objectStorage:
    bucket: my-velero-secondary
    prefix: cluster1
  config:
    region: eu-west-1
  accessMode: ReadWrite
  credential:
    name: velero-credentials
    key: cloud
```

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

## Pre-Upgrade Backup Checklist

```bash
# 1. Record current versions
kubectl version --short
helm list -A
kubectl get nodes -o wide

# 2. Capture all workload manifests
kubectl get all -A -o yaml > pre-upgrade-all-resources-$(date +%Y%m%d).yaml

# 3. Capture CRDs
kubectl get crd -o yaml > pre-upgrade-crds-$(date +%Y%m%d).yaml

# 4. Capture ConfigMaps and Secrets
kubectl get cm -A -o yaml > pre-upgrade-configmaps-$(date +%Y%m%d).yaml
kubectl get secrets -A -o yaml > pre-upgrade-secrets-$(date +%Y%m%d).yaml

# 5. Capture PV/PVC state
kubectl get pv,pvc -A -o yaml > pre-upgrade-storage-$(date +%Y%m%d).yaml

# 6. etcd snapshot
sudo k3s etcd-snapshot save --name pre-upgrade-$(date +%Y%m%d)
sudo k3s etcd-snapshot list

# 7. Velero backup (if installed)
velero backup create pre-upgrade-$(date +%Y%m%d) --wait

# 8. Test snapshot listing
sudo k3s etcd-snapshot list

# 9. Copy snapshot off-node
sudo rsync -av /var/lib/rancher/k3s/server/db/snapshots/ backup-server:/backups/k3s/
```

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

## Post-Restore Verification Commands

```bash
# 1. Check node status
kubectl get nodes
kubectl get nodes -o wide

# 2. Check system pods
kubectl get pods -n kube-system
kubectl get pods -A | grep -v Running | grep -v Completed

# 3. Check API server accessibility
kubectl cluster-info
kubectl version --short

# 4. Check etcd health (if using embedded etcd)
ETCDCTL_ENDPOINTS='https://127.0.0.1:2379' \
  ETCDCTL_CACERT='/var/lib/rancher/k3s/server/tls/etcd/server-ca.crt' \
  ETCDCTL_CERT='/var/lib/rancher/k3s/server/tls/etcd/client.crt' \
  ETCDCTL_KEY='/var/lib/rancher/k3s/server/tls/etcd/client.key' \
  ETCDCTL_API=3 etcdctl endpoint health

# 5. Check workloads in critical namespaces
kubectl get deployments -A
kubectl get statefulsets -A
kubectl rollout status deploy/<name> -n <namespace>

# 6. Check PV/PVC binding
kubectl get pv,pvc -A

# 7. Check services and endpoints
kubectl get svc -A
kubectl get endpoints -A | grep -v '<none>'

# 8. Check ingress
kubectl get ingress -A
kubectl get ingressroutes -A   # Traefik

# 9. Verify application health probes
kubectl get pods -A -o json | jq -r '.items[] | select(.status.phase != "Running") | "\(.metadata.namespace)/\(.metadata.name): \(.status.phase)"'

# 10. Check recent events for errors
kubectl get events -A --sort-by=.lastTimestamp | grep Warning | tail -20

# 11. Test application endpoints
curl -f https://app.example.com/healthz

# 12. Verify Velero backup locations (if installed)
velero backup-location get
velero backup get | head -5
```

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---
*Licensed under [CC BY-NC-SA 4.0](../LICENSE.md) · © 2026 UncleJS*
