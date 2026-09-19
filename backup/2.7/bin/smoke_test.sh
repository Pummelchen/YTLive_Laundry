#!/bin/zsh
# Pre-flight for a change, BEFORE restarting anything.
#
# Both outages in this project came from the same mistake: editing a path and validating
# everything except that path. prepare/_create_and_bind only runs when a broadcast has to
# be created - once every 8 hours - so an UnboundLocalError in it sat harmless for hours
# and then fired during a scheduled rotation. Nothing here touches the live stream or
# creates anything on YouTube.
#
#   bin/smoke_test.sh        exit 0 = safe to restart
set -u
BASE="${BASE:-${0:A:h:h}}"   # the checkout this script lives in (a launchd install is ~/Downloads/YTLive)
cd "$BASE" || exit 2
fails=0
ok()   { print -- "  \033[32mPASS\033[0m  $*"; }
bad()  { print -- "  \033[31mFAIL\033[0m  $*"; fails=$(( fails + 1 )); }

print "=== syntax ==="
for f in bin/*.sh install.sh; do
  zsh -n "$f" 2>/dev/null && ok "$f parses" || bad "$f does NOT parse"
done
for f in bin/*.py; do
  python3 -c "import ast,sys; ast.parse(open('$f').read())" 2>/dev/null && ok "$f parses" || bad "$f does NOT parse"
done

print "\n=== use-before-assignment (the 2026-09-07 crash class) ==="
python3 - <<'PY' && ok "no local read before its earliest assignment" || bad "use-before-assignment found"
import ast, sys
bad=[]
for f in ("bin/yt_api.py","bin/yt_check.py"):
    tree=ast.parse(open(f).read())
    for fn in [n for n in ast.walk(tree) if isinstance(n,ast.FunctionDef)]:
        asg={}
        for n in ast.walk(fn):
            if isinstance(n,ast.Name) and isinstance(n.ctx,ast.Store):
                asg[n.id]=min(asg.get(n.id,10**9), n.lineno)
        args={a.arg for a in fn.args.args}
        for n in ast.walk(fn):
            if isinstance(n,ast.Name) and isinstance(n.ctx,ast.Load):
                if n.id in asg and n.id not in args and n.lineno < asg[n.id]:
                    bad.append(f"{f}:{fn.name}: '{n.id}' read at {n.lineno}, assigned at {asg[n.id]}")
for b in bad: print("     ", b, file=sys.stderr)
sys.exit(1 if bad else 0)
PY

print "\n=== read-only API commands ==="
# These must be judged on the STATUS, not on the mere presence of a "status" key. Grepping for
# '"status"' alone passes on {"status": "ERROR"} - and on OFFLINE, NOREF, UNKNOWN and PENDING -
# so a completely broken API reported a clean bill of health. Only a status that means "this
# command answered" passes; anything else fails, and the body is shown.
for c in token status verify; do
  out=$(BASE="$BASE" python3 bin/yt_api.py $c 2>&1)
  st=$(print -r -- "$out" | sed -n 's/.*"status": *"\([A-Z-]*\)".*/\1/p' | head -1)
  case "$st" in
    OK|LIVE|EXPIRING|DRIFTED|READY|ENDED|CAPTURED|PENDING)
      ok "yt_api.py $c -> $st" ;;
    "")
      bad "yt_api.py $c produced no status: $(print -r -- "$out" | head -2 | tr '\n' ' ' | cut -c1-140)" ;;
    *)
      bad "yt_api.py $c -> $st ($(print -r -- "$out" | cut -c1-140))" ;;
  esac
done

print "\n=== THE CREATION PATH, without creating anything ==="
out=$(BASE="$BASE" python3 bin/yt_api.py prepare --dry-run 2>&1)
if print -r -- "$out" | grep -q '"status": "DRY-RUN"'; then
  ok "prepare builds a valid request ($(print -r -- "$out" | grep -c '"') fields)"
  print -r -- "$out" | grep -q '"title"' && ok "title resolved from the reference" || bad "no title in the request"
  print -r -- "$out" | grep -q '"enableAutoStart": true' && ok "autoStart on" || bad "autoStart missing"
  print -r -- "$out" | grep -q '"enableMonitorStream": false' && ok "monitorStream off (must be)" || bad "monitorStream not forced off"
else
  bad "prepare --dry-run failed: $(print -r -- "$out" | tail -3 | tr '\n' ' ' | cut -c1-160)"
fi

print "\n=== reference + thumbnail present ==="
[[ -s conf/broadcast_template.json ]] && ok "reference present" || bad "no conf/broadcast_template.json"
{ [[ -s conf/thumbnail.jpg ]] || [[ -s conf/thumbnail.png ]] } && ok "thumbnail present" || bad "no thumbnail"

print ""
(( fails == 0 )) && { print -- "  \033[32mALL PASSED - safe to restart\033[0m"; exit 0; } \
                 || { print -- "  \033[31m${fails} FAILED - do NOT restart\033[0m"; exit 1; }
