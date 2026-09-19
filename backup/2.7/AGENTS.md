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
CPU/bitrate figures. Deployment is `install.sh` on a Mac, or unpacking a release archive;
releases are **source** archives (`1.0` = the code that was live on 2026-09-16, `2.0` = the
audit fixes, `2.1` = the installer fixes on 2026-09-17, `2.2` = the external watchdog and host
hardening on 2026-09-19, `2.3` = the host forensics and the verified `pmset` hardening), built and
published by `release.sh`. The architecture is a deliberate
two-process split: a
**reader** (camera RTSP → local UDP, restarts freely) and a **publisher** (UDP + MP3
playlist → YouTube RTMP, runs continuously), so a camera dropout never tears down the
RTMP session.

## Layout

- `bin/` — `stream.sh` (774 lines: reader/publisher, watchdog, rotation, VOD
  verification), `yt_monitor.sh` (the watchdog loop), `yt_api.py` (1250 lines, the
  only thing that can create a broadcast), `yt_check.py` (grades one pulled frame),
  `yt_watchdog.py` (the EXTERNAL watchdog: the one thing that runs off the streamer and
  the only code allowed to notify), `watchdog-install.sh` (installs that watchdog on an
  always-on host as a systemd unit or a LaunchAgent), `lib.sh` (shared API helpers), the
  camera/ONVIF tools (`cam_ip.py`, `camscan.py`, `onvif_probe.py`, `cam_config.py`,
  `cam_reboot.py`), `forensics.sh` (read-only evidence collector for a host-level outage,
  including the Network section), `harden-host.sh` (applies and verifies the `pmset` host
  hardening; dry run by default), `net_watch.sh` (the TRANSPORT-layer watchdog: probes
  gateway/DNS/WAN and repairs a lost network; started by `stream.sh`), and
  `status.sh` / `smoke_test.sh` / `shuffle_playlist.sh` / `preflight.sh` /
  `ssh_mesh.sh`.
- `conf/` is **tracked**: `stream.env.example`, `broadcast_template.json` (the
  enforced reference), `playlist.txt`, thumbnails, camera XML dumps, and the external
  watchdog's `watchdog.env.example` (the tracked template; the live `conf/watchdog.env`
  holds a Gmail app password and is gitignored) and `ytlive-watchdog.service` (the systemd
  unit for the always-on host).
- `docs/` — the design/ops notes, plus the per-release notes `release-notes-vX.Y.md`.
  `docs/v3-datacenter-plan.md` is an unscheduled v3.0 proposal.
  `MP3/` — 25 tracks (328 MB, tracked; never in a release archive).
- `VERSION` at the root is the **only** version declaration; `CHANGELOG.md` is the record.
  `release.sh` builds and (`--publish`) publishes a source release from a tag — dry run by
  default. `tests/` is the credential-free harness; `backup/` holds the frozen snapshots of what
  was deployed (see `backup/README.md`).
- **Audit reports are not kept in the working tree.** A finished audit is archived by commit
  permalink and its outcome is recorded permanently in `CHANGELOG.md`, in the release notes and in
  the wiki project tracker, so the next audit does not read a stale one and mistake it for current.
  The 2026-09-16 report is at
  <https://github.com/Pummelchen/YTLive_Laundry/blob/d603fdcf92dff17bfb7aa770562b04b84e37e71d/AUDIT/2026-09-16-full-audit.md>;
  recover the tree with `git checkout d603fdc -- AUDIT`. `release.sh` excludes `AUDIT/` from every
  archive as well, so the convention is enforced rather than remembered.
- `install.sh` at the root. Gitignored at runtime: `log/`, `conf/stream.env`,
  `conf/yt_oauth.json`, `conf/golden.jpg` and `.release-build/` (transient release scratch).

## Build and test

No build step, and no Python dependency to install: every `.py` is
`#!/usr/bin/env python3` importing only the standard library. `install.sh`
provisions a host instead — it downloads evermeet.cx static `ffmpeg`/`ffprobe` into
`~/.local/bin`, `pip install --user yt-dlp`, and writes two LaunchAgents. Nothing
needs sudo.

```bash
tests/run.sh          # the credential-free suite: 659 checks, no camera, no credentials
tests/run.sh --list   # what it covers
bin/smoke_test.sh     # the pre-restart gate; needs conf/yt_oauth.json to pass fully
```

`tests/run.sh` is the gate that always works: it needs no camera, no network, no credentials and
no `ffmpeg`, runs each case in its own scratch tree under `tests/.tmp/`, and shadows `pkill` with
a recorder so a mis-scoped test cannot signal the live publisher. Prefer it over
`bin/smoke_test.sh` when you have no credentials, and run both before restarting anything. It is
also the CI gate: `.github/workflows/ci.yml` runs it on `macos-latest` for every push to `main`
and every pull request.

**`smoke_test.sh` fails on a bare clone** (non-zero: exit 2 when `~/Downloads/YTLive`
does not exist, otherwise exit 1): its 20 syntax checks (11 shell files including
`install.sh`, 9 `.py`) pass, but the read-only API commands (`token`/`status`/`verify`)
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

**One version declaration, at the root, and nowhere else.** `VERSION` holds a two-component
`MAJOR.MINOR` version and is authoritative: `release.sh` **fails the build** when it disagrees
with the tag being released. No script carries a version literal. Every tunable is declared in
`conf/stream.env` (`ROTATE_HOURS`, `ROTATE_MINUTES`, `MODE`,
`OUT_FPS`, `CHECK_INTERVAL`, `CORR_MIN`, `FAIL_SECONDS`, `OFFLINE_SECONDS`,
`BLIND_SECONDS`, `ROTATE_NATIVE_WAIT`, `ROTATE_GRACE`, `ROTATE_MIN_INTERVAL`,
`ROTATE_WITHOUT_API`, `ROTATE_API_RETRY`, `ENFORCE_EVERY`, `LOG_MAX_BYTES`,
`YT_TITLE_FMT`, `YT_LATENCY`), and the broadcast's own configuration lives in
`conf/broadcast_template.json`. Some declared names are read by no code at all —
see the dead-knobs trap below.

## Gates

**The credential-free suite now runs automatically.** `.github/workflows/ci.yml` is the first
CI workflow this repository has ever had: it runs `zsh tests/run.sh` on every push to `main`
and on every pull request, and any non-zero exit fails the job. It runs on `macos-latest` and
only there — the suite is macOS-only (`zsh` idioms, `stat -f`, `plutil`, and a `pmset` stub
whose absent keys mean "off"), so a Linux matrix would fail for reasons that are not defects.
`bin/smoke_test.sh` is deliberately not in CI: it needs `conf/yt_oauth.json`, a real
gitignored credential, so it cannot pass on a bare clone. GitHub's dynamic CodeQL default
setup stays active alongside it.

The gates, still worth running by hand before restarting anything:

    tests/run.sh          # 659 checks, credential-free; fails if the monitor's classification,
                          # the golden-reference bootstrap or the network ladder regress
    bin/smoke_test.sh     # syntax/AST plus the real API commands and prepare --dry-run;
                          # needs conf/yt_oauth.json, so it cannot pass on a bare clone

`release.sh` runs the syntax gate and the test suite **from the exported archive** before it
packs it, so a release cannot ship a tree that fails either.

## Traps

- **The heartbeat token lives in a mode 600 file and is NEVER passed on a command line
  (T-34).** `bin/stream.sh` starts `bin/yt_heartbeat.py push` with `--token-file
  "$HEARTBEAT_TOKEN_FILE"`, never the secret itself, because argv is world-readable through
  `ps` — the same rule the camera credentials follow. On the watchdog host,
  `bin/yt_heartbeat.py serve` is what enforces the rest: it requires the bearer token on
  every `POST /heartbeat` (constant-time compare, 401 otherwise) and binds the **tailnet
  address only** (`HEARTBEAT_BIND`, never `0.0.0.0`). Plain HTTP on the tailnet is correct
  because WireGuard encrypts it; do not add TLS. The push direction is deliberate: the
  watchdog host holds the Gmail app password and must never be able to reach into the
  streamer. `conf/*.token` is gitignored.
- **A change that spans the streamer and the watchdog host is not live until BOTH are
  deployed — and nothing tells you when they disagree.** They are separate installs with
  separate installers and no version stamp on the host: `bin/deploy-release.sh --tag vX.Y`
  on the streamer, `bin/watchdog-install.sh --start` on the watchdog host (it keeps an
  existing live `conf/watchdog.env`, so a re-install cannot disarm a configured heartbeat).
  Measured 2026-09-19: the host was still running a **pre-2.4** `yt_watchdog.py` — the
  stale-heartbeat rule existed only in the repo, so a freshly deployed push/listener pair
  could not have alerted. Before claiming a cross-host feature works, hash or diff the
  host's `$PREFIX/bin/*.py` against the tagged tree, and run `bin/yt_watchdog.py status`
  there to read what it actually decides.
- **A published release tag is never moved; cut a new version instead.** A moved tag
  silently breaks `git fetch --tags` on clones that already hold the old object (they need
  `--force`, and without it they stay on old code with no error), and it invalidates
  archives and digests published from the old object. The 2026-09-19 `v2.7` re-cut is a
  **one-time recorded exception**: T-34 was a 2.7-scoped row cut before it landed, the only
  installed consumer (the streamer) was force-fetched in the same change, and the GitHub
  release was re-published and re-verified. Do not read it as a precedent.
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
  that with a temporary plist and refuses `--start` until it passes. That is an
  *install* constraint: every script now derives `BASE` from its own location
  (`${0:A:h:h}` / `__file__`), so a copy of the tree elsewhere still runs by hand.
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
  and `stream.sh` signal the publisher and the monitor by pid from
  `log/publisher.pid` / `log/monitor.pid`, never by pattern — see the signalling
  trap below.
- **`set -u` only** — no `set -e`, no `pipefail`. It is set in `install.sh` and in
  every `bin/*.sh` EXCEPT `bin/lib.sh`, which is sourced and inherits the caller's
  options. Failures are handled by explicit checks, never by aborting.
- **The monitor's `*` case is for the PICTURE only.** `BLACK`, `FROZEN` and `MISMATCH`
  are the statuses that mean "YouTube is live and showing the wrong thing". Lookup and
  configuration statuses — `UNKNOWN`, `FETCHFAIL`, `NOSTATUS`, `NOGOLDEN`, `NOCONFIG`,
  `ERROR`, empty — are handled as never-act: they only start the BLIND timer, and after
  `BLIND_SECONDS` the YouTube API is asked whether the channel is actually live. They
  used to fall into `*`, so a missing `conf/golden.jpg` (gitignored, so a fresh install
  had none) was classified as a bad picture and killed a healthy publisher every
  `FAIL_SECONDS`, forever.
- macOS-only: `launchctl`, `/bin/zsh`, `caffeinate`, `stat -f`, `plutil`, `nc -G`,
  `sed -i ''`. There is no Linux path for the streamer, and `install.sh` warns that the
  static ffmpeg is an Intel build needing Rosetta 2. The one documented exception is
  `bin/yt_watchdog.py`: it is deliberately portable, stdlib-only Python, with both a
  systemd unit and a LaunchAgent, because it must not live on the streamer and may run on
  a Linux host (`bin/watchdog-install.sh` picks the service manager from `uname -s`).
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
- **The streamer is a single point of failure, and nothing on it can report its own
  death.** On 2026-09-18 it dropped off the tailnet mid-segment and the channel was dark
  **19 h 26 m** and nothing said so — exactly the class the "no notifications" rule above
  cannot cover. `bin/yt_watchdog.py` is the deliberate exception: the only thing allowed to
  notify, and the one thing that must **never** be run on the streamer, nor may its own host
  be assumed alive. See `docs/watchdog.md`.
- **The recorded cause of that outage was wrong, and the correction matters.** The 2.2/2.3
  notes, the handover and the wiki all said *a mains interruption while the lid was shut, after
  which the Mac slept on battery*. The host's own records falsify it: `kern.boottime` is still
  Mon Aug 31 (uptime 19 days, so no reboot, no panic, no forced power-off and no login window),
  and a `pmset -g log` window covering 09-12 → 09-19 holds **zero** Sleep/Wake and **zero**
  AC/battery transitions. The Mac was **awake and logging** 640–760 lines/hour throughout, with
  `[Errno 8] nodename nor servname provided` and a camera unreachable on the **local** subnet:
  it lost its **transport** — DNS and its own LAN — not its power. Do not restate the sleep
  theory; the evidence is in `CHANGELOG.md` under 2.4.
- **Every retry in this project used to be an *application*-layer retry.** ffmpeg, ONVIF
  discovery, the OAuth probe and launchd all retried, and not one of them ever touched a
  network interface — which is why a transport failure was outside the reach of all of them.
  `bin/net_watch.sh` is that missing bottom layer and `stream.sh` starts it. Two rules are
  load-bearing and regression-guarded in `tests/t09_net.sh`: it must **never power-cycle a
  network service** (toggling the USB-Ethernet service on 2026-09-19 killed that adapter's
  carrier for good) and must **never reorder the service list** (an interface with no router
  gets no default route, so macOS already prefers the working one, and `-ordernetworkservices`
  is one typo away from breaking the only working path). Wired stays first so it becomes
  primary by itself once it holds a real lease — LAN primary, Wi-Fi backup.
- **BASE comes from the checkout you are in** (`BASE="${BASE:-${0:A:h:h}}"`, or
  `pathlib.Path(__file__).resolve().parent.parent` in Python), not from a hardcoded
  `~/Downloads/YTLive`. `bin/preflight.sh` was the one entry point that ignored BASE, so
  `BASE=... bin/preflight.sh` silently probed the *installed* config. The install still has to
  **be** at `~/Downloads/YTLive` — that is a TCC constraint on launchd, not a script one — and
  `install.sh` warns and `bin/preflight.sh` now fails loudly rather than guessing.
  Regression-guarded in `tests/t11_paths_pids.sh`.
- **Never signal a process by pattern.** `pkill -9 -f "ffmpeg.*rtmp"` and
  `pkill -9 -f "zsh.*yt_monitor.sh"` matched the full command line of every process of every
  user, unanchored — a hand-run diagnostic, a second copy of the project, an editor's subshell.
  Both sides now write a pidfile (`log/publisher.pid`, `log/monitor.pid`) and signal through
  `pidfile_pid`, which also checks the pid's command before believing it, because **a pid gets
  recycled**. When there is no trustworthy pid the watchdog kills *nothing* and says so.
- **`conf/broadcast_template.json` is TRACKED and is written only when it changes.**
  `capture` runs at every rotation and its merge is idempotent, so an unconditional write left
  the deployed checkout permanently dirty and could block a `git pull` there. The capture
  timestamp goes to `log/broadcast_captured.json` (ignored); a no-op capture writes nothing.
- **The API quota is a hard 10,000 units/day, and running out used to dark the channel.**
  `yt_api.py verify` reports two kinds of drift and only one is fixable: `diffs` (video-level, which
  `enforce` can write) and `broadcast_diffs` (fixed **at creation** — no update can ever change
  them). Enforcing on any `DRIFTED` chased the second kind forever, which is the bulk of the
  audit's 10,290-unit worst case. On `403 quotaExceeded` a cooldown is now armed in
  `log/quota_exhausted` and every later call refuses **before** making a request, so a retry loop
  cannot spend the day. **The rotation asks `yt_api.py quota` separately** — the token probe hits
  the OAuth endpoint, which is not the Data API and still answers `LIVE` with an empty pool — and
  refuses to cut when the pool is gone.
- **The camera's burned-in clock is an hour fast and ONVIF cannot fix it.** `bin/cam_time.py` sets
  the timezone and the camera accepts it, reports it back and renders UTC+8 anyway, exactly like the
  encoder settings. Measured 2026-09-19; recorded in `docs/camera.md`. Do not re-open it as a task —
  the UTC clock is correct and NTP-synced, so nothing downstream depends on the display.
- **CI exists now, and it is macOS-only.** `.github/workflows/ci.yml` runs `tests/run.sh` on every
  push to `main` and every pull request. Do not move it to a Linux runner: the suite uses `zsh`
  idioms, `stat -f`, `plutil` and a `pmset` stub. `bin/smoke_test.sh` is deliberately absent because
  it needs a gitignored credential.
  Do not "helpfully" put runtime state back into that file.
- `bin/cam_config.py` reports what the camera has been *told*, not what it delivers:
  the firmware accepts ONVIF encoder writes, reports them back correctly, and
  **ignores them** — the delivered stream stayed at ~2.3 Mbit/s and 14 fps through
  bitrate settings of 8192, 12288, 16384 and 20480.

## Task tracker

Open work lives in exactly one place: the wiki's **[Project Tracker](https://github.com/Pummelchen/YTLive_Laundry/wiki/Project-Tracker)**.
It is a single table under `## Tasks`, and it is the only backlog — no Open/Blocked/
Parked sections, no second list, status is a column rather than a heading.

The rules that govern the table — the columns, the four types, the three statuses, the
S/M/L sizes, ownership, and the ordering that *is* the priority — are defined once in
[`docs/task-table-standard.md`](docs/task-table-standard.md). Read it before adding,
changing or closing a row.

- **An epic is a project, not a row.** Split it until each row is one independently
  closable outcome.
- **IDs are stable and never reused.** Closing deletes the row; the gap is correct.
- **Every row has a next step.** If you cannot name one, split it, block it or park it.
- **History does not live in the table.** What was tried, measured or rejected goes to
  `CHANGELOG.md` and the closing commit; the open row links to the evidence.
- **Update a row the moment its state changes**, and read the table top to bottom
  before starting work — the top Open row is the default next task.

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

**Part 2 modifies these for this repository, and Part 2 wins.** There is no compiled artifact and
no `arm64` build to assert: a release here is a **source archive** with a `.sha256` beside it,
built and published by `release.sh`. So §1.2.5, §1.2.6 and §1.8 apply, while §1.6's macOS binary
packaging does not. Identity is the two-component `VERSION` at the root, enforced against the tag.
Archives contain no `MP3/`, no `backup/` and never an audit report.
