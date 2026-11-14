#!/bin/bash
# Build Leapin Mobile and package an unsigned .ipa into ./dist.
#
#   ./Mobile/build-ios.sh            # release build + ipa
#   ./Mobile/build-ios.sh debug      # debug build (no ipa)
#   ./Mobile/build-ios.sh sim        # simulator build only
#
# The.ipa is unsigned on purpose: no Apple developer account is needed to produce
# it, and a sideloading tool (Sideloadly / AltStore) signs it with your own Apple ID.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"

MODE="${1:-release}"
if ! command -v xcodegen >/dev/null 2>&1; then
    echo "error: xcodegen is required (brew install xcodegen)" >&2
    exit 1
fi

echo "==> xcodegen"
(cd Mobile && xcodegen generate >/dev/null)

case "$MODE" in
    sim)
        echo "==> simulator build"
        xcodebuild -project Mobile/LeapinMobile.xcodeproj -scheme LeapinMobile \
            -configuration Debug -destination 'generic/platform=iOS Simulator' \
            -derivedDataPath "$ROOT/Mobile/build" build | tail -5
        echo "==> done (simulator)"
        exit 0
        ;;
esac

CONFIG="Release"
[ "$MODE" = "debug" ] && CONFIG="Debug"

echo "==> xcodebuild ($CONFIG, device, unsigned)"
xcodebuild -project Mobile/LeapinMobile.xcodeproj -scheme LeapinMobile \
    -configuration "$CONFIG" -destination 'generic/platform=iOS' \
    -derivedDataPath "$ROOT/Mobile/build" \
    CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO \
    build | tail -5

APP="$ROOT/Mobile/build/Build/Products/$CONFIG-iphoneos/Leapin.app"
[ -d "$APP" ] || { echo "error: build product missing at $APP" >&2; exit 1; }

if [ "$MODE" = "debug" ]; then
    echo "==> done: $APP (debug, not packaged)"
    exit 0
fi

echo "==> package ipa"
mkdir -p "$ROOT/dist"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/Payload"
cp -R "$APP" "$STAGE/Payload/"
(cd "$STAGE" && zip -qry "$ROOT/dist/LeapinMobile-1.0-unsigned.ipa" Payload)

echo "==> done: dist/LeapinMobile-1.0-unsigned.ipa"
echo "   install: Sideloadly / AltStore, sign with your own Apple ID"
