# k3s Server Cheatsheet

> Mastering k3s Course | [↑ Course Index](../README.md)


[![Course Index](https://img.shields.io/badge/Course-Index-0f766e)](../README.md)
[![License: CC BY-NC-SA 4.0](https://img.shields.io/badge/License-CC%20BY--NC--SA%204.0-lightgrey)](../LICENSE.md)

## Table of Contents

- [Install Commands](#install-commands)
- [k3s CLI Reference](#k3s-cli-reference)
- [Service Management](#service-management)
- [Config & File Locations](#config--file-locations)
- [Server Flags Quick Reference](#server-flags-quick-reference)
- [Config File Format](#config-file-format)
- [Token Operations](#token-operations)
- [etcd-snapshot Commands](#etcd-snapshot-commands)
- [Private Registry Config](#private-registry-config)
- [Useful k3s One-liners](#useful-k3s-one-liners)
- [Uninstall](#uninstall)

---

## Install Commands

### Online Install

```bash
# Latest server
curl -sfL https://get.k3s.io | sh -

# Specific version
curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION=v1.29.3+k3s1 sh -

# Server with options
curl -sfL https://get.k3s.io | sh -s - server \
  --cluster-init \
  --tls-san=myserver.example.com \
  --disable=traefik

# Agent (join existing cluster)
curl -sfL https://get.k3s.io | K3S_URL=https://<server>:6443 K3S_TOKEN=<token> sh -

# Server (join HA cluster)
curl -sfL https://get.k3s.io | K3S_TOKEN=<token> sh -s - server \
  --server https://<first-server>:6443
```

### Airgap Install

```bash
# 1. Download artifacts on internet-connected machine
wget https://github.com/k3s-io/k3s/releases/download/v1.29.3+k3s1/k3s
wget https://github.com/k3s-io/k3s/releases/download/v1.29.3+k3s1/k3s-airgap-images-amd64.tar.zst
wget https://get.k3s.io -O install.sh

# 2. Copy to airgap node
scp k3s k3s-airgap-images-amd64.tar.zst install.sh user@node:~

# 3. Install on airgap node
sudo mkdir -p /var/lib/rancher/k3s/agent/images/
sudo cp k3s-airgap-images-amd64.tar.zst /var/lib/rancher/k3s/agent/images/
sudo cp k3s /usr/local/bin/k3s && sudo chmod +x /usr/local/bin/k3s
INSTALL_K3S_SKIP_DOWNLOAD=true sh install.sh
```

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

## k3s CLI Reference

| Command | Description |
|---------|-------------|
| `k3s server` | Start k3s server |
| `k3s agent` | Start k3s agent |
| `k3s kubectl` | Embedded kubectl |
| `k3s crictl` | CRI CLI (container runtime) |
| `k3s ctr` | containerd CLI |
| `k3s etcd-snapshot` | Snapshot management |
| `k3s secrets-encrypt` | Secrets encryption management |
| `k3s certificate` | Certificate management |
| `k3s token` | Token management |
| `k3s completion bash` | Shell completion |

### crictl Commands

```bash
k3s crictl ps                        # List running containers
k3s crictl ps -a                     # All containers
k3s crictl images                    # List images
k3s crictl pull nginx:latest         # Pull image
k3s crictl rmi <image-id>            # Remove image
k3s crictl pods                      # List pods (sandbox)
k3s crictl logs <container-id>       # Container logs
k3s crictl exec -it <id> sh          # Exec into container
k3s crictl inspect <container-id>    # Container details
k3s crictl inspectp <pod-id>         # Pod details
k3s crictl stats                     # Container resource stats
```

### ctr Commands

```bash
k3s ctr images ls                    # List images
k3s ctr images pull docker.io/library/nginx:latest
k3s ctr images import myimage.tar    # Import tarball
k3s ctr containers ls                # List containers
k3s ctr tasks ls                     # List running tasks
k3s ctr namespaces ls                # List namespaces (k8s.io is default)
```

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

## Service Management

| Command | Description |
|---------|-------------|
| `systemctl start k3s` | Start k3s server |
| `systemctl stop k3s` | Stop k3s server |
| `systemctl restart k3s` | Restart k3s server |
| `systemctl status k3s` | Service status |
| `systemctl enable k3s` | Enable on boot |
| `systemctl disable k3s` | Disable on boot |
| `journalctl -u k3s -f` | Follow server logs |
| `journalctl -u k3s --since "1 hour ago"` | Recent logs |
| `systemctl status k3s-agent` | Agent service status |
| `journalctl -u k3s-agent -f` | Follow agent logs |

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

## Config & File Locations

| Path | Description |
|------|-------------|
| `/etc/rancher/k3s/k3s.yaml` | kubeconfig (root) |
| `/etc/rancher/k3s/config.yaml` | k3s server config file |
| `/etc/rancher/k3s/registries.yaml` | Private registry config |
| `/var/lib/rancher/k3s/server/` | Server data directory |
| `/var/lib/rancher/k3s/server/db/` | Embedded etcd / SQLite DB |
| `/var/lib/rancher/k3s/server/tls/` | TLS certificates |
| `/var/lib/rancher/k3s/server/token` | Server join token |
| `/var/lib/rancher/k3s/server/node-token` | Node join token |
| `/var/lib/rancher/k3s/agent/` | Agent data directory |
| `/var/lib/rancher/k3s/agent/images/` | Airgap image tarballs |
| `/var/lib/rancher/k3s/storage/` | Local-path provisioner |
| `/etc/rancher/node/password` | Node password file |
| `/usr/local/bin/k3s` | k3s binary |
| `/usr/local/bin/k3s-uninstall.sh` | Server uninstall script |
| `/usr/local/bin/k3s-agent-uninstall.sh` | Agent uninstall script |
| `/etc/systemd/system/k3s.service` | Systemd unit (server) |
| `/etc/systemd/system/k3s-agent.service` | Systemd unit (agent) |
| `/var/lib/rancher/k3s/server/manifests/` | Auto-deploy manifests |
| `/var/lib/rancher/k3s/server/static/` | Static file serving |

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

## Server Flags Quick Reference

### Cluster Init & HA

| Flag | Default | Description |
|------|---------|-------------|
| `--cluster-init` | false | Bootstrap embedded etcd (first server) |
| `--cluster-reset` | false | Reset etcd and become sole member |
| `--server <url>` | — | Join URL for additional servers |
| `--token <str>` | — | Shared cluster secret |
| `--token-file <path>` | — | Token file path |

### TLS & Networking

| Flag | Default | Description |
|------|---------|-------------|
| `--tls-san <host>` | — | Add SAN to TLS cert (repeat for multiple) |
| `--bind-address <ip>` | 0.0.0.0 | API server bind address |
| `--advertise-address <ip>` | — | IP to advertise to agents |
| `--advertise-port <port>` | 6443 | Port to advertise |
| `--https-listen-port <port>` | 6443 | HTTPS listener port |
| `--cluster-cidr <cidr>` | 10.42.0.0/16 | Pod CIDR |
| `--service-cidr <cidr>` | 10.43.0.0/16 | Service CIDR |
| `--cluster-dns <ip>` | 10.43.0.10 | CoreDNS IP |
| `--cluster-domain <domain>` | cluster.local | Cluster domain |
| `--flannel-backend <type>` | vxlan | none/host-gw/wireguard-native/vxlan |
| `--flannel-iface <iface>` | — | Override flannel interface |

### Component Control

| Flag | Description |
|------|-------------|
| `--disable=traefik` | Disable Traefik ingress |
| `--disable=servicelb` | Disable ServiceLB (Klipper) |
| `--disable=local-storage` | Disable local-path provisioner |
| `--disable=coredns` | Disable CoreDNS |
| `--disable=metrics-server` | Disable metrics-server |
| `--disable-network-policy` | Disable network policy controller |
| `--disable-helm-controller` | Disable HelmChart controller |

### Datastore

| Flag | Description |
|------|-------------|
| `--datastore-endpoint=<url>` | External DB (postgres/mysql) |
| `--datastore-cafile=<path>` | CA cert for external DB TLS |
| `--datastore-certfile=<path>` | Client cert for external DB |
| `--datastore-keyfile=<path>` | Client key for external DB |

### Kubelet & Agent

| Flag | Description |
|------|-------------|
| `--node-label=key=val` | Add label to server node |
| `--node-taint=key=val:Effect` | Add taint to server node |
| `--kubelet-arg=<arg>` | Pass arg to kubelet |
| `--kube-apiserver-arg=<arg>` | Pass arg to API server |
| `--kube-controller-manager-arg=<arg>` | Pass arg to controller manager |
| `--kube-scheduler-arg=<arg>` | Pass arg to scheduler |
| `--protect-kernel-defaults` | Fail if kernel params differ from kubelet defaults |

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

## Config File Format

```yaml
# /etc/rancher/k3s/config.yaml
cluster-init: true
tls-san:
  - "myserver.example.com"
  - "192.168.1.100"
disable:
  - traefik
  - servicelb
flannel-backend: wireguard-native
cluster-cidr: 10.42.0.0/16
service-cidr: 10.43.0.0/16
write-kubeconfig-mode: "0644"
node-label:
  - "node-type=server"
```

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

## Token Operations

```bash
# Get node join token
sudo cat /var/lib/rancher/k3s/server/node-token

# Get agent-only token (if set separately)
sudo cat /var/lib/rancher/k3s/server/token

# Rotate token (k3s v1.28+)
k3s token rotate --new-token=<new-token>

# List tokens
k3s token list
```

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

## etcd-snapshot Commands

```bash
# On-demand snapshot
k3s etcd-snapshot save
k3s etcd-snapshot save --name=pre-upgrade

# List snapshots
k3s etcd-snapshot list

# Delete snapshot
k3s etcd-snapshot delete --name=<name>

# Restore snapshot (stop k3s first!)
systemctl stop k3s
k3s server --cluster-reset --cluster-reset-restore-path=/var/lib/rancher/k3s/server/db/snapshots/<name>
systemctl start k3s

# Scheduled snapshots (config.yaml)
# etcd-snapshot-schedule-cron: "0 */6 * * *"
# etcd-snapshot-retention: 5
# etcd-snapshot-dir: /opt/k3s-snapshots
```

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

## Private Registry Config

```yaml
# /etc/rancher/k3s/registries.yaml
mirrors:
  "docker.io":
    endpoint:
      - "https://registry.example.com"
configs:
  "registry.example.com":
    auth:
      username: myuser
      password: mypassword
    tls:
      ca_file: /etc/ssl/certs/registry-ca.crt
```

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

## Useful k3s One-liners

```bash
# Copy kubeconfig for regular user
sudo cp /etc/rancher/k3s/k3s.yaml ~/.kube/config
sudo chown $USER ~/.kube/config

# Watch k3s startup logs
journalctl -u k3s -f

# Check k3s version
k3s --version

# Check embedded etcd member list
k3s etcd-snapshot list
ETCDCTL_ENDPOINTS='https://127.0.0.1:2379' \
  ETCDCTL_CACERT='/var/lib/rancher/k3s/server/tls/etcd/server-ca.crt' \
  ETCDCTL_CERT='/var/lib/rancher/k3s/server/tls/etcd/client.crt' \
  ETCDCTL_KEY='/var/lib/rancher/k3s/server/tls/etcd/client.key' \
  ETCDCTL_API=3 etcdctl member list

# Rotate TLS certificates
k3s certificate rotate

# Rotate specific cert
k3s certificate rotate --service api-server

# Dump server config
k3s server --help 2>&1 | less

# Check loaded images in containerd
k3s crictl images | sort

# Preload image to all nodes
k3s ctr images import myimage.tar
```

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

## Uninstall

```bash
# Server
/usr/local/bin/k3s-uninstall.sh

# Agent
/usr/local/bin/k3s-agent-uninstall.sh

# Manual cleanup (if scripts are gone)
systemctl stop k3s k3s-agent
rm -f /usr/local/bin/k3s
rm -f /etc/systemd/system/k3s*.service
rm -rf /etc/rancher /var/lib/rancher /var/lib/kubelet
systemctl daemon-reload
```

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---
*Licensed under [CC BY-NC-SA 4.0](../LICENSE.md) · © 2026 UncleJS*
