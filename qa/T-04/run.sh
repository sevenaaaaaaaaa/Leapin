#!/usr/bin/env bash
# T-04 验收：系统代理标志按事实回读，不按入参写死
# 用法：bash qa/T-04/run.sh
# 默认复用 scratch（${T04_SCRATCH:-/tmp/t04-scratch}），不删目录（eng 在共用机器上构建）。
# 只读仓库，不改 Sources/ Tests/ docs/。任何一条 FAIL → 退出码 1。
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT" || { echo "FAIL C0  无法进入仓库"; exit 1; }

SCRATCH="${T04_SCRATCH:-/tmp/t04-scratch}"
LOGDIR="${T04_LOGDIR:-/tmp/t04-qa-logs}"
mkdir -p "$LOGDIR"

ENGINE="Sources/LeapinRuntime/TouchFlowEngine.swift"
FLAGTESTS="Tests/LeapinRuntimeTests/SystemProxyFlagTests.swift"
ERRTESTS="Tests/LeapinRuntimeTests/SystemProxyErrorTests.swift"

PASSED=0
FAILED=0
pass() { printf 'PASS %-3s %s\n' "$1" "$2"; PASSED=$((PASSED + 1)); }
fail() { printf 'FAIL %-3s %s\n' "$1" "$2"; FAILED=$((FAILED + 1)); }

for f in "$ENGINE" "$FLAGTESTS" "$ERRTESTS"; do
    [ -f "$f" ] || { echo "FAIL C0  缺少文件 $f"; exit 1; }
done

echo "T-04 验收 · 仓库 $ROOT"
echo "scratch=${SCRATCH}（复用，不清理）· 日志=${LOGDIR}"
echo "----------------------------------------------------------------"

# ---------------------------------------------------------------- C1 构建
build_log="$LOGDIR/c1-build.log"
swift build --scratch-path "$SCRATCH" --disable-sandbox >"$build_log" 2>&1
rc=$?
errs=$(grep -c 'error:' "$build_log" || true)
warns=$(grep -c 'warning:' "$build_log" || true)
task_warns=$(grep -E 'warning:' "$build_log" | grep -cE 'TouchFlowEngine\.swift|SystemProxyFlagTests\.swift' || true)
if [ "$rc" -eq 0 ]; then
    pass C1 "swift build --scratch-path ${SCRATCH} --disable-sandbox → exit 0；复用 scratch（未重编的目标不产生 warning，本行 warning 计数只覆盖本轮编译的文件）；日志 ${errs} 个 error:、${warns} 个 warning:，其中落在任务文件（TouchFlowEngine.swift / SystemProxyFlagTests.swift）上的 ${task_warns} 个"
else
    fail C1 "swift build 退出码 ${rc}，见 ${build_log}；首个错误：$(grep -m1 'error:' "$build_log" || echo '（无 error: 行）')"
fi

# ---------------------------------------------------------------- C2 单测 7+3
test_log="$LOGDIR/c2-test.log"
swift test --scratch-path "$SCRATCH" --disable-sandbox --filter 'SystemProxyFlagTests|SystemProxyErrorTests' >"$test_log" 2>&1
rc=$?
flag_cases=$(grep -cE "Test Case '-\[LeapinRuntimeTests\.SystemProxyFlagTests .*\]' passed" "$test_log" || true)
err_cases=$(grep -cE "Test Case '-\[LeapinRuntimeTests\.SystemProxyErrorTests .*\]' passed" "$test_log" || true)
flag_total=$(grep -A2 "Test Suite 'SystemProxyFlagTests' passed" "$test_log" | grep -m1 'Executed' | sed 's/^[[:space:]]*//')
err_total=$(grep -A2 "Test Suite 'SystemProxyErrorTests' passed" "$test_log" | grep -m1 'Executed' | sed 's/^[[:space:]]*//')
if [ "$rc" -eq 0 ] && grep -qF 'Executed 10 tests, with 0 failures' "$test_log" && [ "$flag_cases" -eq 7 ] && [ "$err_cases" -eq 3 ]; then
    pass C2 "swift test --filter 'SystemProxyFlagTests|SystemProxyErrorTests' → exit 0；汇总行含 Executed 10 tests, with 0 failures；逐条 passed：SystemProxyFlagTests ${flag_cases} 条、SystemProxyErrorTests ${err_cases} 条（共 10）"
else
    ten_hit=$(grep -cF 'Executed 10 tests, with 0 failures' "$test_log" || true)
    fail C2 "退出码 ${rc}；'Executed 10 tests, with 0 failures' 命中 ${ten_hit} 次；FlagTests 逐条 ${flag_cases}（要求 7）「${flag_total:-无}」、ErrorTests 逐条 ${err_cases}（要求 3）「${err_total:-无}」；失败用例：$(grep -m3 'failed (' "$test_log" || echo '无')"
fi

# ---------------------------------------------------------------- C3 成功分支回读 + 四条规则
method=$(awk '/public func toggleSystemProxy\(_ enabled: Bool\) async \{/{f=1} f{print} f && /^    \}$/{exit}' "$ENGINE")
do_line=$(printf '%s\n' "$method" | grep -nE '^[[:space:]]*do \{' | head -1 | cut -d: -f1)
catch_line=$(printf '%s\n' "$method" | grep -nE '^[[:space:]]*\} catch' | head -1 | cut -d: -f1)
refresh_line=$(printf '%s\n' "$method" | grep -nF 'refreshSystemProxyStatus()' | head -1 | cut -d: -f1)
direct_write=$(printf '%s\n' "$method" | grep -cE 'systemProxyActive[[:space:]]*=[^=]' || true)
readback_msg=$(printf '%s\n' "$method" | grep -cF 'systemProxyReadbackMessage(' || true)

ours_block=$(awk '/static func systemProxyIsOurs\(/{f=1} f{print} f && /^    \}$/{exit}' "$ENGINE")
ours=$(printf '%s\n' "$ours_block" | sed -n '/-> Bool {/,$p' | tail -n +2 | grep -vE '^[[:space:]]*//')
r_running=$(printf '%s\n' "$ours" | grep -cE '(^|[^a-zA-Z])running([^a-zA-Z]|$)' || true)
r_enabled=$(printf '%s\n' "$ours" | grep -cE '(^|[^a-zA-Z])enabled([^a-zA-Z]|$)' || true)
r_loopback=$(printf '%s\n' "$ours" | grep -cF '127.0.0.1' || true)
r_localhost=$(printf '%s\n' "$ours" | grep -cF 'localhost' || true)
r_port=$(printf '%s\n' "$ours" | grep -cE 'port[[:space:]]*==[[:space:]]*ourPort' || true)
rules=0
[ "$r_running" -ge 1 ] && rules=$((rules + 1))
[ "$r_enabled" -ge 1 ] && rules=$((rules + 1))
[ "$r_loopback" -ge 1 ] && [ "$r_localhost" -ge 1 ] && rules=$((rules + 1))
[ "$r_port" -ge 1 ] && rules=$((rules + 1))
cond_text=$(printf '%s\n' "$ours" | tr -d '\n' | tr -s ' ' | sed 's/^ *//')
ok=0
if [ -n "$do_line" ] && [ -n "$catch_line" ] && [ -n "$refresh_line" ] \
   && [ "$refresh_line" -gt "$do_line" ] && [ "$refresh_line" -lt "$catch_line" ] \
   && [ "$direct_write" -eq 0 ] && [ "$readback_msg" -ge 1 ] && [ "$rules" -ge 4 ]; then
    ok=1
fi
if [ "$ok" -eq 1 ]; then
    pass C3 "toggleSystemProxy 成功分支：do { 第 ${do_line} 行 → refreshSystemProxyStatus() 第 ${refresh_line} 行（在 } catch 第 ${catch_line} 行之前），随后 systemProxyReadbackMessage 记账 ${readback_msg} 处；方法体内直接写 systemProxyActive 的参数写入 ${direct_write} 处（要求 0）；systemProxyIsOurs 四条规则齐（running/enabled、127.0.0.1/localhost、port==ourPort）：${cond_text}"
else
    fail C3 "回读接线不符：do=${do_line:-无}、refreshSystemProxyStatus=${refresh_line:-无}、} catch=${catch_line:-无}、直接写 systemProxyActive=${direct_write}（要求 0）、readback 记账=${readback_msg}（要求 ≥1）、systemProxyIsOurs 规则=${rules}/4；条件文本：${cond_text}"
fi

# ---------------------------------------------------------------- C4 测试不跑真实命令
# 口径同 T-03：判「调用」不判「字面」。注释里提 SystemProxy.statusAsync 不算调用。
code_only=$(sed -E 's://.*$::' "$FLAGTESTS")
exec_paths=$(printf '%s\n' "$code_only" | grep -cE 'Process\(|posix_spawn|popen|SystemProxy\.' || true)
raw_calls=$(grep -cE 'Process\(|posix_spawn|popen|SystemProxy\.' "$FLAGTESTS" || true)
raw_lines=$(grep -nE 'Process\(|posix_spawn|popen|SystemProxy\.' "$FLAGTESTS" | cut -d: -f1 | tr '\n' ',' | sed 's/,$//')
if [ "$exec_paths" -eq 0 ]; then
    pass C4 "SystemProxyFlagTests 代码行里真实命令入口 0 处（Process( / posix_spawn / popen / SystemProxy. 均为 0）；字面命中 ${raw_calls} 次（行 ${raw_lines:-无}），全在注释/文档中，不构成调用"
else
    fail C4 "SystemProxyFlagTests 代码里出现 ${exec_paths} 处真实命令入口：$(printf '%s\n' "$code_only" | grep -nE 'Process\(|posix_spawn|popen|SystemProxy\.' | head -3 | tr '\n' ' ')"
fi

# ---------------------------------------------------------------- C5 T-03 三条回归
missing=""
for name in testSuccessClearsTheErrorLeftByAFailedAttempt testDisablingAlsoClearsAStaleError testFailedAttemptStillReportsAndLeavesTheFlagAlone; do
    grep -qF "func $name(" "$ERRTESTS" || missing="$missing $name"
done
err_suite_ok=0
if grep -A2 "Test Suite 'SystemProxyErrorTests' passed" "$test_log" | grep -qF 'Executed 3 tests, with 0 failures'; then
    err_suite_ok=1
fi
if [ -z "$missing" ] && [ "$err_suite_ok" -eq 1 ]; then
    pass C5 "T-03 的 3 条用例仍在（testSuccessClearsTheErrorLeftByAFailedAttempt / testDisablingAlsoClearsAStaleError / testFailedAttemptStillReportsAndLeavesTheFlagAlone），且本轮 C2 里 SystemProxyErrorTests 3/3 全过"
else
    fail C5 "T-03 回归不全：缺用例=[${missing:- 无}]、ErrorTests 3/3 全过=${err_suite_ok}（要求 1）"
fi

# ---------------------------------------------------------------- 汇总
echo "----------------------------------------------------------------"
echo "T-04 结果：${PASSED} PASS / ${FAILED} FAIL（C1 构建 · C2 单测 7+3 · C3 成功分支回读 · C4 测试不跑真实命令 · C5 T-03 回归）"
if [ "$FAILED" -gt 0 ]; then
    exit 1
fi
exit 0
