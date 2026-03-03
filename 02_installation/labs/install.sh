#!/usr/bin/env bash
# install.sh — k3s single-node installation lab script
# Module 02 · Lab | Course: Mastering k3s
# Licensed under CC BY-NC-SA 4.0 — https://creativecommons.org/licenses/by-nc-sa/4.0/

set -euo pipefail

K3S_VERSION="${K3S_VERSION:-}"   # leave empty for latest stable
K3S_TOKEN="${K3S_TOKEN:-k3s-course-$(openssl rand -hex 12)}"
KUBECONFIG_MODE="${KUBECONFIG_MODE:-644}"
KUBECONFIG_PATH="/etc/rancher/k3s/k3s.yaml"

echo "================================================"
echo "  Mastering k3s — Single-Node Install Lab"
echo "================================================"

# Preflight checks
echo ""
echo "--- Preflight Checks ---"
echo "Note: this lab installs a single-node server (not an agent-only node)."
echo "      Server minimums are 2 CPU cores and 2 GB RAM."

if [[ $EUID -ne 0 ]]; then
  echo "ERROR: This script must be run as root (or with sudo)"
  exit 1
fi

# Check swap
if swapon --show | grep -q .; then
  echo "WARNING: Swap is enabled."
  echo "  For older k3s/kubelet versions, disable it: swapoff -a"
  echo "  For newer versions, configure kubelet swap behavior explicitly if needed"
else
  echo "Swap: OK (disabled)"
fi

# Check cgroup
if stat -fc %T /sys/fs/cgroup/ | grep -q cgroup2fs; then
  echo "cgroup v2: OK"
else
  echo "cgroup v1 detected — k3s will still work but cgroup v2 is recommended"
fi

# Check free disk
DISK_FREE=$(df -BG / | tail -1 | awk '{print $4}' | sed 's/G//')
if [[ $DISK_FREE -lt 5 ]]; then
  echo "ERROR: Less than 5 GB free disk space (found: ${DISK_FREE}G)"
  exit 1
fi
echo "Disk space: OK (${DISK_FREE}G free)"

# Check RAM
RAM_MB=$(free -m | awk '/^Mem:/{print $2}')
if [[ $RAM_MB -lt 2048 ]]; then
  echo "WARNING: Less than 2 GB RAM detected for a server node (found: ${RAM_MB}MB)"
  echo "         Control plane and datastore may be unstable under load"
fi
echo "RAM: OK (${RAM_MB}MB)"

# Check CPU cores
CPU_CORES=$(nproc)
if [[ $CPU_CORES -lt 2 ]]; then
  echo "WARNING: Less than 2 CPU cores detected for a server node (found: ${CPU_CORES})"
  echo "         API responsiveness and scheduling may degrade"
fi
echo "CPU: OK (${CPU_CORES} cores)"

echo ""
echo "--- Installing k3s ---"

echo "Running installer..."
if [[ -n "$K3S_VERSION" ]]; then
  curl -sfL https://get.k3s.io | \
    INSTALL_K3S_VERSION="$K3S_VERSION" \
    K3S_TOKEN="$K3S_TOKEN" \
    sh -s - --write-kubeconfig-mode "$KUBECONFIG_MODE"
else
  curl -sfL https://get.k3s.io | \
    K3S_TOKEN="$K3S_TOKEN" \
    sh -s - --write-kubeconfig-mode "$KUBECONFIG_MODE"
fi

echo ""
echo "--- Waiting for k3s to be Ready ---"
timeout 120 bash -c '
  until kubectl --kubeconfig /etc/rancher/k3s/k3s.yaml get nodes 2>/dev/null | grep -q "Ready"; do
    echo "  Waiting for node to be Ready..."
    sleep 5
  done
'

echo ""
echo "--- Installation Complete! ---"
echo ""
echo "Node status:"
kubectl --kubeconfig "$KUBECONFIG_PATH" get nodes
echo ""
echo "System pods:"
kubectl --kubeconfig "$KUBECONFIG_PATH" get pods -n kube-system
echo ""
echo "Your agent join token (save this for joining agent nodes):"
echo "  $(cat /var/lib/rancher/k3s/server/node-token)"
echo ""
echo "Kubeconfig saved to: /etc/rancher/k3s/k3s.yaml"
echo "Run: export KUBECONFIG=/etc/rancher/k3s/k3s.yaml"
