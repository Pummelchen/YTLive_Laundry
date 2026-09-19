#!/bin/zsh
# Network-layer watchdog for the streamer.
#
# WHY THIS EXISTS - the hole it fills.
# On 2026-09-18 the MacBook stayed AWAKE and kept writing its logs while it lost its whole
# network: not just the internet, but DNS and its own LAN (the camera at 192.168.1.3 stopped
# answering on 554 and WS-Discovery found nothing). It was dark for 19h26m. The host had not
# rebooted - boot time was still 2026-08-31 - and the pmset log for the whole window contains
# no Sleep and no AC/battery transition, so this was a transport-layer failure, not a power or
# sleep event.
# Every retry loop in stream.sh retried the APPLICATION layer - ffmpeg, ONVIF discovery, the
# OAuth probe - and not one of them ever touched the network interface. The design rule is
# "every failure path retries"; at the bottom of the stack nothing did. That is the gap.
#
# WHAT IT DOES. One cheap probe pass every NET_CHECK_EVERY seconds, classifying the transport
# into exactly one of OK / NOLINK / NOGW / NOWAN / NODNS, and then - only after the failure is
# SUSTAINED (NET_FAIL_SAMPLES consecutive failures, so a router reboot is not mistaken for an
# outage) and only within strict rate limits - climbing a ladder of recovery actions, cheapest
# and least disruptive first. State changes and actions go to log/net_events.log, which records
# TRANSITIONS rather than every probe, so a 20-hour outage leaves a readable timeline there even
# though stream.log's in-place trim erases the first hours of the storm (measured at ~700
# lines/hour, which is why the first ~15h of that outage are simply gone).
#
# WHAT IT DELIBERATELY DOES NOT DO.
#  - It never power-cycles the USB-Ethernet service. Toggling that service was tried on
#    2026-09-19 and the WCH adapter (1a86:5394) dropped carrier and did not come back; the
#    USB NIC is only ever asked to re-assert DHCP. Wi-Fi is toggled, because that is safe and
#    reversible.
#  - It never edits the network service ORDER. A secondary interface with no router gets no
#    default route, so macOS already prefers the working one; and reordering the service list
#    is a single mistyped call away from breaking the only working path. LAN stays first, so it
#    becomes primary by itself the moment it holds a real lease - which is the intent.
#  - It never notifies. The streamer must not depend on a human noticing; the OFF-host watchdog
#    is the only component allowed to do that (bin/yt_watchdog.py). This script's job is to
#    repair, and to leave evidence.
#
# Usage:  bin/net_watch.sh loop    run the watchdog (stream.sh starts this)
#         bin/net_watch.sh once    probe once, print the state, exit 0 when OK
#         bin/net_watch.sh status  human-readable one-screen summary
set -u
BASE="${BASE:-${0:A:h:h}}"   # the checkout this script lives in (a launchd install is ~/Downloads/YTLive)
CONF="${CONF:-$BASE/conf/stream.env}"
STATE_FILE="$BASE/log/net_state"
EVENTS="$BASE/log/net_events.log"
HOLD="$BASE/log/net_hold"        # optional epoch deadline: while now < body, take no action

[[ -r "$CONF" ]] && source "$CONF"

# ---------------------------------------------------------------------------
# Knobs. Every one has a default so this script runs on a config that predates it.
# ---------------------------------------------------------------------------
: ${NET_CHECK_EVERY:=30}          # seconds between probe passes
: ${NET_FAIL_SAMPLES:=3}          # consecutive failures before ANY action (~90s at the default)
: ${NET_MIN_ACTION_INTERVAL:=300} # floor between two actions, so a flapping link cannot thrash
: ${NET_MAX_ACTIONS_PER_HOUR:=12} # hard ceiling per rolling hour
: ${NET_PROBE_DNS:=www.youtube.com}   # a name that must resolve
: ${NET_PROBE_IP:=8.8.8.8}            # an address that must be reachable WITHOUT DNS
: ${NET_PROBE_PORT:=53}
: ${NET_LAN_SERVICE:=USB 10/100 LAN}  # the intended primary: wired
: ${NET_WIFI_SERVICE:=Wi-Fi}          # the backup
: ${NET_WIFI_DEVICE:=en0}
: ${NET_WIFI_SSID:=}                  # optional; re-association uses the keychain, no password here
: ${NET_WIFI_CYCLE_WAIT:=5}           # seconds the radio stays down during a power-cycle
: ${NET_DNS_SERVERS:=8.8.8.8 8.8.4.4 1.1.1.1 1.0.0.1}
: ${NET_ALLOW_REBOOT:=no}             # last resort, OFF by default - see do_action
: ${NET_REBOOT_AFTER_ACTIONS:=6}
: ${NET_LOG_MAX_BYTES:=1048576}

mkdir -p "$BASE/log" 2>/dev/null

nlog() { print -r -- "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$EVENTS"; }

# Keep the event log bounded WITHOUT renaming it: the redirect that appends shell stderr to the
# same file holds an fd, and a rename would leave it writing to an unlinked inode forever. Same
# idiom as stream.sh's trim_log, and for the same reason.
trim_events() {
  local sz tmp
  [[ -f "$EVENTS" ]] || return 0
  sz=$(/usr/bin/stat -f %z "$EVENTS" 2>/dev/null) || return 0
  (( sz > NET_LOG_MAX_BYTES )) || return 0
  tmp="${TMPDIR:-/tmp}/ytlive-nettim.$$"
  if tail -c $(( NET_LOG_MAX_BYTES / 2 )) "$EVENTS" > "$tmp" 2>/dev/null; then
    cat "$tmp" > "$EVENTS"
  fi
  rm -f "$tmp"
}

# ---------------------------------------------------------------------------
# Probing. All read-only, all without sudo. Deliberately split so each layer of the
# stack is judged separately: knowing that DNS failed but the WAN answered is the
# difference between "flush the resolver" and "the link is gone".
# ---------------------------------------------------------------------------
iface_addr() { ifconfig "$1" 2>/dev/null | awk '/inet /{print $2; exit}'; }
iface_link() { ifconfig "$1" 2>/dev/null | grep -q 'status: active'; }

# A usable address is one that can actually route: a self-assigned 169.254.x.x means the
# interface linked but never got a lease, which is exactly the state this Mac's wired port was
# found in (en2 = 169.254.114.185, link up at 100baseTX, router unreachable).
iface_usable() {
  local ip
  ip=$(iface_addr "$1")
  [[ -n "$ip" && "$ip" != 169.254.* ]]
}

default_gateway() { route -n get default 2>/dev/null | awk '/gateway:/{print $2; exit}'; }
default_iface()   { route -n get default 2>/dev/null | awk '/interface:/{print $2; exit}'; }

# Map "en2" -> "USB 10/100 LAN" so an action can name the service rather than the device.
service_for_iface() {
  networksetup -listallhardwareports 2>/dev/null | awk -v dev="$1" '
    /^Hardware Port:/ { svc = substr($0, index($0, ":") + 2) }
    /^Device:/        { if ($2 == dev) { print svc; exit } }'
}

# The device behind a named service, e.g. "USB 10/100 LAN" -> en2.
iface_for_service() {
  networksetup -listallhardwareports 2>/dev/null | awk -v svc="$1" '
    /^Hardware Port:/ { h = substr($0, index($0, ":") + 2) }
    /^Device:/        { if (h == svc) { print $2; exit } }'
}

net_probe() {   # prints OK | NOLINK | NOGW | NOWAN | NODNS
  local gw ifc
  gw=$(default_gateway); ifc=$(default_iface)
  [[ -n "$gw" && -n "$ifc" ]] || { print NOGW; return }
  iface_usable "$ifc" || { print NOLINK; return }
  ping -c 1 -t 2 "$gw" >/dev/null 2>&1 || { print NOGW; return }
  # An address, not a name: this must not be able to fail merely because DNS is down.
  nc -z -G 3 "$NET_PROBE_IP" "$NET_PROBE_PORT" >/dev/null 2>&1 || { print NOWAN; return }
  # `dig` is taken from PATH rather than hardcoded, so the test suite can drive this whole
  # classifier with stubs and never touch a real network. Same reason nc/ifconfig/route are
  # bare names here; stream.sh already resolves nc the same way.
  if command -v dig >/dev/null 2>&1; then
    [[ -n "$(dig +short +time=2 +tries=1 "$NET_PROBE_DNS" 2>/dev/null)" ]] || { print NODNS; return }
  else
    nc -z -G 3 "$NET_PROBE_DNS" 443 >/dev/null 2>&1 || { print NODNS; return }
  fi
  print OK
}

# ---------------------------------------------------------------------------
# The decision, as a PURE FUNCTION - no clock, no I/O, no commands.
# The watchdog in bin/yt_watchdog.py is built the same way and for the same reason: a
# six-hour rule must be testable in microseconds, and an action taken "because the
# environment said so" is untestable by construction.
#
#   net_action STATE FAILS SINCE_LAST ACTIONS_IN_OUTAGE [ACTIONS_PER_HOUR]
#
# Returns: none | dns | renew | wifi | reboot
# ---------------------------------------------------------------------------
net_action() {
  local state="$1" fails="$2" since="$3" inoutage="$4" perhour="${5:-0}"
  [[ "$state" == OK ]] && { print none; return }
  # Nothing happens on a blip. A router reboot is ~60s; the floor is 3 samples (~90s).
  (( fails < NET_FAIL_SAMPLES )) && { print none; return }
  (( perhour >= NET_MAX_ACTIONS_PER_HOUR )) && { print none; return }
  (( since < NET_MIN_ACTION_INTERVAL )) && { print none; return }
  # Climb: cheapest and least disruptive first, and only escalate if the cheaper rung did
  # not hold. The count is per outage, so it resets the moment the network is healthy again.
  case "$inoutage" in
    0) print dns ;;
    1) print renew ;;
    2) print wifi ;;
    *)
      if [[ "$NET_ALLOW_REBOOT" == "yes" ]] && (( inoutage >= NET_REBOOT_AFTER_ACTIONS )); then
        print reboot
      else
        print wifi
      fi ;;
  esac
}

# ---------------------------------------------------------------------------
# Actions. Each is idempotent. The network-service writes need no root: `user` is an admin, so
# networksetup is permitted. The two ROOT-only rungs (a targeted `ipconfig` lease renew and a
# resolver-cache flush) go through `sudo -n` and exist only when bin/harden-host.sh has installed
# the narrow NOPASSWD rule - four exact commands, no wildcards, no shell (T-38). sudo -n never
# prompts, so a launchd agent without the rule fails fast and logs the weaker path it took
# instead of hanging on a password it can never type.
# ---------------------------------------------------------------------------
dns_servers_of() { networksetup -getdnsservers "$1" 2>/dev/null | grep -v '^There aren' ; }

# The associated SSID. `networksetup -getairportnetwork <device>` answers correctly on the
# streamer (macOS 12) but reports "not associated" on macOS 27 even while en0 holds a lease, so
# fall back to system_profiler rather than print a falsehood into a diagnostic.
current_ssid() {
  local dev="$1" out
  out=$(networksetup -getairportnetwork "$dev" 2>/dev/null)
  if [[ "$out" == *"Current Wi-Fi Network:"* ]]; then
    print -r -- "${out##*Current Wi-Fi Network: }"
    return
  fi
  system_profiler SPAirPortDataType 2>/dev/null | awk '
    /Current Network Information:/ { getline; gsub(/^[ \t]+/, ""); sub(/:$/, ""); print; exit }'
}

ensure_dns() {   # re-assert the resolver list on every service that can actually carry traffic,
  local svc out        # so resolution cannot depend on which service macOS considers primary
  out=""
  while IFS= read -r svc; do
    [[ -n "$svc" ]] || continue
    # A service with no device is not a network path. The Tailscale service
    # ("io.tailscale.ipn.macsys") is exactly that, and it manages DNS itself - writing resolvers
    # onto it would fight the daemon rather than help. Skipping device-less services is the
    # general rule, so this does not depend on knowing Tailscale's name.
    [[ -n "$(iface_for_service "$svc")" ]] || continue
    if [[ -z "$(dns_servers_of "$svc")" ]]; then
      networksetup -setdnsservers "$svc" ${=NET_DNS_SERVERS} >/dev/null 2>&1 \
        && out="${out}${svc}:set "
    fi
  done < <(all_services)
  print -r -- "$out"
}

all_services() {   # enabled services only; a disabled one is prefixed with "*"
  networksetup -listallnetworkservices 2>/dev/null | tail -n +2 | sed 's/^\*//' | grep -v '^$'
}

do_action() {
  local what="$1" svc
  case "$what" in
    dns)
      # Root-only, and possible at all only because bin/harden-host.sh installs a NOPASSWD rule
      # for exactly this command (T-38). `sudo -n` never prompts, because a launchd agent has no
      # terminal and a prompt would hang the loop instead of failing.
      if sudo -n /usr/bin/dscacheutil -flushcache >/dev/null 2>&1; then
        nlog "NET-ACT dns: resolver cache flushed (via the NOPASSWD rule)"
      elif dscacheutil -flushcache >/dev/null 2>&1; then
        nlog "NET-ACT dns: resolver cache flushed (no root needed)"
      else
        nlog "NET-ACT dns: cache flush refused - install the rule: sudo bin/harden-host.sh --go"
      fi
      local set; set=$(ensure_dns)
      nlog "NET-ACT dns: re-asserted resolvers on [${set:-none}]"
      ;;
    renew)
      svc=$(service_for_iface "$(default_iface)")
      [[ -z "$svc" ]] && svc="$NET_WIFI_SERVICE"
      # Re-assert DHCP rather than power-cycling the service: power-cycling the USB NIC is
      # how the wired link was lost on 2026-09-19, and a watchdog must not be able to make
      # the machine worse than it found it.
      #
      # The targeted renew needs root (`ipconfig`), which the NOPASSWD rule from T-38 grants for
      # the two interfaces this machine has. Fall back to the no-sudo networksetup form when the
      # rule is not installed, and say which path was taken - "we tried the weaker thing" is
      # evidence, not noise.
      local ifc; ifc=$(default_iface)
      if [[ -n "$ifc" ]] && sudo -n /usr/sbin/ipconfig set "$ifc" DHCP >/dev/null 2>&1; then
        nlog "NET-ACT renew: ipconfig renewed the lease on $ifc (via the NOPASSWD rule)"
      elif networksetup -setdhcp "$svc" >/dev/null 2>&1; then
        nlog "NET-ACT renew: re-asserted DHCP on '$svc' (networksetup; no root rule)"
      else
        nlog "NET-ACT renew: could not re-assert DHCP on '$svc'"
      fi
      ;;
    wifi)
      nlog "NET-ACT wifi: power-cycling $NET_WIFI_DEVICE"
      networksetup -setairportpower "$NET_WIFI_DEVICE" off >/dev/null 2>&1
      sleep "$NET_WIFI_CYCLE_WAIT"
      networksetup -setairportpower "$NET_WIFI_DEVICE" on >/dev/null 2>&1
      if [[ -n "$NET_WIFI_SSID" ]]; then
        # No password on the command line: networksetup takes it from the login keychain.
        # (The 2.4GHz SSID on this router has a TRAILING SPACE in its name - quote it exactly.)
        networksetup -setairportnetwork "$NET_WIFI_DEVICE" "$NET_WIFI_SSID" >/dev/null 2>&1 \
          && nlog "NET-ACT wifi: re-associated $NET_WIFI_DEVICE with '$NET_WIFI_SSID'" \
          || nlog "NET-ACT wifi: could not re-associate '$NET_WIFI_SSID' (keychain entry?)"
      fi
      ;;
    reboot)
      # OFF BY DEFAULT, and it must be proven before it is enabled. A reboot only fixes a
      # wedged Mac-side driver; it cannot fix a router that is off, and if auto-login were
      # ever disabled the machine would come back to a login window and stay dark forever -
      # which is one of the ways this project can die permanently. On the streamer auto-login
      # IS configured (autoLoginUser=user, FileVault off), which is what makes it safe there.
      nlog "NET-ACT reboot: escalating to a reboot (NET_ALLOW_REBOOT=yes)"
      osascript -e 'tell application "System Events" to restart' >/dev/null 2>&1 \
        || nlog "NET-ACT reboot: refused (no GUI session or automation permission)"
      ;;
    *) : ;;
  esac
}

write_state() {  # <state> <iface> <service> <gateway>  - read by bin/status.sh
  print -r -- "$1 $(date +%s) $2 ${3:-} ${4:-}" > "$STATE_FILE" 2>/dev/null
}

held() {         # an operator (or a rotation) can hold actions off with an epoch deadline
  local until
  [[ -f "$HOLD" ]] || return 1
  until=$(<"$HOLD")
  [[ "$until" == <-> ]] || return 1
  (( $(date +%s) < until ))
}

# ---------------------------------------------------------------------------
cmd_once() {
  local st
  st=$(net_probe)
  print -r -- "$st"
  [[ "$st" == OK ]]
}

cmd_status() {
  local st gw ifc svc lan_if lan_ip wifi_if
  st=$(net_probe); gw=$(default_gateway); ifc=$(default_iface)
  svc=$(service_for_iface "$ifc")
  lan_if=$(iface_for_service "$NET_LAN_SERVICE")
  wifi_if=$(iface_for_service "$NET_WIFI_SERVICE")
  print "network state : $st"
  print "default route : ${gw:-none} via ${ifc:-none}${svc:+ ($svc)}"
  print "dns servers   : $(dns_servers_of "$NET_WIFI_SERVICE" | tr '\n' ' ')"
  if [[ -n "$lan_if" ]]; then
    lan_ip=$(iface_addr "$lan_if")
    print "wired (LAN)   : $lan_if ${lan_ip:-no address}$(iface_link "$lan_if" && print ' link-up' || print ' NO-LINK')"
  fi
  [[ -n "$wifi_if" ]] && print "wifi (backup) : $wifi_if $(iface_addr "$wifi_if") '$(current_ssid "$wifi_if")'"
  # The intent, stated explicitly, so a status page can say whether reality matches it:
  # WIRED is meant to be the primary path and Wi-Fi the backup. The second line is the
  # machine-readable form - device names only, because service names contain spaces
  # ("USB 10/100 LAN") and would break token parsing.
  print "intent        : primary=$NET_LAN_SERVICE (${lan_if:-none}) backup=$NET_WIFI_SERVICE (${wifi_if:-none}) carrying=${ifc:-none}${svc:+ ($svc)}"
  print "intent_iface  : primary=${lan_if:-none} backup=${wifi_if:-none} carrying=${ifc:-none}"
}

cmd_loop() {
  local st last_state="" fails=0 inoutage=0 last_action=0 hour_start now what
  hour_start=$(date +%s); local perhour=0
  nlog "NET: watchdog starting (every ${NET_CHECK_EVERY}s, action after ${NET_FAIL_SAMPLES} failed samples)"
  while true; do
    now=$(date +%s)
    st=$(net_probe)
    (( now - hour_start >= 3600 )) && { hour_start=$now; perhour=0 }

    if [[ "$st" == OK ]]; then
      if [[ -n "$last_state" && "$last_state" != OK ]]; then
        nlog "NET: RECOVERED -> OK (was $last_state after $fails failed probes and $inoutage actions)"
        inoutage=0
      fi
      fails=0
    else
      fails=$(( fails + 1 ))
      if [[ "$st" != "$last_state" ]]; then
        nlog "NET: state $last_state -> $st (gateway $(default_gateway) via $(default_iface); wired $(iface_for_service "$NET_LAN_SERVICE")=$(iface_addr "$(iface_for_service "$NET_LAN_SERVICE")"))"
      fi
    fi

    write_state "$st" "$(default_iface)" "$(service_for_iface "$(default_iface)")" "$(default_gateway)"

    what=$(net_action "$st" "$fails" "$(( now - last_action ))" "$inoutage" "$perhour")
    if [[ "$what" != none ]]; then
      if held; then
        nlog "NET: would run '$what' but $HOLD holds actions off until $(<"$HOLD")"
      else
        nlog "NET: taking action '$what' for state $st ($fails failed probes, action #$(( inoutage + 1 )) this outage)"
        do_action "$what"
        last_action=$(date +%s); inoutage=$(( inoutage + 1 )); perhour=$(( perhour + 1 ))
      fi
    fi
    last_state="$st"
    trim_events
    sleep "$NET_CHECK_EVERY"
  done
}

case "${1:-loop}" in
  once)   cmd_once ;;
  status) cmd_status ;;
  loop)   cmd_loop ;;
  *)      print -r -- "usage: $0 {loop|once|status}"; exit 2 ;;
esac
