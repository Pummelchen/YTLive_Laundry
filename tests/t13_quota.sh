#!/bin/zsh
# t13 - the API quota must not take the channel dark, and must not be spent on a loop that can
# never succeed.
#
# WHY. YouTube gives the project one 10,000-unit pool per day. The 2026-09-16 audit measured a
# worst case of 10,290 units/day here - over budget - and found something worse than the number:
# on `403 quotaExceeded` the code did not stop. `prepare` failed, ffmpeg restarted anyway, and the
# channel went dark at that rotation. Two separate defects, both tested here:
#
#   (a) The driver of the overrun. `bin/yt_api.py verify` reports two kinds of drift and only one
#       can be fixed: `diffs` is video-level and `enforce` can write it, while `broadcast_diffs`
#       is fixed AT CREATION and no update can ever change it. `stream.sh` enforced on ANY
#       DRIFTED, so a creation-time-only difference was chased every ENFORCE_EVERY forever - up to
#       ~158 units a shot (~7,776/day), which is the bulk of the overrun.
#   (b) The hole itself. The rotation preflight probed the OAuth TOKEN, which is not the Data API
#       and still answers LIVE with an empty pool, so a rotation could cut and then be unable to
#       create the successor.
source "${0:A:h}/lib.sh"
t_begin t13
t_setup >/dev/null

PY="$REPO_DIR/bin/yt_api.py"

# --- (a) the cooldown file, as pure logic ------------------------------------------------
qout=$(BASE="$T_BASE" PYTHONDONTWRITEBYTECODE=1 python3 -c "
import importlib.util, json
spec = importlib.util.spec_from_file_location('yt_api', '$PY')
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
print('clear :', json.dumps(m.quota_record()))
m.quota_arm('test 403')
r = m.quota_record()
print('armed :', r.get('until', 0) > 0, (r.get('detail') or '')[:6])
print('file  :', m.QUOTA_FILE.exists())
" 2>&1)
t_assert_contains "$qout" "clear : {}" "an absent cooldown file means the pool may be used"
t_assert_contains "$qout" "armed : True" "arming the cooldown blocks later calls"
t_assert_contains "$qout" "file  : True" "the cooldown is written where the whole tree can see it"

# An EXPIRED record must not block anything - the pool refills on its own clock.
python3 -c "
import json,time
open('$T_BASE/log/quota_exhausted','w').write(json.dumps({'until': int(time.time())-60}))
"
t_assert_eq "{}" "$(BASE="$T_BASE" PYTHONDONTWRITEBYTECODE=1 python3 -c "
import importlib.util, json
spec = importlib.util.spec_from_file_location('yt_api', '$PY')
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
print(json.dumps(m.quota_record()))
")" "an expired cooldown releases the API again"

# A corrupt file must not brick the channel: the check is a guard, not a gate.
print -r -- "not json at all" > "$T_BASE/log/quota_exhausted"
t_assert_eq "{}" "$(BASE="$T_BASE" PYTHONDONTWRITEBYTECODE=1 python3 -c "
import importlib.util, json
spec = importlib.util.spec_from_file_location('yt_api', '$PY')
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
print(json.dumps(m.quota_record()))
")" "a corrupt cooldown file cannot block the API forever"

# --- (b) the free check, and the refusal to spend ----------------------------------------
out=$(BASE="$T_BASE" python3 "$PY" quota 2>&1); rc=$?
t_assert_contains "$out" '"status": "OK"' "quota reports OK when nothing is armed"
t_assert_eq "0" "$rc" "and exits 0"

BASE="$T_BASE" PYTHONDONTWRITEBYTECODE=1 python3 -c "
import importlib.util
spec = importlib.util.spec_from_file_location('yt_api', '$PY')
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
m.quota_arm('test')
" >/dev/null 2>&1
out=$(BASE="$T_BASE" python3 "$PY" quota 2>&1); rc=$?
t_assert_contains "$out" '"status": "QUOTA"' "quota reports QUOTA while the cooldown is armed"
t_assert_eq "2" "$rc" "and exits non-zero so a caller cannot mistake it for usable"
t_assert_contains "$out" '"reset_in_s"' "and says how long is left, so the log is actionable"

# The important half: with the cooldown armed, `api()` must refuse BEFORE making a request. A fake
# token against the real endpoint would raise a URLError/RuntimeError; a SystemExit proves the
# short-circuit happened and no quota was spent.
spent=$(BASE="$T_BASE" PYTHONDONTWRITEBYTECODE=1 python3 -c "
import importlib.util
spec = importlib.util.spec_from_file_location('yt_api', '$PY')
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
try:
    m.api('GET', 'videos', 'fake-token')
    print('MADE A REQUEST')
except SystemExit as e:
    print('REFUSED code=%s' % e.code)
except Exception as e:
    print('NETWORK ATTEMPT: %s' % type(e).__name__)
" 2>&1)
t_assert_contains "$spent" "REFUSED code=2" "api() refuses to spend quota while the cooldown is armed"

# --- (c) the driver: enforce only what an update can actually change ----------------------
rm -f "$T_BASE/log/quota_exhausted"
EQ="$T_BASE/enforce_funcs.zsh"
{ t_extract_fn "$REPO_DIR/bin/stream.sh" enforce_drift
  print -r -- "BASE='$T_BASE'"
  print -r -- "ENFORCE_EVERY=1800"
  print -r -- "ENFORCE_MAX_ATTEMPTS=3"
  print -r -- "LAST_ENFORCE=0"
  print -r -- "ENFORCE_SIG=''"
  print -r -- "ENFORCE_TRIES=0"
  print -r -- 'log() { print -r -- "$*" >> "$T_BASE/calls.log"; }'
  print -r -- 'yt_api_ready() { return 0 }'
  print -r -- 'yt_api_call() { print -r -- "$1" >> "$T_BASE/calls.log"; case "$1" in verify) print -rn -- "$VERIFY_OUT";; enforce) print -rn -- "{\"status\": \"OK\"}";; esac; }'
} > "$EQ"
mkdir -p "$T_BASE/conf"
print -r -- '{}' > "$T_BASE/conf/broadcast_template.json"

run_enforce() { BASE="$T_BASE" VERIFY_OUT="$1" /bin/zsh -c "source '$EQ'; enforce_drift"; }

# Broadcast-only drift: reported once, never enforced. This is the 7,776-unit loop.
BROADCAST_ONLY='{"status": "DRIFTED", "video": "v1", "diffs": [], "broadcast_diffs": ["enableMonitorStream(False vs True)"]}'
: > "$T_BASE/calls.log"
run_enforce "$BROADCAST_ONLY" >/dev/null
calls=$(cat "$T_BASE/calls.log")
t_assert_contains "$calls" "verify" "a broadcast-only drift is still verified"
if print -r -- "$calls" | grep -q '^enforce$'; then
  t_bad "enforce was called for drift that NO update can fix - that is the quota loop"
else
  t_ok "enforce is NOT called when only creation-time settings differ"
fi
t_assert_contains "$calls" "never enforced" "and the reason is logged, once, with the evidence"

# Fixable drift: enforce IS called, and repeatedly the same set stops after the cap.
FIXABLE='{"status": "DRIFTED", "video": "v1", "diffs": ["tags(3 vs 38)"], "broadcast_diffs": []}'
: > "$T_BASE/calls.log"
run_enforce "$FIXABLE" >/dev/null
t_assert_contains "$(cat "$T_BASE/calls.log")" "enforce" "fixable drift is enforced"

: > "$T_BASE/calls.log"
# ONE shell for the five calls: the counters live in the long-running stream.sh process, so a
# fresh shell per call would reset them and this would test nothing. LAST_ENFORCE is reset between
# calls only to step past the ENFORCE_EVERY throttle, which would otherwise allow one call per
# 30 minutes (that throttle has its own test above).
BASE="$T_BASE" VERIFY_OUT="$FIXABLE" /bin/zsh -c "
  source '$EQ'
  enforce_drift; LAST_ENFORCE=0
  enforce_drift; LAST_ENFORCE=0
  enforce_drift; LAST_ENFORCE=0
  enforce_drift; LAST_ENFORCE=0
  enforce_drift" >/dev/null
n=$(grep -c '^enforce$' "$T_BASE/calls.log")
t_assert_eq "3" "$n" "the same unfixable field set is enforced ENFORCE_MAX_ATTEMPTS times, then abandoned"
t_assert_contains "$(cat "$T_BASE/calls.log")" "GIVING UP" "and the give-up is loud, naming the field set"

# A DIFFERENT fixable set must be chased again - giving up is per field set, not forever. Also one
# shell, for the same reason.
: > "$T_BASE/calls.log"
BASE="$T_BASE" VERIFY_OUT="$FIXABLE" /bin/zsh -c "source '$EQ'
  enforce_drift; LAST_ENFORCE=0
  VERIFY_OUT='{\"status\": \"DRIFTED\", \"video\": \"v1\", \"diffs\": [\"title(a vs b)\"], \"broadcast_diffs\": []}'
  enforce_drift" >/dev/null
n=$(grep -c '^enforce$' "$T_BASE/calls.log")
t_assert_eq "2" "$n" "a changed field set is enforced again (giving up is scoped to the set)"

# --- (d) the rotation must consult the free check ------------------------------------------
grep -q 'yt_api_call quota' "$REPO_DIR/bin/stream.sh" \
  && t_ok "the rotation preflight asks the quota check" \
  || t_bad "the rotation does not check quota before cutting"
grep -q 'quota is exhausted' "$REPO_DIR/bin/stream.sh" \
  && t_ok "and refuses the cut loudly when it is exhausted" \
  || t_bad "the rotation does not refuse on exhausted quota"
grep -q 'cmd == "quota"' "$PY" \
  && t_ok "yt_api.py exposes the free quota verb" \
  || t_bad "yt_api.py has no quota verb"

# --- (e) YouTube's OWN ingest verdict, with its severities respected (T-40) ----------------
# healthStatus carries per-issue severities. An `error` is YouTube saying viewers are affected;
# `info` is an advisory - and this installation's audio bitrate is deliberately above YouTube's
# recommendation, so flattening them into one alarm would push the operator to "fix" a choice.
hout=$(PYTHONDONTWRITEBYTECODE=1 python3 - <<PY
import contextlib, importlib.util, io, json
spec = importlib.util.spec_from_file_location("yt_api", "$PY")
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
m.probe_refresh_token = lambda: ("LIVE", "ok")
m.access_token = lambda: "tok"
def call(issues):
    m.api = lambda *a, **k: {"items": [{"id": "S", "status": {"healthStatus": {"configurationIssues": issues}}}]}
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        rc = m.cmd_health()
    return rc, json.loads(buf.getvalue())
for label, issues in (("clean", []),
                      ("audio", [{"type": "audioBitrateHigh", "severity": "info", "reason": "Check audio settings"}]),
                      ("starved", [{"type": "videoIngestionStarved", "severity": "error", "reason": "Video output low"}]),
                      ("both", [{"type": "videoIngestionStarved", "severity": "error"},
                                {"type": "audioBitrateHigh", "severity": "info"}])):
    rc, o = call(issues)
    print(label, rc, o["status"], o["error_count"], o["advisory_count"])
PY
)
t_assert_contains "$hout" "clean 0 GOOD 0 0" "a healthy ingest reports GOOD and exits 0"
t_assert_contains "$hout" "audio 1 ADVISORY 0 1" "the deliberate audio bitrate is an ADVISORY (exit 1), never an error"
t_assert_contains "$hout" "starved 2 BAD 1 0" "an error-severity ingest issue reports BAD and exits 2"
t_assert_contains "$hout" "both 2 BAD 1 1" "an error outranks an advisory without hiding it"
grep -q 'cmd == "health"' "$PY" \
  && t_ok "yt_api.py exposes the health verb" \
  || t_bad "yt_api.py has no health verb"
grep -q 'ingest health (YouTube' "$REPO_DIR/bin/status.sh" \
  && t_ok "the health page asks for it" \
  || t_bad "status.sh does not show YouTube's ingest verdict"
grep -q 'the audio note is DELIBERATE' "$REPO_DIR/bin/status.sh" \
  && t_ok "and says the audio advisory is deliberate rather than a fault to fix" \
  || t_bad "status.sh does not defend the deliberate audio setting"

t_teardown
t_summary
