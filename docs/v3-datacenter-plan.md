# v3.0 — moving the stream into a datacenter (CLOSED, not happening)

> **CLOSED 2026-09-20 by the operator.** The streamer stays on the shop Mac; there will be no VPS
> on the streaming side. Written down so it is not proposed again: *"for now we will not plan to
> use a vps as a streaming helper."* The consequences are accepted knowingly — the failure classes
> below that v3.0 would have removed (the Mac sleeping, crashing, or being unplugged) remain, and
> what covers them instead is the 2.x set: `caffeinate` plus `pmset -c sleep 0 disablesleep 1` on
> AC, auto-login so a clean reboot recovers without a human, the dead-man heartbeat (2.7) and the
> off-host watchdog (2.2). The two classes no software here can fix — the shop's power and its
> uplink — were never fixed by v3.0 either (see the honest headline below), and the tracker no
> longer carries purchase rows for them (task-table standard, hard rule 6). **This document is
> kept as the analysis, not as a plan.** It was tracked as **T-32** until that row closed with
> this decision.

**Status: closed. No phase was ever approved and no code was written from it.** The analysis below
is retained because the 2026-09-18 outage raised the question and the reasoning should not have to
be re-derived if the decision is ever revisited.

## The problem it addresses

The streamer is one laptop-class Mac in a shop with no power protection, and it is a single point
of failure for the whole channel. On 2026-09-18 it dropped off the network mid-segment and the
channel stayed dark ~19 h 26 m. Two of the three failure classes involved are host-shaped:

| Failure | Today | v3.0 |
|---|---|---|
| Mac sleeps / crashes / OS update | entire channel down | **removed** — the encoder is a datacenter VM |
| Mac is off / unplugged / battery dies | entire channel down | **removed** for the encoder; the shop relay replaces it |
| Shop power cut | channel down, unnoticed | still down — the camera has no power. **Needs a UPS (T-30)** |
| Shop internet cut | channel down, unnoticed | still down, but seen in ≤ 15 min and it self-heals when the link returns |
| Nobody notices | ~19 h 26 m | **removed** — the external watchdog (2.2) |

The honest headline: **v3.0 does not fix the shop's power or its uplink.** The camera and the
router stay there. What it removes is the fragile *encoder host* — the thing that actually failed
on 2026-09-18 — and it moves the high-bitrate upload off the weakest link.

## Target architecture

```
shop ──────────────────────────────── internet ──────────────► Hetzner Singapore
camera ──RTSP──► relay ──SRT push──► (no inbound ports)  ──►  SRT listener
                (ffmpeg -c copy)                              ├─ crop + scale + x264 encode
                                                              ├─ MP3 playlist + filler overlay
                                                              ├─ RTMP → YouTube (same key)
                                                              ├─ yt_api.py rotation (8h03m)
                                                              └─ the external watchdog
```

**The camera is never exposed.** No port-forward, no DYNDNS, no public RTSP. T-09 already records
that it is unauthenticated on its LAN; publishing it would let anyone watch the shop and would be a
standing invitation on a consumer IoT device. The relay connects **outbound** only, which also means
this works behind CGNAT — where a port-forward would not work at all.

**Push, not pull.** The VPS cannot reach `192.168.1.3`, so either a tunnel or a push is required. A
push is chosen because it needs no router configuration, no WireGuard endpoint and no inbound
exposure at all, and the shop-side program shrinks to a single `-c copy` process.

### Why the shop's bandwidth gets *better*

The camera delivers ~2.3 Mbit/s (measured; the firmware ignores ONVIF bitrate writes — docs/camera.md).
Today the Mac uploads the finished programme at `ENC_BITRATE=6800k` + `AUD_BITRATE=384k`:

| Link | Today | v3.0 |
|---|---|---|
| Shop → internet | ~7.2 Mbit/s (~2.4 TB/month) | ~2.6 Mbit/s with SRT overhead (~0.85 TB/month) |
| Datacenter → YouTube | — | ~7.2 Mbit/s (~2.4 TB/month) |

The shop's uplink requirement drops roughly 2.8×, because the expensive part (high-bitrate,
already-encoded upload) moves to the datacenter. Hetzner advertises predictable pricing with no
separate egress fees and no tiered decoding ([Singapore
page](https://www.hetzner.com/cloud-singapore/)); the plan's **included** traffic must still be
confirmed at order time against ~2.4 TB/month egress.

## What actually has to change (the real cost)

The repository is deliberately macOS-only, and `AGENTS.md` says so. This is a genuine exception,
so it is a **breaking architectural change — v3.0**, not a 2.x.

**Portable as-is (stdlib Python, no changes expected):** `bin/yt_api.py` (1250 lines, the only
thing that can create a broadcast), `bin/yt_check.py`, `bin/cam_ip.py`, `bin/camscan.py`,
`bin/find_cam.py`, `bin/onvif_probe.py`, `bin/cam_config.py`, `bin/cam_reboot.py`,
`bin/yt_watchdog.py` (2.2).

**Needs porting:**

| macOS dependency | Where | Replacement |
|---|---|---|
| `h264_videotoolbox` (hardware) | `bin/stream.sh:113` | `libx264` with a tuned preset; no GPU on Hetzner |
| `caffeinate -ism -w $$` | `bin/stream.sh:33` | delete — a server never sleeps |
| two LaunchAgents | `install.sh`, `bin/status.sh` | two systemd units |
| `stat -f`, `sed -i ''`, `date -j`/`-r`, `nc -G` | `stream.sh`, `status.sh`, `yt_monitor.sh` | a **portability shim** in `bin/lib.sh` (`file_size`, `sed_inplace`, `date_epoch`, `port_open`) so OS-specific logic lives in exactly one file |
| launchd inspection | `bin/status.sh:19` | `systemctl` equivalent |
| `~/.local/bin` tool layout | `install.sh` | `/usr/local/bin` + distro `ffmpeg` or a static build |
| `~/Downloads/YTLive` TCC/FDA requirement | `install.sh`, `preflight.sh` | gone — no TCC on Linux |

**Decision: keep zsh.** Debian ships zsh, and keeping it removes the largest source of porting risk
(the 774-line `stream.sh` is written in zsh idioms — `<->` numeric globs, `(N)` qualifiers,
`${(j:,:)}`). The port becomes "replace the OS calls, not the language".

**Encoders and sizing.** `videotoolbox` is hardware; x264 is software, so this trade is real. The
content is a mostly-static CCTV composite from a ~14 fps source, upscaled to 1080p30, which is
cheap to encode — but it must be measured, not assumed. Start with **CCX23 (4 dedicated AMD vCPU,
Singapore)**; benchmark against **CPX31 (4 shared vCPU)** before committing, and treat "zero dropped
frames under load" as the acceptance test.

**Tests.** `tests/` is credential-free and mostly portable, but: `t01` shells out to `zsh -n`
(fine once zsh is installed), `t06` executes the **macOS** `install.sh` (needs a Linux equivalent or
an explicit skip), and `release.sh` uses BSD `stat -f`/`sw_vers` (leave the release builder on
macOS — releases are source archives, so the builder's OS is irrelevant to the artifact).

**The MP3 library travels separately.** 328 MB is tracked in git but excluded from every release
archive, so the VPS needs an explicit one-time sync plus the same `shuffle_playlist.sh` step.

## The trap that must not be stepped in

`docs/machines.md` states it plainly: **only ONE machine may push to a given YouTube stream key at a
time.** During migration the Mac and the VPS must never both publish. Every phase below therefore
ends with an explicit "confirm the other publisher is stopped" step, and the external watchdog is
watching the channel independently the whole time.

## Staged plan — one live change at a time

Each phase is independently reversible and ends with its own verification.

**Phase 0 — design and hardware (no live change).** Approve this document. Order the Singapore VPS
and, separately, the UPS for the Mac **and** the router (T-30 — the only thing that survives a power
cut, and the cheapest reliability win in the whole project).

**Phase 1 — the VPS as a passive observer.** Deploy the watchdog there (already done, 2.2). Add
`ffmpeg` and a **listener** that consumes the SRT push but publishes nothing. No production impact.

**Phase 2 — the Mac becomes a relay, the VPS becomes the encoder.** Add the `-c copy` SRT push to
the shop side and the full pipeline to the VPS, with the VPS's RTMP output **disabled**. Verify
end-to-end input health (no packet loss over a sustained 8 h) before any switchover.

**Phase 3 — cut over at a rotation boundary.** Stop the Mac's publisher, start the VPS's, confirm
exactly one publisher holds the key, and let the normal `prepare`/bind rotation carry it. This is
the only minute of real risk, and it is the same operation `deploy-release.sh` already performs
safely on one machine.

**Phase 4 — remove the laptop.** Replace it with a ~5 W always-on relay (a Pi-class device) on the
UPS, and port the docs, `AGENTS.md`'s macOS-only rule, `install.sh` and the test suite to cover both
platforms. Tag **v3.0**.

## Open questions for the owner

1. Approve the direction, or keep macOS-only and rely on the watchdog + `pmset` + UPS? (Both are
   defensible; the watchdog already removes the ten-hour blindness.)
2. Is a monthly VPS acceptable as a running cost, and is Singapore the right region? (Batam → SG is
   ~15–20 ms; Germany would be ~180 ms — irrelevant for a CCTV feed, but SG is closer and cheaper on
   transit.)
3. Does the shop's uplink sustain ~2.6 Mbit/s **up**, 24/7, with a stable latency? That is the hard
   requirement, and it is 2.8× lower than today's.
4. Who owns a VPS in production — patching, monitoring, renewal? A datacenter box is more reliable
   than a laptop but it does not maintain itself.
5. Should the relay be a Pi from the start, or the hardened Mac first? (This plan says Mac first:
   fewer changes at once, and the Mac is already there.)

## Effort

Roughly **3–5 focused days** for Phases 1–3 including tests and docs, plus a soak period of at least
one full 8 h rotation before Phase 4. The unavoidable calendar cost is the soak, not the code — and
2.2's watchdog means the soak can be watched without anyone sitting up with it.
