# What it is

## Files
    bin/stream.sh            the streamer (auto-reconnect loop)
    bin/shuffle_playlist.sh  regenerate the random track order
    bin/status.sh            health check
    bin/preflight.sh         probe camera codecs
    bin/camscan.py           find cameras on the LAN (ONVIF + port sweep)
    bin/onvif_probe.py       pull RTSP URLs from an ONVIF camera
    bin/smoke_test.sh        RUN THIS BEFORE RESTARTING ANYTHING - see below
    bin/lib.sh               yt_api_ready/yt_api_call, shared by stream.sh and yt_monitor.sh
    bin/cam_ip.py            resolves the camera's address; nothing hardcodes it
    bin/find_cam.py          ONVIF WS-Discovery, used by cam_ip.py as the last resort
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

## Why not ~/Downloads
macOS TCC protects ~/Downloads, ~/Desktop and ~/Documents. A launchd background agent
has no GUI to prompt for consent, so it gets "Operation not permitted" there and the job
dies with EX_CONFIG (78). The project therefore lives in ~/Downloads/YTLive, which is unprotected.
Keeping it here needs no password and no Full Disk Access grant.
