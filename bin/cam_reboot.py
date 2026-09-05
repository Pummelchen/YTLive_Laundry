#!/usr/bin/env python3
"""Reboot the ONVIF camera. Usage: cam_reboot.py [HOST] [PORT] [USER] [PASS]"""
import sys, urllib.request, hashlib, base64, os, datetime
host = sys.argv[1] if len(sys.argv)>1 else "192.168.1.2"
port = sys.argv[2] if len(sys.argv)>2 else "8899"
user = sys.argv[3] if len(sys.argv)>3 else ""
pw   = sys.argv[4] if len(sys.argv)>4 else ""
def wsse():
    if not user: return ""
    n=os.urandom(16); c=datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    d=base64.b64encode(hashlib.sha1(n+c.encode()+pw.encode()).digest()).decode()
    return (f'<s:Header><Security s:mustUnderstand="1" xmlns="http://docs.oasis-open.org/wss/2004/01/'
            f'oasis-200401-wss-wssecurity-secext-1.0.xsd"><UsernameToken><Username>{user}</Username>'
            f'<Password Type="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-username-token-profile-1.0#PasswordDigest">{d}</Password>'
            f'<Nonce EncodingType="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-soap-message-security-1.0#Base64Binary">{base64.b64encode(n).decode()}</Nonce>'
            f'<Created xmlns="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-utility-1.0.xsd">{c}</Created>'
            f'</UsernameToken></Security></s:Header>')
url=f"http://{host}:{port}/onvif/device_service"
env=(f'<s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope">{wsse()}'
     f'<s:Body xmlns:tds="http://www.onvif.org/ver10/device/wsdl"><tds:SystemReboot/></s:Body></s:Envelope>')
req=urllib.request.Request(url, data=env.encode(),
    headers={"Content-Type":'application/soap+xml; charset=utf-8; action="http://www.onvif.org/ver10/device/wsdl/SystemReboot"'})
try:
    r=urllib.request.urlopen(req, timeout=10).read().decode("utf-8","replace")
    print("reboot accepted:", "RebootResponse" in r or r[:200])
except Exception as e:
    body = e.read().decode('utf-8','replace')[:300] if hasattr(e,'read') else ''
    print("ERROR:", e); print(body)
