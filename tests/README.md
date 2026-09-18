# tests/ — the credential-free gate

    bin/smoke_test.sh        the pre-restart gate (needs conf/yt_oauth.json: no credentials, no gate)
    tests/run.sh             zsh tests/run.sh           all tests
                             zsh tests/run.sh t02 t05     selected, by prefix
                             zsh tests/run.sh --list      what is covered

`bin/smoke_test.sh` answers "is this tree safe to restart". It cannot answer anything about
*runtime behaviour*, and it needs a real OAuth token to do even that. This directory is the missing
half: it exercises the rotation, watchdog, monitor-classification and file-maintenance logic with
**no credentials, no camera, no network and no ffmpeg**.

## The safety property

The production stream runs on another Mac, but these tests must still be safe to run *on* the
streamer. Two rules, both enforced by `tests/lib.sh`:

1. **Nothing is written outside `tests/.tmp/`.** Every test gets its own scratch tree there, with
   its own `conf/`, `log/` and `HOME`. The checkout is never modified.
2. **Stubs shadow the real tools.** `tests/stubs` goes first on `PATH` and `HOME` points inside the
   scratch tree, so a test can never reach the real `ffmpeg`, `yt-dlp`, `nc`, `caffeinate`,
   `launchctl` or `pkill`.

`tests/stubs/pkill` is a **recorder, not a killer**. `bin/yt_monitor.sh` runs
`pkill -9 -f "ffmpeg.*rtmp"` and `bin/stream.sh` runs `pkill -9 -f "zsh.*yt_monitor.sh"`; a
mis-scoped test that reached the real `pkill` could kill an operator's unrelated process, or the
live publisher. The stub logs the call and exits 1. Only a test that explicitly sets
`STUB_PKILL_REAL=1` can signal anything, and none does.

## What is covered today

| File | Covers |
|---|---|
| `t01_syntax.sh` | Every shell script parses, every Python file is valid AST, and the use-before-assignment class that took the channel dark on 2026-09-07 is absent. |
| `t02_monitor_classify.sh` | The monitor's status classification, read out of the **real** `case` arms in `bin/yt_monitor.sh`: `NOGOLDEN`/`NOCONFIG`/`ERROR` must never be treated as a bad picture. Moving one back into the `*)` catch-all fails this test. |
| `t03_files.sh` | The golden-reference refresh fires when `conf/golden.jpg` is **missing** (zsh's `-nt` is false against a missing file), and the in-place log trim keeps the same inode while never touching `log/progress.txt`. |
| `t04_token.sh` | The `yt_api.py token` contract: one JSON line, `probe` = `LIVE`/`DEAD`/`UNKNOWN`, `--offline` behaviour, an elapsed countdown that never overrides a working token, and `save_creds()` writing 0600 from the first byte. |
| `t05_rotation_gate.sh` | `prepare_broadcast()` runs **before** the publisher ffmpeg starts (the bind-before-ingest invariant), the rotation refuses to cut without a usable API, and the refusal backs off instead of retrying every 5 seconds. |
| `t06_install.sh` | `install.sh` is executed **end to end** in a sandbox with its own `HOME`, `PATH` and fake interpreters, so the `set -u` abort that broke the 2026-09-17 deploy can never ship syntax-checked again. |
| `t07_watchdog.sh` | The external watchdog (`bin/yt_watchdog.py`) and its alert policy, as a pure function of time and two stubbed signals: a short rotation gap must not alert, `UNKNOWN` is never treated as darkness, an undeliverable alert is spooled rather than dropped, and the channel and host signals stay independent. |
| `t08_hosttools.sh` | The two host tools. `bin/harden-host.sh`: the dry run writes nothing, `--check` fails on an unhardened host and passes on a hardened one, half-hardened is still a failure, and `--go` refuses without root — all against a `pmset` stub that reports its two keys **only when enabled**, which is how macOS behaves and is what makes an absent key a failure rather than an unknown. And `bin/forensics.sh` gathers the sleep/memory/disk/panic evidence while changing nothing. |

The suite prints one line per check and exits non-zero if any failed. It is not wired to CI —
there is no `.github/` in this repository — so run it yourself before pushing, and always before
restarting the stream.

## Adding a test

Copy the shape of an existing file: source `lib.sh`, `t_begin`, use `t_setup` for a scratch tree,
`t_extract_fn` to lift a single function out of a script so you can exercise it without running the
script's main body, then `t_assert_*` and `t_summary`. Name it `tNN_something.sh`.

Prefer extracting the real thing over restating it. `t02` parses the actual `case` arms and `t03`
evaluates the actual condition text — a test that copies the logic it is checking will keep passing
after the code changes, which is worse than no test at all.

## What cannot be tested here

YouTube's real autoStart-on-ingest behaviour, whether a bound broadcast recovers after an ingest
bounce, real thumbnail suggestions, VOD archival timing, and the camera firmware's habit of
accepting encoder writes and ignoring them. Those need the real channel and the real camera. A
passing simulation must never be reported as proof that rotation works.
