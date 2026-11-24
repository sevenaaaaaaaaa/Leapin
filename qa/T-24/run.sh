#!/usr/bin/env bash
# T-24 验收：未配对三页给出原因与替代动作；去掉 VPN 暗示；命名与 Mac 一致。
# 用法：bash qa/T-24/run.sh
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT" || { echo "FAIL C0  无法进入仓库"; exit 1; }

MOBILE="Mobile/LeapinMobile"
CONN="$MOBILE/Views/ConnectionsView.swift"
POL="$MOBILE/Views/PoliciesView.swift"
DIAG="$MOBILE/Views/DiagnosticsView.swift"
TOOLS="$MOBILE/Views/ToolsView.swift"
SETTINGS="$MOBILE/Views/SettingsView.swift"
SCRATCH="${T24_SCRATCH:-/tmp/m3-dd}"
LOGS="${T24_LOGDIR:-/tmp/t24-qa-logs}"
mkdir -p "$LOGS"

PASSED=0; FAILED=0
pass() { printf 'PASS %-3s %s\n' "$1" "$2"; PASSED=$((PASSED + 1)); }
fail() { printf 'FAIL %-3s %s\n' "$1" "$2"; FAILED=$((FAILED + 1)); }

for f in "$CONN" "$POL" "$DIAG" "$TOOLS" "$SETTINGS"; do
    [ -f "$f" ] || { echo "FAIL C0  缺少文件 $f"; exit 1; }
done

echo "T-24 验收 · 仓库 $ROOT"
echo "scratch=$SCRATCH · 日志=$LOGS"
echo "----------------------------------------------------------------"

if (cd Mobile && xcodebuild -project LeapinMobile.xcodeproj -scheme LeapinMobile \
        -configuration Debug -sdk iphonesimulator \
        -destination 'generic/platform=iOS Simulator' \
        -derivedDataPath "$SCRATCH" build \
        CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO >"$LOGS/c1-build.log" 2>&1); then
    pass C1 "xcodebuild → exit 0"
else
    fail C1 "xcodebuild 失败，见 $LOGS/c1-build.log"
fi

conn_guide=$(grep -cF '怎么设置系统代理' "$CONN" || true)
conn_sheet=$(grep -cF 'LocalProxyGuide' "$CONN" || true)
if [ "$conn_guide" -ge 1 ] && [ "$conn_sheet" -ge 1 ]; then
    pass C2 "连接页未配对有替代动作（设置引导 ${conn_guide} 处、guide sheet ${conn_sheet} 处）"
else
    fail C2 "连接页缺替代动作（guide=${conn_guide} sheet=${conn_sheet}）"
fi

pol_card=$(grep -cF '未配对时的走法' "$POL" || true)
pol_pair=$(grep -cF '配对 Mac' "$POL" || true)
if [ "$pol_card" -ge 1 ] && [ "$pol_pair" -ge 1 ]; then
    pass C3 "策略页未配对有说明与动作（走法卡 ${pol_card} 处、配对 ${pol_pair} 处）"
else
    fail C3 "策略页未配对仍空白（card=${pol_card} pair=${pol_pair}）"
fi

diag_local=$(grep -cF '本机连通性' "$DIAG" || true)
diag_note=$(grep -cF '下面三个工具需要 Mac' "$DIAG" || true)
if [ "$diag_local" -ge 1 ] && [ "$diag_note" -ge 1 ]; then
    pass C4 "诊断页未配对有本机连通性与原因（${diag_local} / ${diag_note}）"
else
    fail C4 "诊断页缺本机连通性（local=${diag_local} note=${diag_note}）"
fi

installed=$(grep -cF 'if tunnel.isInstalled' "$TOOLS" || true)
plain=$(grep -cF '未安装 · 需要付费开发者账号' "$TOOLS" || true)
toggle_after=$(grep -A12 '未安装 · 需要付费开发者账号' "$TOOLS" | grep -c 'Toggle(' || true)
if [ "$installed" -ge 1 ] && [ "$plain" -ge 1 ] && [ "$toggle_after" = "0" ]; then
    pass C5 "系统接管未安装时是说明不是开关（isInstalled 分支 ${installed}、说明行 ${plain}、其后 Toggle ${toggle_after}）"
else
    fail C5 "系统接管行仍像开关（branch=${installed} plain=${plain} toggle=${toggle_after}）"
fi

vpn_claims=$(grep -rn 'VPN 已连接\|VPN 已开启' "$MOBILE" --include=*.swift | wc -l | tr -d ' ')
takeover_files=$(grep -rl '已接管' "$MOBILE" --include=*.swift | sort | tr '\n' ' ')
if [ "$vpn_claims" = "0" ] && [ "$takeover_files" = "Mobile/LeapinMobile/State/TunnelManager.swift " ]; then
    pass C6 "文案扫描：0 处 VPN 已连接；「已接管」只在 TunnelManager 的 connected 分支（${takeover_files}）"
else
    fail C6 "文案越界（vpn=${vpn_claims} takeover=${takeover_files}）"
fi

old_claim=$(grep -cF '不代理手机流量' "$SETTINGS" || true)
new_claim=$(grep -cF '监听 127.0.0.1:51003' "$SETTINGS" || true)
if [ "$old_claim" = "0" ] && [ "$new_claim" -ge 1 ]; then
    pass C7 "设置页不再说「不代理手机流量」，改为事实描述"
else
    fail C7 "设置页文案未更正（old=${old_claim} new=${new_claim}）"
fi

lines=$(grep -rn '线路' "$MOBILE" --include=*.swift | wc -l | tr -d ' ')
groups=$(grep -rl '策略组' "$MOBILE" --include=*.swift | wc -l | tr -d ' ')
if [ "$lines" = "0" ] && [ "$groups" -ge 1 ]; then
    pass C8 "命名与 Mac 一致：0 处「线路」、策略组 ${groups} 个文件"
else
    fail C8 "命名不一致（线路=${lines} 策略组=${groups}）"
fi

shot_ok=0
for s in m3-connections m3-policies m3-diagnostics; do
    [ -f "docs/shots/${s}.png" ] && shot_ok=$((shot_ok + 1))
done
if [ "$shot_ok" -eq 3 ]; then
    pass C9 "三页截图齐"
else
    fail C9 "截图缺 ${shot_ok}/3"
fi

echo "----------------------------------------------------------------"
echo "T-24 结果：${PASSED} PASS / ${FAILED} FAIL（C1 构建 · C2 连接 · C3 策略 · C4 诊断 · C5 接管行 · C6 文案 · C7 设置页 · C8 命名 · C9 截图）"
[ "$FAILED" -eq 0 ] || exit 1
