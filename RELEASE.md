# Release and build rules — YTLive_Laundry

The release and build standard for this repository.

**This file belongs to this repository.** Edit it here and nowhere else. It was once
deployed from a master document kept in another repository; that arrangement is gone.
Nothing outside this repository governs these rules or can overwrite this file, and an
agent working here never needs to leave the repository to find the standard.

**Part 1 is the rule set** and **Part 2 is this repository's own section**; where the
two appear to disagree, Part 2 wins.

---

# Part 1 — Generic rules

## 1.1 Scope

These apply to any repository that produces a **runnable artifact**: a binary, a
library, an image, a package. Repositories that only hold documents, data or
configuration are out of scope, and should say so in their Part 2 section rather
than adopting a release process they cannot use.

## 1.2 Non-negotiable

1. **Apple Silicon only.** Build native `arm64`. This covers M1–M6. Never
   `--arch x86_64`, never `ARCHS=arm64 x86_64`, and never `lipo -create` — that
   is how a universal binary gets made, and there is no x86_64 build.
2. **Assert it, do not assume it.** After building, check the artifact:
   `lipo -archs <binary>` must be exactly `arm64`. A build that silently produced
   a fat binary is a release defect, not a build option.
3. **Every release carries the artifacts.** A tag alone is not a release. If the
   Release page has no binaries attached, the release did not happen.
4. **No hardcoded build-toolchain triple in a path.** `.build/release` is the
   stable spelling. `.build/arm64-apple-macosx/release` points at nothing on a
   newer toolchain and at a stale binary on this one. The one exception is a build
   that explicitly passes `--arch arm64`: then the triple directory really is
   where SwiftPM writes, and that build must also assert the arch (§1.2.2).
5. **One checksummed artifact per target, or one checksum file covering all of
   them.** Never publish a binary without a digest beside it.
6. **Dry run by default; publish only on an explicit flag.**
7. **Never fetch a model, dataset or dependency to make a gate pass.** A check
   that cannot run is reported *not checked* — and the release notes must name it.
   "Not checked, no input" and "checked and identical" are different sentences.

## 1.3 Identity

The version or build number is **single-sourced and enforced**, not maintained by
hope.

- **One authoritative value.** A file at the repository root — `VERSION` for a
  semantic version, `BUILD_NUMBER` for a build number. Anywhere else it appears
  is a **mirror**, and the build or CI must fail when a mirror disagrees.
- **Pick one scheme and state it.** Semantic versions (`vX.Y.Z`) or build numbers
  (`b1`, `b2`). Do not mix them, and do not "helpfully" introduce versions into a
  project that uses build numbers.
- **The build refuses a malformed or inconsistent identity.** Fail at configure
  or compile time, not at release time.
- **Identity is observable.** A user must be able to say what they are running
  from the artifact alone: the archive filename, or the program's own answer, or
  both.
- **Bump once, propagate mechanically.** Provide a command that writes the mirrors
  from the authoritative value. A release is one edit plus one command.
- **A second declaration in a test is a defect.** Derive the expected value from
  the source of truth; a literal in a test means every bump fails a test that is
  not about the version, and the tempting fix — editing the test — is how a wrong
  version ships.
- **Multi-library projects version in lockstep.** Libraries that ship together and
  interoperate carry the **same** version, because a caller pairing them has no
  other way to know the pair is compatible. A library with no code change is
  recompiled and republished at the new number rather than left behind.
  Lockstep applies to the **library version only** — an ABI version, protocol
  draft, or schema version is a separate axis and must not be dragged along.

## 1.4 Preconditions

Before starting, confirm and record: the OS floor and toolchain floor are met
(`sw_vers`, `swift --version`); there is disk for a clean scratch build plus the
staged archive; `memory_pressure -Q` is acceptable; **no competing build or model
process is running**; `gh auth status` is the repository owner's account; the tree
is clean; and `HEAD` **is** the tag.

**Never terminate a process you did not start.** If one is blocking, name it with
its parent and age, and stop.

## 1.5 Gates

Run these in order, and make each one **able to fail**:

1. **Lint** — the project's own lint gates.
2. **Full test suite**, serially, and it must report the count that passed.
3. **Parity or golden checks** — real inference, real rendering, real protocol
   frames; whatever "the output is unchanged" means for this project.
4. **A clean scratch build** with the log scanned for warnings.

Two traps, both of which have shipped broken gates in this organisation:

- **A gate that cannot fail is not a gate.** A guard that looks for a file the
  build never produces passes for every input. A warning scan over an *incremental*
  build compiles nothing and passes vacuously — always use a fresh scratch path.
  Before trusting a new gate, break its input and watch it fail.
- **Guard the plan, not the byproduct.** Ask the build system what it resolved
  (`swift package describe --type json`, `cmake --build ... -t help`) rather than
  checking for artifacts after the fact.

## 1.6 Packaging

The archive contains, at minimum:

- the **executables or libraries**, built for arm64;
- **resource bundles** — a Swift binary without its `.bundle` cannot load its
  Metal kernels, and this fails at runtime rather than at build time;
- `LICENSE`, and `NOTICE` / `THIRD_PARTY_NOTICES.md` where third-party code is
  redistributed;
- a **`README-binaries.txt`** stating the platform floor, that the build is
  Apple-Silicon-only, and that the binaries are **not code-signed or notarized** —
  with the quarantine command (`xattr -dr com.apple.quarantine <path>`) so a user
  who verified the checksum can run them. Do not imply a notarized build.

Name the archive `<project>[-<library>]-<version>-macos-arm64.tar.gz`; the
library segment is required only for a multi-library project, and exists so two
artifacts of the same release are distinguishable.

## 1.7 Publishing

```bash
gh release create "$TAG" "$ARCHIVE" "$ARCHIVE.sha256" \
  --repo <owner>/<repo> --title "<Project> $VERSION" \
  --notes-file "$NOTES" --latest
```

**Pin `--repo` on every `gh` call.** In a fork `gh` defaults to the *parent*
repository, so `gh release list` shows another project's releases and
`gh release create` fails with a misleading "tag has not been pushed".

## 1.8 Release notes

- Full notes in `docs/release-notes-vX.Y.md` (or the repository's equivalent),
  one section per user-visible change, each naming the check that backs it.
- End with a checksum block carrying `SHA256_PENDING` and
  `ARCHIVE_BYTES_PENDING`, substituted at publish time. **Never copy a size out
  of a dry run** — publish rebuilds, and the archive differs.
- `--publish` must **refuse** unless the notes carry the placeholder or quote the
  real value. A release quoting the wrong digest is worse than one quoting none.
- Name **every** check that did not run, and why.
- The README gets **no release callout**. It changes only when a fact it states
  changes. The changelog is the announcement.

## 1.9 After publishing

Verify the Release: the notes quote the digest in the `.sha256` beside it, the
assets are the archive and its checksum, and the changelog points at the same tag.
Leave previous releases' notes and performance tables alone.

## 1.10 Rules, agents and other repositories

- **These rules live in this repository and are edited only here.** They are not
  deployed from anywhere and nothing outside this repository can overwrite them. A
  rule an agent cannot find is a rule that will be broken, so a rule about this
  repository belongs in this file or in `AGENTS.md` — not in a shell-script comment,
  and not in another repository.
- **Work happens in this repository only.** Never commit, push, open a pull request
  against, or otherwise modify another repository. A change that appears to belong
  elsewhere is reported to the owner with the exact edit and the reason, not applied.
  Touching another repository requires an instruction that names it, and "the fix
  lives there" is not one.
- **`AGENTS.md` is the one instruction file, and every harness must reach it.** This
  account works with Codex, Claude Code, DeepSeek Harness, OpenCode, Qwen Code,
  Qoder and Zed. Six read `AGENTS.md` directly; **Claude Code does not** — its
  documentation is explicit that it reads `CLAUDE.md`, not `AGENTS.md` — so this
  repository also carries a committed `CLAUDE.md` whose entire content is the
  `@AGENTS.md` import. Commit it: a symlink made on one machine is invisible to a
  fresh clone, to CI and to every other checkout, and on Windows it needs
  Administrator rights. Qwen Code reads `AGENTS.md` alongside its own `QWEN.md`, so
  there is nothing to duplicate for it.
- **Never add a file that shadows `AGENTS.md`.** Zed takes the *first match* from
  `.rules`, `.cursorrules`, `.windsurfrules`, `.clinerules`,
  `.github/copilot-instructions.md`, `AGENT.md`, and only then `AGENTS.md` — so any
  of those six silently replaces this file for every Zed user. Check for them whenever
  the instruction file changes.
- **An archived repository is read-only.** Nothing can be committed to it, so no
  release step may depend on one. Name the exclusion rather than leaving a gap.
- **A check that has never been seen to fail is not yet trusted.**

# Part 2 — This repository

## YTLive_Laundry — Python, source releases

- **Identity** two-component `MAJOR.MINOR`, released as the tags `v1.0`, `v2.0`, `v2.1` and `v2.2`. This is a
  deliberate departure from §1.3's "semantic versions (`vX.Y.Z`)" — the scheme is stated here,
  is used consistently, and should not be mixed with anything else. The authoritative value is
  the `VERSION` file at the repository root; there are no mirrors and no version literal in any
  script, so a bump is a single edit. `release.sh` **fails the build** when `VERSION` and the
  tag disagree (§1.3).
  - `1.0` = `fd8698f`, the code that was live in production on 2026-09-16. Published so a
    rollback is a download. It contains every defect the audit found.
  - `2.0` = the 2026-09-16 audit fixes. Audit reports are **not** kept in the working tree, so the
    next audit cannot read a finished one as current; they are archived by commit permalink. That
    report is at
    <https://github.com/Pummelchen/YTLive_Laundry/blob/d603fdcf92dff17bfb7aa770562b04b84e37e71d/AUDIT/2026-09-16-full-audit.md>.
  - `2.1` = the 2026-09-17 installer fixes — `install.sh` could not complete on any machine and the
    2.0 deploy rolled back on it. Detail in `docs/release-notes-v2.1.md`.
  - `2.2` = the 2026-09-19 external watchdog and host hardening — `bin/yt_watchdog.py`, the one
    component that runs off the streamer, plus the `pmset` runbook. Detail in
    `docs/release-notes-v2.2.md`.
  - `v1.0` additionally exists as a bare snapshot tag with `backup/1.0/` beside it; the 1.0
    Release was created later, from that tag.
- **Archive naming** `<project>-<version>-source.tar.gz` — `YTLive_Laundry-1.0-source.tar.gz`.
  This is a Part 2 override of §1.6's `-macos-arm64` suffix: the payload is zsh and stdlib
  Python, it is architecture-independent, and there is no compiled artifact whose platform the
  name could usefully describe. Every archive ships a `.sha256` beside it (§1.2.5) and a
  generated `README-ARCHIVE.txt` in place of §1.6's `README-binaries.txt`, saying what the
  archive is, what it is not, the macOS-only floor, and how to install it.
- **Repository is public.** Its views badge uses the README-embedded static form
  rather than the endpoint form; either works, and it is left alone rather than
  churning the README. Converting it means moving it into the `REPOS` list in
  `~/bin/traffic-badge-update.sh` and swapping the badge for the endpoint shape.
- **No compiled artifact**, so §1.6's macOS packaging sections do not apply — but three parts of
  Part 1 do, and are enforced by `release.sh`: the archive must carry `LICENSE`; it must carry a
  digest (§1.2.5); and it must be accompanied by release notes naming the checks that ran and the
  checks that did not (§1.2.7, §1.8).
- **Releases are built from a tag and verified against it.** `release.sh` exports the tagged tree
  with `git archive`, then requires every archived file to hash-match
  `git rev-parse <tag>:<path>`, then runs the syntax gates and the `tests/` suite *from the
  archive*. It refuses to publish a tag that is not on the remote, because `gh release create`
  would otherwise invent the tag from the default branch.
- **§1.5's four gates, mapped to this repository.**
  - *Lint* — the syntax gate: `zsh -n` per shell file and `ast.parse` per Python module. There
    has never been another linter here, so this is the whole of it.
  - *Test suite* — `tests/run.sh`, 218 checks, run serially, reporting the count that passed. It
    was added in 2.0; 1.0 has none, and its notes record that as **not checked** rather than
    implying a green run.
  - *Parity / golden* — the archive hash-match: for this project "the output is unchanged" means
    "every archived file is byte-for-byte the file at the tag".
  - *Clean scratch build with the log scanned for warnings* — **not applicable.** Nothing is
    compiled, so there is no build and no warning scan, and claiming one would be theatre.
- **`bin/smoke_test.sh` is not a release gate.** It requires `conf/yt_oauth.json`, which is
  gitignored and in no archive, so it cannot pass inside a release. Every release's notes say so.
- **Dry run by default** (§1.2.6): `./release.sh --version 2.2 --tag v2.2` builds and verifies
  without uploading; `--publish` is required to create the Release. The archive is built once per
  run and the published digest comes from that same file, so §1.8's "never copy a size out of a
  dry run" cannot be violated by a rebuild.
- **No MP3 in a release, and never an audit report.** The 328 MB music library is byte-identical in
  git at every tag (`git checkout v2.0 -- MP3`) and is not code. `backup/` is excluded too: a
  release should not contain a copy of another release. `AUDIT/` is excluded because audit reports
  are not kept in the working tree at all — `release.sh` enforces all three exclusions, so the
  conventions are mechanical rather than hopeful.
- **No CI.** `.github/` does not exist here, so nothing runs `bin/smoke_test.sh` or `tests/run.sh`
  automatically; they are local gates only, and a green check elsewhere says nothing about this
  repository. CodeQL runs from GitHub's dynamic default setup, outside the repo.
- **`bin/smoke_test.sh` cannot pass inside a release.** It needs `conf/yt_oauth.json`, which is
  gitignored and in no archive. Every release's notes therefore record it as **not checked**
  rather than implying it passed.
