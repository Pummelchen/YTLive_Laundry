#!/usr/bin/env python3
"""Read/set the ONVIF video encoder config on the camera.

  cam_config.py get
  cam_config.py set <token> <fps> <bitrate_kbps> <quality> <govlength>
  cam_config.py bitrate <token> <kbps>     change ONLY the bitrate, keep everything else

The address is resolved, never hardcoded - see cam_ip.py. This file used to hold
192.168.1.2, which stopped being the camera on 2026-08-31 and had become this Mac's own
LAN port, so `set` would have been writing to the wrong device entirely.

Everything runs inside main(): resolving the address hits the network and can fail, so merely
importing this module - a REPL, a test, another tool that loads bin/*.py - must do neither.
That is the same import-time bug class cam_reboot.py had; see its docstring.
"""
import os, pathlib, urllib.request, re, sys, importlib.util

USAGE = ("usage: cam_config.py get"
         " | cam_config.py set <token> <fps> <bitrate_kbps> <quality> <govlength>"
         " | cam_config.py bitrate <token> <kbps>")

BASE = pathlib.Path(os.environ.get("BASE", str(pathlib.Path(__file__).resolve().parent.parent)))
PORT = os.environ.get("CAM_ONVIF_PORT", "8899")
MEDIA = ""   # set by main() once the camera answers; call() reads it


def _resolve_media(base):
    """Load cam_ip.py by path and resolve the address. Called only from main(): the load is
    cheap, resolve() is the part that probes the network."""
    spec = importlib.util.spec_from_file_location("cam_ip", base / "bin/cam_ip.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    host, how = mod.resolve(need_onvif=True)
    if not host:
        print(f"camera not reachable on ONVIF - tried: {how}", file=sys.stderr)
        return None
    return f"http://{host}:{PORT}/onvif/media_service"


def usage_error(msg=None):
    if msg:
        print(f"cam_config.py: {msg}", file=sys.stderr)
    print(USAGE, file=sys.stderr)
    return 2

def call(action, body):
    env = ('<s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope"><s:Body '
           'xmlns:trt="http://www.onvif.org/ver10/media/wsdl" '
           'xmlns:tt="http://www.onvif.org/ver10/schema">' + body + '</s:Body></s:Envelope>')
    r = urllib.request.Request(MEDIA, data=env.encode(),
        headers={"Content-Type": f'application/soap+xml; charset=utf-8; action="{action}"'})
    try:
        return urllib.request.urlopen(r, timeout=10).read().decode('utf-8', 'replace')
    except Exception as e:
        return "__ERR__ " + str(e) + "\n" + (e.read().decode('utf-8','replace')[:600] if hasattr(e,'read') else '')

def get():
    return call("http://www.onvif.org/ver10/media/wsdl/GetVideoEncoderConfigurations",
                "<trt:GetVideoEncoderConfigurations/>")

def show(x):
    for b in re.findall(r'<trt:Configurations.*?</trt:Configurations>', x, re.S):
        g=lambda t: (re.search(rf'<tt:{t}>(.*?)</tt:{t}>', b, re.S).group(1) if re.search(rf'<tt:{t}>(.*?)</tt:{t}>', b, re.S) else '?')
        tok=re.search(r'token="([^"]+)"', b)
        print(f"  {tok.group(1) if tok else '?'}: {g('Width')}x{g('Height')} fps={g('FrameRateLimit')} "
              f"interval={g('EncodingInterval')} bitrate={g('BitrateLimit')}kbps quality={g('Quality')} gov={g('GovLength')}")

def set_config(tok, fps, br, q, gov, interval=None):
    """Write one encoder config. Everything not named is preserved from what the camera
    currently reports - this camera rejects or mangles requests that differ more than they
    need to, and EncodingInterval used to be hardcoded to 1 here regardless of its real
    value, which is a silent change to the frame cadence on top of whatever was asked for."""
    x = get()
    blk = [b for b in re.findall(r'<trt:Configurations.*?</trt:Configurations>', x, re.S)
           if f'token="{tok}"' in b]
    if not blk:
        sys.exit(f"token {tok} not found")
    b = blk[0]
    def cur(t, d=None):
        m = re.search(rf'<tt:{t}>(.*?)</tt:{t}>', b, re.S)
        return m.group(1) if m else d
    w, h = cur("Width"), cur("Height")
    prof = cur("H264Profile", "Main")
    interval = interval if interval is not None else cur("EncodingInterval", "1")
    body = (f'<trt:SetVideoEncoderConfiguration><trt:Configuration token="{tok}">'
            f'<tt:Name>{tok}</tt:Name><tt:UseCount>1</tt:UseCount><tt:Encoding>H264</tt:Encoding>'
            f'<tt:Resolution><tt:Width>{w}</tt:Width><tt:Height>{h}</tt:Height></tt:Resolution>'
            f'<tt:Quality>{q}</tt:Quality>'
            f'<tt:RateControl><tt:FrameRateLimit>{fps}</tt:FrameRateLimit>'
            f'<tt:EncodingInterval>{interval}</tt:EncodingInterval>'
            f'<tt:BitrateLimit>{br}</tt:BitrateLimit></tt:RateControl>'
            f'<tt:H264><tt:GovLength>{gov}</tt:GovLength><tt:H264Profile>{prof}</tt:H264Profile></tt:H264>'
            f'<tt:Multicast><tt:Address><tt:Type>IPv4</tt:Type><tt:IPv4Address>239.0.1.0</tt:IPv4Address></tt:Address>'
            f'<tt:Port>32002</tt:Port><tt:TTL>2</tt:TTL><tt:AutoStart>false</tt:AutoStart></tt:Multicast>'
            f'<tt:SessionTimeout>PT10S</tt:SessionTimeout>'
            f'</trt:Configuration><trt:ForcePersistence>true</trt:ForcePersistence>'
            f'</trt:SetVideoEncoderConfiguration>')
    r = call("http://www.onvif.org/ver10/media/wsdl/SetVideoEncoderConfiguration", body)
    ok = "SetVideoEncoderConfigurationResponse" in r
    print("  result:", "OK" if ok else r[:400])
    return ok


def main(argv):
    global MEDIA
    if len(argv) < 2:
        return usage_error()
    cmd = argv[1]
    if cmd == "get":
        if len(argv) != 2:
            return usage_error("get takes no arguments")
    elif cmd == "set":
        if len(argv) != 7:
            return usage_error("set needs <token> <fps> <bitrate_kbps> <quality> <govlength>")
    elif cmd == "bitrate":
        if len(argv) != 4:
            return usage_error("bitrate needs <token> <kbps>")
    else:
        return usage_error(f"unknown command: {cmd}")

    MEDIA = _resolve_media(BASE)
    if not MEDIA:
        return 1

    if cmd == "get":
        x = get()
        if "__ERR__" in x: print(x[:300]); return 1
        show(x)
    elif cmd == "set":
        set_config(argv[2], argv[3], argv[4], argv[5], argv[6])
    else:
        # Minimal delta: read what is there, change one number, write it back.
        tok, kbps = argv[2], argv[3]
        x = get()
        blk = [b for b in re.findall(r'<trt:Configurations.*?</trt:Configurations>', x, re.S)
               if f'token="{tok}"' in b]
        if not blk:
            sys.exit(f"token {tok} not found")
        b = blk[0]
        cur = lambda t, d=None: (re.search(rf'<tt:{t}>(.*?)</tt:{t}>', b, re.S).group(1)
                                 if re.search(rf'<tt:{t}>(.*?)</tt:{t}>', b, re.S) else d)
        print(f"  {tok}: bitrate {cur('BitrateLimit')} -> {kbps} kbps "
              f"(fps={cur('FrameRateLimit')} quality={cur('Quality')} gov={cur('GovLength')} "
              f"interval={cur('EncodingInterval')} all preserved)")
        set_config(tok, cur("FrameRateLimit"), kbps, cur("Quality"), cur("GovLength"),
                   interval=cur("EncodingInterval"))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
