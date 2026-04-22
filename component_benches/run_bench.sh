#!/bin/bash
set -e

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
ROOT_DIR="${SCRIPT_DIR}/.."
RESULTS_DIR="${SCRIPT_DIR}/results"

mkdir -p "${RESULTS_DIR}"

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
# OUTPUT_FILE_OQS="${RESULTS_DIR}/bench_results_oqs_${TIMESTAMP}.json"
OUTPUT_FILE_NATIVE="${RESULTS_DIR}/bench_results_native_${TIMESTAMP}.json"

echo "Running benchmarks..."
# echo "OQS Output will be saved to: ${OUTPUT_FILE_OQS}"
echo "Native Output will be saved to: ${OUTPUT_FILE_NATIVE}"

# "${SCRIPT_DIR}/pqc_bench" > "${OUTPUT_FILE_OQS}"
"${SCRIPT_DIR}/native_pqc_bench" > "${OUTPUT_FILE_NATIVE}"

echo "Done."
# echo "Results (OQS):"
# cat "${OUTPUT_FILE_OQS}"
echo "Results (Native):"
cat "${OUTPUT_FILE_NATIVE}"
