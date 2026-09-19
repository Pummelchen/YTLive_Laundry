#!/bin/zsh
# Self-check loop: every CHECK_INTERVAL seconds, pull a frame from the PUBLIC YouTube
# live stream and compare it to conf/golden.jpg. Acts only on sustained failure, so
# people walking through and day/night light changes never trigger it.
#
# THREE THINGS THIS LOOP MUST NEVER DO
#   1. Act on a single bad check. The scene is a shop; people walk through it.
#   2. Act because the LOOKUP failed. "yt-dlp fell over" is not "the channel is dark".
#      yt_check.py reports UNKNOWN for that, and UNKNOWN never triggers an action.
#   3. Act while stream.sh is rotating. log/rotating holds an epoch deadline for that.
set -u
BASE="${BASE:-${0:A:h:h}}"   # the checkout this script lives in (a launchd install is ~/Downloads/YTLive)
source "$BASE/conf/stream.env"
MLOG="$BASE/log/monitor.log"
HEARTBEAT="$BASE/log/monitor.heartbeat"
MON_PID="$BASE/log/monitor.pid"      # our own pid, so stream.sh can restart exactly US
PUB_PID="$BASE/log/publisher.pid"    # the publisher's pid, written by stream.sh
CAMIP_FILE="$BASE/log/cam_ip"        # the camera's address, written by stream.sh / cam_ip.py
mlog() { print -r -- "$(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$MLOG"; }
# stream.sh's are-you-still-alive check kills a hung monitor by pid. It used to hunt for us with
# `pkill -9 -f "zsh.*yt_monitor.sh"`, which cannot tell this process from anything else whose
# command line happens to contain that text.
print -r -- "$$" > "$MON_PID" 2>/dev/null

: ${CHECK_INTERVAL:=10}
: ${MONITOR_ACTION:=restart}   # "restart" the streamer, or "log" to only report

# Thresholds are SECONDS OF SUSTAINED FAILURE, not counts of checks. They used to be counts,
# which quietly lied: each check spawns yt-dlp AND ffmpeg, so a "10s" interval measured
# 14s median and 118s at worst, and "30 checks = 5 min" was really ~7. Wall-clock means
# these numbers stay true however slow a check happens to be.
: ${FAIL_SECONDS:=90}          # bad PICTURE (black/frozen/mismatch) before restarting ingest
: ${OFFLINE_SECONDS:=300}      # channel confirmed dark before creating a broadcast
: ${BLIND_SECONDS:=300}        # yt-dlp unable to answer before we ask the API instead
: ${ROTATE_REQUEST_BACKOFF:=900}   # silence after asking for a rotation (must exceed ROTATE_GRACE)
: ${TOKEN_CHECK_EVERY:=21600}      # re-check OAuth token expiry every 6h (local, no network)
: ${CHECK_TIMEOUT:=420}            # hard ceiling on ONE grading pass; MUST stay below MONITOR_STALE
                                   # (600) or a slow pass can still get a healthy monitor killed.
                                   # yt_check.py's own timeouts can total ~630s, which is why this
                                   # exists at all - see check_with_ceiling().

# The API is what makes this loop able to FIX things rather than just complain. conf/stream.env
# is sourced, not exported, so every call has to pass its settings explicitly.
YT_API="$BASE/bin/yt_api.py"
source "$BASE/bin/lib.sh"      # yt_api_ready(), yt_api_call() - shared with stream.sh

# One line of ground truth for status.sh and for stream.sh's are-you-still-alive check.
# Silence in monitor.log means "all checks passed", which is indistinguishable from "the
# monitor died" - this file tells them apart.
#
# It is written TWICE per iteration and the ORDER is the whole point: the loop beats CHECKING
# BEFORE it starts the grading pass, then replaces that with the real status once yt_check.py
# has answered. stream.sh calls the heartbeat HUNG when its mtime is older than MONITOR_STALE
# (600s), so if the beat came only AFTER the work, that age would mean "time since the last pass
# finished" - inflated by CHECK_INTERVAL and by the whole duration of the pass. One slow pass (a
# yt-dlp resolve that sits on its timeout, a stalled ffmpeg grab, the forced re-resolve in
# yt_check.py) would then make a perfectly healthy watchdog look hung and the guard would kill
# the very thing guarding the stream. Beating first makes the age mean what stream.sh is
# actually testing: how long since this loop last came around.
beat() { print -r -- "$(date +%s) ${1} ${2:-}" > "$HEARTBEAT" 2>/dev/null; }

# A long backoff is a DELIBERATE silence, and it has to stay distinguishable from a hang.
# ROTATE_REQUEST_BACKOFF is 900s while stream.sh treats a heartbeat older than
# MONITOR_STALE (600s) as hung - so a plain sleep here got a healthy monitor killed and
# relaunched every time it backed off. Keep beating through it.
beat_sleep() {
  local left="$1" label="${2:-BACKOFF}" chunk
  while (( left > 0 )); do
    chunk=$(( left > 30 ? 30 : left ))
    beat "$label" "deliberately quiet, ${left}s left"
    sleep "$chunk"
    left=$(( left - chunk ))
  done
}

# A hard ceiling on ONE grading pass. Beating before the work (above) stops the age meaning
# "time since the last pass FINISHED", but it cannot bound the pass itself: yt_check.py's own
# timeouts add up to about 630s (3x90 for the yt-dlp/ffmpeg calls plus a forced re-resolve that
# repeats two of them, plus 3x30 for the greyscale caches), which is already longer than
# MONITOR_STALE (600s). A pass where everything times out would therefore still age the beat past
# the threshold and get a HEALTHY monitor killed for being slow - the same defect, one layer down.
# So the pass runs under a ceiling, which makes the invariant local and provable: CHECK_TIMEOUT
# must stay below MONITOR_STALE, and tests/t14_monitor_beat.sh proves it from the sources.
# macOS has no `timeout`, so this is the background-and-kill idiom.
# The killer's stdio is redirected for a reason: without it the killer inherits the command
# substitution's pipe and the caller blocks for the whole ceiling even when the pass finished.
check_with_ceiling() {
  local ceilin="$1"; shift
  local outf="${TMPDIR:-/tmp}/ytlive-check.$$"
  "$@" >"$outf" 2>&1 &
  local p=$!
  ( sleep "$ceilin"; kill -TERM "$p" 2>/dev/null; sleep 2; kill -9 "$p" 2>/dev/null ) </dev/null >/dev/null 2>&1 &
  local k=$!
  wait "$p" 2>/dev/null; local rc=$?
  kill -TERM "$k" 2>/dev/null; wait "$k" 2>/dev/null
  cat "$outf" 2>/dev/null
  rm -f "$outf"
  return $rc
}


# stream.sh writes an epoch deadline into log/rotating while it is rotating and during the
# warm-up after. A deadline (not a bare marker) means a crashed streamer cannot mute us forever.
hold_active() {
  local f="$BASE/log/rotating" deadline
  [[ -e "$f" ]] || return 1
  deadline=$(<"$f" 2>/dev/null)
  # A file without a deadline in it (older stream.sh, or a half-written one) is honoured for
  # 10 minutes from its mtime, never indefinitely.
  [[ "$deadline" == <-> ]] || deadline=$(( $(/usr/bin/stat -f %m "$f") + 600 ))
  (( $(date +%s) < deadline ))
}

# The whole point of the project: no live stream found, so MAKE one. Restarting ingest
# cannot do this on this channel - it never could - only the API can.
bring_live() {
  local why="$1" out
  if ! yt_api_ready; then
    mlog "ACTION ($why): no API credentials, so nothing here can create a broadcast. Asking stream.sh to rotate instead."
    touch "$BASE/log/rotate_now"
    return 1
  fi
  out=$(yt_api_call ensure-live)
  if print -r -- "$out" | grep -q '"status": *"LIVE"'; then
    mlog "ACTION ($why): channel is live again via the API: $out"
    return 0
  fi
  mlog "ACTION ($why): the API could not bring the channel live: $out"
  mlog "        falling back to a rotation request; backing off ${ROTATE_REQUEST_BACKOFF}s"
  touch "$BASE/log/rotate_now"
  return 1
}

check_token() {
  yt_api_ready || return
  local out rc
  out=$(yt_api_call token); rc=$?
  (( rc == 0 )) && return
  mlog "TOKEN WARNING: $out"
}

if [[ -z "${YT_CHANNEL:-}" && -z "${YT_WATCH_URL:-}" ]]; then
  mlog "FATAL: neither YT_CHANNEL nor YT_WATCH_URL set - monitor cannot run"
  exit 1
fi

mlog "monitor start: ${YT_CHANNEL:-$YT_WATCH_URL} every ${CHECK_INTERVAL}s; act after ${FAIL_SECONDS}s bad picture / ${OFFLINE_SECONDS}s offline / ${BLIND_SECONDS}s blind (${MONITOR_ACTION})"
check_token
last_token_check=$(date +%s)

bad_since=0        # epoch when the current run of bad PICTURE checks started
off_since=0        # epoch when the channel was first seen OFFLINE
blind_since=0      # epoch when yt-dlp first failed to answer
while true; do
  # BEFORE the work, not after it - see the contract on beat() above. CHECKING is deliberately
  # NOT one of yt_check.py's statuses, so status.sh (and the off-host watchdog that reads this
  # same file) can tell "an iteration has started" from "here is what a pass graded". This is
  # what keeps a single slow pass from making the heartbeat older than MONITOR_STALE and getting
  # a healthy monitor killed by stream.sh.
  beat CHECKING "iteration started, grading pass running"
  now=$(date +%s)
  if (( now - last_token_check >= TOKEN_CHECK_EVERY )); then
    check_token; last_token_check=$now
  fi

  if hold_active; then      # stream.sh is rotating, or YouTube is still spinning a new broadcast up
    beat HOLD "stream.sh is rotating"
    bad_since=0; off_since=0; blind_since=0
    sleep "$CHECK_INTERVAL"; continue
  fi

  # Keep the golden reference fresh: basefill.jpg is a real camera frame grabbed at every
  # publisher start (so at least every rotation). A days-old golden drifts as the shop
  # changes and drags correlation toward the alert line for no reason.
  # zsh's -nt is FALSE when the right-hand file does not exist, so the old test could never
  # bootstrap a missing reference - and conf/golden.jpg is gitignored, so a fresh install had
  # none. That made every check report NOGOLDEN, which the case below then treated as a bad
  # picture and killed the publisher for, forever. Create it when it is absent.
  if [[ -s "$BASE/log/basefill.jpg" ]] && [[ ! -e "$BASE/conf/golden.jpg" || "$BASE/log/basefill.jpg" -nt "$BASE/conf/golden.jpg" ]]; then
    cp "$BASE/log/basefill.jpg" "$BASE/conf/golden.jpg" && mlog "golden reference refreshed from latest publisher start frame"
  fi

  out=$(check_with_ceiling "$CHECK_TIMEOUT" \
        env BASE="$BASE" YT_CHANNEL="${YT_CHANNEL:-}" YT_WATCH_URL="${YT_WATCH_URL:-}" CORR_MIN="${CORR_MIN:-0.60}" \
        python3 "$BASE/bin/yt_check.py")
  st=$(print -r -- "$out" | sed -n 's/.*"status": *"\([A-Z]*\)".*/\1/p')
  now=$(date +%s)
  beat "${st:-NOSTATUS}" "$out"

  case "$st" in
  OK)
    (( bad_since > 0 || off_since > 0 || blind_since > 0 )) && mlog "recovered: $out"
    bad_since=0; off_since=0; blind_since=0
    ;;

  UNKNOWN|FETCHFAIL|NOSTATUS|NOGOLDEN|NOCONFIG|ERROR|"")
    # The lookup or our own reference failed, not the stream. NEVER act on this - acting on it
    # is how a yt-dlp rate limit turns into a rotation that takes a perfectly healthy channel
    # off air. NOGOLDEN/NOCONFIG are configuration faults and ERROR is any yt_check.py
    # exception: none of them is evidence about the picture, and restarting ingest cannot fix
    # any of them. They reach here instead of the `*` arm below, which is for BLACK, FROZEN
    # and MISMATCH only - the statuses that do mean "YouTube is live and showing the wrong
    # thing". A catch-all there classified a missing golden reference as a bad picture and
    # killed a healthy publisher every FAIL_SECONDS indefinitely.
    (( blind_since == 0 )) && { blind_since=$now; mlog "lookup failing (not acting): $out"; }
    if (( now - blind_since >= BLIND_SECONDS )); then
      # Blind for a while. yt-dlp cannot tell us, so ask YouTube itself - the API knows
      # whether a broadcast is live without going anywhere near yt-dlp.
      if yt_api_ready; then
        api=$(yt_api_call status)
        if print -r -- "$api" | grep -q '"status": *"LIVE"'; then
          mlog "BLIND for $(( now - blind_since ))s, but the API confirms the channel IS live: $api"
          mlog "        picture checking is suspended until yt-dlp recovers; the stream itself is fine."
          blind_since=$now      # re-arm, so this repeats rather than spams
        elif print -r -- "$api" | grep -q '"status": *"OFFLINE"'; then
          mlog "BLIND for $(( now - blind_since ))s and the API says the channel is OFFLINE - acting on the API's word."
          if [[ "$MONITOR_ACTION" == "restart" ]]; then
            bring_live "blind+api-offline" || beat_sleep "$ROTATE_REQUEST_BACKOFF" BACKOFF
          else
            mlog "ACTION: log-only mode, not acting"
          fi
          blind_since=0; off_since=0; bad_since=0
          beat_sleep 60 SETTLING; continue
        else
          mlog "BLIND for $(( now - blind_since ))s and the API cannot answer either: $api"
          blind_since=$now
        fi
      else
        mlog "BLIND for $(( now - blind_since ))s and there are no API credentials to ask instead: $out"
        blind_since=$now
      fi
    fi
    ;;

  OFFLINE)
    (( off_since == 0 )) && { off_since=$now; mlog "channel reads OFFLINE, watching it: $out"; }
    if (( now - off_since >= OFFLINE_SECONDS )); then
      if [[ "$MONITOR_ACTION" == "restart" ]]; then
        bring_live "offline ${OFFLINE_SECONDS}s" || beat_sleep "$ROTATE_REQUEST_BACKOFF" BACKOFF
      else
        mlog "ACTION: log-only mode, channel OFFLINE for $(( now - off_since ))s and not acting"
      fi
      off_since=0; bad_since=0; blind_since=0
      beat_sleep 60 SETTLING; continue
    fi
    ;;

  *)  # BLACK, FROZEN, MISMATCH - YouTube is live but showing the wrong thing
    (( bad_since == 0 )) && { bad_since=$now; mlog "bad picture, watching it: $out"; }
    if (( now - bad_since >= FAIL_SECONDS )); then
      if [[ "$MONITOR_ACTION" == "restart" ]]; then
        # A bad picture with a DEAD CAMERA is something a publisher restart cannot fix. The
        # separate reader holds the last good frame over the top, so the picture stays exactly as
        # frozen as the camera left it, and a restart only drops the RTMP session - which trips
        # YouTube's enableAutoStop and FRAGMENTS the recording into short pieces (measured
        # 2026-09-19: five such restarts inside fifty minutes, all while the camera was
        # unreachable). So check the camera first. The reader reconnects on its own when the camera
        # comes back, and cam_ip_watcher is what re-discovers it after a DHCP move.
        # LIMIT: this needs an address to probe. If log/cam_ip is empty or missing - a tree that has
        # never run stream.sh - the guard cannot check anything and falls through to the restart,
        # which is the safe direction: acting on a bad picture beats ignoring one.
        cam_host=$(<"$CAMIP_FILE" 2>/dev/null)
        if [[ -n "$cam_host" ]] && ! nc -z -G 3 "$cam_host" 554 2>/dev/null; then
          mlog "ACTION: $st for $(( now - bad_since ))s but the CAMERA at $cam_host is not answering on 554 - NOT restarting the publisher: a restart cannot fix the camera and it would fragment the recording. The reader reconnects by itself."
        else
          # Restart exactly the publisher stream.sh started, via its pidfile and an identity check.
          # This used to be `pkill -9 -f "ffmpeg.*rtmp"`, which matched any ffmpeg whose command
          # line merely mentioned rtmp - a hand-run diagnostic, or a second copy of the project.
          # When there is no trustworthy pid, kill NOTHING and say so: a restarted-by-hand publisher
          # is a deliberate act, and guessing is how a watchdog kills something it does not own.
          pub_pid_x=""
          if pub_pid_x=$(pidfile_pid "$PUB_PID" ffmpeg rtmp); then
            mlog "ACTION: bad output on YouTube for $(( now - bad_since ))s ($st) - restarting publisher pid $pub_pid_x"
            kill -9 "$pub_pid_x" 2>/dev/null
          else
            mlog "ACTION: bad output on YouTube for $(( now - bad_since ))s ($st) - no usable pid in $PUB_PID; killed nothing"
          fi
        fi
      else
        mlog "ACTION: log-only mode, not restarting"
      fi
      bad_since=0
      beat_sleep 60 SETTLING; continue    # give it time to come back before judging again
    fi
    ;;
  esac
  sleep "$CHECK_INTERVAL"
done
