# Handover — the 2026-09-18 outage and where the work stands

**Written 2026-09-19 11:39 WIB (04:39Z). Delete this file once the incident is closed** — the
durable record is `CHANGELOG.md`, `docs/release-notes-vX.Y.md` and the wiki Project-Tracker, and a
stale handover is worse than none (the same reason `AUDIT/` is not kept in the tree).

Everything below is verified against the repository, the watchdog host and the public channel. Where
something is a hypothesis it says so.

---

## 1. TL;DR for whoever picks this up

1. **The stream is dark because the streamer is down, and only physical access fixes it.** It has
   been offline since **2026-09-18T10:19:54Z** — 18 h at the time of writing.
2. **Everything else is done**: the external watchdog is deployed and has emailed twice, two
   releases are published, the docs and tracker are current, `main` and the wiki are pushed.
3. **The next human action is:** drive to the shop, open the MacBook lid / press a key, then
   `bin/forensics.sh --save` **before** rebooting if it responds, then
   `sudo bin/harden-host.sh --go`. Full procedure in §4.
4. **Resume the engineering work at §6 and §9.** The blocker is physical, nothing else.

Repo state at handover: `main` = **4421ee8** (clean, = `origin/main`), wiki = **f74f76f** (clean),
tags `v1.0`–`v2.3`, latest release **v2.3**, test suite **218 checks, `SUITE PASSED`**.

---

## 2. The incident

| Fact | Value |
|---|---|
| Last broadcast | `3Cnxr6fTrWk` — ingest stopped **2026-09-18T10:19:54Z** (17:19:54 WIB) |
| Segment length | **5 h 14 m** into an 8 h 03 m segment → an abrupt stop, *not* a rotation |
| Streamer's Tailscale last contact | **2026-09-18T10:20:00Z** — the same second |
| The four segments before | 8.05 h each, gaps 4.5–5.2 min — the automation was healthy |
| Streamer now | `100.75.83.5` offline 18 h; ping 100 % loss; SSH:22 times out |
| Channel now | not live (`@ternaklaundrybengkong`) |
| Shop uplink | **up** — the shop's public egress IP `103.21.207.12` answered ICMP 10/10 at ~5 ms |

Unreachability was confirmed from three independent vantage points: this MacBook (`macbook-ab`),
`node1`, and Tailscale's own DERP relay state (`Online:false`, `rx 0`).

### Leading cause (hypothesis, NOT confirmed)

The one sentence to remember:

> The MacBook's lid is **always shut** and it streamed that way for days. What kept it awake was
> `stream.sh`'s `caffeinate -ism` — but `caffeinate -s`'s system-sleep assertion is valid **only on
> AC power**, and lid-close (clamshell) sleep is a *separate* assertion that none of those flags
> touch. So a **momentary** mains interruption is enough: on battery with the lid shut the Mac
> sleeps at once. Nothing wakes a closed-lid Mac — wake-on-LAN is LAN-only, and `autorestart` has
> nothing to do with waking a machine that is merely asleep. It stays dark until a human opens it.

This fits **every** observation, including the owner's two corrections: the shop stayed open with
power and wifi up, and the lid is always closed. Alternative candidates, still live: a hang
(load/swap), a panic or forced power-off, or a reboot to a **login window** — where the two agents
would never start, because they are *user* LaunchAgents. `pmset -g log` on the machine is what
settles it.

### What it is NOT

- **Not a script logic failure.** Four consecutive 8.05 h segments with 4.5–5.2 min gaps prove the
  rotation, the API bind-before-ingest order and the monitor were all working to the last second.
- **Not the ISP or the shop's power grid.** The uplink answered ICMP throughout.
- **Not the watchdog's fault** — it did not exist until this outage.
- **The retry-only design could not have caught it.** A process that is not running cannot retry,
  and launchd cannot revive a machine that is off or asleep.

---

## 3. What is already done (all verified)

### The external watchdog — deployed and armed

`bin/yt_watchdog.py` runs **off** the streamer on the Intel VPS (`deltasona`, Tailscale
`vpn-germany`, `91.99.176.243`), as systemd unit **`ytlive-watchdog`**:
`enabled` + `active`, boot symlink present, `Restart=always`.

- Paths: program `/var/ytlive-watchdog/bin/yt_watchdog.py`, config
  `/var/ytlive-watchdog/conf/watchdog.env` (mode 600, holds a Gmail app password), state
  `state.json`, log `watchdog.log`, spool `spool.jsonl`.
- It watches **two independent signals**: the channel via `yt-dlp` (same `live`/`offline`/`unknown`
  split as `bin/yt_check.py`, so a rate limit cannot page anyone) and the streamer's Tailscale
  presence.
- **Proven end to end**: a transport test was delivered, and the real
  `[YTLive] channel DARK for 15m04s` alert was emailed at 21:15:47Z. `channel=offline`,
  `host=down`, `last seen 2026-09-18T10:20:00Z`.
- The Gmail app password was taken from `~/.gmail-app-password` (mode 600) on **node1**, where it
  already existed. Gmail **rejects unauthenticated direct-to-MX** (`550 5.7.26`), so submission with
  an app password is the only working path.

### Host tools

- **`bin/forensics.sh`** — read-only evidence for a host-level outage: identity/uptime, console user
  (the login-window test), `pmset` settings, real sleep/wake history, memory and swap, disk, panic
  reports, the tails of all four project logs, and the camera/Tailscale state. `--save`, `--deep`.
- **`bin/harden-host.sh`** — applies **and verifies** `pmset -a autorestart 1` and
  `pmset -c sleep 0 disablesleep 1`. Dry run by default, `--go` applies, `--check` verifies only.
- **`bin/watchdog-install.sh`** — POSIX `sh` installer for the watchdog on Linux/macOS, with
  `--dry-run`.

### Releases, docs, tracker

- **v2.2** (the external watchdog) and **v2.3** (host forensics + the verified hardening) are
  published, marked Latest, with `.sha256` assets — independently re-downloaded and verified.
- Documentation drift fixed: the test count (documented as 84 in eight places), `RELEASE.md` and
  `AGENTS.md` stopping at v2.0, `bin/deploy-release.sh` missing from the inventory, and
  `docs/release-notes-v2.1.md` claiming production ran 1.0.
- Wiki: new **External-Watchdog** page, the incident recorded, **T-29** (pmset hardening, BLOCKED),
  **T-30** (UPS, BLOCKED), **T-31** (watchdog redundancy, OPEN), **T-32** (v3.0 datacenter, OPEN),
  and the *"channel is dark and the streamer is unreachable"* page corrected to the mechanism above.
- `docs/v3-datacenter-plan.md` — the agreed v3.0 proposal (push-based SRT, Hetzner **Singapore**,
  camera never exposed). Linked from T-32. Not scheduled.

---

## 4. The recovery procedure (ordered — do not reorder steps 1–3)

1. **Look before you touch.** Screen off and it wakes on a keypress or on opening the lid → it was
   **asleep**; opening it *is* the fix and `KeepAlive` restarts the stream. Open but clearly hung →
   hold power ~10 s. Nothing at all → press power.
2. **If it responds at all, capture the evidence BEFORE rebooting** — a reboot destroys the
   in-memory half:

   ```bash
   cd ~/Downloads/YTLive && git pull
   bin/forensics.sh --save          # read-only; writes log/forensics-<stamp>.txt
   ```

   What you are looking for in `pmset -g log`: a **battery/AC transition plus a `Sleep`** at
   17:19:56 WIB. That confirms the hypothesis. A `.panic`, a shutdown cause of `-128`/`0`, or a
   short uptime with no console user point elsewhere (see the forensics output's own legend).
3. **Then close the class permanently:**

   ```bash
   sudo bin/harden-host.sh --go     # applies, then verifies
   bin/harden-host.sh --check       # must PASS
   ```

4. **Check the charger and cable** while on site. `disablesleep` fixes sleep; it cannot fix a dead
   adapter or a battery that has died.
5. **Confirm the stream came back**: `bin/status.sh` (both jobs, frame counter, heartbeat, token,
   YouTube, camera, disk, rotation history). The watchdog should send
   `[YTLive] channel is LIVE again` by itself — no action needed.
6. **Deploy the release** if the streamer is not already on 2.3: read the wiki
   `Updating-and-Rollback` first, then `bin/deploy-release.sh --tag v2.3` (dry run by default).
   `bin/status.sh` and `bin/smoke_test.sh` come first, always.

---

## 5. After recovery — close the loop

- Confirm the **cause** from the captured forensics and write it into `CHANGELOG.md`, the release
  notes of the next release, and the wiki Project-Tracker incident row (replace "leading cause" with
  what the log showed).
- **Close T-29** only when `bin/harden-host.sh --check` passes on the streamer.
- **Delete this handover file** and note its removal in the commit message.
- If the machine was actually **not** asleep, treat the hypothesis as falsified and reopen the
  investigation — the forensics script exists precisely so that this is decided by data.

---

## 6. Open questions and unknowns

1. **macOS version conflict — unresolved, and it matters.** `docs/machines.md` says the streamer is
   `Intel, macOS 12`, and the wiki's T-24 refers to *"the 2015 dual-core i5-5250U"*. The owner says
   **macOS 15**, which cannot run on 2015 Intel hardware. Both cannot be true. Needed from the
   machine: `sw_vers; sysctl -n hw.model; python3 -V; /opt/homebrew/bin/python3 -V`. This affects
   T-24's CPU budget and the v3.0 sizing assumptions.
2. **The cause of the outage is not confirmed** — see §2. Only the machine's own logs can decide.
3. **The installer's macOS path has never run on a real Mac.** It is covered by tests against a
   sandbox and fake interpreters (`tests/t07_watchdog.sh`), and the Linux path was run for real on
   the VPS, but `bin/watchdog-install.sh` on macOS (launchd) is untested in production. The watchdog
   currently runs on Linux only.
4. **The watchdog is a single point of failure for its own alerts** (T-31). If `vpn-germany` dies or
   its mail path breaks silently, the 2026-09-18 blind spot returns. A second host, or a dead-man
   check, is the fix; not built.
5. **`bin/forensics.sh` has never been run against a real host-level outage** — only against stubbed
   `pmset` output and a healthy Mac.

---

## 7. Traps discovered in this session (do not re-learn these)

Each of these cost real time and is now regression-guarded:

- **A quoted `"\(...\)"` in a zsh `case` pattern keeps its backslashes**, so the `yt-dlp` test stub
  had **never matched anything** and fell through to an empty `exit 0`. No earlier test had
  exercised its stdout.
- **Tailscale reports `LastSeen` as an RFC3339 string**, not an epoch. `once` was fine; `status`
  crashed on the real host.
- **`x or now` treats the legitimate timestamp `0` as unset** (in `decide()`).
- **A systemd unit without `[Install]` is `static`** — `systemctl enable` creates no boot symlink
  and the service silently does not survive a reboot (exactly what the watchdog exists to report).
- **`pmset` reports `SleepDisabled` and `autorestart` only when they are enabled**, so an absent key
  means *off*, not *unknown*. Verification must treat absence as failure.
- **launchd gives a job `PATH=/usr/bin:/bin:/usr/sbin:/sbin`** (`launchctl getenv PATH` is unset)
  and `yt-dlp` lives in `~/.local/bin` — a launchd-installed watchdog would report `UNKNOWN`
  forever, indistinguishable from a dark channel.
- **Debian has no zsh.** A `#!/bin/zsh` installer dies with `cannot execute: required file not
  found` (exit 127) on the host it was written for.
- **`sed > "$FILE"` truncates the destination before `sed` runs.** A missing template zeroed the
  live systemd unit and systemd reported it as **masked**; render to a temp file and `mv` instead.
- **Gmail requires SPF or DKIM** and a valid `Message-ID`; unauthenticated direct-to-MX is refused.
- **The credential-free suite count is quoted in several docs** (README, `AGENTS.md`, `RELEASE.md`)
  and drifts every time a test is added. It is **218** now; update all of them together.
- **`release.sh` refuses a tag that is not already on the remote**, and needs
  `docs/release-notes-vX.Y.md` to carry `SHA256_PENDING`.
- **Only ONE machine may push to a given YouTube stream key at a time** (`docs/machines.md`). Any
  migration must never have two publishers.

---

## 8. Environment an arriving agent needs

- **Streamer**: `ternak-macbook`, `user@100.75.83.5` (Tailscale), project at `~/Downloads/YTLive`
  (TCC/FDA requires that exact path). The account password was supplied in session; it is **not** in
  this repository.
- **Watchdog host**: Intel VPS `deltasona`, `root@91.99.176.243`, tailnet name `vpn-germany`.
  Nothing else in `/var` was touched; `/var/ytlive-watchdog` is this project's space.
- **Nodes**: `node1`–`node5` (Mac minis, `nodeN@nodeN`); `node1` holds
  `~/.gmail-app-password` (mode 600) and can reach the streamer.
- **No secrets are in the repository, and none were committed.** The stream key lives in the
  gitignored `conf/stream.env`, the OAuth refresh token in `conf/yt_oauth.json`, the watchdog's mail
  password in the gitignored `conf/watchdog.env` (live copies only on their hosts).

---

## 9. Suggested next tasks, in order

**Read [`docs/task-table-standard.md`](task-table-standard.md) first.** The project now has exactly
ONE task table — the wiki Project Tracker, under `## Tasks` — whose columns are fixed and whose row
order *is* the priority. See §10.1: the tracker page has not been migrated to that standard yet.

1. Restore the stream (§4) — blocked on physical access, nothing else.
2. Confirm the cause and close T-29; correct the macOS/CPU facts in the docs (§6.1).
3. Cut **2.4** with the installer fixes now on `main` (POSIX sh, newest interpreter, job `PATH`,
   no-truncate unit render) — they are committed but unreleased.
4. T-31: give the notification path redundancy.
5. T-32: the v3.0 datacenter move, per `docs/v3-datacenter-plan.md`, once the incident is closed.

---

## 10. Two documentation inconsistencies, deliberately left alone

1. **The wiki Project-Tracker does not match `docs/task-table-standard.md` yet.** The page still has
   `## Needs the owner` and `## Open — code` sections with `ID | Pri | Task | Why it matters |
   Status`, whereas the standard requires one table under `## Tasks` with
   `ID | Task | Type | Area | Size | Status | Owner | Next step`, and no legends on the page. It was
   left alone rather than rewritten here for two reasons: the owner was actively editing this exact
   area while this handover was being written (the standard and the AGENTS.md pointer landed
   mid-session), and `Type`/`Area`/`Size`/`Owner` are judgements the owner should make rather than
   have an agent infer.
   **Do not renumber the IDs.** `T-01`…`T-32` are already a stable prefix plus a zero-padded number;
   the standard's `TT-001` is an example, not a mandate. Renumbering would break the references in
   `docs/known-issues.md` and in the wiki, against the standard's own rule 2.
2. **`docs/release-notes-v2.2.md` and the 2.2 CHANGELOG entry quote "168 checks"**, which was true
   at `v2.2`; the tree now has **218**. Those are historical release records and are correct as
   written — the current-tree documents (`README.md`, `AGENTS.md`, `RELEASE.md`) carry 218. Do not
   "correct" the historical numbers.
