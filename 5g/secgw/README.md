# 5G Security Gateway (secGW)

A PQC-capable IPSec Security Gateway placed between the RAN (gNB) and the 5G Core network, securing the backhaul link with ML-KEM-768 hybrid key exchange.

## Architecture

```
gNB (10.0.1.1)  ════IPSec═══►  secGW  ──plain──►  Core NFs
     ran0                    (ns_secgw)              core0
                          10.0.1.254 / 10.0.2.1
                          eth-ran     / eth-core
```

- **gNB** initiates an IKEv2 tunnel to the secGW using `aes256-sha384-mlkem768`
- **secGW** runs in a Linux network namespace (`ns_secgw`) with two interfaces
- **Core NFs** (AMF, UPF, etc.) receive plain decrypted traffic on `core0`
- UERANSIM's SCTP (N2) and GTP-U (N3) traffic is tunnelled transparently

## Prerequisites

1. **StrongSwan with PQC** built via `../../ipsec_pqc/build_deps.sh`
2. **Backhaul network** set up via `../setup_backhaul.sh`

## Quick Start

```bash
# 1. Ensure backhaul is up
sudo ../setup_backhaul.sh

# 2. Run the secGW (generates certs + config on first run)
sudo ./run_secgw.sh

# 3. In another terminal, start the 5G core + RAN
cd .. && ./start.sh && ./start_ran.sh
```

## Scripts

| Script | Purpose |
|---|---|
| `setup_secgw.sh` | Creates `ns_secgw` namespace with veth pairs bridging ran0 and core0 |
| `teardown_secgw.sh` | Removes namespace, veth pairs, routes, and daemon processes |
| `gen_secgw_certs.sh` | Generates CA + secGW/gNB certificates using StrongSwan pki |
| `gen_secgw_config.sh` | Generates swanctl.conf and strongswan.conf for both endpoints |
| `run_secgw.sh` | Full orchestration: setup → certs → config → start → verify |

## Custom IKE Proposal

```bash
# Default (ML-KEM-768)
sudo ./run_secgw.sh

# Custom proposal
sudo ./run_secgw.sh aes256-sha384-ke1mlkem768
```

## Verification

After `run_secgw.sh` completes setup, it automatically:
1. Checks IKE SA is ESTABLISHED on both sides
2. Verifies CHILD SA (ESP tunnel) is installed
3. Tests encrypted ping through the tunnel

### Manual checks

```bash
# View secGW logs
cat /tmp/charon_secgw.log

# View gNB logs
cat /tmp/charon_gnb.log

# Check XFRM policies
sudo ip netns exec ns_secgw ip xfrm state
sudo ip xfrm state
```

## Data Directory

After first run, `data/` contains:
```
data/
├── ca/x509ca/          # Root CA cert + key
├── secgw/
│   ├── x509/           # secGW certificate
│   ├── x509ca/         # CA cert (copy)
│   ├── private/        # secGW private key
│   ├── swanctl.conf
│   └── strongswan.conf
└── gnb/
    ├── x509/           # gNB certificate
    ├── x509ca/         # CA cert (copy)
    ├── private/        # gNB private key
    ├── swanctl.conf
    └── strongswan.conf
```

## How the Security Gateway (secGW) Works

The secGW is implemented using a dedicated Linux network namespace (`ns_secgw`) that acts as a secure boundary and router between the RAN subnet (`10.0.1.0/24`) and the Core subnet (`10.0.2.0/24`).

1. **Namespace Isolation:** The environment isolates the gateway using the `ns_secgw` network namespace. It creates two Virtual Ethernet (veth) pairs connecting the host's existing routing domains to the namespace:
   - **RAN-side:** `veth-ran-h` (host) ↔ `eth-ran` (10.0.1.254 in namespace)
   - **Core-side:** `veth-core-h` (host) ↔ `eth-core` (10.0.2.1 in namespace)

2. **Traffic Routing:** IPv4 forwarding and proxy ARP are enabled within the namespace, empowering it to route traffic between the RAN and Core subnets. Routes on the host are explicitly configured to direct 5G Core-bound traffic from the gNB into the secGW interfaces.

3. **Encryption Flow:**
   - **Uplink:** The gNB (10.0.1.1) creates an IKEv2 IPSec tunnel to the secGW (10.0.1.254). Encrypted traffic destined for the 5G core enters the secGW via `eth-ran`. StrongSwan decrypts the ESP packets within the namespace, and the secGW forwards the resulting plain-text SCTP/GTP-U traffic out via `eth-core` (10.0.2.1) to the 5G Core Network Functions (10.0.2.x).
   - **Downlink:** Plain text response traffic from the 5G Core enters the secGW via `eth-core`. The secGW matches this against configured XFRM IPSec policies, encrypts it securely using the negotiated PQC hybrid keys, and routes the encrypted frames back to the gNB via the `eth-ran` interface over the established tunnel.
