#!/bin/zsh
# t23 - the watchguard (bin/watchguard.sh): the 10-minute system-level recovery pass.
#
# WHY THIS FILE EXISTS. The watchguard is the only component allowed to restart the other agents,
# reboot the camera and repair a broadcast. Everything it does is dangerous if it is wrong: a
# restart loop, a camera rebooted during a healthy night, a live broadcast cut. So the rules that
# decide those things are asserted here as pure functions, and then the real script is run once
# per scenario against a scripted environment (stub launchctl/nc/df/pmset/ffprobe/yt_api) so the
# I/O side is exercised without a camera, a network or a credential.
#
# The last block is a STATIC assertion over the source: the never-do list is not a comment.
source "${0:A:h}/lib.sh"
t_begin t23
t_setup >/dev/null

WG="$REPO_DIR/bin/watchguard.sh"
FAKE="$T_BASE/fakebin"
FBIN="$T_BASE/home/.local/bin"
mkdir -p "$FAKE" "$FBIN" "$T_BASE/log" "$T_BASE/conf" "$T_BASE/bin"

# --- a scratch install the real script can source ---------------------------
cat > "$T_BASE/conf/stream.env" <<ENV
CAM_URL="rtsp://127.0.0.1:8554/live/ch00_0"
YT_KEY="test-key-not-real"
MODE="crop"
OUT_FPS="20"
CHECK_INTERVAL="10"
CAM_USER="test"
CAM_PASS="test"
ENV
cat > "$T_BASE/conf/vertical.env" <<ENV
VERT_ENABLED="no"
VERT_KEY=""
ENV
cp "$REPO_DIR/bin/lib.sh" "$T_BASE/bin/lib.sh"
: > "$T_BASE/conf/yt_oauth.json"
print -r -- "127.0.0.1" > "$T_BASE/log/cam_ip"

# A YT_API the script and lib.sh both call. It records every invocation, and answers out of the
# environment so each scenario can state what the API says - including UNKNOWN, which must never
# cause an action.
cat > "$T_BASE/bin/yt_api.py" <<'PY'
#!/usr/bin/env python3
import os, sys
cmd = sys.argv[1] if len(sys.argv) > 1 else "status"
vertical = bool(os.environ.get("YT_KEY"))
with open(os.environ["FAKE_YT_CALLS"], "a") as fh:
    fh.write(("vertical " if vertical else "main ") + " ".join(sys.argv[1:]) + "\n")
if cmd == "status":
    print(os.environ.get("FAKE_VERT_STATUS" if vertical else "FAKE_YT_STATUS", '{"status": "LIVE"}'))
elif cmd == "prepare":
    print('{"status": "READY", "broadcast_id": "b-prepare"}')
elif cmd == "ensure-live":
    print('{"status": "LIVE", "broadcast_id": "b-ensure"}')
else:
    print('{"status": "LIVE"}')
PY
chmod +x "$T_BASE/bin/yt_api.py"

cat > "$T_BASE/bin/cam_reboot.py" <<'RB'
#!/usr/bin/env python3
import os, sys
with open(os.environ["FAKE_CAM_REBOOT_LOG"], "a") as fh:
    fh.write(" ".join(sys.argv[1:]) + "\n")
print("reboot requested")
RB
chmod +x "$T_BASE/bin/cam_reboot.py"

# --- stub commands (they come first on PATH) --------------------------------
cat > "$FAKE/launchctl" <<'STUB'
#!/bin/zsh
print -r -- "launchctl $*" >> "${FAKE_LAUNCHCTL_LOG:-/dev/null}"
case "$1" in
  print) exit ${FAKE_LC_PRINT_RC:-0} ;;
  *)     exit 0 ;;
esac
STUB
cat > "$FAKE/nc" <<'STUB'
#!/bin/zsh
print -r -- "nc $*" >> "${FAKE_NC_LOG:-/dev/null}"
exit ${FAKE_NC_RC:-0}
STUB
cat > "$FAKE/df" <<'STUB'
#!/bin/zsh
print -r -- "Filesystem 512-blocks Used Available Capacity Mounted_on"
print -r -- "/dev/disk1s7s1 100 10 ${FAKE_DF_FREE:-900000} 9% /"
STUB
cat > "$FAKE/sysctl" <<'STUB'
#!/bin/zsh
print -r -- "{ sec = ${FAKE_BOOT_SEC:-1}, usec = 0 } Tue Nov 10 11:37:09 2026"
STUB
cat > "$FAKE/pmset" <<'STUB'
#!/bin/zsh
print -r -- "${FAKE_PMSET:-Now drawing from 'AC Power'}"
STUB
cat > "$FBIN/ffprobe" <<'STUB'
#!/bin/zsh
print -r -- "ffprobe $*" >> "${FAKE_FFPROBE_LOG:-/dev/null}"
[[ "${FAKE_FFPROBE_RC:-0}" == 0 ]] && print -r -- "h264"
exit ${FAKE_FFPROBE_RC:-0}
STUB
chmod +x "$FAKE"/* "$FBIN"/*

# --- the pure decisions, extracted from the real script ---------------------
FUNCS="$T_BASE/wg_funcs.zsh"
: > "$FUNCS"
for fn in camera_action publisher_action broadcast_action agent_action monitor_action; do
  t_extract_fn "$WG" "$fn" >> "$FUNCS"
done
cat >> "$FUNCS" <<'EOF'
: ${WG_CAM_FAILS_BEFORE_REBOOT:=2}
: ${WG_MONITOR_STALE:=900}
EOF
run_wg_fn() {  # run_wg_fn 'zsh code' -> stdout of that code with the pure functions loaded
  /bin/zsh -c "source '$FUNCS'; $1"
}

# --- A. the camera: TCP reachable is not frames flowing ----------------------
t_assert_eq "none" "$(run_wg_fn 'camera_action yes yes 9 yes')" \
  "a camera that answers TCP and delivers frames is never touched"
t_assert_eq "observe" "$(run_wg_fn 'camera_action yes no 1 yes')" \
  "one frame-less pass is observed, not acted on (a reconnect looks like this)"
t_assert_eq "reboot" "$(run_wg_fn 'camera_action yes no 2 yes')" \
  "a camera that accepts TCP but delivers nothing for two passes is rebooted"
t_assert_eq "none" "$(run_wg_fn 'camera_action yes no 5 no')" \
  "the cooldown wins over a still-broken camera: never two reboots in the window"
t_assert_eq "observe" "$(run_wg_fn 'camera_action no no 9 yes')" \
  "an unreachable camera is NOT rebooted (ONVIF needs the network; that is net_watch's job)"

# --- B. publisher and stream.sh ---------------------------------------------
t_assert_eq "none" "$(run_wg_fn 'publisher_action yes yes 5 yes')" \
  "a healthy publisher and agent are left alone"
t_assert_eq "observe" "$(run_wg_fn 'publisher_action yes no 1 yes')" \
  "stream.sh's own watchdog gets the first pass to restart a dead publisher"
t_assert_eq "restart-publisher" "$(run_wg_fn 'publisher_action yes no 2 yes')" \
  "after two passes a still-dead publisher is restarted by pidfile"
t_assert_eq "kickstart-stream" "$(run_wg_fn 'publisher_action no no 1 yes')" \
  "a stream agent that is not even loaded is kickstarted at once"
t_assert_eq "none" "$(run_wg_fn 'publisher_action no no 9 no')" \
  "inside the cooldown nothing is kickstarted twice"

# --- C. the broadcast repair: additive, and never on a lookup failure --------
t_assert_eq "none" "$(run_wg_fn 'broadcast_action LIVE yes no yes')" \
  "a LIVE feed is never repaired"
t_assert_eq "repair" "$(run_wg_fn 'broadcast_action READY yes no yes')" \
  "READY + ingest flowing + no rotation -> prepare/ensure-live"
t_assert_eq "observe" "$(run_wg_fn 'broadcast_action READY yes yes yes')" \
  "while a rotation is armed the feed belongs to stream.sh, not to the watchguard"
t_assert_eq "observe" "$(run_wg_fn 'broadcast_action READY no no yes')" \
  "no broadcast is repaired while nothing is pushing (that would only bind a room)"
t_assert_eq "none" "$(run_wg_fn 'broadcast_action UNKNOWN yes no yes')" \
  "UNKNOWN never causes an action (the rule that keeps a yt-dlp rate limit off the air)"
t_assert_eq "none" "$(run_wg_fn 'broadcast_action ERROR yes no yes')" \
  "an API error never causes an action"
t_assert_eq "observe" "$(run_wg_fn 'broadcast_action OFFLINE yes no no')" \
  "inside the broadcast cooldown: observe only"

# --- D. agents and the monitor ---------------------------------------------
t_assert_eq "none" "$(run_wg_fn 'agent_action yes yes')" "a loaded job is left alone"
t_assert_eq "kickstart" "$(run_wg_fn 'agent_action no yes')" "an unloaded job is kickstarted"
t_assert_eq "none" "$(run_wg_fn 'agent_action no no')" "not twice inside the cooldown"
t_assert_eq "none" "$(run_wg_fn 'monitor_action 60 yes')" "a fresh monitor heartbeat is fine"
t_assert_eq "kickstart" "$(run_wg_fn 'monitor_action 1000 yes')" \
  "a stale monitor heartbeat is a restart, not a shrug"

# --- E. the real script, one pass per scenario ------------------------------
reset_case() {
  rm -rf "$T_BASE/log"
  mkdir -p "$T_BASE/log"
  print -r -- "127.0.0.1" > "$T_BASE/log/cam_ip"
  : > "$T_BASE/log/net_state"
  print -r -- "$(date +%s) OK" > "$T_BASE/log/monitor.heartbeat"
  : > "$T_BASE/log/progress.txt"
  : > "$T_BASE/log/watchguard.log"
  : > "$T_BASE/log/yt_calls"
  : > "$T_BASE/log/cam_reboots"
  : > "$T_BASE/log/launchctl.calls"
  : > "$T_BASE/log/ffprobe.calls"
  # A real, live process whose command line carries the ffmpeg/rtmp needles: this is what a
  # pidfile is supposed to point at, and pidfile_pid checks the command before believing it.
  mkdir -p "$HOME/Library/LaunchAgents"
  local l
  for l in com.user.cctv-stream com.user.cctv-monitor com.user.cctv-vertical com.user.cctv-camscan; do
    : > "$HOME/Library/LaunchAgents/$l.plist"
  done
  python3 -c 'import time; time.sleep(120)' ffmpeg rtmp &
  PUB=$!
  print -r -- "$PUB" > "$T_BASE/log/publisher.pid"
}

run_case() {   # run_case [VAR=VAL ...] -> runs bin/watchguard.sh --once against the scratch tree
  env BASE="$T_BASE" HOME="$T_BASE/home" PATH="$FAKE:$STUBS:$PATH" \
      FAKE_YT_CALLS="$T_BASE/log/yt_calls" \
      FAKE_CAM_REBOOT_LOG="$T_BASE/log/cam_reboots" \
      FAKE_LAUNCHCTL_LOG="$T_BASE/log/launchctl.calls" \
      FAKE_FFPROBE_LOG="$T_BASE/log/ffprobe.calls" \
      WG_CAM_REBOOT_SETTLE=0 \
      "$@" /bin/zsh "$WG" --once
}
acts() { grep -c 'ACTION:' "$T_BASE/log/watchguard.log" 2>/dev/null || true }

# E1: everything healthy -> no action at all, verdict OK
reset_case
out=$(run_case); rc=$?
t_assert_eq "0" "$rc" "a healthy system exits 0"
t_assert_contains "$(cat "$T_BASE/log/watchguard.log")" "actions=0" "a healthy pass takes no action"
t_assert_eq "0" "$(acts)" "no ACTION line on a healthy pass"
t_assert_file "$T_BASE/log/watchguard.heartbeat" "the pass leaves a heartbeat for status.sh"
t_assert_contains "$(cat "$T_BASE/log/watchguard.state")" "verdict=OK" "the state file records OK"
kill $PUB 2>/dev/null

# E2: the feed is READY while ingest flows -> one prepare + one ensure-live, then the cooldown
reset_case
run_case FAKE_YT_STATUS='{"status": "READY"}' >/dev/null; rc=$?
t_assert_eq "1" "$rc" "a repaired pass exits 1, not 0"
t_assert_contains "$(cat "$T_BASE/log/yt_calls")" "prepare" "READY + ingest -> prepare is called"
t_assert_contains "$(cat "$T_BASE/log/yt_calls")" "ensure-live" "and ensure-live follows it"
run_case FAKE_YT_STATUS='{"status": "READY"}' >/dev/null
t_assert_eq "1" "$(grep -c '^main prepare' "$T_BASE/log/yt_calls")" \
  "the second pass inside the cooldown does NOT prepare again"
kill $PUB 2>/dev/null

# E3: the API cannot answer -> no action, ever
reset_case
run_case FAKE_YT_STATUS='{"status": "UNKNOWN"}' >/dev/null; rc=$?
t_assert_eq "0" "$rc" "UNKNOWN is not an outage: the pass stays green"
t_assert_eq "0" "$(grep -c 'prepare\|ensure-live' "$T_BASE/log/yt_calls")" \
  "a lookup failure never triggers a repair"
kill $PUB 2>/dev/null

# E4: a rotation owns the feed -> READY is observed, not repaired
reset_case
print -r -- $(( $(date +%s) + 300 )) > "$T_BASE/log/rotating"
run_case FAKE_YT_STATUS='{"status": "READY"}' >/dev/null
t_assert_eq "0" "$(grep -c '^main prepare' "$T_BASE/log/yt_calls")" \
  "while log/rotating is armed the watchguard does not touch the broadcast"
rm -f "$T_BASE/log/rotating"
kill $PUB 2>/dev/null

# E5: a camera that answers TCP but delivers no frames -> observe, then one reboot, then cooldown
reset_case
run_case FAKE_FFPROBE_RC=1 >/dev/null
t_assert_eq "0" "$(wc -l < "$T_BASE/log/cam_reboots" | tr -d ' ')" \
  "pass 1 of a frame-less camera observes only"
run_case FAKE_FFPROBE_RC=1 >/dev/null
t_assert_eq "1" "$(wc -l < "$T_BASE/log/cam_reboots" | tr -d ' ')" \
  "pass 2 reboots the camera exactly once"
run_case FAKE_FFPROBE_RC=1 >/dev/null
t_assert_eq "1" "$(wc -l < "$T_BASE/log/cam_reboots" | tr -d ' ')" \
  "pass 3 does not reboot again inside WG_CAM_REBOOT_COOLDOWN"
kill $PUB 2>/dev/null

# E6: an agent that is not loaded -> kickstart by label (never a pattern)
reset_case
run_case FAKE_LC_PRINT_RC=1 >/dev/null
calls=$(cat "$T_BASE/log/launchctl.calls")
t_assert_contains "$calls" "kickstart -k gui/$UID/com.user.cctv-stream" \
  "an unloaded stream agent is kickstarted by label"
t_assert_contains "$calls" "load -w" "its plist is loaded first, so kickstart can succeed"
t_assert_contains "$calls" "com.user.cctv-monitor" "the other agents are checked too"
kill $PUB 2>/dev/null

# E7: the disk is low -> logs are trimmed in place
reset_case
python3 -c 'print("x" * 400000)' > "$T_BASE/log/stream.log"
before=$(/usr/bin/stat -f %z "$T_BASE/log/stream.log")
run_case FAKE_DF_FREE=500 >/dev/null
after=$(/usr/bin/stat -f %z "$T_BASE/log/stream.log")
if (( after < before )); then t_ok "a low disk trims the logs"
else t_bad "a low disk did not trim the logs ($before -> $after)"; fi
t_assert_contains "$(cat "$T_BASE/log/watchguard.log")" "ACTION: trim-logs" \
  "and says that it did"
kill $PUB 2>/dev/null

# E8: the action cap is real
reset_case
run_case FAKE_LC_PRINT_RC=1 FAKE_YT_STATUS='{"status": "READY"}' FAKE_FFPROBE_RC=1 WG_MAX_ACTIONS=1 >/dev/null
t_assert_eq "1" "$(acts)" "WG_MAX_ACTIONS caps the actions in one pass"
t_assert_contains "$(cat "$T_BASE/log/watchguard.log")" "ACTION-LIMIT" \
  "and the refusal is logged rather than silently dropped"
kill $PUB 2>/dev/null

# E9: right after a boot every state file is stale - that must not restart stream.sh
reset_case
# net_watch stopped reporting 20 minutes ago
python3 - "$T_BASE/log/net_state" <<'PY'
import os, sys, time
os.utime(sys.argv[1], (time.time() - 1200, time.time() - 1200))
PY
launchctl_log="$T_BASE/log/launchctl.calls"
run_case FAKE_BOOT_SEC=$(( $(date +%s) - 60 )) >/dev/null
t_assert_eq "0" "$(grep -c 'kickstart -k gui/'"$UID"'/com.user.cctv-stream' "$launchctl_log" 2>/dev/null || true)" \
  "inside the boot window a stale net_state does not restart stream.sh"
t_assert_contains "$(cat "$T_BASE/log/watchguard.log")" "startup window" \
  "and it says why it stood down"
run_case FAKE_BOOT_SEC=$(( $(date +%s) - 4000 )) >/dev/null
t_assert_eq "1" "$(grep -c 'kickstart -k gui/'"$UID"'/com.user.cctv-stream' "$launchctl_log" 2>/dev/null || true)" \
  "past the boot window the silent transport watchdog IS a restart"
kill $PUB 2>/dev/null

# --- F. the never-do list, as a static assertion ----------------------------
forbidden=(
  'pkill'
  'killall'
  'networksetup'
  'ipconfig'
  'ordernetworkservices'
  'shutdown'
  'tell application "System Events" to restart'
  'log/rotate_now'
  'yt_api.py end'
)
# Comments are not code: this file documents what it refuses to do, so the scan reads only the
# executable lines.
code=$(grep -v '^[[:space:]]*#' "$WG")
for bad in $forbidden; do
  if print -r -- "$code" | grep -qF -- "$bad"; then
    t_bad "watchguard.sh must not contain '$bad'"
  else
    t_ok "watchguard.sh never uses '$bad'"
  fi
done

# The only kill in the script is the pidfile-verified publisher, and it must be -9 on $pid only.
kills=$(grep -n 'kill ' "$WG" | grep -v 'kill -0' || true)
t_assert_contains "$kills" 'kill -9 "$pid"' \
  "the only process signal is the pidfile-verified publisher pid"
t_assert_contains "$(grep -n 'pidfile_pid' "$WG")" 'ffmpeg rtmp' \
  "and that pid is identity-checked before it is believed"

# --- G. the loop's own safety: one instance, and the heartbeat leads ---------
t_assert_contains "$(cat "$WG")" 'acquire_lock' "the loop refuses a second instance"
t_assert_contains "$(cat "$WG")" 'STARTING actions=0' \
  "the loop beats before its first pass, so a slow pass cannot look dead"

if (( FAIL == 0 )); then
  print -- "\n  \033[32mALL PASSED\033[0m ($(( PASS )) checks)"
  print -- ""
  exit 0
else
  print -- "\n  \033[31m$FAIL FAILED\033[0m, $PASS passed"
  print -- ""
  exit 1
fi
