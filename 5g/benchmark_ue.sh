#!/bin/bash

# Ensure script is run as root
if [ "$EUID" -ne 0 ]; then
  echo "Please run as root (use sudo ./benchmark_ue.sh)"
  exit 1
fi

NUM_RUNS=${NUM_RUNS:-5}
UE_CONFIG="./UERANSIM/config/open5gs-ue0.yaml"
GNB_CONFIG="./UERANSIM/config/open5gs-gnb.yaml"
UE_EXEC="./UERANSIM/build/nr-ue"
GNB_EXEC="./UERANSIM/build/nr-gnb"
LOG_FILE="./UERANSIM/logs/benchmark_ue_hybrid.log"
GNB_LOG_FILE="./UERANSIM/logs/benchmark_gnb_hybrid.log"

TOTAL_TIME=0
SUCCESS_COUNT=0

# Ensure gNB is not already running to avoid conflicts
killall nr-gnb 2>/dev/null
killall nr-ue 2>/dev/null
sleep 1

# Network config
sudo ip link set dev ran0 mtu 1500
sudo ethtool -K ran0 gro off lro off tso off 2>/dev/null || true

# Apply netem on loopback (lo) because dummy interfaces use local routing
# and packets never traverse ran0's egress queue
echo "Setting up network emulation (tc netem) on lo..."
sudo tc qdisc del dev lo root 2>/dev/null || true
sudo tc qdisc add dev lo root netem delay 5ms 1ms distribution normal loss 0.1%

echo "Starting gNB..."
$GNB_EXEC -c "$GNB_CONFIG" > "$GNB_LOG_FILE" 2>&1 &
GNB_PID=$!

# Wait for gNB to initialize
sleep 3

echo "Starting UE Connection Benchmark ($NUM_RUNS runs)"
echo "------------------------------------------------"

for i in $(seq 1 $NUM_RUNS); do
    echo -n "Run $i/$NUM_RUNS: "
    
    # Touch log file and ensure it's empty
    > "$LOG_FILE"
    
    # Run UE in background, save logs
    $UE_EXEC -c "$UE_CONFIG" > "$LOG_FILE" 2>&1 &
    UE_PID=$!
    
    # Wait for success message or 15s timeout
    TIMEOUT=300 # 75 * 0.2s = 15s
    WAIT_COUNT=0
    SUCCESS=0
    
    while [ $WAIT_COUNT -lt $TIMEOUT ]; do
        if grep -q "Initial Registration is successful" "$LOG_FILE"; then
            SUCCESS=1
            break
        fi
        sleep 0.2
        WAIT_COUNT=$((WAIT_COUNT + 1))
    done
    
    if [ $SUCCESS -eq 1 ]; then
        # Registration successful, extract timestamps
        START_STR=$(grep "Sending Initial Registration" "$LOG_FILE" | head -1 | awk -F'[][]' '{print $2}')
        END_STR=$(grep "Initial Registration is successful" "$LOG_FILE" | head -1 | awk -F'[][]' '{print $2}')
        
        # Calculate diff in ms
        DURATION_MS=$(python3 -c "
from datetime import datetime
try:
    t1 = datetime.strptime('$START_STR', '%Y-%m-%d %H:%M:%S.%f')
    t2 = datetime.strptime('$END_STR', '%Y-%m-%d %H:%M:%S.%f')
    print(f'{(t2 - t1).total_seconds() * 1000:.2f}')
except Exception as e:
    print('-1')
")
        
        if [ "$DURATION_MS" != "-1" ]; then
            echo "Success (${DURATION_MS} ms)"
            TOTAL_TIME=$(echo "$TOTAL_TIME + $DURATION_MS" | bc)
            SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
        else
            echo "Failed to parse time"
        fi
    else
        echo "Timeout or Failed"
    fi
    
    # Kill the UE process
    kill $UE_PID 2>/dev/null
    wait $UE_PID 2>/dev/null
    
    # Give the network a little time to clear before next run
    sleep 4
done

# Kill gNB
kill $GNB_PID 2>/dev/null
wait $GNB_PID 2>/dev/null

# Clean up network emulation
echo "Cleaning up network emulation on lo..."
sudo tc qdisc del dev lo root 2>/dev/null || true

echo "------------------------------------------------"
if [ $SUCCESS_COUNT -gt 0 ]; then
    AVG_TIME=$(echo "scale=2; $TOTAL_TIME / $SUCCESS_COUNT" | bc)
    echo "Successful runs: $SUCCESS_COUNT out of $NUM_RUNS"
    echo "Average connection time: ${AVG_TIME} ms"
else
    echo "No successful runs to calculate average."
fi
