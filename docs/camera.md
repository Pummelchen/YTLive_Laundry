# The camera

## Camera
192.168.1.3 - ONVIF (macro-video-soft / XiongMai OEM, fw 2.4), ONVIF svc on :8899, no auth.
- `rtsp://192.168.1.3/live/ch00_0`  1920x3240  <- used
- `rtsp://192.168.1.3/live/ch00_1`, `ch00_2`   640x1080 (same layout, lower res)

**ch00_0 is a COMPOSITE of three 1920x1080 views stacked vertically.**
Only the TOP panel carries the date/time OSD overlay.
    top    1920:1080:0:0      <- streamed (has timestamp)
    middle 1920:1080:0:1080
    bottom 1920:1080:0:2160

## What the camera actually does  (measured 2026-09-07)
It accepts ONVIF encoder writes, reports them back, and then ignores them. Do not trust
`cam_config.py get` as a description of the stream - it is a description of what the camera
has been *told*.

    configured                      actually delivered
    bitrate 8192 -> 20480 kbps      2.3 Mbit/s, unchanged by the setting
    fps 30                          14 fps  (r_frame_rate=100/7, avg_frame_rate=14/1)

Raising the bitrate to 12288, 16384 and 20480 all returned OK and read back correctly, and
changed the delivered bitrate by nothing - verified on a freshly established RTSP session,
not just the running one. `SRC_FPS="14"` in conf/stream.env was already right.

Two things follow. The denoise and sharpen filters are compensating for a genuinely
starved source (~0.026 bits/pixel at 14fps) and are not gratuitous. And OUT_FPS=30 from a
14fps source means half the encoded frames are duplicates.

To probe the camera directly, stop the reader first - it holds the only RTSP session and
this camera is unreliable with two:

    pkill -f 'ffmpeg.*rtsp://'      # reader_loop reconnects on its own in ~2s
    ffprobe -rtsp_transport tcp -i "rtsp://$(bin/cam_ip.py)/live/ch00_0"

## Finding the camera  (bin/cam_ip.py)
The camera is on DHCP and moves after a power cut - it went .2 -> .3 on 2026-08-31 and this
Mac's own LAN port then took the vacated .2. Anything holding a hardcoded address eventually
talks to the wrong device: cam_config.py still pointed at 192.168.1.2 a week later, so a
`set` would have written encoder config to this Mac.

`bin/cam_ip.py` resolves it, cheapest first, and every candidate must actually answer:

    1. CAM_HOST               explicit override, environment variable only - there is no
                              --host flag (cam_ip.py parses only -v/--verbose and --onvif)
    2. log/cam_ip             runtime truth, maintained by stream.sh's cam_ip_watcher
    3. CAM_URL in conf/stream.env
    4. ONVIF WS-Discovery     slow, definitive

The winner is written back to log/cam_ip, so a stale entry self-heals rather than persisting.
cam_config.py and cam_reboot.py both use it; neither holds an address any more.

## Monitor golden reference
The monitor refreshes conf/golden.jpg from log/basefill.jpg whenever that is newer (i.e.
after every publisher start / rotation), so the reference never goes stale. `CORR_MIN` ships
at **0.15** in conf/stream.env.example; `bin/yt_check.py`'s own default is 0.60, but the
monitor passes the configured value explicitly. It was lowered from 0.35 on 2026-09-08 after
that threshold caused the first picture-triggered restart in the project's history on a
completely healthy stream: correlation runs ~0.98 just after golden is refreshed and decays
to 0.32-0.42 within 25 minutes as people move things around the shop, so 0.35 had no margin
and the restart itself refreshed golden, cycling all night. Black scores ~0.01 and garbage
~-0.2, so 0.15 still catches every failure the check exists for.
