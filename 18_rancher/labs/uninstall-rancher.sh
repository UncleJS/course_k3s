#!/usr/bin/env bash
# uninstall-rancher.sh — Remove Rancher from a k3s cluster
# Module 18 · Lab | Course: Mastering k3s
# Licensed under CC BY-NC-SA 4.0 — https://creativecommons.org/licenses/by-nc-sa/4.0/

set -euo pipefail

# ──────────────────────────────────────────────
#  Defaults
# ──────────────────────────────────────────────
REMOVE_CERT_MANAGER=false
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

Uninstall Rancher from a k3s cluster and clean up related resources.

Options:
  --remove-cert-manager   Also uninstall cert-manager and its namespace
  --dry-run               Print commands without executing them
  --force                 Skip confirmation prompt
  -h, --help              Show this help

What this script removes:
  - Helm release 'rancher' from namespace cattle-system
  - Namespace cattle-system (and all resources within it)
  - Lingering cattle-* and fleet-* namespaces (with confirmation)
  - Rancher-related CRDs (optional, prompted)
  - cert-manager Helm release + namespace (if --remove-cert-manager)

What this script does NOT remove:
  - k3s itself
  - Helm binary
  - Other workloads on the cluster

Example:
  sudo ./uninstall-rancher.sh
  sudo ./uninstall-rancher.sh --remove-cert-manager --force
  sudo ./uninstall-rancher.sh --dry-run
EOF
}

# ──────────────────────────────────────────────
#  Argument parsing
# ──────────────────────────────────────────────
parse_args() {
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --remove-cert-manager) REMOVE_CERT_MANAGER=true; shift ;;
      --dry-run)             DRY_RUN=true;             shift ;;
      --force)               FORCE=true;               shift ;;
      -h|--help)             usage; exit 0 ;;
      *) die "Unknown argument: $1. Run with --help for usage." ;;
    esac
  done
}

# ──────────────────────────────────────────────
#  Preflight
# ──────────────────────────────────────────────
check_root() {
  if [[ "$EUID" -ne 0 ]]; then
    die "This script must be run as root (or with sudo)."
  fi
  green "Root: OK"
}

check_kubectl() {
  if ! command -v kubectl &>/dev/null; then
    die "kubectl not found — cannot clean up Kubernetes resources."
  fi
  if ! kubectl --kubeconfig "$KUBECONFIG_PATH" cluster-info &>/dev/null; then
    die "kubectl cannot reach the API server. Is k3s running?"
  fi
  green "kubectl: cluster reachable"
}

check_helm() {
  if ! command -v helm &>/dev/null; then
    die "helm not found — cannot uninstall Helm releases."
  fi
  green "helm: $(helm version --short 2>/dev/null)"
}

# ──────────────────────────────────────────────
#  Confirmation
# ──────────────────────────────────────────────
confirm() {
  if [[ "$FORCE" == "true" || "$DRY_RUN" == "true" ]]; then
    return
  fi
  echo ""
  warn "This will remove Rancher and the cattle-system namespace from the cluster."
  if [[ "$REMOVE_CERT_MANAGER" == "true" ]]; then
    warn "This will also remove cert-manager and its namespace."
  fi
  echo ""
  printf 'Type YES to continue: '
  local answer
  read -r answer
  if [[ "$answer" != "YES" ]]; then
    die "Aborted."
  fi
}

# ──────────────────────────────────────────────
#  Uninstall Rancher Helm release
# ──────────────────────────────────────────────
uninstall_rancher_helm() {
  log "Checking for Rancher Helm release in cattle-system ..."
  if helm --kubeconfig "$KUBECONFIG_PATH" -n cattle-system status rancher &>/dev/null; then
    log "Uninstalling Helm release: rancher"
    run helm --kubeconfig "$KUBECONFIG_PATH" -n cattle-system uninstall rancher
    green "Helm release 'rancher': uninstalled"
  else
    warn "Helm release 'rancher' not found in cattle-system — skipping helm uninstall."
  fi
}

# ──────────────────────────────────────────────
#  Delete cattle-system namespace
# ──────────────────────────────────────────────
delete_cattle_system() {
  if kubectl --kubeconfig "$KUBECONFIG_PATH" get namespace cattle-system &>/dev/null; then
    log "Deleting namespace: cattle-system"
    run kubectl --kubeconfig "$KUBECONFIG_PATH" delete namespace cattle-system

    if [[ "$DRY_RUN" == "false" ]]; then
      log "Waiting for cattle-system namespace to terminate ..."
      local i=0
      while kubectl --kubeconfig "$KUBECONFIG_PATH" get namespace cattle-system &>/dev/null; do
        if [[ "$i" -ge 60 ]]; then
          warn "cattle-system namespace is still terminating after 60s."
          warn "It may be stuck on finalizers. Check:"
          warn "  kubectl get namespace cattle-system -o yaml"
          break
        fi
        sleep 2
        i=$((i + 2))
      done
      if ! kubectl --kubeconfig "$KUBECONFIG_PATH" get namespace cattle-system &>/dev/null; then
        green "Namespace cattle-system: deleted"
      fi
    fi
  else
    log "Namespace cattle-system not found — nothing to delete."
  fi
}

# ──────────────────────────────────────────────
#  Clean up lingering Rancher/Fleet namespaces
# ──────────────────────────────────────────────
cleanup_extra_namespaces() {
  local -a extra_ns=()
  local ns_list
  ns_list=$(kubectl --kubeconfig "$KUBECONFIG_PATH" get namespaces \
    --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null || true)

  while IFS= read -r ns; do
    case "$ns" in
      cattle-*|fleet-*|rancher-*|local)
        extra_ns+=("$ns")
        ;;
    esac
  done <<< "$ns_list"

  if [[ "${#extra_ns[@]}" -eq 0 ]]; then
    log "No lingering cattle-*/fleet-*/rancher-* namespaces found."
    return
  fi

  warn "Found lingering namespaces: ${extra_ns[*]}"

  if [[ "$FORCE" == "true" || "$DRY_RUN" == "true" ]]; then
    for ns in "${extra_ns[@]}"; do
      run kubectl --kubeconfig "$KUBECONFIG_PATH" delete namespace "$ns" --ignore-not-found
    done
  else
    printf 'Delete these namespaces? Type YES to confirm: '
    local answer
    read -r answer
    if [[ "$answer" == "YES" ]]; then
      for ns in "${extra_ns[@]}"; do
        log "Deleting namespace: $ns"
        kubectl --kubeconfig "$KUBECONFIG_PATH" delete namespace "$ns" --ignore-not-found || \
          warn "Could not delete $ns — it may have stuck finalizers."
      done
      green "Extra namespaces: cleaned up"
    else
      warn "Skipped deletion of extra namespaces."
    fi
  fi
}

# ──────────────────────────────────────────────
#  Clean up Rancher CRDs
# ──────────────────────────────────────────────
cleanup_crds() {
  local rancher_crds
  rancher_crds=$(kubectl --kubeconfig "$KUBECONFIG_PATH" get crds \
    --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null \
    | grep -E '\.cattle\.io$|\.fleet\.cattle\.io$|\.rancher\.io$' || true)

  if [[ -z "$rancher_crds" ]]; then
    log "No Rancher/Fleet CRDs found."
    return
  fi

  local crd_count
  crd_count=$(printf '%s\n' "$rancher_crds" | wc -l)
  warn "Found ${crd_count} Rancher-related CRD(s)."

  if [[ "$FORCE" == "true" || "$DRY_RUN" == "true" ]]; then
    log "Removing Rancher CRDs ..."
    while IFS= read -r crd; do
      [[ -z "$crd" ]] && continue
      run kubectl --kubeconfig "$KUBECONFIG_PATH" delete crd "$crd" --ignore-not-found
    done <<< "$rancher_crds"
    if [[ "$DRY_RUN" == "false" ]]; then
      green "Rancher CRDs: removed"
    fi
  else
    printf 'Remove %d Rancher CRD(s)? Removing CRDs deletes all custom resources they manage.\nType YES to confirm: ' "$crd_count"
    local answer
    read -r answer
    if [[ "$answer" == "YES" ]]; then
      while IFS= read -r crd; do
        [[ -z "$crd" ]] && continue
        log "Deleting CRD: $crd"
        kubectl --kubeconfig "$KUBECONFIG_PATH" delete crd "$crd" --ignore-not-found || \
          warn "Failed to delete CRD: $crd"
      done <<< "$rancher_crds"
      green "Rancher CRDs: removed"
    else
      warn "Skipped CRD removal. Some Rancher resources may persist."
    fi
  fi
}

# ──────────────────────────────────────────────
#  Uninstall cert-manager (optional)
# ──────────────────────────────────────────────
uninstall_cert_manager() {
  if [[ "$REMOVE_CERT_MANAGER" == "false" ]]; then
    return
  fi

  log "Uninstalling cert-manager ..."

  if helm --kubeconfig "$KUBECONFIG_PATH" -n cert-manager status cert-manager &>/dev/null; then
    run helm --kubeconfig "$KUBECONFIG_PATH" -n cert-manager uninstall cert-manager
    green "Helm release 'cert-manager': uninstalled"
  else
    warn "Helm release 'cert-manager' not found — skipping helm uninstall."
  fi

  if kubectl --kubeconfig "$KUBECONFIG_PATH" get namespace cert-manager &>/dev/null; then
    log "Deleting namespace: cert-manager"
    run kubectl --kubeconfig "$KUBECONFIG_PATH" delete namespace cert-manager --ignore-not-found

    if [[ "$DRY_RUN" == "false" ]]; then
      log "Waiting for cert-manager namespace to terminate ..."
      local i=0
      while kubectl --kubeconfig "$KUBECONFIG_PATH" get namespace cert-manager &>/dev/null; do
        if [[ "$i" -ge 60 ]]; then
          warn "cert-manager namespace still terminating after 60s — may have stuck finalizers."
          break
        fi
        sleep 2
        i=$((i + 2))
      done
      if ! kubectl --kubeconfig "$KUBECONFIG_PATH" get namespace cert-manager &>/dev/null; then
        green "Namespace cert-manager: deleted"
      fi
    fi
  fi

  # Remove cert-manager CRDs
  local cm_crds
  cm_crds=$(kubectl --kubeconfig "$KUBECONFIG_PATH" get crds --no-headers \
    -o custom-columns=NAME:.metadata.name 2>/dev/null \
    | grep '\.cert-manager\.io$' || true)

  if [[ -n "$cm_crds" ]]; then
    log "Removing cert-manager CRDs ..."
    while IFS= read -r crd; do
      [[ -z "$crd" ]] && continue
      run kubectl --kubeconfig "$KUBECONFIG_PATH" delete crd "$crd" --ignore-not-found
    done <<< "$cm_crds"
    if [[ "$DRY_RUN" == "false" ]]; then
      green "cert-manager CRDs: removed"
    fi
  fi
}

# ──────────────────────────────────────────────
#  Post-uninstall audit
# ──────────────────────────────────────────────
post_uninstall_audit() {
  if [[ "$DRY_RUN" == "true" ]]; then
    return
  fi

  log "Running post-uninstall audit ..."

  local issues=0

  # Check for leftover namespaces
  local leftover_ns
  leftover_ns=$(kubectl --kubeconfig "$KUBECONFIG_PATH" get namespaces \
    --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null \
    | grep -E '^cattle-|^fleet-|^rancher-' || true)

  if [[ -n "$leftover_ns" ]]; then
    while IFS= read -r ns; do
      warn "Leftover namespace: $ns"
      issues=$((issues + 1))
    done <<< "$leftover_ns"
  fi

  # Check for leftover Rancher CRDs
  local leftover_crds
  leftover_crds=$(kubectl --kubeconfig "$KUBECONFIG_PATH" get crds \
    --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null \
    | grep -E '\.cattle\.io$|\.fleet\.cattle\.io$|\.rancher\.io$' || true)

  if [[ -n "$leftover_crds" ]]; then
    local crd_count
    crd_count=$(printf '%s\n' "$leftover_crds" | wc -l)
    warn "${crd_count} Rancher CRD(s) still present on the cluster."
    warn "Run with --force to remove them, or delete manually."
    issues=$((issues + crd_count))
  fi

  # Check cattle-system is gone
  if kubectl --kubeconfig "$KUBECONFIG_PATH" get namespace cattle-system &>/dev/null; then
    warn "Namespace cattle-system still exists (may be terminating)."
    issues=$((issues + 1))
  fi

  echo ""
  echo "════════════════════════════════════════════════"
  if [[ "$issues" -eq 0 ]]; then
    green "Audit: clean — no Rancher artifacts detected."
  else
    warn "Audit found ${issues} issue(s). Review warnings above."
  fi
  echo "════════════════════════════════════════════════"
}

# ──────────────────────────────────────────────
#  Main
# ──────────────────────────────────────────────
main() {
  parse_args "$@"

  echo ""
  echo "════════════════════════════════════════════════"
  echo "  Mastering k3s — Uninstall Rancher (Module 18)"
  echo "════════════════════════════════════════════════"
  if [[ "$DRY_RUN" == "true" ]]; then
    yellow "  DRY-RUN mode — no changes will be made"
  fi
  echo ""

  echo "--- Preflight Checks ---"
  check_root
  check_kubectl
  check_helm
  echo ""

  confirm

  echo "--- Uninstalling Rancher ---"
  uninstall_rancher_helm
  delete_cattle_system
  cleanup_extra_namespaces
  cleanup_crds
  echo ""

  if [[ "$REMOVE_CERT_MANAGER" == "true" ]]; then
    echo "--- Uninstalling cert-manager ---"
    uninstall_cert_manager
    echo ""
  fi

  post_uninstall_audit
}

main "$@"
