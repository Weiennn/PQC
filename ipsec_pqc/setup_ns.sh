#!/bin/bash
set -e

# Namespaces
NS_A="ns_moon"
NS_B="ns_sun"
VETH_A="veth_moon"
VETH_B="veth_sun"
IP_A="192.168.99.1"
IP_B="192.168.99.2"
SUBNET="24"

# Cleanup previous run
sudo ip netns del $NS_A 2>/dev/null || true
sudo ip netns del $NS_B 2>/dev/null || true

# Create namespaces
echo "Creating namespaces $NS_A and $NS_B..."
sudo ip netns add $NS_A
sudo ip netns add $NS_B

# Create veth pair
echo "Creating veth pair..."
sudo ip link add $VETH_A type veth peer name $VETH_B

# Move interfaces to namespaces
sudo ip link set $VETH_A netns $NS_A
sudo ip link set $VETH_B netns $NS_B

# Configure networking in NS_A (Moon)
echo "Configuring $NS_A..."
sudo ip netns exec $NS_A ip link set lo up
sudo ip netns exec $NS_A ip link set $VETH_A up
sudo ip netns exec $NS_A ip addr add $IP_A/$SUBNET dev $VETH_A

# Configure networking in NS_B (Sun)
echo "Configuring $NS_B..."
sudo ip netns exec $NS_B ip link set lo up
sudo ip netns exec $NS_B ip link set $VETH_B up
sudo ip netns exec $NS_B ip addr add $IP_B/$SUBNET dev $VETH_B

# Test connectivity
echo "Testing connectivity..."
sudo ip netns exec $NS_A ping -c 1 $IP_B > /dev/null
echo "Network setup complete."
