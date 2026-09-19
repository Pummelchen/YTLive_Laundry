# The external watchdog

`bin/yt_watchdog.py` watches the channel from **outside** the streamer and emails a human
when it goes dark. It is the only component in this repository that does not run on the
streaming Mac, and the only one allowed to notify anyone.

## Why it exists

On **2026-09-18** the streamer dropped off the network at `10:19:54Z`, 5 h 14 m into an
8 h 03 m segment. The publisher's own watchdog, the monitor, `stream.sh`'s retry loops and
launchd's `KeepAlive` all behaved correctly and all were useless, because the machine had lost
its transport — DNS and its own LAN — while it stayed awake and logging: every retry in them was
an application-layer retry that never touched the network interface. The channel stayed dark for
**~19 h 26 m** and nothing on the streamer said anything — by design, since the rule here was
"no notifications; every failure path retries".

That rule is correct for failures the streamer can retry, and helpless for the one class it
cannot reach: the host. This script closes exactly that hole. It is deliberately *not* on the
streamer, because a watchdog that dies with the thing it watches is not a watchdog.

Evidence from that outage, which is what the thresholds below are set against:

| Signal | Value |
|---|---|
| Last broadcast | `3Cnxr6fTrWk`, ingest stopped `2026-09-18T10:19:54Z` |
| Tailscale last contact with the streamer | `2026-09-18T10:20:00Z` — the same second |
| Segments before it | four consecutive 8.05 h segments, gaps 4.5–5.2 min |
| Shop uplink during the outage | **up** — its public IP answered ICMP 10/10 at ~5 ms |
| Time dark before anyone acted | ~19 h 26 m |

The healthy numbers matter as much as the failure: a rig in perfect order is dark for about
five minutes every eight hours, so any alert threshold has to sit well above that.

## What it watches — independent signals

1. **The channel, twice.** First via `yt-dlp`, which is the ground truth for "is the stream
   up". The `live` / `offline` / `unknown` split and the `OFFLINE_SIGNS` phrase list are
   copied from `bin/yt_check.py` on purpose: `UNKNOWN` means *the lookup failed*, never *the
   channel is dark*, so a yt-dlp rate limit cannot page anyone. Keep the two lists in step.
   Second, independently, via a plain HTTPS `GET` of the public channel `/live` page using
   only `urllib`. That page carries `"isLiveNow":true` while the channel is broadcasting and
   `"isLiveNow":false` when it is not (verified by hand on 2026-09-19); a page without a
   marker — a consent wall, a bot check, a markup change — is `UNKNOWN`, never offline.
   Either reader saying `live` is enough to call it live; only **both** saying `offline` is
   offline; anything else is `unknown`.
   **Why (2026-09-19):** during the recovery `yt-dlp` was rate-limited/bot-checked and
   answered `unknown` for hours, so the watchdog's *only* channel signal went blind at the
   worst moment. It raised two `blind` alerts, and its "channel is LIVE again" mail arrived
   **5 h 21 m** after the channel had actually recovered, because recovery could not be seen
   until `yt-dlp` answered again. A second reader on a different transport means one
   rate-limited tool can no longer blind the watchdog on its own.
2. **The streamer host**, via `tailscale status --json`. This is what turns "dark" into a
   diagnosis — host gone means power or network; host up means publisher, token or camera —
   and it cannot be blinded by a YouTube change the way `yt-dlp` can.
3. **The streamer application's heartbeat**, if a file is configured (`WATCH_HEARTBEAT`). Its
   modification time going stale is positive evidence that the app itself has gone silent —
   a different failure from "the channel is dark", and one the channel read cannot always
   describe. A stale heartbeat is reported **even while the channel read is `UNKNOWN`**. An
   **absent** file is not stale: it is an unconfigured deployment and never alerts.

None is trusted alone. The channel decides *whether* to alert; the host and heartbeat decide
*how to describe it* and cover the case where the lookup is failing at the same time.

## Alert policy

| Situation | Behaviour |
|---|---|
| Channel live | silence, every episode cleared |
| Only one reader says live | live — a single confirmed positive read is enough |
| Only one reader says offline (the other failed) | `unknown` — one failed read is never a dark channel |
| Both readers say offline | offline, and the dark rules below apply |
| Dark < `WATCH_DARK_GRACE` (15 min) | silence — this is a normal rotation gap |
| Dark ≥ 15 min | one email, and a reminder every `WATCH_REMIND` (6 h) while it lasts |
| Live again after an alerted outage | one "LIVE again" email |
| Short dark blip that never alerted | silence, and no recovery mail either |
| Channel `UNKNOWN` (both readers failing) | **never** a dark alert |
| `UNKNOWN` ≥ 45 min | one "the watchdog is blind" email — a check that cannot fail is not trusted |
| Host gone **and** channel unreadable ≥ 15 min | treated as an outage, attributed to the host |
| Host absent from the tailnet but channel verified live | silence — the stream is fine |
| Heartbeat stale (older than `WATCH_HEARTBEAT_MAX`) | one "streamer heartbeat stale" email, **even when the channel is `UNKNOWN`**, then a reminder every `WATCH_REMIND`; if the host is also gone it is attributed to the host |
| Heartbeat fresh | silence |
| Heartbeat absent or unset | silence — an unconfigured deployment, and `status`/`once` say so |
| Heartbeat resumes after a silent alert | one "heartbeat is back" email |

An alert is one per episode, then a reminder, never a stream of messages.

If the mail path itself fails, the alert is **spooled to disk and retried** on the next
cycle; it is never dropped. The mail path is how outages get reported, so losing a message
would hide the very thing being watched.

## Why this one may notify

`AGENTS.md` and `docs/operations.md` both state the rule: no notifications, every failure
path retries, nothing may depend on a human noticing. That remains true for the streamer and
is not weakened here. It is simply inapplicable to a dead host, so the notification lives
*outside* the thing whose failures it reports, on a host whose own failure is a different
problem solved by different means (a real server, not a laptop).

## Deploying it

It needs an always-on host that can see the tailnet and reach YouTube. The Intel VPS is the
current home; a Mac mini node works too.

```bash
# Linux (systemd) — the current deployment
sudo ./bin/watchdog-install.sh                # install, seed config, do not start
sudo vi /var/ytlive-watchdog/conf/watchdog.env   # set WATCH_SMTP_PASS (Gmail app password)
/var/ytlive-watchdog/bin/yt_watchdog.py test-alert   # prove the alert path works
sudo systemctl enable --now ytlive-watchdog

# macOS (launchd) — fallback
./bin/watchdog-install.sh --start
```

The service must **not** be started before `test-alert` succeeds. A running watchdog whose
alerts silently fail is worse than no watchdog, for the same reason `install.sh` refuses to
start the streamer until it is safe.

### What the installer guarantees

It has been run on the real host, and each of these is a bug it had first (2026-09-19):

- **It is POSIX `sh`, not zsh.** The watchdog host is usually Linux and Debian ships no zsh; the
  zsh version died there with `cannot execute: required file not found` (exit 127).
- **It never picks the macOS system python.** `/usr/bin/python3` is the Xcode Command Line Tools
  build — measured at 3.9.6, against 3.14.7 in `/opt/homebrew/bin` — and choosing by PATH order is
  what broke the 2026-09-17 deploy. The newest interpreter wins; `WATCHDOG_PY_SEARCH` overrides
  the search list.
- **It gives the job a `PATH`.** A launchd job gets `/usr/bin:/bin:/usr/sbin:/sbin` (`launchctl
  getenv PATH` is unset), and `yt-dlp` normally lives in `~/.local/bin`. Without this the watchdog
  would start and then report `UNKNOWN` forever — indistinguishable from a dark channel, and the
  worst possible failure for the thing whose job is to notice one. `WATCHDOG_EXTRA_PATH` prepends
  a directory.
- **It will not `--start` when `yt-dlp` is invisible to the job**, for the same reason.
- **`--dry-run`** resolves the interpreter, the job `PATH` and both tools, and writes nothing. Run
  it on a live host before reinstalling anything.
- **A failed render cannot damage the live unit.** The unit is rendered to a temp file, checked
  non-empty, and only then moved into place; the template is resolved *before* anything is
  written. The first version did `sed > $UNIT`, which truncated the destination before `sed` even
  ran — a missing template zeroed the installed unit and systemd reported it as **masked**,
  silently removing the watchdog's boot survival.
- **Re-running it is safe**, including from the installed copy: it skips copying the program onto
  itself and keeps an existing `conf/watchdog.env` (which holds the mail secret) untouched.

### Email delivery

Gmail enforces SPF or DKIM on every sender. Unauthenticated direct-to-MX from a VPS is
rejected — verified here on 2026-09-18 as `550 5.7.26 "the sender is unauthenticated"`, and
over IPv6 as a PTR complaint. The supported path is **submission with an app password**:

```
WATCH_SMTP_HOST="smtp.gmail.com"
WATCH_SMTP_PORT="587"          # STARTTLS
WATCH_SMTP_USER="0xa0b1@gmail.com"
WATCH_SMTP_PASS="<16-char app password>"   # myaccount.google.com/apppasswords
```

`conf/watchdog.env` holds that secret, is `chmod 600`, and is gitignored.

### The heartbeat (dead-man signal)

`WATCH_HEARTBEAT` names a file on the **watchdog host**; `bin/yt_heartbeat.py serve` writes it
on every accepted push from the streamer. If the file exists but its modification time is older
than `WATCH_HEARTBEAT_MAX` (default 900 s = 15 min), the application itself is presumed silent
and that is reported — independently of the channel read, and *even while the channel read is
`UNKNOWN`*. That is the point: it is the one signal that does not depend on YouTube, on
`yt-dlp`, or on the channel page at all.

Three honest limits:

- **The file's contents are ignored; only its mtime matters.** The watchdog only stats it. The
  body is stored so a human debugging a stale heartbeat can see what the streamer thought was
  true when it last pushed, and for no other reason.
- **An absent file is not an outage.** `WATCH_HEARTBEAT=""` (the shipped default) disables the
  signal, and a configured path whose file has never appeared is reported as `absent` and
  never pages. Otherwise every host that had not wired the delivery up would alarm forever,
  and "the heartbeat is missing" would be indistinguishable from "someone unset it".
- **Once `WATCH_HEARTBEAT` is set, a dead listener is an alarm.** If `ytlive-heartbeat` stops,
  the file stops being written, goes stale and the watchdog reports "the streamer's application
  has gone silent" — for a streamer that may be perfectly healthy. The alarm is *real* (the file
  really is stale); it is just not the outage it looks like. That is the price of a signal whose
  failure mode is "no news", and it is why the unit restarts immediately and logs to the journal.

#### The transport: the streamer PUSHES

The operator chose **push** over pull (tracker row T-34). It is implemented by `bin/yt_heartbeat.py`,
which contains both halves so the wire format has exactly one implementation:

- **`yt_heartbeat.py push`** runs on the streamer, started by `bin/stream.sh` beside the network
  watchdog. It POSTs a small JSON document to the listener and repeats every
  `HEARTBEAT_INTERVAL` (default 300 s). It is **opt-in**: `HEARTBEAT_URL=""` (the shipped
  default) means no pusher and no heartbeat. That default is deliberate — a heartbeat that is
  configured but never delivered would page a human about a healthy streamer, while an absent
  file is deliberately silent, so an unconfigured install is safe.
- **`yt_heartbeat.py serve`** runs on the watchdog host as `conf/ytlive-heartbeat.service`. It
  accepts `POST /heartbeat` with `Authorization: Bearer <token>`, compares the token with
  `hmac.compare_digest`, caps the body at 8 KB, and writes the body atomically
  (`mkstemp` + `os.replace`, mode 0600) to the state file. Wrong or missing token is 401, another
  path is 404, another method is 405, an oversized body is 413. Every accept and every rejection
  is one journal line naming the remote address — never the body, never the token.

The token is a shared secret in a **mode 600 file** on each side: `conf/heartbeat.token` on the
streamer (`HEARTBEAT_TOKEN_FILE`) and `/var/ytlive-watchdog/conf/heartbeat.token` on the watchdog
host (`HEARTBEAT_TOKEN_FILE` in `conf/watchdog.env`). It is **never** passed on a command line:
argv is world-readable through `ps`, which is the same rule the camera credentials follow, so
`stream.sh` passes the *path*. The listener binds the **tailnet address only**
(`HEARTBEAT_BIND="100.99.149.11"`, never `0.0.0.0`); WireGuard already encrypts the tailnet, so
plain HTTP is correct here and TLS would be ceremony.

**Why push and not pull.** The direction is the whole security argument. This host holds the
Gmail app password and the streamer holds a YouTube OAuth refresh token, so a pull — the watchdog
host reaching into the streamer — would let a compromised watchdog host touch the streamer's
credentials as well; tracker row T-23 is about exactly that. With push, the streamer is the only
side that initiates: it can post a status and nothing more, and the watchdog host never dials it.

Two honest limits of the transport:

- **An unreachable VPS means the heartbeat goes stale and the watchdog alerts.** That is the
  *intended* failure direction: silence from the streamer is reported rather than hidden. It
  does mean a VPS outage or a firewall mistake pages a human about a healthy stream, so the
  alert text says "heartbeat stale", not "channel dark", and the channel/host signals are
  checked independently.
- **The listener is one more process to keep running.** It must be enabled at boot
  (`systemctl enable --now ytlive-heartbeat`) or the heartbeat dies with the first reboot. The
  unit restarts on exit and the `[Install]` section is required, for the same reason
  `ytlive-watchdog.service` documents: without it systemd reports the unit as `static` and
  creates no boot symlink.

The wire format (JSON body; every field degrades to `null` rather than raising):

| Field | Type | Meaning |
|---|---|---|
| `ts` | int | epoch seconds when the payload was built |
| `host` | str | the streamer's hostname |
| `uptime_s` | int / null | seconds since boot |
| `disk_free_mb` | int / null | free MB on the volume holding the checkout |
| `publisher` | bool | `log/publisher.pid` is alive **and** its command is `ffmpeg` + `rtmp` |
| `publisher_pid` | int / null | that pid, so a mismatch is visible |
| `net_state` | str / null | first two fields of `log/net_state` (`"<state> <epoch>"`) |
| `broadcast` | str / null | first field of `log/broadcast_started` (the broadcast id) |

The listener does not parse the body — the watchdog only reads the mtime — so there is nothing
to execute and nothing to forge beyond the token.

## Operating it

```bash
bin/yt_watchdog.py status        # one page: all three signals, thresholds, last alert
bin/yt_watchdog.py once          # one check as JSON; exit 0 live / 1 dark / 2 unknown
bin/yt_watchdog.py test-alert    # send a test message through the real transport
journalctl -u ytlive-watchdog -f # the loop's own log (Linux)
```

State lives in `WATCH_STATE_DIR` (`state.json`, `watchdog.log`, `spool.jsonl`, `alerts/`) and
is written atomically, so a killed watchdog cannot corrupt its memory of an ongoing outage.
`once` and `run` share it: running `once` by hand does not reset an active episode.

## Configuration

See `conf/watchdog.env.example` for the annotated list. `WATCH_CHANNEL` falls back to
`YT_CHANNEL`, so the handle is declared once in spirit even though this runs on another host.
It accepts either an `@handle` or a raw `UC...` channel id; `WATCH_HTTP_URL` overrides the
page the direct reader fetches (used by the tests with a `file://` fixture, so they open no
socket).

| Knob | Default | Meaning |
|---|---|---|
| `WATCH_HTTP` | `1` | Second channel reader (plain HTTPS, no yt-dlp). `0` falls back to yt-dlp alone. |
| `WATCH_HTTP_TIMEOUT` | `15` | Seconds before the direct read gives up and reports `unknown`. |
| `WATCH_HTTP_URL` | _(derived)_ | Optional override of the page the direct reader fetches. |
| `WATCH_HEARTBEAT` | `""` | Path to the app's heartbeat file. Empty = disabled. |
| `WATCH_HEARTBEAT_MAX` | `900` | A heartbeat older than this is stale and pages. |
| `HEARTBEAT_BIND` | `100.99.149.11` | Listener bind address (`yt_heartbeat.py serve`). Tailnet only, never `0.0.0.0`. |
| `HEARTBEAT_PORT` | `8787` | Listener port. Check it is free with `ss -ltn` before starting. |
| `HEARTBEAT_STATE_FILE` | `/var/ytlive-watchdog/heartbeat` | File the listener writes; should match `WATCH_HEARTBEAT`. |
| `HEARTBEAT_TOKEN_FILE` | `/var/ytlive-watchdog/conf/heartbeat.token` | Mode 600 bearer token (serve side). |

On the streamer, `conf/stream.env` declares `HEARTBEAT_URL` (empty = off), `HEARTBEAT_TOKEN_FILE`
(mode 600) and the internal `HEARTBEAT_INTERVAL` (default 300 s).

## Deploying the listener

The watchdog installer installs `bin/yt_watchdog.py` only; the heartbeat listener is a separate
unit and is installed by hand (tracker row T-34 still has this open — see below):

```bash
sudo install -m 755 bin/yt_heartbeat.py /var/ytlive-watchdog/bin/yt_heartbeat.py
sudo install -m 644 conf/ytlive-heartbeat.service /etc/systemd/system/ytlive-heartbeat.service
# one shared secret, mode 600 on each host:
sudo sh -c 'openssl rand -hex 24 > /var/ytlive-watchdog/conf/heartbeat.token'
sudo chmod 600 /var/ytlive-watchdog/conf/heartbeat.token
ss -ltn | grep 8787                      # must be empty first
sudo systemctl daemon-reload
sudo systemctl enable --now ytlive-heartbeat
journalctl -u ytlive-heartbeat -f        # "listening on 100.99.149.11:8787"
```

Then arm both sides. On the watchdog host, uncomment `WATCH_HEARTBEAT` in
`/var/ytlive-watchdog/conf/watchdog.env` and point it at the same path as `HEARTBEAT_STATE_FILE`
(the template ships it empty so a fresh clone cannot page anyone), then
`sudo systemctl restart ytlive-watchdog`. On the streamer, copy the same token to
`conf/heartbeat.token` (mode 600), set `HEARTBEAT_URL="http://100.99.149.11:8787/heartbeat"` in
`conf/stream.env`, and restart the streamer. The push side is on when the streamer's log says
`heartbeat: dead-man signal ON`; the receive side is on when
`journalctl -u ytlive-heartbeat` shows `accept … bytes from 100.x`. Only then is the dead-man
signal actually covered end to end — the watchdog must not be armed before the pushes arrive.

## Known limits

- It watches **that the stream is up**, not that the picture is any good — that is
  `bin/yt_check.py` with the golden reference, on the streamer.
- It cannot *fix* anything. It reports. Recovery still needs the streamer.
- A watch host that loses its own network reports `UNKNOWN` and, after
  `WATCH_BLIND_GRACE`, says so rather than inventing an outage.
- If `yt-dlp` is stale or missing, the direct HTTPS reader keeps the channel signal alive, and
  the host signal is unaffected. `watchdog-install.sh` still warns when `yt-dlp` is absent.
- The direct reader trusts the channel page's own `"isLiveNow"` flag. A page that changes its
  markup, or that is served as a consent/bot wall, degrades to `UNKNOWN` (never offline); if a
  future layout ever embedded a *recommended* live video's flag on an offline channel page it
  could read `live`, which is why the yt-dlp reader is kept rather than replaced.
- **The heartbeat listener is installed by hand.** `bin/watchdog-install.sh` copies only
  `yt_watchdog.py` and renders only `ytlive-watchdog.service`; teaching it about the heartbeat
  is not done here. Until an operator runs the four commands above, `WATCH_HEARTBEAT` should
  stay empty — the watchdog will not pretend an absent file is an outage, but it also cannot
  report an app that goes quiet unless something is writing the file.
- **A dead listener looks like a dead streamer.** If `ytlive-heartbeat` crashes and is not
  restarted, the heartbeat goes stale and the watchdog pages "the streamer's application has
  gone silent". The alert is true about the file and wrong about the streamer; the journal of
  `ytlive-heartbeat` is where to look first.
