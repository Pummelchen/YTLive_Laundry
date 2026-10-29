#!/bin/zsh
# t18 - the post-stream thumbnail: our own frame, 12 h later and every 12 h after, plus a sweep.
#
# What went wrong (measured 2026-10-28): the scheduler waited an hour for YouTube to offer its
# "pick one of 3" suggestions, they never arrived for an 8 h stream ("no suggestion after
# 321 min"), and only then did it try to grab a frame - which failed with "not seekable yet"
# for six more hours. Videos that fell through the single pending slot (rewritten at every
# cut) kept the channel's generic thumbnail forever, which the operator had been fixing by
# hand.
#
# The replacement is deliberately dumb: 12 h after the cut, take the 01:00:00 frame and set
# it; if YouTube is still processing, retry every 12 h (12, 24, 36, ...); and check the ten
# most recent videos on the same cadence until each shows its own image.
source "${0:A:h}/lib.sh"
t_begin t18
t_setup >/dev/null          # the scheduler test needs a scratch tree

cd "$REPO_DIR" || exit 2

contains() {   # contains FILE NEEDLE LABEL
  t_assert_contains "$(<"$1")" "$2" "$3"
}

# --- the schedule ----------------------------------------------------------------------
contains bin/stream.sh ': ${THUMB_DELAY:=43200}' "the first thumbnail attempt is 12 h after the cut"
contains bin/stream.sh ': ${THUMB_RETRY:=43200}' "a still-processing video is retried every 12 h (12, 24, 36, ...)"
contains bin/stream.sh ': ${THUMB_SWEEP_COUNT:=10}' "the repair sweep covers the 10 most recent videos"
contains bin/stream.sh 'yt_api_call frame-thumbnail "$vid" "$THUMB_FRAME_AT"' "the pending worker grabs a FRAME from the video"
if grep -q 'yt_api_call pick-thumbnail' bin/stream.sh; then
  t_bad "the pending worker still waits for YouTube's suggestion"
else
  t_ok "the pending worker no longer waits for YouTube's suggestion"
fi
contains bin/stream.sh 'THUMB_FRAME_AT:="01:00:00"' "the frame comes from the one-hour mark"

# --- the sweep -------------------------------------------------------------------------
contains bin/stream.sh 'sweep_thumbnails          # repair any recent video' "the repair sweep runs once at startup"
contains bin/stream.sh "    do_pending_thumbnail
" "and the 12 h sweep rides the housekeeping pass"
contains bin/stream.sh 'sweep_thumbnails' "and after a successful post-cut thumbnail"
contains bin/stream.sh 'THUMB-SWEEP: checking the' "the sweep says what it is doing"
# A quota refusal must not count as a completed sweep, or a 12 h window is wasted.
python3 - "$PWD/bin/stream.sh" <<'PY' && t_ok "a quota refusal does not arm the 12 h sweep clock" || t_bad "a QUOTA reply still marks the sweep as done"
import sys
s = open(sys.argv[1]).read()
i = s.find("sweep_thumbnails()")
body = s[i:s.find("\n}", i)]
sys.exit(0 if '"status": *"QUOTA"' in body or '"status": "QUOTA"' in body else 1)
PY

# --- the detector ----------------------------------------------------------------------
contains bin/yt_api.py 'def thumbnail_is_placeholder(' "yt_api exposes a placeholder detector"
contains bin/yt_api.py 'PLACEHOLDER_CORR = 0.95' "the threshold is stated, not magic"
contains bin/yt_api.py 'def cmd_sweep_thumbnails(' "yt_api has the sweep command"
contains bin/yt_api.py 'if cmd == "sweep-thumbnails"' "and the CLI reaches it"
contains bin/yt_api.py 'def grab_frame_thumbnail(' "frame capture is reusable by the sweep"

# The detector must compare AGAINST the channel's own image: YouTube re-encodes an uploaded
# thumbnail, so a byte comparison against conf/thumbnail.jpg can never match. A future edit
# "simplifying" this to == bytes would silently report every video as fine.
python3 - "$PWD/bin/yt_api.py" <<'PY' && t_ok "the detector compares greyscale correlation, not bytes" || t_bad "the detector compares bytes against conf/thumbnail.jpg"
import sys
s = open(sys.argv[1]).read()
i = s.find("def thumbnail_is_placeholder(")
body = s[i:s.find("\ndef ", i + 10)]
sys.exit(0 if "_corr(" in body and "_gray(" in body else 1)
PY


# --- the scheduler, driven for real ----------------------------------------------------
# Static checks cannot prove the file handling: the pending slot must be cleared on SET,
# rewritten on NOTREADY, and untouched before it is due. This runs the real function with a
# stubbed yt_api, so it stays hermetic and costs no quota.
DRV="$T_BASE/thumb_funcs.zsh"
CALLS="$T_BASE/log/thumb_calls.log"
{ t_extract_fn "$REPO_DIR/bin/stream.sh" do_pending_thumbnail
  printf "BASE='%s'\n" "$T_BASE"
  printf "THUMB_PENDING='%s/log/thumb_pending'\n" "$T_BASE"
  printf "THUMB_RETRY=43200\nTHUMB_FRAME_AT='01:00:00'\n"
  printf "CALLS='%s'\n" "$CALLS"
  cat <<'EOF'
log() { print -r -- "log: $*" >> "$CALLS"; }
yt_api_ready() { return 0; }
yt_api_call() { print -r -- "api: $*" >> "$CALLS"; print -r -- "${FAKE_OUT:-}"; }
sweep_thumbnails() { print -r -- "sweep" >> "$CALLS"; }
EOF
} > "$DRV"

pending() { print -r -- "$1" > "$T_BASE/log/thumb_pending"; }
pending_line() { <"$T_BASE/log/thumb_pending"; }
run_pending() { : > "$CALLS"; FAKE_OUT="$1" BASE="$T_BASE" /bin/zsh -c "source '$DRV'; do_pending_thumbnail" >/dev/null 2>&1; }

pending "abcdefghijk $(( $(date +%s) + 3600 )) 0 $(date +%s)"
run_pending '{"status":"SET"}'
if [[ -s "$CALLS" ]]; then t_bad "the scheduler acted an hour BEFORE it was due"; else t_ok "nothing happens before the 12 h mark"; fi

pending "abcdefghijk $(( $(date +%s) - 60 )) 0 $(( $(date +%s) - 3600 ))"
run_pending '{"status":"SET","source":"frame"}'
grep -q "api: frame-thumbnail abcdefghijk 01:00:00" "$CALLS" \
  && t_ok "when due it takes the 01:00:00 FRAME, not a YouTube suggestion" \
  || t_bad "the scheduler did not ask for the frame (calls: $(<"$CALLS"))"
[[ -s "$T_BASE/log/thumb_pending" ]] && t_bad "a SET left the pending slot behind" || t_ok "a SET clears the pending slot"
grep -q "^sweep$" "$CALLS" && t_ok "a SET then runs the repair sweep" || t_bad "no repair sweep after a SET"

pending "abcdefghijk $(( $(date +%s) - 60 )) 1 $(( $(date +%s) - 3600 ))"
run_pending '{"status":"NOTREADY","msg":"video not seekable yet"}'
[[ -s "$T_BASE/log/thumb_pending" ]] && t_ok "a NOTREADY keeps the video queued" || t_bad "a NOTREADY dropped the video"
newdue=$(<"$T_BASE/log/thumb_pending" | awk '{print $2}')
if [[ "$newdue" == <-> ]] && (( newdue >= $(date +%s) + 43100 )); then
  t_ok "and reschedules it 12 h out (12, 24, 36, ...)"
else
  t_bad "NOTREADY did not reschedule by 12 h (due=$newdue)"
fi

t_teardown
t_summary
