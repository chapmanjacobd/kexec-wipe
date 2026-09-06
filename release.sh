#!/bin/bash
#
# Cut a new release: rebuild wipe.sh, bump the version, commit, tag, and push.
#
# Usage:
#   ./release.sh            # bump the patch version (0.2.3 -> 0.2.4)
#   ./release.sh 0.3.0      # set an explicit version
#   ./release.sh --dry-run  # do everything except commit/tag/push
#
# The version lives in ./VERSION (no "v" prefix). The git tag is "v$VERSION".
# release.sh writes the new version to VERSION, runs build.sh (which bakes
# WIPE_VERSION into wipe.sh from VERSION), commits the built artifact and
# VERSION, tags with "v$VERSION", and pushes the commit and tag.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

DRY_RUN=0
NEW_VERSION=""

while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) DRY_RUN=1 ;;
        --help|-h) sed -n '2,12p' "$0"; exit 0 ;;
        [0-9]*.[0-9]*.[0-9]*) NEW_VERSION="$1" ;;
        *) echo "Unknown argument: $1" >&2; sed -n '2,12p' "$0"; exit 1 ;;
    esac
    shift
done

CUR_VERSION="$(cat VERSION)"

# Validate a candidate version (semver, optional leading 'v' which is stripped).
valid_version() {
    [[ "$1" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

bump_patch() {
    local major minor patch
    IFS=. read -r major minor patch <<<"${CUR_VERSION#v}"
    echo "$major.$minor.$((patch + 1))"
}

if [ -n "$NEW_VERSION" ]; then
    NEW_VERSION="${NEW_VERSION#v}"
    valid_version "$NEW_VERSION" || { echo "ERROR: not a valid version: $NEW_VERSION" >&2; exit 1; }
else
    NEW_VERSION="$(bump_patch)"
fi

if [ "$NEW_VERSION" = "${CUR_VERSION#v}" ]; then
    echo "ERROR: version already at $CUR_VERSION; nothing to release" >&2
    exit 1
fi

# Make sure we're on a clean tree that can be pushed.
git diff --quiet -- VERSION || { echo "ERROR: working tree has uncommitted VERSION changes" >&2; exit 1; }

echo "==> Releasing v$NEW_VERSION (was $CUR_VERSION)"

if [ "$DRY_RUN" -eq 1 ]; then
    echo "==> dry-run: skipping version write, build, commit, tag, push"
    echo "    NEW_VERSION=$NEW_VERSION"
    echo "    TAG=v$NEW_VERSION"
    exit 0
fi

echo "$NEW_VERSION" > VERSION
./build.sh

git add VERSION wipe.sh
git commit -m "release v$NEW_VERSION"
git tag "v$NEW_VERSION"
git push origin HEAD
git push origin "v$NEW_VERSION"

echo "==> Released v$NEW_VERSION"
