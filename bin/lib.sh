#!/bin/zsh
# Shared helpers for stream.sh and yt_monitor.sh.
#
# These were defined separately in both scripts and had already drifted: YT_LATENCY was
# added to each by hand, and the two yt_api_ready() bodies tested different paths for the
# same file. A setting that reaches one caller and not the other is exactly the bug class
# that silently dropped the channel's hashtags for a day - conf/stream.env is SOURCED, not
# exported, so anything a subprocess needs has to be passed explicitly, once, in one place.
#
# Expects BASE to be set. Source with:  source "$BASE/bin/lib.sh"

: ${YT_API:="$BASE/bin/yt_api.py"}
: ${YT_OAUTH:="$BASE/conf/yt_oauth.json"}

yt_api_ready() { [[ -s "$YT_OAUTH" && -x "$YT_API" ]] }

yt_api_call() {
  BASE="$BASE" \
  YT_TITLE_FMT="${YT_TITLE_FMT:-}" \
  YT_PRIVACY="${YT_PRIVACY:-public}" \
  YT_LATENCY="${YT_LATENCY:-normal}" \
  YT_TOKEN_TTL_DAYS="${YT_TOKEN_TTL_DAYS:-7}" \
  YT_TOKEN_WARN_DAYS="${YT_TOKEN_WARN_DAYS:-2}" \
  python3 "$YT_API" "$@" 2>&1
}

# --- signalling a process, exactly ---------------------------------------------------------
# Both scripts used to restart each other with `pkill -9 -f "<pattern>"`. `-f` matches the FULL
# command line of every process of every user, unanchored, so `ffmpeg.*rtmp` also matched a
# manual diagnostic ffmpeg, a second copy of the project, or an editor's subshell - and `-9`
# leaves the victim no chance to clean up. A pidfile plus an identity check is exact, and the
# check matters because a pid can be recycled between being written and being read.
pid_is() {   # pid_is PID NEEDLE...  -> true when the pid is alive AND its command has every NEEDLE
  local pid="$1"; shift
  [[ "$pid" == <-> ]] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  local cmd
  cmd=$(ps -p "$pid" -o command= 2>/dev/null) || return 1
  local n
  for n in "$@"; do [[ "$cmd" == *"$n"* ]] || return 1; done
  return 0
}

pidfile_pid() {   # pidfile_pid FILE NEEDLE...  -> prints the pid iff it is alive and matches
  local f="$1"; shift
  [[ -r "$f" ]] || return 1
  local pid
  pid=$(<"$f")
  pid_is "$pid" "$@" || return 1
  print -r -- "$pid"
}
