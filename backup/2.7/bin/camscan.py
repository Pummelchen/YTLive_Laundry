#!/usr/bin/env python3
"""Discover CCTV cameras on the LAN: WS-Discovery (ONVIF) + TCP port sweep.

WS-Discovery lives in find_cam.py and is loaded from there. camscan used to carry its own copy
of the same SOAP probe, so a fix to one would silently miss the other; the TCP port sweep is
camscan's own value and stays here.

  camscan.py             sweep 192.168.1.0/24 (the default)
  camscan.py CIDR        sweep a different network
"""
import importlib.util, ipaddress, pathlib, socket, sys, concurrent.futures as cf

USAGE = "usage: camscan.py [CIDR]    e.g. camscan.py 192.168.1.0/24"

# Ports commonly exposed by Chinese IP cameras / NVRs
PORTS = {
    80:   "http (web UI)",
    443:  "https",
    554:  "RTSP",
    8000: "Hikvision SDK",
    8080: "http-alt",
    8554: "RTSP-alt",
    8899: "XiongMai/generic",
    34567:"XiongMai/XMEye (dvrip)",
    37777:"Dahua SDK",
    2020: "ONVIF-alt",
}

def _find_cam():
    """Load find_cam.py from beside this script, the way cam_ip.py loads it. Deferred into the
    call path so importing camscan does no I/O."""
    here = pathlib.Path(__file__).resolve().parent
    spec = importlib.util.spec_from_file_location("find_cam", here / "find_cam.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod

def ws_discover(timeout=4):
    """ONVIF WS-Discovery, delegated to find_cam.py so exactly one implementation exists."""
    return _find_cam().discover_replies(timeout)

def probe(ip, port, timeout=0.6):
    try:
        with socket.create_connection((str(ip), port), timeout=timeout):
            return True
    except Exception:
        return False

def sweep(cidr):
    net = ipaddress.ip_network(cidr, strict=False)
    hosts = [h for h in net.hosts()]
    jobs = [(h, p) for h in hosts for p in PORTS]
    hits = {}
    with cf.ThreadPoolExecutor(max_workers=400) as ex:
        futs = {ex.submit(probe, h, p): (h, p) for h, p in jobs}
        for f in cf.as_completed(futs):
            h, p = futs[f]
            try:
                if f.result():
                    hits.setdefault(str(h), []).append(p)
            except Exception:
                pass
    return hits

def usage_error(msg=None):
    if msg:
        print(f"camscan.py: {msg}", file=sys.stderr)
    print(USAGE, file=sys.stderr)
    return 2

def main(argv):
    if len(argv) > 2:
        return usage_error(f"unexpected argument: {argv[2]}")
    cidr = argv[1] if len(argv) > 1 else "192.168.1.0/24"
    try:
        # Validate before any socket work: a typo used to surface as a ValueError traceback from
        # deep inside sweep(), after a 4 s multicast wait.
        ipaddress.ip_network(cidr, strict=False)
    except ValueError as e:
        return usage_error(str(e))

    print("== ONVIF WS-Discovery ==")
    d = ws_discover()
    if d:
        import re
        for ip, xml in d.items():
            urls = re.findall(r'https?://[^\s<>"]+', xml)
            print(f"  {ip}")
            for u in dict.fromkeys(urls):
                print(f"     -> {u}")
    else:
        print("  (no ONVIF replies)")

    print(f"\n== TCP sweep {cidr} ==")
    hits = sweep(cidr)
    if not hits:
        print("  (nothing open)")
    for ip in sorted(hits, key=lambda x: tuple(map(int, x.split('.')))):
        ps = sorted(hits[ip])
        print(f"  {ip}")
        for p in ps:
            print(f"     {p:<6} {PORTS[p]}")
    return 0

if __name__ == "__main__":
    sys.exit(main(sys.argv))
