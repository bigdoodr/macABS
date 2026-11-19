#!/usr/bin/env bash
#
# next-version.sh <bump> [latest-tag]
#
# Prints the next app tag. <bump> is major | minor | patch.
# latest-tag defaults to the newest vX.Y[.Z] tag in this repo ("v0.0.0" if
# none). A two-part tag such as v1.2 counts as v1.2.0.
#
#   next-version.sh minor v1.3.0   ->  v1.4.0
#   next-version.sh patch v1.2     ->  v1.2.1

set -euo pipefail

bump="${1:?usage: next-version.sh <major|minor|patch> [latest-tag]}"
latest="${2:-$(git tag --list 'v[0-9]*' --sort=-version:refname | head -1)}"
latest="${latest:-v0.0.0}"

if ! [[ "${latest}" =~ ^v([0-9]+)\.([0-9]+)(\.([0-9]+))?$ ]]; then
    echo "ERROR: cannot parse tag '${latest}'" >&2
    exit 1
fi
major="${BASH_REMATCH[1]}"
minor="${BASH_REMATCH[2]}"
patch="${BASH_REMATCH[4]:-0}"

case "${bump}" in
    major) major=$((major + 1)); minor=0; patch=0 ;;
    minor) minor=$((minor + 1)); patch=0 ;;
    patch) patch=$((patch + 1)) ;;
    *) echo "ERROR: bump must be major, minor or patch (got '${bump}')" >&2; exit 1 ;;
esac

echo "v${major}.${minor}.${patch}"
