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
t_assert_no_file "$STATE/calls.log" "forensics never writes to pmset either"

# --- --save writes the report and nothing else -------------------------------------------
rm -f "$T_BASE"/log/forensics-*.txt(N)
out=$(BASE="$T_BASE" HOME="$T_BASE/home" PATH="$STUBS:$PATH" /bin/zsh "$F" --save 2>&1); rc=$?
t_assert_eq 0 $rc "forensics --save exits 0"
# zsh errors on an unmatched glob, so count through a qualified array rather than ls.
reports=("$T_BASE"/log/forensics-*.txt(N))
t_assert_eq 1 "${#reports}" "and writes exactly one report"

t_teardown
t_summary
