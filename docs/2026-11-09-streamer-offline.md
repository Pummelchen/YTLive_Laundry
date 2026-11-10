# The 2026-11-09/10 outage: 26 hours dark after the network work, and a key that matched nothing

The shop's network was being changed on 2026-11-09 - the operator's note that day records a
router replacement, with the box to be re-plugged into it on site. The channel went dark at
**17:29 WIB** that evening and was live again at **19:56 WIB on 2026-11-10** — about 26 hours
and 27 minutes, with a short return in between. No code change was needed; the streamer and
the external watchdog did what they are built to do. This page records the evidence, because
the streamer's own log is not the clock of record once a machine has been power-cycled several
times in one day.

All times below are **WIB (UTC+7)**, the shop's clock. The watchdog host's journal (UTC, NTP)
is the authoritative clock for this incident; the streamer's `log/stream.log` is authoritative
only for the sequence of events inside a single boot.

## Timeline

| WIB | Event |
|---|---|
| 11-09 13:18 | 16:9 broadcast `XkyqG8AWXnI` goes live |
| 11-09 17:29 | that segment ends at **4h11m** of a planned 8h10m — the box is gone |
| 11-09 23:31 | watchdog: `streamer SILENT + host unreachable (6h15m)` |
| 11-10 05:31 | watchdog: same, `12h15m` |
| 11-10 06:29 | streamer boots, `stream.sh` starts, `l28mto_OYTc` live 06:34, `T2xpUXgnWQI` live 07:08 |
| 11-10 07:25 | watchdog: `SILENT + host unreachable (15m36s)` — gone again |
| 11-10 07:58 | watchdog: `heartbeat is back` … 08:00 `SILENT (50m25s)` |
| 11-10 11:37 | the boot that is still running (`uptime`, `kern.boottime`) |
| 11-10 11:43 | watchdog: `heartbeat is back` |
| 11-10 11:58 | watchdog: `channel DARK for 15m21s` |
| 11-10 11:44 → 19:52 | **every `prepare` answers `no liveStream on this channel uses the configured YT_KEY`** |
| 11-10 17:58 | watchdog: `channel DARK for 6h15m` |
| 11-10 19:52 | `prepare` answers `READY` again and binds `dpEZT1kvPJE` |
| 11-10 19:56 | watchdog: `channel is LIVE again` |
| 11-10 20:03–20:14 | `net_watch` ladder: `NOGW` → `NOWAN` → `OK` twice; ingest reconnects |
| 11-10 20:12 | 16:9 live on `JdbuogBL2tE` |
| 11-10 20:17 | Shorts live on `IRq5gAhWlFw` |
| 11-10 20:51 | 16:9 cut onto `D-NlhLhdHwY` (native, 22 s), next cut 8h10m later |
| 11-10 20:54 | both feeds verified by pulling a frame from the public stream (real camera picture, not the slate) |

## What the evidence proves, and what it does not

Proven:

* **The host was not hung, asleep or full.** `bin/forensics.sh --deep` on the streamer after
  recovery: no `.panic` report, no sleep/wake entries, load ~8 with 0 swap, 158 GiB free.
* **The host did not shut down cleanly.** `who -b` reports `Jan 1 07:00` and `last reboot`
  still ends at 2026-10-29 — there is no wtmp record for any of the 2026-11-10 boots. That is
  what a power cut or a forced restart looks like, not what `shutdown` looks like.
* **There were several boots that day**, at ~06:29, ~10:21 and 11:37 — not one long hang. Each
  one left its own `starting:` line in `stream.log`.
* **The channel was dark because no broadcast could be created**, not because ingest was
  broken: ffmpeg was restarting and the API was answering, but `prepare` could not find the
  configured stream key.

Not proven:

* **Whether the machine's power was cut or it was force-restarted** on site, and by whom. The
  unified log holds no `Previous shutdown cause` record for the window, so this cannot be
  answered from the host.
* **Why the stream key matched nothing between 11:44 and 19:52** and then matched again.
  YouTube's own stream list now holds three streams — the 16:9 key, the Shorts key, and a third
  created during the incident — and `conf/stream.env` was last written at 20:14:21 by
  `cam_ip_watcher`'s camera-IP rewrite. An operator-side edit of `YT_KEY` cannot be ruled out;
  nothing in the host's own logs proves one.

## The second failure: 8 hours of retrying a configuration fault

This is the part worth fixing. From 11:44:50 to 19:52:24 the streamer made **1,704 `prepare`
attempts** — about one every 17 s, because each publisher start re-runs `prepare_broadcast()`
and each failure kills ffmpeg `rc=251` within 15 s:

```
1,589  PUBLISHER died rc=251 ... "Error opening output files: Input/output error"
1,704  PREPARE: {"status": "ERROR", "msg": "no liveStream on this channel uses the
       configured YT_KEY. Check YT_KEY in conf/stream.env ..."}
4,292  API calls in the same window (2,989 liveStreams.list, 1,286 liveBroadcasts.list)
```

At YouTube's list pricing that is most of a day's 10,000-unit pool spent on a condition no
retry could fix. The rotation path already has this guard (`ROTATE_API_RETRY`, 900 s) and the
quota breaker (`log/quota_exhausted`) refuses to make calls once the pool is gone — but the
*publisher-start* path has neither: `prepare_broadcast()` logs the answer and starts the
publisher anyway, so a permanent configuration fault becomes a 15-second loop.

Recorded as an open item in `docs/known-issues.md`; not changed here, because this page is an
incident record and a change to the publisher-restart loop has to be deployed and watched on
the box, not slipped in during a recovery.

## What worked, and is now proven in the field

* **The external watchdog** (`bin/yt_watchdog.py` on the always-on host) sent **15 emails** in
  the window with the right attribution and cadence: host-unreachable, channel-dark (15 min,
  then the 6 h reminder), the recording problem, and one `LIVE again`. This was its first
  multi-hour real outage since it was built for the 2026-09-18 one.
* **`launchd` KeepAlive** restarted both stream agents at every boot with no human action.
* **The rotate-refuses-to-cut-blind rule** held: no broadcast was ended for a successor that
  could not be created.
* **`net_watch.sh`** climbed its ladder twice in the recovery (`NOGW` → `NOWAN` → `OK`) and
  repaired the transport with the DNS rung only — no interface was power-cycled and the
  service order was not touched.
* **The Shorts feed** kept its own broadcast throughout (`VERT_ROTATE=no`) and was live again
  by 20:17.

## If this happens again

1. Read the watchdog host first: its journal is the only clock that survived the reboots
   (`journalctl -u ytlive-watchdog --since "<date>"`).
2. `bin/forensics.sh --deep` on the streamer **before** power-cycling if it answers at all —
   a reboot destroys the in-memory half of the evidence.
3. If `prepare` repeats the `no liveStream ... YT_KEY` answer, stop staring at the streamer and
   compare the key in `conf/stream.env` with Studio → Go Live → Stream key. No amount of
   restarting fixes a key that does not match.
