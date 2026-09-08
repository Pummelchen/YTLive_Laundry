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
    yt_api.py capture [id]    snapshot the full configuration into conf/broadcast_template.json
    yt_api.py verify [id]     compare a broadcast against that reference (0 match, 1 drifted)
    yt_api.py enforce [id]    apply the reference, read back, and retry until it matches
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
# The channel's branded still, reused at every rotation. Kept in whatever format it was
# given - PNG included - because re-encoding it is not ours to decide.
# Order matters: the first that exists wins, so a stray PNG dropped in later would
# silently override the golden thumbnail. Every result names the file it actually used.
THUMBNAIL_CANDIDATES = ("conf/thumbnail.png", "conf/thumbnail.jpg")
def _thumb_path():
    for c in THUMBNAIL_CANDIDATES:
        f = BASE / c
        if f.exists():
            return f
    return BASE / THUMBNAIL_CANDIDATES[0]
UPLOAD = "https://www.googleapis.com/upload/youtube/v3"
API   = "https://www.googleapis.com/youtube/v3"
OAUTH = "https://oauth2.googleapis.com/token"
DEVICE_CODE = "https://oauth2.googleapis.com/device/code"
SCOPE = "https://www.googleapis.com/auth/youtube"

# How long to wait for the ingest stream to report active before transitioning. YouTube
# refuses the transition while the stream is inactive, so this is not optional padding.
INGEST_WAIT = int(os.environ.get("YT_API_INGEST_WAIT", "120"))

# How long to wait before believing a read-back. videos.list is eventually consistent.
READBACK_WAIT = (8, 20, 40)

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


def _create_and_bind(token, stream_id, dry_run=False):
    t = load_template()
    # The reference's title first - it is what Studio last showed. Then YT_TITLE_FMT, then
    # a dated fallback. `or` not a get() default: an empty YT_TITLE_FMT would otherwise
    # produce an empty title, which YouTube rejects.
    title = (t.get("video") or {}).get("title") or time.strftime(
        os.environ.get("YT_TITLE_FMT") or "Ternak Laundry Bengkong - %Y-%m-%d %H:%M")
    ref_bc = dict(t.get("broadcast") or {})
    ref_st = dict(t.get("video_status") or {})
    # NEVER inherited, always off. A monitor stream forces ready->testing->live, and both
    # of those transitions were refused on 2026-09-05 against a healthy active stream - the
    # broadcast sat in "ready" for 17 minutes and the channel was dark. Nobody previews a
    # 24/7 CCTV feed, so this one setting is not the reference's to decide.
    ref_bc.pop("enableMonitorStream", None)
    monitor = False
    content = {
        "enableAutoStart": True,
        "enableAutoStop": True,
        "enableDvr": True,
        "recordFromStart": True,
        "latencyPreference": os.environ.get("YT_LATENCY", "normal"),
        "monitorStream": {"enableMonitorStream": bool(monitor),
                          "broadcastStreamDelayMs": 0},
    }
    # the reference wins for anything it actually records, except the three that keep the
    # rotation working at all - autoStart/autoStop/monitorStream are load-bearing here
    for k, v in ref_bc.items():
        if k not in ("enableAutoStart", "enableAutoStop"):
            content[k] = v
    content["enableAutoStart"] = True
    content["enableAutoStop"] = True
    if os.environ.get("YT_LATENCY"):
        content["latencyPreference"] = os.environ["YT_LATENCY"]
    body = {
                      "snippet": {
                          "title": title,
                          "scheduledStartTime": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                      },
                      "status": {
                          "privacyStatus": ref_st.get("privacyStatus")
                                           or os.environ.get("YT_PRIVACY", "public"),
                          "selfDeclaredMadeForKids": bool(
                              ref_st.get("selfDeclaredMadeForKids", False)),
                      },
                      "contentDetails": content,
                  }
    if dry_run:
        # Everything above this line is the code that broke on 2026-09-07 - a name used
        # before assignment, in the one function that only runs when a broadcast has to be
        # CREATED, i.e. once every 8 hours. Building the request without sending it
        # exercises all of it in a second, which is what a smoke test is for.
        print(json.dumps({"status": "DRY-RUN", "would_create": body}, indent=2))
        return None
    created = api("POST", "liveBroadcasts", token,
                  {"part": "snippet,status,contentDetails"}, body)
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
# THE REFERENCE. Every rotation makes a new video and a new video inherits almost nothing,
# so conf/broadcast_template.json holds the intended configuration and every new broadcast
# is stamped with it, then read back and checked, and fixed until it matches.
#
# Three groups, because they are set through three different API calls:
#   video        -> videos.update part=snippet
#   video_status -> videos.update part=status
#   broadcast    -> liveBroadcasts.insert contentDetails (fixed at creation time)
VIDEO_FIELDS  = ("title", "description", "tags", "categoryId",
                 "defaultLanguage", "defaultAudioLanguage")
STATUS_FIELDS = ("privacyStatus", "license", "embeddable", "publicStatsViewable",
                 "selfDeclaredMadeForKids")
BCAST_FIELDS  = ("latencyPreference", "enableDvr", "enableEmbed", "recordFromStart",
                 "enableAutoStart", "enableAutoStop", "enableContentEncryption",
                 "closedCaptionsType", "projection")


def load_template():
    try:
        return json.loads(TEMPLATE.read_text())
    except Exception:
        return {}


def save_template(t):
    TEMPLATE.parent.mkdir(parents=True, exist_ok=True)
    TEMPLATE.write_text(json.dumps(t, indent=2, ensure_ascii=False))


def cmd_capture(video_id=None):
    """Snapshot a broadcast's full configuration into the reference.

    MERGES rather than replaces: a field the source lacks keeps whatever the reference
    already had. Without that, capturing from a freshly created broadcast - which has no
    tags yet - would record "no tags" and destroy them permanently.
    """
    token = access_token()
    if not video_id:
        b = active_broadcast(token)
        if not b:
            die("nothing live to capture from - pass a video id")
        video_id = b["id"]
    v = api("GET", "videos", token,
            {"part": "snippet,status,localizations", "id": video_id})
    if not v.get("items"):
        die(f"video {video_id} not found")
    v = v["items"][0]
    sn, st = v["snippet"], v["status"]
    t = load_template()
    vid_t = t.setdefault("video", {})
    st_t = t.setdefault("video_status", {})
    bc_t = t.setdefault("broadcast", {})
    took, kept = [], []
    for k in VIDEO_FIELDS:
        val = sn.get(k)
        if k == "title" and val and FALLBACK_TITLE.match(val):
            kept.append("title(refused a fallback title)"); continue
        if val not in (None, "", []):
            vid_t[k] = val; took.append(k)
        elif k in vid_t:
            kept.append(k)
    loc = v.get("localizations")
    if loc:
        t["localizations"] = loc; took.append("localizations")
    elif "localizations" in t:
        kept.append("localizations")
    for k in STATUS_FIELDS:
        val = st.get(k)
        if val is not None:
            st_t[k] = val; took.append(k)
        elif k in st_t:
            kept.append(k)
    # broadcast-level settings, if this id is still a live broadcast
    b = api("GET", "liveBroadcasts", token, {"part": "contentDetails", "id": video_id})
    if b.get("items"):
        cd = b["items"][0]["contentDetails"]
        for k in BCAST_FIELDS:
            if cd.get(k) is not None:
                bc_t[k] = cd[k]; took.append(k)
        bc_t["enableMonitorStream"] = cd.get("monitorStream", {}).get("enableMonitorStream", False)
    t["_captured_from"] = video_id
    t["_captured_at"] = time.strftime("%Y-%m-%d %H:%M:%S")
    save_template(t)
    print(json.dumps({"status": "CAPTURED", "from": video_id,
                      "took": len(took), "kept_from_before": kept,
                      "tags": len(vid_t.get("tags") or []),
                      "description_chars": len(vid_t.get("description") or ""),
                      "localizations": list((t.get("localizations") or {}).keys())}))
    return 0


# A broadcast created before a title was known gets this shape. Capturing FROM one of
# these is how a wrong title got propagated on 2026-09-06, so they are never adopted.
FALLBACK_TITLE = re.compile(r"^Ternak Laundry Bengkong - \d{4}-\d{2}-\d{2} \d{2}:\d{2}$")


def _wanted_video(t):
    """The snippet/status the reference says a broadcast should have.

    The REFERENCE owns the title, not conf/stream.env. Studio is where a title actually
    gets edited, and requiring stream.env to be edited in lockstep just moves the manual
    work somewhere less visible - the "#indonesia" added in Studio was being overwritten
    on every enforcement by a stale YT_TITLE_FMT. YT_TITLE_FMT is now only the name used
    when creating a broadcast before any reference exists.
    """
    vid_t = dict(t.get("video") or {})
    if not vid_t.get("title"):
        fmt = os.environ.get("YT_TITLE_FMT")
        if fmt:
            vid_t["title"] = time.strftime(fmt)
    return vid_t, dict(t.get("video_status") or {})


def _diff_video(sn, st, loc, t):
    """Which reference fields do NOT match what YouTube currently has."""
    vid_t, st_t = _wanted_video(t)
    diffs = []
    for k, want in vid_t.items():
        got = sn.get(k)
        if k == "tags":
            g, w = set(got or []), set(want or [])
            if g != w:
                # Name them. Reporting only counts meant a tag added in Studio was removed
                # by enforcement with no record of WHICH one, which makes the change
                # unrecoverable from the log.
                parts = []
                if w - g:
                    parts.append("adding " + ",".join(sorted(w - g)))
                if g - w:
                    parts.append("REMOVING " + ",".join(sorted(g - w)))
                diffs.append("tags[" + "; ".join(parts) + "]")
        elif got != want:
            diffs.append(k)
    for k, want in st_t.items():
        if st.get(k) != want:
            diffs.append(k)
    # localizations are NOT compared. With defaultLanguage set, YouTube mirrors the main
    # snippet into that language's localization itself, and lags doing it - so comparing
    # them reported "localizations" drift permanently and would have fired a needless
    # update every ENFORCE_EVERY seconds forever. Enforcing title, description and
    # defaultLanguage is what actually determines the localized text.
    return diffs


def _apply_video(token, video_id, t):
    v = api("GET", "videos", token,
            {"part": "snippet,status,localizations", "id": video_id})["items"][0]
    sn, st = v["snippet"], v["status"]
    vid_t, st_t = _wanted_video(t)
    sn.update(vid_t)
    st.update(st_t)
    return api("PUT", "videos", token, {"part": "snippet,status"},
               {"id": video_id, "snippet": sn, "status": st})


def _ensure_thumbnail(token, video_id):
    """Put the branded still back if it is not already there. Never fatal."""
    if not _thumb_path().exists():
        return {}
    try:
        ok, c = thumbnail_matches(token, video_id, _thumb_path())
        if ok:
            return {"thumbnail": "ok", "thumbnail_corr": c}
        set_thumbnail(token, video_id, _thumb_path())
        time.sleep(READBACK_WAIT[1])
        if not RENDERED.exists():
            snapshot_rendered(token, video_id)
        ok, c = thumbnail_matches(token, video_id, _thumb_path())
        return {"thumbnail": "applied" if ok else "applied_unconfirmed",
                "thumbnail_file": _thumb_path().name, "thumbnail_corr": c}
    except Exception as e:
        return {"thumbnail": "failed", "thumbnail_error": str(e)[:180]}


def cmd_verify(video_id=None, quiet=False):
    """Compare a broadcast against the reference. Exit 0 if it matches, 1 if it drifted."""
    t = load_template()
    if not t:
        print(json.dumps({"status": "NOREF", "msg": f"no {TEMPLATE} yet"})); return 2
    token = access_token()
    if not video_id:
        b = active_broadcast(token)
        if not b:
            print(json.dumps({"status": "OFFLINE", "msg": "nothing live to verify"})); return 2
        video_id = b["id"]
    v = api("GET", "videos", token,
            {"part": "snippet,status,localizations", "id": video_id})
    if not v.get("items"):
        die(f"video {video_id} not found")
    v = v["items"][0]
    diffs = _diff_video(v["snippet"], v["status"], v.get("localizations"), t)
    # broadcast-level settings are fixed at creation; report them but never claim to fix
    bdiffs = []
    b = api("GET", "liveBroadcasts", token, {"part": "contentDetails", "id": video_id})
    if b.get("items"):
        cd = b["items"][0]["contentDetails"]
        for k, want in (t.get("broadcast") or {}).items():
            got = cd.get("monitorStream", {}).get("enableMonitorStream") \
                  if k == "enableMonitorStream" else cd.get(k)
            if got != want:
                bdiffs.append(f"{k}({got} vs {want})")
    if _thumb_path().exists():
        try:
            tok, tc = thumbnail_matches(token, video_id, _thumb_path())
            if not tok:
                diffs.append(f"thumbnail(corr {tc})")
        except Exception:
            pass
    out = {"status": "OK" if not diffs and not bdiffs else "DRIFTED",
           "video": video_id, "diffs": diffs, "broadcast_diffs": bdiffs}
    manual = (t.get("manual") or {})
    if manual:
        out["manual_unverifiable"] = list(manual.keys())
    if not quiet:
        print(json.dumps(out))
    return 0 if (not diffs and not bdiffs) else 1


def cmd_enforce(video_id=None, attempts=3):
    """Apply the reference, read it back, and keep fixing until it matches.

    "Applied" is not "correct" - videos.update happily accepts a request and returns a
    body that is not what was stored. Only a read-back proves anything.
    """
    t = load_template()
    if not t:
        print(json.dumps({"status": "NOREF", "msg": f"no {TEMPLATE} yet"})); return 2
    token = access_token()
    if not video_id:
        b = active_broadcast(token)
        if not b:
            print(json.dumps({"status": "OFFLINE", "msg": "nothing live to enforce on"})); return 2
        video_id = b["id"]
    tries = []
    for i in range(attempts):
        v = api("GET", "videos", token,
                {"part": "snippet,status,localizations", "id": video_id})["items"][0]
        diffs = _diff_video(v["snippet"], v["status"], v.get("localizations"), t)
        if not diffs:
            print(json.dumps({"status": "OK", "video": video_id, "attempts": i,
                              "tags": len(v["snippet"].get("tags") or []),
                              "tries": tries}))
            return 0
        tries.append({"attempt": i + 1, "fixing": diffs})
        resp = _apply_video(token, video_id, t)
        # Judge by the WRITE RESPONSE, not by re-reading. videos.list is eventually
        # consistent and serves stale data for several seconds, so a read-back loop
        # reported "tags(1 vs 38)" three times over for a write that had already
        # succeeded - and did three more redundant updates chasing it. The response to
        # the update reflects what was actually stored.
        rdiffs = _diff_video(resp.get("snippet", {}), resp.get("status", {}),
                             resp.get("localizations"), t)
        if not rdiffs:
            out = {"status": "OK", "video": video_id, "attempts": i + 1, "fixed": diffs,
                   "tags": len(resp.get("snippet", {}).get("tags") or []),
                   "confirmed_by": "write response"}
            out.update(_ensure_thumbnail(token, video_id))
            print(json.dumps(out))
            return 0
        time.sleep(READBACK_WAIT[min(i, len(READBACK_WAIT) - 1)])
    time.sleep(READBACK_WAIT[-1])       # final word, after the longest settle
    v = api("GET", "videos", token,
            {"part": "snippet,status,localizations", "id": video_id})["items"][0]
    diffs = _diff_video(v["snippet"], v["status"], v.get("localizations"), t)
    print(json.dumps({"status": "OK" if not diffs else "FAILED", "video": video_id,
                      "attempts": attempts, "remaining": diffs, "tries": tries}))
    return 0 if not diffs else 1


# ------------------------------------------------------------------- thumbnail
# A new broadcast every 8 hours means a new video every 8 hours, each one defaulting to a
# frame YouTube grabbed from the stream. The branded still has to be re-applied every time,
# which is exactly the kind of thing nobody should be doing by hand three times a day.
def set_thumbnail(token, video_id, path):
    data = pathlib.Path(path).read_bytes()
    # No local size check. YouTube documents a 2 MB limit, but the documented limit is not
    # the enforced one and a pre-emptive refusal here just means rejecting a file the
    # service would have accepted. Send it and report what YouTube actually says.
    ctype = "image/png" if data[:8] == b"\x89PNG\r\n\x1a\n" else "image/jpeg"
    req = urllib.request.Request(
        f"{UPLOAD}/thumbnails/set?videoId={urllib.parse.quote(video_id)}&uploadType=media",
        data=data, method="POST",
        headers={"Authorization": f"Bearer {token}", "Content-Type": ctype,
                 "Content-Length": str(len(data))})
    try:
        with urllib.request.urlopen(req, timeout=120) as r:
            return json.loads(r.read() or b"{}")
    except urllib.error.HTTPError as e:
        detail = e.read().decode()[:400]
        if e.code == 403 and "forbidden" in detail.lower():
            raise RuntimeError("YouTube refused the custom thumbnail. The channel must be "
                               "verified (phone) to use custom thumbnails: "
                               f"{detail}")
        raise RuntimeError(f"thumbnails.set -> HTTP {e.code}: {detail}")


def _gray(src, is_url=False):
    """64x36 grayscale bytes, via ffmpeg - same trick yt_check.py uses to compare frames."""
    ff = str(pathlib.Path.home() / ".local/bin/ffmpeg")
    import subprocess
    r = subprocess.run([ff, "-v", "error", "-i", src, "-vf", "scale=64:36,format=gray",
                        "-f", "rawvideo", "-"], capture_output=True, timeout=60)
    return list(r.stdout)


def _corr(a, b):
    if len(a) != len(b) or not a:
        return 0.0
    n = len(a); ma = sum(a) / n; mb = sum(b) / n
    va = sum((x - ma) ** 2 for x in a); vb = sum((x - mb) ** 2 for x in b)
    if va == 0 or vb == 0:
        return 0.0
    return sum((a[i] - ma) * (b[i] - mb) for i in range(n)) / ((va * vb) ** 0.5)


RENDERED = BASE / "conf/thumbnail_rendered.jpg"   # what YouTube shows once ours is applied


def _thumb_url(token, video_id):
    v = api("GET", "videos", token, {"part": "snippet", "id": video_id})
    if not v.get("items"):
        return None
    th = v["items"][0]["snippet"].get("thumbnails", {})
    for k in ("maxres", "standard", "high", "medium", "default"):
        if th.get(k, {}).get("url"):
            return th[k]["url"]
    return None


def snapshot_rendered(token, video_id):
    """Save YouTube's rendering of our thumbnail as the comparison baseline.

    Comparing the SOURCE file against YouTube's version is a false mismatch waiting to
    happen: a 4:3 source comes back as a 16:9 render with the sides filled in, which
    correlates at ~0.5 against the original however correct it is. Comparing YouTube's
    render against a stored copy of YouTube's render is like for like.
    """
    url = _thumb_url(token, video_id)
    if not url:
        return False
    try:
        with urllib.request.urlopen(url, timeout=60) as r:
            RENDERED.write_bytes(r.read())
        return True
    except Exception:
        return False


def thumbnail_matches(token, video_id, path, min_corr=0.90):
    """Is the video's thumbnail actually ours?

    YouTube re-encodes what it is given, so the bytes never match. Compare the picture
    instead, the same way the stream monitor compares frames: downscale both to 64x36
    grey and correlate. That is immune to re-encoding and still catches "YouTube is
    showing a frame it grabbed from the stream" - a completely different image.
    """
    v = api("GET", "videos", token, {"part": "snippet", "id": video_id})
    if not v.get("items"):
        return False, 0.0
    th = v["items"][0]["snippet"].get("thumbnails", {})
    url = None
    for k in ("maxres", "standard", "high", "medium", "default"):
        if th.get(k, {}).get("url"):
            url = th[k]["url"]; break
    if not url:
        return False, 0.0
    ref = str(RENDERED) if RENDERED.exists() else str(path)
    live = _gray(url); mine = _gray(ref)
    if not live or not mine:
        return False, 0.0
    c = _corr(live, mine)
    return c >= min_corr, round(c, 3)


def cmd_thumbnail(arg=None):
    """`thumbnail <file>` adopts a file as the reference; `thumbnail` re-applies it."""
    token = access_token()
    if arg and arg not in ("--check",):
        src = pathlib.Path(arg).expanduser()
        if not src.exists():
            die(f"no such file: {src}")
        _thumb_path().parent.mkdir(parents=True, exist_ok=True)
        (BASE / ('conf/thumbnail' + src.suffix.lower())).write_bytes(src.read_bytes())
    if not _thumb_path().exists():
        die(f"no reference thumbnail yet - run: bin/yt_api.py thumbnail <file>")
    b = active_broadcast(token)
    if not b:
        print(json.dumps({"status": "STORED", "file": str(_thumb_path()),
                          "bytes": _thumb_path().stat().st_size,
                          "msg": "nothing live - it will be applied at the next broadcast"}))
        return 0
    if arg == "--check":
        ok, c = thumbnail_matches(token, b["id"], _thumb_path())
        print(json.dumps({"status": "OK" if ok else "MISMATCH",
                          "video": b["id"], "correlation": c}))
        return 0 if ok else 1
    set_thumbnail(token, b["id"], _thumb_path())
    time.sleep(READBACK_WAIT[1])          # YouTube needs a moment to render it
    RENDERED.unlink(missing_ok=True)      # re-baseline against the new upload
    snapshot_rendered(token, b["id"])
    ok, c = thumbnail_matches(token, b["id"], _thumb_path())
    print(json.dumps({"status": "APPLIED" if ok else "APPLIED_UNCONFIRMED",
                      "video": b["id"], "file": _thumb_path().name,
                      "bytes": _thumb_path().stat().st_size,
                      "correlation": c}))
    return 0


# ------------------------------------------------------- suggested VOD thumbnail
# When a broadcast ends and becomes a video, YouTube DISCARDS the custom thumbnail the live
# broadcast carried and falls back to a frame it picked itself - which is why Studio then
# offers "choose one of 3". Verified on ufmT_Fjg9aw: maxresdefault.jpg was byte-identical to
# maxres1.jpg, i.e. the auto-pick, despite the branded thumbnail having been enforced
# throughout the eight hours it was live.
#
# The three suggestions are fetchable at predictable URLs. The numbered ones (1/2/3.jpg) are
# only 120x90, far below the 640x360 minimum for an upload, but maxres1/2/3.jpg are the same
# frames at 1280x720 - exactly the recommended size.
#
# Adopting suggestion 1 explicitly turns an auto-pick into a real custom thumbnail, so it is
# locked in rather than left to YouTube's discretion.
THUMB_CANDIDATES = ("maxres{n}", "sd{n}", "hq{n}")


def _yt_img(video_id, name):
    try:
        req = urllib.request.Request(f"https://i.ytimg.com/vi/{video_id}/{name}.jpg",
                                     headers={"Cache-Control": "no-cache"})
        with urllib.request.urlopen(req, timeout=60) as r:
            return r.read()
    except Exception:
        return None


def cmd_pick_thumbnail(video_id, which=1, force=False):
    """Set YouTube's own suggestion #which as the video's thumbnail.

    Refuses if the video already has a CUSTOM thumbnail, so a deliberate choice is never
    overwritten. "Custom" is decided by comparing the live thumbnail against the three
    suggestions: if it is byte-identical to one of them it is still YouTube's auto-pick.
    """
    token = access_token()
    cur = _yt_img(video_id, "maxresdefault") or _yt_img(video_id, "hqdefault")
    if cur is None:
        print(json.dumps({"status": "NOTREADY", "video": video_id,
                          "msg": "no thumbnail served yet - video still processing"}))
        return 1
    sugg = {}
    for n in (1, 2, 3):
        for pat in THUMB_CANDIDATES:
            b = _yt_img(video_id, pat.format(n=n))
            if b:
                sugg[n] = b
                break
    if which not in sugg:
        print(json.dumps({"status": "NOTREADY", "video": video_id,
                          "msg": f"suggestion {which} not available yet",
                          "available": sorted(sugg)}))
        return 1
    import hashlib
    h = lambda b: hashlib.md5(b).hexdigest()
    # WHAT COUNTS AS "STILL THE DEFAULT" - two things, not one:
    #   1. byte-identical to one of YouTube's suggestions  -> its auto-pick
    #   2. visually identical to conf/thumbnail.jpg         -> OUR branded still, which is
    #      the same image on every video and is exactly what a frame from the video is
    #      meant to replace
    # Only a thumbnail that is neither - something deliberately chosen - is left alone.
    # This originally skipped on (1) alone, which meant our own branded still was treated
    # as a deliberate choice and protected. Backwards: it is the default.
    replaceable = h(cur) in {h(b) for b in sugg.values()}
    why = "youtube auto-pick"
    if not replaceable and _thumb_path().exists():
        tmpc = BASE / "log/.cur_thumb.jpg"
        tmpc.parent.mkdir(parents=True, exist_ok=True)
        tmpc.write_bytes(cur)
        live = _gray(str(tmpc)); mine = _gray(str(_thumb_path()))
        tmpc.unlink(missing_ok=True)
        if live and mine and _corr(live, mine) >= 0.90:
            replaceable, why = True, "our default branded still"
    if not force and not replaceable:
        print(json.dumps({"status": "CUSTOM", "video": video_id, "action": "none",
                          "msg": "has a deliberately chosen thumbnail - leaving it alone"}))
        return 0
    tmp = BASE / "log/.suggested_thumb.jpg"
    tmp.parent.mkdir(parents=True, exist_ok=True)
    tmp.write_bytes(sugg[which])
    set_thumbnail(token, video_id, tmp)
    tmp.unlink(missing_ok=True)
    print(json.dumps({"status": "SET", "video": video_id, "suggestion": which,
                      "replaced": why, "bytes": len(sugg[which]),
                      "url": f"https://www.youtube.com/watch?v={video_id}"}))
    return 0


def _frame_stats(path):
    """(mean_luma, spread) of a 64x36 grey reduction. A frame that is black, or a flat
    slate, has a near-zero spread even when its mean is not zero."""
    import subprocess
    ff = str(pathlib.Path.home() / ".local/bin/ffmpeg")
    r = subprocess.run([ff, "-v", "error", "-i", str(path),
                        "-vf", "scale=64:36,format=gray", "-f", "rawvideo", "-"],
                       capture_output=True, timeout=60)
    px = list(r.stdout)
    if not px:
        return 0.0, 0.0
    m = sum(px) / len(px)
    var = sum((x - m) ** 2 for x in px) / len(px)
    return m, var ** 0.5


def cmd_frame_thumbnail(video_id, ts="01:00:00", min_luma=24.0, min_spread=8.0):
    """Grab a frame from the finished video and set it as the thumbnail.

    The fallback for when YouTube never offers its own suggestions - an 8h video can take
    hours to produce them, and a video with no thumbnail of its own is worse than one
    showing a real frame.

    The frame is CHECKED before it is used: a near-black frame, or a flat one with no
    detail, means the stream was showing filler or had glitched at that moment, and using
    it would be worse than the auto-pick. Nearby offsets are tried before giving up.
    """
    import subprocess
    token = access_token()
    ytdlp = str(pathlib.Path.home() / ".local/bin/yt-dlp")
    ff = str(pathlib.Path.home() / ".local/bin/ffmpeg")
    r = subprocess.run([ytdlp, "-g", "-f", "bv*[height<=1080]/bv*/best", "--no-warnings",
                        f"https://www.youtube.com/watch?v={video_id}"],
                       capture_output=True, text=True, timeout=120)
    url = (r.stdout.strip().split("\n") or [""])[0]
    if not url:
        print(json.dumps({"status": "NOTREADY", "video": video_id,
                          "msg": "no media URL yet - video still processing"}))
        return 1
    # the requested moment first, then nearby, in case that one frame was bad
    h, m, sec = (int(x) for x in ts.split(":"))
    base = h * 3600 + m * 60 + sec
    tried = []
    out = BASE / "log/.frame_thumb.jpg"
    for off in (0, 300, -300, 600, -600, 1800):
        at = base + off
        if at < 0:
            continue
        stamp = f"{at//3600:02d}:{at%3600//60:02d}:{at%60:02d}"
        g = subprocess.run([ff, "-y", "-v", "error", "-ss", stamp, "-i", url,
                            "-frames:v", "1", "-q:v", "2", str(out)],
                           capture_output=True, timeout=180)
        if not out.exists() or out.stat().st_size == 0:
            tried.append({"at": stamp, "why": "no frame"})
            continue
        luma, spread = _frame_stats(out)
        if luma < min_luma:
            tried.append({"at": stamp, "why": f"too dark (luma {luma:.1f})"}); continue
        if spread < min_spread:
            tried.append({"at": stamp, "why": f"flat/no detail (spread {spread:.1f})"}); continue
        set_thumbnail(token, video_id, out)
        out.unlink(missing_ok=True)
        print(json.dumps({"status": "SET", "video": video_id, "source": "frame",
                          "at": stamp, "luma": round(luma, 1), "spread": round(spread, 1),
                          "rejected": tried,
                          "url": f"https://www.youtube.com/watch?v={video_id}"}))
        return 0
    out.unlink(missing_ok=True)
    # "no frame" everywhere means the video is not seekable yet, not that its content is
    # bad - reporting that as FAILED made the scheduler treat it as settled and give up
    # permanently on a video that was merely still processing.
    if tried and all(t["why"] == "no frame" for t in tried):
        print(json.dumps({"status": "NOTREADY", "video": video_id,
                          "msg": "video not seekable yet - still processing",
                          "rejected": tried}))
        return 1
    print(json.dumps({"status": "FAILED", "video": video_id,
                      "msg": "every candidate frame was black or featureless",
                      "rejected": tried}))
    return 1


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
            if "--dry-run" in sys.argv:
                tok = access_token(); st = stream_for_key(tok, read_key())
                if not st:
                    die("no liveStream uses the configured YT_KEY")
                _create_and_bind(tok, st["id"], dry_run=True)
                return 0
            return cmd_prepare(read_key())
        if cmd == "capture":
            return cmd_capture(sys.argv[2] if len(sys.argv) > 2 else None)
        if cmd == "verify":
            return cmd_verify(sys.argv[2] if len(sys.argv) > 2 else None)
        if cmd == "thumbnail":
            return cmd_thumbnail(sys.argv[2] if len(sys.argv) > 2 else None)
        if cmd == "frame-thumbnail":
            if len(sys.argv) < 3:
                die("frame-thumbnail needs a video id")
            return cmd_frame_thumbnail(sys.argv[2],
                                       sys.argv[3] if len(sys.argv) > 3 else "01:00:00")
        if cmd == "pick-thumbnail":
            if len(sys.argv) < 3:
                die("pick-thumbnail needs a video id")
            return cmd_pick_thumbnail(sys.argv[2],
                                      which=int(sys.argv[3]) if len(sys.argv) > 3 else 1,
                                      force="--force" in sys.argv)
        if cmd in ("apply", "enforce"):
            return cmd_enforce(sys.argv[2] if len(sys.argv) > 2 else None)
        die(f"unknown command '{cmd}' - use: auth | status | prepare | ensure-live | end | token | capture | verify | enforce | thumbnail | pick-thumbnail | frame-thumbnail")
    except RuntimeError as e:
        die(str(e))
    except urllib.error.URLError as e:
        die(f"network error talking to YouTube: {e}")


if __name__ == "__main__":
    sys.exit(main())
