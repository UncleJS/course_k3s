#!/usr/bin/env bash
set -euo pipefail

FORCE=false
MODE="auto"

usage() {
  cat <<'EOF'
Usage: uninstall.sh [--force] [--mode auto|server|agent|manual]

Options:
  --force                Skip confirmation prompt
  --mode <mode>          Cleanup mode (default: auto)
  -h, --help             Show this help

Modes:
  auto                   Detect server/agent uninstall script, else manual cleanup
  server                 Run k3s-uninstall.sh (fallback to manual on failure)
  agent                  Run k3s-agent-uninstall.sh (fallback to manual on failure)
  manual                 Run manual cleanup only
EOF
}

log() {
  printf '[INFO] %s\n' "$*"
}

warn() {
  printf '[WARN] %s\n' "$*"
}

die() {
  printf '[ERROR] %s\n' "$*" >&2
  exit 1
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    die "Run as root: sudo ./uninstall.sh"
  fi
}

remove_symlink_if_points_to_k3s() {
  local path="$1"
  if [[ -L "$path" ]]; then
    local target
    target="$(readlink -f "$path" 2>/dev/null || true)"
    if [[ "$target" == "/usr/local/bin/k3s" ]]; then
      rm -f "$path"
      log "Removed symlink: $path"
    else
      warn "Skipped $path (not linked to /usr/local/bin/k3s)"
    fi
  fi
}

run_manual_cleanup() {
  log "Running manual cleanup"

  systemctl stop k3s k3s-agent 2>/dev/null || true
  systemctl disable k3s k3s-agent 2>/dev/null || true

  rm -f /etc/systemd/system/k3s.service
  rm -f /etc/systemd/system/k3s-agent.service
  rm -f /etc/systemd/system/multi-user.target.wants/k3s.service
  rm -f /etc/systemd/system/multi-user.target.wants/k3s-agent.service
  systemctl daemon-reload || true

  if [[ -x /usr/local/bin/k3s-killall.sh ]]; then
    /usr/local/bin/k3s-killall.sh || warn "k3s-killall.sh reported warnings"
  fi

  remove_symlink_if_points_to_k3s /usr/local/bin/kubectl
  remove_symlink_if_points_to_k3s /usr/local/bin/crictl
  remove_symlink_if_points_to_k3s /usr/local/bin/ctr

  rm -f /usr/local/bin/k3s
  rm -f /usr/local/bin/k3s-killall.sh
  rm -f /usr/local/bin/k3s-uninstall.sh
  rm -f /usr/local/bin/k3s-agent-uninstall.sh

  rm -rf /etc/rancher/k3s
  rm -rf /var/lib/rancher/k3s
  rm -rf /run/k3s

  for iface in cni0 flannel.1; do
    if ip link show "$iface" >/dev/null 2>&1; then
      ip link delete "$iface" || warn "Failed to remove interface: $iface"
    fi
  done
}

# Resolve the real invoking user's home directory.
# When run via sudo the script's EUID is 0, so ~ and $HOME point to /root.
# SUDO_USER contains the original unprivileged username when available.
resolve_real_user_home() {
  local real_user="${SUDO_USER:-}"
  if [[ -z "$real_user" || "$real_user" == "root" ]]; then
    # Running directly as root or SUDO_USER not set — nothing to clean.
    printf ''
    return
  fi
  # Use getent for reliable home lookup across non-standard configurations.
  getent passwd "$real_user" | cut -d: -f6
}

cleanup_user_files() {
  local user_home
  user_home="$(resolve_real_user_home)"

  if [[ -z "$user_home" ]]; then
    log "Skipping user-file cleanup: not invoked via sudo or running directly as root"
    return
  fi

  log "Cleaning up user files for home: $user_home"

  # Remove kubeconfig copy
  if [[ -f "${user_home}/.kube/config" ]]; then
    rm -f "${user_home}/.kube/config"
    log "Removed ${user_home}/.kube/config"
  fi

  # Remove any pre-flight kubeconfig backups created by this lesson
  local backup
  for backup in "${user_home}"/.kube/config.backup.*; do
    if [[ -f "$backup" ]]; then
      rm -f "$backup"
      log "Removed backup: $backup"
    fi
  done

  # Remove KUBECONFIG export lines from shell profiles
  local profile
  for profile in \
    "${user_home}/.bashrc" \
    "${user_home}/.bash_profile" \
    "${user_home}/.profile"; do
    if [[ -f "$profile" ]]; then
      if grep -q 'KUBECONFIG' "$profile" 2>/dev/null; then
        sed -i '/export KUBECONFIG.*\.kube/d' "$profile"
        log "Removed KUBECONFIG export from $profile"
      fi
    fi
  done
}

detect_mode() {
  if [[ "$MODE" != "auto" ]]; then
    return
  fi

  if [[ -x /usr/local/bin/k3s-uninstall.sh ]]; then
    MODE="server"
    return
  fi

  if [[ -x /usr/local/bin/k3s-agent-uninstall.sh ]]; then
    MODE="agent"
    return
  fi

  MODE="manual"
}

confirm() {
  if [[ "$FORCE" == "true" ]]; then
    return
  fi

  printf 'This will uninstall k3s and remove local cluster data from this host. Type YES to continue: '
  local answer
  read -r answer
  if [[ "$answer" != "YES" ]]; then
    die "Aborted"
  fi
}

run_selected_mode() {
  case "$MODE" in
    server)
      if [[ -x /usr/local/bin/k3s-uninstall.sh ]]; then
        log "Running /usr/local/bin/k3s-uninstall.sh"
        /usr/local/bin/k3s-uninstall.sh || {
          warn "Server uninstall script failed, falling back to manual cleanup"
          run_manual_cleanup
        }
      else
        warn "Server uninstall script not found, running manual cleanup"
        run_manual_cleanup
      fi
      cleanup_user_files
      ;;
    agent)
      if [[ -x /usr/local/bin/k3s-agent-uninstall.sh ]]; then
        log "Running /usr/local/bin/k3s-agent-uninstall.sh"
        /usr/local/bin/k3s-agent-uninstall.sh || {
          warn "Agent uninstall script failed, falling back to manual cleanup"
          run_manual_cleanup
        }
      else
        warn "Agent uninstall script not found, running manual cleanup"
        run_manual_cleanup
      fi
      cleanup_user_files
      ;;
    manual)
      run_manual_cleanup
      cleanup_user_files
      ;;
    *)
      die "Invalid mode: $MODE"
      ;;
  esac
}

post_uninstall_audit() {
  log "Running post-uninstall audit"

  local leftovers=0
  local path

  for path in \
    /etc/rancher/k3s \
    /var/lib/rancher/k3s \
    /run/k3s \
    /etc/systemd/system/k3s.service \
    /etc/systemd/system/k3s-agent.service \
    /usr/local/bin/k3s \
    /usr/local/bin/k3s-killall.sh \
    /usr/local/bin/k3s-uninstall.sh \
    /usr/local/bin/k3s-agent-uninstall.sh; do
    if [[ -e "$path" ]]; then
      warn "Leftover path: $path"
      leftovers=$((leftovers + 1))
    fi
  done

  if pgrep -fa 'k3s|containerd.*k3s' >/dev/null 2>&1; then
    warn "Detected running k3s-related processes"
    pgrep -fa 'k3s|containerd.*k3s' || true
    leftovers=$((leftovers + 1))
  fi

  if ip link show cni0 >/dev/null 2>&1; then
    warn "Leftover interface: cni0"
    leftovers=$((leftovers + 1))
  fi

  if ip link show flannel.1 >/dev/null 2>&1; then
    warn "Leftover interface: flannel.1"
    leftovers=$((leftovers + 1))
  fi

  # Check invoking user's local files
  local user_home
  user_home="$(resolve_real_user_home)"
  if [[ -n "$user_home" ]]; then
    if [[ -f "${user_home}/.kube/config" ]]; then
      warn "Leftover user kubeconfig: ${user_home}/.kube/config"
      leftovers=$((leftovers + 1))
    fi
    if ls "${user_home}"/.kube/config.backup.* >/dev/null 2>&1; then
      warn "Leftover kubeconfig backups in ${user_home}/.kube/"
      leftovers=$((leftovers + 1))
    fi
    local profile
    for profile in \
      "${user_home}/.bashrc" \
      "${user_home}/.bash_profile" \
      "${user_home}/.profile"; do
      if grep -q 'KUBECONFIG' "$profile" 2>/dev/null; then
        warn "KUBECONFIG still present in $profile"
        leftovers=$((leftovers + 1))
      fi
    done
  fi

  if [[ "$leftovers" -eq 0 ]]; then
    log "Audit passed: no common k3s artifacts detected"
  else
    warn "Audit found ${leftovers} issue(s). Review warnings above."
  fi
}

parse_args() {
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --force)
        FORCE=true
        shift
        ;;
      --mode)
        [[ "$#" -ge 2 ]] || die "--mode requires a value"
        MODE="$2"
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "Unknown argument: $1"
        ;;
    esac
  done

  case "$MODE" in
    auto|server|agent|manual) ;;
    *) die "Invalid --mode value: $MODE" ;;
  esac
}

main() {
  parse_args "$@"
  require_root
  detect_mode

  log "Selected mode: $MODE"
  confirm
  run_selected_mode
  post_uninstall_audit
}

main "$@"
