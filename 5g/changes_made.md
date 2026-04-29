# 5G Network PQC TLS 1.3 Support Modifications

This document details the modifications made to the `open5gs/` and `UERANSIM/` components to enable Post-Quantum Cryptography (PQC) and hybrid TLS 1.3 support.

## 1. Overview of Code Modifications

### Open5GS
- **Dynamic TLS Group Assignment**: Modified `lib/sbi/nghttp2-server.c` (Lines 252-261) and `lib/sbi/client.c` (Lines 407-412, 532-536) to parse the `OPEN5GS_TLS_GROUPS` environment variable. This enables dynamic assignment for TLS 1.3 groups (specifically `X25519MLKEM768` for PQC hybrid).

### UERANSIM
- **Routing Updates**: Updated routing configurations in `config/open5gs-gnb.yaml` and `config/open5gs-ue.yaml` to interoperate with the SecGW IP topologies and namespaces.
- **Traffic Generation**: Added the `config/generate_ues.py` script to automate UE generation.

---

## 2. Transitioning from Classical to Hybrid Cryptography

By default, the "out of the box" Open5GS configuration does not use TLS; all traffic is unencrypted to facilitate easier debugging via Wireshark. 

To enable hybrid Key Encapsulation Mechanism (KEM) methods, follow these steps:

1. **Compile a compatible OpenSSL version** 
   Find and compile a version of OpenSSL (v3.5.0+) that supports hybrid methods. Install it locally within your project folder. **Do not replace your native OS OpenSSL**, as doing so may break other system dependencies. When compiling dependencies against this, set a custom `PKG_CONFIG_PATH` to point to your new local OpenSSL installation.

2. **Recompile libcurl** Recompile `libcurl` (used for making requests in the Open5GS core) against the new OpenSSL version. Ensure the `PKG_CONFIG_PATH` points to your local OpenSSL directory. Use the /setup_scripts/build_curl.sh script.

3. **Recompile libnghttp2** Recompile `libnghttp2` against the new OpenSSL version. Use the /setup_scripts/build_nghttp2.sh script.

4. **Recompile Open5GS** Recompile Open5GS using these custom versions of `libcurl` and `libnghttp2` (makefiles are located in the project library). Run the following commands:
   ```bash
   cd ~/Desktop/PQC/5g/open5gs
   rm -rf builddir
   PKG_CONFIG_PATH=/home/vboxuser/Desktop/PQC/openssl-3.5.0:/home/vboxuser/Desktop/PQC/5g/curl-install/lib/pkgconfig:/home/vboxuser/Desktop/PQC/5g/nghttp2-install/lib/pkgconfig \
   meson setup builddir --prefix=/usr
   ninja -C builddir
   sudo ninja -C builddir install
   ```

5. **Configure the Open5GS Interface** Modify the Open5GS code for `libcurl` and `libnghttp2` to enable TLS and allow KEM and signature algorithms to be set as parameters within the Network Functions (NFs).
    * **Update Protocols:** Change `http://` to `https://` for all SBI clients across all Open5GS NF configuration files (etc/open5gs/NF.yaml).
    * **Map FQDNs:** Map Fully Qualified Domain Names (FQDNs) to their corresponding IP addresses (e.g., `127.0.0.5 amf.localdomain`) in `/etc/hosts`. This is necessary because TLS requires the FQDN to match the certificate’s SAN/CN.
    * **Update URIs:** Update all configuration files to use the new `https://<NF>.localdomain` URIs in their respective "client" sections.
    * **Modify Source Code (open5gs/lib/sbi/nghttp2-server.c):** Update `lib/sbi/nghttp2-server.c` (line 247). The previous implementation:
      ```c
      #if OPENSSL_VERSION_NUMBER >= 0x30000000L
          if (SSL_CTX_set1_curves_list(ssl_ctx, "P-256") != 1) {
              ogs_error("SSL_CTX_set1_curves_list failed: %s", ERR_error_string(ERR_get_error(), NULL));
              return NULL;
          }
      #endif /* !(OPENSSL_VERSION_NUMBER >= 0x30000000L) */
      ```
      forces the SBI server to accept only the **p-256** curve. Modify this to accept a list of groups via an environment variable. Refer to current implementation for details.
    * **Modify Source Code (open5gs/lib/sbi/client.c):** Update `lib/sbi/client.c` to also accept an environment variable for TLS groups. Refer to current implementation for details.
    * **Define Configuration Files:** Create `openssl_classical.cnf` and `openssl_pqc.cnf` files with the appropriate settings (e.g., specifying TLS protocols for the respective connections). 

# Config files for Open5GS Network Functions

Replace the default config files in `etc/open5gs/` and update your system's hosts file:

```bash
cp config_files/*.yaml etc/open5gs/
cp config_files/hosts /etc/hosts
```