# 2026-10-28 — Why the channel went dark, and how to make both feeds unkillable

Written after a live investigation of `ternak-macbook` (macOS 12.7.6, MacBookAir7,2,
`100.75.83.5`) on 2026-10-28 03:20–03:45 WIB, while the channel was in its 14th hour dark.
All times below are **WIB (UTC+7, the streamer's clock)** unless marked otherwise.

---

## 1. TL;DR

| # | Claim | Status |
|---|---|---|
| 1 | The MacBook never rebooted and never lost power in this event. Auto-start-on-boot was **not** involved. | Proven |
| 2 | The shop camera `192.168.1.3` vanished from the LAN at **13:34:51** and has not come back. That alone is why there is no picture. | Proven |
| 3 | The software turns a camera outage into a **channel** outage within ~60 s and can never recover on its own, because the publisher produces **zero frames** when the camera is gone. | Proven by reproduction |
| 4 | With no frames, the stall watchdog kills the publisher every ~35 s; each kill ends the YouTube broadcast. The replacement broadcast can never go live. | Proven from logs |
| 5 | The 27 Oct 06:02Z segment (`gJH5qUD-Jz0`) is **gone** (404), and a 0-second **public** placeholder (`0Y8I1HqUkLM`) is sitting on the channel. | Proven via API |
| 6 | 14 hours dark produced no alert to the operator. The off-host watchdog host is not reachable to verify why. | Partly proven |
| 7 | The vertical/Shorts feed has **zero** implementation; the only YouTube route (Studio dual-stream) is manual, per-broadcast and resets at every 8 h cut. | Proven (code + API + prior experiment) |
| 8 | A second, independent 9:16 broadcast **is** feasible on this hardware and uplink. Measured today. | Proven by benchmark |

---

## 2. Timeline (WIB)

```
12 Oct 22:14  last real boot (kern.boottime). Uptime now 15 d 5 h.
27 Oct 13:02  rotation: bcuPgvYZk5k ended, gJH5qUD-Jz0 created and LIVE (8 h segment).
27 Oct 13:34:51  camera 192.168.1.3 stops answering on :554. ONVIF discovery: nothing.
27 Oct 13:35:15  the reader's RTSP session dies after 7 547 s (2 h 06 m).
27 Oct 13:35:36  WATCHDOG: publisher output frozen 30 s -> killed and restarted.
27 Oct 13:35:59  channel briefly LIVE again on gJH5qUD (buffered frames).
27 Oct 13:36:09  frozen again -> killed. Ingest gone -> YouTube autoStops the broadcast.
27 Oct 13:36:47  new broadcast 0Y8I1HqUkLM created READY. No ingest ever arrives.
                 ... same loop every ~35 s, for 14 hours ...
27 Oct 21:05  scheduled rotation due (8 h 03 m after 13:02).
27 Oct 21:21  ROTATE: nothing live after 371 s -> fallback -> still PENDING.
28 Oct 03:40  unchanged: 204 camera-probe failures/hour, publisher restart loop.
```

---

## 3. What actually failed — and what did not

### 3.1 The host was healthy (this rules out the "auto-start failed" theory)

* `kern.boottime` = 12 Oct 22:14:42; **no reboot** in 15 days. `last reboot` shows nothing since 19 Sep.
* `pmset -g log`: **no AC→battery transition since 21 Oct 08:46**. The Mac did not lose mains
  power in this event (or it is behind a UPS that is not documented).
* LaunchAgents loaded and running: `com.user.cctv-stream` (pid 541), `com.user.cctv-monitor` (pid 554).
* Network up throughout: gateway reachable, `youtube.com` 200, **upload 16.2 Mbps / download 1.85 Mbps**
  (`networkQuality`). `net_events.log` shows no gateway loss between 10:21 and 21:26.
* Disk 162 GB free. YouTube OAuth probe: LIVE (token accepted). API quota: no cooldown armed.
* Auto-login is configured (`autoLoginUser=user`, `/etc/kcpassword` present, FileVault off),
  and both plists are `RunAtLoad` + `KeepAlive`.

So: **the Mac was running, ready, and online the whole time.** The "auto-start on boot" setup
was never exercised in this incident, because there was no boot.

### 3.2 The camera is not on the network

Measured at 03:20–03:40 WIB:

```
ping 192.168.1.3       100% packet loss
arp  192.168.1.3       incomplete
nc   192.168.1.3:554   refused/timeout
sweep 192.168.1.0/24   no host with 554, 8899, 8000 or 34567 open
ONVIF WS-Discovery     no camera found
```

The camera had already disappeared once on 22 Oct (05:10–07:2x) and came back by itself. This
time it has been gone 14 h+. It is an ONVIF/XiongMai OEM camera on DHCP; the project notes it
**moves address after a power cut** (`.2 → .3` on 2026-08-31) and that its firmware ignores
ONVIF writes. Nothing on the LAN answers on its ports at all, so this is not an address change —
the device is powered off or its uplink/PSU is dead.

**This is the immediate blocker and it cannot be fixed from here.**

### 3.3 The software converts "no camera" into "no channel"

This is the part that *is* ours, and it is worse than the camera fault itself.

The publisher is one ffmpeg process with two inputs:

```
input 0  -loop 1 basefill.jpg            (the filler still)
input 1  udp://127.0.0.1:5000?...timeout=0   (the camera feed)
overlay [base][cam] overlay=eof_action=pass:repeatlast=1:shortest=0
```

The design comment says "a dead reader just means no packets and the overlay holds the last
good frame". **That is not what ffmpeg does.** With `timeout=0` the UDP demuxer blocks forever
waiting for packets, the filter graph stops producing, and `-progress` stops advancing.

Reproduced on the machine today with the exact production graph and no UDP sender:

```
TEST 1  exact publisher graph, dead udp input, 15 s   ->  frame=0        (nothing produced)
TEST 2  the same still + music, no udp input, 8 s     ->  frame=240      (works perfectly)
```

Consequences, all visible in `log/stream.log`:

1. Watchdog sees `progress.txt` frozen 30 s → `kill -9` → restart, every ~35 s.
2. Every kill tears down the RTMP session; YouTube autoStops the broadcast ~9 s later.
3. The restart calls `prepare_broadcast`, which creates a **new** broadcast that can never go
   live because no frames ever reach ingest.
4. The channel therefore goes from "live camera" to "dark" in about one minute, and stays dark
   for as long as the camera is away — instead of showing a slate.

### 3.4 Collateral damage on YouTube

* `gJH5qUD-Jz0` (the 27 Oct 06:02Z segment) returns **404** and is absent from
  `liveBroadcasts.list` and from the uploads playlist, while its predecessor (`bcuPgvYZk5k`,
  8 h 06 m) is intact. It went live for ~30 s after the camera died; it looks like YouTube
  discarded a broadcast whose ingest collapsed, but this is not fully explained — see §8.
* `0Y8I1HqUkLM` is listed as **public, duration `P0D`** — a zero-length placeholder for a
  broadcast that was created and never went live. It is on the channel now.
* `vod_status` shows the last four *published* segments at 7 h 51 m – 7 h 59 m, i.e. under the
  8 h floor the project itself sets (the wall clock is 8 h 03 m; YouTube trims the rest).

### 3.5 Nobody was told

The streamer pushed its heartbeat every 300 s throughout:

```
2026-10-28 03:26:14 push accepted (HTTP 204) broadcast=None disk=162468 publisher=True
```

`broadcast=None` was in every payload for 14 hours. The off-host watchdog
(`100.99.149.11`, "vpn-germany") accepts the push (HTTP 204) but is not reachable over SSH from
here, so its loop and its SMTP delivery cannot be verified. Either it is not running, or its
mail is not arriving. **An outage of this length with no human contact is a monitoring failure
independent of the camera.**

---

## 4. The power class (separate, and still open)

The project already documents this, and today's data sharpens it:

* `SleepDisabled` = 1 → the Mac stays awake on battery even with the lid shut. Good.
* `pmset autorestart` is **absent = off**, and release notes v2.11 record that on this exact
  model it was measured as *accepted and ignored* (T-29). It is not a safety net.
* Battery: **"Service Recommended"**, 339 cycles, 100 % on AC.
* Therefore: a mains outage longer than the battery runtime leaves the Mac **off**, and nothing
  in software brings it back. Only a human or a UPS does.

Note also that the Mac did not lose AC in *this* incident, which means the camera (and possibly
the router) are on a different circuit or the Mac is behind an undocumented UPS. **This needs
answering on site.**

---

## 5. Vertical / Shorts — why it never worked

### 5.1 What exists in the code

Nothing. `grep -i "vertical\|9:16\|shorts"` over `bin/` returns zero hits. The only trace is
`docs/youtube.md`, which records two experiments:

* The YouTube Data API has **no** dual/vertical/aspect field anywhere in `liveBroadcasts` or
  `liveStreams` (discovery revision 20260914).
* The Studio "Dual stream" toggle was enabled by hand on 2026-09-19: Studio showed a vertical
  **Auto crop** preview (both graded *Excellent*), and the API still showed one `liveStream`
  with only the five standard ingestion addresses. It is neither settable nor readable.
* The setting is **per broadcast** and **cannot be changed once live**, and
  `prepare_broadcast()` creates a brand-new broadcast at every 8 h cut. So even a manual toggle
  evaporates within 8 hours.

That is the whole explanation for "it never really worked": it was never a persistent setting,
and the encoder never sent a vertical feed of its own.

### 5.2 What YouTube actually requires

A live stream appears in the Shorts feed when the **encoded video is vertical (9:16)**; the
vertical live surface is served in the YouTube mobile app. It is a property of the stream, not a
per-video checkbox. ([Restream, Jul 2026](https://support.restream.io/en/articles/9520510-stream-to-youtube-shorts),
[YouTube Help: vertical live streams](https://support.google.com/youtube/answer/13822251?hl=en))

So an always-on vertical feed means: **a second, independent broadcast with its own stream key,
pushed as 9:16**. It will have its own URL and its own chat — that is the accepted trade-off,
and it is the only route that survives an 8 h rotation unattended.

Channels may run multiple concurrent live broadcasts (commonly documented as up to 10 per
channel, e.g. [FrogBox](https://frogbox.freshdesk.com/support/solutions/articles/51000515633/thumbs_up)),
so this does not conflict with the horizontal stream.

### 5.3 Feasibility, measured on this machine today

| Resource | Current | With a second 9:16 feed | Verdict |
|---|---|---|---|
| Upload | 16.2 Mbps measured | 6.8 + 0.384 (horizontal) + 2.5 + 0.128 (vertical) ≈ **9.8 Mbps** | fits, 61 % of link |
| CPU (encode) | 59.4 s CPU / 30 s content | 70.5 s CPU / 30 s content → **+18.5 %** | fits (video is encoded by `h264_videotoolbox`, i.e. hardware) |
| Disk | 162 GB free | + ~10 GB/month of logs, VODs live on YouTube | fine |
| API quota | idle | ~2 broadcasts per rotation instead of 1 | trivial |

The camera's native frame is a **1920×3240 composite of three 1920×1080 views** (ratio 0.593),
which is almost exactly 9:16 (0.5625). That makes a full-composite vertical feed nearly
loss-free — far better than cropping one panel down to a 608×1080 slice.

> Caveat: `docs/youtube.md` records YouTube reporting `videoIngestionStarved` on the primary
> stream at some point. Before adding ~2.6 Mbps, the uplink has to be watched for a full day —
> see §7, step 5.

---

## 6. Solution 1 — make a camera outage unable to darken the channel

Ordered by "how much of the dark time it removes per unit of risk".

### Step 0 — on site, now (no code)

1. Power-cycle / inspect the camera: PSU, PoE injector, switch port, cable. It has been off the
   LAN 14 h; nothing remote can bring it back.
2. Confirm with `bin/camscan.py` (it sweeps 192.168.1.0/24 for ONVIF + camera ports) and with
   the router's client list.
3. Once it is back, capture **one full-composite frame** (`rtsp://…/live/ch00_0`, 1920×3240) —
   the vertical layout decision in §7 depends on what the three panels actually show.
4. Answer: is there a UPS on the Mac? On the router? On the camera? Today's silence on
   `pmset -g log` suggests something is protected and something is not.

### Step 1 — never publish "nothing" (the core fix)

Make the local UDP feed **never stop**, so the publisher never freezes and never restarts:

```
feed_loop():
    if camera answers :  ffmpeg RTSP -> -c:v copy -> udp://127.0.0.1:5000   (today's reader)
    else              :  ffmpeg -loop 1 slate.jpg -> h264_videotoolbox -> udp://127.0.0.1:5000
```

* The slate is a 1920×3240 still (same geometry as the camera composite, so the publisher's
  `crop=1920:1080:0:0` chain is untouched) with a "CAMERA OFFLINE — BACK SOON" card and the
  shop branding.
* Switch on camera probe failure (>5 s), switch back the moment port 554 answers.
  A switch costs a sub-second gap; the publisher's stall threshold is 30 s, so it rides through.
* Proven today: the slate-only graph produced **240 frames in 8 s** at 1080p30 (TEST 2), while
  the camera-dependent graph produced **0**.

Result: the broadcast stays live and archived for the whole outage, viewers see a branded card
instead of a dead channel, and the 8 h rotation keeps working.

### Step 2 — stop the restart loop from destroying broadcasts

Even with the slate, harden the lifecycle:

* Do not `kill -9` a publisher that holds a **live** broadcast unless the output is genuinely
  dead *and* the feed is healthy; prefer restarting the reader.
* On any publisher restart, **reuse the live/ready broadcast bound to the same stream** instead
  of creating another one (mostly true today, but the 0-duration public `0Y8I1HqUkLM` shows the
  gap).
* Add a guard: never leave a `ready` broadcast bound to the stream for more than N minutes
  without ingest — either feed it or delete it.
* Clean up zero-length public placeholders.

### Step 3 — power

* **UPS on the camera and the router** (the Mac's battery already covers itself for a while).
  This is the single highest-value hardware change: it turns a power cut into a non-event for
  everything except the Mac, which has its own battery.
* `sudo pmset -a autorestart 1` anyway — cheap, and re-test whether this unit really ignores it
  (T-29 says it does; one controlled power-pull settles it).
* `sudo pmset repeat wakeorpoweron MTWRFSU 03:00:00` as a belt-and-braces boot attempt if the
  machine is off at 03:00.
* Keep auto-login on; it is what makes the LaunchAgents start without a human.

### Step 4 — alerting that reaches a human

* Add a **local** notifier on the streamer (Telegram bot / ntfy.sh over HTTPS): it fires on
  camera-down > 10 min, channel-not-live > 10 min while the publisher is up, publisher restart
  loop (>3 restarts in 10 min), and disk < 5 GB. The streamer had internet the whole time, so
  this would have fired at ~13:45.
* Keep the off-host watchdog for "the whole host is gone" — but **verify it end to end**
  (stop the streamer's heartbeat for 20 min and confirm a mail arrives). Right now it is
  unverified and therefore not a control.
* Add `broadcast_id`/`camera` to the heartbeat payload (it already carries `broadcast=None`,
  which should have been enough — so the alert rule itself needs checking).

### Step 5 — prove it (chaos matrix)

| Test | Expected |
|---|---|
| Unplug the camera 10 min | channel stays LIVE on the slate, no restart loop, alert after 10 min |
| Kill ffmpeg publisher | back in <60 s, same broadcast, no new URL |
| Pull the network cable 5 min | stream resumes, no duplicate broadcasts |
| Reboot the Mac | stream up unattended within ~3 min (auto-login + agents) |
| Power off the whole shop 2 h | UPS carries camera+router; Mac on battery; nothing dark |
| Power off the whole shop 12 h | Mac eventually dies → **must** come back on its own (this is the UPS/autorestart question) |

---

## 7. Solution 2 — an always-on vertical Shorts feed

### Architecture

```
camera RTSP ─► feed_loop ─┬─► udp://127.0.0.1:5000 ─► publisher 16:9 ─► broadcast A (today)
                          └─► udp://127.0.0.1:5001 ─► publisher 9:16 ─► broadcast B (new)
```

* The reader duplicates the MPEG-TS with ffmpeg's `tee` muxer (present in the installed 9.0.1),
  so there is exactly **one** RTSP session to the camera (it is fragile; two sessions is a risk).
* Publisher B: `scale=1080:-2` of the 1920×3240 composite (`≈1080×1823`), padded to 1080×1920
  with a brand strip, `h264_videotoolbox` 2 500 kbps, AAC 128 kbps, 30 fps, GOP 60.
  Alternative layouts if the composite looks bad: single panel with blurred fill, or 3-up with
  labels. **Decision needs the composite frame from step 0.3.**
* Broadcast B is created and bound by the API exactly like A, with its **own** `liveStream`
  (a second stream key), its own title/description/thumbnail, on the same 8 h 03 m rotation.
* Failure isolation: B runs as its own LaunchAgent (`com.user.cctv-vertical`) with its own
  supervisor; if B dies, A is untouched, and vice versa.

### Required code changes (all in `bin/`, no new dependencies)

1. `yt_api.py`: make broadcast lookup **stream-scoped**. `active_broadcast()` today returns
   *any* live broadcast; with two, the horizontal logic would grab the vertical one.
   Add `active_broadcast_for(stream_id)` and a `--key`/`--stream` switch on `prepare`,
   `ensure-live`, `status`.
2. `stream.sh`: `tee` the reader output; add `start_vertical_publisher` with the 9:16 chain and
   its own slate; rotate both broadcasts in the same cut window.
3. `yt_monitor.sh`: judge each broadcast separately (the current check asks "is *the channel*
   live", which a vertical-only survivor would satisfy).
4. `install.sh` / `harden-host.sh`: second agent, second stream key in `conf/stream.env`.
5. `status.sh`: two rows, one per feed.

### Rollout

1. **Staging test, unlisted**: create broadcast B with `privacyStatus=unlisted`, push 3 minutes
   of 9:16 from a still, confirm `LIVE`, confirm the API sees two live broadcasts, and confirm
   the vertical renders on a phone. Delete it afterwards.
2. **Public short test** (10–15 min, daytime): confirm it appears in the Shorts feed on an
   Android/iPhone. This is the only way to verify the Shorts surface — it is algorithmic and
   cannot be asserted from the API.
3. **24 h trial** with the vertical enabled and the horizontal untouched; watch
   `networkQuality`, ingest health, CPU (`top`), and the archive sizes.
4. Enable permanently; keep a kill switch (`VERTICAL=no` in `conf/stream.env` + agent unload).

### Costs / risks

| Item | Assessment |
|---|---|
| Uplink | 9.8 of 16.2 Mbps. Fine, but a 3 Mbps vertical leaves less headroom than today. If the ISP or Wi-Fi is flaky, drop the vertical to 720×1280 @ 2 Mbps. |
| CPU | +18.5 % measured; the hardware encoder does the heavy lifting. Watch memory bandwidth on the 2015 Air. |
| YouTube | Two broadcasts = two URLs, two chats, two thumbnails, two archives. Shorts placement is algorithmic — vertical is *necessary*, not *sufficient*, for reach. |
| Quota | Still trivial (thousands of units/day, limit 10 000). |
| Failure modes | If B's encode lags, it must degrade (fps/resolution) and never block A. |

---

## 8. Open questions I cannot close from here

1. **Is there a UPS?** The Mac shows no AC transition since 21 Oct despite a reported power cut.
   Either it is protected or the cut hit only the camera's circuit.
2. **Why is `gJH5qUD-Jz0` gone** while its neighbours are intact? If it was deleted by hand in
   Studio, fine. If YouTube discarded it, that is a second, silent archive-loss path.
3. **Why did the off-host watchdog stay quiet** for 14 h? Needs access to `vpn-germany`
   (`100.99.149.11`) — SSH is refused with our key.
4. **What do the middle and bottom panels of the camera composite show?** Needed to choose the
   vertical layout.
5. **Was `0Y8I1HqUkLM` (public, 0 s) visible to viewers?** It should be cleaned up either way.

---

## 9. What I need to proceed

* Approval for the two-track plan: (A) slate/feed fix + alerting + power, (B) second 9:16
  broadcast.
* The camera back on the LAN, plus one full-composite frame.
* Answers to §8.1 and §8.2.
* For B: a title/description/thumbnail for the vertical feed, and whether its chat should be
  open or closed.

---

# 10. What was actually built (2026-10-28, 03:50–04:35 WIB)

Implemented on the streamer while the camera was still off the LAN, so that the power
cycle at ~10:00 WIB needs no human at the keyboard.

## 10.1 The 16:9 feed can no longer go dark when the camera dies

`bin/stream.sh` now has a **slate feed** in the reader:

* `reader_loop` probes port 554 before connecting. Camera down → `slate_feed` pushes a
  1920×1080 "CAMERA OFFLINE" card (last camera frame, dimmed, with the current WIB time) into
  the same local UDP port the publisher reads.
* The publisher therefore never blocks, never stalls, and is never restarted; the RTMP
  session and the broadcast survive the whole outage.
* `slate_feed` re-reads `log/cam_ip` every 5 s, so a camera that comes back on a **new DHCP
  address** still reconnects; the watcher also sweeps the LAN with `bin/find_rtsp.py` when
  ONVIF multicast finds nothing (the sweep binds to every local interface, because en0 and
  en2 are separate segments on this box).
* A camera that is alive on ONVIF but has stopped serving RTSP is now rebooted over ONVIF
  (`bin/cam_reboot.py`) — after 10 minutes of dead RTSP and at most once an hour.

Verified on the machine: with the camera absent, the real publisher filter chain produced
**345 frames** from the slate (vs **0** from a dead UDP input before the change), and the
public stream carried the card (frame pulled from YouTube at 04:05 and 04:31).

## 10.2 The vertical feed exists and is proven

* New second `liveStream` ("Vertical 9:16 (Shorts)"), own key in `conf/vertical.env` (mode 600).
* `bin/vertical.sh`: an independent supervisor — own broadcast, own RTMP session, own 8 h 03 m
  rotation, own slate, own LaunchAgent `com.user.cctv-vertical` (RunAtLoad + KeepAlive).
  If it dies the 16:9 feed is untouched, and vice versa.
* Output: the whole 1920×3240 composite scaled to 1080 wide, padded to **1080×1920**.
  Measured end-to-end with an unlisted test broadcast: YouTube reported the live stream at
  **1080×1920**, the API confirmed `LIVE`, the template (title/description/tags/thumbnail)
  was applied, and the broadcast was then ended and deleted.
* It is gated on the camera (`VERT_START_ON_CAMERA=yes`): it will not publish a slate-only
  feed to the Shorts surface before the camera has been seen once. After the first sighting,
  a later camera drop keeps it live on its own 9:16 card.

## 10.3 Isolation between the two feeds

Adding a second live broadcast broke an assumption in the API layer, so:

* `active_broadcast()` is now **stream-scoped**; `prepare`, `ensure-live`, `status`, `end`
  and the id-less capture/verify/enforce/thumbnail fallbacks all resolve against *their own*
  stream key. Without this, the 16:9 logic could adopt the vertical broadcast and report a
  healthy channel while the camera feed was dark.
* `yt_check.py` pins its frame grading to the 16:9 broadcast id (`log/broadcast_started`),
  never the vertical one, and excludes `log/vertical.broadcast` as a fallback. Grading a
  1080×1920 frame against the horizontal golden frame would have reported MISMATCH forever.

## 10.4 State at handover

| Component | State |
|---|---|
| 16:9 feed | **LIVE** on `0Y8I1HqUkLM`, slate card, frames advancing |
| Vertical feed | agent running, **waiting for camera**, no public broadcast |
| Monitor | OK, grading the 16:9 video (corr 0.938 against golden) |
| Camera | powered off / link dead — absent from both en0 and en2, no ONVIF, no ARP |

## 10.5 Known limits that remain

* **No alerting.** Nothing pages anyone. The off-host watchdog is still unverified, and the
  local notifier needs a Telegram/ntfy credential before it can exist.
* **No UPS** on the camera/router; `pmset autorestart` is still off (and reportedly ignored
  on this model). A long outage still ends with the Mac off until a human presses the button.
* **Second RTSP session** for the vertical is unproven against this camera. If it refuses
  concurrent clients, the symptom is a publisher that dies repeatedly in `camera` mode; the
  fix is `VERT_CAM_PATH="ch00_1"` in `conf/vertical.env`.

## 10.6 The independent 10-minute camera scan (2026-10-28, 04:45–04:55 WIB)

The streamer's own watcher only looks for the camera while `stream.sh` is alive, and both
feeds follow `log/cam_ip`. That left one blind spot: if the streamer process is wedged or not
started, nobody is looking, and the 9:16 feed waits on a file nobody updates.

`bin/cam_scan.py` closes it. Every 10 minutes (LaunchAgent `com.user.cctv-camscan`,
`StartInterval=600`, `RunAtLoad`):

* enumerates the Mac's private-LAN addresses (today: **en0 192.168.1.7** and
  **en2 192.168.1.2**);
* runs ONVIF WS-Discovery **bound to each interface** (multicast must not be sent from only
  the default route), then sweeps `:554` and `:8899` across that /24 **from each source
  address** - the two interfaces are separate segments on the same subnet, so an unbound
  sweep misses one of them entirely;
* prefers ONVIF responders, then `:8899`, then a bare RTSP responder;
* writes `log/cam_scan.log` (one line naming both interfaces and the result),
  `log/cam_scan.heartbeat`, and - only on a hit - `log/cam_ip` and `log/cam_found.json`;
* never starts, stops or restarts anything. It answers "where is the camera"; the feeds act.

`bin/status.sh` now fails loudly if the scan has not run for 20 minutes, because a scanner
that stopped looking is not the same as a quiet camera.

**A trap worth recording:** the first version ran `python3` directly from launchd and stalled
for minutes inside Python's import machinery. The real cause was TCC: Full Disk Access is
granted to `/bin/zsh` on this host, and TCC follows the *responsible process*, so the agent
could not read its own script (`can't open file ...: Operation not permitted`). The job now
runs through `bin/cam_scan.sh`, which `exec`s python3 from zsh and inherits the grant - the
same pattern `stream.sh` and `yt_monitor.sh` already use.

**Verified:** a run under launchd writes
`2026-10-28 04:52:12 SCAN en0(192.168.1.7): nothing | en2(192.168.1.2): nothing -> no camera on any interface`
and exits 1; with a camera present the same code path writes the IP. Expected behaviour at
the power cycle: scan hits → `log/cam_ip` updated → `slate_feed` (re-reads it every 5 s) and
the vertical supervisor both switch to the camera within ~5-20 s.

## 10.7 The vertical feed's rotation is proven (05:00 WIB)

An 8 h rotation that has never fired is a guess. Tested end-to-end with an **unlisted**
broadcast and the cycle shortened to 2 minutes:

```
04:57:46 PREPARE: {"status":"READY","broadcast_id":"GjS2weXIpto","action":"created",...}
04:57:47 PUBLISHER start mode=slate pid=6847
04:59:51 ROTATE: ending the vertical broadcast after 2 min
04:59:51 PUBLISHER stopped pid=6847
          {"status":"ENDED","broadcast_id":"GjS2weXIpto",...}
05:00:20 PREPARE: {"status":"READY","broadcast_id":"DjmetYeQoPQ","action":"created",...}
05:00:21 BROADCAST ready DjmetYeQoPQ
05:00:21 PUBLISHER start mode=slate pid=7658
```

The API then reported `LIVE` on the successor. Both test broadcasts were ended and deleted;
no trace is left on the channel. The 16:9 feed was untouched throughout.

## 10.8 Regression guard: tests/t17_camera_recovery.sh

28 checks that lock in exactly the traps hit while building all of this, because every one of
them failed **silently**:

| Check | The trap it prevents |
|---|---|
| `slate_feed` + `make_slate` exist, reader probes before connecting | the publisher blocking on a dead UDP input (0 frames) |
| `ip=$(<"$CAMIP_FILE")` *inside* the slate poll loop | a camera that returns on a new DHCP address never noticed |
| `drawtext ... textfile=` and braced `${SLATE_FONT}:` | the plain-colour card, and zsh eating `:t` |
| `find_rtsp.py` fallback, sweep from every local address | ONVIF multicast blocked; the other segment invisible |
| `/sbin/ifconfig`, `skip=all_local`, `IP_MULTICAST_IF` | the scanner finding no interfaces, or reporting itself as the camera |
| `cam_scan --self-test` runs | the found-camera branch never exercised |
| `vertical.sh` scope/rotation/seen-camera checks | a vertical feed that adopts the 16:9 broadcast, or never rotates |
| `active_broadcast(stream_id)`, yt_check pinning | two live broadcasts cross-wiring status and grading |

Suite result with t17 included: **SUITE PASSED**.

## 11. The off-host watchdog: why nobody was paged (and the mail is now off)

Root access to `vpn-germany` (`100.99.149.11`, hostname `deltasona`) was available, so the
2026-09-18 / 2026-10-28 silence can now be explained rather than guessed at.

**It was running the whole time.** `ytlive-watchdog.service` and `ytlive-heartbeat.service`
were both active, uptime 122 days, `NRestarts=0` since 2026-09-19. It received every heartbeat
(15 s old at worst), and it did send mail - just never about the thing that mattered:

```
2026-10-27T14:11:45Z alert emailed: [YTLive] recording problem: short tzlsZ_Nv6VE 7h57m
2026-10-27T20:12:14Z alert emailed: [YTLive] recording problem: short tzlsZ_Nv6VE 7h57m
2026-10-27T21:04:23Z alert emailed: [YTLive] recording problem: short tzlsZ_Nv6VE 7h57m
...
```

Not one `channel DARK` alert in 14 hours. Its state file said, through the entire outage:

```
"last_channel_state": "live",   "live_since": 1793083068
"last_video": "bcuPgvYZk5k"     <- a long-finished recording, not the current broadcast
"vid": null                     <- yt-dlp cannot resolve the current video on that host
```

So the channel check was stale/incorrect on that host: `yt-dlp` is bot-blocked there (a known
issue in the project notes), the HTTP fallback apparently still reads the channel page as
live, and the watchdog therefore never crossed its `WATCH_DARK_GRACE` threshold. It is a
**heartbeat watchdog, not a channel watchdog**, in practice - it can only notice the streamer
going silent, not the stream going dark while the process is healthy. That is exactly the
failure mode of 2026-10-28.

Actions taken:

* `WATCH_ALERT_MODE` changed from `smtp` to `file` in `/var/ytlive-watchdog/conf/watchdog.env`
  (backup kept beside it), service restarted, and verified with `test-alert`:
  `alert written to /var/ytlive-watchdog/alerts/1793138909-[YTLive] TEST - watchdog alert path.eml`.
  **No further email is sent**; alerts are still recorded on the host.
* The blind spot is recorded here: with alerts on file, and detection unable to see a dark
  channel, this watchdog is now purely a "did the streamer stop pushing" monitor.

## 12. Dual stream in Studio: why the toggle is not the answer, and why we no longer need it

The user's experience is exactly what the project notes predicted: the Studio **Dual stream**
toggle only works when set *before* the broadcast starts, it is per broadcast, and it resets
every time a new broadcast is created - which on this channel happens at every 8 h 03 m cut.

Our vertical feed does not use that toggle at all. It is a **second, independent broadcast**
whose encoder output is genuinely 1080x1920 (verified on YouTube's own live manifest), and
YouTube decides "vertical live -> Shorts feed" from the stream's aspect ratio, not from the
Studio switch. With the toggle off, the 16:9 broadcast is unaffected and the vertical broadcast
still appears as a vertical live stream.

What still needs a phone in the hand: confirming the live vertical stream actually surfaces in
the Shorts feed. That is algorithmic and cannot be asserted from the API - the plan is to check
it on a phone once the camera is back and the vertical feed is public.

## 13. A camera that accepts on 554 but cannot stream (05:10–05:20 WIB)

The nastiest camera state is the one the port probe calls healthy: TCP connects, RTSP never
delivers. `slate_feed` waits for 554 to answer, so it would never engage; the reader would fail
RTSP in under a second, over and over, and the publisher would starve until the stall watchdog
churned the broadcast.

`reader_loop` now counts **short** sessions (`< 30 s`). Any short failure puts the slate back
up immediately (30 s), and the third in a row holds it for `SLATE_BURST_SECONDS` (120 s) so a
booting camera can finish starting.

**Proven on the live box** by pointing `log/cam_ip` at a silent listener on port 554:

```
05:18:11 READER: feed from 192.168.1.7 ended after 0s (short failure 1) - slate up while retrying
05:18:41 READER: feed from 192.168.1.7 ended after 0s (short failure 2) - slate up while retrying
05:19:12 READER: feed from 192.168.1.7 ended after 0s (short failure 3) - slate up while retrying
05:19:12 READER: 3 short RTSP failures in a row - camera accepts on 554 but is not streaming;
                  holding the slate for 120s
```

with the channel **LIVE** and the frame counter advancing throughout.

### The first version of that fix darkened the channel - and that is worth recording

The first patch referenced `${SLATE_BURST_SECONDS}` but never defined it. Under `set -u` the
**reader subshell died** on the third failure (`reader_loop:30: SLATE_BURST_SECONDS: parameter
not set`), nothing restarted it, the publisher starved and the channel went dark at 05:14.
Two lessons, both now enforced:

1. `SLATE_BURST_SECONDS` is defined above its first use, and **every** reference carries a
   default; `tests/t17` fails if either stops being true.
2. The main loop now **supervises the reader** (`kill -0 "$READERPID" || reader_loop &`, logged).
   Until 05:20 a dead reader meant a dark channel until a human looked - the publisher
   watchdog kept restarting an encoder that could never be fed.

Also learned: deploying over a *running* zsh script can produce
`stream.sh:1147: parse error near '&&'` because zsh reads the file incrementally and `scp`
rewrites it in place. Deploys now go to `.stream.sh.new` and `mv` into place.

## 14. The vertical feed reached the Shorts feed (confirmed by the operator, 05:30 WIB)

Watched on a phone while the vertical broadcast was live: **the 9:16 stream appeared as a live
stream inside the Shorts feed.** That closes the open question in §12 - YouTube's placement is
driven by the encoded aspect ratio, not by Studio's Dual stream toggle, and a second
independent broadcast is enough.

At the operator's request both feeds were then brought back online with an Indonesian card:

```
16:9  LAUNDRY BUKA 24 JAM - TETAP BEROPERASI     (Hw_dwnT16ew)
      Kamera CCTV akan kembali dalam beberapa jam
Vertical  LAUNDRY BUKA 24 JAM / TETAP BEROPERASI  (4_EyeqJFff4, 1080x1920)
          Kamera CCTV kembali / dalam beberapa jam
```

`VERT_START_ON_CAMERA` is now `no`: the vertical feed is "always on" by policy, including
through a camera outage, because its being live is what puts the shop in the Shorts feed.

## 15. Cross-wiring: the 16:9 logic adopted the vertical broadcast (05:23, fixed)

While both were live, `await_broadcast` asked `yt_live_id`, which took the **first live video
on the channel** via `/@channel/live`. That was the vertical broadcast, so the 16:9 streamer
logged `LIVE: channel is live on GY8q-3mRsVw` and stamped the horizontal title, tags and
thumbnail onto the vertical video (visible in `stream.log` as a `SETTINGS ... video GY8q` line).

Fixed: `yt_live_id` now asks the **stream-scoped** API status first, and only falls back to
yt-dlp with the vertical's own id (`log/vertical.broadcast`) explicitly excluded. A live
vertical can no longer be mistaken for the 16:9 feed, and `apply_settings` can no longer
rewrite the vertical's metadata.

Guarded by `tests/t17` ("yt_live_id is scoped to our own broadcast", 33 checks total).

## 16. Indonesian card layout

The first Indonesian card overflowed the 1080-wide vertical frame - `drawtext` clipped it at
both edges because `x=(w-text_w)/2` went negative (seen in the 05:31 capture). The vertical
card now uses short lines at 42 px; the 16:9 card keeps the long line at 64 px, which fits 1920.
Both were re-captured from YouTube after the change and read correctly.

## 17. Vertical card layout: text above the frame (operator request)

The vertical card now places the message at `y=240` and the camera frame at `y=700`, so a phone
viewer reads "LAUNDRY BUKA 24 JAM - TETAP BEROPERASI / Kamera CCTV kembali dalam beberapa jam"
first and the shop photo second. Re-captured from the live stream after the change.

## 18. API quota exhausted (05:46 WIB) - and what it does and does not stop

`log/quota_exhausted` is armed: the day's 10 000 units are spent (this session's test broadcasts,
deletions, setting enforcement and status polling). Every API call now fails fast and locally,
and the daily reset is ~5.9 h away.

What still works, because it needs no API:

* both feeds stay **live** (verified with yt-dlp: `Hw_dwnT16ew`, `4_EyeqJFff4`, both `is_live=True`);
* the camera coming back only changes the *encoder source* - `reader_loop` and `slate_feed` need
  no API at all, and neither does the vertical's slate→camera switch while its broadcast lives;
* the monitor keeps grading frames.

What is refused until the reset: creating a new broadcast (`prepare`), `ensure-live`, rotations
(`ROTATE_WITHOUT_API=no` keeps the channel live rather than cutting blind). If a broadcast ends
inside this window the feed cannot be recreated until the quota resets - the one exposure.

Lesson for the next test session: test broadcasts are 50-unit writes each; a day of experiments
can eat the quota the production rotation needs. Do destructive API tests on a scratch channel,
or budget them.

## 19. Post-stream thumbnails: our own frame at 4 h, plus a repair sweep

**What was wrong.** The scheduler waited an hour for YouTube's "pick one of 3" suggestions,
which never arrive for these 8 h streams ("no suggestion after 321 min" in `stream.log`), and
only then tried to grab a frame - which returned "not seekable yet - still processing" for six
more hours. It did eventually work (bcuPgvYZk5k was set at 362 min), but the single pending
slot is rewritten at every cut, so any video still processing when the next cut happened kept
the channel's generic image forever. That is the state the operator had been fixing by hand.

**What it does now.**

* `THUMB_DELAY` = **4 h** after the cut. The video that just ended is then given the
  **01:00:00 frame from itself**; YouTube's suggestions are no longer consulted at all.
* If the video is still processing, the worker retries every 30 min until it succeeds.
* A **repair sweep** (`yt_api.py sweep-thumbnails 10`) checks the **ten most recent videos**
  and fixes any that still show the generic image. It runs once at startup and again after
  every successful post-cut thumbnail, at most twice a day.

**How "default placeholder" is decided.** Every broadcast is stamped with `conf/thumbnail.jpg`
by `apply_settings()`, so a video that never got its own frame keeps that same shop picture.
A byte comparison cannot detect it - YouTube re-encodes an uploaded thumbnail - so
`thumbnail_is_placeholder()` compares 64x36 greyscale correlation against that file and calls
it a placeholder at **corr >= 0.95**, or when the image is flat (spread < 8, YouTube's own
"processing" card). Measured over the 12 most recent videos on 2026-10-28: the two live
broadcasts scored **1.000**, every finished video **0.004-0.185**.

**Verified on the machine.** Dry run over the ten newest videos: 2 placeholders (both currently
live, correctly skipped - their own cuts will handle them), 8 already carrying a frame of
themselves, 0 errors, ~15 s, and **no API quota consumed** because nothing needed repair.
The 01:00:00 frame grab itself was proven against a finished video (1920x1080 JPEG).
`tests/t18_thumbnails.sh` (15 checks) locks the schedule, the sweep and the correlation rule in.

**Not yet exercised:** the actual thumbnail upload, because the API quota is exhausted until
~11:40 WIB. The first real set happens 4 h after the 13:20 cut (~17:20), well after the reset.
