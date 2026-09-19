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
BASE="${BASE:-${0:A:h:h}}"   # the checkout this script lives in (a launchd install is ~/Downloads/YTLive)
CONF="${CONF:-$BASE/conf/stream.env}"
LOG="$BASE/log/stream.log"
PROG="$BASE/log/progress.txt"
SNAP="$BASE/log/lastframe.jpg"
BASEIMG="$BASE/log/basefill.jpg"
CAMIP_FILE="$BASE/log/cam_ip"   # runtime source of truth for the camera address
PUB_PID="$BASE/log/publisher.pid"  # the publisher's pid, so the monitor can restart exactly IT
MON_PID="$BASE/log/monitor.pid"    # the monitor's pid, so this script can restart exactly IT
PUB_WHY="$BASE/log/pub_kill_reason"  # why the publisher was deliberately stopped (see below)
ROTATE_FLAG="$BASE/log/rotating"    # holds an epoch deadline: the monitor stands down until then
ROTATE_NOW="$BASE/log/rotate_now"   # touch this file to force a rotation immediately
YTDLP="$HOME/.local/bin/yt-dlp"
YT_API="$BASE/bin/yt_api.py"
YT_OAUTH="$BASE/conf/yt_oauth.json"
# The API is the only thing that can actually CREATE a broadcast. Pushing RTMP at a stream
# key never has on this channel (see yt_api.py). It switches itself on as soon as
# conf/yt_oauth.json exists, so the streamer keeps working unconfigured - just without the
# ability to bring the channel live on its own.
source "$BASE/bin/lib.sh"      # yt_api_ready(), yt_api_call() - shared with yt_monitor.sh
FF="$HOME/.local/bin/ffmpeg"
source "$CONF"

log() { print -r -- "$(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$LOG"; }
/usr/bin/caffeinate -ism -w $$ &

# --- HOUSEKEEPING ------------------------------------------------------------
# Nothing here used to bound the logs. publisher.log is ffmpeg's stderr and grows forever;
# a noisy camera can turn that into gigabytes on a machine whose only job is to stay up.
: ${LOG_MAX_BYTES:=2097152}       # 2 MB per log file
# stream.log gets a LARGER budget than the rest, and the reason is measured: during the
# 2026-09-18 outage the reader's reconnect storm wrote ~700 lines/hour, so the 512 KB cap
# (which keeps only the last half) retained about four hours - the trim erased the FIRST hours
# of the outage, which are the ones that would have explained it. 2 MB keeps roughly 17h of
# storm. net_events.log exists so the transitions survive regardless; this only widens the net.
: ${LOG_MAX_BYTES_STREAM:=2097152}
: ${HOUSEKEEP_EVERY:=300}         # seconds between housekeeping passes
: ${MONITOR_STALE:=600}           # heartbeat older than this means the watchdog is hung
: ${DISK_LOW_MB:=1000}            # free-space floor that makes housekeep cut logs to a quarter
MON_HEARTBEAT="$BASE/log/monitor.heartbeat"
# No notifications and no log-reading: this Mac is unattended. Nothing here may depend on a
# human noticing anything, so every failure path must keep retrying rather than report.

# Trim in place rather than rotating: ffmpeg holds an O_APPEND fd on publisher.log, so
# renaming the file would leave it writing to an unlinked inode forever. Rewriting the same
# inode keeps every existing writer pointed at the right place.
trim_log() {
  local f="$1" cap="${2:-$LOG_MAX_BYTES}" sz tmp
  [[ -f "$f" ]] || return 0
  sz=$(/usr/bin/stat -f %z "$f" 2>/dev/null) || return 0
  (( sz > cap )) || return 0
  tmp="${TMPDIR:-/tmp}/ytlive-trim.$$"
  if tail -c $(( cap / 2 )) "$f" > "$tmp" 2>/dev/null; then
    cat "$tmp" > "$f"
    log "HOUSEKEEP: trimmed $(basename $f) from ${sz} to $(/usr/bin/stat -f %z "$f") bytes"
  fi
  rm -f "$tmp"
}

housekeep() {
  local f avail_mb stream_cap other_cap
  avail_mb=$(df -k "$BASE" 2>/dev/null | awk 'NR==2 {print int($4/1024)}')
  stream_cap=$LOG_MAX_BYTES_STREAM
  other_cap=$LOG_MAX_BYTES
  # A SLOW DECLINE IS WORTH ACTING ON BEFORE IT IS WORTH REPORTING. Below DISK_LOW_MB every log is
  # cut to a quarter of its budget immediately, and the regenerable monitor artifacts are dropped
  # too. That is safe mid-run: ffmpeg holds the inode of any file it opened, so unlinking one does
  # not disturb the running publisher, and each is rebuilt on the next pull or resolve.
  # NOT touched, deliberately: log/basefill.jpg and log/lastframe.jpg (the filler stills - losing
  # them degrades the next publisher start), the deploy backups under $HOME (they ARE the
  # rollback), and .git. Those are decisions for a human, not housekeeping.
  if [[ "$avail_mb" == <-> ]] && (( avail_mb < ${DISK_LOW_MB:-1000} )); then
    stream_cap=$(( ${LOG_MAX_BYTES_STREAM:-2097152} / 4 ))
    other_cap=$(( ${LOG_MAX_BYTES:-2097152} / 4 ))
    log "HOUSEKEEP: ${avail_mb} MB free (< ${DISK_LOW_MB:-1000}) - cutting every log to a quarter of its budget and dropping regenerable caches, to buy time before this becomes a dark channel"
    for f in "$BASE/log/yt_lastpull.jpg" "$BASE/log/yt_prevpull.jpg" \
             "$BASE/log/golden_gray.cache" "$BASE/log/yt_url.cache"; do
      rm -f "$f" 2>/dev/null
    done
  fi
  # log/progress.txt is deliberately NOT trimmed at any free-space level: ffmpeg writes it at a
  # fixed offset, so rewriting it underneath would corrupt the frame counter the watchdog reads.
  # It is truncated at every publisher start instead, which bounds it to one rotation's worth.
  trim_log "$BASE/log/stream.log" "$stream_cap"
  for f in "$BASE/log/publisher.log" "$BASE/log/reader.log" \
           "$BASE/log/monitor.log" "$BASE/log/net_events.log" \
           "$HOME/Library/Logs/YTLive/"*.log(N); do
    trim_log "$f" "$other_cap"
  done
  # DISK IS THE ONE FAILURE NOTHING HERE CAN RECOVER FROM. A full volume makes ffmpeg's -progress
  # write fail (so the frame counter stops and the watchdog restarts the publisher every 30s),
  # takes yt-dlp down with it, and leaves a dark channel with no diagnosis.
  # NOTE the honest limit: the streamer cannot TELL anyone - the off-host watchdog is the only
  # component allowed to notify (see bin/yt_watchdog.py), and it learns about the disk only when
  # the channel finally stops. Delivering this number to it is the row the tracker calls "give the
  # notification path redundancy"; until that exists this line is the record.
  if [[ "$avail_mb" == <-> ]] && (( avail_mb < 200 )); then
    log "HOUSEKEEP: CRITICAL - only ${avail_mb} MB free on the volume holding $BASE. A full disk stops the frame counter, the recording and yt-dlp, and would need a human on site."
  fi
}

# --- why did the publisher die? --------------------------------------------------------------
# The log used to say only `PUBLISHER died rc=N`. rc alone does not say WHY: 137 is SIGKILL and
# could be the broadcast rotation, the stall watchdog or an ingest bounce, and 224 is ffmpeg's
# broken pipe because YouTube closed the ingest. The archived audit counted 192 deaths of which
# rc=224 was the only recurring mode (~1 per 2 days) - and nothing said so.
# A deliberate kill records its reason in a FILE first, not in a variable, because
# await_broadcast runs in a subshell and a subshell cannot set the main loop's variables. An
# unexpected death quotes ffmpeg's own last error line instead, which is the only thing that can
# explain a death nothing here caused.
# NOT covered, deliberately: the TERM/INT trap kills the publisher and exits immediately, so no
# death line is ever produced for it and there is nothing to explain.
mark_pub_kill() { print -rn -- "$*" > "$PUB_WHY" 2>/dev/null; }
pub_death_reason() {
  local rc="$1" why="" last
  case "$rc" in
    137) # `$(<file)` on a missing file prints its own error even with 2>/dev/null, so test first.
         [[ -r "$PUB_WHY" ]] && why=$(<"$PUB_WHY")
         why="${why:-SIGKILL from outside this script - the monitor's bad-picture restart kills by pid}" ;;
    224) why="YouTube closed the ingest (ffmpeg broken pipe)" ;;
    0)   why="ffmpeg exited 0, which should not happen for a live push" ;;
    *)   why="ffmpeg error" ;;
  esac
  print -rn -- "$why"
  last=$(grep -a . "$BASE/log/publisher.log" 2>/dev/null | tail -1 | cut -c1-200)
  [[ -n "$last" ]] && print -rn -- " | ffmpeg: $last"
  return 0
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
    # Kill exactly the monitor, not "anything whose command line mentions yt_monitor.sh".
    local mon
    if mon=$(pidfile_pid "$MON_PID" zsh yt_monitor.sh); then
      log "MONITOR: heartbeat is ${age}s old - watchdog is hung. Killing pid $mon; launchd KeepAlive brings it back."
      kill -9 "$mon" 2>/dev/null
    else
      log "MONITOR: heartbeat is ${age}s old and $MON_PID has no usable pid - kickstarting the launchd job instead."
      launchctl kickstart -k "gui/$(id -u)/com.user.cctv-monitor" 2>/dev/null \
        || log "MONITOR: kickstart failed too - THE STREAM IS UNWATCHED."
    fi
  else
    log "MONITOR: heartbeat is ${age}s old and com.user.cctv-monitor is NOT loaded - THE STREAM IS UNWATCHED."
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
      # The reader follows log/cam_ip, but start_publisher's snapshot grab uses $CAM_URL, which
      # was only ever read from conf/stream.env when the process started. Leaving it stale meant
      # the per-start still-grab failed after a DHCP move and the filler fell back to a plain
      # colour frame until someone restarted stream.sh. Update the in-memory copy as well.
      CAM_URL="rtsp://${newip}/${CAM_PATH}"
      CAM_HOST="$newip"
      log "CAM-WATCH: camera moved $cur -> $newip (reader and snapshot follow)"
      /usr/bin/sed -i '' "s|^CAM_URL=\"rtsp://[0-9.]*/|CAM_URL=\"rtsp://${newip}/|" "$CONF" 2>/dev/null \
        || log "CAM-WATCH: WARNING - could not rewrite CAM_URL in $CONF; the reader still follows log/cam_ip but the file is now stale"
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
# YouTube starts an autoStart broadcast when ingest ARRIVES at the stream it is bound to.
# Bind after ingest is already flowing and that arrival has gone by: the broadcast sits in
# "ready" forever, and a manual transition is refused (invalidTransition) precisely BECAUSE
# it is set to auto-start. Proven the hard way on 2026-09-05 - the rotation resumed ingest
# and only created the broadcast 6 minutes later, so the channel sat dark for 19 minutes,
# then went live 30s after the publisher was bounced.
#
# Hence: the broadcast must exist and be bound BEFORE ffmpeg starts pushing. Every ingest
# start goes through start_publisher, so this is the one place that guarantees the order.
# WHEN A BROADCAST BECOMES A VIDEO, YOUTUBE THROWS THE THUMBNAIL AWAY. It falls back to a
# frame of its own choosing, which is why Studio then offers "pick one of 3" - verified on
# ufmT_Fjg9aw, whose maxresdefault was byte-identical to YouTube's own maxres1 despite the
# branded thumbnail having been enforced for the whole eight hours it was live.
#
# So about an hour after a cut, once the suggestions exist, adopt the first one. That turns
# an auto-pick into a real custom thumbnail. Scheduled through a state file rather than a
# sleeping subshell so it survives a restart of this script.
schedule_thumbnail() {
  [[ -n "$1" ]] || return 0
  # cut time is recorded so the give-up deadline is measured from the CUT, not from however
  # many retries have happened - restarts and slow attempts cannot extend the window.
  print -r -- "$1 $(( $(date +%s) + THUMB_DELAY )) 0 $(date +%s)" > "$THUMB_PENDING"
  log "THUMB: will adopt YouTube's first suggestion for $1 in $(( THUMB_DELAY / 60 )) min, falling back to the ${THUMB_FRAME_AT} frame after $(( THUMB_GIVEUP / 60 )) min"
}

do_pending_thumbnail() {
  [[ -s "$THUMB_PENDING" ]] || return 0
  yt_api_ready || return 0
  local vid due tries cut out now
  read -r vid due tries cut < "$THUMB_PENDING"
  [[ "$due" == <-> ]] || { rm -f "$THUMB_PENDING"; return 0; }
  [[ "$tries" == <-> ]] || tries=0
  [[ "$cut" == <-> ]] || cut=$due
  now=$(date +%s)
  # Proceed when a retry is due OR the give-up deadline has passed. Gating only on the
  # retry slot rounds the deadline up to the next one: with retries 15 min apart, a 2h
  # window became 2h11m in practice tonight.
  (( now >= due || now - cut >= THUMB_GIVEUP )) || return 0

  # Past the window, stop waiting for YouTube and take a frame ourselves. An 8h video can
  # go hours without producing suggestions, and a video left on the auto-pick is worse than
  # one showing a real frame from its own content.
  if (( now - cut >= THUMB_GIVEUP )); then
    log "THUMB: no suggestion for $vid after $(( (now - cut) / 60 )) min - taking the ${THUMB_FRAME_AT} frame instead"
    out=$(yt_api_call frame-thumbnail "$vid" "$THUMB_FRAME_AT")
    log "THUMB: $out"
    if print -r -- "$out" | grep -q '"status": *"NOTREADY"'; then
      print -r -- "$vid $(( now + THUMB_RETRY )) $tries $cut" > "$THUMB_PENDING"
    else
      rm -f "$THUMB_PENDING"
    fi
    return 0
  fi

  out=$(yt_api_call pick-thumbnail "$vid")
  log "THUMB: $out"
  if print -r -- "$out" | grep -q '"status": *"NOTREADY"'; then
    print -r -- "$vid $(( now + THUMB_RETRY )) $(( tries + 1 )) $cut" > "$THUMB_PENDING"
  else
    rm -f "$THUMB_PENDING"      # SET, CUSTOM or ERROR - either way this one is settled
  fi
}

# Stamp the saved title/description/tags/category onto a new broadcast. Runs only AFTER the
# channel is live and swallows every failure: being on air matters more than being tagged,
# so nothing in here may ever be a reason the stream is down.
apply_settings() {
  yt_api_ready || return 0
  [[ -s "$BASE/conf/broadcast_template.json" ]] || return 0
  log "SETTINGS: $(yt_api_call enforce "$1")"
  return 0
}

# Drift check on the running broadcast. Cheap when nothing is wrong - one videos.list, and
# an update only when the configuration has actually moved away from the reference. This is
# what makes "it will be fixed until it is right" true rather than aspirational: a setting
# changed by hand, or a broadcast that came up wrong, is corrected without anyone noticing.
: ${ENFORCE_EVERY:=1800}          # seconds between drift checks (0 disables)
: ${ENFORCE_MAX_ATTEMPTS:=3}      # stop re-enforcing a field that will not persist (see below)
LAST_ENFORCE=0
ENFORCE_SIG=""                    # the fixable-drift set we are currently chasing
ENFORCE_TRIES=0
enforce_drift() {
  (( ENFORCE_EVERY > 0 )) || return 0
  yt_api_ready || return 0
  [[ -s "$BASE/conf/broadcast_template.json" ]] || return 0
  local now=$(date +%s) out sig
  (( now - LAST_ENFORCE >= ENFORCE_EVERY )) || return 0
  LAST_ENFORCE=$now
  out=$(yt_api_call verify)
  print -r -- "$out" | grep -q '"status": *"DRIFTED"' || { ENFORCE_SIG=""; ENFORCE_TRIES=0; return 0; }
  # `verify` reports TWO kinds of drift and only one of them can be fixed. `diffs` is
  # video-level (title, description, tags, thumbnail) and `enforce` can write it. `broadcast_diffs`
  # is fixed AT CREATION (enableMonitorStream, latencyPreference, ...) and no update can ever
  # change it for a broadcast that is already live - so enforcing against it can never succeed,
  # and doing it every ENFORCE_EVERY spends up to ~158 units a shot forever. That loop is the bulk
  # of the audit's 10,290-unit worst case against a 10,000-unit pool. Report it, never chase it.
  if print -r -- "$out" | grep -q '"diffs": \[\]'; then
    if [[ "$ENFORCE_SIG" != "broadcast-only" ]]; then
      ENFORCE_SIG="broadcast-only"
      log "DRIFT: only creation-time settings differ and no update can change them - reported once, never enforced: $out"
    fi
    ENFORCE_TRIES=0
    return 0
  fi
  # There is something fixable. If the SAME set survives an enforce, the field is one YouTube will
  # not persist for this broadcast and re-trying is pure waste, so give up loudly and name it.
  sig=$(print -r -- "$out" | tr -d ' \n' | sed 's/.*"diffs":\[//; s/\].*//')
  if [[ "$sig" == "$ENFORCE_SIG" ]]; then
    ENFORCE_TRIES=$(( ENFORCE_TRIES + 1 ))
    if (( ENFORCE_TRIES > ENFORCE_MAX_ATTEMPTS )); then
      log "DRIFT: GIVING UP on [$sig] - ${ENFORCE_MAX_ATTEMPTS} enforces did not make it persist, and each retry costs API quota. Fix conf/broadcast_template.json or accept the drift; not trying again until the field set changes."
      return 0
    fi
  else
    ENFORCE_SIG="$sig"; ENFORCE_TRIES=1
  fi
  log "DRIFT: $out"
  log "DRIFT: $(yt_api_call enforce)"
}

# Is the credential actually usable? This mints a real access token, so it is the truth rather
# than a countdown. The exit status of `token` is deliberately not used: it is also non-zero for
# an EXPIRING token, and an expiring token still works perfectly well.
api_usable() {
  yt_api_ready || { print -r -- "no API credentials at $YT_OAUTH"; return 1 }
  local out
  out=$(yt_api_call token)
  if print -r -- "$out" | grep -q '"probe": *"LIVE"'; then
    print -r -- yes
    return 0
  fi
  print -r -- "the OAuth credential is not usable: $(print -r -- "$out" | tr '\n' ' ')"
  return 1
}

prepare_broadcast() {
  # THE API IS REQUIRED FOR EVERY ROTATION. This creates and binds the next broadcast BEFORE
  # any ingest starts. With no broadcast bound, ingest arrives at a bare stream key and YouTube
  # does nothing at all: automatic/default broadcast creation was retired in 2020, and it was
  # proven here on 2026-09-05, when six minutes of clean ingest against a dark channel produced
  # nothing. An earlier comment in this file claimed YouTube created one by itself. It does not.
  yt_api_ready || { log "PREPARE: no API credentials at $YT_OAUTH - nothing can create the next broadcast, so the channel will go dark at the next cut. Run: bin/yt_api.py auth"; return 0; }
  log "PREPARE: $(yt_api_call prepare)"
}

start_publisher() {
  prepare_broadcast
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
  # -loglevel error, not warning: the MP3 concat input emits a "Resumed reading at pts N
  # after a lag" warning every few seconds, which was 5700+ repeats and most of a 6 MB file.
  # Nothing reads it and nobody reads it.
  "$FF" -y -hide_banner -loglevel error -progress "$PROG" \
    "${BASE_IN[@]}" \
    -thread_queue_size 16384 -fflags +genpts+discardcorrupt -itsoffset "$CAM_DELAY" \
    -f mpegts -i "${UDP}?fifo_size=8000000&overrun_nonfatal=1&buffer_size=8388608&timeout=0" \
    -thread_queue_size 8192 "${AUDIO_IN[@]}" \
    -filter_complex "[0:v]fps=${OUT_FPS}[base];[1:v]${CHAIN}[cam];[base][cam]overlay=eof_action=pass:repeatlast=1:shortest=0:format=yuv420[v]" \
    -map "[v]" -map 2:a:0 "${VENC[@]}" "${AUD_OUT[@]}" \
    -f flv -flvflags no_duration_filesize "$DEST" 2>>"$BASE/log/publisher.log" &
  PUBPID=$!
  # Publish the publisher's pid so yt_monitor.sh can restart exactly THIS process. It used to run
  # `pkill -9 -f "ffmpeg.*rtmp"`, which matches the full command line of every process of every
  # user - a manual diagnostic ffmpeg, a second copy of the project, or any command that merely
  # mentions rtmp. `.*` is greedy and unanchored, and `-9` leaves nothing to clean up.
  print -r -- "$PUBPID" > "$PUB_PID" 2>/dev/null
  rm -f "$PUB_WHY" 2>/dev/null   # a fresh publisher has no death reason yet
  # Whatever restarted us, YouTube needs time before the channel reads as live again - and
  # long enough to cover the native wait plus an API fallback behind it.
  hold_monitor $(( ROTATE_NATIVE_WAIT + 120 ))
}

# --- 8-HOUR BROADCAST ROTATION ------------------------------------------------
# YouTube only archives live streams up to 12h. Every ROTATE_HOURS we stop ingest long
# enough for YouTube to close the broadcast (so it is saved as a VOD), then start
# pushing again so YouTube auto-starts a NEW broadcast with a new URL - the same thing
# that already happens after a power cut. A quick 6s restart does NOT do this; the gap
# has to be long enough for YouTube to actually end the old broadcast.
# The cut is timed so the SAVED RECORDING clears 8h, not the wall clock. YouTube's encode
# loses time turning a live stream into a VOD - measured across five broadcasts on
# 2026-09-05..07, wall 8.004-8.023h came back as 7.962-7.990h, a shortfall of 0.6 to 2.3
# minutes. Cutting at exactly 8h therefore always produced a recording just UNDER 8h. The
# extra minutes cover the worst observed loss with margin, and 8h03m is still far inside
# YouTube's 12h archive limit.
ROTATE_SECONDS=$(( ${ROTATE_HOURS:-8} * 3600 + ${ROTATE_MINUTES:-0} * 60 ))
ROTATE_LABEL="${ROTATE_HOURS:-8}h$( (( ${ROTATE_MINUTES:-0} > 0 )) && print -n "${ROTATE_MINUTES}m" )"
: ${ROTATE_MAX_WAIT:=600}      # max seconds to wait for YouTube to report the old broadcast closed
: ${ROTATE_GAP:=60}            # extra seconds of silence after it is closed, before pushing again
# YouTube does NOT bring an auto-created broadcast live the moment ingest resumes - it takes
# minutes. The monitor used to start judging the instant the publisher came back, see OFFLINE
# (correctly, YouTube was still spinning up), and demand another rotation ~70s later. That
# livelocked the stream: 93 rotations in 3.5h on 2026-09-05, none ever allowed to go live.
# ROTATE_GRACE must stay comfortably above the monitor's OFFLINE_SECONDS for that reason.
: ${ROTATE_GRACE:=420}         # monitor stands down this long after ANY publisher start
: ${ROTATE_MIN_INTERVAL:=900}  # hard floor between unscheduled rotations - the livelock backstop
# WHAT YOUTUBE DOES, AND WHAT IT DOES NOT. Every broadcast we create carries autoStart=true AND
# autoStop=true, so stopping ingest makes YouTube close and archive the broadcast by itself
# (measured: 9s). That half needs no API at all. The other half does: autoStart only starts a
# broadcast that is ALREADY BOUND, and YouTube does not create one when ingest arrives at a bare
# stream key - automatic/default broadcast creation was retired in 2020
# (youtube/v3/live/guides/migration-guide-default-broadcasts). Measured here on 2026-09-05: six
# minutes of clean ingest against a dark channel produced nothing. start_publisher()'s
# prepare_broadcast() is therefore LOAD-BEARING on every single cut, and the "native" rotation
# mode below means only "YouTube's autoStart took the broadcast we had already created live,
# without needing the ensure-live fallback". Commit 9a8d458 corrected an earlier claim in this
# very comment that the API was a spare wheel. The correction is the accurate one.
: ${ROTATE_NATIVE_WAIT:=360}   # how long to let YouTube produce the next broadcast on its own
: ${ROTATE_END_PATIENCE:=60}   # if YouTube has not closed the old broadcast by now, end it via API
: ${ROTATE_WITHOUT_API:=no}    # yes = cut even when the API cannot create a successor. That goes
                               # dark the moment the old broadcast closes, so the default is no.
: ${ROTATE_API_RETRY:=900}     # when a cut is refused for that reason, try again this often
ROTATE_BLOCKED_UNTIL=0         # set by a refused rotation; the main loop will not retry before it
ROTATE_HISTORY="$BASE/log/rotation_history.log"
BSTATE="$BASE/log/broadcast_started"   # "<broadcast id> <epoch>"
VODSTATE="$BASE/log/vod_status"        # "<id> <verdict> <checked> <duration>", one line per broadcast
THUMB_PENDING="$BASE/log/thumb_pending"   # "<video id> <due epoch> <attempts>"
: ${THUMB_DELAY:=3600}                 # wait an hour after a cut before adopting a suggestion
: ${THUMB_RETRY:=900}                   # if the video is still processing, look again in 15 min
: ${THUMB_GIVEUP:=7200}                 # after this long, stop waiting for YouTube's own
                                        # suggestions and take a frame from the video instead
: ${THUMB_FRAME_AT:="01:00:00"}         # which moment to grab if it comes to that
LAST_ROTATE=0

# The rotation clock has to track the BROADCAST, not this script. It was set to "now" at
# every stream.sh start, so any restart - launchd reviving a crash, a reboot, a power cut,
# a config change - silently handed the currently running broadcast another full 8 hours.
# A broadcast that drifts past 12h is never archived by YouTube, which is precisely the
# thing this rotation exists to prevent. Verified on 2026-09-05: restarts had pushed a
# broadcast that went live at 15:03 to a 03:12 rotation, i.e. 12h08m old.
refresh_broadcast_clock() {
  local id stored_id="" stored_at="" epoch
  [[ -s "$BSTATE" ]] && read -r stored_id stored_at < "$BSTATE"
  id=$(yt_live_id)
  # THE BIAS THAT MATTERS: rotating EARLY costs a shorter VOD, which is still reviewable.
  # Rotating LATE costs the recording outright - past 12h YouTube answers "this live stream
  # recording is not available", as it does for the 26.1h and 81.5h streams on this channel.
  # So whenever the age is uncertain, assume the broadcast is OLDER, never younger.
  if [[ -z "$id" ]]; then
    # The lookup failed. Trusting the stored clock beats leaving BROADCAST_STARTED at
    # whatever this process happened to start with - that path could hand a 9h-old
    # broadcast another 8 hours and lose the recording.
    [[ "$stored_at" == <-> ]] && BROADCAST_STARTED=$stored_at
    return 0
  fi
  if [[ "$stored_id" == "$id" && "$stored_at" == <-> ]]; then
    BROADCAST_STARTED=$stored_at
    return 0
  fi
  # First time we have seen this broadcast. Prefer YouTube's own actualStartTime, so a
  # restart that finds an already-running broadcast still gets the true age.
  epoch=""
  yt_api_ready && epoch=$(yt_api_call status | sed -n 's/.*"started_epoch": *\([0-9]*\).*/\1/p')
  [[ "$epoch" == <-> ]] || epoch=$(date +%s)
  print -r -- "$id $epoch" > "$BSTATE"
  BROADCAST_STARTED=$epoch
  log "CLOCK: broadcast $id went live $(date -r $epoch '+%H:%M:%S'); rotating at $(date -r $(( epoch + ROTATE_SECONDS )) '+%a %H:%M:%S')"
}

# One line per rotation, kept as the record of how each cut actually went. It used to feed
# a native_is_proven() flag that decided whether the OAuth token still mattered; that flag
# was removed because it was wrong. "native" only ever meant "no ensure-live fallback was
# needed" - PREPARE calls the API on EVERY cut, so the token is never optional, and a green
# light saying otherwise was worse than no light at all.
record_rotation() {
  print -r -- "$(date '+%Y-%m-%d %H:%M:%S') mode=$1 seconds_to_live=$2 broadcast=$3 ended=${4:-}" >> "$ROTATE_HISTORY"
  # keep it bounded without losing the recent record
  if [[ -s "$ROTATE_HISTORY" ]] && (( $(grep -c '' "$ROTATE_HISTORY") > 200 )); then
    tail -n 100 "$ROTATE_HISTORY" > "$ROTATE_HISTORY.t" && cat "$ROTATE_HISTORY.t" > "$ROTATE_HISTORY"
    rm -f "$ROTATE_HISTORY.t"
  fi
}

# THE POINT OF THE WHOLE ROTATION is a recording you can watch later, and a rotation can
# look perfectly successful while producing nothing reviewable - past 12h YouTube answers
# "This live stream recording is not available", as it does for this channel's 26.1h and
# 81.5h streams. So verify it, and do it with yt-dlp rather than the API so the check
# still works after the OAuth token expires.
#
# Checked one rotation late, on purpose: an 8h stream needs time to process, and by the
# next rotation it has had ~8 hours of it.
# 0 = a playable recording exists (seconds printed)
# 1 = YouTube says the recording is GONE - the real failure worth shouting about
# 2 = cannot tell yet: still processing (duration "NA"), or the lookup itself failed
#
# Collapsing 2 into 1 is how a perfectly good 8h recording got logged as "cannot be
# reviewed" six minutes after it had been confirmed at 8.054h - YouTube simply had not
# finished processing it and yt-dlp reported NA. Same mistake as reporting a failed
# lookup as OFFLINE, which yt_check.py already had to be cured of.
vod_duration() {
  local out err
  err=$(mktemp -t vodchk)
  out=$("$YTDLP" --no-warnings --skip-download --print "%(duration)s" \
        "https://www.youtube.com/watch?v=$1" 2>"$err" | head -1)
  out=${out%%.*}
  if [[ "$out" == <-> ]] && (( out > 0 )); then
    rm -f "$err"; print -r -- "$out"; return 0
  fi
  # Matched against what yt-dlp ACTUALLY prints, checked rather than guessed: a lost
  # 81h stream reports "Video unavailable", not the "recording is not available" wording
  # this originally looked for - so a genuinely lost recording was being filed as "not
  # known yet" and would have been retried forever instead of flagged.
  if grep -qiE "recording is not available|video unavailable|has been removed|private video|removed by the uploader" "$err"; then
    rm -f "$err"; return 1
  fi
  rm -f "$err"; return 2          # NA, or the lookup broke - ask again later
}

verify_pending_vods() {
  [[ -s "$ROTATE_HISTORY" ]] || return 0
  local id dur now
  now=$(date '+%Y-%m-%d %H:%M:%S')
  for id in ${(f)"$(sed -n 's/.*ended=\([A-Za-z0-9_-][A-Za-z0-9_-]*\).*/\1/p' "$ROTATE_HISTORY" | sort -u)"}; do
    [[ -n "$id" ]] || continue
    # only settled verdicts are final; a MISSING one is re-checked in case it was still
    # processing when we last looked
    grep -q "^$id ok " "$VODSTATE" 2>/dev/null && continue
    dur=$(vod_duration "$id"); local rc=$?
    case $rc in
    0) print -r -- "$id ok $now $(( dur / 3600 ))h$(( (dur % 3600) / 60 ))m" >> "$VODSTATE.new"
       log "VOD: $id is saved and reviewable ($(( dur / 3600 ))h$(( (dur % 3600) / 60 ))m)" ;;
    1) print -r -- "$id MISSING $now -" >> "$VODSTATE.new"
       log "VOD: recording for $id is NOT available - that stream cannot be reviewed. If this repeats, the cut is happening too late." ;;
    *) log "VOD: $id not processed yet - will ask again at the next rotation" ;;
    esac
  done
  [[ -f "$VODSTATE.new" ]] || return 0
  # one line per broadcast, newest verdict wins, bounded
  { cat "$VODSTATE.new"; [[ -f "$VODSTATE" ]] && cat "$VODSTATE"; } 2>/dev/null \
    | awk '!seen[$1]++' | head -50 > "$VODSTATE.t"
  mv -f "$VODSTATE.t" "$VODSTATE"; rm -f "$VODSTATE.new"
}


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

# Has YouTube closed the broadcast? Ask the API when we have it. yt_live_state() goes
# through yt-dlp, which lags by tens of seconds, and twice reported a broadcast still live
# after YouTube had already closed it - firing a spurious "autoStop off?" warning and a
# no-op API end. The API knows immediately, and this is the one question where being wrong
# costs a misleading log line in the record we rely on to diagnose anything later.
broadcast_closed() {
  local out
  if yt_api_ready; then
    out=$(yt_api_call status)
    print -r -- "$out" | grep -q '"status": *"OFFLINE"' && return 0
    print -r -- "$out" | grep -q '"status": *"LIVE"'    && return 1
    # API could not answer - fall through to the slow path rather than guess
  fi
  [[ "${$(yt_live_state)%% *}" == "offline" ]]
}

# Watch for the broadcast YouTube is supposed to open once ingest is flowing. Runs in the
# background so it never blocks the publisher watchdog. Releases the monitor hold as soon as
# the channel is genuinely live, and says something useful if it never is. Used by BOTH the
# rotation path and the cold start - a cold start needs exactly the same warm-up window.
# $1 = the broadcast id we are replacing (empty if none)
# $2 = "rotation" for a real 8h rotation, "start" for a cold start or publisher restart.
#      Only rotations are written to the rotation history: mixing restarts into it would
#      corrupt the very record we are keeping to decide whether native rotation works.
# Only ONE await_broadcast may be in flight. A rotation spawns one, and a publisher restart
# landing inside the same window spawns another; both then poll YouTube and both enforce
# settings on the same video. Observed on 2026-09-06 at 07:33:21 - two SETTINGS lines in
# the same second, two concurrent videos.update on one broadcast. Harmless only because
# enforcement happens to be idempotent, which is not a property to rely on.
#
# mkdir is the atomic primitive here: it either creates the directory or it does not, with
# no window between the check and the create that a test-then-touch would leave open.
: ${AWAIT_LOCK_TTL:=900}          # a lock older than this belonged to a killed subshell
AWAIT_LOCK="$BASE/log/await.lock"
await_lock() {
  local now=$(date +%s) at
  if mkdir "$AWAIT_LOCK" 2>/dev/null; then print -r -- "$now" > "$AWAIT_LOCK/at"; return 0; fi
  at=$(<"$AWAIT_LOCK/at" 2>/dev/null); [[ "$at" == <-> ]] || at=0
  if (( now - at > AWAIT_LOCK_TTL )); then
    log "AWAIT: taking a lock left behind $(( now - at ))s ago"
    print -r -- "$now" > "$AWAIT_LOCK/at"; return 0
  fi
  return 1
}
await_unlock() { rm -f "$AWAIT_LOCK/at" 2>/dev/null; rmdir "$AWAIT_LOCK" 2>/dev/null; }

await_broadcast() {
  local old_id="${1:-}" ctx="${2:-start}"
  ( local n out took started deadline
    if ! await_lock; then
      log "AWAIT ($ctx): another await_broadcast is already watching - not starting a second"
      exit 0
    fi
    trap 'await_unlock' EXIT INT TERM
    started=$(date +%s)
    # NATIVE FIRST - just wait and see. Do not call the API here: doing so was what hid the
    # fact that YouTube creates the broadcast perfectly well on its own, and it made a
    # 7-day OAuth token a hard dependency of a stream that never needed one.
    deadline=$(( started + ROTATE_NATIVE_WAIT ))
    while (( $(date +%s) < deadline )); do
      sleep 20
      n=$(yt_live_id)
      if [[ -n "$n" && "$n" != "$old_id" ]]; then
        took=$(( $(date +%s) - started ))
        if [[ "$ctx" == rotation ]]; then
          log "LIVE (native): YouTube created and started $n by itself after ${took}s - https://www.youtube.com/watch?v=$n"
          record_rotation native "$took" "$n" "$old_id"
        else
          log "LIVE: channel is live on $n after ${took}s - https://www.youtube.com/watch?v=$n"
        fi
        apply_settings "$n"
        release_monitor
        exit
      fi
    done
    # The broadcast was bound before ingest started, so autoStart should already have taken
    # it live. If it has not, bounce the publisher once: a fresh ingest arrival is the event
    # YouTube actually reacts to, and it is what recovered the channel on 2026-09-05.
    took=$(( $(date +%s) - started ))
    if [[ -n "$PUBPID" ]] && kill -0 "$PUBPID" 2>/dev/null; then
      log "ROTATE: nothing live after ${took}s - bouncing ingest so YouTube sees a fresh arrival"
      mark_pub_kill "deliberate: ingest bounce - YouTube had not started the bound broadcast"
      kill -9 "$PUBPID" 2>/dev/null
      # the publisher watchdog restarts it within 5s, which re-runs prepare_broadcast
      sleep 60
      n=$(yt_live_id)
      if [[ -n "$n" && "$n" != "$old_id" ]]; then
        took=$(( $(date +%s) - started ))
        log "LIVE (after ingest bounce): $n after ${took}s - https://www.youtube.com/watch?v=$n"
        [[ "$ctx" == rotation ]] && record_rotation bounce "$took" "$n" "$old_id"
        apply_settings "$n"
        release_monitor
        exit
      fi
    fi
    took=$(( $(date +%s) - started ))
    if yt_api_ready; then
      log "ROTATE: nothing live ${took}s after ingest resumed - falling back to the API"
      out=$(yt_api_call ensure-live)
      if print -r -- "$out" | grep -q '"status": *"LIVE"'; then
        n=$(print -r -- "$out" | sed -n 's/.*"broadcast_id": *"\([^"]*\)".*/\1/p')
        took=$(( $(date +%s) - started ))
        log "LIVE (API fallback): ${n} - https://www.youtube.com/watch?v=${n}"
        [[ "$ctx" == rotation ]] && record_rotation api-fallback "$took" "$n" "$old_id"
        apply_settings "$n"
        release_monitor
        exit
      fi
      log "YT-API: the fallback could not bring the channel live either: $out"
      [[ "$ctx" == rotation ]] && record_rotation failed "$took" "" "$old_id"
    else
      log "WARNING: no live broadcast ${took}s after ingest resumed, and no API credentials to fall back on."
      [[ "$ctx" == rotation ]] && record_rotation failed-no-api "$took" "" "$old_id"
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
  # PREFLIGHT: CAN WE ACTUALLY CREATE THE NEXT BROADCAST?
  #
  # Cutting without a usable credential is the one thing that turns a healthy channel dark. The
  # cut itself still saves this segment's VOD - YouTube's autoStop does that without any API -
  # but nothing can create the successor, and YouTube will not invent one. Measured on
  # 2026-09-05: after a rotation ended a healthy 8h broadcast, the channel stayed dark 5 hours.
  #
  # Staying LIVE is strictly the better failure. The audience keeps the stream, and the moment a
  # human re-runs `bin/yt_api.py auth` the next attempt succeeds by itself. The cost is that this
  # one segment runs past 12h and is not archived - but a lost recording beats a dark channel,
  # because darkness needs a human anyway. ROTATE_WITHOUT_API=yes restores the old behaviour.
  local usable pre
  pre=$(yt_api_call token)
  # The countdown is advisory and is reported whether or not the probe succeeds.
  if print -r -- "$pre" | grep -q '"token_warning"'; then
    log "TOKEN WARNING: $pre"
  fi
  # The token probe hits the OAuth endpoint, which is NOT the Data API - so it still answers LIVE
  # when the day's 10,000 units are gone. Cutting on that alone is the audit's quota hole: the cut
  # happens, `prepare` then cannot create the successor, and the channel goes dark. This check is
  # local and free, so ask it every rotation.
  local q
  q=$(yt_api_call quota)
  if ! print -r -- "$q" | grep -q '"status": *"OK"'; then
    rm -f "$ROTATE_NOW"
    ROTATE_BLOCKED_UNTIL=$(( now + ROTATE_API_RETRY ))
    LAST_ROTATE=$now
    log "ROTATE ($why): REFUSED - API quota is exhausted ($q). Staying LIVE: a cut now would leave a broadcast that cannot be created. Next attempt in ${ROTATE_API_RETRY}s."
    return
  fi
  if print -r -- "$pre" | grep -q '"probe": *"LIVE"'; then
    usable=yes
  else
    usable=no
  fi
  if [[ "$usable" != yes && "$ROTATE_WITHOUT_API" != yes ]]; then
    rm -f "$ROTATE_NOW"
    ROTATE_BLOCKED_UNTIL=$(( now + ROTATE_API_RETRY ))
    LAST_ROTATE=$now
    log "ROTATE ($why): REFUSED - the API cannot create the next broadcast ($pre). Staying LIVE rather than cutting to darkness; this segment will NOT be archived. Fix with: bin/yt_api.py auth. Next attempt in ${ROTATE_API_RETRY}s."
    return
  fi
  if [[ "$usable" != yes ]]; then
    log "ROTATE ($why): API unusable ($pre) but ROTATE_WITHOUT_API=yes - cutting anyway; the channel will go dark until credentials return."
  fi

  # Before cutting again, confirm the recording the LAST cut was supposed to produce
  # actually exists. Eight hours is ample processing time.
  verify_pending_vods

  old_id=$(yt_live_id)
  schedule_thumbnail "$old_id"
  # Snapshot what is configured on the outgoing broadcast BEFORE ending it, so anything
  # edited in Studio carries to the next one. A new video inherits the channel's default
  # description and category but NOT its tags, and on this channel that is 35 local search
  # terms - they were being silently dropped at every rotation.
  [[ -n "$old_id" ]] && yt_api_ready && log "CAPTURE: $(yt_api_call capture "$old_id")"
  log "ROTATE ($why): stopping ingest so YouTube closes broadcast ${old_id:-<none>} and saves it"
  # Cover the whole rotation AND the warm-up that follows it in one hold.
  hold_monitor $(( ROTATE_MAX_WAIT + ROTATE_GAP + ROTATE_NATIVE_WAIT + 120 ))
  mark_pub_kill "deliberate: broadcast rotation ($why)"
  kill -9 "$PUBPID" 2>/dev/null; wait "$PUBPID" 2>/dev/null
  # Let YouTube close the broadcast itself - that is what saves the VOD, and with  # autoStop=true it takes seconds. Only if it has NOT done so (an older broadcast created
  # by this script with autoStop off, say) do we end it explicitly.
  local ended=0
  while (( waited < ROTATE_MAX_WAIT )); do
    if broadcast_closed; then state=offline; break; fi
    state=live
    if (( waited >= ROTATE_END_PATIENCE )) && (( ended == 0 )) && yt_api_ready; then
      log "ROTATE: YouTube has NOT closed it after ${waited}s (autoStop off on this broadcast) - ending it via the API: $(yt_api_call end)"
      ended=1
    fi
    sleep 15; waited=$(( waited + 15 ))
  done
  log "ROTATE: YouTube state=${state} after ${waited}s, waiting ${ROTATE_GAP}s more, then resuming ingest"
  sleep "$ROTATE_GAP"
  rm -f "$BSTATE"          # the old broadcast's clock is done; the next one re-establishes it
  start_publisher
  BROADCAST_STARTED=$(date +%s)
  LAST_ROTATE=$BROADCAST_STARTED
  rm -f "$ROTATE_NOW"
  hold_monitor $(( ROTATE_NATIVE_WAIT + 120 ))
  log "ROTATE: publisher back up (pid $PUBPID); giving YouTube up to ${ROTATE_NATIVE_WAIT}s to create the next broadcast on its own; next rotation in ${ROTATE_LABEL}"
  await_broadcast "$old_id" rotation
}

log "starting: MODE=$MODE ${OUT_FPS}fps ${ENC_BITRATE} cam=$CAM_URL audio=${AAC_ENC}@${AUD_BITRATE} (cctv mic NOT streamed)"
log "two-process: reader -> ${UDP} -> publisher -> youtube; filters: $CHAIN"

reader_loop & READERPID=$!
cam_ip_watcher & CAMWATCHPID=$!
# The transport layer. On 2026-09-18 this Mac lost LAN + DNS + internet for 19h26m and stayed
# AWAKE the whole time; every retry loop above retried the application layer and none of them
# ever touched the interface. See bin/net_watch.sh for the evidence and the ladder.
NETWATCHPID=""
if [[ "${NET_WATCH:-yes}" == "yes" && -x "$BASE/bin/net_watch.sh" ]]; then
  "$BASE/bin/net_watch.sh" loop >>"$BASE/log/net_events.log" 2>&1 & NETWATCHPID=$!
  log "network watchdog started (pid $NETWATCHPID) - see log/net_events.log"
fi
trap 'release_monitor; kill -9 $READERPID $CAMWATCHPID ${NETWATCHPID:+"$NETWATCHPID"} $PUBPID 2>/dev/null; exit 0' TERM INT

start_publisher
BROADCAST_STARTED=$(date +%s)
LAST_ROTATE=$BROADCAST_STARTED
refresh_broadcast_clock     # adopt the running broadcast's real age, not this process's
verify_pending_vods         # catch up on any recording we have not confirmed yet
log "publisher up (pid $PUBPID); broadcast rotation every ${ROTATE_LABEL}; monitor holds off ${ROTATE_GRACE}s"
await_broadcast "" start

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
    refresh_broadcast_clock
    enforce_drift
    do_pending_thumbnail
  fi
  if [[ -e "$ROTATE_NOW" ]]; then
    rotate_broadcast "manual"; last=""; stuck=0; continue
  elif (( $(date +%s) - BROADCAST_STARTED >= ROTATE_SECONDS )) \
       && (( $(date +%s) >= ROTATE_BLOCKED_UNTIL )); then
    rotate_broadcast "scheduled ${ROTATE_LABEL} reached"; last=""; stuck=0; continue
  fi
  if ! kill -0 "$PUBPID" 2>/dev/null; then
    wait "$PUBPID" 2>/dev/null; local rc=$?
    log "PUBLISHER died rc=$rc - $(pub_death_reason "$rc") - restarting (this does drop the YouTube session briefly)"
    rm -f "$PUB_WHY" 2>/dev/null
    start_publisher; log "publisher back up (pid $PUBPID)"; await_broadcast "" start; last=""; stuck=0; continue
  fi
  cur=$(grep -a '^frame=' "$PROG" 2>/dev/null | tail -1 | cut -d= -f2)
  if [[ -n "$cur" && "$cur" != "$last" ]]; then last="$cur"; stuck=0
  else
    stuck=$(( stuck + 5 ))
    if (( stuck >= STALL_TIMEOUT )); then
      log "WATCHDOG: publisher output frozen ${stuck}s - restarting publisher"
      mark_pub_kill "deliberate: stall watchdog - output frozen ${stuck}s"
      kill -9 "$PUBPID" 2>/dev/null; wait "$PUBPID" 2>/dev/null
      start_publisher; log "publisher back up (pid $PUBPID)"; await_broadcast "" start; last=""; stuck=0
    fi
  fi
done
