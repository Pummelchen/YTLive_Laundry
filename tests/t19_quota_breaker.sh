#!/bin/zsh
# t19 - the quota guard must never outlive the truth.
#
# On 2026-10-28 a guard armed with the old six-hour default blocked every API call until
# 17:37 while YouTube's pool had been back since about 14:00. The streamer kept reporting
# "quota exhausted" against a recovery that had already happened, the vertical feed stayed
# dark, and the rotation refused four times. The guard was a fixed clock, and a fixed clock
# cannot tell whether reality changed.
#
# It is now a circuit breaker: capped backoff, and any successful request clears it.
source "${0:A:h}/lib.sh"
t_begin t19
t_setup >/dev/null

cat > "$T_BASE/probe.zsh" <<'PROBE'
import importlib.util, json, os, sys, time, pathlib
PY = pathlib.Path(os.environ["SCRIPT"])
spec = importlib.util.spec_from_file_location("yt_api", PY)
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
action = sys.argv[1]
if action == "span":
    prev = {"until": int(sys.argv[3]), "armed_at": int(sys.argv[4])} if len(sys.argv) > 3 and sys.argv[3] != "-" else {}
    print(m._quota_span(prev, int(sys.argv[2]), m.QUOTA_MAX_COOLDOWN))
elif action == "arm":
    print(m.quota_arm("test refusal"))
elif action == "record":
    print(json.dumps(m.quota_record()))
elif action == "clear":
    m.quota_clear(); print("cleared")
elif action == "state":
    print(json.dumps({k: m.__dict__[k] for k in ("QUOTA_COOLDOWN", "QUOTA_MAX_COOLDOWN")}))
PROBE

q() { BASE="$T_BASE" SCRIPT="$REPO_DIR/bin/yt_api.py" python3 "$T_BASE/probe.zsh" "$@"; }

state=$(q state)
base=$(print -r -- "$state" | python3 -c 'import json,sys; print(json.load(sys.stdin)["QUOTA_COOLDOWN"])')
cap=$(print -r -- "$state" | python3 -c 'import json,sys; print(json.load(sys.stdin)["QUOTA_MAX_COOLDOWN"])')
[[ "$cap" -le 3600 ]] && t_ok "the ceiling is an hour, so no guard can hide a whole afternoon" \
                    || t_bad "the ceiling is $cap s - too long to notice a stale guard"

first=$(q span "$base" - -)
[[ "$first" -le "$cap" ]] && t_ok "the first backoff respects the ceiling ($first s)" || t_bad "first span $first"

# A guard that was armed with the old 6 h default must be clamped on the next arm.
sixh=$(q span 21600 - -)
[[ "$sixh" -le "$cap" ]] && t_ok "a six-hour setting is clamped to $sixh s" || t_bad "six-hour setting survived ($sixh)"

# Doubling, but never past the cap.
now=$(date +%s)
doubled=$(q span 1800 $(( now + 1800 )) $now)
[[ "$doubled" -gt 1800 && "$doubled" -le "$cap" ]] && t_ok "a repeated refusal doubles, up to the cap ($doubled)" \
                                                  || t_bad "doubling is wrong ($doubled)"

# An expired guard allows the call.
print -r -- "{\"until\": $(( now - 60 )), \"armed_at\": $(( now - 3660 )), \"span\": 3600}" > "$T_BASE/log/quota_exhausted"
rec=$(q record)
[[ "$rec" == "{}" ]] && t_ok "an EXPIRED guard lets the next call through (it does not block forever)" \
                     || t_bad "an expired guard still blocks: $rec"

# An armed guard refuses without spending a request.
print -r -- "{\"until\": $(( now + 600 )), \"armed_at\": $now, \"span\": 600}" > "$T_BASE/log/quota_exhausted"
rec=$(q record)
[[ "$rec" != "{}" ]] && t_ok "an armed guard still refuses, so a dead pool costs nothing" \
                     || t_bad "an armed guard did not refuse"

# A successful call clears it - that is the self-healing half.
q clear >/dev/null
[[ -e "$T_BASE/log/quota_exhausted" ]] && t_bad "quota_clear left the guard behind" || t_ok "quota_clear removes the guard"

# And the API's success path calls it.
python3 - "$REPO_DIR/bin/yt_api.py" <<'PY' && t_ok "the HTTP success path clears the guard" || t_bad "a successful request does not clear the guard"
import sys
s = open(sys.argv[1]).read()
i = s.find("with urllib.request.urlopen(req, timeout=60) as r:")
seg = s[i:i + 400]
sys.exit(0 if "quota_clear()" in seg else 1)
PY

# The status page must show it, or a stale guard stays invisible.
python3 - "$REPO_DIR/bin/status.sh" <<'PY' && t_ok "status.sh reports the breaker state" || t_bad "status.sh is silent about the guard"
import sys
s = open(sys.argv[1]).read()
sys.exit(0 if "quota guard armed" in s and "quota_exhausted" in s else 1)
PY

t_teardown
t_summary
