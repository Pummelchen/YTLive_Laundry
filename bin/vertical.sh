#!/bin/zsh
# The 9:16 companion livestream - the feed YouTube puts in the Shorts feed.
#
# WHY THIS EXISTS
#   The 16:9 stream cannot be made vertical by a setting. YouTube's Studio "Dual stream"
#   toggle is per-broadcast, cannot be changed once live, is absent from the Data API, and
#   stream.sh mints a NEW broadcast at every 8h03m cut - so the toggle evaporates 3x a day.
#   The only route that survives unattended rotation is a second, independent broadcast with
#   its own stream key, pushed as true 9:16. That is what this script runs.
#
#   It is deliberately a SEPARATE launchd job from stream.sh. If this encoder dies, the 16:9
#   feed is untouched; if the 16:9 feed dies, this one keeps the channel lit.
#
# SHAPE OF THE FEED
#   The camera's ch00_0 is a 1920x3240 composite of three 1920x1080 views - ratio 0.593,
#   almost exactly 9:16 (0.5625). So the whole composite is scaled to 1080 wide and padded
#   by 48px top and bottom: no crop, no wasted pixels, all three views visible.
#
# ISOLATION
#   Never calls stream.sh, never touches its pidfiles, never ends a broadcast it did not
#   create: every API call here is scoped by YT_KEY/stream id (see active_broadcast()).
set -u
BASE="${BASE:-${0:A:h:h}}"
CONF="${CONF:-$BASE/conf/stream.env}"
VCONF="${VCONF:-$BASE/conf/vertical.env}"
LOG="$BASE/log/vertical.log"
PROG="$BASE/log/vertical.progress"
PIDFILE="$BASE/log/vertical.pid"
PUB_PID="$BASE/log/vertical.publisher.pid"
BSTATE="$BASE/log/vertical.broadcast"    # "<broadcast id> <epoch>" of the CURRENT vertical one
MASTER="$BASE/log/broadcast_started"     # the 16:9 feed's "<broadcast id> <epoch>": the clock this
                                         # feed follows, so both cuts land together
SLATE="$BASE/log/vertical_slate.jpg"
CAMIP_FILE="$BASE/log/cam_ip"
PLAYLIST="$BASE/conf/playlist.txt"
FF="$HOME/.local/bin/ffmpeg"
FONT="/System/Library/Fonts/Supplemental/Arial.ttf"

source "$BASE/bin/lib.sh"
source "$CONF"
[[ -r "$VCONF" ]] || { print -r -- "vertical: missing $VCONF"; exit 1; }
source "$VCONF"

: ${VERT_ENABLED:=no}
: ${VERT_KEY:=}
: ${VERT_URL:=rtmp://a.rtmp.youtube.com/live2}
: ${VERT_SIZE:=1080x1920}
: ${VERT_BITRATE:=2500k}
: ${VERT_AUDIO_BITRATE:=128k}
: ${VERT_FPS:=30}
: ${VERT_GOP:=60}
: ${VERT_ROTATE_HOURS:=8}
: ${VERT_ROTATE_MINUTES:=3}
: ${VERT_GAP:=45}                 # seconds of silence between ending and re-creating a broadcast
# How long past its OWN interval this feed waits before cutting on its own clock. The 16:9 cut
# takes up to ROTATE_MAX_WAIT + ROTATE_GAP + ROTATE_NATIVE_WAIT (600+60+360 = 1020 s) to name the
# successor, so a fallback that fired at exactly 8h10m would almost always cut a few seconds
# BEFORE the sync, and then cut again when the 16:9 id finally appeared - two cuts per cycle.
# 20 min keeps the normal path synced while still cutting at 8h30m if the other feed never moves.
: ${VERT_FALLBACK_GRACE:=1200}
: ${VERT_SLATE:=yes}              # stay live on a slate when the camera is gone
: ${VERT_START_ON_CAMERA:=yes}    # do not go public until the camera has been up once
: ${VERT_TITLE:=Live CCTV Batam - Ternak Laundry Bengkong (Shorts)}
: ${VERT_PRIVACY:=public}
: ${VERT_CAM_TIMEOUT:=5}
: ${VERT_CAM_PATH:=ch00_0}   # ch00_1/2 are the 640x1080 fallbacks
VERT_ROTATE_SECONDS=$(( VERT_ROTATE_HOURS * 3600 + VERT_ROTATE_MINUTES * 60 ))

[[ "${VERT_ENABLED}" == "yes" ]] || { print -r -- "vertical: disabled in $VCONF"; exit 0 }
[[ -n "${VERT_KEY}" ]] || { print -r -- "vertical: VERT_KEY is empty"; exit 1 }

vlog() { print -r -- "$(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$LOG"; }
say()  { print -r -- "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG"; }

# One instance only. launchd KeepAlive already guarantees this in the normal case, but a
# hand-run of this script while the agent is up would otherwise double-publish to one key,
# and two RTMP publishers on one stream key fight each other on YouTube.
if [[ -r "$PIDFILE" ]] && pid_is "$(<"$PIDFILE")" "vertical.sh"; then
  vlog "already running as pid $(<"$PIDFILE") - refusing a second copy"
  exit 0
fi
print -r -- "$$" > "$PIDFILE"
trap 'rm -f "$PIDFILE"; [[ -n "${PUBPID:-}" ]] && kill "$PUBPID" 2>/dev/null' EXIT INT TERM

# --- API helpers, all scoped to THIS stream key -----------------------------------------
# YT_KEY is what yt_api.py's read_key() prefers, so a single env var is enough to make every
# command below operate on the vertical stream instead of the configured 16:9 one.
vapi() {
  BASE="$BASE" YT_KEY="$VERT_KEY" YT_TEMPLATE="${VERT_TEMPLATE:-$BASE/conf/vertical_template.json}" \
  YT_PRIVACY="$VERT_PRIVACY" YT_TITLE_FMT="$VERT_TITLE" \
  YT_TOKEN_TTL_DAYS="${YT_TOKEN_TTL_DAYS:-0}" \
  YT_QUOTA_COOLDOWN="${YT_QUOTA_COOLDOWN:-21600}" \
  python3 "$BASE/bin/yt_api.py" "$@" 2>&1
}

cam_ip() {
  local ip
  ip=$(<"$CAMIP_FILE" 2>/dev/null) || ip=""
  [[ -n "$ip" ]] || ip="${CAM_URL#*://}"; ip="${ip%%/*}"; ip="${ip%%:*}"
  print -r -- "$ip"
}

cam_up() { nc -z -G "$VERT_CAM_TIMEOUT" "$(cam_ip)" 554 2>/dev/null }

broadcast_id() { sed -n '1s/ .*//p' "$BSTATE" 2>/dev/null }
master_id() { sed -n '1s/ .*//p' "$MASTER" 2>/dev/null; }

# Called once per loop with the id in the 16:9 clock file. 0 means: that broadcast was started
# after the last one this feed cut for, so cut now. The FIRST id ever seen is only adopted
# (MASTER_SEEN), never acted on - a vertical process that starts mid-segment must not cut the
# live broadcast just because it is starting. With no vertical broadcast live there is nothing
# to cut, so the id is adopted too; otherwise the next loop would cut the broadcast that the
# start-up path is about to create.
sync_pending() {
  local mid=$1
  [[ -n "$mid" ]] || return 1
  if [[ -z "${MASTER_SEEN:-}" ]]; then
    MASTER_SEEN=$mid
    return 1
  fi
  [[ "$mid" != "$MASTER_SEEN" ]] || return 1
  [[ -n "$(broadcast_id)" ]] || { MASTER_SEEN=$mid; return 1; }
  return 0
}

broadcast_age() {
  local at
  at=$(sed -n '1s/[^ ]* //p' "$BSTATE" 2>/dev/null)
  [[ "$at" == <-> ]] || { print 0; return }
  print $(( $(date +%s) - at ))
}

# --- the slate --------------------------------------------------------------------------
# A still that says plainly what is happening, built ONCE from the last good camera frame so
# it looks like the shop rather than a black box. Regenerated whenever a newer frame exists.
make_slate() {
  local src="$BASE/log/lastframe.jpg"
  [[ -s "$src" ]] || src="$BASE/log/basefill.jpg"
  local tf="$BASE/log/vertical_slate.txt"
  # Short lines, small type: at 1080 wide the long horizontal card text overflows and gets
  # clipped at both edges (seen 2026-10-28 05:31). Four short lines read better on a phone.
  print -r -- "LAUNDRY BUKA 24 JAM" > "$tf"
  print -r -- "TETAP BEROPERASI" >> "$tf"
  print -r -- "Kamera CCTV kembali" >> "$tf"
  print -r -- "dalam beberapa jam" >> "$tf"
  print -r -- "$(date '+%Y-%m-%d %H:%M') WIB" >> "$tf"
  # Text ABOVE the photograph (operator request, 2026-10-28): the message sits at y=320
  # and the frame at y=700, so a phone viewer reads the sign first and the shop second.
  # 1080x1920, not a letterboxed 16:9 still: a 16:9 card inside a 9:16 frame is two thirds
  # empty bars, which looks broken in the Shorts feed. Brand colour, the last camera frame
  # fitted to the width, and the message underneath.
  if [[ -s "$src" && -r "$FONT" ]]; then
    "$FF" -y -v error -f lavfi -i "color=c=0x0b1a2a:s=1080x1920" -i "$src" \
      -filter_complex "[1:v]eq=brightness=-0.25:saturation=0.7,scale=1080:-2[p];[0:v][p]overlay=0:700[v];[v]drawtext=fontfile=${FONT}:textfile=${tf}:fontcolor=white:fontsize=42:line_spacing=16:box=1:boxcolor=black@0.55:boxborderw=26:x=(w-text_w)/2:y=320" \
      -frames:v 1 -q:v 4 "$SLATE" 2>/dev/null
  fi
  [[ -s "$SLATE" ]] && return 0
  "$FF" -y -v error -f lavfi -i "color=c=0x0b1a2a:s=1080x1920" -frames:v 1 "$SLATE" 2>/dev/null
}

# --- the encoder --------------------------------------------------------------------------
# Two sources, one chain. The camera is the composite (1920x3240); the slate is 1080p. Both
# are scaled to 1080 wide and padded to 1080x1920, so the output geometry never changes and
# YouTube never sees a resolution switch on a live stream.
CAMPATH_FILE="$BASE/log/vertical.campath"

# Which RTSP path this feed should use. Normally the same ch00_0 the 16:9 feed uses, but a
# cheap camera may allow only ONE client per channel; when that happens an automatic fall
# back to ch00_1 (the 640x1080 substream) is better than a feed that never comes up, and much
# better than an operator having to edit conf at 5am.
cam_path() {
  local p
  p=$(<"$CAMPATH_FILE" 2>/dev/null)
  print -r -- "${p:-${VERT_CAM_PATH}}"
}

publisher_args() {
  local mode="$1" ip url
  ip=$(cam_ip)
  local path
  path=$(cam_path)
  [[ -n "$path" ]] || path="$VERT_CAM_PATH"
  url="rtsp://${ip}/${path}"
  if [[ "$mode" == camera ]]; then
    # Read the FAN-OUT from the 16:9 reader, not a second RTSP session: two clients on this
    # camera corrupt the H.264 within hours and the encoder freezes every couple of minutes.
    # A 5 s timeout means a dead feed errors out and the watchdog restarts us, instead of
    # blocking forever.
    CAM_IN=( -f mpegts -i "udp://127.0.0.1:5001?fifo_size=8000000&overrun_nonfatal=1&buffer_size=8388608&timeout=5000000" )
  else
    CAM_IN=( -re -loop 1 -framerate 15 -i "$SLATE" )
  fi
}

start_publisher() {
  local mode="$1" VFILTER
  publisher_args "$mode"
  if [[ "$mode" == camera ]]; then
    # ONE panel, exactly the one the 16:9 feed shows (CROP_GEOM = the top 1080p view).
    # Showing the whole 1920x3240 composite was both wrong (three cameras in a 9:16 frame)
    # and expensive: scaling 3240 lines to 1824 at 30 fps is what made this encoder stall
    # every few minutes on the 2015 i5. Cropping first removes ~85% of the pixels.
    VFILTER="crop=${CROP_GEOM:-1920:1080:0:0},scale=1080:-2:flags=bilinear,pad=1080:1920:0:(oh-ih)/2:color=0x0b1a2a,fps=${VERT_FPS},format=yuv420p"
  else
    VFILTER="scale=1080:-2:flags=bilinear,pad=1080:1920:0:(oh-ih)/2:color=0x0b1a2a,fps=${VERT_FPS},format=yuv420p"
  fi
  local -a AUDIO_IN
  if [[ -s "$PLAYLIST" ]]; then
    AUDIO_IN=( -re -stream_loop -1 -f concat -safe 0 -i "$PLAYLIST" )
  else
    AUDIO_IN=( -f lavfi -i "anullsrc=r=48000:cl=stereo" )
  fi
  : > "$PROG"
  "$FF" -y -hide_banner -loglevel error -nostdin -progress "$PROG" \
    -thread_queue_size 8192 "${CAM_IN[@]}" \
    -thread_queue_size 4096 "${AUDIO_IN[@]}" \
    -filter_complex "[0:v]${VFILTER}[v]" \
    -map "[v]" -map 1:a:0 \
    -c:v h264_videotoolbox -b:v "$VERT_BITRATE" -realtime 1 -g "$VERT_GOP" -pix_fmt yuv420p \
    -c:a aac -b:a "$VERT_AUDIO_BITRATE" -ar 48000 -ac 2 \
    -f flv -flvflags no_duration_filesize \
    "${VERT_URL%/}/${VERT_KEY}" >>"$BASE/log/vertical.publisher.log" 2>&1 &
  PUBPID=$!
  print -r -- "$PUBPID" > "$PUB_PID"
  vlog "PUBLISHER start mode=$mode pid=$PUBPID key=...${VERT_KEY[-4,-1]}"
}

stop_publisher() {
  [[ -n "${PUBPID:-}" ]] || return 0
  kill -9 "$PUBPID" 2>/dev/null
  wait "$PUBPID" 2>/dev/null
  vlog "PUBLISHER stopped pid=$PUBPID"
  PUBPID=""
}

# --- broadcast lifecycle ---------------------------------------------------------------
prepare_broadcast() {
  local out bid
  out=$(vapi prepare)
  say "PREPARE: $out"
  bid=$(print -r -- "$out" | python3 -c 'import json,sys
try: d=json.loads(sys.stdin.read());
except Exception: sys.exit(1)
print(d.get("broadcast_id") or "")' 2>/dev/null)
  [[ -n "$bid" ]] || { vlog "PREPARE failed: $out"; return 1 }
  print -r -- "$bid $(date +%s)" > "$BSTATE"
  vlog "BROADCAST ready $bid"
  return 0
}

rotate() {
  # The age is reported, not the configured interval: since 2026-10-28 most cuts are triggered
  # by the 16:9 clock, so "after 490 min" would be wrong for every one of them.
  vlog "ROTATE: ending the vertical broadcast (age $(( $(broadcast_age) / 60 )) min)"

  stop_publisher
  vapi end >>"$LOG" 2>&1
  rm -f "$BSTATE"
  sleep "$VERT_GAP"
  if prepare_broadcast; then
    start_publisher "$1"
    return 0
  fi
  vlog "ROTATE: could not create the successor - will retry"
  return 1
}

# --- boot: wait for the camera (first time only) ----------------------------------------
if [[ "$VERT_START_ON_CAMERA" == "yes" && "$VERT_SLATE" != "yes" ]]; then
  while ! cam_up; do
    vlog "waiting for the camera on $(cam_ip):554 before starting"
    sleep 60
  done
fi

# --- main loop ---------------------------------------------------------------------------
PUBPID=""
DEATHS=0
FALLBACKS=0
SLATE_UNTIL=0
LAST_WAIT_LOG=0
LAST_LIVE_NUDGE=0
LAST_QUOTA_LOG=0
MASTER_SEEN=""
LAST_LIVE_CHECK=0
MODE=""            # camera | slate
STUCK=0
LAST_FRAME=""
if [[ -s "$SLATE" ]]; then :; else make_slate; fi

while true; do
  if (( $(date +%s) < SLATE_UNTIL )); then
    # Post-crash cooldown: the camera may accept on 554 while its encoder is still booting.
    WANT=slate
  elif cam_up; then
    WANT=camera
  elif [[ "$VERT_SLATE" == "yes" ]]; then
    WANT=slate
  else
    WANT=none
  fi

  # Do not go public with a slate on a channel that has never had the vertical feed up;
  # after the first camera sighting the slate fallback takes over normally.
  if [[ "$VERT_START_ON_CAMERA" == "yes" && ! -e "$BASE/log/vertical.seen_camera" ]]; then
    if [[ "$WANT" == "camera" ]]; then
      : > "$BASE/log/vertical.seen_camera"
    else
      WANT=none
    fi
  fi

  if [[ "$WANT" == "none" ]]; then
    [[ -n "${PUBPID:-}" ]] && { stop_publisher; }
    if (( $(date +%s) >= LAST_WAIT_LOG + 300 )); then
      vlog "waiting: camera $(cam_ip):554 not answering - not going public with a slate (VERT_START_ON_CAMERA=$VERT_START_ON_CAMERA)"
      LAST_WAIT_LOG=$(date +%s)
    fi
    sleep 20
    continue
  fi

  # 1a. the recorded broadcast may be DEAD. YouTube auto-stops it ~9 s after ingest stops,
  # so after a publisher outage the state file still names an ended broadcast and this loop
  # would happily restart an encoder that can never appear. yt-dlp answers "post_live" for
  # free, so this costs no quota; it runs at most every couple of minutes.
  if [[ -s "$BSTATE" ]] && (( $(date +%s) >= LAST_LIVE_CHECK + 120 )); then
    LAST_LIVE_CHECK=$(date +%s)
    local ls
    ls=$(~/.local/bin/yt-dlp --no-warnings --skip-download --print "%(live_status)s" \
          "https://www.youtube.com/watch?v=$(broadcast_id)" 2>/dev/null | head -1)
    if [[ "$ls" == "post_live" || "$ls" == "was_live" || "$ls" == "not_live" ]]; then
      # A recorded id that ended is not proof that THIS stream is off air: an earlier prepare
      # may have left a different broadcast bound to the same stream and YouTube auto-started
      # that one instead. On 2026-10-28 19:23 that produced a live broadcast while the state
      # named a never-started one, and the supervisor enforced settings on the wrong video.
      local st live_id live_start
      st=$(vapi status 2>/dev/null)
      live_id=$(print -r -- "$st" | python3 -c 'import json,sys
try: d=json.load(sys.stdin)
except Exception: sys.exit(0)
print(d.get("broadcast_id") or "") if d.get("status")=="LIVE" else print("")' 2>/dev/null)
      if [[ -n "$live_id" ]]; then
        live_start=$(print -r -- "$st" | python3 -c 'import json,time,sys
try: d=json.load(sys.stdin)
except Exception: sys.exit(0)
print(int(d.get("started_epoch") or time.time()))' 2>/dev/null)
        vlog "BROADCAST: recorded id ended ($ls) but $live_id is LIVE on this stream - adopting it instead of creating another"
        print -r -- "$live_id ${live_start:-$(date +%s)}" > "$BSTATE"
      else
        vlog "BROADCAST: $(broadcast_id) has ENDED ($ls) - dropping the stale state and preparing a new one"
        rm -f "$BSTATE"
        stop_publisher
      fi
    fi
  fi

  # 1b. a broadcast must exist BEFORE ingest starts (YouTube only auto-starts a bound one)
  if [[ -z "$(broadcast_id)" || ! -s "$BSTATE" ]]; then
    stop_publisher        # there is nothing to publish to; do not push into a dead room
    # A quota refusal cannot succeed by retrying: back off instead of writing two log lines
    # every 30 s for hours (measured 2026-10-28: quota out from 05:46 to ~11:40).
    if prepare_broadcast; then
      :
    else
      if [[ -s "$BASE/log/quota_exhausted" ]]; then sleep 300; else sleep 30; fi
      continue
    fi
  fi

  # 2a. SYNC: follow the 16:9 rotation. Both feeds must cut at the same moment, so the 16:9
  # broadcast is the clock. stream.sh rewrites log/broadcast_started with the NEW id when its
  # successor goes live, which is exactly when this feed should start its own cut - the two
  # new broadcasts then begin within a minute of each other.
  mid=$(master_id)
  if sync_pending "$mid"; then
    vlog "SYNC: the 16:9 feed rotated to $mid - rotating this one too"
    MASTER_SEEN=$mid
    rotate "$WANT" || { sleep 60; continue; }
    MODE="$WANT"; STUCK=0; LAST_FRAME=""
    continue
  fi

  # 2b. fallback: the age clock still applies if a sync was missed (a long outage of the
  # other feed, a restart that never saw a change). The grace keeps this from firing during
  # the up-to-1020 s between the 16:9 cut and its successor's id appearing - that would cut
  # twice.
  if (( $(broadcast_age) > VERT_ROTATE_SECONDS + VERT_FALLBACK_GRACE )); then
    rotate "$WANT" || { sleep 60; continue; }
    MODE="$WANT"; STUCK=0; LAST_FRAME=""
  fi

  # 3. start / switch / restart the encoder
  if [[ -z "${PUBPID:-}" ]] || ! kill -0 "$PUBPID" 2>/dev/null; then
    if [[ -n "${PUBPID:-}" ]]; then
      DEATHS=$(( DEATHS + 1 ))
      # Log WHY it went, not just that it did: an unexplained exit every few minutes is a
      # different fault from YouTube closing the ingest (224), an input timeout, or a kill (137).
      local death_rc=0
      wait "$PUBPID" 2>/dev/null; death_rc=$?
      vlog "PUBLISHER exited on its own (mode=$MODE, rc=$death_rc, ${DEATHS} in a row) - restarting"
      if (( DEATHS >= 3 )); then
        if [[ "$MODE" == "camera" ]]; then
          SLATE_UNTIL=$(( $(date +%s) + 120 ))
          vlog "WARNING: 3 encoder deaths in camera mode - holding the slate for 120s before retrying the camera (it may still be booting)"
          DEATHS=0
          FALLBACKS=$(( FALLBACKS + 1 ))
          if (( FALLBACKS >= 2 )) && [[ "$(cam_path)" != "ch00_1" ]]; then
            # Two full cooldowns and still no video: stop assuming the problem is timing.
            print -r -- "ch00_1" > "$CAMPATH_FILE"
            vlog "FALLBACK: ch00_0 keeps failing after ${FALLBACKS} cooldowns - switching this feed to ch00_1 (640x1080 substream) so it can still go live; delete log/vertical.campath to go back"
            DEATHS=0
          fi
        else
          vlog "WARNING: the encoder keeps dying in slate mode too - check bin/vertical.publisher.log"
          sleep 30
        fi
      fi
    else
      DEATHS=0
    fi
    [[ "$WANT" == "slate" ]] && make_slate
    start_publisher "$WANT"
    MODE="$WANT"; STUCK=0; LAST_FRAME=""
  elif [[ "$WANT" != "$MODE" ]]; then
    vlog "SOURCE switch $MODE -> $WANT"
    stop_publisher
    [[ "$WANT" == "slate" ]] && make_slate
    start_publisher "$WANT"
    MODE="$WANT"; STUCK=0; LAST_FRAME=""
  fi

  # 4. stall watchdog: progress comes from ffmpeg itself, so this measures frames, not hope
  sleep 5
  local_cur=$(grep -a '^frame=' "$PROG" 2>/dev/null | tail -1 | cut -d= -f2)
  if [[ -n "$local_cur" && "$local_cur" == "$LAST_FRAME" ]]; then
    STUCK=$(( STUCK + 5 ))
    if (( STUCK >= 30 )); then
      vlog "WATCHDOG: output frozen ${STUCK}s - restarting publisher"
      stop_publisher
      start_publisher "$WANT"
      STUCK=0; LAST_FRAME=""
      continue
    fi
  else
    STUCK=0
    DEATHS=0
    LAST_FRAME="$local_cur"
  fi

  # 5. if ingest is flowing but YouTube has not gone live, let the API drive the transition
  #    (bounded: once every 60s, and never in the first minute after a prepare)
  if (( $(date +%s) >= LAST_LIVE_NUDGE + 60 )) && (( $(broadcast_age) > 60 )); then
    local_out=$(vapi status 2>/dev/null)
    # The API being exhausted is not "the feed is dark". Prodding ensure-live every minute
    # against an exhausted quota only writes two log lines a minute and can never succeed
    # (measured 2026-10-28 05:48-05:51), so back off and say so once an hour.
    if print -r -- "$local_out" | grep -q '"status": *"QUOTA"'; then
      if (( $(date +%s) >= LAST_QUOTA_LOG + 3600 )); then
        vlog "API quota exhausted - cannot verify liveness that way; the encoder keeps running and this will retry after the reset"
        LAST_QUOTA_LOG=$(date +%s)
      fi
      LAST_LIVE_NUDGE=$(( $(date +%s) + 600 ))
      continue
    fi
    local_st=$(print -r -- "$local_out" | python3 -c 'import json,sys
try: print(json.loads(sys.stdin.read()).get("status",""))
except Exception: print("")' 2>/dev/null)
    if [[ "$local_st" == "LIVE" ]]; then
      # apply the template (description, tags, privacy) once per broadcast
      if [[ "$(cat "$BASE/log/vertical.enforced" 2>/dev/null)" != "$(broadcast_id)" ]]; then
        vapi enforce "$(broadcast_id)" >>"$LOG" 2>&1
        broadcast_id > "$BASE/log/vertical.enforced"
      fi
    elif [[ "$local_st" != "LIVE" ]]; then
      vlog "not live yet - ensure-live"
      vapi ensure-live >>"$LOG" 2>&1
      LAST_LIVE_NUDGE=$(date +%s)
      STUCK=0
    fi
  fi
done
