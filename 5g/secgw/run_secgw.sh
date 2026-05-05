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

# --- Require root ---
# charon needs CAP_NET_ADMIN to install XFRM/routing table rules via netlink.
# Running as non-root fails with: "unable to create IPv4 routing table rule"
if [[ $EUID -ne 0 ]]; then
    echo "[ERROR] This script must be run as root: sudo $0 $*"
    exit 1
fi

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

# --- Clean stale temp files from previous runs ---
# If a previous run was interrupted, boot logs, vici sockets, or PID files
# may remain in /tmp. Stale .vici sockets fool wait_for_socket into thinking
# charon is ready when it isn't. Stale boot logs cause 'Permission denied'
# if they were created by a different user (e.g. a previous non-sudo run).
rm -f /tmp/charon_secgw.vici /tmp/charon_secgw.pid /tmp/charon_secgw.log \
       /tmp/charon_secgw_boot.log \
       /tmp/charon_gnb.vici   /tmp/charon_gnb.pid   /tmp/charon_gnb.log \
       /tmp/charon_gnb_boot.log 2>/dev/null || true

# Helper to run commands in the secGW namespace (no inner sudo — we are already root)
run_secgw() {
    LD_LIBRARY_PATH="$LD_LIBRARY_PATH" ip netns exec "$NS" "$@"
}

# --- Cleanup handler ---
cleanup() {
    echo ""
    echo "=== Cleaning up ==="
    killall -q charon 2>/dev/null || true
    ip netns exec "$NS" killall -q charon 2>/dev/null || true
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
bash "$SCRIPT_DIR/setup_secgw.sh"
echo ""

# ============================================================
# Step 2: Generate Certs (if needed)
# ============================================================
if [ ! -f "$DATA_DIR/secgw/x509/secgwCert.pem" ] || [ ! -f "$DATA_DIR/gnb/x509/gnbCert.pem" ]; then
    echo ">>> Step 2/5: Generating certificates..."
    bash "$SCRIPT_DIR/gen_secgw_certs.sh"
else
    # Ensure cert dirs exist with correct perms even if certs are pre-generated
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

# --- Kill any stale host-side charon holding port 500 ---
if sudo ss -ulnp 2>/dev/null | grep -q ':500'; then
    echo "  [pre-flight] Stale charon found on port 500 — killing it..."
    sudo killall -q charon 2>/dev/null || true
    sleep 2
fi

# Prepare PID directories
mkdir -p /tmp/secgw /tmp/gnb_ipsec

# Helper: wait until a VICI unix socket is ready (up to 15s)
# Also checks that the charon PID is still alive — catches crashes that
# leave a stale socket file on disk (which would fool a plain -S check).
wait_for_socket() {
    local socket_path="$1"
    local label="$2"
    local pid="$3"          # optional: charon PID to liveness-check
    local max_wait=15
    local i=0
    while [ $i -lt $max_wait ]; do
        # If a PID was given and it's already dead, fail immediately
        if [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null; then
            echo "  [$label] ERROR: charon (pid=$pid) exited before socket appeared."
            echo "  [$label] Exit code 66 usually means port 500 is already in use."
            echo "  [$label] Run: sudo ss -ulnp | grep ':500'"
            return 1
        fi
        if [ -S "$socket_path" ]; then
            sleep 1   # brief settle — socket appears just before charon is fully ready
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
ip netns exec "$NS" env \
    LD_LIBRARY_PATH="$LD_LIBRARY_PATH" \
    STRONGSWAN_CONF="$DATA_DIR/secgw/strongswan.conf" \
    "$CHARON" > /tmp/charon_secgw_boot.log 2>&1 &
SECGW_PID=$!

wait_for_socket /tmp/charon_secgw.vici "secGW" "$SECGW_PID"

# Load secGW config
echo "  [secGW] Loading swanctl config..."
run_secgw "$SWANCTL" --load-all \
    --file "$DATA_DIR/secgw/swanctl.conf" \
    --uri unix:///tmp/charon_secgw.vici

echo ""

# Start gNB (Initiator) on the host
# Each charon instance writes a PID file to its piddir. The secGW uses
# /tmp/secgw/ and the gNB uses /tmp/gnb_ipsec/ (set in strongswan.conf).
# Remove any stale default-location PID files that might confuse charon.
rm -f "$INSTALL_DIR/../run/charon.pid" \
      "$INSTALL_DIR/var/run/charon.pid" \
      "$PQC_ROOT/ipsec_pqc/run/charon.pid" 2>/dev/null || true

echo "  [gNB] Starting charon on host..."
env \
    LD_LIBRARY_PATH="$LD_LIBRARY_PATH" \
    STRONGSWAN_CONF="$DATA_DIR/gnb/strongswan.conf" \
    "$CHARON" > /tmp/charon_gnb_boot.log 2>&1 &
GNB_PID=$!

wait_for_socket /tmp/charon_gnb.vici "gNB" "$GNB_PID"

# Load gNB config (start_action = start will trigger tunnel initiation)
echo "  [gNB] Loading swanctl config (will initiate tunnel)..."
env LD_LIBRARY_PATH="$LD_LIBRARY_PATH" \
    "$SWANCTL" --load-all \
    --file "$DATA_DIR/gnb/swanctl.conf" \
    --uri unix:///tmp/charon_gnb.vici

# ML-KEM-768 IKE payloads (~1184 bytes) require IP fragmentation on a 1500-byte MTU
# link. Allow extra time compared to classical DH for fragment reassembly.
echo "  Waiting for tunnel establishment (15s for ML-KEM-768 fragmentation)..."
sleep 15

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
env LD_LIBRARY_PATH="$LD_LIBRARY_PATH" \
    "$SWANCTL" --list-sas --uri unix:///tmp/charon_gnb.vici || true
echo ""

echo "--- XFRM States (ESP SAs installed by kernel) ---"
ip xfrm state 2>/dev/null | grep -E 'src|proto|enc|auth' | head -20 || echo "  (none — tunnel not established)"
echo ""

echo "--- XFRM Policies (gNB — tunnel rules) ---"
ip xfrm policy 2>/dev/null | grep -v 'socket' | grep -v '^$' || echo "  (only socket bypass rules — tunnel policies not installed yet)"
echo ""

# Verify using XFRM byte counters — a plain ping succeeds even without IPsec
# (backhaul routing reaches 10.0.2.0/24 directly). Only XFRM counters confirm
# that traffic is actually encrypted through the ESP SA.
echo "--- ESP Encryption Verification ---"
BEFORE=$(ip xfrm state 2>/dev/null | grep 'bytes' | awk '{sum+=$2} END {print sum+0}')
ping -c 3 -W 2 10.0.2.5 > /dev/null 2>&1 || true
AFTER=$(ip xfrm state 2>/dev/null | grep 'bytes' | awk '{sum+=$2} END {print sum+0}')
if [ "$AFTER" -gt "$BEFORE" ] 2>/dev/null; then
    echo "  Result: ENCRYPTED — XFRM byte counters increased (traffic going through ESP SA)"
elif ip xfrm state 2>/dev/null | grep -q 'proto esp'; then
    echo "  Result: SA PRESENT — ESP SA installed but ping may not be routed through it yet"
    echo "  Check: ip xfrm state  &&  ip xfrm policy"
else
    echo "  Result: NOT ENCRYPTED — no ESP SA found."
    echo ""
    echo "--- gNB IKE log (last 30 lines) ---"
    tail -30 /tmp/charon_gnb.log 2>/dev/null || echo "  (log not found)"
    echo ""
    echo "--- secGW IKE log (last 20 lines) ---"
    tail -20 /tmp/charon_secgw.log 2>/dev/null || echo "  (log not found)"
fi

echo ""
echo "=========================================="
echo "  secGW is RUNNING"
echo "  Logs: /tmp/charon_secgw.log, /tmp/charon_gnb.log"
echo "  Press Ctrl+C to stop and cleanup."
echo "=========================================="

# Keep running until interrupted
wait
