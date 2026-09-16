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
# Choose the interpreter deliberately. Do NOT trust PATH order, and do NOT overwrite a
# working yt-dlp with a worse one.
#
# What this replaces, and why: `PY=$(command -v python3)` took whatever came first on PATH.
# On 2026-09-17 that was /usr/bin/python3 - the Xcode Command Line Tools 3.9.6 - while a
# current python.org 3.14 was installed alongside it. pip therefore resolved yt-dlp to the
# last release that still supports 3.9 (2025.10.14), which can no longer parse YouTube's live
# page, and the `ln -sf` below put that stale build on top of a working ~/.local/bin/yt-dlp
# (2026.08.19 via 3.14). The monitor went blind, and because the damage was outside the
# project tree the deploy's rollback reported success while leaving it broken.
py_ver()   { "$1" -c 'import sys;print("%d%02d" % sys.version_info[:2])' 2>/dev/null; }
has_ytdlp() { "$1" -m yt_dlp --version >/dev/null 2>&1; }

# Search PATH *plus* the places a python.org or Homebrew install actually lands. PATH alone is
# not enough: a launchd or ssh shell often has a bare PATH that does not include /usr/local/bin,
# which is exactly where the usable interpreter lives on this machine. YT_PY_SEARCH overrides the
# whole list (colon-separated) to force one interpreter.
typeset -a SEARCH; SEARCH=()
if [[ -n "${YT_PY_SEARCH:-}" ]]; then
  SEARCH=(${(s.:.)YT_PY_SEARCH})
else
  SEARCH=(${(s.:.)PATH})
  SEARCH+=(/usr/local/bin /opt/homebrew/bin "$HOME/.local/bin" /usr/bin)
  SEARCH+=(/Library/Frameworks/Python.framework/Versions/*/bin(N))
fi
SEARCH=(${(u)SEARCH})

typeset -a CAND; CAND=()
for d in "${SEARCH[@]}"; do
  [[ -n "$d" ]] || continue
  for n in python3 python3.14 python3.13 python3.12 python3.11 python3.10; do
    [[ -x "$d/$n" ]] && CAND+=("$d/$n")
  done
done
CAND=(${(u)CAND})
[[ ${#CAND} -eq 0 ]] && die "no python3 found - install the Xcode Command Line Tools, or python.org 3.10+"

BEST_PY=""; BEST_VER=0; FALLBACK_PY=""; FALLBACK_VER=0
for p in "${CAND[@]}"; do
  v=$(py_ver "$p"); [[ "$v" == <-> ]] || continue
  (( v > FALLBACK_VER )) && { FALLBACK_PY="$p"; FALLBACK_VER=$v; }
  if has_ytdlp "$p"; then
    (( v > BEST_VER )) && { BEST_PY="$p"; BEST_VER=$v; }
  fi
done

if [[ -z "$BEST_PY" ]]; then
  # Nothing has yt_dlp yet. Try the NEWEST interpreters first, and fall THROUGH on refusal:
  # pip on 3.9 resolves to an old yt-dlp, and a Homebrew python rejects --user installs
  # outright (PEP 668: "externally-managed-environment"). Stopping at the first refusal would
  # fail on a machine that has a perfectly good python.org interpreter sitting next to it.
  pairs=""
  for p in "${CAND[@]}"; do
    v=$(py_ver "$p"); [[ "$v" == <-> ]] || continue
    (( v >= 310 )) || continue
    pairs+="$v $p"$'\n'
  done
  for line in ${(f)"$(print -r -- "$pairs" | sort -rn)"}; do
    [[ -z "$line" ]] && continue
    cand="${line#* }"
    [[ -x "$cand" ]] || continue
    say "installing yt-dlp for $cand"
    if "$cand" -m pip install --user --quiet --disable-pip-version-check yt-dlp 2>/dev/null; then
      BEST_PY="$cand"; break
    fi
    say "  pip refused for $cand - trying the next interpreter"
  done
  if [[ -z "$BEST_PY" ]]; then
    # Last resort - and say plainly what it costs, rather than quietly handing the monitor
    # something that will never answer. A 3.9 yt-dlp can no longer parse YouTube's live page.
    BEST_PY="$FALLBACK_PY"
    say "WARNING: no Python >= 3.10 could install yt-dlp. Falling back to $("$BEST_PY" -V 2>&1)."
    say "         pip on 3.9 installs an OLD yt-dlp that CANNOT parse YouTube, so the monitor"
    say "         will report UNKNOWN and suspend picture checking. The stream itself is fine."
    say "         Fix it by installing python.org 3.12+ and re-running this installer."
    "$BEST_PY" -m pip install --user --quiet --disable-pip-version-check yt-dlp \
      || die "pip install yt-dlp failed for every interpreter tried"
  fi
fi
PY="$BEST_PY"
say "using python: $PY ($("$PY" -V 2>&1))"

YTB=$("$PY" -c 'import sysconfig;print(sysconfig.get_path("scripts","posix_user"))' 2>/dev/null)
NEWTARGET="${YTB:-/nonexistent}/yt-dlp"
new_ver=""; [[ -x "$NEWTARGET" ]] && new_ver=$("$NEWTARGET" --version 2>/dev/null)
old_ver=""; [[ -x "$BIN/yt-dlp" ]] && old_ver=$("$BIN/yt-dlp" --version 2>/dev/null)

# yt-dlp versions are zero-padded dates (2026.08.19), so a string compare orders them correctly.
if [[ -n "$old_ver" ]] && { [[ -z "$new_ver" ]] || [[ "$old_ver" > "$new_ver" ]]; }; then
  say "keeping the existing $BIN/yt-dlp $old_ver (this python offers ${new_ver:-nothing better})"
else
  [[ -e "$BIN/yt-dlp" ]] && cp -P "$BIN/yt-dlp" "$BIN/yt-dlp.old" 2>/dev/null
  if [[ -x "$NEWTARGET" ]]; then
    ln -sf "$NEWTARGET" "$BIN/yt-dlp"
  else
    # fallback wrapper if the console script is elsewhere
    printf '#!/bin/zsh\nexec "%s" -m yt_dlp "$@"\n' "$PY" > "$BIN/yt-dlp"; chmod +x "$BIN/yt-dlp"
  fi
  got=$("$BIN/yt-dlp" --version 2>/dev/null || true)
  if [[ -z "$got" ]]; then
    if [[ -e "$BIN/yt-dlp.old" ]]; then
      say "WARNING: the new yt-dlp does not run - restoring the previous one ($old_ver)"
      mv -f "$BIN/yt-dlp.old" "$BIN/yt-dlp"
    else
      die "yt-dlp at $BIN/yt-dlp does not run, and there was nothing to fall back to"
    fi
  else
    say "yt-dlp $got"
  fi
fi

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
  # One `local` per line, deliberately. A shell expands ALL of a command's arguments before
  # the command runs, so `local label="$1" ... out="$LA/$label.plist"` reads $label while it is
  # still unset - and under `set -u` that aborts the whole install with
  # "write_plist:1: label: parameter not set". This bit the 2026-09-17 deploy: install.sh could
  # never complete, and the release gate never noticed because the test suite only syntax-checks
  # this file. Verified: splitting the declaration fixes it in both zsh and bash.
  local label="$1"
  local script="$2"
  local ptype="$3"
  local throttle="$4"
  local out="$LA/$label.plist"
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
