#!/usr/bin/env python3
"""Resolve the camera's current address. Never hardcode it.

The camera is on DHCP and its firmware ignores ONVIF address writes, so it moves after a
power cut - it went .2 -> .3 on 2026-08-31 and this Mac's own LAN port then took the
vacated .2. Anything hardcoding an address eventually talks to the wrong device: on
2026-09-07 cam_config.py was still pointed at 192.168.1.2, which by then was this Mac.

Order, cheapest and most authoritative first:
  1. --host / CAM_HOST         an explicit override always wins
  2. log/cam_ip                runtime source of truth, maintained by stream.sh
  3. CAM_URL in conf/stream.env
  4. ONVIF WS-Discovery        the slow but definitive fallback
Each candidate must actually ANSWER before it is accepted, so a stale file cannot win.
The winner is written back to log/cam_ip so the next caller starts at step 2.

  cam_ip.py            print the address, exit 1 if none found
  cam_ip.py -v         print how it was found, too
"""
import os, pathlib, re, socket, subprocess, sys

BASE = pathlib.Path(os.environ.get("BASE", str(pathlib.Path(__file__).resolve().parent.parent)))
CAM_IP_FILE = BASE / "log/cam_ip"
STREAM_ENV  = BASE / "conf/stream.env"
ONVIF_PORT  = int(os.environ.get("CAM_ONVIF_PORT", "8899"))
RTSP_PORT   = int(os.environ.get("CAM_RTSP_PORT", "554"))


def answers(ip, port, timeout=2.0):
    if not ip:
        return False
    try:
        with socket.create_connection((ip, port), timeout=timeout):
            return True
    except Exception:
        return False


def alive(ip, need_onvif=False):
    """A camera answers RTSP; ONVIF work additionally needs 8899."""
    if need_onvif:
        return answers(ip, ONVIF_PORT)
    return answers(ip, RTSP_PORT) or answers(ip, ONVIF_PORT)


def _from_env_file():
    try:
        m = re.search(r'^CAM_URL="rtsp://([0-9.]+)', STREAM_ENV.read_text(), re.M)
        return m.group(1) if m else None
    except Exception:
        return None


def _discover():
    """ONVIF WS-Discovery, reusing find_cam.py so there is one implementation of it."""
    try:
        sys.path.insert(0, str(BASE / "bin"))
        import importlib.util
        spec = importlib.util.spec_from_file_location("find_cam", BASE / "bin/find_cam.py")
        fc = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(fc)
        return fc.discover()
    except Exception:
        return []


def resolve(need_onvif=False, allow_discovery=True, remember=True):
    """Return (ip, how). ip is None if nothing answered."""
    tried = []
    for ip, how in (
        (os.environ.get("CAM_HOST"), "CAM_HOST env"),
        ((CAM_IP_FILE.read_text().strip() if CAM_IP_FILE.exists() else None), "log/cam_ip"),
        (_from_env_file(), "CAM_URL in conf/stream.env"),
    ):
        if not ip:
            continue
        tried.append(f"{ip} ({how})")
        if alive(ip, need_onvif):
            if remember:
                _remember(ip)
            return ip, how
    if allow_discovery:
        for ip in _discover():
            tried.append(f"{ip} (ONVIF discovery)")
            if alive(ip, need_onvif):
                if remember:
                    _remember(ip)
                return ip, "ONVIF discovery"
    return None, "; ".join(tried) or "nothing to try"


def _remember(ip):
    try:
        CAM_IP_FILE.parent.mkdir(parents=True, exist_ok=True)
        if not CAM_IP_FILE.exists() or CAM_IP_FILE.read_text().strip() != ip:
            CAM_IP_FILE.write_text(ip + "\n")
    except Exception:
        pass


if __name__ == "__main__":
    verbose = "-v" in sys.argv or "--verbose" in sys.argv
    need_onvif = "--onvif" in sys.argv
    ip, how = resolve(need_onvif=need_onvif)
    if not ip:
        print(f"camera not found - tried: {how}", file=sys.stderr)
        sys.exit(1)
    print(f"{ip}   (via {how})" if verbose else ip)
