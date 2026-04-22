#!/bin/bash
# Get the project root directory (absolute path)
PROJECT_ROOT="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"

# set -e removed

# Check for --netns and --capture arguments
USE_NETNS=0
USE_CAPTURE=0
for arg in "$@"; do
    if [[ "$arg" == "--netns" ]]; then
        USE_NETNS=1
    elif [[ "$arg" == "--capture" ]]; then
        USE_CAPTURE=1
    fi
done

# Export library paths for OpenSSL and OQS (needed BEFORE netns setup)
export LD_LIBRARY_PATH="$PROJECT_ROOT/../local/lib64:$PROJECT_ROOT/../local/lib:$LD_LIBRARY_PATH"
export OPENSSL_MODULES="$PROJECT_ROOT/../local/lib64/ossl-modules"
export OPENSSL_CONF="$PROJECT_ROOT/openssl_oqs.cnf"

# Ensure providers are available (fallback to lib if lib64 doesn't have it)
if [ ! -f "$OPENSSL_MODULES/oqsprovider.so" ]; then
    export OPENSSL_MODULES="$PROJECT_ROOT/../local/lib/ossl-modules"
fi

# Check if we are running as root/sudo (required for netns or capture)
if [ "$USE_NETNS" -eq 1 ] || [ "$USE_CAPTURE" -eq 1 ]; then
    if [ "$EUID" -ne 0 ]; then 
        echo "Please run with sudo to use --netns or --capture"
        exit 1
    fi
    
    if [ -f "./netns_utils.sh" ]; then
        source ./netns_utils.sh
    else
        echo "Error: netns_utils.sh not found."
        exit 1
    fi
fi

if [ "$USE_NETNS" -eq 1 ]; then
    echo "[BENCH] Network Namespace mode enabled (MTU 1500)"
    
    # Setup Namespaces
    setup_ns 
    
    # Override configuration for NetNS
    # We must explicitly inject the environment variables into the namespace exec
    ENV_VARS="LD_LIBRARY_PATH=$LD_LIBRARY_PATH OPENSSL_MODULES=$OPENSSL_MODULES OPENSSL_CONF=$OPENSSL_CONF"
    
    SERVER_BIN="ip netns exec $SERVER_NS env $ENV_VARS ./build/pqc_server_threaded"
    OPENSSL_BIN="./../local/bin/openssl" # Relative to PROJECT_ROOT
    CLIENT_CMD_PREFIX="ip netns exec $CLIENT_NS env $ENV_VARS"
    HOST="$SERVER_IP" # Defined in netns_utils.sh (10.0.0.1)

    if [ "$USE_CAPTURE" -eq 1 ]; then
        start_capture $SERVER_NS "hps_benchmark.pcap"
    fi
elif [ "$USE_CAPTURE" -eq 1 ]; then
    echo "[BENCH] Capture enabled on host loopback interface"
    start_capture "host" "hps_benchmark_host.pcap"
fi

# Configuration
DURATION=10
CONCURRENCY=4
# Default to local build, but allow overrides
SERVER_BIN="${SERVER_BIN:-./build/pqc_server_threaded}"
OPENSSL_BIN="${OPENSSL_BIN:-./../local/bin/openssl}"
HOST="${HOST:-127.0.0.1}"
CLIENT_CMD_PREFIX="${CLIENT_CMD_PREFIX:-}"
CERT_DIR="certs"

# Export library paths again to ensure they are in the current shell's environment
# (though they were exported above, this section keeps configuration together)
export LD_LIBRARY_PATH="$LD_LIBRARY_PATH"
export OPENSSL_MODULES="$OPENSSL_MODULES"
export OPENSSL_CONF="$OPENSSL_CONF"

# Ensure cleanup on exit
cleanup() {
    echo "Stopping background processes..."
    kill $(jobs -p) 2>/dev/null || true
    pkill -f pqc_server_threaded || true
    
    if [ "$USE_CAPTURE" -eq 1 ]; then
        stop_capture
    fi
    if [ "$USE_NETNS" -eq 1 ]; then
        teardown_ns
    fi
    
    # Wait a bit for port release
    sleep 2
}
trap cleanup EXIT INT TERM

function run_hps_test() {
    local name=$1
    local cert_sub=$2
    local kem_group=$3
    local ca_file="$CERT_DIR/$cert_sub/ca_cert.pem"
    local server_cert="$CERT_DIR/$cert_sub/server_cert.pem"
    local server_key="$CERT_DIR/$cert_sub/server_key.pem"
    
    echo "------------------------------------------------------------"
    echo "Benchmarking: $name"
    echo "  - Auth: $cert_sub"
    echo "  - KEM:  $kem_group"
    
    # Ensure port is free
    fuser -k 4433/tcp >/dev/null 2>&1 || true
    sleep 1

    # Start Threaded Server
    $SERVER_BIN -c "$server_cert" -k "$server_key" -g "$kem_group" > server_hps.log 2>&1 &
    SERVER_PID=$!
    
    # Wait for server and check if it died
    sleep 2
    if ! kill -0 $SERVER_PID 2>/dev/null; then
        echo "  [FATAL] Server failed to start."
        cat server_hps.log
        exit 1
    fi
    
    # Output file
    local out_file="hps_${name}.txt"
    rm -f "$out_file"

    # Start parallel s_time instances
    pids=""
    for i in $(seq 1 $CONCURRENCY); do
        # -new forces new session (full handshake)
        # -time $DURATION specifies runtime
        # -verify 1 forces validation
        # -www is standard s_time fetch
        # -provider oqsprovider is strictly needed for PQC algos
        
        ${CLIENT_CMD_PREFIX} $OPENSSL_BIN s_time \
            -connect ${HOST}:4433 \
            -new \
            -www / \
            -time $DURATION \
            -provider oqsprovider \
            -provider default \
            > "${out_file}.${i}" 2>&1 &
            
        pids="$pids $!"
    done
    
    # Wait for all clients
    wait $pids
    
    # Kill server
    kill $SERVER_PID
    wait $SERVER_PID 2>/dev/null || true
    
    # Aggregate results
    local total_connections=0
    
    for i in $(seq 1 $CONCURRENCY); do
        # Extract "connections" from the s_time output
        # Format usually: "XX connections in X.XXs; X.XX connections/user sec, bytes read: X"
        # We want the first number "XX connections"
        
        # Example output line: "123 connections in 10.01s; 12.30 connections/user sec, bytes read: 0"
        # We verify parsing manually
        local conns=$(grep "connections in" "${out_file}.${i}" | head -n 1 | awk '{print $1}')
        
        if [ -z "$conns" ]; then
             conns=0
             echo "  [WARNING] Instance $i failed to report connections."
             # For debug:
             # cat "${out_file}.${i}" 
        fi
        
        total_connections=$((total_connections + conns))
        # clean up temp file
        rm "${out_file}.${i}"
    done
    
    local hps=$(echo "scale=2; $total_connections / $DURATION" | bc)
    
    echo "  Total Connections: $total_connections"
    echo "  Duration: ${DURATION}s"
    echo "  HPS: $hps"
    
    eval "${name}_HPS=$hps"
    echo ""
}

echo "Starting Handshake Per Second (HPS) Benchmark"
echo "Duration: ${DURATION}s per test | Concurrency: ${CONCURRENCY} clients"
echo ""

# 1. Classical (RSA + X25519)
run_hps_test "Classical" "rsa" "x25519"

# 2. Hybrid (RSA + ML-KEM-768:X25519)
run_hps_test "Hybrid" "rsa" "mlkem768:x25519"

# 3. PQC KEM (RSA + ML-KEM-768)
run_hps_test "PQC_KEM" "rsa" "mlkem768"


# 4. Full PQC (ML-DSA-44 + ML-KEM-768)
run_hps_test "Full_PQC" "mldsa44" "mlkem768"

# 5. ECDSA Classical (ECDSA + X25519)
run_hps_test "ECDSA_Classical" "ecdsa" "x25519"

# 6. ECDSA Hybrid (ECDSA + ML-KEM-768:X25519)
run_hps_test "ECDSA_Hybrid" "ecdsa" "mlkem768:x25519"

echo "==========================================================="
echo "                SUMMARY OF HPS (Handshakes/sec)            "
echo "==========================================================="
printf "%-30s | %-15s\n" "Scenario" "HPS"
echo "-----------------------------------------------------------"
printf "%-30s | %15s\n" "Classical (RSA-X25519)" "${Classical_HPS:-N/A}"
printf "%-30s | %15s\n" "Hybrid (RSA-MLKEM)" "${Hybrid_HPS:-N/A}"
printf "%-30s | %15s\n" "PQC KEM (RSA-MLKEM)" "${PQC_KEM_HPS:-N/A}"
printf "%-30s | %15s\n" "Full PQC (MLDSA-MLKEM)" "${Full_PQC_HPS:-N/A}"
printf "%-30s | %15s\n" "ECDSA (ECDSA-X25519)" "${ECDSA_Classical_HPS:-N/A}"
printf "%-30s | %15s\n" "ECDSA Hybrid (ECDSA-MLKEM)" "${ECDSA_Hybrid_HPS:-N/A}"
echo "==========================================================="
