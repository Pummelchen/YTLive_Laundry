#!/usr/bin/env python3
"""Pull one frame from the live YouTube stream and compare it to a golden reference.

Tolerant by design: the scene is a fixed CCTV view, so people coming and going and
day/night light changes must NOT trigger an alert. Only gross failures should:
black frame, frozen filler, garbage, or the stream being offline.

Exit codes: 0 = OK, 1 = MISMATCH/OFFLINE, 2 = COULD NOT FETCH / UNKNOWN
"""
import subprocess, sys, os, json, time, pathlib, tempfile

BASE = pathlib.Path(os.environ.get("BASE", str(pathlib.Path.home()/"Downloads/YTLive")))
FF   = str(pathlib.Path.home()/".local/bin/ffmpeg")
YTDLP= str(pathlib.Path.home()/".local/bin/yt-dlp")
CACHE= BASE/"log/yt_url.cache"
GOLD = BASE/"conf/golden.jpg"
LAST = BASE/"log/yt_lastpull.jpg"
PREV = BASE/"log/yt_prevpull.jpg"

CHANNEL = os.environ.get("YT_CHANNEL", "").strip()
WATCH   = os.environ.get("YT_WATCH_URL", "").strip()
if not WATCH and CHANNEL:
    h = CHANNEL if CHANNEL.startswith("@") else "@" + CHANNEL
    WATCH = f"https://www.youtube.com/{h}/live"   # always points at whatever is live NOW
CORR_MIN   = float(os.environ.get("CORR_MIN", "0.60"))
BLACK_LUMA = float(os.environ.get("BLACK_LUMA", "16"))
URL_TTL    = int(os.environ.get("URL_TTL", "1800"))
VIDCACHE   = BASE/"log/yt_videoid.cache"

# Phrases YouTube/yt-dlp use when the channel is genuinely not streaming. Anything else
# that goes wrong is a failure of the LOOKUP, not evidence about the channel.
OFFLINE_SIGNS = ("not currently live", "does not have a live", "is not live",
                 "not currently streaming", "this live event will begin",
                 "the channel is not currently live")


def live_info():
    """Resolve the channel's CURRENT live video.

    Returns (video_id, state) where state is "live", "offline" or "unknown".

    "unknown" is NOT evidence that the channel is dark. This used to return a bare
    (None, False) for every failure, so a yt-dlp hiccup - rate limit, bot check, network
    blip, a yt-dlp release that breaks extraction - was reported to the monitor as OFFLINE,
    and OFFLINE is the status that makes the monitor act. stream.sh has always drawn this
    three-way distinction (yt_live_state); this checker is the one the monitor actually
    uses, and it did not.
    """
    try:
        r = subprocess.run([YTDLP, "--no-warnings", "--skip-download",
                            "--print", "%(id)s|%(is_live)s", WATCH],
                           capture_output=True, text=True, timeout=90)
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

def resolve(force=False):
    """Direct media URL for the current live stream. Re-resolves when the broadcast
    changes video id (YouTube rotates these) or when the cached URL expires."""
    vid, state = live_info()
    if state != "live":
        return None, vid, state
    prev = VIDCACHE.read_text().strip() if VIDCACHE.exists() else ""
    fresh = (CACHE.exists() and time.time() - CACHE.stat().st_mtime < URL_TTL
             and prev == vid and not force)
    if fresh:
        u = CACHE.read_text().strip()
        if u: return u, vid, "live"
    try:
        r = subprocess.run([YTDLP, "-g", "-f", "bv*[height<=720]/bv*/best", "--no-warnings",
                            f"https://www.youtube.com/watch?v={vid}"],
                           capture_output=True, text=True, timeout=90)
    except subprocess.TimeoutExpired:
        return None, vid, "live"
    url = (r.stdout.strip().split("\n") or [""])[0]
    if not url:
        return None, vid, "live"
    CACHE.parent.mkdir(parents=True, exist_ok=True)
    CACHE.write_text(url); VIDCACHE.write_text(vid)
    return url, vid, "live"

def grab(url, out):
    r = subprocess.run([FF, "-y", "-v", "error", "-headers", "User-Agent: Mozilla/5.0\r\n",
                        "-i", url, "-frames:v", "1", "-q:v", "3", str(out)],
                       capture_output=True, text=True, timeout=90)
    return out.exists() and out.stat().st_size > 0

def gray(path, w=64, h=36):
    r = subprocess.run([FF, "-v", "error", "-i", str(path),
                        "-vf", f"scale={w}:{h},format=gray", "-f", "rawvideo", "-"],
                       capture_output=True, timeout=30)
    return list(r.stdout)

def corr(a, b):
    """Pearson correlation - brightness/contrast invariant, so day/night is fine."""
    if len(a) != len(b) or not a: return 0.0
    n=len(a); ma=sum(a)/n; mb=sum(b)/n
    va=sum((x-ma)**2 for x in a); vb=sum((x-mb)**2 for x in b)
    if va == 0 or vb == 0: return 0.0
    cov=sum((a[i]-ma)*(b[i]-mb) for i in range(n))
    return cov/((va*vb)**0.5)

def main():
    if not WATCH:
        print(json.dumps({"status":"NOCONFIG","msg":"set YT_CHANNEL (or YT_WATCH_URL)"})); return 2
    if not GOLD.exists():
        print(json.dumps({"status":"NOGOLDEN","msg":f"missing {GOLD}"})); return 2

    url, vid, state = resolve()
    if state == "unknown":
        # Deliberately NOT offline: the monitor must not create or rotate a broadcast
        # because yt-dlp fell over. It logs this and keeps waiting.
        print(json.dumps({"status":"UNKNOWN",
                          "msg":"could not determine whether the channel is live "
                                "(yt-dlp failed) - not treating this as offline"}))
        return 2
    if state != "live":
        print(json.dumps({"status":"OFFLINE","msg":"no active live broadcast on the channel"}))
        return 1
    if not url or not grab(url, LAST):
        url, vid, state = resolve(force=True)        # rotated/expired media URL
        if not url or not grab(url, LAST):
            print(json.dumps({"status":"FETCHFAIL","vid":vid,"msg":"could not pull a frame"}))
            return 2

    cur = gray(LAST); gold = gray(GOLD)
    if not cur:
        print(json.dumps({"status":"FETCHFAIL","msg":"frame unreadable"})); return 2

    luma = sum(cur)/len(cur)
    c    = corr(cur, gold)
    frozen = False
    if PREV.exists():
        p = gray(PREV)
        if p and len(p)==len(cur):
            frozen = corr(cur,p) > 0.9995 and sum(abs(cur[i]-p[i]) for i in range(len(cur))) == 0
    try: LAST.replace(PREV) if False else __import__("shutil").copyfile(LAST, PREV)
    except Exception: pass

    if luma < BLACK_LUMA:
        st, msg = "BLACK", f"frame is near-black (luma {luma:.1f})"
    elif frozen:
        st, msg = "FROZEN", "identical to previous pull - picture is stuck"
    elif c < CORR_MIN:
        st, msg = "MISMATCH", f"correlation {c:.3f} < {CORR_MIN}"
    else:
        st, msg = "OK", ""
    print(json.dumps({"status":st,"vid":vid,"corr":round(c,3),"luma":round(luma,1),"frozen":frozen,"msg":msg}))
    return 0 if st=="OK" else 1

if __name__ == "__main__":
    try: sys.exit(main())
    except subprocess.TimeoutExpired:
        print(json.dumps({"status":"FETCHFAIL","msg":"timeout"})); sys.exit(2)
    except Exception as e:
        print(json.dumps({"status":"ERROR","msg":str(e)[:200]})); sys.exit(2)
