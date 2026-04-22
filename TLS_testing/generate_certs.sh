#!/bin/bash
set -e

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
OPENSSL_DIR="$SCRIPT_DIR/../openssl-3.5.0"

# Define OPENSSL command — use the binary from the OpenSSL 3.5.0 source tree
export LD_LIBRARY_PATH=${OPENSSL_DIR}
OPENSSL_CMD="${OPENSSL_DIR}/apps/openssl"

# Function to generate RSA Chain
generate_rsa() {
    echo "Generating RSA Certificates..."
    mkdir -p certs/rsa
    cd certs/rsa

    # 1. Generate CA
    $OPENSSL_CMD req -x509 -newkey rsa:3072 -keyout ca_key.pem -out ca_cert.pem -days 365 -nodes -subj "/CN=MyRSA_CA"

    # 2. Generate Server Key/CSR
    $OPENSSL_CMD req -newkey rsa:3072 -keyout server_key.pem -out server.csr -nodes -subj "/CN=localhost"

    # 3. Sign Server Cert
    $OPENSSL_CMD x509 -req -in server.csr -out server_cert.pem -CA ca_cert.pem -CAkey ca_key.pem -CAcreateserial -days 365

    # 4. Generate Client Key/CSR
    $OPENSSL_CMD req -newkey rsa:3072 -keyout client_key.pem -out client.csr -nodes -subj "/CN=client"

    # 5. Sign Client Cert
    $OPENSSL_CMD x509 -req -in client.csr -out client_cert.pem -CA ca_cert.pem -CAkey ca_key.pem -CAcreateserial -days 365
    
    cd ../..
}

# Function to generate ML-DSA-44 Chain (native OpenSSL 3.5.0)
generate_mldsa() {
    echo "Generating ML-DSA-44 Certificates..."
    mkdir -p certs/mldsa44
    cd certs/mldsa44

    # 1. Generate CA (Self-signed ML-DSA-44)
    # OpenSSL 3.5.0 supports ML-DSA natively — no provider flags needed
    $OPENSSL_CMD req -x509 -newkey ML-DSA-44 -keyout ca_key.pem -out ca_cert.pem -days 365 -nodes -subj "/CN=MyMLDSA_CA"

    # 2. Generate Server Key/CSR
    $OPENSSL_CMD req -newkey ML-DSA-44 -keyout server_key.pem -out server.csr -nodes -subj "/CN=localhost"

    # 3. Sign Server Cert
    $OPENSSL_CMD x509 -req -in server.csr -out server_cert.pem -CA ca_cert.pem -CAkey ca_key.pem -CAcreateserial -days 365

    # 4. Generate Client Key/CSR
    $OPENSSL_CMD req -newkey ML-DSA-44 -keyout client_key.pem -out client.csr -nodes -subj "/CN=client"

    # 5. Sign Client Cert
    $OPENSSL_CMD x509 -req -in client.csr -out client_cert.pem -CA ca_cert.pem -CAkey ca_key.pem -CAcreateserial -days 365

    cd ../..
}

# Function to generate ECDSA (P-384) Chain
generate_ecdsa() {
    echo "Generating ECDSA (P-384) Certificates..."
    mkdir -p certs/ecdsa
    cd certs/ecdsa
    $OPENSSL_CMD req -x509 -newkey ec -pkeyopt ec_paramgen_curve:secp384r1 -keyout ca_key.pem -out ca_cert.pem -days 365 -nodes -subj "/CN=MyECDSA384_CA"
    $OPENSSL_CMD req -newkey ec -pkeyopt ec_paramgen_curve:secp384r1 -keyout server_key.pem -out server.csr -nodes -subj "/CN=localhost"
    $OPENSSL_CMD x509 -req -in server.csr -out server_cert.pem -CA ca_cert.pem -CAkey ca_key.pem -CAcreateserial -days 365
    $OPENSSL_CMD req -newkey ec -pkeyopt ec_paramgen_curve:secp384r1 -keyout client_key.pem -out client.csr -nodes -subj "/CN=client"
    $OPENSSL_CMD x509 -req -in client.csr -out client_cert.pem -CA ca_cert.pem -CAkey ca_key.pem -CAcreateserial -days 365
    cd ../..
}

# Function to generate ECDSA (P-256) Chain
generate_ecdsa_p256() {
    echo "Generating ECDSA (P-256) Certificates..."
    mkdir -p certs/ecdsa_p256
    cd certs/ecdsa_p256
    $OPENSSL_CMD req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -keyout ca_key.pem -out ca_cert.pem -days 365 -nodes -subj "/CN=MyECDSA256_CA"
    $OPENSSL_CMD req -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -keyout server_key.pem -out server.csr -nodes -subj "/CN=localhost"
    $OPENSSL_CMD x509 -req -in server.csr -out server_cert.pem -CA ca_cert.pem -CAkey ca_key.pem -CAcreateserial -days 365
    $OPENSSL_CMD req -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -keyout client_key.pem -out client.csr -nodes -subj "/CN=client"
    $OPENSSL_CMD x509 -req -in client.csr -out client_cert.pem -CA ca_cert.pem -CAkey ca_key.pem -CAcreateserial -days 365
    cd ../..
}

# Function to generate RSA-4096 Chain
generate_rsa4096() {
    echo "Generating RSA-4096 Certificates..."
    mkdir -p certs/rsa4096
    cd certs/rsa4096
    $OPENSSL_CMD req -x509 -newkey rsa:4096 -keyout ca_key.pem -out ca_cert.pem -days 365 -nodes -subj "/CN=MyRSA4096_CA"
    $OPENSSL_CMD req -newkey rsa:4096 -keyout server_key.pem -out server.csr -nodes -subj "/CN=localhost"
    $OPENSSL_CMD x509 -req -in server.csr -out server_cert.pem -CA ca_cert.pem -CAkey ca_key.pem -CAcreateserial -days 365
    $OPENSSL_CMD req -newkey rsa:4096 -keyout client_key.pem -out client.csr -nodes -subj "/CN=client"
    $OPENSSL_CMD x509 -req -in client.csr -out client_cert.pem -CA ca_cert.pem -CAkey ca_key.pem -CAcreateserial -days 365
    cd ../..
}

# Function to generate Ed25519 Chain
generate_ed25519() {
    echo "Generating Ed25519 Certificates..."
    mkdir -p certs/ed25519
    cd certs/ed25519
    # Ed25519 requires -newkey ed25519 (OpenSSL 3.0+)
    $OPENSSL_CMD req -x509 -newkey ed25519 -keyout ca_key.pem -out ca_cert.pem -days 365 -nodes -subj "/CN=MyEd25519_CA"
    $OPENSSL_CMD req -newkey ed25519 -keyout server_key.pem -out server.csr -nodes -subj "/CN=localhost"
    $OPENSSL_CMD x509 -req -in server.csr -out server_cert.pem -CA ca_cert.pem -CAkey ca_key.pem -CAcreateserial -days 365
    $OPENSSL_CMD req -newkey ed25519 -keyout client_key.pem -out client.csr -nodes -subj "/CN=client"
    $OPENSSL_CMD x509 -req -in client.csr -out client_cert.pem -CA ca_cert.pem -CAkey ca_key.pem -CAcreateserial -days 365
    cd ../..
}

# Function to generate ML-DSA-65 Chain (native OpenSSL 3.5.0)
generate_mldsa65() {
    echo "Generating ML-DSA-65 Certificates..."
    mkdir -p certs/mldsa65
    cd certs/mldsa65
    $OPENSSL_CMD req -x509 -newkey ML-DSA-65 -keyout ca_key.pem -out ca_cert.pem -days 365 -nodes -subj "/CN=MyMLDSA65_CA"
    $OPENSSL_CMD req -newkey ML-DSA-65 -keyout server_key.pem -out server.csr -nodes -subj "/CN=localhost"
    $OPENSSL_CMD x509 -req -in server.csr -out server_cert.pem -CA ca_cert.pem -CAkey ca_key.pem -CAcreateserial -days 365
    $OPENSSL_CMD req -newkey ML-DSA-65 -keyout client_key.pem -out client.csr -nodes -subj "/CN=client"
    $OPENSSL_CMD x509 -req -in client.csr -out client_cert.pem -CA ca_cert.pem -CAkey ca_key.pem -CAcreateserial -days 365
    cd ../..
}

# Function to generate ML-DSA-87 Chain (native OpenSSL 3.5.0)
generate_mldsa87() {
    echo "Generating ML-DSA-87 Certificates..."
    mkdir -p certs/mldsa87
    cd certs/mldsa87
    $OPENSSL_CMD req -x509 -newkey ML-DSA-87 -keyout ca_key.pem -out ca_cert.pem -days 365 -nodes -subj "/CN=MyMLDSA87_CA"
    $OPENSSL_CMD req -newkey ML-DSA-87 -keyout server_key.pem -out server.csr -nodes -subj "/CN=localhost"
    $OPENSSL_CMD x509 -req -in server.csr -out server_cert.pem -CA ca_cert.pem -CAkey ca_key.pem -CAcreateserial -days 365
    $OPENSSL_CMD req -newkey ML-DSA-87 -keyout client_key.pem -out client.csr -nodes -subj "/CN=client"
    $OPENSSL_CMD x509 -req -in client.csr -out client_cert.pem -CA ca_cert.pem -CAkey ca_key.pem -CAcreateserial -days 365
    cd ../..
}

mkdir -p certs
generate_rsa
generate_mldsa
generate_ecdsa
# generate_dilithium3
generate_rsa4096
generate_ecdsa_p256
generate_ed25519
generate_mldsa65
generate_mldsa87

echo "All certificates generated in certs/"
