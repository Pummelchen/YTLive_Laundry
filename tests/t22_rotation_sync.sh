#!/bin/zsh
# t22 - the two feeds must cut together: the 16:9 rotation is the clock for the 9:16 one.
#
# Until 2026-10-28 they rotated on independent 8h10m clocks, so their segments drifted apart -
# the 9:16 broadcast could start an hour or more after the 16:9 one and they never lined up.
# The Shorts feed now watches log/broadcast_started, which stream.sh rewrites with the NEW id
# when its successor goes live, and rotates itself at that moment.
source "${0:A:h}/lib.sh"
t_begin t22
t_setup >/dev/null
cd "$REPO_DIR" || exit 2

contains() {   # contains FILE NEEDLE LABEL
  t_assert_contains "$(<"$1")" "$2" "$3"
}

contains bin/vertical.sh 'MASTER="$BASE/log/broadcast_started"' "the vertical follows the 16:9 clock file"
# ...but only when it is allowed to rotate at all. VERT_ROTATE=no is the "run forever" mode:
# the 9:16 feed keeps one broadcast, ignoring both the 16:9 cut and its own age.
contains bin/vertical.sh ': ${VERT_ROTATE:=yes}' "rotation is a switch, defaulting on"
contains bin/vertical.sh 'if [[ "$VERT_ROTATE" == "yes" ]]; then' "and the sync plus the fallback sit inside it"
contains bin/vertical.sh 'vlog "SYNC: the 16:9 feed rotated to $mid - rotating this one too"' "and rotates when that id changes"
contains bin/vertical.sh 'if sync_pending "$mid"; then' "the loop asks the decision function, so this test drives the same code"

# The decision is a function so it can be driven for real, not grepped. Extract it with the
# two readers it depends on and point all three at the scratch tree.
DRV="$T_BASE/sync_funcs.zsh"
{ t_extract_fn "$REPO_DIR/bin/vertical.sh" master_id
  t_extract_fn "$REPO_DIR/bin/vertical.sh" broadcast_id
  t_extract_fn "$REPO_DIR/bin/vertical.sh" sync_pending
  printf "MASTER='%s/master'\nBSTATE='%s/vertical'\n" "$T_BASE" "$T_BASE"
} > "$DRV"

# -> "<rc>:<MASTER_SEEN after the call>". The caller's job (MASTER_SEEN=$mid on a cut) is done
# by the loop, so a successful decision deliberately leaves MASTER_SEEN untouched here.
run_sync() {   # run_sync MASTER_SEEN
  DRV="$DRV" MASTER_SEEN="$1" BASE="$T_BASE" /bin/zsh -c '
    source "$DRV"
    sync_pending "$(master_id)"
    print -r -- "$?:${MASTER_SEEN:-}"
  ' 2>/dev/null
}

live() { print -r -- "VvVvVvVvVvV 1793000000" > "$T_BASE/vertical" }   # this feed is live
dark() { rm -f "$T_BASE/vertical" }                                   # no vertical broadcast

# 1. The 16:9 streamer may not have written a clock file yet: nothing to follow, no error.
rm -f "$T_BASE/master"; dark
t_assert_eq "1:" "$(run_sync "")" "a missing clock file yields nothing rather than an error"

# 2. First sight of the clock is adopted, NOT a cut: a process starting mid-segment must not
#    cut the live broadcast just because it came up.
print -r -- "AAAAaaaaaa 1793000000" > "$T_BASE/master"; live
t_assert_eq "1:AAAAaaaaaa" "$(run_sync "")" "the first id seen is adopted without cutting"

# 3. Same broadcast on the next pass: still no cut (the loop runs every few seconds).
t_assert_eq "1:AAAAaaaaaa" "$(run_sync "AAAAaaaaaa")" "an unchanged clock does not rotate"

# 4. stream.sh wrote the successor: this feed cuts at that exact moment.
print -r -- "BBBBbbbbbb 1793100000" > "$T_BASE/master"
t_assert_eq "0:AAAAaaaaaa" "$(run_sync "AAAAaaaaaa")" "a new 16:9 broadcast triggers the cut"

# 5. A change while this feed has no broadcast yet is adopted, not queued: otherwise the
#    start-up path would cut the brand-new broadcast on its very next pass.
dark
t_assert_eq "1:BBBBbbbbbb" "$(run_sync "AAAAaaaaaa")" "a change with nothing live is adopted, not queued"

# 6. And once that start-up broadcast exists, it is not cut immediately.
live
t_assert_eq "1:BBBBbbbbbb" "$(run_sync "BBBBbbbbbb")" "the adopted id is not cut afterwards"

# The age fallback must still exist, or a missed sync would leave a segment running forever.
contains bin/vertical.sh 'if (( $(broadcast_age) > VERT_ROTATE_SECONDS + VERT_FALLBACK_GRACE )); then' "the age fallback survives a missed sync"

# ...but it must not fire while the 16:9 cut is still in progress. Equal clocks would make the
# fallback win in the minute between the 16:9 old broadcast ending and its successor's id
# appearing, and the arriving id would then cut a second time. The grace has to be larger than
# the 16:9 rotation's worst case, which is what the numbers below are.
python3 - "$PWD/bin/stream.sh" "$PWD/bin/vertical.sh" <<'PY' && t_ok "the fallback grace outlasts the slowest 16:9 rotation" || t_bad "the fallback grace can beat the 16:9 sync"
import re, sys

def num(path, name):
    s = open(path).read()
    m = re.search(r"\$\{%s:=(\d+)\}" % name, s)
    if not m:
        print(f"{name} not found in {path}")
        sys.exit(1)
    return int(m.group(1))

worst = sum(num(sys.argv[1], n) for n in ("ROTATE_MAX_WAIT", "ROTATE_GAP", "ROTATE_NATIVE_WAIT"))
grace = num(sys.argv[2], "VERT_FALLBACK_GRACE")
print(f"worst 16:9 rotation {worst}s, vertical grace {grace}s")
sys.exit(0 if grace > worst else 1)
PY

# And the sync must be checked BEFORE that fallback, so the normal case is the synced one.
python3 - "$PWD/bin/vertical.sh" <<'PY' && t_ok "the sync block runs before the age fallback" || t_bad "the age fallback can fire before the sync"
import sys
s = open(sys.argv[1]).read()
sys.exit(0 if s.find("2a. SYNC") < s.find("2b. fallback") else 1)
PY

# The clock file must name the new broadcast as soon as that broadcast is live. At the next
# housekeeping pass (up to 300 s later) is too late: the 9:16 cut would trail the 16:9 successor
# by minutes, and the two segments would not line up.
python3 - "$PWD/bin/stream.sh" <<'PY' && t_ok "the new broadcast is published to the clock immediately, not at the next housekeeping pass" || t_bad "the clock may wait for housekeeping, so the Shorts cut trails the 16:9 by minutes"
import sys
s = open(sys.argv[1]).read()
ok = True
for marker in ('await_broadcast "$old_id" rotation', 'await_broadcast "" start'):
    i = s.find(marker)
    if i < 0 or s.find("refresh_broadcast_clock", i, i + 400) < 0:
        print(f"no refresh after {marker!r}")
        ok = False
sys.exit(0 if ok else 1)
PY

t_teardown
t_summary
