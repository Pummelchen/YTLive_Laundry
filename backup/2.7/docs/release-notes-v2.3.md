# YTLive_Laundry 2.3 — host forensics, and a hardening you can verify

> **CORRECTION 2026-09-19 — the cause recorded in this release note was later FALSIFIED.** It was
> not a mains interruption and the Mac did not sleep: it stayed awake and lost its
> **transport** (DNS and its own LAN), and was dark **~19 h 26 m**, not 10 h 23 m. See
> `CHANGELOG.md` 2.4 and `docs/release-notes-v2.4.md`.

2.2 closed the *notification* half of the 2026-09-18 outage: something outside the streamer now
says when the channel goes dark. 2.3 closes the other two halves — finding out *why* a host died,
and stopping that particular death from happening again. Full detail is in
[`CHANGELOG.md`](../CHANGELOG.md).

- Built from tag `v2.3`
- Contents: the tagged tree **without `MP3/`**, without `backup/` and without any audit report. The
  25-track, 328 MB music library is byte-identical in git at the same tag (`git checkout v2.3 -- MP3`).
- Source archive, not a build product: nothing to compile, no binaries, nothing to sign.

## Why this release exists

The streamer is still down and still needs physical access, so this shipped while the incident is
open — because these two tools are what the recovery itself needs, and because leaving them on
`main` would mean the operator deploys an unpinned working tree instead of a tag.

The mechanism is now understood well enough to fix, and it is **not** the obvious one:

> The MacBook's lid is always shut, and it had streamed that way for days. What kept it awake was
> `stream.sh`'s `caffeinate -ism` — but `caffeinate -s`'s system-sleep assertion is valid **only on
> AC power**, and lid-close (clamshell) sleep is a separate assertion that none of those flags
> touch. So a *momentary* mains interruption is enough: on battery with the lid shut the Mac sleeps
> at once. Nothing wakes a closed-lid Mac — wake-on-LAN is LAN-only, and `autorestart` does not
> apply to a machine that is merely asleep — so it stays dark until a human opens the lid.

That single paragraph explains every observation: the network dropping at the same second ingest
stopped, no ping and no SSH, and the shop's own uplink answering ICMP the entire time.

## What is new

**`bin/harden-host.sh` — the fix, applied and verified.**

```
bin/harden-host.sh                 # dry run: the plan and the current settings
sudo bin/harden-host.sh --go       # apply, then verify
bin/harden-host.sh --check         # verify only; this is what closes T-29
```

It sets `pmset -a autorestart 1` and `pmset -c sleep 0 disablesleep 1`. The important design
point is the verification: `SleepDisabled` and `autorestart` are reported by `pmset` **only when
they are enabled**, so an absent key means *off*, not *unknown* — and `--check` treats it as a
failure. A hardening whose success could not be told apart from its absence would be worse than
none, because T-29 would be closed on a guess. `--go` refuses to run without root.

**`bin/forensics.sh` — the evidence, gathered before it is destroyed.**

```
bin/forensics.sh            # read-only report to stdout (~5 s)
bin/forensics.sh --save     # also write log/forensics-<stamp>.txt
bin/forensics.sh --deep     # add the slow `log show` queries (~30 s)
```

From outside, four failures are indistinguishable — all four are "powered on, wifi fine, Tailscale
offline". This separates them: did it sleep and when (`pmset -g log`), did it hang (load average and
swap), did it panic or lose power (panic reports, previous shutdown cause), or did it reboot to a
login window where the user LaunchAgents never start (short uptime, no console user)? It changes
nothing, deliberately: a reboot destroys the in-memory half, so it is meant to be run first.

**`tests/t08_hosttools.sh` — 27 checks.** Against a `pmset` stub that reports its two keys only
when enabled, which is how macOS really behaves, plus the safety properties that matter for a
script changing how a production Mac behaves with the lid shut: the dry run issues no write at all,
`--check` passes only when both settings are on, half-hardened is still a failure, and `--go`
refuses without root and touches nothing.

## Checks run for this release

| What | Result |
|---|---|
| The project's own suite, serially | **checked** — 199 checks, all passing |
| `tests/t08_hosttools.sh` (new) | **checked** — 27 checks, credential-free, no network, `pmset` stubbed |
| That t08 can actually **fail** | **checked** — with `verify()` mutated to always succeed, t08 fails 2 checks (*"--check fails on an unhardened host"*, *"never-sleep without autorestart is still a failure"*) and passes 27/27 once restored. A guard never seen to fail is not trusted. |
| The dry run changes nothing | **checked** — asserted against the stub's write log, which records every `pmset` write |
| The `pmset` key semantics the verification rests on | **checked** — `SleepDisabled` and `autorestart` are absent from real `pmset -g` and `pmset -g custom` output on macOS 27 unless enabled, so absence means off |
| `bin/harden-host.sh --go` on the real streamer | **not checked** — the streamer is offline. It is the first thing to run once the lid is opened. |
| `bin/forensics.sh` against a real host-level outage | **not checked** — there is no host-level outage to collect on this tree yet; it is exercised against stubbed `pmset` output, an empty tree and a real macOS host |
| The stream restored | **not checked** — needs physical access; see the wiki tracker (T-29, T-30) |

## Deploying this

The streamer is offline as this is tagged. Once it is awake: `bin/status.sh` and
`bin/smoke_test.sh` first, then `sudo bin/harden-host.sh --go`, then
`bin/deploy-release.sh --tag v2.3`. Read
[Updating and rollback](https://github.com/Pummelchen/YTLive_Laundry/wiki/Updating-and-Rollback)
first. If it turned out to be asleep rather than hung, run `bin/forensics.sh --save` **before**
anything that reboots it.

```
SHA256  SHA256_PENDING
BYTES   ARCHIVE_BYTES_PENDING
```
