#!/usr/bin/env bash
# install-rancher.sh — Rancher installation on k3s via Helm
# Module 18 · Lab | Course: Mastering k3s
# Licensed under CC BY-NC-SA 4.0 — https://creativecommons.org/licenses/by-nc-sa/4.0/

set -euo pipefail

# ──────────────────────────────────────────────
#  Defaults
# ──────────────────────────────────────────────
HOSTNAME_ARG=""
TLS_SOURCE="rancher"
LE_EMAIL=""
BOOTSTRAP_PASSWORD="changeme"
REPLICAS="1"
RANCHER_VERSION=""           # empty = latest stable
CERT_MANAGER_VERSION="v1.14.5"
SKIP_CERT_MANAGER=false
DRY_RUN=false
FORCE=false

KUBECONFIG_PATH="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"

# ──────────────────────────────────────────────
#  Colours & logging helpers
# ──────────────────────────────────────────────
green()  { printf '\033[0;32m✔  %s\033[0m\n' "$*"; }
red()    { printf '\033[0;31m✘  %s\033[0m\n' "$*"; }
yellow() { printf '\033[0;33m⚠  %s\033[0m\n' "$*"; }
blue()   { printf '\033[0;34m→  %s\033[0m\n' "$*"; }

log()  { printf '[INFO]  %s\n' "$*"; }
warn() { yellow "[WARN]  $*"; }
die()  { red    "[ERROR] $*" >&2; exit 1; }

# Wraps every mutating command so --dry-run prints but does not execute.
run() {
  if [[ "$DRY_RUN" == "true" ]]; then
    blue "[DRY-RUN] $*"
  else
    "$@"
  fi
}

# ──────────────────────────────────────────────
#  Usage
# ──────────────────────────────────────────────
usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Install Rancher on a running k3s cluster using Helm.

Options:
  --hostname <host>              Rancher ingress hostname
                                   (default: rancher.<node-ip>.sslip.io)
  --tls <rancher|letsencrypt|secret>
                                 TLS source (default: rancher)
  --le-email <email>             Required when --tls letsencrypt
  --bootstrap-password <pw>      First-login password (default: changeme)
  --replicas <n>                 Rancher pod replicas (default: 1)
  --rancher-version <version>    Helm chart version to pin (default: latest)
  --cert-manager-version <ver>   cert-manager version (default: v1.14.5)
  --skip-cert-manager            Skip cert-manager install/check
  --dry-run                      Print commands without executing them
  --force                        Skip confirmation prompt
  -h, --help                     Show this help

TLS sources:
  rancher      Rancher-generated self-signed cert via cert-manager  [default]
  letsencrypt  Public cert via cert-manager ACME (requires public DNS)
  secret       Bring your own cert stored in a Kubernetes Secret

Examples:
  # Quickstart — auto-detect hostname, self-signed cert
  sudo ./install-rancher.sh

  # Let's Encrypt with a real domain
  sudo ./install-rancher.sh --tls letsencrypt --hostname rancher.example.com --le-email you@example.com

  # Pin a specific Rancher version, dry-run first
  sudo ./install-rancher.sh --rancher-version 2.8.3 --dry-run

  # BYO cert (Secret must exist in cattle-system before running)
  sudo ./install-rancher.sh --tls secret --hostname rancher.example.com
EOF
}

# ──────────────────────────────────────────────
#  Argument parsing
# ──────────────────────────────────────────────
parse_args() {
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --hostname)
        [[ "$#" -ge 2 ]] || die "--hostname requires a value"
        HOSTNAME_ARG="$2"; shift 2 ;;
      --tls)
        [[ "$#" -ge 2 ]] || die "--tls requires a value"
        TLS_SOURCE="$2"; shift 2 ;;
      --le-email)
        [[ "$#" -ge 2 ]] || die "--le-email requires a value"
        LE_EMAIL="$2"; shift 2 ;;
      --bootstrap-password)
        [[ "$#" -ge 2 ]] || die "--bootstrap-password requires a value"
        BOOTSTRAP_PASSWORD="$2"; shift 2 ;;
      --replicas)
        [[ "$#" -ge 2 ]] || die "--replicas requires a value"
        REPLICAS="$2"; shift 2 ;;
      --rancher-version)
        [[ "$#" -ge 2 ]] || die "--rancher-version requires a value"
        RANCHER_VERSION="$2"; shift 2 ;;
      --cert-manager-version)
        [[ "$#" -ge 2 ]] || die "--cert-manager-version requires a value"
        CERT_MANAGER_VERSION="$2"; shift 2 ;;
      --skip-cert-manager) SKIP_CERT_MANAGER=true; shift ;;
      --dry-run)            DRY_RUN=true;           shift ;;
      --force)              FORCE=true;              shift ;;
      -h|--help)            usage; exit 0 ;;
      *) die "Unknown argument: $1. Run with --help for usage." ;;
    esac
  done

  case "$TLS_SOURCE" in
    rancher|letsencrypt|secret) ;;
    *) die "Invalid --tls value '$TLS_SOURCE'. Must be: rancher, letsencrypt, or secret." ;;
  esac

  if [[ "$TLS_SOURCE" == "letsencrypt" && -z "$LE_EMAIL" ]]; then
    die "--le-email is required when --tls letsencrypt is chosen."
  fi
}

# ──────────────────────────────────────────────
#  Auto-detect node IP
# ──────────────────────────────────────────────
detect_node_ip() {
  # Try the primary non-loopback IPv4 address
  local ip
  ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '/src/ {for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -1)
  if [[ -z "$ip" ]]; then
    ip=$(hostname -I 2>/dev/null | awk '{print $1}')
  fi
  printf '%s' "$ip"
}

# ──────────────────────────────────────────────
#  Preflight checks
# ──────────────────────────────────────────────
check_root() {
  if [[ "$EUID" -ne 0 ]]; then
    die "This script must be run as root (or with sudo)."
  fi
  green "Root: OK"
}

check_k3s() {
  if ! systemctl is-active k3s &>/dev/null; then
    red "k3s service is not active."
    log "Start k3s first, or install it with:"
    log "  sudo ./02_installation/labs/install.sh"
    exit 1
  fi
  green "k3s service: active"

  if ! kubectl --kubeconfig "$KUBECONFIG_PATH" get nodes &>/dev/null; then
    die "kubectl cannot reach the k3s API server. Check: journalctl -u k3s -n 50"
  fi

  local ready_nodes
  ready_nodes=$(kubectl --kubeconfig "$KUBECONFIG_PATH" get nodes --no-headers 2>/dev/null \
    | grep -c ' Ready' || true)
  if [[ "$ready_nodes" -lt 1 ]]; then
    die "No Ready nodes found. Wait for k3s to fully start, then retry."
  fi
  green "Ready nodes: ${ready_nodes}"
}

check_kubectl() {
  if ! command -v kubectl &>/dev/null; then
    die "kubectl not found. It is usually symlinked by k3s at /usr/local/bin/kubectl."
  fi
  green "kubectl: $(kubectl version --client --short 2>/dev/null || kubectl version --client 2>/dev/null | head -1)"
}

check_helm() {
  if ! command -v helm &>/dev/null; then
    red "helm not found."
    log "Install Helm by following Module 08, or run:"
    log "  curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash"
    exit 1
  fi
  green "helm: $(helm version --short 2>/dev/null)"
}

check_traefik() {
  local running
  running=$(kubectl --kubeconfig "$KUBECONFIG_PATH" get pods -n kube-system \
    -l "app.kubernetes.io/name=traefik" --no-headers 2>/dev/null \
    | grep -c Running || true)
  if [[ "$running" -lt 1 ]]; then
    warn "Traefik does not appear to be running in kube-system."
    warn "Rancher requires an ingress controller. See Module 07 if Traefik is missing."
  else
    green "Traefik ingress: ${running} pod(s) running"
  fi
}

check_namespace_collision() {
  if kubectl --kubeconfig "$KUBECONFIG_PATH" get namespace cattle-system &>/dev/null; then
    warn "Namespace 'cattle-system' already exists — this may be a re-run or an existing install."
    warn "The script will proceed; existing resources will be upgraded in-place."
  else
    green "Namespace cattle-system: not present (clean install)"
  fi
}

check_hostname_dns() {
  if [[ "$TLS_SOURCE" != "letsencrypt" ]]; then
    return
  fi
  log "Checking DNS resolution for ${HOSTNAME_ARG} (required for Let's Encrypt) ..."
  if command -v dig &>/dev/null; then
    if ! dig +short "$HOSTNAME_ARG" | grep -qE '^[0-9]'; then
      warn "DNS lookup for '${HOSTNAME_ARG}' returned no A record."
      warn "Let's Encrypt ACME HTTP-01 challenge will fail without public DNS pointing to this node."
    else
      green "DNS: ${HOSTNAME_ARG} resolves OK"
    fi
  elif curl -sf --connect-timeout 5 "http://${HOSTNAME_ARG}" &>/dev/null; then
    green "DNS: ${HOSTNAME_ARG} appears reachable"
  else
    warn "Could not verify DNS for '${HOSTNAME_ARG}' (dig not available)."
    warn "Ensure public DNS points to this node before using Let's Encrypt."
  fi
}

ensure_cert_manager() {
  if [[ "$SKIP_CERT_MANAGER" == "true" ]]; then
    log "Skipping cert-manager check/install (--skip-cert-manager set)."
    return
  fi

  if [[ "$TLS_SOURCE" == "secret" ]]; then
    log "TLS source is 'secret' — cert-manager is not required."
    return
  fi

  # Check if already installed
  if kubectl --kubeconfig "$KUBECONFIG_PATH" get namespace cert-manager &>/dev/null && \
     kubectl --kubeconfig "$KUBECONFIG_PATH" get pods -n cert-manager \
       -l "app.kubernetes.io/name=cert-manager" --no-headers 2>/dev/null \
       | grep -q Running; then
    local cm_ver
    cm_ver=$(kubectl --kubeconfig "$KUBECONFIG_PATH" get pods -n cert-manager \
      -l "app.kubernetes.io/name=cert-manager" -o jsonpath='{.items[0].metadata.labels.app\.kubernetes\.io/version}' \
      2>/dev/null || echo "unknown")
    green "cert-manager: already running (version: ${cm_ver}) — skipping install"
    return
  fi

  log "cert-manager not found — installing ${CERT_MANAGER_VERSION} ..."

  run helm repo add jetstack https://charts.jetstack.io
  run helm repo update

  run kubectl --kubeconfig "$KUBECONFIG_PATH" create namespace cert-manager \
    --dry-run=client -o yaml | kubectl --kubeconfig "$KUBECONFIG_PATH" apply -f -

  run helm upgrade --install cert-manager jetstack/cert-manager \
    --namespace cert-manager \
    --version "$CERT_MANAGER_VERSION" \
    --set installCRDs=true \
    --kubeconfig "$KUBECONFIG_PATH" \
    --wait --timeout 120s

  if [[ "$DRY_RUN" == "false" ]]; then
    log "Waiting for cert-manager pods to be Ready ..."
    kubectl --kubeconfig "$KUBECONFIG_PATH" -n cert-manager \
      rollout status deploy/cert-manager --timeout=120s
    green "cert-manager: installed and ready"
  fi
}

# ──────────────────────────────────────────────
#  Confirmation prompt
# ──────────────────────────────────────────────
confirm() {
  if [[ "$FORCE" == "true" || "$DRY_RUN" == "true" ]]; then
    return
  fi
  echo ""
  echo "  Hostname  : ${HOSTNAME_ARG}"
  echo "  TLS       : ${TLS_SOURCE}"
  echo "  Replicas  : ${REPLICAS}"
  echo "  Namespace : cattle-system"
  if [[ -n "$RANCHER_VERSION" ]]; then
    echo "  Version   : ${RANCHER_VERSION}"
  else
    echo "  Version   : latest stable"
  fi
  echo ""
  printf 'Proceed with Rancher installation? Type YES to continue: '
  local answer
  read -r answer
  if [[ "$answer" != "YES" ]]; then
    die "Aborted."
  fi
}

# ──────────────────────────────────────────────
#  Install Rancher
# ──────────────────────────────────────────────
install_rancher() {
  log "Adding Rancher Helm repo ..."
  run helm repo add rancher-stable https://releases.rancher.com/server-charts/stable
  run helm repo update

  log "Creating cattle-system namespace (idempotent) ..."
  run kubectl --kubeconfig "$KUBECONFIG_PATH" create namespace cattle-system \
    --dry-run=client -o yaml | \
    kubectl --kubeconfig "$KUBECONFIG_PATH" apply -f -

  # Build the helm command incrementally
  local helm_cmd=(
    helm upgrade --install rancher rancher-stable/rancher
    --namespace cattle-system
    --kubeconfig "$KUBECONFIG_PATH"
    --set "hostname=${HOSTNAME_ARG}"
    --set "bootstrapPassword=${BOOTSTRAP_PASSWORD}"
    --set "replicas=${REPLICAS}"
    --set "ingress.tls.source=${TLS_SOURCE}"
    --wait
    --timeout 600s
  )

  if [[ -n "$RANCHER_VERSION" ]]; then
    helm_cmd+=(--version "$RANCHER_VERSION")
  fi

  if [[ "$TLS_SOURCE" == "letsencrypt" ]]; then
    helm_cmd+=(
      --set "letsEncrypt.email=${LE_EMAIL}"
      --set "letsEncrypt.environment=production"
      --set "letsEncrypt.ingress.class=traefik"
    )
  fi

  log "Running: ${helm_cmd[*]}"
  run "${helm_cmd[@]}"
}

# ──────────────────────────────────────────────
#  Wait for rollout
# ──────────────────────────────────────────────
wait_for_rancher() {
  if [[ "$DRY_RUN" == "true" ]]; then
    blue "[DRY-RUN] kubectl -n cattle-system rollout status deploy/rancher --timeout=600s"
    return
  fi

  log "Waiting for Rancher rollout (up to 10 min — image pull may take a while) ..."
  if ! kubectl --kubeconfig "$KUBECONFIG_PATH" \
      -n cattle-system rollout status deploy/rancher --timeout=600s; then
    warn "Rollout did not complete within 10 minutes."
    warn "Check pod events with:"
    warn "  kubectl -n cattle-system describe pods"
    warn "  kubectl -n cattle-system logs -l app=rancher --tail=50"
  else
    green "Rancher rollout: complete"
  fi
}

# ──────────────────────────────────────────────
#  Post-install summary
# ──────────────────────────────────────────────
print_summary() {
  echo ""
  echo "════════════════════════════════════════════════"
  echo "  Rancher Installation Complete"
  echo "════════════════════════════════════════════════"
  echo ""
  echo "  URL      : https://${HOSTNAME_ARG}"
  echo "  Username : admin"
  echo "  Password : ${BOOTSTRAP_PASSWORD}"
  echo ""

  if [[ "$BOOTSTRAP_PASSWORD" == "changeme" ]]; then
    yellow "  ⚠  You are using the default bootstrap password."
    yellow "     Change it immediately after first login!"
  fi

  echo ""
  echo "  Pod status:"
  if [[ "$DRY_RUN" == "false" ]]; then
    kubectl --kubeconfig "$KUBECONFIG_PATH" -n cattle-system get pods 2>/dev/null || true
    echo ""
    echo "  Ingress:"
    kubectl --kubeconfig "$KUBECONFIG_PATH" -n cattle-system get ingress 2>/dev/null || true
  else
    blue "  [DRY-RUN] kubectl -n cattle-system get pods"
    blue "  [DRY-RUN] kubectl -n cattle-system get ingress"
  fi

  echo ""
  echo "  To uninstall Rancher:"
  echo "    sudo ./uninstall-rancher.sh"
  echo ""
  echo "════════════════════════════════════════════════"
}

# ──────────────────────────────────────────────
#  Main
# ──────────────────────────────────────────────
main() {
  parse_args "$@"

  # Resolve hostname now so checks and summary can use it
  if [[ -z "$HOSTNAME_ARG" ]]; then
    local node_ip
    node_ip=$(detect_node_ip)
    if [[ -z "$node_ip" ]]; then
      die "Could not auto-detect node IP. Pass --hostname explicitly."
    fi
    HOSTNAME_ARG="rancher.${node_ip}.sslip.io"
    log "Auto-detected hostname: ${HOSTNAME_ARG}"
  fi

  echo ""
  echo "════════════════════════════════════════════════"
  echo "  Mastering k3s — Install Rancher (Module 18)"
  echo "════════════════════════════════════════════════"
  if [[ "$DRY_RUN" == "true" ]]; then
    yellow "  DRY-RUN mode — no changes will be made"
  fi
  echo ""

  echo "--- Preflight Checks ---"
  check_root
  check_k3s
  check_kubectl
  check_helm
  check_traefik
  check_namespace_collision
  check_hostname_dns
  echo ""

  echo "--- cert-manager ---"
  ensure_cert_manager
  echo ""

  confirm

  echo "--- Installing Rancher ---"
  install_rancher
  echo ""

  echo "--- Waiting for Rollout ---"
  wait_for_rancher
  echo ""

  print_summary
}

main "$@"
