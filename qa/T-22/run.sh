#!/usr/bin/env bash
# T-22 验收：状态页做首页，第一屏三问（v5 构图：页头 / 焦点带 / 证据区）。
# 用法：bash qa/T-22/run.sh
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT" || { echo "FAIL C0  无法进入仓库"; exit 1; }

APP="Mobile/LeapinMobile"
DASH="$APP/Views/DashboardView.swift"
ROOTVIEW="$APP/LeapinMobileApp.swift"
SHOT="docs/shots/v5-ios-home.png"
SCRATCH="${T22_SCRATCH:-/tmp/m3-dd}"
LOGS="${T22_LOGDIR:-/tmp/t22-qa-logs}"
mkdir -p "$LOGS"

PASSED=0; FAILED=0
pass() { printf 'PASS %-3s %s\n' "$1" "$2"; PASSED=$((PASSED + 1)); }
fail() { printf 'FAIL %-3s %s\n' "$1" "$2"; FAILED=$((FAILED + 1)); }

for f in "$DASH" "$ROOTVIEW"; do
    [ -f "$f" ] || { echo "FAIL C0  缺少文件 $f"; exit 1; }
done

echo "T-22 验收 · 仓库 $ROOT"
echo "scratch=${SCRATCH} · 日志=$LOGS"
echo "----------------------------------------------------------------"

if (cd Mobile && xcodebuild -project LeapinMobile.xcodeproj -scheme LeapinMobile \
        -configuration Debug -sdk iphonesimulator \
        -destination 'generic/platform=iOS Simulator' \
        -derivedDataPath "${SCRATCH}" build \
        CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO >"$LOGS/c1-build.log" 2>&1); then
    pass C1 "xcodebuild → exit 0"
else
    fail C1 "xcodebuild 失败，见 $LOGS/c1-build.log"
fi

if grep -qF 'LPPageHeader(title: "这台手机的网络"' "$DASH"; then
    pass C2 "首页标题 = 这台手机的网络（v5 LPPageHeader）"
else
    fail C2 "首页标题不是「这台手机的网络」"
fi

missing=""
grep -qF 'FocusBand(eyebrow: "现在")' "$DASH" || missing="${missing} [焦点带]"
grep -qF 'LPFact(label: "系统代理"' "$DASH" || missing="${missing} [系统代理事实]"
grep -qF 'header: "Mac"' "$DASH" || missing="${missing} [Mac]"
if [ -z "${missing}" ]; then
    pass C3 "三问齐：焦点带（引擎/流量/系统代理）+ Mac 块"
else
    fail C3 "缺块：${missing}"
fi

addr=$(grep -cF '127.0.0.1:\(local.port)' "$DASH" || true)
mono=$(grep -c 'mono: ' "$DASH" || true)
if [ "${addr}" -ge 1 ] && [ "${mono}" -ge 2 ]; then
    pass C4 "端口出现在焦点带与页头，等宽处 ${mono} 个"
else
    fail C4 "端口或等宽缺失（addr=${addr} mono=${mono}）"
fi

dash_line=$(grep -n "DashboardView()" "$ROOTVIEW" | head -1 | cut -d: -f1)
tools_line=$(grep -n "ToolsView()" "$ROOTVIEW" | head -1 | cut -d: -f1)
tag0=$(grep -c "tag(0)" "$ROOTVIEW" || true)
if [ -n "${dash_line}" ] && [ -n "${tools_line}" ] && [ "${dash_line}" -lt "${tools_line}" ] && [ "${tag0}" -ge 1 ]; then
    pass C5 "状态页是第 1 个 tab（DashboardView:${dash_line} < ToolsView:${tools_line}）"
else
    fail C5 "tab 顺序不符（DashboardView=${dash_line} ToolsView=${tools_line} tag0=${tag0}）"
fi

if grep -qF "if let endpoint = store.endpoint" "$DASH" && grep -qF "未连接 Mac" "$DASH"; then
    pass C6 "未配对分支存在：Mac 块走 else 侧（未连接 Mac + 配对）"
else
    fail C6 "未配对分支缺失"
fi

old_cta=$(grep -cF 'title: "连接 Mac"' "$DASH" || true)
pair_btn=$(grep -cF "store.pairingSheetShown = true" "$DASH" || true)
if [ "${old_cta}" = "0" ] && [ "${pair_btn}" -ge 1 ]; then
    pass C7 "配对是次动作：配对按钮 ${pair_btn} 处，无唯一 CTA"
else
    fail C7 "配对仍是唯一动作（cta=${old_cta} pair=${pair_btn}）"
fi

if [ -f "${SHOT}" ]; then
    pass C8 "截图存在：${SHOT}"
else
    fail C8 "缺截图 ${SHOT}"
fi

echo "----------------------------------------------------------------"
echo "T-22 结果：${PASSED} PASS / ${FAILED} FAIL（C1 构建 · C2 标题 · C3 三问 · C4 端口 · C5 首页 tab · C6 未配对 · C7 次动作 · C8 截图）"
[ "${FAILED}" -eq 0 ] || exit 1
