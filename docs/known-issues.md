# Known issues

**This page is cosmetic and known-limitation notes, not the task list.** The authoritative
open-work list is the
[wiki Project-Tracker](https://github.com/Pummelchen/YTLive_Laundry/wiki/Project-Tracker);
closed items are deleted from it, so this file can only ever lag it. Open there at the tracker's
last update (2026-09-17): T-01, T-02, T-06, T-08–T-10, T-12–T-20, T-23–T-26 and T-28.

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
- Host hardening is still wanted on the streamer: `sudo pmset -a autorestart 1` and
  `sudo pmset -c sleep 0 disablesleep 1`, so it returns after a power failure and never sleeps
  with the lid shut. On 2026-09-18 the MacBook lost power, slept on battery and stayed dark
  10 h 23 m; neither setting helps with no power at all - that needs a UPS on the Mac and the
  router. Commands, verification and the limit: docs/operations.md, "Host hardening".
- If the camera IP changes, nothing needs doing by hand: stream.sh's cam_ip_watcher probes
  port 554 every 30s, re-discovers via ONVIF, rewrites CAM_URL in conf/stream.env and the
  reader follows log/cam_ip. bin/camscan.py is still there to inspect the LAN by hand.
