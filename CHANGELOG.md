# Changelog

The scheme is two-component `MAJOR.MINOR`, released as the tags `v1.0`, `v2.0` and `v2.1`. The
authoritative version is the `VERSION` file at the repository root; a release refuses to build
when `VERSION` and the tag disagree. There is no version literal in any script: the streamer's
tunables live in `conf/stream.env`.

Each release is a source archive of the tagged tree with a SHA-256 beside it. There is nothing
to compile. See `release.sh` and [`RELEASE.md`](RELEASE.md).

## 2.1 — 2026-09-17

**The installer could never complete, and it installed the wrong `yt-dlp`.** Full notes with the
evidence: [`docs/release-notes-v2.1.md`](docs/release-notes-v2.1.md).

Both defects were found by running the 2.0 deploy for real on 2026-09-17. It failed at
`install.sh` and rolled back — and the rollback then reported success while leaving the machine's
`yt-dlp` broken and the monitor blind, because the damage was outside the project tree. Three
fixes, and a gate so this class of bug cannot ship again:

- **`install.sh` could not run at all.** `write_plist()` declared five variables in one `local`,
  and a shell expands *all* of a command's arguments before `local` executes — so `$label` was read
  while still unset and, under `set -u`, the shell exited: `write_plist:1: label: parameter not
  set`. Each declaration is now on its own line.
- **It picked the wrong Python.** `PY=$(command -v python3)` trusted PATH order and chose the
  Xcode Command Line Tools **3.9.6** instead of the python.org **3.14** on the same machine. pip
  then resolved `yt-dlp` to the last release supporting 3.9 (`2025.10.14`), which can no longer
  parse YouTube's live page, and `ln -sf` put that stale build **over a working
  `~/.local/bin/yt-dlp`** (`2026.08.19`), blinding the monitor. The installer now scans PATH *and*
  the usual install locations, prefers an interpreter that already has `yt_dlp`, and falls through
  to the next candidate when pip refuses (`PEP 668` on Homebrew Python).
- **It no longer clobbers a working `yt-dlp` with a worse one.** The existing binary is compared
  first and kept if it is newer; if a replacement is written and does not run, the previous one is
  restored automatically.
- **`bin/deploy-release.sh`** replaces the ad-hoc deploy. Its backup covers what `install.sh`
  actually writes — `~/.local/bin`, `~/Library/LaunchAgents`, `~/Library/Logs/YTLive` — not just
  the project tree, it refuses a downgrade, and it verifies the *result* (including that `yt-dlp`
  still resolves the live page) rather than trusting an exit code.
- **`tests/t06_install.sh`** actually **runs** `install.sh` in a sandbox with fake interpreters.
  The suite only syntax-checked it, which is exactly how a fatal runtime abort passed the release
  gate. The new test fails **16 of 21** checks against the released 2.0 installer and passes 21/21
  against this one.

## 2.0 — 2026-09-16

The fixes from the 2026-09-16 full audit. Full notes, with the
check behind each change: [`docs/release-notes-v2.0.md`](docs/release-notes-v2.0.md).

The audit report itself is **not** kept in the tree, so a later audit cannot mistake a finished one
for a current one; it is archived by permalink instead:
<https://github.com/Pummelchen/YTLive_Laundry/blob/d603fdcf92dff17bfb7aa770562b04b84e37e71d/AUDIT/2026-09-16-full-audit.md>

**Two defects could kill a healthy publisher, and both are fixed.** `bin/yt_monitor.sh` treated
the `NOGOLDEN`, `NOCONFIG` and `ERROR` statuses as a bad picture and `pkill`ed the publisher every
`FAIL_SECONDS`, forever; and `conf/golden.jpg` could never be bootstrapped, because zsh's `-nt` is
false against a missing file and `golden.jpg` is gitignored — so a fresh install hit that loop
permanently. Both are now regression-guarded.

**The OAuth credential is checked by probing, not by a countdown.** `bin/yt_api.py token` mints a
real access token and reports `LIVE`/`DEAD`/`UNKNOWN`; the 7-day countdown is advisory only, and
`YT_TOKEN_TTL_DAYS=0` silences it once the OAuth app is published. This matters because the
7-day expiry is a "Testing" publishing-status behaviour, and publishing the app removes it without
any Google verification.

**A rotation with no usable API now stays live instead of going dark.** `prepare_broadcast()`
creates and binds the next broadcast on every cut, so an unusable credential used to mean a dark
channel at the next rotation. `rotate_broadcast()` now refuses to cut (`ROTATE_WITHOUT_API="no"`),
trading one unarchived segment for a channel that keeps streaming and recovers by itself.

Also: `save_creds()` writes the OAuth token 0600 from the first byte; `bin/smoke_test.sh` no
longer passes on `{"status":"ERROR"}`; `bin/cam_reboot.py` no longer reboots the camera on import;
`bin/shuffle_playlist.sh` fails loudly instead of writing a too-short playlist; `cam_ip_watcher`
updates the in-memory `CAM_URL` after a DHCP move; `install.sh` can install a fresh clone, checks
`YT_KEY` correctly, `chmod 600`s the token, uses a private `mktemp -d` for its Full Disk Access
probe, and can verify the ffmpeg/ffprobe digests; `housekeep` and `status.sh` warn about free
disk; and 40+ documentation claims that contradicted the code were corrected.

Added `tests/`: a credential-free harness of 84 checks that needs no camera, network, credentials
or ffmpeg, and shadows `pkill` with a recorder so a mis-scoped test cannot signal the live
publisher.

## 1.0 — 2026-09-16

The code that was live in production on the streamer when the audit began. There are no changes
in it — it is the baseline. Notes: [`docs/release-notes-v1.0.md`](docs/release-notes-v1.0.md).

Published so a rollback is a download rather than a dig through history. **It contains every
defect the audit found**, including both publisher-killing bugs above; the notes name them.
