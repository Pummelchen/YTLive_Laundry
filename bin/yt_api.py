#!/usr/bin/env python3
"""YouTube Live Streaming API client - create, bind and transition broadcasts.

WHY THIS EXISTS
---------------
Pushing RTMP at a stream key does NOT create a broadcast on this channel. That was the
project's founding assumption and it is wrong: rotations at 01:04, 01:10, 01:13 and 01:16
on 2026-09-05 each logged "no live broadcast seen", and the broadcast that did appear at
01:18 was started by hand in Studio. The 93 rotations later that day all failed the same
way. Ingest alone can never bring the channel live, so the 8h rotation needs an API that
can actually say "make a broadcast and put it live".

Stdlib only, on purpose - matches yt_check.py and keeps install.sh dependency-free.

USAGE
    yt_api.py auth            one-time: exchange an OAuth client for a refresh token
    yt_api.py status          print the current broadcast state as JSON
    yt_api.py ensure-live     THE ONE THAT MATTERS: guarantee a live broadcast exists
    yt_api.py end             end the active broadcast (so YouTube saves the VOD)
    yt_api.py prepare         create+bind a broadcast, ready for ingest to start it
    yt_api.py capture [id]    snapshot title/description/tags/category into a template
    yt_api.py apply <id>      stamp that template onto a newly created broadcast
    yt_api.py token           refresh-token expiry check, offline (0 ok, 1 soon, 2 expired)

ensure-live is idempotent. If the channel is already live it does nothing and exits 0.
Otherwise it creates a broadcast, binds it to the stream that owns YT_KEY, and transitions
it live once ingest is flowing.

CREDENTIALS
    conf/yt_oauth.json   {"client_id":..., "client_secret":..., "refresh_token":...}
                         chmod 600, never committed - see .gitignore
Scope needed: https://www.googleapis.com/auth/youtube
"""
import calendar, json, os, re, sys, time, pathlib, urllib.request, urllib.parse, urllib.error

BASE  = pathlib.Path(os.environ.get("BASE", str(pathlib.Path.home() / "Downloads/YTLive")))
CREDS = BASE / "conf/yt_oauth.json"
TEMPLATE = BASE / "conf/broadcast_template.json"
API   = "https://www.googleapis.com/youtube/v3"
OAUTH = "https://oauth2.googleapis.com/token"
DEVICE_CODE = "https://oauth2.googleapis.com/device/code"
SCOPE = "https://www.googleapis.com/auth/youtube"

# How long to wait for the ingest stream to report active before transitioning. YouTube
# refuses the transition while the stream is inactive, so this is not optional padding.
INGEST_WAIT = int(os.environ.get("YT_API_INGEST_WAIT", "120"))

# Google expires a refresh token after 7 days while the OAuth app is in "Testing".
# This project stays in Testing permanently (branding review is not being pursued), so
# re-running `yt_api.py auth` every 7 days is normal maintenance, not an edge case. Warn
# early and loudly - a silently dead token is the one failure nothing else can recover from.
TOKEN_TTL_DAYS  = float(os.environ.get("YT_TOKEN_TTL_DAYS", "7"))
TOKEN_WARN_DAYS = float(os.environ.get("YT_TOKEN_WARN_DAYS", "2"))   # days left before warning


def die(msg, code=2):
    print(json.dumps({"status": "ERROR", "msg": msg}))
    sys.exit(code)


def load_creds():
    if not CREDS.exists():
        die(f"missing {CREDS} - run: bin/yt_api.py auth")
    try:
        return json.loads(CREDS.read_text())
    except Exception as e:
        die(f"{CREDS} is not valid JSON: {e}")


def save_creds(d):
    CREDS.parent.mkdir(parents=True, exist_ok=True)
    CREDS.write_text(json.dumps(d, indent=2))
    CREDS.chmod(0o600)


def post_form(url, fields):
    body = urllib.parse.urlencode(fields).encode()
    req = urllib.request.Request(url, data=body,
                                 headers={"Content-Type": "application/x-www-form-urlencoded"})
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.loads(r.read())


def access_token():
    """Refresh tokens are long-lived; access tokens last an hour, so just mint one."""
    c = load_creds()
    for k in ("client_id", "client_secret", "refresh_token"):
        if not c.get(k):
            die(f"{CREDS} is missing '{k}' - run: bin/yt_api.py auth")
    try:
        return post_form(OAUTH, {
            "client_id": c["client_id"], "client_secret": c["client_secret"],
            "refresh_token": c["refresh_token"], "grant_type": "refresh_token",
        })["access_token"]
    except urllib.error.HTTPError as e:
        detail = e.read().decode()[:300]
        if "invalid_grant" in detail:
            die("refresh token rejected (revoked, expired, or the channel changed). "
                "Re-run: bin/yt_api.py auth")
        die(f"token refresh failed: HTTP {e.code} {detail}")


def api(method, path, token, params=None, body=None):
    url = f"{API}/{path}"
    if params:
        url += "?" + urllib.parse.urlencode(params)
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method, headers={
        "Authorization": f"Bearer {token}",
        "Content-Type": "application/json",
    })
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            raw = r.read()
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as e:
        detail = e.read().decode()[:500]
        # Surface YouTube's own reason - these are the messages worth acting on
        # (quota exceeded, livePermissionBlocked, errorStreamInactive, ...).
        raise RuntimeError(f"{method} {path} -> HTTP {e.code}: {detail}")


# ---------------------------------------------------------------------------- auth
def cmd_auth():
    """OAuth device flow: works over SSH with no browser and no localhost redirect."""
    print("Create an OAuth client first (one time):")
    print("  1. https://console.cloud.google.com/apis/credentials")
    print("  2. Enable 'YouTube Data API v3' for the project")
    print("  3. Create Credentials -> OAuth client ID -> application type 'TVs and Limited"
          " Input devices'")
    print("  4. OAuth consent screen -> PUBLISH THE APP ('In production').")
    print("     This matters: while the app is in 'Testing', Google expires the refresh")
    print("     token after 7 DAYS and the stream would silently stop rotating. Publishing")
    print("     shows an 'unverified app' warning you can click past - that is fine for a")
    print("     personal app, and the token then does not expire.")
    print("  5. Paste the client id and secret below\n")
    try:
        cid = input("client_id: ").strip()
        csec = input("client_secret: ").strip()
    except (EOFError, KeyboardInterrupt):
        # Reached when run without a terminal (a pipe, a launchd job, a cron entry).
        # This flow needs a human, so say so plainly instead of dumping a traceback.
        print()
        die("auth needs an interactive terminal - run it yourself: bin/yt_api.py auth")
    if not cid or not csec:
        die("client_id and client_secret are both required")

    d = post_form(DEVICE_CODE, {"client_id": cid, "scope": SCOPE})
    print(f"\n  Open: {d['verification_url']}")
    print(f"  Code: {d['user_code']}\n")
    print("Waiting for you to approve it...")

    interval = int(d.get("interval", 5))
    deadline = time.time() + int(d.get("expires_in", 600))
    while time.time() < deadline:
        time.sleep(interval)
        try:
            t = post_form(OAUTH, {
                "client_id": cid, "client_secret": csec,
                "device_code": d["device_code"],
                "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
            })
        except urllib.error.HTTPError as e:
            err = json.loads(e.read() or b"{}").get("error", "")
            if err in ("authorization_pending", "slow_down"):
                if err == "slow_down":
                    interval += 5
                continue
            die(f"device flow failed: {err}")
        save_creds({"client_id": cid, "client_secret": csec,
                    "refresh_token": t["refresh_token"],
                    "authorised_at": int(time.time())})
        print(f"\nSaved {CREDS} (chmod 600). Verify with: bin/yt_api.py status")
        return 0
    die("timed out waiting for approval")


# ------------------------------------------------------------------- broadcast ops
def active_broadcast(token):
    """The broadcast currently live, or None."""
    r = api("GET", "liveBroadcasts", token,
            {"part": "id,snippet,status", "broadcastStatus": "active",
             "broadcastType": "all", "maxResults": "5"})
    items = r.get("items", [])
    return items[0] if items else None


def stream_for_key(token, key):
    """The liveStream object whose ingest key is YT_KEY - that is what we bind to."""
    r = api("GET", "liveStreams", token,
            {"part": "id,cdn,status", "mine": "true", "maxResults": "50"})
    for s in r.get("items", []):
        if s.get("cdn", {}).get("ingestionInfo", {}).get("streamName") == key:
            return s
    return None


def pending_broadcasts(token, stream_id):
    """Broadcasts we created but never got live, bound to our stream.

    Returns (newest_reusable_or_None, [stale_ids_to_delete]).

    active_broadcast() only matches a broadcast that is actually live, so a broadcast
    created and bound while ingest was down was invisible to the next ensure-live - which
    happily minted another one, and another, every retry. Reuse the newest instead, and
    delete the abandoned ones so the channel does not silently fill with dead broadcasts.
    """
    r = api("GET", "liveBroadcasts", token,
            {"part": "id,snippet,status,contentDetails", "broadcastStatus": "upcoming",
             "broadcastType": "all", "maxResults": "50"})
    # Only ever touch broadcasts bound to OUR stream: a broadcast a human scheduled by hand
    # in Studio is not ours to reuse and certainly not ours to delete.
    mine = [it for it in r.get("items", [])
            if it.get("contentDetails", {}).get("boundStreamId") == stream_id
            and it.get("status", {}).get("lifeCycleStatus") in ("created", "ready", "testing")]
    if not mine:
        return None, []
    mine.sort(key=lambda it: it.get("snippet", {}).get("publishedAt", ""))
    return mine[-1], [it["id"] for it in mine[:-1]]


def token_age():
    """(age_days, days_left) for the refresh token, or (None, None) if unknowable."""
    try:
        t = load_creds().get("authorised_at")
    except SystemExit:
        return None, None
    if not t:
        return None, None
    age = (time.time() - t) / 86400.0
    return age, TOKEN_TTL_DAYS - age


def token_age_warning():
    """Google expires refresh tokens after 7 days while the OAuth app is in 'Testing'.
    That failure is silent and looks like nothing at all until a rotation needs the API,
    so surface the countdown long before it bites."""
    age, left = token_age()
    if age is None:
        return None
    if left <= 0:
        return (f"refresh token is {age:.1f} days old and has EXPIRED (Testing apps get "
                f"{TOKEN_TTL_DAYS:.0f} days). Rotation and self-healing are dead until you "
                f"re-run: bin/yt_api.py auth")
    if left <= TOKEN_WARN_DAYS:
        return (f"refresh token expires in {left:.1f} days ({age:.1f} days old, Testing apps "
                f"get {TOKEN_TTL_DAYS:.0f}). Re-run bin/yt_api.py auth before then or the "
                f"stream loses rotation and self-healing.")
    return None


def cmd_status(token=None, key=None):
    token = token or access_token()
    b = active_broadcast(token)
    s = stream_for_key(token, key) if key else None
    out = {
        "status": "LIVE" if b else "OFFLINE",
        "broadcast_id": b["id"] if b else None,
        "title": b["snippet"]["title"] if b else None,
        "url": f"https://www.youtube.com/watch?v={b['id']}" if b else None,
        "stream_id": s["id"] if s else None,
        "ingest": (s or {}).get("status", {}).get("streamStatus"),
    }
    # The streamer uses this to age the CURRENT broadcast correctly after a restart: its
    # 8h rotation clock has to follow the broadcast, not the process.
    if b and b.get("snippet", {}).get("actualStartTime"):
        try:
            out["started_epoch"] = int(calendar.timegm(time.strptime(
                b["snippet"]["actualStartTime"][:19], "%Y-%m-%dT%H:%M:%S")))
        except Exception:
            pass
    age, left = token_age()
    if age is not None:
        out["token_age_days"] = round(age, 2)
        out["token_days_left"] = round(left, 2)
    w = token_age_warning()
    if w:
        out["token_warning"] = w
    print(json.dumps(out))
    return 0 if b else 1


def cmd_ensure_live(key):
    """Guarantee a live broadcast. Idempotent. This is what the streamer calls."""
    token = access_token()

    b = active_broadcast(token)
    if b:
        print(json.dumps({"status": "LIVE", "broadcast_id": b["id"], "action": "none",
                          "url": f"https://www.youtube.com/watch?v={b['id']}"}))
        return 0

    stream = stream_for_key(token, key)
    if not stream:
        die("no liveStream on this channel uses the configured YT_KEY. Check YT_KEY in "
            "conf/stream.env against Studio -> Go Live -> Stream key.")

    # Pick up where a previous attempt left off rather than creating a fresh broadcast on
    # every retry. Deleting the abandoned ones keeps the channel clean.
    reuse, stale = pending_broadcasts(token, stream["id"])
    swept = []
    for sid in stale:
        try:
            api("DELETE", "liveBroadcasts", token, {"id": sid})
            swept.append(sid)
        except RuntimeError:
            pass    # not fatal - a broadcast we could not delete is untidy, not broken

    if reuse:
        bid, action = reuse["id"], "reused"
    else:
        bid, action = _create_and_bind(token, stream["id"]), "created"

    return _await_live(token, stream["id"], bid, action, swept)


def _create_and_bind(token, stream_id):
    # `or` not a get() default: an empty YT_TITLE_FMT would otherwise make an empty title,
    # which YouTube rejects.
    title = time.strftime(os.environ.get("YT_TITLE_FMT")
                          or "Ternak Laundry Bengkong - %Y-%m-%d %H:%M")
    created = api("POST", "liveBroadcasts", token,
                  {"part": "snippet,status,contentDetails"},
                  {
                      "snippet": {
                          "title": title,
                          "scheduledStartTime": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                      },
                      "status": {
                          "privacyStatus": os.environ.get("YT_PRIVACY", "public"),
                          "selfDeclaredMadeForKids": False,
                      },
                      "contentDetails": {
                          # Match what YouTube itself puts on this channel's broadcasts:
                          # autoStart so ingest brings it live, autoStop so stopping ingest
                          # closes and ARCHIVES it. autoStop was off here, which broke the
                          # native rotation - stopping ingest left the broadcast open, so
                          # only an API call could ever end it. Brief publisher restarts do
                          # not trip it: 15 of them on 2026-09-03 ended nothing.
                          # Explicit, not left to the API default: Studio-created broadcasts
                          # on this channel used latencyPreference "low", and low/ultraLow
                          # trade away DVR depth and archive robustness. Normal is the right
                          # setting for a 24/7 camera whose whole purpose is a reviewable
                          # recording, and nobody is interacting with this feed live.
                          "latencyPreference": os.environ.get("YT_LATENCY", "normal"),
                          "enableAutoStart": True,
                          "enableAutoStop": True,
                          # With a monitor stream the broadcast has to go
                          # ready -> testing -> live, and BOTH transitions were refused on
                          # 2026-09-05 while the stream was active and healthy. There is no
                          # human previewing a 24/7 CCTV feed, so switch the stage off.
                          "monitorStream": {"enableMonitorStream": False,
                                            "broadcastStreamDelayMs": 0},
                          "enableDvr": True,
                          "recordFromStart": True,
                      },
                  })
    bid = created["id"]
    api("POST", "liveBroadcasts/bind", token,
        {"part": "id,contentDetails", "id": bid, "streamId": stream_id})
    return bid


def _await_live(token, stream_id, bid, action, swept):
    # With enableAutoStart the transition happens on its own once ingest is flowing, but
    # only if ingest IS flowing. Wait for it, then transition explicitly if YouTube has not.
    waited, transitioned = 0, False
    while waited < INGEST_WAIT:
        st = api("GET", "liveStreams", token, {"part": "status", "id": stream_id})
        ingest = st["items"][0]["status"]["streamStatus"] if st.get("items") else "unknown"
        cur = api("GET", "liveBroadcasts", token, {"part": "status", "id": bid})
        life = cur["items"][0]["status"]["lifeCycleStatus"] if cur.get("items") else "unknown"
        if life == "live":
            transitioned = True
            break
        if ingest == "active" and life in ("ready", "testing"):
            try:
                api("POST", "liveBroadcasts/transition", token,
                    {"part": "status", "id": bid, "broadcastStatus": "live"})
                transitioned = True
                break
            except RuntimeError as e:
                # errorStreamInactive races autostart; retry rather than give up
                if "errorStreamInactive" not in str(e) and "invalidTransition" not in str(e):
                    raise
        time.sleep(5)
        waited += 5

    out = {
        "status": "LIVE" if transitioned else "PENDING",
        "broadcast_id": bid,
        "action": action,
        "url": f"https://www.youtube.com/watch?v={bid}",
        "msg": "" if transitioned else
               f"{action} and bound, but not live after {INGEST_WAIT}s - is ingest running? "
               f"The next ensure-live will reuse this broadcast rather than make another.",
    }
    if swept:
        out["swept"] = swept
    print(json.dumps(out))
    return 0 if transitioned else 1


# ---------------------------------------------------------- settings carry-over
# Every rotation makes a NEW video, and a new video does not inherit what was configured on
# the old one. Description, category, language and privacy happen to come across because
# they are channel default-upload settings - TAGS DO NOT, and on this channel that is 34
# local search terms doing the discovery work. Losing them three times a day, and expecting
# a human to retype them in Studio, is not a workable design.
#
# So: snapshot the outgoing broadcast at every rotation and stamp the snapshot onto the new
# one. Whatever is configured in Studio propagates forward by itself from then on.
CARRY_SNIPPET = ("title", "description", "tags", "categoryId",
                 "defaultLanguage", "defaultAudioLanguage")
CARRY_STATUS  = ("privacyStatus", "license", "embeddable", "publicStatsViewable",
                 "selfDeclaredMadeForKids")


def load_template():
    try:
        return json.loads(TEMPLATE.read_text())
    except Exception:
        return {}


def cmd_capture(video_id=None, key=None):
    """Snapshot a broadcast's settings into conf/broadcast_template.json.

    MERGES rather than replaces: a field the source lacks keeps whatever the template
    already had. That matters because the first API-created broadcast has no tags - a
    replacing capture would helpfully record "no tags" and destroy them permanently.
    """
    token = access_token()
    if not video_id:
        b = active_broadcast(token)
        if not b:
            die("nothing live to capture from - pass a video id")
        video_id = b["id"]
    r = api("GET", "videos", token, {"part": "snippet,status", "id": video_id})
    if not r.get("items"):
        die(f"video {video_id} not found")
    sn, st = r["items"][0]["snippet"], r["items"][0]["status"]
    t = load_template()
    kept, taken = [], []
    for k in CARRY_SNIPPET:
        v = sn.get(k)
        if v not in (None, "", []):
            t[k] = v; taken.append(k)
        elif k in t:
            kept.append(k)
    for k in CARRY_STATUS:
        v = st.get(k)
        if v is not None:
            t[k] = v; taken.append(k)
        elif k in t:
            kept.append(k)
    t["_captured_from"] = video_id
    t["_captured_at"] = time.strftime("%Y-%m-%d %H:%M:%S")
    TEMPLATE.parent.mkdir(parents=True, exist_ok=True)
    TEMPLATE.write_text(json.dumps(t, indent=2, ensure_ascii=False))
    print(json.dumps({"status": "CAPTURED", "from": video_id,
                      "took": taken, "kept_from_before": kept,
                      "tags": len(t.get("tags", []))}))
    return 0


def cmd_apply(video_id):
    """Stamp the saved settings onto a video. Never fatal: the stream being live matters
    more than its tags, so a failure here is reported and swallowed by the caller."""
    t = load_template()
    if not t:
        print(json.dumps({"status": "SKIPPED", "msg": f"no {TEMPLATE} yet"}))
        return 0
    token = access_token()
    r = api("GET", "videos", token, {"part": "snippet,status", "id": video_id})
    if not r.get("items"):
        die(f"video {video_id} not found")
    sn, st = r["items"][0]["snippet"], r["items"][0]["status"]
    # videos.update REPLACES the parts it is given, so start from what is there and
    # overlay the template - otherwise omitted fields get wiped.
    # YT_TITLE_FMT owns the title when it is set. Carrying the title from the template too
    # meant one bad title propagated forever: a capture from a broadcast that had the
    # fallback name stamped "Ternak Laundry Bengkong - 2026-09-05 15:03" onto the live
    # stream, replacing the configured hashtag title. Configuration beats inheritance.
    fmt = os.environ.get("YT_TITLE_FMT")
    for k in CARRY_SNIPPET:
        if k == "title" and fmt:
            sn["title"] = time.strftime(fmt)
            continue
        if k in t:
            sn[k] = t[k]
    for k in CARRY_STATUS:
        if k in t:
            st[k] = t[k]
    # Report what YouTube STORED, not what we sent. Reporting the request back as if it
    # were the result once had this claiming "35 tags applied" while the video still had
    # none - a success message that cannot fail is worth nothing.
    resp = api("PUT", "videos", token, {"part": "snippet,status"},
               {"id": video_id, "snippet": sn, "status": st})
    got = resp.get("snippet", {})
    print(json.dumps({"status": "APPLIED", "video": video_id,
                      "tags_sent": len(sn.get("tags") or []),
                      "tags_stored": len(got.get("tags") or []),
                      "title": got.get("title", "")[:60]}))
    return 0


def cmd_prepare(key):
    """Ensure a bound broadcast exists and is READY - do not wait for it to go live.

    YouTube starts an autoStart broadcast when ingest ARRIVES at the stream it is bound to.
    If ingest is already flowing when the bind happens, that arrival has already gone by and
    the broadcast sits in "ready" indefinitely; a manual transition is then refused with
    invalidTransition precisely because the broadcast is set to auto-start. Proven on
    2026-09-05: a bound broadcast sat "ready" for 17 minutes against an active, healthy
    stream, and went live 30 seconds after the publisher was bounced.

    So the broadcast has to exist and be bound BEFORE ingest starts. That is what this is
    for: the streamer calls it during the rotation gap, then starts pushing.
    """
    token = access_token()
    b = active_broadcast(token)
    if b:
        print(json.dumps({"status": "LIVE", "broadcast_id": b["id"], "action": "none",
                          "url": f"https://www.youtube.com/watch?v={b['id']}"}))
        return 0
    stream = stream_for_key(token, key)
    if not stream:
        die("no liveStream on this channel uses the configured YT_KEY. Check YT_KEY in "
            "conf/stream.env against Studio -> Go Live -> Stream key.")
    reuse, stale = pending_broadcasts(token, stream["id"])
    swept = []
    for sid in stale:
        try:
            api("DELETE", "liveBroadcasts", token, {"id": sid}); swept.append(sid)
        except RuntimeError:
            pass
    if reuse:
        bid, action = reuse["id"], "reused"
    else:
        bid, action = _create_and_bind(token, stream["id"]), "created"
    out = {"status": "READY", "broadcast_id": bid, "action": action,
           "url": f"https://www.youtube.com/watch?v={bid}",
           "msg": "bound and waiting for ingest to arrive - start the publisher now"}
    if swept:
        out["swept"] = swept
    print(json.dumps(out))
    return 0


def cmd_end():
    token = access_token()
    b = active_broadcast(token)
    if not b:
        print(json.dumps({"status": "OFFLINE", "action": "none"}))
        return 0
    api("POST", "liveBroadcasts/transition", token,
        {"part": "status", "id": b["id"], "broadcastStatus": "complete"})
    print(json.dumps({"status": "ENDED", "broadcast_id": b["id"],
                      "url": f"https://www.youtube.com/watch?v={b['id']}"}))
    return 0


def cmd_token():
    """Token expiry check that touches no network - cheap enough to run on a schedule.

    Exit 0 fine, 1 expiring soon, 2 expired or unknown. The monitor calls this daily so a
    dying token is noticed days before it takes rotation and self-healing down with it.
    """
    age, left = token_age()
    if age is None:
        print(json.dumps({"status": "UNKNOWN",
                          "msg": f"{CREDS} has no authorised_at - re-run bin/yt_api.py auth "
                                 f"to stamp it"}))
        return 2
    state = "EXPIRED" if left <= 0 else ("EXPIRING" if left <= TOKEN_WARN_DAYS else "OK")
    print(json.dumps({"status": state,
                      "age_days": round(age, 2), "days_left": round(left, 2),
                      "expires": time.strftime("%Y-%m-%d %H:%M",
                                               time.localtime(time.time() + left * 86400)),
                      "msg": token_age_warning() or ""}))
    return {"OK": 0, "EXPIRING": 1, "EXPIRED": 2}[state]


def read_key():
    """YT_KEY from the environment, else parsed out of conf/stream.env (YT_KEY="...")."""
    if os.environ.get("YT_KEY"):
        return os.environ["YT_KEY"]
    env = BASE / "conf/stream.env"
    if env.exists():
        m = re.search(r'^YT_KEY="([^"]*)"', env.read_text(), re.M)
        if m:
            return m.group(1)
    return ""


def main():
    cmd = sys.argv[1] if len(sys.argv) > 1 else "status"
    try:
        if cmd == "auth":
            return cmd_auth()
        if cmd == "status":
            return cmd_status(key=read_key())
        if cmd == "ensure-live":
            return cmd_ensure_live(read_key())
        if cmd == "end":
            return cmd_end()
        if cmd == "token":
            return cmd_token()
        if cmd == "prepare":
            return cmd_prepare(read_key())
        if cmd == "capture":
            return cmd_capture(sys.argv[2] if len(sys.argv) > 2 else None)
        if cmd == "apply":
            if len(sys.argv) < 3:
                die("apply needs a video id")
            return cmd_apply(sys.argv[2])
        die(f"unknown command '{cmd}' - use: auth | status | prepare | ensure-live | end | token | capture | apply")
    except RuntimeError as e:
        die(str(e))
    except urllib.error.URLError as e:
        die(f"network error talking to YouTube: {e}")


if __name__ == "__main__":
    sys.exit(main())
