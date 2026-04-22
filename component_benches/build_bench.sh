#!/bin/bash
set -e

# Define paths relative to this script
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
ROOT_DIR="${SCRIPT_DIR}/.."
INCLUDE_DIR="${ROOT_DIR}/local/include"
LIB_DIR="${ROOT_DIR}/local/lib"

echo "Compiling pqc_bench..."
gcc -o "${SCRIPT_DIR}/pqc_bench" "${SCRIPT_DIR}/pqc_bench.c" \
    -I"${INCLUDE_DIR}" \
    -L"${LIB_DIR}" \
    -L"${ROOT_DIR}/local/lib64" \
    -loqs -lcrypto \
    -Wl,-rpath,"${LIB_DIR}":"${ROOT_DIR}/local/lib64"

echo "Compiling native_pqc_bench..."
gcc -o "${SCRIPT_DIR}/native_pqc_bench" "${SCRIPT_DIR}/native_pqc_bench.c" \
    -I"${INCLUDE_DIR}" \
    -L"${LIB_DIR}" \
    -L"${ROOT_DIR}/local/lib64" \
    -lcrypto \
    -Wl,-rpath,"${LIB_DIR}":"${ROOT_DIR}/local/lib64"

if [ $? -eq 0 ]; then
    echo "Build successful: ${SCRIPT_DIR}/pqc_bench and ${SCRIPT_DIR}/native_pqc_bench"
else
    echo "Build failed!"
    exit 1
fi
