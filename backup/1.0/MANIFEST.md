# YTLive_Laundry — version 1.0, live production snapshot

|  |  |
|---|---|
| **Version** | `1.0` |
| **Git commit** | `fd8698f15a8d20b1d8d525d612cf18e7438d3996` — *"docs: AGENTS.md no longer depends on another repository"*, 2026-09-16 07:47:38 +0700 |
| **Git tag** | `v1.0` (annotated, points at that commit) |
| **Snapshot taken** | 2026-09-16 |
| **Files** | 41 (see `SHA256SUMS`) |
| **Size** | ~932 KB |

## Why this exists

This is a frozen copy of the code that was **running in production** when the
[2026-09-16 audit](../../AUDIT/2026-09-16-full-audit.md) began. The audit then changed the
tree; this folder keeps the exact live revision recoverable inside the repository, so
"what was actually deployed" never has to be reconstructed from memory or from a
force-pushed history.

It is a **source snapshot, not a release.** There is no compiled artifact and no GitHub
Release page, and `RELEASE.md` Part 1's packaging rules do not apply to a project with
nothing to build. A tag alone is not a release, and this tag does not pretend to be one.

## What this is NOT

- **Not a byte-for-byte copy of the deployed working tree.** The production host
  (`user@ternak-macbook`, 100.75.83.5) was not reachable from the audit machine — its SSH
  key is not authorised there — so any uncommitted local edits on the streamer, such as a
  hand-edited `conf/stream.env`, are not captured. The committed state is the best record
  that exists.
- **Not the credentials.** `conf/stream.env` (the YouTube stream key) and
  `conf/yt_oauth.json` (the OAuth refresh token) are gitignored, were never committed at any
  point in this repository's history, and are not here. A restore needs the operator to
  supply both.
- **Not the music library.** `MP3/` is excluded: 25 tracks, 328 MB, and it is byte-identical
  to the copy pinned in git at the same commit (`git checkout v1.0 -- MP3` restores it).

## Contents

Everything tracked at `fd8698f`, except `MP3/`:

    bin/           18 scripts: stream.sh, yt_monitor.sh, yt_api.py, yt_check.py, lib.sh,
                   the camera/ONVIF tools, status.sh, smoke_test.sh, shuffle_playlist.sh,
                   preflight.sh, ssh_mesh.sh
    conf/          stream.env.example, broadcast_template.json, playlist.txt, the camera XML
                   dumps, ternak-macbook.pub, three thumbnails
    docs/          the 8 design/ops notes
    install.sh, README.md, AGENTS.md, CLAUDE.md, RELEASE.md, LICENSE, .gitignore

`MANIFEST.md` (this file) and `SHA256SUMS` are additions describing the snapshot; they are
not part of `fd8698f`.

## Known defects in 1.0 — read this before restoring it

Version 1.0 is the code the audit examined, and it contains every defect the audit found. The
two that could take the channel off air are:

1. **The monitor could kill a healthy publisher.** `bin/yt_monitor.sh`'s `case` had a catch-all
   `*)` for "YouTube is live but showing the wrong thing", but `yt_check.py` can answer
   `NOGOLDEN`, `NOCONFIG` and `ERROR`, which fell into it — so a missing reference frame or any
   `yt_check.py` exception made the monitor `pkill` the publisher every `FAIL_SECONDS`, forever.
2. **`conf/golden.jpg` could never be created.** The refresh test was
   `[[ basefill.jpg -nt golden.jpg ]]`, and in zsh `-nt` is FALSE when the right-hand file does
   not exist. `conf/golden.jpg` is gitignored, so a fresh install had none, so every check
   answered `NOGOLDEN` — which, per (1), meant an unbreakable publisher-restart loop.

Also present in 1.0: `save_creds()` created the OAuth token file 0644 before chmod'ing it;
`bin/smoke_test.sh` accepted `{"status":"ERROR"}` as a pass; `bin/cam_reboot.py` rebooted the
camera merely on import; `bin/shuffle_playlist.sh` silently ignored a raised `ROTATE_HOURS` and
wrote a too-short playlist when `ffprobe` was missing; `cam_ip_watcher` left the in-memory
`CAM_URL` stale after a DHCP move; `install.sh` aborted on a fresh clone and used a fixed,
spoofable `/tmp` path for its Full Disk Access probe; and no disk-space check existed anywhere.

`AGENTS.md`, `README.md` and the `docs/` in this snapshot still carry the **wrong** account of
the rotation: they claim YouTube creates the next broadcast by itself and that the Data API is
only a fallback. It does not and it is not — `prepare_broadcast()` creates and binds the next
broadcast on every cut, and with no usable credential the channel goes dark at the next
rotation. See `AUDIT/2026-09-16-full-audit.md` §2.

## Restoring

From this repository, without touching the working tree:

    git checkout v1.0 -- .          # restore 1.0 into the working tree (includes MP3/)

Or use this folder as a plain tree:

    rsync -a backup/1.0/ ~/Downloads/YTLive/

Then supply `conf/stream.env` (with `YT_KEY`) and `conf/yt_oauth.json` — see `install.sh` and
`bin/yt_api.py auth`. Only one machine may push to a given stream key at a time.

## Integrity

    cd backup/1.0 && shasum -a 256 -c SHA256SUMS
