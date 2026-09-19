#!/usr/bin/env python3
"""Print the camera's current IP, found via ONVIF WS-Discovery. Empty if not found.
The camera is DHCP and its firmware ignores ONVIF config writes, so its address can
change after any power cut. Discovery is more reliable than a hard-coded IP.

This is the ONE WS-Discovery implementation: cam_ip.py and camscan.py both load it by
path instead of carrying a second copy of the probe."""
import socket, uuid, re, sys

def discover_replies(timeout=4):
    """Raw WS-Discovery replies as {ip: xml}. camscan.py prints the URLs inside the reply, so
    the socket work lives here and discover() filters this down to just the addresses."""
    msg = f'''<?xml version="1.0" encoding="UTF-8"?>
<e:Envelope xmlns:e="http://www.w3.org/2003/05/soap-envelope"
 xmlns:w="http://schemas.xmlsoap.org/ws/2004/08/addressing"
 xmlns:d="http://schemas.xmlsoap.org/ws/2005/04/discovery"
 xmlns:dn="http://www.onvif.org/ver10/network/wsdl">
 <e:Header><w:MessageID>uuid:{uuid.uuid4()}</w:MessageID>
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

def discover(timeout=4):
    """Addresses whose reply identifies an ONVIF device, in the order they answered."""
    return [ip for ip, xml in discover_replies(timeout).items()
            if "NetworkVideoTransmitter" in xml or "device_service" in xml]

def reachable(ip, port=554, t=2):
    try:
        with socket.create_connection((ip, port), timeout=t): return True
    except Exception: return False

if __name__ == "__main__":
    for ip in discover():
        if reachable(ip):
            print(ip); sys.exit(0)
    sys.exit(1)
