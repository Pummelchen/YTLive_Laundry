#!/bin/zsh
# Quick health check for the CCTV->YouTube stream.
source "$HOME/Downloads/YTLive/conf/stream.env"
print "=== config ==="
print "  CAM_URL : $CAM_URL"
print "  MODE    : $MODE"
print "  YT_KEY  : ${YT_KEY:+set (${#YT_KEY} chars)}${YT_KEY:-<EMPTY - edit conf/stream.env>}"
print "\n=== launchd job ==="
launchctl list 2>/dev/null | grep cctv-stream || print "  (not loaded)"
print "\n=== running ffmpeg ==="
pgrep -lf "ffmpeg.*$YT_URL" >/dev/null 2>&1 && pgrep -lf "ffmpeg" | grep flv || print "  (no ffmpeg streaming)"
print "\n=== camera reachable? ==="
host=${CAM_URL#rtsp://}; host=${host%%/*}; host=${host%%:*}
if nc -z -G 3 "$host" 554 2>/dev/null; then print "  $host:554 OPEN"; else print "  $host:554 UNREACHABLE"; fi
print "\n=== last 12 log lines ==="
tail -12 "$HOME/Downloads/YTLive/log/stream.log" 2>/dev/null || print "  (no log yet)"
