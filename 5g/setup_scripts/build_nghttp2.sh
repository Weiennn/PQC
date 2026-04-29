#!/bin/bash
set -e

echo "=================================================="
echo "  Rebuilding libnghttp2 with Custom OpenSSL 3.5.0 "
echo "=================================================="

# Define paths
NGHTTP2_DIR="/home/vboxuser/Desktop/PQC/5g/nghttp2-1.61.0"
OPENSSL_DIR="/home/vboxuser/Desktop/PQC/openssl-3.5.0"
INSTALL_PREFIX="/home/vboxuser/Desktop/PQC/5g/nghttp2-install"

if [ ! -d "$NGHTTP2_DIR" ]; then
    echo "nghttp2 directory not found at $NGHTTP2_DIR"
    echo "Downloading nghttp2-1.61.0..."
    cd /home/vboxuser/Desktop/PQC/5g
    wget -qO nghttp2.tar.gz https://github.com/nghttp2/nghttp2/releases/download/v1.61.0/nghttp2-1.61.0.tar.gz
    tar -xf nghttp2.tar.gz
    rm nghttp2.tar.gz
fi

if [ ! -f "$OPENSSL_DIR/libssl.so.3" ]; then
    echo "Error: Custom OpenSSL 3.5.0 not found at $OPENSSL_DIR"
    exit 1
fi

cd "$NGHTTP2_DIR"

# Clean previous build if any
if [ -f Makefile ]; then
    echo "[0/4] Cleaning previous build..."
    make clean 2>/dev/null || true
fi

echo "[1/4] Configuring libnghttp2 with OpenSSL 3.5.0..."
# --enable-lib-only avoids building programs that might need libxml2 or jemalloc
# We just need the shared library for Open5GS
LDFLAGS="-L${OPENSSL_DIR} -Wl,-rpath,${OPENSSL_DIR}" \
CPPFLAGS="-I${OPENSSL_DIR}/include" \
PKG_CONFIG_PATH="${OPENSSL_DIR}" \
./configure --prefix="$INSTALL_PREFIX" \
            --enable-lib-only \
            --enable-shared \
            --disable-static

echo "[2/4] Building libnghttp2..."
make -j$(nproc)

echo "[3/4] Installing libnghttp2 to $INSTALL_PREFIX ..."
make install

echo "[4/4] Verifying..."
echo ""
echo "Library linkage:"
ldd ${INSTALL_PREFIX}/lib/libnghttp2.so || true

echo ""
echo "=================================================="
echo "Success! libnghttp2 installed to: $INSTALL_PREFIX"
echo ""
echo "Next: rebuild Open5GS with custom dependencies:"
echo "  cd ~/Desktop/PQC/5g/open5gs"
echo "  rm -rf builddir"
echo "  PKG_CONFIG_PATH=${OPENSSL_DIR}:/home/vboxuser/Desktop/PQC/5g/curl-install/lib/pkgconfig:${INSTALL_PREFIX}/lib/pkgconfig \\"
echo "    meson setup builddir --prefix=/usr"
echo "  ninja -C builddir"
echo "  sudo ninja -C builddir install"
echo "=================================================="
