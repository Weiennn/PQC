#!/bin/bash
set -e

# =============================================================================
# generate_5g_certs.sh — Generate TLS certificates for all Open5GS NFs
#
# Usage:
#   ./generate_5g_certs.sh [ALGORITHM]
#
# ALGORITHM options (case-insensitive):
#   mldsa44    — ML-DSA-44  (NIST PQC, security level 2)
#   mldsa65    — ML-DSA-65  (NIST PQC, security level 3)  [DEFAULT]
#   mldsa87    — ML-DSA-87  (NIST PQC, security level 5)
#   rsa        — RSA 3072
#   rsa4096    — RSA 4096
#   ecdsa      — ECDSA P-384
#   ecdsa256   — ECDSA P-256
#   ed25519    — Ed25519
#
# Output: certs/<algo>/ with per-NF certs + a shared CA
#
# After generation, copy to /etc/open5gs/tls/:
#   sudo cp certs/<algo>/ca_cert.pem   /etc/open5gs/tls/ca.crt
#   sudo cp certs/<algo>/<nf>_cert.pem /etc/open5gs/tls/<nf>.crt
#   sudo cp certs/<algo>/<nf>_key.pem  /etc/open5gs/tls/<nf>.key
# =============================================================================

OPENSSL_DIR="$HOME/Desktop/PQC/openssl-3.5.0"
export LD_LIBRARY_PATH="${OPENSSL_DIR}"
OPENSSL_CMD="${OPENSSL_DIR}/apps/openssl"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CERT_BASE="${SCRIPT_DIR}/certs"

# All Open5GS NFs that need TLS certs (matching /etc/open5gs/tls/ naming)
NF_NAMES=(amf ausf bsf nrf nssf pcf scp sepp1 sepp2 smf udm udr)

# ---------------------------------------------------------------------------
# Parse algorithm argument
# ---------------------------------------------------------------------------
ALGO="${1:-mldsa65}"
ALGO_LOWER="$(echo "$ALGO" | tr '[:upper:]' '[:lower:]')"

case "$ALGO_LOWER" in
    mldsa44)
        NEWKEY_ARG="ML-DSA-44"
        DIR_NAME="mldsa44"
        ;;
    mldsa65)
        NEWKEY_ARG="ML-DSA-65"
        DIR_NAME="mldsa65"
        ;;
    mldsa87)
        NEWKEY_ARG="ML-DSA-87"
        DIR_NAME="mldsa87"
        ;;
    rsa)
        NEWKEY_ARG="rsa:3072"
        DIR_NAME="rsa"
        ;;
    rsa4096)
        NEWKEY_ARG="rsa:4096"
        DIR_NAME="rsa4096"
        ;;
    ecdsa|ecdsa384)
        NEWKEY_ARG="ec"
        PKEYOPT="ec_paramgen_curve:secp384r1"
        DIR_NAME="ecdsa384"
        ;;
    ecdsa256)
        NEWKEY_ARG="ec"
        PKEYOPT="ec_paramgen_curve:prime256v1"
        DIR_NAME="ecdsa256"
        ;;
    ed25519)
        NEWKEY_ARG="ed25519"
        DIR_NAME="ed25519"
        ;;
    *)
        echo "ERROR: Unknown algorithm '${ALGO}'"
        echo "Valid options: mldsa44, mldsa65, mldsa87, rsa, rsa4096, ecdsa, ecdsa256, ed25519"
        exit 1
        ;;
esac

OUT_DIR="${CERT_BASE}/${DIR_NAME}"
mkdir -p "${OUT_DIR}"

echo "============================================="
echo "  Algorithm : ${NEWKEY_ARG} (${DIR_NAME})"
echo "  Output    : ${OUT_DIR}/"
echo "  NFs       : ${NF_NAMES[*]}"
echo "============================================="

# ---------------------------------------------------------------------------
# Helper: build the -newkey / -pkeyopt flags depending on algorithm
# ---------------------------------------------------------------------------
newkey_flags() {
    local flags="-newkey ${NEWKEY_ARG}"
    if [[ -n "${PKEYOPT:-}" ]]; then
        flags="${flags} -pkeyopt ${PKEYOPT}"
    fi
    echo "${flags}"
}

# ---------------------------------------------------------------------------
# 1. Generate CA
# ---------------------------------------------------------------------------
echo ""
echo "[CA] Generating CA certificate..."
# shellcheck disable=SC2046
$OPENSSL_CMD req -x509 $(newkey_flags) \
    -keyout "${OUT_DIR}/ca_key.pem" \
    -out    "${OUT_DIR}/ca_cert.pem" \
    -days 365 -nodes \
    -subj "/CN=open5gs-ca.localdomain"

echo "[CA] Done: ${OUT_DIR}/ca_cert.pem"

# ---------------------------------------------------------------------------
# 2. Generate per-NF cert signed by the CA
# ---------------------------------------------------------------------------
for NF in "${NF_NAMES[@]}"; do
    echo ""
    echo "[${NF}] Generating key + CSR..."
    # shellcheck disable=SC2046
    $OPENSSL_CMD req $(newkey_flags) \
        -keyout "${OUT_DIR}/${NF}_key.pem" \
        -out    "${OUT_DIR}/${NF}.csr" \
        -nodes \
        -subj "/CN=${NF}.localdomain"

    echo "[${NF}] Signing certificate..."
    $OPENSSL_CMD x509 -req \
        -in     "${OUT_DIR}/${NF}.csr" \
        -out    "${OUT_DIR}/${NF}_cert.pem" \
        -CA     "${OUT_DIR}/ca_cert.pem" \
        -CAkey  "${OUT_DIR}/ca_key.pem" \
        -CAcreateserial -days 365

    # Clean up CSR
    rm -f "${OUT_DIR}/${NF}.csr"

    echo "[${NF}] Done: ${OUT_DIR}/${NF}_cert.pem"
done

# Clean up serial file
rm -f "${OUT_DIR}/ca_cert.srl"

echo ""
echo "============================================="
echo "  All certificates generated in: ${OUT_DIR}/"
echo ""
echo "  To install into Open5GS:"
echo "    sudo cp ${OUT_DIR}/ca_cert.pem    /etc/open5gs/tls/ca.crt"
echo "    for nf in ${NF_NAMES[*]}; do"
echo "      sudo cp ${OUT_DIR}/\${nf}_cert.pem /etc/open5gs/tls/\${nf}.crt"
echo "      sudo cp ${OUT_DIR}/\${nf}_key.pem  /etc/open5gs/tls/\${nf}.key"
echo "    done"
echo "============================================="
