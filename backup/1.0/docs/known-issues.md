# Known issues

## Known cosmetic issues
- status.sh prints a stray artifact after "YT_KEY: set (NN chars)". Harmless; never
  prints the key itself.
- ffmpeg logs "Timestamps are unset in a packet" once at startup and "Resumed reading
  at pts ... after a lag" when the music input primes. Both are normal.

## Todo / notes
- Camera sends only ~1 Mbps for the whole 3-up composite, so one panel is low detail.
  Raise the bitrate in the camera web UI at http://192.168.1.2 - costs this Mac nothing.
- Lid-closed operation still wants:  sudo pmset -c sleep 0 disablesleep 1
- If the camera IP changes (e.g. moving to USB-C ethernet), rerun bin/camscan.py and
  update CAM_URL in conf/stream.env.
