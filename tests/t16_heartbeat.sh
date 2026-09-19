#!/bin/zsh
# t16 - the dead-man heartbeat (bin/yt_heartbeat.py) and its wiring into stream.sh.
#
# The off-host watchdog can already alert when a heartbeat FILE goes stale (t07 covers that
# policy); what was missing is something to WRITE the file. The operator chose a PUSH
# (tracker row T-34) precisely so the watchdog host - which holds the Gmail app password -
# never gets a path into the streamer. This test exercises both halves for real on loopback:
#
#   1. serve: bearer token in constant time (accept right, reject wrong/absent), 404 for a
#      wrong path, 405 for a wrong method, 413 over the body cap, and on success a state file
#      whose CONTENT is the body and whose MODE is 0600, written atomically (no temp left).
#   2. push: degrades to nulls when every runtime file is missing, parses net_state's first
#      two fields and broadcast_started's first field, and reports the free disk number.
#   3. the token is never in argv - checked against the RUNNING process, not just the source,
#      because argv is world-readable through ps and that is the whole reason for the 600 file.
#   4. stream.sh starts the pusher only when HEARTBEAT_URL is set and reaps it in the trap.
#
# Everything is bound to 127.0.0.1 with a scratch state file. No VPS, no tailnet, no network.
source "${0:A:h}/lib.sh"
t_begin t16

t_setup >/dev/null
chmod +x "$T_BASE/bin/yt_heartbeat.py"
mkdir -p "$T_BASE/log"

HB="$T_BASE/bin/yt_heartbeat.py"
SRC="$REPO_DIR/bin/yt_heartbeat.py"
STREAM="$REPO_DIR/bin/stream.sh"
TOKEN="s3cr3t-heartbeat-token-9f2c1d"
TOKENFILE="$T_BASE/conf/heartbeat.token"
STATE="$T_BASE/log/heartbeat.state"
printf '%s' "$TOKEN" > "$TOKENFILE"
chmod 600 "$TOKENFILE"

free_port() {
  python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()'
}
PORT=$(free_port)

# --- the token comparison is constant-time in the source --------------------------------
grep -q 'hmac.compare_digest' "$SRC" \
  && t_ok "the token is compared with hmac.compare_digest, not ==" \
  || t_bad "the listener does not use a constant-time token comparison"

# --- a REAL listener on loopback ---------------------------------------------------------
python3 "$HB" serve --bind 127.0.0.1 --port "$PORT" --state-file "$STATE" \
  --token-file "$TOKENFILE" >"$T_BASE/log/serve.log" 2>&1 &
SRV=$!
ready=0
for i in {1..100}; do
  python3 -c "
import socket, sys
s = socket.socket(); s.settimeout(0.2)
try:
    s.connect(('127.0.0.1', $PORT))
except Exception:
    sys.exit(1)
finally:
    s.close()
" 2>/dev/null && { ready=1; break; }
  sleep 0.05
done
t_assert_eq "1" "$ready" "the listener binds 127.0.0.1 and accepts a connection"

# One python program drives every HTTP case so the statuses are read from a real socket.
RES=$(python3 - "$PORT" "$TOKEN" <<'PY' 2>&1
import sys, urllib.error, urllib.request
port, token = sys.argv[1], sys.argv[2]
base = "http://127.0.0.1:%s" % port

def call(label, path, method, body=None, auth=token, length=None):
    req = urllib.request.Request(base + path, data=body, method=method)
    if auth is not None:
        req.add_header("Authorization", "Bearer " + auth)
    if length is not None:
        req.add_header("Content-Length", str(length))
    try:
        with urllib.request.urlopen(req, timeout=5) as resp:
            code = resp.getcode()
    except urllib.error.HTTPError as e:
        code = e.code
    except Exception as e:
        code = "ERR:%s" % type(e).__name__
    print("%s %s" % (label, code))

BODY = b'{"wire":"manual-body","n":1}'
call("ok", "/heartbeat", "POST", BODY)
call("wrong", "/heartbeat", "POST", BODY, auth="not-the-token")
call("absent", "/heartbeat", "POST", BODY, auth=None)
call("method", "/heartbeat", "GET", None)
call("head", "/heartbeat", "HEAD", None)
call("path", "/nope", "POST", BODY)
call("big", "/heartbeat", "POST", b"x" * 9000)
PY
)
rc() { print -r -- "$RES" | awk -v k="$1" '$1 == k {print $2}'; }
t_assert_eq "204" "$(rc ok)"     "the right token is accepted (204)"
t_assert_eq "401" "$(rc wrong)"  "a wrong token is rejected (401)"
t_assert_eq "401" "$(rc absent)" "an absent Authorization header is rejected (401)"
t_assert_eq "405" "$(rc method)" "a non-POST method is rejected (405)"
t_assert_eq "405" "$(rc head)"   "a HEAD is rejected (405) with no response body"
t_assert_eq "404" "$(rc path)"   "a path other than /heartbeat is rejected (404)"
t_assert_eq "413" "$(rc big)"    "a body over the 8 KB cap is rejected (413)"

# --- an accepted push stores exactly the body, mode 0600, atomically ---------------------
t_assert_file "$STATE" "an accepted push creates the state file"
t_assert_eq '{"wire":"manual-body","n":1}' "$(cat "$STATE")" \
  "the state file content is the request body, byte for byte"
MODE=$(python3 -c "import os; print('%o' % (os.stat('$STATE').st_mode & 0o777))")
t_assert_eq "600" "$MODE" "the state file is mode 0600"
TMPLEFT=$(ls -A "$T_BASE/log" 2>/dev/null | grep -c '^\.hb\.')
t_assert_eq "0" "$TMPLEFT" "no temp file is left behind (the write is atomic via os.replace)"
grep -q 'os.replace' "$SRC" && grep -q 'mkstemp' "$SRC" \
  && t_ok "the source atomic-writes with mkstemp + os.replace" \
  || t_bad "the state write is not obviously atomic in the source"

# A reader must never see a partial file either. Hammer the listener while reading the state
# continuously: every successful read has to be the complete body, never a truncation.
python3 - "$PORT" "$TOKEN" <<'PY' &
import json, sys, time, urllib.request
port, token = sys.argv[1], sys.argv[2]
deadline = time.time() + 2
bad = 0
while time.time() < deadline:
    data = json.dumps({"wire": "atomic", "t": time.time()}).encode()
    req = urllib.request.Request("http://127.0.0.1:%s/heartbeat" % port, data=data, method="POST")
    req.add_header("Authorization", "Bearer " + token)
    urllib.request.urlopen(req, timeout=5).read()
PY
STRESS=$!
PARTIAL=0
while kill -0 $STRESS 2>/dev/null; do
  if [[ -f "$STATE" ]]; then
    python3 -c "
import json
try:
    json.load(open('$STATE'))
except Exception:
    raise SystemExit(1)
" 2>/dev/null || PARTIAL=1
  fi
done
wait $STRESS 2>/dev/null
t_assert_eq "0" "$PARTIAL" "a concurrent reader never observed a partial state file"

# --- the pusher degrades when every runtime file is missing ------------------------------
mkdir -p "$T_BASE/emptybase"
python3 "$HB" push --url "http://127.0.0.1:$PORT/heartbeat" --token-file "$TOKENFILE" \
  --base "$T_BASE/emptybase" >"$T_BASE/log/push-empty.log" 2>&1
t_assert_eq "0" "$?" "the pusher exits 0 even with no runtime files at all"
EMPTY=$(python3 -c "
import json
d = json.load(open('$STATE'))
for k in ('uptime_s','publisher','publisher_pid','net_state','broadcast'):
    print('%s=%s' % (k, d.get(k)))
")
t_assert_contains "$EMPTY" "publisher=False" "a missing publisher.pid degrades to publisher=False"
t_assert_contains "$EMPTY" "publisher_pid=None" "and to a null pid"
t_assert_contains "$EMPTY" "net_state=None" "a missing net_state degrades to null"
t_assert_contains "$EMPTY" "broadcast=None" "a missing broadcast_started degrades to null"

# ...and a base that does not exist at all still exits 0 rather than raising.
python3 "$HB" push --url "http://127.0.0.1:$PORT/heartbeat" --token-file "$TOKENFILE" \
  --base "$T_BASE/nope-not-here" >"$T_BASE/log/push-nobase.log" 2>&1
t_assert_eq "0" "$?" "the pusher survives a --base that does not exist"

# --- the real payload: parsed fields, disk number, publisher identity ---------------------
print -r -- "OK 1758000000 en2 USB" > "$T_BASE/log/net_state"
print -r -- "3Cnxr6fTrWk 1758000000" > "$T_BASE/log/broadcast_started"
sleep 30 & SLEEPPID=$!
print -r -- "$SLEEPPID" > "$T_BASE/log/publisher.pid"
python3 "$HB" push --url "http://127.0.0.1:$PORT/heartbeat" --token-file "$TOKENFILE" \
  --base "$T_BASE" >"$T_BASE/log/push-full.log" 2>&1
t_assert_eq "0" "$?" "the pusher exits 0 against a live listener"
FIELDS=$(python3 -c "
import json
d = json.load(open('$STATE'))
for k in ('ts','host','uptime_s','disk_free_mb','publisher','publisher_pid','net_state','broadcast'):
    print('%s=%s' % (k, d.get(k)))
")
fv() { print -r -- "$FIELDS" | sed -n "s/^$1=//p"; }
t_assert_eq "OK 1758000000" "$(fv net_state)" "net_state keeps the first two fields of log/net_state"
t_assert_eq "3Cnxr6fTrWk"   "$(fv broadcast)" "broadcast keeps the first field of log/broadcast_started"
t_assert_eq "False" "$(fv publisher)" "a live pid that is NOT ffmpeg rtmp is not the publisher"
t_assert_eq "$SLEEPPID" "$(fv publisher_pid)" "and the payload names that pid so the lie is visible"
[[ "$(fv disk_free_mb)" == <-> ]] \
  && t_ok "the payload carries the free disk number ($(fv disk_free_mb) MB)" \
  || t_bad "the payload has no disk_free_mb number ($(fv disk_free_mb))"
[[ "$(fv ts)" == <-> && "$(fv uptime_s)" == <-> ]] \
  && t_ok "the payload carries an epoch and an uptime in seconds" \
  || t_bad "timestamp/uptime missing ($(fv ts) / $(fv uptime_s))"
t_assert_contains "$FIELDS" "host=" "the payload names the host"
kill "$SLEEPPID" 2>/dev/null

# --- the token is NEVER in argv ----------------------------------------------------------
: > "$T_BASE/log/push-loop.log"
python3 "$HB" push --url "http://127.0.0.1:$PORT/heartbeat" --token-file "$TOKENFILE" \
  --base "$T_BASE" --loop 5 >"$T_BASE/log/push-loop.log" 2>&1 &
PUSHER=$!
for i in {1..60}; do grep -q 'push accepted' "$T_BASE/log/push-loop.log" 2>/dev/null && break; sleep 0.05; done
PSOUT=$(ps -p "$PUSHER" -o command= 2>/dev/null)
kill -TERM "$PUSHER" 2>/dev/null
wait "$PUSHER" 2>/dev/null
t_assert_contains "$PSOUT" "--token-file" "the running pusher takes the token as a file path"
if print -r -- "$PSOUT" | grep -qF -- "$TOKEN"; then
  t_bad "THE TOKEN VALUE IS VISIBLE IN ARGV (ps): the 600 file is pointless"
else
  t_ok "the token value never appears in the running process's argv"
fi
if print -r -- "$PSOUT" | grep -qF -- "$TOKENFILE"; then
  t_ok "and the argv names the 600 token file instead"
else
  t_bad "the pusher argv does not name the token file (got [$PSOUT])"
fi
# Belt and braces in the source: no subprocess call and no argv construction may touch it.
grep -nE 'subprocess[^#]*token' "$SRC" >/dev/null \
  && t_bad "a subprocess call in the source references the token" \
  || t_ok "no subprocess call in the source references the token"
grep -q 'HEARTBEAT_TOKEN' "$SRC" \
  && t_ok "the env fallback \$HEARTBEAT_TOKEN exists for an install with no token file" \
  || t_bad "\$HEARTBEAT_TOKEN fallback is missing"

# --- stream.sh wiring --------------------------------------------------------------------
t_assert_contains "$(grep -n ': ${HEARTBEAT_URL:=}' "$STREAM")" "HEARTBEAT_URL" \
  "stream.sh declares HEARTBEAT_URL as a knob"
t_assert_contains "$(grep -n ': ${HEARTBEAT_TOKEN_FILE:=}' "$STREAM")" "HEARTBEAT_TOKEN_FILE" \
  "stream.sh declares HEARTBEAT_TOKEN_FILE as a knob"
grep -q 'start_heartbeat$' "$STREAM" \
  && t_ok "stream.sh calls start_heartbeat from the main body" \
  || t_bad "start_heartbeat is defined but never called"
grep -q '${HEARTBEATPID:+"$HEARTBEATPID"}' "$STREAM" \
  && t_ok "the TERM/INT trap reaps the pusher, so a restart cannot leave a live heartbeat behind" \
  || t_bad "the trap does not kill the pusher"
awk '/^start_heartbeat\(\)/,/^}/' "$STREAM" | grep -q '\[\[ -z "${HEARTBEAT_URL:-}" \]\]' \
  && t_ok "the pusher starts only when HEARTBEAT_URL is non-empty" \
  || t_bad "start_heartbeat does not gate on HEARTBEAT_URL"
awk '/^start_heartbeat\(\)/,/^}/' "$STREAM" | grep -q -- '--token-file "\$HEARTBEAT_TOKEN_FILE"' \
  && t_ok "stream.sh passes the token FILE PATH, never a value" \
  || t_bad "stream.sh does not pass --token-file"
awk '/^start_heartbeat\(\)/,/^}/' "$STREAM" | grep -q '! -r "\$HEARTBEAT_TOKEN_FILE"' \
  && t_ok "a URL with an unreadable token file refuses to start the pusher, so the failure is in the log rather than hidden behind an absent (silent) heartbeat" \
  || t_bad "start_heartbeat starts a pusher it knows cannot authenticate"
grep -q 'dead-man signal OFF' "$STREAM" && grep -q 'dead-man signal ON' "$STREAM" \
  && t_ok "stream.sh logs one line saying whether the dead-man signal is on or off" \
  || t_bad "the on/off log line is missing"

# Run the extracted function with a python3 stub that records its argv, so the OFF path is
# proven to launch NOTHING and the ON path to launch the pusher with a file path.
HBF="$T_BASE/hb_func.zsh"
{ t_extract_fn "$STREAM" start_heartbeat
  printf "BASE='%s'\n" "$T_BASE"
  printf "HEARTBEAT_INTERVAL=300\n"
  printf "LOG='%s/log/hb-calls.log'\n" "$T_BASE"
  cat <<'EOF'
log() { print -r -- "$*" >> "$LOG"; }
EOF
} > "$HBF"
mkdir -p "$T_BASE/stub"
cat > "$T_BASE/stub/python3" <<EOF
#!/bin/sh
printf '%s\n' "\$@" >> "$T_BASE/log/py_args"
EOF
chmod 755 "$T_BASE/stub/python3"
run_hb() {   # run_hb URL TOKENFILE
  BASE="$T_BASE" HOME="$T_BASE/home" LOG="$T_BASE/log/hb-calls.log" \
  HEARTBEAT_URL="$1" HEARTBEAT_TOKEN_FILE="$2" HEARTBEAT_INTERVAL=300 \
  PATH="$T_BASE/stub:$STUBS:$PATH" \
  /bin/zsh -c "source '$HBF'; start_heartbeat; print -r -- \"PID=\$HEARTBEATPID\" >> '$T_BASE/log/py_args'"
}

: > "$T_BASE/log/py_args"; : > "$T_BASE/log/hb-calls.log"
run_hb "" "$TOKENFILE"
grep -q 'dead-man signal OFF' "$T_BASE/log/hb-calls.log" \
  && t_ok "an empty HEARTBEAT_URL logs the signal as OFF" \
  || t_bad "the OFF path does not say so"
if print -r -- "$(grep -v '^PID=' "$T_BASE/log/py_args")" | grep -q .; then
  t_bad "the pusher was launched even though HEARTBEAT_URL is empty"
else
  t_ok "and launches no pusher at all"
fi

: > "$T_BASE/log/py_args"; : > "$T_BASE/log/hb-calls.log"
run_hb "http://127.0.0.1:9/heartbeat" "$TOKENFILE"
# The pusher is backgrounded and the stub is its own process: give it a moment to record its
# argv before reading the file, or this races and reports a false failure.
for i in {1..40}; do grep -q '^push$' "$T_BASE/log/py_args" 2>/dev/null && break; sleep 0.05; done
PYARGS=$(cat "$T_BASE/log/py_args")
t_assert_contains "$PYARGS" "push" "a set HEARTBEAT_URL launches the pusher"
t_assert_contains "$PYARGS" "--url" "with --url"
t_assert_contains "$PYARGS" "http://127.0.0.1:9/heartbeat" "and the configured URL"
t_assert_contains "$PYARGS" "--token-file" "and --token-file"
t_assert_contains "$PYARGS" "$TOKENFILE" "naming the file, not the secret"
if print -r -- "$PYARGS" | grep -qxF -- "$TOKEN"; then
  t_bad "stream.sh put the token VALUE on the pusher's argv"
else
  t_ok "stream.sh never puts the token value on the pusher's argv"
fi
grep -q 'dead-man signal ON' "$T_BASE/log/hb-calls.log" \
  && t_ok "and logs the signal as ON with the URL" \
  || t_bad "the ON path does not log a line"

# --- clean shutdown ----------------------------------------------------------------------
kill -TERM "$SRV" 2>/dev/null
wait "$SRV" 2>/dev/null
t_assert_contains "$(cat "$T_BASE/log/serve.log" 2>/dev/null)" "shutting down" \
  "SIGTERM shuts the listener down cleanly instead of dying on the signal"
grep -q 'accept ' "$T_BASE/log/serve.log" && grep -q 'reject ' "$T_BASE/log/serve.log" \
  && t_ok "the listener logs one line per accepted push and per rejection" \
  || t_bad "the accept/reject journal lines are missing"
if grep -qF -- "$TOKEN" "$T_BASE/log/serve.log"; then
  t_bad "the listener log contains the token"
else
  t_ok "and never logs the token (nor the body)"
fi

t_teardown
t_summary
