#!/bin/bash
# gen_secgw_config.sh — Generates StrongSwan configs for secGW and gNB
#
# The secGW is the responder (listens for IKE from gNB).
# The gNB is the initiator (connects to secGW on 10.0.1.254).
#
# Usage: ./gen_secgw_config.sh [IKE_PROPOSAL]
#   Default IKE_PROPOSAL: aes256-sha384-mlkem768
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PQC_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DATA_DIR="$SCRIPT_DIR/data"
INSTALL_DIR="$PQC_ROOT/ipsec_pqc/_install"

# Configurable IKE proposal (PQC KEM for key exchange)
IKE_PROPOSAL="${1:-aes256-sha384-mlkem768}"
ESP_PROPOSAL="aes256gcm16"

# Network addresses
SECGW_RAN_IP="10.0.1.254"
GNB_IP="10.0.1.1"
CORE_SUBNET="10.0.2.0/24"

echo "=== Generating StrongSwan Configurations ==="
echo "  IKE Proposal: $IKE_PROPOSAL"
echo "  ESP Proposal: $ESP_PROPOSAL"

mkdir -p "$DATA_DIR/secgw" "$DATA_DIR/gnb"

# ============================================================
# secGW swanctl.conf (Responder)
# ============================================================
cat > "$DATA_DIR/secgw/swanctl.conf" <<EOF
connections {
   gnb-tunnel {
      local_addrs = $SECGW_RAN_IP
      proposals = $IKE_PROPOSAL
      local {
         auth = pubkey
         certs = secgwCert.pem
         id = secgw.5glab.local
      }
      remote {
         auth = pubkey
         id = gnb.5glab.local
      }
      children {
         backhaul {
            local_ts = $CORE_SUBNET
            remote_ts = $GNB_IP/32
            esp_proposals = $ESP_PROPOSAL
            mode = tunnel
         }
      }
      version = 2
   }
}
secrets {
   private_secgw {
      file = secgwKey.pem
   }
}
EOF

# ============================================================
# gNB swanctl.conf (Initiator)
# ============================================================
cat > "$DATA_DIR/gnb/swanctl.conf" <<EOF
connections {
   secgw-tunnel {
      remote_addrs = $SECGW_RAN_IP
      proposals = $IKE_PROPOSAL
      local {
         auth = pubkey
         certs = gnbCert.pem
         id = gnb.5glab.local
      }
      remote {
         auth = pubkey
         id = secgw.5glab.local
      }
      children {
         backhaul {
            local_ts = $GNB_IP/32
            remote_ts = $CORE_SUBNET
            esp_proposals = $ESP_PROPOSAL
            mode = tunnel
            start_action = start
         }
      }
      version = 2
   }
}
secrets {
   private_gnb {
      file = gnbKey.pem
   }
}
EOF

# ============================================================
# secGW strongswan.conf (runs inside ns_secgw)
# ============================================================
cat > "$DATA_DIR/secgw/strongswan.conf" <<EOF
charon {
    load_modular = yes
    pid_file = /tmp/charon_secgw.pid
    plugins {
        include $PQC_ROOT/ipsec_pqc/etc/strongswan.d/charon/*.conf
        vici {
            socket = unix:///tmp/charon_secgw.vici
        }
    }
    filelog {
        secgw {
            path = /tmp/charon_secgw.log
            time_format = %b %e %T
            default = 2
            ike = 2
            knl = 2
            net = 2
        }
    }
    piddir = /tmp/secgw
}
swanctl {
    x509 = $DATA_DIR/secgw/x509
    x509ca = $DATA_DIR/secgw/x509ca
    private = $DATA_DIR/secgw/private
}
EOF

# ============================================================
# gNB strongswan.conf (runs on host / gNB namespace)
# ============================================================
cat > "$DATA_DIR/gnb/strongswan.conf" <<EOF
charon {
    load_modular = yes
    pid_file = /tmp/charon_gnb.pid
    plugins {
        include $PQC_ROOT/ipsec_pqc/etc/strongswan.d/charon/*.conf
        vici {
            socket = unix:///tmp/charon_gnb.vici
        }
    }
    filelog {
        gnb {
            path = /tmp/charon_gnb.log
            time_format = %b %e %T
            default = 2
            ike = 2
            knl = 2
            net = 2
        }
    }
    piddir = /tmp/gnb_ipsec
}
swanctl {
    x509 = $DATA_DIR/gnb/x509
    x509ca = $DATA_DIR/gnb/x509ca
    private = $DATA_DIR/gnb/private
}
EOF

echo ""
echo "=== Configurations Generated ==="
echo "  secGW: $DATA_DIR/secgw/swanctl.conf"
echo "  gNB:   $DATA_DIR/gnb/swanctl.conf"
echo "  IKE:   $IKE_PROPOSAL"
