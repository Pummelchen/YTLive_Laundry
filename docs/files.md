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
    bin/cam_time.py          read/set the camera's clock and timezone over ONVIF. It sets it and
                             the camera reports the new zone back - and the burned-in OSD still
                             renders UTC+8, because this firmware ignores the write like it
                             ignores the encoder settings. See docs/camera.md.
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
    bin/yt_heartbeat.py      the dead-man heartbeat, both halves in one file so the wire format
                             has one implementation: `serve` (on the watchdog host) accepts an
                             authenticated POST and atomically writes the file the watchdog
                             reads as WATCH_HEARTBEAT; `push` (on the streamer, started by
                             bin/stream.sh) sends a small status JSON. Stdlib-only and portable.
                             PUSH, not pull, on purpose - the watchdog host holds the mail
                             secret and must never reach into the streamer. See docs/watchdog.md.
    bin/watchdog-install.sh  install that watchdog on an always-on host (systemd or launchd)
    bin/deploy-release.sh    deploy a tag with a rollback that covers what install.sh writes
    bin/forensics.sh         read-only evidence for a HOST-level outage - sleep, hang, panic or
                             a reboot to a login window; run it BEFORE rebooting
    bin/harden-host.sh       applies and verifies the pmset host hardening (dry run by default)
    bin/net_watch.sh         the TRANSPORT-layer watchdog: probes gateway/DNS/WAN every 30s and
                             repairs a lost network after a sustained failure (dns -> renew ->
                             wifi), rate-limited. Started by stream.sh; `once` and `status` are
                             safe to run by hand. It never notifies and never power-cycles a
                             service - see its own header for why both matter.
    conf/stream.env          settings + YouTube key (chmod 600, gitignored)
    conf/yt_oauth.json       OAuth refresh token (chmod 600, gitignored)
    conf/broadcast_template.json  THE REFERENCE: title, description, tags, category,
                             language, privacy, latency - enforced onto every new broadcast.
                             TRACKED, and `capture` (which runs at every rotation) writes it
                             only when the merged content actually changed, so the deployed
                             checkout stays clean; the capture timestamp goes to
                             log/broadcast_captured.json instead
    conf/thumbnail.jpg       the golden thumbnail, re-applied at every rotation
    conf/thumbnail_source.jpg  untouched original, so the crop/angle can be redone
    conf/thumbnail_rendered.jpg  YouTube's render of thumbnail.jpg, the compare-render-to-
                             render baseline (tracked)
    conf/cam_encoder_*.xml, conf/camera_original.txt, conf/ternak-macbook.pub
                             tracked camera dumps and an SSH public key
    conf/playlist.txt        the shuffled order (generated)
    conf/watchdog.env.example  tracked template for the external watchdog; the live
                             conf/watchdog.env holds a Gmail app password (chmod 600, gitignored)
                             and the heartbeat listener's bind/port/state/token-file knobs
    conf/ytlive-watchdog.service  the systemd unit for the always-on watchdog host
    conf/ytlive-heartbeat.service the systemd unit for the heartbeat listener on that host
                             (bin/yt_heartbeat.py serve); ExecStart binds the tailnet address
                             only, and [Install] is required or systemd calls it "static"
    conf/heartbeat.token     the shared bearer secret (chmod 600, gitignored, NOT tracked) on
                             the streamer; the watchdog host keeps its own copy under
                             /var/ytlive-watchdog/conf/. Never on a command line - see AGENTS.md
    conf/ytlive-sudoers      the TEMPLATE for /etc/sudoers.d/ytlive-net: three exact NOPASSWD
                             commands for the transport watchdog's root-only rungs (ipconfig on
                             en0/en2, dscacheutil -flushcache). Rendered with the streamer's user,
                             proved by visudo -cf and installed 0440 root:wheel by
                             `sudo bin/harden-host.sh --go`, which also verifies it in --check.
                             No wildcards, no shell, no ALL - keep it that way (T-38)
    log/host_hardening.json  runtime state (gitignored): the recorded answer to "does this
                             hardware support autorestart?". Written by harden-host.sh --go after
                             it applies the setting and reads it back, consumed by --check so an
                             unsupported key reports N/A instead of failing forever (T-29)
    docs/                    the design/ops notes (architecture.md, operations.md, watchdog.md,
                             ...) plus the per-release notes release-notes-vX.Y.md
    docs/v3-datacenter-plan.md          the v3.0 analysis, CLOSED 2026-09-20: no VPS on the
                             streaming side; kept so the question is not re-derived
    docs/task-table-standard.md         the ONE task-table standard: columns, types, statuses,
                             sizes, ownership, and the ordering that is the priority
    tests/                   the credential-free suite: tests/run.sh and its README
    .github/workflows/ci.yml the ONLY automated gate: runs tests/run.sh on macOS runners for
                             every push to main and every pull request. Not a Linux job - the
                             suite is macOS-only - and bin/smoke_test.sh is deliberately absent
                             from it because it needs a gitignored credential.
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
                             net_events.log (append-only network transitions and the recovery
                             actions taken - the durable record of a transport outage, because
                             stream.log's in-place trim keeps only its tail), net_state (the
                             last classification, read by status.sh), net_hold (optional epoch
                             deadline that suspends the network watchdog's actions),
                             broadcast_captured.json (when and from which broadcast the tracked
                             reference was last captured - bookkeeping kept out of the tracked
                             file on purpose, see below),
                             publisher.pid / monitor.pid (so each side can signal exactly the
                             other process instead of pattern-matching a command line),
                             vod_pending (recordings still awaiting a verdict, as "<id> <probes>";
                             deliberately NOT derived from rotation_history.log, which is trimmed
                             to the last 100 rotations - an id whose verdict never settled used to
                             fall out of the retried set that way),
                             forensics-<stamp>.txt (a saved forensics report)
    ~/Library/Logs/YTLive/   launchd stdout/stderr (outside Downloads on purpose)

## Why not ~/Downloads
macOS TCC protects ~/Downloads, ~/Desktop and ~/Documents. A launchd background agent has no
GUI to prompt for consent, so it gets "Operation not permitted" and the job dies with
EX_CONFIG (78). This project therefore needs **Full Disk Access for `/bin/zsh`**: install.sh
probes for it by running a temporary launchd job that reads `bin/stream.sh` and
`conf/stream.env` exactly as launchd will, and refuses `./install.sh --start` until the probe
passes. The old text here claimed the path was unprotected and needed no grant - that was
wrong. install.sh can install from any directory (it warns when not at
`~/Downloads/YTLive`), and every script now derives `BASE` from its own location rather than
assuming that path, so a copy of the tree elsewhere works for interactive use. The supported
install path is still `~/Downloads/YTLive`, because that is what the launchd agents and the
Full Disk Access grant are written against.
