#!/bin/zsh
# t07 - the EXTERNAL watchdog (bin/yt_watchdog.py): wake a human, but only for real.
#
# This is the one component that runs OFF the streamer, so what it must get right is not
# "is the picture good" but "should someone be woken, and only then". Three facts from the
# 2026-09-18 outage shape every check below:
#   1. A healthy rig is dark ~5 min every 8h03m while the broadcast is cut, so a short
#      dark window must NOT alert. Measured gaps: 4.5-5.2 min over four segments.
#   2. UNKNOWN (the yt-dlp lookup failed) is never evidence that the channel is dark. It is
#      the same distinction bin/yt_check.py draws; a rate limit must not page anyone.
#   3. An alert that cannot be delivered must be spooled, never dropped - the mail path is
#      how outages are reported, so losing a message hides the very thing being watched.
#   4. The streamer can be gone while the channel check is fine, and vice versa, so the two
#      signals must be independent.
#
# Nothing here touches the network, YouTube or the real streamer: yt-dlp and tailscale are
# stubs (see tests/stubs), and the alert transport is file/stdio, never smtp.
source "${0:A:h}/lib.sh"
t_begin t07

t_setup >/dev/null

# --- the module must be importable with no side effects ---------------------------------
# bin/cam_reboot.py once rebooted the camera at import time. A watchdog that reached the
# network when imported could not be tested like this at all.
OUT=$(PYTHONDONTWRITEBYTECODE=1 python3 -c "
import importlib.util
spec = importlib.util.spec_from_file_location('w', '$T_BASE/bin/yt_watchdog.py')
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
print('IMPORTED')
" 2>&1)
t_assert_eq "IMPORTED" "$OUT" "bin/yt_watchdog.py imports without doing anything"

# --- the alerting policy, exercised as a pure function ----------------------------------
# decide() takes the time as an argument, so a 6-hour rule is tested in microseconds and
# without a clock, a network, or a 15-minute wait.
PYOUT="$T_BASE/policy.txt"
# Results go to their own file, NOT to stdout: the module logs to stdout by design (systemd
# and journald read it), and that output would otherwise be parsed as a result line.
T_RESULTS="$T_BASE/results.txt"
export T_RESULTS
: > "$T_RESULTS"
T_BASE="$T_BASE" PYTHONDONTWRITEBYTECODE=1 python3 - <<'PY' > "$PYOUT" 2>&1
import importlib.util, os, pathlib
scratch = os.environ["T_BASE"]
spec = importlib.util.spec_from_file_location("w", os.path.join(scratch, "bin", "yt_watchdog.py"))
wd = importlib.util.module_from_spec(spec); spec.loader.exec_module(wd)

RESULTS = os.environ["T_RESULTS"]

def ck(cond, label):
    with open(RESULTS, "a") as fh:
        fh.write(("PASS" if cond else "FAIL") + "\t" + label + "\n")

def cfg(**over):
    env = {"WATCH_CHANNEL": "@ternaklaundrybengkong", "WATCH_HOST": "ternak-macbook",
           "WATCH_STATE_DIR": os.path.join(scratch, "log", "wd"),
           "WATCH_ALERT_MODE": "file",
           "WATCH_ALERT_DIR": os.path.join(scratch, "log", "alerts")}
    env.update(over)
    return wd.Cfg(env)

C = cfg()

def run(seq, c=None, hb="disabled", disk=None):
    c = c or C
    st = wd.new_state(); out = []
    for item in seq:
        t, ch, host = item[0], item[1], item[2]
        h = item[3] if len(item) > 3 else hb
        age = item[4] if len(item) > 4 else None
        d = item[5] if len(item) > 5 else disk
        if isinstance(h, tuple):
            h, age = h
        st, acts = wd.decide(t, st, ch, host, c, h, age, d)
        out.append([a["kind"] for a in acts])
    return out, st

# healthy
out, st = run([(0, "live", "live"), (60, "live", "live")])
ck(out == [[], []], "a live channel raises nothing")
ck(st["dark_since"] is None and st["last_alert_kind"] is None, "live leaves the state clean")

# the expected rotation gap
out, st = run([(0, "offline", "live"), (300, "offline", "live")])
ck(out == [[], []], "a dark window shorter than the grace (a rotation gap) does not alert")
ck(st["dark_since"] == 0, "the dark clock starts at the first dark observation")

# sustained dark
out, st = run([(0, "offline", "live"), (1000, "offline", "live"), (1100, "offline", "live")])
ck(out[1] == ["dark"], "a dark channel past the grace alerts")
ck(out[2] == [], "and does not alert again on the very next check")

# reminder while unresolved: the alert fires at t=1000, so REMIND (21600 s) elapses at 22600
out, st = run([(0, "offline", "live"), (1000, "offline", "live"), (23000, "offline", "live")])
ck(out[2] == ["dark"], "an unresolved outage is reminded after WATCH_REMIND")
ck(run([(0, "offline", "live"), (1000, "offline", "live"), (22500, "offline", "live")])[0][2] == [],
   "and not one second before WATCH_REMIND has elapsed")

# recovery, exactly once
out, st = run([(0, "offline", "live"), (1000, "offline", "live"),
               (2000, "live", "live"), (2060, "live", "live")])
ck(out[2] == ["recover"], "recovery after an alerted outage is reported once")
ck(out[3] == [], "and not repeated while healthy")
ck(st["last_alert_kind"] is None, "a recovery clears the alert episode")

# a blip that never alerted must not send a recovery mail either
out, st = run([(0, "offline", "live"), (100, "live", "live")])
ck(out[1] == [], "a short blip that never alerted sends no recovery mail")

# UNKNOWN is not OFFLINE
out, st = run([(0, "unknown", "live"), (2000, "unknown", "live")])
ck(out == [[], []], "an unreadable channel (yt-dlp failing) never raises a dark alert")
out, st = run([(0, "unknown", "live"), (3000, "unknown", "live")])
ck(out[1] == ["blind"], "a watchdog blind past WATCH_BLIND_GRACE warns that it cannot see")

# the 2026-09-18 shape: host gone and the channel unreadable
out, st = run([(0, "unknown", "down"), (1000, "unknown", "down")])
ck(out[1] == ["dark"], "host gone AND channel unreadable is alerted as an outage")
# The payload of the alert that actually fired (not of a later, deliberately silent check).
st2 = wd.new_state()
st2, _ = wd.decide(0, st2, "unknown", "down", C)
st2, a2 = wd.decide(1000, st2, "unknown", "down", C)
ck(bool(a2) and a2[0].get("host_lost") is True, "that outage is attributed to the host")

# host missing while the channel is verifiably live is NOT an outage
out, st = run([(0, "live", "down"), (5000, "live", "down")])
ck(out == [[], []], "a streamer absent from the tailnet while the channel is live is not an outage")

# no tailscale at all: the channel signal must still stand on its own
out, st = run([(0, "offline", "unknown"), (1000, "offline", "unknown")])
ck(out[1] == ["dark"], "the channel signal alone still alerts when the host cannot be seen")

# --- the dead-man signal: the streamer application's heartbeat --------------------------
# WATCH_HEARTBEAT_MAX is the grace: "stale" already means the file is older than that limit,
# so the first stale check may alert. The failure this catches is the app going quiet while
# the channel read says nothing useful - the 2026-09-19 defect, where yt-dlp answered
# UNKNOWN for hours and the watchdog had no independent evidence to fall back on.
out, st = run([(0, "unknown", "live"), (2000, "unknown", "live")], hb="fresh")
ck(out == [[], []], "a fresh heartbeat adds no alert")

out, st = run([(0, "unknown", "live")], hb=("stale", 2000))
ck(out[0] == ["silent"], "a stale heartbeat alerts even while the channel read is UNKNOWN")
ck(st["silent_since"] == 0, "and the silent clock starts at the first stale observation")

out, st = run([(0, "unknown", "live"), (60, "unknown", "live"), (100, "unknown", "live")],
              hb=("stale", 2000))
ck(out[1] == [] and out[2] == [], "a stale heartbeat does not repeat on the very next check")
out, st = run([(0, "unknown", "live"), (23000, "unknown", "live")], hb=("stale", 2000))
ck(out[1] == ["silent"], "an unresolved silent app is reminded after WATCH_REMIND")

# Absent is NOT stale: an unconfigured deployment must never page, or every host that never
# wired up a delivery mechanism would alarm forever.
out, st = run([(0, "unknown", "live"), (2000, "unknown", "live")], hb="absent")
ck(out == [[], []], "an absent heartbeat file is unconfigured and never alerts")
out, st = run([(0, "unknown", "live"), (5000, "unknown", "live")], hb="absent")
ck(out[1] == ["blind"], "an absent heartbeat does not suppress the ordinary blind warning")
out, st = run([(0, "unknown", "live"), (2000, "unknown", "live")], hb="disabled")
ck(out == [[], []], "a disabled heartbeat (WATCH_HEARTBEAT unset) never alerts")

# A heartbeat that resumes is proof the app is back; a stale one that merely stops being
# readable is not, so absence drops the episode without claiming a recovery.
out, st = run([(0, "unknown", "live"), (100, "unknown", "live", "fresh")], hb=("stale", 2000))
ck(out[1] == ["recover"], "a heartbeat that resumes reports a recovery")
ck(st["last_alert_kind"] is None, "and clears the silent episode")
out, st = run([(0, "unknown", "live"), (100, "live", "live")], hb=("stale", 2000))
ck(out[1] == ["recover"], "the channel going live also closes a silent-heartbeat episode")

# The heartbeat still names the host when the box is gone as well: silent + unreachable.
st2 = wd.new_state()
st2, a2 = wd.decide(0, st2, "unknown", "down", C, "stale", 2000)
ck(bool(a2) and a2[0]["kind"] == "silent" and a2[0].get("host_lost") is True,
   "a stale heartbeat with the host gone is attributed to the host")

# --- the disk level the push carries: a level, not an episode ----------------------------
# The pusher already sends disk_free_mb, so a filling disk is visible off-host with no new
# mechanism. It must report on its own: a healthy live channel on a full disk is exactly the
# case that has to page, and a low disk must not be swallowed by an unrelated dark/silent
# episode (nor swallow one).
LOW = {"free_mb": 500, "threshold": 2000}
FINE = {"free_mb": 165000, "threshold": 2000}
out, st = run([(0, "live", "live", "fresh", 30, LOW), (60, "live", "live", "fresh", 30, LOW)])
ck(out[0] == ["disk_low"], "a low disk alerts even while the channel is perfectly live")
ck(out[1] == [], "and does not repeat on the very next check")
ck(st["last_alert_kind"] is None,
   "a disk alert does not claim the outage episode (so a later dark still alerts at once)")
ck(st["disk"]["since"] == 0, "the low-disk clock starts at the first crossing")

out, st = run([(0, "live", "live", "fresh", 30, LOW), (23000, "live", "live", "fresh", 30, LOW)])
ck(out[1] == ["disk_low"], "an unresolved low disk is reminded after WATCH_REMIND")

out, st = run([(0, "live", "live", "fresh", 30, LOW), (100, "live", "live", "fresh", 30, FINE)])
ck(out[1] == ["disk_recover"], "free space returning above the floor reports a recovery once")
ck(st["disk"]["since"] is None, "and clears the low-disk episode so the next crossing is new")

out, st = run([(0, "live", "live", "fresh", 30, FINE)])
ck(out[0] == [] and st["disk"]["free_mb"] == 165000, "a healthy disk is recorded silently")

# An unusable number must be silent, never guessed at: no fresh push, no integer, or the
# feature switched off. An OLD number is the dangerous one - it would page about a disk that
# may be fine now.
out, st = run([(0, "live", "live", "fresh", 30, LOW), (100, "live", "live", "fresh", 30, None)])
ck(out[1] == [], "a low disk whose number went away does not report a recovery it cannot prove")
# A stale push is the app being gone: that is the silent story, and decide() is handed no disk
# (disk_state() refuses an old file's number), so one event cannot be reported as two.
ck(wd.disk_state(cfg(WATCH_DISK_MIN_MB="2000"), "stale", {"disk_free_mb": 500}) is None,
   "disk_state refuses a stale push, so an old figure can never page about the disk now")
out, st = run([(0, "unknown", "live", "stale", 2000, None)])
ck(out[0] == ["silent"], "a stale push yields the silent alert")

# The switch: WATCH_DISK_MIN_MB=0 turns the whole rule off, and the writer's own file is the
# source - no second mechanism, no API call.
off = cfg(WATCH_DISK_MIN_MB="0")
out, st = run([(0, "live", "live", "fresh", 30, None)], c=off)
ck(out[0] == [], "WATCH_DISK_MIN_MB=0 disables the disk rule")

# UNKNOWN is still not DARK: the original rule must survive the new signal.
out, st = run([(0, "unknown", "live"), (2000, "unknown", "live")])
ck("dark" not in out[0] + out[1], "UNKNOWN alone still never alerts as dark")

# purity: the caller's state must not be mutated
before = wd.new_state(); snapshot = dict(before)
wd.decide(0, before, "offline", "down", C)
ck(before == snapshot, "decide() does not mutate the state it is handed")

# --- the second channel reader: the public /live page over plain HTTPS ------------------
# On 2026-09-19 yt-dlp was rate-limited and returned UNKNOWN for hours; the direct read is
# the independent second opinion that keeps the channel signal alive. The body is a stub -
# nothing here opens a socket - and the SAME live|offline|unknown vocabulary applies, so a
# failed read can never be mistaken for a dark channel.
class _FakeResp:
    def __init__(self, body):
        self._body = body
    def read(self, *a):
        return self._body
    def __enter__(self):
        return self
    def __exit__(self, *a):
        return False

def http_stub(payload):
    def _open(req, timeout=None):
        if isinstance(payload, Exception):
            raise payload
        return _FakeResp(payload if isinstance(payload, bytes) else payload.encode())
    return _open

_real_urlopen = wd.urllib.request.urlopen
wd.urllib.request.urlopen = http_stub('<html>"isLiveNow": true</html>')
ck(wd.http_channel_state(C) == "live", "HTTP reader: isLiveNow:true reads live (whitespace tolerated)")
wd.urllib.request.urlopen = http_stub('<html>"isLiveNow":false</html>')
ck(wd.http_channel_state(C) == "offline", "HTTP reader: isLiveNow:false reads offline")
wd.urllib.request.urlopen = http_stub("<html>consent wall, no marker</html>")
ck(wd.http_channel_state(C) == "unknown",
   "HTTP reader: a page without the marker is unknown, NEVER offline")
wd.urllib.request.urlopen = http_stub(OSError("blocked / bot check"))
ck(wd.http_channel_state(C) == "unknown", "HTTP reader: a network error is unknown, not offline")
wd.urllib.request.urlopen = http_stub(ValueError("unexpected body"))
ck(wd.http_channel_state(C) == "unknown", "HTTP reader: any exception becomes unknown without escaping")

# Both URL shapes must be built and actually requested.
Cid = cfg(WATCH_CHANNEL="UC" + "a" * 22)
ck(C.channel_url == "https://www.youtube.com/@ternaklaundrybengkong/live",
   "an @handle builds the handle /live URL")
ck(Cid.channel_url == "https://www.youtube.com/channel/UC" + "a" * 22 + "/live",
   "a UC... channel id builds the /channel/.../live URL, not @UC...")
seen = {}
def _capture(req, timeout=None):
    seen["url"] = req.full_url
    return _FakeResp(b'"isLiveNow":true')
wd.urllib.request.urlopen = _capture
wd.http_channel_state(Cid)
ck(seen.get("url") == Cid.channel_url, "HTTP reader fetches the channel-id URL it was given")
wd.urllib.request.urlopen = _real_urlopen

# the combination rule: either live wins, only TWO offline reads agree on offline
ck(wd.combine_channel_states("live", "offline") == "live", "combination: yt-dlp live wins over HTTP offline")
ck(wd.combine_channel_states("offline", "live") == "live", "combination: HTTP live wins over yt-dlp offline")
ck(wd.combine_channel_states("offline", "offline") == "offline", "combination: both offline is offline")
ck(wd.combine_channel_states("offline", "unknown") == "unknown",
   "combination: a yt-dlp offline with an HTTP failure is unknown, not dark")
ck(wd.combine_channel_states("unknown", "offline") == "unknown",
   "combination: a yt-dlp failure with an HTTP offline is unknown, not dark")
ck(wd.combine_channel_states("unknown", "unknown") == "unknown", "combination: two failures stay unknown")

# read_channel wiring, including the WATCH_HTTP=0 fallback the CLI tests use
_rs, _hs = wd.channel_state, wd.http_channel_state
wd.channel_state = lambda c: ("vid1", "unknown")
wd.http_channel_state = lambda c: "live"
ck(wd.read_channel(C) == ("vid1", "live"), "read_channel: the HTTP reader rescues a yt-dlp unknown")
wd.channel_state = lambda c: ("vid1", "offline")
wd.http_channel_state = lambda c: "offline"
ck(wd.read_channel(C) == ("vid1", "offline"), "read_channel: both readers offline is offline")
wd.channel_state = lambda c: ("vid1", "offline")
wd.http_channel_state = lambda c: (_ for _ in ()).throw(AssertionError("HTTP reader was called"))
ck(wd.read_channel(cfg(WATCH_HTTP="0")) == ("vid1", "offline"),
   "read_channel: WATCH_HTTP=0 uses the yt-dlp reader alone and opens no socket")
wd.channel_state, wd.http_channel_state = _rs, _hs

# --- config file parsing ----------------------------------------------------------------
p = pathlib.Path(scratch, "conf", "wd.env")
p.write_text('# a comment\nexport A="quoted value"\nB=plain\n\nC=\'single\'\nD=\n')
e = wd.load_env_file(str(p))
ck(e.get("A") == "quoted value", "env file: double quotes are stripped")
ck(e.get("B") == "plain", "env file: a bare value is kept")
ck(e.get("C") == "single", "env file: single quotes are stripped")
ck("a comment" not in " ".join(e.keys()), "env file: comments are ignored")

# --- time handling ----------------------------------------------------------------------
# Tailscale reports LastSeen as an RFC3339 STRING while our own state holds epochs. Assuming
# only one of those crashed `status` on the watchdog host the first time it met a real peer -
# `once` was fine, `status` died. This is that regression.
ck(wd.parse_epoch(1789765200) == 1789765200.0, "parse_epoch accepts an epoch")
ck(wd.parse_epoch("2026-09-18T10:20:00.1Z") is not None, "parse_epoch accepts Tailscale's RFC3339 string")
ck(wd.parse_epoch("not a time") is None, "parse_epoch returns None for garbage instead of raising")
ck("2026-09-18" in wd.human_time("2026-09-18T10:20:00.1Z", C), "human_time renders a string timestamp")
ck(wd.human_time(None, C) == "never", "human_time renders a missing timestamp as 'never'")
try:
    wd.render_status(C, wd.new_state(), "offline", "down", "2026-09-18T10:20:00.1Z", None)
    ck(True, "status renders a real string LastSeen without raising")
except Exception as exc:
    ck(False, f"status renders a real string LastSeen without raising (raised {type(exc).__name__})")

# --- the mail path ----------------------------------------------------------------------
m = wd.default_message(C, "s", "b")
ck(m.get("Message-ID") is not None, "outgoing mail carries a Message-ID (Gmail rejects without one)")
ck(m.get("Date") is not None, "outgoing mail carries a Date")

subj_dark, body = wd.compose({"kind": "dark", "dark_for": 3600}, st, "offline", "down", None, None, C)
ck("DARK" in subj_dark.upper(), "the outage subject says DARK")
ck("ternak-macbook" in body, "the outage body names the host to go and check")
subj_lost, _ = wd.compose({"kind": "dark", "dark_for": 3600, "host_lost": True},
                          st, "unknown", "down", None, None, C)
ck("unreachable" in subj_lost.lower(), "the host-lost subject says the host is unreachable")
subj_b, _ = wd.compose({"kind": "blind", "unknown_for": 3600}, st, "unknown", "live", None, None, C)
ck("blind" in subj_b.lower(), "the blind subject says the watchdog cannot see")
subj_s, _ = wd.compose({"kind": "silent", "silent_for": 3600, "heartbeat_age": 3600},
                       st, "unknown", "live", None, None, C)
ck("heartbeat" in subj_s.lower(), "the silent-app subject names the heartbeat")
subj_s2, _ = wd.compose({"kind": "recover", "of": "silent"}, st, "unknown", "live", None, None, C)
ck("heartbeat" in subj_s2.lower() and "LIVE again" not in subj_s2,
   "a silent-heartbeat recovery is not mislabelled 'channel is LIVE again'")
ck("absent" in wd.human_heartbeat({"last_heartbeat_state": "absent"}, C),
   "status spells out an absent heartbeat instead of treating it as stale")

ok = wd.send_alert(C, "subject line", "body text")
files = sorted(pathlib.Path(os.path.join(scratch, "log", "alerts")).glob("*.eml"))
ck(ok is True and len(files) == 1, "file mode writes exactly one alert")
ck(files and "Message-ID" in files[0].read_text(), "the written alert carries full headers")

Cs = cfg(WATCH_ALERT_MODE="smtp", WATCH_SMTP_USER="", WATCH_SMTP_PASS="", WATCH_ALERT_TO="x@example.invalid")
spool = pathlib.Path(Cs["WATCH_SPOOL"])
if spool.exists():
    spool.unlink()
ok = wd.send_alert(Cs, "undeliverable", "body")
ck(ok is False, "an alert with no usable transport reports failure")
ck(spool.exists() and spool.read_text().strip() != "", "an undeliverable alert is spooled, not dropped")
PY

# A harness that dies silently must not look like a pass.
if [[ ! -s "$T_RESULTS" ]]; then
  t_bad "the policy harness produced no results at all"
  print -r -- "--- harness output ---"; head -20 "$PYOUT" 2>/dev/null
fi
while IFS=$'\t' read -r verdict label; do
  [[ -z "$verdict" ]] && continue
  if [[ "$verdict" == "PASS" ]]; then t_ok "$label"; else t_bad "$label"; fi
done < "$T_RESULTS"

# --- the deployment unit must be installable and must agree with the installer -------------
# Shipped once without an [Install] section: `systemctl enable` reported the unit as "static",
# created no boot symlink, and the watchdog would have run only until the next reboot - which is
# precisely the failure it exists to report. Caught on the real host on 2026-09-18.
UNIT="$REPO_DIR/conf/ytlive-watchdog.service"
t_assert_file "$UNIT" "the systemd unit is tracked"
if [[ -f "$UNIT" ]]; then
  t_assert_contains "$(cat "$UNIT")" "WantedBy=multi-user.target" "the unit declares [Install] so it can survive a reboot"
  t_assert_contains "$(cat "$UNIT")" "yt_watchdog.py run" "the unit runs the watchdog loop"
  # The installer seeds $PREFIX/conf/watchdog.env, so EnvironmentFile must point at conf/.
  t_assert_contains "$(cat "$UNIT")" "EnvironmentFile=/var/ytlive-watchdog/conf/watchdog.env" \
    "the unit reads the config where the installer writes it"
  t_assert_contains "$(cat "$UNIT")" "Restart=always" "the unit restarts the watchdog if it dies"
fi
ENVEX="$REPO_DIR/conf/watchdog.env.example"
t_assert_file "$ENVEX" "the tracked config template exists"
if [[ -f "$ENVEX" ]]; then
  t_assert_contains "$(cat "$ENVEX")" 'WATCH_SMTP_PASS=""' "the template ships with an empty password (never a secret)"
  t_assert_contains "$(cat "$ENVEX")" 'WATCH_ALERT_MODE="smtp"' "the template defaults to the smtp transport"
  # The two new signals must be discoverable from the tracked template, and the dead-man
  # signal must ship OFF: an unconfigured heartbeat is normal, not an outage.
  t_assert_contains "$(cat "$ENVEX")" 'WATCH_HEARTBEAT=""' "the template ships with the heartbeat unset (disabled, not alerting)"
  t_assert_contains "$(cat "$ENVEX")" 'WATCH_HEARTBEAT_MAX="900"' "and documents the heartbeat staleness limit"
  t_assert_contains "$(cat "$ENVEX")" 'WATCH_DISK_MIN_MB="2000"' "and ships the disk floor for the figure the same push carries"
  t_assert_contains "$(cat "$ENVEX")" 'WATCH_HTTP="1"' "and the second channel reader on by default"
fi

# --- end to end through the real CLI, against the stubs ---------------------------------
# The second reader is pointed at a FILE fixture, so the CLI never opens a socket: the same
# combined live|offline|unknown logic runs, but over a URL that cannot leave the machine.
HTTP_PAGE="$T_BASE/log/fake_channel.html"
print -r -- '{"isLiveNow":false}' > "$HTTP_PAGE"
run_once() {  # run_once [extra VAR=VALUE ...]
  env "$@" \
    BASE="$T_BASE" HOME="$T_BASE/home" PATH="$STUBS:$PATH" \
    WATCH_CHANNEL="@ternaklaundrybengkong" WATCH_HOST="ternak-macbook" \
    WATCH_YTDLP="yt-dlp" WATCH_TAILSCALE="tailscale" \
    WATCH_HTTP_URL="file://$HTTP_PAGE" \
    WATCH_STATE_DIR="$T_BASE/log/wd" WATCH_ALERT_MODE="file" \
    WATCH_ALERT_DIR="$T_BASE/log/alerts" \
    PYTHONDONTWRITEBYTECODE=1 \
    python3 "$T_BASE/bin/yt_watchdog.py" once
}

print -r -- "live" > "$T_BASE/log/fake_yt_live"
print -r -- "live" > "$T_BASE/log/fake_tailscale"
out=$(run_once); rc=$?
t_assert_eq 0 $rc "once: a live channel exits 0"
t_assert_contains "$out" '"channel": "live"' "once: reports the channel live"

print -r -- "offline" > "$T_BASE/log/fake_yt_live"
print -r -- "down" > "$T_BASE/log/fake_tailscale"
out=$(run_once); rc=$?
t_assert_eq 1 $rc "once: a dark channel exits 1"
t_assert_contains "$out" '"host": "down"' "once: reports the host down"
d1=$(print -r -- "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin)["dark_since"])' 2>/dev/null)

out2=$(run_once)
d2=$(print -r -- "$out2" | python3 -c 'import json,sys; print(json.load(sys.stdin)["dark_since"])' 2>/dev/null)
t_assert_eq "$d1" "$d2" "the dark clock survives a restart (state is on disk, not in memory)"

out=$(run_once WATCH_DARK_GRACE=0); rc=$?
t_assert_contains "$out" '"dark"' "once: a channel dark past zero grace reports a dark action"
n=$(ls "$T_BASE/log/alerts"/*.eml 2>/dev/null | wc -l | tr -d ' ')
t_assert_eq 1 "$n" "a real dark run writes exactly one alert file"

print -r -- "unknown" > "$T_BASE/log/fake_yt_live"
out=$(run_once); rc=$?
t_assert_eq 2 $rc "once: an unreadable channel exits 2, not 1"
t_assert_contains "$out" '"channel": "unknown"' "once: reports unknown rather than offline"

# The 2026-09-19 defect, end to end: yt-dlp is rate-limited to UNKNOWN while the public page
# still says isLiveNow:true. Before the second reader this exact state was blind; now the
# channel stays verifiable and no "blind" alert is raised.
print -r -- '{"isLiveNow":true}' > "$HTTP_PAGE"
out=$(run_once); rc=$?
t_assert_eq 0 $rc "once: the HTTP reader keeps a yt-dlp-unknown channel live"
t_assert_contains "$out" '"channel": "live"' "once: and the combined state is live"
print -r -- '{"isLiveNow":false}' > "$HTTP_PAGE"

# --- the dead-man signal, end to end ----------------------------------------------------
# A heartbeat file older than WATCH_HEARTBEAT_MAX is the application going quiet: it must
# page even though the channel read is UNKNOWN, which is exactly what the channel cannot see.
HB="$T_BASE/log/heartbeat"
print -r -- "tick" > "$HB"
touch -t 202001010000 "$HB"
print -r -- "unknown" > "$T_BASE/log/fake_yt_live"
out=$(run_once WATCH_HEARTBEAT="$HB" WATCH_HEARTBEAT_MAX=900); rc=$?
t_assert_eq 2 $rc "once: a stale heartbeat with an unknown channel still exits 2 (unknown, not dark)"
t_assert_contains "$out" '"heartbeat": "stale"' "once: reports the heartbeat stale"
acts=$(print -r -- "$out" | python3 -c 'import json,sys; print(",".join(json.load(sys.stdin)["actions"]))' 2>/dev/null)
t_assert_eq "silent" "$acts" "once: the stale heartbeat raises a silent action while the channel is unknown"

# A fresh heartbeat is silence, and an absent file is an unconfigured deployment: neither may
# page. `absent` is the case that would otherwise alarm forever on a host that never wired a
# delivery mechanism up, which is the reason it is not treated as stale.
print -r -- "tick" > "$HB"
out=$(run_once WATCH_HEARTBEAT="$HB" WATCH_HEARTBEAT_MAX=900); rc=$?
acts=$(print -r -- "$out" | python3 -c 'import json,sys; print(",".join(json.load(sys.stdin)["actions"]))' 2>/dev/null)
t_assert_eq "recover" "$acts" "a fresh heartbeat closes the silent episode without a new silent alert"
out=$(run_once WATCH_HEARTBEAT="$T_BASE/log/no-such-heartbeat" WATCH_HEARTBEAT_MAX=900); rc=$?
t_assert_contains "$out" '"heartbeat": "absent"' "once: an absent heartbeat is reported as absent"
acts=$(print -r -- "$out" | python3 -c 'import json,sys; print(",".join(json.load(sys.stdin)["actions"]))' 2>/dev/null)
t_assert_eq "" "$acts" "once: an absent heartbeat never raises a silent action (unconfigured)"

# The push body is a status document, not just a mtime: its disk_free_mb must reach the rule
# through the real file, and a body that is absent or malformed must stay silent rather than
# page on a guess.
print -r -- '{"ts":1,"host":"ternak","disk_free_mb":500,"publisher":true}' > "$HB"
out=$(run_once WATCH_HEARTBEAT="$HB" WATCH_HEARTBEAT_MAX=900 WATCH_DISK_MIN_MB=2000); rc=$?
acts=$(print -r -- "$out" | python3 -c 'import json,sys; print(",".join(json.load(sys.stdin)["actions"]))' 2>/dev/null)
t_assert_contains "$acts" "disk_low" "once: a fresh push reporting 500 MB free raises disk_low"
t_assert_contains "$out" '"free_mb": 500' "once: the reported free space is carried in the state"

print -r -- '{"ts":1,"host":"ternak","disk_free_mb":165000}' > "$HB"
out=$(run_once WATCH_HEARTBEAT="$HB" WATCH_HEARTBEAT_MAX=900 WATCH_DISK_MIN_MB=2000)
acts=$(print -r -- "$out" | python3 -c 'import json,sys; print(",".join(json.load(sys.stdin)["actions"]))' 2>/dev/null)
t_assert_contains "$acts" "disk_recover" "once: space above the floor reports the recovery"

print -r -- 'not json at all' > "$HB"
out=$(run_once WATCH_HEARTBEAT="$HB" WATCH_HEARTBEAT_MAX=900 WATCH_DISK_MIN_MB=2000); rc=$?
acts=$(print -r -- "$out" | python3 -c 'import json,sys; print(",".join(json.load(sys.stdin)["actions"]))' 2>/dev/null)
t_assert_eq "" "$acts" "once: a malformed push body is silent, never a disk alert"
t_assert_contains "$out" '"heartbeat": "fresh"' "once: a malformed body still counts as a fresh heartbeat"

# `status` must be a LIVE page: it recomputes the heartbeat, so it must recompute the disk level
# from the same file. Measured on the real host: a freshly installed watchdog printed
# "disk : unavailable" while a fresh push carrying 165357 MB sat right there, because status
# replayed the loop's last persisted state instead of reading the file.
write_status() {  # write_status [extra VAR=VALUE ...]
  env "$@" \
    BASE="$T_BASE" HOME="$T_BASE/home" PATH="$STUBS:$PATH" \
    WATCH_CHANNEL="@ternaklaundrybengkong" WATCH_HOST="ternak-macbook" \
    WATCH_YTDLP="yt-dlp" WATCH_TAILSCALE="tailscale" \
    WATCH_HTTP_URL="file://$HTTP_PAGE" \
    WATCH_STATE_DIR="$T_BASE/log/wd-status" WATCH_ALERT_MODE="file" \
    WATCH_ALERT_DIR="$T_BASE/log/alerts" \
    PYTHONDONTWRITEBYTECODE=1 \
    python3 "$T_BASE/bin/yt_watchdog.py" status 2>&1
}
print -r -- '{"ts":1,"disk_free_mb":165357,"publisher":true}' > "$HB"
out=$(write_status WATCH_HEARTBEAT="$HB" WATCH_HEARTBEAT_MAX=900 WATCH_DISK_MIN_MB=2000)
t_assert_contains "$out" "165,357 MB free" "status reads the disk level out of a fresh push, not the loop's memory"
t_assert_contains "$out" "alert under 2,000 MB" "status names the floor it would alert at"

print -r -- '{"ts":1,"disk_free_mb":500}' > "$HB"
out=$(write_status WATCH_HEARTBEAT="$HB" WATCH_HEARTBEAT_MAX=900 WATCH_DISK_MIN_MB=2000)
t_assert_contains "$out" "ok 500 MB free" "status shows a below-floor reading as a live number (LOW is the alert episode, which the loop owns)"

touch -t 202001010000 "$HB"
out=$(write_status WATCH_HEARTBEAT="$HB" WATCH_HEARTBEAT_MAX=900 WATCH_DISK_MIN_MB=2000)
t_assert_contains "$out" "unavailable" "status does not believe a stale push's disk figure"

# --- the host line must not print year 1 ------------------------------------------------
# Tailscale reports Go's zero time for a peer that is ONLINE (measured on the real tailnet
# 2026-09-19), and formatting it printed "last seen 1-01-01T00:00:00Z" for a perfectly healthy
# streamer - on the page an operator reads during an incident. Online means now, so the line
# says so and carries no date at all.
print -r -- "live" > "$T_BASE/log/fake_tailscale"
out=$(write_status WATCH_HEARTBEAT="$HB" WATCH_HEARTBEAT_MAX=900)
t_assert_contains "$out" "host state     : live  online now" "an ONLINE peer reads 'online now'"
if print -r -- "$out" | grep -qE "0001-01-01|1-01-01"; then
  t_bad "status still renders Tailscale's zero time as a date for an online peer"
else
  t_ok "status never prints year 1 for an online peer"
fi
print -r -- "down" > "$T_BASE/log/fake_tailscale"
out=$(write_status WATCH_HEARTBEAT="$HB" WATCH_HEARTBEAT_MAX=900)
t_assert_contains "$out" "host state     : down" "an offline peer reads down"
t_assert_contains "$out" "last seen" "and an OFFLINE peer keeps its real last-seen date"
if print -r -- "$out" | grep -qE "1-01-01"; then
  t_bad "the offline path lost its last-seen date"
else
  t_ok "the offline last-seen date is intact"
fi
print -r -- "live" > "$T_BASE/log/fake_tailscale"

# --- the installer must not use the macOS system python, and must give the job a PATH -------
# /usr/bin/python3 is the Xcode Command Line Tools build - 3.9.6, measured on this project's
# machines on 2026-09-19 - and trusting it is exactly what broke the 2026-09-17 deploy. For a
# WATCHDOG it is worse than merely untidy: a launchd job gets PATH=/usr/bin:/bin:/usr/sbin:/sbin,
# yt-dlp normally lives in ~/.local/bin, so a launchd-installed watchdog would report UNKNOWN
# forever - indistinguishable from a dark channel, which is the one thing it must never confuse.
INST="$REPO_DIR/bin/watchdog-install.sh"
if grep -q '<string>/usr/bin/python3</string>' "$INST"; then
  t_bad "the installer hardcodes /usr/bin/python3 in the LaunchAgent (the 2.1-era mistake)"
else
  t_ok "the installer does not hardcode the macOS system python"
fi
# It installs onto a Linux host, and Debian has no zsh: the zsh version died with
# "cannot execute: required file not found" (exit 127) on the real watchdog host.
if /bin/sh -n "$INST" 2>/dev/null; then
  t_ok "the installer is valid POSIX sh (it must run on a host with no zsh)"
else
  t_bad "the installer is not valid POSIX sh"
fi

# The Linux branch cannot be exercised without root and systemd, but the two sed expressions
# that decide the unit's paths and interpreter can be - and those are the part that breaks.
UNITSRC="$REPO_DIR/conf/ytlive-watchdog.service"
sub=$(sed -e "s#/var/ytlive-watchdog#/PFX#g" -e "s#^ExecStart=/usr/bin/python3#ExecStart=/SOME/PY#" "$UNITSRC")
t_assert_contains "$sub" "ExecStart=/SOME/PY /PFX/bin/yt_watchdog.py run" "the systemd substitution rewrites the interpreter and the prefix"
t_assert_contains "$sub" "EnvironmentFile=/PFX/conf/watchdog.env" "and points at the config the installer seeds"

# NEVER render straight onto the live unit path. `sed > $UNIT` truncates the destination before
# sed runs, so a missing template zeroed /etc/systemd/system/ytlive-watchdog.service and systemd
# reported the unit as "masked" - silently removing the watchdog's boot survival, which is the
# exact failure it exists to report. Found by running the installer on the real host 2026-09-19.
if grep -q '> "$UNIT.new"' "$INST" && grep -q 'mv "$UNIT.new" "$UNIT"' "$INST" && grep -q '! -s "$UNIT.new"' "$INST"; then
  t_ok "the installer renders the unit through a temp file and refuses an empty one"
else
  t_bad "the installer can write an empty unit straight onto the live path"
fi
if grep -qE '>[[:space:]]*"\$(UNIT|PLIST)"[[:space:]]' "$INST"; then
  t_bad "the installer redirects straight onto the live unit/plist path (a failed render would truncate it)"
else
  t_ok "nothing redirects straight onto the live unit or plist path"
fi
if grep -q 'UNIT_TEMPLATE' "$INST" && grep -q 'nothing has been changed' "$INST"; then
  t_ok "the unit template is resolved before anything is written"
else
  t_bad "the installer does not resolve its template before writing"
fi

# Two fake interpreters, deliberately listed OLDEST FIRST: the choice must be by version, not by
# position, because PATH order is what made the original bug possible.
mkdir -p "$T_BASE/fakepy/old" "$T_BASE/fakepy/new"
cat > "$T_BASE/fakepy/old/python3" <<'PY'
#!/bin/zsh
case "$*" in
  *%d%02d%02d*) print -- 30906 ;;
  *)             print -- 3.9.6 ;;
esac
PY
cat > "$T_BASE/fakepy/new/python3" <<'PY'
#!/bin/zsh
case "$*" in
  *%d%02d%02d*) print -- 31407 ;;
  *)             print -- 3.14.7 ;;
esac
PY
chmod +x "$T_BASE/fakepy/old/python3" "$T_BASE/fakepy/new/python3"

WDPREFIX="$T_BASE/wd"
out=$(HOME="$T_BASE/home" PATH="$STUBS:$PATH" \
      WATCHDOG_PY_SEARCH="$T_BASE/fakepy/old/python3 $T_BASE/fakepy/new/python3" \
      /bin/sh "$INST" --prefix "$WDPREFIX" 2>&1); rc=$?
t_assert_eq 0 $rc "the watchdog installer runs in a sandbox"
t_assert_contains "$out" "python   : $T_BASE/fakepy/new/python3" "and picks the NEWEST interpreter, not the first on the list"
t_assert_contains "$out" "not started" "and does not start the service by itself"

PLIST="$T_BASE/home/Library/LaunchAgents/com.user.ytlive-watchdog.plist"
t_assert_file "$PLIST" "the LaunchAgent plist is written"
if [[ -f "$PLIST" ]]; then
  t_assert_contains "$(cat "$PLIST")" "<string>$T_BASE/fakepy/new/python3</string>" "the plist runs the newest interpreter"
  t_assert_contains "$(cat "$PLIST")" "<key>PATH</key>" "the plist sets a PATH for the job"
  t_assert_contains "$(cat "$PLIST")" "$T_BASE/home/.local/bin" "and it includes the per-user bin dir where yt-dlp lives"
  if plutil -lint "$PLIST" >/dev/null 2>&1; then
    t_ok "the generated plist passes plutil -lint"
  else
    t_bad "the generated plist is invalid"
  fi
fi

# A dry run must be safe to run on the live host: it resolves and reports, and writes nothing.
out=$(HOME="$T_BASE/home" PATH="$STUBS:$PATH" WATCHDOG_PY_SEARCH="$T_BASE/fakepy/new/python3" \
      /bin/sh "$INST" --prefix "$T_BASE/wd-dry" --dry-run 2>&1); rc=$?
t_assert_eq 0 $rc "the installer has a dry run"
t_assert_contains "$out" "DRY RUN" "and it says so"
t_assert_contains "$out" "python   : $T_BASE/fakepy/new/python3" "and reports the interpreter it would use"
t_assert_no_file "$T_BASE/wd-dry/bin/yt_watchdog.py" "the dry run writes nothing at all"

# The host must be able to say WHICH build it runs. It could not before: the live watchdog host
# was found running a pre-2.4 yt_watchdog.py - no heartbeat code at all - while the streamer
# said DEPLOY COMPLETE, and the only way to see it was to hash the file against a checkout.
VER="$T_BASE/wd-real"
out=$(HOME="$T_BASE/home" PATH="$STUBS:$PATH" WATCHDOG_PY_SEARCH="$T_BASE/fakepy/new/python3" \
      /bin/sh "$INST" --prefix "$VER" 2>&1); rc=$?
t_assert_eq 0 $rc "the installer installs without --start"
t_assert_contains "$out" "version  : $(cat "$REPO_DIR/VERSION")" "and reports the version it stamped"
t_assert_file "$VER/VERSION" "the install carries a VERSION stamp"
if [ -f "$VER/VERSION" ] && [ "$(cat "$VER/VERSION")" = "$(cat "$REPO_DIR/VERSION")" ]; then
  t_ok "the stamp is byte-identical to the tree it came from"
else
  t_bad "the stamp does not match the tree's VERSION"
fi
# and the watchdog reads that stamp back, so `status` answers the question on the host itself.
out=$(WATCH_STATE_DIR="$VER" WATCH_ALERT_MODE=file PYTHONDONTWRITEBYTECODE=1 python3 -c "
import importlib.util, os
spec = importlib.util.spec_from_file_location('w', '$VER/bin/yt_watchdog.py')
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
env = {'WATCH_STATE_DIR': '$VER', 'WATCH_ALERT_MODE': 'file'}
print(m.program_version(m.Cfg(env)))
" 2>&1)
t_assert_eq "$(cat "$REPO_DIR/VERSION")" "$out" "and yt_watchdog.py reads the stamp back"
# A hand-made or pre-2.7 install has no stamp; that must be stated, not guessed.
out=$(WATCH_STATE_DIR="$T_BASE/no-stamp" PYTHONDONTWRITEBYTECODE=1 python3 -c "
import importlib.util
spec = importlib.util.spec_from_file_location('w', '$REPO_DIR/bin/yt_watchdog.py')
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
env = {'WATCH_STATE_DIR': '$T_BASE/no-stamp', 'WATCH_ALERT_MODE': 'file'}
print(m.program_version(m.Cfg(env)))
" 2>&1)
t_assert_contains "$out" "unknown" "an unstamped install reports unknown rather than a version"

t_teardown
t_summary
