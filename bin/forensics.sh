#!/bin/zsh
# Collect the evidence for a HOST-LEVEL outage, on the streamer, in one shot.
#
#   bin/forensics.sh              fast report to stdout (~5 s)
#   bin/forensics.sh --save       also writes log/forensics-<stamp>.txt
#   bin/forensics.sh --deep       adds the slow `log show` queries (~30 s)
#
# READ-ONLY. It changes nothing, deliberately: the evidence for why the host vanished lives
# in the sleep log, the panic reports, the swap figures and the tail of the project's own
# logs, and a reboot is exactly what destroys the in-memory half of it. Run this BEFORE
# power-cycling if the machine responds at all.
#
# Why it exists: on 2026-09-18 the streamer dropped off the network mid-segment and stayed
# dark 10 h 23 m. From outside, a sleeping Mac, a hung Mac and a powered-off Mac are
# indistinguishable - all three look like "powered on, wifi fine, Tailscale offline". The
# candidates are separated only by data this machine has, and the point of this script is to
# fetch all of it in one command instead of six:
#
#   1. lid-close / idle sleep on battery - caffeinate -s is AC-only, and lid-close sleep is a
#      separate assertion that only `pmset disablesleep` covers
#   2. a hang                             - huge load average, long uptime, swap blown out
#   3. a panic or a forced power-off      - a .panic report, or shutdown cause -128
#   4. a reboot to the login window       - SHORT uptime and no console user: the two agents
#      are USER LaunchAgents, so nothing starts until someone logs in
set -u

BASE="${BASE:-${0:A:h:h}}"
SAVE=no
DEEP=no
for a in "$@"; do
  case "$a" in
    --save) SAVE=yes ;;
    --deep) DEEP=yes ;;
    -h|--help) sed -n '2,22p' "${0:A}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) print -u2 -- "unknown argument: $a"; exit 2 ;;
  esac
done

STAMP=$(date -u '+%Y%m%dT%H%M%SZ')
OUT="${TMPDIR:-/tmp}/ytlive-forensics.$$"

# Everything goes into one buffer and is printed at the end, so --save cannot make the report
# print itself through a tee it is still writing to.
{
hdr() { print -- ""; print -- "=== $1 ==="; }

print -- "YTLive host forensics - $(date -u '+%Y-%m-%dT%H:%M:%SZ') UTC / $(date '+%Y-%m-%d %H:%M %Z') local"

hdr "identity and uptime"
print -- "host   : $(hostname)"
print -- "model  : $(sysctl -n hw.model 2>/dev/null)"
print -- "macOS  : $(sw_vers -productVersion 2>/dev/null) ($(sw_vers -buildVersion 2>/dev/null))"
print -- "uptime : $(uptime)"
print -- "booted : $(sysctl -n kern.boottime 2>/dev/null)"
print -- "  A SHORT uptime means it rebooted. If there is also no console user below, it is"
print -- "  sitting at a login window and neither agent has started since."

hdr "who is logged in"
print -- "console user : $(stat -f %Su /dev/console 2>/dev/null)"
print -- "logged in    : $(who 2>/dev/null | awk '{print $1}' | sort -u | tr '\n' ' ')"
print -- "our agents   : $(launchctl list 2>/dev/null | grep -c cctv) loaded (expect 2)"

hdr "power and sleep settings (the fix that was never applied)"
pmset -g 2>/dev/null | grep -iE 'SleepDisabled|hibernatemode|standby|^ *sleep' | sed 's/^/  /'
print -- "  --- autorestart (1 = comes back after a power failure) ---"
{ pmset -g custom 2>/dev/null; pmset -g 2>/dev/null; } | grep -i autorestart | sed 's/^/  /'
print -- "  (both keys are reported only when ENABLED, so nothing here means NOT hardened)"

hdr "sleep / wake history (leading candidate)"
# Real power events only: the raw log is dominated by PreventUserIdleSystemSleep assertion
# bookkeeping, which says nothing about whether the machine actually slept.
pmset -g log 2>/dev/null \
  | grep -E '^[0-9]{4}-[0-9]{2}-[0-9]{2}.*[[:space:]](Sleep|Wake|DarkWake)[[:space:]]' \
  | grep -vE 'Assertions|Prevent|Kernel Assertions' | tail -25 | sed 's/^/  /'

hdr "memory and swap (a hang)"
print -- "  RAM  : $(( $(sysctl -n hw.memsize 2>/dev/null) / 1073741824 )) GB"
print -- "  swap : $(sysctl -n vm.swapusage 2>/dev/null)"
print -- "  load : $(sysctl -n vm.loadavg 2>/dev/null)"
vm_stat 2>/dev/null | head -6 | sed 's/^/  /'

hdr "disk (a full volume hangs a Mac and stops ffmpeg writing)"
df -h / 2>/dev/null | sed 's/^/  /'
print -- "  log/ total: $(du -sh "$BASE/log" 2>/dev/null | awk '{print $1}')"
if [[ -d "$BASE/log" ]]; then
  print -- "  largest in log/:"
  du -ah "$BASE/log" 2>/dev/null | sort -rh | head -8 | sed 's/^/    /'
fi

hdr "panics and crash reports"
for d in /Library/Logs/DiagnosticReports "$HOME/Library/Logs/DiagnosticReports"; do
  n=$(ls -1 "$d"/*.panic 2>/dev/null | wc -l | tr -d ' ')
  print -- "  $d: ${n} panic(s)"
  ls -lt "$d"/*.panic 2>/dev/null | head -3 | sed 's/^/    /'
done

hdr "what the project last did"
for f in stream.log publisher.log monitor.log reader.log; do
  p="$BASE/log/$f"
  [[ -f "$p" ]] || continue
  print -- "  --- $f (last 8 lines, $(stat -f %z "$p" 2>/dev/null) bytes) ---"
  tail -8 "$p" 2>/dev/null | sed 's/^/    /'
done
if [[ -f "$BASE/log/stream.log" ]]; then
  print -- "  --- markers ---"
  print -- "    PUBLISHER died events: $(grep -ac 'PUBLISHER died' "$BASE/log/stream.log" 2>/dev/null)"
  grep -a 'PUBLISHER died\|WATCHDOG:\|HOUSEKEEP: WARNING' "$BASE/log/stream.log" 2>/dev/null | tail -6 | sed 's/^/    /'
  grep -a 'ROTATE' "$BASE/log/stream.log" 2>/dev/null | tail -3 | sed 's/^/    /'
fi

hdr "runtime state"
for f in cam_ip broadcast_started rotating rotate_now vod_status thumb_pending; do
  p="$BASE/log/$f"
  [[ -e "$p" ]] && print -- "  $f: $(head -c 120 "$p" 2>/dev/null | tr '\n' ' ')"
done
print -- "  progress.txt : $(stat -f %z "$BASE/log/progress.txt" 2>/dev/null) bytes"
print -- "  last frame   : $(grep -a '^frame=' "$BASE/log/progress.txt" 2>/dev/null | tail -1)"

hdr "camera and network"
CAMIP=$(cat "$BASE/log/cam_ip" 2>/dev/null)
print -- "  camera ip : ${CAMIP:-unknown}"
if [[ -n "$CAMIP" ]]; then
  if nc -z -G 3 "$CAMIP" 554 2>/dev/null; then print -- "  port 554  : open"; else print -- "  port 554  : unreachable"; fi
fi
TS=$(/Applications/Tailscale.app/Contents/MacOS/Tailscale status 2>/dev/null | head -3)
[[ -z "$TS" ]] && TS=$(tailscale status 2>/dev/null | head -3)
print -- "  tailscale : ${TS:-not available}"

if [[ "$DEEP" == "yes" ]]; then
  hdr "deep: previous shutdown cause (0 = power loss, 5 = clean, -128 = forced power-off)"
  log show --last 2d --style compact --predicate 'eventMessage CONTAINS "Previous shutdown cause"' 2>/dev/null | tail -5 | sed 's/^/  /'
  hdr "deep: sleep/wake detail, last 2 days"
  log show --last 2d --style compact --predicate 'eventMessage CONTAINS[c] "sleep" OR eventMessage CONTAINS[c] "wake"' 2>/dev/null | grep -iE 'sleep|wake' | tail -20 | sed 's/^/  /'
fi

hdr "how to read this"
cat <<'EOF'
  Sleep        - "SleepDisabled 0" plus a sleep entry at the outage minute. A Mac on battery
                 or with the lid shut sleeps regardless of caffeinate; the fix is
                 `sudo bin/harden-host.sh --go`.
  Hang         - load average in the hundreds, swap in the many-GB, or a full volume.
  Panic / off  - a .panic near the outage, or shutdown cause -128 / 0.
  Login window - SHORT uptime and a console user that is not `user`: the agents are user
                 LaunchAgents, so nothing starts until someone logs in.
  Nothing here is a result too: it means the host was healthy until the moment it went silent,
  which is what the outside view already showed.
EOF
} > "$OUT" 2>&1

cat "$OUT"

if [[ "$SAVE" == "yes" ]]; then
  mkdir -p "$BASE/log"
  if cp "$OUT" "$BASE/log/forensics-$STAMP.txt" 2>/dev/null; then
    print -- ""
    print -- "saved: $BASE/log/forensics-$STAMP.txt"
  fi
fi
rm -f "$OUT"
