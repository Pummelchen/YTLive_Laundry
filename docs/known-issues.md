# Known issues

## Known cosmetic issues
- The two ffmpeg warnings this page used to list are suppressed by `-loglevel error` and no
  longer reach a log: "Timestamps are unset in a packet" and the MP3 concat's "Resumed reading
  at pts ... after a lag". The latter repeated 5700+ times and filled most of a 6 MB log
  before the publisher was moved to `-loglevel error`.

## Todo / notes
- The camera delivers only ~2.3 Mbit/s for the whole 3-up composite, so one panel is low
  detail. This is NOT fixable from the camera web UI: the firmware accepts ONVIF encoder
  writes, reports them back and ignores them - the delivered stream stayed at ~2.3 Mbit/s and
  14 fps through bitrate settings of 8192, 12288, 16384 and 20480 (measured 2026-09-07). See
  docs/camera.md.
- Lid-closed operation still wants:  sudo pmset -c sleep 0 disablesleep 1
- If the camera IP changes, nothing needs doing by hand: stream.sh's cam_ip_watcher probes
  port 554 every 30s, re-discovers via ONVIF, rewrites CAM_URL in conf/stream.env and the
  reader follows log/cam_ip. bin/camscan.py is still there to inspect the LAN by hand.
