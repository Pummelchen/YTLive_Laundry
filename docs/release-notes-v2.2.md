# YTLive_Laundry 2.2 — the external watchdog and host hardening

The streamer went dark for 10h23m on 2026-09-18 and the project's own retry-only design could not
say so, because the machine that would have said it was the machine that was gone. This release
adds the one component that watches from outside, and turns the already-documented `pmset` fix
into a runbook. Full detail is in [`CHANGELOG.md`](../CHANGELOG.md).

- Built from tag `v2.2`
- Contents: the tagged tree **without `MP3/`**, without `backup/` and without any audit report. The
  25-track, 328 MB music library is byte-identical in git at the same tag (`git checkout v2.2 -- MP3`).
- Source archive, not a build product: nothing to compile, no binaries, nothing to sign.

## Why this release exists

At **10:19:54Z on 2026-09-18** the publisher's ingest stopped, 5h14m into an 8h03m segment. Tailscale
recorded its last contact with `ternak-macbook` at **10:20:00Z** — the same second. The host was gone.

The automation up to that moment was healthy by every measure available: four consecutive 8.05h
segments, 4.5–5.2 min gaps, no missed rotation. What failed was not a script. The shop's uplink was
still up (its public egress IP answered ICMP 10/10 at ~5 ms) while the Mac answered nothing, which
puts the failure in the host: most likely a shop power/router loss, after which the Mac ran on
battery and slept, and never came back because `autorestart` is off and lid-closed sleep is not
disabled.

Two things turned that into a ten-hour outage:

1. **A process that is not running cannot retry.** Every failure path in this project is a retry
   loop, and launchd's `KeepAlive` revives a job that exits — not a machine that is off or asleep.
   The retry-only design is correct for the failures it was written for, and structurally blind to
   the host dying.
2. **Nothing was allowed to say anything.** The rule on the streamer is "no notifications — every
   failure path retries". That rule is why a channel can be dark for ten hours with every log
   looking exactly like a channel that is fine.

## What is new

**`bin/yt_watchdog.py` — the watchdog that runs off the streamer.** Portable, standard-library
Python 3, designed to live on an always-on host and never on the machine it watches. It watches two
independent signals:

- **the channel**, via `yt-dlp`. The `live` / `offline` / `unknown` split and the `OFFLINE_SIGNS`
  phrase list are taken from `bin/yt_check.py` deliberately, so that `UNKNOWN` — the lookup failed —
  can never be mistaken for `OFFLINE` — the channel is dark. A yt-dlp rate limit must not page
  anyone, any more than it may trigger a rotation.
- **the streamer's presence in the tailnet**, via `tailscale status --json`. This is what turns
  "dark" into a diagnosis (host gone means power or network; host up means publisher, token or
  camera) and it cannot be blinded by a YouTube change the way `yt-dlp` can.

| Situation | Behaviour |
|---|---|
| Channel live | silence; any episode is cleared |
| Dark < 15 min | silence — a healthy rig is dark ~5 min every 8h03m |
| Dark ≥ 15 min | one email, reminded every 6 h while it lasts |
| Live again after an alerted outage | one "LIVE again" email |
| `UNKNOWN` (yt-dlp failing) | **never** a dark alert |
| `UNKNOWN` ≥ 45 min | one "the watchdog is blind" email |
| Host gone **and** channel unreadable ≥ 15 min | treated as an outage, attributed to the host |
| Host absent but channel verifiably live | silence |

An alert that cannot be delivered is **spooled to disk and retried** on later cycles. The mail path
is how outages get reported, so losing a message would hide the very thing being watched.

**Deployment.** `bin/watchdog-install.sh` installs it as a systemd unit on Linux or a LaunchAgent on
macOS, seeds `conf/watchdog.env` at mode 0600, and deliberately does not pretend that starting is
safe — `test-alert` must succeed first. It is deployed and running on the Intel VPS under systemd as
`ytlive-watchdog`.

**Email.** Gmail enforces SPF or DKIM on every sender; unauthenticated direct-to-MX from a VPS was
rejected here as `550 5.7.26 "the sender is unauthenticated"` (and over IPv6 as a PTR complaint).
Delivery therefore uses authenticated Gmail submission on `smtp.gmail.com:587` with an app password,
which lives in the gitignored `conf/watchdog.env`.

**Host hardening, as a runbook.** `docs/operations.md` gained the section that `docs/known-issues.md`
had been noting as still-wanted:

```
sudo pmset -a autorestart 1             # come back up after a power failure
sudo pmset -c sleep 0 disablesleep 1    # never sleep, lid closed included
```

with the limit stated plainly: neither setting survives losing power entirely, and that needs a UPS
on the Mac *and* the router. **Not yet applied** — the streamer needs physical access.

## Checks run for this release

| What | Result |
|---|---|
| The project's own suite, serially | **checked** — 168 checks, all passing |
| `tests/t07_watchdog.sh` (new) | **checked** — 49 checks; the policy is a pure function of time, so no clock and no network |
| That the new tests can actually fail | **checked** — t07 failed 13 checks, then 2, against the code as first written (the `or now` epoch bug and two wrong assertions), and `status` crashed on the real host until the `LastSeen` type bug was fixed |
| The watchdog against the **real, ongoing outage** | **checked** — on the VPS it reported `channel=offline`, `host=down`, `last seen 2026-09-18T10:20:00Z`, and produced a correctly-headered alert |
| Alert generation end to end on the watchdog host | **checked** — a real alert was written with `Message-ID`, `Date` and a full body |
| Email delivery to the operator's Gmail | **not checked at the time of tagging** — the transport is built and the failure modes were measured, but the app password is supplied at deploy time; `test-alert` is the gate before the service is trusted |
| `pmset` hardening on the streamer | **not checked** — the streamer is unreachable and needs physical access |
| The stream restored | **not checked** — the streamer must be woken first; see the tracker |

## Deploying this does not happen by itself

The production streamer is currently **offline** (since 2026-09-18T10:19:54Z) and needs physical
access before anything can be deployed to it. Once it is back, its `bin/status.sh` and
`bin/smoke_test.sh` come first, then `bin/deploy-release.sh --tag v2.2` — and read
[Updating and rollback](https://github.com/Pummelchen/YTLive_Laundry/wiki/Updating-and-Rollback)
first. The watchdog itself is already deployed and does not depend on the streamer.

```
SHA256  SHA256_PENDING
BYTES   ARCHIVE_BYTES_PENDING
```
