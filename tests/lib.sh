#!/bin/zsh
# Shared helpers for the test suite. Sourced only by tests/*.sh.
#
# SAFETY. These tests run on developer machines and on the production host, where a real
# stream may be running. Two rules make that safe:
#   1. Every test works inside its own scratch tree under tests/.tmp, never in ~/Downloads/YTLive.
#   2. tests/stubs is put FIRST on PATH and HOME points inside the scratch tree, so the tests
#      can never reach the real ffmpeg, yt-dlp, nc, caffeinate, launchctl or pkill. The pkill
#      stub is a recorder: no test can signal a process it did not start.
set -u

TESTS_DIR="${0:A:h}"
REPO_DIR="${TESTS_DIR:h}"
STUBS="$TESTS_DIR/stubs"
TMPROOT="$TESTS_DIR/.tmp"

PASS=0
FAIL=0
CURRENT=""

t_begin() { CURRENT="$1"; }

t_ok()   { PASS=$(( PASS + 1 )); print -- "  \033[32mPASS\033[0m  $1"; }
t_bad()  { FAIL=$(( FAIL + 1 )); print -- "  \033[31mFAIL\033[0m  $1"; }

t_assert_eq() {   # t_assert_eq EXPECTED ACTUAL LABEL
  if [[ "$1" == "$2" ]]; then t_ok "$3"; else t_bad "$3 (expected [$1], got [$2])"; fi
}
t_assert_contains() {   # t_assert_contains HAYSTACK NEEDLE LABEL
  if print -r -- "$1" | grep -qF -- "$2"; then t_ok "$3"
  else t_bad "$3 (missing [$2] in [$(print -r -- "$1" | head -3 | tr '\n' ' ')])"; fi
}
t_assert_file() {  # t_assert_file PATH LABEL
  if [[ -e "$1" ]]; then t_ok "$2"; else t_bad "$2 (no $1)"; fi
}
t_assert_no_file() {
  if [[ ! -e "$1" ]]; then t_ok "$2"; else t_bad "$2 ($1 exists)"; fi
}

# A fresh scratch tree that looks enough like an install for the functions under test.
t_setup() {
  mkdir -p "$TMPROOT"
  T_BASE=$(mktemp -d "$TMPROOT/case.XXXXXX")
  mkdir -p "$T_BASE/bin" "$T_BASE/conf" "$T_BASE/log" "$T_BASE/home"
  export T_BASE
  export BASE="$T_BASE"
  export HOME="$T_BASE/home"
  export PATH="$STUBS:$PATH"
  # A test config: real keys, tiny thresholds, no network use by the pieces under test.
  cat > "$T_BASE/conf/stream.env" <<'ENV'
CAM_URL="rtsp://127.0.0.1:8554/live/ch00_0"
YT_KEY="test-key-not-real"
YT_URL="rtmp://127.0.0.1:1935/live2"
MODE="crop"
CROP_GEOM="1920:1080:0:0"
ENV
  # Copy the scripts so tests can exercise them without ever writing to the checkout.
  cp "$REPO_DIR"/bin/*.sh "$REPO_DIR"/bin/*.py "$T_BASE/bin/" 2>/dev/null
  print -r -- "$T_BASE"
}

t_teardown() {
  [[ -n "${T_BASE:-}" && -d "${T_BASE:-}" ]] && rm -rf "$T_BASE"
}

# Extract one shell function's source text, so a single function can be exercised without
# running the script's main body (which would start processes and talk to the network).
t_extract_fn() {   # t_extract_fn FILE FUNCNAME
  awk -v fn="$2" '
    $0 ~ "^"fn"\\(\\)" { inside=1 }
    inside { print }
    inside && /^}/ { exit }
  ' "$1"
}

# Run a snippet of zsh with BASE/HOME/PATH already aimed at the scratch tree.
t_zsh() { BASE="$T_BASE" HOME="$T_BASE/home" PATH="$STUBS:$PATH" /bin/zsh -c "$1"; }

t_summary() {
  print ""
  if (( FAIL == 0 )); then
    print -- "  \033[32mALL PASSED\033[0m ($PASS checks)"
    return 0
  fi
  print -- "  \033[31m$FAIL FAILED\033[0m, $PASS passed"
  return 1
}
