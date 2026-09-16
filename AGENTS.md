# YTLive_Laundry

<!-- agent-harnesses:begin -->
> **One instruction file.** This is it. Codex, DeepSeek Harness, OpenCode,
> Qwen Code, Qoder and Zed read `AGENTS.md` directly, and Claude Code reads it
> through the committed `CLAUDE.md`, which contains nothing but `@AGENTS.md`.
> **Edit only this file** — do not add a second set of instructions anywhere.
>
> Do **not** add `.rules`, `.cursorrules`, `.windsurfrules`, `.clinerules`,
> `.github/copilot-instructions.md` or `AGENT.md`. Zed takes the *first match*
> from that list, **ahead of `AGENTS.md`**, so any one of them silently
> replaces this file for every Zed user.
<!-- agent-harnesses:end -->

A shop CCTV camera in Batam streamed 24/7 to YouTube from one MacBook. This is a
macOS-only **operational system, not a reusable library**: zsh scripts plus
stdlib-only Python drive ffmpeg from an ONVIF camera into an 8h03m broadcast
rotation, with a second process watching the public stream and repairing it. It is
in production — the docs record real outages with timestamps and measured
CPU/bitrate figures. There are **no releases**, so deployment is
`install.sh` on a Mac. The only tag is `v1.0`, and it is not a release: it marks the
commit that was live in production on 2026-09-16 and is snapshotted under `backup/1.0/`
(see `backup/README.md`). The architecture is a deliberate two-process split: a
**reader** (camera RTSP → local UDP, restarts freely) and a **publisher** (UDP + MP3
playlist → YouTube RTMP, runs continuously), so a camera dropout never tears down the
RTMP session.

## Layout

- `bin/` — `stream.sh` (774 lines: reader/publisher, watchdog, rotation, VOD
  verification), `yt_monitor.sh` (the watchdog loop), `yt_api.py` (1250 lines, the
  only thing that can create a broadcast), `yt_check.py` (grades one pulled frame),
  `lib.sh` (shared API helpers), the camera/ONVIF tools (`cam_ip.py`, `camscan.py`,
  `onvif_probe.py`, `cam_config.py`, `cam_reboot.py`), and
  `status.sh` / `smoke_test.sh` / `shuffle_playlist.sh` / `preflight.sh` /
  `ssh_mesh.sh`.
- `conf/` is **tracked**: `stream.env.example`, `broadcast_template.json` (the
  enforced reference), `playlist.txt`, thumbnails, camera XML dumps.
- `docs/` — 8 design/ops notes. `MP3/` — 25 tracks (328 MB, tracked).
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

**`smoke_test.sh` fails on a bare clone** (non-zero: exit 2 when `~/Downloads/YTLive`
does not exist, otherwise exit 1): its 17 syntax checks (9 shell files including
`install.sh`, 8 `.py`) pass, but the read-only API commands (`token`/`status`/`verify`)
and `yt_api.py prepare --dry-run` all need `conf/yt_oauth.json`. Each of those is judged
on a STATUS that means the command answered (`OK`/`LIVE`/`EXPIRING`/`DRIFTED`/`READY`/...):
an `{"status":"ERROR"}` body now FAILS, where an earlier revision grepped for `"status"`
alone and passed it.

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

**No version constant anywhere** — no app version, no releases, and no version literal
in any script. The single tag, `v1.0`, is a frozen snapshot of the deployed code, not a
release (see `backup/README.md`). Every tunable is declared in
`conf/stream.env` (`ROTATE_HOURS`, `ROTATE_MINUTES`, `MODE`,
`OUT_FPS`, `CHECK_INTERVAL`, `CORR_MIN`, `FAIL_SECONDS`, `OFFLINE_SECONDS`,
`BLIND_SECONDS`, `ROTATE_NATIVE_WAIT`, `ROTATE_GRACE`, `ROTATE_MIN_INTERVAL`,
`ROTATE_WITHOUT_API`, `ROTATE_API_RETRY`, `ENFORCE_EVERY`, `LOG_MAX_BYTES`,
`YT_TITLE_FMT`, `YT_LATENCY`), and the broadcast's own configuration lives in
`conf/broadcast_template.json`. Some declared names are read by no code at all —
see the dead-knobs trap below.

## Gates

**None automatic.** `.github/` does not exist in the repository — no CI workflow is
tracked, and only GitHub's dynamic CodeQL default setup is active. `bin/smoke_test.sh`
is the entire local gate and nothing runs it for you.

## Traps

- **`CAM_LINK_TIMEOUT="45"` is declared in `conf/stream.env.example` but read by no
  script.** It is one of the dead knobs listed below, and its old comment claimed the
  watchdog watched the camera's TCP session "instead" of the output frame counter -
  false. The code only watches `STALL_TIMEOUT` on that counter, and the filler base
  layer is always on, so the counter keeps advancing on a held frame and **the
  implemented watchdog cannot see a dead camera**. The only camera liveness check is
  `cam_ip_watcher`'s `nc -z -G 3 <ip> 554` every 30 s, which re-discovers via ONVIF
  and rewrites `CAM_URL` — it never restarts the publisher.
- **Several example knobs are read by no code at all.** `FILLER`, `SRC_FPS`,
  `ENC_FPS`, `FPS_MODE`, `SNAP_INTERVAL` and `CAM_LINK_TIMEOUT` are declared in
  `conf/stream.env.example` and never read by any script; the example now marks each
  one. (`MP3_DIR` is read only by `bin/shuffle_playlist.sh`, never by `stream.sh`.)
  Setting them changes nothing, so do not tune them expecting an effect.
- **The API is REQUIRED for every rotation.** `stream.sh`'s `prepare_broadcast()` runs
  inside `start_publisher()` on every publisher start and calls `yt_api.py prepare`,
  which CREATES and BINDS the next broadcast before any ingest flows. YouTube retired
  automatic/default broadcast creation in 2020
  (youtube/v3/live/guides/migration-guide-default-broadcasts); measured here
  2026-09-05, six minutes of clean ingest against a dark channel produced nothing.
  What YouTube still does with no API is `enableAutoStop`: stopping ingest closes and
  archives the broadcast (~9s measured), so the current segment's VOD is saved and only
  the NEXT rotation fails. `enableAutoStart` starts a broadcast only if it is ALREADY
  BOUND. So `mode=native` in `log/rotation_history.log` means "autoStart took the
  already-bound broadcast live without `ensure-live`", never "the API was optional".
  `rotate_broadcast()` now REFUSES to cut when the API cannot create the successor and
  stays LIVE (`ROTATE_WITHOUT_API="no"` default; `yes` cuts anyway; `ROTATE_API_RETRY`
  900 s).
- **The shipped configuration wins over the docs, and it always did.** The docs were
  reconciled to `conf/stream.env.example` on 2026-09-16: `CORR_MIN=0.15` (not 0.35;
  `bin/yt_check.py`'s own default is 0.60), `LOG_MAX_BYTES=524288` (not 2097152;
  `stream.sh`'s own default is 2097152) and native `aac` at 384k (not `aac_at` at
  320k; `aac_at` hard-caps at 320k in this chain). When prose and the example
  disagree, the example is right.
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
- **A fresh clone installs but cannot start until the operator supplies credentials.**
  `install.sh` now seeds `conf/stream.env` from the tracked example when it is absent
  (an absent file used to abort the install before the LaunchAgents and playlist were
  written). `--start` still refuses while `YT_KEY` is empty or Full Disk Access is not
  granted, and with no `conf/yt_oauth.json` the stream runs and still saves the
  current segment, but cannot rotate.
- **No credentials are committed** — `conf/stream.env` and `conf/yt_oauth.json` are
  gitignored. But the stream key is interpolated into the RTMP URL on ffmpeg's
  command line, so it is visible in `ps`.
- **Publishing the OAuth app removes the 7-day refresh-token death, and Google
  verification is NOT required to do it.** While the consent screen's publishing
  status stays "Testing", Google expires the refresh token after 7 days and
  `bin/yt_api.py auth` must be re-run. Publishing it to "In production" removes that
  clock: an unverified published app still works for its owner (one "unverified app"
  warning to click past, 100-user cap), and `bin/yt_api.py auth` prints the console
  click-path at step 4. Re-run auth after publishing - tokens issued while Testing
  keep their 7-day life. If the app must stay in Testing, a dead token still saves the
  current segment's VOD but cannot create the next broadcast, so `rotate_broadcast()`
  refuses to cut and stays LIVE until `bin/yt_api.py auth` is re-run.
- **Destructive commands:** `bin/yt_api.py end` ends the broadcast YouTube is
  currently serving; `ensure-live` creates and deletes broadcasts. `yt_monitor.sh`
  and `stream.sh` use `pkill -9` against `ffmpeg.*rtmp` and `zsh.*yt_monitor.sh`.
- **`set -u` only** — no `set -e`, no `pipefail`. It is set in `install.sh` and in
  every `bin/*.sh` EXCEPT `bin/lib.sh` (which is sourced and inherits the caller's
  options) and `bin/preflight.sh` (which sets no shell options at all). Failures are
  handled by explicit checks, never by aborting.
- **The monitor's `*` case is for the PICTURE only.** `BLACK`, `FROZEN` and `MISMATCH`
  are the statuses that mean "YouTube is live and showing the wrong thing". Lookup and
  configuration statuses — `UNKNOWN`, `FETCHFAIL`, `NOSTATUS`, `NOGOLDEN`, `NOCONFIG`,
  `ERROR`, empty — are handled as never-act: they only start the BLIND timer, and after
  `BLIND_SECONDS` the YouTube API is asked whether the channel is actually live. They
  used to fall into `*`, so a missing `conf/golden.jpg` (gitignored, so a fresh install
  had none) was classified as a bad picture and killed a healthy publisher every
  `FAIL_SECONDS`, forever.
- macOS-only: `launchctl`, `/bin/zsh`, `caffeinate`, `stat -f`, `plutil`, `nc -G`,
  `sed -i ''`. There is no Linux path, and `install.sh` warns that the static ffmpeg
  is an Intel build needing Rosetta 2.
- `install.sh` downloads ffmpeg/ffprobe with `curl -fL --retry 3` from evermeet.cx as
  **unpinned "latest" Intel builds**, and verifies nothing unless `FFMPEG_SHA256` /
  `FFPROBE_SHA256` are set - then it checks the archive digest and refuses a mismatch,
  and otherwise states in its own output that it verified nothing. That binary is then
  handed the stream key in argv, so treat the download as a supply-chain exposure. The
  same is true of the unpinned `pip install --user yt-dlp`.
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

## Releasing

**Read [`RELEASE.md`](RELEASE.md) before cutting a release.** It is this repository's
own release standard — edited here, not deployed from anywhere — and it carries both
the general rules and this repository's own section. Do not improvise a release.

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
