#!/bin/zsh
# t14 - the watchdog must beat BEFORE it grades, not after.
#
# Regression for T-20. stream.sh calls a heartbeat older than MONITOR_STALE (600s) HUNG and kills
# the monitor by pid. The loop used to write the heartbeat only AFTER yt_check.py returned, so
# the file's age meant "time since the last pass finished" - CHECK_INTERVAL plus the whole
# duration of the pass. One slow pass (a yt-dlp resolve sitting on its 90s timeout, a stalled
# ffmpeg grab, the forced re-resolve in yt_check.py) could therefore make a perfectly healthy
# monitor look hung, and stream.sh would kill the one thing guarding the stream: the exact
# reverse of the guard's intent. The point of the fix is that the marker now means "the loop is
# alive and this iteration started", which is what stream.sh is actually testing.
#
# The primary check here is BEHAVIOURAL: a stub yt_check.py records the heartbeat's state at the
# instant it runs, proving the marker already existed and was fresh before any grading work.
# A source-text order check comes second, as a cheap pin so a later edit cannot silently move
# the pre-beat back after the grader.
source "${0:A:h}/lib.sh"
t_begin t14
t_setup >/dev/null

MON="$REPO_DIR/bin/yt_monitor.sh"
HB="$T_BASE/log/monitor.heartbeat"

# --- 1. behavioural: the beat lands BEFORE the grading pass ---------------------------------
# Overwrite the scratch copy of yt_check.py with a stub that, the moment it is invoked, records
# whether the heartbeat exists, how old it is and what it says. BASE points at the scratch tree,
# so the monitor reaches this stub and nothing here touches the network or a real grader.
cat > "$T_BASE/bin/yt_check.py" <<'PY'
import os, sys, time
base = os.environ.get("BASE", ".")
hb = os.path.join(base, "log", "monitor.heartbeat")
rec = os.path.join(base, "log", "stub_seen.txt")
exists = os.path.exists(hb)
age = (time.time() - os.stat(hb).st_mtime) if exists else -1.0
content = open(hb).read().strip() if exists else ""
with open(rec, "a") as f:
    f.write("exists=%s age=%.3f content=%s\n" % (exists, age, content))
print('{"status": "OK", "msg": "stub grading pass"}')
sys.exit(0)
PY

# Run the REAL script, loop and all. CHECK_INTERVAL is deliberately wide (4s): under the old
# after-the-work beat the marker would be most of an interval stale at grading time, while with
# the fix it is ~0s. The 2.0s threshold below separates the two, rather than accepting both.
env BASE="$T_BASE" HOME="$T_BASE/home" PATH="$STUBS:$PATH" \
    YT_WATCH_URL="https://example.invalid/live" \
    CHECK_INTERVAL=4 MONITOR_ACTION=log \
    /bin/zsh "$MON" >>"$T_BASE/log/t14_monitor.out" 2>&1 &
MONPID=$!

# Wait (bounded) for the stub grader to have been invoked at least once.
seen=""
for _ in {1..100}; do
  [[ -s "$T_BASE/log/stub_seen.txt" ]] && { seen=yes; break }
  sleep 0.05
done
t_assert_eq "yes" "$seen" "the real loop actually invoked the stub grader"

REC=$(head -1 "$T_BASE/log/stub_seen.txt" 2>/dev/null)
t_assert_contains "$REC" "exists=True" "the heartbeat EXISTED at the instant the grading command ran"
age_ok=$(print -r -- "$REC" | awk '{ for (i=1;i<=NF;i++) if ($i ~ /^age=/) { v=substr($i,5)+0; print (v >= 0 && v < 2.0) ? "yes" : "no" } }')
t_assert_eq "yes" "$age_ok" "and it was FRESH there (< 2s), not most of a CHECK_INTERVAL old"
t_assert_contains "$REC" "CHECKING" "and it carried the iteration-started status, not a graded result"

# One beat before the loop would satisfy the first-iteration check while every LATER pass stayed
# stale, so demand a fresh marker on a later iteration too: the beat has to belong to each pass.
for _ in {1..120}; do
  (( $(wc -l < "$T_BASE/log/stub_seen.txt" 2>/dev/null | tr -d ' ') >= 2 )) && break
  sleep 0.05
done
LAST=$(tail -1 "$T_BASE/log/stub_seen.txt" 2>/dev/null)
last_age_ok=$(print -r -- "$LAST" | awk '{ for (i=1;i<=NF;i++) if ($i ~ /^age=/) { v=substr($i,5)+0; print (v >= 0 && v < 2.0) ? "yes" : "no" } }')
t_assert_eq "yes" "$last_age_ok" "a LATER pass is fresh at grading time too, so the beat is per-iteration"

# The graded result must still overwrite the marker when the pass returns.
graded=""; hbtext=""
for _ in {1..60}; do
  hbtext=$(<"$HB" 2>/dev/null)
  graded=$(print -r -- "$hbtext" | awk '{print $2}')
  [[ "$graded" == "OK" ]] && break
  sleep 0.05
done
t_assert_eq "OK" "$graded" "the graded status still lands in the heartbeat afterwards"
t_assert_contains "$hbtext" "stub grading pass" "and it carries the grader's own message"

# Only OUR background loop, which we started ourselves - never a production process. It is in
# its CHECK_INTERVAL sleep by now; TERM stops it and wait reaps it.
kill "$MONPID" 2>/dev/null
wait "$MONPID" 2>/dev/null

# --- 2. source-level second check: the ORDER is pinned in the real file ---------------------
pre=$(grep -nE '^[[:space:]]*beat CHECKING' "$MON" | head -1 | cut -d: -f1)
run=$(grep -nF 'python3 "$BASE/bin/yt_check.py"' "$MON" | head -1 | cut -d: -f1)
post=$(grep -nF 'beat "${st:-NOSTATUS}"' "$MON" | head -1 | cut -d: -f1)
if [[ -n "$pre" && -n "$run" && -n "$post" ]] && (( pre < run && run < post )); then
  t_ok "source order: pre-beat (line $pre) < grader (line $run) < graded beat (line $post)"
else
  t_bad "source order wrong: pre-beat [$pre], grader [$run], graded beat [$post]"
fi
# CHECKING must stay OUTSIDE yt_check.py's status vocabulary, or status.sh could no longer tell
# "an iteration started" from "here is what a pass graded".
grep -q 'CHECKING' "$REPO_DIR/bin/yt_check.py" \
  && t_bad "CHECKING has become a graded status (it must only mean an iteration started)" \
  || t_ok "CHECKING is not one of yt_check.py's graded statuses"

# --- 3. the deliberate backoff must keep beating (beat_sleep is unchanged and working) -------
# beat_sleep exists so a 900s ROTATE_REQUEST_BACKOFF is not mistaken for a hang. Exercise the
# REAL beat()/beat_sleep() with only `sleep` stubbed, so the chunked loop runs instantly and
# every pause shows the heartbeat written immediately before it.
BF="$T_BASE/beat_funcs.zsh"
{ t_extract_fn "$MON" beat
  t_extract_fn "$MON" beat_sleep
  print -r -- "HEARTBEAT='$T_BASE/log/backoff.heartbeat'"
} > "$BF"
: > "$T_BASE/log/beats_during_backoff.txt"
cat > "$T_BASE/beat_harness.zsh" <<EOF
source "$BF"
sleep() { print -r -- "\$(<\$HEARTBEAT)" >> "$T_BASE/log/beats_during_backoff.txt"; }
beat_sleep 65 TESTLABEL
print -r -- "done"
EOF
out=$(/bin/zsh "$T_BASE/beat_harness.zsh")
t_assert_eq "done" "$out" "beat_sleep finishes its chunks with sleep stubbed out"

n=$(wc -l < "$T_BASE/log/beats_during_backoff.txt" | tr -d ' ')
t_assert_eq "3" "$n" "beat_sleep 65 beats once per 30s chunk (3), so a long backoff keeps beating"
labels=$(awk '{print $2}' "$T_BASE/log/beats_during_backoff.txt" | sort -u | tr '\n' ' ')
t_assert_eq "TESTLABEL" "${labels% }" "every backoff beat carries the label status.sh reads as field 1"
t_assert_contains "$(sed -n 1p "$T_BASE/log/beats_during_backoff.txt")" "65s left" \
  "the first beat precedes the first 30s wait"
t_assert_contains "$(sed -n 3p "$T_BASE/log/beats_during_backoff.txt")" "5s left" \
  "the last beat precedes the final 5s wait - it keeps beating, it does not beat once"
backoff_hb=$(<"$T_BASE/log/backoff.heartbeat")
t_assert_contains "$backoff_hb" "TESTLABEL" \
  "the real beat() wrote the backoff status into the heartbeat file"

# --- the ceiling that makes the guard sound -----------------------------------------------
# Beating before the work fixes the age's MEANING but cannot bound the pass: yt_check.py's own
# timeouts total ~630s, longer than MONITOR_STALE (600s), so an all-timeouts pass could still get a
# healthy monitor killed for being slow. The pass runs under a ceiling now, and the two numbers
# must stay ordered - this is the check that keeps them ordered if either is ever edited.
mon_stale=$(sed -n 's/^: ${MONITOR_STALE:=\([0-9]*\)}.*/\1/p' "$REPO_DIR/bin/stream.sh")
chk_tmo=$(sed -n 's/^: ${CHECK_TIMEOUT:=\([0-9]*\)}.*/\1/p' "$REPO_DIR/bin/yt_monitor.sh")
[[ "$mon_stale" == <-> && "$chk_tmo" == <-> ]] \
  && t_ok "both limits are declared where this test can read them ($chk_tmo < $mon_stale)" \
  || t_bad "could not read MONITOR_STALE ($mon_stale) or CHECK_TIMEOUT ($chk_tmo) from the sources"
(( ${chk_tmo:-0} > 0 && ${chk_tmo:-0} < ${mon_stale:-0} )) \
  && t_ok "CHECK_TIMEOUT is below MONITOR_STALE, so a slow pass cannot look like a hang" \
  || t_bad "CHECK_TIMEOUT (${chk_tmo}) is not below MONITOR_STALE (${mon_stale}) - a healthy monitor can be killed"

grep -q 'out=$(check_with_ceiling "$CHECK_TIMEOUT"' "$REPO_DIR/bin/yt_monitor.sh" \
  && t_ok "the grading pass actually runs under that ceiling" \
  || t_bad "yt_check.py is invoked without the ceiling, so the bound is decorative"

# Behavioural: a pass that never returns is killed at the ceiling and yields NOTHING, which the
# monitor reads as NOSTATUS and handles on the never-act path - not as a bad picture.
CEILF="$T_BASE/ceiling.zsh"
t_extract_fn "$REPO_DIR/bin/yt_monitor.sh" check_with_ceiling > "$CEILF"
t0=$(date +%s)
out=$(/bin/zsh -c "source '$CEILF'; check_with_ceiling 2 env sleep 30"); rc=$?
t1=$(date +%s)
(( t1 - t0 <= 8 )) && t_ok "a hanging pass is killed at the ceiling (${t1}-${t0}s), not waited out" \
                   || t_bad "the ceiling did not kill a hanging pass (took $(( t1 - t0 ))s)"
t_assert_eq "" "$out" "and it returns no output at all, so the caller sees nothing to grade"
(( rc != 0 )) && t_ok "with a non-zero status ($rc), so a caller cannot mistake it for a pass" \
             || t_bad "a killed pass reported success"
out=$(/bin/zsh -c "source '$CEILF'; check_with_ceiling 30 env echo '{\"status\": \"OK\"}'")
t_assert_contains "$out" '"status": "OK"' "a normal pass still returns its output untouched"

# --- a dead camera must NOT cause a restart -----------------------------------------------
# A bad picture with an unreachable camera cannot be fixed by restarting the publisher: the reader
# holds the last frame, so the picture stays as frozen as the camera left it, and the restart only
# drops the RTMP session - which trips enableAutoStop and fragments the recording (measured
# 2026-09-19: five such restarts inside fifty minutes, every one while the camera was down).
# The guard must not disable the action, though: with the camera UP the same picture must still
# restart. Both directions are checked, end to end, on the real script.
cat >> "$T_BASE/conf/stream.env" <<'ENV'
YT_CHANNEL="test-channel"
CHECK_INTERVAL="1"
FAIL_SECONDS="0"
MONITOR_ACTION="restart"
ENV
cat > "$T_BASE/bin/yt_check.py" <<'PY'
#!/usr/bin/env python3
print('{"status": "FROZEN", "vid": "x", "corr": 1.0, "luma": 128.0, "frozen": true, "msg": "held frame"}')
PY
chmod +x "$T_BASE/bin/yt_check.py"
FKB="$T_BASE/fakebin"; mkdir -p "$FKB"
printf '#!/bin/zsh\nsleep 60\n' > "$FKB/ffmpeg"; chmod +x "$FKB/ffmpeg"
print -r -- "192.0.2.1" > "$T_BASE/log/cam_ip"

start_victim() { "$FKB/ffmpeg" rtmp://stub & VICTIM=$!; print -r -- "$VICTIM" > "$T_BASE/log/publisher.pid"; }
run_monitor()  {
  BASE="$T_BASE" HOME="$T_BASE/home" PATH="$FKB:$STUBS:$PATH" \
    /bin/zsh "$MON" >>"$T_BASE/log/mon.out" 2>&1 &
  MONP=$!; sleep "$1"; kill "$MONP" 2>/dev/null; wait "$MONP" 2>/dev/null
}

# (1) camera DOWN. The repo's nc stub fails when log/fake_nc_down exists.
: > "$T_BASE/log/fake_nc_down"; : > "$T_BASE/log/mon.out"
start_victim; run_monitor 4
kill -0 "$VICTIM" 2>/dev/null \
  && t_ok "a bad picture with an UNREACHABLE camera does NOT restart the publisher" \
  || t_bad "the publisher was killed although the camera was down - it fragments the recording for nothing"
t_assert_contains "$(cat "$T_BASE/log/mon.out")" "CAMERA at 192.0.2.1 is not answering" \
  "and it names the camera, so the log says why nothing was done"
kill -9 "$VICTIM" 2>/dev/null; wait "$VICTIM" 2>/dev/null

# (2) camera UP. The action must still happen - a guard that never acts is not a guard.
rm -f "$T_BASE/log/fake_nc_down"; : > "$T_BASE/log/mon.out"
start_victim; run_monitor 4
kill -0 "$VICTIM" 2>/dev/null \
  && t_bad "with the camera reachable the monitor no longer restarts a frozen publisher" \
  || t_ok "with the camera reachable the same bad picture DOES restart the publisher"
wait "$VICTIM" 2>/dev/null

t_teardown
t_summary
