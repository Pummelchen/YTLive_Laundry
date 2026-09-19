#!/usr/bin/env python3
"""Carry the streamer's dead-man heartbeat to the external watchdog (tracker row T-34).

WHY THIS EXISTS
---------------
bin/yt_watchdog.py can alert when the STREAMER APPLICATION goes silent, but only if a file
named by WATCH_HEARTBEAT keeps being touched: `heartbeat_state()` calls it `stale` when the
file exists and its mtime is older than WATCH_HEARTBEAT_MAX, and `decide()` then raises the
`silent` alert. A file that is *absent* is deliberately never an outage - that is an
unconfigured deployment, not a dead app - so shipping the watchdog without a writer is safe
but blind. Something has to write that file. This is that something, with no change needed on
the watchdog side.

The operator chose PUSH over PULL (docs/watchdog.md, tracker row T-34). The direction is the
whole security argument: this VPS holds a Gmail app password and the streamer holds a YouTube
OAuth refresh token, so a pull that let the watchdog reach *into* the streamer would widen the
blast radius of a compromised watchdog host. Instead the streamer is the only side that
initiates: it POSTs a small status document to a listener here, and the listener stores it. The
watchdog host never dials the streamer.

TWO MODES, ONE WIRE FORMAT
--------------------------
    yt_heartbeat.py serve   the listener, on the WATCHDOG host (systemd: ytlive-heartbeat)
    yt_heartbeat.py push    the sender, on the STREAMER (started by bin/stream.sh)

Both live in one file so the format has exactly one implementation and cannot drift.

THE WIRE FORMAT (JSON object, UTF-8, one POST body)
---------------------------------------------------
    ts             int    epoch seconds when the payload was built
    host           str    socket.gethostname() of the streamer
    uptime_s       int    seconds since boot, or null if it cannot be read
    disk_free_mb   int    free MB on the volume holding --base, or null
    publisher      bool   is log/publisher.pid alive AND its command ffmpeg + rtmp
    publisher_pid  int    that pid, or null
    net_state      str    first two fields of log/net_state ("<state> <epoch>"), or null
    broadcast      str    first field of log/broadcast_started (the broadcast id), or null

Every runtime read degrades to null; a missing file is never an exception. The listener does
NOT parse the body: the watchdog only reads the FILE'S MTIME, so the body exists purely so a
human debugging a stale heartbeat can see what the streamer thought was true when it last
pushed. Nothing in this file evaluates it, and nothing should.

SECURITY
--------
- The bearer token is read from a 600 file (--token-file) or $HEARTBEAT_TOKEN, NEVER from a
  command line: argv is world-readable through `ps`, which is the same rule the camera
  credentials already follow. push builds no argv that contains the secret.
- Token comparison on the listener uses hmac.compare_digest, so a wrong token cannot be
  recovered by timing the answer.
- The body is capped at MAX_BODY (8 KB) and rejected above it, and the request line/headers
  are already bounded by http.server. The body is stored as opaque bytes.
- The state file is written to a temp file in the same directory and os.replace()d into place,
  so a reader (the watchdog, stat-only) can never observe a partial write. Mode 0600.
- Bind to the tailnet address only. WireGuard already encrypts the tailnet, so plain HTTP is
  correct here and TLS would be ceremony; binding 0.0.0.0 would put a token-accepting socket
  on every interface, which is not.

Python 3.8+, standard library only - deliberately portable, like bin/yt_watchdog.py, because
the two halves run on different operating systems (the streamer is macOS, the watchdog host is
Linux).

USAGE
-----
    # on the watchdog host (the unit does this):
    yt_heartbeat.py serve --bind 100.99.149.11 --port 8787 \
        --state-file /var/ytlive-watchdog/heartbeat \
        --token-file /var/ytlive-watchdog/conf/heartbeat.token

    # on the streamer (bin/stream.sh does this):
    yt_heartbeat.py push --url http://100.99.149.11:8787/heartbeat \
        --token-file "$HOME/Downloads/YTLive/conf/heartbeat.token" --loop 300
"""
import argparse
import hmac
import json
import os
import re
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# The listener's hard limits. 8 KB is thousands of times larger than any payload push emits;
# the cap is here so a hostile or broken client cannot make the listener buffer forever.
MAX_BODY = 8 * 1024
DEFAULT_PORT = 8787
HEARTBEAT_PATH = "/heartbeat"
AUTH_PREFIX = "Bearer "
# The publisher identity needles, the same idea as bin/lib.sh's pidfile_pid: a recycled pid
# must not be mistaken for our ffmpeg. Both must appear in the process command line.
PUB_NEEDLES = ("ffmpeg", "rtmp")


def out(msg):
    """One timestamped line to stdout - systemd's journal, never the body."""
    print(time.strftime("%Y-%m-%d %H:%M:%S") + " " + msg, flush=True)


def err(msg):
    print("yt_heartbeat: " + msg, file=sys.stderr, flush=True)


# --------------------------------------------------------------------------------------
# push - the streamer side
# --------------------------------------------------------------------------------------
def resolve_token(token_file=None):
    """The bearer token as str, from --token-file (preferred) or $HEARTBEAT_TOKEN.

    Deliberately never a command-line argument. Returns None when nothing is configured so
    the caller can fail honestly instead of pushing with an empty secret.
    """
    if token_file:
        try:
            with open(token_file, "r") as fh:
                token = fh.read().strip()
        except OSError as e:
            err("cannot read --token-file %s (%s)" % (token_file, e))
            return None
        if not token:
            err("--token-file %s is empty" % token_file)
            return None
        return token
    token = (os.environ.get("HEARTBEAT_TOKEN") or "").strip()
    if token:
        return token
    err("no token: pass --token-file PATH or set HEARTBEAT_TOKEN")
    return None


def uptime_seconds():
    """Seconds since boot, or None. /proc/uptime on Linux, kern.boottime on macOS."""
    try:
        with open("/proc/uptime", "r") as fh:
            return int(float(fh.read().split()[0]))
    except Exception:
        pass
    try:
        res = subprocess.run(["sysctl", "-n", "kern.boottime"],
                             stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                             timeout=5)
        m = re.search(r"sec\s*=\s*(\d+)", res.stdout.decode("utf-8", "replace"))
        if m:
            return int(max(0, time.time() - int(m.group(1))))
    except Exception:
        pass
    return None


def disk_free_mb(base):
    """Free MB on the volume holding BASE, or None. Never raises on a missing path."""
    candidates = [base]
    parent = os.path.dirname(os.path.abspath(base))
    if parent and parent not in candidates:
        candidates.append(parent)
    if "/" not in candidates:
        candidates.append("/")
    for path in candidates:
        try:
            return int(shutil.disk_usage(path).free // (1024 * 1024))
        except OSError:
            continue
    return None


def first_fields(path, n):
    """The first n whitespace-separated fields of the file's first line, joined by single
    spaces; None when the file is missing, empty or unreadable."""
    try:
        with open(path, "r") as fh:
            line = fh.readline().strip()
    except OSError:
        return None
    parts = line.split()
    if not parts:
        return None
    return " ".join(parts[:n])


def publisher_state(base):
    """(running, pid) for log/publisher.pid.

    A pid is only trusted when it is alive AND its command line carries every needle in
    PUB_NEEDLES - the Python spelling of lib.sh's pidfile_pid(), so a recycled pid cannot
    make a dead publisher look alive. Anything unreadable degrades to (False, pid-or-None).
    """
    pid = None
    try:
        with open(os.path.join(base, "log", "publisher.pid"), "r") as fh:
            pid = int(fh.read().strip())
    except (OSError, ValueError):
        return False, None
    if pid <= 0:
        return False, None
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False, pid
    except PermissionError:
        pass  # alive, owned by someone else
    except OSError:
        return False, pid
    try:
        res = subprocess.run(["ps", "-p", str(pid), "-o", "command="],
                             stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                             timeout=5)
        cmd = res.stdout.decode("utf-8", "replace")
    except Exception:
        return False, pid
    return all(n in cmd for n in PUB_NEEDLES), pid


def build_payload(base):
    """The wire document. Every read degrades to null; this function does not raise."""
    running, pid = publisher_state(base)
    return {
        "ts": int(time.time()),
        "host": socket.gethostname(),
        "uptime_s": uptime_seconds(),
        "disk_free_mb": disk_free_mb(base),
        "publisher": bool(running),
        "publisher_pid": pid,
        "net_state": first_fields(os.path.join(base, "log", "net_state"), 2),
        "broadcast": first_fields(os.path.join(base, "log", "broadcast_started"), 1),
    }


def push_once(url, token, payload, timeout):
    """POST one payload. Returns (ok, detail); never raises."""
    data = json.dumps(payload, separators=(",", ":")).encode("utf-8")
    req = urllib.request.Request(
        url, data=data, method="POST",
        headers={"Content-Type": "application/json",
                 "Content-Length": str(len(data)),
                 "Authorization": AUTH_PREFIX + token,
                 "User-Agent": "ytlive-heartbeat/1.0"})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            code = int(resp.getcode() or 0)
        return (200 <= code < 300), "HTTP %d" % code
    except urllib.error.HTTPError as e:
        return False, "HTTP %d" % e.code
    except Exception as e:
        # str(e) is the transport error; it never contains the token, which only ever
        # travelled in a header.
        return False, "%s: %s" % (type(e).__name__, e)


def run_push(args):
    token = resolve_token(args.token_file)
    if token is None:
        return 1
    if not args.url:
        err("push needs --url, e.g. http://100.99.149.11:8787/heartbeat")
        return 1
    base = args.base or os.environ.get("BASE") or os.path.join("~", "Downloads", "YTLive")
    base = os.path.expanduser(base)
    if args.loop and args.loop > 0:
        out("pushing to %s every %gs (base %s)" % (args.url, args.loop, base))
    while True:
        started = time.monotonic()
        payload = build_payload(base)
        ok, detail = push_once(args.url, token, payload, args.timeout)
        if ok:
            out("push accepted (%s) broadcast=%s disk=%s publisher=%s"
                % (detail, payload.get("broadcast"), payload.get("disk_free_mb"),
                   payload.get("publisher")))
        else:
            out("push FAILED (%s) - will retry; the watchdog alerts only if this stays "
                "broken past WATCH_HEARTBEAT_MAX" % detail)
        if not args.loop or args.loop <= 0:
            return 0 if ok else 1
        # Measure the interval from the START of the attempt, so a slow or failed push
        # cannot add the request time and drift into a tight loop.
        delay = args.loop - (time.monotonic() - started)
        if delay > 0:
            time.sleep(delay)


# --------------------------------------------------------------------------------------
# serve - the watchdog-host side
# --------------------------------------------------------------------------------------
def write_state(path, data):
    """Atomically replace `path` with `data`. A reader sees the old file or the new one."""
    directory = os.path.dirname(os.path.abspath(path)) or "."
    if not os.path.isdir(directory):
        os.makedirs(directory, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=".hb.", suffix=".tmp", dir=directory)
    try:
        with os.fdopen(fd, "wb") as fh:
            fh.write(data)
            fh.flush()
            os.fsync(fh.fileno())
        os.chmod(tmp, 0o600)  # mkstemp already does this; belt and braces
        os.replace(tmp, path)
    except Exception:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


class HeartbeatServer(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def __init__(self, addr, handler, state_file, token):
        super().__init__(addr, handler)
        self.state_file = state_file
        self.token = token


class Handler(BaseHTTPRequestHandler):
    server_version = "ytlive-heartbeat/1.0"
    protocol_version = "HTTP/1.1"

    # Our own lines are the journal; the stock per-request log is noise.
    def log_message(self, fmt, *args):
        pass

    def _reply(self, code, text):
        body = (text + "\n").encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        # A HEAD response has the headers of the GET it mirrors and no body at all.
        if self.command != "HEAD":
            self.wfile.write(body)

    def _reject(self, code, reason):
        peer = self.client_address[0]
        out("reject %d %s from %s" % (code, reason, peer))
        self._reply(code, reason)

    def _send_no_content(self):
        self.send_response(204)
        # 204 carries no body and no Content-Length; closing the connection is how an
        # HTTP/1.1 client knows the response is complete.
        self.close_connection = True
        self.end_headers()

    def _token_ok(self):
        header = self.headers.get("Authorization", "")
        provided = header[len(AUTH_PREFIX):] if header.startswith(AUTH_PREFIX) else ""
        # Constant time on both sides; a wrong token is not distinguishable by timing.
        return hmac.compare_digest(provided.encode("utf-8"), self.server.token)

    def do_POST(self):
        try:
            if self.path.split("?", 1)[0] != HEARTBEAT_PATH:
                self._reject(404, "not found")
                return
            if not self._token_ok():
                self._reject(401, "bad or missing token")
                return
            raw_len = self.headers.get("Content-Length")
            if raw_len is None:
                self.close_connection = True
                self._reject(411, "length required")
                return
            try:
                length = int(raw_len)
            except ValueError:
                self.close_connection = True
                self._reject(400, "bad content-length")
                return
            if length < 0 or length > MAX_BODY:
                # Do not drain a body we have already refused.
                self.close_connection = True
                self._reject(413, "body too large (max %d bytes)" % MAX_BODY)
                return
            body = self.rfile.read(length)
            if len(body) != length:
                self.close_connection = True
                self._reject(400, "short body")
                return
            write_state(self.server.state_file, body)
            out("accept %d bytes from %s -> %s"
                % (len(body), self.client_address[0], self.server.state_file))
            self._send_no_content()
        except Exception as e:
            # One malformed client must never take the accept loop down.
            out("error handling request from %s: %s: %s"
                % (self.client_address[0], type(e).__name__, e))
            try:
                self.close_connection = True
                self._reply(500, "internal error")
            except Exception:
                pass

    def do_GET(self):
        self._reject(405, "method not allowed")

    def do_PUT(self):
        self._reject(405, "method not allowed")

    def do_DELETE(self):
        self._reject(405, "method not allowed")

    def do_HEAD(self):
        self._reject(405, "method not allowed")


def read_token_bytes(path):
    try:
        with open(path, "rb") as fh:
            token = fh.read().strip()
    except OSError as e:
        err("cannot read --token-file %s (%s)" % (path, e))
        return None
    if not token:
        err("--token-file %s is empty" % path)
        return None
    return token


def run_serve(args):
    token = read_token_bytes(args.token_file)
    if token is None:
        return 1
    state_file = os.path.abspath(args.state_file)
    try:
        server = HeartbeatServer((args.bind, args.port), Handler, state_file, token)
    except OSError as e:
        # A listener that silently is not listening is worse than no listener: the heartbeat
        # would stay absent and nothing would say why the dead-man signal is dead. Fail loud.
        err("cannot bind %s:%d (%s)" % (args.bind, args.port, e))
        err("refusing to run: nothing would be listening, and the heartbeat file would "
            "never be written")
        return 1

    def stop(signum, _frame):
        out("received signal %d - shutting down" % signum)
        # shutdown() must run off the serve_forever thread; the signal handler IS that
        # thread, so hand the shutdown to a helper thread and let serve_forever return.
        threading.Thread(target=server.shutdown, daemon=True).start()

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    out("listening on %s:%d -> %s (token from %s)"
        % (args.bind, args.port, state_file, args.token_file))
    try:
        server.serve_forever(poll_interval=0.5)
    finally:
        server.server_close()
        out("stopped")
    return 0


def build_parser():
    parser = argparse.ArgumentParser(
        prog="yt_heartbeat.py",
        description="Push the streamer's dead-man heartbeat to the external watchdog host.")
    sub = parser.add_subparsers(dest="mode", required=True)

    srv = sub.add_parser("serve", help="listen for pushes (on the watchdog host)")
    srv.add_argument("--bind", default="127.0.0.1",
                     help="address to bind; the unit passes the tailnet address (default 127.0.0.1)")
    srv.add_argument("--port", type=int, default=DEFAULT_PORT,
                     help="port to listen on (default %d)" % DEFAULT_PORT)
    srv.add_argument("--state-file", required=True,
                     help="file to write on each accepted push (the watchdog's WATCH_HEARTBEAT)")
    srv.add_argument("--token-file", required=True,
                     help="600 file holding the bearer token")

    psh = sub.add_parser("push", help="send a heartbeat (on the streamer)")
    psh.add_argument("--url", required=True,
                     help="listener URL, e.g. http://100.99.149.11:8787/heartbeat")
    psh.add_argument("--token-file", default=None,
                     help="600 file holding the bearer token ($HEARTBEAT_TOKEN is the fallback)")
    psh.add_argument("--base", default=None,
                     help="streamer checkout (default $BASE or ~/Downloads/YTLive)")
    psh.add_argument("--loop", type=float, default=None,
                     help="repeat every N seconds; without it, push once and exit")
    psh.add_argument("--timeout", type=float, default=10.0,
                     help="per-request timeout in seconds (default 10)")
    return parser


def main(argv=None):
    # Belt and braces: nothing below may ever show a traceback. systemd's journal wants a
    # clean sentence, and a pusher sprayed into stream.log must not look like a crash.
    try:
        args = build_parser().parse_args(argv)
        if args.mode == "serve":
            return run_serve(args)
        return run_push(args)
    except KeyboardInterrupt:
        return 0
    except SystemExit:
        raise
    except Exception as e:
        err("%s: %s" % (type(e).__name__, e))
        return 1


if __name__ == "__main__":
    sys.exit(main())
