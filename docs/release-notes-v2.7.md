# YTLive_Laundry 2.7 — the clock a restart stranded, the verdict a trimmed log ate, the bounce aimed at a stale pid, and the heartbeat written too late

2.7 closes four silent failure modes in the stream's own restarts and bookkeeping. A restart could
strand the rotation loop on the **dead broadcast's age**, so the loop could fire a rotation early
and cut a **second short recording out of the same session** — and a bad picture with an
**unreachable camera** no longer restarts the publisher at all, because that restart cannot fix the
picture and only fragments the recording (T-08). A recording whose verdict never settled used to
fall out of `rotation_history.log`, which is deliberately trimmed to the last 100 rotations, and
**was never confirmed at all** (T-12). The ingest bounce signalled a pid snapshotted before the
publisher could be restarted underneath it (T-19), and the monitor wrote its heartbeat only
**after** the grading pass, so one slow pass could get a healthy monitor killed for being slow
(T-20). Full detail is in [`CHANGELOG.md`](../CHANGELOG.md).

- Built from tag `v2.7`
- Contents: the tagged tree **without `MP3/`**, without `backup/` and without `AUDIT/`. The
  music library is byte-identical in git at the same tag (`git checkout v2.7 -- MP3`), which is
  why it is excluded rather than shipped. No credentials or runtime state are in any archive:
  `conf/stream.env`, `conf/yt_oauth.json`, `conf/watchdog.env` and `log/` are gitignored and were
  never committed.
- Source archive, not a build product: nothing to compile, no binaries, nothing to sign.

## T-08 — a restart can no longer strand the rotation clock, and a dead camera is no longer blamed

A publisher death or a stall makes `stream.sh` restart ffmpeg, and YouTube's `enableAutoStop`
closes the old broadcast about 9 s after ingest stops — so the successor is brand new while
`BROADCAST_STARTED` still described the old one. That variable was only re-adopted by `housekeep`,
every 300 s, so for up to five minutes the loop could decide an eight-hour segment was already past
its cut and **fire a rotation early, cutting a second short recording out of the same session**.

A restart now arms a **bounded** retry — both the publisher-death path and the stall-watchdog path —
that re-adopts the clock the moment the successor appears:

    CLOCK_RETRY_EVERY="30"    # seconds between re-adopt attempts while armed
    CLOCK_RETRY_WINDOW="300"  # give up this long after the restart

and it names what happened when the broadcast id actually changes:

    FRAGMENT: the restart closed broadcast X early, so its recording is a partial segment and Y is a fresh one. The rotation clock is now Y's; this line is why the VOD is short.

The retry costs **no API call** when the id did not change: `refresh_broadcast_clock` sees the
stored id still live and re-uses the stored epoch, which is what makes re-asking every 30 s
affordable at all. `tests/t15_resilience.sh` proves both halves behaviourally — a new broadcast
adopts its real start time, and an unchanged one re-uses the stored clock and never asks YouTube.

**The limit:** the retry stops on its own **300 s after the restart, whether or not the id changed**.
It is a window, not a watcher: if the successor appears later than that, the clock falls back to the
old `housekeep` cadence. The five-minute hole is closed, not made impossible.

**A restart is also no longer taken for a fault it cannot fix.** When the picture is bad because the
**camera** is unreachable, restarting the publisher changes nothing — the separate reader holds the
last good frame over the top, so the picture stays exactly as frozen as the camera left it, and the
restart only drops the RTMP session, which trips `enableAutoStop` and **fragments the recording**.
Measured 2026-09-19: **five such restarts inside fifty minutes, every one while the camera was
down.** The monitor now probes the camera first (`nc -z -G 3 <address> 554`), refuses the restart,
and says so, naming the address:

    ACTION: FROZEN for 95s but the CAMERA at 192.168.1.3 is not answering on 554 - NOT restarting the publisher: a restart cannot fix the camera and it would fragment the recording. The reader reconnects by itself.

It is a guard, not a mute: with the camera reachable the same bad picture still restarts, and both
directions are checked end to end in `tests/t14_monitor_beat.sh`.

**The fragment is now visible where a human looks.** A `FRAGMENT` line is not a rotation, so it
never appears in the rotation history, and "why is this recording 40 minutes long" had no answer on
the health page. `bin/status.sh` now counts the `FRAGMENT:` lines in `log/stream.log` and warns,
naming what can still cause one. **The limit:** that count covers only the window `stream.log` still
holds (the log is trimmed in place), and it is a **report, not a fix** — the dead-camera restart can
no longer cause a fragment, but a stall or an OOM kill still can.
`tests/t15_resilience.sh` asserts the count is wired.

## T-12 — a recording can no longer lose its verdict to a trimmed log

`verify_pending_vods` decided which broadcasts to confirm from `rotation_history.log`, which is
deliberately trimmed to the last 100 rotations. An id whose verdict never settled — `yt-dlp`
returning "still processing" — therefore fell out of the retried set and **its recording was never
confirmed at all**. At the measured ~3 rotations a day the window is about 33 days, which is exactly
why this was invisible.

The set now lives in `log/vod_pending`, one `<id> <probes>` per line, and it is bounded in both
directions:

- a definitive MISSING is re-probed `VOD_MISSING_RETRIES` (2) times and then dropped, with a log
  line saying it is not coming back;
- an id that never resolves is dropped after `VOD_MAX_PROBES` (10) probes rather than sitting there
  forever.

The candidate set is the pending file **first**, then whatever the (bounded) history still
remembers, so an install that predates the file adopts its open ids on the first pass.
`vod_pending_add` is idempotent and the probe count is carried forward across a rewrite rather than
reset — `tests/t15_resilience.sh` drives every one of those outcomes (verified, MISSING twice,
never-resolving, adopted from the history, count carried, idempotent add).

**The limit — the rewrite is a replace, not a merge.** `verify_pending_vods` writes
`log/vod_pending.new` and `mv`s it over the file, so an append landing during the probes would be
lost. The code reasons that this cannot happen because the only appender is `vod_pending_add`
inside `record_rotation`, which runs at the **end** of `await_broadcast`'s subshell, and this
function is called either at startup or from `rotate_broadcast` **before** it starts one: the gap
between two `rotate_broadcast` calls is bounded below by `ROTATE_MIN_INTERVAL` (900 s) while a whole
`await_broadcast` — native wait 360 s + bounce 60 s + the API fallback's ingest wait 120 s — is
bounded above by about **600 s**. That ordering is the whole safety argument, and it is arithmetic
in a comment rather than a guard: if either knob is ever changed so those two cross, this must
become a merge.

## T-19 — the ingest bounce signals the pid it actually owns

`await_broadcast` runs in a `( … ) &` subshell, so `$PUBPID` was snapshotted when that subshell was
forked. A restart in between made it stale, in two directions: `kill -9` on a **recycled** pid kills
a stranger, and a stale pid that is merely **gone** makes the bounce a silent no-op while the log
claims it happened. It now reads `log/publisher.pid` at the moment of the kill and checks the pid's
command first (`pidfile_pid "$PUB_PID" ffmpeg rtmp`) — the same rule the monitor already follows.
`tests/t15_resilience.sh` asserts the pidfile call is there, that nothing in `await_broadcast` kills
the stale `$PUBPID`, and that both restart paths arm the clock retry.

**The limit:** when no live publisher owns the pidfile, the bounce is **skipped on purpose** and the
log says so (`... NOT bouncing (there is nothing to bounce; the publisher watchdog restarts it)`).
Recovery then rests on the publisher watchdog, which owns that job; guessing at a pid is how a
watchdog kills something it does not own.

## T-20 — the monitor beats before it grades, and the pass itself is bounded

`stream.sh` calls a heartbeat older than `MONITOR_STALE` (600 s) HUNG and kills the monitor so
launchd restarts it. The beat came only **after** the work, so the age meant "time since the last
pass finished" — inflated by `CHECK_INTERVAL` and by the whole duration of the pass. One slow pass
(a `yt-dlp` resolve sitting on its timeout, a stalled frame grab, the forced re-resolve in
`yt_check.py`) made a perfectly healthy monitor look hung, and the guard killed the one thing
guarding the stream: the exact reverse of its intent.

The loop now beats `CHECKING` at the **top** of the iteration, and the graded status still overwrites
it afterwards (`beat "${st:-NOSTATUS}"`), so the health page keeps showing the real verdict.
`CHECKING` is deliberately **not** one of `yt_check.py`'s statuses, so `status.sh` can still tell
"an iteration has started" from "here is what a pass graded". The deliberate backoff keeps beating
too (`beat_sleep`), so a 900 s `ROTATE_REQUEST_BACKOFF` is not mistaken for a hang.

**Beating first fixes the age's meaning but not its bound**, so the pass itself now runs under
`CHECK_TIMEOUT` (420 s). `yt_check.py`'s own timeouts total about **630 s** (3×90 s for the
`yt-dlp`/ffmpeg calls, plus a forced re-resolve that repeats two of them, plus 3×30 s for the
greyscale caches), already longer than `MONITOR_STALE` (600 s) — so an all-timeouts pass could still
age the beat past the threshold and get a healthy monitor killed for being slow, the same defect one
layer down. The ceiling is the background-and-kill idiom (macOS has no `timeout`), and
`tests/t14_monitor_beat.sh` reads `MONITOR_STALE` and `CHECK_TIMEOUT` out of the sources and **fails
if they cross**.

**The limits.** A pass killed at the ceiling returns **nothing at all** and exits non-zero, which
the monitor reads as `NOSTATUS` and handles on the **never-act** path — a killed grading pass is not
evidence of a bad picture, so it never triggers a restart. And `tests/t14_monitor_beat.sh` runs the
**real** `yt_monitor.sh` loop in the scratch tree (with a stub grader and a stubbed `nc`), so it
takes about **20 s**: it is behavioural rather than mocked, and it is one of the slower files in the
suite.

## Files in this release

| File | Change |
|---|---|
| `bin/stream.sh` | T-08: `CLOCK_RETRY_EVERY` (30) / `CLOCK_RETRY_WINDOW` (300) armed by both the publisher-death and stall-watchdog restart paths, re-adopting the clock via `refresh_broadcast_clock` and logging the `FRAGMENT:` line when the broadcast id changes; T-12: `log/vod_pending` as the retried set (`vod_pending_add`, `verify_pending_vods`), bounded by `VOD_MISSING_RETRIES` (2) and `VOD_MAX_PROBES` (10); T-19: the ingest bounce reads `log/publisher.pid` and checks the pid's command instead of the fork-time `$PUBPID` |
| `bin/yt_monitor.sh` | T-20: `beat CHECKING` at the top of the loop, with the graded status overwriting it, and `check_with_ceiling` / `CHECK_TIMEOUT` (420 s) around the grading pass; T-08: a bad picture with the camera unreachable on port 554 refuses the publisher restart and names the address |
| `conf/stream.env.example` | `CLOCK_RETRY_EVERY="30"`, `CLOCK_RETRY_WINDOW="300"`, `VOD_MISSING_RETRIES="2"`, `VOD_MAX_PROBES="10"`, `CHECK_TIMEOUT="420"`, each with the reasoning beside it |
| `bin/status.sh` | T-08: counts the `FRAGMENT:` lines in `log/stream.log` and warns on the health page, so a short VOD is explained where a human looks, naming what can still fragment (a stall or an OOM kill; a dead-camera restart no longer can) |
| `tests/t14_monitor_beat.sh` | **new** — 25 checks: the heartbeat exists and is fresh (< 2 s) at the instant the grader runs, on more than one iteration; the graded status still lands; `CHECKING` is not a graded status; `beat_sleep` keeps beating through a long backoff; `CHECK_TIMEOUT < MONITOR_STALE` read from the sources; a hanging pass is killed, returns nothing and exits non-zero; and both directions of the dead-camera guard (T-20, T-08) |
| `tests/t15_resilience.sh` | **new** — 21 checks: the pending list through verified / MISSING twice / never-resolving / adopted from the history / probe count carried / idempotent add; the clock adoption behaviourally (a new broadcast adopts its real start, an unchanged one re-uses the stored clock and costs no API call); the bounce uses the pidfile and `await_broadcast` no longer kills `$PUBPID`; both restart paths arm the retry; the `FRAGMENT:` line exists and `status.sh` counts it (T-12, T-08, T-19) |
| `docs/files.md` | `log/vod_pending` added to the runtime-state list, with why it is not derived from the trimmed `rotation_history.log` |
| `AGENTS.md` | the suite count: 520 → **569** checks |
| `README.md` | the suite count: 520 → **569** checks |
| `RELEASE.md` | the suite count: 520 → **569** checks |
| `tests/t11_paths_pids.sh` | grew to 38: every script tracked 755 is now asserted, because `install.sh` chmods `bin/*.sh` and `bin/*.py`, so the 644 `bin/cam_time.py` of 2.6 left a deployed tree that could never be clean |
| `log/vod_pending` (**runtime state, gitignored**) | the recordings still awaiting a verdict, one `<id> <probes>` per line; bounded by `VOD_MISSING_RETRIES` / `VOD_MAX_PROBES`, and adopted from the history on an install that predates it (T-12) |

## Verification

Measured on 2026-09-19 from the working tree with `zsh tests/run.sh` (serial, all files) and then
per file with `zsh tests/run.sh <name>`. The runner prints a per-file count, not a grand total;
the total below is the sum of the per-file counts.

| Test file | Checks | Result |
|---|---|---|
| `tests/t01_syntax.sh` | 53 | all passed |
| `tests/t02_monitor_classify.sh` | 12 | all passed |
| `tests/t03_files.sh` | 22 | all passed |
| `tests/t04_token.sh` | 13 | all passed |
| `tests/t05_rotation_gate.sh` | 15 | all passed |
| `tests/t06_install.sh` | 21 | all passed |
| `tests/t07_watchdog.sh` | 120 | all passed |
| `tests/t08_hosttools.sh` | 46 | all passed |
| `tests/t09_net.sh` | 42 | all passed |
| `tests/t10_camtools.sh` | 63 | all passed |
| `tests/t11_paths_pids.sh` | 38 | all passed |
| `tests/t12_deploy.sh` | 57 | all passed |
| `tests/t13_quota.sh` | 21 | all passed |
| `tests/t14_monitor_beat.sh` | 25 | all passed |
| `tests/t15_resilience.sh` | 21 | all passed |
| **Total** | **569** | **`SUITE PASSED`** |

- The project's own suite, serially: **checked** — 569 checks, all passing. The runner reports
  `ALL PASSED (N checks)` per file and `SUITE PASSED` at the end.
- `tests/t15_resilience.sh` (new): **checked** — 21 checks. The pending list through every outcome
  (an id only in `vod_pending` is verified and dropped; a MISSING is recorded, re-probed once and
  then dropped at `VOD_MISSING_RETRIES`; an unresolved id is bounded at `VOD_MAX_PROBES` and says
  so; a history id is adopted; the probe count is carried forward; the add is idempotent and an
  empty id is not recorded), the clock adoption behaviourally, the wiring for the pidfile bounce
  and the two retry sites, and that `status.sh` counts the `FRAGMENT:` lines.
- `tests/t14_monitor_beat.sh` (new): **checked** — 25 checks. The heartbeat existed and was under
  2 s old at the instant the grading command ran, on a later iteration too; the graded status
  overwrote it afterwards; `CHECKING` is not a `yt_check.py` status; `beat_sleep` wrote one beat per
  30 s chunk; `CHECK_TIMEOUT < MONITOR_STALE` as read from the sources; a hanging pass was killed at
  the ceiling, returned no output and exited non-zero; and the dead-camera guard held the restart
  with the camera down while the same picture restarted it with the camera up.
- `tests/t11_paths_pids.sh`: grew to **38** — every script tracked 755, which is what caught the
  644 `bin/cam_time.py` of the 2.6 tree.
- `bin/status.sh` (the T-08 surface): **checked** — its syntax is parsed by t01 and t11, and t15
  asserts the `FRAGMENT:` count is wired. That is a **source assertion**, not an execution against a
  log that actually holds fragments: no check here proves the warning renders correctly against a
  real `stream.log`.
- `AGENTS.md`, `README.md` and `RELEASE.md`: **checked** — all three now state the credential-free
  suite is **569** checks (they said 520 for 2.6).
- `bin/smoke_test.sh`: **not checked** — it needs `conf/yt_oauth.json`, which is gitignored and in
  no archive, so it cannot pass inside a release. It is not a release gate.
- The dead-camera guard against a **real camera**: **not checked** — t14 uses a stubbed `nc`, a
  fake `ffmpeg` and the scratch tree in `tests/.tmp`; no camera, RTSP session or YouTube ingest is
  involved in the test. The five-restart measurement of 2026-09-19 came from the live logs.
- The `vod_pending` **replace-vs-merge** ordering: **not checked** — the safety argument is the
  constant comparison in the code (`ROTATE_MIN_INTERVAL` 900 s > a whole `await_broadcast` at about
  600 s) and there is **no test that fails if those two cross**. It is stated in the code as
  reasoning, and recorded here as the limit it is.
- A real restart's effect on YouTube (`enableAutoStop` closing the old broadcast, a successor taking
  over): **not staged** — t15 stubs `yt_live_id` / `yt_api_call`; the ~9 s close and the id change
  are measured behaviour from the live channel, not reproduced in the suite.

## Deploying this

The channel is live, so this is a normal deploy: `bin/status.sh` and `bin/smoke_test.sh` on the
streamer first, then `bin/deploy-release.sh --tag v2.7`. Read
[Updating and rollback](https://github.com/Pummelchen/YTLive_Laundry/wiki/Updating-and-Rollback)
first. There is no config migration: every new tunable has a default in the scripts, so an
unchanged `conf/stream.env` keeps working. Three things are worth checking after the first restart:

- `log/vod_pending` should exist and hold one `<id> <probes>` line per recording still awaiting a
  verdict; each rotation adds one and a settled one leaves. An absent file just means nothing has
  rotated since the deploy. `log/vod_status` is still the verdict record.
- `log/monitor.heartbeat` should read `CHECKING` **while a pass is running** and the graded status
  (`OK`, `FROZEN`, …) between passes. In `conf/stream.env`, `CHECK_TIMEOUT` must stay below
  `MONITOR_STALE`; if a heartbeat older than `MONITOR_STALE` (600 s) is ever seen, the monitor is
  genuinely hung now, not merely slow.
- A `FRAGMENT:` line in `stream.log` appears **only** when a restart actually closed the broadcast
  and a new one took over. It is the explanation for a short VOD, not a new fault — and if the
  camera is down, `monitor.log` should show the publisher restart being **held back** with the
  camera's address, while the publisher itself keeps running.

```
SHA256  SHA256_PENDING
BYTES   ARCHIVE_BYTES_PENDING
```
