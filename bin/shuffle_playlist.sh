#!/bin/zsh
# Build a randomized concat playlist from the MP3 library.
# Usage: shuffle_playlist.sh          (uses MP3_DIR from stream.env)
BASE="${BASE:-$HOME/Downloads/YTLive}"
source "$BASE/conf/stream.env"
python3 - "$MP3_DIR" "$BASE/conf/playlist.txt" <<'PY'
import sys, pathlib, random
src = pathlib.Path(sys.argv[1]); out = pathlib.Path(sys.argv[2])
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
def duration(path):
    r = subprocess.run([str(pathlib.Path.home()/".local/bin/ffprobe"), "-v", "error",
                        "-show_entries", "format=duration", "-of", "csv=p=0", str(path)],
                       capture_output=True, text=True)
    try: return float(r.stdout.strip())
    except ValueError: return 0.0

one_pass = sum(duration(f) for f in files)
rotate_h = float(__import__("os").environ.get("ROTATE_HOURS", "8"))
need = rotate_h * 3600 * 1.25              # a broadcast plus 25% margin
passes = 1 if one_pass <= 0 else max(1, int(-(-need // one_pass)))

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
