#!/bin/zsh
# Shared helpers for stream.sh and yt_monitor.sh.
#
# These were defined separately in both scripts and had already drifted: YT_LATENCY was
# added to each by hand, and the two yt_api_ready() bodies tested different paths for the
# same file. A setting that reaches one caller and not the other is exactly the bug class
# that silently dropped the channel's hashtags for a day - conf/stream.env is SOURCED, not
# exported, so anything a subprocess needs has to be passed explicitly, once, in one place.
#
# Expects BASE to be set. Source with:  source "$BASE/bin/lib.sh"

: ${YT_API:="$BASE/bin/yt_api.py"}
: ${YT_OAUTH:="$BASE/conf/yt_oauth.json"}

yt_api_ready() { [[ -s "$YT_OAUTH" && -x "$YT_API" ]] }

yt_api_call() {
  BASE="$BASE" \
  YT_TITLE_FMT="${YT_TITLE_FMT:-}" \
  YT_PRIVACY="${YT_PRIVACY:-public}" \
  YT_LATENCY="${YT_LATENCY:-normal}" \
  python3 "$YT_API" "$@" 2>&1
}
