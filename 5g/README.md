# 5G Open5GS Configuration for PQC Hybrid Methods

This directory (`/5g`) contains scripts to manage an Open5GS 5G core network with support for both **classical TLS 1.2** and **PQC TLS 1.3** (X25519MLKEM768 + ML-DSA). It also includes a PQC Security Gateway (secGW) that sits between the simulated RAN (UERANSIM) and the 5G Core.

## Quick Start

```bash
# 1. Setup the backhaul network interfaces (ran0 and core0 dummy interfaces)
./setup_backhaul.sh

# 2. Generate PQC certs (or use a different algo: mldsa44, mldsa87, rsa, ecdsa, ed25519)
# Note: Cert generation scripts are inside the `setup scripts/` directory
./setup scripts/generate_5g_certs.sh mldsa65

# 3. Generate classical certs (for toggling back)
./setup scripts/generate_5g_certs.sh rsa

# 4. Switch to PQC mode
sudo ./toggle_pqc.sh pqc mldsa65

# 5. Start the Open5GS network
./start.sh

# 6. Start the virtual gNB and UE via UERANSIM
./start_ran.sh

# 7. Disconnect and reset
./off.sh
./teardown_backhaul.sh
```

## Architecture

Open5GS has been **recompiled against OpenSSL 3.5.0** (at `~/Desktop/PQC/openssl-3.5.0/`).

The same binary supports **both** TLS 1.2 and TLS 1.3 — switching is purely config-based:

| Mode       | Certs       | Key Exchange   | TLS Version | OPENSSL_CONF        |
|------------|-------------|----------------|-------------|---------------------|
| Classical  | RSA / ECDSA | X25519         | TLS 1.2     | (none)              |
| PQC        | ML-DSA-65   | X25519MLKEM768 | TLS 1.3     | `openssl_pqc.cnf`   |

The 5G testbed operates over a custom backhaul (dummy interfaces):
* **RAN Subnet (ran0)**: `10.0.1.0/24` (gNB)
* **Core Subnet (core0)**: `10.0.2.0/24` (AMF, UPF, SMF, etc.)

## Directory Contents & Scripts

| Script/Directory         | Purpose                                                   |
|--------------------------|-----------------------------------------------------------|
| `setup scripts/`         | Contains initialization scripts (`generate_5g_certs.sh`, `enable_mtls.sh`, `update_nf_ips.sh`) |
| `setup_backhaul.sh`      | Creates `ran0` and `core0` interfaces for network emulation |
| `teardown_backhaul.sh`   | Cleans up the dummy backhaul network interfaces           |
| `toggle_pqc.sh`          | Switch between PQC and classical mode (certs + systemd)   |
| `start.sh`               | Start all Open5GS NFs via systemctl                       |
| `off.sh`                 | Stop all Open5GS NFs                                      |
| `start_ran.sh`           | Start UERANSIM gNB + UE                                   |
| `benchmark_ue.sh`        | Benchmark UE registration times                           |
| `tls_handshake_latency.py`| Python script to benchmark and visualize TLS handshake latency on the SBI |
| `secgw/`                 | PQC IPSec Security Gateway testbed (see `secgw/README.md`) |
| `open5gs/`               | Modified Open5GS source code                              |
| `UERANSIM/`              | Modified UERANSIM source code                             |

## How the Toggle Works

`toggle_pqc.sh` does three things:
1. **Copies certs** from `5g/certs/<algo>/` into `/etc/open5gs/tls/`
2. **Adds/removes** `OPENSSL_CONF` and `LD_LIBRARY_PATH` in systemd service files
3. **Reloads** the systemd daemon

No recompilation is needed — just toggle and restart.

## Certificate Generation

```bash
# Generate certs using scripts inside the setup directory
cd "setup scripts"

# Available algorithms:
./generate_5g_certs.sh mldsa44   # ML-DSA-44 (PQC level 2)
./generate_5g_certs.sh mldsa65   # ML-DSA-65 (PQC level 3) [DEFAULT]
./generate_5g_certs.sh mldsa87   # ML-DSA-87 (PQC level 5)
./generate_5g_certs.sh rsa       # RSA 3072
./generate_5g_certs.sh rsa4096   # RSA 4096
./generate_5g_certs.sh ecdsa     # ECDSA P-384
./generate_5g_certs.sh ecdsa256  # ECDSA P-256
./generate_5g_certs.sh ed25519   # Ed25519
```

Certs are generated for all 12 NFs: amf, ausf, bsf, nrf, nssf, pcf, scp, sepp1, sepp2, smf, udm, udr.

## Build from Source

If you need to recompile Open5GS:

```bash
cd ~/Desktop/PQC/5g/open5gs

# Clean previous build
rm -rf builddir

# Configure with custom OpenSSL 3.5.0
PKG_CONFIG_PATH=/home/vboxuser/Desktop/PQC/openssl-3.5.0 \
  meson setup builddir --prefix=/usr

# Build and install
ninja -C builddir
sudo ninja -C builddir install
```

## Verification

```bash
# Check which OpenSSL the AMF loads (in PQC mode, should show 3.5.0 path)
sudo ./toggle_pqc.sh status

# Verify PQC cert is installed
openssl x509 -in /etc/open5gs/tls/amf.crt -text -noout | grep "Signature Algorithm"

# Verify LD_LIBRARY_PATH resolves to OpenSSL 3.5.0
LD_LIBRARY_PATH=~/Desktop/PQC/openssl-3.5.0 ldd /usr/bin/open5gs-amfd | grep libssl
```

## Security Gateway (secGW)

A PQC-capable IPSec tunnel can be established between the RAN and the Core using StrongSwan and Linux Network Namespaces.

```bash
cd secgw
sudo ./run_secgw.sh
```

Traffic from the UERANSIM gNB (`10.0.1.1`) to the AMF (`10.0.2.5`) will be transparently routed into the `ns_secgw` namespace where StrongSwan encrypts the payload using ML-KEM-768 inside an IKEv2 tunnel.

## Network Function Configuration

Config files live in `/etc/open5gs/` (not `/var/open5gs/`). The table below maps each NF to its config file and the key fields you are most likely to change:

| NF | Config File | Key Configurable Fields |
|----|-------------|------------------------|
| AMF | `amf.yaml` | PLMN ID (mcc/mnc), TAC, GUAMI, S-NSSAI, NGAP address, SBI address, security algorithms |
| SMF | `smf.yaml` | UE IP pool (session subnet), DNS, MTU, UPF PFCP address, DNN, S-NSSAI |
| UPF | `upf.yaml` | GTP-U address, PFCP address, session subnet/gateway |
| NRF | `nrf.yaml` | PLMN ID, SBI bind address |
| SCP | `scp.yaml` | SBI bind address, NRF URI |
| AUSF / UDM / UDR | respective `.yaml` | SBI address, SCP/NRF URI, MongoDB URI |
| NSSF / PCF / BSF | respective `.yaml` | SBI address, slice policies |
| SEPP1 / SEPP2 | `sepp1.yaml`, `sepp2.yaml` | N32 address, peer SEPP URI |

### 1. PLMN / TAC — `amf.yaml` and `nrf.yaml`

These must **exactly match** the UERANSIM gNB and UE configs.

```yaml
# /etc/open5gs/amf.yaml  (current values in this testbed)
guami:
  - plmn_id:
      mcc: 999
      mnc: 70
    amf_id:
      region: 2
      set: 1
tai:
  - plmn_id:
      mcc: 999
      mnc: 70
    tac: 1
plmn_support:
  - plmn_id:
      mcc: 999
      mnc: 70
    s_nssai:
      - sst: 1
```

```yaml
# /etc/open5gs/nrf.yaml
nrf:
  serving:
    - plmn_id:
        mcc: 999
        mnc: 70
```

### 2. IP Address Bindings

Each NF binds its SBI interface to a unique IP on the `core0` subnet (`10.0.2.x`):

| NF   | SBI / Control IP | Protocol Port |
|------|-----------------|----------------|
| NRF  | `10.0.2.10`     | 7777           |
| SCP  | `10.0.2.200`    | 7777           |
| AMF  | `10.0.2.5`      | 7777 (SBI), 38412 (NGAP N2) |
| SMF  | `10.0.2.4`      | 7777 (SBI), PFCP |
| UPF  | `10.0.2.7`      | PFCP, GTP-U N3 |
| AUSF | `10.0.2.8`      | 7777           |
| UDM  | `10.0.2.11`     | 7777           |
| UDR  | `10.0.2.12`     | 7777           |

If you change any NF's IP, you must update **both** the NF's own `.yaml` and any peer NFs that reference it (e.g. SMF references UPF via `pfcp.client.upf.address`).

### 3. UE IP Pool & Data Path — `smf.yaml` and `upf.yaml`

```yaml
# /etc/open5gs/smf.yaml
session:
  - subnet: 10.45.0.0/16
    gateway: 10.45.0.1
dns:
  - 8.8.8.8
  - 8.8.4.4
mtu: 1400
pfcp:
  client:
    upf:
      - address: 10.0.2.7   # must match upf.yaml pfcp.server.address
```

```yaml
# /etc/open5gs/upf.yaml
pfcp:
  server:
    - address: 10.0.2.7
gtpu:
  server:
    - address: 10.0.2.7
session:
  - subnet: 10.45.0.0/16
    gateway: 10.45.0.1
```

> The `ogstun` TUN interface on the host must have `10.45.0.1` assigned for UE traffic to be routed correctly:
> ```bash
> sudo ip addr add 10.45.0.1/16 dev ogstun
> sudo ip link set ogstun up
> ```

### 4. TLS / mTLS / PQC — all NFs

Cert paths are defined under `default.tls` in each NF's YAML. The standard layout is:

```yaml
default:
  tls:
    server:
      scheme: https
      private_key: /etc/open5gs/tls/<nf>.key
      cert: /etc/open5gs/tls/<nf>.crt
      verify_client: true                          # enables mTLS
      verify_client_cacert: /etc/open5gs/tls/ca.crt
    client:
      scheme: https
      cacert: /etc/open5gs/tls/ca.crt
      client_private_key: /etc/open5gs/tls/<nf>.key
      client_cert: /etc/open5gs/tls/<nf>.crt
```

- `toggle_pqc.sh` replaces the cert files in `/etc/open5gs/tls/` to switch algorithms.
- `verify_client: true` enables mutual TLS — remove it to downgrade to server-only TLS.
- To enable SSL key logging for Wireshark, add `sslkeylogfile: /var/log/open5gs/tls/<nf>-sslkeylog.log` under the `server:` block.

### 5. Logging

Every NF config has a `logger:` stanza at the top:

```yaml
logger:
  file:
    path: /var/log/open5gs/<nf>.log
#  level: info   # fatal | error | warn | info (default) | debug | trace
```

Uncomment `level: debug` or `level: trace` to get verbose output for a specific NF. Logs land in `/var/log/open5gs/`.

### 6. Max UE Capacity

```yaml
global:
  max:
    ue: 1024   # increase if running many concurrent UEs
```

Present in every NF config under `global.max.ue`.

---

## UERANSIM Configuration

UERANSIM configs are in `UERANSIM/config/`. The values **must mirror** the Open5GS AMF config.

### gNB — `config/open5gs-gnb.yaml`

```yaml
mcc: '999'        # match amf.yaml plmn_id.mcc
mnc: '70'         # match amf.yaml plmn_id.mnc
tac: 1            # match amf.yaml tai.tac

linkIp: 10.0.1.1  # gNB IP on the ran0 interface (Radio Link Sim)
ngapIp: 10.0.1.1  # gNB N2 IP → AMF connects here
gtpIp:  10.0.1.1  # gNB N3 IP → UPF GTP tunnel endpoint

amfConfigs:
  - address: 10.0.2.5   # must match amf.yaml ngap.server.address
    port: 38412

slices:
  - sst: 1              # must match amf.yaml plmn_support.s_nssai
```

### UE — `config/open5gs-ueN.yaml`

```yaml
supi: 'imsi-999700000000001'  # must be registered in the subscriber DB
mcc: '999'
mnc: '70'
key: '465B5CE8B199B49FAA5F0A2EE238A6BC'   # K — must match subscriber DB
op:  'E8ED289DEBA952E4283B54E88E6183CA'   # OPc — must match subscriber DB
opType: 'OPC'

gnbSearchList:
  - 10.0.1.1   # gNB IP

sessions:
  - type: 'IPv4'
    apn: 'internet'   # must match DNN in smf.yaml / subscriber profile
    slice:
      sst: 1
```

Multiple UE configs (`open5gs-ue0.yaml` … `open5gs-ue9.yaml`) exist for concurrent UE benchmarking.

---

## Subscriber Registration

Add a UE to the MongoDB database via the Web UI or CLI:

```bash
# Web UI (recommended)
open http://localhost:9999

# CLI — add via open5gs-dbctl
/usr/local/lib/node_modules/open5gs-webui/node_modules/.bin/open5gs-dbctl \
  add 999700000000001 465B5CE8B199B49FAA5F0A2EE238A6BC E8ED289DEBA952E4283B54E88E6183CA
```

Each subscriber entry must contain: **IMSI, K (key), OPc, APN/DNN, S-NSSAI (sst/sd)**.

---

## Setting MTU
```bash
sudo ip link set dev lo mtu 65536
sudo ethtool -K lo gro off lro off tso off
```

> The SMF also sets `mtu: 1400` to account for GTP-U and IPSec overhead. Adjust if using the secGW (IPSec adds ~60–80 bytes of overhead).

---

## Troubleshooting

| Symptom | Likely Cause | Fix |
|---------|-------------|-----|
| gNB fails to connect to AMF | PLMN/TAC mismatch or wrong `ngapIp`/`amfConfigs.address` | Verify `mcc`, `mnc`, `tac` match in both configs |
| UE registration rejected | IMSI/K/OPc not in subscriber DB, or PLMN mismatch | Check Web UI at http://localhost:9999 |
| UE gets no IP address | `ogstun` not up, or `10.45.0.1` not assigned | Run `ip addr add 10.45.0.1/16 dev ogstun && ip link set ogstun up` |
| TLS handshake failure | Cert/key mismatch or wrong CA | Re-run `generate_5g_certs.sh` and `toggle_pqc.sh` |
| NF won't start (port in use) | Previous instance still running | `sudo ./off.sh` then re-run `./start.sh` |
| PQC mode reverts after reboot | systemd env vars cleared | Re-run `sudo ./toggle_pqc.sh pqc mldsa65` |
