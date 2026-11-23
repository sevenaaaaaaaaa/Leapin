#!/usr/bin/env bash
# T-03 验收：系统代理切换成功后清除上一条错误
# 用法：bash qa/T-03/run.sh
# 不清空 scratch（清空会触发全量重建）；产物 /tmp/t03-scratch，日志 /tmp/t03-qa-logs。
# 只读仓库，不改 Sources/ Tests/ docs/。任何一条 FAIL → 退出码 1。
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT" || { echo "FAIL C0  无法进入仓库"; exit 1; }

SCRATCH="${T03_SCRATCH:-/tmp/t03-scratch}"
LOGDIR="${T03_LOGDIR:-/tmp/t03-qa-logs}"
mkdir -p "$LOGDIR"

ENGINE="Sources/LeapinRuntime/TouchFlowEngine.swift"
TESTS="Tests/LeapinRuntimeTests/SystemProxyErrorTests.swift"

PASSED=0
FAILED=0
pass() { printf 'PASS %-3s %s\n' "$1" "$2"; PASSED=$((PASSED + 1)); }
fail() { printf 'FAIL %-3s %s\n' "$1" "$2"; FAILED=$((FAILED + 1)); }

for f in "$ENGINE" "$TESTS"; do
    [ -f "$f" ] || { echo "FAIL C0  缺少文件 $f"; exit 1; }
done

echo "T-03 验收 · 仓库 $ROOT"
echo "scratch=${SCRATCH}（复用，不清理）· 日志=${LOGDIR}"
echo "----------------------------------------------------------------"

# ---------------------------------------------------------------- C1 构建
build_log="$LOGDIR/c1-build.log"
swift build --scratch-path "$SCRATCH" --disable-sandbox >"$build_log" 2>&1
rc=$?
errs=$(grep -c 'error:' "$build_log" || true)
warns=$(grep -c 'warning:' "$build_log" || true)
task_warns=$(grep -E 'warning:' "$build_log" | grep -cE 'TouchFlowEngine\.swift|SystemProxyErrorTests\.swift' || true)
if [ "$rc" -eq 0 ]; then
    pass C1 "swift build --scratch-path ${SCRATCH} --disable-sandbox → exit 0；复用 scratch（未重编的目标不产生 warning，本行 warning 计数只覆盖本轮编译的文件）；日志 ${errs} 个 error:、${warns} 个 warning:，其中落在任务文件（TouchFlowEngine.swift）上的 ${task_warns} 个"
else
    fail C1 "swift build 退出码 ${rc}，见 ${build_log}；首个错误：$(grep -m1 'error:' "$build_log" || echo '（无 error: 行）')"
fi

# ---------------------------------------------------------------- C2 单测
test_log="$LOGDIR/c2-test.log"
swift test --scratch-path "$SCRATCH" --disable-sandbox --filter SystemProxyErrorTests >"$test_log" 2>&1
rc=$?
total_line=$(grep -E "Test Suite 'SystemProxyErrorTests' passed" -A2 "$test_log" | grep -m1 'Executed' | sed 's/^[[:space:]]*//')
cases=$(grep -cE "Test Case '-\[LeapinRuntimeTests\.SystemProxyErrorTests .*\]' passed" "$test_log" || true)
if [ "$rc" -eq 0 ] && grep -qF 'Executed 3 tests, with 0 failures' "$test_log"; then
    pass C2 "swift test --filter SystemProxyErrorTests → exit 0；汇总行「${total_line}」；逐条 passed 用例 ${cases} 个"
else
    fail C2 "swift test --filter SystemProxyErrorTests 退出码 ${rc}；汇总行「${total_line:-无}」；未匹配 'Executed 3 tests, with 0 failures'；失败用例：$(grep -m3 'failed (' "$test_log" || echo '无')"
fi

# ---------------------------------------------------------------- C3 成功分支有一处清错（机制无关）
# 2026-11-23 DoD 二次更正（T-04 落地后）：清错从 applySystemProxySuccess 挪进行内
# 回读记账，所以这里不再钉函数名。判三件事：
#   1) 入口（do 之前）没有对 lastError 的赋值（B-1：那会连带清掉 saveProfile / 回滚的错误）；
#   2) 成功分支（do 之后、} catch 之前）有一处 lastError 赋值＝这次“清错动作”，
#      且该处不是写死字符串（写死说明是“记一条错”，不是“清错”）；
#   3) catch 里仍然写 lastError（失败照旧上报）。
# 已知限制：静态只能证“成功分支里有这个动作”，证不了它的返回值确实是 nil；
# nil 由 SystemProxyFlagTests 的 readback 文案用例覆盖，端到端那条仍缺，见 qa/T-03/report.md。
method=$(awk '/public func toggleSystemProxy\(_ enabled: Bool\) async \{/{f=1} f{print} f && /^    \}$/{exit}' "$ENGINE")
do_line=$(printf '%s\n' "$method" | grep -nE '^[[:space:]]*do \{' | head -1 | cut -d: -f1)
catch_line=$(printf '%s\n' "$method" | grep -nE '^[[:space:]]*\} catch' | head -1 | cut -d: -f1)
entry_last=0
if [ -n "$do_line" ] && [ "$do_line" -gt 1 ]; then
    entry_last=$(printf '%s\n' "$method" | awk -v d="$do_line" 'NR < d' | grep -vE '^[[:space:]]*//' | grep -cE 'lastError[[:space:]]*=' || true)
fi
succ_region=""
succ_n=0
succ_text=""
succ_literal=0
if [ -n "$do_line" ] && [ -n "$catch_line" ]; then
    succ_region=$(printf '%s\n' "$method" | awk -v a="$do_line" -v b="$catch_line" 'NR > a && NR < b' | grep -vE '^[[:space:]]*//')
    succ_n=$(printf '%s\n' "$succ_region" | grep -cE 'lastError[[:space:]]*=' || true)
    succ_text=$(printf '%s\n' "$succ_region" | grep -E 'lastError[[:space:]]*=' | head -1 | sed 's/^[[:space:]]*//')
    succ_literal=$(printf '%s\n' "$succ_region" | grep -cE 'lastError[[:space:]]*=[[:space:]]*"' || true)
fi
catch_last=0
if [ -n "$catch_line" ]; then
    catch_last=$(printf '%s\n' "$method" | awk -v l="$catch_line" 'NR >= l' | grep -vE '^[[:space:]]*//' | grep -cE 'lastError[[:space:]]*=' || true)
fi
ok=0
if [ -n "$do_line" ] && [ -n "$catch_line" ] \
   && [ "$entry_last" -eq 0 ] && [ "$succ_n" -ge 1 ] && [ "$succ_literal" -eq 0 ] && [ "$catch_last" -ge 1 ]; then
    ok=1
fi
if [ "$ok" -eq 1 ]; then
    pass C3 "toggleSystemProxy 方法体内：入口（do 之前）lastError 赋值 ${entry_last} 处（要求 0，B-1）；成功分支（do 第 ${do_line} 行之后、} catch 第 ${catch_line} 行之前）清错动作 ${succ_n} 处、写死字符串 ${succ_literal} 处（要求 ≥1 / 0）：${succ_text}；catch 内 lastError 赋值 ${catch_last} 处（要求 ≥1，失败照旧上报）。不钉具体函数名（二次更正）"
else
    fail C3 "清错接线不符：入口 lastError 赋值 ${entry_last} 处（要求 0）、do 行=${do_line:-无}、} catch 行=${catch_line:-无}、成功分支清错动作 ${succ_n} 处（要求 ≥1）、成功分支写死字符串 ${succ_literal} 处（要求 0）、catch 内 lastError ${catch_last} 处（要求 ≥1）；成功分支实得：${succ_text:-无}"
fi

# ---------------------------------------------------------------- C4 测试不跑真实命令
# 口径：判「执行」，不是判「字面出现」。注释与 fixture 字符串里提 networksetup 不构成执行；
# 真执行要经过 Process / posix_spawn / popen / SystemProxy.*。字面数量一并打印出来便于复核。
literal=$(grep -ci 'networksetup' "$TESTS" || true)
exec_paths=$(grep -cE 'Process\(|posix_spawn|popen|SystemProxy\.' "$TESTS" || true)
literal_lines=$(grep -ni 'networksetup' "$TESTS" | cut -d: -f1 | tr '\n' ',' | sed 's/,$//')
if [ "$exec_paths" -eq 0 ]; then
    pass C4 "测试文件内可执行真实命令的入口 0 处（Process( / posix_spawn / popen / SystemProxy. 均 0）；networksetup 字面出现 ${literal} 次，全在非执行位置（行 ${literal_lines}）：注释与 fixture 字符串"
else
    fail C4 "测试文件出现 ${exec_paths} 处真实命令入口：$(grep -nE 'Process\(|posix_spawn|popen|SystemProxy\.' "$TESTS" | head -3 | tr '\n' ' ')"
fi

# ---------------------------------------------------------------- 汇总
echo "----------------------------------------------------------------"
echo "T-03 结果：${PASSED} PASS / ${FAILED} FAIL（C1 构建 · C2 单测 · C3 清错在成功分支 · C4 测试不跑真实命令）"
if [ "$FAILED" -gt 0 ]; then
    exit 1
fi
exit 0
