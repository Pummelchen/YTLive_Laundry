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
- Host hardening is still wanted on the streamer, and only HALF of it is applied:
  `SleepDisabled` is already 1, but `autorestart` is absent (reported only when enabled, so
  absent means OFF). `sudo bin/harden-host.sh --go` applies and verifies both; it needs the
  machine's password, which a launchd agent does not have. Neither setting would have helped
  with the 2026-09-18 outage - that one was a **network** loss with the host awake and
  unrebooted (see CHANGELOG 2.4), and no `pmset` setting touches the transport. The power
  class still needs a UPS on the Mac **and** the router. Commands and verification:
  docs/operations.md, "Host hardening".
- The streamer's wired NIC has **no carrier** and traffic runs on Wi-Fi. The adapter is a cheap
  WCH `1a86:5394` USB part whose link did not survive a network-service toggle on 2026-09-19.
  A `169.254` self-assigned address on a first-in-order service is a linked-but-unusable
  primary: check the cable, the port it lands on, and replace the adapter with a better one if
  the wired path is wanted as the primary. `bin/status.sh` warns while reality and intent
  disagree. See docs/operations.md, "LAN primary, Wi-Fi backup".
- If the camera IP changes, nothing needs doing by hand: stream.sh's cam_ip_watcher probes
  port 554 every 30s, re-discovers via ONVIF, rewrites CAM_URL in conf/stream.env and the
  reader follows log/cam_ip. bin/camscan.py is still there to inspect the LAN by hand.
