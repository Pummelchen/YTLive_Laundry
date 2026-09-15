# YTLive_Laundry

<!-- agent-harnesses:begin -->
> **One instruction file.** This is it. Codex, DeepSeek Harness, OpenCode, Qwen Code, Qoder and Zed read `AGENTS.md` directly, and
> Claude Code reads it through the committed `CLAUDE.md`, which contains nothing
> but `@AGENTS.md`. **Edit only this file** — do not add a second set of
> instructions anywhere.
>
> Do **not** add `.rules`, `.cursorrules`, `.windsurfrules`, `.clinerules`, `.github/copilot-instructions.md` or `AGENT.md`. Zed takes the *first match* from that list, **ahead of
> `AGENTS.md`**, so any one of them silently replaces this file for every Zed user.
<!-- agent-harnesses:end -->

A shop CCTV camera in Batam streamed 24/7 to YouTube from one Mac mini. This is a
macOS-only **operational system, not a reusable library**: zsh scripts plus
stdlib-only Python drive ffmpeg from an ONVIF camera into an 8h03m broadcast
rotation, with a second process watching the public stream and repairing it. It is
in production — the docs record real outages with timestamps and measured
CPU/bitrate figures. There are **no releases and no tags**, so deployment is
`install.sh` on a Mac. The architecture is a deliberate two-process split: a
**reader** (camera RTSP → local UDP, restarts freely) and a **publisher** (UDP + MP3
playlist → YouTube RTMP, runs continuously), so a camera dropout never tears down the
RTMP session.

## Layout

- `bin/` — `stream.sh` (714 lines: reader/publisher, watchdog, rotation, VOD
  verification), `yt_monitor.sh` (the watchdog loop), `yt_api.py` (1148 lines, the
  only thing that can create a broadcast), `yt_check.py` (grades one pulled frame),
  `lib.sh` (shared API helpers), the camera/ONVIF tools (`cam_ip.py`, `camscan.py`,
  `onvif_probe.py`, `cam_config.py`, `cam_reboot.py`), and
  `status.sh` / `smoke_test.sh` / `shuffle_playlist.sh` / `preflight.sh`.
- `conf/` is **tracked**: `stream.env.example`, `broadcast_template.json` (the
  enforced reference), `playlist.txt`, thumbnails, camera XML dumps.
- `docs/` — 7 design/ops notes. `MP3/` — 25 tracks (328 MB, tracked).
- `install.sh` at the root. Gitignored at runtime: `log/`, `conf/stream.env`,
  `conf/yt_oauth.json`, `conf/golden.jpg`.

## Build and test

No build step, and no Python dependency to install: every `.py` is
`#!/usr/bin/env python3` importing only the standard library. `install.sh`
provisions a host instead — it downloads evermeet.cx static `ffmpeg`/`ffprobe` into
`~/.local/bin`, `pip install --user yt-dlp`, and writes two LaunchAgents. Nothing
needs sudo.

```bash
bin/smoke_test.sh     # exit 0 = safe to restart
```

**`smoke_test.sh` fails on a bare clone** (exit 1): its 17 syntax/AST checks pass,
but `yt_api.py prepare --dry-run` needs `conf/yt_oauth.json`. Its read-only API
checks also "pass" on an `{"status":"ERROR"}` body, because they only grep for
`"status"`.

## Run

```bash
launchctl load -w ~/Library/LaunchAgents/com.user.cctv-stream.plist
launchctl load -w ~/Library/LaunchAgents/com.user.cctv-monitor.plist
bin/status.sh          # --no-net skips the API calls
touch log/rotate_now   # force a rotation
```

Both agents are required, and `bin/status.sh` reports on both — it is the single
place that answers "is it healthy". Health covers both jobs, the moving frame
counter, heartbeat age, the token, YouTube's own view, camera port 554, disk,
rotation history, config drift and VOD tallies.

**The rotation order is mandatory.** Every 8h03m the publisher is killed so YouTube
closes and saves the VOD, and `prepare_broadcast()` must create and bind the next
broadcast **before** ffmpeg pushes — `enableAutoStart` fires on ingest *arrival*,
and binding afterwards leaves the broadcast in `ready` forever.

## Identity

**No version constant anywhere** — no app version, no tags, no releases. Every
tunable is declared in `conf/stream.env` (`ROTATE_HOURS`, `ROTATE_MINUTES`, `MODE`,
`SRC_FPS`/`OUT_FPS`, `CHECK_INTERVAL`, `CORR_MIN`, `FAIL_SECONDS`,
`OFFLINE_SECONDS`, `BLIND_SECONDS`, `ROTATE_GRACE`, `ROTATE_MIN_INTERVAL`,
`ENFORCE_EVERY`, `LOG_MAX_BYTES`, `YT_TITLE_FMT`, `YT_LATENCY`), and the
broadcast's own configuration lives in `conf/broadcast_template.json`.

## Gates

**None automatic.** `.github/` does not exist in the repository — no CI workflow is
tracked, and only GitHub's dynamic CodeQL default setup is active. `bin/smoke_test.sh`
is the entire local gate and nothing runs it for you.

## Traps

- **`CAM_LINK_TIMEOUT="45"` is declared and documented in
  `conf/stream.env.example` but is never read by any script.** Its comment claims the
  watchdog watches the camera's TCP session "instead" of the output frame counter;
  the code only watches `STALL_TIMEOUT` on that counter. With `FILLER="yes"` the
  counter keeps advancing on a held frame, so **the implemented watchdog cannot see a
  dead camera**. The only camera liveness check is `cam_ip_watcher`'s
  `nc -z -G 3 <ip> 554` every 30 s, which re-discovers via ONVIF and rewrites
  `CAM_URL` — it never restarts the publisher.
- **The docs contradict the shipped config, and the shipped config wins.**
  `docs/camera.md` says `CORR_MIN` is 0.35 but `conf/stream.env.example` ships 0.15
  (and `bin/yt_check.py` defaults to 0.60); `docs/operations.md` says
  `LOG_MAX_BYTES=2097152` but the example ships 524288 (and `stream.sh` defaults to
  2097152); `docs/architecture.md` says `aac_at` at 320k while the example sets
  `AAC_ENC="aac"` at 384k. **Trust `conf/stream.env.example`** — the docs describe an
  older revision.
- **`conf/playlist.txt` is tracked with an absolute path into another machine's
  home** (`/Users/user/Downloads/YTLive/MP3/...`). `stream.sh` regenerates the
  playlist only when it is missing or empty, so a cloned copy is used as-is and the
  concat demuxer fails on nonexistent files. `install.sh` rebuilds it;
  `bin/shuffle_playlist.sh` is the manual repair.
- The project **must live at `~/Downloads/YTLive`** — macOS TCC blocks a launchd
  agent in a protected directory without Full Disk Access. `install.sh` probes for
  that with a temporary plist and refuses `--start` until it passes.
  `bin/preflight.sh` hardcodes `$HOME/Downloads/YTLive/...` with no override.
- `conf/stream.env` is **sourced, not exported**, so any value a subprocess needs
  must be passed explicitly — `lib.sh`'s `yt_api_call` exists to do that in one place.
- **A fresh clone cannot install or start** until the operator supplies the stream
  key and OAuth refresh token: `install.sh` dies if `conf/stream.env` is absent, and
  the example ships `YT_KEY=""`.
- **No credentials are committed** — `conf/stream.env` and `conf/yt_oauth.json` are
  gitignored. But the stream key is interpolated into the RTMP URL on ffmpeg's
  command line, so it is visible in `ps`.
- **One task cannot be automated away:** the OAuth app stays in Google's "Testing"
  state, so the refresh token dies every 7 days and `bin/yt_api.py auth` must be
  re-run. With a dead token the stream keeps running but cannot rotate.
- **Destructive commands:** `bin/yt_api.py end` ends the broadcast YouTube is
  currently serving; `ensure-live` creates and deletes broadcasts. `yt_monitor.sh`
  and `stream.sh` use `pkill -9` against `ffmpeg.*rtmp` and `zsh.*yt_monitor.sh`.
- **Only `set -u`** — no `set -e`, no `pipefail` — in `install.sh` and every script
  under `bin/`. Failures are handled by explicit checks, never by aborting.
- macOS-only: `launchctl`, `/bin/zsh`, `caffeinate`, `stat -f`, `plutil`, `nc -G`,
  `sed -i ''`. There is no Linux path, and `install.sh` warns that the static ffmpeg
  is an Intel build needing Rosetta 2.
- `install.sh` downloads ffmpeg/ffprobe with `curl -fL --retry 3` and **no hash or
  signature verification**.
- Logs are trimmed **in place, on the same inode** rather than rotated, because
  ffmpeg holds an `O_APPEND` fd on `publisher.log`. `log/progress.txt` is
  deliberately never trimmed — ffmpeg writes it at a fixed offset.
- ffmpeg runs at `-loglevel error` because the MP3 concat input emitted a warning
  every few seconds (5700+ repeats, most of a 6 MB log).
- **OFFLINE and UNKNOWN are kept distinct everywhere on purpose.** Both
  `yt_live_state()` and `yt_check.py` separate "YouTube said it is dark" from "the
  lookup itself failed", and UNKNOWN never triggers an action — a yt-dlp rate limit
  must not become a rotation that takes a healthy channel off air. The design rule is
  that nothing may depend on a human noticing: there are no notifications, and every
  failure path retries.
- `bin/cam_config.py` reports what the camera has been *told*, not what it delivers:
  the firmware accepts ONVIF encoder writes, reports them back correctly, and
  **ignores them** — the delivered stream stayed at ~2.3 Mbit/s and 14 fps through
  bitrate settings of 8192, 12288, 16384 and 20480.

<!-- release-rules:begin -->
## Releasing

**Read [`RELEASE.md`](RELEASE.md) before cutting a release.** It carries the
generic rules every Pummelchen repository follows, plus this repository's own
section. Do not improvise a release.

The non-negotiables:

- **Apple Silicon only** — build native `arm64` (M1–M6). Never `--arch x86_64`,
  never `ARCHS=arm64 x86_64`, and never `lipo -create`, which is how a universal
  binary gets made.
- **Assert it** — `lipo -archs <binary>` must report exactly `arm64`. A build that
  silently produced a fat binary is a release defect, not a build option.
- **Every release carries the artifacts.** A tag alone is not a release.
- **Identity is single-sourced and enforced** — never bump one declaration of the
  version or build number on its own; the build or CI must fail on a mismatch.
- **Dry run first**; publish only on an explicit flag.
- **Never fetch a model, dataset or dependency to make a gate pass.** A check that
  cannot run is reported *not checked*, and the release notes must name it.
<!-- release-rules:end -->
