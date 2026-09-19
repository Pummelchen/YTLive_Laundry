#!/usr/bin/env python3
"""Reboot the ONVIF camera. Usage: cam_reboot.py [HOST] [PORT] [USER] [PASS]

Everything runs inside main(): this module used to do its work at import time, so merely
importing it - from a REPL, a test, or another tool that loads bin/*.py - rebooted the
camera. Discovery is also deferred, because resolving the address hits the network.
USER/PASS are accepted on argv for operator convenience, but argv is world-readable
through ps, so CAM_USER/CAM_PASS are preferred and win when they are set.
"""
import base64
import datetime
import hashlib
import importlib.util
import os
import pathlib
import sys
import urllib.request


def _load_cam_ip(base):
    spec = importlib.util.spec_from_file_location("cam_ip", base / "bin/cam_ip.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def wsse(user, pw):
    if not user:
        return ""
    n = os.urandom(16)
    c = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    d = base64.b64encode(hashlib.sha1(n + c.encode() + pw.encode()).digest()).decode()
    return (f'<s:Header><Security s:mustUnderstand="1" xmlns="http://docs.oasis-open.org/wss/2004/01/'
            f'oasis-200401-wss-wssecurity-secext-1.0.xsd"><UsernameToken><Username>{user}</Username>'
            f'<Password Type="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-username-token-profile-1.0#PasswordDigest">{d}</Password>'
            f'<Nonce EncodingType="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-soap-message-security-1.0#Base64Binary">{base64.b64encode(n).decode()}</Nonce>'
            f'<Created xmlns="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-utility-1.0.xsd">{c}</Created>'
            f'</UsernameToken></Security></s:Header>')


def reboot(host, port, user, pw):
    url = f"http://{host}:{port}/onvif/device_service"
    env = (f'<s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope">{wsse(user, pw)}'
           f'<s:Body xmlns:tds="http://www.onvif.org/ver10/device/wsdl"><tds:SystemReboot/></s:Body></s:Envelope>')
    req = urllib.request.Request(
        url, data=env.encode(),
        headers={"Content-Type": 'application/soap+xml; charset=utf-8; '
                                 'action="http://www.onvif.org/ver10/device/wsdl/SystemReboot"'})
    try:
        r = urllib.request.urlopen(req, timeout=10).read().decode("utf-8", "replace")
        print("reboot accepted:", "RebootResponse" in r or r[:200])
        return 0
    except Exception as e:
        body = e.read().decode("utf-8", "replace")[:300] if hasattr(e, "read") else ""
        print("ERROR:", e)
        print(body)
        return 1


USAGE = "usage: cam_reboot.py [HOST] [PORT] [USER] [PASS]   (credentials: prefer CAM_USER/CAM_PASS)"
ARGV_CRED_WARNING = ("warning: USER/PASS on argv are world-readable in ps;"
                     " prefer CAM_USER/CAM_PASS")


def credentials(argv, env):
    """(user, pw, on_argv). CAM_USER/CAM_PASS are preferred; the positional form still works for
    compatibility but is visible in ps, so main() warns when it is used."""
    on_argv = len(argv) > 3
    user = env.get("CAM_USER") or (argv[3] if len(argv) > 3 else "")
    pw = env.get("CAM_PASS") or (argv[4] if len(argv) > 4 else "")
    return user, pw, on_argv


def main(argv):
    base = pathlib.Path(os.environ.get("BASE", str(pathlib.Path(__file__).resolve().parent.parent)))
    if len(argv) > 5:
        print(USAGE, file=sys.stderr)
        return 2
    if len(argv) > 1:
        host = argv[1]
    else:
        found = _load_cam_ip(base).resolve(need_onvif=True)[0]
        if not found:
            print("camera not found", file=sys.stderr)
            return 1
        host = found
    port = argv[2] if len(argv) > 2 else "8899"
    user, pw, on_argv = credentials(argv, os.environ)
    if on_argv:
        print(ARGV_CRED_WARNING, file=sys.stderr)
    return reboot(host, port, user, pw)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
