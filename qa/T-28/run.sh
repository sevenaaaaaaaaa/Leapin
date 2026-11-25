#!/usr/bin/env bash
# T-28 验收：三端视觉对齐——同一套 token、同一个 RouteLine、同一个页头。
# 用法：bash qa/T-28/run.sh
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT" || { echo "FAIL C0  无法进入仓库"; exit 1; }

IOS_KIT="Mobile/LeapinMobile/Design/RouteKit.swift"
AND_KIT="Android/app/src/main/java/app/leapin/mobile/ui/RouteKit.kt"
MAC_KIT="Sources/LeapinApp/Design/RouteLine.swift"
MAC_THEME="Sources/LeapinApp/Design/Theme.swift"

PASSED=0; FAILED=0
pass() { printf 'PASS %-3s %s\n' "$1" "$2"; PASSED=$((PASSED + 1)); }
fail() { printf 'FAIL %-3s %s\n' "$1" "$2"; FAILED=$((FAILED + 1)); }

echo "T-28 验收 · 三端视觉对齐"
echo "----------------------------------------------------------------"

for f in "$IOS_KIT" "$AND_KIT" "$MAC_KIT" "$MAC_THEME"; do
    [ -f "$f" ] || { echo "FAIL C0  缺少文件 $f"; exit 1; }
done

[ -f "$IOS_KIT" ] && grep -q "struct RouteLine" "$IOS_KIT" && grep -q "struct FocusBand" "$IOS_KIT" && grep -q "struct LPPageHeader" "$IOS_KIT" \
    && pass C1 "iOS RouteKit：RouteLine / FocusBand / LPPageHeader" \
    || fail C1 "iOS RouteKit 组件缺"

[ -f "$AND_KIT" ] && grep -q "fun RouteLine" "$AND_KIT" && grep -q "fun FocusBand" "$AND_KIT" && grep -q "fun PageHeader" "$AND_KIT" \
    && pass C2 "Android RouteKit：RouteLine / FocusBand / PageHeader" \
    || fail C2 "Android RouteKit 组件缺"

grep -q "struct RouteLine" "$MAC_KIT" && grep -q "struct FocusBand" Sources/LeapinApp/Design/FocusBand.swift && grep -q "struct PageHeader" "$MAC_THEME" \
    && pass C3 "macOS：RouteLine / FocusBand / PageHeader" \
    || fail C3 "macOS 组件缺"

ios_pages=0
for f in DashboardView ConnectionsView PoliciesView DiagnosticsView ToolsView; do
    grep -q "LPPageHeader(" "Mobile/LeapinMobile/Views/$f.swift" && ios_pages=$((ios_pages + 1))
done
[ "$ios_pages" -eq 5 ] && pass C4 "iOS 五页都用 LPPageHeader（${ios_pages}/5）" \
    || fail C4 "iOS 只有 ${ios_pages}/5 页用了页头"

and_pages=0
for f in DashboardScreen ConnectionsScreen PoliciesScreen DiagnosticsScreen ToolsScreen; do
    grep -q "PageHeader(" "Android/app/src/main/java/app/leapin/mobile/ui/$f.kt" && and_pages=$((and_pages + 1))
done
[ "$and_pages" -eq 5 ] && pass C5 "Android 五屏都用 PageHeader（${and_pages}/5）" \
    || fail C5 "Android 只有 ${and_pages}/5 屏用了页头"

ios_accent=$(grep -c "0xC63A12" Mobile/LeapinMobile/Design/MobileTheme.swift || true)
and_accent=$(grep -c "0xFFC63A12" Android/app/src/main/java/app/leapin/mobile/ui/Theme.kt || true)
mac_accent=$(grep -c "0xC63A12" "$MAC_THEME" || true)
if [ "$ios_accent" -ge 1 ] && [ "$and_accent" -ge 1 ] && [ "$mac_accent" -ge 1 ]; then
    pass C6 "同一支朱红：macOS/iOS 0xC63A12、Android 0xFFC63A12"
else
    fail C6 "朱红不一致（mac=${mac_accent} ios=${ios_accent} and=${and_accent}）"
fi

apk=$(ls Android/app/build/outputs/apk/debug/*.apk 2>/dev/null | head -1)
[ -n "$apk" ] && pass C7 "Android APK 产物存在：$apk" || fail C7 "没有 Android APK 产物"

echo "----------------------------------------------------------------"
echo "T-28 结果：${PASSED} PASS / ${FAILED} FAIL（C1 iOS · C2 Android · C3 macOS · C4 iOS 五页 · C5 Android 五屏 · C6 朱红 · C7 APK）"
[ "$FAILED" -eq 0 ] || exit 1
