#!/bin/bash
# Sets the version everywhere it is recorded.
#
#   scripts/bump-version.sh 1.2.0
#
# The build number is derived from the version when the app is built (scripts/build.sh).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
VERSION="${1:-}"
VERSION="${VERSION#v}"
if [[ ! "$VERSION" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]?)\.(0|[1-9][0-9]?)$ ]]; then
    echo "usage: scripts/bump-version.sh 1.2.0 (minor and patch must be below 100)" >&2
    exit 2
fi

PLIST="$ROOT/Resources/Info.plist"
# Edit the one string in place so the rest of the file keeps its formatting.
VERSION="$VERSION" perl -0pi -e 's{(<key>CFBundleShortVersionString</key>\s*<string>)[^<]*(</string>)}{$1$ENV{VERSION}$2}' "$PLIST"
plutil -lint "$PLIST" >/dev/null
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")" == "$VERSION" ]] || {
    echo "error: could not set the version in Resources/Info.plist" >&2
    exit 1
}

if ! grep -q "^## \[$VERSION\]" "$ROOT/CHANGELOG.md"; then
    echo "note: add a '## [$VERSION]' section to CHANGELOG.md before tagging."
fi
echo "Version set to $VERSION."
