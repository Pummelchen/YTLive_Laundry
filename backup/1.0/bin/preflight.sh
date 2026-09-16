#!/bin/zsh
source "$HOME/Downloads/YTLive/conf/stream.env"
print "Probing $CAM_URL ..."
"$HOME/.local/bin/ffprobe" -v error -rtsp_transport tcp -timeout 15000000 \
  -show_entries stream=codec_type,codec_name,width,height,avg_frame_rate,sample_rate,channels \
  -of default=noprint_wrappers=1 "$CAM_URL"
