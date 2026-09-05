#!/bin/zsh
# Health check for the CCTV->YouTube stream.
#
# This used to grep launchctl for cctv-stream and nothing else, which meant it printed a
# clean bill of health on a machine whose watchdog was dead. Everything that can fail
# silently is on this page now: both jobs, the watchdog heartbeat, the OAuth token, and
# what YouTube itself thinks.
#   --no-net   skip the YouTube API call (everything else is local and instant)
set -u
BASE="${BASE:-$HOME/Downloads/YTLive}"
source "$BASE/conf/stream.env"
NET=yes; [[ "${1:-}" == "--no-net" ]] && NET=no
# no -r here: print -r is raw and would emit the escape codes literally
ok()   { print -- "  \033[32mOK\033[0m    $*"; }
warn() { print -- "  \033[33mWARN\033[0m  $*"; }
bad()  { print -- "  \033[31mFAIL\033[0m  $*"; }

print "=== launchd jobs ==="
for l in com.user.cctv-stream com.user.cctv-monitor; do
  line=$(launchctl list 2>/dev/null | grep "$l")
  if [[ -z "$line" ]]; then
    bad "$l is NOT loaded  ->  launchctl load -w ~/Library/LaunchAgents/$l.plist"
  else
    pid=$(print -r -- "$line" | awk '{print $1}')
    [[ "$pid" == "-" ]] && warn "$l loaded but not running (last exit $(print -r -- "$line" | awk '{print $2}'))" \
                        || ok "$l running, pid $pid"
  fi
done

print "\n=== publisher ==="
if pgrep -f "ffmpeg.*rtmp://" >/dev/null 2>&1; then
  f1=$(grep -a '^frame=' "$BASE/log/progress.txt" 2>/dev/null | tail -1 | cut -d= -f2)
  sleep 2
  f2=$(grep -a '^frame=' "$BASE/log/progress.txt" 2>/dev/null | tail -1 | cut -d= -f2)
  if [[ -n "$f2" && "$f2" != "$f1" ]]; then ok "pushing to YouTube (frame $f1 -> $f2)"
  else bad "ffmpeg is running but the frame counter is STUCK at ${f1:-?}"; fi
else
  bad "no publisher ffmpeg running - nothing is being sent to YouTube"
fi

print "\n=== watchdog heartbeat ==="
HB="$BASE/log/monitor.heartbeat"
if [[ -f "$HB" ]]; then
  age=$(( $(date +%s) - $(/usr/bin/stat -f %m "$HB") ))
  read -r _ hbst hbrest < "$HB"
  if   (( age > 600 )); then bad  "heartbeat ${age}s old - the watchdog is hung or gone"
  elif (( age > 120 )); then warn "heartbeat ${age}s old (last status: $hbst)"
  else                       ok   "checked ${age}s ago, last status: $hbst"; fi
  [[ -n "${hbrest:-}" ]] && print "        $hbrest"
else
  bad "no heartbeat file - the watchdog has not run since this was installed"
fi

print "\n=== OAuth token (Testing apps expire every 7 days) ==="
tok=$(BASE="$BASE" python3 "$BASE/bin/yt_api.py" token 2>&1); trc=$?
case $trc in
  0) ok   "$tok" ;;
  1) warn "$tok" ;;
  *) bad  "$tok  ->  $BASE/bin/yt_api.py auth" ;;
esac

if [[ "$NET" == yes ]]; then
  print "\n=== YouTube says ==="
  st=$(BASE="$BASE" python3 "$BASE/bin/yt_api.py" status 2>&1)
  print -r -- "$st" | grep -q '"status": *"LIVE"' && ok "$st" || bad "$st"
fi

print "\n=== camera ==="
host=$(<"$BASE/log/cam_ip" 2>/dev/null) || host="${CAM_URL#rtsp://}"
host=${host%%/*}; host=${host%%:*}
nc -z -G 3 "$host" 554 2>/dev/null && ok "$host:554 reachable" || bad "$host:554 UNREACHABLE (stream shows the filler still)"

print "\n=== disk ==="
print "  log/ $(du -sh "$BASE/log" 2>/dev/null | cut -f1)   repo $(du -sh "$BASE/.git" 2>/dev/null | cut -f1)"
du -h "$BASE/log"/*(.N) 2>/dev/null | sort -rh | head -4 | sed 's/^/  /'

print "\n=== rotations (the project's own record of whether it needs the API) ==="
RH="$BASE/log/rotation_history.log"
if [[ -s "$RH" ]]; then
  tail -5 "$RH" | sed 's/^/  /'
  n=$(grep -c 'mode=native' "$RH"); a=$(grep -c 'mode=api-fallback' "$RH"); f=$(grep -c 'mode=failed' "$RH")
  print "  totals: ${n} native, ${a} needed the API, ${f} failed"
  (( a == 0 && f == 0 && n >= 3 )) && ok "native rotation is carrying it - the OAuth token is only a spare" \
                                    || warn "the API is still load-bearing - keep the token alive"
else
  print "  (no rotation has run yet)"
fi
