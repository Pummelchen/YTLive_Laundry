#!/bin/zsh
# Build - and with --publish, publish - a source release of YTLive_Laundry.
#
#   ./release.sh --version 1.0 --tag v1.0                 dry run: build, verify, upload nothing
#   ./release.sh --version 2.0 --tag v2.0 --publish       build, verify, then publish
#
# This repository has nothing to compile, so a "release" here is a source archive of the tagged
# tree plus a SHA-256 beside it. RELEASE.md Part 1's macOS binary packaging does not apply; see
# Part 2 for the parts that do, and for why the archive is named without an arch suffix.
#
# WHAT THIS SCRIPT REFUSES TO DO, on purpose:
#   - release a version whose VERSION file disagrees with the tag (a mirror mismatch)
#   - release a tag that is not on the remote (gh would otherwise invent it from main)
#   - release an archive whose contents do not hash-match the tag it claims to be
#   - publish notes that carry neither the checksum placeholder nor a real digest
#   - rebuild between the dry run and the publish, which is how a digest ends up wrong
set -u

REPO="Pummelchen/YTLive_Laundry"
VERSION=""; TAG=""; PUBLISH=no; LATEST=no; KEEP=no
BUILD_ROOT=".release-build"

while (( $# > 0 )); do
  case "$1" in
    --version) VERSION="${2:-}"; shift 2 ;;
    --tag)     TAG="${2:-}";     shift 2 ;;
    --repo)    REPO="${2:-}";    shift 2 ;;
    --publish) PUBLISH=yes; shift ;;
    --latest)  LATEST=yes; shift ;;
    --keep)    KEEP=yes; shift ;;
    -h|--help) sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) print -u2 -- "unknown argument: $1"; exit 2 ;;
  esac
done

die()  { print -u2 -- "ERROR: $*"; exit 1; }
say()  { print -r -- "==> $*"; }
note() { print -r -- "    $*"; }

[[ -n "$VERSION" ]] || die "--version is required (e.g. --version 2.0)"
[[ -n "$TAG" ]]     || TAG="v$VERSION"
case "$VERSION" in
  [0-9]*.[0-9]*) : ;;
  *) die "version '$VERSION' is not MAJOR.MINOR" ;;
esac

BASE="$(cd "$(dirname "$0")" && pwd)"
cd "$BASE" || die "cannot cd to $BASE"
# Absolute, because several steps cd into the staging tree and a relative path would then
# resolve against THAT directory (which is how the first version of this script failed to
# write its test log).
ABS_BUILD="$BASE/$BUILD_ROOT/$VERSION"

# --- §1.4 preconditions -------------------------------------------------------------------
say "preconditions"
note "macOS $(sw_vers -productVersion) $(uname -m), zsh $ZSH_VERSION, python3 $(python3 -V 2>&1 | awk '{print $2}')"
note "disk $(df -h . | awk 'NR==2 {print $4}') free"
gh auth status >/dev/null 2>&1 || die "gh is not authenticated; §1.4 requires the repository owner's account"
note "gh: $(gh auth status 2>&1 | grep -o 'account [A-Za-z0-9_-]*' | head -1)"

# The tag must exist locally, and be on the remote: `gh release create` will otherwise create the
# tag from the default branch, publishing something that is not the tree we verified.
git rev-parse -q --verify "refs/tags/$TAG" >/dev/null || die "tag $TAG does not exist locally"
git ls-remote --exit-code --tags origin "$TAG" >/dev/null 2>&1 \
  || die "tag $TAG is not on origin. Push it first: git push origin $TAG"
TAG_SHA=$(git rev-parse "$TAG^{commit}")
note "tag $TAG -> $TAG_SHA"

# §1.3 identity is single-sourced: VERSION is authoritative, and a mismatch fails the build.
if git cat-file -e "$TAG:VERSION" 2>/dev/null; then
  TAG_VERSION=$(git show "$TAG:VERSION" | tr -d '[:space:]')
  [[ "$TAG_VERSION" == "$VERSION" ]] \
    || die "identity mismatch: $TAG:VERSION says '$TAG_VERSION' but this release is '$VERSION'"
  note "VERSION at $TAG says '$TAG_VERSION' - matches"
else
  note "NOTE: $TAG has no VERSION file (predates it); identity comes from the tag alone"
fi

# --- build the archive from the tag, never from the working tree ---------------------------
STAGE="$BUILD_ROOT/$VERSION/tree"
ARCHIVE_NAME="YTLive_Laundry-${VERSION}-source.tar.gz"
ARCHIVE="$BUILD_ROOT/$VERSION/$ARCHIVE_NAME"
rm -rf "$BUILD_ROOT/$VERSION"
mkdir -p "$STAGE"

say "exporting $TAG (excluding MP3/ and backup/)"
git archive "$TAG" -- ':(exclude)MP3' ':(exclude)backup' | tar -x -C "$STAGE" \
  || die "git archive failed"
note "$(find "$STAGE" -type f | wc -l | tr -d ' ') files"

cat > "$STAGE/README-ARCHIVE.txt" <<EOF
YTLive_Laundry $VERSION - source archive
Built from tag $TAG ($TAG_SHA) on $(date '+%Y-%m-%d %H:%M:%S %Z').

WHAT THIS IS
  The source of the CCTV -> YouTube streamer, exactly as committed at the tag above. There is
  nothing to compile: bin/*.sh are zsh, bin/*.py are stdlib-only Python, and the deployment
  step is install.sh. This archive is not a build product and has no binary to sign, notarize
  or quarantine.

WHAT IT IS NOT
  - No MP3/ music library. It is 328 MB and byte-identical in git at the same tag:
        git checkout $TAG -- MP3
    or copy it from an existing install.
  - No credentials. conf/stream.env (the YouTube stream key) and conf/yt_oauth.json (the OAuth
    refresh token) are gitignored and were never committed. You must supply both.
  - Not a backup of a running installation: conf/playlist.txt points at another machine's home
    and install.sh rebuilds it.

PLATFORM
  macOS only. Requires launchctl, /bin/zsh, caffeinate, stat -f, plutil, nc -G and sed -i '',
  so there is no Linux path. Apple Silicon needs Rosetta 2 for the static Intel ffmpeg that
  install.sh downloads.

INSTALL
    cd ~/Downloads/YTLive            # the project must live here; see AGENTS.md
    tar -xzf $ARCHIVE_NAME --strip-components=0
    cp conf/stream.env.example conf/stream.env    # then paste your stream key into YT_KEY
    ./install.sh                                  # installs, does not start
    bin/yt_api.py auth                            # OAuth device flow, one time
    ./install.sh --start

  Only ONE machine may push to a given YouTube stream key at a time.
  Verify this archive first:  shasum -a 256 -c $ARCHIVE_NAME.sha256
EOF

# --- §1.5 gate: the archive must BE the tag -------------------------------------------------
say "gate: every archived file must hash-match $TAG"
python3 - "$STAGE" "$TAG" <<'PY' || die "archive does not match the tag"
import subprocess, sys, pathlib
stage, tag = pathlib.Path(sys.argv[1]), sys.argv[2]
skip = {"README-ARCHIVE.txt"}
files = [p for p in stage.rglob("*") if p.is_file() and p.relative_to(stage).as_posix() not in skip]
bad, missing = [], []
for p in files:
    rel = p.relative_to(stage).as_posix()
    h = subprocess.run(["git", "hash-object", str(p)], capture_output=True, text=True).stdout.strip()
    r = subprocess.run(["git", "rev-parse", f"{tag}:{rel}"], capture_output=True, text=True)
    if r.returncode != 0:
        missing.append(rel)
    elif r.stdout.strip() != h:
        bad.append(rel)
print(f"    compared {len(files)} | identical {len(files)-len(bad)-len(missing)} | mismatched {len(bad)} | not-in-tag {len(missing)}")
for b in bad[:5]:     print(f"    MISMATCH {b}")
for m in missing[:5]: print(f"    NOT IN TAG {m}")
sys.exit(1 if bad or missing else 0)
PY

# --- §1.5 gate: syntax of the staged tree ---------------------------------------------------
say "gate: syntax"
syntax_fail=0
while IFS= read -r f; do
  case "$f" in
    *.py) python3 -c "import ast,sys; ast.parse(open(sys.argv[1]).read())" "$STAGE/$f" 2>/dev/null \
            || { print -u2 -- "    FAIL $f"; syntax_fail=1; } ;;
    *.sh) /bin/zsh -n "$STAGE/$f" 2>/dev/null || { print -u2 -- "    FAIL $f"; syntax_fail=1; } ;;
  esac
done < <(cd "$STAGE" && find . -name '*.sh' -o -name '*.py' | sed 's|^\./||')
(( syntax_fail == 0 )) && note "all shell and python files parse" || die "syntax gate failed"

# --- §1.5 gate: the project's own test suite, if this version has one -----------------------
say "gate: test suite"
if [[ -f "$STAGE/tests/run.sh" ]]; then
  if (cd "$STAGE" && /bin/zsh tests/run.sh >"$ABS_BUILD/tests.log" 2>&1); then
    note "$(grep -cE 'PASS' "$ABS_BUILD/tests.log") PASS lines; suite passed"
    note "log: $ABS_BUILD/tests.log"
  else
    tail -8 "$ABS_BUILD/tests.log" | sed 's/^/    /'
    die "the test suite failed"
  fi
else
  note "NOT CHECKED: $VERSION has no tests/ suite (it was added after 1.0)."
  note "           bin/smoke_test.sh also cannot pass without credentials. Named in the release notes."
fi

# --- pack ----------------------------------------------------------------------------------
say "packing"
# COPYFILE_DISABLE + --no-mac-metadata: without them bsdtar writes ._ AppleDouble members and
# the archive is full of junk.
( cd "$STAGE" && COPYFILE_DISABLE=1 tar --no-mac-metadata -czf "$BASE/$ARCHIVE" . ) \
  || die "tar failed"
BYTES=$(stat -f %z "$ARCHIVE")
DIGEST=$(shasum -a 256 "$ARCHIVE" | awk '{print $1}')
print -r -- "$DIGEST  $ARCHIVE_NAME" > "$ARCHIVE.sha256"
note "$ARCHIVE_NAME  $BYTES bytes"
note "sha256 $DIGEST"
( cd "$BUILD_ROOT/$VERSION" && shasum -a 256 -c "$ARCHIVE_NAME.sha256" >/dev/null ) \
  || die "the checksum does not verify against the file we just wrote"

# --- §1.8 notes ----------------------------------------------------------------------------
NOTES="docs/release-notes-v$VERSION.md"
[[ -f "$NOTES" ]] || die "missing $NOTES"
if ! grep -q 'SHA256_PENDING' "$NOTES" && ! grep -qE '[0-9a-f]{64}' "$NOTES"; then
  die "$NOTES carries neither SHA256_PENDING nor a real digest; §1.8 forbids publishing that"
fi
PUB_NOTES="$ABS_BUILD/notes.md"
sed -e "s/SHA256_PENDING/$DIGEST/g" -e "s/ARCHIVE_BYTES_PENDING/$BYTES/g" "$NOTES" > "$PUB_NOTES"
say "release notes for the GitHub Release"
note "$NOTES -> $PUB_NOTES (digest substituted at publish time)"

if [[ "$PUBLISH" != yes ]]; then
  print ""
  say "DRY RUN - nothing uploaded. To publish:"
  note "./release.sh --version $VERSION --tag $TAG --publish"
  [[ "$KEEP" == yes ]] || note "(staging kept at $BUILD_ROOT/$VERSION for inspection)"
  exit 0
fi

# --- §1.7 publish --------------------------------------------------------------------------
say "publishing $TAG to $REPO"
LATEST_ARG=()
[[ "$LATEST" == yes ]] && LATEST_ARG=(--latest)
gh release create "$TAG" "$ARCHIVE" "$ARCHIVE.sha256" \
  --repo "$REPO" --title "YTLive_Laundry $VERSION" --notes-file "$PUB_NOTES" "${LATEST_ARG[@]}" \
  || die "gh release create failed"

# --- §1.9 verify ---------------------------------------------------------------------------
say "verifying the published release"
# Note: `gh release view --json` has no isLatest field; the latest marker comes from
# `gh release list`, which is also what a reader would use.
gh release view "$TAG" --repo "$REPO" --json tagName,isDraft,isPrerelease,assets \
  --jq '"    tag \(.tagName)  draft=\(.isDraft)  prerelease=\(.isPrerelease)  assets: \([.assets[].name] | join(", "))"' \
  || die "could not read the release back"
gh release download "$TAG" --repo "$REPO" --pattern '*.sha256' --output - 2>/dev/null \
  | grep -q "$DIGEST" || die "the published .sha256 does not carry the digest we built"
note "the published .sha256 carries the digest"
gh release view "$TAG" --repo "$REPO" --json body --jq '.body' \
  | grep -q "$DIGEST" || die "the published notes do not quote the digest in the .sha256"
note "the published notes quote the digest"
note "latest release is now $(gh release list --repo "$REPO" --limit 1 --json tagName --jq '.[0].tagName')"

[[ "$KEEP" == yes ]] || rm -rf "$BUILD_ROOT/$VERSION"
say "done: https://github.com/$REPO/releases/tag/$TAG"
