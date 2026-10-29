#!/bin/bash
# A test release from the branch you're on: a pre-release that only shows up in Settings > Updates >
# Select version (marked "test", with Show test versions on), never as the latest, and main isn't touched.
#
#   bash tools/test-release.sh [notes.md]      from a checkout of the branch (not main)
#
# 1. Checks: not main, nothing uncommitted, nothing on GitHub that isn't here; every plugin's tests
#    (tests/run.lua with KOReader's LuaJIT: $LUAJIT, or luajit on the PATH, or the emulator's through WSL);
#    the privacy check on what the branch adds, when tools/privacy_check.py is there.
# 2. Pushes the branch, then tags it with the next free test tag after the latest release (v1.0.15 ->
#    v1.0.15-test1, -test2, …; the updater compares only the numbers, so a test sorts after its release
#    and before the next one) and pushes the tag. The notes: the file given, else the branch's commits.
# 3. GitHub's release workflow (.github/workflows/release.yml) builds it: a tag with a dash is a
#    pre-release. This waits for it, then checks the release has the plugins zip and each optional app's.
# Needs git and gh (signed in); python for the privacy check.
set -euo pipefail

die() { echo "test-release: $*" >&2; exit 1; }
cd "$(git rev-parse --show-toplevel)"

branch=$(git rev-parse --abbrev-ref HEAD)
[ "$branch" != "HEAD" ] || die "not on a branch"
[ "$branch" != "main" ] || die "you're on main: a test release comes from another branch"
[ -z "$(git status --porcelain)" ] || die "there are uncommitted changes: commit or set them aside first"
repo=$(git remote get-url origin | sed -E 's#^(https://github.com/|git@github.com:)##; s#\.git$##')
command -v gh >/dev/null || die "gh (GitHub's command line) is needed"

git fetch -q origin --tags
if git rev-parse -q --verify "refs/remotes/origin/$branch" >/dev/null; then
    behind=$(git log --oneline "HEAD..origin/$branch")
    [ -z "$behind" ] || { echo "$behind"; die "GitHub has commits on $branch this checkout doesn't: pull them first"; }
fi

# ---------------------------------------------------------------- checks

lj=()
if [ -n "${LUAJIT:-}" ]; then lj=("$LUAJIT")
elif command -v luajit >/dev/null; then lj=(luajit)
elif command -v wsl >/dev/null; then lj=(wsl -e '~/ko-doc-emu/squashfs-root/usr/lib/koreader/luajit')
fi
if [ ${#lj[@]} -eq 0 ]; then
    echo "tests: skipped (no LuaJIT: set LUAJIT to KOReader's)"
else
    failed=0
    for t in */tests/run.lua optional/*/tests/run.lua; do
        [ -f "$t" ] || continue
        dir=${t%/tests/run.lua}
        if [ "${lj[0]}" = wsl ]; then
            out=$(cd "$dir" && MSYS_NO_PATHCONV=1 wsl -e bash -c "${lj[2]} tests/run.lua" 2>&1) || failed=1
        else
            out=$(cd "$dir" && "${lj[@]}" tests/run.lua 2>&1) || failed=1
        fi
        echo "tests: $dir: $(echo "$out" | tail -1)"
    done
    [ $failed = 0 ] || die "a plugin's tests failed"
fi

base=$(git tag -l 'v*' | grep -v -- - | sort -V | tail -1 || true)
[ -n "$base" ] || die "no release tag to start from"
if [ -f tools/privacy_check.py ]; then
    python tools/privacy_check.py --range "$base..HEAD" || die "the privacy check found something"
    echo "privacy: clean"
fi

# ---------------------------------------------------------------- the tag

n=$(git tag -l "$base-test*" | sed -E "s/^$base-test//" | grep -E '^[0-9]+$' | sort -n | tail -1 || true)
tag="$base-test$(( ${n:-0} + 1 ))"
notes=$(mktemp)
trap 'rm -f "$notes"' EXIT
if [ $# -ge 1 ]; then
    [ -f "$1" ] || die "no notes file: $1"
    cp "$1" "$notes"
else
    { echo "Test release from the $branch branch: not a finished release."; echo
      git log --no-merges --format='- %s' "$base..HEAD"; } > "$notes"
fi

git push -q origin "HEAD:refs/heads/$branch"
git tag -a "$tag" -F "$notes"
git push -q origin "refs/tags/$tag"
echo "tagged: $tag on $branch ($(git rev-parse --short HEAD))"

# ---------------------------------------------------------------- GitHub's build

run=""
for __ in $(seq 1 30); do
    run=$(gh run list -R "$repo" --workflow release.yml --branch "$tag" --limit 1 --json databaseId -q '.[0].databaseId' 2>/dev/null || true)
    [ -n "$run" ] && break
    sleep 5
done
[ -n "$run" ] || die "GitHub's release workflow didn't start for $tag"
gh run watch -R "$repo" "$run" --exit-status >/dev/null || die "the release workflow failed: gh run view -R $repo $run --log-failed"

assets=$(gh release view "$tag" -R "$repo" --json assets -q '.assets[].name')
pre=$(gh release view "$tag" -R "$repo" --json isPrerelease -q '.isPrerelease')
[ "$pre" = true ] || die "$tag isn't marked as a pre-release"
want="kindle-plugins.zip"
for d in optional/*.koplugin; do [ -d "$d" ] && want="$want kindle-$(basename "$d" .koplugin).zip"; done
for a in $want; do echo "$assets" | grep -qx "$a" || die "the release is missing $a"; done
echo "released: $tag (pre-release): $(echo $assets | tr '\n' ' ')"
echo "On the Kindle: Settings > Updates > Show test versions on, then Select version > $tag (test)"
