#!/bin/bash
# run_secgw.sh — Full lifecycle: setup network, generate certs/config, start tunnel, verify
#
# Usage:
#   sudo ./run_secgw.sh                          # Default ML-KEM-768
#   sudo ./run_secgw.sh aes256-sha384-ke1mlkem768   # Custom IKE proposal
#
# Prerequisites:
#   1. Backhaul network must be up: ../setup_backhaul.sh
#   2. StrongSwan must be built: ../../ipsec_pqc/build_deps.sh
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PQC_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
INSTALL_DIR="$PQC_ROOT/ipsec_pqc/_install"
DATA_DIR="$SCRIPT_DIR/data"
CHARON="$INSTALL_DIR/libexec/ipsec/charon"
SWANCTL="$INSTALL_DIR/sbin/swanctl"
IKE_PROPOSAL="${1:-aes256-sha384-mlkem768}"

NS="ns_secgw"

# Library path for StrongSwan
export LD_LIBRARY_PATH="$INSTALL_DIR/lib:$INSTALL_DIR/lib64:${LD_LIBRARY_PATH:-}"

# --- Pre-flight checks ---
if [ ! -f "$CHARON" ]; then
    echo "[ERROR] charon not found at $CHARON"
    echo "        Build StrongSwan first: cd $PQC_ROOT && ./ipsec_pqc/build_deps.sh"
    exit 1
fi

if ! ip link show ran0 &>/dev/null; then
    echo "[ERROR] ran0 interface not found. Run ../setup_backhaul.sh first."
    exit 1
fi

# Helper to run commands in the secGW namespace
run_secgw() {
    sudo -n LD_LIBRARY_PATH="$LD_LIBRARY_PATH" ip netns exec "$NS" "$@"
}

# --- Cleanup handler ---
cleanup() {
    echo ""
    echo "=== Cleaning up ==="
    sudo killall -q charon 2>/dev/null || true
    sudo ip netns exec "$NS" killall -q charon 2>/dev/null || true
    bash "$SCRIPT_DIR/teardown_secgw.sh" 2>/dev/null || true
}
trap cleanup EXIT

# ============================================================
# Step 1: Network Setup
# ============================================================
echo ""
echo "=========================================="
echo "  secGW — PQC Security Gateway for 5G"
echo "  IKE Proposal: $IKE_PROPOSAL"
echo "=========================================="
echo ""

echo ">>> Step 1/5: Setting up network namespace..."
sudo bash "$SCRIPT_DIR/setup_secgw.sh"
echo ""

# ============================================================
# Step 2: Generate Certs (if needed)
# ============================================================
if [ ! -f "$DATA_DIR/secgw/x509/secgwCert.pem" ] || [ ! -f "$DATA_DIR/gnb/x509/gnbCert.pem" ]; then
    echo ">>> Step 2/5: Generating certificates..."
    bash "$SCRIPT_DIR/gen_secgw_certs.sh"
else
    echo ">>> Step 2/5: Certificates already exist, skipping."
fi
echo ""

# ============================================================
# Step 3: Generate Config
# ============================================================
echo ">>> Step 3/5: Generating StrongSwan configs (IKE: $IKE_PROPOSAL)..."
bash "$SCRIPT_DIR/gen_secgw_config.sh" "$IKE_PROPOSAL"
echo ""

# ============================================================
# Step 4: Start StrongSwan Daemons
# ============================================================
echo ">>> Step 4/5: Starting StrongSwan daemons..."

# Prepare PID directories
mkdir -p /tmp/secgw /tmp/gnb_ipsec

# Helper: wait until a VICI unix socket is ready (up to 15s)
wait_for_socket() {
    local socket_path="$1"
    local label="$2"
    local max_wait=15
    local i=0
    while [ $i -lt $max_wait ]; do
        if [ -S "$socket_path" ]; then
            echo "  [$label] VICI socket ready."
            return 0
        fi
        sleep 1
        i=$((i + 1))
    done
    echo "  [$label] ERROR: socket $socket_path not ready after ${max_wait}s"
    echo "  [$label] Check log: $(echo "$socket_path" | sed 's|vici|log|')"
    return 1
}

# Start secGW (Responder) inside namespace
echo "  [secGW] Starting charon in $NS..."
sudo ip netns exec "$NS" env \
    LD_LIBRARY_PATH="$LD_LIBRARY_PATH" \
    STRONGSWAN_CONF="$DATA_DIR/secgw/strongswan.conf" \
    "$CHARON" > /tmp/charon_secgw_boot.log 2>&1 &
SECGW_PID=$!

wait_for_socket /tmp/charon_secgw.vici "secGW"

# Load secGW config
echo "  [secGW] Loading swanctl config..."
run_secgw "$SWANCTL" --load-all \
    --file "$DATA_DIR/secgw/swanctl.conf" \
    --uri unix:///tmp/charon_secgw.vici

echo ""

# Start gNB (Initiator) on the host
# Use sudo -E to inherit the already-exported LD_LIBRARY_PATH
echo "  [gNB] Starting charon on host..."
sudo -E \
    STRONGSWAN_CONF="$DATA_DIR/gnb/strongswan.conf" \
    "$CHARON" > /tmp/charon_gnb_boot.log 2>&1 &
GNB_PID=$!

wait_for_socket /tmp/charon_gnb.vici "gNB"

# Load gNB config (start_action = start will trigger tunnel initiation)
echo "  [gNB] Loading swanctl config (will initiate tunnel)..."
sudo -E "$SWANCTL" --load-all \
    --file "$DATA_DIR/gnb/swanctl.conf" \
    --uri unix:///tmp/charon_gnb.vici

# Wait for IKE exchange to complete
echo "  Waiting for tunnel establishment..."
sleep 5

# ============================================================
# Step 5: Verify
# ============================================================
echo ""
echo ">>> Step 5/5: Verifying tunnel..."
echo ""

echo "--- secGW Security Associations ---"
run_secgw "$SWANCTL" --list-sas --uri unix:///tmp/charon_secgw.vici || true
echo ""

echo "--- gNB Security Associations ---"
sudo -n LD_LIBRARY_PATH="$LD_LIBRARY_PATH" \
    "$SWANCTL" --list-sas --uri unix:///tmp/charon_gnb.vici || true
echo ""

echo "--- XFRM Policies (gNB) ---"
ip xfrm policy 2>/dev/null || true
echo ""

echo "--- XFRM Policies (secGW) ---"
sudo ip netns exec "$NS" ip xfrm policy 2>/dev/null || true
echo ""

# Test encrypted ping through the tunnel
echo "--- Encrypted Connectivity Test ---"
echo "  Pinging core subnet (10.0.2.5) from gNB through secGW tunnel..."
ping -c 3 -W 2 10.0.2.5 > /dev/null 2>&1 \
    && echo "  Result: OK — traffic flows through secGW" \
    || echo "  Result: FAILED — check logs at /tmp/charon_secgw.log and /tmp/charon_gnb.log"

echo ""
echo "=========================================="
echo "  secGW is RUNNING"
echo "  Logs: /tmp/charon_secgw.log, /tmp/charon_gnb.log"
echo "  Press Ctrl+C to stop and cleanup."
echo "=========================================="

# Keep running until interrupted
wait
