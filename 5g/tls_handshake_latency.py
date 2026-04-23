#!/usr/bin/env python3
"""
tls_handshake_latency.py
========================
Measures the time delta between the first TLS Client Hello sent TO nrf.localdomain
and the first TLS Client Hello sent TO udm.localdomain during Open5GS startup.

This effectively captures the "NRF TLS handshake start → UDM TLS handshake start"
latency — a proxy for how long the PQC (or classical) key exchange adds to the
NF boot-and-register chain.

Strategy
--------
  1. Flush & restart all Open5GS NFs (via off.sh / start.sh).
  2. Run tcpdump on loopback in the background, writing a temporary .pcap file.
  3. Tail /var/log/open5gs/nrf.log and wait for two events:
       - First "NF registered" line  → first NF completed TLS + registration
       - "NF registered" line that follows the UDM associating at NRF
  4. Stop tcpdump, parse the pcap for TLS Client Hello SNIs.
  5. Compute delta between first nrf.localdomain Client Hello timestamp and
     first udm.localdomain Client Hello timestamp.
  6. Repeat for NUM_RUNS, then print statistics.

Network emulation (netem) parameters are applied to the loopback before each run
and removed afterwards, exactly like test_disable_NF.sh.

Usage
-----
  sudo python3 tls_handshake_latency.py [--runs N] [--mode {hybrid,classical,both}]
                                         [--delay MS] [--loss PCT] [--mtu BYTES]
                                         [--algo ALGO] [--output FILE]

Examples
  sudo python3 tls_handshake_latency.py --mode both --runs 30
  sudo python3 tls_handshake_latency.py --mode hybrid --runs 20 --delay 10 --loss 0.5 --mtu 1400

Requirements
  pip install scapy   (for pcap parsing — no tshark needed)

  OR the script falls back to a pure-Python struct-based TLS SNI parser if
  scapy is not available.
"""

import argparse
import csv
import os
import signal
import struct
import subprocess
import sys
import tempfile
import time
from datetime import datetime
from pathlib import Path
from statistics import mean, median, stdev

# ---------------------------------------------------------------------------
# Paths (adjust if your layout differs)
# ---------------------------------------------------------------------------
SCRIPT_DIR      = Path(__file__).parent.resolve()
OFF_SH          = SCRIPT_DIR / "off.sh"
START_SH        = SCRIPT_DIR / "start.sh"
TOGGLE_SH       = SCRIPT_DIR / "toggle_pqc.sh"
NRF_LOG         = Path("/var/log/open5gs/nrf.log")
SBI_PORT        = 7777          # Open5GS SBI HTTPS port
IFACE           = "lo"          # loopback — all NF-to-NF traffic

# NRF log marker: emitted once a NF completes TLS + HTTP/2 + NRF registration
NRF_REGISTERED_TOKEN = "NF registered"
UDM_ASSOCIATED_TOKEN = "UDM] NFInstance associated"

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

def parse_args():
    p = argparse.ArgumentParser(
        description="Benchmark NRF→UDM TLS handshake latency (hybrid vs classical)"
    )
    p.add_argument("--runs",   type=int,   default=20, help="Number of iterations per mode (default: 20)")
    p.add_argument("--mode",   choices=["hybrid", "classical", "both"], default="both",
                   help="TLS mode to benchmark (default: both)")
    p.add_argument("--delay",  type=float, default=5.0,  help="Netem base delay in ms (default: 5)")
    p.add_argument("--jitter", type=float, default=1.0,  help="Netem jitter in ms (default: 1)")
    p.add_argument("--loss",   type=float, default=0.1,  help="Netem packet loss %% (default: 0.1)")
    p.add_argument("--mtu",    type=int,   default=1500, help="Loopback MTU in bytes (default: 1500)")
    p.add_argument("--algo",   type=str,   default="rsa", help="Cert algo for toggle_pqc.sh (default: rsa)")
    p.add_argument("--output", type=str,   default="tls_handshake_results.csv",
                   help="CSV output file (default: tls_handshake_results.csv)")
    p.add_argument("--timeout", type=int,  default=60, help="Max seconds to wait per run (default: 60)")
    p.add_argument("--no-netem", action="store_true",
                   help="Skip network emulation (useful for baseline / debugging)")
    p.add_argument("--debug", action="store_true",
                   help="Print per-packet SNI discovery details and keep pcap files")
    return p.parse_args()


# ---------------------------------------------------------------------------
# Privilege check
# ---------------------------------------------------------------------------

def require_root():
    if os.geteuid() != 0:
        sys.exit("ERROR: This script must be run as root (sudo python3 tls_handshake_latency.py)")


# ---------------------------------------------------------------------------
# Network emulation helpers
# ---------------------------------------------------------------------------

def netem_setup(delay_ms, jitter_ms, loss_pct, mtu):
    print(f"  [netem] delay={delay_ms}ms jitter={jitter_ms}ms loss={loss_pct}% mtu={mtu}")
    subprocess.run(["tc", "qdisc", "del", "dev", IFACE, "root"],
                   capture_output=True)
    subprocess.run([
        "tc", "qdisc", "add", "dev", IFACE, "root", "netem",
        "delay", f"{delay_ms}ms", f"{jitter_ms}ms",
        "distribution", "normal",
        "loss", f"{loss_pct}%"
    ], check=True)
    subprocess.run(["ip", "link", "set", "dev", IFACE, "mtu", str(mtu)], check=True)
    subprocess.run(["ethtool", "-K", IFACE, "gro", "off", "lro", "off", "tso", "off"],
                   capture_output=True)


def netem_teardown():
    subprocess.run(["tc", "qdisc", "del", "dev", IFACE, "root"], capture_output=True)
    subprocess.run(["ip", "link", "set", "dev", IFACE, "mtu", "1500"], capture_output=True)
    subprocess.run(["ethtool", "-K", IFACE, "gro", "on", "lro", "on", "tso", "on"],
                   capture_output=True)


# ---------------------------------------------------------------------------
# Mode switching
# ---------------------------------------------------------------------------

def switch_mode(mode: str, algo: str):
    """Call toggle_pqc.sh then restart all NFs."""
    tls_mode = "pqc" if mode == "hybrid" else "classical"
    print(f"  [toggle] Switching to {mode} mode ({tls_mode} {algo})...")
    subprocess.run(["bash", str(TOGGLE_SH), tls_mode, algo], check=True)


def restart_nfs():
    print("  [nfs] Stopping all NFs...")
    subprocess.run(["bash", str(OFF_SH)], capture_output=True)
    time.sleep(2)
    print("  [nfs] Starting all NFs...")
    subprocess.run(["bash", str(START_SH)], capture_output=True)
    time.sleep(3)   # give NFs a moment to begin startup


# ---------------------------------------------------------------------------
# tcpdump capture
# ---------------------------------------------------------------------------

def start_tcpdump(pcap_path: str) -> subprocess.Popen:
    """
    Capture all TCP traffic on the Open5GS SBI ports on loopback.
    We use a SIMPLE port-only BPF filter (no complex byte-expression)
    and let Python do the TLS Client Hello / SNI filtering from the pcap.

    The complex BPF filter `tcp[((tcp[12:1] & 0xf0) >> 2):1] = 0x16` was
    dropped because:
      - On Linux loopback, the TCP data-offset calculation can be wrong
        when GRO/TSO offloads are active, causing the filter to miss packets.
      - It was also silently matching TLS AppData (0x17) on existing sessions
        that happened to have the same byte at a miscalculated offset.
    """
    # Capture on SBI port (7777) AND standard HTTPS (443) in case any NF uses it
    bpf_filter = f"tcp port {SBI_PORT} or tcp port 443"
    cmd = [
        "tcpdump",
        "-i", IFACE,
        "-w", pcap_path,
        "-s", "0",       # full snaplen — we need the entire packet for SNI
        "-B", "4096",    # 4 MB kernel buffer to avoid drops during NF burst
        bpf_filter,
    ]
    proc = subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    # Wait for tcpdump to open the interface before we start NFs
    # (tcpdump prints "listening on lo" to stderr once ready)
    deadline = time.monotonic() + 3.0
    while time.monotonic() < deadline:
        line = proc.stderr.readline()
        if b"listening on" in line:
            break
        if proc.poll() is not None:   # tcpdump crashed
            raise RuntimeError(f"tcpdump failed to start: {line.decode().strip()}")
    return proc


def stop_tcpdump(proc: subprocess.Popen):
    proc.send_signal(signal.SIGTERM)
    try:
        proc.wait(timeout=5)
    except subprocess.TimeoutExpired:
        proc.kill()


# ---------------------------------------------------------------------------
# TLS Client Hello SNI parser (pure Python, no scapy dependency)
# ---------------------------------------------------------------------------

def parse_sni_from_client_hello(data: bytes) -> str | None:
    """
    Parse a TLS ClientHello message and return the SNI value, or None.
    data: the raw TCP payload (starting at TLS record layer byte 0x16).
    """
    try:
        # TLS record header: 1 (type) + 2 (version) + 2 (length)
        if len(data) < 5 or data[0] != 0x16:
            return None
        record_len = struct.unpack("!H", data[3:5])[0]
        if len(data) < 5 + record_len:
            return None
        hs = data[5:]
        # Handshake header: 1 (type=0x01 ClientHello) + 3 (length)
        if hs[0] != 0x01:
            return None
        hs_len = struct.unpack("!I", b"\x00" + hs[1:4])[0]
        ch = hs[4:]
        if len(ch) < hs_len:
            return None

        # ClientHello body:
        # 2 (version) + 32 (random) + 1+N (session id) + 2+N (cipher suites) + 1+N (compression)
        pos = 2 + 32  # skip version + random
        if pos >= len(ch):
            return None
        sid_len = ch[pos]; pos += 1 + sid_len      # session id
        if pos + 2 > len(ch):
            return None
        cs_len = struct.unpack("!H", ch[pos:pos+2])[0]; pos += 2 + cs_len   # cipher suites
        if pos >= len(ch):
            return None
        cm_len = ch[pos]; pos += 1 + cm_len         # compression methods

        # Extensions
        if pos + 2 > len(ch):
            return None
        ext_total = struct.unpack("!H", ch[pos:pos+2])[0]; pos += 2
        end = pos + ext_total
        while pos + 4 <= end:
            ext_type = struct.unpack("!H", ch[pos:pos+2])[0]
            ext_len  = struct.unpack("!H", ch[pos+2:pos+4])[0]
            pos += 4
            if ext_type == 0x0000:  # SNI extension
                # server_name_list_length (2) + type (1) + name_length (2) + name
                if pos + 5 <= end:
                    name_len = struct.unpack("!H", ch[pos+3:pos+5])[0]
                    if pos + 5 + name_len <= end:
                        return ch[pos+5:pos+5+name_len].decode("ascii", errors="ignore")
                return None
            pos += ext_len
    except Exception:
        pass
    return None


# ---------------------------------------------------------------------------
# Pcap parser (reads libpcap global header + records manually)
# ---------------------------------------------------------------------------

PCAP_GLOBAL_HEADER_LEN = 24
PCAP_RECORD_HEADER_LEN = 16

def iter_pcap_records(pcap_path: str):
    """
    Yield (timestamp_float, raw_packet_bytes) for every record in a pcap file.
    Supports both little-endian and big-endian pcap.
    """
    with open(pcap_path, "rb") as f:
        raw = f.read()

    if len(raw) < PCAP_GLOBAL_HEADER_LEN:
        return

    magic = struct.unpack_from("<I", raw, 0)[0]
    if magic == 0xA1B2C3D4:
        endian = "<"
    elif magic == 0xD4C3B2A1:
        endian = ">"
    else:
        return  # unknown format

    link_type = struct.unpack_from(f"{endian}H", raw, 20)[0]
    pos = PCAP_GLOBAL_HEADER_LEN

    while pos + PCAP_RECORD_HEADER_LEN <= len(raw):
        ts_sec  = struct.unpack_from(f"{endian}I", raw, pos)[0]
        ts_usec = struct.unpack_from(f"{endian}I", raw, pos + 4)[0]
        inc_len = struct.unpack_from(f"{endian}I", raw, pos + 8)[0]
        pos += PCAP_RECORD_HEADER_LEN

        if pos + inc_len > len(raw):
            break

        pkt = raw[pos:pos + inc_len]
        pos += inc_len
        ts = ts_sec + ts_usec / 1e6
        yield ts, pkt, link_type


def extract_tcp_payload(pkt: bytes, link_type: int) -> bytes | None:
    """Extract raw TCP payload from a pcap packet, handling Ethernet and loopback (Linux cooked / null)."""
    try:
        if link_type == 1:    # Ethernet
            eth_type = struct.unpack_from("!H", pkt, 12)[0]
            if eth_type != 0x0800:  # only IPv4
                return None
            iph_start = 14
        elif link_type == 0:  # BSD loopback (null)
            af = struct.unpack_from("<I", pkt, 0)[0]
            if af != 2:       # AF_INET
                return None
            iph_start = 4
        elif link_type == 113:  # Linux cooked (SLL)
            proto = struct.unpack_from("!H", pkt, 14)[0]
            if proto != 0x0800:
                return None
            iph_start = 16
        else:
            iph_start = 0     # best-effort

        ihl = (pkt[iph_start] & 0x0F) * 4
        proto = pkt[iph_start + 9]
        if proto != 6:        # TCP
            return None
        tcp_start = iph_start + ihl
        data_offset = ((pkt[tcp_start + 12] >> 4) & 0xF) * 4
        payload_start = tcp_start + data_offset
        return pkt[payload_start:]
    except Exception:
        return None


def find_sni_timestamps(pcap_path: str, debug: bool = False) -> dict[str, float]:
    """
    Parse pcap and return a dict mapping SNI → first-seen timestamp (float seconds).
    Scans all TCP payloads for TLS records, searching for ClientHello (type 0x01)
    records even when they appear mid-stream (after TCP SYN/ACK overhead).
    """
    sni_times: dict[str, float] = {}
    total_pkts = 0
    tls_records_seen = 0

    for ts, pkt, link_type in iter_pcap_records(pcap_path):
        total_pkts += 1
        payload = extract_tcp_payload(pkt, link_type)
        if payload is None or len(payload) < 6:
            continue

        # A TLS record can start anywhere in the payload (TCP is a stream).
        # Scan the payload for a 0x16 (handshake) record header.
        # We look at every byte offset to handle TCP segment boundaries.
        data = payload
        offset = 0
        while offset < len(data):
            # Fast scan: find the next 0x16 byte
            idx = data.find(b'\x16', offset)
            if idx == -1:
                break
            candidate = data[idx:]
            if len(candidate) < 5:
                break
            # Validate TLS record version (byte 1-2 must be 0x0301..0x0304)
            ver_major = candidate[1]
            ver_minor = candidate[2]
            if ver_major == 0x03 and ver_minor in (0x01, 0x02, 0x03, 0x04):
                tls_records_seen += 1
                sni = parse_sni_from_client_hello(candidate)
                if sni:
                    if sni not in sni_times:
                        sni_times[sni] = ts
                        if debug:
                            print(f"      [pcap] Found SNI '{sni}' at ts={ts:.6f}")
            offset = idx + 1

    if debug:
        print(f"      [pcap] Scanned {total_pkts} packets, {tls_records_seen} TLS records, SNIs: {list(sni_times.keys())}")

    return sni_times


# ---------------------------------------------------------------------------
# Log-based fallback: parse NRF log for registration timestamps
# ---------------------------------------------------------------------------

def get_nrf_log_size() -> int:
    try:
        return NRF_LOG.stat().st_size
    except Exception:
        return 0


def wait_for_nrf_and_udm(start_offset: int, timeout: int) -> tuple[datetime | None, datetime | None]:
    """
    Tail NRF log from start_offset. Return (first_NF_registered_time, UDM_registered_time).
    Both as datetime objects parsed from the Open5GS log format: MM/DD HH:MM:SS.mmm
    Returns (None, None) on timeout.
    """
    first_nf_time  = None
    udm_time       = None
    deadline       = time.monotonic() + timeout
    current_year   = datetime.now().year

    with open(NRF_LOG, "rb") as f:
        f.seek(start_offset)
        buf = ""
        while time.monotonic() < deadline:
            chunk = f.read(4096).decode("utf-8", errors="replace")
            if chunk:
                buf += chunk
                lines = buf.split("\n")
                buf = lines[-1]
                for line in lines[:-1]:
                    dt = _parse_open5gs_ts(line, current_year)
                    if dt is None:
                        continue
                    if first_nf_time is None and NRF_REGISTERED_TOKEN in line:
                        first_nf_time = dt
                    if udm_time is None and UDM_ASSOCIATED_TOKEN in line:
                        udm_time = dt
                    if first_nf_time and udm_time:
                        return first_nf_time, udm_time
            else:
                time.sleep(0.05)

    return first_nf_time, udm_time


def _parse_open5gs_ts(line: str, year: int) -> datetime | None:
    """Parse Open5GS log timestamp: '03/19 01:45:36.541: ...' """
    try:
        ts_str = line.strip()[:21]  # e.g. '03/19 01:45:36.541: '
        dt = datetime.strptime(f"{year}/{ts_str}", "%Y/%m/%d %H:%M:%S.%f:")
        return dt
    except Exception:
        return None


# ---------------------------------------------------------------------------
# Single benchmark run
# ---------------------------------------------------------------------------

def run_once(mode: str, run_idx: int, timeout: int, debug: bool = False) -> dict | None:
    """
    Restart NFs, capture TLS Client Hello packets, return result dict or None on failure.
    """
    pcap_fd, pcap_path = tempfile.mkstemp(suffix=".pcap", prefix=f"tls_bench_{mode}_{run_idx}_")
    os.close(pcap_fd)
    tcpdump_proc = None

    try:
        # Record log offset BEFORE restarting NFs so we only read new lines
        log_offset = get_nrf_log_size()

        # ── IMPORTANT: tcpdump must be listening BEFORE NFs start ──
        # start_tcpdump() blocks until tcpdump prints "listening on lo",
        # so by the time restart_nfs() is called, we are guaranteed to
        # capture every packet from the very first SYN.
        tcpdump_proc = start_tcpdump(pcap_path)

        # Now (re)start the NFs — tcpdump is already listening
        restart_nfs()

        # Wait for NRF log confirmation (both first NF and UDM registered)
        nrf_t, udm_t = wait_for_nrf_and_udm(log_offset, timeout)

        # Extra window: let any stragglers arrive
        time.sleep(1)
        stop_tcpdump(tcpdump_proc)
        tcpdump_proc = None

        # Parse pcap for SNI timestamps
        sni_times = find_sni_timestamps(pcap_path, debug=debug)

        nrf_sni_ts  = sni_times.get("nrf.localdomain")
        udm_sni_ts  = sni_times.get("udm.localdomain")

        result = {
            "mode":           mode,
            "run":            run_idx,
            # pcap-based (most precise — actual packet timestamps)
            "nrf_sni_ts":     nrf_sni_ts,
            "udm_sni_ts":     udm_sni_ts,
            "delta_pcap_ms":  round((udm_sni_ts - nrf_sni_ts) * 1000, 3)
                              if (nrf_sni_ts and udm_sni_ts) else None,
            # log-based (fallback / cross-check)
            "nrf_log_t":      nrf_t.isoformat() if nrf_t else None,
            "udm_log_t":      udm_t.isoformat() if udm_t else None,
            "delta_log_ms":   round((udm_t - nrf_t).total_seconds() * 1000, 3)
                              if (nrf_t and udm_t) else None,
            # additional SNIs found
            "all_snis":       list(sni_times.keys()),
        }
        return result

    except Exception as e:
        print(f"    ERROR in run {run_idx}: {e}")
        import traceback; traceback.print_exc()
        return None
    finally:
        if tcpdump_proc is not None:
            stop_tcpdump(tcpdump_proc)
        try:
            if not debug:          # keep pcap for inspection when debugging
                os.unlink(pcap_path)
        except FileNotFoundError:
            pass


# ---------------------------------------------------------------------------
# Statistics helper
# ---------------------------------------------------------------------------

def print_stats(label: str, values: list[float]):
    if not values:
        print(f"  {label}: no valid measurements")
        return
    print(f"  {label}:")
    print(f"    n       = {len(values)}")
    print(f"    mean    = {mean(values):.2f} ms")
    print(f"    median  = {median(values):.2f} ms")
    print(f"    stdev   = {stdev(values):.2f} ms" if len(values) > 1 else f"    stdev   = N/A")
    print(f"    min     = {min(values):.2f} ms")
    print(f"    max     = {max(values):.2f} ms")


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    require_root()
    args = parse_args()

    modes_to_run = (
        ["hybrid", "classical"] if args.mode == "both" else [args.mode]
    )

    csv_path = Path(args.output)
    all_results = []

    print("=" * 60)
    print("  NRF → UDM TLS Handshake Latency Benchmark")
    print(f"  Modes : {', '.join(modes_to_run)}")
    print(f"  Runs  : {args.runs} per mode")
    print(f"  Netem : delay={args.delay}ms jitter={args.jitter}ms "
          f"loss={args.loss}% mtu={args.mtu}")
    print("=" * 60)

    for mode in modes_to_run:
        print(f"\n{'─'*60}")
        print(f"  MODE: {mode.upper()}")
        print(f"{'─'*60}")

        # 1. Switch TLS mode
        switch_mode(mode, args.algo)

        # 2. Apply network emulation
        if not args.no_netem:
            netem_setup(args.delay, args.jitter, args.loss, args.mtu)

        mode_results = []

        for i in range(1, args.runs + 1):
            print(f"\n  Run {i}/{args.runs}:")
            result = run_once(mode, i, args.timeout, debug=args.debug)

            if result is None:
                print(f"    ✗ Run failed (timeout or error)")
                all_results.append({
                    "mode": mode, "run": i,
                    "nrf_sni_ts": None, "udm_sni_ts": None,
                    "delta_pcap_ms": None, "nrf_log_t": None,
                    "udm_log_t": None, "delta_log_ms": None,
                    "all_snis": []
                })
                continue

            all_results.append(result)

            delta_pcap = result["delta_pcap_ms"]
            delta_log  = result["delta_log_ms"]

            if delta_pcap is not None:
                print(f"    ✓ pcap delta (NRF→UDM Client Hello) : {delta_pcap:.1f} ms")
            else:
                print(f"    ✗ pcap: could not find both SNIs — found: {result['all_snis']}")

            if delta_log is not None:
                print(f"    ✓ log  delta (NRF reg → UDM assoc)  : {delta_log:.1f} ms")

            if delta_pcap is not None:
                mode_results.append(delta_pcap)

            # short cooldown
            time.sleep(1)

        print(f"\n  ── {mode.upper()} SUMMARY ──")
        print_stats(f"pcap delta (NRF→UDM Client Hello)", mode_results)

        # Teardown netem between modes
        if not args.no_netem:
            netem_teardown()

    # -----------------------------------------------------------------------
    # Write CSV
    # -----------------------------------------------------------------------
    fieldnames = [
        "mode", "run", "delta_pcap_ms", "delta_log_ms",
        "nrf_sni_ts", "udm_sni_ts", "nrf_log_t", "udm_log_t", "all_snis"
    ]
    with open(csv_path, "w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        writer.writeheader()
        for r in all_results:
            writer.writerow({k: r.get(k, "") for k in fieldnames})

    print(f"\n{'='*60}")
    print(f"  Results saved → {csv_path}")
    print(f"{'='*60}")

    # -----------------------------------------------------------------------
    # Cross-mode delta summary
    # -----------------------------------------------------------------------
    if args.mode == "both":
        hybrid_vals     = [r["delta_pcap_ms"] for r in all_results
                           if r["mode"] == "hybrid" and r["delta_pcap_ms"] is not None]
        classical_vals  = [r["delta_pcap_ms"] for r in all_results
                           if r["mode"] == "classical" and r["delta_pcap_ms"] is not None]

        print("\n  ── COMPARISON ──")
        print_stats("Hybrid    (X25519MLKEM768)", hybrid_vals)
        print_stats("Classical (X25519)", classical_vals)

        if hybrid_vals and classical_vals:
            diff = mean(hybrid_vals) - mean(classical_vals)
            pct  = (diff / mean(classical_vals)) * 100 if mean(classical_vals) != 0 else 0
            sign = "+" if diff >= 0 else ""
            print(f"\n  Hybrid overhead vs Classical:")
            print(f"    mean delta = {sign}{diff:.2f} ms ({sign}{pct:.1f}%)")

    # Restore NFs to a running state
    print("\n  [cleanup] Restarting NFs in final mode...")
    subprocess.run(["bash", str(START_SH)], capture_output=True)
    if not args.no_netem:
        netem_teardown()

    print("  Done.")


if __name__ == "__main__":
    main()
