#!/bin/zsh
# t09 - the transport-layer watchdog (bin/net_watch.sh).
#
# WHY THIS FILE EXISTS. The 2026-09-18 outage was 19h26m of darkness on a host that was AWAKE:
# it had lost its LAN, its DNS and its internet, and every retry loop in stream.sh retried the
# application layer without ever touching the interface. bin/net_watch.sh fills that hole, so
# what it decides, when it decides it, and - just as important - what it must never do, are all
# asserted here.
#
# The classifier is driven through stubs, so this file needs no network, no credentials and
# cannot touch this machine's real interfaces. The stubs live in the scratch tree rather than in
# tests/stubs on purpose: a global `ping` or `networksetup` stub would change the behaviour of
# every other test file.
source "${0:A:h}/lib.sh"
t_begin t09
t_setup >/dev/null

NW="$REPO_DIR/bin/net_watch.sh"
FAKE="$T_BASE/fakebin"
mkdir -p "$FAKE" "$T_BASE/log"
NSLOG="$T_BASE/ns.log"
OSALOG="$T_BASE/osa.log"
: > "$NSLOG"; : > "$OSALOG"

# --- stub commands -----------------------------------------------------------
# networksetup records one ARGUMENT PER LINE, so a test can assert on an exact argument -
# including the trailing space in this router's 2.4GHz SSID name, which must be quoted exactly.
cat > "$FAKE/ifconfig" <<'STUB'
#!/bin/zsh
print -r -- "${FAKE_IFCONFIG}"
STUB
cat > "$FAKE/route" <<'STUB'
#!/bin/zsh
print -r -- "${FAKE_ROUTE}"
STUB
cat > "$FAKE/ping" <<'STUB'
#!/bin/zsh
exit ${FAKE_PING_RC:-0}
STUB
cat > "$FAKE/nc" <<'STUB'
#!/bin/zsh
exit ${FAKE_NC_RC:-0}
STUB
cat > "$FAKE/dig" <<'STUB'
#!/bin/zsh
print -r -- "${FAKE_DIG_OUT}"
STUB
cat > "$FAKE/dscacheutil" <<'STUB'
#!/bin/zsh
exit ${FAKE_DSCACHE_RC:-0}
STUB
cat > "$FAKE/osascript" <<'STUB'
#!/bin/zsh
print -r -- "$*" >> "${FAKE_OSA_LOG:-/dev/null}"
exit 0
STUB
cat > "$FAKE/networksetup" <<'STUB'
#!/bin/zsh
for a in "$@"; do print -r -- "$a" >> "${FAKE_NS_LOG:-/dev/null}"; done
case "$1" in
  -listallnetworkservices) print -r -- "${FAKE_NS_SERVICES}" ;;
  -getdnsservers)          print -r -- "${FAKE_NS_DNS}" ;;
  *)                       print -r -- "${FAKE_NS_OUT}" ;;
esac
STUB
chmod +x "$FAKE"/*

# --- the real functions, extracted from the real script ----------------------
FUNCS="$T_BASE/nw_funcs.zsh"
: > "$FUNCS"
for fn in iface_addr iface_link iface_usable default_gateway default_iface service_for_iface \
          iface_for_service net_probe net_action held do_action nlog trim_events ensure_dns \
          dns_servers_of all_services current_ssid; do
  t_extract_fn "$NW" "$fn" >> "$FUNCS"
done
# The harness sets its own values rather than inheriting the script's defaults, so a test can
# never pass merely because a default changed. The defaults themselves are asserted separately
# below. The paths are the scratch tree's.
cat >> "$FUNCS" <<EOF
BASE="$T_BASE"
STATE_FILE="$T_BASE/log/net_state"
EVENTS="$T_BASE/log/net_events.log"
HOLD="$T_BASE/log/net_hold"
: \${NET_CHECK_EVERY:=30}
: \${NET_FAIL_SAMPLES:=3}
: \${NET_MIN_ACTION_INTERVAL:=300}
: \${NET_MAX_ACTIONS_PER_HOUR:=12}
: \${NET_PROBE_DNS:=www.youtube.com}
: \${NET_PROBE_IP:=8.8.8.8}
: \${NET_PROBE_PORT:=53}
: \${NET_LAN_SERVICE:=USB 10/100 LAN}
: \${NET_WIFI_SERVICE:=Wi-Fi}
: \${NET_WIFI_DEVICE:=en0}
: \${NET_WIFI_SSID:=}
: \${NET_DNS_SERVERS:=8.8.8.8 8.8.4.4 1.1.1.1 1.0.0.1}
: \${NET_ALLOW_REBOOT:=no}
: \${NET_REBOOT_AFTER_ACTIONS:=6}
: \${NET_WIFI_CYCLE_WAIT:=0}
: \${NET_LOG_MAX_BYTES:=1024}
EOF

run_nw() {  # run_nw 'zsh code' [VAR=VAL ...]  -> stdout of the code, with stubs first on PATH
  local code="$1"; shift
  env BASE="$T_BASE" HOME="$T_BASE/home" PATH="$FAKE:$STUBS:$PATH" \
      FAKE_NS_LOG="$NSLOG" FAKE_OSA_LOG="$OSALOG" "$@" \
      /bin/zsh -c "source '$FUNCS'; $code"
}

IF_OK=$'\tinet 192.168.1.18 netmask 0xffffff00 broadcast 192.168.1.255\n\tstatus: active'
IF_LL=$'\tinet 169.254.114.185 netmask 0xffff0000 broadcast 169.254.255.255\n\tstatus: active'
R_OK=$'   route to: default\ngateway: 192.168.1.1\ninterface: en0'
NS_PORTS=$'Hardware Port: USB 10/100 LAN\nDevice: en2\n\nHardware Port: Wi-Fi\nDevice: en0\n\nHardware Port: io.tailscale.ipn.macsys\nDevice: \n'
NS_SERVICES=$'An asterisk (*) denotes that a network service is disabled.\nUSB 10/100 LAN\nWi-Fi\nTailscale'

# --- A. classification of the transport -------------------------------------
t_assert_eq "NOGW" "$(run_nw 'net_probe' FAKE_ROUTE='')" \
  "no default route at all -> NOGW"
t_assert_eq "NOLINK" "$(run_nw 'net_probe' FAKE_ROUTE="$R_OK" FAKE_IFCONFIG="$IF_LL")" \
  "link up but only a 169.254 self-assigned address -> NOLINK (the wired-port trap)"
t_assert_eq "NOGW" "$(run_nw 'net_probe' FAKE_ROUTE="$R_OK" FAKE_IFCONFIG="$IF_OK" FAKE_PING_RC=1)" \
  "gateway does not answer -> NOGW"
t_assert_eq "NOWAN" "$(run_nw 'net_probe' FAKE_ROUTE="$R_OK" FAKE_IFCONFIG="$IF_OK" FAKE_PING_RC=0 FAKE_NC_RC=1)" \
  "gateway fine but a public address is unreachable -> NOWAN"
t_assert_eq "NODNS" "$(run_nw 'net_probe' FAKE_ROUTE="$R_OK" FAKE_IFCONFIG="$IF_OK" FAKE_DIG_OUT='')" \
  "WAN up but resolution fails -> NODNS (the exact 2026-09-18 symptom)"
t_assert_eq "OK" "$(run_nw 'net_probe' FAKE_ROUTE="$R_OK" FAKE_IFCONFIG="$IF_OK" FAKE_DIG_OUT='142.251.10.93')" \
  "gateway, WAN and DNS all answer -> OK"

t_assert_eq "yes" "$(run_nw 'iface_usable en0 && print yes || print no' FAKE_IFCONFIG="$IF_OK")" \
  "a routable address counts as usable"
t_assert_eq "no" "$(run_nw 'iface_usable en0 && print yes || print no' FAKE_IFCONFIG="$IF_LL")" \
  "a self-assigned 169.254 address does not"
t_assert_eq "no" "$(run_nw 'iface_usable en0 && print yes || print no' FAKE_IFCONFIG='')" \
  "no address at all does not"

t_assert_eq "USB 10/100 LAN" "$(run_nw 'service_for_iface en2' FAKE_NS_OUT="$NS_PORTS")" \
  "device -> service mapping (needed to name the right service in an action)"
t_assert_eq "en0" "$(run_nw 'iface_for_service Wi-Fi' FAKE_NS_OUT="$NS_PORTS")" \
  "service -> device mapping"

# --- B. the action ladder, as a pure function -------------------------------
t_assert_eq "none" "$(run_nw 'net_action OK 99 9999 9 0')" \
  "a healthy network is never touched, however many failures preceded it"
t_assert_eq "none" "$(run_nw 'net_action NOWAN 2 9999 0 0')" \
  "below the sustained-failure floor: no action (a router reboot must not trigger one)"
t_assert_eq "none" "$(run_nw 'net_action NOWAN 3 299 0 0')" \
  "inside NET_MIN_ACTION_INTERVAL: no action (a flapping link cannot thrash)"
t_assert_eq "dns" "$(run_nw 'net_action NOWAN 3 300 0 0')" \
  "at the interval floor the first rung is the cheapest one: dns"
t_assert_eq "renew" "$(run_nw 'net_action NOWAN 3 9999 1 0')" \
  "second action this outage escalates to renew"
t_assert_eq "wifi" "$(run_nw 'net_action NOWAN 3 9999 2 0')" \
  "third action escalates to the wireless radio"
t_assert_eq "wifi" "$(run_nw 'net_action NOWAN 3 9999 99 0')" \
  "a reboot is NOT taken by default, however long the outage lasts"
t_assert_eq "reboot" "$(run_nw 'NET_ALLOW_REBOOT=yes
net_action NOWAN 3 9999 6 0')" \
  "and is reached only when explicitly enabled, at NET_REBOOT_AFTER_ACTIONS"
t_assert_eq "none" "$(run_nw 'net_action NOWAN 3 9999 4 12')" \
  "the hourly action cap is enforced"
t_assert_eq "none" "$(run_nw 'NET_FAIL_SAMPLES=5
net_action NOWAN 4 9999 0 0')" \
  "the sustained-failure floor is configurable"
t_assert_eq "dns" "$(run_nw 'NET_FAIL_SAMPLES=5
net_action NOWAN 5 9999 0 0')" \
  "and acts exactly at its boundary"

# --- C. the operator hold ---------------------------------------------------
t_assert_eq "not-held" "$(run_nw 'held && print held || print not-held')" \
  "with no hold file, actions are allowed"
print -r -- "$(( $(date +%s) + 600 ))" > "$T_BASE/log/net_hold"
t_assert_eq "held" "$(run_nw 'held && print held || print not-held')" \
  "a future deadline holds actions off, so an operator is never fought"
print -r -- "$(( $(date +%s) - 600 ))" > "$T_BASE/log/net_hold"
t_assert_eq "not-held" "$(run_nw 'held && print held || print not-held')" \
  "an expired deadline releases them"
print -r -- "rubbish" > "$T_BASE/log/net_hold"
t_assert_eq "not-held" "$(run_nw 'held && print held || print not-held')" \
  "a corrupt hold cannot mute the watchdog forever"
rm -f "$T_BASE/log/net_hold"

# --- D. what an action must NEVER do ---------------------------------------
# This is the safety core: a watchdog that can make the machine worse than it found it is a
# liability. Power-cycling the USB-Ethernet service is exactly how the wired link was lost on
# 2026-09-19, so no action may do it.
: > "$NSLOG"
run_nw 'do_action renew' FAKE_ROUTE="$R_OK" FAKE_NS_OUT="$NS_PORTS" >/dev/null
renew_log=$(cat "$NSLOG")
if print -r -- "$renew_log" | grep -qx -- "-setdhcp"; then
  t_ok "renew re-asserts DHCP"
else
  t_bad "renew did not re-assert DHCP (log: $(print -r -- "$renew_log" | tr '\n' ' '))"
fi
if print -r -- "$renew_log" | grep -q -- "-setnetworkserviceenabled"; then
  t_bad "renew POWER-CYCLED a service - that is how the wired link was lost"
else
  t_ok "renew never power-cycles a service"
fi
if print -r -- "$renew_log" | grep -q -- "-setairportpower"; then
  t_bad "renew touched the wireless radio"
else
  t_ok "renew leaves the wireless radio alone"
fi

: > "$NSLOG"
run_nw 'do_action wifi' >/dev/null
wifi_log=$(cat "$NSLOG")
if print -r -- "$wifi_log" | grep -qx -- "-setairportpower" && print -r -- "$wifi_log" | grep -qx -- "en0"; then
  t_ok "wifi power-cycles the wireless device"
else
  t_bad "wifi did not power-cycle en0 (log: $(print -r -- "$wifi_log" | tr '\n' ' '))"
fi
if print -r -- "$wifi_log" | grep -q -- "-setnetworkserviceenabled"; then
  t_bad "wifi disabled a network service"
else
  t_ok "wifi never disables a service either"
fi

# The router's 2.4GHz SSID ends in a SPACE. Quoting it under-quoted is a real, silent failure:
# the association would simply never happen.
: > "$NSLOG"
run_nw 'do_action wifi' NET_WIFI_SSID="TERNAK LAUNDRY " >/dev/null
if grep -qxF -- "TERNAK LAUNDRY " "$NSLOG"; then
  t_ok "re-associates by the exact SSID, trailing space preserved"
else
  t_bad "the SSID was not passed through byte-for-byte"
fi

# --- E. resolvers go on every REAL path, and on nothing else ---------------
# The streamer lists a "Tailscale" service whose hardware port is io.tailscale.ipn.macsys with NO
# device. Writing resolvers onto it would fight the daemon that manages DNS itself, so a service
# with no device must be skipped - and the rule is stated generally rather than by name.
: > "$NSLOG"
run_nw 'ensure_dns' FAKE_NS_OUT="$NS_PORTS" FAKE_NS_SERVICES="$NS_SERVICES" FAKE_NS_DNS="" >/dev/null
dns_log=$(cat "$NSLOG")
if print -r -- "$dns_log" | grep -qx -- "-setdnsservers"; then
  t_ok "ensure_dns writes resolvers onto services that have a device"
else
  t_bad "ensure_dns did not write any resolvers"
fi
if print -r -- "$dns_log" | grep -qx -- "Tailscale"; then
  t_bad "ensure_dns wrote resolvers onto a device-less service (Tailscale manages DNS itself)"
else
  t_ok "ensure_dns skips a service with no device"
fi
# A service that already has resolvers must be left alone, so a healthy box is never rewritten.
: > "$NSLOG"
run_nw 'ensure_dns' FAKE_NS_OUT="$NS_PORTS" FAKE_NS_SERVICES="$NS_SERVICES" FAKE_NS_DNS="9.9.9.9" >/dev/null
if print -r -- "$(cat "$NSLOG")" | grep -qx -- "-setdnsservers"; then
  t_bad "ensure_dns rewrote resolvers that were already set"
else
  t_ok "ensure_dns leaves an already-configured service alone"
fi

# --- F. the event log ------------------------------------------------------
python3 -c "open('$T_BASE/log/net_events.log','w').write('x'*4096)"
ev_before=$(/usr/bin/stat -f %i "$T_BASE/log/net_events.log")
run_nw 'trim_events' >/dev/null
ev_after=$(/usr/bin/stat -f %i "$T_BASE/log/net_events.log")
ev_size=$(/usr/bin/stat -f %z "$T_BASE/log/net_events.log")
t_assert_eq "$ev_before" "$ev_after" "trim_events keeps the inode (the append fd survives)"
(( ev_size < 4096 )) && t_ok "trim_events actually bounds the file ($ev_size bytes)" \
                     || t_bad "trim_events did not bound the file"

# --- G. the wiring, and the defaults that matter ---------------------------
grep -q 'net_watch.sh" loop' "$REPO_DIR/bin/stream.sh" \
  && t_ok "stream.sh starts the network watchdog" \
  || t_bad "stream.sh does not start bin/net_watch.sh"
grep -q 'NETWATCHPID' "$REPO_DIR/bin/stream.sh" \
  && t_ok "stream.sh reaps it on shutdown" \
  || t_bad "stream.sh does not track the network watchdog's pid"
grep -q 'LOG_MAX_BYTES_STREAM' "$REPO_DIR/bin/stream.sh" \
  && t_ok "stream.log has its own (larger) trim budget" \
  || t_bad "stream.log still shares the small trim budget"
grep -q ': ${NET_ALLOW_REBOOT:=no}' "$NW" \
  && t_ok "a reboot is opt-in, not a default" \
  || t_bad "NET_ALLOW_REBOOT no longer defaults to no"
grep -q ': ${NET_FAIL_SAMPLES:=3}' "$NW" \
  && t_ok "the sustained-failure floor defaults to 3 samples" \
  || t_bad "NET_FAIL_SAMPLES default changed"

t_teardown
t_summary
