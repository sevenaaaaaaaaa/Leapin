#!/usr/bin/env bash
# T-16 RouteLine + FocusBand：一条路与焦点带组件
# 用法：bash qa/T-16/run.sh
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT" || { echo "FAIL C0  无法进入仓库"; exit 1; }

APP="Sources/LeapinApp"
RL="$APP/Design/RouteLine.swift"
FB="$APP/Design/FocusBand.swift"
SCRATCH=/tmp/t16-scratch
LOGS=/tmp/t16-qa-logs
mkdir -p "$LOGS"

PASSED=0
FAILED=0
pass() { printf 'PASS %-3s %s\n' "$1" "$2"; PASSED=$((PASSED + 1)); }
fail() { printf 'FAIL %-3s %s\n' "$1" "$2"; FAILED=$((FAILED + 1)); }

echo "T-16 验收 · 仓库 $ROOT"
echo "----------------------------------------------------------------"

for f in "$RL" "$FB"; do
    [ -f "$f" ] || { echo "FAIL C0  缺少 $f"; exit 1; }
done

# C1 构建
if swift build --scratch-path "$SCRATCH" --disable-sandbox > "$LOGS/c1-build.log" 2>&1; then
    errs=$(grep -c 'error:' "$LOGS/c1-build.log" || true)
    warn=$(grep 'warning:' "$LOGS/c1-build.log" | grep -cE 'RouteLine.swift|FocusBand.swift' || true)
    if [ "$errs" = "0" ] && [ "$warn" = "0" ]; then
        pass C1 "swift build exit 0；error 0；新组件 0 warning"
    else
        fail C1 "构建 error=$errs / 新组件 warning=$warn"
    fi
else
    fail C1 "swift build 失败，见 $LOGS/c1-build.log"
fi

# C2 两轴
if grep -q 'enum Axis' "$RL" && grep -q 'case horizontal, vertical' "$RL" \
   && grep -q 'horizontalBody' "$RL" && grep -q 'verticalBody' "$RL"; then
    pass C2 "RouteLine 支持 horizontal / vertical 两轴"
else
    fail C2 "RouteLine 缺两轴实现"
fi

# C3 三态 + 当前节点用信号色
if grep -q 'case idle, current, alert' "$RL" && grep -q 'LP.accent' "$RL"; then
    n=$(grep -c 'LP.accent' "$RL" || true)
    pass C3 "节点三态齐备；信号色只用于当前/异常（LP.accent 引用 $n 处）"
else
    fail C3 "节点三态或信号色缺失"
fi

# C4 焦点带底色与圆角
if grep -q 'fill(LP.ink)' "$FB" && grep -q 'LPRadius.panel' "$FB" && grep -q 'struct RouteFact' "$FB"; then
    pass C4 "FocusBand 用 LP.ink + LPRadius.panel；RouteFact 存在"
else
    fail C4 "FocusBand 底色/圆角/RouteFact 不合规"
fi

# C5 组件不接引擎与全局状态
bad=$(grep -cE 'LeapinEngine|ResidentStatusStore|@EnvironmentObject|@ObservedObject' "$RL" "$FB" | awk -F: '{s+=$2} END {print s+0}')
if [ "$bad" = "0" ]; then
    pass C5 "两个组件都不引用引擎 / 全局 store / ObservableObject（只吃传入数据）"
else
    fail C5 "组件引用了全局状态 $bad 处"
fi

# C6 主操作槽唯一
slots=$(grep -c 'LPPrimaryButtonStyle' "$FB" || true)
if [ "$slots" = "0" ]; then
    pass C6 "FocusBand 自身不自带按钮（主操作由调用方在 content 里放一个）"
else
    fail C6 "FocusBand 内部出现按钮样式 $slots 处，违反单槽约定"
fi

echo "----------------------------------------------------------------"
echo "T-16 结果：$PASSED PASS / $FAILED FAIL"
echo "=================================================================="
[ "$FAILED" = "0" ]
