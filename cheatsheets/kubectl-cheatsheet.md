# kubectl Cheatsheet

> Mastering k3s Course | [↑ Course Index](../README.md)

## Table of Contents

- [Cluster Info](#cluster-info)
- [Contexts](#contexts)
- [Nodes](#nodes)
- [Pods](#pods)
- [Deployments](#deployments)
- [Services](#services)
- [ConfigMaps & Secrets](#configmaps--secrets)
- [Namespaces](#namespaces)
- [Labels & Selectors](#labels--selectors)
- [Resource Management](#resource-management)
- [Port-Forward](#port-forward)
- [Copy Files](#copy-files)
- [Events](#events)
- [RBAC Quick Checks](#rbac-quick-checks)
- [Output Formats](#output-formats)
- [Useful Aliases](#useful-aliases)

---

## Cluster Info

| Command | Description |
|---------|-------------|
| `kubectl cluster-info` | Show cluster endpoint URLs |
| `kubectl cluster-info dump` | Full cluster diagnostic dump |
| `kubectl version --short` | Client and server versions |
| `kubectl api-resources` | All available resource types |
| `kubectl api-versions` | All available API versions |
| `kubectl explain pod.spec.containers` | Field docs for any resource |

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

## Contexts

| Command | Description |
|---------|-------------|
| `kubectl config get-contexts` | List all contexts |
| `kubectl config current-context` | Show active context |
| `kubectl config use-context <name>` | Switch context |
| `kubectl config set-context --current --namespace=<ns>` | Set default namespace |
| `kubectl config view --minify` | Show current context config |
| `kubectl config delete-context <name>` | Remove a context |

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

## Nodes

| Command | Description |
|---------|-------------|
| `kubectl get nodes` | List nodes |
| `kubectl get nodes -o wide` | List with IPs and OS info |
| `kubectl describe node <name>` | Full node details |
| `kubectl top node` | CPU/memory usage |
| `kubectl cordon <node>` | Mark node unschedulable |
| `kubectl uncordon <node>` | Mark node schedulable |
| `kubectl drain <node> --ignore-daemonsets --delete-emptydir-data` | Evict all pods |
| `kubectl taint nodes <node> key=val:NoSchedule` | Add taint |
| `kubectl taint nodes <node> key:NoSchedule-` | Remove taint |

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

## Pods

### Get / Describe

| Command | Description |
|---------|-------------|
| `kubectl get pods` | List pods in current namespace |
| `kubectl get pods -A` | List pods in all namespaces |
| `kubectl get pods -o wide` | Include node and IP |
| `kubectl get pods --field-selector=status.phase=Running` | Filter by phase |
| `kubectl get pods --sort-by=.metadata.creationTimestamp` | Sort by creation time |
| `kubectl describe pod <name>` | Full pod details and events |

### Logs

| Command | Description |
|---------|-------------|
| `kubectl logs <pod>` | Stdout of first container |
| `kubectl logs <pod> -c <container>` | Specific container |
| `kubectl logs <pod> --previous` | Previous (crashed) container |
| `kubectl logs <pod> -f` | Follow (tail) logs |
| `kubectl logs <pod> --tail=100` | Last 100 lines |
| `kubectl logs <pod> --since=1h` | Logs from last hour |
| `kubectl logs -l app=myapp --all-containers` | Logs across label selector |

### Exec / Run

| Command | Description |
|---------|-------------|
| `kubectl exec -it <pod> -- bash` | Interactive shell |
| `kubectl exec -it <pod> -c <container> -- sh` | Shell in specific container |
| `kubectl exec <pod> -- env` | Non-interactive command |
| `kubectl run debug --image=nicolaka/netshoot -it --rm` | Ephemeral debug pod |
| `kubectl run debug --image=busybox -it --rm -- sh` | BusyBox debug shell |

### Delete

| Command | Description |
|---------|-------------|
| `kubectl delete pod <name>` | Delete pod (graceful) |
| `kubectl delete pod <name> --grace-period=0 --force` | Force delete immediately |
| `kubectl delete pods --all` | Delete all pods in namespace |
| `kubectl delete pods -l app=myapp` | Delete by label |

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

## Deployments

| Command | Description |
|---------|-------------|
| `kubectl get deploy` | List deployments |
| `kubectl describe deploy <name>` | Deployment details |
| `kubectl rollout status deploy/<name>` | Watch rollout progress |
| `kubectl rollout history deploy/<name>` | Revision history |
| `kubectl rollout undo deploy/<name>` | Roll back one revision |
| `kubectl rollout undo deploy/<name> --to-revision=2` | Roll back to revision N |
| `kubectl rollout restart deploy/<name>` | Trigger rolling restart |
| `kubectl scale deploy/<name> --replicas=3` | Scale deployment |
| `kubectl set image deploy/<name> app=image:tag` | Update container image |
| `kubectl autoscale deploy/<name> --min=2 --max=10 --cpu-percent=80` | Create HPA |

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

## Services

| Command | Description |
|---------|-------------|
| `kubectl get svc` | List services |
| `kubectl get svc -o wide` | Include selectors and ports |
| `kubectl describe svc <name>` | Service details + endpoints |
| `kubectl get endpoints <name>` | Show backing pod IPs |
| `kubectl expose deploy/<name> --port=80 --target-port=8080` | Expose deployment |
| `kubectl delete svc <name>` | Delete service |

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

## ConfigMaps & Secrets

| Command | Description |
|---------|-------------|
| `kubectl get cm` | List ConfigMaps |
| `kubectl describe cm <name>` | ConfigMap data |
| `kubectl create cm <name> --from-literal=key=val` | Create from literal |
| `kubectl create cm <name> --from-file=config.yaml` | Create from file |
| `kubectl get secret` | List Secrets |
| `kubectl describe secret <name>` | Secret metadata (no values) |
| `kubectl create secret generic <name> --from-literal=pass=secret` | Create generic secret |
| `kubectl create secret docker-registry <name> --docker-server=... --docker-username=... --docker-password=...` | Registry pull secret |
| `kubectl get secret <name> -o jsonpath='{.data.password}' \| base64 -d` | Decode secret value |

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

## Namespaces

| Command | Description |
|---------|-------------|
| `kubectl get ns` | List namespaces |
| `kubectl create ns <name>` | Create namespace |
| `kubectl delete ns <name>` | Delete namespace and all resources |
| `kubectl get all -n <name>` | All resources in namespace |
| `kubectl -n <name> <command>` | Run command in namespace |

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

## Labels & Selectors

| Command | Description |
|---------|-------------|
| `kubectl get pods -l app=myapp` | Filter by label |
| `kubectl get pods -l 'env in (prod,staging)'` | Set-based selector |
| `kubectl get pods -l app=myapp,env=prod` | Multiple labels (AND) |
| `kubectl label pod <name> env=prod` | Add/update label |
| `kubectl label pod <name> env-` | Remove label |
| `kubectl annotate pod <name> note="test"` | Add annotation |

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

## Resource Management

### Apply / Edit / Patch / Delete

| Command | Description |
|---------|-------------|
| `kubectl apply -f manifest.yaml` | Apply declarative config |
| `kubectl apply -f ./dir/` | Apply all files in directory |
| `kubectl apply -k ./overlays/prod` | Apply Kustomize overlay |
| `kubectl create -f manifest.yaml` | Imperative create |
| `kubectl replace -f manifest.yaml` | Replace (must exist) |
| `kubectl edit deploy/<name>` | Edit live resource in $EDITOR |
| `kubectl patch deploy/<name> -p '{"spec":{"replicas":2}}'` | Strategic merge patch |
| `kubectl patch deploy/<name> --type=json -p '[{"op":"replace","path":"/spec/replicas","value":2}]'` | JSON patch |
| `kubectl delete -f manifest.yaml` | Delete by manifest |
| `kubectl delete deploy,svc -l app=myapp` | Delete multiple types by label |

### Top (Metrics)

| Command | Description |
|---------|-------------|
| `kubectl top node` | Node CPU/mem usage |
| `kubectl top pod` | Pod CPU/mem usage |
| `kubectl top pod --containers` | Per-container usage |
| `kubectl top pod -l app=myapp` | Usage by label |

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

## Port-Forward

```bash
# Pod
kubectl port-forward pod/<name> 8080:80

# Deployment (picks a pod)
kubectl port-forward deploy/<name> 8080:80

# Service
kubectl port-forward svc/<name> 8080:80

# Bind to all interfaces
kubectl port-forward svc/<name> 8080:80 --address=0.0.0.0
```

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

## Copy Files

```bash
# Host -> Pod
kubectl cp /local/path <pod>:/remote/path

# Pod -> Host
kubectl cp <pod>:/remote/path /local/path

# Specific container
kubectl cp <pod>:/path /local/path -c <container>
```

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

## Events

| Command | Description |
|---------|-------------|
| `kubectl get events` | Events in current namespace |
| `kubectl get events -A` | All namespace events |
| `kubectl get events --sort-by=.lastTimestamp` | Sort by time |
| `kubectl get events --field-selector=type=Warning` | Warnings only |
| `kubectl get events --field-selector=involvedObject.name=<pod>` | Events for specific pod |

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

## RBAC Quick Checks

```bash
# Can I do this?
kubectl auth can-i create pods
kubectl auth can-i delete deployments -n production

# Can user X do this?
kubectl auth can-i list secrets --as=jane
kubectl auth can-i get pods --as=system:serviceaccount:default:mysa

# List all permissions for current user
kubectl auth whoami
kubectl auth can-i --list
kubectl auth can-i --list -n kube-system
```

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

## Output Formats

| Flag | Description | Example |
|------|-------------|---------|
| `-o wide` | Extra columns | `kubectl get pods -o wide` |
| `-o yaml` | Full YAML manifest | `kubectl get pod foo -o yaml` |
| `-o json` | Full JSON | `kubectl get pod foo -o json` |
| `-o name` | Resource/name only | `kubectl get pods -o name` |
| `-o jsonpath='...'` | JSONPath expression | `kubectl get pod foo -o jsonpath='{.status.podIP}'` |
| `-o custom-columns=...` | Custom column output | See below |
| `-o go-template=...` | Go template | Advanced templating |

```bash
# JSONPath examples
kubectl get pods -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.podIP}{"\n"}{end}'
kubectl get nodes -o jsonpath='{.items[*].status.addresses[?(@.type=="InternalIP")].address}'

# Custom columns
kubectl get pods -o custom-columns='NAME:.metadata.name,NODE:.spec.nodeName,IP:.status.podIP'

# Get all image names
kubectl get pods -A -o jsonpath='{range .items[*]}{.spec.containers[*].image}{"\n"}{end}' | sort -u
```

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

## Useful Aliases

```bash
# Add to ~/.bashrc or ~/.zshrc
alias k='kubectl'
alias kn='kubectl -n'
alias kgp='kubectl get pods'
alias kgpa='kubectl get pods -A'
alias kgn='kubectl get nodes'
alias kd='kubectl describe'
alias kdp='kubectl describe pod'
alias kl='kubectl logs'
alias klf='kubectl logs -f'
alias ke='kubectl exec -it'
alias ka='kubectl apply -f'
alias kaf='kubectl apply -f'
alias kak='kubectl apply -k'
alias kdel='kubectl delete'
alias kctx='kubectl config use-context'
alias kns='kubectl config set-context --current --namespace'

# Kubernetes namespace switcher (requires kubens)
# kubens <namespace>

# Watch pods (requires watch)
alias watchpods='watch kubectl get pods'

# Kubecolor for colorized output
# alias kubectl='kubecolor'
```

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---
*Licensed under [CC BY-NC-SA 4.0](../LICENSE.md) · © 2026 UncleJS*
