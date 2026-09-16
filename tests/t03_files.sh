#!/bin/zsh
# t03 - the golden reference must be creatable, and the trim must not corrupt ffmpeg's file.
#
# Two separate regressions in one file, both about a file that only has to exist:
#   (a) zsh's -nt is FALSE when the right-hand operand is missing (unlike bash's). The monitor
#       refreshed conf/golden.jpg only when basefill.jpg was -nt golden.jpg, so with golden.jpg
#       absent - which it is on every fresh clone, since it is gitignored - it could never be
#       created at all. Every check then answered NOGOLDEN, which used to mean "kill the
#       publisher". The condition is extracted from the real file and evaluated for real.
#   (b) The in-place log trim has to keep the inode (ffmpeg holds an O_APPEND fd) and must never
#       touch log/progress.txt (ffmpeg writes it at a fixed offset).
source "${0:A:h}/lib.sh"
t_begin t03

t_setup >/dev/null

# --- (a) the golden-refresh condition, taken verbatim from yt_monitor.sh -----------------
COND=$(grep -m1 'basefill.jpg" -nt' "$REPO_DIR/bin/yt_monitor.sh" | sed 's/^[[:space:]]*if[[:space:]]*//; s/;[[:space:]]*then[[:space:]]*$//')
if [[ -z "$COND" ]]; then
  t_bad "could not extract the golden-refresh condition from yt_monitor.sh"
else
  t_ok "extracted the live golden-refresh condition"
fi

eval_cond() {  # eval_cond -> YES/NO
  BASE="$T_BASE" /bin/zsh -c "if $COND; then print -- YES; else print -- NO; fi"
}

# The bug: basefill exists, golden does not.
print -r -- "frame" > "$T_BASE/log/basefill.jpg"
rm -f "$T_BASE/conf/golden.jpg"
t_assert_eq "YES" "$(eval_cond)" "refreshes when golden is MISSING but basefill exists (the bug)"

# Sanity: the raw -nt test that caused it. Documented so nobody 'simplifies' it back.
raw=$(BASE="$T_BASE" /bin/zsh -c '[[ "$BASE/log/basefill.jpg" -nt "$BASE/conf/golden.jpg" ]] && print YES || print NO')
t_assert_eq "NO" "$raw" "plain -nt is FALSE against a missing file (the trap)"

# basefill newer than golden -> refresh; older -> leave it alone.
touch -t 202001010000 "$T_BASE/conf/golden.jpg"
touch "$T_BASE/log/basefill.jpg"
t_assert_eq "YES" "$(eval_cond)" "refreshes when basefill is newer"
touch -t 203001010000 "$T_BASE/conf/golden.jpg"
t_assert_eq "NO" "$(eval_cond)" "leaves a newer golden alone"
rm -f "$T_BASE/log/basefill.jpg"
t_assert_eq "NO" "$(eval_cond)" "does nothing when basefill is absent"

# --- (b) the in-place log trim ----------------------------------------------------------
TRIM=$(t_extract_fn "$REPO_DIR/bin/stream.sh" trim_log)
if [[ -z "$TRIM" ]]; then t_bad "could not extract trim_log"; else t_ok "extracted trim_log"; fi

mkdir -p "$T_BASE/log"
LOG_MAX_BYTES=1024
big="$T_BASE/log/publisher.log"
python3 -c "open('$big','w').write('x'*4096)"
before_inode=$(/usr/bin/stat -f %i "$big")
before_size=$(/usr/bin/stat -f %z "$big")
# A live O_APPEND writer, exactly like ffmpeg's: it must keep appending to the same inode.
python3 -c "
import os,time
fd=os.open('$big', os.O_WRONLY|os.O_APPEND)
os.write(fd,b'appended-after-trim\n'); os.close(fd)
" &
wait
BASE="$T_BASE" /bin/zsh -c "LOG_MAX_BYTES=1024; log(){ :; }; $TRIM; trim_log '$big'" >/dev/null 2>&1
after_inode=$(/usr/bin/stat -f %i "$big")
after_size=$(/usr/bin/stat -f %z "$big")
t_assert_eq "$before_inode" "$after_inode" "trim keeps the same inode (ffmpeg's O_APPEND fd survives)"
(( after_size < before_size )) && t_ok "trim actually shrank the file ($before_size -> $after_size)" \
                                || t_bad "trim did not shrink the file ($before_size -> $after_size)"

# progress.txt must never be trimmed: it is read at a fixed offset. housekeep must still trim the
# files it IS responsible for, so assert both directions - otherwise this passes when housekeep
# is simply broken, which is exactly what a vacuous test does.
prog="$T_BASE/log/progress.txt"
python3 -c "open('$prog','w').write('frame=1\n'*2000)"
hlog="$T_BASE/log/publisher.log"
python3 -c "open('$hlog','w').write('y'*4096)"
prog_before=$(/usr/bin/stat -f %z "$prog")
hlog_before=$(/usr/bin/stat -f %z "$hlog")
HOUSE=$(t_extract_fn "$REPO_DIR/bin/stream.sh" housekeep)
BASE="$T_BASE" /bin/zsh -c "LOG_MAX_BYTES=1024; log(){ :; }; $TRIM; $HOUSE; housekeep" >/dev/null 2>&1
prog_after=$(/usr/bin/stat -f %z "$prog")
hlog_after=$(/usr/bin/stat -f %z "$hlog")
t_assert_eq "$prog_before" "$prog_after" "housekeep never trims log/progress.txt"
(( hlog_after < hlog_before )) && t_ok "housekeep did trim publisher.log ($hlog_before -> $hlog_after)" \
                               || t_bad "housekeep did not trim publisher.log - the check above is vacuous"

t_teardown
t_summary
