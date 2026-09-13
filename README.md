# YTLive - CCTV to YouTube, 24/7

[![Profile Visitors](https://komarev.com/ghpvc/?username=Pummelchen&label=Profile%20Visitors&color=blueviolet&style=flat-square)](https://github.com/Pummelchen)
[![Contact](https://img.shields.io/badge/Contact-0xa0b1%40gmail.com-blue?style=flat-square&logo=gmail&logoColor=white)](mailto:0xa0b1@gmail.com)

A shop camera in Bengkong, Batam streamed continuously to YouTube from a Mac mini, cut
every 8h03m so each segment is archived as a watchable recording rather than lost past
YouTube's 12h limit.

    bin/status.sh              is it healthy? one page, everything that can fail silently
    bin/smoke_test.sh          RUN BEFORE RESTARTING ANYTHING - exit 0 means safe
    bin/yt_api.py status       what YouTube thinks is live
    bin/yt_api.py token        days left on the OAuth token
    tail -f log/stream.log     watch it work

    launchctl load -w ~/Library/LaunchAgents/com.user.cctv-stream.plist    # start
    launchctl load -w ~/Library/LaunchAgents/com.user.cctv-monitor.plist   # both are needed

**The one thing that needs a human.** The OAuth app stays in "Testing", so Google expires
the refresh token every 7 days. Re-run `bin/yt_api.py auth` before it does, or rotation
stops - the stream keeps running but recordings pass 12h and become unrecoverable.
`bin/status.sh` shows the days remaining.

There are deliberately no notifications and the logs are the project's own bookkeeping, not
a report anyone reads: nothing here may depend on a human noticing anything, so every
failure path retries instead of reporting.

## Documentation

- [docs/files.md](docs/files.md) - Files and layout
- [docs/architecture.md](docs/architecture.md) - Architecture: the two-process design, filters, watchdogs
- [docs/rotation.md](docs/rotation.md) - The 8h03m rotation, recording verification, timing
- [docs/youtube.md](docs/youtube.md) - The API, the token, configuration and thumbnails
- [docs/camera.md](docs/camera.md) - The camera: what it really does, and finding it
- [docs/operations.md](docs/operations.md) - Day to day: control, smoke test, disk and logs
- [docs/machines.md](docs/machines.md) - Installing elsewhere, the SSH mesh, Tailscale
- [docs/known-issues.md](docs/known-issues.md) - Known issues and open items

## The two rules that cost the most to learn

**Bind the broadcast BEFORE ingest starts.** YouTube starts an autoStart broadcast when
ingest ARRIVES at the stream it is bound to. Bind afterwards and it sits in `ready` forever
while manual transitions are refused. Getting this backwards cost 19 minutes of dark air.
See [docs/rotation.md](docs/rotation.md).

**Run bin/smoke_test.sh before restarting anything.** Both outages this project has had came
from editing a path and validating everything except that path. See
[docs/operations.md](docs/operations.md).
