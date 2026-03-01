# Storage Cheatsheet

> Mastering k3s Course | [↑ Course Index](../README.md)

## StorageClass Operations

```bash
# List storage classes
kubectl get storageclass
kubectl get sc

# Describe storage class
kubectl describe sc <name>

# Get default storage class
kubectl get sc -o jsonpath='{range .items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")]}{.metadata.name}{"\n"}{end}'

# Set a storage class as default
kubectl patch sc <name> -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'

# Remove default annotation
kubectl patch sc <name> -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"false"}}}'

# Delete storage class
kubectl delete sc <name>
```

```yaml
# local-path StorageClass (k3s default)
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: local-path
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: rancher.io/local-path
reclaimPolicy: Delete
volumeBindingMode: WaitForFirstConsumer
```

## PV / PVC Lifecycle

### PV States

| Phase | Description |
|-------|-------------|
| `Available` | Free, not bound to a claim |
| `Bound` | Bound to a PVC |
| `Released` | PVC deleted, not yet reclaimed |
| `Failed` | Reclamation failed |

### Reclaim Policies

| Policy | Behaviour on PVC delete |
|--------|------------------------|
| `Delete` | PV and underlying storage deleted |
| `Retain` | PV preserved, data intact, manual cleanup needed |
| `Recycle` | (Deprecated) `rm -rf` then Available again |

### PV / PVC Commands

```bash
# List PVs
kubectl get pv
kubectl get pv --sort-by=.spec.capacity.storage

# Describe PV
kubectl describe pv <name>

# List PVCs
kubectl get pvc
kubectl get pvc -A

# Describe PVC
kubectl describe pvc <name>

# Get PVC storage class and status
kubectl get pvc -o custom-columns='NAME:.metadata.name,STATUS:.status.phase,VOLUME:.spec.volumeName,CAPACITY:.status.capacity.storage,SC:.spec.storageClassName'

# Find which PV is bound to a PVC
kubectl get pv -o jsonpath='{range .items[?(@.spec.claimRef.name=="<pvc-name>")]}{.metadata.name}{"\n"}{end}'

# Delete PVC
kubectl delete pvc <name>

# Force delete stuck PVC (remove finalizer)
kubectl patch pvc <name> -p '{"metadata":{"finalizers":null}}'

# Delete PV
kubectl delete pv <name>

# Change PV reclaim policy
kubectl patch pv <name> -p '{"spec":{"persistentVolumeReclaimPolicy":"Retain"}}'
```

## Dynamic Provisioning Templates

### local-path PVC (k3s built-in)

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: my-data
  namespace: default
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: local-path
  resources:
    requests:
      storage: 5Gi
```

### Longhorn PVC

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: my-replicated-data
  namespace: default
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: longhorn
  resources:
    requests:
      storage: 20Gi
```

### ReadWriteMany PVC (Longhorn RWX)

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: shared-data
  namespace: default
spec:
  accessModes:
    - ReadWriteMany
  storageClassName: longhorn
  resources:
    requests:
      storage: 10Gi
```

### Static PV + PVC (manual bind)

```yaml
apiVersion: v1
kind: PersistentVolume
metadata:
  name: local-pv
spec:
  capacity:
    storage: 10Gi
  accessModes:
    - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  storageClassName: manual
  local:
    path: /mnt/data
  nodeAffinity:
    required:
      nodeSelectorTerms:
        - matchExpressions:
            - key: kubernetes.io/hostname
              operator: In
              values:
                - worker-node-1
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: local-pvc
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: manual
  resources:
    requests:
      storage: 10Gi
```

## PVC Resize Procedure

```bash
# 1. Check StorageClass allows expansion
kubectl get sc <name> -o jsonpath='{.allowVolumeExpansion}'

# 2. Patch PVC with new size (must be larger)
kubectl patch pvc <name> -p '{"spec":{"resources":{"requests":{"storage":"20Gi"}}}}'

# 3. Monitor resize
kubectl get pvc <name> -w
kubectl describe pvc <name> | grep -A5 Conditions

# 4. For filesystem resize (may require pod restart)
kubectl rollout restart deploy/<name>

# Enable expansion on existing StorageClass
kubectl patch sc longhorn -p '{"allowVolumeExpansion": true}'
```

## Volume Debug Commands

```bash
# Check what node a PVC is on
kubectl get pv $(kubectl get pvc <name> -o jsonpath='{.spec.volumeName}') \
  -o jsonpath='{.spec.nodeAffinity.required.nodeSelectorTerms[0].matchExpressions[0].values[0]}'

# Check PVC events
kubectl describe pvc <name> | tail -20

# Find pods using a PVC
kubectl get pods -A -o json | jq -r '.items[] | select(.spec.volumes[]?.persistentVolumeClaim.claimName=="<pvc-name>") | "\(.metadata.namespace)/\(.metadata.name)"'

# Check volume mounts in pod
kubectl get pod <name> -o jsonpath='{range .spec.containers[*]}{.name}{"\n"}{range .volumeMounts[*]}  {.name} -> {.mountPath}{"\n"}{end}{end}'

# Exec into pod and check mount
kubectl exec -it <pod> -- df -h
kubectl exec -it <pod> -- ls -la /data

# Check node disk usage (SSH to node)
df -h /var/lib/rancher/k3s/storage/

# Find all local-path volumes
ls /var/lib/rancher/k3s/storage/

# Check if PV directory exists on node
sudo ls -la /var/lib/rancher/k3s/storage/pvc-<uuid>
```

## Longhorn Quick Reference

### Install

```bash
# Install via Helm
helm repo add longhorn https://charts.longhorn.io
helm repo update
helm install longhorn longhorn/longhorn \
  --namespace longhorn-system \
  --create-namespace \
  --set defaultSettings.defaultReplicaCount=2

# Install via kubectl
kubectl apply -f https://raw.githubusercontent.com/longhorn/longhorn/v1.6.0/deploy/longhorn.yaml

# Check installation
kubectl get pods -n longhorn-system -w
kubectl get storageclass
```

### Access UI

```bash
# Port-forward to Longhorn UI
kubectl port-forward svc/longhorn-frontend 8000:80 -n longhorn-system

# Create ingress for Longhorn UI
kubectl apply -f - <<'EOF'
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: longhorn-ingress
  namespace: longhorn-system
  annotations:
    nginx.ingress.kubernetes.io/auth-type: basic
    nginx.ingress.kubernetes.io/auth-secret: longhorn-basic-auth
spec:
  rules:
    - host: longhorn.example.com
      http:
        paths:
          - pathType: Prefix
            path: /
            backend:
              service:
                name: longhorn-frontend
                port:
                  number: 80
EOF
```

### Longhorn Operations

```bash
# Get node storage info
kubectl get nodes.longhorn.io -n longhorn-system

# Get volumes
kubectl get volumes.longhorn.io -n longhorn-system

# Get replicas
kubectl get replicas.longhorn.io -n longhorn-system

# Attach/detach volume
kubectl get volumes.longhorn.io <name> -n longhorn-system -o yaml

# Configure backup target (S3)
kubectl edit settings.longhorn.io backup-target -n longhorn-system
# Set: s3://mybucket@us-east-1/longhorn

# Create recurring backup job
kubectl apply -f - <<'EOF'
apiVersion: longhorn.io/v1beta1
kind: RecurringJob
metadata:
  name: daily-backup
  namespace: longhorn-system
spec:
  cron: "0 2 * * *"
  task: backup
  groups:
    - default
  retain: 7
  concurrency: 1
EOF

# Restore volume from backup (via UI or)
kubectl apply -f - <<'EOF'
apiVersion: longhorn.io/v1beta2
kind: Volume
metadata:
  name: restored-volume
  namespace: longhorn-system
spec:
  fromBackup: "s3://mybucket@us-east-1/longhorn?backup=backup-xxx&volume=pvc-yyy"
  numberOfReplicas: 2
  size: "10Gi"
EOF
```

## Common PVC Issues

| Symptom | Likely Cause | Fix |
|---------|-------------|-----|
| PVC stuck in `Pending` | No matching StorageClass | Check `kubectl get sc`, verify SC name in PVC |
| PVC stuck in `Pending` | `WaitForFirstConsumer` binding | SC waits for pod; create pod referencing PVC |
| PVC stuck in `Pending` | Insufficient disk space | Check node disk with `df -h` |
| PVC stuck in `Terminating` | Pod still using volume | Delete pod first, then PVC |
| PVC stuck in `Terminating` | Finalizer not removed | `kubectl patch pvc <name> -p '{"metadata":{"finalizers":null}}'` |
| Pod stuck in `ContainerCreating` | Volume not mounted | `kubectl describe pod` → check Events for mount errors |
| `FailedMount` error | PV on wrong node | Check nodeAffinity; delete PVC and let re-provision |
| Read-only filesystem | App writing to RO mount | Check `readOnlyRootFilesystem` in SecurityContext |
| `AccessModes` mismatch | RWX requested, RWO provided | Use Longhorn or NFS-based StorageClass |
| Data lost after pod restart | Using `emptyDir` not PVC | Use PersistentVolumeClaim for persistence |

---
*Licensed under [CC BY-NC-SA 4.0](../LICENSE.md) · © 2026 UncleJS*
