#!/usr/bin/env python3
"""Watch the channel from OUTSIDE the streamer, and say so out loud when it goes dark.

WHY THIS EXISTS (2026-09-18 outage)
-----------------------------------
Every other program in bin/ runs ON the streamer and assumes the streamer is alive. On
2026-09-18 at 10:19:54Z the streamer MacBook dropped off the network mid-segment because it
lost its transport - DNS and its own LAN - while it stayed awake and kept logging. The
publisher's own watchdog could not help: every retry in it was an application-layer retry
that never touched the network interface. The channel stayed dark for ~19h26m and *nothing
on the streamer said anything*, because the design rule was "no notifications - every failure
path retries".

That rule is right for failures the streamer can retry, and helpless for the one class it
cannot: the host itself. This script closes exactly that hole. It is the only component in
this repository designed to run OFF the streamer, on an always-on host, and it is allowed
to notify a human because no amount of retrying on a dead box will ever fix a dead box.

WHAT IT WATCHES - independent signals
-------------------------------------
1. The channel, TWICE. First via yt-dlp, the ground truth for "is the stream up"; the
   live/offline/unknown split and the OFFLINE_SIGNS phrase list are deliberately the same
   as bin/yt_check.py's: UNKNOWN (the lookup failed) is never evidence that the channel is
   dark, because a yt-dlp rate limit must not become a false alarm any more than it may
   become a false rotation. Second, and independently, via a plain HTTPS GET of the public
   /live page with urllib - no yt-dlp, no cookies, no API key.
   WHY THE SECOND READER (2026-09-19): during the recovery yt-dlp was rate-limited and
   returned "unknown" for hours, so the watchdog's ONLY channel signal went blind exactly
   when it mattered. It raised two "blind" alerts, and its "channel is LIVE again" mail
   arrived 5 h 21 m after the channel had actually recovered, because the recovery could not
   be seen until yt-dlp answered again. A second reader over a different transport means one
   rate-limited tool can no longer blind the watchdog on its own.
2. The streamer host, via `tailscale status --json`. This catches the 2026-09-18 class the
   channel check alone cannot describe, and it cannot be blinded by a YouTube change the
   way yt-dlp can.
3. The streamer application's heartbeat, if a file is configured (WATCH_HEARTBEAT). Its
   modification time going stale is positive evidence that the app has gone silent, which
   is a different failure from "the channel is dark" and the channel read cannot always
   describe it. A heartbeat that is absent is treated as an unconfigured deployment, never
   as an outage: a watchdog must not page someone for a signal nobody wired up.

None of them is trusted alone. The channel is what gets alerted on; the host presence
turns "dark" into a diagnosis (host gone = power/network; host up = publisher, token or
camera) and covers the case where the lookup itself is failing at the same time.

ROTATION GAPS ARE EXPECTED
---------------------------
A healthy rig is dark for ~5 minutes every 8h03m while the broadcast is cut and the
successor is bound. Measured across 2026-09-16..18: 8.05 h segments, 4.5-5.2 min gaps. So
the alert threshold must sit comfortably above that; WATCH_DARK_GRACE defaults to 15 min.

USAGE
-----
    yt_watchdog.py once            one check, prints JSON, exit 0 live / 1 dark / 2 unknown
    yt_watchdog.py run             the loop (default); alerts on transitions
    yt_watchdog.py status          one human-readable page, no network beyond a check
    yt_watchdog.py test-alert      send a test message through the configured transport

Configuration comes from the environment, with an optional env file
(conf/watchdog.env, or $WATCHDOG_ENV) loaded first; real environment variables win, so a
systemd EnvironmentFile or a shell can both drive it. See conf/watchdog.env.example.

Python 3.8+, standard library only - deliberately, so it runs unchanged on the Linux
watchdog host and on a Mac. It never writes into the repository: state, logs and the
undeliverable-alert spool all live outside it.
"""
import json
import os
import pathlib
import re
import smtplib
import subprocess
import sys
import time
import urllib.request
from datetime import datetime
from email.message import EmailMessage
from email.utils import formatdate, make_msgid

# --- the same phrase list as bin/yt_check.py: keep the two in step ---------------------
# Phrases YouTube/yt-dlp use when the channel is genuinely not streaming. Anything else
# that goes wrong is a failure of the LOOKUP, not evidence about the channel.
OFFLINE_SIGNS = ("not currently live", "does not have a live", "is not live",
                 "not currently streaming", "this live event will begin",
                 "the channel is not currently live")

# The public channel page carries this JSON flag: true while the channel is broadcasting,
# false when it is not. Verified by hand against the live shop channel on 2026-09-19, and it
# is the whole reason the second reader can exist without yt-dlp. Whitespace is stripped from
# the body before the search so a reformatted "isLiveNow": true still matches; anything else
# (a consent wall, a bot check, a markup change) is UNKNOWN, never offline.
LIVE_MARKER = '"isLiveNow":true'
DARK_MARKER = '"isLiveNow":false'

# A page this size is already far past the marker; the cap keeps a pathological response from
# pulling all of memory into a watchdog that has to stay small.
HTTP_MAX_BYTES = 2_000_000
HTTP_UA = ("Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) "
           "Chrome/124.0 Safari/537.36")

DEFAULTS = {
    "WATCH_CHANNEL": "",            # "@handle" or a UC... channel id; YT_CHANNEL is a fallback
    "WATCH_HOST": "",               # Tailscale peer name, e.g. "ternak-macbook"
    "WATCH_INTERVAL": "60",
    "WATCH_DARK_GRACE": "900",      # 15 min: comfortably above the ~5 min rotation gap
    "WATCH_HOST_LOST_GRACE": "900",  # host gone + channel unverifiable -> outage
    "WATCH_BLIND_GRACE": "2700",    # 45 min unable to see the channel -> warn anyway
    "WATCH_REMIND": "21600",        # repeat an unresolved alert every 6 h
    "WATCH_HEARTBEAT": "",          # path to a file the streamer app touches; empty = disabled
    "WATCH_HEARTBEAT_MAX": "900",   # 15 min without a touch -> the app is silent
    "WATCH_DISK_MIN_MB": "2000",    # the streamer's push carries free MB; below this -> alert.
                                    # 0 disables. Chosen above stream.sh's DISK_LOW_MB (1000), so
                                    # the repair runs first and this fires only if it cannot keep up.
    "WATCH_HTTP": "1",              # second channel reader (direct HTTPS) on by default
    "WATCH_HTTP_URL": "",           # optional override; default derives from WATCH_CHANNEL
    "WATCH_HTTP_TIMEOUT": "15",     # short: the loop must not stall on a hanging page
    "WATCH_TZ_OFFSET": "7",         # shop time, WIB
    "WATCH_TZ_LABEL": "WIB",
    "WATCH_ALERT_MODE": "smtp",     # smtp | file | stdout
    "WATCH_ALERT_TO": "",
    "WATCH_ALERT_FROM": "",
    "WATCH_ALERT_DIR": "",
    "WATCH_SMTP_HOST": "smtp.gmail.com",
    "WATCH_SMTP_PORT": "587",
    "WATCH_SMTP_USER": "",
    "WATCH_SMTP_PASS": "",
    "WATCH_YTDLP": "yt-dlp",
    "WATCH_TAILSCALE": "tailscale",
    "WATCH_YTDLP_TIMEOUT": "90",
    "WATCH_STATE": "",
    "WATCH_LOG": "",
    "WATCH_SPOOL": "",
}


class Cfg:
    """Configuration resolved from an optional env file plus the real environment."""

    def __init__(self, env):
        self._v = dict(DEFAULTS)
        self._v.update({k: v for k, v in env.items() if v is not None})
        # YT_CHANNEL is the streamer's name for the same fact; accept it so the handle is
        # declared once in spirit even though this runs on another host.
        if not self._v.get("WATCH_CHANNEL"):
            self._v["WATCH_CHANNEL"] = env.get("YT_CHANNEL", "") or ""
        if not self._v.get("WATCH_ALERT_FROM"):
            self._v["WATCH_ALERT_FROM"] = self._v.get("WATCH_SMTP_USER", "")
        # Everything that writes defaults to a directory this script owns, never the repo.
        # Note: these keys exist in DEFAULTS as "", so plain setdefault() would keep the
        # empty string - assign only when the resolved value is actually empty.
        base = pathlib.Path(self._v.get("WATCH_STATE_DIR") or "/var/lib/ytlive-watchdog")
        for key, leaf in (("WATCH_STATE", "state.json"), ("WATCH_LOG", "watchdog.log"),
                          ("WATCH_SPOOL", "spool.jsonl"), ("WATCH_ALERT_DIR", "alerts")):
            if not str(self._v.get(key) or "").strip():
                self._v[key] = str(base / leaf)

    def __getitem__(self, k):
        v = self._v.get(k, "")
        return v

    def num(self, k):
        try:
            return int(str(self._v.get(k, DEFAULTS.get(k, "0"))).strip())
        except (TypeError, ValueError):
            return int(DEFAULTS.get(k, "0"))

    def flag(self, k):
        """Truthy for anything except "", "0", "no", "off", "false" - so a knob can be turned
        off in an env file without the parser needing a boolean type."""
        raw = str(self._v.get(k, DEFAULTS.get(k, ""))).strip().lower()
        return raw not in ("", "0", "no", "off", "false")

    @property
    def channel_url(self):
        h = self["WATCH_CHANNEL"].strip()
        if not h:
            return ""
        # A raw UC... id is a channel URL in its own right; prefixing "@" would make
        # "youtube.com/@UC..." which YouTube does not serve. Handles keep the @ form.
        if re.fullmatch(r"UC[\w-]{22}", h):
            return f"https://www.youtube.com/channel/{h}/live"
        if not h.startswith("@"):
            h = "@" + h
        return f"https://www.youtube.com/{h}/live"

    @property
    def http_url(self):
        """The URL the direct reader fetches. WATCH_HTTP_URL overrides the derived one so the
        reader can be pointed at a test fixture (or a proxy) without touching the channel."""
        return (self["WATCH_HTTP_URL"] or "").strip() or self.channel_url


def load_env_file(path):
    """KEY=VALUE with # comments, the shape conf/stream.env already has.

    Loaded BEFORE the real environment, so the environment wins and one file can serve as
    the shipped default without overriding an operator's explicit override.
    """
    out = {}
    p = pathlib.Path(path)
    if not p.is_file():
        return out
    for raw in p.read_text(errors="replace").splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("export "):
            line = line[len("export "):].lstrip()
        if "=" not in line:
            continue
        k, _, v = line.partition("=")
        k = k.strip()
        v = v.strip()
        if len(v) >= 2 and v[0] == v[-1] and v[0] in "\"'":
            v = v[1:-1]
        if k:
            out[k] = v
    return out


def build_cfg(argv_env=None):
    env = dict(os.environ if argv_env is None else argv_env)
    candidates = []
    if env.get("WATCHDOG_ENV"):
        candidates.append(env["WATCHDOG_ENV"])
    if env.get("BASE"):
        candidates.append(str(pathlib.Path(env["BASE"]) / "conf/watchdog.env"))
    candidates.append(str(pathlib.Path(__file__).resolve().parent.parent / "conf/watchdog.env"))
    file_env = {}
    for c in candidates:
        file_env = load_env_file(c)
        if file_env:
            break
    merged = dict(file_env)
    merged.update(env)          # the real environment wins
    return Cfg(merged)


# --------------------------------------------------------------------------------------
# Signals
# --------------------------------------------------------------------------------------
def channel_state(cfg):
    """(video_id, state) with state in {"live", "offline", "unknown"}.

    Mirrors bin/yt_check.py:live_info() on purpose. The distinction that matters most is
    that "unknown" is NOT evidence about the channel - it is evidence about yt-dlp.
    """
    url = cfg.channel_url
    if not url:
        return None, "unknown"
    try:
        r = subprocess.run([cfg["WATCH_YTDLP"], "--no-warnings", "--skip-download",
                            "--print", "%(id)s|%(is_live)s", url],
                           capture_output=True, text=True, timeout=cfg.num("WATCH_YTDLP_TIMEOUT"))
    except FileNotFoundError:
        return None, "unknown"
    except subprocess.TimeoutExpired:
        return None, "unknown"
    line = (r.stdout.strip().split("\n") or [""])[0]
    if "|" in line:
        vid, live = line.split("|", 1)
        return vid.strip(), ("live" if live.strip().lower() == "true" else "offline")
    err = (r.stderr or "").lower()
    if any(sign in err for sign in OFFLINE_SIGNS):
        return None, "offline"
    return None, "unknown"


def http_channel_state(cfg):
    """Return "live" | "offline" | "unknown" from the public channel page over plain HTTPS.

    WHY THIS SECOND READER EXISTS: on 2026-09-19 yt-dlp was rate-limited/bot-checked and
    answered "unknown" for hours, which blinded the watchdog at the worst possible moment
    and made its recovery mail 5 h 21 m late. This read shares no code, no credential and no
    rate limit with yt-dlp, so the two fail independently.

    It deliberately reuses the same three-word vocabulary: a 200 page without the marker (a
    consent wall, a bot check, a YouTube markup change) is "unknown", NOT evidence that the
    channel is dark, so it can never page anyone by itself.
    """
    url = cfg.http_url
    if not url:
        return "unknown"
    try:
        req = urllib.request.Request(url, headers={"User-Agent": HTTP_UA})
        with urllib.request.urlopen(req, timeout=cfg.num("WATCH_HTTP_TIMEOUT")) as resp:
            raw = resp.read(HTTP_MAX_BYTES)
        text = raw.decode("utf-8", "replace") if isinstance(raw, (bytes, bytearray)) else str(raw)
    except Exception:                   # DNS, TLS, timeout, 403, bot check: all "not known"
        return "unknown"
    # Collapse whitespace so `"isLiveNow": true` matches too; the page is one huge minified
    # JSON blob in practice, but a reformat must not read as "the lookup failed".
    compact = re.sub(r"\s+", "", text)
    if LIVE_MARKER in compact:
        return "live"
    if DARK_MARKER in compact:
        return "offline"
    return "unknown"


def combine_channel_states(primary, direct):
    """Either reader saying live wins; BOTH saying offline is offline; anything else unknown.

    The asymmetry is the whole point: "live" is only ever positive evidence, so one confirmed
    live read is enough, while a single "offline" is not - one reader failing must not become
    a dark alert. This keeps a yt-dlp rate limit from paging anyone (the pre-existing rule)
    and extends it to a blocked/failed HTTP read.
    """
    if primary == "live" or direct == "live":
        return "live"
    if primary == "offline" and direct == "offline":
        return "offline"
    return "unknown"


def read_channel(cfg):
    """(video_id, state) from both readers, combined as combine_channel_states() describes.

    The video id can only come from yt-dlp; when only the HTTP reader says live it is None.
    WATCH_HTTP=0 falls back to the yt-dlp reader alone, which is what the offline tests use.
    """
    vid, primary = channel_state(cfg)
    if not cfg.flag("WATCH_HTTP"):
        return vid, primary
    return vid, combine_channel_states(primary, http_channel_state(cfg))


def tailscale_last_seen(value):
    """Tailscale's LastSeen, or None when it carries no information.

    A peer that is ONLINE has no last-seen: Tailscale reports Go's zero time
    ("0001-01-01T00:00:00Z") for it, verified on the real tailnet 2026-09-19 (the streamer,
    Node1-4 and MacBook AB all report it while online, while genuinely offline peers carry a
    real timestamp). Formatting that zero time is how the status page came to print
    "last seen 1-01-01T00:00:00Z (1-01-01 07:00 WIB)" for a perfectly healthy streamer - on
    the page an operator reads during an incident. A state with no information is reported as
    no information, never as a date.
    """
    if not value:
        return None
    text = str(value).strip()
    if not text or text.startswith("0001-01-01T00:00:00"):
        return None
    return text


def host_seen_text(host, last_seen, cfg):
    """The parenthetical after the host state: when it was seen, or 'online now'."""
    if last_seen:
        return f"last seen {human_time(last_seen, cfg)}"
    if host == "live":
        return "online now"
    return ""


def host_state(cfg):
    """(state, last_seen) for the streamer in the tailnet: live | down | unknown.

    "unknown" covers a host that is not in this tailnet, or no tailscale at all. It is
    never alerted on by itself: a watchdog on a host that cannot see the tailnet must not
    invent an outage.
    """
    name = cfg["WATCH_HOST"].strip()
    if not name:
        return "unknown", None
    try:
        r = subprocess.run([cfg["WATCH_TAILSCALE"], "status", "--json"],
                           capture_output=True, text=True, timeout=30)
    except (FileNotFoundError, subprocess.TimeoutExpired):
        return "unknown", None
    if r.returncode != 0:
        return "unknown", None
    try:
        data = json.loads(r.stdout or "{}")
    except ValueError:
        return "unknown", None
    for peer in (data.get("Peer") or {}).values():
        host = (peer.get("HostName") or "")
        dns = (peer.get("DNSName") or "").split(".")[0]
        if name.lower() in (host.lower(), dns.lower()):
            seen = tailscale_last_seen(peer.get("LastSeen"))
            if peer.get("Online"):
                return "live", seen
            return "down", seen
    return "unknown", None


def heartbeat_payload(path):
    """The parsed body of the last push, or None.

    The pusher sends a real status document (timestamp, host, uptime, free disk MB, publisher
    liveness, network state, broadcast id), so the freshness check is no longer the only thing
    this file can answer. Every failure - missing, unreadable, not JSON, not an object -
    degrades to None, and a body is only believed while it is FRESH: a stale file is positive
    evidence the app is gone, and its last numbers say nothing about now.
    """
    if not path:
        return None
    try:
        text = pathlib.Path(path).read_text()
    except Exception:
        return None
    try:
        body = json.loads(text)
    except ValueError:
        return None
    return body if isinstance(body, dict) else None


def heartbeat_state(cfg):
    """(state, age_seconds) for the streamer application's heartbeat file.

    fresh    - the file exists and was touched within WATCH_HEARTBEAT_MAX seconds
    stale    - the file exists but is older: positive evidence the app has gone silent
    absent   - WATCH_HEARTBEAT is set but the file is missing; nothing is writing it
    disabled - WATCH_HEARTBEAT is unset: this deployment has no dead-man signal
    unknown  - the file exists but cannot be stat'ed (permissions); never alerts

    The I/O lives here, in the caller's world, so decide() stays a pure function of plain
    values. "absent" is deliberately NOT "stale": an unconfigured deployment must not page
    anyone, which would otherwise be a false alarm on every watchdog host that never wired a
    heartbeat up.
    """
    path = cfg["WATCH_HEARTBEAT"].strip()
    if not path:
        return "disabled", None
    try:
        mtime = pathlib.Path(path).stat().st_mtime
    except FileNotFoundError:
        return "absent", None
    except Exception:
        return "unknown", None
    age = int(max(0, time.time() - mtime))
    if age <= cfg.num("WATCH_HEARTBEAT_MAX"):
        return "fresh", age
    return "stale", age


def disk_state(cfg, heartbeat, payload):
    """The pusher's free-space figure as a plain value for decide(), or None.

    None means "no usable number" - the signal is disabled, the file is absent or unreadable,
    the push is too old to believe, or the body carries no integer disk_free_mb - and every
    one of those must be SILENT rather than guessed at. An old file's number is worse than no
    number: it would page about a disk that may be fine now.
    """
    min_mb = cfg.num("WATCH_DISK_MIN_MB")
    if min_mb <= 0 or heartbeat != "fresh" or not isinstance(payload, dict):
        return None
    free_mb = payload.get("disk_free_mb")
    if not isinstance(free_mb, int) or isinstance(free_mb, bool):
        return None
    return {"free_mb": free_mb, "threshold": min_mb}


# --------------------------------------------------------------------------------------
# State
# --------------------------------------------------------------------------------------
def new_state():
    return {
        "dark_since": None,
        "unknown_since": None,
        "silent_since": None,
        "live_since": None,
        "last_alert_kind": None,
        "last_alert_at": None,
        "last_check_at": None,
        "last_video": None,
        "last_channel_state": None,
        "last_host_state": None,
        "last_heartbeat_state": None,
        "last_heartbeat_age": None,
        "disk": None,               # {"free_mb","min_mb","threshold","since","alerted_at"}
        "last_error": None,
        "checks": 0,
    }


def load_state(path):
    try:
        s = json.loads(pathlib.Path(path).read_text())
        if isinstance(s, dict):
            merged = new_state()
            merged.update(s)
            return merged
    except Exception:
        pass
    return new_state()


def save_state(path, state):
    """Atomic: a watchdog killed mid-write must not corrupt its own memory of an outage."""
    p = pathlib.Path(path)
    p.parent.mkdir(parents=True, exist_ok=True)
    tmp = p.with_suffix(p.suffix + ".tmp")
    tmp.write_text(json.dumps(state, indent=2, sort_keys=True))
    os.replace(str(tmp), str(p))


# --------------------------------------------------------------------------------------
# The decision, as a pure function of (time, state, signals, config)
# --------------------------------------------------------------------------------------
def decide(now, state, channel, host, cfg, heartbeat="disabled", heartbeat_age=None, disk=None):
    """Return (new_state, actions). Pure - no clock, no network, no I/O - so the whole
    alerting policy is testable without waiting 15 minutes or touching YouTube.

    `heartbeat` and `heartbeat_age` are plain values read by the caller (heartbeat_state());
    keeping the file I/O out here is what lets every heartbeat rule below be tested in
    microseconds. "stale" is positive evidence the streamer app is silent; "fresh",
    "absent", "disabled" and "unknown" are not.

    `disk` is {"free_mb", "threshold"} from the same push (disk_state()), or None when there
    is no fresh number. It is a DIFFERENT kind of fact from the three signals above: the
    channel, the host and the app are episodes that end, while free space is a level that
    crosses a line. It therefore reports on its own, under its own episode key, so a full disk
    can never be hidden by - or hide - an unrelated dark/blind/silent alert.
    """
    s = dict(state)
    actions = []
    dark_grace = cfg.num("WATCH_DARK_GRACE")
    host_lost_grace = cfg.num("WATCH_HOST_LOST_GRACE")
    blind_grace = cfg.num("WATCH_BLIND_GRACE")
    remind = cfg.num("WATCH_REMIND")

    s["last_check_at"] = now
    s["checks"] = int(s.get("checks") or 0) + 1
    s["last_channel_state"] = channel
    s["last_host_state"] = host
    s["last_heartbeat_state"] = heartbeat
    s["last_heartbeat_age"] = heartbeat_age

    def due(kind):
        """One alert per episode, then a reminder every `remind` seconds."""
        if s.get("last_alert_kind") != kind:
            return True
        last = s.get("last_alert_at") or 0
        return (now - last) >= remind

    def alert(kind, **extra):
        s["last_alert_kind"] = kind
        s["last_alert_at"] = now
        actions.append(dict(kind=kind, **extra))

    # --- free space: a level, not an episode ------------------------------------------------
    # Reported before the channel rules and independent of the live-channel early return, so
    # a healthy stream on a filling disk is exactly the case that gets reported. Its own
    # `alerted_at` gives one mail per crossing plus WATCH_REMIND reminders; it never touches
    # last_alert_kind, which belongs to the outage story.
    if disk is None:
        prior = s.get("disk")
        if isinstance(prior, dict) and prior.get("since") is not None:
            # The number went away (push stopped, or disk_free_mb became unreadable). That is
            # not a recovery, so no mail - but forget the episode, so a later crossing is new.
            prior = dict(prior)
            prior["since"] = None
            prior["alerted_at"] = None
            s["disk"] = prior
    else:
        free_mb = disk["free_mb"]
        threshold = disk["threshold"]
        prior = s.get("disk") if isinstance(s.get("disk"), dict) else {}
        if free_mb < threshold:
            since = prior.get("since")
            if since is None:
                since = now
            alerted_at = prior.get("alerted_at")
            if alerted_at is None or (now - alerted_at) >= remind:
                s["disk"] = {"free_mb": free_mb, "min_mb": disk.get("min_mb"), "threshold": threshold,
                             "since": since, "alerted_at": now}
                actions.append(dict(kind="disk_low", free_mb=free_mb, threshold=threshold,
                                    low_for=now - since))
            else:
                s["disk"] = {"free_mb": free_mb, "min_mb": disk.get("min_mb"), "threshold": threshold,
                             "since": since, "alerted_at": alerted_at}
        else:
            if isinstance(prior.get("since"), int) and prior["since"] is not None:
                actions.append(dict(kind="disk_recover", free_mb=free_mb, threshold=threshold))
            s["disk"] = {"free_mb": free_mb, "min_mb": disk.get("min_mb"), "threshold": threshold,
                         "since": None, "alerted_at": None}

    if channel == "live":
        s["dark_since"] = None
        s["unknown_since"] = None
        s["silent_since"] = None
        if s.get("live_since") is None:
            s["live_since"] = now
        # Recovery is only worth a mail if we previously cried wolf about this episode.
        prior = s.get("last_alert_kind")
        if prior in ("dark", "blind", "silent"):
            actions.append(dict(kind="recover", of=prior))
        s["last_alert_kind"] = None
        return s, actions

    s["live_since"] = None

    # A stale heartbeat is the dead-man signal: positive evidence the app itself has gone
    # silent. It is reported even while the channel read is UNKNOWN (that is the whole point
    # of a second, independent signal), and it takes precedence over the dark/blind story so
    # the two alert kinds cannot alternate and page twice for one failure. A stale file is
    # already older than WATCH_HEARTBEAT_MAX, so no extra grace is applied here.
    if heartbeat == "stale":
        if s.get("silent_since") is None:
            s["silent_since"] = now
        silent_for = now - s["silent_since"]
        if due("silent"):
            alert("silent", silent_for=silent_for, heartbeat_age=heartbeat_age,
                  host_lost=(host == "down"))
        return s, actions

    # Heartbeat is fresh / absent / disabled / unreadable. A fresh file is proof the app came
    # back; the others only remove the silent evidence, so drop the episode without claiming
    # a recovery the file cannot support. Clearing last_alert_kind either way means a future
    # silent episode alerts immediately rather than waiting out WATCH_REMIND.
    s["silent_since"] = None
    if s.get("last_alert_kind") == "silent":
        if heartbeat == "fresh":
            actions.append(dict(kind="recover", of="silent"))
        s["last_alert_kind"] = None

    if channel == "offline":
        s["unknown_since"] = None
        # Explicit None test, not `or now`: 0 is a legitimate timestamp and `x or now`
        # would treat it as unset (t07 caught this).
        if s.get("dark_since") is None:
            s["dark_since"] = now
        dark_for = now - s["dark_since"]
        if dark_for >= dark_grace and due("dark"):
            alert("dark", dark_for=dark_for)
        return s, actions

    # channel == "unknown": do not invent an outage from a failed lookup. But a failed
    # lookup on top of a host that has been gone for a while is two bad signs, and the
    # 2026-09-18 case looked exactly like that from outside.
    if s.get("unknown_since") is None:
        s["unknown_since"] = now
    unknown_for = now - s["unknown_since"]
    if host == "down" and unknown_for >= host_lost_grace and due("dark"):
        alert("dark", dark_for=unknown_for, host_lost=True)
    elif unknown_for >= blind_grace and due("blind"):
        alert("blind", unknown_for=unknown_for)
    return s, actions


# --------------------------------------------------------------------------------------
# Notifying
# --------------------------------------------------------------------------------------
def log_line(cfg, msg):
    stamp = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    line = f"{stamp} {msg}"
    print(line, flush=True)
    path = cfg["WATCH_LOG"]
    if path:
        try:
            p = pathlib.Path(path)
            p.parent.mkdir(parents=True, exist_ok=True)
            with open(p, "a") as fh:
                fh.write(line + "\n")
        except Exception:
            pass


def parse_epoch(value):
    """Return an epoch for either an epoch or the RFC3339 string Tailscale reports.

    Tailscale's LastSeen is a string like "2026-09-18T10:20:00.1Z"; our own state stores
    epochs. Accepting only one of them crashed `status` on the watchdog host the first time
    it met a real peer, so both are handled here and neither caller has to care.
    """
    if value is None or value == "":
        return None
    if isinstance(value, (int, float)):
        return float(value)
    text = str(value).strip()
    try:
        return float(text)
    except ValueError:
        pass
    cand = text.replace("Z", "+00:00")
    for attempt in (cand, re.sub(r"\.\d+", "", cand)):
        try:
            return datetime.fromisoformat(attempt).timestamp()
        except ValueError:
            continue
    return None


def human_time(value, cfg=None):
    epoch = parse_epoch(value)
    if epoch is None:
        return "never"
    off = cfg.num("WATCH_TZ_OFFSET") if cfg else 0
    label = cfg["WATCH_TZ_LABEL"] if cfg else "UTC"
    utc = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(epoch))
    local = time.strftime("%Y-%m-%d %H:%M", time.gmtime(epoch + off * 3600))
    return f"{utc} ({local} {label})"


def human_duration(seconds):
    if seconds is None:
        return "unknown"
    seconds = int(seconds)
    h, rem = divmod(seconds, 3600)
    m, s = divmod(rem, 60)
    if h:
        return f"{h}h{m:02d}m"
    if m:
        return f"{m}m{s:02d}s"
    return f"{s}s"


def human_heartbeat(state, cfg):
    """One line for status/alert bodies, spelling out why an absent file is not an outage."""
    hb = state.get("last_heartbeat_state")
    age = state.get("last_heartbeat_age")
    limit = human_duration(cfg.num("WATCH_HEARTBEAT_MAX"))
    if hb == "disabled":
        return "disabled (WATCH_HEARTBEAT unset - no dead-man signal)"
    if hb == "absent":
        return "absent (file not written - not alerting; see docs/watchdog.md)"
    if hb == "fresh":
        return f"fresh (last touch {human_duration(age)} ago)"
    if hb == "stale":
        return f"STALE (last touch {human_duration(age)} ago, limit {limit})"
    return "unknown"


def program_version(cfg):
    """The release this install came from, written by watchdog-install.sh, or "unknown".

    This is the answer to "which build is the host actually running?", and it could not be
    asked before 2026-09-19 - when the live host turned out to be running a pre-2.4 watchdog
    whose heartbeat code the deployed release depended on, with no way to see that from the
    outside. A missing file means the install predates the stamp or was made by hand.
    """
    try:
        base = pathlib.Path(cfg["WATCH_STATE_DIR"] or ".")
    except Exception:
        return "unknown"
    for cand in (base / "VERSION", base.parent / "VERSION"):
        try:
            text = cand.read_text().strip()
        except Exception:
            continue
        if text:
            return text
    return "unknown (no stamp - installed before 2.7 or by hand)"


def human_disk(state, cfg):
    """One line for the disk level the streamer's push reports, or why there is none."""
    d = state.get("disk")
    if not isinstance(d, dict) or d.get("free_mb") is None:
        if cfg.num("WATCH_DISK_MIN_MB") <= 0:
            return "disabled (WATCH_DISK_MIN_MB=0)"
        return "unavailable (no fresh push carries disk_free_mb)"
    free = d["free_mb"]
    limit = d.get("threshold") or cfg.num("WATCH_DISK_MIN_MB")
    if isinstance(d.get("since"), int) and d.get("since") is not None:
        return (f"LOW {free:,} MB free, under {limit:,} MB since "
                f"{human_duration(max(0, int(time.time()) - d['since']))}")
    return f"ok {free:,} MB free (alert under {limit:,} MB)"


def compose(action, state, channel, host, host_last_seen, vid, cfg):
    """Subject and body. Written for someone reading it on a phone at 3am: what is wrong,
    since when, whether the box is reachable, and the first thing to do about it."""
    kind = action["kind"]
    where = cfg["WATCH_HOST"] or "the streamer"
    if kind == "dark":
        dark_for = human_duration(action.get("dark_for"))
        if action.get("host_lost"):
            subject = f"[YTLive] DARK + host unreachable ({dark_for})"
            head = (f"The channel has not been verifiable as live for {dark_for}, and "
                    f"{where} has been offline in the tailnet at the same time.")
        else:
            subject = f"[YTLive] channel DARK for {dark_for}"
            head = f"The channel has been dark for {dark_for} (rotation gaps are ~5 min)."
    elif kind == "blind":
        subject = "[YTLive] watchdog is blind - cannot read the channel"
        head = (f"The watchdog has been unable to determine the channel's state for "
                f"{human_duration(action.get('unknown_for'))}. This is a yt-dlp/lookup "
                f"failure, not proof the stream is down - but while it lasts nothing is "
                f"watching.")
    elif kind == "silent":
        # Prefer the file's real age for the headline; silent_for can be 0 on the first check
        # that crosses the limit, and `0 or fallback` would swallow that legitimate value.
        age = action.get("heartbeat_age")
        if age is None:
            age = action.get("silent_for")
        silent_for = human_duration(age)
        if action.get("host_lost"):
            subject = f"[YTLive] streamer SILENT + host unreachable ({silent_for})"
            head = (f"The streamer's heartbeat file has not been touched for {silent_for}, "
                    f"and {where} is offline in the tailnet at the same time. The streaming "
                    f"application looks dead, not merely unpublishable.")
        else:
            subject = f"[YTLive] streamer heartbeat stale ({silent_for})"
            head = (f"The streamer's heartbeat file has not been touched for {silent_for} "
                    f"(limit {human_duration(cfg.num('WATCH_HEARTBEAT_MAX'))}). That is the "
                    f"application itself, not the channel: it may be hung, still running but "
                    f"no longer publishing, or the machine may be gone.")
    elif action.get("of") == "silent":
        subject = "[YTLive] streamer heartbeat is back"
        head = "The streamer's heartbeat file is being updated again; the app is alive."
    elif kind == "disk_low":
        free = action.get("free_mb")
        limit = action.get("threshold")
        subject = f"[YTLive] streamer disk low ({free:,} MB free)"
        head = (f"{where} has {free:,} MB free, under the {limit:,} MB floor"
                + (f", and has been for {human_duration(action.get('low_for'))}"
                   if action.get("low_for") else "")
                + ". The streamer's own housekeep drops quarter-sized logs and the regenerable "
                  "caches below DISK_LOW_MB, so reaching this floor means that was not enough: "
                  "recordings, deploy backups and the git tree are what is left, and $HOME "
                  "filling up also kills the next rotation's ffmpeg.")
    elif kind == "disk_recover":
        subject = "[YTLive] streamer disk is back above the floor"
        head = (f"{where} reports {action.get('free_mb'):,} MB free again, above the "
                f"{action.get('threshold'):,} MB floor. Nothing to do unless it repeats - if it "
                f"does, the growth is faster than housekeep, and the deploy backups in $HOME are "
                f"the first thing to delete.")
    else:
        subject = "[YTLive] channel is LIVE again"
        head = "The channel is live again; the outage is over."

    seen = host_seen_text(host, host_last_seen, cfg)
    lines = [
        head,
        "",
        f"channel state : {channel}",
        f"host state    : {host}" + (f" ({seen})" if seen else ""),
        f"heartbeat     : {human_heartbeat(state, cfg)}",
        f"disk          : {human_disk(state, cfg)}",
        f"video id      : {vid or 'none'}",
        f"now           : {human_time(time.time(), cfg)}",
    ]
    if state.get("dark_since") and kind == "dark":
        lines.append(f"dark since    : {human_time(state['dark_since'], cfg)}")
    if state.get("live_since"):
        lines.append(f"live since    : {human_time(state['live_since'], cfg)}")
    lines += [
        "",
        "Where the stream stands",
        "  The streamer is a single MacBook at the shop; the publisher's watchdog can only",
        "  retry while that machine is running. If it is off, asleep or off the network,",
        "  nothing on it can help and someone has to go and wake it.",
        "",
        "First checks",
        f"  1. Is {where} powered and awake? (lid, charger, power strip, macOS sleep)",
        "  2. Is the shop's internet up? (router lights; the uplink answered ICMP on 09-18)",
        "  3. If it is up: ssh in and run  bin/status.sh  then  bin/smoke_test.sh",
        "     before restarting anything.",
        "  4. Then check conf/yt_oauth.json is still valid:  bin/yt_api.py token",
        "",
        "Known cause of the 2026-09-18 outage: the streamer lost its transport (DNS and its",
        "own LAN) while it stayed awake and logging; it was dark ~19h26m. docs/known-issues.md",
        "records the pmset hardening for the separate power class: sudo pmset -c sleep 0",
        "disablesleep 1  (plus autorestart after power loss).",
        "",
        f"-- {cfg['WATCH_HOST'] or 'ytlive'} watchdog on {os.uname().nodename}",
    ]
    return subject, "\n".join(lines)


def default_message(cfg, subject, body):
    msg = EmailMessage()
    msg["From"] = cfg["WATCH_ALERT_FROM"] or cfg["WATCH_SMTP_USER"]
    msg["To"] = cfg["WATCH_ALERT_TO"]
    msg["Subject"] = subject
    # Gmail rejects mail without a valid Message-ID (RFC 5322) - learned the hard way.
    msg["Message-ID"] = make_msgid()
    msg["Date"] = formatdate(localtime=True)
    msg["Auto-Submitted"] = "auto-generated"
    msg.set_content(body)
    return msg


def deliver_smtp(cfg, msg):
    host = cfg["WATCH_SMTP_HOST"]
    port = cfg.num("WATCH_SMTP_PORT")
    user = cfg["WATCH_SMTP_USER"]
    password = cfg["WATCH_SMTP_PASS"]
    if not host or not cfg["WATCH_ALERT_TO"]:
        raise RuntimeError("WATCH_SMTP_HOST and WATCH_ALERT_TO are required for smtp mode")
    if not user or not password:
        raise RuntimeError("WATCH_SMTP_USER and WATCH_SMTP_PASS are required for smtp mode "
                           "(Gmail needs an app password; SPF/DKIM is enforced on port 25)")
    with smtplib.SMTP(host, port, timeout=30) as s:
        s.ehlo()
        s.starttls()
        s.ehlo()
        s.login(user, password)
        s.send_message(msg)


def deliver_file(cfg, msg, subject):
    d = pathlib.Path(cfg["WATCH_ALERT_DIR"] or ".")
    d.mkdir(parents=True, exist_ok=True)
    path = d / f"{int(time.time())}-{subject.replace('/', '_')[:60]}.eml"
    path.write_bytes(bytes(msg))
    return str(path)


def send_alert(cfg, subject, body, action=None):
    """Deliver, and never lose an alert because the mail path was down: the mail path is
    the thing that reports outages, so a failure to send is itself an outage of the
    watchdog. Undeliverable messages are spooled and retried on later cycles."""
    mode = (cfg["WATCH_ALERT_MODE"] or "smtp").strip().lower()
    msg = default_message(cfg, subject, body)
    if mode == "stdout":
        print(f"--- ALERT ({subject}) ---\n{body}\n--- end alert ---", flush=True)
        return True
    if mode == "file":
        try:
            where = deliver_file(cfg, msg, subject)
            log_line(cfg, f"alert written to {where}")
            return True
        except Exception as e:
            log_line(cfg, f"ERROR writing alert: {e}")
            return False
    try:
        deliver_smtp(cfg, msg)
        log_line(cfg, f"alert emailed: {subject}")
        return True
    except Exception as e:
        log_line(cfg, f"ERROR sending alert: {e}")
        try:
            p = pathlib.Path(cfg["WATCH_SPOOL"])
            p.parent.mkdir(parents=True, exist_ok=True)
            with open(p, "a") as fh:
                fh.write(json.dumps({"at": int(time.time()), "subject": subject,
                                     "body": body}) + "\n")
            log_line(cfg, f"alert spooled for retry: {p}")
        except Exception as e2:
            log_line(cfg, f"ERROR spooling alert: {e2}")
        return False


def flush_spool(cfg):
    """Retry anything the mail path could not deliver earlier. Keeps the oldest failure
    visible instead of silently dropping the one message that mattered."""
    p = pathlib.Path(cfg["WATCH_SPOOL"])
    if not p.is_file():
        return
    try:
        lines = [l for l in p.read_text().splitlines() if l.strip()]
    except Exception:
        return
    if not lines:
        return
    remaining = []
    for line in lines:
        try:
            item = json.loads(line)
        except ValueError:
            continue
        msg = default_message(cfg, item.get("subject", "[YTLive] spooled alert"),
                              item.get("body", ""))
        try:
            deliver_smtp(cfg, msg)
            log_line(cfg, f"spooled alert finally sent: {item.get('subject')}")
        except Exception:
            remaining.append(line)
    try:
        if remaining:
            p.write_text("\n".join(remaining) + "\n")
        else:
            p.unlink()
    except Exception:
        pass


# --------------------------------------------------------------------------------------
# Commands
# --------------------------------------------------------------------------------------
def check_once(cfg, state):
    vid, channel = read_channel(cfg)
    host, host_last_seen = host_state(cfg)
    heartbeat, heartbeat_age = heartbeat_state(cfg)
    if channel == "live" and vid:
        state["last_video"] = vid
    now = int(time.time())
    # The push that proves the app is alive also carries its free-space figure, so the disk
    # rule needs no second mechanism and no network: one file, one read, two facts.
    disk = disk_state(cfg, heartbeat, heartbeat_payload(cfg["WATCH_HEARTBEAT"].strip()))
    new, actions = decide(now, state, channel, host, cfg, heartbeat, heartbeat_age, disk)
    return new, actions, channel, host, host_last_seen, vid, heartbeat, heartbeat_age


def cmd_once(cfg, as_json=True):
    state = load_state(cfg["WATCH_STATE"])
    new, actions, channel, host, host_last_seen, vid, heartbeat, heartbeat_age = check_once(cfg, state)
    save_state(cfg["WATCH_STATE"], new)
    if as_json:
        print(json.dumps({
            "channel": channel, "host": host,
            "heartbeat": heartbeat, "heartbeat_age": heartbeat_age,
            "disk": new.get("disk"),
            "host_last_seen": host_last_seen, "vid": vid,
            "actions": [a["kind"] for a in actions],
            "dark_since": new.get("dark_since"),
            "silent_since": new.get("silent_since"),
            "last_alert_kind": new.get("last_alert_kind"),
        }))
    else:
        print(render_status(cfg, new, channel, host, host_last_seen, vid))
    return {"live": 0, "offline": 1}.get(channel, 2)


def cmd_run(cfg):
    log_line(cfg, f"watchdog starting: version={program_version(cfg)} "
                  f"channel={cfg.channel_url or '(unset)'} "
                  f"host={cfg['WATCH_HOST'] or '(unset)'} "
                  f"heartbeat={cfg['WATCH_HEARTBEAT'] or '(disabled)'} "
                  f"every {cfg.num('WATCH_INTERVAL')}s")
    state = load_state(cfg["WATCH_STATE"])
    while True:
        try:
            (state, actions, channel, host, host_last_seen, vid,
             heartbeat, heartbeat_age) = check_once(cfg, state)
            save_state(cfg["WATCH_STATE"], state)
            for action in actions:
                subject, body = compose(action, state, channel, host, host_last_seen, vid, cfg)
                log_line(cfg, f"action={action['kind']} channel={channel} host={host} "
                              f"heartbeat={heartbeat}")
                send_alert(cfg, subject, body, action)
            if actions:
                flush_spool(cfg)
            elif state["checks"] % 60 == 0:
                log_line(cfg, f"ok channel={channel} host={host} heartbeat={heartbeat} "
                              f"checks={state['checks']}")
        except KeyboardInterrupt:
            log_line(cfg, "watchdog stopping on interrupt")
            return 0
        except Exception as e:                      # never die: a dead watchdog is silent
            log_line(cfg, f"ERROR in cycle: {type(e).__name__}: {e}")
        time.sleep(max(10, cfg.num("WATCH_INTERVAL")))


def render_status(cfg, state, channel, host, host_last_seen, vid):
    seen = host_seen_text(host, host_last_seen, cfg)
    lines = [
        "YTLive external watchdog",
        f"  watchdog       : version {program_version(cfg)}",
        f"  channel        : {cfg['WATCH_CHANNEL'] or '(unset)'}  ->  {cfg.channel_url or '(unset)'}",
        f"  host peer      : {cfg['WATCH_HOST'] or '(unset)'}",
        f"  channel state  : {channel}",
        f"  host state     : {host}" + (f"  {seen}" if seen else ""),
        f"  heartbeat      : {human_heartbeat(state, cfg)}",
        f"  disk           : {human_disk(state, cfg)}",
        f"  video id       : {vid or 'none'}",
        f"  dark since     : {human_time(state.get('dark_since'), cfg)}",
        f"  unknown since  : {human_time(state.get('unknown_since'), cfg)}",
        f"  silent since   : {human_time(state.get('silent_since'), cfg)}",
        f"  last alert     : {state.get('last_alert_kind') or 'none'} at {human_time(state.get('last_alert_at'), cfg)}",
        f"  alert mode     : {cfg['WATCH_ALERT_MODE']} -> {cfg['WATCH_ALERT_TO'] or '(unset)'}",
        f"  state file     : {cfg['WATCH_STATE']}",
        f"  thresholds     : dark {human_duration(cfg.num('WATCH_DARK_GRACE'))}, blind {human_duration(cfg.num('WATCH_BLIND_GRACE'))}, heartbeat {human_duration(cfg.num('WATCH_HEARTBEAT_MAX'))}, disk {cfg.num('WATCH_DISK_MIN_MB'):,.0f} MB, remind {human_duration(cfg.num('WATCH_REMIND'))}",
    ]
    return "\n".join(lines)


def cmd_status(cfg):
    state = load_state(cfg["WATCH_STATE"])
    vid, channel = read_channel(cfg)
    host, host_last_seen = host_state(cfg)
    heartbeat, heartbeat_age = heartbeat_state(cfg)
    # Show the CURRENT heartbeat, not the last one the loop happened to record, so `status`
    # is a live page rather than a replay of the previous check. The disk level comes from the
    # same file, so it is read live too - otherwise a fresh install (or a loop that has not
    # run yet) prints "unavailable" while the number is sitting right there.
    disk = disk_state(cfg, heartbeat, heartbeat_payload(cfg["WATCH_HEARTBEAT"].strip()))
    entry = state.get("disk") if isinstance(state.get("disk"), dict) else {}
    state = dict(state, last_heartbeat_state=heartbeat, last_heartbeat_age=heartbeat_age,
                 disk=(dict(entry, free_mb=disk["free_mb"], min_mb=disk.get("min_mb"),
                            threshold=disk["threshold"]) if disk else
                       dict(entry, free_mb=None, threshold=cfg.num("WATCH_DISK_MIN_MB"))))
    print(render_status(cfg, state, channel, host, host_last_seen, vid))
    return 0


def cmd_test_alert(cfg):
    state = load_state(cfg["WATCH_STATE"])
    subject = "[YTLive] TEST - watchdog alert path"
    body = ("This is a test of the YTLive external watchdog alert path.\n\n"
            "No action needed. If you can read this, the watchdog can reach you.\n\n"
            + render_status(cfg, state, "test", "test", None, None))
    ok = send_alert(cfg, subject, body)
    return 0 if ok else 1


USAGE = __doc__.strip().split("USAGE")[-1].strip()


def main(argv):
    if not argv:
        print(USAGE)
        return 2
    cmd = argv[0]
    if cmd in ("-h", "--help", "help"):
        print(USAGE)
        return 0
    cfg = build_cfg()
    if cmd == "once":
        return cmd_once(cfg, as_json="--text" not in argv)
    if cmd == "status":
        return cmd_status(cfg)
    if cmd == "test-alert":
        return cmd_test_alert(cfg)
    if cmd == "run":
        return cmd_run(cfg)
    print(f"unknown command: {cmd}\n\n{USAGE}")
    return 2


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except KeyboardInterrupt:
        sys.exit(130)
