# Changelog

The scheme is two-component `MAJOR.MINOR`, released as the tags `v1.0`, `v2.0`, `v2.1`, `v2.2`,
`v2.3` and `v2.4`. The
authoritative version is the `VERSION` file at the repository root; a release refuses to build
when `VERSION` and the tag disagree. There is no version literal in any script: the streamer's
tunables live in `conf/stream.env`.

Each release is a source archive of the tagged tree with a SHA-256 beside it. There is nothing
to compile. See `release.sh` and [`RELEASE.md`](RELEASE.md).

## 2.6 — 2026-09-19

**The API quota can no longer take the channel dark, drift checking stopped chasing a field that
can never change, the disk guard acts before it reports, and the repository finally has a CI gate.
One row closed by measurement instead of by code: the camera's clock.**

- **T-06 — the quota hole, and the loop that was filling it.** YouTube gives one 10,000-unit pool
  per day; the 2026-09-16 audit measured a worst case of **10,290** here, and found something
  worse than the number: on `403 quotaExceeded` the code **did not stop** — `prepare` failed, ffmpeg
  restarted anyway, and the channel went dark at that rotation. Two fixes, both regression-guarded
  in `tests/t13_quota.sh`:
  - **The driver.** `yt_api.py verify` reports two kinds of drift and only one can be fixed:
    video-level `diffs` that `enforce` can write, and **`broadcast_diffs`, which are fixed at
    creation and no update can ever change**. `enforce_drift` enforced on *any* `DRIFTED`, so a
    creation-time-only difference was chased every 1800 s forever — up to ~158 units a shot, the
    bulk of the overrun. It now enforces only fixable drift, reports the unfixable kind once, and
    gives up loudly (`ENFORCE_MAX_ATTEMPTS`, default 3) when the *same* field set survives an
    enforce — scoped to the set, so a different drift is chased again.
  - **The hole.** A `403 quotaExceeded` now arms `log/quota_exhausted`, and every later call refuses
    **before making a request**, so a retry loop cannot spend the rest of the day. `yt_api.py quota`
    is the free check, and `rotate_broadcast()` asks it — because the token probe hits the OAuth
    endpoint, which is *not* the Data API and still answers `LIVE` with an empty pool. A rotation
    with no quota now **refuses to cut** (`ROTATE_WITHOUT_API=no`) instead of cutting into a state
    where no successor can be created.
- **T-13 — the disk guard acts before it reports.** Below `DISK_LOW_MB` (1000) `housekeep` now cuts
  every log to a quarter of its budget and drops the regenerable monitor caches, to buy time; below
  200 MB it says the failure has become a human's problem. It never touches the filler stills
  (losing them degrades the next publisher start), never `log/progress.txt` (ffmpeg writes it at a
  fixed offset), and never a deploy backup or `.git` — those are the rollback, a decision rather
  than housekeeping. **The honest limit, recorded rather than papered over:** the streamer still
  cannot *tell* anyone; the off-host watchdog is the only component allowed to notify and it learns
  about the disk only when the channel finally stops. The **near half is done and the alert half
  depends on the delivery decision**, so the row moves to `Blocked`/`operator` rather than closing.
- **T-18 — the first automated gate this repository has ever had.** `.github/workflows/ci.yml` runs
  `tests/run.sh` on **macOS** runners for every push to `main` and every pull request. macOS only,
  deliberately: the suite uses `zsh` idioms, `stat -f`, `plutil` and a `pmset` stub, so a Linux job
  would fail for reasons that are not defects. `bin/smoke_test.sh` is deliberately **not** in CI —
  it needs `conf/yt_oauth.json` — so it stays a by-hand host gate. `AGENTS.md`, `README.md`,
  `RELEASE.md` and `tests/README.md` no longer claim there is no CI.
- **T-28 — `bin/deploy-release.sh` is tested.** `tests/t12_deploy.sh` (57 checks) runs entirely in
  `tests/.tmp` with a fake `HOME`/`BASE` as siblings and a fake `git` that refuses `checkout`, so no
  run can reach `./install.sh`; a tripwire would record it if one did. It covers the dry run
  changing nothing, argument handling, the extracted `ytdlp_works` preflight (including the
  `ERROR`-with-exit-0 case that blinded `yt-dlp` once), `rollback` restoring the tree **and** the
  out-of-tree state, the `PARTIAL ROLLBACK` path, the `--go` kill switch, and `--wait-for-cut`
  rotation detection — which had never been exercised at all.
- **T-25 closed as not fixable on this firmware, with the evidence.** The camera burns its own clock
  into the top panel and it renders **UTC+8 on a UTC+7 island**, so every viewer sees a time an hour
  ahead. `bin/cam_time.py` reads and writes it over ONVIF — the only open interface, since port 80
  and the XM/Dahua CGI are closed — and on the real camera: ONVIF reported `timezone PST0PDT` with a
  correct UTC, the OSD read `20:44:21` while local time was `19:45`; after `set WIB-7` ONVIF
  reported `WIB-7` and the OSD read `20:45:47` while local time was `19:46`. **Accepted, reported
  back, ignored** — the same lie the encoder settings tell. The UTC clock is correct and NTP-synced,
  so nothing downstream depends on the wrong display, but the display cannot be fixed from here.
  Recorded in `docs/camera.md` so it is not re-opened as a task.
- **Tests.** `tests/t13_quota.sh` (21 checks: the cooldown as pure logic, the refusal to spend, and
  the drift loop) and `tests/t12_deploy.sh` (57) are new. `tests/t03_files.sh` grew to 22 with the
  disk guard, and `tests/t10_camtools.sh` to 63 with `cam_time.py`. The suite is now **520 checks**
  (t01 51, t02 12, t03 22, t04 13, t05 15, t06 21, t07 120, t08 46, t09 42, t10 63, t11 37, t12 57,
  t13 21).

## 2.5 — 2026-09-19

**The queue's own top rows, plus the two operational defects the 2.4 investigation left behind:
a script that would not work anywhere but one directory, watchdogs that killed by pattern, and a
tracked file that the rotation rewrote every eight hours.**

- **T-14 — every entry point now uses the checkout it is run from.** All of them defaulted `BASE`
  to a hardcoded `~/Downloads/YTLive` (`BASE="${BASE:-${0:A:h:h}}"`, or
  `pathlib.Path(__file__).resolve().parent.parent` in Python), so a copy of the tree on another
  machine read the wrong configuration — and `bin/preflight.sh` ignored `BASE` altogether, which
  made `BASE=... bin/preflight.sh` silently probe the *installed* config. It also had no shell
  options and a fixed `$HOME/.local/bin/ffprobe`; it now follows the repo's `set -u` convention,
  prefers the installer's build and falls back to `PATH`, and fails loudly on an explicitly named
  ffprobe that does not exist rather than quietly probing with a different binary. The install
  still has to **be** at `~/Downloads/YTLive` — that is a TCC constraint on launchd, not a script
  one.
- **T-15 — camera tools no longer crash on, or leak, their arguments.** `bin/cam_config.py`
  indexed `sys.argv` with no arity check and resolved the host *at import*, so importing it did
  network I/O and could `sys.exit`; `bin/onvif_probe.py` ran its whole probe at module level, the
  exact bug already fixed in `cam_reboot.py`. Both now have a `main()` and an arity check that
  prints a one-line usage and exits 2 with no traceback. Credentials still work positionally for
  compatibility but `CAM_USER`/`CAM_PASS` are preferred, and argv credentials print a one-line
  warning — argv is world-readable through `ps`.
- **T-16 — nothing is signalled by pattern any more.** `stream.sh` and `yt_monitor.sh` restarted
  each other with `pkill -9 -f "zsh.*yt_monitor.sh"` and `pkill -9 -f "ffmpeg.*rtmp"`. `-f`
  matches the full command line of every process of every user, unanchored, so a hand-run
  diagnostic ffmpeg, a second copy of the project or an editor's subshell could be killed — and
  `-9` leaves nothing to clean up. Both sides now write a pidfile (`log/publisher.pid`,
  `log/monitor.pid`) and signal through `pidfile_pid`, which also checks that the pid still looks
  like the process we mean, because **a pid gets recycled**. When there is no trustworthy pid the
  monitor kills *nothing* and says so in its log. `stream.sh` falls back to
  `launchctl kickstart -k` for the hung monitor, and `bin/status.sh` now identifies the publisher
  instead of accepting any `ffmpeg.*rtmp://` on the machine.
- **T-17 — one WS-Discovery implementation, as the code always claimed.** `bin/camscan.py`
  carried its own SOAP/3702 probe while `bin/cam_ip.py` documents `bin/find_cam.py` as the single
  implementation. `find_cam` grew `discover_replies()` (raw XML, for camscan, which prints the
  URLs inside the reply) with `discover()` as a filter over it; camscan's duplicate is gone and it
  now validates its CIDR with `ipaddress.ip_network()` *before* discovery, so a typo exits 2
  instead of raising `ValueError` after a four-second multicast wait.
- **T-39 — the deployed tree can be clean again.** `conf/broadcast_template.json` is tracked, and
  `capture` — which `stream.sh` runs at **every rotation** — wrote a fresh `_captured_from` /
  `_captured_at` stamp into it each time. The merge is idempotent, so that was a guaranteed
  modification of a tracked file every eight hours: the deployed checkout was permanently dirty
  and a `git pull` or `git checkout` in it could refuse or conflict. The stamp moved to
  `log/broadcast_captured.json` (ignored), the legacy keys are removed from the reference, and
  `save_template()` now skips the write when the content did not change. **This is a correctness
  fix, not an optimisation**: a no-op must not modify a tracked file.
- **T-37 closed as a symptom, not a defect.** The reader churn — `READER: feed from 192.168.1.3
  ended after Ns`, with a median session of 15 s — was measured at **89–106 restarts per hour
  during the outage window** and **zero in the 2.5 hours after it**, with the camera answering
  20/20 pings and the reader up continuously since 16:24. It was the network, not the camera
  handling. The residual in `reader.log` is occasional H.264 bitstream corruption from the camera
  and jittery LAN latency (1.7–209 ms), both worth watching but neither a code fault. The reader
  failure shapes are also now recorded: `Operation timed out` (1217), `Host is down` (75) and
  `No route to host` (20).
- **T-26 — a publisher death now says why.** The log said only `PUBLISHER died rc=N`, and rc alone
  does not say: 137 is SIGKILL and could be the broadcast rotation, the stall watchdog, an ingest
  bounce or the shutdown trap, while **224 is ffmpeg's broken pipe because YouTube closed the
  ingest** — the only recurring mode in the archived audit's 192 deaths (~1 per 2 days), and
  nothing distinguished it. Each deliberate kill now records its reason in `log/pub_kill_reason`
  first — a *file*, not a variable, because `await_broadcast` runs in a subshell and a subshell
  cannot set the main loop's variables — and the death line reports it, or quotes ffmpeg's own
  last error line when nothing here caused the death. An unmarked SIGKILL is attributed to the
  monitor, which is the only outside killer.
- **Tests.** `tests/t10_camtools.sh` (50 checks) proves the camera tools' usage errors, that
  importing them performs no network I/O (with `socket` and `urllib` poisoned to raise), and that
  `camscan`/`cam_ip` really delegate to `find_cam`. `tests/t11_paths_pids.sh` (37 checks) covers
  the BASE behaviour end to end — including `preflight.sh` reading another tree's config — the
  pidfile helpers against a live, a dead and a foreign pid, that a no-op capture never rewrites
  the tracked reference, and the whole death-reason mapping. The suite is now **415 checks**
  (t01 48, t02 12, t03 11, t04 13, t05 15, t06 21, t07 120, t08 46, t09 42, t10 50, t11 37).

## 2.4 — 2026-09-19

**The 2026-09-18 outage was not what the 2.2/2.3 documentation said it was, and the fix is a
layer of the design that did not exist: the transport.** The incident is closed — the channel
went live again on 2026-09-19 — and the machine's own records contradict the recorded cause, so
this release corrects the record and then fills the hole the incident exposed.

### What actually happened (correcting 2.2, 2.3 and the wiki)

`docs/release-notes-v2.2.md` and `.3`, the handover and the wiki all recorded the leading cause
as *a momentary mains interruption while the lid was shut, after which the Mac slept on battery*.
That is **falsified** by the host's own records, read on 2026-09-19:

- **It never rebooted.** `kern.boottime` is Mon Aug 31 01:55:19 2026; uptime at the time of
  measurement was 19 days 17 hours. A panic, a forced power-off and a reboot to a login window are
  all excluded, and the console user was `user`, so both LaunchAgents were loaded.
- **It never slept, and never ran on battery.** Across a `pmset -g log` window covering
  2026-09-12 → 09-19 there are **zero** `Entering Sleep`/`Wake from` lines and **zero**
  AC/battery transition lines. (The sleep/wake section of `bin/forensics.sh` is empty for the
  last two days for the same reason.)
- **It was awake and logging throughout.** `log/stream.log` holds 640–760 lines per hour
  through 08:00–12:00 WIB on 09-19 — while the host was still absent from the tailnet.

What the log actually says is a **transport failure**: `PREPARE: network error talking to
YouTube: <urlopen error [Errno 8] nodename nor servname provided, or not known>` — a DNS
resolution failure — and `CAM-WATCH: 192.168.1.3 not answering on 554` followed by `no ONVIF
camera found on the LAN`, which is the *local* link. The Mac had lost DNS **and its own LAN**
while it kept running and retrying. The shop's uplink was never the problem.

Timeline as measured: ingest stopped **2026-09-18T10:19:54Z**, 5h14m into an 8h03m segment; the
network returned on 09-19 around 05:00Z; the first successor broadcast created after the outage
went live at **05:46:12Z** (`D9kF4Rf9uPU`); the current stable broadcast `ycAbb2G_Q2U` went live
at **08:06:55Z**. **Dark for ~19h26m**, not the 10h23m the earlier documents recorded.

Two further facts from the same investigation:

- **The external watchdog performed correctly and was still nearly useless at the end**, because
  `yt-dlp` returns `unknown` under a rate limit: it raised two `blind` alerts and its "channel is
  LIVE again" mail arrived **5h21m after** the channel had actually recovered. Its own `DARK for
  11h05m` reminder went out 57 seconds *before* the recovery.
- **The streamer's name resolution depended on a single nameserver inside the shop router**
  (`192.168.1.1`, A-records only). The reference Mac in this project carries four IPv4 and four
  IPv6 public resolvers from two independent providers on every service. That asymmetry is now
  removed on the streamer.

### The fix: a transport layer under the retries

- **`bin/net_watch.sh`** — the missing bottom of the design rule "every failure path retries".
  Every retry in `stream.sh` retried the *application* layer (ffmpeg, ONVIF discovery, the OAuth
  probe) and not one of them ever touched the network interface, which is why the 19h26m outage
  was outside the reach of all of them. The new watchdog probes once every `NET_CHECK_EVERY`
  (30s) and classifies the transport as exactly one of `OK / NOLINK / NOGW / NOWAN / NODNS`,
  then — only after `NET_FAIL_SAMPLES` (3) *consecutive* failures, so a 60s router reboot cannot
  trigger a repair, and inside a rate limit (`NET_MIN_ACTION_INTERVAL`, `NET_MAX_ACTIONS_PER_HOUR`)
  — climbs a ladder: re-assert DNS → re-assert DHCP → power-cycle the wireless radio. The decision
  is a pure function of `(state, failures, seconds since last action, actions this outage,
  actions this hour)`, so a 15-minute rule is tested in microseconds, exactly like `yt_watchdog.py`.
- **Two things it must never do, both learned the hard way.** It never **power-cycles a network
  service**: toggling the USB-Ethernet service on 2026-09-19 killed that adapter's carrier and it
  did not come back, so the wired NIC is only ever asked to re-assert DHCP. And it never
  **reorders the service list**: a secondary interface with no router gets no default route, so
  macOS already prefers the working one, and one mistyped `-ordernetworkservices` is a broken
  only path. Wired stays first, so it becomes primary by itself the moment it holds a real lease —
  which is the intent: **LAN primary, Wi-Fi backup**. `bin/status.sh` now says which interface is
  actually carrying the traffic and warns when that is not the intended primary.
- **`LOG_MAX_BYTES_STREAM` (2 MB)** — a second, larger trim budget for `stream.log`. The old
  512 KB cap keeps only its last half, which at the measured ~700 lines/hour of an outage storm
  retained about four hours, so the trim erased the **first** hours of this one. That is why the
  earliest part of the incident cannot be read from the log at all. `log/net_events.log` records
  transitions rather than every probe, so it survives a 20-hour outage regardless.
- **`bin/forensics.sh` gained a Network section** — interfaces and whether one is `active` with
  only a `169.254` self-assigned address, service order, default route, resolvers with their
  flags (so a supplemental Tailscale resolver can be told from the default one), Wi-Fi SSID and
  **signal/noise**, DHCP, ARP (which interface resolved the gateway), and Tailscale presence. The
  section that would have answered this incident from the machine instead of from a day of
  inference.
- **A `zsh` bug in `forensics.sh`** — the panic-report lines used a bare `*.panic` glob. zsh treats
  an unmatched glob as a hard error printed *before* any redirection can suppress it, so on a
  healthy host the report carried error text into the evidence. Now null-globbed.
- **`bin/yt_watchdog.py` no longer depends on `yt-dlp` alone.** A second, independent channel read
  fetches the channel's `/live` page over plain HTTPS and combines with `yt-dlp` so that a rate
  limit cannot blind the watchdog: either reader saying `live` is live, both saying `offline` is
  offline, anything else is unknown. `UNKNOWN` still never pages anyone.
- **A dead-man heartbeat** (`WATCH_HEARTBEAT`, `WATCH_HEARTBEAT_MAX`) that reports a streamer whose
  application has gone silent even when the channel read is `unknown`. Deliberately, delivery is
  not implemented: the two options are a push endpoint or a restricted SSH pull, and choosing
  between them is a security decision, not a coding one.
- **`tests/t09_net.sh`** — 42 checks driving the classifier through stubs (so the suite still
  needs no network and cannot touch a real interface), the whole action ladder, the rate limits,
  the operator hold, and the safety property that no action may power-cycle a service or disable
  the radio. `tests/t07_watchdog.sh` grew 76 → 120 and `tests/t08_hosttools.sh` grew with the new
  forensics section. `t_extract_fn` in `tests/lib.sh` now also handles single-line function
  definitions; it previously read past them to the next function's closing brace, so a test could
  exercise the wrong text and still pass.

### Also on the streamer (configuration, not code)

- Redundant public resolvers (`8.8.8.8 8.8.4.4 1.1.1.1 1.0.0.1`) set on the streamer's services,
  so resolution no longer depends on the router or on which service macOS considers primary.
- The streamer was running **2.1**; the wired interface was found `active` at 100baseTX with a
  `169.254` self-assigned address and no route to the router, while being **first** in the service
  order — a linked-but-unusable primary. It has no carrier at all now and needs a site visit: a
  cheap WCH `1a86:5394` USB adapter whose link did not survive a service toggle. Replace it with a
  better adapter, or leave it disabled and stay on Wi-Fi.

## 2.3 — 2026-09-19

**Two commands for the two things that went wrong: one to find out why a host died, and one to
stop it happening again.** The host hardening that `docs/known-issues.md` had recorded as
still-wanted is now applied *and verified* by a script, and the evidence for a host-level outage
is gathered by one read-only command. Full notes:
[`docs/release-notes-v2.3.md`](docs/release-notes-v2.3.md).

Released while the 2026-09-18 outage was still open — the streamer is offline and needs physical
access — because these two tools are what the recovery itself needs.

- **`bin/harden-host.sh`** — applies `pmset -a autorestart 1` and `pmset -c sleep 0
  disablesleep 1`, then verifies them. Dry run by default, `--go` to apply, `--check` to verify
  only. This is what closes T-29, and it cannot close it on a guess: `SleepDisabled` and
  `autorestart` are reported by `pmset` **only when they are enabled**, so an absent key is
  treated as a failure rather than as an unknown.
- **`bin/forensics.sh`** — read-only evidence for a host-level outage, run **before** a reboot
  because that is what destroys the in-memory half. It answers the four questions that are
  indistinguishable from outside, all of which look like "powered on, wifi fine, Tailscale
  offline": did it sleep and when, did it hang (load and swap), did it panic or lose power
  (panic reports and the previous shutdown cause), or did it reboot to a login window where the
  user LaunchAgents never start? Then it prints how to read its own output.
- **`tests/t08_hosttools.sh`** — 27 checks against a `pmset` stub that reports its two keys only
  when enabled, which is how macOS actually behaves, plus the safety properties of a script that
  changes how a production Mac behaves with the lid shut: the dry run issues no write at all,
  `--check` passes only when both settings are on, half-hardened is still a failure, and `--go`
  refuses without root and changes nothing. The suite is now **199 checks**.
- **The mechanism, recorded because it is not the obvious one.** The MacBook's lid is always shut
  and it had streamed that way for days, because `stream.sh`'s `caffeinate -s` prevents system
  sleep — but only **on AC power**, and lid-close (clamshell) sleep is a separate assertion that
  none of those flags touch. So losing mains for an instant is enough: on battery with the lid
  shut the Mac sleeps at once, and nothing wakes a closed-lid Mac — wake-on-LAN is LAN-only, and
  `autorestart` does not apply to a machine that is merely asleep. `disablesleep 1` is the flag
  that covers it.

## 2.2 — 2026-09-19

**The streamer died and nothing said so for 10h23m. The one class of failure the retry-only design
cannot cover now has a watchdog outside the box, and the pmset fix that was already written down
is a runbook instead of a note.** Full notes:
[`docs/release-notes-v2.2.md`](docs/release-notes-v2.2.md).

On 2026-09-18 the streamer `ternak-macbook` dropped off the network mid-segment. The evidence is
unusually clean: the last broadcast `3Cnxr6fTrWk` stopped receiving ingest at **10:19:54Z**, and
Tailscale's last contact with the host was **10:20:00Z** — the same second. The segment was 5h14m
into an 8h03m window, so this was not a rotation. Everything before it was flawless: four
consecutive 8.05h segments with 4.5–5.2 min gaps. The shop's own uplink stayed up — its public
egress IP answered ICMP 10/10 at ~5 ms — while the Mac answered nothing, so the failure was the
host, not the line. The most likely mechanism is a shop power/router loss, after which the Mac ran
on battery and slept, and never restarted because `autorestart` is off and lid-closed sleep is not
disabled.

Every existing failure path behaved correctly and none of them could help: a process that is not
running cannot retry, and launchd cannot revive a machine that is off. The channel stayed dark for
over ten hours because the design rule is "no notifications — every failure path retries", which
is right for the streamer and inapplicable to the streamer being gone.

- **`bin/yt_watchdog.py`** — the first component here designed to run OFF the streamer, and the
  only one allowed to notify a human. Two independent signals: the channel via `yt-dlp` (the
  `live`/`offline`/`unknown` split and `OFFLINE_SIGNS` are copied from `yt_check.py`, so a rate
  limit cannot page anyone) and the streamer's Tailscale presence, which cannot be blinded by a
  YouTube change. A dark channel alerts after 15 min — above the measured ~5 min rotation gap —
  reminds every 6 h, and sends one recovery mail. `UNKNOWN` never alerts; 45 min blind is reported
  as blind. An undeliverable alert is spooled and retried, never dropped. Stdlib-only, portable,
  and it never writes into the repository.
- **`bin/watchdog-install.sh`** — installs it as a systemd unit on Linux or a LaunchAgent on macOS,
  seeds `conf/watchdog.env` at 0600, and refuses to imply that starting is safe: run `test-alert`
  first. A running watchdog whose alerts silently fail is worse than no watchdog.
- **`tests/t07_watchdog.sh`** — 49 checks driving the alerting policy as a pure function of time,
  so a 6-hour rule is tested in microseconds with no clock and no network. The suite is now
  **168 checks**.
- **`conf/watchdog.env.example`, `conf/ytlive-watchdog.service`, `docs/watchdog.md`** — the config
  template, the unit, and the design and operator runbook.
- **Deployed and running** on the Intel VPS under systemd (`ytlive-watchdog`), watching both
  signals. Email goes out over authenticated Gmail submission; unauthenticated direct-to-MX is
  rejected (`550 5.7.26`), which is why the app password exists.
- **Host hardening is a runbook now.** `docs/operations.md` gained the pmset section:
  `sudo pmset -a autorestart 1` and `sudo pmset -c sleep 0 disablesleep 1`, with the honest limit
  that neither survives losing power entirely — that needs a UPS on the Mac *and* the router. Not
  yet applied: the streamer needs physical access.
- **Three bugs found by actually testing it.** The `yt-dlp` test stub had never matched anything —
  a quoted `"\(...\)"` in a zsh `case` pattern keeps its backslashes, so it fell through to an
  empty `exit 0`, and no earlier test had exercised its stdout. `decide()` used `x or now`, which
  treats the legitimate timestamp 0 as unset. And `status` crashed on the real host because
  Tailscale reports `LastSeen` as an RFC3339 string while `human_time()` assumed an epoch: `once`
  was fine, `status` died. All three are regression-guarded.
- **Documentation drift corrected**, including the test count (documented as 84 in eight places,
  actually 168), `RELEASE.md` and `AGENTS.md` still stopping at v2.0, `bin/deploy-release.sh`
  missing from the file inventory, and `docs/release-notes-v2.1.md` still claiming production ran
  1.0.

## 2.1 — 2026-09-17

**The installer could never complete, and it installed the wrong `yt-dlp`.** Full notes with the
evidence: [`docs/release-notes-v2.1.md`](docs/release-notes-v2.1.md).

Both defects were found by running the 2.0 deploy for real on 2026-09-17. It failed at
`install.sh` and rolled back — and the rollback then reported success while leaving the machine's
`yt-dlp` broken and the monitor blind, because the damage was outside the project tree. Three
fixes, and a gate so this class of bug cannot ship again:

- **`install.sh` could not run at all.** `write_plist()` declared five variables in one `local`,
  and a shell expands *all* of a command's arguments before `local` executes — so `$label` was read
  while still unset and, under `set -u`, the shell exited: `write_plist:1: label: parameter not
  set`. Each declaration is now on its own line.
- **It picked the wrong Python.** `PY=$(command -v python3)` trusted PATH order and chose the
  Xcode Command Line Tools **3.9.6** instead of the python.org **3.14** on the same machine. pip
  then resolved `yt-dlp` to the last release supporting 3.9 (`2025.10.14`), which can no longer
  parse YouTube's live page, and `ln -sf` put that stale build **over a working
  `~/.local/bin/yt-dlp`** (`2026.08.19`), blinding the monitor. The installer now scans PATH *and*
  the usual install locations, prefers an interpreter that already has `yt_dlp`, and falls through
  to the next candidate when pip refuses (`PEP 668` on Homebrew Python).
- **It no longer clobbers a working `yt-dlp` with a worse one.** The existing binary is compared
  first and kept if it is newer; if a replacement is written and does not run, the previous one is
  restored automatically.
- **`bin/deploy-release.sh`** replaces the ad-hoc deploy. Its backup covers what `install.sh`
  actually writes — `~/.local/bin`, `~/Library/LaunchAgents`, `~/Library/Logs/YTLive` — not just
  the project tree, it refuses a downgrade, and it verifies the *result* (including that `yt-dlp`
  still resolves the live page) rather than trusting an exit code.
- **`tests/t06_install.sh`** actually **runs** `install.sh` in a sandbox with fake interpreters.
  The suite only syntax-checked it, which is exactly how a fatal runtime abort passed the release
  gate. The new test fails **16 of 21** checks against the released 2.0 installer and passes 21/21
  against this one.

## 2.0 — 2026-09-16

The fixes from the 2026-09-16 full audit. Full notes, with the
check behind each change: [`docs/release-notes-v2.0.md`](docs/release-notes-v2.0.md).

The audit report itself is **not** kept in the tree, so a later audit cannot mistake a finished one
for a current one; it is archived by permalink instead:
<https://github.com/Pummelchen/YTLive_Laundry/blob/d603fdcf92dff17bfb7aa770562b04b84e37e71d/AUDIT/2026-09-16-full-audit.md>

**Two defects could kill a healthy publisher, and both are fixed.** `bin/yt_monitor.sh` treated
the `NOGOLDEN`, `NOCONFIG` and `ERROR` statuses as a bad picture and `pkill`ed the publisher every
`FAIL_SECONDS`, forever; and `conf/golden.jpg` could never be bootstrapped, because zsh's `-nt` is
false against a missing file and `golden.jpg` is gitignored — so a fresh install hit that loop
permanently. Both are now regression-guarded.

**The OAuth credential is checked by probing, not by a countdown.** `bin/yt_api.py token` mints a
real access token and reports `LIVE`/`DEAD`/`UNKNOWN`; the 7-day countdown is advisory only, and
`YT_TOKEN_TTL_DAYS=0` silences it once the OAuth app is published. This matters because the
7-day expiry is a "Testing" publishing-status behaviour, and publishing the app removes it without
any Google verification.

**A rotation with no usable API now stays live instead of going dark.** `prepare_broadcast()`
creates and binds the next broadcast on every cut, so an unusable credential used to mean a dark
channel at the next rotation. `rotate_broadcast()` now refuses to cut (`ROTATE_WITHOUT_API="no"`),
trading one unarchived segment for a channel that keeps streaming and recovers by itself.

Also: `save_creds()` writes the OAuth token 0600 from the first byte; `bin/smoke_test.sh` no
longer passes on `{"status":"ERROR"}`; `bin/cam_reboot.py` no longer reboots the camera on import;
`bin/shuffle_playlist.sh` fails loudly instead of writing a too-short playlist; `cam_ip_watcher`
updates the in-memory `CAM_URL` after a DHCP move; `install.sh` can install a fresh clone, checks
`YT_KEY` correctly, `chmod 600`s the token, uses a private `mktemp -d` for its Full Disk Access
probe, and can verify the ffmpeg/ffprobe digests; `housekeep` and `status.sh` warn about free
disk; and 40+ documentation claims that contradicted the code were corrected.

Added `tests/`: a credential-free harness of 84 checks that needs no camera, network, credentials
or ffmpeg, and shadows `pkill` with a recorder so a mis-scoped test cannot signal the live
publisher.

## 1.0 — 2026-09-16

The code that was live in production on the streamer when the audit began. There are no changes
in it — it is the baseline. Notes: [`docs/release-notes-v1.0.md`](docs/release-notes-v1.0.md).

Published so a rollback is a download rather than a dig through history. **It contains every
defect the audit found**, including both publisher-killing bugs above; the notes name them.
