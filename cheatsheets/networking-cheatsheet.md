# Networking Cheatsheet

> Mastering k3s Course | [↑ Course Index](../README.md)

## Service Types Reference

| Type | Cluster Access | External Access | Use Case |
|------|---------------|-----------------|----------|
| `ClusterIP` | Yes (cluster DNS) | No | Internal microservices |
| `NodePort` | Yes | Yes (node IP + port 30000-32767) | Dev/test, no load balancer |
| `LoadBalancer` | Yes | Yes (external IP via cloud or Klipper) | Production external access |
| `ExternalName` | Yes (CNAME) | No | Alias to external DNS name |
| `Headless` (`clusterIP: None`) | Yes (DNS → pod IPs) | No | StatefulSets, direct pod addressing |

## kubectl for Services & Endpoints

```bash
# List services
kubectl get svc
kubectl get svc -A -o wide

# Service details (includes selectors and ports)
kubectl describe svc <name>

# Get endpoints (backing pod IPs)
kubectl get endpoints <name>
kubectl get ep <name> -o yaml

# Check if service has endpoints
kubectl get ep <name> -o jsonpath='{.subsets}'

# List all services with their types
kubectl get svc -A -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name,TYPE:.spec.type,CLUSTER-IP:.spec.clusterIP,EXTERNAL-IP:.status.loadBalancer.ingress[0].ip,PORT:.spec.ports[0].port'

# Get NodePort
kubectl get svc <name> -o jsonpath='{.spec.ports[0].nodePort}'

# Watch service external IP assignment
kubectl get svc <name> -w
```

## Port-Forward Patterns

```bash
# Forward local port to pod
kubectl port-forward pod/<name> <local>:<pod>

# Forward to deployment (load balanced across pods)
kubectl port-forward deploy/<name> 8080:80

# Forward to service
kubectl port-forward svc/<name> 8080:80

# Bind to all interfaces (accessible from network)
kubectl port-forward svc/<name> 8080:80 --address=0.0.0.0

# Background port-forward
kubectl port-forward svc/grafana 3000:80 -n monitoring &
PF_PID=$!
# ... do work ...
kill $PF_PID

# Common port-forwards
kubectl port-forward svc/prometheus-grafana 3000:80 -n monitoring
kubectl port-forward svc/prometheus-kube-prometheus-prometheus 9090:9090 -n monitoring
kubectl port-forward svc/argocd-server 8080:443 -n argocd
kubectl port-forward svc/longhorn-frontend 8000:80 -n longhorn-system
```

## Flannel / CNI Status

```bash
# Check Flannel pods
kubectl get pods -n kube-flannel
kubectl get pods -A -l app=flannel

# Flannel DaemonSet status
kubectl get ds -n kube-flannel

# Flannel config
kubectl get cm -n kube-flannel kube-flannel-cfg -o yaml

# CNI config on node
ls /etc/cni/net.d/
cat /etc/cni/net.d/10-flannel.conflist

# Check pod network allocation
cat /var/lib/rancher/k3s/server/node-token  # not CNI but related
kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.podCIDR}{"\n"}{end}'

# Flannel backend in use
kubectl get cm -n kube-flannel kube-flannel-cfg -o jsonpath='{.data.net-conf\.json}' | python3 -m json.tool
```

## DNS Testing

```bash
# Test DNS from a debug pod
kubectl run dns-test --image=busybox:1.28 -it --rm -- nslookup kubernetes
kubectl run dns-test --image=busybox:1.28 -it --rm -- nslookup <service>.<namespace>.svc.cluster.local

# Test with netshoot
kubectl run netshoot --image=nicolaka/netshoot -it --rm -- dig kubernetes.default.svc.cluster.local

# Test DNS from inside existing pod
kubectl exec -it <pod> -- nslookup <service>
kubectl exec -it <pod> -- cat /etc/resolv.conf

# Check CoreDNS pods
kubectl get pods -n kube-system -l k8s-app=kube-dns
kubectl logs -n kube-system -l k8s-app=kube-dns

# Check CoreDNS config
kubectl get cm -n kube-system coredns -o yaml

# Test service DNS resolution patterns
# <service>                              (same namespace)
# <service>.<namespace>                  (cross-namespace)
# <service>.<namespace>.svc              (explicit svc)
# <service>.<namespace>.svc.cluster.local  (FQDN)
```

## Traefik IngressRoute Templates

```yaml
# Basic IngressRoute (Traefik v2/v3)
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: my-app
  namespace: default
spec:
  entryPoints:
    - web          # HTTP (port 80)
    - websecure    # HTTPS (port 443)
  routes:
    - match: Host(`app.example.com`)
      kind: Rule
      services:
        - name: my-service
          port: 80
  tls:
    certResolver: letsencrypt
```

```yaml
# IngressRoute with path prefix and middleware
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: my-app-api
  namespace: default
spec:
  entryPoints:
    - websecure
  routes:
    - match: Host(`app.example.com`) && PathPrefix(`/api`)
      kind: Rule
      middlewares:
        - name: strip-prefix
      services:
        - name: api-service
          port: 8080
  tls: {}
---
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: strip-prefix
  namespace: default
spec:
  stripPrefix:
    prefixes:
      - /api
```

```yaml
# Standard Kubernetes Ingress (also works with Traefik)
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: my-app
  annotations:
    traefik.ingress.kubernetes.io/router.entrypoints: websecure
    traefik.ingress.kubernetes.io/router.tls: "true"
spec:
  ingressClassName: traefik
  rules:
    - host: app.example.com
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: my-service
                port:
                  number: 80
  tls:
    - hosts:
        - app.example.com
      secretName: app-tls-secret
```

## NetworkPolicy Templates

```yaml
# Default deny-all ingress
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-ingress
  namespace: production
spec:
  podSelector: {}
  policyTypes:
    - Ingress
```

```yaml
# Default deny-all (ingress + egress)
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: production
spec:
  podSelector: {}
  policyTypes:
    - Ingress
    - Egress
```

```yaml
# Allow specific ingress from namespace + label
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-frontend-to-backend
  namespace: production
spec:
  podSelector:
    matchLabels:
      app: backend
  policyTypes:
    - Ingress
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              name: production
          podSelector:
            matchLabels:
              app: frontend
      ports:
        - protocol: TCP
          port: 8080
```

```yaml
# Allow DNS egress (required if default-deny-egress)
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-dns-egress
  namespace: production
spec:
  podSelector: {}
  policyTypes:
    - Egress
  egress:
    - ports:
        - protocol: UDP
          port: 53
        - protocol: TCP
          port: 53
```

## Netshoot One-liners

```bash
# Launch netshoot debug pod
kubectl run netshoot --image=nicolaka/netshoot -it --rm

# Inside netshoot:
# Test TCP connectivity
nc -zv <service> <port>

# HTTP test
curl -v http://<service>.<namespace>.svc.cluster.local

# DNS lookup
dig <service>.<namespace>.svc.cluster.local
nslookup <service>

# Trace route
traceroute <ip>

# TCP dump
tcpdump -i any port 80 -n

# Check listening ports
ss -tlnp
netstat -tlnp

# Bandwidth test (with iperf3 server on other end)
iperf3 -c <server-ip>

# Run as specific service account
kubectl run netshoot --image=nicolaka/netshoot -it --rm \
  --overrides='{"spec":{"serviceAccountName":"mysa"}}'
```

## iptables Inspection

```bash
# List all rules
sudo iptables -L -n -v

# List NAT rules (ClusterIP/NodePort/LoadBalancer)
sudo iptables -t nat -L -n -v

# List KUBE-SERVICES chain (ClusterIP entries)
sudo iptables -t nat -L KUBE-SERVICES -n -v

# List rules for specific service
sudo iptables -t nat -L KUBE-SERVICES -n -v | grep <clusterIP>

# Show FORWARD chain (inter-pod routing)
sudo iptables -L FORWARD -n -v

# IPVS mode inspection (if using kube-proxy IPVS mode)
sudo ipvsadm -Ln
sudo ipvsadm -Ln --stats

# Check conntrack table
sudo conntrack -L
sudo conntrack -L | grep <ip>

# Count connections per state
sudo ss -s

# Show all active connections
sudo ss -tnp
```

---
*Licensed under [CC BY-NC-SA 4.0](../LICENSE.md) · © 2026 UncleJS*
