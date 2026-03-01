# Troubleshooting Cheatsheet

> Mastering k3s Course | [↑ Course Index](../README.md)

## Table of Contents

- [Pod States Decision Table](#pod-states-decision-table)
- [Quick Diagnosis Commands](#quick-diagnosis-commands)
- [Node Troubleshooting](#node-troubleshooting)
- [Network Debugging One-liners](#network-debugging-one-liners)
- [Common Error Patterns & Fixes](#common-error-patterns--fixes)
- [Debug Pod Snippets](#debug-pod-snippets)
- [DNS Testing](#dns-testing)
- [Certificate Debugging](#certificate-debugging)
- [Performance Quick Checks](#performance-quick-checks)

---

## Pod States Decision Table

| Status | Meaning | First Action |
|--------|---------|-------------|
| `Pending` | Not scheduled | `kubectl describe pod` → check Events |
| `ContainerCreating` | Pulling image or mounting volumes | `kubectl describe pod` → check Events |
| `Running` | At least one container running | Check logs if app misbehaving |
| `CrashLoopBackOff` | Container crashing repeatedly | `kubectl logs <pod> --previous` |
| `ImagePullBackOff` | Cannot pull container image | Check image name, tag, registry access |
| `ErrImagePull` | Image pull failed once | Same as above |
| `OOMKilled` | Killed by out-of-memory | Increase memory limit or fix memory leak |
| `Error` | Container exited with non-zero | `kubectl logs <pod> --previous` |
| `Completed` | Container ran and exited 0 | Normal for Jobs; not for long-running pods |
| `Terminating` | Graceful shutdown in progress | Stuck? Check finalizers or force delete |
| `Unknown` | Node unreachable | Check node status |
| `Evicted` | Evicted due to resource pressure | Check node disk/memory pressure |
| `CreateContainerConfigError` | Bad env var or volume ref | `kubectl describe pod` → check config |
| `InvalidImageName` | Malformed image reference | Fix image name in spec |
| `Init:X/Y` | X of Y init containers complete | `kubectl logs <pod> -c <init-container>` |
| `Init:CrashLoopBackOff` | Init container crashing | `kubectl logs <pod> -c <init-container-name>` |
| `PodInitializing` | All init containers done, starting main | Normal transient state |

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

## Quick Diagnosis Commands

### Describe (always first)

```bash
# Pod
kubectl describe pod <name>
kubectl describe pod <name> -n <namespace>

# Check Events section at the bottom of describe
kubectl describe pod <name> | tail -30

# Deployment
kubectl describe deploy <name>

# Node
kubectl describe node <name>

# Service (check selector matches pod labels!)
kubectl describe svc <name>

# Check service selector vs pod labels
kubectl get svc <name> -o jsonpath='{.spec.selector}'
kubectl get pods -l <key>=<value>
```

### Logs

```bash
# Current logs
kubectl logs <pod>
kubectl logs <pod> -c <container>

# Previous (crashed) container
kubectl logs <pod> --previous
kubectl logs <pod> -c <container> --previous

# Follow
kubectl logs <pod> -f --tail=100

# Multiple pods via label
kubectl logs -l app=myapp --all-containers --prefix

# Since timestamp / duration
kubectl logs <pod> --since=30m
kubectl logs <pod> --since-time=2026-01-15T10:00:00Z
```

### Events

```bash
# All events in namespace, sorted by time
kubectl get events --sort-by=.lastTimestamp

# All namespaces
kubectl get events -A --sort-by=.lastTimestamp

# Warnings only
kubectl get events --field-selector=type=Warning

# Events for a specific pod
kubectl get events --field-selector=involvedObject.name=<pod>

# Watch events in real time
kubectl get events -w

# Formatted event list
kubectl get events -o custom-columns='TIME:.lastTimestamp,TYPE:.type,REASON:.reason,OBJECT:.involvedObject.name,MESSAGE:.message' --sort-by=.lastTimestamp
```

### Exec for Live Debugging

```bash
# Shell into running pod
kubectl exec -it <pod> -- bash
kubectl exec -it <pod> -- sh           # Alpine/BusyBox

# Run one-off command
kubectl exec <pod> -- env
kubectl exec <pod> -- cat /etc/config/app.conf
kubectl exec <pod> -- wget -qO- localhost:8080/healthz
kubectl exec <pod> -- curl -s localhost:8080/metrics | head -20

# Check process list
kubectl exec <pod> -- ps aux

# Check network in pod
kubectl exec <pod> -- ss -tlnp
kubectl exec <pod> -- cat /etc/resolv.conf
```

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

## Node Troubleshooting

```bash
# Node status overview
kubectl get nodes -o wide
kubectl get nodes -o custom-columns='NAME:.metadata.name,STATUS:.status.conditions[-1].type,REASON:.status.conditions[-1].reason,MEMORY:.status.allocatable.memory,CPU:.status.allocatable.cpu'

# Node conditions
kubectl get node <name> -o jsonpath='{range .status.conditions[*]}{.type}: {.status} ({.reason}){"\n"}{end}'

# Node resource usage
kubectl top node
kubectl top node --sort-by=cpu
kubectl top node --sort-by=memory

# Pods on specific node
kubectl get pods -A --field-selector=spec.nodeName=<node>

# Check node pressure conditions
kubectl describe node <name> | grep -A5 Conditions

# k3s agent logs (on the node itself)
journalctl -u k3s-agent -f
journalctl -u k3s -f

# Node disk usage
df -h
du -sh /var/lib/rancher/k3s/

# Check kubelet status on node
systemctl status k3s
systemctl status k3s-agent

# Check system resources on node
free -h
vmstat 1 5
iostat -x 1 5
```

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

## Network Debugging One-liners

```bash
# Launch netshoot debug pod
kubectl run netshoot --image=nicolaka/netshoot -it --rm -- bash

# Test connectivity to service
kubectl run curl-test --image=curlimages/curl -it --rm -- curl -v http://<service>.<ns>.svc.cluster.local

# Test DNS resolution
kubectl run dns-test --image=busybox:1.28 -it --rm -- nslookup <service>.<namespace>

# Test NodePort from outside
curl http://<node-ip>:<nodeport>

# Test connectivity between pods
kubectl exec -it <pod-a> -- wget -qO- http://<pod-b-ip>:8080

# Check if service has endpoints
kubectl get endpoints <service-name>
# Empty subsets = no matching pods!

# Trace network policy issues
kubectl run netshoot -it --rm --image=nicolaka/netshoot -- \
  nmap -p 8080 <service-cluster-ip>

# Check kube-proxy / flannel
kubectl get pods -n kube-system | grep -E "flannel|kube-proxy"

# Check CoreDNS
kubectl get pods -n kube-system -l k8s-app=kube-dns
kubectl logs -n kube-system -l k8s-app=kube-dns

# iptables NAT rules for service
sudo iptables -t nat -L KUBE-SERVICES -n | grep <cluster-ip>
```

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

## Common Error Patterns & Fixes

| Error | Cause | Fix |
|-------|-------|-----|
| `ImagePullBackOff` | Wrong image name/tag | Fix `image:` field; check with `docker pull` locally |
| `ImagePullBackOff` | Private registry, no credentials | Add `imagePullSecrets` + create docker-registry secret |
| `CrashLoopBackOff` | App exits immediately | Check `kubectl logs --previous`; fix app or entrypoint |
| `CrashLoopBackOff` | Missing env var / secret | `kubectl describe pod` → check `CreateContainerConfigError` |
| `OOMKilled` | Memory limit too low | Increase `resources.limits.memory`; profile app |
| `Pending` forever | No nodes match affinity | `kubectl describe pod` → check `NodeAffinity` events |
| `Pending` forever | Insufficient CPU/memory | `kubectl describe pod` → `Insufficient cpu/memory`; scale nodes |
| `Pending` forever | PVC not bound | Check PVC status; check StorageClass |
| `Terminating` forever | Finalizer blocking deletion | `kubectl patch <resource> -p '{"metadata":{"finalizers":null}}'` |
| `Error from server: etcdserver: request timeout` | etcd overloaded | Check etcd disk I/O; use SSD |
| `connection refused` on service | No endpoints / selector mismatch | `kubectl get ep <svc>`; check pod labels vs service selector |
| `no such host` DNS error | CoreDNS not running / wrong namespace | Check CoreDNS pods; verify FQDN |
| `x509: certificate` error | TLS cert mismatch / expired | Check cert SANs; `k3s certificate rotate` |
| `cannot list resource "pods"` | Missing RBAC permissions | Add Role/ClusterRole with correct rules |
| `resource quota exceeded` | Namespace quota hit | `kubectl describe quota -n <ns>`; increase or clean up |
| `pod disruption budget` blocks drain | PDB minAvailable not met | Temporarily delete PDB or scale up first |

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

## Debug Pod Snippets

```bash
# General purpose debug (netshoot)
kubectl run debug --image=nicolaka/netshoot \
  --restart=Never -it --rm

# BusyBox minimal debug
kubectl run debug --image=busybox:1.28 \
  --restart=Never -it --rm -- sh

# Debug in same namespace as app
kubectl run debug -n production \
  --image=nicolaka/netshoot \
  --restart=Never -it --rm

# Debug with same SA as app (for RBAC testing)
kubectl run debug --image=curlimages/curl \
  --overrides='{"spec":{"serviceAccountName":"my-app-sa"}}' \
  --restart=Never -it --rm

# Ephemeral debug container (kubectl 1.23+)
kubectl debug -it <pod> --image=nicolaka/netshoot --target=<container>
kubectl debug -it <pod> --image=busybox --copy-to=debug-pod

# Debug node (runs privileged pod on node)
kubectl debug node/<node-name> -it --image=ubuntu
```

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

## DNS Testing

```bash
# Basic nslookup
kubectl run dns-test --image=busybox:1.28 --restart=Never -it --rm -- \
  nslookup kubernetes.default.svc.cluster.local

# Dig with full output
kubectl run dns-test --image=nicolaka/netshoot --restart=Never -it --rm -- \
  dig +search kubernetes.default

# Test service DNS patterns
kubectl exec -it <any-pod> -- nslookup <service>            # same ns
kubectl exec -it <any-pod> -- nslookup <service>.<ns>       # cross-ns
kubectl exec -it <any-pod> -- nslookup <service>.<ns>.svc   # explicit svc
kubectl exec -it <any-pod> -- nslookup <service>.<ns>.svc.cluster.local  # FQDN

# Check /etc/resolv.conf
kubectl exec -it <pod> -- cat /etc/resolv.conf
# Expected: search <ns>.svc.cluster.local svc.cluster.local cluster.local

# CoreDNS config
kubectl get cm coredns -n kube-system -o yaml

# Restart CoreDNS
kubectl rollout restart deploy/coredns -n kube-system
```

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

## Certificate Debugging

```bash
# Check TLS cert on endpoint
openssl s_client -connect <hostname>:443 -servername <hostname> 2>/dev/null | \
  openssl x509 -noout -text | grep -E 'Subject:|Issuer:|Not Before:|Not After:|DNS:'

# Check cert expiry
openssl s_client -connect <host>:443 2>/dev/null | \
  openssl x509 -noout -dates

# Check k3s server certificates
sudo openssl x509 -noout -text -in /var/lib/rancher/k3s/server/tls/server-ca.crt | \
  grep -E 'Not (Before|After)'

# List all k3s TLS certs and expiry
for cert in /var/lib/rancher/k3s/server/tls/*.crt; do
  echo "=== $cert ==="
  openssl x509 -noout -dates -in "$cert" 2>/dev/null
done

# Rotate k3s certificates
k3s certificate rotate
systemctl restart k3s

# Check cert-manager certificates
kubectl get certificates -A
kubectl describe certificate <name> -n <ns>
kubectl get certificaterequest -A
kubectl get order -A            # ACME orders
kubectl get challenge -A        # ACME challenges

# Check cert-manager logs
kubectl logs -n cert-manager deploy/cert-manager
```

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

## Performance Quick Checks

```bash
# Cluster-wide resource usage
kubectl top nodes
kubectl top pods -A --sort-by=cpu | head -20
kubectl top pods -A --sort-by=memory | head -20

# Identify resource hogs
kubectl get pods -A -o json | jq -r '.items[] | "\(.metadata.namespace)/\(.metadata.name): cpu=\(.spec.containers[0].resources.limits.cpu // "none") mem=\(.spec.containers[0].resources.limits.memory // "none")"' | sort

# Check etcd performance
k3s etcd-snapshot list
# Check etcd latency via metrics (requires port-forward)
kubectl port-forward -n kube-system svc/prometheus-kube-prometheus-prometheus 9090:9090
# Query: histogram_quantile(0.99, rate(etcd_disk_wal_fsync_duration_seconds_bucket[5m]))

# API server latency
kubectl get --raw /metrics | grep apiserver_request_duration

# Node conditions (pressure indicators)
kubectl get nodes -o json | jq -r '.items[] | "\(.metadata.name): \(.status.conditions[] | select(.status=="True") | .type)"'

# Disk pressure on nodes
kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{": "}{range .status.conditions[?(@.type=="DiskPressure")]}{.status}{end}{"\n"}{end}'

# Check for resource quota usage
kubectl get resourcequota -A
kubectl describe resourcequota -A

# Check LimitRanges
kubectl get limitrange -A
kubectl describe limitrange -A
```

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---
*Licensed under [CC BY-NC-SA 4.0](../LICENSE.md) · © 2026 UncleJS*
