#!/bin/zsh
# t08 - the two host tools: bin/forensics.sh (read-only evidence) and bin/harden-host.sh (T-29).
#
# harden-host.sh is the script whose output decides whether T-29 can be closed, so its
# verification has to be right. It reads `SleepDisabled` and `autorestart`, and macOS reports
# those keys ONLY when they are enabled - so an absent key means "off", not "unknown". The pmset
# stub models exactly that (an always-present stub would let a wrong reading pass).
#
# Also checked: the dry run must not write anything, and --go must refuse without root. Both are
# safety properties of a script that changes how a production Mac behaves with the lid shut.
source "${0:A:h}/lib.sh"
t_begin t08

t_setup >/dev/null

H="$T_BASE/bin/harden-host.sh"
F="$T_BASE/bin/forensics.sh"
STATE="$T_BASE/log/fake_pmset"
run_h() { BASE="$T_BASE" HOME="$T_BASE/home" PATH="$STUBS:$PATH" /bin/zsh "$H" "$@"; }

# --- the dry run must change nothing -----------------------------------------------------
rm -rf "$STATE"; mkdir -p "$STATE"
out=$(run_h 2>&1); rc=$?
t_assert_eq 0 $rc "harden-host dry run exits 0"
t_assert_contains "$out" "DRY RUN" "and says it is a dry run"
t_assert_contains "$out" "disablesleep" "and names the settings it would apply"
t_assert_no_file "$STATE/calls.log" "the dry run issued no pmset write at all"

# --- --check on an unhardened host -------------------------------------------------------
rm -rf "$STATE"; mkdir -p "$STATE"
out=$(run_h --check 2>&1); rc=$?
t_assert_eq 1 $rc "--check fails on an unhardened host"
t_assert_contains "$out" "FAIL  SleepDisabled" "and names SleepDisabled"
t_assert_contains "$out" "FAIL  autorestart" "and names autorestart"

# --- --check on a hardened host ----------------------------------------------------------
print -- 1 > "$STATE/sleepdisabled"; print -- 1 > "$STATE/autorestart"
out=$(run_h --check 2>&1); rc=$?
t_assert_eq 0 $rc "--check passes when both settings are on"
t_assert_contains "$out" "PASS  SleepDisabled = 1" "SleepDisabled is confirmed"
t_assert_contains "$out" "PASS  autorestart = 1" "autorestart is confirmed"

# --- half-hardened is still a failure ----------------------------------------------------
print -- 1 > "$STATE/sleepdisabled"; print -- 0 > "$STATE/autorestart"
out=$(run_h --check 2>&1); rc=$?
t_assert_eq 1 $rc "never-sleep without autorestart is still a failure"

# --- --go must refuse without root and must not touch pmset ------------------------------
rm -rf "$STATE"; mkdir -p "$STATE"
if (( EUID == 0 )); then
  t_ok "--go root path not exercised (the suite is running as root)"
else
  out=$(run_h --go 2>&1); rc=$?
  t_assert_eq 1 $rc "--go refuses to run without root"
  t_assert_contains "$out" "sudo" "and says how to run it properly"
  t_assert_no_file "$STATE/calls.log" "the refusal did not change anything"
fi

# --- the read-only collector -------------------------------------------------------------
out=$(BASE="$T_BASE" HOME="$T_BASE/home" PATH="$STUBS:$PATH" /bin/zsh "$F" 2>&1); rc=$?
t_assert_eq 0 $rc "forensics exits 0 even with no runtime logs present"
t_assert_contains "$out" "identity and uptime" "forensics reports identity and uptime"
t_assert_contains "$out" "who is logged in" "forensics reports the console user (the login-window test)"
t_assert_contains "$out" "sleep / wake history" "forensics reports sleep history"
t_assert_contains "$out" "memory and swap" "forensics reports memory pressure"
t_assert_contains "$out" "disk" "forensics reports disk"
t_assert_contains "$out" "panics" "forensics looks for panic reports"
t_assert_contains "$out" "how to read this" "forensics explains how to read itself"
# Its own sleep filter must drop assertion noise and keep the real event.
t_assert_contains "$out" "Clamshell Sleep" "the sleep filter keeps a real sleep event"
if print -r -- "$out" | grep -q 'PreventUserIdleSystemSleep'; then
  t_bad "the sleep filter leaked assertion noise"
else
  t_ok "the sleep filter drops PreventUserIdleSystemSleep noise"
fi

# --- the panic glob must stay silent when nothing matches ---------------------------------
# A bare `*.panic` glob made zsh print "no matches found" BEFORE 2>/dev/null could take effect,
# injecting shell noise into the evidence on exactly the healthy host that has no panics.
if print -r -- "$out" | grep -q 'no matches found'; then
  t_bad "a bare glob leaked 'no matches found' into the evidence"
else
  t_ok "no unmatched-glob noise in the report"
fi

# --- the network section: the 2026-09-18 blind spot --------------------------------------
# On that outage the host never slept, so every other section was empty and forensics had nothing
# to say about the lost network. tests/stubs/ifconfig supplies a deterministic pair: en0 is
# `active` with only a 169.254.x.x link-local (the trap), en1 is healthy, so the flag must fire
# for en0 and not for en1.
t_assert_contains "$out" "network (the 2026-09-18 blind spot)" "forensics reports the network section"
t_assert_contains "$out" "interfaces (en*)" "and the interfaces"
t_assert_contains "$out" "network service order" "and the service order"
t_assert_contains "$out" "default route" "and the default route"
t_assert_contains "$out" "effective resolvers" "and the effective resolvers"
t_assert_contains "$out" "per-service configured DNS" "and the per-service configured DNS"
t_assert_contains "$out" "Wi-Fi (system_profiler SPAirPortDataType" "and the Wi-Fi signal/noise"
t_assert_contains "$out" "DHCP (ipconfig getpacket" "and the DHCP lease"
t_assert_contains "$out" "ARP table" "and the ARP table"
t_assert_contains "$out" "Tailscale (usually NOT on PATH" "and the Tailscale CLI location"
t_assert_contains "$out" "LINKED BUT UNUSABLE" "an active link-local is flagged as unusable"
t_assert_contains "$out" "169.254.13.7" "and the address it judged is printed"
t_assert_contains "$out" "192.168.1.42" "while the healthy interface's address is printed too"
traps=$(print -r -- "$out" | grep -c 'LINKED BUT UNUSABLE')
t_assert_eq 1 "$traps" "the trap fires for the link-local interface only"
t_assert_contains "$out" "No network" "the legend explains the no-network trap"
t_assert_contains "$out" "not on the router's LAN" "the legend ties an unresolved gateway to the LAN"
t_assert_no_file "$STATE/calls.log" "forensics never writes to pmset either"
# A host missing the network tools must still produce a report: the section is defensive and an
# aborted collector is worse than a thin one. /sbin and /usr/sbin are dropped, so ifconfig (the
# stub), networksetup, route, scutil, ipconfig, arp and system_profiler are all absent.
out2=$(BASE="$T_BASE" HOME="$T_BASE/home" PATH="$STUBS:/bin:/usr/bin" /bin/zsh "$F" 2>&1); rc2=$?
t_assert_eq 0 $rc2 "forensics still exits 0 when the network tools are missing"
t_assert_contains "$out2" "network (the 2026-09-18 blind spot)" "and still prints the network section"

# --- --save writes the report and nothing else -------------------------------------------
rm -f "$T_BASE"/log/forensics-*.txt(N)
out=$(BASE="$T_BASE" HOME="$T_BASE/home" PATH="$STUBS:$PATH" /bin/zsh "$F" --save 2>&1); rc=$?
t_assert_eq 0 $rc "forensics --save exits 0"
# zsh errors on an unmatched glob, so count through a qualified array rather than ls.
reports=("$T_BASE"/log/forensics-*.txt(N))
t_assert_eq 1 "${#reports}" "and writes exactly one report"

t_teardown
t_summary
