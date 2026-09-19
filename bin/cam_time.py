#!/usr/bin/env python3
"""Read or set the camera's clock and timezone over ONVIF.

  cam_time.py get                 what the camera believes, and what zone it thinks it is in
  cam_time.py set [TZ]            NTP on, daylight saving off, zone TZ (default CAM_TZ or WIB-7)

WHY THIS EXISTS. The camera burns its own date/time into the picture, and it was an hour fast:
the firmware had no timezone, so a UTC+7 island was rendered on a UTC+8 clock. Every viewer sees
that clock, so it is not cosmetic. Port 80 and the XM/Dahua CGI are closed on this firmware, so
ONVIF is the only route - see docs/camera.md.

The address is resolved, never hardcoded (see cam_ip.py). Everything runs inside main(): resolving
the address hits the network, so importing this module must do NOTHING - the same import-time bug
class cam_reboot.py and cam_config.py each had.

Honest limit: this sets the clock, not the on-screen display. If the OSD does not move after a
successful set, the firmware is ignoring it - record that rather than trying harder.
"""
import os, pathlib, urllib.request, re, sys, importlib.util
from datetime import datetime, timezone

USAGE = ("usage: cam_time.py get"
         " | cam_time.py set [TZ]        (TZ default WIB-7; NTP on, daylight saving off)")

BASE = pathlib.Path(os.environ.get("BASE", str(pathlib.Path(__file__).resolve().parent.parent)))
PORT = os.environ.get("CAM_ONVIF_PORT", "8899")
TZ_DEFAULT = os.environ.get("CAM_TZ", "WIB-7")


def _resolve(base):
    """Load cam_ip.py by path and resolve the address. Called only from main()."""
    spec = importlib.util.spec_from_file_location("cam_ip", base / "bin/cam_ip.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    host, how = mod.resolve(need_onvif=True)
    if not host:
        print(f"camera not reachable on ONVIF - tried: {how}", file=sys.stderr)
        return None
    return f"http://{host}:{PORT}/onvif/device_service"


def call(url, body, action):
    env = ('<s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope">'
           '<s:Body xmlns:tds="http://www.onvif.org/ver10/device/wsdl" '
           'xmlns:tt="http://www.onvif.org/ver10/schema">' + body + '</s:Body></s:Envelope>')
    req = urllib.request.Request(url, data=env.encode(),
        headers={"Content-Type": f'application/soap+xml; charset=utf-8; action="{action}"'})
    try:
        return urllib.request.urlopen(req, timeout=10).read().decode("utf-8", "replace")
    except Exception as e:
        detail = e.read().decode("utf-8", "replace")[:600] if hasattr(e, "read") else ""
        return "__ERR__ " + str(e) + "\n" + detail


def _clock(xml, which):
    """The ONVIF DateTime type is Year/Month/Day/Hour/Minute/Second nested elements.

    The firmware sends them unpadded ("2026-9-19"), which reads badly in a report a human is
    comparing against `date`; pad them here rather than at every call site.
    """
    m = re.search(rf"<tt:{which}>(.*?)</tt:{which}>", xml, re.S)
    if not m:
        return ""
    blk = m.group(1)
    vals = []
    for k in ("Year", "Month", "Day", "Hour", "Minute", "Second"):
        mm = re.search(rf"<tt:{k}>(\d+)</tt:{k}>", blk)
        vals.append(mm.group(1).zfill(4 if k == "Year" else 2) if mm else "?")
    return "%s-%s-%s %s:%s:%s" % tuple(vals)


def _field(xml, name):
    m = re.search(rf"<tt:{name}>(.*?)</tt:{name}>", xml, re.S)
    return m.group(1).strip() if m else ""


def cmd_get(url):
    out = call(url, "<tds:GetSystemDateAndTime/>",
               "http://www.onvif.org/ver10/device/wsdl/GetSystemDateAndTime")
    if out.startswith("__ERR__"):
        print(out, file=sys.stderr)
        return 1
    print("utc      :", _clock(out, "UTCDateTime") or "(none reported)")
    print("local    :", _clock(out, "LocalDateTime") or "(none reported)")
    print("timezone :", _field(out, "TZ") or "(NONE - the firmware has no zone set)")
    print("dst      :", _field(out, "DaylightSavings") or "(none reported)")
    print("type     :", _field(out, "DateTimeType") or "(none reported)")
    return 0


def cmd_set(url, tz):
    now = datetime.now(timezone.utc)
    # Field order follows the ONVIF schema. Several firmwares require the UTCDateTime block to be
    # present even when the type is NTP, and its value is UTC - not local time.
    body = ("<tds:SetSystemDateAndTime>"
            "<tds:DateTimeType>NTP</tds:DateTimeType>"
            "<tds:DaylightSavings>false</tds:DaylightSavings>"
            f"<tds:TimeZone><tt:TZ>{tz}</tt:TZ></tds:TimeZone>"
            "<tds:UTCDateTime>"
            f"<tt:Time><tt:Hour>{now.hour}</tt:Hour><tt:Minute>{now.minute}</tt:Minute>"
            f"<tt:Second>{now.second}</tt:Second></tt:Time>"
            f"<tt:Date><tt:Year>{now.year}</tt:Year><tt:Month>{now.month}</tt:Month>"
            f"<tt:Day>{now.day}</tt:Day></tt:Date>"
            "</tds:UTCDateTime>"
            "</tds:SetSystemDateAndTime>")
    out = call(url, body, "http://www.onvif.org/ver10/device/wsdl/SetSystemDateAndTime")
    if out.startswith("__ERR__"):
        print("set refused:", out[:400], file=sys.stderr)
        return 1
    print("set accepted:", "SetSystemDateAndTimeResponse" in out)
    print()
    # Read it back rather than trusting the write: this firmware accepts ONVIF encoder writes,
    # reports them correctly and then ignores them (docs/camera.md), so the read-back is the only
    # evidence. The real proof is the burned-in clock, which a human has to look at.
    rc = cmd_get(url)
    print()
    print("Now look at the picture: `bin/preflight.sh` is not needed - the clock is in the video.")
    print("If the on-screen time is still wrong, this firmware ignores the write.")
    return rc


def main(argv):
    if len(argv) < 2:
        print(USAGE, file=sys.stderr)
        return 2
    cmd = argv[1]
    if cmd not in ("get", "set"):
        print(USAGE, file=sys.stderr)
        return 2
    if (cmd == "get" and len(argv) > 2) or (cmd == "set" and len(argv) > 3):
        print(USAGE, file=sys.stderr)
        return 2
    url = _resolve(BASE)
    if not url:
        return 1
    if cmd == "get":
        return cmd_get(url)
    return cmd_set(url, argv[2] if len(argv) > 2 else TZ_DEFAULT)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
