# The external watchdog

`bin/yt_watchdog.py` watches the channel from **outside** the streamer and emails a human
when it goes dark. It is the only component in this repository that does not run on the
streaming Mac, and the only one allowed to notify anyone.

## Why it exists

On **2026-09-18** the streamer dropped off the network at `10:19:54Z`, 5 h 14 m into an
8 h 03 m segment. The publisher's own watchdog, the monitor, `stream.sh`'s retry loops and
launchd's `KeepAlive` all behaved correctly and all were useless, because the machine itself
was gone: a process that is not running cannot retry, and launchd cannot revive a Mac that is
asleep or powered off. The channel stayed dark for **10 h 23 m** and nothing said anything —
by design, since the rule here was "no notifications; every failure path retries".

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
| Time dark before anyone acted | 10 h 23 m |

The healthy numbers matter as much as the failure: a rig in perfect order is dark for about
five minutes every eight hours, so any alert threshold has to sit well above that.

## What it watches — two independent signals

1. **The channel**, via `yt-dlp`, which is the ground truth for "is the stream up". The
   `live` / `offline` / `unknown` split and the `OFFLINE_SIGNS` phrase list are copied from
   `bin/yt_check.py` on purpose: `UNKNOWN` means *the lookup failed*, never *the channel is
   dark*, so a yt-dlp rate limit cannot page anyone. Keep the two lists in step.
2. **The streamer host**, via `tailscale status --json`. This is what turns "dark" into a
   diagnosis — host gone means power or network; host up means publisher, token or camera —
   and it cannot be blinded by a YouTube change the way `yt-dlp` can.

Neither is trusted alone. The channel decides *whether* to alert; the host decides *how to
describe it* and covers the case where the lookup is failing at the same time.

## Alert policy

| Situation | Behaviour |
|---|---|
| Channel live | silence, every episode cleared |
| Dark < `WATCH_DARK_GRACE` (15 min) | silence — this is a normal rotation gap |
| Dark ≥ 15 min | one email, and a reminder every `WATCH_REMIND` (6 h) while it lasts |
| Live again after an alerted outage | one "LIVE again" email |
| Short dark blip that never alerted | silence, and no recovery mail either |
| Channel `UNKNOWN` (yt-dlp failing) | **never** a dark alert |
| `UNKNOWN` ≥ 45 min | one "the watchdog is blind" email — a check that cannot fail is not trusted |
| Host gone **and** channel unreadable ≥ 15 min | treated as an outage, attributed to the host |
| Host absent from the tailnet but channel verified live | silence — the stream is fine |

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

## Operating it

```bash
bin/yt_watchdog.py status        # one page: both signals, thresholds, last alert
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

## Known limits

- It watches **that the stream is up**, not that the picture is any good — that is
  `bin/yt_check.py` with the golden reference, on the streamer.
- It cannot *fix* anything. It reports. Recovery still needs the streamer.
- A watch host that loses its own network reports `UNKNOWN` and, after
  `WATCH_BLIND_GRACE`, says so rather than inventing an outage.
- If `yt-dlp` is stale or missing, the channel signal degrades to `UNKNOWN`; the host signal
  keeps working, which is the point of having two. `watchdog-install.sh` warns when `yt-dlp`
  is absent.
