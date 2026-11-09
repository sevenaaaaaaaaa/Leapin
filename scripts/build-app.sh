#!/bin/bash
# Build Leapin.app + leapin into ./dist
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
APP="dist/Leapin.app"

echo "==> swift build -c ${CONFIG}"
swift build -c "${CONFIG}" --product LeapinApp
swift build -c "${CONFIG}" --product leapin
BIN="$(swift build -c "${CONFIG}" --show-bin-path)"

echo "==> assemble ${APP}"
rm -rf "${APP}"
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources"
cp "${BIN}/LeapinApp" "${APP}/Contents/MacOS/LeapinApp"
cp "${BIN}/leapin" "${APP}/Contents/MacOS/leapin"
cp scripts/Info.plist "${APP}/Contents/Info.plist"
if [ -f Assets/AppIcon.icns ]; then
    mkdir -p "${APP}/Contents/Resources"
    cp Assets/AppIcon.icns "${APP}/Contents/Resources/AppIcon.icns"
    /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "${APP}/Contents/Info.plist" 2>/dev/null \
      || /usr/libexec/PlistBuddy -c "Set :CFBundleIconFile AppIcon" "${APP}/Contents/Info.plist"
fi

# SwiftPM resource bundles (Leapin_LeapinRuntime.bundle etc.)
for b in "${BIN}"/*.bundle; do
    [ -e "$b" ] && cp -R "$b" "${APP}/Contents/Resources/"
done

# ad-hoc sign so the app launches without a developer account
codesign --force --deep --sign - "${APP}" >/dev/null 2>&1 || echo "warn: codesign failed (app still runnable locally)"
codesign -dv "${APP}" 2>&1 | head -3 || true

echo "==> done: ${APP}"
echo "   open dist/Leapin.app"
echo "   dist/Leapin.app/Contents/MacOS/leapin run"
