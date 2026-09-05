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

print "\n=== configuration vs conf/broadcast_template.json ==="
if [[ -s "$BASE/conf/broadcast_template.json" ]]; then
  if [[ "$NET" == yes ]]; then
    v=$(BASE="$BASE" YT_TITLE_FMT="${YT_TITLE_FMT:-}" python3 "$BASE/bin/yt_api.py" verify 2>&1)
    print -r -- "$v" | grep -q '"status": *"OK"' && ok "live broadcast matches the reference" || bad "$v"
  fi
  python3 - "$BASE/conf/broadcast_template.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
v=d.get("video",{})
print(f"  title  {len(v.get('title',''))} chars | desc {len(v.get('description',''))} chars | "
      f"{len(v.get('tags') or [])} tags | cat {v.get('categoryId')} | lang {v.get('defaultLanguage')}")
print(f"  latency {d.get('broadcast',{}).get('latencyPreference')} | dvr "
      f"{d.get('broadcast',{}).get('enableDvr')} | localizations "
      f"{list((d.get('localizations') or {}).keys())}")
import os
tp = [c for c in ("conf/thumbnail.png","conf/thumbnail.jpg")
      if os.path.exists(os.path.join(os.path.dirname(os.path.dirname(sys.argv[1])), c))]
print(f"  thumbnail {tp[0] if tp else 'NONE - run: bin/yt_api.py thumbnail <file>'}")
for name,m in (d.get("manual") or {}).items():
    state = "wanted ON" if m.get("desired") else "wanted OFF"
    print(f"  MANUAL: {name} - {state}, NOT settable or readable via the API")
    print(f"          set it at: {m.get('where')}")
PY
else
  print "  (no reference captured yet - run: bin/yt_api.py capture)"
fi

print "\n=== recordings (the whole point of cutting at 8h) ==="
VS="$BASE/log/vod_status"
if [[ -s "$VS" ]]; then
  head -5 "$VS" | sed 's/^/  /'
  good=$(grep -c ' ok ' "$VS"); miss=$(grep -c ' MISSING ' "$VS")
  (( miss == 0 )) && ok "${good} recordings saved and reviewable, none lost" \
                  || bad "${miss} recording(s) NOT reviewable - the cut is happening too late"
else
  print "  (nothing verified yet - the first check runs at the rotation after next)"
fi
