#!/usr/bin/env bash
# T-18 验收：「怎么判」+「改成什么」两页改成表为主、左对齐过滤条、单一主按钮。
# 用法：bash qa/T-18/run.sh
# 只读仓库；任何一条 FAIL → 退出码 1。
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT" || { echo "FAIL C0  无法进入仓库"; exit 1; }

RULES="Sources/LeapinApp/Views/RulesView.swift"
REWRITE="Sources/LeapinApp/Views/RewriteView.swift"
DECK="Sources/LeapinApp/Views/RewriteDeck.swift"
SCRATCH="${T18_SCRATCH:-/tmp/t18-scratch}"
LOGS="${T18_LOGDIR:-/tmp/t18-qa-logs}"
mkdir -p "$LOGS"

PASSED=0; FAILED=0
pass() { printf 'PASS %-3s %s\n' "$1" "$2"; PASSED=$((PASSED + 1)); }
fail() { printf 'FAIL %-3s %s\n' "$1" "$2"; FAILED=$((FAILED + 1)); }

for f in "$RULES" "$REWRITE" "$DECK"; do
    [ -f "$f" ] || { echo "FAIL C0  缺少文件 $f"; exit 1; }
done

echo "T-18 验收 · 仓库 $ROOT"
echo "scratch=${SCRATCH} · 日志=${LOGS}"
echo "----------------------------------------------------------------"

# C1 构建：两页都不能有新增 warning
build_log="$LOGS/c1-build.log"
swift build --scratch-path "$SCRATCH" --disable-sandbox >"$build_log" 2>&1
rc=$?
errs=$(grep -c 'error:' "$build_log" || true)
task_warns=$(grep -E 'warning:' "$build_log" | grep -cE 'RulesView\.swift|RewriteView\.swift' || true)
if [ "$rc" -eq 0 ] && [ "$errs" -eq 0 ] && [ "$task_warns" -eq 0 ]; then
    pass C1 "swift build --scratch-path ${SCRATCH} → exit 0；error ${errs} 个；本任务两个文件 warning ${task_warns} 个（要求 0）"
else
    fail C1 "swift build 退出码 ${rc}；error ${errs}；本任务文件 warning ${task_warns}；首个错误：$(grep -m1 'error:' "$build_log" || echo 无)"
fi

# C2 没有居中悬浮 tab；两页都是左对齐过滤条
segmented=$(cat "$RULES" "$REWRITE" | grep -cF '.pickerStyle(.segmented)' || true)
rewrite_chips=$(grep -cF 'LPChip(title: kind.title, selected: tab == kind)' "$REWRITE" || true)
rewrite_kinds=$(grep -cF 'ForEach(RewriteDeck.Kind.allCases)' "$REWRITE" || true)
rules_chips=$(grep -cF 'LPChip(title: option.title' "$RULES" || true)
centered=$(grep -cF 'frame(maxWidth: 420)' "$REWRITE" || true)
if [ "$segmented" -eq 0 ] && [ "$rewrite_chips" -eq 1 ] && [ "$rewrite_kinds" -eq 1 ] \
   && [ "$rules_chips" -eq 1 ] && [ "$centered" -eq 0 ]; then
    pass C2 "两页都没有 segmented（合计 ${segmented} 处）也没有固定 420 宽的居中容器（${centered} 处）；改成 chip 过滤条：改写 ${rewrite_chips} 处、读 Kind.allCases ${rewrite_kinds} 处；怎么判 ${rules_chips} 处"
else
    fail C2 "过滤条形态不符：segmented ${segmented}（0）、改写 chips ${rewrite_chips}（1）、Kind.allCases ${rewrite_kinds}（1）、规则页 chips ${rules_chips}（1）、居中容器 ${centered}（0）"
fi

# C3 每页可见主按钮 ≤1。数的是「页面本体」里的 LPPrimaryButtonStyle——
#    编辑器 sheet 里的保存按钮不算填充主按钮（它是模态里的唯一出口）。
rules_body=$(awk '/^struct RulesView: View \{/,/^struct RuleRow: View \{/' "$RULES")
rewrite_body=$(awk '/^struct RewriteView: View \{/,/^\/\/ MARK: - Editor sheet/' "$REWRITE")
rules_primary=$(printf '%s\n' "$rules_body" | grep -cF 'LPPrimaryButtonStyle()' || true)
rewrite_primary=$(printf '%s\n' "$rewrite_body" | grep -cF 'LPPrimaryButtonStyle()' || true)
rewrite_new=$(printf '%s\n' "$rewrite_body" | grep -cF '新建' || true)
empty_primary=$(printf '%s\n' "$rewrite_body" | grep -cF '添加第一条' || true)
# 空态动作是不是降级了：直接看 emptyState 函数体，别按行距猜（上一版按 -A2 数，样式行在
# 第四行，数出 0 —— 是检查写错了，不是代码错了）。
empty_block=$(awk '/private func emptyState\(for kind/,/^    }$/' "$REWRITE")
empty_ghost=$(printf '%s\n' "$empty_block" | grep -cF 'LPGhostButtonStyle()' || true)
if [ "$rules_primary" -eq 1 ] && [ "$rewrite_primary" -eq 1 ] && [ "$rewrite_new" -ge 1 ] && [ "$empty_ghost" -ge 1 ]; then
    pass C3 "怎么判填充主按钮 ${rules_primary} 个（重载/策略组开关都是 ghost）；改成什么 ${rewrite_primary} 个，就是过滤条右端那个「新建」；空态动作已降为 ghost（${empty_ghost} 处，空态文案 ${empty_primary} 处）"
else
    fail C3 "主按钮不符：怎么判 ${rules_primary}（1）、改成什么 ${rewrite_primary}（1）、新建入口 ${rewrite_new}（≥1）、空态 ghost ${empty_ghost}（≥1）"
fi

# C4 落地仍然只有一个入口：四类都走 RewriteDeck.applyRewrite，视图不直接改配置
apply_fn=$(grep -cF 'func applyRewrite(' "$DECK" || true)
apply_calls=$(grep -cF 'deck.applyRewrite' "$REWRITE" || true)
direct_write=$(grep -cE 'engine\.profile\.(rewrites|mocks|scripts)[[:space:]]*=' "$REWRITE" || true)
if [ "$apply_fn" -eq 1 ] && [ "$apply_calls" -eq 3 ] && [ "$direct_write" -eq 0 ]; then
    pass C4 "唯一落地口仍在 Deck（applyRewrite 定义 ${apply_fn} 处）；RewriteView 三个调用点（重写 / Mock / 脚本，实际 ${apply_calls}）全部走它；视图内直接改配置 ${direct_write} 处（要求 0）"
else
    fail C4 "落地口不符：applyRewrite 定义 ${apply_fn}（1）、视图调用 ${apply_calls}（3）、直接写配置 ${direct_write}（0）"
fi

# C5 怎么判：策略组右栏可折叠
toggle_state=$(grep -cF '@State private var showsPolicyGroups = true' "$RULES" || true)
toggle_gate=$(grep -cF 'if showsPolicyGroups {' "$RULES" || true)
toggle_button=$(grep -cF 'showsPolicyGroups.toggle()' "$RULES" || true)
if [ "$toggle_state" -eq 1 ] && [ "$toggle_gate" -eq 1 ] && [ "$toggle_button" -eq 1 ]; then
    pass C5 "策略组右栏可折叠：状态 ${toggle_state} 处、条件渲染 ${toggle_gate} 处、开关 ${toggle_button} 处；收起来时规则表占满宽度"
else
    fail C5 "折叠不全：状态 ${toggle_state}（1）、条件 ${toggle_gate}（1）、开关 ${toggle_button}（1）"
fi

echo "----------------------------------------------------------------"
echo "T-18 结果：${PASSED} PASS / ${FAILED} FAIL（C1 构建 · C2 无居中 tab · C3 主按钮 ≤1 · C4 唯一落地口 · C5 策略组可折叠）"
[ "$FAILED" -eq 0 ]
