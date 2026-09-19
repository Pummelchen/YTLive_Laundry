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
# A valid rendered NOPASSWD rule, so the checks that are about pmset are not decided by the
# sudoers file's absence. The rule itself is covered in its own section below.
SDOK="$T_BASE/sudoers.d-ok/ytlive-net"
mkdir -p "${SDOK:h}"
sed "s/__YT_USER__/$USER/g" "$REPO_DIR/conf/ytlive-sudoers" > "$SDOK"
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
out=$(BASE="$T_BASE" SUDOERS_DEST="$SDOK" HOME="$T_BASE/home" PATH="$STUBS:$PATH" /bin/zsh "$H" --check 2>&1); rc=$?
t_assert_eq 0 $rc "--check passes when both settings are on and the sudoers rule is installed"
t_assert_contains "$out" "PASS  SleepDisabled = 1" "SleepDisabled is confirmed"
t_assert_contains "$out" "PASS  autorestart = 1" "autorestart is confirmed"

# --- half-hardened is still a failure ----------------------------------------------------
print -- 1 > "$STATE/sleepdisabled"; print -- 0 > "$STATE/autorestart"
out=$(run_h --check 2>&1); rc=$?
t_assert_eq 1 $rc "never-sleep without autorestart is still a failure"

# --- `autorestart` support is a HARDWARE fact, and the check must not confuse the two -----
# Measured on the streamer (MacBookAir7,2) 2026-09-19 with root: `pmset -a autorestart 1` exits
# 0 and the key never appears, so --check failed forever on a setting this Mac cannot have.
# Unproven support still fails (a check that cannot confirm must not report OK), but a RECORDED
# "unsupported" is a stated hardware limit, not a failed setting.
rm -rf "$STATE"; mkdir -p "$STATE"
print -- 1 > "$STATE/sleepdisabled"
print -- autorestart > "$STATE/unsupported"
out=$(run_h --check 2>&1); rc=$?
t_assert_eq 1 $rc "unproven autorestart support still fails (cannot confirm = not OK)"
t_assert_contains "$out" "UNPROVEN" "and says support is unproven rather than simply 'off'"
t_assert_contains "$out" "run 'sudo bin/harden-host.sh --go' once" "and names the one command that settles it"

print -r -- '{"probed_at": 1789834000, "host": "test", "autorestart_supported": false, "probe": "pmset -a autorestart 1, then pmset -g"}' > "$T_BASE/log/host_hardening.json"
out=$(BASE="$T_BASE" SUDOERS_DEST="$SDOK" HOME="$T_BASE/home" PATH="$STUBS:$PATH" /bin/zsh "$H" --check 2>&1); rc=$?
t_assert_eq 0 $rc "a host whose hardware cannot autorestart passes the check"
t_assert_contains "$out" "N/A   autorestart is NOT SUPPORTED by this hardware" "and says so plainly"
t_assert_contains "$out" "T-30" "and points at the only mitigation (the UPS)"
if print -r -- "$out" | grep -q "FAIL  autorestart"; then
  t_bad "an unsupported key is still reported as a failed setting"
else
  t_ok "an unsupported key is never reported as a failed setting"
fi
rm -f "$T_BASE/log/host_hardening.json"

# The probe itself: it applies the setting, reads it back, and records the verdict. Extracted so
# the root-only --go path is still covered by the suite.
PROBE_FN=$(t_extract_fn "$H" probe_autorestart)
AR_FN=$(t_extract_fn "$H" autorestart_values)
probe_run() { BASE="$T_BASE" HOME="$T_BASE/home" PATH="$STUBS:$PATH" PROBE="$T_BASE/log/host_hardening.json" \
              /bin/zsh -c "$AR_FN
$PROBE_FN
probe_autorestart"; }
rm -f "$T_BASE/log/host_hardening.json"
print -- autorestart > "$STATE/unsupported"
probe_run >/dev/null 2>&1; rc=$?
t_assert_eq 1 $rc "the probe reports failure when the hardware ignores the write"
t_assert_contains "$(cat "$T_BASE/log/host_hardening.json" 2>/dev/null)" '"autorestart_supported": false' \
  "and records that verdict, so --check can report the limit instead of failing forever"
rm -f "$STATE/unsupported" "$T_BASE/log/host_hardening.json"
probe_run >/dev/null 2>&1; rc=$?
t_assert_eq 0 $rc "the probe reports success when the hardware honours the write"
t_assert_contains "$(cat "$T_BASE/log/host_hardening.json" 2>/dev/null)" '"autorestart_supported": true' \
  "and records the supported verdict too"

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

# --- the NOPASSWD rule the transport watchdog needs (T-38) --------------------------------
# The rule grants root for exactly three commands. What matters here is that the check can tell
# present-and-parsing from missing from MALFORMED - a broken file in /etc/sudoers.d can make sudo
# refuse every rule, including the one needed to remove it, so the failure has to be loud.
SD="$T_BASE/sudoers.d/ytlive-net"
mkdir -p "${SD:h}"
out=$(SUDOERS_DEST="$SD" run_h --check 2>&1); rc=$?
t_assert_eq 1 $rc "a host without the sudoers rule fails the check"
t_assert_contains "$out" "no $SD" "and names the missing rule"
t_assert_contains "$out" "a wedged lease needs a human" "and says what its absence costs"

out=$(SUDOERS_DEST="$SDOK" run_h --check 2>&1); rc=$?
t_assert_contains "$out" "PASS  $SDOK" "a rendered, parsing rule passes the check"

# An unreadable file is NOT a broken one: 0440 root:wheel is the correct mode, and a normal user
# cannot parse what it cannot read. Reporting that as "sudo may be refusing EVERY rule" was the
# first 2.8 build's bug, so it is pinned here.
print -r -- "valid enough" > "$SD"; chmod 000 "$SD"
out=$(SUDOERS_DEST="$SD" run_h --check 2>&1); rc=$?
t_assert_contains "$out" "readable only by root" "an unreadable (0440) rule is reported as unverifiable, not as broken"
if print -r -- "$out" | grep -q "refusing EVERY rule"; then
  t_bad "an unreadable rule still raised the alarming broken-file failure"
else
  t_ok "an unreadable rule never claims sudo itself may be broken"
fi
chmod 644 "$SD"

print -r -- "this is not a sudoers file" > "$SD"
out=$(SUDOERS_DEST="$SD" run_h --check 2>&1); rc=$?
t_assert_eq 1 $rc "a malformed sudoers file fails the check"
t_assert_contains "$out" "refusing EVERY rule" "and warns that sudo itself may be broken"
rm -f "$SD"

# The template itself: it must render to something visudo accepts, for the user it names, and it
# must not contain a wildcard - a wildcard in an argument is how a narrow grant stops being narrow.
if /usr/sbin/visudo -cf <(sed "s/__YT_USER__/nobody/g" "$REPO_DIR/conf/ytlive-sudoers") >/dev/null 2>&1; then
  t_ok "conf/ytlive-sudoers renders to a file visudo accepts"
else
  t_bad "conf/ytlive-sudoers does not parse"
fi
if grep -q '\*' "$REPO_DIR/conf/ytlive-sudoers"; then
  t_bad "the sudoers template contains a wildcard"
else
  t_ok "the sudoers template grants exact commands, with no wildcard"
fi
if grep -q 'NOPASSWD' "$REPO_DIR/conf/ytlive-sudoers" && ! grep -q 'ALL=(ALL)' "$REPO_DIR/conf/ytlive-sudoers"; then
  t_ok "it grants root per-command, not ALL=(ALL)"
else
  t_bad "the sudoers template grants ALL=(ALL)"
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
