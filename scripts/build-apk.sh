#!/bin/bash
# Build the Android console and copy a signed APK into ./dist.
#
#   ./scripts/build-apk.sh
#
# Needs: JDK 17 and an Android SDK (build-tools + a platform). Signing uses
# Android/keystore.properties when present; without it Gradle falls back to the
# debug key, which still installs but changes identity between machines.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"

export JAVA_HOME="${JAVA_HOME:-/opt/homebrew/opt/openjdk@17}"
export ANDROID_HOME="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
if [ ! -x "$JAVA_HOME/bin/java" ]; then
    echo "error: no JDK found. Set JAVA_HOME or install a JDK 17." >&2
    exit 1
fi
if [ ! -d "$ANDROID_HOME/platforms" ]; then
    echo "error: no Android SDK at $ANDROID_HOME. Set ANDROID_HOME." >&2
    exit 1
fi

# Gradle's own HTTP timeouts are minutes by default: on a dead network the build
# sits in timedFinishConnect instead of failing, and release.sh hangs there.
GRADLE_NET=(-Dorg.gradle.internal.http.connectionTimeout=15000
            -Dorg.gradle.internal.http.socketTimeout=20000)

echo "==> gradle assembleRelease"
# Offline first: the dependency cache is normally warm, and an offline build makes
# the same APK. Going online first means a dead network stalls the release in
# timedFinishConnect for minutes before the fallback even starts.
if ! (cd Android && ./gradlew assembleRelease --no-daemon --offline "${GRADLE_NET[@]}" >/tmp/leapin-apk-offline.log 2>&1); then
    echo "  ! offline build failed (cold dependency cache?), retrying online" >&2
    (cd Android && ./gradlew assembleRelease --no-daemon "${GRADLE_NET[@]}" >/tmp/leapin-apk.log 2>&1) || {
        echo "error: build failed; last lines of /tmp/leapin-apk.log:" >&2
        tail -25 /tmp/leapin-apk.log >&2
        echo "offline attempt:" >&2
        tail -25 /tmp/leapin-apk-offline.log >&2
        exit 1
    }
fi

APK="Android/app/build/outputs/apk/release/app-release.apk"
[ -f "$APK" ] || { echo "error: missing $APK" >&2; exit 1; }

AAPT="$(ls -d "$ANDROID_HOME"/build-tools/* 2>/dev/null | sort -V | tail -1)/aapt"
VERSION="1.0"
if [ -x "$AAPT" ]; then
    VERSION="$("$AAPT" dump badging "$APK" 2>/dev/null \
        | sed -n "s/.*versionName='\([^']*\)'.*/\1/p" | head -1)"
    VERSION="${VERSION:-1.0}"
    "$(dirname "$AAPT")/apksigner" verify "$APK" && echo "==> signature ok"
fi

mkdir -p "$ROOT/dist"
OUT="$ROOT/dist/LeapinMobile-Android-${VERSION}.apk"
cp "$APK" "$OUT"
echo "==> done: ${OUT#$ROOT/}"
ls -lh "$OUT"
