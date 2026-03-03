#!/usr/bin/env bash
# verify.sh — k3s post-install verification lab script
# Module 02 · Lab | Course: Mastering k3s
# Licensed under CC BY-NC-SA 4.0 — https://creativecommons.org/licenses/by-nc-sa/4.0/

set -uo pipefail

PASS=0
FAIL=0
WARN=0

green() { echo -e "\033[0;32m✔ $*\033[0m"; }
red()   { echo -e "\033[0;31m✘ $*\033[0m"; }
yellow(){ echo -e "\033[0;33m⚠ $*\033[0m"; }

check() {
  local desc="$1"
  local cmd="$2"
  if eval "$cmd" &>/dev/null; then
    green "$desc"
    ((PASS++))
  else
    red "$desc"
    ((FAIL++))
  fi
}

warn_check() {
  local desc="$1"
  local cmd="$2"
  if eval "$cmd" &>/dev/null; then
    green "$desc"
    ((PASS++))
  else
    yellow "$desc (warning only)"
    ((WARN++))
  fi
}

echo "================================================"
echo "  Mastering k3s — Installation Verification"
echo "================================================"
echo ""

echo "--- Binary Checks ---"
check "k3s binary exists at /usr/local/bin/k3s" "test -f /usr/local/bin/k3s"
check "k3s binary is executable" "test -x /usr/local/bin/k3s"
check "kubectl symlink exists" "command -v kubectl"
check "k3s crictl available" "k3s crictl --help"

echo ""
echo "--- Service Checks ---"
check "k3s service is active" "systemctl is-active k3s"
check "k3s service is enabled" "systemctl is-enabled k3s"

echo ""
echo "--- API Server Checks ---"
check "API server responds (local)" "curl -sk https://localhost:6443/healthz | grep -q ok"
check "Kubeconfig exists" "test -f /etc/rancher/k3s/k3s.yaml"
check "kubectl can reach API" "kubectl cluster-info"

echo ""
echo "--- Node Checks ---"
check "Node is Ready" "kubectl get nodes | grep -q Ready"
NODES=$(kubectl get nodes --no-headers 2>/dev/null | wc -l)
green "Total nodes: $NODES"

echo ""
echo "--- Core Component Checks ---"
check "CoreDNS is Running" "kubectl get pods -n kube-system -l k8s-app=kube-dns | grep -q Running"
warn_check "Traefik is Running" "kubectl get pods -n kube-system -l app.kubernetes.io/name=traefik | grep -q Running"
check "local-path-provisioner is Running" "kubectl get pods -n kube-system -l app=local-path-provisioner | grep -q Running"
warn_check "metrics-server is Running" "kubectl get pods -n kube-system -l k8s-app=metrics-server | grep -q Running"

echo ""
echo "--- Storage Checks ---"
check "local-path StorageClass exists" "kubectl get storageclass local-path"
check "local-path is default StorageClass" "kubectl get storageclass local-path -o jsonpath='{.metadata.annotations}' | grep -q 'is-default-class.*true'"

echo ""
echo "--- Networking Checks ---"
check "flannel.1 interface exists" "ip link show flannel.1"
check "cni0 bridge exists" "ip link show cni0 2>/dev/null || ip link show flannel.1"

echo ""
echo "--- Token & Certs ---"
check "Node join token file exists" "test -f /var/lib/rancher/k3s/server/node-token"
warn_check "Server join token file exists" "test -f /var/lib/rancher/k3s/server/token"
check "TLS certs directory exists" "test -d /var/lib/rancher/k3s/server/tls"

echo ""
echo "================================================"
echo "  Results: ${PASS} passed | ${FAIL} failed | ${WARN} warnings"
echo "================================================"

if [[ $FAIL -gt 0 ]]; then
  echo ""
  red "Some checks FAILED. Review the output above."
  echo "Check logs with: sudo journalctl -u k3s -n 50"
  exit 1
else
  echo ""
  green "All critical checks passed! Your k3s cluster is ready."
fi
