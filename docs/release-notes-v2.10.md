# YTLive_Laundry 2.10 — the off-host watchdog could not read the channel any more

2.10 repairs the **second channel reader** in `bin/yt_watchdog.py` — the one that shares no code,
no credential and no rate limit with yt-dlp, and whose whole purpose is to keep watching the
channel when yt-dlp is blocked. Its single marker had stopped being served, so the off-host
watchdog reported `channel unknown` for hours and emailed *"the watchdog is blind"*: a true alarm,
because while it lasts nothing is watching the channel. Full detail is in
[`CHANGELOG.md`](../CHANGELOG.md).

- Built from tag `v2.10`
- Contents: the tagged tree **without `MP3/`**, without `backup/` and without `AUDIT/`
  (`git checkout v2.10 -- MP3` restores the music library). No credentials or runtime state are in
  any archive: `conf/stream.env`, `conf/yt_oauth.json`, `conf/watchdog.env`,
  `conf/heartbeat.token` and `log/` are gitignored and were never committed.
- Source archive, not a build product: nothing to compile, no binaries, nothing to sign.

## What was wrong

The reader looked for one string, `"isLiveNow":true`. It is no longer served. Both readers were
therefore blind at once — and the first one cannot cover for it from that host:

    yt-dlp on deltasona : ERROR: [youtube] Fo0bJ7V28zU: Sign in to confirm you're not a bot
    the same command on
    the streamer         : Fo0bJ7V28zU|True

So the block is specific to the watchdog host's address, not to the channel. The plain HTTPS fetch
was no better: from a European address YouTube answers `302` (the consent wall) unless the request
carries a consent cookie — and the bot-check page has no live marker either.

## What it does now

Measured from the watchdog host on 2026-09-20, `/<channel>/live` returns one of three documents:

| The channel is | YouTube serves | Keys | Reader says |
|---|---|---|---|
| live | a **video page** | `"isLive":true`, `liveIndicatorText`, `videoDetails`, `playabilityStatus` | `live` |
| not broadcasting | its **channel page** | `channelMetadataRenderer`, canonical `/channel/UC…`, none of the video keys | `offline` |
| anything else | a consent wall, a bot check, a further markup change, an error | neither shape | `unknown` |

The reader now sends `Cookie: SOCS=CAI; CONSENT=YES+cb` and a pinned `Accept-Language: en-US`, so a
European address gets the page rather than the wall and the surrounding markup (and its key names)
does not vary by IP. `"isLiveNow"` is still accepted for older page variants.

**Both directions are positive evidence, and that is the point.** `offline` requires the
channel-page shape — `channelMetadataRenderer` with no `playabilityStatus` — not merely the absence
of a live marker, because a false offline would page for a healthy stream. Anything fitting neither
shape stays `unknown`.

**The limit, stated plainly:** yt-dlp remains bot-blocked from that host, so the off-host watchdog
now depends on this one reader. It is a different failure mode from yt-dlp's (no credential, no
rate limit, no API), but it is one reader, and a further markup change would blind it again — which
is exactly what the `unknown` default and the 45-minute "blind" alert exist to surface. Giving the
watchdog host a YouTube API credential would be the robust fix, and it is a credential-direction
decision for the operator, not a code change to make unilaterally.

## Files in this release

| File | Change |
|---|---|
| `bin/yt_watchdog.py` | `LIVE_MARKERS` / `LIVE_INDICATOR` / `CHANNEL_PAGE_MARKER` / `VIDEO_PAGE_MARKER`; `http_channel_state()` sends the consent cookie and language pin and requires a positive shape in both directions |
| `tests/t07_watchdog.sh` | 153 → **159** checks: the 2026-09 video page reads live, the channel page reads offline, a page that is neither shape stays unknown, contradictory keys stay unknown, and the request carries the consent cookie and the language pin |
| `AGENTS.md`, `README.md`, `RELEASE.md` | suite count 701 → **707** |
| `VERSION`, `CHANGELOG.md` | 2.9 → **2.10**, with the section above |

## Verification

- The severity of the fix is that it was measured against the real pages, from the host that was
  blind: `live` for this channel, `offline` for two channels that are not broadcasting.
- `tests/t07_watchdog.sh`: **159 checks**, all passing, including the fail-safe direction — a page
  that is neither shape (a future markup change) is `unknown`, never `offline`.
- The full suite is **707 checks** (2.10's six new ones plus 2.9's 701).
- After deploying, the loop must be **restarted**, not merely installed, and its own start line read
  back: `watchdog starting: version=2.10` (AGENTS.md and RELEASE.md now say so — 2.9's install left
  a 2.7 loop running and its alert emails still carried the old body).

## Deploying this

    bin/deploy-release.sh --tag v2.10 --go                 # on the streamer (tree identity)
    bin/watchdog-install.sh --start && systemctl restart ytlive-watchdog   # on the watchdog host
    journalctl -u ytlive-watchdog -n 3                      # must say version=2.10

Then `bin/yt_watchdog.py status` should read `channel state : live` instead of `unknown`.

```
SHA256  SHA256_PENDING
BYTES   ARCHIVE_BYTES_PENDING
```
