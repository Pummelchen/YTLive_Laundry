# The 8-hour rotation

## 8-hour broadcast rotation  (added 2026-09-05)
YouTube only archives live streams up to 12h, so every ROTATE_HOURS + ROTATE_MINUTES
(8h03m) the current broadcast is ended and saved as a VOD, and a successor is created and
bound via the API before ingest resumes. Pushing RTMP alone never creates one.

**Why 8h03m and not 8h.** The cut is timed so the SAVED RECORDING clears 8 hours, not the
wall clock. YouTube's encode loses time turning a live stream into a VOD - measured across
five broadcasts, wall times of 8.004-8.023h came back as VODs of 7.962-7.990h, a shortfall
of 0.6 to 2.3 minutes. Cutting at exactly 8h therefore always produced a recording just
UNDER 8h. Three extra minutes covers the worst observed loss with margin, and is still far
inside the 12h archive limit.

**Ingest alone cannot create a broadcast - the project's founding mistake, correct in
conclusion.** The original design stopped ingest, waited, and pushed again, expecting YouTube
to auto-start a new broadcast "the same thing that already happens after a power cut". It
does not. YouTube retired automatic/default broadcast creation in 2020
(developers.google.com/youtube/v3/live/guides/migration-guide-default-broadcasts), and the
early rotation logs were originally read as proving something subtler than they did. The
accurate, controlled evidence is 2026-09-05: **six minutes of clean ingest against a dark
channel produced nothing at all.**

What YouTube does and does not do with no API:
  - `enableAutoStop=true` - forced on every broadcast we create - closes and archives the
    broadcast when ingest stops, ~9s measured. That half of a rotation needs no API, so a
    dead token still saves the CURRENT segment's VOD.
  - `enableAutoStart=true` only starts a broadcast that is ALREADY BOUND. It does not create
    one, so pushing RTMP at a bare stream key does nothing.

So `mode=native` in log/rotation_history.log means only "YouTube's autoStart took the
already-bound broadcast live without needing the `ensure-live` fallback". It does NOT mean the
API was unnecessary.

With a dead or absent token the stream keeps running and the current segment is still saved,
but the NEXT rotation cannot create a successor and the channel goes dark until a human runs
`bin/yt_api.py auth` - the documented 2026-09-05 five-hour outage. To stop that being a
self-inflicted wound, `rotate_broadcast()` now checks the API first and REFUSES to cut when it
cannot create the successor, staying LIVE instead: a segment that runs past 12h and is not
archived beats a dark channel, which needs a human anyway. `ROTATE_WITHOUT_API=yes` restores
the old cut-anyway behaviour; `ROTATE_API_RETRY` (900s) is how long it waits before re-checking.

Creating a broadcast requires the YouTube Live Streaming API: see `bin/yt_api.py`.
    touch ~/Downloads/YTLive/log/rotate_now        # force a rotation right now
    grep ROTATE ~/Downloads/YTLive/log/stream.log  # see what it did
log/rotating holds an epoch deadline; the monitor stands down until then, and a stale file
expires by itself instead of muting the monitor forever.
The monitor calls `ensure-live` first when it sees the channel OFFLINE, and asks for a rotation
only as a fallback if the API cannot bring it back; a bare restart never fixes OFFLINE. If you
stop the stream by hand in Studio, nothing automatic can bring it back - go live again in
Studio.

**The warm-up window (fixed 2026-09-05).** YouTube does not bring an already-bound broadcast
live the moment ingest resumes; autoStart takes minutes. The first version cleared
log/rotating as soon as the publisher restarted, so the monitor started judging immediately,
correctly saw OFFLINE, and demanded another rotation ~70s later - which killed the new
publisher before YouTube could ever open the broadcast. That livelocked the stream for 3.5h
(93 rotations, 09:17-12:47 on 2026-09-05) after the first scheduled 8h rotation. Three things
stop it:
    hold_monitor $(( ROTATE_NATIVE_WAIT + 120 ))   the REAL hold: 480s after ANY publisher
                              start (start_publisher), and a longer one across a cut.
                              ROTATE_GRACE=420 is still declared and printed in the startup
                              log line, but no longer drives the hold.
    OFFLINE_SECONDS=300       5 min of continuous OFFLINE before the monitor even acts
    ROTATE_MIN_INTERVAL=900   stream.sh REFUSES an unscheduled rotation within 15 min of the
                              last one (scheduled 8h rotations are exempt)
Both yt_live_state() (stream.sh) and yt_check.py distinguish "offline" (YouTube said so)
from "unknown" (the lookup itself failed). Only stream.sh did at first, which mattered
because the monitor uses yt_check.py: a yt-dlp rate limit or a broken yt-dlp release read
as OFFLINE, and OFFLINE is the status that makes the monitor act. UNKNOWN never triggers an
action. If UNKNOWN persists past BLIND_SECONDS the monitor asks the YouTube API instead,
which does not involve yt-dlp at all - so a blind lookup no longer means a blind watchdog.

**Thresholds are seconds, not check counts.** They used to be counts, and counts lied: each
check spawns yt-dlp *and* ffmpeg, so a "10s" interval measured 14s median and 118s worst
case over 1342 logged checks. "30 checks = 5 min" was really ~7. Wall-clock thresholds stay
true however slow an individual check happens to be.
**The broadcast must be BOUND BEFORE INGEST STARTS (fixed 2026-09-06).** This is the part
that actually makes the rotation work, and getting it backwards cost 19 minutes of dark air
on the first live run. YouTube starts an `enableAutoStart` broadcast when ingest ARRIVES at
the stream it is bound to. Bind after ingest is already flowing and that arrival has gone
by: the broadcast sits in `ready` indefinitely, and a manual transition is refused with
`invalidTransition` precisely BECAUSE it is set to auto-start. Both ready->testing and
ready->live were rejected for 60s each against a stream YouTube itself reported active and
healthy. The broadcast sat `ready` for 17 minutes and went live 30 seconds after the
publisher was bounced.

So `prepare_broadcast()` runs inside `start_publisher()` - the one place every ingest start
goes through - and the order is always: create + bind, then push.
    PREPARE: {"status":"READY","broadcast_id":"...","msg":"bound and waiting for ingest"}
    publisher up (pid ...)          <- ingest starts AFTER the bind
    LIVE: channel is live on ...    <- autoStart fires on arrival, ~30s
A `PREPARE` line appearing BEFORE `publisher up` is the tell that this is working.

`monitorStream` is forced off on every broadcast we create, regardless of what the
reference says. With a monitor stream the broadcast has to go ready->testing->live, and
that is the transition YouTube was refusing. Nobody previews a 24/7 CCTV feed.

If nothing is live after ROTATE_NATIVE_WAIT the streamer bounces the publisher once, because
a fresh ingest arrival is the event YouTube actually reacts to - that is what recovered the
channel. Only after that does it fall back to `ensure-live`.

**The rotation clock follows the BROADCAST, not this process.** BROADCAST_STARTED used to be
set to "now" at every stream.sh start, so any restart - launchd reviving a crash, a reboot,
a config change - silently handed the running broadcast another full 8 hours. Caught in the
act: restarts had pushed a broadcast that went live at 15:03 to a 03:12 rotation, making it
12h08m old and unarchivable. log/broadcast_started holds "<id> <epoch>"; on a first sighting
it takes YouTube's own actualStartTime. When the age is uncertain it assumes the broadcast
is OLDER, never younger - rotating early costs a shorter VOD, rotating late costs the
recording outright.

## Did the recording actually save?
The whole point of cutting at 8h is a reviewable VOD, and a rotation can look perfectly
successful while producing nothing watchable. Past 12h YouTube answers "This live stream
recording is not available" - as it does for this channel's 26.1h and 81.5h streams, over
four days of footage lost permanently.

Each rotation verifies the broadcast the PREVIOUS one ended, a cut late on purpose so
YouTube has had ~8 hours to process it. The check is yt-dlp, deliberately not the API, so it
keeps working after the OAuth token expires - and "does a playable recording exist" is
exactly the question a viewer asks. Verdicts land in log/vod_status, one line per broadcast;
an "ok" is final, a MISSING is retried at every later rotation in case it was still
processing. status.sh reports the tally.

    tzlsZ_Nv6VE ok 2026-09-05 23:24:30 7h57m

## Timing settings, and why they are what they are
    ROTATE_HOURS=8 + ROTATE_MINUTES=3   cut at 8h03m so the SAVED recording clears 8h -
                                        YouTube's encode loses 0.6-2.3 min making the VOD
    CHECK_INTERVAL=20                   each monitor check spawns yt-dlp AND ffmpeg for
                                        ~2.0 CPU-seconds; at 10s that was ~15% of a core
                                        burning continuously on a box with 17% idle
    ENFORCE_EVERY=1800                  configuration drift check; one cheap read when
                                        nothing is wrong
    THUMB_DELAY=3600                    how long after a cut to adopt YouTube's suggestion
