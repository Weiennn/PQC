#!/bin/bash
# benchmark_consolidated.sh
# Comprehensive benchmark for Latency, CPU, and HPS across various KEM and Signing combinations.
# Uses Network Namespaces to simulate realistic network conditions (MTU 1500).

# Clean environment
# sudo pkill -9 -f pqc_server
# sudo ip netns del pqc_server_ns pqc_client_ns 2>/dev/null

# # Run benchmark  
# sudo ./benchmark_consolidated.sh

# Configuration
ITERATIONS=100        # Reduced for testing
DURATION=5        # Seconds for HPS test
CONCURRENCY=2
PROJECT_ROOT="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
SERVER_BIN="./build/pqc_server_threaded"
CLIENT_BIN="./build/pqc_client"
CERT_DIR="certs"
OPENSSL_BIN="./../local/bin/openssl"

# Source Network Namespace Utilities
if [ -f "$PROJECT_ROOT/netns_utils.sh" ]; then
    source "$PROJECT_ROOT/netns_utils.sh"
else
    echo "[ERROR] netns_utils.sh not found!"
    exit 1
fi

# Export Environment for Host
export LD_LIBRARY_PATH="$PROJECT_ROOT/../local/lib64:$PROJECT_ROOT/../local/lib:$LD_LIBRARY_PATH"
export OPENSSL_MODULES="$PROJECT_ROOT/../local/lib64/ossl-modules"
export OPENSSL_CONF="$PROJECT_ROOT/openssl_oqs.cnf"

# Environment string for sudo/netns execution (ensures OQS provider is loaded inside namespace)
ENV_VARS="LD_LIBRARY_PATH=$LD_LIBRARY_PATH OPENSSL_MODULES=$OPENSSL_MODULES OPENSSL_CONF=$OPENSSL_CONF"

# Ensure providers are available
if [ ! -f "$OPENSSL_MODULES/oqsprovider.so" ]; then
    export OPENSSL_MODULES="$PROJECT_ROOT/../local/lib/ossl-modules"
    ENV_VARS="LD_LIBRARY_PATH=$LD_LIBRARY_PATH OPENSSL_MODULES=$OPENSSL_MODULES OPENSSL_CONF=$OPENSSL_CONF"
fi

# Initialize Output File
OUTPUT_FILE="benchmark_summary_$(date +%Y%m%d_%H%M%S).csv"
DETAILED_LATENCY_FILE="latency_finegrained_$(date +%Y%m%d_%H%M%S).csv"
echo "SigAlg,KEM,NegotiatedGroup,Latency_ms,CPU_ms,HPS" > "$OUTPUT_FILE"
echo "SigAlg,KEM,NegotiatedGroup,Iteration,Latency_ms,UserCPU_ms,SysCPU_ms" > "$DETAILED_LATENCY_FILE"

echo "Starting Consolidated Benchmark with Network Namespaces (MTU $MTU)..."
echo "Results will be saved to $OUTPUT_FILE"
echo "Detailed latency will be saved to $DETAILED_LATENCY_FILE"
echo "======================================================================================================="
printf "%-15s | %-15s | %-20s | %-10s | %-10s | %-10s\n" "Signing" "KEM" "NegotiatedGroup" "Latency" "CPU" "HPS"
echo "-------------------------------------------------------------------------------------------------------"

cleanup_all() {
    # Surgical cleanup inside namespaces (quietly)
    pkill_in_ns "$SERVER_NS" pqc_server_threaded
    pkill_in_ns "$CLIENT_NS" pqc_client
    pkill_in_ns "$CLIENT_NS" s_time
    
    # Generic host cleanup
    pkill -9 -f pqc_server_threaded >/dev/null 2>&1 || true
    
    # Port cleanup (host and namespaces)
    fuser_kill_in_ns "$SERVER_NS" 4433
    fuser -k 4433/tcp > /dev/null 2>&1 || true
    
    sleep 1
}

# Initial namespace setup
setup_ns 

# Ensure cleanup on script exit
trap "cleanup_all; teardown_ns" EXIT INT TERM

# sudo ./5g/setup_backhaul.sh

# Algorithms
SIG_ALGOS=(
    "RSA-3072:rsa"
    "Ed25519:ed25519"
    "ML-DSA-44:mldsa44"
    "ML-DSA-65:mldsa65"
    "ML-DSA-87:mldsa87"
)

KEM_ALGOS=(
    "X25519:x25519"
    "ML-KEM-512:MLKEM512"
    "ML-KEM-768:MLKEM768"
    "ML-KEM-1024:MLKEM1024"
    "X25519-ML-KEM-768:X25519MLKEM768"
)

# Loop through combinations
for sig in "${SIG_ALGOS[@]}"; do
    IFS=':' read -r sig_name sig_dir <<< "$sig"
    echo "[PROGRESS] Starting signature algorithm: $sig_name"
    
    for kem in "${KEM_ALGOS[@]}"; do
        IFS=':' read -r kem_name kem_group <<< "$kem"
        
        # Paths
        server_cert="$CERT_DIR/$sig_dir/server_cert.pem"
        server_key="$CERT_DIR/$sig_dir/server_key.pem"
        ca_cert="$CERT_DIR/$sig_dir/ca_cert.pem"
        client_cert="$CERT_DIR/$sig_dir/client_cert.pem"
        client_key="$CERT_DIR/$sig_dir/client_key.pem"

        # ---------------------------------------------------------
        # 1. Measure Latency & CPU (pqc_client)
        # ---------------------------------------------------------
        echo "[PROGRESS] Testing $sig_name / $kem_name - Latency"
        cleanup_all
        
        echo "[PROGRESS] Starting server..."
        # Verify namespace exists (no sudo needed, script runs as root)
        if ! ip netns list | grep -q "$SERVER_NS"; then
            echo "[ERROR] Server namespace doesn't exist! Re-creating..."
            teardown_ns 2>/dev/null || true
            setup_ns 
        fi
        
        # Start Server in Server Namespace with explicit environment
        # -a: CA cert used to verify the client certificate (mTLS)
        echo "=== Latency: $sig_name / $kem_name ===" >> server.log
        run_in_server_ns_env $SERVER_BIN -c "$server_cert" -k "$server_key" -a "$ca_cert" -g "$kem_group" >> server.log 2>&1 &
        sleep 2
        
        if ! pgrep_in_ns "$SERVER_NS" pqc_server_threaded; then
             echo "[ERROR] Server failed to start for $sig_name / $kem_name"
             echo "[ERROR] Server log:"
             cat server.log 2>/dev/null | head -5
             continue
        fi

        total_latency=0
        total_cpu=0
        valid_iters=0
        
        echo "[PROGRESS] Running $ITERATIONS client iterations..."
        
        # Change to project directory for relative paths
        cd "$PROJECT_ROOT"
        
        negotiated_group="unknown"
        echo "=== Latency: $sig_name / $kem_name ===" >> client.log
        for ((i=1; i<=ITERATIONS; i++)); do
            # Run Client in Client Namespace, connecting to Server IP
            # -C: CA cert to verify server  -c/-k: client cert/key for mTLS
            output=$(run_in_client_ns_env "$CLIENT_BIN" -H "$SERVER_IP" -g "$kem_group" -C "$ca_cert" -c "$client_cert" -k "$client_key" 2>&1)
            echo "--- Iteration $i ---" >> client.log
            echo "$output" >> client.log
            exit_code=$?
            if [ $exit_code -eq 0 ]; then
                lat=$(echo "$output" | grep "PQC_METRIC_HANDSHAKE_MS" | awk '{print $2}')
                usr=$(echo "$output" | grep "PQC_METRIC_USER_CPU_MS" | awk '{print $2}')
                sys=$(echo "$output" | grep "PQC_METRIC_SYS_CPU_MS" | awk '{print $2}')
                # Capture which group was actually negotiated (first success only)
                if [[ "$negotiated_group" == "unknown" ]]; then
                    neg=$(echo "$output" | grep "Negotiated Group Name" | awk -F': ' '{print $2}' | tr -d '[:space:]')
                    [[ -n "$neg" ]] && negotiated_group="$neg"
                fi
                if [[ ! -z "$lat" ]]; then
                    total_latency=$(echo "$total_latency + $lat" | bc)
                    cpu_sum=$(echo "$usr + $sys" | bc)
                    total_cpu=$(echo "$total_cpu + $cpu_sum" | bc)
                    valid_iters=$((valid_iters + 1))
                    echo "$sig_name,$kem_name,$negotiated_group,$i,$lat,$usr,$sys" >> "$DETAILED_LATENCY_FILE"
                fi
            fi
        done
        
        avg_latency="N/A"
        avg_cpu="N/A"
        if [ $valid_iters -gt 0 ]; then
            avg_latency=$(echo "scale=2; $total_latency / $valid_iters" | bc)
            avg_cpu=$(echo "scale=2; $total_cpu / $valid_iters" | bc)
        fi

        
        echo "[PROGRESS] Latency complete. Results: $valid_iters/$ITERATIONS successful"
        
        # ---------------------------------------------------------
        # 2. Measure HPS (openssl s_time)
        # ---------------------------------------------------------
        echo "[PROGRESS] Testing $sig_name / $kem_name - HPS"
        cleanup_all
        
        # Create temp OpenSSL config to set Groups
        TEMP_CONF="temp_openssl_${kem_group}.cnf"
        sed "s/^Groups = .*/Groups = ${kem_group}/" "$PROJECT_ROOT/openssl_oqs.cnf" > "$TEMP_CONF"
        
        # Verify namespace still exists (no sudo needed, script runs as root)
        if ! ip netns list | grep -q "$SERVER_NS"; then
            echo "[ERROR] Server namespace doesn't exist! Re-creating..."
            teardown_ns 2>/dev/null || true
            setup_ns 
        fi
        
        # Restart Server for HPS test (mTLS: -a enables client cert verification)
        echo "=== HPS: $sig_name / $kem_name ===" >> server_hps.log
        run_in_server_ns_env $SERVER_BIN -c "$server_cert" -k "$server_key" -a "$ca_cert" -g "$kem_group" >> server_hps.log 2>&1 &
        sleep 2
        
        if ! pgrep_in_ns "$SERVER_NS" pqc_server_threaded; then
             echo "[ERROR] Server (HPS) failed to start for $sig_name / $kem_name"
             rm -f "$TEMP_CONF"
             continue
        fi

        # Run s_time concurrently from Client Namespace
        rm -f hps_output.*
        cd "$PROJECT_ROOT"
        pids=""
        for i in $(seq 1 $CONCURRENCY); do
            # Set the temporary config and run s_time with mTLS client cert/key
            run_in_client_ns_custom_env "OPENSSL_CONF=$PROJECT_ROOT/$TEMP_CONF" "$OPENSSL_BIN" s_time \
                -connect "${SERVER_IP}:4433" \
                -new \
                -www / \
                -CAfile "$ca_cert" \
                -cert "$client_cert" \
                -key "$client_key" \
                -time $DURATION \
                -provider oqsprovider \
                -provider default \
                > "hps_output.${i}" 2>&1 &
            pids="$pids $!"
        done
        
        # Wait for all background s_time processes to finish
        for pid in $pids; do
            wait $pid 2>/dev/null || true
        done
        
        # Process results
        total_conns=0
        for i in $(seq 1 $CONCURRENCY); do
             if [ -f "hps_output.${i}" ]; then
                 cnt=$(grep "connections in" "hps_output.${i}" | head -n 1 | awk '{print $1}')
                 if [[ "$cnt" =~ ^[0-9]+$ ]]; then
                     total_conns=$((total_conns + cnt))
                 fi
                 echo "=== HPS ($i): $sig_name / $kem_name ===" >> client_hps.log
                 cat "hps_output.${i}" >> client_hps.log
                 rm "hps_output.${i}"
             fi
        done
        
        hps=$(echo "scale=2; $total_conns / $DURATION" | bc)
        rm -f "$TEMP_CONF"
        
        # Output Results
        printf "%-15s | %-15s | %-20s | %-10s | %-10s | %-10s\n" "$sig_name" "$kem_name" "$negotiated_group" "$avg_latency" "$avg_cpu" "$hps"
        echo "$sig_name,$kem_name,$negotiated_group,$avg_latency,$avg_cpu,$hps" >> "$OUTPUT_FILE"
        
        sleep 1
    done
done

echo "=========================================================================================="
echo "Benchmark Complete."
