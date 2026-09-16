# YTLive_Laundry 1.0 — the code that was live in production

**This release has no changes. It is the baseline.** It exists so that rolling back to the code
that was running on `ternak-macbook` when the 2026-09-16 audit began is a download rather than a
dig through git history.

- Built from tag `v1.0` → commit `fd8698f15a8d20b1d8d525d612cf18e7438d3996`
  (*"docs: AGENTS.md no longer depends on another repository"*, 2026-09-16 07:47:38 +0700)
- Contents: the tagged tree **without `MP3/`**. The 25-track, 328 MB music library is
  byte-identical in git at the same tag (`git checkout v1.0 -- MP3`), and it is not code.
- Source archive, not a build product: nothing to compile, no binaries, nothing to sign.

## What is in it

The two-process CCTV → YouTube streamer: `bin/stream.sh` (reader → local UDP → publisher → RTMP,
watchdog, 8h03m rotation, VOD verification), `bin/yt_monitor.sh`, `bin/yt_api.py`, `bin/yt_check.py`,
the camera/ONVIF tools, `install.sh`, and the tracked `conf/` and `docs/`.

## Read this before you deploy 1.0

**It contains every defect the audit found.** Two of them could take the channel off air:

1. **The monitor could kill a healthy publisher.** `bin/yt_monitor.sh`'s `case` had a catch-all
   `*)` meaning *"YouTube is live but showing the wrong thing"*, but `bin/yt_check.py` can answer
   `NOGOLDEN`, `NOCONFIG` and `ERROR`, which fell into it — so a missing reference frame or any
   `yt_check.py` exception made the monitor `pkill` the publisher every `FAIL_SECONDS`, forever.
2. **`conf/golden.jpg` could never be bootstrapped.** The refresh test was
   `[[ basefill.jpg -nt golden.jpg ]]`, and in zsh `-nt` is FALSE when the right-hand file does
   not exist. `conf/golden.jpg` is gitignored, so a fresh install had none, so every check
   answered `NOGOLDEN` — which, per (1), meant an unbreakable publisher-restart loop.

Also present in 1.0: `save_creds()` created the OAuth token file 0644 before chmod'ing it;
`bin/smoke_test.sh` accepted `{"status":"ERROR"}` as a pass; `bin/cam_reboot.py` rebooted the
camera merely on import; `bin/shuffle_playlist.sh` silently ignored a raised `ROTATE_HOURS` and
wrote a too-short playlist when `ffprobe` was missing; `cam_ip_watcher` left the in-memory
`CAM_URL` stale after a DHCP move; `install.sh` aborted on a fresh clone and used a fixed,
spoofable `/tmp` path for its Full Disk Access probe; and nothing anywhere checked free disk.

Its `AGENTS.md`, `README.md` and `docs/` also carry a **wrong** account of the rotation — that
YouTube creates the next broadcast by itself and the Data API is only a fallback. It does not, and
it is not. Use the docs from 2.0 if you are working on either version.

## Checks

| Gate | Result |
|---|---|
| Archive contents hash-match tag `v1.0` | **checked** — every file compared by `git hash-object` against `git rev-parse v1.0:<path>` |
| Shell/Python syntax of the archived tree | **checked** — `zsh -n` per script, `ast.parse` per module |
| `shasum -a 256 -c` against the published `.sha256` | **checked** |
| The project's own test suite | **NOT CHECKED — 1.0 has no `tests/` directory.** The harness was added in 2.0. |
| `bin/smoke_test.sh` end to end | **NOT CHECKED — it needs `conf/yt_oauth.json`**, which is not in any release. Its syntax and AST phases pass; its API phase cannot run here. |
| Clean scratch build / warning scan | **NOT APPLICABLE — nothing is compiled.** |
| Real rotation, ingest and VOD archival | **NOT CHECKED — requires the channel and the camera.** No simulation here is evidence that rotation works. |

## Install

    shasum -a 256 -c YTLive_Laundry-1.0-source.tar.gz.sha256
    mkdir -p ~/Downloads/YTLive && tar -xzf YTLive_Laundry-1.0-source.tar.gz -C ~/Downloads/YTLive
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
