#!/bin/zsh
# t02 - the monitor must never treat a lookup/config failure as a bad picture.
#
# Regression for a real defect: yt_check.py can answer NOGOLDEN, NOCONFIG and ERROR, but
# yt_monitor.sh's case only named OK / UNKNOWN|FETCHFAIL|NOSTATUS|"" / OFFLINE, so those three
# fell into the `*)` arm - "YouTube is live but showing the wrong thing" - and the monitor killed
# the publisher every FAIL_SECONDS, forever, on a stream it could not have been right about.
# With conf/golden.jpg gitignored and un-creatable (see t03) that was reachable on a fresh
# install. The classification is read out of the REAL file, not restated here, so moving a
# status back into the catch-all fails this test.
source "${0:A:h}/lib.sh"
t_begin t02

CLASSIFY=$(python3 - "$REPO_DIR/bin/yt_monitor.sh" <<'PY'
import re, sys
src = open(sys.argv[1]).read()
m = re.search(r'\n\s*case "\$st" in\n(.*?)\n\s*esac\n', src, re.S)
if not m:
    sys.exit("could not find the status case block in yt_monitor.sh")
arms = []
for line in m.group(1).splitlines():
    s = line.strip()
    if not s or s.startswith("#"):
        continue
    mm = re.match(r'^([^#]*?)\)\s*(#.*)?$', s)
    if mm:
        arms.append([p.strip() for p in mm.group(1).split("|")])
if not arms:
    sys.exit("no case arms parsed")
print(repr(arms))
PY
)

if [[ -z "$CLASSIFY" ]]; then t_bad "could not parse the monitor's case arms"; t_summary; exit 1; fi

# Ask the real arm list which arm a status lands in, then assert the semantics of that arm.
arm_index() {
  python3 -c "
import fnmatch, sys
arms = $CLASSIFY
want = sys.argv[1]
for i, pats in enumerate(arms):
    for p in pats:
        if p == '\"\"':      # zsh: the empty pattern matches the empty string
            p = ''
        if p == want or fnmatch.fnmatchcase(want, p):
            print(i); sys.exit(0)
print(-1)
" "$1"
}

never_act=$(arm_index UNKNOWN)   # the arm that also holds UNKNOWN: "never act on a failed lookup"
bad_picture=$(arm_index BLACK)   # the `*` arm

for st in UNKNOWN FETCHFAIL NOSTATUS NOGOLDEN NOCONFIG ERROR ""; do
  got=$(arm_index "$st")
  if [[ "$got" == "$never_act" ]]; then
    t_ok "$st -> never-act arm (correct)"
  else
    t_bad "$st -> arm $got, expected the never-act arm $never_act"
  fi
done

for st in BLACK FROZEN MISMATCH; do
  got=$(arm_index "$st")
  if [[ "$got" == "$bad_picture" ]]; then
    t_ok "$st -> bad-picture arm (correct)"
  else
    t_bad "$st -> arm $got, expected the bad-picture arm $bad_picture"
  fi
done

t_assert_eq "$(arm_index OK)" 0 "OK is the first arm"
got=$(arm_index OFFLINE)
[[ "$got" != "$never_act" && "$got" != "$bad_picture" ]] && [ "$got" -ge 0 ] \
  && t_ok "OFFLINE has its own arm (arm $got)" || t_bad "OFFLINE does not have its own arm"

t_summary
