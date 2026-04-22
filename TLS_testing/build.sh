#!/bin/bash
set -e

# Ensure build directory exists
mkdir -p build

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
OPENSSL_DIR="$SCRIPT_DIR/../openssl-3.5.0"

# Compile Server
gcc -o build/pqc_server pqc_server.c -I${OPENSSL_DIR}/include -L${OPENSSL_DIR} -lssl -lcrypto -Wl,-rpath,${OPENSSL_DIR}

# Compile Threaded Server (for benchmarks)
gcc -o build/pqc_server_threaded pqc_server_threaded.c -I${OPENSSL_DIR}/include -L${OPENSSL_DIR} -lssl -lcrypto -lpthread -Wl,-rpath,${OPENSSL_DIR}

# Compile Client
gcc -o build/pqc_client pqc_client.c -I${OPENSSL_DIR}/include -L${OPENSSL_DIR} -lssl -lcrypto -Wl,-rpath,${OPENSSL_DIR}
gcc -o build/classical_client classical_client.c -I${OPENSSL_DIR}/include -L${OPENSSL_DIR} -lssl -lcrypto -Wl,-rpath,${OPENSSL_DIR}

echo "Build complete. Binaries are in the 'build' directory."
