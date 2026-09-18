# How it works

## Video processing
Camera delivers ~14fps at 1920x1080 (after crop - already full HD, no upscaling).
Output to YouTube is a CONSTANT 30fps at `ENC_BITRATE="6800k"` (the rate YouTube Studio
asks for at 1080p30).

The literal chain (stream.sh) is:

    [0:v]fps=${OUT_FPS}[base];[1:v]${CHAIN}[cam];[base][cam]overlay=eof_action=pass:repeatlast=1:shortest=0:format=yuv420[v]

Input 0 is the filler BASE (a still loop, or a colour source on the very first run); input 1
is the camera UDP. So `fps=OUT_FPS` runs FIRST, on the BASE layer, and the camera chain runs
at the camera's own ~14fps - the "applied LAST" claim this doc used to make was backwards.
The camera chain itself is:

    crop=1920:1080:0:0      top panel (the one with the timestamp)
    hqdn3d=3:2:4:4          denoise - targets H.264 blocking/mosquito, not sensor grain
    unsharp=5:5:0.7:5:5:0   gentle sharpen
    eq=saturation=1.05      +5% colour

The output is genuine CFR 30 because the base layer is 30fps and `overlay=repeatlast` holds
the last camera frame in between; the camera's own rate never becomes the output rate.

**Frame interpolation:** true motion-compensated interpolation (`minterpolate`) was
benchmarked on this machine at **0.04x realtime - about 25x too slow**. It is not usable.
`fps=30` duplicates frames instead: motion judder is unchanged from the 14fps source, but
the stream is genuine CFR 30 and duplicated frames cost almost no bitrate. `FPS_MODE` is
declared in conf/stream.env.example but read by no script - the chain is hardcoded to
`fps=OUT_FPS`, so setting `FPS_MODE="blend"` (the `framerate` filter, which blends
neighbours into synthetic frames) does nothing today. It is kept as a record of the option.

**Why eq instead of vibrance:** the `vibrance` filter only accepts RGB, forcing a
yuv420p->rgb24->yuv420p round-trip that measured ~3x slower. `eq=saturation` works
natively in YUV. Same visual goal, near-zero cost.

Measured: ~106% CPU of 400% available (4 logical cores) = comfortable headroom.

## Audio
CCTV microphone audio is **never streamed** (privacy). It is dropped in the READER (`-c:v
copy -an`), so it never even reaches the publisher; the publisher's maps are `-map "[v]"`
(the overlay output) and `-map 2:a:0` (the MP3 concat input). The camera's audio track is
simply not connected to the output.

Music comes from `MP3/` (25 tracks, all 48kHz stereo 320k, 2.39h total), in a randomized
order saved to `conf/playlist.txt`, looped forever with `-stream_loop -1`.
Encoded with ffmpeg's native AAC (`AAC_ENC="aac"`) at `AUD_BITRATE="384k"`/48kHz stereo.
Apple's `aac_at` was tried first and hard-caps at 320k inside this filter chain
("Bitrate 384000 not allowed") even though the FLV metadata still claims 384k, so native
`aac` is what gives a true 384k - the "aac_at at 320k" text this doc used to carry was stale.
`alimiter=limit=0.95` guards against clipping (the bass-boosted files already hit 0.0 dBFS).

## Watchdog
ffmpeg does NOT exit when the camera's RTSP feed dies - it keeps running and streams music
over dead video, which neither launchd KeepAlive nor the reconnect loop would notice.
(Seen live: RTSP socket CLOSED while the YouTube socket stayed ESTABLISHED.)
stream.sh runs ffmpeg with -progress and a watchdog that kills it if the video frame
counter stalls for STALL_TIMEOUT seconds (default 30), so the reconnect loop recovers.

## The external watchdog: the one thing not on the streamer
The two processes above both live on the Mac, and every retry in them assumes the Mac is
running. On 2026-09-18 it was not: the streamer dropped off the network at 10:19:54Z (a shop
power/router loss, after which the Mac ran on battery and slept), and the publisher watchdog,
the monitor, `stream.sh`'s retry loops and launchd's `KeepAlive` all behaved correctly and all
were useless. A process that is not running cannot retry, and launchd cannot revive a machine
that is off. The channel stayed dark 10 h 23 m and nothing said so, because the design rule was
"no notifications; every failure path retries" - a rule that is right for everything the
streamer can retry and inapplicable to the host itself.

`bin/yt_watchdog.py` is the deliberate exception, and it is **not** a third process in the
reader/publisher split: it is not part of the streamer at all. It runs on an always-on host off
the streamer (the Intel VPS today), watches two independent signals - the channel via `yt-dlp`
and the streamer's presence in the tailnet via `tailscale status --json` - and emails a human
when the channel goes dark. It is the only component here allowed to notify, and for the same
reason it must never be installed on the streamer: a watchdog that dies with the thing it
watches is not a watchdog.

What it does **not** do: it cannot repair anything (recovery still needs the streamer), it does
not judge the picture (that is `bin/yt_check.py` with the golden reference, on the streamer), and
a lookup it cannot complete is reported `UNKNOWN`, never as an outage. Full design, thresholds
and the 2026-09-18 evidence are in docs/watchdog.md; the implementation is bin/yt_watchdog.py.

## Concurrency and shared code
`await_broadcast` is serialised behind an atomic `mkdir` lock (log/await.lock). A rotation
spawns one and a publisher restart inside the same window spawns another; both then poll
YouTube and both enforce settings on the same video - observed 2026-09-06 07:33:21, two
SETTINGS lines in one second. A lock older than AWAIT_LOCK_TTL is taken, so a killed
subshell cannot block rotations forever.

`yt_api_ready()` and `yt_api_call()` live in bin/lib.sh. They were defined in both
stream.sh and yt_monitor.sh and had already drifted - YT_LATENCY added to each by hand, and
the two `yt_api_ready()` bodies testing different paths for the same file. conf/stream.env
is SOURCED rather than exported, so anything a subprocess needs must be passed explicitly;
doing that in two places is how the channel silently lost its hashtags for a day.
