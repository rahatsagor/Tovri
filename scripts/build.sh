#!/bin/bash
# Builds Tovri.app (arm64) into build/Release/ or build/Debug/.
#
#   scripts/build.sh [--version 1.2.3] [--debug]
#
# Environment:
#   TOVRI_SIGN_IDENTITY  Code signing identity name. Defaults to "Tovri Self-Signed"
#                        when that identity exists (see scripts/make-signing-identity.sh),
#                        otherwise ad-hoc ("-").
#   TOVRI_KEYCHAIN       Keychain holding the identity (optional).
#   TOVRI_UPDATE_KEY     Sparkle EdDSA public key. Without it the build never checks
#                        for updates.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
CONFIGURATION=Release
VERSION=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --version)
            [[ $# -ge 2 ]] || { echo "error: --version needs a value, like 1.2.3" >&2; exit 2; }
            VERSION="${2#v}"; shift 2 ;;
        --debug) CONFIGURATION=Debug; shift ;;
        -h|--help) sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done

if [[ -z "$VERSION" ]]; then
    VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/Resources/Info.plist")"
fi
if [[ ! "$VERSION" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]?)\.(0|[1-9][0-9]?)$ ]]; then
    echo "error: use a version like 1.2.3 with minor and patch numbers below 100 (got '$VERSION')" >&2
    exit 2
fi
# Sparkle compares build numbers, so derive one that always increases.
BUILD=$(( BASH_REMATCH[1] * 10000 + BASH_REMATCH[2] * 100 + BASH_REMATCH[3] ))

UPDATE_KEY="${TOVRI_UPDATE_KEY:-}"
if [[ -n "$UPDATE_KEY" ]]; then
    if [[ ! "$UPDATE_KEY" =~ ^[A-Za-z0-9+/]{43}=$ ]] || [[ "$(printf '%s' "$UPDATE_KEY" | base64 -D | wc -c | tr -d ' ')" != 32 ]]; then
        echo "error: TOVRI_UPDATE_KEY must be the base64 Sparkle public key from generate_keys -p" >&2
        exit 2
    fi
fi

for tool in swift codesign ditto; do
    command -v "$tool" >/dev/null || { echo "error: $tool is required; install Xcode (see CONTRIBUTING.md)" >&2; exit 1; }
done

echo "==> Building Tovri $VERSION ($BUILD), $CONFIGURATION"
cd "$ROOT"
mkdir -p build
if [[ ! -f Resources/AppIcon.icns ]] || [[ scripts/make-icon.swift -nt Resources/AppIcon.icns ]]; then
    swift scripts/make-icon.swift Resources/AppIcon.icns
fi

SWIFT_CONFIG="$(echo "$CONFIGURATION" | tr '[:upper:]' '[:lower:]')"
LOG="$ROOT/build/swift-build.log"
if ! swift build -c "$SWIFT_CONFIG" --arch arm64 >"$LOG" 2>&1; then
    grep -E "error:" "$LOG" | sort -u | head -40 >&2 || true
    echo "error: swift build failed; full log in $LOG" >&2
    exit 1
fi
grep -E "\.swift:[0-9]+:[0-9]+: warning:" "$LOG" | sort -u || true
BIN_DIR="$(swift build -c "$SWIFT_CONFIG" --arch arm64 --show-bin-path)"
[[ -d "$BIN_DIR/Sparkle.framework" ]] || { echo "error: Sparkle.framework is missing from $BIN_DIR" >&2; exit 1; }

OUT="$ROOT/build/$CONFIGURATION"
mkdir -p "$OUT"
STAGING="$(mktemp -d "$OUT/.tovri-build.XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT
APP="$STAGING/Tovri.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN_DIR/Tovri" "$APP/Contents/MacOS/Tovri"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp scripts/tovri "$APP/Contents/Resources/tovri"
chmod +x "$APP/Contents/Resources/tovri"
# ditto keeps the framework's Versions/Current symlinks intact.
ditto "$BIN_DIR/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"

PLIST="$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :SUPublicEDKey $UPDATE_KEY" "$PLIST"

EXECUTABLE="$APP/Contents/MacOS/Tovri"
# SwiftPM also adds rpaths into the toolchain that built the app. Only Sparkle loads through
# @rpath, and an rpath outside the bundle would let whatever sits at that path supply it.
otool -l "$EXECUTABLE" | awk '$1 == "cmd" && $2 == "LC_RPATH" { rpath = 1; next }
    rpath && $1 == "path" { sub(/^ *path /, ""); sub(/ \(offset [0-9]+\)$/, ""); print; rpath = 0 }' |
    while IFS= read -r path; do
        case "$path" in
            /usr/lib/swift|@executable_path/../Frameworks) ;;
            *) install_name_tool -delete_rpath "$path" "$EXECUTABLE" 2>/dev/null ;;
        esac
    done
# Outputs are read into variables first: with pipefail, grep -q closing a pipe early could
# fail the command that writes to it.
LOAD_COMMANDS="$(otool -l "$EXECUTABLE")"
if ! grep -q "path @executable_path/../Frameworks " <<<"$LOAD_COMMANDS"; then
    install_name_tool -add_rpath "@executable_path/../Frameworks" "$EXECUTABLE"
fi
UNBUNDLED="$(otool -L "$EXECUTABLE" | grep "@rpath/" | grep -v "@rpath/Sparkle.framework/" || true)"
if [[ -n "$UNBUNDLED" ]]; then
    echo "error: the app links a library through @rpath that isn't bundled:" >&2
    echo "$UNBUNDLED" >&2
    exit 1
fi
if [[ "$CONFIGURATION" == Release ]]; then
    strip -x "$EXECUTABLE"
fi

# A stable signing identity keeps macOS privacy permissions (such as access to Desktop,
# Documents or removable volumes) across updates: macOS ties them to the signature, and
# ad-hoc signatures change with every build.
IDENTITY="${TOVRI_SIGN_IDENTITY:-}"
KEYCHAIN_ARGS=()
if [[ -n "${TOVRI_KEYCHAIN:-}" ]]; then KEYCHAIN_ARGS=(--keychain "$TOVRI_KEYCHAIN"); fi
if [[ -z "$IDENTITY" ]]; then
    IDENTITIES="$(security find-identity -p codesigning ${TOVRI_KEYCHAIN:+"$TOVRI_KEYCHAIN"} 2>/dev/null || true)"
    if grep -q '"Tovri Self-Signed"' <<<"$IDENTITIES"; then
        IDENTITY="Tovri Self-Signed"
    else
        IDENTITY="-"
        echo "warning: signing ad-hoc. Run scripts/make-signing-identity.sh so macOS remembers Tovri's permissions between builds." >&2
    fi
fi

sign() { codesign --force --timestamp=none ${KEYCHAIN_ARGS[@]+"${KEYCHAIN_ARGS[@]}"} --sign "$IDENTITY" "$@"; }
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
# Inside-out, as Sparkle's documentation describes for re-signing. The app's entitlements turn
# off library validation: a self-signed identity has no Team ID, so the hardened runtime would
# otherwise refuse Sparkle.framework.
sign --options runtime "$SPARKLE/XPCServices/Installer.xpc"
sign --options runtime --preserve-metadata=entitlements "$SPARKLE/XPCServices/Downloader.xpc"
sign --options runtime "$SPARKLE/Autoupdate"
sign --options runtime "$SPARKLE/Updater.app"
sign --options runtime "$APP/Contents/Frameworks/Sparkle.framework"
sign --options runtime --entitlements "$ROOT/Resources/Tovri.entitlements" "$APP"
codesign --verify --deep --strict "$APP"

rm -rf "$OUT/Tovri.app"
mv "$APP" "$OUT/Tovri.app"
APP="$OUT/Tovri.app"
echo "==> $APP ($(du -sh "$APP" | cut -f1))"
echo "    signed with: $IDENTITY"
if [[ -z "$UPDATE_KEY" ]]; then
    echo "    updates: off (no TOVRI_UPDATE_KEY)"
fi
