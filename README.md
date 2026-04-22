# Post-Quantum Cryptography (PQC) Research Testbed

A comprehensive testbed for evaluating Post-Quantum Cryptography in TLS handshakes, IPSec VPNs, and 5G core networks. Uses **OpenSSL 3.5.0**'s native ML-KEM and ML-DSA support — no external PQC providers required.

## What This Project Does

| Module | Description |
|--------|-------------|
| **TLS Benchmarks** (`TLS_testing/`) | Custom C client/server measuring handshake latency, CPU usage, and throughput (HPS) across classical and PQC algorithms |
| **Component Benchmarks** (`component_benches/`) | Isolated KEM/signature operation benchmarks (keygen, encaps, sign, verify) |
| **IPSec PQC** (`ipsec_pqc/`) | StrongSwan VPN testbed with ML-KEM-768 key exchange via Linux network namespaces |
| **5G Core** (`5g/`) | Open5GS + UERANSIM with PQC hybrid TLS (X25519MLKEM768) on the SBI interfaces |
| **Security Gateway** (`5g/secgw/`) | PQC IPSec gateway protecting the RAN↔Core backhaul link |

## Supported Algorithms

| Category | Algorithms |
|----------|-----------|
| **Key Exchange (KEM)** | X25519, ML-KEM-512, ML-KEM-768, ML-KEM-1024, X25519MLKEM768 (hybrid) |
| **Digital Signatures** | RSA-3072, RSA-4096, ECDSA P-256, ECDSA P-384, Ed25519, ML-DSA-44, ML-DSA-65, ML-DSA-87 |

---

## Prerequisites

- **OS**: Ubuntu 22.04 or 24.04 LTS (tested on Ubuntu 24.04)
- **Hardware**: 4+ CPU cores, 4GB+ RAM recommended
- **Packages**:

```bash
sudo apt update
sudo apt install -y \
    build-essential gcc make perl \
    iproute2 ethtool net-tools tcpdump \
    bc jq \
    python3 python3-pip python3-venv
```

For the 5G testbed (optional):
```bash
sudo apt install -y \
    meson ninja-build flex bison \
    libtalloc-dev libgnutls28-dev libnghttp2-dev \
    libmicrohttpd-dev libcurl4-gnutls-dev libyaml-dev \
    libmongoc-dev libsctp-dev libgcrypt20-dev
```

For the IPSec testbed (optional):
```bash
sudo apt install -y \
    cmake autoconf automake libtool pkg-config \
    libgmp-dev
```

---

## Setup

### 1. Clone the Repository

```bash
git clone https://github.com/Weiennn/PQC.git
cd PQC
```

### 2. Download and Build OpenSSL 3.5.0

The entire project links against OpenSSL 3.5.0 for native PQC support. The source tree must be at `openssl-3.5.0/` in the project root.

```bash
# Download OpenSSL 3.5.0
wget https://github.com/openssl/openssl/releases/download/openssl-3.5.0/openssl-3.5.0.tar.gz
tar xzf openssl-3.5.0.tar.gz

# Build (stay in project root)
cd openssl-3.5.0
./Configure
make -j2    # Use -j2 to avoid OOM on VMs with limited RAM
cd ..
```

> **Note**: Use `make -j2` instead of `make -j$(nproc)` if your machine has less than 8GB RAM. OpenSSL's build can be memory-intensive and may freeze the system with full parallelism.

After building, verify the version:
```bash
./openssl-3.5.0/apps/openssl version
# Expected: OpenSSL 3.5.0 ...
```

### 3. Build the TLS Client/Server Binaries

```bash
cd TLS_testing
./build.sh
# Output: build/pqc_server, build/pqc_server_threaded, build/pqc_client, build/classical_client
```

### 4. Generate TLS Certificates

```bash
# Still inside TLS_testing/
./generate_certs.sh
```

This generates certificate chains for all supported signature algorithms under `TLS_testing/certs/`:
- `certs/rsa/` — RSA-3072
- `certs/rsa4096/` — RSA-4096
- `certs/ecdsa/` — ECDSA P-384
- `certs/ecdsa_p256/` — ECDSA P-256
- `certs/ed25519/` — Ed25519
- `certs/mldsa44/` — ML-DSA-44
- `certs/mldsa65/` — ML-DSA-65
- `certs/mldsa87/` — ML-DSA-87

Each directory contains: `ca_cert.pem`, `ca_key.pem`, `server_cert.pem`, `server_key.pem`, `client_cert.pem`, `client_key.pem`.

---

## Quick Test

Verify everything works with a basic PQC handshake:

```bash
cd TLS_testing
export LD_LIBRARY_PATH=$PWD/../openssl-3.5.0

# Terminal 1 — Start the server (hybrid mode)
./build/pqc_server \
    -c certs/rsa/server_cert.pem \
    -k certs/rsa/server_key.pem \
    -a certs/rsa/ca_cert.pem \
    -g X25519MLKEM768

# Terminal 2 — Connect with the PQC client
./build/pqc_client \
    -H 127.0.0.1 \
    -g X25519MLKEM768 \
    -C certs/rsa/ca_cert.pem \
    -c certs/rsa/client_cert.pem \
    -k certs/rsa/client_key.pem
```

You should see output including:
```
Negotiated Group Name: X25519MLKEM768
PQC_METRIC_HANDSHAKE_MS <value>
```

---

## Running Benchmarks

All benchmark scripts should be run from inside the `TLS_testing/` directory.

### TLS Handshake Latency & CPU

Measures handshake time across multiple KEM algorithms with realistic network conditions (MTU 1500, 5ms delay, 0.1% loss):

```bash
cd TLS_testing
sudo ./benchmark.sh
```

### Consolidated Benchmark (All Combinations)

Iterates over all signature × KEM combinations (28 total) measuring latency, CPU, and HPS:

```bash
cd TLS_testing
sudo ./benchmark_consolidated.sh
```

### Handshakes Per Second (HPS)

Stress-tests server throughput using parallel load generation:

```bash
cd TLS_testing
sudo ./benchmark_hps.sh
```

### Component-Level Benchmarks

Measures raw KEM/signature operation performance (keygen, encaps/decaps, sign/verify):

```bash
cd component_benches
./build_bench.sh
./run_bench.sh
```

> **Note**: `build_bench.sh` links against `local/lib` which requires the legacy OQS provider build. For the native OpenSSL 3.5.0 benchmark, use `native_pqc_bench.c`.

---

## IPSec PQC Testbed (`ipsec_pqc/`)

Tests PQC key exchange (ML-KEM-768) in an IKEv2/IPSec tunnel using StrongSwan with liboqs.

### Setup

```bash
# From the project root — build liboqs and StrongSwan
./ipsec_pqc/build_deps.sh

# Run the IPSec test (creates namespaces, certs, tunnel, verifies encryption)
./ipsec_pqc/run_test.sh
```

### What It Does
1. Creates two network namespaces (Alice and Bob) connected by a virtual link
2. Generates certificates and StrongSwan configs
3. Starts charon daemons in each namespace
4. Initiates an IKEv2 tunnel using ML-KEM-768
5. Verifies encrypted traffic with ping and `ip xfrm state`

---

## 5G PQC Testbed (`5g/`)

Integrates PQC into a full 5G core network (Open5GS) with UERANSIM as the RAN simulator.

### Prerequisites
- Open5GS installed and configured (source included in `5g/open5gs/`)
- UERANSIM installed (source included in `5g/UERANSIM/`)
- MongoDB running for subscriber database

### Recompile Open5GS with OpenSSL 3.5.0

```bash
cd 5g/open5gs
rm -rf builddir
PKG_CONFIG_PATH=$HOME/Desktop/PQC/openssl-3.5.0 \
    meson setup builddir --prefix=/usr
ninja -C builddir
sudo ninja -C builddir install
```

### Generate 5G Certificates and Toggle PQC

```bash
cd 5g

# Generate PQC certificates for all 12 NFs
./generate_5g_certs.sh mldsa65

# Generate classical certificates (for comparison)
./generate_5g_certs.sh rsa

# Switch to PQC mode
sudo ./toggle_pqc.sh pqc mldsa65

# Start the 5G core
./start.sh
```

See [`5g/README.md`](5g/README.md) for the full 5G guide.

### Security Gateway (`5g/secgw/`)

PQC IPSec gateway protecting the RAN↔Core backhaul:

```bash
cd 5g/secgw
sudo ./run_secgw.sh
```

See [`5g/secgw/README.md`](5g/secgw/README.md) for architecture details.

---

## Project Structure

```
PQC/
├── TLS_testing/                       # TLS handshake benchmarking suite
│   ├── pqc_server.c / pqc_client.c   # TLS client/server source (C)
│   ├── pqc_server_threaded.c          # Multi-threaded server for HPS benchmarks
│   ├── classical_client.c             # Classical-only client for comparison
│   ├── build.sh                       # Compile all binaries
│   ├── generate_certs.sh              # Generate all cert types
│   ├── benchmark.sh                   # KEM latency benchmark
│   ├── benchmark_consolidated.sh      # Full matrix benchmark (sig × KEM)
│   ├── benchmark_hps.sh              # Throughput benchmark
│   ├── netns_utils.sh                 # Network namespace utilities
│   ├── openssl_oqs.cnf                # OpenSSL config for PQC groups
│   └── plot_*.py                      # Plotting scripts
├── component_benches/                 # Isolated crypto operation benchmarks
├── ipsec_pqc/                         # StrongSwan IPSec PQC testbed
├── 5g/                                # Open5GS + UERANSIM 5G testbed
│   ├── open5gs/                       # Open5GS source (modified for PQC)
│   ├── UERANSIM/                      # UERANSIM source
│   ├── secgw/                         # PQC Security Gateway
│   └── toggle_pqc.sh                  # Classical ↔ PQC mode switch
├── openssl-3.5.0/                     # OpenSSL source tree (not in repo — build locally)

```

---

## Third-Party Software

This project includes modified versions of:
- **[Open5GS](https://github.com/open5gs/open5gs)** (AGPL-3.0) — 5G core network, modified for PQC TLS group support
- **[UERANSIM](https://github.com/aligungr/UERANSIM)** (AGPL-3.0) — 5G RAN simulator, config changes for backhaul subnet


---

## License

This project's own code (benchmarks, scripts, C source files) is provided for research and educational purposes.
The included Open5GS and UERANSIM source code is licensed under AGPL-3.0 — see their respective LICENSE files.
