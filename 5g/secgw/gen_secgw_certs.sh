#!/bin/bash
# gen_secgw_certs.sh — Generates CA + endpoint certs for secGW and gNB
#
# Uses the StrongSwan pki tool from the existing ipsec_pqc build.
# Certificates use RSA for compatibility with StrongSwan's IKEv2 auth.
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PQC_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
INSTALL_DIR="$PQC_ROOT/ipsec_pqc/_install"
PKI="$INSTALL_DIR/bin/pki"
DATA_DIR="$SCRIPT_DIR/data"

# Check dependencies
if [ ! -f "$PKI" ]; then
    echo "Error: pki tool not found at $PKI"
    echo "Build StrongSwan first: cd $PQC_ROOT && ./ipsec_pqc/build_deps.sh"
    exit 1
fi

echo "=== Generating secGW Certificates ==="

# --- Create directory structure ---
mkdir -p "$DATA_DIR/ca/x509ca"
mkdir -p "$DATA_DIR/secgw/x509"
mkdir -p "$DATA_DIR/secgw/private"
mkdir -p "$DATA_DIR/secgw/x509ca"
mkdir -p "$DATA_DIR/gnb/x509"
mkdir -p "$DATA_DIR/gnb/private"
mkdir -p "$DATA_DIR/gnb/x509ca"

# --- 1. Generate CA ---
echo "[1/3] Generating CA keypair..."
cd "$DATA_DIR/ca/x509ca"
"$PKI" --gen --type rsa --size 4096 --outform pem > caKey.pem
"$PKI" --self --ca --lifetime 3650 --in caKey.pem \
      --dn "C=AU, O=PQC-5G-Lab, CN=secGW Root CA" --outform pem > caCert.pem

# Distribute CA cert to both endpoints
cp caCert.pem "$DATA_DIR/secgw/x509ca/"
cp caCert.pem "$DATA_DIR/gnb/x509ca/"

# --- 2. Generate secGW Certificate ---
echo "[2/3] Generating secGW certificate..."
cd "$DATA_DIR/secgw/x509"
"$PKI" --gen --type rsa --size 3072 --outform pem > ../private/secgwKey.pem
"$PKI" --pub --in ../private/secgwKey.pem | "$PKI" --issue --lifetime 730 \
      --cacert "$DATA_DIR/ca/x509ca/caCert.pem" \
      --cakey "$DATA_DIR/ca/x509ca/caKey.pem" \
      --dn "C=AU, O=PQC-5G-Lab, CN=secgw.5glab.local" \
      --san "secgw.5glab.local" --san "10.0.1.254" \
      --outform pem > secgwCert.pem

# --- 3. Generate gNB Certificate ---
echo "[3/3] Generating gNB certificate..."
cd "$DATA_DIR/gnb/x509"
"$PKI" --gen --type rsa --size 3072 --outform pem > ../private/gnbKey.pem
"$PKI" --pub --in ../private/gnbKey.pem | "$PKI" --issue --lifetime 730 \
      --cacert "$DATA_DIR/ca/x509ca/caCert.pem" \
      --cakey "$DATA_DIR/ca/x509ca/caKey.pem" \
      --dn "C=AU, O=PQC-5G-Lab, CN=gnb.5glab.local" \
      --san "gnb.5glab.local" --san "10.0.1.1" \
      --outform pem > gnbCert.pem

echo ""
echo "=== Certificates Generated ==="
echo "  CA:    $DATA_DIR/ca/x509ca/caCert.pem"
echo "  secGW: $DATA_DIR/secgw/x509/secgwCert.pem"
echo "  gNB:   $DATA_DIR/gnb/x509/gnbCert.pem"
