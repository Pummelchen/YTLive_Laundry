#!/usr/bin/env python3
"""Minimal ONVIF client (stdlib only) -> device info + RTSP stream URIs.
Usage: onvif_probe.py HOST [PORT] [USER] [PASS]"""
import sys, urllib.request, re, hashlib, base64, os, datetime

host = sys.argv[1]
port = sys.argv[2] if len(sys.argv) > 2 else "8899"
user = sys.argv[3] if len(sys.argv) > 3 else ""
pw   = sys.argv[4] if len(sys.argv) > 4 else ""
DEV  = f"http://{host}:{port}/onvif/device_service"
MEDIA= f"http://{host}:{port}/onvif/media_service"

def wsse():
    if not user:
        return ""
    nonce = os.urandom(16)
    created = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    digest = base64.b64encode(hashlib.sha1(nonce + created.encode() + pw.encode()).digest()).decode()
    n64 = base64.b64encode(nonce).decode()
    return f'''<s:Header><Security s:mustUnderstand="1" xmlns="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-secext-1.0.xsd">
<UsernameToken><Username>{user}</Username>
<Password Type="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-username-token-profile-1.0#PasswordDigest">{digest}</Password>
<Nonce EncodingType="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-soap-message-security-1.0#Base64Binary">{n64}</Nonce>
<Created xmlns="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-utility-1.0.xsd">{created}</Created>
</UsernameToken></Security></s:Header>'''

def call(url, action, body):
    env = f'''<s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope">{wsse()}<s:Body xmlns:trt="http://www.onvif.org/ver10/media/wsdl" xmlns:tds="http://www.onvif.org/ver10/device/wsdl">{body}</s:Body></s:Envelope>'''
    req = urllib.request.Request(url, data=env.encode(),
          headers={"Content-Type": f'application/soap+xml; charset=utf-8; action="{action}"'})
    try:
        return urllib.request.urlopen(req, timeout=6).read().decode("utf-8","replace")
    except Exception as e:
        return f"__ERR__ {e}\n" + (e.read().decode('utf-8','replace') if hasattr(e,'read') else '')

def tag(xml, name):
    return re.findall(rf'<[^>]*{name}[^>]*>(.*?)</[^>]*{name}>', xml, re.S)

print(f"== Device {DEV} ==")
r = call(DEV, "http://www.onvif.org/ver10/device/wsdl/GetDeviceInformation",
         "<tds:GetDeviceInformation/>")
for f in ("Manufacturer","Model","FirmwareVersion","SerialNumber","HardwareId"):
    v = tag(r, f)
    if v: print(f"  {f}: {v[0]}")
if "__ERR__" in r: print("  "+r.splitlines()[0])

print("\n== Profiles ==")
r = call(MEDIA, "http://www.onvif.org/ver10/media/wsdl/GetProfiles", "<trt:GetProfiles/>")
tokens = re.findall(r'token="([^"]+)"', r)
tokens = list(dict.fromkeys(tokens))
if not tokens and "__ERR__" in r:
    print("  "+r.splitlines()[0]); print("  (auth may be required: pass USER PASS)")
for t in tokens:
    print(f"\n  profile token: {t}")
    rr = call(MEDIA, "http://www.onvif.org/ver10/media/wsdl/GetStreamUri",
      f'''<trt:GetStreamUri><trt:StreamSetup><Stream xmlns="http://www.onvif.org/ver10/schema">RTP-Unicast</Stream>
<Transport xmlns="http://www.onvif.org/ver10/schema"><Protocol>RTSP</Protocol></Transport></trt:StreamSetup>
<trt:ProfileToken>{t}</trt:ProfileToken></trt:GetStreamUri>''')
    uri = tag(rr, "Uri")
    print(f"     RTSP: {uri[0] if uri else '(none / auth required)'}")
