#!/bin/zsh
# Probe the camera by hand: what codecs, resolution, frame rate and audio it is really sending.
# The quick answer to "is the camera the problem" without touching the stream.
#
# BASE defaults to the checkout THIS script lives in rather than a hardcoded ~/Downloads/YTLive,
# so a copy of the tree on another machine works with no edit. (The launchd install still has to
# BE at ~/Downloads/YTLive - macOS TCC refuses a background agent in a protected directory, which
# install.sh probes for - but that is an install constraint, not a script one.) This file was the
# one entry point that ignored BASE entirely, so `BASE=... bin/preflight.sh` had no effect;
# forensics.sh has used the ${0:A:h:h} form since it was written.
set -u
BASE="${BASE:-${0:A:h:h}}"
CONF="${CONF:-$BASE/conf/stream.env}"
source "$CONF"

# An explicitly named FFPROBE wins outright and must exist: silently falling back to PATH after
# the caller named a binary turns a typo into what looks like a camera fault. When it is not set,
# prefer the installer's static build and then PATH - a bare "$HOME/.local/bin/ffprobe" used to
# fail with "no such file or directory" on a machine where install.sh had not run yet.
if [[ -n "${FFPROBE:-}" ]]; then
  if [[ ! -x "$FFPROBE" ]]; then
    print -u2 -- "preflight: FFPROBE=$FFPROBE is not executable"
    exit 1
  fi
else
  FFPROBE="$HOME/.local/bin/ffprobe"
  [[ -x "$FFPROBE" ]] || FFPROBE="$(command -v ffprobe 2>/dev/null)"
  if [[ -z "$FFPROBE" || ! -x "$FFPROBE" ]]; then
    print -u2 -- "preflight: no ffprobe found - install.sh puts one in ~/.local/bin, or set FFPROBE=..."
    exit 1
  fi
fi
if [[ -z "${CAM_URL:-}" ]]; then
  print -u2 -- "preflight: CAM_URL is empty in $CONF"
  exit 1
fi

print "Probing $CAM_URL ..."
"$FFPROBE" -v error -rtsp_transport tcp -timeout 15000000 \
  -show_entries stream=codec_type,codec_name,width,height,avg_frame_rate,sample_rate,channels \
  -of default=noprint_wrappers=1 "$CAM_URL"
