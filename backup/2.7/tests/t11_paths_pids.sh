#!/bin/zsh
# t11 - entry points must honour their own checkout, and a watchdog must signal only its own
# processes.
#
# Two regressions, both about a script being sure of WHO and WHERE it is:
#
#   (a) T-14. Every entry point defaulted BASE to a hardcoded ~/Downloads/YTLive, and
#       bin/preflight.sh ignored BASE entirely, so `BASE=... bin/preflight.sh` had no effect and a
#       copy of the tree on another machine read the wrong config. forensics.sh already used the
#       ${0:A:h:h} form; this file pins the rest to it, behaviourally for preflight.sh.
#   (b) T-16. stream.sh and yt_monitor.sh restarted each other with
#       `pkill -9 -f "zsh.*yt_monitor.sh"` and `pkill -9 -f "ffmpeg.*rtmp"`. `-f` matches the full
#       command line of every process of every user, unanchored, so a hand-run ffmpeg or an
#       editor's subshell could be killed. They now signal a pid from a pidfile, and the pid is
#       checked for identity first because a pid can be recycled.
#   (c) T-39. conf/broadcast_template.json is TRACKED, but the rotation rewrote it every 8 hours
#       with a fresh capture timestamp, so the deployed checkout was never clean. The stamp now
#       lives in log/ (ignored) and a no-op capture does not write at all.
source "${0:A:h}/lib.sh"
t_begin t11
t_setup >/dev/null

# --- (a) T-14: the checkout you are in is the checkout you use -----------------------------
hard=$(grep -l 'BASE="\${BASE:-$HOME/Downloads/YTLive}"' "$REPO_DIR"/bin/*.sh 2>/dev/null | wc -l | tr -d ' ')
t_assert_eq "0" "$hard" "no entry point still hardcodes ~/Downloads/YTLive as its BASE default"

missing=""
for f in stream.sh yt_monitor.sh status.sh smoke_test.sh shuffle_playlist.sh preflight.sh forensics.sh net_watch.sh; do
  grep -q '\${0:A:h:h}' "$REPO_DIR/bin/$f" || missing="$missing $f"
done
t_assert_eq "" "$missing" "every entry point derives BASE from its own path"

# The one behavioural case that used to be broken: with BASE pointed at another tree, preflight.sh
# must read THAT tree's conf. A stub ffprobe keeps this off the network entirely.
FB="$T_BASE/fakebin"; mkdir -p "$FB"
cat > "$FB/ffprobe" <<'STUB'
#!/bin/zsh
print -r -- "STUB-FFPROBE $*"
STUB
chmod +x "$FB/ffprobe"
out=$(BASE="$T_BASE" FFPROBE="$FB/ffprobe" /bin/zsh "$REPO_DIR/bin/preflight.sh" 2>&1)
t_assert_contains "$out" "rtsp://127.0.0.1:8554/live/ch00_0" "preflight.sh reads the CAM_URL of the BASE it was given"
t_assert_contains "$out" "STUB-FFPROBE" "preflight.sh uses the ffprobe it was given, not a fixed ~/.local/bin path"

# A missing tool and an empty CAM_URL must be reported, not raised as a bare shell error.
cat > "$T_BASE/conf/empty.env" <<'ENV'
CAM_URL=""
ENV
out2=$(BASE="$T_BASE" CONF="$T_BASE/conf/empty.env" FFPROBE="$FB/ffprobe" /bin/zsh "$REPO_DIR/bin/preflight.sh" 2>&1)
t_assert_contains "$out2" "CAM_URL is empty" "preflight.sh reports an empty CAM_URL instead of probing nothing"
out3=$(BASE="$T_BASE" FFPROBE=/nonexistent/ffprobe /bin/zsh "$REPO_DIR/bin/preflight.sh" 2>&1)
t_assert_contains "$out3" "is not executable" "preflight.sh refuses an explicitly named ffprobe that does not exist"
out4=$(env -u FFPROBE PATH=/usr/bin:/bin BASE="$T_BASE" HOME="$T_BASE/home" /bin/zsh "$REPO_DIR/bin/preflight.sh" 2>&1)
t_assert_contains "$out4" "no ffprobe found" "preflight.sh reports a missing ffprobe instead of failing obscurely"

# The Python side: BASE must default to the checkout the module lives in. Checked across EVERY
# module, not just the two the streamer calls, because the camera tools are entry points too and
# were the last ones still pointing at one hardcoded home directory.
py_hard=$(grep -l 'Path.home() / "Downloads/YTLive"\|Path.home()/"Downloads/YTLive"' "$REPO_DIR"/bin/*.py 2>/dev/null | wc -l | tr -d ' ')
t_assert_eq "0" "$py_hard" "no Python entry point still hardcodes ~/Downloads/YTLive"
if grep -q 'pathlib.Path(__file__).resolve().parent.parent' "$REPO_DIR/bin/yt_api.py"; then
  t_ok "yt_api.py derives BASE from its own file"
else
  t_bad "yt_api.py does not derive BASE from its own file"
fi
if grep -q 'pathlib.Path(__file__).resolve().parent.parent' "$REPO_DIR/bin/cam_reboot.py"; then
  t_ok "cam_reboot.py derives BASE from its own file"
else
  t_bad "cam_reboot.py does not derive BASE from its own file"
fi

# --- (b) T-16: signal only our own processes ----------------------------------------------
# Comments are stripped first: the explanation of WHY pkill was removed must not itself fail this
# check, so only real command text counts.
for f in stream.sh yt_monitor.sh; do
  if sed 's/#.*//' "$REPO_DIR/bin/$f" | grep -q 'pkill'; then
    t_bad "$f uses pkill again (it matches unrelated processes)"
  else
    t_ok "$f never pattern-kills a process"
  fi
done
grep -q 'pidfile_pid "\$PUB_PID" ffmpeg rtmp' "$REPO_DIR/bin/yt_monitor.sh" \
  && t_ok "yt_monitor.sh restarts the publisher through the pidfile helper" \
  || t_bad "yt_monitor.sh no longer uses the pidfile helper"
grep -q 'print -r -- "\$PUBPID" > "\$PUB_PID"' "$REPO_DIR/bin/stream.sh" \
  && t_ok "stream.sh publishes the publisher pid for the monitor to use" \
  || t_bad "stream.sh does not write log/publisher.pid"
grep -q 'print -r -- "\$\$" > "\$MON_PID"' "$REPO_DIR/bin/yt_monitor.sh" \
  && t_ok "yt_monitor.sh publishes its own pid" \
  || t_bad "yt_monitor.sh does not write log/monitor.pid"
grep -q 'pidfile_pid "\$MON_PID"' "$REPO_DIR/bin/stream.sh" \
  && t_ok "stream.sh can restart exactly the hung monitor" \
  || t_bad "stream.sh cannot identify the hung monitor"
grep -q 'pidfile_pid' "$REPO_DIR/bin/status.sh" \
  && t_ok "status.sh identifies the publisher rather than trusting any ffmpeg" \
  || t_bad "status.sh still trusts any ffmpeg on the machine"

# --- (c) the helper itself ----------------------------------------------------------------
BASE="$T_BASE" source "$REPO_DIR/bin/lib.sh"

sleep 30 & live=$!
t_assert_eq "yes" "$(pid_is "$live" sleep && print yes || print no)" \
  "pid_is accepts a live pid whose command matches"
t_assert_eq "no" "$(pid_is "$live" ffmpeg && print yes || print no)" \
  "pid_is rejects a live pid whose command does NOT match (the recycled-pid case)"
t_assert_eq "no" "$(pid_is "$$" sleep && print yes || print no)" \
  "pid_is rejects our own shell when the needle is someone else's command"

done_pid_file="$T_BASE/log/stale.pid"
print -r -- "$live" > "$T_BASE/log/live.pid"
print -r -- "999999" > "$done_pid_file"
print -r -- "not-a-pid" > "$T_BASE/log/garbage.pid"
print -r -- "$$" > "$T_BASE/log/foreign.pid"

t_assert_eq "$live" "$(pidfile_pid "$T_BASE/log/live.pid" sleep)" \
  "pidfile_pid returns the pid when the process is alive and matches"
t_assert_eq "" "$(pidfile_pid "$T_BASE/log/absent.pid" sleep)" \
  "pidfile_pid returns nothing for a missing file"
t_assert_eq "" "$(pidfile_pid "$done_pid_file" sleep)" \
  "pidfile_pid returns nothing for a dead pid"
t_assert_eq "" "$(pidfile_pid "$T_BASE/log/garbage.pid" sleep)" \
  "pidfile_pid returns nothing for a non-numeric pid"
t_assert_eq "" "$(pidfile_pid "$T_BASE/log/foreign.pid" sleep)" \
  "pidfile_pid returns nothing for a live pid that is not the process we mean"

kill -9 "$live" 2>/dev/null; wait "$live" 2>/dev/null

# --- (e) T-26: a publisher death must say WHY -----------------------------------------------
# `PUBLISHER died rc=N` alone is unreadable: 137 is SIGKILL and could be the rotation, the stall
# watchdog, an ingest bounce or the shutdown trap, and 224 is ffmpeg's broken pipe from YouTube.
# The reason is recorded in a FILE before each deliberate kill, because await_broadcast runs in a
# subshell and a subshell cannot set the main loop's variables.
WHYF="$T_BASE/why_funcs.zsh"
{ t_extract_fn "$REPO_DIR/bin/stream.sh" mark_pub_kill
  t_extract_fn "$REPO_DIR/bin/stream.sh" pub_death_reason
  print -r -- "BASE='$T_BASE'"
  print -r -- "PUB_WHY='$T_BASE/log/pub_kill_reason'"; } > "$WHYF"
why() { /bin/zsh -c "source '$WHYF'; $1"; }

t_assert_eq "YouTube closed the ingest (ffmpeg broken pipe)" "$(why 'pub_death_reason 224')" \
  "rc=224 is named as YouTube closing the ingest, not left as a number"
t_assert_eq "ffmpeg error" "$(why 'pub_death_reason 1')" "an ordinary ffmpeg failure is named"
t_assert_eq "ffmpeg exited 0, which should not happen for a live push" "$(why 'pub_death_reason 0')" \
  "rc=0 is called out rather than silently restarted"
t_assert_contains "$(why 'pub_death_reason 137')" "SIGKILL from outside this script" \
  "an unmarked SIGKILL is attributed to the monitor, which is the only outside killer"
t_assert_eq "deliberate: broadcast rotation (scheduled 8h3m reached)" \
  "$(why 'mark_pub_kill "deliberate: broadcast rotation (scheduled 8h3m reached)"; pub_death_reason 137')" \
  "a marked kill reports its recorded reason instead of guessing"
t_assert_eq "3" "$(grep -c 'mark_pub_kill "deliberate:' "$REPO_DIR/bin/stream.sh")" \
  "all three deliberate kills record why (rotation, stall, ingest bounce)"
grep -q 'pub_death_reason "\$rc"' "$REPO_DIR/bin/stream.sh" \
  && t_ok "the death handler reports the reason it derived" \
  || t_bad "the death handler does not use pub_death_reason"

# --- (d) T-39: the deployed tree must stay CLEAN -------------------------------------------
# install.sh runs `chmod +x bin/*.sh bin/*.py`. A tool committed as mode 644 therefore becomes a
# permanent MODE change against the tag after every install: the deployed checkout can never be
# clean and a `git pull` there can refuse. bin/cam_time.py shipped that way in 2.6 and was caught
# by `git status` on the streamer minutes after the deploy. Cheap to assert, invisible otherwise.
nonexec=$(git -C "$REPO_DIR" ls-files -s -- 'bin/*.sh' 'bin/*.py' install.sh release.sh 2>/dev/null \
          | awk '$1 != "100755" {print $4}' | tr '\n' ' ')
t_assert_eq "" "$nonexec" "every script is tracked 755 (install.sh chmods them, so 644 means a dirty tree)"
# stream.sh captures the outgoing broadcast at every rotation, and that used to rewrite the
# TRACKED conf/broadcast_template.json every 8 hours with a fresh timestamp - so the deployed
# checkout was permanently dirty and a `git pull` or `git checkout` there could refuse or
# conflict. The stamp moved to log/ (untracked) and a no-op capture no longer writes at all.
if grep -q '"_captured_from"' "$REPO_DIR/conf/broadcast_template.json"; then
  t_bad "the tracked reference still carries a runtime capture stamp"
else
  t_ok "the tracked reference carries no runtime capture stamp"
fi
t_assert_contains "$(grep -c 'CAPTURED = BASE / "log/broadcast_captured.json"' "$REPO_DIR/bin/yt_api.py")" "1" \
  "the capture stamp is written under log/, which .gitignore covers"
git check-ignore -q "$REPO_DIR/log/broadcast_captured.json" \
  && t_ok "the capture stamp cannot be committed (log/ is ignored)" \
  || t_bad "log/broadcast_captured.json is NOT gitignored - it would dirty every commit"

# Behavioural: a no-op capture must not touch the file, a real change must.
nw=$(BASE="$T_BASE" PYTHONDONTWRITEBYTECODE=1 python3 -c "
import importlib.util
spec = importlib.util.spec_from_file_location('yt_api', '$REPO_DIR/bin/yt_api.py')
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
t = {'video': {'title': 'x'}}
a = m.save_template(t)
b = m.save_template(t)
t['video']['title'] = 'y'
c = m.save_template(t)
print('%s %s %s' % (a, b, c))
" 2>&1)
t_assert_eq "True False True" "$nw" "a no-op capture does not rewrite the tracked reference (idempotent merge)"
t_assert_file "$T_BASE/conf/broadcast_template.json" "and the reference really was written the first time"

t_teardown
t_summary
