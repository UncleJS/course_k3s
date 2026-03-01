#!/usr/bin/env bash
# =============================================================================
# etcd-snapshot.sh — k3s etcd snapshot management helper
# =============================================================================
# Modes:
#   --snapshot               Take an on-demand snapshot
#   --list                   List available snapshots
#   --restore --revision <n> Restore from a named snapshot
#   --schedule               Show how to configure scheduled snapshots
#
# Optional S3 upload (requires 'aws' CLI and env vars):
#   AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, S3_BUCKET, S3_ENDPOINT
#
# Usage:
#   sudo ./etcd-snapshot.sh --snapshot
#   sudo ./etcd-snapshot.sh --list
#   sudo ./etcd-snapshot.sh --restore --revision etcd-snapshot-20260301-060000
#   ./etcd-snapshot.sh --schedule
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Color helpers
# ---------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

info()    { echo -e "${BLUE}[INFO]${RESET}  $*"; }
success() { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
error()   { echo -e "${RED}[ERROR]${RESET} $*" >&2; }
header()  { echo -e "\n${BOLD}${CYAN}==> $*${RESET}"; }
divider() { echo -e "${CYAN}$(printf '%.0s─' {1..72})${RESET}"; }

# ---------------------------------------------------------------------------
# Configuration — override via environment variables
# ---------------------------------------------------------------------------
K3S_BIN="${K3S_BIN:-/usr/local/bin/k3s}"
SNAPSHOT_DIR="${SNAPSHOT_DIR:-/var/lib/rancher/k3s/server/db/snapshots}"
SNAPSHOT_PREFIX="${SNAPSHOT_PREFIX:-etcd-snapshot}"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
SNAPSHOT_NAME="${SNAPSHOT_PREFIX}-${TIMESTAMP}"

# S3 settings (optional)
S3_BUCKET="${S3_BUCKET:-}"
S3_REGION="${S3_REGION:-us-east-1}"
S3_ENDPOINT="${S3_ENDPOINT:-}"         # e.g. http://minio.internal:9000
AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-}"
AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-}"

# ---------------------------------------------------------------------------
# Utility functions
# ---------------------------------------------------------------------------

require_root() {
    if [[ $EUID -ne 0 ]]; then
        error "This operation must be run as root (or with sudo)."
        exit 1
    fi
}

require_k3s() {
    if [[ ! -x "${K3S_BIN}" ]]; then
        error "k3s binary not found at ${K3S_BIN}. Set K3S_BIN env var if installed elsewhere."
        exit 1
    fi
}

require_embedded_etcd() {
    # Check that k3s is running with embedded etcd (not SQLite)
    if ! systemctl is-active --quiet k3s 2>/dev/null; then
        warn "k3s service is not running. Cannot verify datastore type."
        return
    fi
    if ! pgrep -f "k3s server" | xargs -I{} cat /proc/{}/cmdline 2>/dev/null \
            | tr '\0' ' ' | grep -q "cluster-init\|etcd"; then
        warn "k3s does not appear to be running with embedded etcd."
        warn "The 'etcd-snapshot' command is only available for embedded-etcd clusters."
        warn "For single-node SQLite clusters, see the SQLite backup section."
    fi
}

aws_available() {
    command -v aws &>/dev/null
}

s3_configured() {
    [[ -n "${S3_BUCKET}" && -n "${AWS_ACCESS_KEY_ID}" && -n "${AWS_SECRET_ACCESS_KEY}" ]]
}

upload_to_s3() {
    local snapshot_path="$1"
    local snapshot_file
    snapshot_file=$(basename "${snapshot_path}")

    if ! aws_available; then
        warn "aws CLI not found — skipping S3 upload."
        warn "Install the AWS CLI and set S3_BUCKET, AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY"
        warn "to enable automatic S3 upload."
        return 0
    fi

    if ! s3_configured; then
        warn "S3 environment variables not fully set — skipping S3 upload."
        warn "Required: S3_BUCKET, AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY"
        return 0
    fi

    header "Uploading snapshot to S3"
    info "Bucket  : s3://${S3_BUCKET}"
    info "Object  : snapshots/${snapshot_file}"
    [[ -n "${S3_ENDPOINT}" ]] && info "Endpoint: ${S3_ENDPOINT}"

    local aws_extra_args=()
    [[ -n "${S3_ENDPOINT}" ]] && aws_extra_args+=(--endpoint-url "${S3_ENDPOINT}")

    AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID}" \
    AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY}" \
    aws s3 cp "${snapshot_path}" \
        "s3://${S3_BUCKET}/snapshots/${snapshot_file}" \
        --region "${S3_REGION}" \
        "${aws_extra_args[@]}"

    # Also upload the metadata sidecar if it exists
    local meta_path="${snapshot_path}.metadata"
    if [[ -f "${meta_path}" ]]; then
        AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID}" \
        AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY}" \
        aws s3 cp "${meta_path}" \
            "s3://${S3_BUCKET}/snapshots/${snapshot_file}.metadata" \
            --region "${S3_REGION}" \
            "${aws_extra_args[@]}"
    fi

    success "Snapshot uploaded to S3 successfully."
}

# ---------------------------------------------------------------------------
# Mode: --snapshot
# ---------------------------------------------------------------------------
cmd_snapshot() {
    require_root
    require_k3s
    require_embedded_etcd

    header "Creating on-demand etcd snapshot"
    info "Snapshot name : ${SNAPSHOT_NAME}"
    info "Directory     : ${SNAPSHOT_DIR}"

    # Ensure the directory exists
    mkdir -p "${SNAPSHOT_DIR}"

    # Take the snapshot
    "${K3S_BIN}" etcd-snapshot save --name "${SNAPSHOT_NAME}"

    # Find the newly created file
    local snapshot_file
    snapshot_file=$(find "${SNAPSHOT_DIR}" -name "${SNAPSHOT_NAME}*" ! -name "*.metadata" | head -n1)

    if [[ -z "${snapshot_file}" ]]; then
        error "Snapshot file not found in ${SNAPSHOT_DIR} after save command."
        exit 1
    fi

    # Verify
    local snapshot_size
    snapshot_size=$(du -sh "${snapshot_file}" | awk '{print $1}')
    success "Snapshot created: ${snapshot_file} (${snapshot_size})"

    # Show metadata if available
    local meta_file="${snapshot_file}.metadata"
    if [[ -f "${meta_file}" ]]; then
        info "Metadata:"
        if command -v jq &>/dev/null; then
            jq . "${meta_file}" | sed 's/^/  /'
        else
            cat "${meta_file}" | sed 's/^/  /'
        fi
    fi

    # Attempt S3 upload
    upload_to_s3 "${snapshot_file}"

    divider
    success "Snapshot operation complete."
    info "To restore this snapshot later, run:"
    echo -e "  ${YELLOW}sudo $0 --restore --revision ${SNAPSHOT_NAME}${RESET}"
}

# ---------------------------------------------------------------------------
# Mode: --list
# ---------------------------------------------------------------------------
cmd_list() {
    require_root
    require_k3s

    header "Listing etcd snapshots"

    # Local snapshots via k3s CLI
    info "Local snapshots (${SNAPSHOT_DIR}):"
    "${K3S_BIN}" etcd-snapshot list 2>/dev/null || {
        warn "No local snapshots found, or k3s etcd-snapshot list is unavailable."
        ls -lh "${SNAPSHOT_DIR}" 2>/dev/null || true
    }

    # S3 listing (optional)
    if aws_available && s3_configured; then
        echo ""
        info "S3 snapshots (s3://${S3_BUCKET}/snapshots/):"
        local aws_extra_args=()
        [[ -n "${S3_ENDPOINT}" ]] && aws_extra_args+=(--endpoint-url "${S3_ENDPOINT}")

        AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID}" \
        AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY}" \
        aws s3 ls "s3://${S3_BUCKET}/snapshots/" \
            --region "${S3_REGION}" \
            "${aws_extra_args[@]}" 2>/dev/null \
            | grep -v '\.metadata$' \
            || warn "No S3 snapshots found or S3 is unreachable."
    fi
}

# ---------------------------------------------------------------------------
# Mode: --restore --revision <name>
# ---------------------------------------------------------------------------
cmd_restore() {
    local revision="$1"

    require_root
    require_k3s

    if [[ -z "${revision}" ]]; then
        error "--restore requires --revision <snapshot-name>"
        echo "  Example: sudo $0 --restore --revision etcd-snapshot-20260301-060000"
        exit 1
    fi

    header "etcd Snapshot Restore"

    echo -e "${RED}${BOLD}"
    echo "  ██╗    ██╗ █████╗ ██████╗ ███╗   ██╗██╗███╗   ██╗ ██████╗"
    echo "  ██║    ██║██╔══██╗██╔══██╗████╗  ██║██║████╗  ██║██╔════╝"
    echo "  ██║ █╗ ██║███████║██████╔╝██╔██╗ ██║██║██╔██╗ ██║██║  ███╗"
    echo "  ██║███╗██║██╔══██║██╔══██╗██║╚██╗██║██║██║╚██╗██║██║   ██║"
    echo "  ╚███╔███╔╝██║  ██║██║  ██║██║ ╚████║██║██║ ╚████║╚██████╔╝"
    echo "   ╚══╝╚══╝ ╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═══╝╚═╝╚═╝  ╚═══╝ ╚═════╝"
    echo -e "${RESET}"

    warn "THIS IS A DESTRUCTIVE OPERATION."
    warn "Restoring from snapshot will REPLACE ALL CURRENT CLUSTER STATE."
    warn "All changes made after the snapshot was taken will be PERMANENTLY LOST."
    echo ""
    warn "Snapshot to restore: ${revision}"
    echo ""

    # Confirmation prompt
    echo -ne "${YELLOW}Type 'yes-i-am-sure' to proceed: ${RESET}"
    read -r confirmation
    if [[ "${confirmation}" != "yes-i-am-sure" ]]; then
        info "Restore aborted by user."
        exit 0
    fi

    # Locate snapshot file
    local snapshot_path=""

    # Check local directory
    if [[ -f "${SNAPSHOT_DIR}/${revision}" ]]; then
        snapshot_path="${SNAPSHOT_DIR}/${revision}"
    elif [[ -f "${revision}" ]]; then
        # Absolute or relative path provided
        snapshot_path="${revision}"
    fi

    # If not found locally and S3 is configured, attempt download
    if [[ -z "${snapshot_path}" ]] && aws_available && s3_configured; then
        header "Downloading snapshot from S3"
        local download_path="/tmp/${revision}"
        local aws_extra_args=()
        [[ -n "${S3_ENDPOINT}" ]] && aws_extra_args+=(--endpoint-url "${S3_ENDPOINT}")

        AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID}" \
        AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY}" \
        aws s3 cp \
            "s3://${S3_BUCKET}/snapshots/${revision}" \
            "${download_path}" \
            --region "${S3_REGION}" \
            "${aws_extra_args[@]}"

        snapshot_path="${download_path}"
        success "Downloaded to ${snapshot_path}"
    fi

    if [[ -z "${snapshot_path}" ]]; then
        error "Snapshot '${revision}' not found locally or on S3."
        error "Local path checked: ${SNAPSHOT_DIR}/${revision}"
        exit 1
    fi

    info "Using snapshot: ${snapshot_path}"

    # Step 1: Stop k3s
    header "Step 1 — Stopping k3s service"
    warn "Stopping k3s on THIS node. You must stop k3s on ALL other server nodes manually."
    echo -ne "${YELLOW}Press ENTER to stop k3s on this node (or Ctrl+C to abort): ${RESET}"
    read -r _
    systemctl stop k3s
    success "k3s stopped."

    # Confirm other nodes stopped
    echo ""
    warn "IMPORTANT: Ensure k3s is stopped on ALL other server nodes before continuing:"
    warn "  sudo systemctl stop k3s   (run on each server node)"
    echo -ne "${YELLOW}Confirm ALL server nodes are stopped [yes/no]: ${RESET}"
    read -r all_stopped
    if [[ "${all_stopped}" != "yes" ]]; then
        warn "Please stop all server nodes first, then re-run this script."
        info "Restarting k3s on this node..."
        systemctl start k3s
        exit 1
    fi

    # Step 2: Run cluster reset
    header "Step 2 — Running cluster reset with snapshot restore"
    info "This will reset etcd and restore state from: ${snapshot_path}"
    info "The command will exit after completion — this is expected."

    "${K3S_BIN}" server \
        --cluster-reset \
        --cluster-reset-restore-path="${snapshot_path}" \
        2>&1 | tee /tmp/k3s-restore-$(date +%Y%m%d%H%M%S).log || true
    # k3s exits with code 0 after cluster reset, but the process itself terminates

    # Step 3: Restart k3s
    header "Step 3 — Restarting k3s on this node"
    systemctl start k3s

    info "Waiting for k3s to become ready (up to 120s)..."
    local timeout=120
    local elapsed=0
    while ! "${K3S_BIN}" kubectl get nodes &>/dev/null 2>&1; do
        sleep 5
        elapsed=$((elapsed + 5))
        if [[ ${elapsed} -ge ${timeout} ]]; then
            error "k3s did not become ready within ${timeout}s."
            error "Check: sudo journalctl -u k3s -n 100"
            exit 1
        fi
        echo -n "."
    done
    echo ""
    success "k3s is ready."
    "${K3S_BIN}" kubectl get nodes

    divider
    success "Snapshot restore on this node is complete."
    echo ""
    warn "NEXT STEPS (for HA clusters):"
    warn "  On each additional server node (ONE AT A TIME):"
    warn "    sudo rm -rf /var/lib/rancher/k3s/server/db/"
    warn "    sudo systemctl start k3s"
    warn "  Then restart all agent nodes:"
    warn "    sudo systemctl restart k3s-agent"
    echo ""
    warn "  After all nodes are up, run the verification checklist:"
    warn "    kubectl get nodes"
    warn "    kubectl get pods -A | grep -v Running"
}

# ---------------------------------------------------------------------------
# Mode: --schedule
# ---------------------------------------------------------------------------
cmd_schedule() {
    header "Configuring Scheduled Snapshots"

    echo -e "${BOLD}Option 1 — k3s config file (recommended):${RESET}"
    cat <<'YAML'

  # /etc/rancher/k3s/config.yaml
  etcd-snapshot-schedule-cron: "0 */6 * * *"   # every 6 hours
  etcd-snapshot-retention: 5                    # keep the 5 most recent
  etcd-snapshot-dir: /var/lib/rancher/k3s/server/db/snapshots

  # Optional — ship snapshots directly to S3:
  etcd-s3: true
  etcd-s3-bucket: my-k3s-backups
  etcd-s3-region: us-east-1
  etcd-s3-access-key: AKIAIOSFODNN7EXAMPLE
  etcd-s3-secret-key: wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY
  # For MinIO / private endpoints:
  # etcd-s3-endpoint: http://minio.internal:9000
  # etcd-s3-skip-ssl-verify: true

YAML

    echo -e "${BOLD}Option 2 — systemd environment variables:${RESET}"
    cat <<'INI'

  # /etc/systemd/system/k3s.service.d/snapshot.conf
  [Service]
  Environment="K3S_ETCD_SNAPSHOT_SCHEDULE_CRON=0 */6 * * *"
  Environment="K3S_ETCD_SNAPSHOT_RETENTION=5"

INI

    echo -e "${BOLD}After editing, apply the configuration:${RESET}"
    cat <<'BASH'

  sudo systemctl daemon-reload
  sudo systemctl restart k3s
  # Verify the scheduler is active:
  sudo journalctl -u k3s -f | grep -i snapshot

BASH

    echo -e "${BOLD}Verify scheduled snapshots are being created:${RESET}"
    cat <<'BASH'

  sudo k3s etcd-snapshot list
  # or watch the directory:
  watch ls -lh /var/lib/rancher/k3s/server/db/snapshots/

BASH
}

# ---------------------------------------------------------------------------
# Usage / help
# ---------------------------------------------------------------------------
usage() {
    cat <<USAGE
${BOLD}etcd-snapshot.sh${RESET} — k3s etcd snapshot management

${BOLD}Usage:${RESET}
  sudo $0 --snapshot              Take an on-demand snapshot
  sudo $0 --list                  List available snapshots
  sudo $0 --restore \\
          --revision <name>       Restore from a named snapshot
       $0 --schedule              Show scheduled snapshot configuration

${BOLD}Environment variables:${RESET}
  SNAPSHOT_DIR       Local snapshot directory (default: /var/lib/rancher/k3s/server/db/snapshots)
  SNAPSHOT_PREFIX    Snapshot name prefix    (default: etcd-snapshot)
  S3_BUCKET          S3 bucket name          (optional — enables S3 upload)
  S3_REGION          S3 region               (default: us-east-1)
  S3_ENDPOINT        S3 endpoint URL         (optional — for MinIO etc.)
  AWS_ACCESS_KEY_ID  S3 access key           (required if S3_BUCKET is set)
  AWS_SECRET_ACCESS_KEY  S3 secret key       (required if S3_BUCKET is set)

${BOLD}Examples:${RESET}
  # On-demand snapshot with S3 upload
  S3_BUCKET=my-k3s-backups \\
  AWS_ACCESS_KEY_ID=AKIA... \\
  AWS_SECRET_ACCESS_KEY=secret \\
  sudo $0 --snapshot

  # List snapshots
  sudo $0 --list

  # Restore from a specific revision
  sudo $0 --restore --revision etcd-snapshot-20260301-060000

USAGE
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
MODE=""
REVISION=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --snapshot)  MODE="snapshot" ;;
        --list)      MODE="list" ;;
        --restore)   MODE="restore" ;;
        --schedule)  MODE="schedule" ;;
        --revision)  REVISION="$2"; shift ;;
        -h|--help)   usage; exit 0 ;;
        *)
            error "Unknown argument: $1"
            usage
            exit 1
            ;;
    esac
    shift
done

if [[ -z "${MODE}" ]]; then
    usage
    exit 1
fi

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------
case "${MODE}" in
    snapshot)  cmd_snapshot ;;
    list)      cmd_list ;;
    restore)   cmd_restore "${REVISION}" ;;
    schedule)  cmd_schedule ;;
esac
