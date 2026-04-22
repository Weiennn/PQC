#!/bin/bash
set -e

# Directories
BASE_DIR="$(pwd)/ipsec_pqc"
DEPS_DIR="$BASE_DIR/deps"
INSTALL_DIR="$BASE_DIR/_install"
mkdir -p "$DEPS_DIR"
mkdir -p "$INSTALL_DIR"

# Library versions
LIBOQS_VERSION="0.8.0"
STRONGSWAN_VERSION="5.9.13" # Or master if we want bleeding edge, but lets try stable first with master for oqs

echo "=== Building Dependencies in $DEPS_DIR ==="

# 1. Build liboqs
cd "$DEPS_DIR"
if [ ! -d "liboqs" ]; then
    echo " Cloning liboqs..."
    git clone --branch main --single-branch https://github.com/open-quantum-safe/liboqs.git
fi

cd liboqs
# Ensure we are in a clean state
# git clean -fdx
mkdir -p build
cd build
echo " Configuring liboqs..."
cmake -DCMAKE_INSTALL_PREFIX="$INSTALL_DIR" -DOQS_USE_OPENSSL=ON ..
echo " Building liboqs..."
make -j$(nproc)
echo " Installing liboqs..."
make install

# 2. Build strongswan
cd "$DEPS_DIR"
if [ ! -d "strongswan" ]; then
    echo " Cloning strongswan..."
    git clone https://github.com/strongswan/strongswan.git
fi

cd strongswan
echo " Configuring strongswan..."
./autogen.sh
./configure --prefix="$INSTALL_DIR" \
            --enable-oqs \
            --enable-openssl \
            --enable-gcm \
            --with-liboqs="$INSTALL_DIR" \
            --with-piddir="$BASE_DIR/run" \
            --sysconfdir="$BASE_DIR/etc"

echo " Building strongswan..."
make -j$(nproc)
echo " Installing strongswan..."
make install

echo "=== Build Complete ==="
echo "Binaries installed to $INSTALL_DIR"
