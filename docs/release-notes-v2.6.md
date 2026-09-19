# YTLive_Laundry 2.6 — the quota that could go dark, the disk that now acts, and the first CI gate

2.6 fixes the way the channel could be taken offline by its own API budget: `403 quotaExceeded`
used to be ignored, and a drift loop that **could never succeed** was quietly spending the day's
quota (T-06). It makes the disk guard **act before it reports** instead of describing the failure
while it happens (T-13), and it gives the repository its **first automated gate** — `tests/run.sh`
on macOS runners for every push and pull request (T-18). `bin/deploy-release.sh` is now tested
rather than trusted (T-28), and T-25 is **closed by measurement, not by a fix**: the camera's
burned-in clock is an hour fast, the timezone writes over ONVIF, the camera accepts it and reports
it back, and the OSD does not move. Full detail is in [`CHANGELOG.md`](../CHANGELOG.md).

- Built from tag `v2.6`
- Contents: the tagged tree **without `MP3/`**, without `backup/` and without `AUDIT/`. The
  music library is byte-identical in git at the same tag (`git checkout v2.6 -- MP3`), which is
  why it is excluded rather than shipped. No credentials or runtime state are in any archive:
  `conf/stream.env`, `conf/yt_oauth.json`, `conf/watchdog.env` and `log/` are gitignored and were
  never committed.
- Source archive, not a build product: nothing to compile, no binaries, nothing to sign.

## T-06 — the quota hole, and the loop that was filling it

YouTube gives one **10,000-unit pool per project per day**, resetting at midnight Pacific. The
2026-09-16 audit measured a worst case of **10,290 units/day** here — over budget — and found
something worse than the number: on `403 quotaExceeded` the code **did not stop**. `prepare`
failed, ffmpeg restarted anyway, and the channel went dark at that rotation. There were two
distinct defects, and both are regression-guarded in `tests/t13_quota.sh` (21 checks).

**The driver: a loop that could never succeed.** `yt_api.py verify` reports two kinds of drift,
and only one of them is fixable:

- `diffs` is video-level (title, description, tags, thumbnail) and `enforce` can write it;
- `broadcast_diffs` is fixed **at creation** (`enableMonitorStream`, `latencyPreference`, …) and
  **no update can ever change it** for a broadcast that is already live.

`enforce_drift` enforced on *any* `DRIFTED`, so a creation-time-only difference was chased every
`ENFORCE_EVERY` (1800 s) forever — up to **~158 units a shot**, which is the bulk of the overrun.
It now enforces **only** fixable drift, logs the unfixable kind **once** with the evidence rather
than chasing it, and gives up loudly when the *same* field set survives an enforce, naming the
set. The give-up is scoped to the set, so a **different** drift is still chased.

**The hole: the refusal to spend, and the refusal to cut.** A `403 quotaExceeded` now arms
`log/quota_exhausted`, and every later call refuses **before making a request** — the check is
local and free, so a retry loop cannot spend the rest of the day. `yt_api.py quota` is that free
check (exit 0 / `"status": "OK"` when usable, exit 2 / `"status": "QUOTA"` with `reset_in_s` when
armed), and `rotate_broadcast()` asks it before every cut. That separation matters because the
token probe hits the **OAuth endpoint, which is not the Data API** and still answers `LIVE` with
an empty pool. A rotation with no quota now **refuses to cut** (`ROTATE_WITHOUT_API=no`) instead
of cutting into a state where no successor broadcast can be created.

**The limits, recorded rather than papered over.** The cooldown is a **fixed window that defaults
to 6 h** (`YT_QUOTA_COOLDOWN=21600`), not a check against the real reset time, and it is
**re-armed by a fresh `403`** — a `quotaExceeded` body in any later call extends it from that
moment. `ENFORCE_MAX_ATTEMPTS` defaults to **3**, so a field YouTube simply will not persist is
retried three times before the give-up line appears. And the give-up is scoped to the field
**set**, not to the field: if `verify` reports a different set after a real edit, the cap starts
over. This reduces the spend; it does not prove the daily total stays under 10,000.

## T-13 — the disk guard acts before it reports

A full volume is the one failure nothing in this project recovers from: ffmpeg's `-progress` write
fails, the frame counter stalls, the watchdog restarts the publisher every 30 s, and yt-dlp goes
with it. `housekeep` used to watch the free space and only **print** what was about to happen.
Below `DISK_LOW_MB` (1000) it now:

- cuts every log to **a quarter** of its budget, to buy time;
- drops the **regenerable** monitor artifacts — `log/yt_lastpull.jpg`, `log/yt_prevpull.jpg`,
  `log/golden_gray.cache`, `log/yt_url.cache`. Unlinking one is safe mid-run because ffmpeg holds
  the inode of any file it opened, and each is rebuilt on the next pull or resolve.

Below **200 MB** it reports `CRITICAL` and says the failure has become a human's problem.
**Never touched, at any free-space level:** `log/progress.txt` (ffmpeg writes it at a fixed offset,
so rewriting it would corrupt the frame counter the watchdog reads), the filler stills
`log/basefill.jpg` and `log/lastframe.jpg` (losing them degrades the next publisher start), and a
deploy backup or `.git` — those are the rollback, a decision rather than housekeeping.
`tests/t03_files.sh` grew to **22** checks here, including that `progress.txt` is byte-identical
after a trim on a healthy volume and on a critical one.

**The honest limit — the alert half is NOT done.** The streamer still cannot *tell* anyone. The
off-host watchdog is the only component allowed to notify, and it learns about the disk only when
the channel finally stops. Delivering this number off-host is the half that **depends on the
watchdog-delivery decision**, so T-13's row stays **Blocked** rather than closing: the near half
(act) is implemented and tested, the far half (notify) does not exist yet. What ships is a longer
runway, not a notification.

## T-18 — the first automated gate this repository has ever had

`.github/workflows/ci.yml` runs `zsh tests/run.sh` — the credential-free suite, all 520 checks —
for **every push to `main`** and **every pull request**. Before this file there was no `.github/`
directory at all: nothing ran the syntax gate or the suite on push, and only GitHub's dynamic
CodeQL default setup watched the Python. The job runs on `macos-latest` with `contents: read`, no
caching (nothing is installed), no `install.sh`, no credentials and no network use.

**macOS only, deliberately.** The suite is written for macOS: it uses `zsh` idioms, `stat -f`,
`plutil`, and a `pmset` stub that models the keys macOS reports only when they are enabled. A Linux
job would fail for reasons that are **not defects in this repository**, so the workflow comment
says in as many words that it MUST NOT be moved to `ubuntu-latest` or into a Linux matrix.

**`bin/smoke_test.sh` is deliberately not in CI.** It needs `conf/yt_oauth.json`, a real
gitignored credential, so it cannot pass on a clean checkout; it stays a by-hand host gate. The
workflow runs `zsh tests/run.sh` only, which already includes t01's `zsh -n` parse of every shell
file and AST parse of every Python module — a separate syntax step would duplicate work and hide
nothing new. `AGENTS.md`, `README.md`, `RELEASE.md` and `tests/README.md` no longer claim there is
no CI. The limits are the runner and the credential: a green check says the credential-free suite
passed on macOS, and says **nothing** about whether the stream itself is publishing.

## T-28 — `bin/deploy-release.sh` is tested instead of trusted

The script had run for real exactly once, on 2026-09-17, and "it worked" is a data point rather
than a test. `tests/t12_deploy.sh` (57 checks) drives what can be driven without risk, entirely in
`tests/.tmp`:

- `--dry-run` changes nothing, and the test asserts the tracked tree is **byte-for-byte
  unchanged** — the scratch world makes `HOME` and `BASE` *siblings*, because the script backs the
  tree up into a job dir under `HOME` and `HOME` inside `BASE` would recurse into its own
  destination. Nothing touches the real `~/Downloads/YTLive`, `~/.local/bin` or
  `~/Library/LaunchAgents`.
- argument handling exits 2 with the usage line and creates no job directory.
- the extracted `ytdlp_works` preflight, including the case that blinded `yt-dlp` once: an
  `ERROR` line printed **with exit 0** is blindness, not success. Empty output, a URL instead of an
  id, a non-zero exit, a non-executable and a missing `yt-dlp` are all blindness too.
- `rollback` restores the tree **and** the out-of-tree state (`~/.local/bin` — the half the
  2026-09-17 rollback missed — and `~/Library/LaunchAgents`), keeping the failed copies beside
  them, and the `PARTIAL ROLLBACK` path never claims `rollback done`.
- the `--go` kill switch refuses while `~/ytlive-deploy-HOLD` exists, **before any tree backup**.
- `--wait-for-cut` rotation detection, **which had never been exercised at all**: a `state=offline`
  line dated just ahead of the loop's start makes the real detection fire, and the run then enters
  the real deploy steps.

A fake `git` refuses `checkout`, and a tripwire `install.sh` records it if the run ever reaches
`./install.sh`; the test asserts the marker does not exist.

**The limit:** the **`--go` path is still not exercised end to end**. What is tested is the
refusal when the kill switch is engaged; the 10-hour no-rotation deadline branch, the real
`launchctl`, the real `install.sh`, and any real network are deliberately not staged.

## T-25 closed by measurement, not by a fix

The camera burns its own clock into the top panel of the composite and it renders **UTC+8 (WITA)
on a UTC+7 island**, so every viewer sees a time an hour ahead. `bin/cam_time.py` reads and writes
it over ONVIF — the only open interface here, since port 80 and the XM/Dahua CGI are closed:

    bin/cam_time.py get            # utc, local, timezone, dst, type
    bin/cam_time.py set WIB-7      # NTP on, daylight saving off, zone WIB-7

Measured before and after on the real camera:

| | ONVIF says | the on-screen clock says |
|---|---|---|
| before | timezone `PST0PDT`, UTC correct | `20:44:21` while local time was `19:45` |
| after `set WIB-7` | timezone `WIB-7` (accepted, and reads back) | `20:45:47` while local time was `19:46` |

**This is not a fix.** The write is accepted, reported back correctly, and ignored by the OSD —
the same lie the encoder settings tell. The OSD's own zone is not reachable through ONVIF, and
both other interfaces that could hold it are closed, so **this is not fixable on this firmware**.
The task is closed with the evidence in [`docs/camera.md`](camera.md) so it is not re-opened as a
task. The UTC clock itself is correct and NTP-synced, so nothing downstream depends on the wrong
display; if the camera is ever replaced, check the OSD clock on the new one.

**The limit:** the measurement is one camera on one firmware, taken by a human reading the burned-in
panel against local time — there is no instrumented check for it, and `tests/t10_camtools.sh`
proves the tool's plumbing (usage, no network at import, the ONVIF DateTime shape, and that `set`
sends the zone with NTP on and daylight saving off against a stub device service), **not** that
the OSD moves.

## Files in this release

| File | Change |
|---|---|
| `bin/yt_api.py` | `log/quota_exhausted` cooldown (`quota_record` / `quota_arm` / `die_quota`, `YT_QUOTA_COOLDOWN`, default 21600 s), armed by a `403 quotaExceeded` and re-armed by a fresh one; `api()` refuses before requesting; new free `quota` verb |
| `bin/stream.sh` | `enforce_drift` enforces only fixable `diffs`, reports `broadcast_diffs` once, and gives up after `ENFORCE_MAX_ATTEMPTS` (default 3) on the same field set; `rotate_broadcast` asks `yt_api.py quota` and refuses to cut; `housekeep` cuts logs to a quarter and drops regenerable caches below `DISK_LOW_MB` |
| `bin/lib.sh` | `yt_api_call` exports `YT_QUOTA_COOLDOWN` (default 21600), so a direct `yt_api.py` call sees the same window |
| `bin/cam_time.py` | **new** — read/set the camera's clock and timezone over ONVIF; `get` prints utc/local/timezone/dst/type; `set [TZ]` sends NTP on, daylight saving off and the zone, then reads it back rather than trusting the write. Usage exits 2; importing it touches no network (T-25) |
| `bin/deploy-release.sh` | tested by `tests/t12_deploy.sh`; no behaviour change (T-28) |
| `conf/stream.env.example` | `export YT_QUOTA_COOLDOWN="21600"`, `DISK_LOW_MB="1000"`, `ENFORCE_MAX_ATTEMPTS="3"` with the reasoning beside each |
| `.github/workflows/ci.yml` | **new** — the first automated gate: `zsh tests/run.sh` on `macos-latest` for every push to `main` and every pull request; macOS only; `bin/smoke_test.sh` deliberately absent (T-18) |
| `tests/t13_quota.sh` | **new** — 21 checks: the cooldown as pure logic, the free check and the refusal to spend, the drift loop, and the rotation's refusal to cut |
| `tests/t12_deploy.sh` | **new** — 57 checks: argument handling, `--dry-run` changing nothing, `ytdlp_works`, `rollback` and `PARTIAL ROLLBACK`, the `--go` kill switch, and `--wait-for-cut` detection (T-28) |
| `tests/t03_files.sh` | grew to 22 with the disk guard: what it cuts below the floor, and that it never touches the filler stills or `progress.txt` |
| `tests/t10_camtools.sh` | grew to 63 with `cam_time.py`: usage and arity, no network at import, the ONVIF DateTime shape, and the bytes `set` sends |
| `docs/camera.md` | the OSD clock measured before and after, recorded as **not fixable on this firmware** so it is not re-opened |
| `docs/files.md` | `bin/cam_time.py` and `.github/workflows/ci.yml` added to the tree map |
| `AGENTS.md` | the fixture list no longer says "no CI"; the camera clock and the quota rules are recorded as constraints |
| `README.md` | the testing section: one gate now runs in CI, the other still needs a credential |
| `RELEASE.md` | the CI section rewritten: the credential-free suite runs on macOS runners, `smoke_test.sh` does not |
| `tests/README.md` | the suite is wired to CI now; still run it yourself before pushing |
| `log/quota_exhausted` (**runtime state, gitignored**) | armed by a `403 quotaExceeded`, holds `until` / `armed_at` / `detail`; expires by time and is re-armed by a fresh `403` (T-06) |

## Verification

Measured on 2026-09-19 from the working tree with `zsh tests/run.sh` (serial, all files) and then
per file with `zsh tests/run.sh <name>`. The runner prints a per-file count, not a grand total;
the total below is the sum of the per-file counts.

| Test file | Checks | Result |
|---|---|---|
| `tests/t01_syntax.sh` | 51 | all passed |
| `tests/t02_monitor_classify.sh` | 12 | all passed |
| `tests/t03_files.sh` | 22 | all passed |
| `tests/t04_token.sh` | 13 | all passed |
| `tests/t05_rotation_gate.sh` | 15 | all passed |
| `tests/t06_install.sh` | 21 | all passed |
| `tests/t07_watchdog.sh` | 120 | all passed |
| `tests/t08_hosttools.sh` | 46 | all passed |
| `tests/t09_net.sh` | 42 | all passed |
| `tests/t10_camtools.sh` | 63 | all passed |
| `tests/t11_paths_pids.sh` | 37 | all passed |
| `tests/t12_deploy.sh` | 57 | all passed |
| `tests/t13_quota.sh` | 21 | all passed |
| **Total** | **520** | **`SUITE PASSED`** |

- The project's own suite, serially: **checked** — 520 checks, all passing. The runner reports
  `ALL PASSED` per file and `SUITE PASSED` at the end.
- `tests/t13_quota.sh` (new): **checked** — 21 checks. The cooldown as pure logic (an absent file
  permits, an armed one blocks, an expired one releases, a corrupt one cannot brick the channel),
  the free `quota` check in both states, that `api()` raises `SystemExit` instead of making a
  request while armed, that a broadcast-only drift is verified but **never** enforced, that a
  fixable drift is enforced up to `ENFORCE_MAX_ATTEMPTS` and then abandoned loudly, that a changed
  field set is chased again, and that `rotate_broadcast` asks the quota check and refuses the cut.
- `tests/t12_deploy.sh` (new): **checked** — 57 checks, entirely inside `tests/.tmp` (see T-28).
- `tests/t03_files.sh` and `tests/t10_camtools.sh`: **checked** — 22 and 63 checks, including every
  new disk-guard and `cam_time.py` case named above.
- `bin/smoke_test.sh`: **not checked** — it needs `conf/yt_oauth.json`, which is gitignored and in
  no archive, so it cannot pass inside a release. It is not a release gate, and it is not in CI.
- `bin/deploy-release.sh --go` end to end: **not checked** — only the kill-switch refusal is
  exercised; the 10-hour deadline branch, the real `launchctl`, the real `install.sh` and any real
  network are not staged.
- The disk guard's **notification** path: **not checked** — it does not exist. The streamer cannot
  notify; that half is the blocked tracker row, not code in this release.
- The camera's OSD clock (T-25): **not re-derived here** — the before/after readings come from the
  real camera on 2026-09-19 and are recorded in `docs/camera.md`; t10 stubs the device service and
  never opens a socket. There is no automated check that the OSD moves, because it does not.
- CI actually running on GitHub: **checked** — the workflow's first real run on the push that
  carried it (`CI`, run `35444069236`, job `credential-free gate (macOS)`) completed **success** in
  3m01s, including the per-file count step. That is the whole point of T-18 and it is now observed,
  not assumed.
- The release gates (`release.sh`): syntax (`zsh -n` per shell file, `ast.parse` per Python
  module), the suite from the archive, and the per-file byte-match against the tag: **checked at
  publish time**, the same mechanical gates 2.2–2.5 used.

## Deploying this

The channel is live, so this is a normal deploy: `bin/status.sh` and `bin/smoke_test.sh` on the
streamer first, then `bin/deploy-release.sh --tag v2.6`. Read
[Updating and rollback](https://github.com/Pummelchen/YTLive_Laundry/wiki/Updating-and-Rollback)
first. Three things are worth checking after the first restart:

- the first rotation should **not** be refused: `log/quota_exhausted` should be absent, and the
  rotation preflight's `yt_api.py quota` should answer `"status": "OK"`. If a rotation logs
  `REFUSED - API quota is exhausted`, the channel is **deliberately** staying live with the old
  broadcast — that is the refusal working, not a crash.
- the next `housekeep` line on a healthy volume should be silent about the disk; below
  `DISK_LOW_MB` it should read `cutting every log to a quarter of its budget ... to buy time`, and
  the filler stills and `log/progress.txt` should still be there.
- the new CI job should appear on the next push to `main`; a red job means the credential-free
  suite regressed, and nothing about it can be concluded from `bin/smoke_test.sh`.

The camera's OSD clock stays an hour fast. That is expected: it cannot be fixed on this firmware,
and `bin/cam_time.py set` will keep reporting success while the display does not move.

```
SHA256  SHA256_PENDING
BYTES   ARCHIVE_BYTES_PENDING
```
