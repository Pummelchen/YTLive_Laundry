# YTLive_Laundry 2.1 — the installer fixes

2.0 was released and could not be installed. This release makes the installer work, and adds the
gate that would have caught it. Full detail is in [`CHANGELOG.md`](../CHANGELOG.md).

- Built from tag `v2.1`
- Contents: the tagged tree **without `MP3/`**, without `backup/` and without any audit report. The
  25-track, 328 MB music library is byte-identical in git at the same tag (`git checkout v2.1 -- MP3`).
- Source archive, not a build product: nothing to compile, no binaries, nothing to sign.

## Why this release exists

On 2026-09-17 the 2.0 deploy ran for real on `ternak-macbook`. It fired at the correct rotation,
backed up, preserved the broadcast template, stopped both agents, checked out `v2.0` — and then
`./install.sh` **failed**. The deploy rolled back in 23 seconds and the streamer came back healthy
on 1.0, but the rollback reported success having restored less than the install had changed.

Nothing about this was caught by the release gate, because the gate never ran `install.sh`.

## The three defects

**1. `install.sh` could not complete on any machine.**

```
write_plist:1: label: parameter not set
```

`write_plist()` declared five variables in a single statement:

```zsh
local label="$1" script="$2" ptype="$3" throttle="$4" out="$LA/$label.plist"
```

A shell expands *all* of a command's arguments **before** the command runs, so `$label` is read
while it is still unset. Under the `set -u` at line 29 the shell exits. This is not a zsh quirk:
it fails under bash for the same reason. Reproduced in isolation before fixing.

*Fix:* one `local` per line. *Check:* `tests/t06_install.sh` runs the installer for real, and
against the released 2.0 code it fails **16 of 21** checks.

**2. It chose the wrong Python, and installed a `yt-dlp` that cannot work.**

```zsh
PY=$(command -v python3)
```

trusted PATH order. On this machine that resolved to `/usr/bin/python3` — the Xcode Command Line
Tools **3.9.6** — while a python.org **3.14.7** was installed alongside it. `yt-dlp` dropped
Python 3.9, so pip resolved to the last release that supports it, **2025.10.14**, which can no
longer parse YouTube's live page.

*Fix:* scan PATH **and** the usual install locations (a bare launchd/ssh PATH does not include
`/usr/local/bin`, which is exactly where the usable interpreter lives), prefer an interpreter that
already has `yt_dlp`, require ≥ 3.10 when installing, and fall through to the next candidate when
pip refuses — Homebrew Python rejects `--user` installs under PEP 668. `YT_PY_SEARCH` overrides
the search list to force one interpreter.

*Verified on the machine:* the selector now resolves `/usr/local/bin/python3` (3.14.7) with
`yt_dlp 2026.08.19` already present, so no pip install happens at all.

**3. It clobbered a working `yt-dlp` with a worse one.**

`ln -sf "$YTB/yt-dlp" "$BIN/yt-dlp"` replaced whatever was there, unconditionally. That is how the
monitor went blind: `~/.local/bin/yt-dlp` was repointed at the stale 3.9 build, and `yt-dlp` could
no longer answer, so every check returned `UNKNOWN` and picture checking was suspended.

*Fix:* compare versions first and keep the existing binary when it is newer; back up the old one
and restore it automatically if a replacement does not run.

## What also changed

- **`bin/deploy-release.sh`** — a real deploy tool, because "git checkout && ./install.sh" is not
  one. Its backup covers what `install.sh` actually writes (`~/.local/bin`, `~/Library/LaunchAgents`,
  `~/Library/Logs/YTLive`) and not merely the project tree; it verifies the **result**, including
  that `yt-dlp` still resolves the live page, instead of trusting an exit code; and it says
  `PARTIAL ROLLBACK` out loud rather than claiming a clean one it did not achieve.
- **`tests/t06_install.sh`** — 21 checks that run the installer in a sandbox with fake interpreters
  and its own `HOME`, so it can never reach the real `~/.local/bin`, the real LaunchAgents or the
  live stream. The suite is now **106 checks**.

## Checks run for this release

| What | Result |
|---|---|
| The project's own suite, serially | **checked** — 106 checks, all passing |
| The new installer test against the **released 2.0** code | **checked** — fails 16/21, proving it guards the bug |
| The installer, end to end, on the real streamer in a throwaway `HOME` | **checked** — exit 0, both plists valid, real `~/.local/bin` untouched |
| Interpreter selection on the real streamer | **checked** — resolves 3.14.7 with a working `yt-dlp`; no pip install |
| Deploy actually performed on the streamer | **not checked** — this is the next step, in a maintenance window |

## Deploying this does not happen by itself

The production streamer runs **1.0** and is live. Nothing in this repository pushes to it. Use
`bin/deploy-release.sh --tag v2.1` on the machine, and read
[Updating and rollback](https://github.com/Pummelchen/YTLive_Laundry/wiki/Updating-and-Rollback)
first — it now begins with an environment pre-flight, and a rollback that covers the machine.

```
SHA256  SHA256_PENDING
BYTES   ARCHIVE_BYTES_PENDING
```
