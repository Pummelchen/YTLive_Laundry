# YTLive_Laundry 2.4 — the transport layer, and the corrected record

2.4 does two things. It **corrects the record** of the 2026-09-18 outage — the cause written into
the 2.2/2.3 notes, the handover and the wiki was wrong, and the host's own records falsify it — and
it adds the part of the design that never existed: a **transport layer under the retries**. The
incident is closed (the channel went live again on 2026-09-19), and the corrected timeline plus the
missing layer are what the investigation left behind. Full detail is in
[`CHANGELOG.md`](../CHANGELOG.md).

- Built from tag `v2.4`
- Contents: the tagged tree **without `MP3/`**, without `backup/` and without any audit report. The
  25-track, 328 MB music library is byte-identical in git at the same tag (`git checkout v2.4 -- MP3`).
- Source archive, not a build product: nothing to compile, no binaries, nothing to sign.

## Why this release exists

The 2026-09-18 outage was recorded for a day as a power/sleep failure: a momentary mains
interruption while the lid was shut, after which the Mac slept on battery and never came back. On
2026-09-19 the machine's own records were read and they contradict that cause completely. The host
was **awake and logging the whole time** and had lost its **network**: DNS and its own LAN, not its
power. That matters beyond bookkeeping, because the recorded cause pointed at `pmset` hardening,
and no `pmset` setting touches a transport failure. The corrected record points at a real hole in
the design, and 2.4 fills it.

The channel is live again, so this ships with the incident closed rather than open. The streamer is
running an older release and the wired adapter is still unusable, so the deploy section below is
the operational half of the release.

## The corrected record (what 2.2 and 2.3 got wrong)

The two prior releases, the live handover and the wiki all recorded the leading cause as *a
momentary mains interruption while the lid was shut, after which the Mac slept on battery*. The
host's own records falsify that:

- **It never rebooted.** `kern.boottime` is Mon Aug 31 01:55:19 2026 and uptime at the time of
  measurement was 19 days 17 hours. A panic, a forced power-off and a reboot to a login window are
  all excluded, and the console user was `user`, so both LaunchAgents were loaded.
- **It never slept, and never ran on battery.** Across a `pmset -g log` window covering
  2026-09-12 → 09-19 there are **zero** `Entering Sleep`/`Wake from` lines and **zero** AC/battery
  transition lines. The sleep/wake section of `bin/forensics.sh` is empty for the last two days for
  the same reason.
- **It was awake and logging throughout.** `log/stream.log` holds 640–760 lines per hour through
  08:00–12:00 WIB on 09-19, while the host was still absent from the tailnet.

What the log actually says is a **transport failure**:
`PREPARE: network error talking to YouTube: <urlopen error [Errno 8] nodename nor servname
provided, or not known>` (a DNS resolution failure) and `CAM-WATCH: 192.168.1.3 not answering on
554` followed by `no ONVIF camera found on the LAN` (the *local* link). The Mac had lost DNS **and
its own LAN** while it kept running and retrying. The shop's uplink was never the problem.

Timeline as measured: ingest stopped **2026-09-18T10:19:54Z**, 5h14m into an 8h03m segment; the
network returned on 09-19 around 05:00Z; the first successor broadcast created after the outage
went live at **05:46:12Z** (`D9kF4Rf9uPU`); the current stable broadcast `ycAbb2G_Q2U` went live at
**08:06:55Z**. **Dark for ~19h26m**, not the 10h23m the earlier documents recorded.

Two further facts from the same investigation:

- **The external watchdog performed correctly and was still nearly useless at the end**, because
  `yt-dlp` returns `unknown` under a rate limit: it raised two `blind` alerts and its "channel is
  LIVE again" mail arrived **5h21m after** the channel had actually recovered. Its own `DARK for
  11h05m` reminder went out 57 seconds *before* the recovery.
- **The streamer's name resolution depended on a single nameserver inside the shop router**
  (`192.168.1.1`, A-records only). The reference Mac in this project carries four IPv4 and four
  IPv6 public resolvers from two independent providers on every service. That asymmetry is now
  removed on the streamer.

## What is new

**`bin/net_watch.sh` (new) — the missing bottom of "every failure path retries".**

Every retry in `stream.sh` retried the *application* layer (ffmpeg, ONVIF discovery, the OAuth
probe) and not one of them ever touched the network interface, which is why the 19h26m outage was
outside the reach of all of them. The new watchdog probes once every `NET_CHECK_EVERY` (30s) and
classifies the transport as exactly one of `OK / NOLINK / NOGW / NOWAN / NODNS`:

```
bin/net_watch.sh status   # one screen: state, route, resolvers, wired vs wifi, intent vs reality
bin/net_watch.sh once     # probe once; prints the state; exit 0 iff OK
bin/net_watch.sh loop     # the loop; stream.sh starts this
```

`NOLINK` is the trap worth naming: an interface that reports `status: active` but holds only a
`169.254` self-assigned address is linked-but-unusable, and that is exactly the state the wired port
was found in. Only after `NET_FAIL_SAMPLES` (3) **consecutive** failures, so a 60s router reboot
cannot trigger a repair, and inside a rate limit (`NET_MIN_ACTION_INTERVAL` 300s,
`NET_MAX_ACTIONS_PER_HOUR` 12), it climbs a ladder: re-assert DNS → re-assert DHCP → power-cycle the
wireless radio. The decision is a pure function of
`(state, failures, seconds since last action, actions this outage, actions this hour)`, so a
15-minute rule is tested in microseconds, exactly like `yt_watchdog.py`.

**Two things it must never do, both learned the hard way.** It never **power-cycles a network
service**: toggling the USB-Ethernet service on 2026-09-19 killed that adapter's carrier and it did
not come back, so the wired NIC is only ever asked to re-assert DHCP. And it never **reorders the
service list**: a secondary interface with no router gets no default route, so macOS already
prefers the working one, and one mistyped `-ordernetworkservices` is a broken only path. Wired stays
first, so it becomes primary by itself the moment it holds a real lease. The intent is stated
explicitly: **LAN primary, Wi-Fi backup**.

**Repair, not notification.** The streamer's rule is that nothing there may depend on a human
noticing; the off-host watchdog is the only component allowed to notify. `net_watch.sh` repairs and
leaves evidence. Every state transition and every action lands in `log/net_events.log`, which
records transitions rather than every probe, so a 20-hour outage leaves a readable timeline even
though `stream.log`'s in-place trim would not.

**`LOG_MAX_BYTES_STREAM` (2 MB) — a second, larger trim budget for `stream.log`.** The old 512 KB
cap keeps only its last half, which at the measured ~700 lines/hour of an outage storm retained
about four hours, so the trim erased the **first** hours of this one. That is why the earliest part
of the incident cannot be read from the log at all. The append-only `net_events.log` is the durable
record; the larger cap only widens the net around it. `trim_log` grew a second argument for the
cap, and `stream.log` is now trimmed separately from the shared budget.

**`bin/status.sh` gained a network transport section.** It prints the classifier's state, the
default route and the service carrying it, the resolvers, the wired and Wi-Fi interfaces, and the
machine-readable `intent_iface` line. It warns when the traffic-carrying interface is not the
intended primary, which is the honest signal that the wired path is down.

**`bin/forensics.sh` gained a Network section**, the section that would have answered this incident
from the machine instead of from a day of inference: interfaces and whether one is `active` with
only a `169.254` self-assigned address, service order, default route, routing table, resolvers with
their flags and `if_index` (so a supplemental Tailscale resolver can be told from the default one),
`/etc/resolver`, Wi-Fi SSID and **signal/noise**, DHCP leases, ARP (which interface resolved the
gateway and the camera) and Tailscale presence. It is read-only and unprivileged, and calls that can
block are given a hard ceiling so a wedged daemon cannot hang the report.

**A `zsh` bug in `forensics.sh`.** The panic-report lines used a bare `*.panic` glob. zsh treats an
unmatched glob as a hard error printed *before* any redirection can suppress it, so on a healthy
host the report carried error text into the evidence. It is now null-globbed with `(N)`.

**`bin/yt_watchdog.py` no longer depends on `yt-dlp` alone.** A second, independent channel read
fetches the channel's `/live` page over plain HTTPS with `urllib` (no yt-dlp, no cookies, no API
key) and combines with the `yt-dlp` read: either reader saying `live` is live, both saying `offline`
is offline, anything else is `unknown`. `UNKNOWN` still never pages anyone. The reader trusts the
page's own `isLiveNow` flag; a page without that marker (a consent wall, a bot check, a markup
change) is `unknown`, never `offline`, so a YouTube markup change degrades the second reader rather
than lying with it. `WATCH_HTTP=0` falls back to the yt-dlp reader alone.

**A dead-man heartbeat** (`WATCH_HEARTBEAT`, `WATCH_HEARTBEAT_MAX` 900s) that reports a streamer
whose application has gone silent even when the channel read is `unknown`. A stale heartbeat is
positive evidence about the app; a fresh one adds nothing; an **absent** file is treated as an
unconfigured deployment and never pages. **Delivery is deliberately not implemented:** the two
options are a small authenticated push endpoint on the watchdog host or a restricted SSH pull with
a forced `touch`, and choosing between them is a security decision, not a coding one. The shipped
default is empty.

**Tests.** `tests/t09_net.sh` is new with **42 checks** driving the classifier through stubs (so
the suite still needs no network and cannot touch a real interface), the whole action ladder, the
rate limits, the operator hold, and the safety property that no action may power-cycle a service or
disable the radio. `tests/t07_watchdog.sh` grew **76 → 120** (heartbeat rules and the second channel
reader) and `tests/t08_hosttools.sh` grew with the new forensics network section. `t_extract_fn` in
`tests/lib.sh` now also handles single-line function definitions; it previously read past them to
the next function's closing brace, so a test could exercise the wrong text and still pass.

## Also on the streamer (configuration, not code)

- Redundant public resolvers (`8.8.8.8 8.8.4.4 1.1.1.1 1.0.0.1`) are set on the streamer's services,
  so resolution no longer depends on the router or on which service macOS considers primary.
- The streamer was running **2.1**. Its wired interface was found `active` at 100baseTX with a
  `169.254` self-assigned address and no route to the router, while being **first** in the service
  order: a linked-but-unusable primary. It has **no carrier at all now** and needs a **site visit**.
  The adapter is a cheap WCH `1a86:5394` USB part whose link did not survive a service toggle on
  2026-09-19. Replace it with a better adapter, or leave it disabled and stay on Wi-Fi.
- `NET_ALLOW_REBOOT` is **off by default**. A reboot fixes a wedged Mac-side driver; it cannot fix a
  router that is off, and if auto-login were ever disabled the machine would come back to a login
  window and stay dark. It is only safe here because auto-login is configured
  (`autoLoginUser=user`, FileVault off), so it is opt-in and unproven.

## Files in this release

| File | Change |
|---|---|
| `bin/net_watch.sh` | **new** — transport watchdog: `OK/NOLINK/NOGW/NOWAN/NODNS` classifier, pure `net_action` decision, `dns → renew → wifi` ladder, rate limits, `log/net_hold` operator hold, append-only `log/net_events.log` |
| `bin/stream.sh` | starts `net_watch.sh loop` alongside the reader and reaps it on shutdown; `LOG_MAX_BYTES_STREAM` (2 MB) and a second `trim_log` cap argument |
| `bin/status.sh` | new `=== network transport ===` section; warns when traffic is not on the intended primary |
| `bin/forensics.sh` | new Network section (interfaces, service order, route, resolvers, Wi-Fi signal/noise, DHCP, ARP, Tailscale); bare `*.panic` glob null-globbed |
| `bin/yt_watchdog.py` | second channel reader over plain HTTPS (`WATCH_HTTP`), combined `live`/`offline`/`unknown` rule; dead-man heartbeat (`WATCH_HEARTBEAT`, `WATCH_HEARTBEAT_MAX`) |
| `conf/stream.env.example` | `NET_*` knobs incl. `NET_ALLOW_REBOOT="no"`, and `LOG_MAX_BYTES_STREAM="2097152"` |
| `conf/watchdog.env.example` | `WATCH_HTTP`, `WATCH_HTTP_TIMEOUT`, `WATCH_HTTP_URL`, `WATCH_HEARTBEAT`, `WATCH_HEARTBEAT_MAX`, with the delivery limit stated |
| `tests/t09_net.sh` | **new** — 42 checks, stubbed, no network |
| `tests/lib.sh` | `t_extract_fn` handles single-line function definitions |
| `tests/t07_watchdog.sh` | 76 → 120 checks: heartbeat rules and the direct HTTP reader |
| `tests/t08_hosttools.sh` | 27 → 46 checks: the forensics network section, the glob fix, and a missing-tools run |
| `docs/operations.md` | "When the network dies (`bin/net_watch.sh`)" and "LAN primary, Wi-Fi backup" |
| `docs/files.md` | `bin/net_watch.sh`, `log/net_events.log`, `log/net_state`, `log/net_hold`, `log/forensics-<stamp>.txt` |
| `AGENTS.md` | `net_watch.sh` in the tool list; the corrected cause of 2026-09-18 and the application-layer retry gap as load-bearing rules |

## Verification

Measured on 2026-09-19 from the working tree with `zsh tests/run.sh` (serial, all files) and then
per file. The runner prints a per-file count, not a grand total; the total below is the sum of the
per-file counts.

| Test file | Checks | Result |
|---|---|---|
| `tests/t01_syntax.sh` | 46 | all passed |
| `tests/t02_monitor_classify.sh` | 12 | all passed |
| `tests/t03_files.sh` | 11 | all passed |
| `tests/t04_token.sh` | 13 | all passed |
| `tests/t05_rotation_gate.sh` | 15 | all passed |
| `tests/t06_install.sh` | 21 | all passed |
| `tests/t07_watchdog.sh` | 120 | all passed |
| `tests/t08_hosttools.sh` | 46 | all passed |
| `tests/t09_net.sh` | 42 | all passed |
| **Total** | **326** | **`SUITE PASSED`** |

- The project's own suite, serially: **checked** — 326 checks, all passing.
- `tests/t09_net.sh` (new): **checked** — 42 checks. The classifier, the ladder, the rate limits, the
  hold and the resolver policy are exercised through stubs in the scratch tree, so the file opens no
  socket and cannot touch a real interface. The two safety properties are regression-guarded: no
  action may power-cycle a service, and the default `NET_ALLOW_REBOOT=no` may not become a reboot.
- `tests/t07_watchdog.sh`: **checked** — 120 checks, credential-free and network-free; the heartbeat
  and combination rules are a pure function of time and inputs.
- `tests/t08_hosttools.sh`: **checked** — 46 checks. Another agent was still editing this file at the
  time of measurement; the run reported 46/46 both in the full suite and per file.
- The release gates (`release.sh`): syntax (`zsh -n` per shell file, `ast.parse` per Python module),
  the suite from the archive, and the per-file byte-match against the tag: **checked at publish
  time**, the same mechanical gates 2.2 and 2.3 used.
- `bin/smoke_test.sh`: **not checked** — it needs `conf/yt_oauth.json`, which is gitignored and in no
  archive, so it cannot pass inside a release. It is not a release gate.
- `bin/net_watch.sh` against a real transport outage on the streamer: **not checked** — there is no
  real outage to collect on, and the actions it would take are deliberately the ones that are hard
  to stage. The classifier and the ladder are exercised against stubs only.
- The dead-man heartbeat end to end: **not checked** — the watchdog side is finished and tested, but
  no delivery mechanism from the streamer to the watchdog host exists, so the shipped default is
  `WATCH_HEARTBEAT=""` and the signal is disabled.
- The reboot rung: **not checked** — `NET_ALLOW_REBOOT` is off by default and has not been proven on
  the streamer.
- The wired path: **not checked** — the USB adapter has no carrier and needs a site visit. Until
  then traffic is on Wi-Fi and `bin/status.sh` warns about it.

## Deploying this

The channel is live again, so this is a normal deploy: `bin/status.sh` and `bin/smoke_test.sh` on the
streamer first, then `bin/deploy-release.sh --tag v2.4`. Read
[Updating and rollback](https://github.com/Pummelchen/YTLive_Laundry/wiki/Updating-and-Rollback)
first. The streamer was on 2.1 and still needs `bin/harden-host.sh --go` (autorestart is still off)
and a decision on the wired adapter — replace it or leave it disabled and stay on Wi-Fi. It is worth
checking `log/net_events.log` and `bin/net_watch.sh status` after the first restart, because the
intent-versus-reality warning will still be firing while the wired link is dead.

```
SHA256  SHA256_PENDING
BYTES   ARCHIVE_BYTES_PENDING
```
