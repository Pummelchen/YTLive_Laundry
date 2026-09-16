#!/bin/zsh
# t05 - the rotation must not cut when nothing can create the next broadcast, and the bind must
#       always precede ingest.
#
# Two invariants that have each cost real downtime:
#   1. prepare_broadcast() must run BEFORE the publisher ffmpeg starts. YouTube's autoStart fires
#      when ingest ARRIVES at a broadcast that is already bound; bind afterwards and the
#      broadcast sits in `ready` forever and manual transitions are refused. That cost 19 minutes
#      of dark air on 2026-09-05.
#   2. A cut with an unusable API creates no successor and takes the channel dark. Measured
#      2026-09-05: five hours dark. So the rotation now REFUSES and stays live unless
#      ROTATE_WITHOUT_API=yes.
source "${0:A:h}/lib.sh"
t_begin t05

STREAM="$REPO_DIR/bin/stream.sh"

# --- 1. bind before ingest ---------------------------------------------------------------
python3 - "$STREAM" <<'PY'
import re, sys
src = open(sys.argv[1]).read()
m = re.search(r'\nstart_publisher\(\) \{\n(.*?)\n\}\n', src, re.S)
if not m:
    sys.exit("could not find start_publisher()")
body = m.group(1)
prep = body.find("prepare_broadcast")
ff = max(body.find('-f flv'), body.find('"$FF" -y -hide_banner'))
if prep < 0:
    sys.exit("start_publisher never calls prepare_broadcast - nothing would create the next broadcast")
if ff < 0:
    sys.exit("could not find the publisher launch inside start_publisher")
if prep > ff:
    sys.exit(f"prepare_broadcast appears AFTER the publisher launch (char {prep} > {ff})")
print("ok")
PY
if (( $? == 0 )); then t_ok "start_publisher calls prepare_broadcast BEFORE it launches ffmpeg"; else t_bad "bind-before-ingest order is broken"; fi

# --- 2. the rotation gate ----------------------------------------------------------------
for needle in 'ROTATE_WITHOUT_API' 'ROTATE_API_RETRY' 'ROTATE_BLOCKED_UNTIL'; do
  if grep -qF -- "$needle" "$STREAM"; then t_ok "stream.sh consults $needle"; else t_bad "stream.sh does not consult $needle"; fi
done
# Fixed-string: this is the exact pattern the rotation greps for, and -F keeps the shell's own
# metacharacters out of this test's regex.
if grep -qF -- '"probe": *"LIVE"' "$STREAM"; then
  t_ok "stream.sh judges usability on the probe field, not on an exit status"
else
  t_bad "stream.sh does not read the probe field"
fi
if grep -qE '^: \$\{ROTATE_WITHOUT_API:=no\}' "$STREAM"; then
  t_ok "ROTATE_WITHOUT_API defaults to no (stay live rather than cut to darkness)"
else
  t_bad "ROTATE_WITHOUT_API does not default to no"
fi
# A refusal must set a deadline, otherwise the once-per-5s loop retries the cut forever.
if grep -q 'ROTATE_BLOCKED_UNTIL=\$(( now + ROTATE_API_RETRY ))' "$STREAM"; then
  t_ok "a refused rotation backs off for ROTATE_API_RETRY seconds"
else
  t_bad "a refused rotation does not back off"
fi
if grep -q 'ROTATE_BLOCKED_UNTIL )); then' "$STREAM"; then
  t_ok "the main loop honours the backoff deadline"
else
  t_bad "the main loop ignores the backoff deadline"
fi

# --- 3. api_usable(): the truth is the PROBE, not the exit status -------------------------
t_setup >/dev/null
print -r -- '{"client_id":"x","client_secret":"y","refresh_token":"z"}' > "$T_BASE/conf/yt_oauth.json"
API_USABLE=$(t_extract_fn "$STREAM" api_usable)
if [[ -z "$API_USABLE" ]]; then t_bad "could not extract api_usable"; t_summary; exit 1; fi

check_usable() {   # check_usable <json> [expected_exit]
  cat > "$T_BASE/bin/yt_api.py" <<EOF
import sys
print('''$1''')
sys.exit(${2:-0})
EOF
  chmod +x "$T_BASE/bin/yt_api.py"
  BASE="$T_BASE" /bin/zsh -c "
    source '$REPO_DIR/bin/lib.sh'
    YT_API='$T_BASE/bin/yt_api.py'
    $API_USABLE
    api_usable
  " 2>&1
}

out=$(check_usable '{"status":"OK","probe":"LIVE"}'); rc=$?
t_assert_eq "0" "$rc" "probe LIVE -> api_usable succeeds"
t_assert_eq "yes" "$out" "probe LIVE -> api_usable prints yes"

# An EXPIRING token still WORKS. Judging by exit status alone would refuse to rotate a healthy
# channel, so the check must read the probe field.
out=$(check_usable '{"status":"EXPIRING","probe":"LIVE","token_warning":"x"}' 1); rc=$?
t_assert_eq "0" "$rc" "probe LIVE with an EXPIRING countdown is still usable (exit status 1 is not 'dead')"
t_assert_eq "yes" "$out" "probe LIVE with EXPIRING -> api_usable prints yes"

out=$(check_usable '{"status":"EXPIRED","probe":"DEAD","msg":"rejected"}' 2); rc=$?
t_assert_eq "1" "$rc" "probe DEAD -> api_usable fails"
t_assert_contains "$out" "not usable" "probe DEAD -> api_usable explains why"

out=$(check_usable '{"status":"UNKNOWN","probe":"UNKNOWN","msg":"no network"}' 2); rc=$?
t_assert_eq "1" "$rc" "probe UNKNOWN -> api_usable fails (cannot confirm is not 'fine')"

t_teardown
t_summary
