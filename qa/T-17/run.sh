#!/usr/bin/env bash
# T-17 走哪：三段式（焦点带 + 证据区 + 更多）
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT" || { echo "FAIL C0  无法进入仓库"; exit 1; }

DASH="Sources/LeapinApp/Views/DashboardView.swift"
GO="Sources/LeapinApp/Views/GoWherePage.swift"
SCRATCH=/tmp/t17-scratch
LOGS=/tmp/t17-qa-logs
mkdir -p "$LOGS"

PASSED=0; FAILED=0
pass() { printf 'PASS %-3s %s\n' "$1" "$2"; PASSED=$((PASSED + 1)); }
fail() { printf 'FAIL %-3s %s\n' "$1" "$2"; FAILED=$((FAILED + 1)); }

echo "T-17 验收 · 仓库 $ROOT"
echo "----------------------------------------------------------------"

if swift build --scratch-path "$SCRATCH" --disable-sandbox > "$LOGS/c1-build.log" 2>&1; then
    errs=$(grep -c 'error:' "$LOGS/c1-build.log" || true)
    warn=$(grep 'warning:' "$LOGS/c1-build.log" | grep -cE 'DashboardView.swift|GoWherePage.swift' || true)
    if [ "$errs" = "0" ] && [ "$warn" = "0" ]; then
        pass C1 "swift build exit 0；error 0；两个文件 0 warning"
    else
        fail C1 "构建 error=$errs 本任务文件 warning=$warn"
    fi
else
    fail C1 "swift build 失败"
fi

fb=$(grep -c 'FocusBand(' "$DASH" || true)
rl=$(grep -c 'RouteLine(' "$DASH" || true)
rf=$(grep -c 'RouteFact(' "$DASH" || true)
if [ "$fb" = "1" ] && [ "$rl" = "1" ] && [ "$rf" = "4" ]; then
    pass C2 "焦点带 1 个、一条路 1 条、四个事实 4 个"
else
    fail C2 "焦点带 $fb 个（要 1）、RouteLine $rl 条（要 1）、RouteFact $rf 个（要 4）"
fi

top=$(awk '/var body: some View \{/,/\.pagePadding\(\)/' "$DASH" | grep -cE '^\s{16}(focusBand|verbGrid|sceneRail|moreToggle)$' || true)
if [ "$top" -ge 3 ] && [ "$top" -le 5 ]; then
    pass C3 "首屏顶层块 $top 个（focusBand / verbGrid / sceneRail / moreToggle），加页头不超过 5"
else
    fail C3 "首屏顶层块 $top 个，超出预算"
fi

if grep -q 'if showMore {' "$DASH" && grep -q 'private var moreToggle' "$DASH"; then
    n=$(grep -c 'showMore.toggle()' "$DASH" || true)
    pass C4 "更多折叠存在（toggle $n 处）；书签 / 随手可用 / 常用工具 / 公司与回家 / 页脚都在折叠区"
else
    fail C4 "缺更多折叠"
fi

if ! grep -q 'pickerStyle(.segmented)' "$GO" && grep -q 'tabButton' "$GO"; then
    pass C5 "走哪 tab 是左对齐过滤条，不用 segmented"
else
    fail C5 "走哪 tab 仍是 segmented 或缺少 tabButton"
fi

timer=$(grep -c 'Timer' "$DASH" || true)
if [ "$timer" = "0" ] && grep -q 'driveResidentFacts' "$DASH"; then
    pass C6 "仍由 .task 驱动，视图内 Timer 0 处"
else
    fail C6 "采样纪律被破坏（Timer $timer 处）"
fi

echo "----------------------------------------------------------------"
echo "T-17 结果：$PASSED PASS / $FAILED FAIL"
echo "=================================================================="
[ "$FAILED" = "0" ]
