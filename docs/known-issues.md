# Known issues

**This page is cosmetic and known-limitation notes, not a task list.** There is no separate
tracker: what is known and unfixed is described here, and what changed is in `CHANGELOG.md`.

## Known cosmetic issues
- The two ffmpeg warnings this page used to list are suppressed by `-loglevel error` and no
  longer reach a log: "Timestamps are unset in a packet" and the MP3 concat's "Resumed reading
  at pts ... after a lag". The latter repeated 5700+ times and filled most of a 6 MB log
  before the publisher was moved to `-loglevel error`.

## Todo / notes
- **A negative DNS entry on this host outlives the outage that caused it, and cannot be flushed
  without root.** Measured 2026-11-13 after the mains cut: `getaddrinfo()` failed for
  `a.rtmp.youtube.com` and `oauth2.googleapis.com` (`[Errno 8] nodename nor servname provided`)
  while `dig`/`host` resolved both and `www.youtube.com` worked — a poisoned cache in
  `mDNSResponder`, whose resolver #1 is Tailscale's `100.100.100.100`. `sudo dscacheutil -flushcache`
  (the one DNS rule in `/etc/sudoers.d/ytlive-net`) does not clear it, `killall -HUP mDNSResponder`
  needs root the account does not have, and the cache cleared itself after about **11 minutes**. The
  publisher died `rc=251` every ~10 s throughout. If it ever does not clear, the levers are a reboot
  (account password) or a `/etc/hosts` entry (root) — there is no unprivileged one.
- **The camera returns on a new DHCP address after a power cut, and the feeds follow it.** Measured
  2026-11-13: `192.168.1.2` -> `192.168.1.22` after a six-minute cut; `cam_ip_watcher` found it with
  the TCP sweep and both readers followed `log/cam_ip` without a restart. The trap is that the
  streamer's own `en2` may hold the vacated address in the meantime (it took `.2`, so a probe of
  "the camera" was probing this Mac) — `bin/status.sh` and `bin/cam_scan.py` skip local addresses,
  which is why the sweep still reported honestly.
- **A camera that leaves the LAN cannot be recovered remotely.** Measured 2026-11-13, 07:14 WIB:
  the camera stopped answering on 554 and then vanished from L2 entirely - `arp -an` holds
  `(incomplete)` for its address, ICMP fails, and a sweep of `192.168.1.0/24` finds no listener on
  554 or on the ONVIF port 8899 from either interface. Nothing on the streamer can reach it:
  `cam_ip.py`/`cam_scan.py` cannot discover a device that does not answer, `cam_reboot.py` needs
  ONVIF, and the watchguard's camera reboot needs TCP. The feeds stay live on the fallback card
  and return to the camera by themselves when it reappears; the physical fix (power cycle, PoE,
  cabling) needs a human at the shop. The class is therefore a **stated limit, not a bug** - do not
  spend a session trying to raise a dead camera over the network.
- **The Shorts feed runs without rotation on purpose** (`VERT_ROTATE=no`), so YouTube stops
  archiving its broadcast after 12 h: the stream stays up, the recording past that point is
  lost. Set `VERT_ROTATE=yes` if a continuous archive matters more than an uninterrupted
  Shorts stream.
- **A key that matches nothing used to become a 15-second restart loop.** Measured 2026-11-10: the
  configured stream key matched no `liveStream` on the channel for 8 h 08 m, and because
  `start_publisher()` called `prepare_broadcast()` unconditionally and started ffmpeg anyway, that
  cost **1,704 prepares, 1,589 `rc=251` deaths and 4,292 API calls** - most of a day's
  10,000-unit pool. **Fixed 2026-11-10:** that one ERROR class returns a distinct status and arms
  an exponential hold-down (`PREPARE_BACKOFF_BASE` 300 s, doubling to `PREPARE_BACKOFF_MAX`
  1800 s) instead of a restart; a *transient* ERROR still starts the publisher, because ingest is
  what starts an already-bound broadcast. Asserted in `tests/t24_prepare_backoff.sh`. The old
  behaviour is still visible in `docs/2026-11-09-streamer-offline.md`. The camera delivers only ~2.3 Mbit/s for the whole 3-up composite, so one panel is low
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
- The streamer's wired NIC lost its carrier on 2026-09-19 (a cheap WCH `1a86:5394` USB part,
  whose link did not survive a network-service toggle) and the stream ran on Wi-Fi for weeks.
  **It is back:** after the 2026-11-09 router/cabling work `en2` is `active` at 100baseTX with
  `192.168.1.3`, holds the default route via `192.168.1.1`, and `bin/status.sh` reports intent
  and reality agreeing (primary `en2`, carrying `en2`). The lesson still stands for the next
  time it goes: a `169.254` self-assigned address on a first-in-order service is a
  linked-but-unusable primary — check the cable and the port it lands on, and prefer replacing
  the adapter over trusting it. See docs/operations.md, "LAN primary, Wi-Fi backup".
- If the camera IP changes, nothing needs doing by hand: stream.sh's cam_ip_watcher probes
  port 554 every 30s, re-discovers via ONVIF, rewrites CAM_URL in conf/stream.env and the
  reader follows log/cam_ip. bin/camscan.py is still there to inspect the LAN by hand.
