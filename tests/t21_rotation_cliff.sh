#!/bin/zsh
# t21 - a refused rotation must not be unbounded: the 12 h archive cliff is a hard stop.
#
# On 2026-10-28 the API quota ran out, so the scheduled 8h03m rotation was refused twelve
# times (13:20 through 16:05). The channel stayed live - correct, a cut with no successor
# leaves a dark channel - but the segment reached 10h57m, and at 12 h YouTube discards the
# recording outright. Staying live must have a ceiling.
source "${0:A:h}/lib.sh"
t_begin t21

cd "$REPO_DIR" || exit 2

contains() {   # contains FILE NEEDLE LABEL
  t_assert_contains "$(<"$1")" "$2" "$3"
}

contains bin/stream.sh ': ${ROTATE_HARD_STOP_AFTER:=40500}' "a forced cut exists at 11h15m"
contains bin/stream.sh ': ${ROTATE_WARN_AFTER:=32400}' "and a warning exists at 9h"

# The bound must be inside the 12 h wall with room for the cut itself (up to 10 min).
hard=$(sed -n 's/^: ${ROTATE_HARD_STOP_AFTER:=\([0-9]*\)}.*/\1/p' bin/stream.sh | head -1)
[[ "$hard" == <-> ]] && (( hard > 36000 && hard < 43200 )) \
  && t_ok "the forced cut lands before 12h but well after the 8h03m target ($hard s)" \
  || t_bad "ROTATE_HARD_STOP_AFTER is missing or outside 10h..12h ($hard)"

# Both refusal paths - exhausted quota and unusable credential - must honour it.
python3 - "$PWD/bin/stream.sh" <<'PY' && t_ok "the quota refusal forces a cut at the cliff" || t_bad "a quota outage can still grow the segment without bound"
import sys
s = open(sys.argv[1]).read()
i = s.find('q=$(yt_api_call quota)')
seg = s[i:i + 1400]
sys.exit(0 if 'ROTATE_HARD_STOP_AFTER' in seg and 'cut happens anyway' in seg else 1)
PY
python3 - "$PWD/bin/stream.sh" <<'PY' && t_ok "the credential refusal forces a cut at the cliff too" || t_bad "a dead credential can still grow the segment without bound"
import sys
s = open(sys.argv[1]).read()
i = s.find('ROTATE ($why): REFUSED - the API cannot create the next broadcast')
seg = s[max(0, i - 900):i + 200]
sys.exit(0 if 'ROTATE_HARD_STOP_AFTER' in seg else 1)
PY

# And the health page must state the age, or the overrun is invisible until Studio shows it.
contains bin/status.sh 'rotation at 8h03m, forced cut at 11h15m, archive lost at 12h' "status.sh states the segment age against the cliff"
contains bin/status.sh 'past the 11h15m cliff' "and fails when the segment is past it"

t_teardown
t_summary
