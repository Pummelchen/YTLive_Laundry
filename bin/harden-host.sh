#!/bin/zsh
# Apply and VERIFY the host hardening that covers the host power class of outage.
#
#   bin/harden-host.sh              show the plan and the current settings (dry run)
#   sudo bin/harden-host.sh --go    apply it, then verify it
#   bin/harden-host.sh --check      verify only, change nothing
#
# The 2026-09-18 outage was a transport failure - the streamer lost DNS and its own LAN while
# it stayed awake, and was dark ~19 h 26 m - so nothing here would have prevented it. This file
# covers the separate POWER class, which this machine was still allowed to become:
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

BASE="${BASE:-${0:A:h:h}}"          # the checkout this script lives in; tests override it
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

# --- is `autorestart` even SUPPORTED by this hardware? --------------------------------------
# This is the part the read-only check cannot answer by reading. macOS reports `autorestart`
# only when it is ON, so "supported but off" and "this Mac cannot do it at all" look identical
# in `pmset -g`. And `pmset -g cap` is not an oracle either: measured 2026-09-19 it omits
# `disablesleep`, which demonstrably works on this host.
#
# Measured on the streamer (MacBookAir7,2) 2026-09-19 with root: `pmset -a autorestart 1`
# returns 0, prints nothing, and the key NEVER appears - while a control toggle of `womp`
# (1 -> 0 -> 1) read back correctly, proving pmset writes do work here. So the write is
# accepted and ignored, and `--check` failed forever on an unsupported key.
#
# The answer is therefore PROBED once (root: apply, read back) and RECORDED, and the read-only
# check consumes the record instead of guessing. An unprobed host still FAILS, because a check
# that cannot confirm must not report OK.
PROBE="${BASE:-$PWD}/log/host_hardening.json"

# --- the transport watchdog's root-only rungs (T-38) ----------------------------------------
# bin/net_watch.sh is a launchd USER agent: `ipconfig` and a resolver flush need root, so the
# ladder stopped at the no-sudo networksetup actions and a wedged lease needed a human. The fix
# is not to hand the agent the account password - that would put a login secret in a file a
# network-facing process can read - but a sudoers rule granting exactly four commands.
SUDOERS_SRC="$BASE/conf/ytlive-sudoers"
SUDOERS_DEST="${SUDOERS_DEST:-/etc/sudoers.d/ytlive-net}"   # overridable so the suite can point it at a scratch tree
SUDOERS_USER="$(stat -f %Su "$BASE" 2>/dev/null || print -- "${USER:-user}")"

sudoers_installed() {   # 0 only when the rule is present AND parses
  [[ -f "$SUDOERS_DEST" ]] || return 1
  /usr/sbin/visudo -cf "$SUDOERS_DEST" >/dev/null 2>&1 || return 1
  grep -q 'NOPASSWD: /usr/sbin/ipconfig set' "$SUDOERS_DEST" 2>/dev/null || return 1
  return 0
}

autorestart_support() {   # -> yes | no | unknown
  [[ -f "$PROBE" ]] || { print -- unknown; return }
  if grep -q '"autorestart_supported": *true' "$PROBE" 2>/dev/null; then print -- yes
  elif grep -q '"autorestart_supported": *false' "$PROBE" 2>/dev/null; then print -- no
  else print -- unknown; fi
}

probe_autorestart() {   # root only. Applies, reads back, records the verdict. 0 = supported
  pmset -a autorestart 1 || return 1
  local ar=false
  [[ -n "$(autorestart_values)" ]] && ar=true
  mkdir -p "${PROBE:h}" 2>/dev/null
  print -r -- "{\"probed_at\": $(date +%s), \"host\": \"$(hostname)\", \"autorestart_supported\": $ar, \"probe\": \"pmset -a autorestart 1, then pmset -g custom / pmset -g\"}" > "$PROBE" 2>/dev/null
  [[ "$ar" == true ]]
}

verify() {   # verify -> 0 if everything wanted is set
  local rc=0 sd ar
  sd=$(sleep_disabled)
  if [[ "$sd" == "1" ]]; then say "  PASS  SleepDisabled = 1 (the Mac will not sleep, lid closed included)"
  else say "  FAIL  SleepDisabled is not set (reads '${sd:-absent}'; pmset reports it only when it is 1)"; rc=1; fi

  ar=$(autorestart_values)
  case "$(autorestart_support)" in
    no)
      # The probe already established that this Mac cannot do it. Failing here forever would
      # train the operator to ignore the check, which is worse than reporting the limit.
      say "  N/A   autorestart is NOT SUPPORTED by this hardware - a recorded probe shows the write is accepted and ignored. A power cut still leaves the Mac off; the UPS (T-30) is the only mitigation. This is a hardware limit, not a failed setting." ;;
    *)
      if [[ -z "$ar" ]]; then
        say "  FAIL  autorestart is not set (pmset reports it only when it is on). Support is UNPROVEN on this host: run 'sudo bin/harden-host.sh --go' once and it will probe and record the answer."
        rc=1
      elif print -r -- "$ar" | grep -qv '^1$'; then
        say "  FAIL  autorestart = $(print -r -- "$ar" | tr '\n' ' ')(every profile must be 1)"; rc=1
      else
        say "  PASS  autorestart = 1"
      fi ;;
  esac

  # The NOPASSWD rule the transport watchdog needs (T-38). A file in /etc/sudoers.d that does
  # not parse can make sudo refuse everything, so a broken one is louder than a missing one.
  if sudoers_installed; then
    say "  PASS  $SUDOERS_DEST: the transport watchdog may renew DHCP and flush the resolver"
  elif [[ -f "$SUDOERS_DEST" ]]; then
    say "  FAIL  $SUDOERS_DEST exists but does not parse or lacks the rule - sudo may be refusing EVERY rule. Fix or remove it now: sudo rm $SUDOERS_DEST"
    rc=1
  else
    say "  FAIL  no $SUDOERS_DEST: bin/net_watch.sh cannot renew DHCP or flush the resolver cache, so a wedged lease needs a human (T-38). Apply: sudo bin/harden-host.sh --go"
    rc=1
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
  say "and one file laid down, for the transport watchdog's root-only rungs (T-38):"
  say "    $SUDOERS_DEST  <- $SUDOERS_SRC, for user '$SUDOERS_USER',"
  say "    parsed with visudo -cf before it is installed 0440 root:wheel"
  say ""
  say "autorestart is APPLIED AND READ BACK, because some Macs silently ignore it; the verdict is"
  say "recorded in $PROBE so that --check can tell 'unsupported by this hardware' from 'off'."
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
pmset -c sleep 0 disablesleep 1 || die "pmset -c sleep 0 disablesleep 1 failed"

# The sudoers rule goes through visudo BEFORE it can reach /etc/sudoers.d: a file that does not
# parse there can make sudo refuse every rule, including the one needed to remove it.
if [[ -f "$SUDOERS_SRC" ]]; then
  tmp=$(mktemp) || die "cannot create a temporary file"
  sed "s/__YT_USER__/$SUDOERS_USER/g" "$SUDOERS_SRC" > "$tmp"
  if ! /usr/sbin/visudo -cf "$tmp" >/dev/null; then
    rm -f "$tmp"
    die "the rendered sudoers file does not parse - NOT installing it (nothing was changed)"
  fi
  install -m 0440 -o root -g wheel "$tmp" "$SUDOERS_DEST" || { rm -f "$tmp"; die "cannot install $SUDOERS_DEST"; }
  rm -f "$tmp"
  say "sudoers: installed $SUDOERS_DEST for user '$SUDOERS_USER' (3 exact NOPASSWD commands, no wildcards)"
else
  say "sudoers: no $SUDOERS_SRC in this checkout - the transport watchdog keeps its no-sudo limit"
fi
if probe_autorestart; then
  say "autorestart: applied and confirmed."
else
  say "autorestart: NOT SUPPORTED by this hardware - the write is accepted and ignored (the probe read the key back and it is still absent). Recorded in $PROBE so --check reports the hardware limit instead of failing forever. A power cut still leaves the Mac off: only the UPS (T-30) covers that."
fi
say "applied. verifying"
say ""

if verify; then
  say ""
  if [[ "$(autorestart_support)" == "no" ]]; then
    say "HARDENED as far as this hardware allows. This survives a reboot and a lid close; it does NOT survive a power cut (autorestart is unsupported here - T-30, the UPS, is the mitigation)."
  else
    say "HARDENED. This survives a reboot and a lid close."
  fi
  say "Record it: the wiki Project-Tracker carries this as T-29, and it can now be closed."
  exit 0
fi

print -u2 -- ""
print -u2 -- "NOT HARDENED - a setting did not take. The FAIL lines above say which."
print -u2 -- "Do not close T-29 on this result."
exit 1
