#!/bin/zsh
# t06: install.sh actually RUNS, in a sandbox with fake interpreters
#
# The suite only syntax-checked install.sh, which is how a fatal `set -u` abort inside
# write_plist shipped in 2.0: the installer could never complete on any machine, the
# 2026-09-17 deploy failed on it, and no gate noticed. A syntax check cannot catch that.
#
# Every scenario here runs in a throwaway tree with its own HOME, PATH and fake interpreters,
# so it can never reach the real ~/.local/bin, ~/Library/LaunchAgents or the live stream.
set -u
source "${0:A:h}/lib.sh"

SB=$(mktemp -d "$TMPROOT/install.XXXXXX")
REPO="$SB/repo"
SHOME="$SB/home"
PYDIR="$SB/pythons"
BIN="$SHOME/.local/bin"
LA="$SHOME/Library/LaunchAgents"
mkdir -p "$REPO/bin" "$REPO/conf" "$REPO/log" "$BIN" "$LA" "$PYDIR"

cp "$REPO_DIR/install.sh" "$REPO/install.sh"; chmod +x "$REPO/install.sh"
cp "$REPO_DIR/conf/stream.env.example" "$REPO/conf/" 2>/dev/null
# ffmpeg/ffprobe already present, so install.sh never touches the network.
for t in ffmpeg ffprobe; do
  printf '#!/bin/zsh\nexit 0\n' > "$BIN/$t"; chmod +x "$BIN/$t"
done

# mkpy NAME VERSION_INT YTDLP_VER_OR_EMPTY PIP_WOULD_INSTALL_VER
# A fake python3 that answers the four questions install.sh asks it.
mkpy() {
  local name="$1" ver="$2" ytv="$3" pipv="$4"
  local d="$PYDIR/$name"
  mkdir -p "$d/scripts"
  cat > "$d/python3" <<EOF
#!/bin/zsh
for a in "\$@"; do
  case "\$a" in
    *sys.version_info*)   print -r -- "$ver"; exit 0 ;;
    *sysconfig.get_path*) print -r -- "$d/scripts"; exit 0 ;;
  esac
done
case "\$*" in
  *"-m yt_dlp"*)      [[ -n "$ytv" ]] && { print -r -- "$ytv"; exit 0; } || exit 1 ;;
  *"-m pip install"*) print -r -- "#!/bin/zsh" > "$d/scripts/yt-dlp"
                      print -r -- "print -r -- '$pipv'" >> "$d/scripts/yt-dlp"
                      chmod +x "$d/scripts/yt-dlp"; exit 0 ;;
esac
exit 1
EOF
  chmod +x "$d/python3"
  if [[ -n "$ytv" ]]; then
    printf '#!/bin/zsh\nprint -r -- "%s"\n' "$ytv" > "$d/scripts/yt-dlp"
    chmod +x "$d/scripts/yt-dlp"
  fi
}

# run_install SEARCH_DIRS  -> stdout+stderr; exit status in $?
# env -i gives a clean environment; STUBS goes FIRST so the launchctl stub shadows the real one.
run_install() {
  env -i HOME="$SHOME" PATH="$STUBS:/usr/bin:/bin:/usr/sbin:/sbin" \
        YT_PY_SEARCH="$1" TERM=dumb /bin/zsh "$REPO/install.sh" 2>&1
}

# ============================================================================
t_begin "install.sh completes at all (the set -u abort in write_plist)"
# The exact shape of the production machine on 2026-09-17: a new interpreter that already has
# yt-dlp, and an old one that does not.
mkpy new314 314 2026.08.19 2026.08.19
mkpy old39  309 ""         2025.10.14
# ...and a working yt-dlp already in place, which the installer must not destroy.
printf '#!/bin/zsh\nprint -r -- "2026.08.19"\n' > "$BIN/yt-dlp"; chmod +x "$BIN/yt-dlp"

OUT=$(run_install "$PYDIR/new314:$PYDIR/old39"); RC=$?

t_assert_eq "0" "$RC" "install.sh exits 0 (old code died here with 'label: parameter not set')"
t_assert_contains "$OUT" "using python: $PYDIR/new314/python3" "picks the interpreter that already has yt-dlp, not the first PATH entry"
t_assert_contains "$OUT" "yt-dlp 2026.08.19" "the working yt-dlp survives the install"

# ============================================================================
t_begin "both LaunchAgents are written and are valid plists"
for l in com.user.cctv-stream com.user.cctv-monitor; do
  t_assert_file "$LA/$l.plist" "$l.plist written"
done
t_assert_eq "" "$(plutil -lint "$LA/com.user.cctv-stream.plist" 2>&1 | grep -v 'OK$' | head -1)" "stream plist passes plutil -lint"
t_assert_eq "" "$(plutil -lint "$LA/com.user.cctv-monitor.plist" 2>&1 | grep -v 'OK$' | head -1)" "monitor plist passes plutil -lint"
t_assert_contains "$(plutil -p "$LA/com.user.cctv-stream.plist" 2>/dev/null)" "Interactive" "stream plist keeps ProcessType Interactive (Background would be CPU-throttled)"
t_assert_contains "$(plutil -p "$LA/com.user.cctv-monitor.plist" 2>/dev/null)" "Standard" "monitor plist keeps ProcessType Standard"
t_assert_contains "$(plutil -p "$LA/com.user.cctv-stream.plist" 2>/dev/null)" "$REPO/bin/stream.sh" "stream plist points at THIS tree"
t_assert_no_file "$LA/com.user.fdaprobe.plist" "the temporary FDA-probe plist is cleaned up"

# ============================================================================
t_begin "a fresh machine installs yt-dlp for the NEWEST interpreter"
rm -f "$BIN/yt-dlp"
mkpy fresh309 309 "" 2025.10.14
mkpy fresh314 314 "" 2026.08.19
OUT=$(run_install "$PYDIR/fresh309:$PYDIR/fresh314"); RC=$?
t_assert_eq "0" "$RC" "fresh install exits 0"
t_assert_file "$PYDIR/fresh314/scripts/yt-dlp" "yt-dlp was installed for the 3.14 interpreter"
t_assert_no_file "$PYDIR/fresh309/scripts/yt-dlp" "yt-dlp was NOT installed for the 3.9 interpreter"
t_assert_eq "2026.08.19" "$("$BIN/yt-dlp" --version 2>/dev/null)" "the linked yt-dlp is the current one"
t_assert_contains "$OUT" "using python: $PYDIR/fresh314/python3" "reports the 3.14 interpreter"

# ============================================================================
t_begin "an OLDER candidate never downgrades a working yt-dlp"
printf '#!/bin/zsh\nprint -r -- "2026.08.19"\n' > "$BIN/yt-dlp"; chmod +x "$BIN/yt-dlp"
mkpy only310 310 "" 2025.10.14
OUT=$(run_install "$PYDIR/only310"); RC=$?
t_assert_eq "0" "$RC" "install still exits 0"
t_assert_contains "$OUT" "keeping the existing" "refuses to replace a newer yt-dlp with an older one"
t_assert_eq "2026.08.19" "$("$BIN/yt-dlp" --version 2>/dev/null)" "the working yt-dlp is still 2026.08.19"

# ============================================================================
t_begin "conf/stream.env is seeded from the tracked example on a fresh clone"
rm -f "$REPO/conf/stream.env"
OUT=$(run_install "$PYDIR/new314"); RC=$?
t_assert_file "$REPO/conf/stream.env" "stream.env created from the example"
t_assert_contains "$OUT" "created conf/stream.env from the example" "and says so"

rm -rf "$SB"
t_summary
