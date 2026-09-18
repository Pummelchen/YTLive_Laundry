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
On 2026-09-18 the streamer dropped off the network at 10:19:54Z and the channel stayed dark
10 h 23 m with nothing reporting it. The mechanism is not the obvious one, and it is why this
section now exists. **The MacBook's lid is always shut and it had streamed that way for days.**
What kept it awake was `stream.sh`'s `caffeinate -ism` - and `caffeinate -s`'s system-sleep
assertion is valid **only on AC power**, while lid-close (clamshell) sleep is a separate
assertion that none of those flags touch. So a *momentary* interruption of mains power is
enough: on battery with the lid shut the Mac sleeps immediately, and nothing wakes a closed-lid
Mac - wake-on-LAN is LAN-only, and `autorestart` has nothing to do with waking a machine that is
merely asleep. It stays dark until a human opens the lid.

Two settings cover that class, and `bin/harden-host.sh` applies and verifies them:

    bin/harden-host.sh                 # dry run: show the plan and the current settings
    sudo bin/harden-host.sh --go       # apply, then verify
    bin/harden-host.sh --check         # verify only, change nothing

which is exactly:

    sudo pmset -a autorestart 1              # come back up after a power failure
    sudo pmset -c sleep 0 disablesleep 1     # never sleep, lid closed included

`disablesleep 1` is the one that answers this outage: it makes the machine ignore lid-close and
stay awake on battery as well. `autorestart` covers the harder case where the machine really
does lose power and shut down - launchd cannot revive a Mac that is off. Both keys are reported
by `pmset` **only when they are enabled**, so `--check` treats an absent key as a failure rather
than as an unknown, and it will not let this be closed on a guess.

The limit matters as much as the fix: neither setting runs code on a machine with no power. If
the shop loses mains for long enough, the camera and the router go dark too, and that needs a
UPS on the Mac **and** the router (T-30). The lid-closed half is the long-standing item
docs/known-issues.md used to carry.

## When the host dies (bin/forensics.sh)
A host-level outage is the one thing nothing here can diagnose from inside, and rebooting
destroys the in-memory half of the evidence. So run this **before** power-cycling, if the machine
responds at all:

    bin/forensics.sh            # read-only report to stdout (~5 s)
    bin/forensics.sh --save     # also write log/forensics-<stamp>.txt
    bin/forensics.sh --deep     # add the slow `log show` queries (~30 s)

It answers the four questions that are indistinguishable from outside - all four look like
"powered on, wifi fine, Tailscale offline" - and then prints how to read its own output: did it
sleep and when, did it hang (load average and swap), did it panic or lose power (panic reports
and the previous shutdown cause), or did it reboot to a login window where the user LaunchAgents
never start? It changes nothing.

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
