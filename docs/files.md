# What it is

## Files
    install.sh               provision the STREAMER: ffmpeg, yt-dlp, two LaunchAgents
    release.sh               build and publish a source release from a tag (RELEASE.md)
    bin/stream.sh            the streamer (reader + publisher, watchdog, rotation, VOD check)
    bin/shuffle_playlist.sh  regenerate the random track order
    bin/status.sh            health check
    bin/preflight.sh         probe camera codecs
    bin/camscan.py           find cameras on the LAN (ONVIF + port sweep)
    bin/cam_ip.py            resolves the camera's address; nothing hardcodes it
    bin/cam_config.py        read/set the ONVIF encoder config (what the camera is TOLD)
    bin/cam_reboot.py        reboot the camera via ONVIF SystemReboot
    bin/onvif_probe.py       pull RTSP URLs from an ONVIF camera
    bin/find_cam.py          ONVIF WS-Discovery, used by cam_ip.py as the last resort
    bin/ssh_mesh.sh          build and verify a full SSH key mesh between the Macs
    bin/smoke_test.sh        RUN THIS BEFORE RESTARTING ANYTHING - see below
    bin/lib.sh               yt_api_ready/yt_api_call, shared by stream.sh and yt_monitor.sh
    bin/yt_api.py            YouTube Live API: create/bind/end, and the config reference
    bin/yt_check.py          pulls a frame from the public stream and grades it
    bin/yt_monitor.sh        the watchdog loop
    bin/yt_watchdog.py       the EXTERNAL watchdog: runs OFF the streamer and emails a human
                             when the channel goes dark (the only code allowed to notify)
    bin/watchdog-install.sh  install that watchdog on an always-on host (systemd or launchd)
    bin/deploy-release.sh    deploy a tag with a rollback that covers what install.sh writes
    conf/stream.env          settings + YouTube key (chmod 600, gitignored)
    conf/yt_oauth.json       OAuth refresh token (chmod 600, gitignored)
    conf/broadcast_template.json  THE REFERENCE: title, description, tags, category,
                             language, privacy, latency - enforced onto every new broadcast
    conf/thumbnail.jpg       the golden thumbnail, re-applied at every rotation
    conf/thumbnail_source.jpg  untouched original, so the crop/angle can be redone
    conf/thumbnail_rendered.jpg  YouTube's render of thumbnail.jpg, the compare-render-to-
                             render baseline (tracked)
    conf/cam_encoder_*.xml, conf/camera_original.txt, conf/ternak-macbook.pub
                             tracked camera dumps and an SSH public key
    conf/playlist.txt        the shuffled order (generated)
    conf/watchdog.env.example  tracked template for the external watchdog; the live
                             conf/watchdog.env holds a Gmail app password (chmod 600, gitignored)
    conf/ytlive-watchdog.service  the systemd unit for the always-on watchdog host
    docs/                    the design/ops notes (architecture.md, operations.md, watchdog.md,
                             ...) plus the per-release notes release-notes-vX.Y.md
    tests/                   the credential-free suite: tests/run.sh and its README
    backup/                  frozen snapshots of what was deployed (backup/README.md)
    log/                     runtime state, gitignored. Files the project reads back:
                             broadcast_started (rotation clock), rotating (monitor stand-down
                             deadline), rotate_now (forced-rotation trigger), cam_ip (current
                             camera address), monitor.heartbeat, rotation_history.log,
                             vod_status, thumb_pending, progress.txt (frame counter),
                             basefill.jpg / lastframe.jpg (filler stills), await.lock,
                             yt_url.cache / yt_videoid.cache / golden_gray.cache,
                             yt_lastpull.jpg / yt_prevpull.jpg, and the logs
                             stream.log / monitor.log / publisher.log / reader.log
    ~/Library/Logs/YTLive/   launchd stdout/stderr (outside Downloads on purpose)

## Why not ~/Downloads
macOS TCC protects ~/Downloads, ~/Desktop and ~/Documents. A launchd background agent has no
GUI to prompt for consent, so it gets "Operation not permitted" and the job dies with
EX_CONFIG (78). This project therefore needs **Full Disk Access for `/bin/zsh`**: install.sh
probes for it by running a temporary launchd job that reads `bin/stream.sh` and
`conf/stream.env` exactly as launchd will, and refuses `./install.sh --start` until the probe
passes. The old text here claimed the path was unprotected and needed no grant - that was
wrong. install.sh can install from any directory (it warns when not at
`~/Downloads/YTLive`), but `bin/preflight.sh` hardcodes `$HOME/Downloads/YTLive/...` with no
override, so the supported path is `~/Downloads/YTLive`.
