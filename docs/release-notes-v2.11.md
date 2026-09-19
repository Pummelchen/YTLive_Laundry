# YTLive_Laundry 2.11 — the recording is verified, not assumed (and without a new credential)

2.11 closes a silent-loss class on the one thing this project exists to produce: the 8-hour
recording. Two segments had to be discovered by hand as *"Video unavailable"* before anything
noticed, and a third was verified `8h4m` at the cut and published at `7h53m47s` with nothing
looking again. Full detail is in [`CHANGELOG.md`](../CHANGELOG.md).

- Built from tag `v2.11`
- Contents: the tagged tree **without `MP3/`**, without `backup/` and without `AUDIT/`
  (`git checkout v2.11 -- MP3` restores the music library). No credentials or runtime state are in
  any archive: `conf/stream.env`, `conf/yt_oauth.json`, `conf/watchdog.env`,
  `conf/heartbeat.token` and `log/` are gitignored and were never committed.
- Source archive, not a build product: nothing to compile, no binaries, nothing to sign.
- **No new Google authorization.** By operator policy the fixes use only what already exists: the
  streamer's own yt-dlp (its address is not bot-checked), the heartbeat push the streamer already
  sends, and no YouTube read from the watchdog host at all — its datacenter address is bot-checked
  and an account login there would expire and reintroduce the problem.

## 1. A recording closed outside a rotation was never verified

`log/vod_pending` was fed only by `record_rotation`. A broadcast closed by YouTube's **autoStop**
instead — a publisher death, a crash, a reboot — was registered nowhere, so its recording was
never checked. Measured 2026-09-20: **`D9kF4Rf9uPU`**, created by the post-outage recovery start
rather than by a rotation, has no verdict anywhere and now answers *"Video unavailable"*.
`3Cnxr6fTrWk` (the segment the 2026-09-18 outage cut short) is in the same state.

`register_predecessor()` registers the broadcast that was live when the process last stopped. It
reads `log/broadcast_started` **before** `refresh_broadcast_clock()` rewrites it, and
`vod_pending_add()` is idempotent, so an id can be registered by any path without duplicating.

## 2. The first verdict is optimistic, and nothing re-read it

The duration is read minutes after the cut, from the machine that closed the broadcast. YouTube
keeps re-encoding and trims the head afterwards:

| Segment | Wall | Published | Trim |
|---|---|---|---|
| `ycAbb2G_Q2U` | 8h04m16s | **7h53m47s** | **10.5m** |
| `PxXbNbduIOQ` | 8h04m23s | 8h03m22s | 1.1m |
| `BiTn4WxnIAE` | 8h03m18s | 8h02m31s | 0.8m |
| `oG_DUHXFPUA` | 8h03m22s | 8h03m14s | 0.1m |
| `swvTSq2I-To` | 8h03m11s | 8h02m46s | 0.4m |

Against the 8h03m wall the published recording normally lands **8h02m–8h03m** — inside the
operator's 8:02–8:05 target — and one outlier landed **below 8h00m**. So the missing thing was
never margin (beating a 10.5-minute trim would need an 8h15m wall and would push every normal
segment out of the band); it was **verification**.

`recheck_final_vods()` re-reads the published duration `VOD_RECHECK_AFTER` (24 h) later and files:

- **`short`** when it is under **`VOD_MIN_SECONDS` (8h00m)** — with the id, the duration and the
  floor in the log line, and the segment's URL;
- **`gone`** when the recording is no longer available at all;
- `ok` again when it settled whole, which rewrites the optimistic line with the settled number.

It is a **detection, not a repair**: by then the recording is published, and what the alarm can
change is the next cut. That trade is deliberate and stated, not hidden.

## 3. The two surfaces that needed the answer

- **`bin/status.sh`** reports them as failures, with the ids:
  `FAIL 1 short / 0 gone recording(s) - the published duration is below the floor or the video is
  no longer available`, plus a note that the wall clock is 8h03m and YouTube's own trim is what
  makes the published number smaller.
- **The heartbeat payload carries `vod_problem`**, so the off-host watchdog learns it through the
  push it already receives. `bin/yt_watchdog.py` alerts on it as its **own episode** — reported
  while the channel is live, unable to hide or be hidden by a dark alert — and believes it only
  while the push is fresh, so an old problem cannot page about a recording a later good segment
  replaced. The window is 24 h.

## 4. The alert no longer advises something impossible, and can name the segment

- The dark-alert body taught `pmset … autorestart`, which T-29 measured as **accepted and
  ignored** on this MacBookAir7,2. It now says that plainly, warns that a power cut leaves the
  machine off, and separates the 2026-09-18 network cause from the `pmset` power class.
- Alerts from the watchdog host said `video id : none` because its yt-dlp is bot-blocked. The
  streamer already pushes its broadcast id, so that is the display fallback. Scraping the page was
  rejected on measurement: the first `videoId` in the HTML is a **related** video
  (`p87TUkMUgx4`), not the broadcast.

## Files in this release

| File | Change |
|---|---|
| `bin/stream.sh` | `register_predecessor()`, `vod_schedule_recheck()`, `vod_state_merge()`, `recheck_final_vods()`; `short`/`gone` verdicts; `VOD_MIN_SECONDS` / `VOD_RECHECK_AFTER` / `log/vod_recheck`; both passes called at startup and at every rotation |
| `bin/status.sh` | the short/gone recording failure line, with the ids and the wall-clock note |
| `bin/yt_heartbeat.py` | `vod_problem()` and the `vod_problem` payload field |
| `bin/yt_watchdog.py` | `vod_state()`, the `vod`/`vod_recover` rule and bodies, `human_vod()` on the status page, the pushed-broadcast-id display fallback, and the corrected power advice |
| `tests/t07_watchdog.sh` | 159 → **174** checks: the vod episode (live-channel alert, no repeat, reminder, recovery, freshness), the id fallback, and that the body no longer advises `autorestart` |
| `tests/t15_resilience.sh` | 23 → **32** checks: predecessor registration, the `short` verdict, the scheduled re-check, and the re-check filing short/gone/ok |
| `tests/t16_heartbeat.sh` | 54 → **61** checks: `vod_problem` in the payload, ok is not a problem, newest wins, the window forgets |
| `VERSION`, `CHANGELOG.md`, `AGENTS.md`, `README.md`, `RELEASE.md` | 2.10 → **2.11**, and the suite count 707 → **738** |

## Verification

- The full suite is **738 checks**, all passing.
- The VOD logic is driven as pure functions against stubs (`t15`): the predecessor taken from
  `log/broadcast_started`, a below-floor recording filed `short` rather than `ok`, a settled
  re-check rewriting the verdict, and a vanished recording filed `gone`.
- The payload parsing is exercised against real files (`t16`), including the freshness window.
- The watchdog rule is exercised through `decide()` (`t07`), including that a recording alert does
  not claim the outage episode.
- **Measured on the live streamer after deploying:** `register_predecessor` logs the predecessor,
  and the re-check files `ycAbb2G_Q2U` as `short` at **7h53m47s** — the real outlier, detected by
  the code rather than by hand. That also produces the first `vod` alert from the watchdog, which
  is the feature working.

## Deploying this

    bin/deploy-release.sh --tag v2.11 --go                 # streamer: the VOD verification and status
    bin/watchdog-install.sh --start && systemctl restart ytlive-watchdog   # watchdog host: the rule
    journalctl -u ytlive-watchdog -n 3                      # must say version=2.11

An install is not a restart: 2.9's install left a 2.7 loop running and its alerts kept the old
body, so the loop's own start line is the check.

```
SHA256  SHA256_PENDING
BYTES   ARCHIVE_BYTES_PENDING
```
