#!/usr/bin/env python3
"""Every 10 minutes: is the camera reachable on Wi-Fi, on the USB LAN, on neither?

WHY THIS IS SEPARATE FROM stream.sh
    stream.sh already probes harder than this while it is running (every 30 s, and it sweeps
    when ONVIF is silent). But it is one process: if it is wedged, restarting, or simply not
    started yet, nobody is looking for the camera - and the 9:16 feed waits on
    log/cam_ip for its cue. This scanner is a second, independent pair of eyes on a fixed
    600 s cadence, owned by launchd rather than by the streamer.

WHAT IT DOES NOT DO
    It never starts, stops or restarts anything. It answers one question - "where is the
    camera, if anywhere" - writes the answer where both feeds already look (log/cam_ip),
    and leaves the acting to them. A finder that also restarts encoders is a second
    controller, and two controllers fighting over one camera is how this box used to flap.

OUTPUT
    stdout   one JSON object (used by tests and by anything that wants to parse it)
    log/cam_scan.log          one human line per run, both interfaces named
    log/cam_scan.heartbeat    epoch, so status.sh and the off-host watchdog can see it is alive
    log/cam_ip                written ONLY when the camera was actually found
    log/cam_found.json        {"ip", "iface", "method", "epoch"} for status.sh

Exit: 0 found, 1 not found, 2 usage/config error.
"""
import concurrent.futures as cf
import ipaddress
import json
import os
import pathlib
import re
import socket
import subprocess
import sys
import time
import uuid

BASE = pathlib.Path(__file__).resolve().parent.parent
LOG = BASE / "log" / "cam_scan.log"
BEAT = BASE / "log" / "cam_scan.heartbeat"
CAMIP = BASE / "log" / "cam_ip"
FOUND = BASE / "log" / "cam_found.json"
RTSP_PORT = 554
ONVIF_PORT = 8899
PROBE_TIMEOUT = 0.6


def local_addrs():
    """[(iface, ip)] for every IPv4 address on a private LAN, in service order.

    ifconfig, not socket.gethostbyname: this box has en0 (Wi-Fi) and en2 (USB LAN) on the
    SAME 192.168.1.0/24. They are separate segments - devices on one are invisible to the
    other - so the scanner has to try each source address explicitly. An unbound sweep
    silently reports "no camera" while the camera is answering on the other segment.
    """
    # Absolute path: launchd runs with PATH=/usr/bin:/bin, and `ifconfig` lives in /sbin.
    # With a bare name the subprocess raised FileNotFoundError, the scanner silently reported
    # "interfaces: []", and a camera that WAS present would have been reported missing.
    ifconfig = "/sbin/ifconfig" if os.path.exists("/sbin/ifconfig") else "ifconfig"
    try:
        out = subprocess.run([ifconfig], capture_output=True, text=True, timeout=10).stdout
    except Exception:
        return []
    addrs, iface = [], ""
    for line in out.splitlines():
        m = re.match(r"^([a-z0-9]+):", line)
        if m:
            iface = m.group(1)
            continue
        m = re.search(r"\binet (\d+\.\d+\.\d+\.\d+)", line)
        if m and not line.strip().startswith("inet6"):
            ip = m.group(1)
            if re.match(r"^(10\.|192\.168\.|172\.(1[6-9]|2\d|3[01])\.)", ip):
                addrs.append((iface, ip))
    return addrs


def onvif_probe(src, timeout=4.0):
    """WS-Discovery single probe, bound to one interface. Returns the reply addresses."""
    msg = (
        '<?xml version="1.0" encoding="UTF-8"?>'
        '<e:Envelope xmlns:e="http://www.w3.org/2003/05/soap-envelope" '
        'xmlns:w="http://schemas.xmlsoap.org/ws/2004/08/addressing" '
        'xmlns:d="http://schemas.xmlsoap.org/ws/2005/04/discovery" '
        'xmlns:dn="http://www.onvif.org/ver10/network/wsdl">'
        '<e:Header><w:MessageID>uuid:' + str(uuid.uuid4()) + '</w:MessageID>'
        '<w:To e:mustUnderstand="true">urn:schemas-xmlsoap-org:ws:2005:04:discovery</w:To>'
        '<w:Action e:mustUnderstand="true">'
        'http://schemas.xmlsoap.org/ws/2005/04/discovery/Probe</w:Action></e:Header>'
        '<e:Body><d:Probe><d:Types>dn:NetworkVideoTransmitter</d:Types></d:Probe>'
        '</e:Body></e:Envelope>'
    ).encode()
    seen = set()
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP)
        s.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_TTL, 2)
        s.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_IF, socket.inet_aton(src))
        s.bind((src, 0))
        s.settimeout(timeout)
        s.sendto(msg, ("239.255.255.250", 3702))
        deadline = time.time() + timeout
        while time.time() < deadline:
            try:
                _, addr = s.recvfrom(65535)
                if addr[0] != src:
                    seen.add(addr[0])
            except socket.timeout:
                break
        s.close()
    except Exception:
        pass
    return sorted(seen, key=lambda x: tuple(int(p) for p in x.split(".")))


def tcp_open(ip, port, src, timeout=PROBE_TIMEOUT):
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.settimeout(timeout)
    try:
        s.bind((src, 0))
        s.connect((ip, port))
        return True
    except Exception:
        return False
    finally:
        s.close()


def sweep(src, ports=(RTSP_PORT, ONVIF_PORT), skip=()):
    net = ipaddress.ip_network(f"{src}/24", strict=False)
    # Skip ALL of this Mac's addresses, not just the one we send from: this host listens on
    # 192.168.1.7 and has 192.168.1.2 on the other segment, and a port-554 listener on either
    # would otherwise be reported as "the camera".
    skip = set(skip) | {src}
    hosts = [str(h) for h in net.hosts() if str(h) not in skip]
    hits = {p: [] for p in ports}
    with cf.ThreadPoolExecutor(max_workers=256) as ex:
        futs = {ex.submit(tcp_open, h, p, src): (h, p) for h in hosts for p in ports}
        for f in cf.as_completed(futs):
            try:
                if f.result():
                    h, p = futs[f]
                    hits[p].append(h)
            except Exception:
                pass
    for p in hits:
        hits[p].sort(key=lambda x: tuple(int(q) for q in x.split(".")))
    return hits


def scan():
    addrs = local_addrs()
    report = {"at": time.strftime("%Y-%m-%d %H:%M:%S"), "interfaces": [],
              "found": None, "ip": None, "iface": None, "method": None}
    all_local = [ip for _, ip in addrs]
    for iface, src in addrs:
        entry = {"iface": iface, "src": src, "onvif": [], "onvif_hosts": [],
                 "rtsp": [], "onvif_port": []}
        entry["onvif_hosts"] = onvif_probe(src)
        hits = sweep(src, skip=all_local)
        entry["rtsp"] = hits[RTSP_PORT]
        entry["onvif_port"] = hits[ONVIF_PORT]
        report["interfaces"].append(entry)

    # Preference order: a device that ANNOUNCED itself over ONVIF, then one answering on the
    # ONVIF port, then a bare RTSP responder (some cameras have discovery disabled).
    for method, key in (("onvif-discovery", "onvif_hosts"),
                        ("onvif-port", "onvif_port"),
                        ("rtsp-port", "rtsp")):
        for e in report["interfaces"]:
            if e[key]:
                report.update(found=True, ip=e[key][0], iface=e["iface"], method=method)
                return report
    report["found"] = False
    return report


def describe(r):
    parts = []
    for e in r["interfaces"]:
        bits = []
        if e["onvif_hosts"]:
            bits.append("ONVIF " + ",".join(e["onvif_hosts"]))
        if e["onvif_port"]:
            bits.append(f":{ONVIF_PORT} " + ",".join(e["onvif_port"]))
        if e["rtsp"]:
            bits.append(f":{RTSP_PORT} " + ",".join(e["rtsp"]))
        parts.append(f"{e['iface']}({e['src']}): " + ("; ".join(bits) if bits else "nothing"))
    tail = (f"-> CAMERA {r['ip']} via {r['iface']}/{r['method']}" if r["found"]
            else "-> no camera on any interface")
    return " | ".join(parts) + " " + tail


def self_test():
    """Exercise the decision and the persistence path with a synthetic LAN.

    A negative scan only proves the absence of a camera; it never touches the code that
    decides WHICH interface won, or that writes cam_ip. This does, in a scratch directory,
    so the live log/cam_ip is untouched.
    """
    global local_addrs, onvif_probe, sweep, LOG, BEAT, CAMIP, FOUND
    import tempfile
    old = (local_addrs, onvif_probe, sweep, LOG, BEAT, CAMIP, FOUND)
    tmp = pathlib.Path(tempfile.mkdtemp(prefix="camscan-selftest."))
    try:
        LOG, BEAT = tmp / "cam_scan.log", tmp / "cam_scan.heartbeat"
        CAMIP, FOUND = tmp / "cam_ip", tmp / "cam_found.json"
        local_addrs = lambda: [("en0", "192.168.1.7"), ("en2", "192.168.1.2")]
        onvif_probe = lambda src, timeout=4.0: (["192.168.1.3"] if src == "192.168.1.2" else [])
        sweep = lambda src, ports=(RTSP_PORT, ONVIF_PORT), skip=(): {p: [] for p in ports}
        rc = main([])
        found = json.loads(FOUND.read_text()) if FOUND.exists() else {}
        assert rc == 0, f"exit {rc} for a found camera"
        assert found.get("ip") == "192.168.1.3", found
        assert found.get("iface") == "en2", found
        assert found.get("method") == "onvif-discovery", found
        assert CAMIP.read_text().strip() == "192.168.1.3", CAMIP.read_text()
        line = LOG.read_text().strip()
        assert "en0(192.168.1.7): nothing" in line, line
        assert "en2(192.168.1.2): ONVIF 192.168.1.3" in line, line
        assert "CAMERA 192.168.1.3 via en2/onvif-discovery" in line, line
        print("SELFTEST OK :: " + line)
        return 0
    finally:
        local_addrs, onvif_probe, sweep, LOG, BEAT, CAMIP, FOUND = old
        import shutil
        shutil.rmtree(tmp, ignore_errors=True)


def main(argv):
    if "--self-test" in argv:
        return self_test()
    if "--ifconfig" in argv:
        print(json.dumps(local_addrs()))
        return 0
    r = scan()
    line = f"{r['at']} SCAN {describe(r)}"
    try:
        LOG.parent.mkdir(parents=True, exist_ok=True)
        with LOG.open("a") as fh:
            fh.write(line + "\n")
        BEAT.write_text(str(int(time.time())))
    except Exception:
        pass
    if r["found"]:
        try:
            CAMIP.write_text(r["ip"] + "\n")
            FOUND.write_text(json.dumps({"ip": r["ip"], "iface": r["iface"],
                                         "method": r["method"],
                                         "epoch": int(time.time())}, indent=2) + "\n")
        except Exception:
            pass
    print(json.dumps(r))
    return 0 if r["found"] else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
