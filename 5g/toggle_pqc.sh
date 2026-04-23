#!/bin/bash
set -e

# =============================================================================
# toggle_pqc.sh — Switch Open5GS between TLS 1.2 (classical) and TLS 1.3 (PQC)
#
# Usage:
#   sudo ./toggle_pqc.sh pqc    [ALGO]    Switch to PQC mode  (default algo: mldsa65)
#   sudo ./toggle_pqc.sh classical [ALGO] Switch to classical  (default algo: rsa)
#   sudo ./toggle_pqc.sh status           Show current mode
#
# This script:
#   1. Copies the correct certs into /etc/open5gs/tls/
#   2. Adds/removes OPENSSL_CONF and LD_LIBRARY_PATH from systemd services
#   3. Reloads the systemd daemon
#
# IMPORTANT: Run this BEFORE starting the NFs (./start.sh)
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CERT_BASE="${SCRIPT_DIR}/certs"
TLS_DIR="/etc/open5gs/tls"
BACKUP_DIR="/etc/open5gs/tls/backup"

OPENSSL_DIR="/home/vboxuser/Desktop/PQC/openssl-3.5.0"
CURL_INSTALL_DIR="/home/vboxuser/Desktop/PQC/5g/curl-install"
OPENSSL_PQC_CNF="${SCRIPT_DIR}/openssl_pqc.cnf"
OPENSSL_CLASSICAL_CNF="${SCRIPT_DIR}/openssl_classical.cnf"

# NFs with TLS certs
NF_NAMES=(amf ausf bsf nrf nssf pcf scp sepp1 sepp2 smf udm udr)

# Systemd service names (one per NF that uses SBI)
SERVICE_NAMES=(
    open5gs-amfd open5gs-ausfd open5gs-bsfd open5gs-nrfd
    open5gs-nssfd open5gs-pcfd open5gs-scpd
    open5gs-smfd open5gs-udmd open5gs-udrd open5gs-upfd
)

# LD_LIBRARY_PATH is ALWAYS set (both modes use OpenSSL 3.5.0 + custom libcurl)
ENV_LD="Environment=\"LD_LIBRARY_PATH=${OPENSSL_DIR}:${CURL_INSTALL_DIR}/lib\""

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
usage() {
    echo "Usage: sudo $0 {pqc|classical|status} [ALGO]"
    echo ""
    echo "Modes:"
    echo "  pqc [ALGO]       — Install PQC certs and enable TLS 1.3 config"
    echo "                     ALGO: mldsa44, mldsa65 (default), mldsa87"
    echo "  classical [ALGO] — Install classical certs and disable PQC config"
    echo "                     ALGO: rsa (default), rsa4096, ecdsa384, ecdsa256, ed25519"
    echo "  status           — Show current cert type in /etc/open5gs/tls/"
    exit 1
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo "ERROR: This script must be run as root (sudo)."
        exit 1
    fi
}

backup_current_certs() {
    mkdir -p "${BACKUP_DIR}"
    echo "[backup] Saving current certs to ${BACKUP_DIR}/"
    cp -a "${TLS_DIR}"/*.crt "${TLS_DIR}"/*.key "${BACKUP_DIR}/" 2>/dev/null || true
}

install_certs() {
    local algo_dir="$1"
    local src="${CERT_BASE}/${algo_dir}"

    if [[ ! -d "${src}" ]]; then
        echo "ERROR: Certificate directory not found: ${src}"
        echo "Run ./generate_5g_certs.sh ${algo_dir} first."
        exit 1
    fi

    echo "[certs] Installing ${algo_dir} certs into ${TLS_DIR}/"
    cp "${src}/ca_cert.pem" "${TLS_DIR}/ca.crt"
    for nf in "${NF_NAMES[@]}"; do
        if [[ -f "${src}/${nf}_cert.pem" ]]; then
            cp "${src}/${nf}_cert.pem" "${TLS_DIR}/${nf}.crt"
            cp "${src}/${nf}_key.pem"  "${TLS_DIR}/${nf}.key"
        fi
    done
    # Fix permissions so open5gs user can read them
    chmod 644 "${TLS_DIR}"/*.crt
    chmod 640 "${TLS_DIR}"/*.key
    chown root:open5gs "${TLS_DIR}"/*.key 2>/dev/null || true
}

set_env_in_services() {
    local conf_file="$1"
    local tls_groups="$2"
    local env_conf="Environment=\"OPENSSL_CONF=${conf_file}\""
    local env_groups="Environment=\"OPEN5GS_TLS_GROUPS=${tls_groups}\""
    echo "[systemd] Setting env in service files..."
    echo "  OPENSSL_CONF=${conf_file}"
    echo "  OPEN5GS_TLS_GROUPS=${tls_groups}"
    echo "  LD_LIBRARY_PATH=${OPENSSL_DIR}:${CURL_INSTALL_DIR}/lib"
    for svc in "${SERVICE_NAMES[@]}"; do
        local svc_file="/lib/systemd/system/${svc}.service"
        [[ -f "${svc_file}" ]] || continue

        # Remove old entries first (idempotent)
        sed -i '/^Environment="OPENSSL_CONF=/d' "${svc_file}"
        sed -i '/^Environment="LD_LIBRARY_PATH=/d' "${svc_file}"
        sed -i '/^Environment="OPEN5GS_TLS_GROUPS=/d' "${svc_file}"

        # Add after [Service]
        sed -i "/^\[Service\]/a ${ENV_LD}" "${svc_file}"
        sed -i "/^\[Service\]/a ${env_groups}" "${svc_file}"
        sed -i "/^\[Service\]/a ${env_conf}" "${svc_file}"
    done
}

show_status() {
    echo "=== Current TLS Configuration ==="
    if [[ -f "${TLS_DIR}/ca.crt" ]]; then
        echo ""
        echo "CA cert info:"
        LD_LIBRARY_PATH="${OPENSSL_DIR}" "${OPENSSL_DIR}/apps/openssl" x509 \
            -in "${TLS_DIR}/ca.crt" -noout -subject -issuer -text 2>/dev/null \
            | grep -E "Signature Algorithm|Subject:|Public Key Algorithm" | head -5
    fi
    echo ""
    echo "Systemd env status:"
    local svc_file="/lib/systemd/system/open5gs-amfd.service"
    if grep -q "OPENSSL_CONF=.*pqc" "${svc_file}" 2>/dev/null; then
        echo "  Mode: PQC (X25519MLKEM768)"
    elif grep -q "OPENSSL_CONF=.*classical" "${svc_file}" 2>/dev/null; then
        echo "  Mode: Classical (X25519)"
    else
        echo "  Mode: Unknown (no OPENSSL_CONF set)"
    fi
    grep "Environment=" "${svc_file}" 2>/dev/null | head -3
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
MODE="${1:-}"
ALGO="${2:-}"

case "${MODE}" in
    pqc)
        check_root
        ALGO="${ALGO:-rsa}"
        echo "============================================="
        echo "  PQC mode: X25519MLKEM768 (certs: ${ALGO})"
        echo "============================================="
        backup_current_certs
        install_certs "${ALGO}"
        set_env_in_services "${OPENSSL_PQC_CNF}" "X25519MLKEM768:X25519"
        systemctl daemon-reload
        echo ""
        echo "[done] PQC mode active (KEM: X25519MLKEM768)."
        echo "       Restart NFs: ./off.sh && ./start.sh"
        ;;
    classical)
        check_root
        ALGO="${ALGO:-rsa}"
        echo "============================================="
        echo "  Classical mode: X25519 (certs: ${ALGO})"
        echo "============================================="
        backup_current_certs
        install_certs "${ALGO}"
        set_env_in_services "${OPENSSL_CLASSICAL_CNF}" "X25519:P-256"
        systemctl daemon-reload
        echo ""
        echo "[done] Classical mode active (KEM: X25519)."
        echo "       Restart NFs: ./off.sh && ./start.sh"
        ;;
    status)
        show_status
        ;;
    *)
        usage
        ;;
esac
