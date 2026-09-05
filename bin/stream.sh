#!/bin/zsh
# CCTV video + MP3 music -> YouTube, 24/7.
#
# TWO-PROCESS DESIGN (this is the important bit):
#   READER    : camera RTSP -> local UDP.  Restarts freely whenever the camera dies.
#   PUBLISHER : local UDP + music -> YouTube RTMP.  Runs CONTINUOUSLY.
# UDP never signals EOF, so a dead reader just means "no packets" and the publisher's
# overlay holds the last good frame. The RTMP session to YouTube is therefore NEVER torn
# down by a camera dropout - which is what used to cause ~18s of black on every restart.
# CCTV audio is deliberately NEVER mapped (privacy).
set -u
BASE="${BASE:-$HOME/Downloads/YTLive}"
CONF="${CONF:-$BASE/conf/stream.env}"
LOG="$BASE/log/stream.log"
PROG="$BASE/log/progress.txt"
SNAP="$BASE/log/lastframe.jpg"
BASEIMG="$BASE/log/basefill.jpg"
CAMIP_FILE="$BASE/log/cam_ip"   # runtime source of truth for the camera address
ROTATE_FLAG="$BASE/log/rotating"    # holds an epoch deadline: the monitor stands down until then
ROTATE_NOW="$BASE/log/rotate_now"   # touch this file to force a rotation immediately
YTDLP="$HOME/.local/bin/yt-dlp"
YT_API="$BASE/bin/yt_api.py"
YT_OAUTH="$BASE/conf/yt_oauth.json"
# The API is the only thing that can actually CREATE a broadcast. Pushing RTMP at a stream
# key never has on this channel (see yt_api.py). It switches itself on as soon as
# conf/yt_oauth.json exists, so the streamer keeps working unconfigured - just without the
# ability to bring the channel live on its own.
yt_api_ready() { [[ -s "$YT_OAUTH" && -x "$YT_API" ]] }
# conf/stream.env is sourced, not exported, so settings there are invisible to a subprocess
# unless passed explicitly. Route every API call through here so none of them get forgotten.
yt_api_call() {
  BASE="$BASE" \
  YT_TITLE_FMT="${YT_TITLE_FMT:-}" \
  YT_PRIVACY="${YT_PRIVACY:-public}" \
  python3 "$YT_API" "$@" 2>&1
}
FF="$HOME/.local/bin/ffmpeg"
source "$CONF"

log() { print -r -- "$(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$LOG"; }
/usr/bin/caffeinate -ism -w $$ &

# --- HOUSEKEEPING ------------------------------------------------------------
# Nothing here used to bound the logs. publisher.log is ffmpeg's stderr and grows forever;
# a noisy camera can turn that into gigabytes on a machine whose only job is to stay up.
: ${LOG_MAX_BYTES:=2097152}       # 2 MB per log file
: ${HOUSEKEEP_EVERY:=300}         # seconds between housekeeping passes
: ${MONITOR_STALE:=600}           # heartbeat older than this means the watchdog is hung
MON_HEARTBEAT="$BASE/log/monitor.heartbeat"

# Trim in place rather than rotating: ffmpeg holds an O_APPEND fd on publisher.log, so
# renaming the file would leave it writing to an unlinked inode forever. Rewriting the same
# inode keeps every existing writer pointed at the right place.
trim_log() {
  local f="$1" sz tmp
  [[ -f "$f" ]] || return 0
  sz=$(/usr/bin/stat -f %z "$f" 2>/dev/null) || return 0
  (( sz > LOG_MAX_BYTES )) || return 0
  tmp="${TMPDIR:-/tmp}/ytlive-trim.$$"
  if tail -c $(( LOG_MAX_BYTES / 2 )) "$f" > "$tmp" 2>/dev/null; then
    cat "$tmp" > "$f"
    log "HOUSEKEEP: trimmed $(basename $f) from ${sz} to $(/usr/bin/stat -f %z "$f") bytes"
  fi
  rm -f "$tmp"
}

housekeep() {
  local f
  # log/progress.txt is deliberately NOT trimmed: ffmpeg writes it at a fixed offset, so
  # rewriting it underneath would corrupt the frame counter the watchdog below reads. It is
  # truncated at every publisher start instead, which bounds it to one rotation's worth.
  for f in "$BASE/log/publisher.log" "$BASE/log/stream.log" "$BASE/log/reader.log" \
           "$BASE/log/monitor.log" "$HOME/Library/Logs/YTLive/"*.log(N); do
    trim_log "$f"
  done
}

# Watchdog for the watchdog. launchd KeepAlive restarts a monitor that EXITS, but not one
# that hangs - and a hung monitor is silent in exactly the same way a healthy one is.
check_monitor() {
  local beat age
  [[ -f "$MON_HEARTBEAT" ]] || { log "MONITOR: no heartbeat file yet - is com.user.cctv-monitor loaded?"; return; }
  beat=$(/usr/bin/stat -f %m "$MON_HEARTBEAT" 2>/dev/null) || return
  age=$(( $(date +%s) - beat ))
  (( age < MONITOR_STALE )) && return
  if launchctl list 2>/dev/null | grep -q com.user.cctv-monitor; then
    log "MONITOR: heartbeat is ${age}s old - watchdog is hung. Killing it so launchd restarts it."
    pkill -9 -f "zsh.*yt_monitor.sh" 2>/dev/null
  else
    log "MONITOR: heartbeat is ${age}s old and com.user.cctv-monitor is NOT loaded - THE STREAM IS UNWATCHED. Fix: launchctl load -w ~/Library/LaunchAgents/com.user.cctv-monitor.plist"
  fi
}

[[ -z "$YT_KEY" ]] && { log "FATAL: YT_KEY empty in $CONF"; exit 1; }
DEST="${YT_URL}/${YT_KEY}"
UDP="udp://127.0.0.1:${UDP_PORT}"

# --- audio ------------------------------------------------------------------
[[ "$RESHUFFLE_ON_START" == "yes" ]] && { "$BASE/bin/shuffle_playlist.sh" >>"$LOG" 2>&1 && log "playlist reshuffled"; }
[[ ! -s "$PLAYLIST" ]] && { log "playlist missing, generating"; "$BASE/bin/shuffle_playlist.sh" >>"$LOG" 2>&1; }
if [[ -s "$PLAYLIST" ]]; then
  AUDIO_IN=( -re -stream_loop -1 -f concat -safe 0 -i "$PLAYLIST" )
  log "audio: MP3 playlist ($(grep -c '^file ' "$PLAYLIST") tracks, looping)"
else
  AUDIO_IN=( -f lavfi -i anullsrc=r=48000:cl=stereo )
  log "WARNING: no playlist - SILENT audio"
fi

GOP=$(( OUT_FPS * 2 ))
VENC=( -c:v h264_videotoolbox -b:v "$ENC_BITRATE" -realtime 1 -g "$GOP" -pix_fmt yuv420p )
AUD_OUT=( -c:a "$AAC_ENC" -b:a "$AUD_BITRATE" -ar 48000 -ac 2 -af "$AUDIO_FILTER" )
CAM_HOST="${CAM_URL#*://}"; CAM_HOST="${CAM_HOST%%/*}"; CAM_HOST="${CAM_HOST%%:*}"
CAM_PATH="${CAM_URL##*/}"
print -r -- "$CAM_HOST" > "$CAMIP_FILE"

# --- CAMERA IP WATCHER -------------------------------------------------------
# The camera is DHCP and its firmware ignores ONVIF config writes, so it cannot be
# pinned to a fixed address. After a power cut it moves (it went .2 -> .3 on
# 2026-08-31, and this Mac's own LAN port then took the vacated .2). Every 30s we do
# a cheap TCP probe of the current address; only if that fails do we run ONVIF
# discovery. The reader picks the new address up on its next reconnect.
cam_ip_watcher() {
  local cur newip
  while true; do
    sleep 30
    cur=$(<"$CAMIP_FILE")
    if nc -z -G 3 "$cur" 554 2>/dev/null; then
      continue                       # still there, nothing to do
    fi
    log "CAM-WATCH: $cur not answering on 554, running ONVIF discovery"
    newip=$(python3 "$BASE/bin/find_cam.py" 2>/dev/null)
    if [[ -n "$newip" && "$newip" != "$cur" ]]; then
      print -r -- "$newip" > "$CAMIP_FILE"
      log "CAM-WATCH: camera moved $cur -> $newip (reader will follow)"
      /usr/bin/sed -i '' "s|^CAM_URL=\"rtsp://[0-9.]*/|CAM_URL=\"rtsp://${newip}/|" "$CONF" 2>/dev/null
    elif [[ -n "$newip" ]]; then
      log "CAM-WATCH: discovery still reports $newip - camera itself is down"
    else
      log "CAM-WATCH: no ONVIF camera found on the LAN"
    fi
  done
}

cam_filters=()
case "$MODE" in
  crop)   cam_filters+=("crop=${CROP_GEOM}") ;;
  encode) cam_filters+=("scale=${ENC_SIZE%x*}:-2" "pad=${ENC_SIZE/x/:}:(ow-iw)/2:(oh-ih)/2") ;;
esac
[[ -n "$DENOISE"    ]] && cam_filters+=("$DENOISE")
[[ -n "$SHARPEN"    ]] && cam_filters+=("$SHARPEN")
[[ -n "$SATURATION" ]] && cam_filters+=("$SATURATION")
CHAIN="${(j:,:)cam_filters}"
SIZE="${ENC_SIZE}"
[[ "$MODE" == "crop" ]] && SIZE="${CROP_GEOM%%:*}x$(print -r -- ${CROP_GEOM} | cut -d: -f2)"

# --- READER: camera -> local UDP, restarts on its own -----------------------
reader_loop() {
  local backoff=2 start dur ip url
  while true; do
    ip=$(<"$CAMIP_FILE")
    url="rtsp://${ip}/${CAM_PATH}"
    start=$(date +%s)
    "$FF" -v error -rtsp_transport tcp -timeout 15000000 -fflags +genpts \
      -i "$url" -c:v copy -an -f mpegts "${UDP}?pkt_size=1316&bitrate=20000000" 2>>"$BASE/log/reader.log"
    dur=$(( $(date +%s) - start ))
    (( dur > 30 )) && backoff=2 || backoff=$(( backoff < 20 ? backoff*2 : 20 ))
    log "READER: feed from $ip ended after ${dur}s, retrying in ${backoff}s (YouTube unaffected)"
    sleep "$backoff"
  done
}

# --- PUBLISHER: local UDP + music -> YouTube, stays up ----------------------
start_publisher() {
  : > "$PROG"
  # Refresh the filler still with one quick grab from the camera. Done here (not as a
  # second output on the publisher) because a second output stalls the whole filter graph.
  "$FF" -y -v error -rtsp_transport tcp -timeout 8000000 -i "$CAM_URL" \
        -frames:v 1 -vf "${CHAIN}" -q:v 6 "$SNAP" 2>/dev/null
  local -a BASE_IN
  if [[ -s "$SNAP" ]] && cp "$SNAP" "$BASEIMG" 2>/dev/null; then
    BASE_IN=( -re -loop 1 -framerate 2 -i "$BASEIMG" )   # decode 2/s, fps filter fans out to OUT_FPS
  else
    BASE_IN=( -re -f lavfi -i "color=c=${FILLER_BG}:s=${SIZE}:r=${OUT_FPS}" )
  fi
  "$FF" -y -hide_banner -loglevel warning -progress "$PROG" \
    "${BASE_IN[@]}" \
    -thread_queue_size 16384 -fflags +genpts+discardcorrupt -itsoffset "$CAM_DELAY" \
    -f mpegts -i "${UDP}?fifo_size=8000000&overrun_nonfatal=1&buffer_size=8388608&timeout=0" \
    -thread_queue_size 8192 "${AUDIO_IN[@]}" \
    -filter_complex "[0:v]fps=${OUT_FPS}[base];[1:v]${CHAIN}[cam];[base][cam]overlay=eof_action=pass:repeatlast=1:shortest=0:format=yuv420[v]" \
    -map "[v]" -map 2:a:0 "${VENC[@]}" "${AUD_OUT[@]}" \
    -f flv -flvflags no_duration_filesize "$DEST" 2>>"$BASE/log/publisher.log" &
  PUBPID=$!
  # Whatever restarted us, YouTube needs time before the channel reads as live again.
  hold_monitor "$ROTATE_GRACE"
}

# --- 8-HOUR BROADCAST ROTATION ------------------------------------------------
# YouTube only archives live streams up to 12h. Every ROTATE_HOURS we stop ingest long
# enough for YouTube to close the broadcast (so it is saved as a VOD), then start
# pushing again so YouTube auto-starts a NEW broadcast with a new URL - the same thing
# that already happens after a power cut. A quick 6s restart does NOT do this; the gap
# has to be long enough for YouTube to actually end the old broadcast.
ROTATE_SECONDS=$(( ${ROTATE_HOURS:-8} * 3600 ))
: ${ROTATE_MAX_WAIT:=600}      # max seconds to wait for YouTube to report the old broadcast closed
: ${ROTATE_GAP:=60}            # extra seconds of silence after it is closed, before pushing again
# YouTube does NOT bring an auto-created broadcast live the moment ingest resumes - it takes
# minutes. The monitor used to start judging the instant the publisher came back, see OFFLINE
# (correctly, YouTube was still spinning up), and demand another rotation ~70s later. That
# livelocked the stream: 93 rotations in 3.5h on 2026-09-05, none ever allowed to go live.
# ROTATE_GRACE must stay comfortably above the monitor's OFFLINE_SECONDS for that reason.
: ${ROTATE_GRACE:=420}         # monitor stands down this long after ANY publisher start
: ${ROTATE_MIN_INTERVAL:=900}  # hard floor between unscheduled rotations - the livelock backstop
LAST_ROTATE=0

# The hold is a deadline, not a marker: if stream.sh dies mid-rotation the file expires on its
# own instead of muting the monitor forever.
hold_monitor()    { print -r -- $(( $(date +%s) + ${1:-60} )) > "$ROTATE_FLAG"; }
release_monitor() { rm -f "$ROTATE_FLAG"; }

# Prints "<state> [id]" where state is one of:
#   live    - channel is live, id follows
#   offline - YouTube explicitly says the channel is not live
#   unknown - the lookup itself failed (network, rate limit, yt-dlp breakage)
# "unknown" is NOT evidence that the broadcast closed. The old code could not tell the two
# apart, so every failed lookup read as "not live" and every rotation logged "not live after 0s".
# Printed rather than stored in a global, because callers use it inside $(...) subshells.
yt_live_state() {
  local out err id
  err=$(mktemp -t ytlive)
  out=$("$YTDLP" --no-warnings --skip-download --print "%(id)s|%(is_live)s" \
        "https://www.youtube.com/${YT_CHANNEL}/live" 2>"$err")
  id=$(print -r -- "$out" | awk -F'|' '$2=="True"{print $1; exit}')
  if [[ -n "$id" ]]; then
    print -r -- "live $id"
  elif grep -qi "not currently live\|does not have a live\|is not live\|not currently streaming" "$err"; then
    print -r -- "offline"
  else
    print -r -- "unknown"
  fi
  rm -f "$err"
}

yt_live_id() { yt_live_state | awk '$1=="live"{print $2}'; }

# Watch for the broadcast YouTube is supposed to open once ingest is flowing. Runs in the
# background so it never blocks the publisher watchdog. Releases the monitor hold as soon as
# the channel is genuinely live, and says something useful if it never is. Used by BOTH the
# rotation path and the cold start - a cold start needs exactly the same warm-up window.
await_broadcast() {
  local old_id="${1:-}"
  ( local n deadline=$(( $(date +%s) + ROTATE_GRACE )) out
    # With credentials, do not sit and hope: ask YouTube to create the broadcast. This is
    # idempotent - if the channel is already live it changes nothing.
    if yt_api_ready; then
      out=$(yt_api_call ensure-live)
      if print -r -- "$out" | grep -q '"status": *"LIVE"'; then
        n=$(print -r -- "$out" | sed -n 's/.*"broadcast_id": *"\([^"]*\)".*/\1/p')
        log "LIVE: broadcast is up via API: ${n} - https://www.youtube.com/watch?v=${n}"
        release_monitor
        exit
      fi
      log "YT-API: could not bring the channel live: $out"
    fi
    while (( $(date +%s) < deadline )); do
      sleep 20
      n=$(yt_live_id)
      if [[ -n "$n" ]]; then
        log "LIVE: broadcast is up: $n (previous was ${old_id:-<none>}) - https://www.youtube.com/watch?v=$n"
        release_monitor
        exit
      fi
    done
    if yt_api_ready; then
      log "WARNING: no live broadcast ${ROTATE_GRACE}s after ingest started, and the API could not create one. See the YT-API line above for YouTube's own reason."
    else
      log "WARNING: no live broadcast ${ROTATE_GRACE}s after ingest started, though RTMP is connected. Pushing ingest cannot CREATE a broadcast on this channel - it never has. Either press Go Live in YouTube Studio, or configure the API once with: bin/yt_api.py auth"
    fi ) &
}

rotate_broadcast() {
  local why="$1" old_id waited=0 now since state=unknown
  now=$(date +%s)
  # Backstop against the monitor<->rotation livelock. A scheduled rotation is always allowed;
  # an unscheduled one is refused if we only just rotated, because killing ingest again cannot
  # make YouTube open a broadcast it has not opened yet - it only restarts the clock.
  if [[ "$why" != scheduled* ]] && (( LAST_ROTATE > 0 )); then
    since=$(( now - LAST_ROTATE ))
    if (( since < ROTATE_MIN_INTERVAL )); then
      rm -f "$ROTATE_NOW"
      hold_monitor $(( ROTATE_MIN_INTERVAL - since ))
      log "ROTATE ($why): REFUSED - only ${since}s since the last rotation (floor ${ROTATE_MIN_INTERVAL}s). Ingest is still running; leaving it alone."
      return
    fi
  fi
  # PREFLIGHT - the most important rule in this script.
  # Never end a working broadcast unless we can start the next one. Rotating without that
  # ability does not "restart" anything; it just takes the channel dark until a human
  # presses Go Live. That is exactly what happened on 2026-09-05: the 09:17 rotation ended
  # a healthy 8h broadcast and the channel stayed dark for 5 hours. Losing the >12h archive
  # is a far smaller cost than losing the stream, so when in doubt we do NOT rotate.
  if ! yt_api_ready; then
    log "ROTATE ($why): SKIPPED - no YouTube API credentials, so nothing here can create the next broadcast. Staying live on the current one. Run bin/yt_api.py auth to enable rotation."
    rm -f "$ROTATE_NOW"
    BROADCAST_STARTED=$(date +%s)   # do not re-ask every 5s
    return
  fi
  local pre
  pre=$(yt_api_call status)
  # The token countdown lives in this output and used to be thrown away here, so the one
  # warning designed to give days of notice reached no log at all.
  if print -r -- "$pre" | grep -q '"token_warning"'; then
    log "TOKEN WARNING: $pre"
    log "        Fix it with: $BASE/bin/yt_api.py auth"
  fi
  if print -r -- "$pre" | grep -q '"status": *"ERROR"'; then
    log "ROTATE ($why): SKIPPED - the API cannot talk to YouTube, so the next broadcast could not be created. Staying live. YouTube said: $pre"
    rm -f "$ROTATE_NOW"
    BROADCAST_STARTED=$(date +%s)
    return
  fi

  old_id=$(yt_live_id)
  log "ROTATE ($why): stopping ingest so YouTube closes broadcast ${old_id:-<none>} and saves it"
  # Ending the broadcast explicitly is what actually gets the VOD saved. Dropping ingest
  # only makes YouTube eventually time the broadcast out.
  if yt_api_ready; then
    log "ROTATE: ending broadcast via API: $(yt_api_call end)"
  fi
  # Cover the whole rotation AND the warm-up that follows it in one hold.
  hold_monitor $(( ROTATE_MAX_WAIT + ROTATE_GAP + ROTATE_GRACE ))
  kill -9 "$PUBPID" 2>/dev/null; wait "$PUBPID" 2>/dev/null
  while (( waited < ROTATE_MAX_WAIT )); do
    state="${$(yt_live_state)%% *}"
    [[ "$state" == "offline" ]] && break
    sleep 15; waited=$(( waited + 15 ))
  done
  log "ROTATE: YouTube state=${state} after ${waited}s, waiting ${ROTATE_GAP}s more, then starting a new broadcast"
  sleep "$ROTATE_GAP"
  start_publisher
  BROADCAST_STARTED=$(date +%s)
  LAST_ROTATE=$BROADCAST_STARTED
  rm -f "$ROTATE_NOW"
  hold_monitor "$ROTATE_GRACE"
  log "ROTATE: publisher back up (pid $PUBPID); monitor holds off ${ROTATE_GRACE}s while YouTube spins up; next rotation in ${ROTATE_HOURS:-8}h"
  await_broadcast "$old_id"
}

log "starting: MODE=$MODE ${OUT_FPS}fps ${ENC_BITRATE} cam=$CAM_URL audio=${AAC_ENC}@${AUD_BITRATE} (cctv mic NOT streamed)"
log "two-process: reader -> ${UDP} -> publisher -> youtube; filters: $CHAIN"

reader_loop & READERPID=$!
cam_ip_watcher & CAMWATCHPID=$!
trap 'release_monitor; kill -9 $READERPID $CAMWATCHPID $PUBPID 2>/dev/null; exit 0' TERM INT

start_publisher
BROADCAST_STARTED=$(date +%s)
LAST_ROTATE=$BROADCAST_STARTED
log "publisher up (pid $PUBPID); broadcast rotation every ${ROTATE_HOURS:-8}h; monitor holds off ${ROTATE_GRACE}s"
await_broadcast ""

# Publisher watchdog: only a genuinely stuck publisher warrants a YouTube reconnect.
last=""; stuck=0; housekeep_in=0
housekeep
while true; do
  sleep 5
  housekeep_in=$(( housekeep_in + 5 ))
  if (( housekeep_in >= HOUSEKEEP_EVERY )); then
    housekeep_in=0
    housekeep
    check_monitor
  fi
  if [[ -e "$ROTATE_NOW" ]]; then
    rotate_broadcast "manual"; last=""; stuck=0; continue
  elif (( $(date +%s) - BROADCAST_STARTED >= ROTATE_SECONDS )); then
    rotate_broadcast "scheduled ${ROTATE_HOURS:-8}h reached"; last=""; stuck=0; continue
  fi
  if ! kill -0 "$PUBPID" 2>/dev/null; then
    wait "$PUBPID" 2>/dev/null; local rc=$?
    log "PUBLISHER died rc=$rc - restarting (this does drop the YouTube session briefly)"
    start_publisher; log "publisher back up (pid $PUBPID)"; await_broadcast ""; last=""; stuck=0; continue
  fi
  cur=$(grep -a '^frame=' "$PROG" 2>/dev/null | tail -1 | cut -d= -f2)
  if [[ -n "$cur" && "$cur" != "$last" ]]; then last="$cur"; stuck=0
  else
    stuck=$(( stuck + 5 ))
    if (( stuck >= STALL_TIMEOUT )); then
      log "WATCHDOG: publisher output frozen ${stuck}s - restarting publisher"
      kill -9 "$PUBPID" 2>/dev/null; wait "$PUBPID" 2>/dev/null
      start_publisher; log "publisher back up (pid $PUBPID)"; await_broadcast ""; last=""; stuck=0
    fi
  fi
done
