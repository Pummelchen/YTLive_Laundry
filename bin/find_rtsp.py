#!/usr/bin/env python3
"""Last-resort camera finder: sweep the LAN for a host with RTSP (or ONVIF) open.

Why this exists: ONVIF WS-Discovery is multicast, and multicast is exactly what a flaky AP,
a cheap PoE switch or the camera's own firmware drops first. The 2026-10-28 outage showed the
other failure mode too - the camera is DHCP and moves address after a power cut, so "the
configured IP does not answer" is not the same as "the camera is gone". find_cam.py answers
"did the camera announce itself"; this answers "is anything on this LAN speaking RTSP", which
a plain TCP connect cannot be blocked from doing.

Prints the first candidate IP and exits 0, or prints nothing and exits 1.
The local machine's own addresses are excluded (the Mac is not a camera).
"""
import concurrent.futures as cf
import ipaddress
import re
import socket
import subprocess
import sys

PORTS = (554, 8899)          # RTSP first, then the XiongMai/Hikvision ONVIF port


def local_ips():
    try:
        out = subprocess.run(["ifconfig"], capture_output=True, text=True, timeout=10).stdout
    except Exception:
        return set()
    return set(re.findall(r"inet (192\.\d+\.\d+\.\d+)", out))


def probe(ip, port, timeout=0.6, src=None):
    """Connect, optionally FROM a given local address.

    Binding the source matters on this Mac: en0 (Wi-Fi, 192.168.1.7) and en2 (wired,
    192.168.1.2) sit on the SAME /24 but are separate segments. Devices visible only on the
    wired side answer `ping -b en2` and nothing at all through the default route, so an
    unbound sweep silently reports "no camera" while the camera is sitting right there.
    """
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.settimeout(timeout)
    try:
        if src:
            s.bind((src, 0))
        s.connect((ip, int(port)))
        return True
    except Exception:
        return False
    finally:
        s.close()


def main(cidr):
    try:
        net = ipaddress.ip_network(cidr, strict=False)
    except ValueError as e:
        print(f"find_rtsp.py: {e}", file=sys.stderr)
        return 2
    sources = sorted(local_ips())          # sweep from EACH interface, not just the default
    hosts = [str(h) for h in net.hosts() if str(h) not in set(sources)]
    hits = []
    with cf.ThreadPoolExecutor(max_workers=256) as ex:
        futs = {}
        for src in (sources or [None]):
            for h in hosts:
                for p in PORTS:
                    futs[ex.submit(probe, h, p, 0.6, src)] = (h, p)
        for f in cf.as_completed(futs):
            try:
                if f.result():
                    hits.append(futs[f])
            except Exception:
                pass
    if not hits:
        return 1
    # Prefer a host that speaks RTSP; then the lowest address, so the answer is deterministic.
    hits.sort(key=lambda hp: (hp[1], tuple(int(x) for x in hp[0].split("."))))
    print(hits[0][0])
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else "192.168.1.0/24"))
