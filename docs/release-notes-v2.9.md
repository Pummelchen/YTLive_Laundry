# YTLive_Laundry 2.9 — the check told an operator to delete a working sudoers rule

2.9 fixes one bug in 2.8, found by running 2.8's own documented check. `bin/harden-host.sh
--check` is meant to run **without sudo**, and the `NOPASSWD` rule it verifies is installed `0440
root:wheel`. A normal user therefore cannot read it, and `visudo -cf` fails on **permission**
rather than on syntax — but 2.8 treated that as a malformed file and printed the loudest message
in the tool:

    FAIL  /etc/sudoers.d/ytlive-net exists but does not parse or lacks the rule - sudo may be
          refusing EVERY rule. Fix or remove it now: sudo rm /etc/sudoers.d/ytlive-net

On a file that was perfectly good. That is worse than a missing check: it invites an operator to
delete a working rule, on the strength of a false alarm, at the moment they are least able to
audit it. Full detail is in [`CHANGELOG.md`](../CHANGELOG.md).

- Built from tag `v2.9`
- Contents: the tagged tree **without `MP3/`**, without `backup/` and without `AUDIT/`
  (`git checkout v2.9 -- MP3` restores the music library). No credentials or runtime state are in
  any archive: `conf/stream.env`, `conf/yt_oauth.json`, `conf/watchdog.env`,
  `conf/heartbeat.token` and `log/` are gitignored and were never committed.
- Source archive, not a build product: nothing to compile, no binaries, nothing to sign.

## What changed

`sudoers_state()` now answers with one of four values, and each prints its own sentence:

| State | Meaning | The check says |
|---|---|---|
| `installed` | readable, parses, carries the rule | `PASS`, the watchdog may renew DHCP and flush the resolver |
| `unreadable` | present but root-only (`0440`), which is correct | `NOTE … readable only by root - run 'sudo bin/harden-host.sh --check' to verify that it parses`, and **no failure** |
| `broken` | readable and does not parse | the loud `FAIL` above, unchanged — because a malformed file in `/etc/sudoers.d` really can make sudo refuse every rule |
| `missing` | nothing installed | `FAIL` naming `sudo bin/harden-host.sh --go` |

The distinction is the whole point: **"I cannot confirm this" is not "this is broken"**, and the
project's rule is that a check which cannot confirm must not report OK — which is exactly why an
unreadable file gets its own sentence rather than a PASS or a FAIL.

## Verification

- `tests/t08_hosttools.sh`: **68 checks**, all passing. The new ones pin that an unreadable (`000`
  mode, simulating `0440` root-only for a normal user) rule is reported as unverifiable, that it
  never says sudo itself may be broken, and that a readable-but-garbage file still produces the
  loud failure.
- Measured on the live streamer: `bin/harden-host.sh --check` as the normal user now prints
  `NOTE  /etc/sudoers.d/ytlive-net is present but readable only by root - run 'sudo
  bin/harden-host.sh --check' to verify that it parses` and exits 0; `sudo bin/harden-host.sh
  --check` verifies the parse and prints `PASS`.
- The full suite is **701 checks** (2.8's 699 plus these two).

## Deploying this

A one-file change: `bin/deploy-release.sh --tag v2.9 --go` on the streamer. Nothing on the
watchdog host changed, so no reinstall is needed there. There is no config migration.

```
SHA256  SHA256_PENDING
BYTES   ARCHIVE_BYTES_PENDING
```
