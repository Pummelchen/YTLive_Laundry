#!/bin/zsh
# The suite runner.   zsh tests/run.sh            all tests
#                     zsh tests/run.sh t02        everything starting with t02
#                     zsh tests/run.sh t02 t05    several
#
# Exit 0 only if every test passed. Nothing here touches the live stream: see tests/lib.sh.
set -u
TESTS_DIR="${0:A:h}"
cd "$TESTS_DIR" || exit 2

fails=0
files=()

if (( $# > 0 )) && [[ "$1" == "--list" ]]; then
  print -- "tests in $TESTS_DIR:"
  for f in t[0-9]*.sh(N); do
    desc=$(sed -n '2s/^# *//p' "$f")
    printf '  %-28s %s\n' "$f" "$desc"
  done
  exit 0
fi

if (( $# > 0 )); then
  for a in "$@"; do
    if [[ -f "$a" ]]; then
      files+=( "$a" )
    elif [[ -f "$a.sh" ]]; then
      files+=( "$a.sh" )
    else
      # Accept a prefix (t02) or a glob, so an operator does not have to type a full filename.
      m=( ${a}*.sh(N) )
      if (( ${#m} > 0 )); then
        files+=( "${m[@]}" )
      else
        print -- "no such test: $a"
        fails=$(( fails + 1 ))
      fi
    fi
  done
else
  files=( t[0-9]*.sh(N) )
fi

for f in "${files[@]}"; do
  print "\n=== $f ==="
  /bin/zsh "$f" || fails=$(( fails + 1 ))
done

print ""
(( fails == 0 )) && print -- "SUITE PASSED" || print -- "SUITE FAILED ($fails test file(s))"
exit $(( fails > 0 ))
