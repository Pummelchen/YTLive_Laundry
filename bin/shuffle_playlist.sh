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
random.shuffle(files)                      # randomize the by-name list
lines = ["# randomized playlist - regenerate with bin/shuffle_playlist.sh"]
for p in files:
    esc = str(p.resolve()).replace("'", r"'\''")
    lines.append(f"file '{esc}'")
out.write_text("\n".join(lines) + "\n")
print(f"wrote {out} with {len(files)} tracks")
for i, p in enumerate(files, 1):
    print(f"  {i:2d}. {p.name}")
PY
