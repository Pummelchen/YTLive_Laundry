# YTLive_Laundry 2.5 — the checkout you are in, and the processes you actually own

2.5 does three things. It makes every entry point use the **checkout it is run from** instead of a
hardcoded `~/Downloads/YTLive` (T-14); it stops the two watchdogs from **signalling by command-line
pattern** and makes them signal an exact pid (T-16); and it lets the **deployed tree be clean
again** by moving the capture stamp out of a tracked file (T-39). The camera-side defects the 2.4
investigation left behind — tools that crashed on their own arguments, and a second WS-Discovery
implementation the code claimed did not exist — are fixed as well (T-15, T-17), and a publisher
death now says **why** it happened instead of only quoting an exit code (T-26). T-37 is **closed as
a symptom, not a defect**: the reader churn was the network, and it was measured, not patched. Full
detail is in [`CHANGELOG.md`](../CHANGELOG.md).

- Built from tag `v2.5`
- Contents: the tagged tree **without `MP3/`**, without `backup/` and without `AUDIT/`. The
  328 MB music library is byte-identical in git at the same tag
  (`git checkout v2.5 -- MP3`), which is why it is excluded rather than shipped. No credentials
  or runtime state are in any archive: `conf/stream.env`, `conf/yt_oauth.json`, `conf/watchdog.env`
  and `log/` are gitignored and were never committed.
- Source archive, not a build product: nothing to compile, no binaries, nothing to sign.

## T-14 — the checkout you are in is the checkout you use

Every entry point defaulted `BASE` to a hardcoded `~/Downloads/YTLive`. A copy of the tree on
another machine therefore read the **wrong configuration** and, worse, could read it silently:
`bin/preflight.sh` ignored `BASE` altogether, so `BASE=... bin/preflight.sh` probed the *installed*
config while the operator believed they were probing another tree. All of them now use
`BASE="${BASE:-${0:A:h:h}}"` (or `pathlib.Path(__file__).resolve().parent.parent` in Python),
which is the form `forensics.sh` has used since it was written. An explicitly passed `BASE` still
wins, because that is what the launchd agents and the tests pass.

`preflight.sh` needed more than the one line. It had **no shell options at all** and a fixed
`$HOME/.local/bin/ffprobe`. It now follows the repo's `set -u` convention, prefers the installer's
static build and falls back to `PATH`, and:

- an explicitly named `FFPROBE` that is **not executable** is a hard error (`exit 1`) rather than a
  silent fall-back to a different binary — a typo must not look like a camera fault;
- a missing ffprobe in both places is reported as `no ffprobe found`, not as a bare shell error;
- an empty `CAM_URL` is reported as `CAM_URL is empty in <conf>` before anything is probed.

**The limit:** the **install** still has to *be* at `~/Downloads/YTLive`. That is a TCC constraint
on launchd — a background agent in a protected directory needs Full Disk Access — not a script
constraint. `install.sh` warns when it is installed elsewhere and `preflight.sh` now fails loudly
rather than guessing, but nothing here moves the supported install path. What is fixed is that a
copy of the tree elsewhere runs correctly **by hand**.

The same default was changed in the entry points the 2.5 changelog does not name individually:
`bin/deploy-release.sh`, `bin/net_watch.sh`, `bin/shuffle_playlist.sh`, `bin/smoke_test.sh`,
`bin/yt_api.py`, `bin/yt_check.py` and `bin/cam_ip.py`.

## T-15 — camera tools no longer crash on, or leak, their arguments

Two of the camera tools did their work at **import time**:

- `bin/cam_config.py` indexed `sys.argv` with no arity check and resolved the camera host at
  module level. A short command line was an `IndexError` traceback, and merely importing the module
  performed network I/O and could `sys.exit`. The address resolution is now inside `main()`, and
  `get` / `set` / `bitrate` each check their own arity.
- `bin/onvif_probe.py` ran its whole probe at module level — the exact bug already fixed in
  `cam_reboot.py`, so importing it hit the camera. It now has a `main()` too, and it bounds the
  argument count at **both** ends, so a surplus argument is rejected rather than silently ignored.

Every usage error prints a one-line usage and exits **2**, with no traceback.

**Credentials.** The positional `USER PASS` form still works for compatibility, but `CAM_USER` /
`CAM_PASS` are now **preferred and win when they are set**, and argv credentials print a one-line
warning to stderr. That precedence is deliberate even when both are present: `argv` is
world-readable through `ps`, so a credential that is visible to every user on the machine must not
be the one that is used. The warning still fires when argv credentials are supplied but ignored,
because `ps` shows them either way. The `onvif_probe.py` output shape is unchanged.

## T-16 — exact process signalling instead of `pkill -f`

`stream.sh` and `yt_monitor.sh` restarted each other with `pkill -9 -f "zsh.*yt_monitor.sh"` and
`pkill -9 -f "ffmpeg.*rtmp"`. `-f` matches the **full command line of every process of every
user**, unanchored and with a greedy `.*`, so a hand-run diagnostic ffmpeg, a second copy of the
project or an editor's subshell could be killed — and `-9` leaves the victim nothing to clean up.
Both sides now write a pidfile and signal through the new helpers in `bin/lib.sh`:

- `stream.sh` writes `log/publisher.pid` immediately after it starts ffmpeg, so the monitor can
  restart exactly that process. It also reads `log/monitor.pid`.
- `yt_monitor.sh` writes its own `log/monitor.pid` at startup and reads `log/publisher.pid`.
- `pid_is PID NEEDLE...` is true only when the pid is **alive and its command contains every
  needle**; `pidfile_pid FILE NEEDLE...` prints the pid only when the file is readable and
  `pid_is` accepts it. The identity check is the point: **a pid gets recycled** between being
  written and being read.
- `stream.sh`'s hung-monitor path kills the checked pid when there is one, and otherwise falls
  back to `launchctl kickstart -k gui/<uid>/com.user.cctv-monitor` — and logs
  `kickstart failed too - THE STREAM IS UNWATCHED` if that fails as well.
- `yt_monitor.sh` **kills nothing** when there is no trustworthy pid, and says so in its log. A
  publisher restarted by hand is a deliberate act, and guessing is how a watchdog kills something
  it does not own.

`bin/status.sh` also stopped accepting any `ffmpeg.*rtmp://` on the machine: it identifies the
publisher through `log/publisher.pid` and prints its pid, and only falls back to the old probe when
the pidfile is absent (an older `stream.sh`) — warning that it cannot identify the process when it
does.

**The limit:** the helpers are proven against a live pid, a dead pid, a non-numeric pid, a missing
file and a live-but-foreign pid, but **not yet on a real hung monitor or a real bad-output
publisher** on the streamer. The behaviour when a pidfile is stale is the behaviour of "no
trustworthy pid": kill nothing. That is the safe direction, and it is also the conservative one —
a watchdog that cannot identify its target now declines to act rather than acting on a guess.

## T-17 — one WS-Discovery implementation, as the code always claimed

`bin/camscan.py` carried its own SOAP/3702 probe while `bin/cam_ip.py` documents
`bin/find_cam.py` as the **single** implementation, so a fix to one would silently miss the other.
`find_cam.py` grew `discover_replies()`, which returns the raw XML replies as `{ip: xml}` keyed by
sender (camscan prints the URLs inside the reply); `discover()` is now just a filter over it for
addresses whose reply identifies an ONVIF device. camscan's duplicate probe is gone — it loads
`find_cam.py` by path, the way `cam_ip.py` already did. This is also pinned by tests that fail if
`239.255.255.250` or `3702` reappears in `camscan.py`.

`camscan.py` additionally validates its CIDR with `ipaddress.ip_network()` **before** discovery, so
a typo exits 2 with the usage line instead of raising `ValueError` after a four-second multicast
wait. `cam_reboot.py` — whose import-time reboot was fixed earlier — keeps its `main()` and now
shares the same credential rule as `onvif_probe.py`.

## T-26 — a publisher death now says why

The log said only `PUBLISHER died rc=N`, and **rc alone does not say why**. `137` is SIGKILL, and
in this system that could be the broadcast rotation, the stall watchdog, an ingest bounce or the
shutdown trap — four different causes with four different responses, all printed as the same
number. `224` is ffmpeg's broken pipe because **YouTube closed the ingest**, and it was the only
*recurring* mode among the **192 deaths counted in the archived audit** (~1 per 2 days) — and
nothing in the log distinguished it from the rest.

Each deliberate kill now records its reason in `log/pub_kill_reason` **first**, and the death line
prints it:

```
PUBLISHER died rc=137 - deliberate: broadcast rotation (scheduled 8h3m reached) - restarting ...
```

The three deliberate sites are the rotation, the stall watchdog and the ingest bounce, and
`mark_pub_kill` is called at each. When nothing here caused the death, the line quotes **ffmpeg's
own last error line** from `log/publisher.log` (truncated to 200 chars), because that is the only
thing that can explain a death nothing local caused; an unmarked SIGKILL is attributed to the
monitor, which is the only outside killer. The reason file is cleared by the death handler and by
every `start_publisher`, so a stale reason cannot describe the next death.

**It is a file and not a variable, and that is the whole point:** `await_broadcast` runs in a
**subshell**, and a subshell cannot set the main loop's variables. A variable would have silently
shown every ingest bounce as `unknown` — the change would have looked correct and told the operator
nothing.

**The limit:** the mapping is unit-tested for `224`, `1`, `0`, a marked `137` and an unmarked
`137`, but **no real `rc=224` death has been observed since the change**, so the end-to-end line
has not yet been seen in production. This makes a death legible; it does not reduce the death rate,
and it does not attempt to.

## T-39 — the deployed tree can be clean again

`conf/broadcast_template.json` is **tracked**, and `capture` — which `stream.sh` runs at **every
rotation** — wrote a fresh `_captured_from` / `_captured_at` stamp into it each time. The merge is
idempotent, so that was a guaranteed modification of a tracked file every eight hours: the deployed
checkout was permanently dirty, and a `git pull` or `git checkout` in it could refuse or conflict.
What changed:

- the stamp moved to `log/broadcast_captured.json`, which `.gitignore` covers (`log/`);
- the legacy `_captured_from` / `_captured_at` keys are removed from the reference, so a deployed
  copy converges back to the tracked content and goes clean;
- `save_template()` now compares the serialized content and **skips the write when it did not
  change**, returning whether it wrote. `capture` reports that as `reference_written` in its JSON
  output.

**This is a correctness fix, not an optimisation**: a no-op must not modify a tracked file. The
idempotent merge and the capture itself are unchanged — the reference is still written the first
time and still written whenever the content really changes. The limit of the guarantee is exactly
the comparison: content that differs only in ways `json.dumps(indent=2, ensure_ascii=False)`
preserves will still write, which is what it is for.

## T-37 closed as a symptom, not a defect

T-37 was the reader churn: `READER: feed from 192.168.1.3 ended after Ns`, with a **median session
of 15 s**. It was measured, and the measurement says the churn was a property of the **outage
window**, not of the camera handling:

| Measurement | Value |
|---|---|
| Reader restarts per hour **during** the outage window | **89–106** |
| Reader restarts per hour in the **2.5 hours after** it | **0** |
| Camera answering pings | **20/20** |
| Reader uptime since | continuous since **16:24** |

**This is not a fix and is not presented as one.** No code was changed to make the reader quieter;
what changed is the network, and the restart rate went to zero with it. The residual in
`reader.log` is occasional H.264 bitstream corruption from the camera and jittery LAN latency
(**1.7–209 ms**), both worth watching, neither a code fault. For the record, the reader failure
shapes observed were `Operation timed out` (1217), `Host is down` (75) and `No route to host` (20).
Closing a task as a symptom rather than a defect is the honest outcome here: it removes a
non-actionable item from the queue without claiming a repair that did not happen.

## Files in this release

| File | Change |
|---|---|
| `bin/lib.sh` | new `pid_is PID NEEDLE...` and `pidfile_pid FILE NEEDLE...`: liveness **and** command-identity check, because a pid gets recycled |
| `bin/stream.sh` | `BASE` from its own path; writes `log/publisher.pid`; restarts a hung monitor by checked pid, else `launchctl kickstart -k`; `mark_pub_kill` records why a deliberate kill happened and `pub_death_reason` names the code (T-26) |
| `bin/yt_monitor.sh` | `BASE` from its own path; writes `log/monitor.pid`; restarts the publisher by pid from `log/publisher.pid`, or kills nothing and logs that it did |
| `bin/status.sh` | `BASE` from its own path; sources `bin/lib.sh`; the publisher section identifies the publisher by pid instead of accepting any `ffmpeg.*rtmp://` |
| `bin/preflight.sh` | `BASE` honoured and derived from its own path; `set -u`; `FFPROBE` named-but-missing is fatal, else installer build then `PATH`; empty `CAM_URL` reported |
| `bin/yt_api.py` | `BASE` from its own file; `CAPTURED = log/broadcast_captured.json`; `save_template()` writes only on a real change; `capture` drops the legacy stamp keys and reports `reference_written` |
| `bin/yt_check.py` | `BASE` from its own file (an explicit `BASE` still wins) |
| `bin/cam_config.py` | `main()` and per-subcommand arity checks, usage on stderr with exit 2; host resolution moved out of import time; `BASE` from its own file |
| `bin/cam_reboot.py` | shares the credential rule (`CAM_USER`/`CAM_PASS` win, argv warns); usage line names it |
| `bin/camscan.py` | its own SOAP/3702 probe removed — discovery delegates to `find_cam.py`; CIDR validated **before** discovery; surplus arguments rejected; `BASE`-independent |
| `bin/find_cam.py` | new `discover_replies()` (raw `{ip: xml}`) with `discover()` as a filter over it, so the single implementation serves both callers |
| `bin/cam_ip.py` | `BASE` from its own file; discovery comment names `find_cam.py` as the single implementation |
| `bin/onvif_probe.py` | all work moved into `main()`; arity checked at both ends; usage with exit 2; `CAM_USER`/`CAM_PASS` preferred with an argv warning (named in the changelog under T-15) |
| `conf/broadcast_template.json` | the `_captured_from` / `_captured_at` stamp removed; the file is written only when the merged content really changes |
| `log/pub_kill_reason` (**runtime state, gitignored**) | the reason a deliberate publisher kill is about to happen, written before the kill because the death handler runs in the main shell and `await_broadcast` does not; cleared by the death handler and by every `start_publisher` (T-26) |
| `bin/deploy-release.sh`, `bin/net_watch.sh`, `bin/shuffle_playlist.sh`, `bin/smoke_test.sh` | `BASE` defaulted from the checkout the script lives in (the mechanical half of T-14) |
| `tests/t10_camtools.sh` | **new** — 50 checks |
| `tests/t11_paths_pids.sh` | **new** — 37 checks (BASE, the pidfile helpers, the tracked reference, and the T-26 death-reason mapping) |

## Verification

Measured on 2026-09-19 from the working tree with `zsh tests/run.sh` (serial, all files) and then
per file with `zsh tests/run.sh <name>`. The runner prints a per-file count, not a grand total;
the total below is the sum of the per-file counts.

| Test file | Checks | Result |
|---|---|---|
| `tests/t01_syntax.sh` | 48 | all passed |
| `tests/t02_monitor_classify.sh` | 12 | all passed |
| `tests/t03_files.sh` | 11 | all passed |
| `tests/t04_token.sh` | 13 | all passed |
| `tests/t05_rotation_gate.sh` | 15 | all passed |
| `tests/t06_install.sh` | 21 | all passed |
| `tests/t07_watchdog.sh` | 120 | all passed |
| `tests/t08_hosttools.sh` | 46 | all passed |
| `tests/t09_net.sh` | 42 | all passed |
| `tests/t10_camtools.sh` | 50 | all passed |
| `tests/t11_paths_pids.sh` | 37 | all passed |
| **Total** | **415** | **`SUITE PASSED`** |

- The project's own suite, serially: **checked** — 415 checks, all passing. The runner reports
  `ALL PASSED` per file and `SUITE PASSED` at the end.
- `tests/t10_camtools.sh` (new): **checked** — 50 checks. Every camera tool's usage error, the
  credential rule in both directions (argv works; `CAM_USER`/`CAM_PASS` win; the warning fires when
  argv credentials are present but unused), that importing each module performs no network I/O
  (with `socket` and `urllib` poisoned to raise) and that `camscan`/`cam_ip` really delegate to
  `find_cam` — proven against a recorder stub that fails if either probes on its own.
- `tests/t11_paths_pids.sh` (new): **checked** — 37 checks. The BASE behaviour end to end,
  including `preflight.sh` reading another tree's `conf` and refusing a nonexistent `FFPROBE`; the
  pidfile helpers against a live, a dead, a non-numeric and a foreign pid; that a no-op capture
  does not rewrite the tracked reference; and the T-26 reason mapping for `224`, `1`, `0`, a marked
  `137` and an unmarked `137`.
- A real `rc=224` publisher death end to end (T-26): **not checked** — the mapping is unit-tested,
  but no such death has been observed since the change, so the finished log line has not been seen
  in production.
- `bin/status.sh` while a foreign ffmpeg pushes to rtmp: **not checked** — the fall-back path that
  warns instead of reporting health is exercised by text, not by running a second publisher.
- The pidfile helpers against a **real** hung monitor or bad-output publisher on the streamer:
  **not checked** — no such event was staged, and staging one means deliberately hanging the
  watchdog. The helpers themselves are tested against live/dead/foreign pids.
- Real camera hardware for T-15 and T-17: **not checked** — t10 poisons `socket()` and `urlopen()`
  and never opens a socket, so argument handling and delegation are proven without touching the
  LAN; no `set`/`bitrate` write was sent to the camera.
- T-37's measurement: **not re-derived here** — the restart counts, the 20/20 pings and the 16:24
  uptime come from the outage investigation and the streamer's own logs; the reader churn is not
  reproducible on the reference machine.
- The release gates (`release.sh`): syntax (`zsh -n` per shell file, `ast.parse` per Python
  module), the suite from the archive, and the per-file byte-match against the tag: **checked at
  publish time**, the same mechanical gates 2.2, 2.3 and 2.4 used.
- `bin/smoke_test.sh`: **not checked** — it needs `conf/yt_oauth.json`, which is gitignored and in
  no archive, so it cannot pass inside a release. It is not a release gate.

## Deploying this

The channel is live, so this is a normal deploy: `bin/status.sh` and `bin/smoke_test.sh` on the
streamer first, then `bin/deploy-release.sh --tag v2.5`. Read
[Updating and rollback](https://github.com/Pummelchen/YTLive_Laundry/wiki/Updating-and-Rollback)
first. Two things are worth checking after the first restart:

- `log/publisher.pid` and `log/monitor.pid` should exist and hold live, matching pids; the
  monitor's log says `killed nothing` rather than killing by pattern if either is unusable.
- The first rotation after the deploy is the real test of T-39: `git status` in the deployed tree
  should stay clean across a capture. A capture that changed nothing also prints
  `"reference_written": false`.

The streamer was on 2.1 at the time of the 2.4 work and still needs `bin/harden-host.sh --go`
(autorestart) and a decision on the wired adapter — replace it or leave it disabled and stay on
Wi-Fi. Neither is changed by this release.

```
SHA256  SHA256_PENDING
BYTES   ARCHIVE_BYTES_PENDING
```
