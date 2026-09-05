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

ensure-live is idempotent. If the channel is already live it does nothing and exits 0.
Otherwise it creates a broadcast, binds it to the stream that owns YT_KEY, and transitions
it live once ingest is flowing.

CREDENTIALS
    conf/yt_oauth.json   {"client_id":..., "client_secret":..., "refresh_token":...}
                         chmod 600, never committed - see .gitignore
Scope needed: https://www.googleapis.com/auth/youtube
"""
import json, os, re, sys, time, pathlib, urllib.request, urllib.parse, urllib.error

BASE  = pathlib.Path(os.environ.get("BASE", str(pathlib.Path.home() / "Downloads/YTLive")))
CREDS = BASE / "conf/yt_oauth.json"
API   = "https://www.googleapis.com/youtube/v3"
OAUTH = "https://oauth2.googleapis.com/token"
DEVICE_CODE = "https://oauth2.googleapis.com/device/code"
SCOPE = "https://www.googleapis.com/auth/youtube"

# How long to wait for the ingest stream to report active before transitioning. YouTube
# refuses the transition while the stream is inactive, so this is not optional padding.
INGEST_WAIT = int(os.environ.get("YT_API_INGEST_WAIT", "120"))


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


def token_age_warning():
    """Google expires refresh tokens after 7 days while the OAuth app is in 'Testing'.
    That failure is silent and looks like nothing at all until a rotation needs the API,
    so surface the countdown long before it bites."""
    try:
        t = load_creds().get("authorised_at")
    except SystemExit:
        return None
    if not t:
        return None
    days = (time.time() - t) / 86400.0
    if days >= 6.0:
        return (f"refresh token is {days:.1f} days old. If the OAuth app is still in "
                f"'Testing', Google expires it at 7 days - re-run bin/yt_api.py auth, or "
                f"publish the app so it stops expiring.")
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
                          # enableAutoStart is the setting the stream-key trick was silently
                          # missing: with it, YouTube puts the broadcast live by itself as
                          # soon as ingest arrives, which is what this project always assumed
                          # happened. enableAutoStop stays off so an ingest blip cannot end
                          # the broadcast and strand the channel.
                          "enableAutoStart": True,
                          "enableAutoStop": False,
                          "enableDvr": True,
                          "recordFromStart": True,
                      },
                  })
    bid = created["id"]

    api("POST", "liveBroadcasts/bind", token,
        {"part": "id,contentDetails", "id": bid, "streamId": stream["id"]})

    # With enableAutoStart the transition happens on its own once ingest is flowing, but
    # only if ingest IS flowing. Wait for it, then transition explicitly if YouTube has not.
    waited, transitioned = 0, False
    while waited < INGEST_WAIT:
        st = api("GET", "liveStreams", token, {"part": "status", "id": stream["id"]})
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

    print(json.dumps({
        "status": "LIVE" if transitioned else "PENDING",
        "broadcast_id": bid,
        "action": "created",
        "url": f"https://www.youtube.com/watch?v={bid}",
        "msg": "" if transitioned else
               f"created and bound, but not live after {INGEST_WAIT}s - is ingest running?",
    }))
    return 0 if transitioned else 1


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
        die(f"unknown command '{cmd}' - use: auth | status | ensure-live | end")
    except RuntimeError as e:
        die(str(e))
    except urllib.error.URLError as e:
        die(f"network error talking to YouTube: {e}")


if __name__ == "__main__":
    sys.exit(main())
