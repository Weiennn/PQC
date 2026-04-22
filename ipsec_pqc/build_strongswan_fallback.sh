#!/bin/bash
set -e

# Directories
BASE_DIR="$(pwd)/ipsec_pqc"
DEPS_DIR="$BASE_DIR/deps"
INSTALL_DIR="$BASE_DIR/_install"

# StrongSwan Version
STRONGSWAN_VERSION="6.0.4"

echo "=== Building StrongSwan $STRONGSWAN_VERSION ==="
cd "$DEPS_DIR"

if [ ! -d "strongswan-$STRONGSWAN_VERSION" ]; then
    echo "Downloading StrongSwan $STRONGSWAN_VERSION from GitHub..."
    wget -c https://github.com/strongswan/strongswan/releases/download/$STRONGSWAN_VERSION/strongswan-$STRONGSWAN_VERSION.tar.bz2
    tar xjf strongswan-$STRONGSWAN_VERSION.tar.bz2
fi

cd "strongswan-$STRONGSWAN_VERSION"

echo "Configuring strongswan..."
./configure --prefix="$INSTALL_DIR" \
            --enable-ml \
            --enable-sha3 \
            --enable-openssl \
            --disable-gmp \
            --enable-gcm \
            --with-piddir="$BASE_DIR/run" \
            --sysconfdir="$BASE_DIR/etc"


echo "Building strongswan..."
make -j$(nproc)
echo "Installing strongswan..."
make install

echo "=== StrongSwan Build Complete ==="
