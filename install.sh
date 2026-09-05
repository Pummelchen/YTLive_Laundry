#!/bin/zsh
# ============================================================================
#  YTLive installer - sets up the CCTV -> YouTube streamer on a fresh Mac.
#
#  Usage:   cd ~/Downloads/YTLive && ./install.sh            # install, do NOT start
#           cd ~/Downloads/YTLive && ./install.sh --start    # install and start services
#
#  Idempotent: safe to re-run. Nothing here needs sudo.
#
#  What it does
#    1. ffmpeg + ffprobe static builds into ~/.local/bin   (Intel build; on Apple Silicon
#       it runs under Rosetta 2 - install Rosetta first:  softwareupdate --install-rosetta)
#    2. yt-dlp via pip --user, symlinked into ~/.local/bin (needed by the monitor)
#    3. ~/.local/bin on PATH in ~/.zshrc
#    4. LaunchAgents for the stream + monitor, written with THIS user's home path
#    5. log dirs, permissions, playlist
#
#  What it CANNOT do (you must, once, in the GUI)
#    - Full Disk Access for /bin/zsh: System Settings > Privacy & Security > Full Disk
#      Access > "+" > Cmd+Shift+G > /bin/zsh. Without it launchd cannot read ~/Downloads.
#    - Tailscale sign-in (for remote SSH/control).
#    - YouTube Studio: stream key in conf/stream.env, and Auto-start ON / Auto-stop OFF.
#
#  WARNING: conf/stream.env carries the YouTube stream key. Two Macs pushing to the same
#  key at the same time fight each other. Only run --start on ONE machine per key.
# ============================================================================
set -u
BASE="$(cd "$(dirname "$0")" && pwd)"
BIN="$HOME/.local/bin"
LA="$HOME/Library/LaunchAgents"
LOGS="$HOME/Library/Logs/YTLive"
START="no"; [[ "${1:-}" == "--start" ]] && START="yes"

say() { print -r -- "==> $*"; }
die() { print -r -- "ERROR: $*" >&2; exit 1; }

[[ "$BASE" == "$HOME/Downloads/YTLive" ]] || \
  say "note: running from $BASE (expected ~/Downloads/YTLive). Paths below use $BASE."

mkdir -p "$BIN" "$LA" "$LOGS" "$BASE/log" "$BASE/conf"
ARCH=$(uname -m); OSV=$(sw_vers -productVersion)
say "macOS $OSV on $ARCH, user $(whoami), base $BASE"

# --- 1. ffmpeg / ffprobe -----------------------------------------------------
if [[ -x "$BIN/ffmpeg" && -x "$BIN/ffprobe" ]]; then
  say "ffmpeg already present: $("$BIN/ffmpeg" -version 2>/dev/null | head -1 | cut -c1-60)"
else
  if [[ "$ARCH" == "arm64" ]] && ! /usr/bin/pgrep -q oahd; then
    say "Apple Silicon without Rosetta: run  softwareupdate --install-rosetta --agree-to-license  then re-run."
    die "Rosetta 2 required for the static Intel ffmpeg build"
  fi
  TMP=$(mktemp -d)
  for t in ffmpeg ffprobe; do
    say "downloading $t (evermeet.cx static build)"
    curl -fL --retry 3 -o "$TMP/$t.zip" "https://evermeet.cx/ffmpeg/get/$([[ $t == ffprobe ]] && echo ffprobe/)zip" \
      || die "download of $t failed"
    (cd "$TMP" && unzip -qo "$t.zip") || die "unzip $t failed"
    install -m755 "$TMP/$t" "$BIN/$t"
  done
  rm -rf "$TMP"
  say "installed $("$BIN/ffmpeg" -version | head -1 | cut -c1-60)"
fi
"$BIN/ffmpeg" -hide_banner -encoders 2>/dev/null | grep -q h264_videotoolbox \
  || say "WARNING: h264_videotoolbox not reported by this ffmpeg - hardware encode may be unavailable"

# --- 2. yt-dlp ---------------------------------------------------------------
PY=$(command -v python3) || die "python3 not found (install Xcode Command Line Tools: xcode-select --install)"
if ! "$PY" -m yt_dlp --version >/dev/null 2>&1; then
  say "installing yt-dlp for $PY"
  "$PY" -m pip install --user --quiet --disable-pip-version-check yt-dlp || die "pip install yt-dlp failed"
fi
YTB=$("$PY" -c 'import sysconfig;print(sysconfig.get_path("scripts","posix_user"))' 2>/dev/null)
if [[ -x "$YTB/yt-dlp" ]]; then ln -sf "$YTB/yt-dlp" "$BIN/yt-dlp"
else
  # fallback wrapper if the console script is elsewhere
  printf '#!/bin/zsh\nexec "%s" -m yt_dlp "$@"\n' "$PY" > "$BIN/yt-dlp"; chmod +x "$BIN/yt-dlp"
fi
say "yt-dlp $("$BIN/yt-dlp" --version 2>/dev/null)"

# --- 3. PATH -----------------------------------------------------------------
grep -q '\.local/bin' "$HOME/.zshrc" 2>/dev/null || {
  printf '\n# user-installed tools\nexport PATH="$HOME/.local/bin:$PATH"\n' >> "$HOME/.zshrc"
  say "added ~/.local/bin to PATH in ~/.zshrc"
}

# --- 4. scripts, config, playlist ----------------------------------------------
chmod +x "$BASE"/bin/*.sh "$BASE"/bin/*.py 2>/dev/null
[[ -f "$BASE/conf/stream.env" ]] || die "conf/stream.env missing - copy it from the source machine"
chmod 600 "$BASE/conf/stream.env"
if [[ -d "$BASE/MP3" ]]; then
  # playlist paths are absolute; rebuild for this machine
  "$BASE/bin/shuffle_playlist.sh" >/dev/null 2>&1 && say "playlist rebuilt for this machine"
else
  say "WARNING: no MP3 folder - stream will run with SILENT audio until you add one"
fi
# make the reader start from the configured camera, then let discovery take over
grep -q '^YT_KEY="."' "$BASE/conf/stream.env" 2>/dev/null || say "WARNING: YT_KEY looks empty in conf/stream.env"

# --- 5. LaunchAgents (written fresh with this user's HOME) ----------------------
write_plist() {
  local label="$1" script="$2" ptype="$3" throttle="$4" out="$LA/$label.plist"
  cat > "$out" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$label</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/zsh</string>
    <string>$BASE/bin/$script</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>$throttle</integer>
  <key>StandardOutPath</key><string>$LOGS/${script%.sh}.out.log</string>
  <key>StandardErrorPath</key><string>$LOGS/${script%.sh}.err.log</string>
  <key>ProcessType</key><string>$ptype</string>
</dict>
</plist>
EOF
  plutil -lint "$out" >/dev/null || die "bad plist $out"
  say "wrote $out"
}
# ProcessType MUST be Interactive for the streamer: Background is CPU-throttled by macOS.
write_plist com.user.cctv-stream  stream.sh     Interactive 10
write_plist com.user.cctv-monitor yt_monitor.sh Background  30

# --- 6. Full Disk Access check --------------------------------------------------
# A LaunchAgent cannot read ~/Downloads without FDA. Probe it the same way launchd will.
cat > "$LA/com.user.fdaprobe.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>com.user.fdaprobe</string>
<key>ProgramArguments</key><array><string>/bin/zsh</string><string>-c</string>
<string>head -c 1 "$BASE/bin/stream.sh" >/dev/null 2>&1 && echo OK > /tmp/ytlive_fda || echo DENIED > /tmp/ytlive_fda</string></array>
<key>RunAtLoad</key><true/></dict></plist>
EOF
rm -f /tmp/ytlive_fda
launchctl unload "$LA/com.user.fdaprobe.plist" 2>/dev/null
launchctl load -w "$LA/com.user.fdaprobe.plist" 2>/dev/null; sleep 3
launchctl unload "$LA/com.user.fdaprobe.plist" 2>/dev/null; rm -f "$LA/com.user.fdaprobe.plist"
FDA=$(cat /tmp/ytlive_fda 2>/dev/null); rm -f /tmp/ytlive_fda
if [[ "$FDA" == "OK" ]]; then
  say "Full Disk Access: OK (launchd can read $BASE)"
else
  say "Full Disk Access: NOT granted. launchd cannot read ~/Downloads until you add /bin/zsh:"
  say "   System Settings > Privacy & Security > Full Disk Access > + > Cmd+Shift+G > /bin/zsh"
fi

# --- 7. start? ---------------------------------------------------------------------
if [[ "$START" == "yes" ]]; then
  [[ "$FDA" == "OK" ]] || die "refusing to start: grant Full Disk Access to /bin/zsh first, then run ./install.sh --start"
  say "starting services (remember: only ONE machine per YouTube stream key)"
  for l in com.user.cctv-stream com.user.cctv-monitor; do
    launchctl unload "$LA/$l.plist" 2>/dev/null; launchctl load -w "$LA/$l.plist" && say "loaded $l"
  done
  sleep 8; launchctl list | grep cctv
else
  say "installed but NOT started. When ready (and the other machine is NOT streaming):"
  say "   ./install.sh --start        or:   launchctl load -w $LA/com.user.cctv-stream.plist"
fi
say "done. Status any time:  $BASE/bin/status.sh"
