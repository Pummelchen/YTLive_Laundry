#!/bin/zsh
# t12 - bin/deploy-release.sh: the dry run and tooling checks, and a rollback that restores the
# out-of-tree half (including the PARTIAL ROLLBACK path) without touching real machine state.
#
# The script itself only ever ran for real once, on 2026-09-17, and "it worked" is a data point,
# not a test. This file builds a scratch world - a fake HOME, a fake BASE tree, and fake
# git/sleep/pgrep ahead of the real ones on PATH - and drives the parts that can be driven without
# risk:
#
#   * argument handling, which exits before anything is created;
#   * --dry-run, which must leave the tree and the out-of-tree state byte-for-byte unchanged;
#   * ytdlp_works(), the check that catches a yt-dlp which exists but can no longer SEE the stream
#     (the 2026-09-17 rollback restored the tree while leaving a blinded yt-dlp in place);
#   * rollback(), extracted with t_extract_fn and run in a subshell, for both the complete restore
#     and the PARTIAL ROLLBACK branch;
#   * --wait-for-cut, which had never been exercised: a state=offline line dated just ahead of the
#     loop's start_epoch makes the real detection fire, and from there the run enters the real
#     deploy steps - the fake git refuses `checkout`, so it lands in rollback, still entirely
#     inside the scratch tree.
#
# What is deliberately NOT exercised: `--go` for real, the 10-hour no-rotation deadline branch,
# the real launchctl, and any real network. The kill switch is tested by engaging it and asserting
# the refusal happens before any backup. A tripwire install.sh proves ./install.sh is never reached.
#
# The real ~/Downloads/YTLive, ~/.local/bin and ~/Library/LaunchAgents are never touched: BASE and
# HOME are siblings inside tests/.tmp, and the fakebin is local to this test (tests/stubs is global
# and must not gain anything that changes another test).
source "${0:A:h}/lib.sh"
t_begin t12

t_setup >/dev/null

SCRIPT="$REPO_DIR/bin/deploy-release.sh"

# ---------------------------------------------------------------------------------------------
# Scratch world. BASE and HOME are SIBLINGS: the script backs the tree up into a job dir under
# HOME, so if HOME sat inside BASE the `cp -a "$BASE" "$JOB/tree"` would recurse into its own
# destination. Nothing below is a real path.
# ---------------------------------------------------------------------------------------------
W="$T_BASE/w"
BASE_DIR="$W/base"
HOME_DIR="$W/home"
FAKEBIN="$W/fakebin"
BIN_DIR="$HOME_DIR/.local/bin"
LA_DIR="$HOME_DIR/Library/LaunchAgents"
mkdir -p "$BASE_DIR/bin" "$BASE_DIR/conf" "$BASE_DIR/log" "$BASE_DIR/.git" \
         "$HOME_DIR" "$FAKEBIN" "$BIN_DIR" "$LA_DIR"

cp "$SCRIPT" "$BASE_DIR/bin/deploy-release.sh"
cp "$T_BASE/conf/stream.env" "$BASE_DIR/conf/stream.env"
print -r -- '{"fake":true}' > "$BASE_DIR/conf/yt_oauth.json"
print -r -- '{"fake":true}' > "$BASE_DIR/conf/broadcast_template.json"
print -r -- '1.0' > "$BASE_DIR/VERSION"

# A yt-dlp that answers the way a working one does: an id for the live page, a version for --version.
cat > "$BIN_DIR/yt-dlp" <<'YT'
#!/bin/zsh
for a in "$@"; do
  [[ "$a" == "--version" ]] && { print -r -- "2026.08.19"; exit 0; }
done
print -r -- "dQw4w9WgXcQ"
YT
chmod +x "$BIN_DIR/yt-dlp"
cp "$BIN_DIR/yt-dlp" "$W/ytdlp.good"

# Scratch fake git. It records every call, answers the read-only questions the preflight asks, and
# makes `checkout` FAIL so no test can ever reach ./install.sh. The real repository is never read
# or written: `git rev-parse` is answered by this script, not by /usr/bin/git.
cat > "$FAKEBIN/git" <<'GIT'
#!/bin/zsh
print -r -- "git $*" >> "${FAKE_GIT_LOG:-/dev/null}"
case "$*" in
  *"^{commit}"*) print -r -- "1111111111111111111111111111111111111111"; exit 0 ;;
esac
case "$*" in
  rev-parse*--verify*) exit 0 ;;
  rev-parse*--short*)  print -r -- "1111111"; exit 0 ;;
  "rev-parse HEAD")    print -r -- "1111111111111111111111111111111111111111"; exit 0 ;;
esac
exit 1
GIT
printf '#!/bin/zsh\nexit 0\n' > "$FAKEBIN/sleep"   # stop_agents/rollback sleeps -> instant
printf '#!/bin/zsh\nexit 1\n' > "$FAKEBIN/pgrep"   # publisher_up must never look at real ffmpeg
chmod +x "$FAKEBIN/git" "$FAKEBIN/sleep" "$FAKEBIN/pgrep"

export PATH="$FAKEBIN:$PATH"   # never anything but tests/stubs and the system tools
GITLOG="$W/git.log"
LASTOUT="$W/last.out"

# Content signature of the tracked tree. `log/` is excluded because the GLOBAL launchctl stub
# records its own calls into $BASE/log/stub_launchctl.calls - that file is the test harness's
# writing, not the script's, and the script's only launchctl call here is a read-only `list`.
tree_sig() { ( cd "$1" && find . -type f -not -path './log/*' -exec cksum {} + ) 2>/dev/null | sort; }

# run_deploy ARGS -> output in $LASTOUT, exit status in $?. The absolute /bin/sleep is insurance:
# the script tees through a process substitution, and the fake sleep above is a no-op.
run_deploy() {
  : > "$GITLOG"
  BASE="$BASE_DIR" HOME="$HOME_DIR" FAKE_GIT_LOG="$GITLOG" \
    PATH="$FAKEBIN:$STUBS:$PATH" \
    /bin/zsh "$BASE_DIR/bin/deploy-release.sh" "$@" > "$LASTOUT" 2>&1
  local rc=$?
  /bin/sleep 0.1
  return $rc
}
out() { cat "$LASTOUT"; }

mkytdlp() {   # mkytdlp FILE 'zsh-line'
  local f="$1"
  print -r -- '#!/bin/zsh' > "$f"
  print -r -- "$2" >> "$f"
  chmod +x "$f"
}

YTROOT="$W/fake-ytdlp"
mkdir -p "$YTROOT"

# =============================================================================================
t_begin "t12: bad arguments exit before anything is created"
run_deploy --tag v1 --bogus; rc=$?
t_assert_eq 2 $rc "an unknown argument exits 2"
t_assert_contains "$(out)" "unknown argument: --bogus" "and names the argument"
run_deploy --dry-run; rc=$?
t_assert_eq 2 $rc "a missing --tag exits 2"
t_assert_contains "$(out)" "usage:" "and prints the usage line"
job_dirs=( "$HOME_DIR"/ytlive-deploy-*(N) )
t_assert_eq 0 "${#job_dirs}" "neither bad invocation created a job directory"

# =============================================================================================
t_begin "t12: --dry-run changes nothing"
sig_before=$(tree_sig "$BASE_DIR")
bin_before=$(cat "$BIN_DIR/yt-dlp")
run_deploy --tag v1; rc=$?
DU=$(out)
t_assert_eq 0 $rc "a dry run exits 0"
t_assert_contains "$DU" "mode=--dry-run" "the default mode is the dry run (no flag needed)"
t_assert_contains "$DU" "DRY RUN OK" "and it says the dry run is OK"
t_assert_contains "$DU" "would back up : $BASE_DIR, $BIN_DIR, $LA_DIR" "and lists BOTH halves it would back up"
t_assert_contains "$DU" "resolves the live page: yes" "and confirms yt-dlp can resolve the live page"
t_assert_eq "$sig_before" "$(tree_sig "$BASE_DIR")" "the checkout is byte-for-byte unchanged"
t_assert_eq "$bin_before" "$(cat "$BIN_DIR/yt-dlp")" "the out-of-tree yt-dlp is unchanged"
# It does create its own job dir + log under HOME. That is the only write, and it must contain no backup.
jobdir_arr=( "$HOME_DIR"/ytlive-deploy-*(N/) )
t_assert_eq 1 "${#jobdir_arr}" "the only thing it creates is its own job directory"
if (( ${#jobdir_arr} )); then
  t_assert_no_file "${jobdir_arr[1]}/tree" "and it took no tree backup"
  t_assert_no_file "${jobdir_arr[1]}/dot-local-bin" "and no out-of-tree backup"
fi
lcalls="$BASE_DIR/log/stub_launchctl.calls"
if [[ -f "$lcalls" ]] && grep -qE 'bootout|bootstrap|enable|load' "$lcalls"; then
  t_bad "the dry run only queried launchctl (found a destructive call)"
else
  t_ok "the dry run only queried launchctl; it changed no agent"
fi
if grep -q 'checkout' "$GITLOG" 2>/dev/null; then
  t_bad "the dry run never ran git checkout"
else
  t_ok "the dry run never ran git checkout"
fi

# =============================================================================================
t_begin "t12: ytdlp_works catches a yt-dlp that exists but cannot see the stream"
YFUNC=$(t_extract_fn "$SCRIPT" ytdlp_works)
if [[ -z "$YFUNC" ]]; then
  t_bad "could not extract ytdlp_works from deploy-release.sh"
else
  t_ok "extracted ytdlp_works from deploy-release.sh"
  eval "$YFUNC"
  LIVE_URL="https://example.invalid/@x/live"
  mkytdlp "$YTROOT/good"  'print -r -- "dQw4w9WgXcQ"'
  mkytdlp "$YTROOT/empty" 'exit 0'
  mkytdlp "$YTROOT/blind" 'print -r -- "ERROR: unable to download API page: HTTP Error 429"'
  mkytdlp "$YTROOT/url"   'print -r -- "https://example.invalid/watch?v=dQw4w9WgXcQ"'
  mkytdlp "$YTROOT/fail"  'exit 1'
  print -r -- '#!/bin/zsh' > "$YTROOT/noexec"   # deliberately not executable

  YTDLP="$YTROOT/good";  if ytdlp_works; then t_ok "a yt-dlp that prints an id passes"; else t_bad "a yt-dlp that prints an id passes"; fi
  YTDLP="$YTROOT/empty"; if ytdlp_works; then t_bad "empty output is blind"; else t_ok "empty output is blind"; fi
  YTDLP="$YTROOT/blind"; if ytdlp_works; then t_bad "an ERROR line is blind despite exit 0"; else t_ok "an ERROR line is blind despite exit 0"; fi
  YTDLP="$YTROOT/url";   if ytdlp_works; then t_bad "a URL instead of an id is blind"; else t_ok "a URL instead of an id is blind"; fi
  YTDLP="$YTROOT/fail";  if ytdlp_works; then t_bad "a non-zero exit is blind"; else t_ok "a non-zero exit is blind"; fi
  YTDLP="$YTROOT/noexec"; if ytdlp_works; then t_bad "a non-executable yt-dlp is blind"; else t_ok "a non-executable yt-dlp is blind"; fi
  YTDLP="$YTROOT/absent"; if ytdlp_works; then t_bad "a missing yt-dlp is blind"; else t_ok "a missing yt-dlp is blind"; fi
fi

# ...and the real script must warn about it in the preflight, without aborting the dry run.
mkytdlp "$BIN_DIR/yt-dlp" 'print -r -- "ERROR: unable to download API page: HTTP Error 429"'
run_deploy --tag v1; rc=$?
t_assert_contains "$(out)" "already blind" "the preflight warns that a blinded yt-dlp means the monitor is already blind"
t_assert_contains "$(out)" "DRY RUN OK" "and the dry run still completes (a blind tool is a warning, not an abort)"
cp "$W/ytdlp.good" "$BIN_DIR/yt-dlp"

SRC=$(cat "$SCRIPT")
t_assert_contains "$SRC" 'ytdlp_works || fail="$fail yt-dlp-blind"' "the verify step fails the deploy on a blinded yt-dlp (inline block, asserted from source)"
t_assert_contains "$SRC" "no Python >= 3.10" "the interpreter scan warns below 3.10 (machine-dependent, asserted from source)"

# =============================================================================================
t_begin "t12: rollback restores the tree AND the out-of-tree half"
RB=$(t_extract_fn "$SCRIPT" rollback)
if [[ -z "$RB" ]]; then
  t_bad "could not extract rollback from deploy-release.sh"
else
  t_ok "extracted rollback from deploy-release.sh"
fi
# Process control is stubbed: rollback()'s file moves are what is under test here. The real
# stop_agents/start_agents run, through the launchctl stub, in the --wait-for-cut section below.
say() { print -r -- "$*"; }
stop_agents() { :; }
start_agents() { :; }
jobs_loaded() { print -r -- 2; }
publisher_up() { return 1; }
eval "$RB"

RH="$W/roll/home"; RBASE="$W/roll/base"; RJOB="$W/roll/job"; RBIN="$RH/.local/bin"; RLA="$RH/Library/LaunchAgents"
mkdir -p "$RBIN" "$RLA" "$RBASE" "$RJOB/tree" "$RJOB/dot-local-bin" "$RJOB/LaunchAgents"
print -r -- POSTTREE > "$RBASE/state.txt"
print -r -- PRETREE  > "$RJOB/tree/state.txt"
print -r -- POSTBIN  > "$RBIN/state.txt"
print -r -- PREBIN   > "$RJOB/dot-local-bin/state.txt"
print -r -- POSTLA   > "$RLA/state.txt"
print -r -- PRELA    > "$RJOB/LaunchAgents/state.txt"
printf '#!/bin/zsh\nprint -r -- 2026.08.19\n' > "$RBIN/yt-dlp"; chmod +x "$RBIN/yt-dlp"

(
  HOME="$RH" BASE="$RBASE" JOB="$RJOB" BIN="$RBIN" LA="$RLA" STAMP="s1" YTDLP="$RBIN/yt-dlp"
  rollback
) > "$W/roll/full.out" 2>&1
rc=$?
RFOUT=$(cat "$W/roll/full.out")
t_assert_eq 1 $rc "rollback exits 1, so a failed deploy cannot report success"
t_assert_contains "$RFOUT" "ROLLING BACK" "it announces the rollback"
t_assert_contains "$RFOUT" "rollback done" "and reaches the complete-restore branch"
if grep -q "PARTIAL ROLLBACK" "$W/roll/full.out"; then
  t_bad "a complete rollback must not report PARTIAL"
else
  t_ok "a complete rollback does not report PARTIAL"
fi
t_assert_eq "PRETREE" "$(cat "$RBASE/state.txt")" "the tree is restored from the backup"
t_assert_eq "POSTTREE" "$(cat "$RBASE.failed-s1/state.txt")" "the failed tree is kept beside it"
t_assert_eq "PREBIN" "$(cat "$RBIN/state.txt")" "~/.local/bin is restored (the half the 2026-09-17 rollback missed)"
t_assert_eq "POSTBIN" "$(cat "$RBIN.replaced-s1/state.txt")" "the installed ~/.local/bin is kept"
t_assert_eq "PRELA" "$(cat "$RLA/state.txt")" "~/Library/LaunchAgents is restored too"
t_assert_eq "POSTLA" "$(cat "$RLA.replaced-s1/state.txt")" "the installed LaunchAgents are kept"

# =============================================================================================
t_begin "t12: a restore that fails is reported as PARTIAL, never as done"
PH="$W/part/home"; PBASE="$W/part/base"; PJOB="$W/part/job"
mkdir -p "$PH" "$PBASE" "$PJOB/tree" "$PJOB/dot-local-bin"
print -r -- POSTTREE > "$PBASE/state.txt"
print -r -- PRETREE  > "$PJOB/tree/state.txt"
print -r -- PREBIN   > "$PJOB/dot-local-bin/state.txt"
# $PH/.local deliberately does NOT exist, so `mv "$JOB/dot-local-bin" "$BIN"` cannot succeed -
# exactly the partially-restored state a rollback must not hide behind "rollback done".
(
  HOME="$PH" BASE="$PBASE" JOB="$PJOB" BIN="$PH/.local/bin" LA="$PH/Library/LaunchAgents" STAMP="s2" YTDLP="$PH/.local/bin/yt-dlp"
  rollback
) > "$W/part/out" 2>&1
rc=$?
POUT=$(cat "$W/part/out")
t_assert_eq 1 $rc "a partial rollback still exits 1"
t_assert_contains "$POUT" "PARTIAL ROLLBACK" "it says PARTIAL ROLLBACK"
t_assert_contains "$POUT" "could not restore" "and names the half it could not restore"
t_assert_contains "$POUT" "Check" "and tells the operator to check by hand"
t_assert_eq "PRETREE" "$(cat "$PBASE/state.txt")" "the tree is still restored in a partial rollback"
if grep -q "rollback done" "$W/part/out"; then
  t_bad "a partial rollback must not claim 'rollback done'"
else
  t_ok "a partial rollback never claims 'rollback done'"
fi

# =============================================================================================
t_begin "t12: the kill switch refuses --go, and --wait-for-cut detects a rotation"
# Tripwire: if the fake git ever let the run through, ./install.sh would leave a marker.
cat > "$BASE_DIR/install.sh" <<INS
#!/bin/zsh
print -r -- "INSTALL RAN" >> "$BASE_DIR/log/install_ran.marker"
exit 1
INS
chmod +x "$BASE_DIR/install.sh"

touch "$HOME_DIR/ytlive-deploy-HOLD"
run_deploy --tag v1 --go; rc=$?
t_assert_eq 1 $rc "--go refuses to proceed while the kill switch is engaged"
t_assert_contains "$(out)" "kill switch" "and names the kill switch"
t_assert_contains "$(out)" "mode=--go" "and the --go argument was recognised"
any_tree=( "$HOME_DIR"/ytlive-deploy-*/tree(N) )
t_assert_eq 0 "${#any_tree}" "the refusal happened before any tree backup"
run_deploy --tag v1; rc=$?
t_assert_eq 0 $rc "a dry run still works with the kill switch engaged (it changes nothing)"
rm -f "$HOME_DIR/ytlive-deploy-HOLD"

# A state=offline line dated just AHEAD of the loop's start_epoch makes the real detection fire on
# the first pass. From there the run enters the real deploy steps; the fake git refuses `checkout`,
# so it lands in the real rollback - all inside the scratch tree, with the tripwire proving
# ./install.sh was never reached. The 10-hour no-rotation deadline branch is not exercised.
future=$(python3 -c 'import time;print(time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(time.time()+120)))')
print -r -- "$future state=offline rotation" > "$BASE_DIR/log/stream.log"
run_deploy --tag v1 --wait-for-cut; rc=$?
WOUT=$(out)
t_assert_eq 1 $rc "--wait-for-cut ends non-zero when the checkout is refused"
t_assert_contains "$WOUT" "armed: waiting for a rotation" "it arms and waits for a rotation"
t_assert_contains "$WOUT" "ROTATION DETECTED" "it detects a fresh state=offline line as the rotation"
t_assert_contains "$WOUT" "ABORT: checkout failed" "and then proceeds into the real deploy steps"
t_assert_contains "$WOUT" "ROLLING BACK" "and rolls back instead of continuing"
markers=( "$W"/base*/log/install_ran.marker(N) )
t_assert_eq 0 "${#markers}" "install.sh was never reached (the tripwire held)"

t_teardown
t_summary
