#!/bin/zsh
# t04 - the OAuth token check must report the TRUTH, not a day countdown.
#
# The credential is load-bearing: bin/stream.sh's prepare_broadcast() creates and binds the next
# broadcast on every cut, so a dead token means the channel goes dark at the next rotation.
# "Dead" was previously inferred from a hardcoded 7-day countdown, which is only a guess about
# Google's Testing-mode rule and is wrong the moment the OAuth app is published - a published
# app's refresh token does not expire on a clock. So the check now PROBES (mints a real access
# token) and the countdown is advisory. These are the contract checks that need no network.
source "${0:A:h}/lib.sh"
t_begin t04

Y="$REPO_DIR/bin/yt_api.py"

t_setup >/dev/null
run() { BASE="$T_BASE" YT_TOKEN_TTL_DAYS="${TTL:-7}" python3 "$Y" "$@"; }

# --- no credentials at all ---------------------------------------------------------------
rm -f "$T_BASE/conf/yt_oauth.json"
out=$(run token 2>&1); rc=$?
t_assert_eq "2" "$rc" "token with no credentials exits 2"
t_assert_eq "1" "$(print -r -- "$out" | grep -c '')" "token with no credentials prints exactly one JSON line"
t_assert_contains "$out" '"probe": "UNKNOWN"' "a missing credential file is UNKNOWN, not a false EXPIRED"

out=$(run token --offline 2>&1); rc=$?
t_assert_eq "2" "$rc" "token --offline with no credentials exits 2"
t_assert_contains "$out" '"offline": true' "token --offline says it is offline"

# --- credentials that cannot work --------------------------------------------------------
print -r -- '{}' > "$T_BASE/conf/yt_oauth.json"
out=$(run token 2>&1); rc=$?
t_assert_eq "2" "$rc" "an empty credentials object exits 2"
t_assert_contains "$out" '"probe": "DEAD"' "missing client fields are reported DEAD without touching the network"

# --- the countdown is advisory, never authoritative --------------------------------------
# An elapsed countdown with a token Google still accepts must NOT be reported as an outage.
old=$(( $(date +%s) - 30*86400 ))
python3 -c "
import json
json.dump({'client_id':'x','client_secret':'y','refresh_token':'z','authorised_at':$old},
          open('$T_BASE/conf/yt_oauth.json','w'))
"
warn=$(BASE="$T_BASE" python3 - <<PY
import importlib.util, os, sys
spec = importlib.util.spec_from_file_location("yt_api", "$Y")
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
print(m.token_age_warning("LIVE") or "")
PY
)
t_assert_contains "$warn" "advisory only" "an elapsed countdown on a LIVE token is reported as advisory, not an outage"
if print -r -- "$warn" | grep -q "EXPIRED"; then
  t_bad "an elapsed countdown still says EXPIRED even though the probe proved the token live"
else
  t_ok "an elapsed countdown never says EXPIRED when the probe proved the token live"
fi

# --- offline: an elapsed countdown must never be a FAIL -----------------------------------
# Measured 2026-09-19: the live token was 14.3 days old and Google still accepted it, while
# `token --offline` (what `status.sh --no-net` runs) returned EXPIRED/exit 2 and told the
# operator to re-auth. Age is a prediction; the offline path proves nothing, so it warns.
out=$(run token --offline 2>&1); rc=$?
t_assert_eq "1" "$rc" "token --offline past the countdown warns (exit 1), it does not fail"
t_assert_contains "$out" '"status": "WARN"' "the offline status is WARN, not EXPIRED"
if print -r -- "$out" | grep -qE "EXPIRED|Run: bin/yt_api.py auth"; then
  t_bad "the offline countdown still claims the token is dead (EXPIRED / re-auth) on age alone"
else
  t_ok "the offline countdown never claims the token is dead on age alone"
fi
t_assert_contains "$out" "proves nothing" "it says plainly that age alone proves nothing"

warn2=$(BASE="$T_BASE" python3 - <<PY
import importlib.util
spec = importlib.util.spec_from_file_location("yt_api", "$Y")
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
print(m.token_age_warning(None) or "")
PY
)
t_assert_contains "$warn2" "bin/yt_api.py auth" "with no probe evidence, an elapsed countdown does tell the operator to re-auth"

# --- YT_TOKEN_TTL_DAYS=0 means "the app is published, there is no countdown" ---------------
TTL=0 out=$(run token --offline 2>&1); rc=$?
t_assert_eq "0" "$rc" "TTL=0 offline check passes (published app: no scheduled expiry)"
t_assert_contains "$out" '"status": "OK"' "TTL=0 offline check reports OK"

# --- secrets must never be created world-readable ----------------------------------------
mode_test=$(python3 - <<PY
import importlib.util, os, pathlib, stat
spec = importlib.util.spec_from_file_location("yt_api", "$Y")
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
m.save_creds({"client_id":"a","client_secret":"b","refresh_token":"c"})
p = pathlib.Path("$T_BASE/conf/yt_oauth.json")
print(oct(stat.S_IMODE(p.stat().st_mode)))
PY
)
t_assert_eq "0o600" "$mode_test" "save_creds writes the token file 0600 from the first byte"

t_teardown
t_summary
