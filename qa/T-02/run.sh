#!/usr/bin/env bash
# T-02 验收：菜单栏图标三态（四态四字形）
# 用法：bash qa/T-02/run.sh
# 不清空 scratch（清空会触发全量重建）；产物 /tmp/t02-scratch，日志 /tmp/t02-qa-logs。
# 只读仓库，不改 Sources/ Tests/ docs/。任何一条 FAIL → 退出码 1。
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT" || { echo "FAIL C0  无法进入仓库"; exit 1; }

SCRATCH="${T02_SCRATCH:-/tmp/t02-scratch}"
LOGDIR="${T02_LOGDIR:-/tmp/t02-qa-logs}"
mkdir -p "$LOGDIR"

ICON="Sources/LeapinRuntime/ResidentIcon.swift"
ICONTESTS="Tests/LeapinRuntimeTests/ResidentIconTests.swift"
APP="Sources/LeapinApp/LeapinApp.swift"

PASSED=0
FAILED=0
pass() { printf 'PASS %-3s %s\n' "$1" "$2"; PASSED=$((PASSED + 1)); }
fail() { printf 'FAIL %-3s %s\n' "$1" "$2"; FAILED=$((FAILED + 1)); }

for f in "$ICON" "$ICONTESTS" "$APP"; do
    [ -f "$f" ] || { echo "FAIL C0  缺少文件 $f"; exit 1; }
done

echo "T-02 验收 · 仓库 $ROOT"
echo "scratch=${SCRATCH}（复用，不清理）· 日志=${LOGDIR}"
echo "----------------------------------------------------------------"

# ---------------------------------------------------------------- C1 构建
build_log="$LOGDIR/c1-build.log"
swift build --scratch-path "$SCRATCH" --disable-sandbox >"$build_log" 2>&1
rc=$?
errs=$(grep -c 'error:' "$build_log" || true)
warns=$(grep -c 'warning:' "$build_log" || true)
task_warns=$(grep -E 'warning:' "$build_log" | grep -cE 'ResidentIcon\.swift|LeapinApp\.swift' || true)
if [ "$rc" -eq 0 ]; then
    pass C1 "swift build --scratch-path ${SCRATCH} --disable-sandbox → exit 0；复用 scratch（未重编的目标不产生 warning，本行 warning 计数只覆盖本轮编译的文件）；日志 ${errs} 个 error:、${warns} 个 warning:，其中落在任务文件（ResidentIcon.swift / LeapinApp.swift）上的 ${task_warns} 个"
else
    fail C1 "swift build 退出码 ${rc}，见 ${build_log}；首个错误：$(grep -m1 'error:' "$build_log" || echo '（无 error: 行）')"
fi

# ---------------------------------------------------------------- C2 单测
test_log="$LOGDIR/c2-test.log"
swift test --scratch-path "$SCRATCH" --disable-sandbox --filter ResidentIconTests >"$test_log" 2>&1
rc=$?
total_line=$(grep -E "Test Suite 'ResidentIconTests' passed" -A2 "$test_log" | grep -m1 'Executed' | sed 's/^[[:space:]]*//')
cases=$(grep -cE "Test Case '-\[LeapinRuntimeTests\.ResidentIconTests .*\]' passed" "$test_log" || true)
if [ "$rc" -eq 0 ] && grep -qF 'Executed 6 tests, with 0 failures' "$test_log"; then
    pass C2 "swift test --filter ResidentIconTests → exit 0；汇总行「${total_line}」；逐条 passed 用例 ${cases} 个"
else
    fail C2 "swift test --filter ResidentIconTests 退出码 ${rc}；汇总行「${total_line:-无}」；未匹配 'Executed 6 tests, with 0 failures'；失败用例：$(grep -m3 'failed (' "$test_log" || echo '无')"
fi

# ---------------------------------------------------------------- C3 四态四字形
icon_block=$(awk '/var iconName: String \{/{f=1} f{print} f && /^    \}$/{exit}' "$ICON")
map=$(printf '%s\n' "$icon_block" | awk '
    /case \.[a-z]+:/ { t=$0; sub(/^.*case \./, "", t); sub(/:.*$/, "", t) }
    /return "/ { v=$0; sub(/^.*return "/, "", v); sub(/".*$/, "", v); if (t != "") print t "=" v }
')
map_sorted=$(printf '%s\n' "$map" | sort)
want_sorted=$(printf '%s\n' 'idle=shield.slash' 'normal=shield.lefthalf.filled' 'degraded=exclamationmark.shield.fill' 'failed=xmark.shield.fill' | sort)
map_n=$(printf '%s\n' "$map" | grep -c '=' || true)
glyph_n=$(printf '%s\n' "$map" | cut -d= -f2 | sort -u | wc -l | tr -d ' ')
if [ "$map_sorted" = "$want_sorted" ] && [ "$map_n" -eq 4 ] && [ "$glyph_n" -eq 4 ]; then
    pass C3 "iconName 映射 4 条且互不相同：$(printf '%s' "$map_sorted" | tr '\n' '|')（唯一字形 ${glyph_n} 个）"
else
    fail C3 "iconName 映射不符：实得 [$(printf '%s' "$map_sorted" | tr '\n' '|')]，条目 ${map_n} 个、唯一字形 ${glyph_n} 个（要求 4/4，且 idle=shield.slash、normal=shield.lefthalf.filled、degraded=exclamationmark.shield.fill、failed=xmark.shield.fill）"
fi

# ---------------------------------------------------------------- C4 读同一份状态 + 延迟徽标
block=$(awk '/private struct MenuBarLabel: View \{/{f=1} f{print} f && /^\}$/{exit}' "$APP")
reads_store=$(printf '%s\n' "$block" | grep -cF 'ResidentStatusStore' || true)
two_state=$(printf '%s\n' "$block" | grep -cE 'running[[:space:]]*\?' || true)
badge_text=$(printf '%s\n' "$block" | grep -F 'status.badge' | head -1 | sed 's/^[[:space:]]*//')
badge_guarded=0
case "$badge_text" in
    *'tone == .normal'*) badge_guarded=1 ;;
esac
if [ "$badge_guarded" -eq 0 ] && printf '%s\n' "$block" | grep -qE 'guard tone == \.normal'; then
    badge_guarded=1
fi
block_n=$(printf '%s\n' "$block" | grep -c '[^[:space:]]' || true)
# R2-1 之后接线变了：窗口全关时图标不能靠别处重绘，必须有自己的事件订阅；
# 同时不许用定时器兜底（那是 T-02「不新增定时器」的底线）。
STATE_HOOK='onReceive(engine.$state'
state_hook_n=$(printf '%s\n' "$block" | grep -cF "$STATE_HOOK" || true)
timer_n=$(printf '%s\n' "$block" | grep -cE 'Timer' || true)
if [ "$block_n" -gt 0 ] && [ "$reads_store" -ge 1 ] && [ "$two_state" -eq 0 ] && [ "$badge_guarded" -eq 1 ] && [ "$state_hook_n" -ge 1 ] && [ "$timer_n" -eq 0 ]; then
    pass C4 "MenuBarLabel（${block_n} 行）读 ResidentStatusStore ${reads_store} 处；块内 'running ?' 两态判断 ${two_state} 处（要求 0）；${STATE_HOOK} 订阅 ${state_hook_n} 处（按事件更新，不靠别处重绘）；块内 Timer ${timer_n} 处（要求 0，不许定时器兜底）；延迟徽标行受 tone == .normal 约束：${badge_text}"
else
    fail C4 "MenuBarLabel 块 ${block_n} 行：ResidentStatusStore ${reads_store} 处（要求 ≥1）、'running ?' ${two_state} 处（要求 0）、${STATE_HOOK} 订阅 ${state_hook_n} 处（要求 ≥1）、块内 Timer ${timer_n} 处（要求 0）、徽标守卫=${badge_guarded}（要求 1）；徽标行：${badge_text:-未找到 status.badge}"
fi

# ---------------------------------------------------------------- C5 无彩色图标
block_nsimage=$(printf '%s\n' "$block" | grep -cE 'NSImage' || true)
block_istemplate=$(printf '%s\n' "$block" | grep -cE 'isTemplate' || true)
app_nsimage=$(grep -cE 'NSImage' "$APP" || true)
app_istemplate=$(grep -cE 'isTemplate' "$APP" || true)
global_istemplate_false=$(grep -rnE 'isTemplate[[:space:]]*=[[:space:]]*false' Sources --include='*.swift' | wc -l | tr -d ' ')
if [ "$block_nsimage" -eq 0 ] && [ "$block_istemplate" -eq 0 ] && [ "$app_nsimage" -eq 0 ] && [ "$app_istemplate" -eq 0 ] && [ "$global_istemplate_false" -eq 0 ]; then
    pass C5 "图标走 SF Symbol（Image(systemName:)）：MenuBarLabel 内 NSImage ${block_nsimage} 处、isTemplate ${block_istemplate} 处；LeapinApp.swift 内 NSImage ${app_nsimage} 处、isTemplate ${app_istemplate} 处；全仓库 isTemplate=false ${global_istemplate_false} 处（全部要求 0）"
else
    fail C5 "出现非模板/彩色图标迹象：MenuBarLabel NSImage=${block_nsimage} isTemplate=${block_istemplate}；LeapinApp.swift NSImage=${app_nsimage} isTemplate=${app_istemplate}；全仓库 isTemplate=false=${global_istemplate_false}（均要求 0）"
fi

# ---------------------------------------------------------------- 汇总
echo "----------------------------------------------------------------"
echo "T-02 结果：${PASSED} PASS / ${FAILED} FAIL（C1 构建 · C2 单测 · C3 四态四字形 · C4 单一状态源+延迟徽标 · C5 无彩色图标）"
if [ "$FAILED" -gt 0 ]; then
    exit 1
fi
exit 0
