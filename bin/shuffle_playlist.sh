#!/bin/zsh
# Build a randomized concat playlist from the MP3 library.
# Usage: shuffle_playlist.sh          (uses MP3_DIR from stream.env)
set -u
BASE="${BASE:-$HOME/Downloads/YTLive}"
source "$BASE/conf/stream.env"

# ROTATE_HOURS is normally declared in stream.env, which is SOURCED and not exported, so a
# subprocess cannot see it. It used to be read inside the python block with a "8" default,
# which meant raising ROTATE_HOURS silently produced a playlist shorter than one broadcast -
# the exact concat-wrap death the pass count exists to prevent. Pass it explicitly.
ROTATE_HOURS="${ROTATE_HOURS:-8}"
# Prefer the installed ffprobe but fall back to PATH, so this works on a machine where
# install.sh has not run. A missing ffprobe used to raise an uncaught FileNotFoundError and
# leave the caller with no playlist at all and a traceback.
FFPROBE="${FFPROBE:-$HOME/.local/bin/ffprobe}"
if [[ ! -x "$FFPROBE" ]]; then
  FFPROBE="$(command -v ffprobe 2>/dev/null || true)"
fi
if [[ -z "$FFPROBE" || ! -x "$FFPROBE" ]]; then
  print -u2 -- "ERROR: no ffprobe found (looked in $HOME/.local/bin and PATH) - cannot measure the MP3 library, refusing to write a playlist that might be too short"
  exit 1
fi

ROTATE_HOURS="$ROTATE_HOURS" FFPROBE="$FFPROBE" python3 - "$MP3_DIR" "$BASE/conf/playlist.txt" <<'PY'
import os, sys, pathlib, random
src = pathlib.Path(sys.argv[1]); out = pathlib.Path(sys.argv[2])
if not src.is_dir():
    sys.exit(f"ERROR: MP3_DIR {src} is not a directory")
files = sorted(p for p in src.iterdir() if p.is_file() and p.suffix.lower() == ".mp3")
if not files:
    sys.exit(f"ERROR: no .mp3 files in {src}")
# THE PLAYLIST MUST OUTLAST A BROADCAST. ffmpeg's concat demuxer dies when
# -stream_loop wraps it past the last entry:
#     [in#2/concat] Task finished with error code: -1 (Operation not permitted)
# which kills the publisher and drops the RTMP session. Measured on 2026-09-06/07: the
# 25-track list ran 143.5 min and the publisher died every 143.8 min, eleven times in
# 26.7 hours. Writing enough reshuffled passes to cover a whole broadcast means the wrap
# never happens while a broadcast is live - the publisher restarts at each rotation and
# builds a fresh list anyway. -stream_loop stays as a backstop for the impossible case.
import subprocess
FFPROBE = os.environ["FFPROBE"]

def duration(path):
    try:
        r = subprocess.run([FFPROBE, "-v", "error", "-show_entries", "format=duration",
                            "-of", "csv=p=0", str(path)],
                           capture_output=True, text=True)
    except OSError as e:
        sys.exit(f"ERROR: cannot run ffprobe ({FFPROBE}): {e}")
    try:
        return float(r.stdout.strip())
    except ValueError:
        return 0.0

durations = [(f, duration(f)) for f in files]
bad = [f for f, d in durations if d <= 0]
# A zero duration means ffprobe could not read the file. Summing those as 0 would shrink the
# measured library and can collapse the pass count to 1, producing a playlist that wraps
# mid-broadcast and kills the publisher. Refuse instead of shipping a silent time bomb.
if bad:
    sys.exit("ERROR: ffprobe could not measure " + ", ".join(str(f) for f in bad[:5]) +
             (" ..." if len(bad) > 5 else "") + " - refusing to write a playlist that may be too short")

one_pass = sum(d for _, d in durations)
rotate_h = float(os.environ.get("ROTATE_HOURS") or "8")
if rotate_h <= 0:
    sys.exit(f"ERROR: ROTATE_HOURS={rotate_h} is not usable")
need = rotate_h * 3600 * 1.25              # a broadcast plus 25% margin
passes = max(1, int(-(-need // one_pass)))

lines = ["# randomized playlist - regenerate with bin/shuffle_playlist.sh",
         f"# {len(files)} tracks x {passes} reshuffled passes = "
         f"{one_pass*passes/3600:.1f}h, longer than the {rotate_h:.0f}h rotation on purpose"]
for _ in range(passes):
    random.shuffle(files)                  # reshuffle each pass, so it does not simply repeat
    for p in files:
        esc = str(p.resolve()).replace("'", r"'\''")
        lines.append(f"file '{esc}'")
out.write_text("\n".join(lines) + "\n")
print(f"wrote {out}: {len(files)} tracks x {passes} passes = {len(files)*passes} entries, "
      f"{one_pass*passes/3600:.2f}h (one pass {one_pass/60:.1f} min)")
PY
