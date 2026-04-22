#!/bin/bash

SERVER_NS="pqc_server_ns"
CLIENT_NS="pqc_client_ns"
VETH_SERVER="veth_s"
VETH_SERVER_PEER="veth_s_peer"
VETH_CLIENT="veth_c"
VETH_CLIENT_PEER="veth_c_peer"
BRIDGE="br_pqc"

PREFIX="10.0.0"
SERVER_IP="${PREFIX}.1"
CLIENT_IP="${PREFIX}.2"
NETMASK="24"
# Using MTU 1500 to simulate standard Ethernet and force PQC fragmentation
MTU="1500" 

function setup_ns() {
    echo "[NETNS] Setting up namespaces..."
    
    # 1. Clean up old environment if it exists to ensure a fresh start
    teardown_ns 2>/dev/null

    # 2. Create the segregated Network Namespaces
    # These act like independent networking stacks (containers without the filesystem)
    sudo ip netns add $SERVER_NS
    sudo ip netns add $CLIENT_NS

    # 3. Create a Virtual Ethernet (veth) pair
    # Imagine this as a virtual crossover cable. Data sent into VETH_SERVER comes out of VETH_CLIENT
    sudo ip link add ${VETH_SERVER} type veth peer name ${VETH_CLIENT}

    # 4. Move each end of the virtual cable into its respective namespace
    # Once moved, the physical host can no longer see these interfaces directly
    sudo ip link set ${VETH_SERVER} netns $SERVER_NS
    sudo ip link set ${VETH_CLIENT} netns $CLIENT_NS

    # 5. Configure the Server Namespace
    # Assign an IP address to the virtual interface inside the server namespace
    sudo ip netns exec $SERVER_NS ip addr add ${SERVER_IP}/${NETMASK} dev ${VETH_SERVER}
    # Bring the virtual interface UP (enable it)
    sudo ip netns exec $SERVER_NS ip link set ${VETH_SERVER} up
    # Enable the Loopback interface (standard practice for stable networking)
    sudo ip netns exec $SERVER_NS ip link set dev lo up
    # Force the MTU to 1500 to simulate standard Ethernet behavior (crucial for PQC fragmentation tests)
    sudo ip netns exec $SERVER_NS ip link set dev ${VETH_SERVER} mtu $MTU
    
    # Disable "Offloading" (GSO, TSO, GRO)
    # This prevents the CPU from merging small packets into one giant packet before sending.
    # We want to see the individual 1500-byte packets in tcpdump.
    sudo ip netns exec $SERVER_NS ethtool -K ${VETH_SERVER} gso off tso off gro off >/dev/null 2>&1 || true

    # 6. Configure the Client Namespace
    # Similar steps as above but for the client side
    sudo ip netns exec $CLIENT_NS ip addr add ${CLIENT_IP}/${NETMASK} dev ${VETH_CLIENT}
    sudo ip netns exec $CLIENT_NS ip link set ${VETH_CLIENT} up
    sudo ip netns exec $CLIENT_NS ip link set dev lo up
    sudo ip netns exec $CLIENT_NS ip link set dev ${VETH_CLIENT} mtu $MTU
    sudo ip netns exec $CLIENT_NS ethtool -K ${VETH_CLIENT} gso off tso off gro off >/dev/null 2>&1 || true

    # 7. Add Simulated Network Latency (Optional)
    # setup_ns 10ms will add a 10ms delay to the client's interface using 'tc' (Traffic Control)
    if [ ! -z "$1" ]; then
        echo "[NETNS] Adding $1 latency to client interface..."
        # 'netem' (Network Emulator) is used to simulate WAN conditions
        sudo ip netns exec $CLIENT_NS tc qdisc add dev ${VETH_CLIENT} root netem delay $1
    fi

    echo "[NETNS] Setup complete."
    echo "  Server: $SERVER_IP (MTU $MTU) in $SERVER_NS"
    echo "  Client: $CLIENT_IP (MTU $MTU) in $CLIENT_NS"
    echo "  Note: Use the namespace NAME (e.g. $SERVER_NS) not the IP for 'ip netns exec'"
}

function teardown_ns() {
    echo "[NETNS] Tearing down namespaces..."
    sudo ip netns del $SERVER_NS 2>/dev/null || true
    sudo ip netns del $CLIENT_NS 2>/dev/null || true
    # veths are destroyed when namespaces are deleted
}

# Check connectivity
function verify_ns() {
    echo "[NETNS] Verifying connectivity..."
    sudo ip netns exec $CLIENT_NS ping -c 2 $SERVER_IP
}

# Packet Capture
function start_capture() {
    local ns=$1
    local pcap_file=$2
    local interface=$VETH_SERVER
    local cmd_prefix="sudo ip netns exec $ns"

    # Ensure captures directory exists
    mkdir -p captures
    local target_pcap="captures/$pcap_file"

    if [ "$ns" == "$CLIENT_NS" ]; then
        interface=$VETH_CLIENT
    elif [ "$ns" == "host" ] || [ -z "$ns" ]; then
        interface="lo"
        cmd_prefix="sudo"
    fi

    echo "[NETNS] Starting capture on $interface -> $target_pcap"
    # Run tcpdump in background. -U for unbuffered, -i interface, -w file
    $cmd_prefix tcpdump -U -i $interface -w "$target_pcap" >/dev/null 2>&1 &
    TCPDUMP_PID=$!
    # Small sleep to ensure tcpdump is ready
    sleep 1
}

function stop_capture() {
    if [ ! -z "$TCPDUMP_PID" ]; then
        echo "[NETNS] Stopping capture (PID $TCPDUMP_PID)..."
        sudo kill $TCPDUMP_PID 2>/dev/null || true
        wait $TCPDUMP_PID 2>/dev/null || true
        unset TCPDUMP_PID
    fi
}

# Execute a command in the server namespace
# Usage: run_in_server_ns <command> [args...]
function run_in_server_ns() {
    sudo ip netns exec "$SERVER_NS" "$@"
}

# Execute a command in the client namespace
# Usage: run_in_client_ns <command> [args...]
function run_in_client_ns() {
    sudo ip netns exec "$CLIENT_NS" "$@"
}

# Execute a command in the server namespace with environment variables preserved
# Usage: run_in_server_ns_env <command> [args...]
# Requires ENV_VARS to be set in the calling script
function run_in_server_ns_env() {
    sudo -E env $ENV_VARS ip netns exec "$SERVER_NS" "$@"
}

# Execute a command in the client namespace with environment variables preserved
# Usage: run_in_client_ns_env <command> [args...]
# Requires ENV_VARS to be set in the calling script
function run_in_client_ns_env() {
    sudo -E env $ENV_VARS ip netns exec "$CLIENT_NS" "$@"
}

# Execute a command in the client namespace with custom extra environment variables
# Usage: run_in_client_ns_custom_env <extra_env_vars> <command> [args...]
# Requires ENV_VARS to be set in the calling script
# Example: run_in_client_ns_custom_env "OPENSSL_CONF=/path/to/conf" ./openssl s_time ...
function run_in_client_ns_custom_env() {
    local extra_env=$1
    shift
    sudo -E env $ENV_VARS $extra_env ip netns exec "$CLIENT_NS" "$@"
}

# Kill processes matching a pattern in a namespace
# Usage: pkill_in_ns <namespace> <pattern>
function pkill_in_ns() {
    local ns=$1
    local pattern=$2
    # Use pkill without -f to match process name only (avoids matching own cmdline)
    sudo ip netns exec "$ns" pkill -9 "$pattern" >/dev/null 2>&1 || true
}

# Check if a process matching a pattern is running in a namespace
# Usage: pgrep_in_ns <namespace> <pattern>
# Returns: 0 if process found, 1 otherwise
function pgrep_in_ns() {
    local ns=$1
    local pattern=$2
    sudo ip netns exec "$ns" pgrep -f "$pattern" > /dev/null 2>&1
}

# Kill processes using a specific port in a namespace
# Usage: fuser_kill_in_ns <namespace> <port>
function fuser_kill_in_ns() {
    local ns=$1
    local port=$2
    (sudo ip netns exec "$ns" fuser -k "${port}/tcp" >/dev/null 2>&1) 2>/dev/null || true
}
