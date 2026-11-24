#!/usr/bin/env bash
# T-22 验收：状态页做首页，第一屏三问（本机引擎 / 系统使用 / Mac）。
# 用法：bash qa/T-22/run.sh
# 只读仓库；构建产物落在 /tmp。任何一条 FAIL → 退出码 1。
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT" || { echo "FAIL C0  无法进入仓库"; exit 1; }

APP="Mobile/LeapinMobile"
DASH="$APP/Views/DashboardView.swift"
ROOTVIEW="$APP/LeapinMobileApp.swift"
SHOT="docs/shots/m3-home.png"
SCRATCH="${T22_SCRATCH:-/tmp/m3-dd}"
LOGS="${T22_LOGDIR:-/tmp/t22-qa-logs}"
mkdir -p "${LOGS}"

PASSED=0; FAILED=0
pass() { printf 'PASS %-3s %s\n' "$1" "$2"; PASSED=$((PASSED + 1)); }
fail() { printf 'FAIL %-3s %s\n' "$1" "$2"; FAILED=$((FAILED + 1)); }

for f in "$DASH" "$ROOTVIEW"; do
    [ -f "$f" ] || { echo "FAIL C0  缺少文件 $f"; exit 1; }
done

echo "T-22 验收 · 仓库 $ROOT"
echo "scratch=${SCRATCH} · 日志=${LOGS}"
echo "----------------------------------------------------------------"

# C1 构建
if (cd Mobile && xcodebuild -project LeapinMobile.xcodeproj -scheme LeapinMobile \
        -configuration Debug -sdk iphonesimulator \
        -destination 'generic/platform=iOS Simulator' \
        -derivedDataPath "${SCRATCH}" build \
        CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO >"${LOGS}/c1-build.log" 2>&1); then
    pass C1 "xcodebuild → exit 0"
else
    fail C1 "xcodebuild 失败，见 ${LOGS}/c1-build.log"
fi

# C2 大标题
if grep -qF 'navigationTitle("这台手机的网络")' "$DASH"; then
    pass C2 "首页标题 = 这台手机的网络"
else
    fail C2 "首页标题不是「这台手机的网络」"
fi

# C3 三块
missing=""
for h in '本机引擎' '系统使用' 'Mac'; do
    grep -qF "header: \"$h\"" "$DASH" || missing="${missing} [$h]"
done
if [ -z "${missing}" ]; then
    pass C3 "三块 header 齐：本机引擎 / 系统使用 / Mac"
else
    fail C3 "缺 header：${missing}"
fi

# C4 端口等宽
addr=$(grep -cF 'value: local.isRunning ? "127.0.0.1:" + String(local.port) : "—"' "$DASH" || true)
mono=$(grep -c 'mono: true' "$DASH" || true)
if [ "${addr}" -ge 1 ] && [ "${mono}" -ge 2 ]; then
    pass C4 "地址行存在且等宽（mono: true 共 ${mono} 处）"
else
    fail C4 "地址行或等宽缺失（addr=${addr} mono=${mono}）"
fi

# C5 首页 = 状态 tab
dash_line=$(grep -n 'DashboardView()' "$ROOTVIEW" | head -1 | cut -d: -f1)
tools_line=$(grep -n 'ToolsView()' "$ROOTVIEW" | head -1 | cut -d: -f1)
tag0=$(grep -c 'tag(0)' "$ROOTVIEW" || true)
if [ -n "${dash_line}" ] && [ -n "${tools_line}" ] && [ "${dash_line}" -lt "${tools_line}" ] && [ "${tag0}" -ge 1 ]; then
    pass C5 "状态页是第 1 个 tab（DashboardView:${dash_line} < ToolsView:${tools_line}，tag(0) ${tag0} 处）"
else
    fail C5 "tab 顺序不符（DashboardView=${dash_line} ToolsView=${tools_line} tag0=${tag0}）"
fi

# C6 未配对分支
if grep -qF 'if let endpoint = store.endpoint' "$DASH" && grep -qF '未连接 Mac' "$DASH"; then
    pass C6 "未配对分支存在：Mac 块走 else 侧（未连接 Mac + 配对）"
else
    fail C6 "未配对分支缺失"
fi

# C7 配对不再是唯一动作
old_cta=$(grep -cF 'title: "连接 Mac"' "$DASH" || true)
old_ports=$(grep -cF 'private var portsSection' "$DASH" || true)
pair_btn=$(grep -cF 'store.pairingSheetShown = true' "$DASH" || true)
if [ "${old_cta}" = "0" ] && [ "${old_ports}" = "0" ] && [ "${pair_btn}" -ge 1 ]; then
    pass C7 "配对是次动作：旧「连接 Mac」唯一 CTA 0 处、端口块已并走、配对按钮 ${pair_btn} 处"
else
    fail C7 "配对仍是唯一动作或旧结构残留（cta=${old_cta} ports=${old_ports} pair=${pair_btn}）"
fi

# C8 截图
if [ -f "${SHOT}" ]; then
    pass C8 "截图存在：${SHOT}"
else
    fail C8 "缺截图 ${SHOT}（跑 T-25 生成）"
fi

echo "----------------------------------------------------------------"
echo "T-22 结果：${PASSED} PASS / ${FAILED} FAIL（C1 构建 · C2 标题 · C3 三块 · C4 端口 · C5 首页 tab · C6 未配对 · C7 次动作 · C8 截图）"
[ "$FAILED" -eq 0 ] || exit 1
