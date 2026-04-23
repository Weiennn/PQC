#!/bin/bash
# teardown_secgw.sh — Removes the Security Gateway namespace and veth pairs
set -e

NS="ns_secgw"
VETH_RAN_HOST="veth-ran-h"
VETH_CORE_HOST="veth-core-h"
SECGW_RAN_IP="10.0.1.254"
SECGW_CORE_IP="10.0.2.1"

echo "=== Tearing down Security Gateway ==="

# Kill any StrongSwan daemons running in the namespace
sudo ip netns exec "$NS" killall charon 2>/dev/null || true
# Kill gNB-side StrongSwan (identified by config/PID file)
sudo killall -q charon 2>/dev/null || true

# Remove host routes pointing to secGW
sudo ip route del "${SECGW_RAN_IP}/32" 2>/dev/null || true
sudo ip route del "${SECGW_CORE_IP}/32" 2>/dev/null || true

# Delete veth pairs (deleting one end removes both)
sudo ip link del "$VETH_RAN_HOST" 2>/dev/null || true
sudo ip link del "$VETH_CORE_HOST" 2>/dev/null || true

# Delete namespace
sudo ip netns del "$NS" 2>/dev/null || true

# Cleanup temp files
rm -f /tmp/charon_secgw.pid /tmp/charon_secgw.log /tmp/charon_secgw.vici
rm -f /tmp/charon_gnb.pid /tmp/charon_gnb.log /tmp/charon_gnb.vici
rm -rf /tmp/secgw /tmp/gnb_ipsec

echo "=== Security Gateway Torn Down ==="
