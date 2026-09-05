# CCTV -> YouTube 24/7 livestream  (~/Downloads/YTLive)

## Why not ~/Downloads
macOS TCC protects ~/Downloads, ~/Desktop and ~/Documents. A launchd background agent
has no GUI to prompt for consent, so it gets "Operation not permitted" there and the job
dies with EX_CONFIG (78). The project therefore lives in ~/Downloads/YTLive, which is unprotected.
Keeping it here needs no password and no Full Disk Access grant.

## Camera
192.168.1.2 - ONVIF (macro-video-soft / XiongMai OEM, fw 2.4), ONVIF svc on :8899, no auth.
- `rtsp://192.168.1.2/live/ch00_0`  1920x3240  <- used
- `rtsp://192.168.1.2/live/ch00_1`, `ch00_2`   640x1080 (same layout, lower res)

**ch00_0 is a COMPOSITE of three 1920x1080 views stacked vertically.**
Only the TOP panel carries the date/time OSD overlay.
    top    1920:1080:0:0      <- streamed (has timestamp)
    middle 1920:1080:0:1080
    bottom 1920:1080:0:2160

## Audio
CCTV microphone audio is **never streamed** (privacy) - ffmpeg maps `0:v:0` and `1:a:0`
only, so the camera's audio track is simply not connected to the output.

Music comes from `MP3/` (25 tracks, all 48kHz stereo 320k, 2.39h total), in a randomized
order saved to `conf/playlist.txt`, looped forever with `-stream_loop -1`.
Encoded with Apple's AudioToolbox AAC (`aac_at`) at 320k/48kHz stereo - `aac_at` refuses
384k and silently drops to 320k, so 320k IS its stereo ceiling and best quality.
`alimiter=limit=0.95` guards against clipping (the bass-boosted files already hit 0.0 dBFS).

## Video processing
Camera delivers ~14fps at 1920x1080 (after crop - already full HD, no upscaling).
Output to YouTube is a CONSTANT 30fps, 4500k.

    crop=1920:1080:0:0      top panel (the one with the timestamp)
    hqdn3d=3:2:4:4          denoise - targets H.264 blocking/mosquito, not sensor grain
    unsharp=5:5:0.7:5:5:0   gentle sharpen
    eq=saturation=1.05      +5% colour
    fps=30                  constant 30fps (applied LAST: filtering at 14fps is ~2x cheaper)

**Frame interpolation:** true motion-compensated interpolation (`minterpolate`) was
benchmarked on this machine at **0.04x realtime - about 25x too slow**. It is not usable.
`fps=30` duplicates frames instead: motion judder is unchanged from the 14fps source, but
the stream is genuine CFR 30 and duplicated frames cost almost no bitrate. Set
FPS_MODE="blend" for the `framerate` filter, which blends neighbours into synthetic
frames - marginally smoother motion, but it ghosts moving people and wastes bitrate.

**Why eq instead of vibrance:** the `vibrance` filter only accepts RGB, forcing a
yuv420p->rgb24->yuv420p round-trip that measured ~3x slower. `eq=saturation` works
natively in YUV. Same visual goal, near-zero cost.

Measured: ~106% CPU of 400% available (4 logical cores) = comfortable headroom.

## Files
    bin/stream.sh            the streamer (auto-reconnect loop)
    bin/shuffle_playlist.sh  regenerate the random track order
    bin/status.sh            health check
    bin/preflight.sh         probe camera codecs
    bin/camscan.py           find cameras on the LAN (ONVIF + port sweep)
    bin/onvif_probe.py       pull RTSP URLs from an ONVIF camera
    bin/yt_api.py            YouTube Live API: create/bind/end, and the config reference
    bin/yt_check.py          pulls a frame from the public stream and grades it
    bin/yt_monitor.sh        the watchdog loop
    conf/stream.env          settings + YouTube key (chmod 600, gitignored)
    conf/yt_oauth.json       OAuth refresh token (chmod 600, gitignored)
    conf/broadcast_template.json  THE REFERENCE: title, description, tags, category,
                             language, privacy, latency - enforced onto every new broadcast
    conf/thumbnail.jpg       the golden thumbnail, re-applied at every rotation
    conf/thumbnail_source.jpg  untouched original, so the crop/angle can be redone
    conf/playlist.txt        the shuffled order (generated)
    log/                     runtime state, gitignored. Files the project reads back:
                             broadcast_started (rotation clock), monitor.heartbeat,
                             rotation_history.log, vod_status, progress.txt
    ~/Library/Logs/YTLive/   launchd stdout/stderr (outside Downloads on purpose)

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

The logs are the project's own bookkeeping, not a report to be read - nothing here depends
on a human noticing anything, and there are deliberately no notifications. Every failure
path retries instead of reporting. status.sh is the one place that answers "is it healthy".

Reshuffle the music (takes effect on next restart):
    ~/Downloads/YTLive/bin/shuffle_playlist.sh
Or set RESHUFFLE_ON_START="yes" in conf/stream.env for a fresh order on every restart.

## Modes (conf/stream.env)
    MODE="crop"    crop one panel + HW encode. Current. ~50% of one core.
    MODE="copy"    passthrough the whole 3-up stack, lowest CPU (no crop possible).
    MODE="encode"  letterbox the whole tall stack into 16:9.

## Known cosmetic issues
- status.sh prints a stray artifact after "YT_KEY: set (NN chars)". Harmless; never
  prints the key itself.
- ffmpeg logs "Timestamps are unset in a packet" once at startup and "Resumed reading
  at pts ... after a lag" when the music input primes. Both are normal.

## Todo / notes
- Camera sends only ~1 Mbps for the whole 3-up composite, so one panel is low detail.
  Raise the bitrate in the camera web UI at http://192.168.1.2 - costs this Mac nothing.
- Lid-closed operation still wants:  sudo pmset -c sleep 0 disablesleep 1
- If the camera IP changes (e.g. moving to USB-C ethernet), rerun bin/camscan.py and
  update CAM_URL in conf/stream.env.


## Watchdog
ffmpeg does NOT exit when the camera's RTSP feed dies - it keeps running and streams music
over dead video, which neither launchd KeepAlive nor the reconnect loop would notice.
(Seen live: RTSP socket CLOSED while the YouTube socket stayed ESTABLISHED.)
stream.sh runs ffmpeg with -progress and a watchdog that kills it if the video frame
counter stalls for STALL_TIMEOUT seconds (default 30), so the reconnect loop recovers.

## Tailscale
Installer downloaded to ~/Downloads/Tailscale-1.102.3-macos.pkg (signed by Tailscale Inc.,
notarized, declares min macOS 11.0 so Monterey is fine). Install + sign-in are yours to do.
Do NOT tick "Use as exit node" and do not select an exit node.


## 8-hour broadcast rotation  (added 2026-09-05)
YouTube only archives live streams up to 12h, so every ROTATE_HOURS (8) the current
broadcast is ended and a new one started. The old one is saved as a VOD.

**Ingest alone cannot create a broadcast on this channel - this was the project's founding
mistake.** The original design stopped ingest, waited, and pushed again, expecting YouTube
to auto-start a new broadcast "the same thing that already happens after a power cut".
It does not, and it never did here. Rotations at 01:04, 01:10, 01:13 and 01:16 on
2026-09-05 each logged "no live broadcast seen"; the broadcast that appeared at 01:18 was
started by hand in Studio. When the first scheduled 8h rotation ran at 09:17 the channel
went dark and stayed dark - 93 further rotations changed nothing, because no number of
RTMP reconnects can make YouTube create a broadcast.

Creating a broadcast requires the YouTube Live Streaming API: see `bin/yt_api.py`.
    touch ~/Downloads/YTLive/log/rotate_now        # force a rotation right now
    grep ROTATE ~/Downloads/YTLive/log/stream.log  # see what it did
log/rotating holds an epoch deadline; the monitor stands down until then, and a stale file
expires by itself instead of muting the monitor forever.
The monitor requests a rotation (not a bare kill) when it sees the channel OFFLINE, because
a restart never fixes OFFLINE. If you stop the stream by hand in Studio, nothing automatic
can bring it back - go live again in Studio.

**The warm-up window (fixed 2026-09-05).** YouTube does not bring an auto-created broadcast
live the moment ingest resumes; it takes minutes. The first version cleared log/rotating as
soon as the publisher restarted, so the monitor started judging immediately, correctly saw
OFFLINE, and demanded another rotation ~70s later - which killed the new publisher before
YouTube could ever open the broadcast. That livelocked the stream for 3.5h (93 rotations,
09:17-12:47 on 2026-09-05) after the first scheduled 8h rotation. Three things stop it:
    ROTATE_GRACE=420          monitor stands down for 7 min after ANY publisher start
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

## The YouTube API  (bin/yt_api.py)
The only thing that can create a broadcast. Stdlib only, no pip installs.

    bin/yt_api.py auth          one-time: OAuth device flow -> conf/yt_oauth.json
    bin/yt_api.py status        what is live right now, as JSON
    bin/yt_api.py prepare       create + bind a broadcast, ready for ingest to start it
    bin/yt_api.py ensure-live   idempotent: if nothing is live, create + bind + go live
    bin/yt_api.py end           end the active broadcast so YouTube saves the VOD
    bin/yt_api.py token         refresh-token expiry, offline (0 ok, 1 soon, 2 expired)
    bin/yt_api.py capture [id]  snapshot the configuration into the reference
    bin/yt_api.py verify [id]   compare a broadcast against the reference (0 match, 1 drift)
    bin/yt_api.py enforce [id]  apply the reference and retry until it matches
    bin/yt_api.py thumbnail [f] adopt a file as the golden thumbnail, or re-apply it
    bin/yt_api.py thumbnail --check   is the live thumbnail actually ours?

One-time setup: console.cloud.google.com/apis/credentials -> enable "YouTube Data API v3"
-> Create OAuth client ID -> type **TVs and Limited Input devices** -> run `bin/yt_api.py
auth` and paste the id and secret. It prints a short code to enter at google.com/device.
No browser is needed on the streaming Mac, so this works fine over SSH.

**The OAuth app stays in "Testing", so the token expires every 7 days.** Branding review is
not being pursued, so this is permanent: Google kills the refresh token after 7 days and
`bin/yt_api.py auth` has to be re-run. That is normal maintenance for this project, not an
edge case, and it is the one failure nothing else here can recover from - with a dead token
the stream keeps running but cannot rotate, and a channel that goes dark stays dark.

Three things make sure it never surprises you:

    bin/yt_api.py token       offline check: 0 = fine, 1 = expiring, 2 = expired
    bin/status.sh             shows days remaining every time you look
    yt_monitor.sh             re-checks every TOKEN_CHECK_EVERY (6h) and logs a loud
                              warning from 2 days out; stream.sh logs it at every rotation

The countdown existed before but was written into a variable the rotation preflight threw
away, so it reached no log at all. Now it reaches three.

**Verified end to end on 2026-09-05 15:01-15:03** - a forced rotation ran the whole path:

    15:01:54  ROTATE (manual): stopping ingest, closing dcw5E1qrp8I
    15:01:56  ending broadcast via API: {"status":"ENDED","broadcast_id":"dcw5E1qrp8I"}
    15:02:15  YouTube state=offline after 15s
    15:03:22  publisher back up
    15:03:46  LIVE: broadcast is up via API: tzlsZ_Nv6VE

110s of downtime, old broadcast saved as a 41:42 VOD, new one live with a new URL. Note
"offline after 15s" - a real confirmation from YouTube, where the pre-API code always
printed "0s" because it could not tell "offline" from "the lookup failed".

Everything switches on automatically once `conf/yt_oauth.json` exists:
- **stream.sh** calls `ensure-live` after every publisher start (cold start, watchdog
  restart, rotation), and `end` when rotating, so the VOD is saved properly.
- **yt_monitor.sh** calls `ensure-live` when it sees the channel OFFLINE, instead of asking
  for a rotation that cannot help.
- **ensure-live reuses a broadcast it already created** rather than minting a new one on
  every retry, and deletes the abandoned ones. Without that, a spell of "channel dark and
  ingest broken" left a fresh orphaned broadcast on the channel every retry, at 100 quota
  units each. It only ever touches broadcasts bound to our own stream key - a broadcast
  scheduled by hand in Studio is left alone.
Without the file both fall back to the old yt-dlp polling and say plainly that only Studio
can bring the channel live.

`enableAutoStart: true` on the created broadcast is the setting the stream-key approach was
always missing - with it YouTube puts the broadcast live by itself as soon as ingest lands.
`enableAutoStop` is left OFF so a brief ingest blip cannot end the broadcast.

Set YT_TITLE_FMT in conf/stream.env or every rotation loses the channel's hashtags -
conf/stream.env is *sourced*, not exported, so stream.sh passes it through explicitly via
yt_api_call(). YT_PRIVACY defaults to public.

conf/yt_oauth.json is gitignored even though the repo is private: a refresh token grants
ongoing control of the channel and would outlive any later decision to share the repo.
conf/stream.env is gitignored for the same reason - it holds the stream key.

## Installing on another Mac  (install.sh)
    # on the SOURCE machine (this one):
    rsync -avz -e ssh --exclude 'log/*' --exclude '*.bak-*' ~/Downloads/YTLive/ USER@HOST:Downloads/YTLive/
    # on the TARGET machine:
    cd ~/Downloads/YTLive && ./install.sh          # installs, does not start
    # grant Full Disk Access to /bin/zsh, then:
    ./install.sh --start
install.sh installs ffmpeg/ffprobe + yt-dlp into ~/.local/bin, writes the LaunchAgents
with that user's home, rebuilds the playlist, and probes Full Disk Access. It refuses to
start until FDA is granted. Only ONE machine may push to a given YouTube key at a time.
A bundle of the folder (minus logs) is also produced as ~/Downloads/YTLive-bundle-DATE.tar.gz.

## SSH keys between the Macs
Ternak MacBook has ~/.ssh/id_ed25519 (no passphrase, for unattended rsync); its public
key is also in conf/ternak-macbook.pub. First-time install of that key on another Mac
needs that Mac's password once:   ssh-copy-id USER@macbook-maria   (or macbook-ab)

## Machines / SSH mesh  (2026-09-05)
Full key mesh verified, all 6 directions:
    user@ternak-macbook      100.75.83.5     Intel, macOS 12   (the streamer)
    maria@macbook-maria      100.80.66.66    arm64, macOS 26   (copy of YTLive in ~/Downloads/YTLive, NOT installed/started)
    andreborchert@macbook-ab 100.101.16.45   ("MacBook AB")
Re-verify or add a machine:  bin/ssh_mesh.sh maria@macbook-maria andreborchert@macbook-ab
Sync the folder again:       rsync -az --stats -e ssh --exclude 'log/*' --exclude '*.bak-*' --exclude conf/playlist.txt ~/Downloads/YTLive/ maria@macbook-maria:Downloads/YTLive/
(macOS ships rsync 2.6.9: use --stats, not --info.)

## Monitor golden reference
The monitor refreshes conf/golden.jpg from log/basefill.jpg whenever that is newer (i.e.
after every publisher start / rotation), so the reference never goes stale. CORR_MIN is
0.35: a 5-day-old golden measured only 0.52-0.64 against a perfectly healthy stream,
while black is ~0.01 and garbage ~-0.2.

## Disk and logs  (added 2026-09-05)
Nothing bounded the logs before, and `log/` was tracked in git - so every commit stored
another copy of a multi-megabyte `publisher.log`, and `.git` reached 352 MB.

    LOG_MAX_BYTES=2097152     2 MB cap per log file
    HOUSEKEEP_EVERY=300       stream.sh trims every 5 min, and once at startup

Trimming rewrites the SAME inode (keeping the last 1 MB) rather than renaming the file.
That matters: ffmpeg holds an `O_APPEND` fd on `publisher.log`, so a rename would leave it
writing to an unlinked inode forever, invisibly. Verified with a live append-mode writer -
it kept appending correctly across a trim, with no offset corruption.

`log/progress.txt` is deliberately NOT trimmed: ffmpeg writes it at a fixed offset, so
rewriting it underneath would corrupt the frame counter the publisher watchdog reads. It is
truncated at every publisher start instead, which bounds it to one rotation's worth (~12 MB).

Runtime state is gitignored, not tracked: `log/` and `conf/golden.jpg` (re-grabbed at every
publisher start). `MP3/` stays tracked - it is write-once, so it does not grow the repo.
The 352 MB already in history is untouched; shrinking that needs a history rewrite and a
force-push, which is a separate, deliberate decision.

## Broadcast configuration  (added 2026-09-06)
Every rotation makes a NEW video, and a new video inherits almost nothing. Description,
category and language happen to come across because they are channel default-upload
settings. **Tags do not** - and here that is 38 local search terms doing the discovery
work, which were being silently dropped three times a day and expected to be retyped in
Studio by hand.

`conf/broadcast_template.json` is the reference: title, description, tags, categoryId,
language, privacy, license, embeddable, DVR, latency, and the thumbnail. At every rotation
stream.sh captures from the OUTGOING broadcast and enforces the reference onto the new one,
so anything edited in Studio propagates forward by itself.

    bin/yt_api.py capture     # adopt what is live now as the reference
    bin/yt_api.py verify      # 0 = matches, 1 = drifted (names what differs)
    bin/yt_api.py enforce     # fix it, retrying until it matches

stream.sh re-checks every ENFORCE_EVERY (30 min) and repairs drift. Cheap when nothing is
wrong: one videos.list, and an update only when something actually moved.

Five things this needed in order to work rather than merely appear to:

**capture MERGES, it does not replace.** A field the source lacks keeps whatever the
reference already had. Without that, the first capture from a freshly created broadcast -
which has no tags yet - records "no tags" and destroys them permanently.

**enforce judges by the WRITE RESPONSE, not by re-reading.** videos.list is eventually
consistent and serves stale data for a surprisingly long time; a read-back loop reported
"tags(1 vs 38)" three times over for a write that had already succeeded, and fired three
redundant updates chasing it.

**The reference owns the title, not conf/stream.env.** YT_TITLE_FMT was overwriting a
"#indonesia" added in Studio at every enforcement. Requiring stream.env to be edited in
lockstep just relocates the manual work. capture refuses to adopt a dated fallback title,
which is what made an explicit override seem necessary in the first place.

**localizations are not compared.** With defaultLanguage set, YouTube mirrors the main
snippet into that localization itself and lags doing it, so comparing them reported drift
permanently and would have fired a pointless update every 30 minutes forever.

**The drift log names the tags it adds and removes.** It used to print counts, so a tag
added in Studio was removed by enforcement with no record of which one - and that is not
recoverable from YouTube afterwards.

### Editing settings in Studio
The drift check will treat a Studio edit as drift and revert it if the reference still
holds the old value. Before editing, move the reference aside:

    mv conf/broadcast_template.json conf/broadcast_template.json.held   # enforcement OFF
    # ... edit in Studio, wait for it to appear (the API lags, sometimes by many minutes)
    cp conf/broadcast_template.json.held conf/broadcast_template.json
    bin/yt_api.py capture                                              # adopt the change

Both `apply_settings` and `enforce_drift` guard on that file existing, so moving it
disables enforcement instantly with no restart and no write to YouTube.

## Thumbnail
`conf/thumbnail.jpg` is re-applied and verified at every rotation. It is checked against
**YouTube's render of it**, not against the source file: a 4:3 source comes back as a 16:9
render with the sides filled, which correlates at ~0.5 against the original no matter how
correct it is. conf/thumbnail_rendered.jpg is that baseline; comparing render to render is
like for like and scores 1.0.

    bin/yt_api.py thumbnail path/to/image.jpg   # adopt and apply
    bin/yt_api.py thumbnail --check             # is the live one ours?

The current still is the shop entrance rotated 3 degrees left and cropped to fill 16:9.
Rotate first, crop second: a 3 degree rotation leaves empty wedges at the edges, so the crop
has to clear those as well as the 4:3 letterbox. For a 1280x960 source the safe inner box is
1180x826 and the 16:9 crop taken from it is 1180x664, scaled to 1280x720. ffmpeg's rotate
filter takes a positive angle as CLOCKWISE, so "3 degrees left" is `rotate=-3*PI/180`.

Cropping to fill is only safe when the source has nothing in the corners. The previous
branded still had text in two corners and had to be pillarboxed instead.

There is no local file-size check. YouTube documents a 2 MB limit but does not enforce it -
a 2.29 MB PNG uploaded fine. Refusing a file the service would accept is not validation.

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

## Dual stream
Soft issue, not chased. No field for it exists anywhere in youtube/v3 - checked against the
discovery document and every part of the liveBroadcasts and liveStreams resources - so it
can be neither set nor read here. It is also only toggleable while a stream is in its
starting phase, not once running, which on an 8h rotation is a few unattended minutes per
cycle. Recorded under "manual" in the reference and reported by status.sh as a single quiet
line. Treat it as off.
