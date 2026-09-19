# YTLive_Laundry — version 2.7, live production snapshot

|  |  |
|---|---|
| **Version** | `2.7` |
| **Git commit** | `230009117f0ada8373bf3f9236903be254b4aa42` — *"watchdog status: read the disk level live, like the heartbeat line already does"*, 2026-09-19 22:30:27 +0700 |
| **Git tag** | `v2.7` (annotated, points at that commit) |
| **Snapshot taken** | 2026-09-19 |
| **Files** | 98 (see `SHA256SUMS`) |
| **Size** | ~1.7 MB |
| **Deployed to** | `user@ternak-macbook` (100.75.83.5) on 2026-09-19 22:31 WIB by `bin/deploy-release.sh --tag v2.7 --go`; the host was rebooted at 23:15 WIB the same evening |

## Why this exists

`backup/README.md` says one directory per released-to-production revision, and only `1.0` was
ever taken. Version 2.7 carried the largest change this project has had — the dead-man heartbeat
delivered end to end, the disk alert that had been blocked since 2.6, a rotation clock that
survives a restart, and the record corrections — and a snapshot is cheaper than reconstructing
"what was actually running" from tags, deploy logs and memory.

It is a **source snapshot, not a release.** The release is the tag and the GitHub Release page
with its archive and digest; this folder is for reading and diffing without a checkout.

## What this is NOT

- **Not a copy of the deployed working tree.** `conf/playlist.txt` differs on the host (it is
  rebuilt per machine by `install.sh`), and `conf/stream.env`, `conf/yt_oauth.json`,
  `conf/heartbeat.token` and `log/` are gitignored runtime state that has never been committed.
- **Not including `MP3/`, `backup/` or `AUDIT/`.** The 25 music tracks (328 MB) are byte-identical
  in git at this tag (`git checkout v2.7 -- MP3` restores them) and are excluded from every
  archive by `release.sh` too.
- **Not the newest `main`.** Two documentation-only commits sit on top of this tag (the
  dual-stream verdict and its experiment result); nothing in them is deployed.
- **Not a claim that 2.7 is defect-free.** See the next section.

## What 2.7 contains that matters in production

- **T-34 — the dead-man heartbeat is delivered.** `bin/yt_heartbeat.py` (one file, both ends):
  the streamer pushes its status every 300 s to a listener on the watchdog host, which writes it
  atomically at 0600. `bin/stream.sh` starts the pusher only when `HEARTBEAT_URL` is set, passes
  the secret as a **file path and never as argv**, and reaps it in the TERM/INT trap.
  `conf/watchdog.env.example` ships `WATCH_HEARTBEAT=""` on purpose: an absent file never alerts,
  an armed watchdog with no pusher pages for a healthy streamer.
- **T-13 — the disk pages a human.** The same heartbeat body carries `disk_free_mb`, so
  `bin/yt_watchdog.py` alerts below `WATCH_DISK_MIN_MB` (default 2000 MB), reporting while the
  channel is live and believing the figure only while the push is fresh.
- **T-08/T-12/T-19/T-20 — the 2.7 stream fixes**: the rotation clock is re-adopted after a
  restart, a recording cannot lose its verdict to a trimmed log, the ingest bounce signals the pid
  it owns, and the monitor beats before it grades.
- **T-01 — closed by decision.** The OAuth app stays in Testing, so an elapsed token countdown is
  advisory (`WARN`) and never reported as a dead credential.
- **Truthful counts.** The suite is 631 checks at this tag, and `release.sh` counts checks rather
  than lines containing "PASS".

## Known limits in 2.7

- **`autorestart` is not supported on this hardware** (MacBookAir7,2): a root write returns 0 and
  the key never appears, so `bin/harden-host.sh --check` still fails on it. 2.8 teaches the check
  to tell "unsupported" from "off".
- **`bin/status.sh` does not surface YouTube's own `healthStatus`**, so a transient
  `videoIngestionStarved` is invisible while it lasts. Added in 2.8.
- **The watchdog's status page prints `last seen 1-01-01` for an online peer** (Tailscale's Go zero
  time). Cosmetic; fixed in 2.8.
- **The transport ladder cannot renew DHCP or flush the resolver cache** — both need root, and the
  narrow NOPASSWD rule arrives in 2.8 (`conf/ytlive-sudoers`).
- Dual stream cannot be enabled from code: the API exposes no field, verified with the feature
  switched on (`docs/youtube.md`, and `conf/broadcast_template.json` → `manual.dualStream`).

## Restoring

    git checkout v2.7 -- .          # restore 2.7 into the working tree (includes MP3/)

Or use this folder as a plain tree:

    rsync -a backup/2.7/ ~/Downloads/YTLive/

Then supply `conf/stream.env` (with `YT_KEY`), `conf/yt_oauth.json` (`bin/yt_api.py auth`) and,
if the dead-man signal is wanted, `conf/heartbeat.token` plus `HEARTBEAT_URL`. Only one machine
may push to a given stream key at a time.

## Integrity

Every file below was proved against the commit, not merely copied: for all 98 files
`git hash-object <file>` equals `git rev-parse 2300091:<path>` (98 compared, 0 mismatched).

    cd backup/2.7 && shasum -a 256 -c SHA256SUMS
