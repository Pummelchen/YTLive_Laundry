# YTLive_Laundry 2.0 — the audit fixes

The fixes from the [2026-09-16 full audit](../AUDIT/2026-09-16-full-audit.md). This is the
version to deploy.

- Built from tag `v2.0`
- Contents: the tagged tree **without `MP3/`** and without `backup/`. The 25-track, 328 MB music
  library is byte-identical in git at the same tag (`git checkout v2.0 -- MP3`).
- Source archive, not a build product: nothing to compile, no binaries, nothing to sign.

**Deploying this does not happen by itself.** The production streamer runs 1.0. Nothing in this
repository pushes to it; see `docs/machines.md` for the rsync + `install.sh` procedure.

## Two defects could kill a healthy publisher

**The monitor no longer restarts a stream that is fine.** `bin/yt_monitor.sh`'s `case` named only
`OK`, `UNKNOWN|FETCHFAIL|NOSTATUS|""`, `OFFLINE` and a catch-all `*)` for *"YouTube is live but
showing the wrong thing"*. `bin/yt_check.py` can also answer `NOGOLDEN`, `NOCONFIG` and `ERROR`,
and those fell into the catch-all — so after `FAIL_SECONDS` the monitor ran
`pkill -9 -f "ffmpeg.*rtmp"` against a healthy publisher. With `yt-dlp` missing that was a restart
every ~150 s, forever. Those three statuses now join the never-act arm, which is what the file's
own rule 2 already demanded.
*Check:* `tests/t02_monitor_classify.sh` — parses the **real** `case` arms and asserts where each
status lands. Reverting the fix makes it fail 3 of its checks (demonstrated).

**The golden reference can now be created.** `conf/golden.jpg` was refreshed only when
`[[ basefill.jpg -nt golden.jpg ]]`, and in zsh `-nt` is FALSE when the right-hand file does not
exist. `golden.jpg` is gitignored, so a fresh install had none and the refresh could never fire:
every check returned `NOGOLDEN`, which per the defect above meant an unbreakable publisher-restart
loop. The test now also fires when the reference is simply absent.
*Check:* `tests/t03_files.sh` — extracts the live condition from `yt_monitor.sh` and evaluates it
against a missing `golden.jpg`. Reverting makes it fail (demonstrated).

## The OAuth credential is probed, not counted down

`bin/yt_api.py token` now attempts a real refresh (`probe_refresh_token`) and reports
`"probe": "LIVE"|"DEAD"|"UNKNOWN"`. The 7-day countdown is **advisory only**: it is a guess about
Google's "Testing" rule and is wrong once the app is published, so an elapsed countdown on a token
Google still accepts is reported as probable publication, never as an outage. `YT_TOKEN_TTL_DAYS=0`
silences it, and `token --offline` keeps the network-free path for `status.sh --no-net`.
*Check:* `tests/t04_token.sh` — 13 checks over the JSON contract, the exit codes and both
countdown paths (an elapsed countdown with a live token must not say `EXPIRED`).

**The underlying problem is a console setting, not a code problem.** The 7-day expiry applies to
an External app whose publishing status is "Testing". Publishing it to **"In production"** removes
the clock, and **Google verification is NOT required to do that** — an unverified published app
still works for its owner behind one "unverified app" warning. `bin/yt_api.py auth` prints the
click-path at step 4. Until it is published, a human must re-authorise every 7 days; no code change
can remove that.

## A rotation with no usable API now stays live

`prepare_broadcast()` runs inside `start_publisher()` on every publisher start and creates and
binds the next broadcast, so an unusable credential meant the channel went dark at the next
rotation — the documented five-hour outage of 2026-09-05. `rotate_broadcast()` now **refuses to
cut** and keeps streaming: an unarchived segment beats a dark channel, because darkness needs a
human anyway. `ROTATE_WITHOUT_API="yes"` restores the old behaviour and `ROTATE_API_RETRY="900"`
backs the retry off so the 5-second loop cannot hammer it.
*Check:* `tests/t05_rotation_gate.sh` — drives `api_usable()` with stubbed probe output. An
`EXPIRING` token with `"probe": "LIVE"` must still count as usable (a bare exit status would
wrongly refuse to rotate a healthy channel).

## Bind before ingest is now guarded

The invariant that cost 19 minutes of dark air on 2026-09-05 was documented but untested: a
broadcast must be created and bound **before** ffmpeg pushes, because `enableAutoStart` fires on
ingest *arrival* and binding afterwards leaves it in `ready` forever.
*Check:* `tests/t05_rotation_gate.sh` — asserts `prepare_broadcast()` appears before the publisher
launch inside `start_publisher()`.

## Other fixes

| Change | Check that backs it |
|---|---|
| `save_creds()` creates the OAuth token 0600 from the first byte (was 0644-then-chmod, a window on a credential that grants control of the channel) | `tests/t04_token.sh` (asserts `0o600`) |
| `bin/smoke_test.sh` judges the API **status**, so `{"status":"ERROR"}` fails instead of passing | Observed by running it on a credential-less checkout: it now reports 4 FAIL, where it previously reported PASS |
| `cam_ip_watcher` updates the in-memory `CAM_URL`/`CAM_HOST` after a DHCP move, so the per-start snapshot does not silently degrade to a colour filler | Static; no test yet (tracker T-14/T-15 area) |
| `housekeep` warns below 200 MB free; `status.sh` reports free space, not just usage | Static; `tests/t01` covers syntax only |
| `bin/cam_reboot.py` does nothing on import (it rebooted the camera merely being loaded) | Static; no test yet |
| `bin/shuffle_playlist.sh` fails loudly when `ffprobe` is missing or a track cannot be measured, and receives `ROTATE_HOURS` explicitly instead of silently ignoring it | Static; no test yet |
| `install.sh` seeds `conf/stream.env` on a fresh clone, detects an empty `YT_KEY` correctly, `chmod 600`s the token, uses a private `mktemp -d` for the Full Disk Access probe, and can verify the ffmpeg/ffprobe digests via `FFMPEG_SHA256`/`FFPROBE_SHA256` | Static; syntax gate only |
| 40+ documentation claims that contradicted the code were corrected, including the account of the rotation itself | Repository-wide consistency sweep; every correction cites the code or `conf/stream.env.example` |

## Added: a test suite

`tests/` is new in 2.0 — a credential-free harness of **84 checks** that needs no camera, network,
credentials or ffmpeg. It runs in its own scratch tree and shadows `pkill` with a recorder, so a
mis-scoped test cannot signal the live publisher.

*Check:* `tests/run.sh` — this is the suite. Its guards are proved able to fail: reverting the two
monitor fixes makes `t02` and `t03` fail exactly as described above.

## Checks

| Gate | Result |
|---|---|
| Archive contents hash-match tag `v2.0` | **checked** — every file compared by `git hash-object` against `git rev-parse v2.0:<path>` |
| Shell/Python syntax of the archived tree | **checked** — `zsh -n` per script, `ast.parse` per module |
| The project's own test suite, serially | **checked** — 84 checks, all passing, run from the archived tree |
| The guards can fail | **checked** — the two monitor guards were reverted and observed failing, then restored |
| `shasum -a 256 -c` against the published `.sha256` | **checked** |
| `bin/smoke_test.sh` end to end | **NOT CHECKED — it needs `conf/yt_oauth.json`**, which is not in any release |
| Clean scratch build / warning scan | **NOT APPLICABLE — nothing is compiled.** |
| Real rotation, ingest and VOD archival | **NOT CHECKED — requires the channel and the camera.** A passing simulation is not evidence that rotation works. |
| CodeQL | **checked on the push** — GitHub's dynamic Python analysis, completed successfully, 0 open alerts |

## Install

    shasum -a 256 -c YTLive_Laundry-2.0-source.tar.gz.sha256
    mkdir -p ~/Downloads/YTLive && tar -xzf YTLive_Laundry-2.0-source.tar.gz -C ~/Downloads/YTLive
    cd ~/Downloads/YTLive
    cp conf/stream.env.example conf/stream.env     # paste your stream key into YT_KEY
    ./install.sh                                   # installs, does not start
    bin/yt_api.py auth                             # OAuth device flow, one time
    ./install.sh --start

Only ONE machine may push to a given YouTube stream key at a time.

## Integrity

    SHA256  SHA256_PENDING
    BYTES   ARCHIVE_BYTES_PENDING

The placeholders above are substituted with the real values when the GitHub Release is published;
`release.sh` refuses to publish notes that carry neither them nor a real digest.

## Rolling back

Release 1.0 is the previous version, published from the same repository and built the same way.
Switching back is an unpack over the install directory plus `install.sh`; no git history is
involved.
