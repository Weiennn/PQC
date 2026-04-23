#!/bin/bash
# setup_secgw.sh — Creates a Security Gateway namespace between RAN and Core
#
# Topology:
#   Host ran0 (10.0.1.1/gNB) ◄──veth──► ns_secgw eth-ran (10.0.1.254)
#   Host core0 (10.0.2.x/NFs) ◄──veth──► ns_secgw eth-core (10.0.2.1)
#
# The secGW forwards decrypted traffic between subnets.
set -e

NS="ns_secgw"

# veth pairs: host-side <-> namespace-side
VETH_RAN_HOST="veth-ran-h"
VETH_RAN_NS="eth-ran"
VETH_CORE_HOST="veth-core-h"
VETH_CORE_NS="eth-core"

# IPs
SECGW_RAN_IP="10.0.1.254"
SECGW_CORE_IP="10.0.2.1"
RAN_SUBNET="10.0.1.0/24"
CORE_SUBNET="10.0.2.0/24"
GNB_IP="10.0.1.1"

echo "=== Setting up Security Gateway Namespace ==="

# --- Cleanup previous run ---
sudo ip netns del "$NS" 2>/dev/null || true
sudo ip link del "$VETH_RAN_HOST" 2>/dev/null || true
sudo ip link del "$VETH_CORE_HOST" 2>/dev/null || true

# --- Create namespace ---
echo "[1/6] Creating namespace $NS..."
sudo ip netns add "$NS"

# --- Create veth pairs ---
echo "[2/6] Creating veth pairs..."
sudo ip link add "$VETH_RAN_HOST" type veth peer name "$VETH_RAN_NS"
sudo ip link add "$VETH_CORE_HOST" type veth peer name "$VETH_CORE_NS"

# --- Move namespace-side interfaces into ns_secgw ---
sudo ip link set "$VETH_RAN_NS" netns "$NS"
sudo ip link set "$VETH_CORE_NS" netns "$NS"

# --- Configure host-side interfaces ---
echo "[3/6] Configuring host-side interfaces..."
# Attach host-side veths to the existing dummy bridges
# We bring them up and add them to the same subnets so traffic can flow
sudo ip link set "$VETH_RAN_HOST" up
sudo ip link set "$VETH_CORE_HOST" up
# These don't need IPs — they act as L2 bridges. We add routes instead.

# --- Configure namespace-side interfaces ---
echo "[4/6] Configuring namespace interfaces..."
sudo ip netns exec "$NS" ip link set lo up
sudo ip netns exec "$NS" ip link set "$VETH_RAN_NS" up
sudo ip netns exec "$NS" ip link set "$VETH_CORE_NS" up
sudo ip netns exec "$NS" ip addr add "${SECGW_RAN_IP}/24" dev "$VETH_RAN_NS"
sudo ip netns exec "$NS" ip addr add "${SECGW_CORE_IP}/24" dev "$VETH_CORE_NS"

# Enable IP forwarding in the namespace (secGW must route between subnets)
sudo ip netns exec "$NS" sysctl -w net.ipv4.ip_forward=1 >/dev/null

# --- Routing ---
echo "[5/6] Setting up routes..."

# Host → secGW RAN-side: traffic to 10.0.1.254 goes via veth
sudo ip route add "${SECGW_RAN_IP}/32" dev "$VETH_RAN_HOST" 2>/dev/null || true
# Host → secGW Core-side: traffic to 10.0.2.1 goes via veth
sudo ip route add "${SECGW_CORE_IP}/32" dev "$VETH_CORE_HOST" 2>/dev/null || true

# Inside namespace: route to gNB via RAN-side, route to core NFs via core-side
sudo ip netns exec "$NS" ip route add "${GNB_IP}/32" dev "$VETH_RAN_NS" 2>/dev/null || true
sudo ip netns exec "$NS" ip route add "${CORE_SUBNET}" dev "$VETH_CORE_NS" 2>/dev/null || true

# On the host (gNB side): route to core via secGW
# This makes gNB traffic headed for the core go through the secGW
# We do NOT override the existing core0 routes — only add a gateway hint
# The IPSec policies will handle actual routing into the tunnel

# --- ARP/Proxy ---
# Enable proxy ARP so the secGW can answer for the other subnet
sudo ip netns exec "$NS" sysctl -w net.ipv4.conf.all.proxy_arp=1 >/dev/null

# --- Verification ---
echo "[6/6] Verifying connectivity..."
echo ""

# Host → secGW (RAN side)
ping -c 1 -W 1 "$SECGW_RAN_IP" > /dev/null 2>&1 \
    && echo "  Host → secGW RAN (${SECGW_RAN_IP}): OK" \
    || echo "  Host → secGW RAN (${SECGW_RAN_IP}): FAILED"

# Host → secGW (Core side)
ping -c 1 -W 1 "$SECGW_CORE_IP" > /dev/null 2>&1 \
    && echo "  Host → secGW Core (${SECGW_CORE_IP}): OK" \
    || echo "  Host → secGW Core (${SECGW_CORE_IP}): FAILED"

# secGW → gNB
sudo ip netns exec "$NS" ping -c 1 -W 1 "$GNB_IP" > /dev/null 2>&1 \
    && echo "  secGW → gNB (${GNB_IP}): OK" \
    || echo "  secGW → gNB (${GNB_IP}): FAILED"

echo ""
echo "=== Security Gateway Network Ready ==="
echo "  Namespace:  $NS"
echo "  RAN-side:   $SECGW_RAN_IP (${VETH_RAN_NS})"
echo "  Core-side:  $SECGW_CORE_IP (${VETH_CORE_NS})"
