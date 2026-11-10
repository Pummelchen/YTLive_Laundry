#!/bin/zsh
# THE WATCHGUARD - one recovery pass every WATCHGUARD_EVERY seconds (default 600 = 10 minutes).
#
# WHY IT EXISTS
# ------------
# This stream has come back from nothing many times, and every time a different layer was the
# reason it stayed dark. Each inner loop is good at its own layer and blind to the rest:
#
#   bin/stream.sh      reader + publisher, publisher watchdog, cam_ip_watcher      (seconds)
#   bin/yt_monitor.sh  the PUBLIC picture, frame grading, "restart the publisher"  (seconds)
#   bin/net_watch.sh   the transport: gateway, DNS, WAN, DHCP, Wi-Fi               (30 s)
#   launchd            a process that EXITS                                        (immediately)
#   bin/yt_watchdog.py (off the host) decides that a human must be told            (60 s)
#
# What none of them owns is the SYSTEM: whether every agent is actually loaded, whether the
# camera delivers frames rather than merely accepting TCP, whether EACH feed has a live
# broadcast (the Shorts has never had an independent liveness check), whether the box came back
# from a power cut into a half-started state, and whether the disk still has room. That is this
# script's job - the fifth agent, and the only one allowed to restart the other four.
#
# Measured failures this is built against (all in the repo's own logs):
#   2026-11-09/10  power/network work: several reboots, 26 h dark, and after it came back
#                  `prepare` could not match the stream key for 8 h while the publisher
#                  restarted every 17 s.
#   2026-11-10     the off-host watchdog was found running from DELETED files; a reboot would
#                  have retired the only thing that can alert. Nothing in `systemctl status`
#                  said so - so this script checks what is there, not what is running.
#   2026-11-09     the camera moved 192.168.1.20 -> .2 mid-outage, and RTSP demux timeouts
#                  continued after it "answered": TCP reachable is not frames flowing.
#
# WHAT IT MAY DO (cheapest and most reversible first)
#   * kickstart a launchd job that is not loaded or not running (never `kill`, never a pattern)
#   * trim logs when the disk is low                          (in place, same inode)
#   * `yt_api.py prepare` + `ensure-live` for a feed with no live broadcast - but ONLY when
#     ingest is already flowing, no rotation is armed, and the API answered a real state
#   * reboot the ONVIF camera, but ONLY when it accepts TCP and delivers no frames, after N
#     consecutive passes, at most once per cooldown
#   * restart the 16:9 publisher, or stream.sh itself, only after its own watchdog has had two
#     passes to fix it (stream.sh retries the publisher every 5 s; this does not double that)
#
# WHAT IT MUST NEVER DO (tests/t23_watchguard.sh asserts each one)
#   * never `pkill`/`killall`: a pid is signalled only through its pidfile + identity check, or
#     through launchd by label. A recycled pid must not become a victim.
#   * never power-cycle the USB-Ethernet service and never reorder network services - the
#     2026-09-19 carrier loss and the LAN-primary rule are recorded traps; net_watch.sh owns the
#     transport and this script does not touch interfaces at all.
#   * never reboot the Mac. It cannot fix a camera, and a reboot with auto-login broken is the
#     one way to lose the machine permanently.
#   * never cut, rotate or `end` a live broadcast. Repairs are additive and idempotent; a cut
#     destroys the segment being recorded right now.
#   * never act on UNKNOWN. "yt-dlp/API could not answer" is not "the channel is dark" - the
#     same rule as bin/yt_monitor.sh and bin/yt_watchdog.py.
#   * never act twice inside a cooldown, and never take more than WG_MAX_ACTIONS per pass.
#     A watchdog that thrashes is worse than the outage it is chasing.
#
# WHAT IT CANNOT DO, AND NO SCRIPT CAN
#   A powered-off MacBook is unreachable from inside it. This Mac's `pmset autorestart` is
#   UNSUPPORTED on this hardware (measured 2026-09-19, AGENTS.md), so the only mitigations for
#   "no power" are a UPS on the Mac AND the router (T-30) and the off-host watchdog telling a
#   human. What this script guarantees is the other half: when power returns, the box is driven
#   back to two live feeds without anyone touching it - and that is checked every pass, not
#   assumed.
#
# Usage:  bin/watchguard.sh             run the loop (what the LaunchAgent runs)
#         bin/watchguard.sh --once      one pass; exit 0 healthy, 1 repaired, 2 degraded
#         bin/watchguard.sh --dry-run   decide and log, take no action
#         bin/watchguard.sh --status    what the last pass saw and did
set -u
BASE="${BASE:-${0:A:h:h}}"
CONF="${CONF:-$BASE/conf/stream.env}"
LOG="$BASE/log/watchguard.log"
STATE="$BASE/log/watchguard.state"
BEAT="$BASE/log/watchguard.heartbeat"
LOCK="$BASE/log/watchguard.lock"
CAMIP_FILE="$BASE/log/cam_ip"
PUB_PID="$BASE/log/publisher.pid"
MON_BEAT="$BASE/log/monitor.heartbeat"
NET_STATE="$BASE/log/net_state"
PROGRESS="$BASE/log/progress.txt"
ROTATE_FLAG="$BASE/log/rotating"
FFPROBE="$HOME/.local/bin/ffprobe"
CAM_REBOOT="$BASE/bin/cam_reboot.py"
YT_API="$BASE/bin/yt_api.py"

[[ -r "$CONF" ]] && source "$CONF"
[[ -r "$BASE/conf/vertical.env" ]] && source "$BASE/conf/vertical.env"
source "$BASE/bin/lib.sh"

# ---------------------------------------------------------------------------
# Knobs. Defaults so this runs on a config that predates it.
# ---------------------------------------------------------------------------
: ${WATCHGUARD_EVERY:=600}          # seconds between passes - the cadence the operator asked for
: ${WG_DISK_LOW_MB:=1500}           # free space that makes a pass trim logs
: ${WG_NET_STALE:=300}              # net_state older than this means net_watch stopped writing
: ${WG_NET_RESTART_AFTER:=900}      # ... and this long a silence restarts stream.sh
: ${WG_CAM_FAILS_BEFORE_REBOOT:=2}  # consecutive frame-less passes before an ONVIF reboot
: ${WG_CAM_REBOOT_COOLDOWN:=3600}   # never reboot the camera twice inside this window
: ${WG_CAM_PROBE_TIMEOUT:=12}       # seconds for one RTSP frame probe (passed to ffprobe in us)
: ${WG_CAM_REBOOT_SETTLE:=20}       # seconds to wait after an ONVIF reboot before re-probing
: ${WG_AGENT_COOLDOWN:=900}         # between two kickstarts of the same job
: ${WG_STREAM_COOLDOWN:=1800}       # between two restarts of stream.sh itself
: ${WG_BROADCAST_COOLDOWN:=1200}    # between two prepare/ensure-live repairs of one feed
: ${WG_MONITOR_STALE:=900}          # monitor heartbeat age that means the monitor is gone
: ${WG_MAX_ACTIONS:=4}              # hard ceiling of ACTIONS in one pass
: ${WG_LOG_MAX_BYTES:=1048576}
: ${WG_PLISTS:="$HOME/Library/LaunchAgents"}
: ${VERT_ENABLED:=no}
: ${VERT_KEY:=}
: ${MONITOR_STALE:=600}

DRY=no
ACTIONS=0
VERDICT=OK
TROUBLE=""
CAM_URL="${CAM_URL:-}"

mkdir -p "$BASE/log" 2>/dev/null

wlog() { print -r -- "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG"; }
say()  { print -r -- "$*"; }

# Keep the log bounded WITHOUT renaming it (an append fd would follow an unlinked inode). Same
# idiom as stream.sh's trim_log and net_watch.sh's trim_events.
trim_log() {
  local f="$1" max="${2:-${WG_LOG_MAX_BYTES:-1048576}}"
  [[ -f "$f" ]] || return 0
  local sz; sz=$(/usr/bin/stat -f %z "$f" 2>/dev/null) || return 0
  (( sz > max )) || return 0
  local tmp="${TMPDIR:-/tmp}/ytlive-wg.$$"
  if tail -c $(( max / 2 )) "$f" > "$tmp" 2>/dev/null; then cat "$tmp" > "$f"; fi
  rm -f "$tmp"
}

# --- state: one key=value per line, read and written whole ---------------------------------
typeset -gA ST=()
load_state() {
  ST=()
  [[ -r "$STATE" ]] || return 0
  local line k v
  while IFS= read -r line; do
    [[ "$line" == *=* ]] || continue
    k="${line%%=*}"; v="${line#*=}"
    ST[$k]="$v"
  done < "$STATE"
}
st_get() { print -r -- "${ST[$1]:-0}" }
st_set() { ST[$1]="$2" }
save_state() {
  local tmp="${TMPDIR:-/tmp}/ytlive-wgst.$$"
  : > "$tmp" || return 1
  local k
  for k in ${(ko)ST}; do print -r -- "$k=${ST[$k]}" >> "$tmp"; done
  mv "$tmp" "$STATE" 2>/dev/null
}

now() { date +%s; }
cooldown_ok() {   # cooldown_ok KEY SECONDS
  local last; last=$(st_get "$1")
  [[ "$last" == <-> ]] || last=0
  (( $(now) - last >= $2 ))
}

# Every action goes through here: the ONE place that counts, logs and enforces the cap, so a
# report can never claim an action that did not happen.
act() {   # act WHAT DETAIL
  local what="$1" detail="$2"
  if (( ACTIONS >= WG_MAX_ACTIONS )); then
    wlog "ACTION-LIMIT: refusing '$what' ($detail) - $WG_MAX_ACTIONS actions already in this pass"
    return 1
  fi
  ACTIONS=$(( ACTIONS + 1 ))
  if [[ "$DRY" == yes ]]; then
    wlog "WOULD: $what - $detail"
  else
    wlog "ACTION: $what - $detail"
  fi
  return 0
}

# ---------------------------------------------------------------------------
# PURE DECISIONS. No clock, no I/O: a rule that can only be tested by waiting is untestable,
# and these rules are the part that has to be right. Same idiom as net_watch.sh's net_action
# and yt_watchdog.py's decision functions.
# ---------------------------------------------------------------------------

# camera_action TCP_OK FRAMES_OK FAILS COOLDOWN_OK  ->  none | observe | reboot
#   TCP reachable is NOT frames flowing: on 2026-11-09 the camera answered 554 while every RTSP
#   session timed out. A reboot needs ONVIF, so it is only attempted when TCP answered.
camera_action() {
  local tcp="$1" frames="$2" fails="$3" cool="$4"
  [[ "$tcp" == yes && "$frames" == yes ]] && { print none; return }
  [[ "$tcp" == yes ]] || { print observe; return }      # unreachable: not ours to reboot
  (( fails < WG_CAM_FAILS_BEFORE_REBOOT )) && { print observe; return }
  [[ "$cool" == yes ]] && { print reboot; return }
  print none
}

# publisher_action AGENT_OK PUBLISHER_OK FAILS COOLDOWN_OK
#   ->  none | observe | kickstart-stream | restart-publisher
publisher_action() {
  local agent="$1" pub="$2" fails="$3" cool="$4"
  [[ "$agent" == yes && "$pub" == yes ]] && { print none; return }
  if [[ "$agent" != yes ]]; then
    [[ "$cool" == yes ]] && print kickstart-stream || print none
    return
  fi
  # stream.sh is alive and its own watchdog restarts a dead publisher every 5 s. Give it two
  # passes before stepping in, so a deliberate restart is never doubled.
  (( fails < 2 )) && { print observe; return }
  print restart-publisher
}

# broadcast_action STATE PUBLISHING ROTATING COOLDOWN_OK  ->  none | observe | repair
#   STATE is what the API said: LIVE / READY / PENDING / OFFLINE / UNKNOWN / ERROR / empty.
broadcast_action() {
  local state="$1" pub="$2" rot="$3" cool="$4"
  case "$state" in
    LIVE) print none ;;
    READY|ready|PENDING|pending|OFFLINE|offline|created)
      [[ "$pub" == yes && "$rot" == no && "$cool" == yes ]] && print repair || print observe ;;
    *) print none ;;   # UNKNOWN / ERROR / empty / EXPIRING: a lookup failure is not an outage
  esac
}

# agent_action LOADED COOLDOWN_OK  ->  none | kickstart
agent_action() {
  [[ "$1" == yes ]] && { print none; return }
  [[ "$2" == yes ]] && print kickstart || print none
}

# monitor_action AGE COOLDOWN_OK  ->  none | kickstart
monitor_action() {
  (( $1 > WG_MONITOR_STALE )) && [[ "$2" == yes ]] && { print kickstart; return }
  print none
}

# ---------------------------------------------------------------------------
# Observation helpers (cheap; no side effects)
# ---------------------------------------------------------------------------
launchctl_loaded() {
  launchctl print "gui/$UID/$1" >/dev/null 2>&1
}

metric_age() {   # metric_age FILE -> seconds since mtime, or a huge number when absent
  [[ -e "$1" ]] || { print 999999; return }
  local m; m=$(/usr/bin/stat -f %m "$1" 2>/dev/null) || { print 999999; return }
  print $(( $(now) - m ))
}

cam_addr() {
  if [[ -r "$CAMIP_FILE" ]]; then
    local a; a=$(<"$CAMIP_FILE"); a="${a//[[:space:]]/}"
    [[ -n "$a" ]] && { print -r -- "$a"; return; }
  fi
  print -r -- "${CAM_URL#rtsp://}" | cut -d/ -f1 | cut -d: -f1
}

cam_rtsp_url() {   # cam_rtsp_url HOST -> the configured RTSP path on that host
  local rest="${CAM_URL#*://}"
  rest="${rest#*/}"
  print -r -- "rtsp://$1/$rest"
}

tcp_open() {   # tcp_open HOST [PORT]
  nc -z -G 3 "$1" "${2:-554}" >/dev/null 2>&1
}

# A REAL frame probe: does the camera deliver decodable video, not merely accept TCP?
# One pass per WATCHGUARD_EVERY at 12 s worst case is a rounding error next to two encoders.
frames_flow() {
  local url="$1" probe="$FFPROBE"
  [[ -x "$probe" ]] || probe=$(command -v ffprobe 2>/dev/null) || return 1
  [[ -n "${probe:-}" ]] || return 1
  local out
  out=$("$probe" -v error -rtsp_transport tcp -timeout $(( WG_CAM_PROBE_TIMEOUT * 1000000 )) \
        -select_streams v:0 -show_entries stream=codec_name -of csv=p=0 "$url" 2>/dev/null)
  [[ -n "$out" ]]
}

api_state() {   # api_state [KEY] -> the JSON body (never raises); no KEY means the 16:9
  local key="${1:-}"
  if [[ -n "$key" ]]; then
    BASE="$BASE" YT_KEY="$key" YT_TEMPLATE="${VERT_TEMPLATE:-$BASE/conf/vertical_template.json}" \
      python3 "$YT_API" status 2>&1
  else
    yt_api_call status
  fi
}

json_field() {   # json_field '<json>' FIELD  -- empty on parse failure, never a guess
  python3 -c 'import json,sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
v = d.get(sys.argv[1])
print(v if v is not None else "")' "$2" <<<"$1" 2>/dev/null
}

mark_trouble() { [[ " $TROUBLE " == *" $1 "* ]] || TROUBLE="${TROUBLE:+$TROUBLE }$1"; }

rotating() {   # 0 while a rotation owns the stream
  [[ -f "$ROTATE_FLAG" ]] || return 1
  local until; until=$(<"$ROTATE_FLAG")
  [[ "$until" == <-> ]] || return 1
  (( $(now) < until ))
}

restart_stream() {
  [[ "$DRY" == yes ]] && return 0
  if [[ -f "$WG_PLISTS/com.user.cctv-stream.plist" ]]; then
    launchctl load -w "$WG_PLISTS/com.user.cctv-stream.plist" >/dev/null 2>&1
  fi
  launchctl kickstart -k "gui/$UID/com.user.cctv-stream" >/dev/null 2>&1
  st_set restart.stream "$(now)"
}

# ---------------------------------------------------------------------------
# The checks. Each returns 0 healthy, 1 repaired, 2 degraded-and-unfixable-this-pass.
# ---------------------------------------------------------------------------
check_power() {
  # Power is the one class software cannot repair. Recording it is not decoration: it is the
  # difference between "the stream is unstable" and "someone must buy a UPS".
  local batt
  batt=$(pmset -g batt 2>/dev/null | tr '\n' ' ')
  case "$batt" in
    *"AC Power"*) return 0 ;;
    *"Battery Power"*)
      mark_trouble power
      wlog "POWER: on the battery - a power cut leaves this host off air until mains returns (a UPS is the only fix)"
      return 2 ;;
  esac
  return 0
}

check_disk() {
  local free
  free=$(df -m / 2>/dev/null | awk 'NR==2{print $4}')
  [[ "$free" == <-> ]] || return 0
  (( free < WG_DISK_LOW_MB )) || return 0
  mark_trouble disk
  act trim-logs "free ${free}MB < ${WG_DISK_LOW_MB}MB" || return 2
  [[ "$DRY" == yes ]] && return 1
  local f
  for f in "$BASE/log/stream.log" "$BASE/log/publisher.log" "$BASE/log/monitor.log" \
           "$BASE/log/vertical.log" "$BASE/log/vertical.publisher.log" "$BASE/log/reader.log"; do
    trim_log "$f" 262144
  done
  return 1
}

check_agents() {
  local label st=0 plan
  for label in com.user.cctv-stream com.user.cctv-monitor com.user.cctv-vertical com.user.cctv-camscan; do
    launchctl_loaded "$label" && continue
    mark_trouble agent
    plan=$(agent_action no "$(cooldown_ok "kick.$label" "$WG_AGENT_COOLDOWN" && print yes || print no)")
    if [[ "$plan" != kickstart ]]; then st=2; continue; fi
    act kickstart "$label is not loaded" || { st=2; continue; }
    st=1
    [[ "$DRY" == yes ]] && continue
    # load -w first: a job whose plist was unloaded is not kickstartable. Both are idempotent.
    [[ -f "$WG_PLISTS/$label.plist" ]] && launchctl load -w "$WG_PLISTS/$label.plist" >/dev/null 2>&1
    launchctl kickstart -k "gui/$UID/$label" >/dev/null 2>&1 \
      || wlog "ACTION-FAILED: kickstart $label returned non-zero"
    st_set "kick.$label" "$(now)"
  done
  return $st
}

check_net() {
  local age; age=$(metric_age "$NET_STATE")
  (( age > WG_NET_STALE )) || return 0
  mark_trouble net
  # net_watch is a child of stream.sh. A stale state file means it stopped writing; if that
  # lasts, the only repair is restarting stream.sh - a controlled bounce, so it is rate-limited
  # hard and only taken after the longer threshold.
  if (( age >= WG_NET_RESTART_AFTER )) && cooldown_ok restart.stream "$WG_STREAM_COOLDOWN"; then
    act restart-stream "net_state has not moved for ${age}s (net_watch inside stream.sh is silent)" || return 2
    restart_stream
    return 1
  fi
  wlog "NET: net_state is ${age}s old (the transport watchdog is not reporting)"
  return 2
}

check_camera() {
  local cam tcp=no frames=no fails plan url
  cam=$(cam_addr)
  [[ -n "$cam" ]] || { mark_trouble camera; wlog "CAMERA: no camera address known"; return 2; }
  url=$(cam_rtsp_url "$cam")
  tcp_open "$cam" 554 && tcp=yes
  [[ "$tcp" == yes ]] && frames_flow "$url" && frames=yes
  fails=$(st_get cam_fails); [[ "$fails" == <-> ]] || fails=0
  if [[ "$tcp" == yes && "$frames" == yes ]]; then
    st_set cam_fails 0
    return 0
  fi
  fails=$(( fails + 1 )); st_set cam_fails "$fails"
  mark_trouble camera
  plan=$(camera_action "$tcp" "$frames" "$fails" \
      "$(cooldown_ok camera.reboot "$WG_CAM_REBOOT_COOLDOWN" && print yes || print no)")
  wlog "CAMERA: $cam tcp=$tcp frames=$frames fails=$fails -> $plan"
  case "$plan" in
    reboot)
      act cam-reboot "$cam accepts TCP but delivers no frames (${fails} passes)" || return 2
      [[ "$DRY" == yes ]] && return 1
      st_set camera.reboot "$(now)"
      local out; out=$(python3 "$CAM_REBOOT" "$cam" 8899 2>&1)
      wlog "CAM-REBOOT: $(print -r -- "$out" | tr '\n' ' ' | cut -c1-200)"
      sleep "$WG_CAM_REBOOT_SETTLE"
      if frames_flow "$url"; then
        wlog "CAM-REBOOT: frames are flowing again"
        st_set cam_fails 0
      else
        wlog "CAM-REBOOT: still no frames after the reboot"
      fi
      return 1 ;;
    observe) return 2 ;;
    *) return 2 ;;
  esac
}

# The 16:9 feed: publisher liveness, then whether the feed is actually LIVE on YouTube.
check_16x9() {
  local st=0 pid age fails pub=no agent=no plan body state rot=no
  launchctl_loaded com.user.cctv-stream && agent=yes
  pid=$(pidfile_pid "$PUB_PID" ffmpeg rtmp)
  [[ -n "$pid" ]] && pub=yes
  if rotating; then rot=yes; fi
  age=$(metric_age "$PROGRESS")
  fails=$(st_get pub_fails); [[ "$fails" == <-> ]] || fails=0

  # A publisher that exists but has written no progress for over two cadences is wedged,
  # not merely early: ffmpeg rewrites progress.txt continuously.
  if [[ "$pub" == yes ]] && (( age > WATCHGUARD_EVERY * 2 + 120 )); then
    wlog "16:9: publisher pid $pid has not written progress for ${age}s"
    mark_trouble publisher
    pub=no
  fi

  if [[ "$rot" == no && "$pub" == no ]]; then
    fails=$(( fails + 1 )); st_set pub_fails "$fails"; mark_trouble publisher
    plan=$(publisher_action "$agent" no "$fails" \
        "$(cooldown_ok restart.stream "$WG_AGENT_COOLDOWN" && print yes || print no)")
    case "$plan" in
      kickstart-stream)
        act restart-stream "the stream agent is not loaded" || return 2
        restart_stream; st=1 ;;
      restart-publisher)
        if [[ -n "$pid" ]]; then
          act restart-publisher "pid $pid is wedged (no progress for ${age}s)" || return 2
          [[ "$DRY" == no ]] && kill -9 "$pid" 2>/dev/null
          st=1
        else
          # No trustworthy pid: stream.sh's own watchdog is the only thing allowed to restart
          # it, and there is nothing here to signal. Say so instead of killing a guess.
          wlog "16:9: no trustworthy publisher pid - NOT killing anything (stream.sh owns it)"
          st=2
        fi ;;
      *) st=2 ;;
    esac
  elif [[ "$pub" == yes ]]; then
    st_set pub_fails 0
  fi

  body=$(api_state)
  state=$(json_field "$body" status)
  plan=$(broadcast_action "$state" "$([[ "$pub" == yes ]] && print yes || print no)" "$rot" \
      "$(cooldown_ok broadcast.16x9 "$WG_BROADCAST_COOLDOWN" && print yes || print no)")
  case "$plan" in
    none)
      if [[ -z "$state" || "$state" == UNKNOWN || "$state" == ERROR ]]; then
        wlog "16:9: API answered '$state' - not acting on a lookup failure"
      fi ;;
    observe)
      mark_trouble broadcast
      wlog "16:9: API state=$state pubbing=$pub rotating=$rot - observing (not repairing)"
      st=2 ;;
    repair)
      mark_trouble broadcast
      act repair-broadcast "16:9 API state=$state while ingest is flowing" || return 2
      if [[ "$DRY" == no ]]; then
        st_set broadcast.16x9 "$(now)"
        local prep ens
        prep=$(yt_api_call prepare)
        wlog "PREPARE: $(print -r -- "$prep" | cut -c1-220)"
        ens=$(yt_api_call ensure-live)
        wlog "ENSURE-LIVE: $(print -r -- "$ens" | cut -c1-220)"
      fi
      st=1 ;;
  esac
  return $st
}

# The 9:16 feed: its own broadcast, its own supervisor - and until now NOTHING checked that it
# was live, because the off-host watchdog reads the channel's one /live page.
check_vertical() {
  [[ "$VERT_ENABLED" == "yes" && -n "$VERT_KEY" ]] || return 0
  local body state fails st=0
  if ! launchctl_loaded com.user.cctv-vertical; then
    mark_trouble vertical
    if cooldown_ok kick.vertical "$WG_AGENT_COOLDOWN"; then
      act kickstart "com.user.cctv-vertical is not loaded" || return 2
      if [[ "$DRY" == no ]]; then
        [[ -f "$WG_PLISTS/com.user.cctv-vertical.plist" ]] && \
          launchctl load -w "$WG_PLISTS/com.user.cctv-vertical.plist" >/dev/null 2>&1
        launchctl kickstart -k "gui/$UID/com.user.cctv-vertical" >/dev/null 2>&1
        st_set kick.vertical "$(now)"
      fi
      return 1
    fi
    return 2
  fi
  body=$(api_state "$VERT_KEY")
  state=$(json_field "$body" status)
  if [[ "$state" == LIVE ]]; then st_set vert_fails 0; return 0; fi
  if [[ -z "$state" || "$state" == UNKNOWN || "$state" == ERROR || "$state" == EXPIRING ]]; then
    wlog "9:16: API answered '$state' - not acting on a lookup failure"
    return 0
  fi
  fails=$(st_get vert_fails); [[ "$fails" == <-> ]] || fails=0
  fails=$(( fails + 1 )); st_set vert_fails "$fails"
  mark_trouble vertical
  if (( fails >= 2 )) && cooldown_ok restart.vertical "$WG_STREAM_COOLDOWN"; then
    act restart-vertical "9:16 API state=$state for ${fails} passes" || return 2
    if [[ "$DRY" == no ]]; then
      st_set restart.vertical "$(now)"
      # The vertical's own loop restarts its publisher; a kickstart is the heaviest safe rung.
      launchctl kickstart -k "gui/$UID/com.user.cctv-vertical" >/dev/null 2>&1
    fi
    return 1
  fi
  wlog "9:16: API state=$state (pass $fails) - observing"
  return 2
}

check_monitor() {
  local age plan
  age=$(metric_age "$MON_BEAT")
  plan=$(monitor_action "$age" \
      "$(cooldown_ok kick.com.user.cctv-monitor "$WG_AGENT_COOLDOWN" && print yes || print no)")
  if [[ "$plan" == kickstart ]]; then
    mark_trouble monitor
    act kickstart "monitor heartbeat is ${age}s old (stale at ${MONITOR_STALE}s)" || return 2
    if [[ "$DRY" == no ]]; then
      launchctl kickstart -k "gui/$UID/com.user.cctv-monitor" >/dev/null 2>&1
      st_set kick.com.user.cctv-monitor "$(now)"
    fi
    return 1
  fi
  (( age > WG_MONITOR_STALE )) && { mark_trouble monitor; return 2; }
  return 0
}

# ---------------------------------------------------------------------------
# One pass
# ---------------------------------------------------------------------------
pass() {
  load_state
  local started; started=$(now)
  local rc=0 x=0
  VERDICT=OK; TROUBLE=""; ACTIONS=0

  check_power;  x=$?; (( x > rc )) && rc=$x
  check_disk;   x=$?; (( x > rc )) && rc=$x
  check_agents; x=$?; (( x > rc )) && rc=$x
  check_net;    x=$?; (( x > rc )) && rc=$x
  check_camera; x=$?; (( x > rc )) && rc=$x
  check_16x9;   x=$?; (( x > rc )) && rc=$x
  check_vertical; x=$?; (( x > rc )) && rc=$x
  check_monitor;  x=$?; (( x > rc )) && rc=$x

  case "$rc" in
    0) VERDICT=OK ;;
    1) VERDICT=REPAIRED ;;
    *) VERDICT=DEGRADED ;;
  esac
  [[ -n "$TROUBLE" ]] && VERDICT="$VERDICT(${TROUBLE// /,})"

  st_set pass_epoch "$started"
  st_set pass_no $(( $(st_get pass_no) + 1 ))
  st_set verdict "$VERDICT"
  st_set actions "$ACTIONS"
  save_state

  # The heartbeat is how status.sh tells "quiet" from "dead", exactly like monitor.heartbeat.
  print -r -- "$(now) $VERDICT actions=$ACTIONS" > "$BEAT" 2>/dev/null

  # Every pass is logged, healthy or not: "no line for ten minutes" must never be the only
  # way to tell a quiet watchguard from a dead one (status.sh reads the heartbeat, humans read
  # this line).
  local line="PASS $(( $(now) - started ))s verdict=$VERDICT actions=$ACTIONS"
  wlog "$line"
  [[ "$VERDICT" != OK ]] && say "$line"
  trim_log "$LOG"
  return $rc
}

cmd_status() {
  load_state
  local age; age=$(metric_age "$BEAT")
  print -r -- "watchguard: verdict=$(st_get verdict) pass=$(st_get pass_no) at $(st_get pass_epoch)"
  print -r -- "  heartbeat: ${age}s old (interval ${WATCHGUARD_EVERY}s)"
  print -r -- "  actions  : $(st_get actions) in the last pass"
  print -r -- "  counters : cam_fails=$(st_get cam_fails) pub_fails=$(st_get pub_fails) vert_fails=$(st_get vert_fails)"
  local f
  for f in camera.reboot restart.stream broadcast.16x9 restart.vertical; do
    print -r -- "  last $f: $(st_get "$f")"
  done
  print -r -- "  log      : $LOG"
  (( age <= WATCHGUARD_EVERY * 3 ))
}

# One instance only. launchd's KeepAlive already prevents a second copy, but a hand-run loop
# during an incident must not fight the agent. --once/--dry-run are deliberately exempt.
acquire_lock() {
  if [[ -r "$LOCK" ]]; then
    local pid; pid=$(<"$LOCK")
    if [[ "$pid" == <-> ]] && kill -0 "$pid" 2>/dev/null; then
      print -r -- "watchguard: already running as pid $pid" >&2
      return 1
    fi
  fi
  print -r -- $$ > "$LOCK" 2>/dev/null
  return 0
}

case "${1:-loop}" in
  --status) cmd_status; exit $? ;;
  --once)   pass; exit $? ;;
  --dry-run) DRY=yes; pass; exit $? ;;
  loop)
    acquire_lock || exit 0
    # Beat before the work, so a slow pass cannot look like a dead watchguard (the same bug
    # class the monitor's heartbeat had to be rewritten for).
    print -r -- "$(now) STARTING actions=0" > "$BEAT" 2>/dev/null
    wlog "watchguard starting: every ${WATCHGUARD_EVERY}s plists=$WG_PLISTS"
    while true; do
      pass
      sleep "$WATCHGUARD_EVERY"
    done ;;
  *) print -u2 -- "usage: bin/watchguard.sh [--once|--dry-run|--status]"; exit 2 ;;
esac
