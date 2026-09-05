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
BASE="${BASE:-$HOME/Downloads/YTLive}"
source "$BASE/conf/stream.env"
MLOG="$BASE/log/monitor.log"
HEARTBEAT="$BASE/log/monitor.heartbeat"
mlog() { print -r -- "$(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$MLOG"; }

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

# The API is what makes this loop able to FIX things rather than just complain. conf/stream.env
# is sourced, not exported, so every call has to pass its settings explicitly.
YT_API="$BASE/bin/yt_api.py"
yt_api_ready() { [[ -s "$BASE/conf/yt_oauth.json" && -x "$YT_API" ]] }
yt_api_call() {
  BASE="$BASE" YT_TITLE_FMT="${YT_TITLE_FMT:-}" YT_PRIVACY="${YT_PRIVACY:-public}" \
  python3 "$YT_API" "$@" 2>&1
}

# One line of ground truth for status.sh and for stream.sh's are-you-still-alive check.
# Silence in monitor.log means "all checks passed", which is indistinguishable from "the
# monitor died" - this file tells them apart.
beat() { print -r -- "$(date +%s) ${1} ${2:-}" > "$HEARTBEAT" 2>/dev/null; }

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
  mlog "        Fix it with: $BASE/bin/yt_api.py auth   (rotation and self-healing stop without it)"
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
  if [[ "$BASE/log/basefill.jpg" -nt "$BASE/conf/golden.jpg" && -s "$BASE/log/basefill.jpg" ]]; then
    cp "$BASE/log/basefill.jpg" "$BASE/conf/golden.jpg" && mlog "golden reference refreshed from latest publisher start frame"
  fi

  out=$(BASE="$BASE" YT_CHANNEL="${YT_CHANNEL:-}" YT_WATCH_URL="${YT_WATCH_URL:-}" CORR_MIN="${CORR_MIN:-0.60}" \
        python3 "$BASE/bin/yt_check.py" 2>&1)
  st=$(print -r -- "$out" | sed -n 's/.*"status": *"\([A-Z]*\)".*/\1/p')
  now=$(date +%s)
  beat "${st:-NOSTATUS}" "$out"

  case "$st" in
  OK)
    (( bad_since > 0 || off_since > 0 || blind_since > 0 )) && mlog "recovered: $out"
    bad_since=0; off_since=0; blind_since=0
    ;;

  UNKNOWN|FETCHFAIL|NOSTATUS|"")
    # The lookup failed, not the stream. NEVER act on this - acting on it is how a yt-dlp
    # rate limit turns into a rotation that takes a perfectly healthy channel off air.
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
            bring_live "blind+api-offline" || sleep "$ROTATE_REQUEST_BACKOFF"
          else
            mlog "ACTION: log-only mode, not acting"
          fi
          blind_since=0; off_since=0; bad_since=0
          sleep 60; continue
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
        bring_live "offline ${OFFLINE_SECONDS}s" || sleep "$ROTATE_REQUEST_BACKOFF"
      else
        mlog "ACTION: log-only mode, channel OFFLINE for $(( now - off_since ))s and not acting"
      fi
      off_since=0; bad_since=0; blind_since=0
      sleep 60; continue
    fi
    ;;

  *)  # BLACK, FROZEN, MISMATCH - YouTube is live but showing the wrong thing
    (( bad_since == 0 )) && { bad_since=$now; mlog "bad picture, watching it: $out"; }
    if (( now - bad_since >= FAIL_SECONDS )); then
      if [[ "$MONITOR_ACTION" == "restart" ]]; then
        mlog "ACTION: bad output on YouTube for $(( now - bad_since ))s ($st) - restarting the publisher"
        pkill -9 -f "ffmpeg.*rtmp" 2>/dev/null
      else
        mlog "ACTION: log-only mode, not restarting"
      fi
      bad_since=0
      sleep 60; continue    # give it time to come back before judging again
    fi
    ;;
  esac
  sleep "$CHECK_INTERVAL"
done
