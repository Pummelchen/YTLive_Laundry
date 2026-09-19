# YTLive - CCTV to YouTube, 24/7

[![Views (14d)](https://img.shields.io/badge/Views_(14d)-29-blueviolet)](https://github.com/Pummelchen/YTLive_Laundry)
[![Contact](https://img.shields.io/badge/Contact-0xa0b1%40gmail.com-blue?style=flat-square&logo=gmail&logoColor=white)](mailto:0xa0b1@gmail.com)

A shop camera in Bengkong, Batam streamed continuously to YouTube from a MacBook, cut
every 8h03m so each segment is archived as a watchable recording rather than lost past
YouTube's 12h limit.

    bin/status.sh              is it healthy? one page, everything that can fail silently
    bin/smoke_test.sh          RUN BEFORE RESTARTING ANYTHING - exit 0 means safe
    bin/yt_api.py status       what YouTube thinks is live
    bin/yt_api.py token        probe the OAuth credential (LIVE/DEAD/UNKNOWN; --offline = days)
    tail -f log/stream.log     watch it work

    launchctl load -w ~/Library/LaunchAgents/com.user.cctv-stream.plist    # start
    launchctl load -w ~/Library/LaunchAgents/com.user.cctv-monitor.plist   # both are needed

**The one thing that needs a human - and only while the OAuth app is in "Testing".** Google
expires a refresh token after 7 days for an External app whose publishing status is
"Testing". Publishing the app to **"In production"** removes that clock, and Google
verification is NOT required to escape it: an unverified published app still works for its
owner (one "unverified app" warning to click past, 100-user cap). Then re-run
`bin/yt_api.py auth`, because tokens issued while Testing keep their 7-day life. If the app
must stay in Testing, re-run `bin/yt_api.py auth` before day 7. With a dead token the stream
keeps running and the current segment's recording is still saved, but no successor broadcast
can be created and the channel goes dark until a human runs auth. `bin/yt_api.py auth` prints
the publish click-path; `bin/status.sh` shows the probe result.

On the streamer there are deliberately no notifications and the logs are the project's own
bookkeeping, not a report anyone reads: nothing there may depend on a human noticing anything,
so every failure path retries instead of reporting. Retrying cannot cover the host itself — on
2026-09-18 the MacBook lost its **network** (DNS and its own LAN) while it stayed awake, the
channel was dark 19 h 26 m, and nothing said so. Two components now cover that class: the
external watchdog ([bin/yt_watchdog.py](bin/yt_watchdog.py), [docs/watchdog.md](docs/watchdog.md)),
the only thing here that runs off the streamer and the only one allowed to notify, and
[bin/net_watch.sh](bin/net_watch.sh), the transport layer underneath the retries, which repairs
a lost network instead of reporting it ([docs/operations.md](docs/operations.md)).

## Documentation

- [docs/files.md](docs/files.md) - Files and layout
- [docs/architecture.md](docs/architecture.md) - Architecture: the two-process design, filters, watchdogs
- [docs/rotation.md](docs/rotation.md) - The 8h03m rotation, recording verification, timing
- [docs/youtube.md](docs/youtube.md) - The API, the token, configuration and thumbnails
- [docs/camera.md](docs/camera.md) - The camera: what it really does, and finding it
- [docs/operations.md](docs/operations.md) - Day to day: control, smoke test, disk and logs
- [docs/machines.md](docs/machines.md) - Installing elsewhere, the SSH mesh, Tailscale
- [docs/known-issues.md](docs/known-issues.md) - Known issues and open items
- [docs/watchdog.md](docs/watchdog.md) - The external watchdog: the one component that runs off the streamer
- [wiki](https://github.com/Pummelchen/YTLive_Laundry/wiki) - the operator's guide: install,
  day-to-day commands, troubleshooting, updating and rollback

## Testing

Two gates. The first now runs in CI on every push and pull request (`.github/workflows/ci.yml`,
macOS runners — the suite is macOS-only); the second still needs a credential, so it cannot run
there and stays a by-hand host gate:

    tests/run.sh          569 checks, credential-free: no camera, network, ffmpeg or credentials,
                          so it is safe to run on the streaming Mac. --list shows what it covers.
    bin/smoke_test.sh     syntax/AST plus the real API commands and prepare --dry-run. Needs
                          conf/yt_oauth.json, so it cannot pass on a bare clone.

Run both before restarting anything. `release.sh` runs the syntax gate and the test suite from
the exported archive before it packs a release.

## Versions

`VERSION` is the only version declaration and `CHANGELOG.md` records what changed. Releases are
source archives with a `.sha256` beside them, built from a tag by `release.sh` — which refuses to
build when `VERSION` and the tag disagree. Nothing is compiled, so there is no binary and nothing
to notarize. The full standard is [RELEASE.md](RELEASE.md).

## The two rules that cost the most to learn

**Bind the broadcast BEFORE ingest starts.** YouTube starts an autoStart broadcast when
ingest ARRIVES at the stream it is bound to. Bind afterwards and it sits in `ready` forever
while manual transitions are refused. Getting this backwards cost 19 minutes of dark air.
See [docs/rotation.md](docs/rotation.md).

**Run bin/smoke_test.sh before restarting anything.** Both outages this project has had came
from editing a path and validating everything except that path. See
[docs/operations.md](docs/operations.md).

## License

MIT — see [LICENSE](LICENSE).

## Contact

Questions, bug reports and suggestions are always welcome. You can contact André Borchert by email at [0xa0b1@gmail.com](mailto:0xa0b1@gmail.com).