# YTLive — a shop camera on YouTube, 24/7, two feeds

A laundry in Bengkong, Batam, streamed continuously from a 2015 MacBook Air. Two independent
YouTube live broadcasts run from one camera:

| Feed | Format | What it is |
|---|---|---|
| **16:9** | 1080p, music + shop view | the channel's main live stream |
| **9:16** | 1080×1920, same view | a companion broadcast that lands in the **Shorts** feed |

Both are always on: when the camera drops, each feed shows an "offline" card instead of going
dark, and both come back by themselves when the camera returns.

```
bin/status.sh              is it healthy? one page: both feeds, both agents, camera, quota, disk
bin/smoke_test.sh          RUN BEFORE RESTARTING ANYTHING - exit 0 means safe
bin/yt_api.py status       what YouTube thinks is live on the 16:9 stream
tail -f log/stream.log     the main feed
tail -f log/vertical.log   the Shorts feed
```

LaunchAgents (all four are needed):

```
com.user.cctv-stream     the 16:9 feed
com.user.cctv-vertical   the 9:16 Shorts feed
com.user.cctv-monitor    frame grading against a golden reference
com.user.cctv-camscan    every 10 minutes: where is the camera, on Wi-Fi or on the LAN?
```

## How it behaves

- **Rotation.** Each segment is cut after **8 h 10 m**, so YouTube keeps a watchable recording
  instead of dropping it at its 12 h archive limit. The 9:16 feed follows the 16:9 rotation clock
  (`log/broadcast_started`), so both cuts land together and the two feeds stay in step. A cut
  needs the API to create the successor broadcast, so a cut is refused while the API is
  unusable — with a **hard stop at 11 h 15 m**, past which the cut happens anyway, because a
  lost recording is worse than a short dark gap.
- **Camera loss is not channel loss.** The reader feeds a slate card into the same local UDP
  port the publisher reads, so the broadcast stays live; a camera that answers on 554 but cannot
  stream gets slate bursts and, after 10 minutes, an ONVIF reboot.
- **The camera moves.** It is DHCP and takes a new address after a power cut. A watcher probes
  it every 30 s, `bin/find_rtsp.py` sweeps both interfaces, and `bin/cam_scan.py` reports its
  address every 10 minutes into `log/cam_ip`, which both feeds follow.
- **Quota is a circuit breaker.** The YouTube Data API allows 10 000 units a day. When it runs
  out the guard backs off (30 min, doubling, never above 1 h) and is cleared by the first
  successful request — it cannot outlive the reset. `status.sh` shows its state.
- **Thumbnails.** Four hours after a cut, the **01:00:00 frame from that video** becomes its
  thumbnail; a sweep repairs the ten most recent videos that still show the channel's generic
  image.

## Documentation

- [docs/architecture.md](docs/architecture.md) — the two-process design, filters, watchdogs
- [docs/rotation.md](docs/rotation.md) — the rotation, recording verification, timing
- [docs/youtube.md](docs/youtube.md) — the API, the token, configuration, thumbnails
- [docs/camera.md](docs/camera.md) — the camera: what it really does, and finding it
- [docs/operations.md](docs/operations.md) — day to day: control, smoke test, disk and logs
- [docs/machines.md](docs/machines.md) — installing elsewhere, the SSH mesh, Tailscale
- [docs/watchdog.md](docs/watchdog.md) — the external watchdog
- [docs/known-issues.md](docs/known-issues.md) — known issues and open items
- [docs/files.md](docs/files.md) — files and layout
- [docs/2026-10-28-outage-postmortem-and-plan.md](docs/2026-10-28-outage-postmortem-and-plan.md)
  — the October 2026 outage, what caused it, and everything built in response
- [wiki](https://github.com/Pummelchen/YTLive_Laundry/wiki) — the operator's guide

## Testing

`.github/workflows/ci.yml` runs the suite on every push (macOS runners — it is macOS-only).
`bin/smoke_test.sh` needs `conf/yt_oauth.json`, so it stays a by-hand host gate.

```
tests/run.sh            800+ credential-free checks (--list to see them)
bin/smoke_test.sh       syntax/AST plus the real API commands and prepare --dry-run
```

Run both before restarting anything.

## The two rules that cost the most to learn

**Bind the broadcast BEFORE ingest starts.** YouTube starts an autoStart broadcast when ingest
*arrives* at the stream it is bound to; bind afterwards and it sits in `ready` forever while
manual transitions are refused. Getting this backwards cost 19 minutes of dark air. See
[docs/rotation.md](docs/rotation.md).

**Run bin/smoke_test.sh before restarting anything.** Both outages this project has had came
from editing a path and validating everything except that path. See
[docs/operations.md](docs/operations.md).

## Working on this repository

`main` is the only branch and the only artifact: there are no GitHub releases and no version
tags. `VERSION` names the current checkout and `CHANGELOG.md` records what changed.

## License

MIT — see [LICENSE](LICENSE).

## Contact

André Borchert — [0xa0b1@gmail.com](mailto:0xa0b1@gmail.com)
