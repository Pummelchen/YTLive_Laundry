#!/bin/zsh
# Install the EXTERNAL watchdog (bin/yt_watchdog.py) on an always-on host.
#
#   sudo ./bin/watchdog-install.sh                 install, do not start
#   sudo ./bin/watchdog-install.sh --start         install and enable the service
#   sudo ./bin/watchdog-install.sh --prefix /var/ytlive-watchdog
#        ./bin/watchdog-install.sh --uninstall
#
# This is NOT install.sh. install.sh provisions the STREAMER (ffmpeg, yt-dlp, the two
# LaunchAgents that encode and publish). This installs the one component that must not live
# on the streamer at all, because its job is to notice that the streamer is gone.
#
# Linux gets a systemd unit; macOS gets a LaunchAgent. The service is not started unless
# --start is given, for the same reason install.sh refuses to start until it is safe: the
# watchdog is useless without a working alert path, and a running watchdog whose alerts
# silently fail is worse than no watchdog.
set -u

SELF="${0:A}"
BASE="${SELF:h:h}"                    # the repository root
PREFIX="/var/ytlive-watchdog"
START=no
UNINSTALL=no

while (( $# > 0 )); do
  case "$1" in
    --prefix) PREFIX="${2:-}"; shift 2 ;;
    --start) START=yes; shift ;;
    --uninstall) UNINSTALL=yes; shift ;;
    -h|--help) sed -n '2,20p' "$SELF" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) print -u2 -- "unknown argument: $1"; exit 2 ;;
  esac
done

say() { print -- "$@" }
die() { print -u2 -- "FATAL: $*"; exit 1 }

OS=$(uname -s)
[[ -f "$BASE/bin/yt_watchdog.py" ]] || die "cannot find bin/yt_watchdog.py (run this from the checkout)"

if [[ "$UNINSTALL" == "yes" ]]; then
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

# --- lay down the program, the config and the state directory --------------------------
mkdir -p "$PREFIX/bin" "$PREFIX/conf" || die "cannot create $PREFIX"
install -m 755 "$BASE/bin/yt_watchdog.py" "$PREFIX/bin/yt_watchdog.py" || die "cannot install the script"

if [[ -f "$PREFIX/conf/watchdog.env" ]]; then
  say "keeping the existing $PREFIX/conf/watchdog.env (it holds the mail secret)"
else
  install -m 600 "$BASE/conf/watchdog.env.example" "$PREFIX/conf/watchdog.env" || die "cannot seed the config"
  chmod 600 "$PREFIX/conf/watchdog.env"
  say "seeded $PREFIX/conf/watchdog.env from the tracked example - EDIT IT"
fi

# The watchdog reads conf/watchdog.env next to its BASE, and BASE defaults to the parent of
# bin/. Point it at this install so the tracked example and the live file agree.
if ! grep -q '^WATCH_STATE_DIR=' "$PREFIX/conf/watchdog.env" 2>/dev/null; then
  print -- "WATCH_STATE_DIR=\"$PREFIX\"" >> "$PREFIX/conf/watchdog.env"
fi

# A missing yt-dlp blinds the watchdog (the v2.1 lesson: a stale yt-dlp looked exactly like
# a dark channel). Refuse to start without one.
YTDLP="$(command -v yt-dlp || true)"
[[ -n "$YTDLP" ]] || say "WARNING: yt-dlp is not on PATH; the watchdog will report UNKNOWN until it is"

# --- the service ------------------------------------------------------------------------
case "$OS" in
  Linux)
    UNIT=/etc/systemd/system/ytlive-watchdog.service
    sed "s#/var/ytlive-watchdog#$PREFIX#g" "$BASE/conf/ytlive-watchdog.service" > "$UNIT" \
      || die "cannot write $UNIT"
    systemctl daemon-reload
    say "installed $UNIT"
    if [[ "$START" == "yes" ]]; then
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
    cat > "$PLIST" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.user.ytlive-watchdog</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/bin/python3</string>
    <string>$PREFIX/bin/yt_watchdog.py</string>
    <string>run</string>
  </array>
  <key>WorkingDirectory</key><string>$PREFIX</string>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ProcessType</key><string>Background</string>
  <key>StandardOutPath</key><string>$PREFIX/watchdog.out.log</string>
  <key>StandardErrorPath</key><string>$PREFIX/watchdog.err.log</string>
</dict>
</plist>
PLISTEOF
    plutil -lint "$PLIST" >/dev/null || die "the generated plist is invalid"
    say "installed $PLIST"
    if [[ "$START" == "yes" ]]; then
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
