#!/bin/zsh
# Self-check loop: every CHECK_INTERVAL seconds, pull a frame from the PUBLIC YouTube
# live stream and compare it to conf/golden.jpg. Acts only on sustained failure, so
# people walking through and day/night light changes never trigger it.
set -u
BASE="${BASE:-$HOME/Downloads/YTLive}"
source "$BASE/conf/stream.env"
MLOG="$BASE/log/monitor.log"
mlog() { print -r -- "$(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$MLOG"; }

: ${CHECK_INTERVAL:=10}
: ${FAIL_STREAK:=6}          # consecutive bad checks before acting (6 x 10s = 1 min)
: ${MONITOR_ACTION:=restart}  # "restart" the streamer, or "log" to only report
# OFFLINE deserves far more patience than a bad picture. A YouTube broadcast that was just
# auto-created reads as OFFLINE for minutes while it spins up, and the old 1-minute streak
# meant we demanded a rotation before every fresh broadcast could ever come live - which
# livelocked the stream for 3.5h on 2026-09-05. Judge OFFLINE on a much longer window, and
# never ask for rotations back to back.
: ${OFFLINE_STREAK:=30}            # 30 x 10s = 5 min of continuous OFFLINE before acting
: ${ROTATE_REQUEST_BACKOFF:=900}   # silence after asking for a rotation (must exceed ROTATE_GRACE)

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

if [[ -z "${YT_CHANNEL:-}" && -z "${YT_WATCH_URL:-}" ]]; then
  mlog "FATAL: neither YT_CHANNEL nor YT_WATCH_URL set - monitor cannot run"
  exit 1
fi

mlog "monitor start: ${YT_CHANNEL:-$YT_WATCH_URL} every ${CHECK_INTERVAL}s, act after ${FAIL_STREAK} bad checks / ${OFFLINE_STREAK} OFFLINE checks (${MONITOR_ACTION})"
streak=0
while true; do
  if hold_active; then      # stream.sh is rotating, or YouTube is still spinning a new broadcast up
    streak=0; sleep "$CHECK_INTERVAL"; continue
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
  if [[ "$st" == "OK" ]]; then
    (( streak > 0 )) && mlog "recovered after ${streak} bad checks: $out"
    streak=0
  else
    streak=$(( streak + 1 ))
    need=$FAIL_STREAK
    [[ "$st" == "OFFLINE" ]] && need=$OFFLINE_STREAK
    mlog "check ${streak}/${need}: $out"
    if (( streak >= need )); then
      if [[ "$MONITOR_ACTION" == "restart" && "$st" == "OFFLINE" ]] && [[ -s "$BASE/conf/yt_oauth.json" && -x "$BASE/bin/yt_api.py" ]]; then
        # The whole point of the project: no live stream found, so MAKE one. Restarting
        # ingest cannot do this - only the API can.
        out=$(BASE="$BASE" python3 "$BASE/bin/yt_api.py" ensure-live 2>&1)
        if print -r -- "$out" | grep -q '"status": *"LIVE"'; then
          mlog "ACTION: channel was OFFLINE - brought it live via the API: $out"
          streak=0
          sleep 60
          continue
        fi
        mlog "ACTION: channel OFFLINE and the API could not fix it: $out"
        mlog "        falling back to a rotation request; backing off ${ROTATE_REQUEST_BACKOFF}s"
        touch "$BASE/log/rotate_now"
        streak=0
        sleep "$ROTATE_REQUEST_BACKOFF"
        continue
      elif [[ "$MONITOR_ACTION" == "restart" && "$st" == "OFFLINE" ]]; then
        # OFFLINE means YouTube has no broadcast. A quick publisher restart never fixes
        # that; only a proper stop -> gap -> start does (same as the 8h rotation), so ask
        # stream.sh to rotate. This is a REQUEST, not a command: stream.sh refuses it if it
        # rotated recently. It has to, because if the broadcast was ended by hand in Studio
        # nothing here can bring it back, and asking forever just holds the stream down.
        mlog "ACTION: channel OFFLINE for ${OFFLINE_STREAK} checks - requesting a broadcast rotation (stop, gap, start); backing off ${ROTATE_REQUEST_BACKOFF}s"
        touch "$BASE/log/rotate_now"
        streak=0
        sleep "$ROTATE_REQUEST_BACKOFF"
        continue
      elif [[ "$MONITOR_ACTION" == "restart" ]]; then
        mlog "ACTION: restarting the streamer (sustained bad output on YouTube: $st)"
        pkill -9 -f "ffmpeg.*rtmp" 2>/dev/null
      else
        mlog "ACTION: log-only mode, not restarting"
      fi
      streak=0
      sleep 60      # give it time to come back before judging again
    fi
  fi
  sleep "$CHECK_INTERVAL"
done
