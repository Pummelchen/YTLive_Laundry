#!/bin/zsh
# t17 - the camera-loss recovery path, and the second (9:16) feed, keep working.
#
# Everything here was learned the hard way on 2026-10-28, when a dead camera left the channel
# dark for 14 hours and the vertical feed had never existed at all. Each check guards one of
# the specific traps hit while building the fix, because every one of them was silent:
#
#   * a publisher that blocks on a dead UDP input and produces nothing (0 frames measured);
#   * the reader not feeding a slate when the camera is gone;
#   * a slate reader that keeps polling the OLD address after a DHCP move;
#   * an agent-written message on the offline card, which the operator never authorised;
#   * a scanner that runs ifconfig from launchd's PATH and finds no interfaces at all;
#   * a scanner that reports this Mac itself as the camera because it only skips one address;
#   * two live broadcasts confusing the single-broadcast API lookups.
source "${0:A:h}/lib.sh"
t_begin t17

cd "$REPO_DIR" || exit 2

contains() {   # contains FILE NEEDLE LABEL
  t_assert_contains "$(<"$1")" "$2" "$3"
}

# --- the 16:9 feed never goes quiet when the camera does --------------------------------
contains bin/stream.sh "slate_feed()"        "stream.sh defines the slate feeder"
contains bin/stream.sh "make_slate()"        "stream.sh builds the offline card"
contains bin/stream.sh "slate_feed \"\$ip\"" "the reader calls the slate feeder when 554 fails"
contains bin/stream.sh 'nc -z -G 3 "$ip" 554' "the reader probes the camera BEFORE connecting"
contains bin/stream.sh 'timeout=0'           "the publisher still uses timeout=0, so the slate must never stop"
# The IP must be re-read INSIDE the poll loop, or a camera that returns on a new DHCP
# address is never noticed: the loop holds the old ip for as long as the slate lasts.
python3 - "$PWD/bin/stream.sh" <<'PY' && t_ok "slate_feed re-reads cam_ip inside its poll loop" || t_bad "slate_feed polls a STALE ip"
import re, sys
s = open(sys.argv[1]).read()
m = re.search(r"slate_feed\(\)\s*\{(.*?)\n\}", s, re.S)
body = m.group(1) if m else ""
loops = re.findall(r"while kill -0.*?done", body, re.S)
sys.exit(0 if loops and 'ip=$(<"$CAMIP_FILE"' in loops[0] else 1)
PY

# The offline card carries NO TEXT (operator policy, 2026-11-13). The first version of this
# check asserted the OPPOSITE - that make_slate() used `drawtext=...:textfile=` with a braced
# font path - because an agent had written three lines of Indonesian prose onto the card and
# called it an operator request. The operator had never authorised a word of it, and on
# 2026-11-13 the card put an unauthorised promise ("back in a few hours") and a stale clock on
# both feeds. A fallback card may show the shop; it may not speak for the shop.
python3 - "$PWD/bin/stream.sh" "$PWD/bin/vertical.sh" <<'PY' && t_ok "both offline cards draw NO text" || t_bad "an offline card draws text or operator-facing prose"
import re, sys
bad = []
for path in sys.argv[1:]:
    src = open(path).read()
    m = re.search(r"make_slate\(\)\s*\{(.*?)\n\}", src, re.S)
    body = m.group(1) if m else ""
    if not body:
        bad.append(path + ": no make_slate() body found")
    if "drawtext" in body or "textfile=" in body:
        bad.append(path + ": make_slate() draws text")
    # Comments may quote the words it used to show (that is the record); executable lines may not.
    code = "\n".join(l for l in src.splitlines() if not l.lstrip().startswith("#"))
    if re.search(r"Kamera CCTV|BUKA 24 JAM|TETAP BEROPERASI|kembali dalam", code):
        bad.append(path + ": operator-facing prose is still in the script")
if bad:
    print("\n".join(bad))
sys.exit(1 if bad else 0)
PY

# A camera that ACCEPTS on 554 but never streams. The slate has to come back immediately,
# and the variable this path logs must be DEFINED - it was first used undefined and `set -u`
# killed the reader subshell on the third failure, darkening the channel (2026-10-28 05:13).
contains bin/stream.sh 'SLATE_BURST_SECONDS="${SLATE_BURST_SECONDS:-120}"' "the burst length is defined, not just referenced"
if grep -qE '\$\{SLATE_BURST_SECONDS\}' bin/stream.sh; then
  t_bad "SLATE_BURST_SECONDS is referenced without a default (dies under set -u)"
else
  t_ok "every SLATE_BURST_SECONDS reference has a default"
fi
contains bin/stream.sh "camera accepts on 554 but is not streaming" "short RTSP failures are detected, not just a closed port"
contains bin/stream.sh "the reader process is GONE" "the main loop restarts a dead reader"

# ONVIF discovery is multicast and can be blocked; the TCP sweep is the fallback.
contains bin/stream.sh "find_rtsp.py" "the watcher falls back to a TCP sweep when ONVIF is silent"
t_assert_file bin/find_rtsp.py "find_rtsp.py exists"
contains bin/find_rtsp.py "for src in (sources or [None])" "find_rtsp sweeps from EVERY local address"

# --- the independent scanner ------------------------------------------------------------
t_assert_file bin/cam_scan.py "cam_scan.py exists"
contains bin/cam_scan.py "/sbin/ifconfig" "the scanner uses an absolute ifconfig (launchd PATH has no /sbin)"
contains bin/cam_scan.py "skip=all_local" "the scanner skips ALL local addresses, not just the probing one"
contains bin/cam_scan.py "IP_MULTICAST_IF" "the scanner binds ONVIF discovery to each interface"
t_assert_file bin/cam_scan.sh "the zsh wrapper exists"
contains bin/cam_scan.sh 'exec /usr/bin/python3' "the wrapper execs python3 from zsh (TCC/FDA)"

if python3 bin/cam_scan.py --self-test >/dev/null 2>&1; then
  t_ok "cam_scan --self-test proves the found-camera branch"
else
  t_bad "cam_scan --self-test FAILS"
fi

# --- the vertical feed ------------------------------------------------------------------
t_assert_file bin/vertical.sh "vertical.sh exists"
contains bin/vertical.sh 'scale=${VERT_W}:-2' "the vertical feed scales to VERT_SIZE's width"
contains bin/vertical.sh 'pad=${VERT_W}:${VERT_H}' "and pads to a true 9:16 frame"
contains bin/vertical.sh "color=black" "with a black background above and below it (operator request 2026-10-28)"
contains bin/vertical.sh 'color=c=black:s=${VERT_W}x${VERT_H}' "and the offline card is black too, not the brand navy"
contains bin/vertical.sh "YT_KEY=\"\$VERT_KEY\"" "every vertical API call is scoped to its own key"
t_assert_file conf/vertical.env.example "the Shorts config has a tracked template"
contains conf/vertical.env.example 'VERT_ROTATE="no"' "which records the run-forever choice"
contains bin/vertical.sh "ROTATE" "the vertical feed rotates before YouTube's 12h archive limit"
contains bin/vertical.sh "vertical.seen_camera" "it will not go public with only a slate before the first sighting"

# The liveness confirmation names a broadcast ID, not a session, so an external stop (a power
# cut, YouTube's 12 h limit) leaves it matching a DEAD broadcast and the poll below never runs
# again - the Shorts then stays OFFLINE after power, network and camera have all recovered.
# Measured 2026-11-13: 18 minutes dark with every other signal back. A publisher start must
# invalidate the confirmation, so the next poll re-asks the API and repairs it.
python3 - "$PWD/bin/vertical.sh" <<'PY3' && t_ok "a publisher start clears the stale liveness confirmation" || t_bad "live_ok survives a publisher restart and mutes the liveness poll"
import re, sys
src = open(sys.argv[1]).read()
start = re.search(r"start_publisher\(\)\s*\{(.*?)\n\}", src, re.S)
body = start.group(1) if start else ""
sys.exit(0 if body and 'rm -f "$LIVEOK"' in body else 1)
PY3

# --- one broadcast lookup cannot adopt the other ----------------------------------------
contains bin/yt_api.py "def active_broadcast(token, stream_id=None)" "active_broadcast is stream-scoped"
contains bin/yt_api.py "active_broadcast(token, stream[\"id\"])" "ensure-live/prepare scope by stream"
contains bin/yt_check.py "broadcast_started" "yt_check pins its grading to the 16:9 broadcast"
contains bin/yt_check.py "vertical.broadcast" "and excludes the vertical one"
# The liveness poll is the other place the two feeds met: with both live, /@channel/live can
# resolve to the vertical one, and await_broadcast stamped the 16:9 title/tags/thumbnail onto
# it (2026-10-28 05:23). It must ask the scoped API status first, and exclude the vertical id
# as its yt-dlp fallback.
python3 - "$PWD/bin/stream.sh" <<'PY2' && t_ok "yt_live_id is scoped to our own broadcast" || t_bad "yt_live_id can adopt the vertical broadcast"
import sys
s = open(sys.argv[1]).read()
i = s.find('yt_live_id()')
body = s[i:s.find('\n}', i)] if i >= 0 else ''
ok = ('yt_api_call status' in body) and ('vertical.broadcast' in body)
sys.exit(0 if ok else 1)
PY2

t_teardown
t_summary
