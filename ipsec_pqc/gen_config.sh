#!/bin/bash
set -e

BASE_DIR="$(pwd)/ipsec_pqc"
INSTALL_DIR="$BASE_DIR/_install"
DATA_DIR="$BASE_DIR/data"
PKI="$INSTALL_DIR/bin/pki"

# Ensure we have the binaries
if [ ! -f "$PKI" ]; then
    echo "Error: pki tool not found at $PKI. Did the build finish?"
    exit 1
fi

mkdir -p "$DATA_DIR/ca/x509ca"
mkdir -p "$DATA_DIR/moon/x509"
mkdir -p "$DATA_DIR/moon/private"
mkdir -p "$DATA_DIR/moon/x509ca"
mkdir -p "$DATA_DIR/sun/x509"
mkdir -p "$DATA_DIR/sun/private"
mkdir -p "$DATA_DIR/sun/x509ca"

# 1. Generate CA
echo "Generating CA..."
cd "$DATA_DIR/ca/x509ca"
"$PKI" --gen --type rsa --size 4096 --outform pem > caKey.pem
"$PKI" --self --ca --lifetime 3650 --in caKey.pem \
      --dn "C=CH, O=strongSwan, CN=strongSwan CA" --outform pem > caCert.pem
cp caCert.pem "$DATA_DIR/moon/x509ca/"
cp caCert.pem "$DATA_DIR/sun/x509ca/"

# 2. Generate Moon Certs (Server)
echo "Generating Moon certs..."
cd "$DATA_DIR/moon/x509"
"$PKI" --gen --type rsa --size 3072 --outform pem > ../private/moonKey.pem
"$PKI" --pub --in ../private/moonKey.pem | "$PKI" --issue --lifetime 730 \
      --cacert "$DATA_DIR/ca/x509ca/caCert.pem" --cakey "$DATA_DIR/ca/x509ca/caKey.pem" \
      --dn "C=CH, O=strongSwan, CN=moon.strongswan.org" \
      --san "moon.strongswan.org" --outform pem > moonCert.pem

# 3. Generate Sun Certs (Client)
echo "Generating Sun certs..."
cd "$DATA_DIR/sun/x509"
"$PKI" --gen --type rsa --size 3072 --outform pem > ../private/sunKey.pem
"$PKI" --pub --in ../private/sunKey.pem | "$PKI" --issue --lifetime 730 \
      --cacert "$DATA_DIR/ca/x509ca/caCert.pem" --cakey "$DATA_DIR/ca/x509ca/caKey.pem" \
      --dn "C=CH, O=strongSwan, CN=sun.strongswan.org" \
      --san "sun.strongswan.org" --outform pem > sunCert.pem


# 4. Generate configurations
# We will create specific swanctl.conf files
# Moon (Responder)
cat > "$DATA_DIR/moon/swanctl.conf" <<EOF
connections {
   rw {
      local_addrs = 192.168.99.1
      proposals = aes256-sha384-mlkem768
      local {
         auth = pubkey
         certs = moonCert.pem
         id = moon.strongswan.org
      }
      remote {
         auth = pubkey
         id = sun.strongswan.org
      }
      children {
         net {
            local_ts = 192.168.99.1/32
            remote_ts = 192.168.99.2/32
            esp_proposals = aes256gcm16
         }
      }
      version = 2
   }
}
secrets {
   private_moon {
      file = moonKey.pem
   }
}
EOF

# Sun (Initiator)
cat > "$DATA_DIR/sun/swanctl.conf" <<EOF
connections {
   home {
      remote_addrs = 192.168.99.1
      vips = 0.0.0.0
      proposals = aes256-sha384-mlkem768
      local {
         auth = pubkey
         certs = sunCert.pem
         id = sun.strongswan.org
      }
      remote {
         auth = pubkey
         id = moon.strongswan.org
      }
      children {
         net {
            local_ts = 192.168.99.2/32
            remote_ts = 192.168.99.1/32
            esp_proposals = aes256gcm16
            start_action = start
         }
      }
      version = 2
   }
}
secrets {
   private_sun {
      file = sunKey.pem
   }
}
EOF


# 5. Generate strongswan.conf
# This is crucial to separate the two instances (sockets, PIDs)
cat > "$DATA_DIR/moon/strongswan.conf" <<EOF
charon {
    load_modular = yes
    pid_file = /tmp/charon_moon.pid
    plugins {
        include $BASE_DIR/etc/strongswan.d/charon/*.conf
        vici {
            socket = unix:///tmp/charon_moon.vici
        }
    }
    filelog {
        moon {
            path = /tmp/charon_moon.log
            time_format = %b %e %T
            default = 2
            ike = 2
            knl = 2
        }
    }

    piddir = /tmp/moon
}
swanctl {
    x509 = $DATA_DIR/moon/x509
    x509ca = $DATA_DIR/moon/x509ca
    private = $DATA_DIR/moon/private
}
EOF

cat > "$DATA_DIR/sun/strongswan.conf" <<EOF
charon {
    load_modular = yes
    pid_file = /tmp/charon_sun.pid
    plugins {
        include $BASE_DIR/etc/strongswan.d/charon/*.conf
        vici {
            socket = unix:///tmp/charon_sun.vici
        }
    }
    filelog {
        sun {
            path = /tmp/charon_sun.log
            time_format = %b %e %T
            default = 2
            ike = 2
            knl = 2
        }
    }

    piddir = /tmp/sun
}
swanctl {
    x509 = $DATA_DIR/sun/x509
    x509ca = $DATA_DIR/sun/x509ca
    private = $DATA_DIR/sun/private
}
EOF

echo "Configuration generation complete."
