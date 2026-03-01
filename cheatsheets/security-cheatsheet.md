# Security Cheatsheet

> Mastering k3s Course | [↑ Course Index](../README.md)

## RBAC Commands

```bash
# List roles and cluster roles
kubectl get roles -A
kubectl get clusterroles | grep -v system:

# Describe role/clusterrole
kubectl describe role <name> -n <ns>
kubectl describe clusterrole <name>

# List role bindings
kubectl get rolebindings -A
kubectl get clusterrolebindings

# Describe bindings
kubectl describe rolebinding <name> -n <ns>
kubectl describe clusterrolebinding <name>

# Who has access to a resource?
kubectl get rolebindings,clusterrolebindings -A -o jsonpath='{range .items[?(@.subjects)]}{.metadata.name}{"\t"}{range .subjects[*]}{.kind}/{.name}{" "}{end}{"\n"}{end}'
```

### auth can-i

```bash
# Can current user perform an action?
kubectl auth can-i create pods
kubectl auth can-i delete deployments -n production
kubectl auth can-i get secrets

# Can a specific user perform an action?
kubectl auth can-i list pods --as=jane
kubectl auth can-i create deployments --as=jane -n staging

# Can a ServiceAccount perform an action?
kubectl auth can-i get secrets --as=system:serviceaccount:default:mysa
kubectl auth can-i list pods --as=system:serviceaccount:kube-system:coredns

# List all permissions for current user
kubectl auth can-i --list
kubectl auth can-i --list -n production

# Who am I?
kubectl auth whoami
```

## Role & ClusterRole Templates

```yaml
# Role (namespace-scoped)
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: pod-reader
  namespace: default
rules:
  - apiGroups: [""]
    resources: ["pods", "pods/log"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["apps"]
    resources: ["deployments"]
    verbs: ["get", "list", "watch"]
```

```yaml
# ClusterRole (cluster-wide)
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: namespace-viewer
rules:
  - apiGroups: [""]
    resources: ["namespaces", "nodes"]
    verbs: ["get", "list", "watch"]
  - apiGroups: [""]
    resources: ["pods", "services", "endpoints"]
    verbs: ["get", "list", "watch"]
```

```yaml
# RoleBinding — bind Role to User
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: jane-pod-reader
  namespace: default
subjects:
  - kind: User
    name: jane
    apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: Role
  name: pod-reader
  apiGroup: rbac.authorization.k8s.io
```

```yaml
# ClusterRoleBinding — bind ClusterRole to Group
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: ops-team-viewer
subjects:
  - kind: Group
    name: ops-team
    apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: ClusterRole
  name: namespace-viewer
  apiGroup: rbac.authorization.k8s.io
```

## ServiceAccount Operations

```bash
# List service accounts
kubectl get sa
kubectl get sa -A

# Create service account
kubectl create sa my-service-account
kubectl create sa my-service-account -n production

# Describe (shows secrets)
kubectl describe sa my-service-account

# Create pod using service account
kubectl run my-pod --image=nginx --overrides='{"spec":{"serviceAccountName":"my-service-account"}}'

# Create token for SA (short-lived, Kubernetes 1.22+)
kubectl create token my-service-account
kubectl create token my-service-account --duration=1h

# Create long-lived SA token secret (legacy)
kubectl create secret generic my-sa-token \
  --type=kubernetes.io/service-account-token \
  --from-literal="" \
  -n default
# Then annotate:
kubectl annotate secret my-sa-token kubernetes.io/service-account.name=my-service-account

# Bind ClusterRole to ServiceAccount
kubectl create clusterrolebinding my-sa-binding \
  --clusterrole=view \
  --serviceaccount=default:my-service-account
```

## Secrets

```bash
# Create secrets
kubectl create secret generic db-creds \
  --from-literal=username=admin \
  --from-literal=password=s3cr3t

kubectl create secret generic app-config \
  --from-file=config.yaml \
  --from-file=.env

kubectl create secret docker-registry regcred \
  --docker-server=registry.example.com \
  --docker-username=myuser \
  --docker-password=mypass \
  --docker-email=me@example.com

# TLS secret
kubectl create secret tls my-tls \
  --cert=tls.crt \
  --key=tls.key

# Get and decode
kubectl get secret db-creds -o yaml
kubectl get secret db-creds -o jsonpath='{.data.password}' | base64 -d
kubectl get secret db-creds -o jsonpath='{.data}' | python3 -c "import sys,json,base64; d=json.load(sys.stdin); print({k:base64.b64decode(v).decode() for k,v in d.items()})"

# Edit secret (re-encode before saving)
kubectl edit secret db-creds
# Values must be base64-encoded:
echo -n 'newsecret' | base64
```

## Pod Security Standards

Labels applied to **namespaces** to enforce security levels:

| Level | Description |
|-------|-------------|
| `privileged` | No restrictions |
| `baseline` | Prevents known privilege escalation |
| `restricted` | Strictly hardened (best practice) |

| Mode | Action |
|------|--------|
| `enforce` | Reject non-compliant pods |
| `audit` | Log violations, allow pods |
| `warn` | Warn user, allow pods |

```bash
# Label namespace with Pod Security Standard
kubectl label ns production \
  pod-security.kubernetes.io/enforce=restricted \
  pod-security.kubernetes.io/audit=restricted \
  pod-security.kubernetes.io/warn=restricted

# Check namespace labels
kubectl get ns production --show-labels

# Remove PSS label
kubectl label ns production pod-security.kubernetes.io/enforce-
```

## SecurityContext Template

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: secure-pod
spec:
  securityContext:
    runAsNonRoot: true
    runAsUser: 1000
    runAsGroup: 1000
    fsGroup: 2000
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: app
      image: myapp:latest
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities:
          drop:
            - ALL
          add:
            - NET_BIND_SERVICE   # only if needed
      volumeMounts:
        - name: tmp
          mountPath: /tmp
        - name: var-run
          mountPath: /var/run
  volumes:
    - name: tmp
      emptyDir: {}
    - name: var-run
      emptyDir: {}
```

## NetworkPolicy Templates

```yaml
# Deny all ingress to namespace
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
# Allow only from same namespace
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-same-namespace
  namespace: production
spec:
  podSelector: {}
  ingress:
    - from:
        - podSelector: {}
```

## Sealed Secrets Workflow

```bash
# Install kubeseal CLI
wget https://github.com/bitnami-labs/sealed-secrets/releases/download/v0.26.0/kubeseal-0.26.0-linux-amd64.tar.gz
tar xzf kubeseal-*.tar.gz && sudo mv kubeseal /usr/local/bin/

# Install controller (Helm)
helm repo add sealed-secrets https://bitnami-labs.github.io/sealed-secrets
helm install sealed-secrets sealed-secrets/sealed-secrets -n kube-system

# Seal a secret
kubectl create secret generic db-creds \
  --from-literal=password=s3cr3t \
  --dry-run=client -o yaml \
  | kubeseal --format yaml > db-creds-sealed.yaml

# Seal for specific namespace (namespace-scoped by default)
kubectl create secret generic db-creds \
  --from-literal=password=s3cr3t -n production \
  --dry-run=client -o yaml \
  | kubeseal --namespace production --format yaml > db-creds-sealed.yaml

# Apply sealed secret
kubectl apply -f db-creds-sealed.yaml

# Verify (controller decrypts and creates actual Secret)
kubectl get secret db-creds
kubectl get sealedsecret db-creds

# Fetch public key (for offline sealing)
kubeseal --fetch-cert > pub-cert.pem
kubectl create secret generic db-creds --dry-run=client -o yaml \
  | kubeseal --cert pub-cert.pem --format yaml > db-creds-sealed.yaml
```

## Image Scanning (Trivy)

```bash
# Install Trivy
wget https://github.com/aquasecurity/trivy/releases/download/v0.50.0/trivy_0.50.0_Linux-64bit.tar.gz
tar xzf trivy_*.tar.gz && sudo mv trivy /usr/local/bin/

# Scan image
trivy image nginx:latest
trivy image --severity HIGH,CRITICAL nginx:latest

# Scan with SBOM output
trivy image --format cyclonedx nginx:latest

# Scan Kubernetes cluster
trivy k8s --report summary cluster
trivy k8s -n production --report all

# Scan manifest files
trivy config ./kubernetes/

# Scan running pod's image
IMAGE=$(kubectl get pod <name> -o jsonpath='{.spec.containers[0].image}')
trivy image $IMAGE

# CI pipeline scan (fail on HIGH+)
trivy image --exit-code 1 --severity HIGH,CRITICAL myapp:latest
```

## CIS Compliance (kube-bench)

```bash
# Run kube-bench as pod
kubectl apply -f https://raw.githubusercontent.com/aquasecurity/kube-bench/main/job.yaml
kubectl logs job/kube-bench

# Run specific checks
kubectl apply -f https://raw.githubusercontent.com/aquasecurity/kube-bench/main/job-master.yaml
kubectl logs job/kube-bench-master

# Run locally (must be on cluster node)
kube-bench run --targets node
kube-bench run --targets master
kube-bench run --targets etcd

# Check specific CIS section
kube-bench run --check 4.2.1

# Output as JSON
kube-bench run --json | jq '.Controls[].tests[].results[]|select(.status=="FAIL")'

# Remediation report only
kube-bench run --targets master 2>&1 | grep -A3 '\[FAIL\]'
```

---
*Licensed under [CC BY-NC-SA 4.0](../LICENSE.md) · © 2026 UncleJS*
