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

def run(seq, c=None):
    c = c or C
    st = wd.new_state(); out = []
    for t, ch, host in seq:
        st, acts = wd.decide(t, st, ch, host, c)
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

# purity: the caller's state must not be mutated
before = wd.new_state(); snapshot = dict(before)
wd.decide(0, before, "offline", "down", C)
ck(before == snapshot, "decide() does not mutate the state it is handed")

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
fi

# --- end to end through the real CLI, against the stubs ---------------------------------
run_once() {  # run_once [extra VAR=VALUE ...]
  env "$@" \
    BASE="$T_BASE" HOME="$T_BASE/home" PATH="$STUBS:$PATH" \
    WATCH_CHANNEL="@ternaklaundrybengkong" WATCH_HOST="ternak-macbook" \
    WATCH_YTDLP="yt-dlp" WATCH_TAILSCALE="tailscale" \
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

t_teardown
t_summary
