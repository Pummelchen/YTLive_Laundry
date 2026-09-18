# Running it

## Control
    launchctl load -w   ~/Library/LaunchAgents/com.user.cctv-stream.plist   # start
    launchctl unload    ~/Library/LaunchAgents/com.user.cctv-stream.plist   # stop

There are TWO jobs and both must be loaded - `com.user.cctv-stream` (the streamer) and
`com.user.cctv-monitor` (the watchdog). For a while only the streamer was installed here
and the watchdog was running as a hand-started orphan, so it would not have survived a
reboot, and nothing would have said so: the streamer's own KeepAlive kept everything
looking healthy. `bin/status.sh` now reports both, and stream.sh watches the watchdog's
heartbeat (log/monitor.heartbeat) - if it goes stale the streamer restarts it, because
launchd revives a job that EXITS but not one that HANGS.
    ~/Downloads/YTLive/bin/status.sh          # everything that can fail silently, on one page
    ~/Downloads/YTLive/bin/status.sh --no-net  # same, skipping the YouTube API calls

The logs are the project's own bookkeeping, not a report to be read - nothing on the streamer
depends on a human noticing anything, and there are deliberately no notifications there. Every
failure path retries instead of reporting. status.sh is the one place that answers "is it
healthy". The one exception is host-level failure, which retries cannot cover: on 2026-09-18 the
MacBook lost power and slept, the channel stayed dark 10 h 23 m, and nothing said so. The
external watchdog (`bin/yt_watchdog.py`) emails a human for exactly that class - it runs off the
streamer, and is the only thing allowed to notify. See docs/watchdog.md.

Reshuffle the music (takes effect on next restart):
    ~/Downloads/YTLive/bin/shuffle_playlist.sh
Or set RESHUFFLE_ON_START="yes" in conf/stream.env for a fresh order on every restart.

## Before you restart anything: bin/smoke_test.sh
Both outages this project has had came from the same mistake - editing a path and
validating everything except that path. `prepare`/`_create_and_bind` only runs when a
broadcast has to be CREATED, once every 8 hours, so an `UnboundLocalError` in it sat
harmless for hours and then fired during a scheduled rotation, taking the channel dark.

    bin/smoke_test.sh        exit 0 = safe to restart

It checks every script parses, runs the read-only API commands, scans for the specific
use-before-assignment class with an AST pass, and exercises the creation path through
`yt_api.py prepare --dry-run`, which builds the real request body without sending it.
Verified against the actual bug: reintroduced in a copy, the test fails twice over -
statically and at runtime with the genuine UnboundLocalError.

## Modes (conf/stream.env)
    MODE="crop"    cut the one timestamped panel and HW-encode it. Current. ~50% of one core.
    MODE="encode"  letterbox the whole tall stack into 16:9.

There is no `MODE="copy"` case in stream.sh - its `case` has only `crop` and `encode`. The
publisher ALWAYS re-encodes with `h264_videotoolbox`, so there is no passthrough mode even
in principle.

## Host hardening (run once, on the streamer)
On 2026-09-18 the streamer dropped off the network at 10:19:54Z - a shop power/router loss,
after which the Mac ran on battery and slept - and the channel stayed dark 10 h 23 m with
nothing reporting it. No in-process watchdog could see that, because the host itself was gone.
Two `pmset` settings make the host harder to lose, and they are set once, as root, on the
streamer:

    sudo pmset -a autorestart 1              # come back up after a power failure
    sudo pmset -c sleep 0 disablesleep 1     # never sleep, lid closed included
    pmset -g | grep -Ei 'sleep|autorestart'  # verify
    pmset -g | grep -i SleepDisabled         # must be 1

`autorestart` makes the Mac boot again as soon as mains power returns, so a power failure
becomes a reboot rather than an outage. `sleep 0` with `disablesleep 1` keeps it awake with the
lid shut, so closing the Mac does not suspend the stream. The limit matters as much as the fix:
neither setting can do anything if the Mac loses power entirely or is unplugged, because no
setting runs code on a machine with no power - that case needs a UPS on the Mac **and** the
router, and it is why the external watchdog (docs/watchdog.md) exists. The lid-closed half is
the long-standing item docs/known-issues.md used to carry.

## Disk and logs  (added 2026-09-05)
Nothing bounded the logs before, and `log/` was tracked in git - so every commit stored
another copy of a multi-megabyte `publisher.log`. `.git` is 353 MB, but the logs are not why:
measured across the whole history, `log/` accounts for 26.6 MB and `conf/` for 3.7 MB, while
the tracked `MP3/` library is **328.4 MB** of it. The weight is the music. Both are gitignored
now, which stops new copies but does not remove the blobs already in the public history (see
the accepted-risk note in the wiki Project-Tracker).

    LOG_MAX_BYTES=524288      512 KB cap per log file (the shipped conf/stream.env.example)
    HOUSEKEEP_EVERY=300       stream.sh trims every 5 min, and once at startup

stream.sh's own built-in default is 2097152 (2 MB), but the shipped example sets 524288, and
the shipped config wins.

Trimming rewrites the SAME inode, keeping the last `LOG_MAX_BYTES/2` = 256 KB, rather than
renaming the file. That matters: ffmpeg holds an `O_APPEND` fd on `publisher.log`, so a
rename would leave it writing to an unlinked inode forever, invisibly. Verified with a live
append-mode writer - it kept appending correctly across a trim, with no offset corruption.

`log/progress.txt` is deliberately NOT trimmed: ffmpeg writes it at a fixed offset, so
rewriting it underneath would corrupt the frame counter the publisher watchdog reads. It is
truncated at every publisher start instead, which bounds it to one rotation's worth (~12 MB).

Runtime state is gitignored, not tracked: `log/` and `conf/golden.jpg` (re-grabbed at every
publisher start). `MP3/` stays tracked: it is write-once, so it does not grow - but at 328.4 MB
it is nearly the whole 353 MB `.git`, so it is also not a rounding error. The blobs already in
public history (the MP3 library, plus the `log/` and `conf/golden.jpg` copies that were tracked
until 2026-09-05) are untouched; removing any of them needs a history rewrite and a force-push,
which is a separate, deliberate decision - see the accepted-risk note in the wiki Project-Tracker.
