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
  # Text ABOVE the photograph (operator request, 2026-10-28): the message sits at y=240
  # and the frame at y=700, so a phone viewer reads the sign first and the shop second.
  # 1080x1920, not a letterboxed 16:9 still: a 16:9 card inside a 9:16 frame is two thirds
  # empty bars, which looks broken in the Shorts feed. Brand colour, the last camera frame
  # fitted to the width, and the message underneath.
  if [[ -s "$src" && -r "$FONT" ]]; then
    "$FF" -y -v error -f lavfi -i "color=c=0x0b1a2a:s=1080x1920" -i "$src" \
      -filter_complex "[1:v]eq=brightness=-0.25:saturation=0.7,scale=1080:-2[p];[0:v][p]overlay=0:700[v];[v]drawtext=fontfile=${FONT}:textfile=${tf}:fontcolor=white:fontsize=42:line_spacing=16:box=1:boxcolor=black@0.55:boxborderw=26:x=(w-text_w)/2:y=240" \
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
    CAM_IN=( -rtsp_transport tcp -timeout 8000000 -i "$url" )
  else
    CAM_IN=( -re -loop 1 -framerate 15 -i "$SLATE" )
  fi
}

start_publisher() {
  local mode="$1"
  publisher_args "$mode"
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
    -filter_complex "[0:v]fps=${VERT_FPS},scale=1080:-2:flags=bilinear,pad=1080:1920:0:(oh-ih)/2:color=0x0b1a2a,format=yuv420p[v]" \
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
  vlog "ROTATE: ending the vertical broadcast after $(( VERT_ROTATE_SECONDS / 60 )) min"
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

  # 1. a broadcast must exist BEFORE ingest starts (YouTube only auto-starts a bound one)
  if [[ -z "$(broadcast_id)" || ! -s "$BSTATE" ]]; then
    prepare_broadcast || { sleep 30; continue; }
  fi

  # 2. rotation, measured on the BROADCAST's age so a restart cannot extend a segment
  if (( $(broadcast_age) > VERT_ROTATE_SECONDS )); then
    rotate "$WANT" || { sleep 60; continue; }
    MODE="$WANT"; STUCK=0; LAST_FRAME=""
  fi

  # 3. start / switch / restart the encoder
  if [[ -z "${PUBPID:-}" ]] || ! kill -0 "$PUBPID" 2>/dev/null; then
    if [[ -n "${PUBPID:-}" ]]; then
      DEATHS=$(( DEATHS + 1 ))
      vlog "PUBLISHER exited on its own (mode=$MODE, ${DEATHS} in a row) - restarting"
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
    local_st=$(vapi status | python3 -c 'import json,sys
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
