#!/bin/zsh
# t15 - three ways a restart or a late verdict used to lose something silently.
#
#   (a) T-12. A recording's fate was decided from `rotation_history.log`, which is deliberately
#       trimmed to the last 100 rotations. An id whose verdict never settled (yt-dlp still
#       processing) therefore fell out of the retried set and its recording was never confirmed at
#       all - at ~3 rotations/day the window is ~33 days, which is why nobody noticed. The set now
#       lives in log/vod_pending, and this file drives that list through every outcome.
#   (b) T-08. A restart can make YouTube close the old broadcast (autoStop, ~9s after ingest
#       stops). BROADCAST_STARTED was only re-adopted by housekeep every 300s, so the rotation loop
#       could hold the DEAD broadcast's age and then fire early, cutting a second short recording
#       out of the same session. The re-adopt must read the NEW broadcast's real start.
#   (c) T-19. `await_broadcast` runs in a `( ... ) &` subshell that snapshotted `$PUBPID` when it
#       was forked. A restart in between makes that pid stale: `kill -9` on a recycled pid kills a
#       stranger, and a stale pid that is merely gone makes the bounce a silent no-op.
source "${0:A:h}/lib.sh"
t_begin t15
t_setup >/dev/null
mkdir -p "$T_BASE/log"
CALLS="$T_BASE/log/calls.log"

# --- (a) the pending list -----------------------------------------------------------------
VODF="$T_BASE/vod_funcs.zsh"
{ t_extract_fn "$REPO_DIR/bin/stream.sh" vod_pending_add
  t_extract_fn "$REPO_DIR/bin/stream.sh" verify_pending_vods
  printf "BASE='%s'\n" "$T_BASE"
  printf "VODSTATE='%s/log/vod_status'\n" "$T_BASE"
  printf "VOD_PENDING='%s/log/vod_pending'\n" "$T_BASE"
  printf "ROTATE_HISTORY='%s/log/rotation_history.log'\n" "$T_BASE"
  printf "VOD_MISSING_RETRIES=2\nVOD_MAX_PROBES=3\nCALLS='%s'\n" "$CALLS"
  cat <<'EOF'
log() { print -r -- "$*" >> "$CALLS"; }
vod_duration() { print -r -- "${VOD_DUR:-123}"; return ${VOD_RC:-0}; }
EOF
} > "$VODF"

pending_has() { grep -q "^$1 " "$T_BASE/log/vod_pending" 2>/dev/null; }
status_has()  { grep -q "^$1 " "$T_BASE/log/vod_status" 2>/dev/null; }
run_vod()     { BASE="$T_BASE" VOD_RC="$1" VOD_DUR="${2:-123}" /bin/zsh -c "source '$VODF'; verify_pending_vods" >/dev/null 2>&1; }
reset_vod()   { : > "$T_BASE/log/vod_status"; : > "$T_BASE/log/vod_pending"; : > "$T_BASE/log/rotation_history.log"; }

# THE BUG: the id is only in the pending file; the (trimmed) history has forgotten it entirely.
reset_vod
print -r -- "OnlyInPending 0" > "$T_BASE/log/vod_pending"
run_vod 0 28800
status_has "OnlyInPending ok" && t_ok "an id only in vod_pending is verified - the trimmed history is irrelevant" \
                              || t_bad "an id that fell out of rotation_history was NOT verified"
pending_has "OnlyInPending" && t_bad "a verified recording was left in the pending list" \
                            || t_ok "and it is dropped from the list once settled"

# A MISSING verdict is re-probed, then dropped: bounded, not forever.
reset_vod
print -r -- "MissingOne 0" > "$T_BASE/log/vod_pending"
run_vod 1 0
status_has "MissingOne MISSING" && t_ok "a definitively MISSING recording is recorded as such" \
                               || t_bad "the MISSING verdict was not written"
pending_has "MissingOne" && t_ok "and re-probed once more (a late encode can still appear)" \
                         || t_bad "MISSING was dropped after a single probe"
run_vod 1 0
pending_has "MissingOne" && t_bad "a twice-MISSING recording is still being probed forever" \
                         || t_ok "and dropped after VOD_MISSING_RETRIES probes"

# An id that never resolves is bounded too - otherwise the list grows forever.
reset_vod
print -r -- "NeverResolves 0" > "$T_BASE/log/vod_pending"
run_vod 2 0; run_vod 2 0
pending_has "NeverResolves" && t_ok "an unresolved id is kept while probes remain" \
                            || t_bad "an unresolved id was dropped too early"
run_vod 2 0
pending_has "NeverResolves" && t_bad "an id that never resolves stays in the list forever" \
                            || t_ok "and dropped at VOD_MAX_PROBES"
t_assert_contains "$(cat "$CALLS")" "never resolved" "and says so, with the id, instead of vanishing"

# Migration: an install that predates vod_pending adopts what the history still remembers.
reset_vod
print -r -- "2026-09-19 12:00:00 mode=native seconds_to_live=23 broadcast=NEWER ended=FromHistory" > "$T_BASE/log/rotation_history.log"
run_vod 2 0
pending_has "FromHistory" && t_ok "an id the history still remembers is adopted into pending" \
                          || t_bad "the history was not adopted, so an old install would lose it"

# The probe count survives a rewrite of the list.
reset_vod
print -r -- "Counted 1" > "$T_BASE/log/vod_pending"
run_vod 2 0
t_assert_eq "Counted 2" "$(cat "$T_BASE/log/vod_pending")" "the probe count is carried forward, not reset"

# vod_pending_add must never duplicate.
reset_vod
/bin/zsh -c "source '$VODF'; vod_pending_add Dup; vod_pending_add Dup" >/dev/null 2>&1
t_assert_eq "1" "$(grep -c '^Dup ' "$T_BASE/log/vod_pending")" "vod_pending_add is idempotent"
/bin/zsh -c "source '$VODF'; vod_pending_add ''" >/dev/null 2>&1
t_assert_eq "1" "$(grep -c '' "$T_BASE/log/vod_pending")" "and an empty id is not recorded"

# --- (b) the restart clock ----------------------------------------------------------------
CLKF="$T_BASE/clock_funcs.zsh"
{ t_extract_fn "$REPO_DIR/bin/stream.sh" refresh_broadcast_clock
  printf "BASE='%s'\nBSTATE='%s/log/broadcast_started'\nROTATE_SECONDS=28980\nCALLS='%s'\n" "$T_BASE" "$T_BASE" "$CALLS"
  cat <<'EOF'
log() { print -r -- "$*" >> "$CALLS"; }
yt_api_ready() { return 0 }
yt_live_id() { print -r -- "$FAKE_LIVE_ID" }
yt_api_call() { print -r -- "{\"started_epoch\": $FAKE_STARTED}" }
EOF
} > "$CLKF"
clock_run() { BASE="$T_BASE" CALLS="$CALLS" FAKE_LIVE_ID="$1" FAKE_STARTED="$2" \
              /bin/zsh -c "source '$CLKF'; refresh_broadcast_clock; print -r -- \"STARTED=\$BROADCAST_STARTED\""; }

print -r -- "OldBroadcast 1000" > "$T_BASE/log/broadcast_started"
out=$(clock_run NewBroadcast 2000)
t_assert_contains "$out" "STARTED=2000" "a restart that finds a NEW broadcast adopts its real start time"
t_assert_eq "NewBroadcast 2000" "$(cat "$T_BASE/log/broadcast_started")" "and records it, so the next pass is free"

print -r -- "SameOne 3000" > "$T_BASE/log/broadcast_started"
: > "$CALLS"
out=$(clock_run SameOne 9999)
t_assert_contains "$out" "STARTED=3000" "an UNCHANGED broadcast re-uses the stored clock"
if grep -q "started_epoch" "$CALLS" 2>/dev/null; then
  t_bad "the unchanged path asked YouTube for the age when the stored clock was valid"
else
  t_ok "and costs no API call, which is why the bounded retry is affordable"
fi

# --- (c) the wiring ------------------------------------------------------------------------
grep -q 'bounce_pid=$(pidfile_pid "$PUB_PID" ffmpeg rtmp)' "$REPO_DIR/bin/stream.sh" \
  && t_ok "the ingest bounce identifies the publisher by pidfile, not by a snapshot" \
  || t_bad "the bounce still signals the pid it inherited when the subshell forked"
awk '/^await_broadcast\(\)/,/^}/' "$REPO_DIR/bin/stream.sh" | grep -q 'kill -9 "\$PUBPID"' \
  && t_bad "await_broadcast still kills the stale \$PUBPID" \
  || t_ok "and nothing in await_broadcast kills the stale publisher pid"
t_assert_eq "2" "$(grep -c 'CLOCK_RETRY_END=\$((' "$REPO_DIR/bin/stream.sh")" \
  "both restart paths arm the bounded clock retry"
grep -q 'FRAGMENT: the restart closed broadcast' "$REPO_DIR/bin/stream.sh" \
  && t_ok "a restart that fragments the recording says so, with both ids" \
  || t_bad "fragmentation is still invisible in the log"
grep -q "grep -c 'FRAGMENT:'" "$REPO_DIR/bin/status.sh" \
  && t_ok "and the health page counts them, so a short VOD is explained where a human looks" \
  || t_bad "fragmentation is logged but never surfaced"

t_teardown
t_summary
