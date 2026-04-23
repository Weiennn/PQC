#!/bin/bash
# setup_backhaul.sh — Creates dummy interfaces to simulate a RAN↔Core backhaul
# RAN subnet: 10.0.1.0/24 (ran0)
# Core subnet: 10.0.2.0/24 (core0)
set -e

echo "=== Setting up Backhaul Network ==="

# --- Cleanup any previous run ---
sudo ip link del ran0 2>/dev/null || true
sudo ip link del core0 2>/dev/null || true

# --- Create dummy interfaces ---
sudo ip link add ran0 type dummy
sudo ip link add core0 type dummy
sudo ip link set ran0 up
sudo ip link set core0 up

# --- RAN IPs (10.0.1.0/24) ---
sudo ip addr add 10.0.1.1/24 dev ran0     # gNB
sudo ip addr add 10.0.1.254/24 dev ran0   # secGW (RAN-facing anchor)

# --- Core NF IPs (10.0.2.0/24) ---
sudo ip addr add 10.0.2.1/24   dev core0  # secGW (Core-facing anchor)
sudo ip addr add 10.0.2.4/24  dev core0  # SMF
sudo ip addr add 10.0.2.5/24  dev core0  # AMF
sudo ip addr add 10.0.2.7/24  dev core0  # UPF
sudo ip addr add 10.0.2.10/24 dev core0  # NRF
sudo ip addr add 10.0.2.11/24 dev core0  # AUSF
sudo ip addr add 10.0.2.12/24 dev core0  # UDM
sudo ip addr add 10.0.2.13/24 dev core0  # PCF
sudo ip addr add 10.0.2.14/24 dev core0  # NSSF
sudo ip addr add 10.0.2.15/24 dev core0  # BSF
sudo ip addr add 10.0.2.20/24 dev core0  # UDR
sudo ip addr add 10.0.2.200/24 dev core0 # SCP
sudo ip addr add 10.0.2.250/24 dev core0 # SEPP1
sudo ip addr add 10.0.2.251/24 dev core0 # SEPP2
sudo ip addr add 10.0.2.252/24 dev core0 # SEPP N32

# --- Cross-subnet routing ---
# Allow RAN to reach Core and vice versa
sudo ip route add 10.0.2.0/24 dev ran0 2>/dev/null || true
sudo ip route add 10.0.1.0/24 dev core0 2>/dev/null || true

# --- Verification ---
echo ""
echo "RAN interface (ran0):"
ip addr show ran0 | grep "inet "
echo ""
echo "Core interface (core0):"
ip addr show core0 | grep "inet "
echo ""

# Note: Since both interfaces are on the same host, the kernel routes
# local-to-local traffic through loopback internally. This is normal.
# The dummy interfaces just provide distinct bind addresses for processes.
echo "Testing IP reachability..."
ping -c 1 -W 1 10.0.2.5 > /dev/null 2>&1 && echo "  AMF (10.0.2.5): OK" || echo "  AMF (10.0.2.5): FAILED"
ping -c 1 -W 1 10.0.2.7 > /dev/null 2>&1 && echo "  UPF (10.0.2.7): OK" || echo "  UPF (10.0.2.7): FAILED"
ping -c 1 -W 1 10.0.1.1 > /dev/null 2>&1 && echo "  gNB (10.0.1.1): OK" || echo "  gNB (10.0.1.1): FAILED"

echo ""
echo "=== Backhaul Network Ready ==="
echo "Note: Start NFs AFTER this script (./start.sh), then UERANSIM (./start_ran.sh)"
