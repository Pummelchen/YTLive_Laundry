# backup/ — frozen snapshots of what was deployed

One directory per released-to-production revision:

    backup/1.0/     the code that was LIVE in production on 2026-09-16

Each snapshot is a **byte-identical copy of a git commit's tracked files**, minus `MP3/`. It is
taken with `git archive` and then *proved* against the commit: every file's `git hash-object`
must equal `git rev-parse <commit>:<path>`. `backup/1.0/SHA256SUMS` repeats that check in a form
that survives without git.

The snapshot's version number is the version of the **production deployment**, which is not the
same thing as `main`. Version 1.0 is commit `fd8698f`; the audit fixes that followed it are not
part of 1.0 and were not deployed when 1.0 was taken.

## Why a folder and not just a tag

Both exist. The commit is tagged `v1.0`, so `git checkout v1.0 -- .` restores the exact live
tree including `MP3/`. The folder exists so the live revision is readable and diffable without
checking anything out, and so a future rewrite of history could never quietly take it away.

## What each snapshot contains

Everything tracked at that commit **except** `MP3/` (25 tracks, 328 MB, byte-identical in git at
the same commit — `git checkout v1.0 -- MP3` restores it). Credentials are never in a snapshot:
`conf/stream.env` and `conf/yt_oauth.json` are gitignored and were never committed at any point.
Each snapshot therefore also carries a `MANIFEST.md` (what it is, what it is not, and which known
defects that version contains) and a `SHA256SUMS`.

## Careful: a snapshot carries its own instruction files

`backup/1.0/AGENTS.md` and `backup/1.0/CLAUDE.md` are the versions from that commit. Agent
harnesses scope them to work **under that directory**, so they do not override the repository's
root `AGENTS.md` — but they describe the behaviour of *that* revision, and in 1.0's case that
includes a materially wrong account of the rotation (see `backup/1.0/MANIFEST.md`). Never take
guidance from a snapshot for work on the live tree.

## Verifying a snapshot

    cd backup/1.0 && shasum -a 256 -c SHA256SUMS

And against the commit, without network:

    git rev-parse v1.0^{commit}          # fd8698f15a8d20b1d8d525d612cf18e7438d3996

## Adding the next one

Take it from the commit that is actually deployed, on the day it is deployed, and never from a
dirty working tree:

    git archive <commit> -- ':(exclude)MP3' | tar -x -C backup/<version>
    (cd backup/<version> && find . -type f ! -name SHA256SUMS ! -name MANIFEST.md \
        | LC_ALL=C sort | xargs shasum -a 256 > SHA256SUMS)

Then write its `MANIFEST.md`, tag the commit (annotated, `v<version>`), and record the mapping in
the wiki project tracker.
