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
#    - YouTube Studio: the stream key in conf/stream.env. Auto-start AND auto-stop are both
#      forced ON by every broadcast this project creates (bin/yt_api.py _create_and_bind), and
#      that is what lets YouTube close and archive a broadcast when ingest stops. Leave them.
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
  say "note: running from $BASE (the project expects ~/Downloads/YTLive, because the launchd job needs Full Disk Access to read it)."
# Export BASE so every helper that this script runs - shuffle_playlist.sh, cam_ip.py and the
# others - operates on THIS tree. They all default to $HOME/Downloads/YTLive, so without this a
# checkout in any other directory would rebuild its playlist from, and resolve its camera in,
# the wrong place. That failure used to be swallowed by >/dev/null.
export BASE

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
  # These are UNPINNED "latest" static builds fetched over TLS with no signature, and this host
  # then hands the binary the stream key and the camera feed - a real supply-chain exposure.
  # Set FFMPEG_SHA256 / FFPROBE_SHA256 to the digests you expect and the archive is verified and
  # rejected on mismatch. Leave them unset and the installer says plainly that it verified
  # nothing; it never claims a check it did not perform.
  for t in ffmpeg ffprobe; do
    say "downloading $t (evermeet.cx static build, unpinned)"
    curl -fL --retry 3 -o "$TMP/$t.zip" "https://evermeet.cx/ffmpeg/get/$([[ $t == ffprobe ]] && echo ffprobe/)zip" \
      || die "download of $t failed"
    want=""
    [[ "$t" == ffmpeg  ]] && want="${FFMPEG_SHA256:-}"
    [[ "$t" == ffprobe ]] && want="${FFPROBE_SHA256:-}"
    if [[ -n "$want" ]]; then
      got=$(shasum -a 256 "$TMP/$t.zip" | awk '{print $1}')
      [[ "$got" == "$want" ]] || die "$t.zip digest mismatch: expected $want, got $got - refusing to install it"
      say "$t.zip digest verified"
    else
      say "NOTE: $t.zip NOT verified (no digest supplied for $t) - this is an unpinned upstream build"
    fi
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
# A fresh clone has no conf/stream.env (it is gitignored - it holds the stream key). Dying here
# used to abort the install before the LaunchAgents and the playlist were written, so a clean
# clone could never be installed at all. Seed it from the tracked example instead and let the
# operator fill it in; --start still refuses until a key exists.
if [[ ! -f "$BASE/conf/stream.env" ]]; then
  if [[ -f "$BASE/conf/stream.env.example" ]]; then
    cp "$BASE/conf/stream.env.example" "$BASE/conf/stream.env"
    say "created conf/stream.env from the example - it has NO stream key and NO OAuth token yet"
  else
    die "conf/stream.env is missing and there is no conf/stream.env.example to seed it from"
  fi
fi
chmod 600 "$BASE/conf/stream.env"
# The refresh token grants CONTROL of the channel, so it gets the same 0600 as the stream key.
# install.sh used to chmod only stream.env and leave this one to whatever yt_api.py had set.
[[ -f "$BASE/conf/yt_oauth.json" ]] && chmod 600 "$BASE/conf/yt_oauth.json"
if [[ -d "$BASE/MP3" ]]; then
  # playlist paths are absolute; rebuild for this machine
  if "$BASE/bin/shuffle_playlist.sh" >/dev/null 2>&1; then
    say "playlist rebuilt for this machine"
  else
    say "WARNING: could not rebuild conf/playlist.txt (run bin/shuffle_playlist.sh to see why). The tracked playlist points at another machine's home and will not work here."
  fi
else
  say "WARNING: no MP3 folder - stream will run with SILENT audio until you add one"
fi
# Detect an empty key correctly. The old pattern '^YT_KEY="."' required exactly one character
# between the quotes, so every REAL key (which is far longer) failed to match and the installer
# warned "YT_KEY looks empty" on a perfectly good config.
YTLINE=$(grep -E '^YT_KEY=' "$BASE/conf/stream.env" 2>/dev/null | head -1)
YT_EMPTY=no
[[ -z "$YTLINE" || "$YTLINE" == 'YT_KEY=""' || "$YTLINE" == "YT_KEY=''" ]] && YT_EMPTY=yes
[[ "$YT_EMPTY" == yes ]] && say "WARNING: YT_KEY is empty in conf/stream.env - YouTube will reject the ingest until you paste the stream key in"

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
# Standard, not Background: macOS CPU-throttles Background jobs and every check of the
# watchdog spawns yt-dlp and ffmpeg.
write_plist com.user.cctv-monitor yt_monitor.sh Standard    30

# --- 6. Full Disk Access check --------------------------------------------------
# A LaunchAgent cannot read ~/Downloads without FDA. Probe it the same way launchd will.
FDADIR=$(mktemp -d "${TMPDIR:-/tmp}/ytlive-fda.XXXXXX") || die "mktemp -d failed"
FDAFILE="$FDADIR/result"
cat > "$LA/com.user.fdaprobe.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>com.user.fdaprobe</string>
<key>ProgramArguments</key><array><string>/bin/zsh</string><string>-c</string>
<string>cat "$BASE/bin/stream.sh" >/dev/null 2>&1 && cat "$BASE/conf/stream.env" >/dev/null 2>&1 && echo OK > "$FDAFILE" || echo DENIED > "$FDAFILE"</string></array>
<key>RunAtLoad</key><true/></dict></plist>
EOF
# /tmp is world-writable and the old probe wrote a FIXED filename there. Any local user could
# pre-create it mode 444 (the sticky bit then stops our rm and our write) and hand the installer
# an "OK" it never earned - or symlink it and have this user's shell truncate an arbitrary file.
# A mktemp -d directory is 0700 and owned by us, so nothing outside this account can plant a
# result. The probe now reads the whole config too, not one byte.
launchctl unload "$LA/com.user.fdaprobe.plist" 2>/dev/null
launchctl load -w "$LA/com.user.fdaprobe.plist" 2>/dev/null; sleep 3
launchctl unload "$LA/com.user.fdaprobe.plist" 2>/dev/null; rm -f "$LA/com.user.fdaprobe.plist"
FDA=$(cat "$FDAFILE" 2>/dev/null); rm -rf "$FDADIR"
if [[ "$FDA" == "OK" ]]; then
  say "Full Disk Access: OK (launchd can read $BASE)"
else
  say "Full Disk Access: NOT granted. launchd cannot read ~/Downloads until you add /bin/zsh:"
  say "   System Settings > Privacy & Security > Full Disk Access > + > Cmd+Shift+G > /bin/zsh"
fi

# --- 7. start? ---------------------------------------------------------------------
if [[ "$START" == "yes" ]]; then
  [[ "$FDA" == "OK" ]] || die "refusing to start: grant Full Disk Access to /bin/zsh first, then run ./install.sh --start"
  [[ "$YT_EMPTY" == yes ]] && die "refusing to start: YT_KEY is empty in conf/stream.env - paste your YouTube stream key in first"
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
