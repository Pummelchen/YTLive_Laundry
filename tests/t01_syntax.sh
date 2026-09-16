#!/bin/zsh
# t01 - every script parses, and every Python file is valid AST.
#
# This is the cheap gate that has to pass before anything else. It is the same check
# bin/smoke_test.sh performs, but it needs no credentials and no install, so it runs here too.
source "${0:A:h}/lib.sh"
t_begin t01

cd "$REPO_DIR" || exit 2

for f in bin/*.sh install.sh; do
  if /bin/zsh -n "$f" 2>/dev/null; then t_ok "$f parses"; else t_bad "$f does NOT parse"; fi
done
for f in bin/*.py; do
  if python3 -c "import ast,sys; ast.parse(open('$f').read())" 2>/dev/null; then
    t_ok "$f parses"
  else
    t_bad "$f does NOT parse"
  fi
done
for f in tests/*.sh tests/stubs/*; do
  case "$f" in
    *.py) python3 -c "import ast,sys; ast.parse(open('$f').read())" 2>/dev/null && t_ok "$f parses" || t_bad "$f does NOT parse" ;;
    *)    /bin/zsh -n "$f" 2>/dev/null && t_ok "$f parses" || t_bad "$f does NOT parse" ;;
  esac
done

# The use-before-assignment class that took the channel dark on 2026-09-07: a local read before
# its earliest assignment, which only fires on the once-every-8-hours creation path.
python3 - "$REPO_DIR" <<'PY'
import ast, sys, pathlib
root = pathlib.Path(sys.argv[1])
bad = []
for name in ("bin/yt_api.py", "bin/yt_check.py"):
    tree = ast.parse((root / name).read_text())
    for fn in [n for n in ast.walk(tree) if isinstance(n, ast.FunctionDef)]:
        asg = {}
        for n in ast.walk(fn):
            if isinstance(n, ast.Name) and isinstance(n.ctx, ast.Store):
                asg[n.id] = min(asg.get(n.id, 10**9), n.lineno)
        args = {a.arg for a in fn.args.args}
        for n in ast.walk(fn):
            if isinstance(n, ast.Name) and isinstance(n.ctx, ast.Load):
                if n.id in asg and n.id not in args and n.lineno < asg[n.id]:
                    bad.append(f"{name}:{fn.name}: '{n.id}' read at {n.lineno}, assigned at {asg[n.id]}")
sys.exit("\n".join(bad) or 0)
PY
if (( $? == 0 )); then t_ok "no local read before its earliest assignment"; else t_bad "use-before-assignment found"; fi

t_summary
