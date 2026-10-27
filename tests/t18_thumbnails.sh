#!/bin/zsh
# t18 - the post-stream thumbnail: our own frame, four hours later, plus a repair sweep.
#
# What went wrong (measured 2026-10-28): the scheduler waited an hour for YouTube to offer its
# "pick one of 3" suggestions, they never arrived for an 8 h stream ("no suggestion after
# 321 min"), and only then did it try to grab a frame - which failed with "not seekable yet"
# for six more hours. Videos that fell through the single pending slot (rewritten at every
# cut) kept the channel's generic thumbnail forever, which the operator had been fixing by
# hand.
#
# The replacement is deliberately dumb: four hours after the cut, take the 01:00:00 frame and
# set it; retry until YouTube can serve the video; and repair the ten most recent videos that
# still show the generic image.
source "${0:A:h}/lib.sh"
t_begin t18

cd "$REPO_DIR" || exit 2

contains() {   # contains FILE NEEDLE LABEL
  t_assert_contains "$(<"$1")" "$2" "$3"
}

# --- the schedule ----------------------------------------------------------------------
contains bin/stream.sh ': ${THUMB_DELAY:=14400}' "the thumbnail is taken 4 h after the cut, not 1 h"
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

t_teardown
t_summary
