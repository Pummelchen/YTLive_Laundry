# YTLive_Laundry — full audit, 2026-09-16

Read-only static audit of the whole repository, plus live-channel forensics and verification
against Google's own documentation. Every finding below is labelled:

- **(a) proven from code** — with `file:line`
- **(b) proven from official documentation** — with a URL
- **(c) measured** — on the live channel or locally
- **(d) suspected** — stated as such, never as fact

The audit produced 5 test files and a first batch of fixes; see §7 and §8.

---

## 1. Verdict

The rotation works, and the archive is healthy. The empirical evidence is unusually good:

- **(c)** 25 consecutive archived broadcasts, every one between **28885 s and 29003 s**
  (8h01m25s – 8h03m23s): all clear the 8 h target, minimum margin **85 s**.
- **(c)** Start-to-start cycle **29259–29301 s** (mean 29275 s = 8h07m55s); measured downtime
  between broadcasts **mean 296 s, median 288 s** (~5 min), consistent with the configured
  `ROTATE_GAP=180` plus YouTube's own close and bring-up.
- **(c)** Rotating at exactly 8 h would have pushed 5 of the last 24 VODs below 8 h. The
  `8h03m` choice is justified, and 3 h 57 m inside the 12 h archive limit.
  (b) <https://support.google.com/youtube/answer/6247592>

The serious problems are **not** in the rotation. They are: a privacy exposure in the public git
history, a monitor that can kill a healthy publisher, and a documentation set that contradicts
the code on exactly the question the owner is trying to decide.

---

## 2. THE HEADLINE: the API is required, and the OAuth fix needs no Google approval

### 2.1 The repository contradicts itself, and the DOCS are the stale side

`bin/stream.sh` carried a comment claiming YouTube creates the next broadcast by itself and that
"the API is a FALLBACK now". That claim is **false** and the repository already corrected it —
five hours later, in a commit whose message was never reflected back into the comment or the docs.

| Commit | Time | Claim |
|---|---|---|
| `57f34ae` | 2026-09-05 14:02 | "Add the YouTube API so the streamer can actually create a broadcast" — API required |
| `da54c8d` | 2026-09-05 19:14 | "Rotate natively" — claims YouTube does it, API is a fallback |
| **`9a8d458`** | **2026-09-05 23:27** | **explicitly retracts it** |
| **`ac53790`** | **2026-09-07 16:28** | **"prepare calls the API on EVERY cut"** |

`9a8d458` verbatim: *"AND A CORRECTION. I claimed this afternoon that the earlier conclusion was
wrong and that YouTube creates a broadcast by itself when ingest arrives at a bare stream key.
Tonight was a controlled test of exactly that and it does not: six minutes of clean ingest against
a dark channel produced nothing. The 3 September case I reasoned from was YouTube rolling over a
CONTINUOUSLY FLOWING ingest into a new broadcast, which is a different mechanism and does not help
here. **The API is load-bearing, not a spare wheel.**"*

`ac53790` verbatim: *"'native' only ever meant 'went live without needing the ensure-live
fallback' — prepare calls the API on EVERY cut to create and bind the next broadcast, so with no
token there is no rotation at all."*

**(a)** The code agrees with the correction: `bin/stream.sh`'s `start_publisher()` calls
`prepare_broadcast()` **before** it launches ffmpeg, on every publisher start.
**(b)** Google retired automatic broadcast creation in 2020: *"YouTube will no longer create
automatic live stream events and live videos … client applications must create and manage
liveBroadcast and liveStream resources and bind them."*
<https://developers.google.com/youtube/v3/live/guides/migration-guide-default-broadcasts>

### 2.2 What YouTube does and does not do on its own

| Half of the rotation | Who does it | Needs the API? |
|---|---|---|
| Stop the broadcast at 8h03m | YouTube `enableAutoStop=true` (~9 s measured) | **No** |
| Save and archive the VOD | YouTube `enableDvr`/`recordFromStart` | **No** |
| **Create + bind the next broadcast** | `yt_api.py prepare` → `liveBroadcasts.insert` + `bind` | **YES** |

**(a)** Every broadcast this project creates forces `enableAutoStart=true` **and**
`enableAutoStop=true` (`bin/yt_api.py:350,362-363`), and the shipped reference has autoStop true
(`conf/broadcast_template.json:62`). autoStart only starts a broadcast that is *already bound*.

**So the owner's stated hope — "rely on YouTube behaviour to stop the stream after 8h03m and start
a new one a couple of minutes later" — is half-achievable.** The stop/archive half already works
with no API. The "new live stream under a new URL" half cannot be done by YouTube behaviour on any
channel today; it needs `liveBroadcasts.insert`.

### 2.3 The OAuth fix, and it needs no Google approval

**(b)** The 7-day refresh-token expiry is a **"Testing" publishing-status** behaviour for External
user type. Publishing the consent screen to **"In production"** removes it:

> "Apps with a publishing status of 'In production' must complete verification for all requested
> sensitive and restricted scopes. An app requesting unverified sensitive or restricted scopes will
> result in the display of unverified app warnings, which may prevent user authorization."
> — Google product expert, <https://discuss.google.dev/t/oauth2-refresh-token-expiration-and-youtube-api-v3/160874>

> "it's an intended behavior for the refresh token to always have a lifespan for as long as 7 days.
> This will remain intact as long as the publishing status is set to 'Testing'. … the obvious
> solution here would be to publish the OAuth consent screen app."
> — Google product expert, <https://discuss.google.dev/t/persistent-oauth-authorization-for-youtube-api-automation-needed/171427>

`https://www.googleapis.com/auth/youtube` is a **sensitive** scope. Google's own sensitive-scope
policy documents a **personal-use exception**: a sole user (or a few known users) need not submit
for verification and may proceed through the unverified-app screen.
<https://developers.google.com/identity/protocols/oauth2/production-readiness/sensitive-scope-verification>

**Verification is not required to escape the 7-day expiry.** It is required only to remove the
"Google hasn't verified this app" warning for *other* users. An unverified published app keeps its
refresh token, and a 100-user cap applies — irrelevant for one account.

**The repository already knew this.** `bin/yt_api.py:146-150` prints exactly this advice during
`auth`: *"OAuth consent screen -> PUBLISH THE APP ('In production'). This matters: while the app is
in 'Testing', Google expires the refresh token after 7 DAYS … Publishing shows an 'unverified app'
warning you can click past — that is fine for a personal app, and the token then does not expire."*

Every other document says the opposite ("stays in Testing, so … this is permanent"). **The code was
right and the docs were wrong.** `README.md`, `docs/youtube.md` and the `AGENTS.md` trap have been
corrected in this commit.

Console click-path: `console.cloud.google.com` → APIs & Services → OAuth consent screen / Google
Auth Platform → **Audience** → User type **External** → Publishing status **In production** →
**Publish app**. Keep the existing *TVs and Limited Input devices* client. Do **not** submit for
verification. Then re-run `bin/yt_api.py auth` — tokens issued while Testing keep their 7-day life.

### 2.4 A dead token is a dark channel, so the failure mode was hardened

**(a)** With a dead or absent credential: the stream keeps running and the in-flight segment's VOD
is still saved (autoStop needs no API), but at the next cut `prepare` cannot create a successor, and
nothing else will. The channel goes dark until a human re-authorises. That is the documented
2026-09-05 outage (5 hours dark).

Since publishing is off the table here, the code is now hardened for Testing-only:

- `bin/yt_api.py token` **probes** the credential (mints a real access token via
  `probe_refresh_token`) instead of trusting a countdown. JSON gains `"probe": "LIVE"|"DEAD"|"UNKNOWN"`.
  Exit codes stay `0` fine / `1` expiring / `2` dead-or-unknown. `token --offline` retains the old
  network-free countdown for `status.sh --no-net`.
- The countdown is **advisory only**. An elapsed countdown on a token Google still accepts is
  reported as probable publication, not as an outage. `YT_TOKEN_TTL_DAYS=0` disables it.
- **`rotate_broadcast()` now REFUSES to cut when the API cannot create the next broadcast**, and
  stays live. A lost recording beats a dark channel, because darkness needs a human either way.
  `ROTATE_WITHOUT_API=yes` restores the old behaviour; `ROTATE_API_RETRY` (900 s) sets the backoff
  so the 5-second loop does not retry the cut forever.

**The residual risk is honest and unavoidable:** with a Testing-only app, the credential dies every
7 days and *a human must re-authorise*. No code change can remove that. Publishing is the only real
fix, and it is one console toggle.

---

## 3. Critical: shop CCTV footage is in the public git history

**(c)** Verified directly from this clone, reachable from `origin/main` on a **public** repository:

| Blob | Size | Content |
|---|---|---|
| `log/combined.flv` | 9,166,244 B | **1920×1080 H.264 + 48 kHz stereo AAC, 20.05 s** |
| `log/basefill.jpg` | 245,069 B | camera still |
| `log/yt_lastpull.jpg` | 199,307 / 188,917 B | frames pulled from the public stream |
| `log/yt_prevpull.jpg` | — | frames pulled from the public stream |
| `conf/golden.jpg` | 243,010 / 253,166 B | camera still |

Introduced in `81f5318`, `a38dfde` and `d3d02da`; none of those commits is an ancestor *exclusion*,
so every clone of this public repository still contains them.

**Note the audio.** `log/combined.flv` carries a real 48 kHz stereo AAC track at 640 kbps of video
datarate. The current design provably never streams the CCTV microphone — the reader passes `-an`
and the publisher maps only `-map 2:a:0` (the MP3 playlist) — but an **earlier revision captured
camera audio**, and that recording is public.

`log/stream.log`, `log/launchd.out.log`, `log/cam_ip` and `log/yt_url.cache` additionally leak the
LAN subnet (`192.168.1.2/3`) and the shop's public egress IP (`103.21.207.12`).

**Owner decision (2026-09-16): accepted risk — do not rewrite history.** Recorded here so the
decision is deliberate rather than forgotten. The blobs remain publicly clonable, and GitHub may
retain cached copies and forks regardless. Consequence for the tracker: the stream key and OAuth
token have not been published (verified: no credential was ever committed), so no rotation of them
is implied by this exposure. See T-21.

---

## 4. High: the monitor could kill a healthy publisher

### 4.1 `NOGOLDEN` / `NOCONFIG` / `ERROR` were classified as a bad picture — FIXED

**(a)** `bin/yt_check.py` can answer `NOGOLDEN` (`:140`), `NOCONFIG` (`:139`) and `ERROR`
(`:189`). `bin/yt_monitor.sh`'s `case` named only `OK`, `UNKNOWN|FETCHFAIL|NOSTATUS|""`, `OFFLINE`
and a catch-all `*)` that means *"YouTube is live but showing the wrong thing"*. The three error
statuses fell into that catch-all, and after `FAIL_SECONDS` the monitor ran
`pkill -9 -f "ffmpeg.*rtmp"` — killing a healthy publisher. This contradicts the file's own rule 2
("Act because the LOOKUP failed … never triggers an action").

Concrete path: the `yt-dlp` binary is missing → `FileNotFoundError` → `yt_check.py` prints `ERROR`
→ the monitor restarts the publisher every `FAIL_SECONDS + 60 s`, forever, on a healthy stream.

Fixed: `NOGOLDEN|NOCONFIG|ERROR` now join the never-act arm. Guarded by `tests/t02`.

### 4.2 `conf/golden.jpg` could never be bootstrapped — FIXED

**(a)** `bin/yt_monitor.sh:123` refreshed the reference only when
`[[ basefill.jpg -nt golden.jpg ]]`. In **zsh, `-nt` is FALSE when the right-hand file does not
exist** (verified locally, 5.9) — unlike bash. `conf/golden.jpg` is gitignored, so a fresh install
has none, so the refresh could never fire, so every check returned `NOGOLDEN` — which, per 4.1,
meant "kill the publisher", permanently and unfixably.

Fixed: `[[ ! -e golden || basefill -nt golden ]]`. Guarded by `tests/t03`.

### 4.3 A rotation with a dead token leaves a broadcast to cross 12 h

**(a) suspected** `bin/stream.sh:644-652` exits its wait loop after `ROTATE_MAX_WAIT` even if the
old broadcast never closed, and with no token the API `end` is skipped — so ingest resumes while the
old broadcast may still be live. Mitigated by the new refusal gate (§2.4): without a usable
credential the cut no longer happens at all. Still open for the `ROTATE_WITHOUT_API=yes` case.

### 4.4 `enableAutoStop` interaction with publisher restarts

**(a) suspected.** autoStop ends a broadcast when ingest stops, so any restart long enough to trip
YouTube's debounce can end the broadcast and fragment the 8 h VOD. The watchdog restart
(`:708-711`) is quick, but `start_publisher()` runs `prepare_broadcast()` (an API round trip with
30 s and 60 s timeouts) plus an 8 s snapshot grab **before** ffmpeg starts, and `refresh_broadcast_clock()`
only runs every 300 s — so the loop keeps the old clock for up to 5 minutes and could rotate the
young replacement early. Not yet reproduced; listed as T-08.

---

## 5. Medium and low findings

### API quota can exceed the daily allowance — **(b) and (a)**
Quota costs: `list` = 1, `insert`/`bind`/`transition`/`delete`/`videos.update`/`thumbnails.set` = 50,
single 10,000-unit pool, reset midnight PT.
`<https://developers.google.com/youtube/v3/determine_quota_cost>`

Worst case per day = rotations 1,788 + clock refresh 576 + **drift-check 7,776** + thumbnails 150 =
**10,290 — over budget by 290**. The driver is `ENFORCE_EVERY=1800` (48 verify+enforce cycles at up
to 158 units) firing because a reference field will not persist. A dark channel makes it far worse:
the monitor's `ensure-live` retries can reach 19k–48k/day. T-06.

**(a)** On `403 quotaExceeded` the code does not stop: `prepare` fails but ffmpeg restarts anyway,
so the channel goes dark at that rotation. T-06.

### Dead configuration knobs
**(a)** Declared in `conf/stream.env.example` and **read by no code**:
`CAM_LINK_TIMEOUT` (documented wrongly as watching the camera's TCP session — the watchdog only
watches `STALL_TIMEOUT` on the output frame counter, which the filler keeps advancing on a held
frame), `FILLER`, `SRC_FPS`, `ENC_FPS`, `FPS_MODE`, `SNAP_INTERVAL`, `MP3_DIR`.
`docs/architecture.md` instructs the reader to set `FPS_MODE="blend"`, which does nothing: the chain
is hardcoded `[0:v]fps=${OUT_FPS}[base]`. T-05.

### Documentation drift — 40+ claims
**(a)** Full table in the audit session; the headline corrections are in §2, and the rest were fixed
in this commit: `CORR_MIN` 0.35→0.15, `LOG_MAX_BYTES` 2097152→524288 and "last 1 MB"→256 KB,
`ENC_BITRATE` 4500k→6800k, `aac_at`→native `aac` 384k, `enableAutoStop` OFF→forced ON,
`MODE="copy"` is not a passthrough (the publisher always re-encodes), `ROTATE_GRACE` is a log
string only (real holds are 480 s), the phantom `--host` flag, the non-existent install bundle
tarball, `docs/files.md`'s self-contradiction about TCC/Full Disk Access, and the `.gitignore`
header attributing the 353 MB repository to logs when **MP3/ is 328 MB of it**.

### Testability
**(a)** There was no automated test of runtime behaviour at all, and no CI (`.github/` is absent;
only GitHub's dynamic CodeQL for Python is active). `bin/smoke_test.sh` accepted
`{"status":"ERROR"}` as a PASS because it grepped only for `"status"` — fixed, and its bare-clone
exit code is 2, not the 1 that `AGENTS.md` claimed.

---

## 6. Numbers that back the operator's understanding

| Measurement | Value |
|---|---|
| VOD durations, last 25 | 28,885 – 29,003 s (all > 8 h; min margin 85 s) |
| Rotation cycle (start→start) | 29,259 – 29,301 s (mean 8h07m55s) |
| Downtime per rotation | mean 296 s, median 288 s |
| 12 h archive margin | 3 h 57 m (32.9 %) |
| MP3 library | 25 tracks, 48 kHz stereo 320 kbps, 2.391 h |
| Playlist | 125 entries = 25 × 5 passes = 11.955 h (1.49× one rotation) |
| Steady-state runtime state | ~16 MB (progress.txt dominates, truncated per publisher start) |
| Disk free-space check | **none existed** — now warned in `housekeep` below 200 MB |

---

## 7. Fixed in this commit

1. `bin/yt_monitor.sh` — `NOGOLDEN|NOCONFIG|ERROR` moved to the never-act arm.
2. `bin/yt_monitor.sh` — golden reference can now be created when `basefill.jpg` exists.
3. `bin/yt_api.py` — `probe_refresh_token()`; `token` probes and reports `LIVE/DEAD/UNKNOWN`;
   `token --offline` for the network-free path; the countdown is advisory and never reports a
   working token as expired; `save_creds()` writes 0600 from the first byte (was a 0644 window).
4. `bin/stream.sh` — the false "the API is a FALLBACK" comment replaced with the corrected account;
   `prepare_broadcast()` no longer claims YouTube creates broadcasts by itself; `api_usable()` added;
   `rotate_broadcast()` refuses to cut without a usable API (`ROTATE_WITHOUT_API`, `ROTATE_API_RETRY`,
   `ROTATE_BLOCKED_UNTIL`); `cam_ip_watcher` updates the in-memory `CAM_URL` and `CAM_HOST` after a
   DHCP move; `housekeep` warns below 200 MB free.
5. `bin/smoke_test.sh` — read-only API checks now judge the *status*, so `ERROR`/`OFFLINE`/`NOREF`
   fail instead of passing.
6. `install.sh` — seeds `conf/stream.env` from the example on a fresh clone instead of aborting
   before the LaunchAgents are written; `chmod 600 conf/yt_oauth.json`; empty-`YT_KEY` detection
   fixed (the old pattern matched only a one-character key); refuses `--start` without a key; FDA
   probe moved to a private `mktemp -d` directory (it used a fixed world-writable `/tmp` path that
   any local user could pre-create or symlink); optional `FFMPEG_SHA256`/`FFPROBE_SHA256`
   verification with an honest "not verified" message when unset; `BASE` exported; the autoStop
   comment corrected.
7. `bin/cam_reboot.py` — everything moved into `main()`; importing it no longer reboots the camera.
8. `bin/shuffle_playlist.sh` — `set -u`; `ROTATE_HOURS` passed explicitly (it is sourced, not
   exported, so a change used to be silently ignored); refuses to write a playlist when `ffprobe`
   is missing or cannot measure a track (that produced a 2.4 h playlist that kills the publisher
   mid-broadcast); falls back to `PATH` for `ffprobe`.
9. **`tests/`** — a new credential-free harness: `tests/run.sh`, `tests/lib.sh`, `tests/stubs/`
   (including a `pkill` recorder so a mis-scoped test cannot signal a real process) and 5 test files,
   **84 checks**. Every test works in its own scratch tree under `tests/.tmp`.
10. Documentation corrected throughout (see §2 and §5), including `AGENTS.md`'s traps.

## 8. Open — needs the owner

- **T-21 (accepted risk)** Purge the CCTV/audio blobs from public history, or accept them. Decision
  taken 2026-09-16: **accept and document**.
- **T-01** Publish the OAuth consent screen to "In production" — the only real fix for the 7-day
  expiry. One console toggle; no Google approval required.
- **T-02** Rotate the YouTube stream key if the accepted history exposure is judged material
  (the key itself was never committed).
- **T-06** Quota: back off `enforce` when a field will not persist, and detect `403 quotaExceeded`
  instead of hammering.
- **T-08** Verify whether a publisher restart can trip `enableAutoStop` and fragment the VOD; the
  broadcast was not observed being closed early, so this is a suspected, not a proven, defect.
- **T-09** Camera/ONVIF is unauthenticated on the LAN (`:8899`, no auth) and WS-Discovery accepts
  any responder — a LAN attacker can redirect the public video source. Needs network policy, not code.
- **T-10** Full Disk Access is granted to `/bin/zsh`, a shared interpreter: every script and
  postinstall inherits it. A signed wrapper would be narrower.
- **T-12** `verify_pending_vods` de-duplicates against a history trimmed to ~100 lines, so a lost
  VOD can fall out of the retried set.
- **T-13** `status.sh` reports disk *usage*, not free space (the streamer now warns in its log).
- **T-14** `bin/preflight.sh` still hardcodes `$HOME/Downloads/YTLive` with no `BASE` override, and
  every other entry point defaults to that path, so a checkout in another directory silently
  inspects the wrong tree.

---

*Audit performed read-only. Live-channel facts measured with `yt-dlp` against
<https://www.youtube.com/@ternaklaundrybengkong>; the production host was not modified.*
