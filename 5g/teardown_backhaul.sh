#!/bin/bash
# teardown_backhaul.sh — Removes the dummy backhaul interfaces
set -e

echo "=== Tearing down Backhaul Network ==="

sudo ip link del ran0 2>/dev/null || true
sudo ip link del core0 2>/dev/null || true

# Clean up any stale routes
sudo ip route del 10.0.2.0/24 2>/dev/null || true
sudo ip route del 10.0.1.0/24 2>/dev/null || true

echo "Done. Dummy interfaces removed."
