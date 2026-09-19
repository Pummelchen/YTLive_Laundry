#!/bin/sh
# Install the EXTERNAL watchdog (bin/yt_watchdog.py) on an always-on host.
#
#   sudo ./bin/watchdog-install.sh                 install, do not start
#   sudo ./bin/watchdog-install.sh --start         install and enable the service
#   ./bin/watchdog-install.sh --dry-run            resolve the interpreter and the job PATH, write nothing
#   sudo ./bin/watchdog-install.sh --prefix /var/ytlive-watchdog
#        ./bin/watchdog-install.sh --uninstall
#
# POSIX sh, deliberately, NOT zsh: the host this installs onto is usually Linux, and Debian does
# not ship zsh. Written in zsh at first, it failed on the real watchdog host with `cannot
# execute: required file not found` (exit 127) - measured on Debian 13, 2026-09-19. The runtime
# it installs is portable Python; the installer has no business requiring a shell the target
# does not have.
#
# This is NOT install.sh. install.sh provisions the STREAMER (ffmpeg, yt-dlp, the two
# LaunchAgents that encode and publish). This installs the one component that must not live on
# the streamer, because its whole job is to notice that the streamer is gone.
#
# Linux gets a systemd unit; macOS gets a LaunchAgent. The service is not started unless --start
# is given, for the same reason install.sh refuses to start until it is safe: the watchdog is
# useless without a working alert path and a visible yt-dlp, and a running watchdog whose checks
# silently fail is worse than no watchdog.
set -u

SELF="$0"
SELF_DIR=$(CDPATH= cd -- "$(dirname -- "$SELF")" && pwd)
BASE=$(CDPATH= cd -- "$SELF_DIR/.." && pwd)     # the repository root
PREFIX="/var/ytlive-watchdog"
START=no
UNINSTALL=no
DRY=no

while [ $# -gt 0 ]; do
  case "$1" in
    --prefix) PREFIX="${2:-}"; shift 2 ;;
    --start) START=yes; shift ;;
    --dry-run|--dry) DRY=yes; shift ;;
    --uninstall) UNINSTALL=yes; shift ;;
    -h|--help) sed -n '2,23p' "$SELF" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) printf 'unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
done

say() { printf '%s\n' "$*"; }
die() { printf 'FATAL: %s\n' "$*" >&2; exit 1; }

OS=$(uname -s)
[ -f "$BASE/bin/yt_watchdog.py" ] || die "cannot find bin/yt_watchdog.py (run this from the checkout)"

if [ "$UNINSTALL" = "yes" ]; then
  case "$OS" in
    Linux)
      systemctl disable --now ytlive-watchdog 2>/dev/null
      rm -f /etc/systemd/system/ytlive-watchdog.service
      systemctl daemon-reload 2>/dev/null
      say "removed the systemd unit. State and logs are left in $PREFIX (delete them by hand)." ;;
    Darwin)
      PLIST="$HOME/Library/LaunchAgents/com.user.ytlive-watchdog.plist"
      launchctl unload "$PLIST" 2>/dev/null
      rm -f "$PLIST"
      say "removed $PLIST. State and logs are left in $PREFIX." ;;
  esac
  exit 0
fi

# --- which python3, and can the job actually see its tools? (read-only) -------------------
# NEVER the macOS system python by default. /usr/bin/python3 is the Xcode Command Line Tools
# build - measured at 3.9.6 on this project's machines on 2026-09-19 - and trusting PATH order
# is exactly what broke the 2026-09-17 deploy: it resolved a yt-dlp that could no longer parse
# YouTube's live page. The watchdog is stdlib-only and would still run on 3.9, but normalising
# the system python is how that class of bug comes back, so the newest interpreter wins here
# too. WATCHDOG_PY_SEARCH overrides the whole search list (space separated), mirroring
# install.sh's YT_PY_SEARCH, which is what the test suite uses to make the choice deterministic.
pick_python() {
  _best=""; _bestver=0
  if [ -n "${WATCHDOG_PY_SEARCH:-}" ]; then
    _list="$WATCHDOG_PY_SEARCH"
  else
    _list="$(command -v python3 2>/dev/null)
$HOME/.local/bin/python3
/opt/homebrew/bin/python3
/usr/local/bin/python3
/Library/Frameworks/Python.framework/Versions/*/bin/python3
/usr/bin/python3"
  fi
  # Unquoted on purpose: word splitting separates the candidates, and the framework glob above
  # expands here. An unmatched glob stays literal and is dropped by the -x test.
  for _p in $_list; do
    [ -n "$_p" ] || continue
    [ -x "$_p" ] || continue
    _ver=$("$_p" -c 'import sys; print("%d%02d%02d" % sys.version_info[:3])' 2>/dev/null) || continue
    case "$_ver" in ''|*[!0-9]*) continue ;; esac
    if [ "$_ver" -gt "$_bestver" ]; then _bestver="$_ver"; _best="$_p"; fi
  done
  printf '%s' "$_best"
}

PY=$(pick_python)
[ -n "$PY" ] || die "no python3 found. Install python.org or Homebrew python 3.12+ - do not rely on the Xcode CLT build"
PYV=$("$PY" -c 'import sys; print(".".join(map(str, sys.version_info[:3])))' 2>/dev/null)
say "python   : $PY ($PYV)"
# Only a warning on macOS: on Debian /usr/bin/python3 IS the modern system python (3.13.5 on the
# watchdog host, measured 2026-09-19), and crying wolf about it there is exactly the kind of
# noise that trains an operator to ignore warnings.
if [ "$OS" = "Darwin" ] && [ "$PY" = "/usr/bin/python3" ]; then
  say "WARNING: the only python3 found is the macOS system build. Install python.org or Homebrew 3.12+."
fi

# A launchd job gets PATH=/usr/bin:/bin:/usr/sbin:/sbin - measured: `launchctl getenv PATH` is
# unset - and yt-dlp normally lives in ~/.local/bin. Without this the watchdog would start and
# then report UNKNOWN forever, which looks exactly like a dark channel and is the worst possible
# failure for the thing whose job is to notice a dark channel. systemd's default PATH does
# include /usr/local/bin, so this bites macOS hardest, but it is set for both.
JOB_PATH="${WATCHDOG_EXTRA_PATH:+$WATCHDOG_EXTRA_PATH:}$HOME/.local/bin:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
YTDLP_OK=no
say "job PATH : $JOB_PATH"
for _t in yt-dlp tailscale; do
  if env -i PATH="$JOB_PATH" HOME="$HOME" /bin/sh -c "command -v $_t" >/dev/null 2>&1; then
    say "  found   $_t"
    [ "$_t" = "yt-dlp" ] && YTDLP_OK=yes
  else
    say "  MISSING $_t under the job's PATH"
  fi
done
if [ "$YTDLP_OK" != "yes" ]; then
  say "WARNING: without yt-dlp the channel signal is permanently UNKNOWN and the watchdog is"
  say "         blind. Put it on the job's PATH, or set WATCHDOG_EXTRA_PATH to the directory."
fi

# The systemd unit template has to be findable wherever this runs: the checkout (normal) or an
# installed prefix (a re-install). Resolving it HERE, before anything is written, is not tidiness:
# the first version rendered the unit with `sed > $UNIT`, and when the template was missing the
# shell had already truncated the destination, so it zeroed the LIVE unit and systemd reported it
# as "masked". That silently removed the watchdog's boot survival - the exact failure it exists to
# report - and it was found by running the installer on the real host on 2026-09-19.
UNIT_TEMPLATE=""
if [ "$OS" = "Linux" ]; then
  for _c in "$BASE/conf/ytlive-watchdog.service" "$PREFIX/conf/ytlive-watchdog.service"; do
    if [ -f "$_c" ]; then UNIT_TEMPLATE="$_c"; break; fi
  done
  if [ -z "$UNIT_TEMPLATE" ]; then
    die "no unit template: looked for conf/ytlive-watchdog.service in $BASE and $PREFIX. Run this from the checkout (or the unpacked archive); nothing has been changed."
  fi
fi

# --- dry run stops here, having written nothing ------------------------------------------
if [ "$DRY" = "yes" ]; then
  say ""
  say "DRY RUN - nothing written. For real:"
  say "    sudo $SELF --prefix $PREFIX${START:+ --start}"
  exit 0
fi

# --- lay down the program, the config and the state directory ----------------------------
mkdir -p "$PREFIX/bin" "$PREFIX/conf" || die "cannot create $PREFIX"
# Skipped when the source IS the destination: re-running the installer from an installed copy is
# a normal way to update a host, and `install` refuses to copy a file onto itself ("are the same
# file"), which aborted the run half way through. Measured on the watchdog host 2026-09-19.
if [ "$BASE/bin/yt_watchdog.py" = "$PREFIX/bin/yt_watchdog.py" ]; then
  say "program  : already at $PREFIX/bin/yt_watchdog.py, not copying onto itself"
else
  install -m 755 "$BASE/bin/yt_watchdog.py" "$PREFIX/bin/yt_watchdog.py" || die "cannot install the script"
fi

# --- the version stamp --------------------------------------------------------------------
# Without this, "which build is this host running?" had no answer except hashing the file
# against a checkout - which is how a PRE-2.4 yt_watchdog.py sat on the live host while the
# streamer reported DEPLOY COMPLETE and the dead-man rule the release depended on could not
# fire (measured 2026-09-19). The streamer and this host are separate installs with separate
# installers, so the host has to be able to say what it is running.
if [ -f "$BASE/VERSION" ]; then
  cat "$BASE/VERSION" > "$PREFIX/VERSION" || die "cannot write $PREFIX/VERSION"
  say "version  : $(cat "$PREFIX/VERSION")"
else
  say "version  : NO $BASE/VERSION - this host will report unknown (not a release tree?)"
fi

if [ -f "$PREFIX/conf/watchdog.env" ]; then
  say "keeping the existing $PREFIX/conf/watchdog.env (it holds the mail secret)"
else
  install -m 600 "$BASE/conf/watchdog.env.example" "$PREFIX/conf/watchdog.env" || die "cannot seed the config"
  chmod 600 "$PREFIX/conf/watchdog.env"
  say "seeded $PREFIX/conf/watchdog.env from the tracked example - EDIT IT"
fi

# The watchdog reads conf/watchdog.env next to its BASE, and BASE defaults to the parent of
# bin/. Point it at this install so the tracked example and the live file agree.
if ! grep -q '^WATCH_STATE_DIR=' "$PREFIX/conf/watchdog.env" 2>/dev/null; then
  printf 'WATCH_STATE_DIR="%s"\n' "$PREFIX" >> "$PREFIX/conf/watchdog.env"
fi

# Keep the unit template beside the install too, so re-running this from the installed copy (the
# normal way to update a host) can find it without a checkout present.
if [ "$OS" = "Linux" ] && [ "$UNIT_TEMPLATE" != "$PREFIX/conf/ytlive-watchdog.service" ]; then
  install -m 644 "$UNIT_TEMPLATE" "$PREFIX/conf/ytlive-watchdog.service" 2>/dev/null || true
fi

# --- the service -------------------------------------------------------------------------
case "$OS" in
  Linux)
    UNIT=/etc/systemd/system/ytlive-watchdog.service
    # Render to a temp file and move it into place, so a failure can never leave a truncated or
    # empty unit where a working one used to be. Check the rendered output is non-empty too.
    if ! sed -e "s#/var/ytlive-watchdog#$PREFIX#g" -e "s#^ExecStart=/usr/bin/python3#ExecStart=$PY#" \
             "$UNIT_TEMPLATE" > "$UNIT.new" 2>/dev/null; then
      rm -f "$UNIT.new"
      die "could not render the unit from $UNIT_TEMPLATE; $UNIT is untouched"
    fi
    if [ ! -s "$UNIT.new" ]; then
      rm -f "$UNIT.new"
      die "the rendered unit is empty; refusing to replace $UNIT"
    fi
    mv "$UNIT.new" "$UNIT" || die "cannot install $UNIT"
    systemctl daemon-reload
    say "installed $UNIT"
    if [ "$START" = "yes" ]; then
      [ "$YTDLP_OK" = "yes" ] || die "refusing to start: yt-dlp is not visible to the job, so the channel signal would be permanently UNKNOWN and look healthy"
      systemctl enable --now ytlive-watchdog || die "systemctl enable failed"
      say "started. Follow it with:  journalctl -u ytlive-watchdog -f"
    else
      say "not started. Check the config, then:"
      say "    sudo systemctl enable --now ytlive-watchdog"
    fi
    ;;
  Darwin)
    PLIST="$HOME/Library/LaunchAgents/com.user.ytlive-watchdog.plist"
    mkdir -p "$HOME/Library/LaunchAgents"
    cat > "$PLIST.new" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.user.ytlive-watchdog</string>
  <key>ProgramArguments</key>
  <array>
    <string>$PY</string>
    <string>$PREFIX/bin/yt_watchdog.py</string>
    <string>run</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key><string>$JOB_PATH</string>
  </dict>
  <key>WorkingDirectory</key><string>$PREFIX</string>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ProcessType</key><string>Background</string>
  <key>StandardOutPath</key><string>$PREFIX/watchdog.out.log</string>
  <key>StandardErrorPath</key><string>$PREFIX/watchdog.err.log</string>
</dict>
</plist>
PLISTEOF
    # Validate before moving it into place: an invalid plist at the real path is worse than none,
    # because launchd would keep failing to load it while the file looks installed.
    if ! plutil -lint "$PLIST.new" >/dev/null 2>&1; then
      rm -f "$PLIST.new"
      die "the generated plist is invalid; $PLIST is untouched"
    fi
    mv "$PLIST.new" "$PLIST" || die "cannot install $PLIST"
    say "installed $PLIST"
    if [ "$START" = "yes" ]; then
      [ "$YTDLP_OK" = "yes" ] || die "refusing to start: yt-dlp is not visible to the job, so the channel signal would be permanently UNKNOWN and look healthy"
      launchctl unload "$PLIST" 2>/dev/null
      launchctl load -w "$PLIST" || die "launchctl load failed"
      say "started."
    else
      say "not started. Check the config, then:  launchctl load -w $PLIST"
    fi
    ;;
  *)
    die "unsupported platform: $OS (this installer knows Linux/systemd and macOS/launchd)" ;;
esac

say ""
say "Before trusting it, send one real alert through the configured path:"
say "    $PREFIX/bin/yt_watchdog.py test-alert"
say "and check the channel state it reports:"
say "    $PREFIX/bin/yt_watchdog.py status"
