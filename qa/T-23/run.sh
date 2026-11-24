#!/usr/bin/env bash
# T-23 验收：固定端口 51003 + 一步接入引导。
# 用法：bash qa/T-23/run.sh
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT" || { echo "FAIL C0  无法进入仓库"; exit 1; }

ENGINE="Mobile/LeapinMobile/State/LocalProxyEngine.swift"
GUIDE="Mobile/LeapinMobile/Views/LocalProxyGuide.swift"
DASH="Mobile/LeapinMobile/Views/DashboardView.swift"
SHOT="docs/shots/m3-guide.png"
SCRATCH="${T23_SCRATCH:-/tmp/m3-dd}"
LOGS="${T23_LOGDIR:-/tmp/t23-qa-logs}"
mkdir -p "$LOGS"

PASSED=0; FAILED=0
pass() { printf 'PASS %-3s %s\n' "$1" "$2"; PASSED=$((PASSED + 1)); }
fail() { printf 'FAIL %-3s %s\n' "$1" "$2"; FAILED=$((FAILED + 1)); }

for f in "$ENGINE" "$GUIDE" "$DASH"; do
    [ -f "$f" ] || { echo "FAIL C0  缺少文件 $f"; exit 1; }
done

echo "T-23 验收 · 仓库 $ROOT"
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

port_const=$(grep -cF 'static let defaultPort: UInt16 = 51003' "$ENGINE" || true)
port_use=$(grep -cF 'port: Self.defaultPort' "$ENGINE" || true)
if [ "$port_const" -ge 1 ] && [ "$port_use" -ge 1 ]; then
    pass C2 "端口固定 51003：常量 ${port_const} 处、start 使用 ${port_use} 处"
else
    fail C2 "端口未固定（const=${port_const} use=${port_use}）"
fi

auto=$(awk '/init\(\) \{/,/^    \}/' "$ENGINE" | grep -c '^        start()' || true)
if [ "$auto" -ge 1 ]; then
    pass C3 "init 自动启动引擎（非 DEBUG 分支 start() ${auto} 处）"
else
    fail C3 "init 没有自动启动"
fi

entry=$(grep -cF '把这台手机的 Wi-Fi 代理指过来' "$DASH" || true)
if [ "$entry" -ge 1 ]; then
    pass C4 "首页有引导入口（${entry} 处）"
else
    fail C4 "首页没有引导入口"
fi

copy=$(grep -cF 'UIPasteboard.general.string' "$GUIDE" || true)
steps=$(grep -cF '无线局域网' "$GUIDE" || true)
manual=$(grep -cF '配置代理' "$GUIDE" || true)
store=$(grep -cF '存储' "$GUIDE" || true)
if [ "$copy" -ge 1 ] && [ "$steps" -ge 1 ] && [ "$manual" -ge 1 ] && [ "$store" -ge 1 ]; then
    pass C5 "引导含复制与五步（复制 ${copy} · 无线局域网 ${steps} · 配置代理 ${manual} · 存储 ${store}）"
else
    fail C5 "引导缺要素（copy=${copy} lan=${steps} manual=${manual} store=${store}）"
fi

check=$(grep -cF 'selfCheck' "$GUIDE" || true)
verified=$(grep -cF '已验证' "$DASH" || true)
if [ "$check" -ge 1 ] && [ "$verified" -ge 1 ]; then
    pass C6 "自检闭环：引导调用 selfCheck ${check} 处，首页显示「已验证」${verified} 处"
else
    fail C6 "自检闭环缺失（check=${check} verified=${verified}）"
fi

if [ -f "$SHOT" ]; then
    pass C7 "截图存在：$SHOT"
else
    fail C7 "缺截图 $SHOT"
fi

echo "----------------------------------------------------------------"
echo "T-23 结果：${PASSED} PASS / ${FAILED} FAIL（C1 构建 · C2 端口 · C3 自动启动 · C4 入口 · C5 五步 · C6 自检 · C7 截图）"
[ "$FAILED" -eq 0 ] || exit 1
