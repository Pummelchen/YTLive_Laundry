# Changelog

The scheme is two-component `MAJOR.MINOR`, released as the tags `v1.0`, `v2.0`, `v2.1`, `v2.2` and
`v2.3`. The
authoritative version is the `VERSION` file at the repository root; a release refuses to build
when `VERSION` and the tag disagree. There is no version literal in any script: the streamer's
tunables live in `conf/stream.env`.

Each release is a source archive of the tagged tree with a SHA-256 beside it. There is nothing
to compile. See `release.sh` and [`RELEASE.md`](RELEASE.md).

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
