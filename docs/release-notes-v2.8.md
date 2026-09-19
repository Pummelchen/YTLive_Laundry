# YTLive_Laundry 2.8 — the year-1 the health page printed, the hardware limit that looked like a fault, the ladder that could not renew a lease, and YouTube's own verdict nobody read

2.8 is a small release about **honesty on the page a human reads during an incident**. Four
things were wrong in the same direction: a status line that described a healthy streamer as last
seen in the year 1, a hardening check that failed forever on a setting this Mac cannot have, a
transport ladder whose two root-only rungs were unreachable so a wedged DHCP lease needed a
person, and YouTube's own ingest verdict — which nothing here read. Full detail is in
[`CHANGELOG.md`](../CHANGELOG.md).

- Built from tag `v2.8`
- Contents: the tagged tree **without `MP3/`**, without `backup/` and without `AUDIT/`. The
  music library is byte-identical in git at the same tag (`git checkout v2.8 -- MP3`), which is
  why it is excluded rather than shipped. No credentials or runtime state are in any archive:
  `conf/stream.env`, `conf/yt_oauth.json`, `conf/watchdog.env`, `conf/heartbeat.token` and `log/`
  are gitignored and were never committed.
- Source archive, not a build product: nothing to compile, no binaries, nothing to sign.

## The host line said the streamer was last seen in the year 1

Tailscale reports Go's zero time (`0001-01-01T00:00:00Z`) for a peer that is **online**. Verified
across the whole tailnet on 2026-09-19: the streamer, Node1-4 and MacBook AB all carry it while
online, while genuinely offline peers carry a real timestamp. The watchdog formatted that value,
so its one-line host summary — the page an operator reads when something is wrong — said:

    host state     : live  last seen 1-01-01T00:00:00Z (1-01-01 07:00 WIB)

**Online is not a date.** The line now reads `host state : live  online now`, and an offline peer
keeps its real last-seen date, because that is the case where the date carries information. The
limit is that this is Tailscale's own field: a peer that is online but unreachable at the
application layer still reads `online now` — which is exactly why the channel and heartbeat
signals exist beside it.

**Why the suite missed it.** `tests/stubs/tailscale` invented a plausible timestamp
(`2026-09-19T00:00:00Z`) for the online case. A stub that is nicer than reality cannot produce the
bug reality produces; it now returns the zero time, and `t07` pins both directions.

## T-29 — "not supported by this hardware" is not "off"

macOS reports `autorestart` only when it is **on**, so a read-only check cannot tell a supported
key that is off from one this Mac cannot have at all. `pmset -g cap` does not settle it either:
measured here, it omits `disablesleep`, which demonstrably works on this host.

Measured 2026-09-19 on the streamer (`MacBookAir7,2`) with root: `pmset -a autorestart 1` exits 0,
prints nothing, and the key never appears — while a control toggle of `womp` (1 → 0 → 1) read back
correctly, proving pmset writes do work here. So the write is accepted and ignored, and
`harden-host.sh --check` was **failing forever on a setting this machine cannot have** — which
trains an operator to ignore the check, the one outcome a hardening check must never cause.

Support is now **probed** where root is available: `--go` applies the setting, reads it back, and
records the verdict in `log/host_hardening.json`. `--check` consumes that record:

    PASS  SleepDisabled = 1 (the Mac will not sleep, lid closed included)
    N/A   autorestart is NOT SUPPORTED by this hardware - a recorded probe shows the write is
          accepted and ignored. A power cut still leaves the Mac off; the UPS (T-30) is the only
          mitigation. This is a hardware limit, not a failed setting.

**What is NOT solved.** `N/A` is not a fix and this release does not pretend otherwise: a power
cut still leaves the Mac off until someone presses the button, and the only real mitigation is a
UPS (T-30 — which the operator has accepted as a risk rather than bought). What changed is that the
tool now states the limit instead of failing at it. An **unprobed** host still FAILS, with the one
command that settles it, because a check that cannot confirm must not report OK.

## T-38 — the transport ladder's root-only rungs

`bin/net_watch.sh` runs as a launchd **USER** agent, so the two rungs that need root were
unreachable: `ipconfig set <iface> DHCP` (a targeted lease renew, stronger than re-asserting DHCP
through `networksetup`) and `dscacheutil -flushcache`. A wedged lease therefore needed a human.

The fix is deliberately **not** to hand the agent the account password: that would put a login
secret in a file that a network-facing process can read, and it would make the watchdog's own
failure modes more dangerous than the ones it repairs. Instead, `conf/ytlive-sudoers` grants
**three exact commands** for the one user:

    user ALL=(root) NOPASSWD: /usr/sbin/ipconfig set en0 DHCP
    user ALL=(root) NOPASSWD: /usr/sbin/ipconfig set en2 DHCP
    user ALL=(root) NOPASSWD: /usr/bin/dscacheutil -flushcache

No wildcards, no shell, no `ALL` — a wildcard in an argument is how "renew DHCP on en0" stops
being narrow. `harden-host.sh` renders the template, proves the result with `visudo -cf` **before**
it can land in `/etc/sudoers.d/` (a malformed file there can make sudo refuse every rule, including
the one needed to remove it), installs it `0440 root:wheel`, and `--check` verifies presence and
parseability — with a louder message for a file that exists but is broken.

In the ladder, the targeted renew is tried first and the no-sudo `networksetup` form is the
fallback, and **which path was taken is logged**: "we tried the weaker thing" is evidence, not
noise. Every call uses `sudo -n`, because a launchd agent has no terminal and a prompt would hang
the loop instead of failing; `tests/t09_net.sh` fails if a call is ever made without `-n`.

**Installed and verified on the live streamer on 2026-09-19**: `sudo -n -l` lists exactly the three
`NOPASSWD` entries above and nothing else.

## T-40 — YouTube's own ingest verdict, with its severities respected

`liveStreams.status.healthStatus` is YouTube's own judgement about the ingest, and nothing in this
project read it — so when YouTube reported `videoIngestionStarved` (`severity: error`, "viewers
will experience buffering") for several minutes after an ingest restart, the local health page said
`OK` throughout. Same class of blindness as the dead-man signal before T-34.

`bin/yt_api.py health` reports it as one JSON line (one `liveStreams.list`, already inside the API
budget) and `bin/status.sh` colours it by severity:

| YouTube says | The page shows |
|---|---|
| no issues | `OK  YouTube reports the ingest healthy` |
| `info`/advisory only | `WARN  … 1 advisory note(s), no error` |
| any `error` | `FAIL  … error-severity ingest issue(s)`, with YouTube's own reason text |
| the answer could not be obtained | `WARN  … could not confirm - not a fault` |

**The audio advisory is deliberate and is not a fault.** This installation sends AAC **384 kbps**
where YouTube recommends 128, because the shop's stream is mostly music and audio quality was
chosen over a quieter health page. The API grades the mismatch `info`, and Studio's own wording for
it is buggy — *"the audio stream's current bitrate of 0 is higher than the recommended bitrate"*.
The page prints YouTube's text verbatim and adds, in as many words, that lowering the bitrate is
not the fix.

**The limit.** This is a snapshot of YouTube's opinion, not a measurement of ours: a transient
`error` right after an ingest restart is reported as `FAIL` until YouTube clears it, which is the
honest reading of a platform verdict but is not the same as our own frame grading. The two live
side by side: the monitor grades the picture, YouTube grades the ingest.

## Files in this release

| File | Change |
|---|---|
| `bin/yt_watchdog.py` | the online/offline host line (zero time is not a date); `host_seen_text()` |
| `bin/harden-host.sh` | `probe_autorestart()` + recorded verdict; `N/A` for unsupported hardware; the sudoers render, `visudo -cf`, install and verify |
| `conf/ytlive-sudoers` | **new** — the three-command `NOPASSWD` template, with the scope argument written down |
| `bin/net_watch.sh` | root-only rungs via `sudo -n` with logged fallback; header and action comments corrected |
| `bin/yt_api.py` | **new verb** `health` (severity-preserving), listed in the usage block |
| `bin/status.sh` | the `ingest health (YouTube's own verdict)` section, and the deliberate-audio note |
| `tests/stubs/tailscale` | the online case now carries Go's zero time — the input that triggers the bug |
| `tests/stubs/sudo` | **new** — a recorder that refuses unless the rule is "installed", and fails loudly on a call without `-n` |
| `tests/stubs/pmset` | **new** `unsupported` mode: a write that is accepted and ignored |
| `tests/t07`, `t08`, `t09`, `t13` | 153 / 66 / 49 / 28 checks respectively |
| `backup/2.7/` | the deployed 2.7 tree, proved against its commit (see below) |
| `VERSION`, `CHANGELOG.md` | 2.7 → **2.8**, with the section above |

## Verification

Measured on 2026-09-19 from the working tree with `zsh tests/run.sh` (serial, all files). The
runner prints a per-file count; the total below is the sum of the per-file counts.

| Test file | Checks | Result |
|---|---|---|
| `tests/t01_syntax.sh` | 56 | all passed |
| `tests/t02_monitor_classify.sh` | 12 | all passed |
| `tests/t03_files.sh` | 22 | all passed |
| `tests/t04_token.sh` | 17 | all passed |
| `tests/t05_rotation_gate.sh` | 15 | all passed |
| `tests/t06_install.sh` | 21 | all passed |
| `tests/t07_watchdog.sh` | 153 | all passed |
| `tests/t08_hosttools.sh` | 66 | all passed |
| `tests/t09_net.sh` | 49 | all passed |
| `tests/t10_camtools.sh` | 63 | all passed |
| `tests/t11_paths_pids.sh` | 38 | all passed |
| `tests/t12_deploy.sh` | 57 | all passed |
| `tests/t13_quota.sh` | 28 | all passed |
| `tests/t14_monitor_beat.sh` | 25 | all passed |
| `tests/t15_resilience.sh` | 23 | all passed |
| `tests/t16_heartbeat.sh` | 54 | all passed |
| **Total** | **699** | **`SUITE PASSED`** |

- The host line: **checked** — `t07` runs the real `status` against a stubbed tailnet whose online
  peer carries the zero time, asserts the line reads `live  online now`, asserts no `1-01-01`
  appears, and asserts an offline peer keeps its real date.
- The `autorestart` probe: **checked** — `t08` covers the three states (unproven → FAIL with the
  command that settles it; recorded unsupported → `N/A` and exit 0; supported → the existing
  FAIL/PASS rules), and drives the extracted `probe_autorestart()` against a pmset stub in both
  "honours the write" and "accepts and ignores" modes, asserting the recorded verdict. **Not
  checked:** the real hardware, which is covered by the live measurement above and the record now
  on the streamer.
- The sudoers rule: **checked** — `t08` asserts a rendered file renders to something `visudo -cf`
  accepts, contains no wildcard, grants per-command rather than `ALL=(ALL)`, passes the check when
  present, fails when missing, and fails **loudly** when malformed. `t09` asserts the ladder prefers
  the root path when the rule is installed, falls back when it is not, never calls `sudo` without
  `-n`, and names the command that installs the rule when both are refused. **Not checked:** the
  install itself (needs root) — done by hand on the live streamer and verified with `sudo -n -l`.
- The health verb: **checked** — `t13` drives `cmd_health()` with a stubbed API for four cases and
  pins GOOD/0, ADVISORY/1, BAD/2 and the error-outranks-advisory rule; `status.sh` is asserted to
  ask for it and to defend the deliberate audio setting. Measured live: `ADVISORY`, one issue,
  `audioBitrateHigh`, `error_count 0`, exit 1 — which is exactly the operator's Studio screenshot.
- `backup/2.7/`: **checked** — 98 files, each one proved with `git hash-object` against
  `git rev-parse 2300091:<path>` (98 compared, 0 mismatched), plus `SHA256SUMS` and a `MANIFEST.md`
  that records what is and is not in it.

## Deploying this

The channel is live, so this is a normal deploy: `bin/status.sh` and `bin/smoke_test.sh` on the
streamer first, then `bin/deploy-release.sh --tag v2.8`. Read
[Updating and rollback](https://github.com/Pummelchen/YTLive_Laundry/wiki/Updating-and-Rollback)
first. There is no config migration: every new tunable has a default.

**This release also touches the watchdog host and the host settings**, so three steps matter:

1. `bin/deploy-release.sh --tag v2.8 --go` on the streamer (the health line, the ladder and the
   host tool).
2. `sudo bin/harden-host.sh --go` on the streamer — it probes `autorestart` once, records the
   verdict, and installs the `NOPASSWD` rule. Then `bin/harden-host.sh --check` must PASS (with
   `N/A` for `autorestart` on this hardware).
3. `bin/watchdog-install.sh --start` on the watchdog host, so the year-1 host line is fixed there
   too — and `bin/yt_watchdog.py status` must print the new version.

```
SHA256  SHA256_PENDING
BYTES   ARCHIVE_BYTES_PENDING
```
