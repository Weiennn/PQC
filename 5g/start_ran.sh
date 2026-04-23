#!/bin/bash

# Ensure we have a logs directory
mkdir -p ./UERANSIM/logs

echo "Starting nr-gnb in the background..."
# Run gnb in background and redirect all output to gnb.log
./UERANSIM/build/nr-gnb -c ./UERANSIM/config/open5gs-gnb.yaml > ./UERANSIM/logs/gnb.log 2>&1 &
GNB_PID=$!

# Give the gNB a couple of seconds to initialize before starting the UE
sleep 2

echo "Starting nr-ue in the background..."
# Run ue in background and redirect all output to ue.log
sudo ./UERANSIM/build/nr-ue -c ./UERANSIM/config/open5gs-ue.yaml > ./UERANSIM/logs/ue.log 2>&1 &
UE_PID=$!

echo "====================================================="
echo "RAN processes started successfully in the background!"
echo "gNB PID: $GNB_PID -> Logging to ./UERANSIM/logs/gnb.log"
echo "UE PID:  $UE_PID -> Logging to ./UERANSIM/logs/ue.log"
echo "====================================================="
echo "Note: You do not need to run these in separate terminals."
echo "They are running in the background. To view live logs, run:"
echo "  tail -f ./UERANSIM/logs/gnb.log"
echo "  tail -f ./UERANSIM/logs/ue.log"
echo ""
echo "To stop the processes, use:"
echo "  kill $GNB_PID $UE_PID"