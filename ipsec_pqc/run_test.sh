#!/bin/bash
set -e

BASE_DIR="$(pwd)/ipsec_pqc"
INSTALL_DIR="$BASE_DIR/_install"
DATA_DIR="$BASE_DIR/data"
CHARON="$INSTALL_DIR/libexec/ipsec/charon"
SWANCTL="$INSTALL_DIR/sbin/swanctl"

# Library path
export LD_LIBRARY_PATH="$INSTALL_DIR/lib:$INSTALL_DIR/lib64:$LD_LIBRARY_PATH"

# Helper for running in NS with correct environment
run_ns() {
    local ns=$1
    shift
    sudo -n LD_LIBRARY_PATH="$LD_LIBRARY_PATH" ip netns exec "$ns" "$@"
}

cleanup() {
    echo "=== Cleaning up ==="
    sudo -n killall charon 2>/dev/null || true
    sudo -n ./ipsec_pqc/setup_ns.sh # Deletes namespaces
}
trap cleanup EXIT

# 1. Setup Network Namespaces
echo "=== Setting up Network Namespaces ==="
sudo -n ./ipsec_pqc/setup_ns.sh


# 2. Prepare directories
mkdir -p /tmp/moon
mkdir -p /tmp/sun

# 3. Start Moon (Responder)
echo "=== Starting Moon (Responder) ==="
sudo -n ip netns exec ns_moon env LD_LIBRARY_PATH="$LD_LIBRARY_PATH" STRONGSWAN_CONF="$DATA_DIR/moon/strongswan.conf" "$CHARON" &
MOON_PID=$!
sleep 5 # Wait for startup

# Debug: Check algorithms (now that a daemon is running)
echo "=== Checking Available Algorithms (on Moon) ==="
run_ns ns_moon "$SWANCTL" --list-algs --uri unix:///tmp/charon_moon.vici

# Load Moon config
echo "Loading Moon config..."
run_ns ns_moon "$SWANCTL" --load-all --file "$DATA_DIR/moon/swanctl.conf" --uri unix:///tmp/charon_moon.vici

# 4. Start Sun (Initiator)
echo "=== Starting Sun (Initiator) ==="
sudo rm -f "$BASE_DIR/run/charon.pid"
sudo -n ip netns exec ns_sun env LD_LIBRARY_PATH="$LD_LIBRARY_PATH" STRONGSWAN_CONF="$DATA_DIR/sun/strongswan.conf" "$CHARON" &
SUN_PID=$!
sleep 5


# Load Sun config
echo "Loading Sun config..."
run_ns ns_sun "$SWANCTL" --load-all --file "$DATA_DIR/sun/swanctl.conf" --uri unix:///tmp/charon_sun.vici

# 5. Initiate Connection
echo "=== Initiating Connection from Sun ==="
run_ns ns_sun "$SWANCTL" --initiate --child net --uri unix:///tmp/charon_sun.vici || true

sleep 5

# 6. Verify
echo "=== Verifying Connection ==="
echo "Checking Moon SAs:"
run_ns ns_moon "$SWANCTL" --list-sas --uri unix:///tmp/charon_moon.vici

echo "Checking Sun SAs:"
run_ns ns_sun "$SWANCTL" --list-sas --uri unix:///tmp/charon_sun.vici

echo "Testing Encrypted Connectivity (Ping)..."
run_ns ns_sun ping -c 3 192.168.99.1

echo "Check policy status:"
run_ns ns_sun ip xfrm policy

echo "Done. Press Ctrl+C to stop daemons and cleanup."
sleep 1000

