#!/usr/bin/env bash
# =============================================================================
# join-agent.sh — Helper script for joining k3s agent nodes
# Module 06 · Lab | Mastering k3s Course
# =============================================================================
# Usage:
#   On the SERVER, generate a join command:
#     sudo bash join-agent.sh --generate
#
#   On each WORKER, join the cluster:
#     bash join-agent.sh --join --server <SERVER_IP> --token <TOKEN>
#
#   Run pre-join checks on the worker:
#     bash join-agent.sh --check --server <SERVER_IP>
# =============================================================================
set -euo pipefail

# ── Colours ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
step()  { echo -e "${BLUE}[STEP]${NC}  $*"; }

# ── Defaults ─────────────────────────────────────────────────────────────────
MODE=""
SERVER_IP=""
NODE_TOKEN=""
NODE_LABEL=""
K3S_VERSION="${K3S_VERSION:-}"   # empty = latest

# ── Argument Parsing ─────────────────────────────────────────────────────────
usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Modes:
  --generate              Print the join command (run on SERVER)
  --join                  Join this machine as an agent (run on WORKER)
  --check                 Run pre-join checks only (run on WORKER)

Options:
  --server   <IP>         IP address of the k3s server
  --token    <TOKEN>      k3s node token
  --label    <key=value>  Optional node label to apply on join
  --version  <v1.x.y>    k3s version to install (default: latest)
  -h, --help              Show this help

Examples:
  sudo bash join-agent.sh --generate
  bash join-agent.sh --check  --server 192.168.1.10
  bash join-agent.sh --join   --server 192.168.1.10 --token K10abc...
  bash join-agent.sh --join   --server 192.168.1.10 --token K10abc... --label zone=us-east-1a
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --generate) MODE="generate" ;;
    --join)     MODE="join" ;;
    --check)    MODE="check" ;;
    --server)   SERVER_IP="$2"; shift ;;
    --token)    NODE_TOKEN="$2"; shift ;;
    --label)    NODE_LABEL="$2"; shift ;;
    --version)  K3S_VERSION="$2"; shift ;;
    -h|--help)  usage; exit 0 ;;
    *) error "Unknown option: $1"; usage; exit 1 ;;
  esac
  shift
done

# ── Mode: generate (run on server) ───────────────────────────────────────────
generate_join_command() {
  if [[ $EUID -ne 0 ]]; then
    error "Run with sudo on the server node."
    exit 1
  fi

  TOKEN_FILE="/var/lib/rancher/k3s/server/node-token"
  if [[ ! -f "$TOKEN_FILE" ]]; then
    error "Token file not found. Is k3s server running on this node?"
    exit 1
  fi

  TOKEN=$(cat "$TOKEN_FILE")
  SERVER_IP_AUTO=$(hostname -I | awk '{print $1}')

  echo ""
  info "===== k3s Agent Join Command ====="
  echo ""
  echo "Run the following on each worker node:"
  echo ""
  echo -e "${BLUE}bash join-agent.sh --join \\${NC}"
  echo -e "${BLUE}  --server ${SERVER_IP_AUTO} \\${NC}"
  echo -e "${BLUE}  --token  ${TOKEN}${NC}"
  echo ""
  warn "The token above grants cluster join access — handle it securely."
}

# ── Mode: check (run on worker) ───────────────────────────────────────────────
run_checks() {
  if [[ -z "$SERVER_IP" ]]; then
    error "--server is required for --check mode"
    exit 1
  fi

  step "1/5  Checking hostname uniqueness"
  HOSTNAME=$(hostname)
  info "Hostname: $HOSTNAME"

  step "2/5  Checking time synchronisation"
  if command -v chronyc &>/dev/null; then
    OFFSET=$(chronyc tracking 2>/dev/null | grep "System time" | awk '{print $4}' || echo "unknown")
    info "Chrony offset: ${OFFSET}s"
  elif command -v timedatectl &>/dev/null; then
    timedatectl status | grep -E "NTP|synchronized" || true
  else
    warn "Cannot detect time sync daemon — ensure NTP is running"
  fi

  step "3/5  Checking network reachability to server"
  if curl -sk --connect-timeout 5 "https://${SERVER_IP}:6443/readyz" | grep -q "ok"; then
    info "Server API at ${SERVER_IP}:6443 is reachable ✓"
  else
    error "Cannot reach ${SERVER_IP}:6443 — check firewall and server status"
    exit 1
  fi

  step "4/5  Checking for existing k3s installation"
  if systemctl is-active k3s-agent &>/dev/null 2>&1; then
    warn "k3s-agent is already running on this node. Joining again will restart it."
  elif systemctl is-active k3s &>/dev/null 2>&1; then
    warn "k3s (server mode) is already running on this node."
  else
    info "No existing k3s installation detected ✓"
  fi

  step "5/5  Checking required ports are accessible"
  for PORT in 6443 6444; do
    if timeout 3 bash -c ">/dev/tcp/${SERVER_IP}/${PORT}" 2>/dev/null; then
      info "Port ${PORT} is open ✓"
    else
      warn "Port ${PORT} appears closed — agent may not connect properly"
    fi
  done

  echo ""
  info "Pre-join checks complete. Run with --join to proceed."
}

# ── Mode: join (run on worker) ────────────────────────────────────────────────
join_agent() {
  if [[ -z "$SERVER_IP" || -z "$NODE_TOKEN" ]]; then
    error "--server and --token are required for --join mode"
    exit 1
  fi

  step "Running pre-join checks..."
  run_checks

  step "Installing k3s agent..."
  INSTALL_CMD="curl -sfL https://get.k3s.io | K3S_URL=https://${SERVER_IP}:6443 K3S_TOKEN=${NODE_TOKEN}"

  if [[ -n "$K3S_VERSION" ]]; then
    INSTALL_CMD="$INSTALL_CMD INSTALL_K3S_VERSION=${K3S_VERSION}"
  fi

  if [[ -n "$NODE_LABEL" ]]; then
    INSTALL_CMD="$INSTALL_CMD sh -s - --node-label ${NODE_LABEL}"
  else
    INSTALL_CMD="$INSTALL_CMD sh -"
  fi

  eval "$INSTALL_CMD"

  step "Waiting for agent to register (up to 60s)..."
  for i in $(seq 1 12); do
    if systemctl is-active k3s-agent &>/dev/null; then
      info "k3s-agent service is active ✓"
      break
    fi
    sleep 5
    echo -n "."
  done

  echo ""
  info "Agent joined successfully!"
  info ""
  info "Verify on the server with:"
  info "  kubectl get nodes -o wide"
  info ""
  info "View agent logs with:"
  info "  sudo journalctl -u k3s-agent -f"
}

# ── Dispatch ──────────────────────────────────────────────────────────────────
case "$MODE" in
  generate) generate_join_command ;;
  check)    run_checks ;;
  join)     join_agent ;;
  *)        usage; exit 1 ;;
esac
