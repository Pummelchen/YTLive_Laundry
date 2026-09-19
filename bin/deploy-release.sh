#!/bin/zsh
# Deploy a tagged release onto this machine, with a rollback that covers everything the install
# actually changes.
#
#   deploy-release.sh --tag v2.1 [--dry-run]        check everything, change nothing (default)
#   deploy-release.sh --tag v2.1 --go               deploy now
#   deploy-release.sh --tag v2.1 --wait-for-cut      wait for the next rotation, then deploy
#
# KILL SWITCH: create ~/ytlive-deploy-HOLD and it stops before changing anything.
#
# WHY THIS EXISTS instead of "git checkout && ./install.sh":
#
# On 2026-09-17 a deploy did exactly that. install.sh failed, the rollback restored
# ~/Downloads/YTLive, and it printed "rollback done" - while leaving ~/.local/bin/yt-dlp
# pointing at a broken build the installer had just written. The stream never stopped, so
# nothing looked wrong; the monitor had simply gone blind. install.sh writes OUTSIDE the tree:
# ~/.local/bin (it symlinks yt-dlp), ~/Library/LaunchAgents, ~/Library/Logs/YTLive and pip's
# user site. A backup of the tree alone restores LESS than the install changed, and a rollback
# that reports success having done that is worse than no rollback, because it stops you looking.
#
# So this script backs up both halves, verifies the RESULT rather than trusting the exit code,
# and - the part that was missing - checks that the tooling still works afterwards.
set -u

BASE="${BASE:-${0:A:h:h}}"   # the checkout this script lives in (a launchd install is ~/Downloads/YTLive)
BIN="$HOME/.local/bin"
LA="$HOME/Library/LaunchAgents"
LOGS="$HOME/Library/Logs/YTLive"
HOLD="$HOME/ytlive-deploy-HOLD"
DOMAIN="gui/$(id -u)"
SVC_STREAM="com.user.cctv-stream"
SVC_MONITOR="com.user.cctv-monitor"
YTDLP="$BIN/yt-dlp"
LIVE_URL="https://www.youtube.com/@ternaklaundrybengkong/live"

TAG=""
MODE="--dry-run"
while (( $# )); do
  case "$1" in
    --tag) TAG="${2:-}"; shift 2 ;;
    --go|--dry-run|--wait-for-cut) MODE="$1"; shift ;;
    *) print -u2 -- "unknown argument: $1"; exit 2 ;;
  esac
done
[[ -n "$TAG" ]] || { print -u2 -- "usage: $0 --tag vX.Y [--dry-run|--go|--wait-for-cut]"; exit 2; }

STAMP="$(date +%Y%m%d-%H%M%S)"
JOB="$HOME/ytlive-deploy-$STAMP"
LOG="$JOB.log"
mkdir -p "$JOB"
exec > >(tee -a "$LOG") 2>&1

say()  { print -r -- "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
warn() { print -r -- "[$(date '+%Y-%m-%d %H:%M:%S')] WARNING: $*" }
stop_agents() {
  launchctl bootout "$DOMAIN/$SVC_STREAM"  2>/dev/null
  launchctl bootout "$DOMAIN/$SVC_MONITOR" 2>/dev/null
  sleep 2
}
start_agents() {
  for s in "$SVC_STREAM" "$SVC_MONITOR"; do
    launchctl enable "$DOMAIN/$s" 2>/dev/null
    launchctl bootstrap "$DOMAIN" "$LA/$s.plist" 2>/dev/null || launchctl load -w "$LA/$s.plist" 2>/dev/null
  done
}
jobs_loaded()  { launchctl list 2>/dev/null | grep -c cctv; }
publisher_up() { pgrep -f 'ffmpeg.*rtmp' >/dev/null 2>&1; }
# The check the 2026-09-17 rollback never made: can this machine still SEE the stream?
ytdlp_works() {
  [[ -x "$YTDLP" ]] || return 1
  "$YTDLP" --no-warnings --print '%(id)s' "$LIVE_URL" 2>/dev/null | grep -qE '^[A-Za-z0-9_-]{6,}$'
}

cd "$BASE" || { say "ABORT: no $BASE"; exit 1; }
say "=== deploy $TAG | mode=$MODE | log=$LOG ==="

# ---------- preconditions -----------------------------------------------------
[[ -d .git ]] || { say "ABORT: $BASE is not a git checkout"; exit 1; }
git rev-parse --verify -q "$TAG" >/dev/null || { say "ABORT: tag $TAG not present (git fetch --tags origin)"; exit 1; }
for f in conf/stream.env conf/yt_oauth.json conf/broadcast_template.json; do
  [[ -f "$f" ]] || { say "ABORT: $f missing"; exit 1; }
done
WANT_V="${TAG#v}"
TAG_SHA="$(git rev-parse "$TAG^{commit}")"
say "pre: HEAD=$(git rev-parse --short HEAD) VERSION=$(cat VERSION 2>/dev/null || echo none) -> target $TAG ($(git rev-parse --short "$TAG^{commit}"))"
say "pre: disk free=$(df -h "$BASE" | tail -1 | awk '{print $4}') jobs=$(jobs_loaded)"

# ---------- the environment scan that was missing ------------------------------
# install.sh picks an interpreter and installs yt-dlp with it. If it picks one that is too old,
# pip resolves an old yt-dlp that can no longer parse YouTube and the monitor goes blind. Print
# what is on the machine BEFORE changing anything.
say "--- interpreters on this machine ---"
say "  PATH would resolve python3 to: $(command -v python3 2>/dev/null || print 'none')"
typeset -a PYS; PYS=()
for d in ${(s.:.)PATH} /usr/local/bin /opt/homebrew/bin /usr/bin; do
  [[ -n "$d" ]] || continue
  for n in python3 python3.14 python3.13 python3.12 python3.11 python3.10; do
    [[ -x "$d/$n" ]] && PYS+=("$d/$n")
  done
done
PYS=(${(u)PYS})
newest=0
for p in "${PYS[@]}"; do
  v=$("$p" -c 'import sys;print("%d%02d" % sys.version_info[:2])' 2>/dev/null) || continue
  [[ "$v" == <-> ]] || continue
  (( v > newest )) && newest=$v
  ytv=$("$p" -m yt_dlp --version 2>/dev/null)
  say "  $p  $("$p" -V 2>&1)  $( [[ -n "$ytv" ]] && print "yt_dlp $ytv" || print "no yt_dlp" )"
done
(( newest >= 310 )) || warn "no Python >= 3.10 here. install.sh can only install an OLD yt-dlp, which cannot parse YouTube."
say "--- yt-dlp in use now ---"
say "  $YTDLP -> $(readlink "$YTDLP" 2>/dev/null || print '(not a symlink)')  $("$YTDLP" --version 2>/dev/null || print 'BROKEN')"
ytdlp_works && say "  resolves the live page: yes" || warn "it does NOT resolve the live page right now - the monitor is already blind"

if [[ "$MODE" == "--dry-run" ]]; then
  say "DRY RUN - nothing changed"
  say "  would back up : $BASE, $BIN, $LA, $LOGS  ->  $JOB/"
  say "  would checkout: $TAG ($(git rev-parse --short "$TAG^{commit}"))"
  say "  then          : $BASE/install.sh, verify tools + agents, roll back both halves on failure"
  say "DRY RUN OK"; exit 0
fi

[[ -e "$HOLD" ]] && { say "ABORT: kill switch $HOLD is engaged"; exit 1; }

# ---------- optional: wait for the rotation -----------------------------------
if [[ "$MODE" == "--wait-for-cut" ]]; then
  start_epoch=$(date +%s)
  say "armed: waiting for a rotation after $(date -r $start_epoch '+%H:%M:%S')"
  deadline=$(( start_epoch + 36000 ))
  while true; do
    [[ -e "$HOLD" ]] && { say "ABORT: kill switch engaged while waiting"; exit 1; }
    line=$(grep -a "state=offline" log/stream.log 2>/dev/null | tail -1)
    if [[ -n "$line" ]]; then
      ts="${line[1,19]}"
      ep=$(date -j -f "%Y-%m-%d %H:%M:%S" "$ts" +%s 2>/dev/null || print 0)
      (( ep >= start_epoch )) && { say "ROTATION DETECTED - old broadcast offline at $ts"; break; }
    fi
    (( $(date +%s) > deadline )) && { say "ABORT: no rotation within 10h"; exit 1; }
    sleep 10
  done
  say "proceeding now - the streamer is inside its post-close sleep"
fi

# ---------- 1. back up BOTH halves --------------------------------------------
say "1/6 backing up the tree and everything install.sh writes outside it"
cp -a "$BASE" "$JOB/tree" || { say "ABORT: tree backup failed"; exit 1; }
cp -a "$BIN"  "$JOB/dot-local-bin" 2>/dev/null || warn "could not back up $BIN"
cp -a "$LA"   "$JOB/LaunchAgents"  2>/dev/null || warn "could not back up $LA"
cp -a "$LOGS" "$JOB/Logs-YTLive"   2>/dev/null || true
readlink "$YTDLP" > "$JOB/ytdlp-target" 2>/dev/null || print -r -- "(none)" > "$JOB/ytdlp-target"
readlink "$YTDLP.old" > "$JOB/ytdlp-old-target" 2>/dev/null || true
cp -P "$BASE/conf/broadcast_template.json" "$JOB/broadcast_template.json.live" 2>/dev/null || true
say "   backup: $(du -sh "$JOB" 2>/dev/null | awk '{print $1}')  yt-dlp was -> $(cat "$JOB/ytdlp-target")"

rollback() {
  say "*** ROLLING BACK ***"
  local partial=no
  stop_agents
  cd "$HOME" || { say "*** ROLLBACK FAILED: cannot cd \$HOME ***"; exit 1; }
  rm -rf "$BASE.failed-$STAMP"
  mv "$BASE" "$BASE.failed-$STAMP" 2>/dev/null
  mv "$JOB/tree" "$BASE" || { say "*** ROLLBACK FAILED: no tree backup ***"; exit 1; }
  # the half that was missing last time
  if [[ -d "$JOB/dot-local-bin" ]]; then
    rm -rf "$BIN.replaced-$STAMP"; mv "$BIN" "$BIN.replaced-$STAMP" 2>/dev/null
    mv "$JOB/dot-local-bin" "$BIN" || { partial=yes; say "  could not restore $BIN"; }
  fi
  if [[ -d "$JOB/LaunchAgents" ]]; then
    rm -rf "$LA.replaced-$STAMP"; mv "$LA" "$LA.replaced-$STAMP" 2>/dev/null
    mv "$JOB/LaunchAgents" "$LA" || { partial=yes; say "  could not restore $LA"; }
  fi
  cd "$BASE" || exit 1
  start_agents
  sleep 3
  if [[ "$partial" == yes ]]; then
    say "*** PARTIAL ROLLBACK: the tree is restored but some machine state is NOT. Check $BIN and $LA by hand. ***"
  else
    say "*** rollback done: HEAD=$(git rev-parse --short HEAD) VERSION=$(cat VERSION 2>/dev/null || echo none) jobs=$(jobs_loaded) yt-dlp=$("$YTDLP" --version 2>/dev/null || echo BROKEN) ***"
  fi
  say "*** stream is $(publisher_up && print publishing || print NOT publishing) ***"
  exit 1
}

# ---------- 2. stop -----------------------------------------------------------
say "2/6 stopping both agents (domain $DOMAIN)"
stop_agents
say "   jobs now=$(jobs_loaded) ffmpeg-rtmp=$(pgrep -f 'ffmpeg.*rtmp' 2>/dev/null | wc -l | tr -d ' ')"

# ---------- 3. checkout -------------------------------------------------------
say "3/6 git checkout $TAG"
git checkout -- conf/broadcast_template.json 2>/dev/null
git checkout "$TAG" || { say "ABORT: checkout failed"; rollback; }
rm -rf AUDIT
cp "$JOB/broadcast_template.json.live" conf/broadcast_template.json 2>/dev/null
[[ "$(git rev-parse HEAD)" == "$TAG_SHA" ]] || { say "ABORT: HEAD is not $TAG"; rollback; }
[[ "$(cat VERSION 2>/dev/null)" == "$WANT_V" ]] || { say "ABORT: VERSION is not $WANT_V"; rollback; }
say "   HEAD=$(git rev-parse --short HEAD) VERSION=$(cat VERSION)"

# ---------- 4. install --------------------------------------------------------
say "4/6 ./install.sh"
if ! ./install.sh; then
  say "ABORT: install.sh failed (output above)"; rollback
fi

# ---------- 5. verify the RESULT, not the exit code ---------------------------
say "5/6 verifying"
fail=""
for l in "$SVC_STREAM" "$SVC_MONITOR"; do
  [[ -f "$LA/$l.plist" ]] || fail="$fail $l.plist-missing"
  plutil -lint "$LA/$l.plist" >/dev/null 2>&1 || fail="$fail $l.plist-invalid"
done
cmp -s "$JOB/broadcast_template.json.live" conf/broadcast_template.json || fail="$fail template-changed"
ytdlp_works || fail="$fail yt-dlp-blind"
if [[ -n "$fail" ]]; then
  say "   FAILED:$fail"
  rollback
fi
say "   plists valid, template preserved, yt-dlp $("$YTDLP" --version) resolves the live page"

# ---------- 6. start ----------------------------------------------------------
say "6/6 starting agents"
start_agents
ok=0
for i in {1..18}; do
  if (( $(jobs_loaded) >= 2 )) && publisher_up; then ok=1; break; fi
  sleep 5
done
(( ok )) || { say "ABORT: the publisher did not come up"; rollback; }
say "   jobs=$(jobs_loaded) publisher=up yt-dlp=$("$YTDLP" --version)"

say "=== DEPLOY COMPLETE ==="
say "  HEAD      = $(git rev-parse --short HEAD)   VERSION=$(cat VERSION)"
say "  backup    = $JOB   (tree + machine state; delete when you are happy)"
say "  next      : watch one rotation - grep ROTATE log/stream.log"
