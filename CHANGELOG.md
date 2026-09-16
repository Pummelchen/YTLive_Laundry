# Changelog

The scheme is two-component `MAJOR.MINOR`, released as the tags `v1.0` and `v2.0`. The
authoritative version is the `VERSION` file at the repository root; a release refuses to build
when `VERSION` and the tag disagree. There is no version literal in any script: the streamer's
tunables live in `conf/stream.env`.

Each release is a source archive of the tagged tree with a SHA-256 beside it. There is nothing
to compile. See `release.sh` and [`RELEASE.md`](RELEASE.md).

## 2.0 — 2026-09-16

The fixes from the [2026-09-16 full audit](AUDIT/2026-09-16-full-audit.md). Full notes, with the
check behind each change: [`docs/release-notes-v2.0.md`](docs/release-notes-v2.0.md).

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
