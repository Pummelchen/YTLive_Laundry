#!/bin/zsh
# launchd entry point for cam_scan.py.
#
# WHY A SHELL WRAPPER AND NOT python3 DIRECTLY IN THE PLIST
#   Full Disk Access on this host is granted to /bin/zsh (see install.sh's FDA probe and
#   docs/operations.md). TCC follows the *responsible process*, so a LaunchAgent whose program
#   is python3 is denied the project folder itself:
#       python3: can't open file '/Users/user/Downloads/YTLive/bin/cam_scan.py':
#       [Errno 1] Operation not permitted
#   and with the framework python it does not even fail - it stalls inside the import
#   machinery waiting on a decision that never comes. Running the script through zsh inherits
#   the grant, exactly like stream.sh and yt_monitor.sh do.
BASE="${BASE:-${0:A:h:h}}"
exec /usr/bin/python3 "$BASE/bin/cam_scan.py" "$@"
