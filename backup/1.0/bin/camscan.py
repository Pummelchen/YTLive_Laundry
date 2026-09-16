#!/usr/bin/env python3
"""Discover CCTV cameras on the LAN: WS-Discovery (ONVIF) + TCP port sweep."""
import socket, struct, sys, uuid, ipaddress, concurrent.futures as cf

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

def ws_discover(timeout=4):
    """ONVIF WS-Discovery probe over UDP multicast 239.255.255.250:3702."""
    msg = f'''<?xml version="1.0" encoding="UTF-8"?>
<e:Envelope xmlns:e="http://www.w3.org/2003/05/soap-envelope"
 xmlns:w="http://schemas.xmlsoap.org/ws/2004/08/addressing"
 xmlns:d="http://schemas.xmlsoap.org/ws/2005/04/discovery"
 xmlns:dn="http://www.onvif.org/ver10/network/wsdl">
 <e:Header>
  <w:MessageID>uuid:{uuid.uuid4()}</w:MessageID>
  <w:To e:mustUnderstand="true">urn:schemas-xmlsoap-org:ws:2005:04:discovery</w:To>
  <w:Action e:mustUnderstand="true">http://schemas.xmlsoap.org/ws/2005/04/discovery/Probe</w:Action>
 </e:Header>
 <e:Body><d:Probe><d:Types>dn:NetworkVideoTransmitter</d:Types></d:Probe></e:Body>
</e:Envelope>'''.encode()
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_TTL, 4)
    s.settimeout(timeout)
    found = {}
    try:
        s.sendto(msg, ("239.255.255.250", 3702))
        while True:
            try:
                data, addr = s.recvfrom(65535)
            except socket.timeout:
                break
            found.setdefault(addr[0], data.decode("utf-8", "replace"))
    finally:
        s.close()
    return found

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

if __name__ == "__main__":
    cidr = sys.argv[1] if len(sys.argv) > 1 else "192.168.1.0/24"
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
