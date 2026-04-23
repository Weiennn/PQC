#!/bin/bash
set -e

echo "=================================================="
echo "    Rebuilding libcurl with Custom OpenSSL 3.5.0  "
echo "=================================================="

# Define paths
CURL_DIR="/home/vboxuser/Desktop/PQC/5g/curl-8.5.0"
OPENSSL_DIR="/home/vboxuser/Desktop/PQC/openssl-3.5.0"
INSTALL_PREFIX="/home/vboxuser/Desktop/PQC/5g/curl-install"

if [ ! -d "$CURL_DIR" ]; then
    echo "Error: curl directory not found at $CURL_DIR"
    exit 1
fi

if [ ! -f "$OPENSSL_DIR/libssl.so.3" ]; then
    echo "Error: Custom OpenSSL 3.5.0 not found at $OPENSSL_DIR"
    exit 1
fi

cd "$CURL_DIR"

# Clean previous build if any
if [ -f Makefile ]; then
    echo "[0/4] Cleaning previous build..."
    make clean 2>/dev/null || true
fi

echo "[1/4] Configuring libcurl with OpenSSL 3.5.0..."
# --with-openssl: path to OpenSSL headers + libs
# --without-gnutls: explicitly disable GnuTLS (the whole point)
# --prefix: install to a local directory (not /usr/local) so we can control it
# We need to tell configure where to find OpenSSL's headers and libs
LDFLAGS="-L${OPENSSL_DIR} -Wl,-rpath,${OPENSSL_DIR}" \
CPPFLAGS="-I${OPENSSL_DIR}/include" \
PKG_CONFIG_PATH="${OPENSSL_DIR}" \
./configure --prefix="$INSTALL_PREFIX" \
            --with-openssl="$OPENSSL_DIR" \
            --without-gnutls \
            --without-mbedtls \
            --without-nss \
            --without-libpsl \
            --enable-shared \
            --disable-static

echo "[2/4] Building libcurl..."
make -j$(nproc)

echo "[3/4] Installing libcurl to $INSTALL_PREFIX ..."
make install

echo "[4/4] Verifying..."
# Check that the built curl uses OpenSSL, not GnuTLS
echo ""
echo "Built curl binary:"
LD_LIBRARY_PATH="${OPENSSL_DIR}:${INSTALL_PREFIX}/lib" ${INSTALL_PREFIX}/bin/curl --version | head -1
echo ""
echo "Library linkage:"
ldd ${INSTALL_PREFIX}/lib/libcurl.so | grep -iE "ssl|gnutls|crypto"

echo ""
echo "=================================================="
echo "Success! libcurl installed to: $INSTALL_PREFIX"
echo ""
echo "Next: rebuild Open5GS with both custom OpenSSL and custom libcurl:"
echo "  cd ~/Desktop/PQC/5g/open5gs"
echo "  rm -rf builddir"
echo "  PKG_CONFIG_PATH=${OPENSSL_DIR}:${INSTALL_PREFIX}/lib/pkgconfig \\"
echo "    meson setup builddir --prefix=/usr"
echo "  ninja -C builddir"
echo "  sudo ninja -C builddir install"
echo "=================================================="
