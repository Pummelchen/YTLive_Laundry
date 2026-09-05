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
    conf/stream.env          settings + YouTube key (chmod 600)
    conf/playlist.txt        the shuffled order (generated)
    log/                     stream.log, progress.txt
    ~/Library/Logs/YTLive/   launchd.out.log, launchd.err.log (outside Downloads on purpose)

## Control
    launchctl load -w   ~/Library/LaunchAgents/com.user.cctv-stream.plist   # start
    launchctl unload    ~/Library/LaunchAgents/com.user.cctv-stream.plist   # stop
    ~/Downloads/YTLive/bin/status.sh
    tail -f ~/Downloads/YTLive/log/stream.log

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
YouTube only archives live streams up to 12h. Every ROTATE_HOURS (8) stream.sh stops
ingest, waits until YouTube reports the channel not live (max ROTATE_MAX_WAIT), waits
ROTATE_GAP more seconds, then starts pushing again so YouTube auto-starts a NEW broadcast
with a new URL - the same thing that already happens after a power cut. The old one is
saved as a VOD. A quick 6s restart does NOT do this; the gap is the whole point.
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
    OFFLINE_STREAK=30         5 min of continuous OFFLINE before the monitor even asks
    ROTATE_MIN_INTERVAL=900   stream.sh REFUSES an unscheduled rotation within 15 min of the
                              last one (scheduled 8h rotations are exempt)
yt_live_state() also now distinguishes "offline" (YouTube said so) from "unknown" (the
yt-dlp lookup itself failed). The old yt_live_id() could not, which is why every rotation
logged "not live after 0s" - it was never really confirming anything.
If ROTATE_GRACE passes with no live broadcast, the log says so and nothing further is tried
for ROTATE_MIN_INTERVAL: at that point YouTube is refusing to auto-create a broadcast and
only Go Live in Studio will fix it.

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
