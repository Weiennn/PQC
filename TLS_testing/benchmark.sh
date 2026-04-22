#!/bin/bash
# benchmark.sh
# Simple latency/CPU/throughput benchmark across KEM algorithms.
# Runs on localhost (127.0.0.1) — NO network namespaces.
# Applies tc netem on 'lo': 5ms ± 2ms delay, 0.1% packet loss, MTU 1500.
# Traffic is visible to Wireshark on the 'lo' interface, port 4433.
# Requires sudo (tc and ip link need root).

# Require root — needed for tc qdisc and ip link set
if [ "$EUID" -ne 0 ]; then
    echo "[ERROR] Please run with sudo (required for tc netem on lo)"
    exit 1
fi

# Get the project root directory (absolute path)
PROJECT_ROOT="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"

# Ensure we can find the openssl modules and libraries
export LD_LIBRARY_PATH="$PROJECT_ROOT/../local/lib64:$PROJECT_ROOT/../local/lib:$LD_LIBRARY_PATH"
export OPENSSL_MODULES="$PROJECT_ROOT/../local/lib64/ossl-modules"
export OPENSSL_CONF="$PROJECT_ROOT/openssl_oqs.cnf"

# Verify oqsprovider.so is reachable (fallback path)
if [ ! -f "$OPENSSL_MODULES/oqsprovider.so" ]; then
    export OPENSSL_MODULES="$PROJECT_ROOT/../local/lib/ossl-modules"
fi

# --- Configuration ---
SERVER_BIN="./build/pqc_server_threaded"
CLIENT_BIN="./build/pqc_client"
HOST="127.0.0.1"
PORT=4433
NUM_ITERATIONS=1

# RSA certs (signing algo kept constant so we isolate KEM differences)
SIG_DIR="rsa"
CA_CERT="certs/$SIG_DIR/ca_cert.pem"
SERVER_CERT="certs/$SIG_DIR/server_cert.pem"
SERVER_KEY="certs/$SIG_DIR/server_key.pem"
CLIENT_CERT="certs/$SIG_DIR/client_cert.pem"
CLIENT_KEY="certs/$SIG_DIR/client_key.pem"

# KEM algorithms to benchmark
# Format: "Display Name:kem_group_string"
KEM_ALGOS=(
    "X25519:x25519"
    "ML-KEM-512:MLKEM512"
    "ML-KEM-768:MLKEM768"
    "ML-KEM-1024:MLKEM1024"
    "X25519-ML-KEM-768:X25519MLKEM768"
)

# --- Helper: kill any server leftover on our port ---
kill_server() {
    pkill -f "pqc_server_threaded" > /dev/null 2>&1 || true
    # Give the OS a moment to release the port
    sleep 1
}

# --- Network emulation on loopback ---
# netem settings: 5ms base delay, ±2ms jitter, 0.1% packet loss
NETEM_DELAY="5ms"
NETEM_JITTER="2ms"
NETEM_LOSS="0.1%"
NETEM_MTU=1500
ORIG_MTU=""

apply_netem() {
    # Save current MTU
    ORIG_MTU=$(ip link show lo | awk '/mtu/ {for(i=1;i<=NF;i++) if($i=="mtu") print $(i+1); exit}')
    echo "[netem] Saving original lo MTU: ${ORIG_MTU}"

    # Set MTU to 1500
    ip link set lo mtu $NETEM_MTU
    echo "[netem] lo MTU set to $NETEM_MTU"

    # Disable TCP offloads so Wireshark sees real packets split at MTU
    # Without this, the kernel coalesces segments and Wireshark shows
    # giant >1500 byte frames that never hit the wire fragmented.
    ethtool -K lo tso off gso off gro off > /dev/null 2>&1 || true
    echo "[netem] TCP offloads disabled on lo (tso/gso/gro off)"

    # Remove any existing qdisc first (ignore errors if none exists)
    tc qdisc del dev lo root > /dev/null 2>&1 || true

    # Apply netem: delay + jitter + loss
    tc qdisc add dev lo root netem \
        delay $NETEM_DELAY $NETEM_JITTER \
        loss $NETEM_LOSS
    echo "[netem] Applied: delay=${NETEM_DELAY} ±${NETEM_JITTER}, loss=${NETEM_LOSS}"
}

restore_netem() {
    echo ""
    echo "[netem] Restoring lo to original settings..."
    tc qdisc del dev lo root > /dev/null 2>&1 || true
    # Re-enable TCP offloads
    ethtool -K lo tso on gso on gro on > /dev/null 2>&1 || true
    echo "[netem] TCP offloads restored on lo"
    if [[ -n "$ORIG_MTU" ]]; then
        ip link set lo mtu "$ORIG_MTU"
        echo "[netem] lo MTU restored to $ORIG_MTU"
    fi
    echo "[netem] Done."
}

# Always restore netem on script exit (normal or interrupted)
trap 'kill_server; restore_netem; rm -f server.log' EXIT INT TERM

# --- Build ---
echo "Compiling all components..."
./build.sh
echo ""

# --- Apply network emulation to loopback ---
apply_netem
echo ""

echo "=============================================================="
echo "  PQC KEM BENCHMARK  —  Loopback (127.0.0.1), port $PORT"
echo "  Wireshark tip: capture on interface 'lo', filter 'tcp.port == $PORT'"
echo "  Signing: RSA-3072  |  Iterations per KEM: $NUM_ITERATIONS"
echo "  Network: MTU=$NETEM_MTU, delay=${NETEM_DELAY}±${NETEM_JITTER}, loss=${NETEM_LOSS}"
echo "=============================================================="
echo ""

# Storage for results (parallel arrays keyed by index)
declare -a KEM_NAMES
declare -a RES_LATENCY
declare -a RES_CPU
declare -a RES_GROUP

idx=0
for kem in "${KEM_ALGOS[@]}"; do
    IFS=':' read -r kem_name kem_group <<< "$kem"
    KEM_NAMES[$idx]="$kem_name"

    echo "▶  Testing $kem_name ($kem_group)..."

    # Cleanup any previous server
    kill_server

    # Start server on loopback (mTLS: -a verifies client cert)
    echo "   [server] Starting on $HOST:$PORT..."
    $SERVER_BIN \
        -c "$SERVER_CERT" \
        -k "$SERVER_KEY" \
        -a "$CA_CERT" \
        -g "$kem_group" \
        >> server.log 2>&1 &
    SERVER_PID=$!
    sleep 2

    # Verify server is up
    if ! kill -0 $SERVER_PID 2>/dev/null; then
        echo "   [ERROR] Server failed to start. Check server.log."
        RES_LATENCY[$idx]="ERR"
        RES_CPU[$idx]="ERR"
        RES_GROUP[$idx]="ERR"
        idx=$((idx + 1))
        continue
    fi

    total_latency=0
    total_cpu=0
    valid_iters=0
    negotiated_group="unknown"

    # Log header for this KEM in client.log
    echo "=== $kem_name ($kem_group) ===" >> client_benchmark.log

    echo -ne "   [client] Progress: "
    for i in $(seq 1 $NUM_ITERATIONS); do
        output=$(
            $CLIENT_BIN \
                -H "$HOST" \
                -g "$kem_group" \
                -C "$CA_CERT" \
                -c "$CLIENT_CERT" \
                -k "$CLIENT_KEY" \
                2>/dev/null
        )
        # Log raw output for every iteration
        echo "--- iteration $i ---" >> client_benchmark.log
        echo "$output" >> client_benchmark.log

        if [ $? -eq 0 ]; then
            lat=$(echo "$output" | grep "PQC_METRIC_HANDSHAKE_MS" | awk '{print $2}')
            usr=$(echo "$output" | grep "PQC_METRIC_USER_CPU_MS"  | awk '{print $2}')
            sys=$(echo "$output" | grep "PQC_METRIC_SYS_CPU_MS"   | awk '{print $2}')

            # Capture negotiated group from the first successful iteration
            if [[ "$negotiated_group" == "unknown" ]]; then
                neg=$(echo "$output" | grep "Negotiated Group Name" | awk -F': ' '{print $2}' | tr -d '[:space:]')
                [[ -n "$neg" ]] && negotiated_group="$neg"
            fi

            if [[ -n "$lat" ]]; then
                total_latency=$(echo "$total_latency + $lat" | bc)
                total_cpu=$(echo "$total_cpu + ${usr:-0} + ${sys:-0}" | bc)
                valid_iters=$((valid_iters + 1))
            fi
        fi
        echo -ne "█"
    done
    echo "  ($valid_iters/$NUM_ITERATIONS ok)  negotiated: $negotiated_group"

    # Stop server
    kill $SERVER_PID 2>/dev/null || true
    wait $SERVER_PID 2>/dev/null || true

    # Calculate averages
    if [ $valid_iters -gt 0 ]; then
        RES_LATENCY[$idx]=$(echo "scale=3; $total_latency / $valid_iters" | bc)
        RES_CPU[$idx]=$(echo     "scale=3; $total_cpu     / $valid_iters" | bc)
        RES_GROUP[$idx]="$negotiated_group"
    else
        RES_LATENCY[$idx]="N/A"
        RES_CPU[$idx]="N/A"
        RES_GROUP[$idx]="N/A"
    fi

    idx=$((idx + 1))
    sleep 1
done

# --- Final Report ---
echo ""
echo "================================================================"
echo "  RESULTS  —  RSA Signing  |  $NUM_ITERATIONS iteration(s) per KEM"
echo "  Network: MTU=${NETEM_MTU}, delay=${NETEM_DELAY}±${NETEM_JITTER}, loss=${NETEM_LOSS}"
echo "================================================================"
printf "%-22s | %-24s | %-15s | %-12s\n" \
    "KEM Algorithm" "Negotiated Group" "Handshake (ms)" "CPU (ms)"
echo "----------------------------------------------------------------"
for i in "${!KEM_NAMES[@]}"; do
    printf "%-22s | %-24s | %-15s | %-12s\n" \
        "${KEM_NAMES[$i]}" \
        "${RES_GROUP[$i]}" \
        "${RES_LATENCY[$i]}" \
        "${RES_CPU[$i]}"
done
echo "================================================================"
echo ""
# netem + server cleanup handled by EXIT trap
