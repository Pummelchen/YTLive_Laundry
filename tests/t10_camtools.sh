#!/bin/zsh
# t10 - the camera/ONVIF tools: argv handling, import safety, and ONE WS-Discovery.
#
# Three failures this file exists to prevent:
#   (a) bin/cam_config.py indexed sys.argv[1..6] with no arity check and resolved the camera at
#       IMPORT time, so a short command line was an IndexError traceback and merely importing the
#       module did network I/O and could sys.exit.
#   (b) bin/onvif_probe.py ran the whole probe at module level - the exact bug class already fixed
#       in bin/cam_reboot.py (see its docstring) - so importing it hit the camera.
#   (c) bin/find_cam.py and bin/camscan.py each carried a WS-Discovery probe, while bin/cam_ip.py
#       documents find_cam.py as the single implementation. camscan now loads it.
#
# No credential is real and no socket is opened: the import checks poison socket()/urlopen(), the
# CLI checks stop at the usage error, and discovery runs against a fake socket plus a scratch
# stub, never the LAN. write is confined to tests/.tmp (see tests/lib.sh).
source "${0:A:h}/lib.sh"
t_begin t10

t_setup >/dev/null
CAM_BIN="$T_BASE/bin"

# A usage error is a one-line usage and a non-zero exit, never a Python traceback.
no_traceback() {  # no_traceback TEXT LABEL
  if print -r -- "$1" | grep -q "Traceback"; then t_bad "$2"; else t_ok "$2"; fi
}

# --- A. no-argument / bad-argument handling ------------------------------------------------
out=$(python3 "$CAM_BIN/cam_config.py" 2>&1); rc=$?
t_assert_eq 2 $rc "cam_config.py with no arguments exits non-zero (was an IndexError traceback)"
t_assert_contains "$out" "usage: cam_config.py" "and prints a usage line"
no_traceback "$out" "and no traceback"

out=$(python3 "$CAM_BIN/onvif_probe.py" 2>&1); rc=$?
t_assert_eq 2 $rc "onvif_probe.py with no arguments exits non-zero"
t_assert_contains "$out" "usage: onvif_probe.py" "and prints a usage line"
no_traceback "$out" "and no traceback"

# The check must bound the upper end too, or surplus arguments are silently ignored.
out=$(python3 "$CAM_BIN/onvif_probe.py" host 8899 user pass stray 2>&1); rc=$?
t_assert_eq 2 $rc "onvif_probe.py rejects a surplus argument"
t_assert_contains "$out" "usage: onvif_probe.py" "with the usage line"
no_traceback "$out" "and no traceback"

out=$(python3 "$CAM_BIN/cam_config.py" set tok 2>&1); rc=$?
t_assert_eq 2 $rc "cam_config.py set with too few arguments exits non-zero"
t_assert_contains "$out" "usage: cam_config.py" "and prints a usage line"
out=$(python3 "$CAM_BIN/cam_config.py" bogus 2>&1); rc=$?
t_assert_eq 2 $rc "cam_config.py rejects an unknown subcommand"
no_traceback "$out" "and no traceback"

out=$(python3 "$CAM_BIN/cam_reboot.py" a b c d e 2>&1); rc=$?
t_assert_eq 2 $rc "cam_reboot.py rejects a surplus argument"
t_assert_contains "$out" "usage: cam_reboot.py" "and prints a usage line"
no_traceback "$out" "and no traceback"

# --- B. camscan rejects a bad CIDR with usage, not a ValueError traceback -------------------
out=$(python3 "$CAM_BIN/camscan.py" 999.999.0.0/24 2>&1); rc=$?
t_assert_eq 2 $rc "camscan.py rejects a bad CIDR"
t_assert_contains "$out" "usage: camscan.py" "and prints a usage line"
no_traceback "$out" "and no traceback"
# A bad CIDR must be rejected BEFORE discovery, or a typo costs a 4 s multicast wait first.
if print -r -- "$out" | grep -q "WS-Discovery"; then
  t_bad "camscan started WS-Discovery before validating the CIDR"
else
  t_ok "camscan validates the CIDR before any discovery"
fi

out=$(python3 "$CAM_BIN/camscan.py" 10.0.0.0/24 stray 2>&1); rc=$?
t_assert_eq 2 $rc "camscan.py rejects a surplus argument"
t_assert_contains "$out" "usage: camscan.py" "with the usage line"

# --- C. ONE WS-Discovery implementation ----------------------------------------------------
# camscan carried its own SOAP probe of the same multicast group; these fail if it comes back.
if grep -q "239.255.255.250" "$REPO_DIR/bin/camscan.py"; then
  t_bad "camscan.py contains its own WS-Discovery multicast probe again"
else
  t_ok "camscan.py carries no WS-Discovery multicast probe"
fi
if grep -q "3702" "$REPO_DIR/bin/camscan.py"; then
  t_bad "camscan.py targets the discovery port itself again"
else
  t_ok "camscan.py does not target the discovery port itself"
fi
t_assert_contains "$(cat "$REPO_DIR/bin/camscan.py")" "find_cam" \
  "camscan.py loads find_cam.py for discovery"
t_assert_contains "$(cat "$REPO_DIR/bin/camscan.py")" "discover_replies" \
  "and calls find_cam's discovery function"
t_assert_contains "$(cat "$REPO_DIR/bin/find_cam.py")" "def discover_replies" \
  "find_cam.py exposes discover_replies"

# --- D. import safety, credentials and the discovery delegation, exercised in-process -------
T_RESULTS="$T_BASE/results.txt"
export T_RESULTS
: > "$T_RESULTS"
PYOUT="$T_BASE/camtools.txt"
BASE="$T_BASE" HOME="$T_BASE/home" PATH="$STUBS:$PATH" PYTHONDONTWRITEBYTECODE=1 python3 - <<'PY' > "$PYOUT" 2>&1
import contextlib, importlib.util, io, os, pathlib, socket, urllib.request

scratch = pathlib.Path(os.environ["T_BASE"])
binp = scratch / "bin"
results = pathlib.Path(os.environ["T_RESULTS"])

def ck(cond, label):
    with open(results, "a") as fh:
        fh.write(("PASS" if cond else "FAIL") + "\t" + label + "\n")

def load(name):
    spec = importlib.util.spec_from_file_location(name, binp / (name + ".py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod

# No module may touch the network merely by being imported.
def boom(*a, **k):
    raise AssertionError("network I/O during import")

saved = (socket.socket, socket.create_connection, urllib.request.urlopen)
socket.socket = boom
socket.create_connection = boom
urllib.request.urlopen = boom
try:
    for name in ("cam_config", "onvif_probe", "cam_reboot", "find_cam", "camscan"):
        try:
            load(name)
            ck(True, "importing %s performs no network I/O and does not raise" % name)
        except BaseException as e:
            ck(False, "importing %s raised %r" % (name, e))
finally:
    socket.socket, socket.create_connection, urllib.request.urlopen = saved

# --- onvif_probe: credentials ---------------------------------------------------------------
op = load("onvif_probe")
seen = []
op.probe = lambda host, port, user, pw: seen.append((host, port, user, pw))

os.environ.pop("CAM_USER", None); os.environ.pop("CAM_PASS", None)
err = io.StringIO()
with contextlib.redirect_stderr(err):
    rc = op.main(["onvif_probe.py", "10.0.0.5", "8899", "alice", "s3cret"])
ck(rc == 0 and seen and seen[-1][2:] == ("alice", "s3cret"),
   "onvif_probe still accepts USER PASS on argv (compatibility)")
ck("world-readable" in err.getvalue() and "CAM_USER" in err.getvalue(),
   "onvif_probe warns on stderr that argv credentials are world-readable")

os.environ["CAM_USER"] = "envuser"; os.environ["CAM_PASS"] = "envpass"
seen.clear(); err = io.StringIO()
with contextlib.redirect_stderr(err):
    op.main(["onvif_probe.py", "10.0.0.5", "8899", "alice", "s3cret"])
ck(seen and seen[-1][2:] == ("envuser", "envpass"),
   "CAM_USER/CAM_PASS win over argv credentials")
ck("world-readable" in err.getvalue(),
   "the argv warning still fires when argv creds are present but unused (ps shows them anyway)")

seen.clear(); err = io.StringIO()
with contextlib.redirect_stderr(err):
    op.main(["onvif_probe.py", "10.0.0.5"])
ck(seen and seen[-1][2:] == ("envuser", "envpass"),
   "env credentials are used when argv supplies none")
ck(err.getvalue() == "", "and no argv warning is printed")
os.environ.pop("CAM_USER", None); os.environ.pop("CAM_PASS", None)

# the probe's output shape is unchanged, against canned SOAP
op2 = load("onvif_probe")
def fake_call(url, action, body, user, pw):
    if "GetDeviceInformation" in action:
        return "<tds:Manufacturer>Acme</tds:Manufacturer><tds:Model>X1</tds:Model>"
    if "GetProfiles" in action:
        return '<trt:Profiles token="main"/>'
    return "<tt:Uri>rtsp://10.0.0.5:554/live</tt:Uri>"
op2.call = fake_call
buf = io.StringIO()
with contextlib.redirect_stdout(buf):
    op2.probe("10.0.0.5", "8899", "", "")
out = buf.getvalue()
ck("== Device http://10.0.0.5:8899/onvif/device_service ==" in out, "the device header is unchanged")
ck("Manufacturer: Acme" in out, "device fields are still printed")
ck("profile token: main" in out, "profile tokens are still printed")
ck("RTSP: rtsp://10.0.0.5:554/live" in out, "the RTSP URI is still printed")

# --- cam_reboot: credentials -----------------------------------------------------------------
cr = load("cam_reboot")
rseen = []
cr.reboot = lambda host, port, user, pw: (rseen.append((host, port, user, pw)), 0)[1]
os.environ.pop("CAM_USER", None); os.environ.pop("CAM_PASS", None)
err = io.StringIO()
with contextlib.redirect_stderr(err):
    rc = cr.main(["cam_reboot.py", "10.0.0.5", "8899", "bob", "pw"])
ck(rc == 0 and rseen and rseen[-1] == ("10.0.0.5", "8899", "bob", "pw"),
   "cam_reboot still accepts USER PASS on argv")
ck("world-readable" in err.getvalue(), "cam_reboot warns about argv credentials too")
os.environ["CAM_USER"] = "eu"; os.environ["CAM_PASS"] = "ep"
rseen.clear()
with contextlib.redirect_stderr(io.StringIO()):
    cr.main(["cam_reboot.py", "10.0.0.5", "8899", "bob", "pw"])
ck(rseen and rseen[-1][2:] == ("eu", "ep"), "cam_reboot prefers CAM_USER/CAM_PASS")
os.environ.pop("CAM_USER", None); os.environ.pop("CAM_PASS", None)

# --- find_cam: the single discovery implementation, against a fake socket --------------------
fc = load("find_cam")

class FakeSock:
    def __init__(self, replies): self._replies = list(replies)
    def setsockopt(self, *a): pass
    def settimeout(self, *a): pass
    def sendto(self, *a): pass
    def recvfrom(self, n):
        if self._replies: return self._replies.pop(0)
        raise socket.timeout()
    def close(self): pass

ONVIF = b"<Envelope>NetworkVideoTransmitter</Envelope>"
OTHER = b"<Envelope>something that is not a camera</Envelope>"

def run_discovery(fn, replies):
    orig = socket.socket
    socket.socket = lambda *a, **k: FakeSock(replies)
    try:
        return fn(timeout=0.01)
    finally:
        socket.socket = orig

raw = run_discovery(fc.discover_replies, [
    (ONVIF, ("10.0.0.9", 3702)),
    (OTHER, ("10.0.0.8", 3702)),
    (ONVIF, ("10.0.0.9", 3702)),
])
ck(list(raw) == ["10.0.0.9", "10.0.0.8"],
   "discover_replies keeps every reply, deduped by IP, in arrival order")
ips = run_discovery(fc.discover, [
    (ONVIF, ("10.0.0.9", 3702)),
    (OTHER, ("10.0.0.8", 3702)),
    (ONVIF, ("10.0.0.7", 3702)),
])
ck(ips == ["10.0.0.9", "10.0.0.7"], "discover keeps only ONVIF replies")

# --- camscan and cam_ip must actually go through find_cam ------------------------------------
# Replace the scratch copy of find_cam.py with a recorder: if camscan still probed on its own,
# the marker would never be written and the returned data would not be this stub's.
marker = scratch / "log" / "find_cam_called"
(binp / "find_cam.py").write_text(
    "import pathlib\n"
    "MARKER = pathlib.Path(%r)\n"
    "def discover_replies(timeout=4):\n"
    "    MARKER.write_text('called')\n"
    "    return {'10.0.0.9': '<xml>http://10.0.0.9/onvif/device_service</xml>'}\n"
    "def discover(timeout=4):\n"
    "    return ['10.0.0.9']\n" % str(marker))

cs = load("camscan")
d = cs.ws_discover()
ck(d == {"10.0.0.9": "<xml>http://10.0.0.9/onvif/device_service</xml>"},
   "camscan's discovery returns exactly what find_cam returns")
ck(marker.exists() and marker.read_text() == "called",
   "camscan actually called find_cam instead of probing discovery itself")

ci = load("cam_ip")
ck(ci._discover() == ["10.0.0.9"], "cam_ip's discovery still goes through find_cam")
PY

# A harness that dies before writing anything must not look like a pass.
if [[ ! -s "$T_RESULTS" ]]; then
  t_bad "the camera-tools harness produced no results at all"
  print -r -- "--- harness output ---"; head -30 "$PYOUT" 2>/dev/null
fi
while IFS=$'\t' read -r verdict label; do
  [[ -z "$verdict" ]] && continue
  if [[ "$verdict" == "PASS" ]]; then t_ok "$label"; else t_bad "$label"; fi
done < "$T_RESULTS"

# --- bin/cam_time.py: the camera's clock ----------------------------------------------------
# The OSD renders the camera's own clock and it is an hour fast (UTC+8 shown on a UTC+7 island).
# cam_time.py is the only open route to it - ONVIF, because port 80 and the XM/Dahua CGI are
# closed. Measured on the real camera 2026-09-19: the write is ACCEPTED, reads back as WIB-7, and
# the on-screen clock does not move - the same lie the encoder settings tell. These checks cover
# the tool's plumbing, not that outcome (which is recorded in docs/camera.md).
CT="$REPO_DIR/bin/cam_time.py"
out=$(python3 "$CT" 2>&1); rc=$?
t_assert_contains "$out" "usage: cam_time.py" "cam_time.py prints usage with no arguments"
t_assert_eq "2" "$rc" "and exits 2 rather than raising"
out=$(python3 "$CT" warp 2>&1); rc=$?
t_assert_eq "2" "$rc" "cam_time.py rejects an unknown subcommand"
out=$(python3 "$CT" get extra 2>&1); rc=$?
t_assert_eq "2" "$rc" "cam_time.py rejects surplus arguments"

CTOUT=$(python3 -c "
import importlib.util, socket, urllib.request
def boom(*a, **k): raise AssertionError('import touched the network')
socket.socket = boom; socket.create_connection = boom; urllib.request.urlopen = boom
spec = importlib.util.spec_from_file_location('cam_time', '$CT')
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
print('import-ok')
xml = ('<tt:GetSystemDateAndTimeResponse><tt:SystemDateAndTime>'
       '<tt:TimeZone><tt:TZ>PST0PDT</tt:TZ></tt:TimeZone>'
       '<tt:UTCDateTime><tt:Time><tt:Hour>12</tt:Hour><tt:Minute>45</tt:Minute>'
       '<tt:Second>29</tt:Second></tt:Time><tt:Date><tt:Year>2026</tt:Year>'
       '<tt:Month>9</tt:Month><tt:Day>19</tt:Day></tt:Date></tt:UTCDateTime>'
       '</tt:SystemDateAndTime></tt:GetSystemDateAndTimeResponse>')
print('clock', m._clock(xml, 'UTCDateTime'))
print('tz', m._field(xml, 'TZ'))
# cmd_set WRITES and then reads back, so record every call and assert on the first one - the
# read-back would otherwise be the last thing seen and the set would look like it never happened.
calls = []
m.call = lambda url, body, action: (calls.append((url, body, action)), '<ok/>')[1]
m._resolve = lambda base: 'http://stub/onvif/device_service'
print('rc', m.main(['cam_time.py', 'set', 'WIB-7']))
print('calls', len(calls))
print('tz-sent', '<tt:TZ>WIB-7</tt:TZ>' in calls[0][1])
print('ntp', '<tds:DateTimeType>NTP</tds:DateTimeType>' in calls[0][1])
print('dst-off', '<tds:DaylightSavings>false</tds:DaylightSavings>' in calls[0][1])
print('action', calls[0][2].endswith('SetSystemDateAndTime'))
" 2>&1)
t_assert_contains "$CTOUT" "import-ok" "importing cam_time.py touches no network"
t_assert_contains "$CTOUT" "clock 2026-09-19 12:45:29" "cam_time.py parses the ONVIF DateTime shape"
t_assert_contains "$CTOUT" "tz PST0PDT" "and the timezone the firmware reports"
t_assert_contains "$CTOUT" "rc 0" "set succeeds against a stub device service"
t_assert_contains "$CTOUT" "calls 2" "set writes and then reads back rather than trusting the write"
t_assert_contains "$CTOUT" "tz-sent True" "set sends the requested timezone"
t_assert_contains "$CTOUT" "ntp True" "set asks for NTP"
t_assert_contains "$CTOUT" "dst-off True" "and turns daylight saving off"
t_assert_contains "$CTOUT" "action True" "against the ONVIF device service"

t_teardown
t_summary
