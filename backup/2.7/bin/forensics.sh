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
# ${MEM:-0} is not cosmetic: zsh treats an empty arithmetic operand as a FATAL parse error in a
# non-interactive shell, so a host without sysctl (or with it off PATH) would abort the report
# here instead of continuing to the evidence.
MEM=$(sysctl -n hw.memsize 2>/dev/null)
print -- "  RAM  : $(( ${MEM:-0} / 1073741824 )) GB"
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
# (N) is required: with no .panic files - the normal healthy case - a bare *.panic glob makes
# zsh print "no matches found" BEFORE any 2>/dev/null can take effect, injecting shell noise
# into the evidence. The array form also matters: `ls ... *.panic(N)` with no match would hand
# `ls` zero arguments, and `ls` with zero arguments lists the CURRENT directory instead.
for d in /Library/Logs/DiagnosticReports "$HOME/Library/Logs/DiagnosticReports"; do
  panics=("$d"/*.panic(N))
  print -- "  $d: ${#panics} panic(s)"
  if (( ${#panics} > 0 )); then
    ls -lt "${panics[@]}" 2>/dev/null | head -3 | sed 's/^/    /'
  fi
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

hdr "network (the 2026-09-18 blind spot)"
# On 2026-09-18 the streamer lost its ENTIRE network for ~19.5 h while the host stayed awake, and
# this script had nothing to say about it: no sleep, no panic, no reboot. Every command below is
# unprivileged and READ-ONLY, and none of it may hang the report - a wedged daemon is one of the
# things we are here to catch. macOS has no `timeout`, so the calls that can block get a hard
# ceiling by running in the background and killing the straggler. The watcher's stdout/stderr
# MUST be redirected: without it its `sleep` inherits the caller's command-substitution pipe and
# the whole report stalls for the full timeout, which is exactly what a kill is meant to avoid.
net_tmo() {   # net_tmo SECONDS cmd...
  local secs="$1"; shift
  "$@" &
  local p=$!
  ( sleep "$secs"; kill -TERM "$p" 2>/dev/null ) </dev/null >/dev/null 2>&1 &
  local k=$!
  wait "$p" 2>/dev/null
  kill -TERM "$k" 2>/dev/null
  wait "$k" 2>/dev/null
  return 0
}

print -- "  --- interfaces (en*) ---"
for i in ${(f)"$(ifconfig -l 2>/dev/null | tr ' ' '\n')"}; do
  [[ "$i" == en* ]] || continue
  nic=$(ifconfig "$i" 2>/dev/null)
  stat=$(print -r -- "$nic" | grep -m1 'status:' | sed 's/.*status: *//')
  med=$(print -r -- "$nic" | grep -m1 'media:' | sed 's/.*media: *//')
  addrs=$(print -r -- "$nic" | awk '/inet /{print $2}' | tr '\n' ' ')
  print -- "  $i: status=${stat:-unknown}  media=${med:-unknown}"
  print -- "      inet  : ${addrs:-none}"
  # The trap that matters here: the port reports `active` (carrier up) but holds only a
  # 169.254.x.x link-local, so interface, route and DNS all look present and none of them work.
  if [[ "$stat" == active ]]; then
    if [[ -z "${addrs// /}" ]]; then
      print -- "      TRAP  : LINKED BUT UNUSABLE - active with no address (DHCP never answered)"
    elif [[ "$addrs" == *169.254.* ]]; then
      print -- "      TRAP  : LINKED BUT UNUSABLE - active with only a 169.254.x.x link-local"
    fi
  fi
done

print -- "  --- network service order (the first enabled service wins) ---"
# networksetup and scutil both talk to configd, which is one of the things that can wedge and
# take the network with it, so they get the same ceiling as the rest of this section.
net_tmo 5 networksetup -listnetworkserviceorder 2>/dev/null | sed 's/^/    /'
dis=$(net_tmo 5 networksetup -listallnetworkservices 2>/dev/null | tail -n +2 | grep '^\*' | sed 's/^\*//' | tr '\n' ' ')
print -- "  disabled services: ${dis:-none}"

print -- "  --- default route ---"
defroute=$(net_tmo 3 route -n get default 2>/dev/null)
print -r -- "$defroute" | sed 's/^/    /'
GW=$(print -r -- "$defroute" | awk '/gateway:/{print $2}')
print -- "  --- inet routing table ---"
netstat -rn -f inet 2>/dev/null | sed 's/^/    /'

print -- "  --- effective resolvers (scutil --dns; a supplemental resolver has its own flags/if_index) ---"
net_tmo 5 scutil --dns 2>/dev/null | grep -E 'resolver #[0-9]+|nameserver|flags|if_index|reach|search domain' | sed 's/^/    /'
print -- "  --- per-service configured DNS (a service with none inherits the router) ---"
net_tmo 5 networksetup -listallnetworkservices 2>/dev/null | tail -n +2 | sed 's/^\*//' | while IFS= read -r s; do
  [[ -n "$s" ]] || continue
  print -- "    $s: $(net_tmo 5 networksetup -getdnsservers "$s" 2>/dev/null | tr '\n' ' ')"
done
if [[ -d /etc/resolver ]]; then
  print -- "  --- /etc/resolver (per-domain resolvers; split DNS lives here) ---"
  for f in /etc/resolver/*(N); do
    print -- "    --- ${f:t} ---"
    sed 's/^/      /' "$f" 2>/dev/null
  done
fi

print -- "  --- Wi-Fi (system_profiler SPAirPortDataType; the SSID is withheld if Location is off) ---"
wifi=$(net_tmo 12 system_profiler SPAirPortDataType 2>/dev/null)
ssid=$(print -r -- "$wifi" | awk '/Current Network Information:/{f=1;next} f&&/^[[:space:]]+[^:]+:$/{gsub(/^[[:space:]]+|:$/,"");print;exit}')
print -- "  SSID  : ${ssid:-unknown}"
# Signal/noise is the single most useful RF fact on an AirPort; PHY mode and channel follow it.
print -r -- "$wifi" | grep -E 'PHY Mode|Channel:|Signal / Noise|Transmit Rate|Security:' | head -8 | sed 's/^[[:space:]]*/    /'

print -- "  --- DHCP (ipconfig getpacket; no packet = no lease) ---"
for i in ${(f)"$(ifconfig -l 2>/dev/null | tr ' ' '\n')"}; do
  [[ "$i" == en* ]] || continue
  pkt=$(net_tmo 5 ipconfig getpacket "$i" 2>/dev/null)
  if [[ -z "$pkt" ]]; then
    print -- "    $i: no DHCP packet (no lease, or the interface is not DHCP)"
  else
    print -- "    $i:"
    print -r -- "$pkt" | grep -E 'yiaddr|server_identifier|lease_time|router|subnet_mask|domain_name_server' | sed 's/^[[:space:]]*/      /'
  fi
done

CAMIP=$(cat "$BASE/log/cam_ip" 2>/dev/null)
print -- "  --- ARP table (which interface resolved the gateway ${GW:-?} and the camera ${CAMIP:-?}) ---"
ARPT=$(arp -an 2>/dev/null)
if [[ -z "$ARPT" ]]; then
  print -- "    (empty: nothing on this LAN has been resolved into the ARP cache)"
else
  print -r -- "$ARPT" | sed 's/^/    /'
  for ip in "$GW" "$CAMIP"; do
    [[ -n "$ip" ]] || continue
    hits=$(print -r -- "$ARPT" | grep -F "($ip)" | sed 's/.* on /on /' | tr '\n' ' ')
    print -- "  $ip resolved on: ${hits:-NOT IN THE TABLE}"
  done
fi

print -- "  --- Tailscale (usually NOT on PATH on macOS: the CLI lives inside Tailscale.app) ---"
TSCLI=""
# PATH first, so a test stub (and a Homebrew install) wins over the app bundle.
for c in tailscale /Applications/Tailscale.app/Contents/MacOS/Tailscale; do
  p=$(command -v "$c" 2>/dev/null) && { TSCLI="$p"; break; }
done
if [[ -n "$TSCLI" ]]; then
  print -- "  cli   : $TSCLI"
  net_tmo 6 "$TSCLI" status 2>/dev/null | head -5 | sed 's/^/    /'
else
  print -- "  cli   : not found on PATH or at /Applications/Tailscale.app/Contents/MacOS/Tailscale"
fi

hdr "camera reachability"
CAMIP=$(cat "$BASE/log/cam_ip" 2>/dev/null)
print -- "  camera ip : ${CAMIP:-unknown}"
if [[ -n "$CAMIP" ]]; then
  if nc -z -G 3 "$CAMIP" 554 2>/dev/null; then print -- "  port 554  : open"; else print -- "  port 554  : unreachable"; fi
fi

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
  No network   - `status: active` with only a 169.254.x.x inet (or none) is "linked but
                 unusable": the port has carrier but DHCP never answered, so the Mac is up with
                 no route. If `arp -an` never resolved the router on ANY interface, that cable
                 or switch port is not on the router's LAN.
  DNS          - an empty nameserver list, or only a supplemental resolver whose `if_index` is a
                 utun, means resolution depends entirely on the router: a router reboot takes the
                 streamer's DNS with it.
  DHCP         - no `ipconfig getpacket` output = no lease; a `yiaddr` in 169.254.x.x means the
                 router answered with a link-local (the DHCP pool is broken).
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
