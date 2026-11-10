#!/bin/zsh
# t24 - the prepare backoff: a key that matches nothing must not become a 15-second restart loop.
#
# WHY THIS FILE EXISTS. On 2026-11-10 the configured stream key matched no liveStream on the
# channel for 8 h 08 m. Nothing about that is fixable by retrying, but the publisher-start path
# retried anyway - one `prepare` every ~17 s, 1,704 attempts, 1,589 ffmpeg deaths and 4,292 API
# calls in that window, most of a day's 10,000-unit quota. The rule that replaces it is
# exponential and capped, and it MUST NOT swallow the transient case: a network blip must still
# start the publisher, because ingest can reach a broadcast that is already bound.
#
# Both halves are asserted here: the delay as a pure function, and the source's shape - which
# error class is treated as fatal, and that the restart loop honours a refused start.
source "${0:A:h}/lib.sh"
t_begin t24
t_setup >/dev/null

ST="$REPO_DIR/bin/stream.sh"

# --- A. the delay, as a pure function ---------------------------------------
FUNCS="$T_BASE/stream_funcs.zsh"
: > "$FUNCS"
t_extract_fn "$ST" prepare_backoff_delay >> "$FUNCS"
cat >> "$FUNCS" <<'EOF'
PREPARE_BACKOFF_BASE=300
PREPARE_BACKOFF_MAX=1800
EOF
delay() {  # delay FAILS -> seconds
  /bin/zsh -c "source '$FUNCS'; prepare_backoff_delay $1"
}

t_assert_eq "300"  "$(delay 1)"  "the first key failure holds the publisher down for 300s"
t_assert_eq "600"  "$(delay 2)"  "the second doubles it"
t_assert_eq "1200" "$(delay 3)"  "then 1200s"
t_assert_eq "1800" "$(delay 4)"  "and it stops at the 1800s ceiling, not doubling forever"
t_assert_eq "1800" "$(delay 9)"  "a long outage stays at the ceiling"
t_assert_eq "1800" "$(delay 99)" "and a nonsense counter cannot overflow the shift"
t_assert_eq "300"  "$(delay 0)"  "a zero/negative counter behaves like the first attempt"
t_assert_eq "300"  "$(delay abc)" "a non-numeric counter does not crash the loop"

# The ceiling must stay above the longest thing this is meant to avoid: YouTube's quota day.
# (A short ceiling would turn a quota outage into a restart every few minutes all night.)
max=$(/bin/zsh -c "source '$FUNCS'; print \$PREPARE_BACKOFF_MAX")
if (( max >= 900 )); then t_ok "the ceiling (${max}s) is long enough to stop a storm"
else t_bad "the ceiling (${max}s) is too short to suppress a storm"; fi

# --- B. the classification --------------------------------------------------
# The one ERROR class retrying cannot fix is the key/config one. Everything else must still
# start the publisher: a broadcast may already be bound and ingest is what starts it.
block=$(awk '/^prepare_broadcast\(\)/,/^}/' "$ST")
t_assert_contains "$block" "no liveStream on this channel uses the configured YT_KEY" \
  "prepare_broadcast recognises the key/config error by name"
t_assert_contains "$block" '"status": *"ERROR"' \
  "and only treats an ERROR body as a failure at all"
t_assert_contains "$block" "return 2" "the key error is a distinct status (2)"
t_assert_contains "$block" "return 1" "a transient ERROR is a different status (1)"

start=$(awk '/^start_publisher\(\)/,/^}/' "$ST")
t_assert_contains "$start" "prepare_holddown_active" \
  "start_publisher refuses to start while the hold-down is armed"
t_assert_contains "$start" "prepare_backoff_delay" \
  "and arms it from the pure delay function"
t_assert_contains "$start" "PREPARE_FAILS=0" "a successful start clears the failure count"

# --- C. the loop honours a refused start ------------------------------------
loop=$(awk '/^while true; do/,0' "$ST")
t_assert_contains "$loop" 'if ! start_publisher; then' \
  "the publisher watchdog loop notices that a start was refused"
t_assert_contains "$loop" "continue" \
  "and keeps turning instead of retrying every 5 seconds"

# A publisher that was never started must not be announced as pid "".
t_assert_contains "$(cat "$ST")" 'if [[ -n "${PUBPID:-}" ]]' \
  "a refused start is never logged as 'publisher back up (pid )'"

# --- D. the hold-down is announced once per block, not every 5 seconds ------
note=$(awk '/^prepare_holddown_note\(\)/,/^}/' "$ST")
t_assert_contains "$note" 'PREPARE_HOLD_LOGGED' \
  "the hold-down is logged once, so a 30-minute backoff is one line and not 360"

if (( FAIL == 0 )); then
  print -- "\n  \033[32mALL PASSED\033[0m ($(( PASS )) checks)"
  print -- ""
  exit 0
else
  print -- "\n  \033[31m$FAIL FAILED\033[0m, $PASS passed"
  print -- ""
  exit 1
fi
