#!/bin/zsh
# Apply and VERIFY the host hardening that stops the 2026-09-18 class of outage.
#
#   bin/harden-host.sh              show the plan and the current settings (dry run)
#   sudo bin/harden-host.sh --go    apply it, then verify it
#   bin/harden-host.sh --check      verify only, change nothing
#
# On 2026-09-18 the streamer dropped off the network mid-segment and stayed dark 10 h 23 m.
# From outside it looked like a sleeping Mac - powered on, wifi fine, Tailscale offline - and
# a sleeping Mac is exactly what this machine was allowed to become:
#
#   * stream.sh runs `caffeinate -ism`, whose system-sleep assertion is valid ONLY on AC
#     power, and which does not cover lid-close (clamshell) sleep at all. Lid-close sleep is
#     governed by a separate assertion, and `disablesleep` is the only thing that sets it.
#   * `autorestart` was off, so a power failure left the machine off until a human pressed
#     the button. launchd cannot revive a Mac that is off.
#
# This is the fix docs/known-issues.md recorded as "still wanted" and never applied. It is a
# host setting, not a project one: nothing here touches the repository, the stream or YouTube.
#
# It also reports auto-login, because there is a third way to be dark and look healthy: after
# a reboot the two agents do not start until someone logs in, since they are USER
# LaunchAgents. Enabling automatic login is a deliberate security trade and is NOT done here.
set -u

DRY=yes
CHECK_ONLY=no
for a in "$@"; do
  case "$a" in
    --go) DRY=no ;;
    --check) CHECK_ONLY=yes ;;
    -h|--help) sed -n '2,21p' "${0:A}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) print -u2 -- "unknown argument: $a"; exit 2 ;;
  esac
done

say() { print -- "$@" }
die() { print -u2 -- "FATAL: $*"; exit 1 }

[[ "$(uname -s)" == "Darwin" ]] || die "this is a macOS host setting; $(uname -s) does not have it"

# --- read what is set now --------------------------------------------------------------
# `disablesleep` and `autorestart` are reported by pmset ONLY when they are enabled, so an
# absent key means "off", not "unknown" - which is why absence is a FAIL below and not a WARN.
# Verified against real `pmset -g` and `pmset -g custom` output on macOS 27.
sleep_disabled() { pmset -g 2>/dev/null | awk '/SleepDisabled/ {print $2; exit}' }
autorestart_values() { { pmset -g custom 2>/dev/null; pmset -g 2>/dev/null; } | awk '/autorestart/ {print $2}' }
auto_login() { defaults read /Library/Preferences/com.apple.loginwindow autoLoginUser 2>/dev/null || print -- "(not set)"; }

verify() {   # verify -> 0 if everything wanted is set
  local rc=0 sd ar
  sd=$(sleep_disabled)
  if [[ "$sd" == "1" ]]; then say "  PASS  SleepDisabled = 1 (the Mac will not sleep, lid closed included)"
  else say "  FAIL  SleepDisabled is not set (reads '${sd:-absent}'; pmset reports it only when it is 1)"; rc=1; fi

  ar=$(autorestart_values)
  if [[ -z "$ar" ]]; then
    say "  FAIL  autorestart is not set (pmset reports it only when it is on)"; rc=1
  elif print -r -- "$ar" | grep -qv '^1$'; then
    say "  FAIL  autorestart = $(print -r -- "$ar" | tr '\n' ' ')(every profile must be 1)"; rc=1
  else
    say "  PASS  autorestart = 1"
  fi
  return $rc
}

say "YTLive host hardening - $(hostname), macOS $(sw_vers -productVersion 2>/dev/null)"
say ""
say "current settings"
verify || true
say "  auto-login  : $(auto_login)"
say ""

if [[ "$CHECK_ONLY" == "yes" ]]; then
  verify >/dev/null 2>&1 && { say "host is hardened."; exit 0; }
  say "host is NOT fully hardened - see the FAIL lines above."
  exit 1
fi

if [[ "$DRY" == "yes" ]]; then
  say "DRY RUN - nothing changed. The two settings that would be applied:"
  say "    pmset -a autorestart 1              # boot again by itself after a power failure"
  say "    pmset -c sleep 0 disablesleep 1     # never sleep, lid closed included"
  say ""
  say "Apply with:  sudo bin/harden-host.sh --go"
  say ""
  say "This cannot help against a power cut that does not come back, or a charger that is not"
  say "plugged in. That case needs a UPS on the Mac and on the router - it is the one thing"
  say "no software setting can cover, and it is tracked as T-30 in the wiki tracker."
  exit 0
fi

# Only --go gets here, and only root can change these.
(( EUID == 0 )) || die "pmset needs root:  sudo bin/harden-host.sh --go"

say "applying"
pmset -a autorestart 1 || die "pmset -a autorestart 1 failed"
pmset -c sleep 0 disablesleep 1 || die "pmset -c sleep 0 disablesleep 1 failed"
say "applied. verifying"
say ""

if verify; then
  say ""
  say "HARDENED. This survives a reboot and a lid close."
  say "Record it: the wiki Project-Tracker carries this as T-29, and it can now be closed."
  exit 0
fi

print -u2 -- ""
print -u2 -- "NOT HARDENED - a setting did not take. The FAIL lines above say which."
print -u2 -- "Do not close T-29 on this result."
exit 1
