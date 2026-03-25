#!/usr/bin/env bash
# =============================================================================
# rancher-import-cluster.sh
# Automates importing a downstream k3s cluster into Rancher Manager.
#
# Usage:
#   ./rancher-import-cluster.sh \
#     --rancher-url https://rancher.example.com \
#     --api-token   token-xxxx:yyyyyyyy \
#     --cluster-name my-downstream-k3s \
#     --kubeconfig  /path/to/downstream-kubeconfig.yaml
#
#   Add --dry-run to print commands without executing them.
#
# Requirements:
#   - jq
#   - kubectl
#   - curl (via sandbox — script uses fetch workaround internally)
#   - Rancher API token with cluster:create permission
# =============================================================================

set -euo pipefail

# --------------------------------------------------------------------------- #
# Colour helpers
# --------------------------------------------------------------------------- #
RED='\033[0;31m'
YEL='\033[0;33m'
GRN='\033[0;32m'
CYA='\033[0;36m'
NC='\033[0m'   # No Colour

info()    { echo -e "${CYA}[INFO]${NC}  $*"; }
success() { echo -e "${GRN}[OK]${NC}    $*"; }
warn()    { echo -e "${YEL}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
die()     { error "$*"; exit 1; }

# --------------------------------------------------------------------------- #
# Defaults
# --------------------------------------------------------------------------- #
RANCHER_URL=""
API_TOKEN=""
CLUSTER_NAME=""
DOWNSTREAM_KUBECONFIG=""
DRY_RUN=false
POLL_TIMEOUT=300   # 5 minutes
POLL_INTERVAL=10   # seconds between status checks

# --------------------------------------------------------------------------- #
# Argument parsing
# --------------------------------------------------------------------------- #
usage() {
  cat <<EOF
Usage: $0 [OPTIONS]

Required:
  --rancher-url   <url>        Rancher server URL  (e.g. https://rancher.example.com)
  --api-token     <token>      Rancher API token   (e.g. token-xxxx:yyyyyyyy)
  --cluster-name  <name>       Name for the imported cluster in Rancher
  --kubeconfig    <path>       Path to the downstream cluster's kubeconfig file

Optional:
  --dry-run                    Print commands without executing them
  --poll-timeout  <seconds>    Max seconds to wait for Active state (default: 300)
  --help                       Show this help

Examples:
  # Standard import
  $0 --rancher-url https://rancher.example.com \\
     --api-token token-xxxx:yyyyyyyy \\
     --cluster-name my-k3s-edge \\
     --kubeconfig ~/.kube/edge-cluster.yaml

  # Dry-run — see what would happen without making any changes
  $0 --rancher-url https://rancher.example.com \\
     --api-token token-xxxx:yyyyyyyy \\
     --cluster-name my-k3s-edge \\
     --kubeconfig ~/.kube/edge-cluster.yaml \\
     --dry-run
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --rancher-url)   RANCHER_URL="${2:?'--rancher-url requires a value'}"; shift 2 ;;
    --api-token)     API_TOKEN="${2:?'--api-token requires a value'}"; shift 2 ;;
    --cluster-name)  CLUSTER_NAME="${2:?'--cluster-name requires a value'}"; shift 2 ;;
    --kubeconfig)    DOWNSTREAM_KUBECONFIG="${2:?'--kubeconfig requires a value'}"; shift 2 ;;
    --dry-run)       DRY_RUN=true; shift ;;
    --poll-timeout)  POLL_TIMEOUT="${2:?'--poll-timeout requires a value'}"; shift 2 ;;
    --help|-h)       usage; exit 0 ;;
    *) die "Unknown argument: $1. Run $0 --help for usage." ;;
  esac
done

# --------------------------------------------------------------------------- #
# run() — wraps every mutating command so --dry-run works throughout
# --------------------------------------------------------------------------- #
run() {
  if [[ "$DRY_RUN" == "true" ]]; then
    echo -e "${YEL}[DRY-RUN]${NC} $*"
  else
    "$@"
  fi
}

# --------------------------------------------------------------------------- #
# Preflight checks
# --------------------------------------------------------------------------- #
preflight() {
  local errors=0

  echo ""
  info "=== Preflight Checks ==="

  # 1. jq available
  if command -v jq &>/dev/null; then
    success "jq: $(jq --version)"
  else
    error "jq not found — install jq before running this script"
    (( errors++ ))
  fi

  # 2. kubectl available
  if command -v kubectl &>/dev/null; then
    success "kubectl: $(kubectl version --client --short 2>/dev/null | head -1)"
  else
    error "kubectl not found — install kubectl before running this script"
    (( errors++ ))
  fi

  # 3. Required arguments present
  if [[ -z "$RANCHER_URL" ]]; then
    error "--rancher-url is required"
    (( errors++ ))
  fi
  if [[ -z "$API_TOKEN" ]]; then
    error "--api-token is required"
    (( errors++ ))
  fi
  if [[ -z "$CLUSTER_NAME" ]]; then
    error "--cluster-name is required"
    (( errors++ ))
  fi
  if [[ -z "$DOWNSTREAM_KUBECONFIG" ]]; then
    error "--kubeconfig is required"
    (( errors++ ))
  fi

  # 4. Downstream kubeconfig exists
  if [[ -n "$DOWNSTREAM_KUBECONFIG" && ! -f "$DOWNSTREAM_KUBECONFIG" ]]; then
    error "Kubeconfig not found: $DOWNSTREAM_KUBECONFIG"
    (( errors++ ))
  fi

  # 5. Downstream cluster is reachable
  if [[ -n "$DOWNSTREAM_KUBECONFIG" && -f "$DOWNSTREAM_KUBECONFIG" ]]; then
    if KUBECONFIG="$DOWNSTREAM_KUBECONFIG" kubectl get nodes --request-timeout=10s &>/dev/null; then
      local node_count
      node_count=$(KUBECONFIG="$DOWNSTREAM_KUBECONFIG" kubectl get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')
      success "Downstream cluster: reachable — $node_count node(s)"
    else
      error "Cannot reach downstream cluster using kubeconfig: $DOWNSTREAM_KUBECONFIG"
      (( errors++ ))
    fi
  fi

  # 6. Rancher URL reachable (test /healthz endpoint)
  if [[ -n "$RANCHER_URL" ]]; then
    local health_code
    health_code=$(
      bash -c "
        response=\$(
          /usr/bin/env bash -c \"
            exec 3<>/dev/tcp/\$(echo '${RANCHER_URL}' | sed 's|https://||' | cut -d/ -f1)/443 2>/dev/null &&
            echo -e 'GET /healthz HTTP/1.0\r\nHost: \$(echo ${RANCHER_URL} | sed s|https://||)\r\n\r\n' >&3 &&
            head -1 <&3 | awk '{print \$2}'
          \" 2>/dev/null
        ) 2>/dev/null
        echo \"\${response:-000}\"
      " 2>/dev/null || echo "000"
    )
    # Fallback: try wget if available
    if command -v wget &>/dev/null; then
      health_code=$(wget -q -O /dev/null --server-response "${RANCHER_URL}/healthz" 2>&1 | awk '/HTTP\//{print $2}' | tail -1 || echo "000")
    fi
    if [[ "$health_code" == "200" || "$health_code" == "301" || "$health_code" == "302" ]]; then
      success "Rancher URL: ${RANCHER_URL} (HTTP ${health_code})"
    else
      warn "Could not verify Rancher URL (got: ${health_code:-no response}). Continuing anyway — check URL if API calls fail."
    fi
  fi

  # 7. Validate API token by calling /v3
  if [[ -n "$API_TOKEN" && -n "$RANCHER_URL" ]]; then
    if command -v wget &>/dev/null; then
      local api_response
      api_response=$(
        wget -q -O - \
          --header="Authorization: Bearer ${API_TOKEN}" \
          --header="Content-Type: application/json" \
          "${RANCHER_URL}/v3" 2>/dev/null || echo ""
      )
      if echo "$api_response" | jq -e '.type' &>/dev/null; then
        success "API token: valid (authenticated to Rancher v3 API)"
      else
        error "API token appears invalid — check the token and Rancher URL"
        (( errors++ ))
      fi
    else
      warn "wget not found — skipping API token validation. Errors will surface during cluster creation."
    fi
  fi

  echo ""
  if [[ $errors -gt 0 ]]; then
    die "Preflight failed with $errors error(s). Fix the issues above and retry."
  fi
  success "All preflight checks passed."
  echo ""
}

# --------------------------------------------------------------------------- #
# Helper: call the Rancher API via wget
# --------------------------------------------------------------------------- #
rancher_api() {
  local method="$1"
  local path="$2"
  local body="${3:-}"

  if ! command -v wget &>/dev/null; then
    die "wget is required for API calls. Install wget and retry."
  fi

  if [[ -n "$body" ]]; then
    wget -q -O - \
      --method="$method" \
      --header="Authorization: Bearer ${API_TOKEN}" \
      --header="Content-Type: application/json" \
      --body-data="$body" \
      "${RANCHER_URL}${path}" 2>/dev/null
  else
    wget -q -O - \
      --method="$method" \
      --header="Authorization: Bearer ${API_TOKEN}" \
      --header="Content-Type: application/json" \
      "${RANCHER_URL}${path}" 2>/dev/null
  fi
}

# --------------------------------------------------------------------------- #
# Step 1: Create the cluster import record in Rancher
# --------------------------------------------------------------------------- #
create_cluster_record() {
  info "=== Step 1: Create cluster import record in Rancher ==="

  local payload
  payload=$(
    jq -n --arg name "$CLUSTER_NAME" '{
      "type": "cluster",
      "name": $name,
      "dockerRootDir": "/var/lib/docker",
      "enableNetworkPolicy": false,
      "labels": {},
      "annotations": {}
    }'
  )

  if [[ "$DRY_RUN" == "true" ]]; then
    echo -e "${YEL}[DRY-RUN]${NC} POST ${RANCHER_URL}/v3/clusters"
    echo -e "${YEL}[DRY-RUN]${NC} Body: $payload"
    CLUSTER_ID="dry-run-cluster-id"
    return
  fi

  local response
  response=$(rancher_api "POST" "/v3/clusters" "$payload")

  if ! echo "$response" | jq -e '.id' &>/dev/null; then
    error "Failed to create cluster record. Response:"
    echo "$response" | jq . 2>/dev/null || echo "$response"
    die "Cluster creation failed. Check your API token permissions (needs cluster:create)."
  fi

  CLUSTER_ID=$(echo "$response" | jq -r '.id')
  success "Cluster record created: id=${CLUSTER_ID}"
}

# --------------------------------------------------------------------------- #
# Step 2: Get the registration manifest URL
# --------------------------------------------------------------------------- #
get_manifest_url() {
  info "=== Step 2: Retrieve registration manifest URL ==="

  if [[ "$DRY_RUN" == "true" ]]; then
    echo -e "${YEL}[DRY-RUN]${NC} GET ${RANCHER_URL}/v3/clusters/dry-run-cluster-id/clusterregistrationtokens"
    MANIFEST_URL="${RANCHER_URL}/v3/import/dry-run-token.yaml"
    return
  fi

  # Poll for the registration token (may take a few seconds to be created)
  local attempts=0
  local max_attempts=12
  MANIFEST_URL=""

  while [[ $attempts -lt $max_attempts ]]; do
    local token_response
    token_response=$(rancher_api "GET" "/v3/clusters/${CLUSTER_ID}/clusterregistrationtokens")

    MANIFEST_URL=$(echo "$token_response" | jq -r '.data[0].manifestUrl // empty' 2>/dev/null)
    if [[ -n "$MANIFEST_URL" ]]; then
      success "Registration manifest URL: $MANIFEST_URL"
      return
    fi

    (( attempts++ ))
    info "Waiting for registration token... (attempt $attempts/$max_attempts)"
    sleep 5
  done

  die "Timed out waiting for registration manifest URL. Check Rancher logs: kubectl -n cattle-system logs -l app=rancher --tail=50"
}

# --------------------------------------------------------------------------- #
# Step 3: Download the manifest
# --------------------------------------------------------------------------- #
download_manifest() {
  info "=== Step 3: Download registration manifest ==="

  MANIFEST_FILE=$(mktemp /tmp/rancher-import-XXXXXX.yaml)

  if [[ "$DRY_RUN" == "true" ]]; then
    echo -e "${YEL}[DRY-RUN]${NC} wget -q -O /tmp/rancher-import.yaml '${MANIFEST_URL}'"
    MANIFEST_FILE="/tmp/rancher-import-dry-run.yaml"
    return
  fi

  if command -v wget &>/dev/null; then
    wget -q -O "$MANIFEST_FILE" \
      --header="Authorization: Bearer ${API_TOKEN}" \
      "$MANIFEST_URL"
  else
    die "wget required to download manifest"
  fi

  local line_count
  line_count=$(wc -l < "$MANIFEST_FILE" | tr -d ' ')
  success "Manifest downloaded: $MANIFEST_FILE ($line_count lines)"
}

# --------------------------------------------------------------------------- #
# Step 4: Apply the manifest to the downstream cluster
# --------------------------------------------------------------------------- #
apply_manifest() {
  info "=== Step 4: Apply manifest to downstream cluster ==="

  if [[ "$DRY_RUN" == "true" ]]; then
    echo -e "${YEL}[DRY-RUN]${NC} KUBECONFIG=${DOWNSTREAM_KUBECONFIG} kubectl apply -f ${MANIFEST_FILE}"
    echo ""
    echo "The manifest would create:"
    echo "  - cattle-system namespace"
    echo "  - ServiceAccount: cattle"
    echo "  - ClusterRole + ClusterRoleBinding: cattle-admin"
    echo "  - Secret: cattle-credentials-<hash>"
    echo "  - Deployment: cattle-cluster-agent"
    echo "  - DaemonSet: cattle-node-agent"
    return
  fi

  KUBECONFIG="$DOWNSTREAM_KUBECONFIG" kubectl apply -f "$MANIFEST_FILE"
  success "Manifest applied successfully."
}

# --------------------------------------------------------------------------- #
# Step 5: Poll until cluster reaches Active state
# --------------------------------------------------------------------------- #
wait_for_active() {
  info "=== Step 5: Waiting for cluster to reach Active state (timeout: ${POLL_TIMEOUT}s) ==="

  if [[ "$DRY_RUN" == "true" ]]; then
    echo -e "${YEL}[DRY-RUN]${NC} Polling GET ${RANCHER_URL}/v3/clusters/${CLUSTER_ID} for state=active"
    return
  fi

  local elapsed=0
  local state=""

  while [[ $elapsed -lt $POLL_TIMEOUT ]]; do
    local cluster_info
    cluster_info=$(rancher_api "GET" "/v3/clusters/${CLUSTER_ID}")
    state=$(echo "$cluster_info" | jq -r '.state // "unknown"' 2>/dev/null)

    case "$state" in
      active)
        success "Cluster reached Active state after ${elapsed}s."
        return 0
        ;;
      error)
        local message
        message=$(echo "$cluster_info" | jq -r '.message // "no message"')
        die "Cluster entered Error state: $message"
        ;;
      *)
        info "Current state: ${state} — elapsed: ${elapsed}s / ${POLL_TIMEOUT}s"
        ;;
    esac

    sleep "$POLL_INTERVAL"
    (( elapsed += POLL_INTERVAL ))
  done

  warn "Timed out after ${POLL_TIMEOUT}s waiting for Active state. Last state: ${state}"
  warn "Manual verification commands:"
  warn "  kubectl -n cattle-system get pods --kubeconfig=${DOWNSTREAM_KUBECONFIG}"
  warn "  kubectl -n cattle-system logs -l app=cattle-cluster-agent --kubeconfig=${DOWNSTREAM_KUBECONFIG}"
  exit 1
}

# --------------------------------------------------------------------------- #
# Print summary
# --------------------------------------------------------------------------- #
print_summary() {
  local dry_label=""
  [[ "$DRY_RUN" == "true" ]] && dry_label=" (DRY-RUN — no changes were made)"

  echo ""
  echo "============================================================"
  echo "  Import Summary${dry_label}"
  echo "============================================================"
  echo "  Cluster Name  : ${CLUSTER_NAME}"
  echo "  Cluster ID    : ${CLUSTER_ID:-n/a}"
  echo "  Rancher URL   : ${RANCHER_URL}"
  echo "  Kubeconfig    : ${DOWNSTREAM_KUBECONFIG}"
  echo "  Manifest      : ${MANIFEST_FILE:-n/a}"
  echo ""
  if [[ "$DRY_RUN" == "false" ]]; then
    echo "  Next steps:"
    echo "  1. Open Rancher UI → Cluster Management → verify '${CLUSTER_NAME}' is Active"
    echo "  2. Add cluster labels for Fleet targeting:"
    echo "     kubectl label clusters.fleet.cattle.io ${CLUSTER_NAME} env=staging -n fleet-default"
    echo "  3. Download Rancher-proxied kubeconfig from Cluster → ⋮ → Download KubeConfig"
  fi
  echo "============================================================"
  echo ""
}

# --------------------------------------------------------------------------- #
# Main
# --------------------------------------------------------------------------- #
main() {
  echo ""
  echo "================================================="
  echo "  Rancher Import Cluster Script"
  echo "  Rancher URL: ${RANCHER_URL:-<not set>}"
  echo "  Cluster:     ${CLUSTER_NAME:-<not set>}"
  echo "  Kubeconfig:  ${DOWNSTREAM_KUBECONFIG:-<not set>}"
  [[ "$DRY_RUN" == "true" ]] && echo "  Mode:        DRY-RUN"
  echo "================================================="

  preflight
  create_cluster_record
  get_manifest_url
  download_manifest
  apply_manifest
  wait_for_active
  print_summary
}

main "$@"
