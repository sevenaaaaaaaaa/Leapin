#!/usr/bin/env bash
# T-05 验收：工作层纯逻辑（动词 / 上下文 / 侧栏计划 / 规则原子）
# 用法：bash qa/T-05/run.sh
# 默认复用 scratch（${T05_SCRATCH:-/tmp/t05-scratch}），不删目录。
# 跑前会等机器上的 swift 构建安静下来（eng 可能正用别的 scratch 构建）；
# 本脚本 scratch 独立，等到上限仍在构建则打印 WARN 继续，不会因此假绿。
# 只读仓库，不改 Sources/ Tests/ docs/。任何一条 FAIL → 退出码 1。
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT" || { echo "FAIL C0  无法进入仓库"; exit 1; }

SCRATCH="${T05_SCRATCH:-/tmp/t05-scratch}"
LOGDIR="${T05_LOGDIR:-/tmp/t05-qa-logs}"
mkdir -p "$LOGDIR"

WB="Sources/LeapinRuntime/Workbench.swift"
WBTESTS="Tests/LeapinRuntimeTests/WorkbenchTests.swift"

PASSED=0
FAILED=0
pass() { printf 'PASS %-3s %s\n' "$1" "$2"; PASSED=$((PASSED + 1)); }
fail() { printf 'FAIL %-3s %s\n' "$1" "$2"; FAILED=$((FAILED + 1)); }

for f in "$WB" "$WBTESTS"; do
    [ -f "$f" ] || { echo "FAIL C0  缺少文件 $f"; exit 1; }
done

echo "T-05 验收 · 仓库 $ROOT"
echo "scratch=${SCRATCH}（复用，不清理）· 日志=${LOGDIR}"

busy() { ps -Ao command | grep -Ec '[s]wift-build|[s]wift-test'; }
waited=0
while [ "$(busy)" -gt 0 ] && [ "$waited" -lt 60 ]; do sleep 5; waited=$((waited + 5)); done
if [ "$(busy)" -gt 0 ]; then
    echo "WARN 另有 swift 构建在跑（等过 ${waited}s）；本脚本用独立 scratch，继续，耗时会长"
else
    echo "环境就绪：无其它 swift 构建（等了 ${waited}s）"
fi
echo "----------------------------------------------------------------"

# ---------------------------------------------------------------- C1 构建
build_log="$LOGDIR/c1-build.log"
swift build --scratch-path "$SCRATCH" --disable-sandbox >"$build_log" 2>&1
rc=$?
errs=$(grep -c 'error:' "$build_log" || true)
warns=$(grep -c 'warning:' "$build_log" || true)
task_warns=$(grep -E 'warning:' "$build_log" | grep -cE 'Workbench\.swift|WorkbenchTests\.swift' || true)
if [ "$rc" -eq 0 ]; then
    pass C1 "swift build --scratch-path ${SCRATCH} --disable-sandbox → exit 0；复用 scratch（未重编的目标不产生 warning，本行 warning 计数只覆盖本轮编译的文件）；日志 ${errs} 个 error:、${warns} 个 warning:，其中落在任务文件（Workbench.swift / WorkbenchTests.swift）上的 ${task_warns} 个"
else
    fail C1 "swift build 退出码 ${rc}，见 ${build_log}；首个错误：$(grep -m1 'error:' "$build_log" || echo '（无 error: 行）')"
fi

# ---------------------------------------------------------------- C2 WorkbenchTests
test_log="$LOGDIR/c2-test.log"
swift test --scratch-path "$SCRATCH" --disable-sandbox --filter WorkbenchTests >"$test_log" 2>&1
rc=$?
total_line=$(grep -A2 "Test Suite 'WorkbenchTests' passed" "$test_log" | grep -m1 'Executed' | sed 's/^[[:space:]]*//')
cases=$(grep -cE "Test Case '-\[LeapinRuntimeTests\.WorkbenchTests .*\]' passed" "$test_log" || true)
if [ "$rc" -eq 0 ] && grep -qF 'Executed 24 tests, with 0 failures' "$test_log"; then
    pass C2 "swift test --filter WorkbenchTests → exit 0；汇总行「${total_line}」；逐条 passed 用例 ${cases} 个"
else
    ten_hit=$(grep -cF 'Executed 24 tests, with 0 failures' "$test_log" || true)
    fail C2 "退出码 ${rc}；'Executed 24 tests, with 0 failures' 命中 ${ten_hit} 次；逐条 passed ${cases} 个（要求 24）；失败用例：$(grep -m3 'failed (' "$test_log" || echo '无')"
fi

# ---------------------------------------------------------------- C3 纯逻辑四件套
rows=$(grep -cE '^[[:space:]]*Row\(title:' "$WB" || true)
groups=$(grep -cE '^[[:space:]]*Group\(name:' "$WB" || true)
short_block=$(awk '/public var shortcut: String \{/{f=1} f{print} f && /^    \}$/{exit}' "$WB")
short_vals=$(printf '%s\n' "$short_block" | grep -oE 'return "[0-9]"' | grep -oE '[0-9]' | sort | tr -d '\n')
short_cases=$(printf '%s\n' "$short_block" | grep -cE 'case \.' || true)
peek_n=$(grep -cE 'func peek\(for' "$WB" || true)
take_n=$(grep -cE 'func take\(for' "$WB" || true)
inserting_n=$(grep -cE 'func inserting\(into' "$WB" || true)
entry_n=$(grep -cE 'func makeRuleSetEntry\(existing' "$WB" || true)
if [ "$rows" -eq 11 ] && [ "$groups" -eq 3 ] && [ "$short_vals" = "1234" ] && [ "$short_cases" -eq 4 ] \
   && [ "$peek_n" -ge 1 ] && [ "$take_n" -ge 1 ] && [ "$inserting_n" -ge 1 ] && [ "$entry_n" -ge 1 ]; then
    pass C3 "WorkbenchSidebar ${groups} 组 ${rows} 行（Group(name: / Row(title: 各计入）；四动词 shortcut 值 ${short_vals}（${short_cases} 个 case）；RouteContext.peek(for:) ${peek_n} 处、take(for:) ${take_n} 处；RuleDraft.inserting(into:) ${inserting_n} 处、makeRuleSetEntry(existing:) ${entry_n} 处"
else
    fail C3 "纯逻辑断言不符：组数 ${groups}（要求 3）、行数 ${rows}（要求 11）、shortcut 值 [${short_vals}]（要求 1234）、shortcut case ${short_cases}（要求 4）、peek ${peek_n}／take ${take_n}（各要求 ≥1）、inserting ${inserting_n}／makeRuleSetEntry ${entry_n}（各要求 ≥1）"
fi

# ---------------------------------------------------------------- C4 RuleDraft 不写死 DIRECT
# 判代码不判注释：文件里注释解释“为什么不能写 DIRECT”，那不是实现。
wb_code=$(sed -E 's://.*$::' "$WB")
direct_code=$(printf '%s\n' "$wb_code" | grep -c '"DIRECT"' || true)
direct_raw=$(grep -c '"DIRECT"' "$WB" || true)
policy_from_draft=$(printf '%s\n' "$wb_code" | grep -cF 'policy: policy' || true)
if [ "$direct_code" -eq 0 ] && [ "$policy_from_draft" -ge 1 ]; then
    pass C4 "Workbench.swift 代码行里 \"DIRECT\" 字面 ${direct_code} 处（要求 0，policy 只能来自 draft）；注释/文档里提到 ${direct_raw} 次（不构成实现）；RuleDraft.rule 用 policy: policy ${policy_from_draft} 处"
else
    fail C4 "RuleDraft 写死了 DIRECT 或没用自己的 policy：代码行 \"DIRECT\" ${direct_code} 处（要求 0）、policy: policy ${policy_from_draft} 处（要求 ≥1）"
fi

# ---------------------------------------------------------------- C5 其它用例回归抽样
reg_log="$LOGDIR/c5-regression.log"
swift test --scratch-path "$SCRATCH" --disable-sandbox --filter 'ResidentStatusTests|ResidentIconTests|SystemProxy' >"$reg_log" 2>&1
rc=$?
s_status=$(grep -cE "Test Case '-\[LeapinRuntimeTests\.ResidentStatusTests .*\]' passed" "$reg_log" || true)
s_icon=$(grep -cE "Test Case '-\[LeapinRuntimeTests\.ResidentIconTests .*\]' passed" "$reg_log" || true)
s_flag=$(grep -cE "Test Case '-\[LeapinRuntimeTests\.SystemProxyFlagTests .*\]' passed" "$reg_log" || true)
s_err=$(grep -cE "Test Case '-\[LeapinRuntimeTests\.SystemProxyErrorTests .*\]' passed" "$reg_log" || true)
s_total=$((s_status + s_icon + s_flag + s_err))
failed_lines=$(grep -cE 'failed \(' "$reg_log" || true)
if [ "$rc" -eq 0 ] && [ "$failed_lines" -eq 0 ] && [ "$s_status" -ge 1 ] && [ "$s_icon" -ge 1 ] && [ "$s_flag" -ge 1 ] && [ "$s_err" -ge 1 ]; then
    pass C5 "回归抽样 swift test --filter 'ResidentStatusTests|ResidentIconTests|SystemProxy' → exit 0；ResidentStatusTests ${s_status} 条、ResidentIconTests ${s_icon} 条、SystemProxyFlagTests ${s_flag} 条、SystemProxyErrorTests ${s_err} 条，共 ${s_total} 条全过（这是抽样，不等于全量 swift test）"
else
    fail C5 "回归抽样失败：退出码 ${rc}、失败用例 ${failed_lines} 条；各套件 passed：ResidentStatus ${s_status}、ResidentIcon ${s_icon}、SystemProxyFlag ${s_flag}、SystemProxyError ${s_err}（各自要求 ≥1）"
fi

# ---------------------------------------------------------------- 汇总
echo "----------------------------------------------------------------"
echo "T-05 结果：${PASSED} PASS / ${FAILED} FAIL（C1 构建 · C2 WorkbenchTests 24 · C3 纯逻辑四件套 · C4 不写死 DIRECT · C5 回归抽样）"
if [ "$FAILED" -gt 0 ]; then
    exit 1
fi
exit 0
