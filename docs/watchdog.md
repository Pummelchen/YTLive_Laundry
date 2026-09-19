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

`WATCH_HEARTBEAT` names a file on the **watchdog host**; the streaming application touches it
on every successful loop. If the file exists but its modification time is older than
`WATCH_HEARTBEAT_MAX` (default 900 s = 15 min), the application itself is presumed silent and
that is reported — independently of the channel read, and *even while the channel read is
`UNKNOWN`*. That is the point: it is the one signal that does not depend on YouTube, on
`yt-dlp`, or on the channel page at all.

Two honest limits:

- **The file's contents are ignored; only its mtime matters.** There is nothing to parse and
  nothing to forge beyond a `touch`.
- **An absent file is not an outage.** `WATCH_HEARTBEAT=""` (the shipped default) disables the
  signal, and a configured path whose file has never appeared is reported as `absent` and
  never pages. Otherwise every host that had not wired the delivery up would alarm forever,
  and "the heartbeat is missing" would be indistinguishable from "someone unset it".

**Delivery is not implemented here.** Something has to carry a tick from the streamer to the
watchdog host. There are exactly two reasonable shapes, and neither exists in this repository
yet:

1. **Push** — a small authenticated HTTP endpoint on the watchdog host that the streamer
   `PUT`s to on each loop; the endpoint touches the file. Needs a listener and a shared
   secret, and the listener becomes a new thing to secure.
2. **Pull** — a restricted SSH pull from the watchdog host on an `authorized_keys` entry with
   a forced command that does nothing but `touch <the heartbeat file>` (plus
   `no-port-forwarding`, `no-pty`). No listener and no shared secret beyond the key, but it
   needs the watchdog host to hold a key the streamer accepts, in the reverse of the usual
   direction.

Whichever is chosen, the watchdog side is already finished: point `WATCH_HEARTBEAT` at the
file and it will notice when the ticks stop.

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
- **The heartbeat needs a delivery mechanism that does not exist here yet** (a push endpoint
  or a restricted SSH pull, see above). Until it does, leave `WATCH_HEARTBEAT` empty; the
  watchdog will not pretend an absent file is an outage, but it also cannot report an app
  that goes quiet unless something is writing the file.
