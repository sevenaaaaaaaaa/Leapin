#!/usr/bin/env bash
# T-20 验收：常驻层（菜单栏面板 / 浮窗）的「路」缩略、空态、动效。
# 用法：bash qa/T-20/run.sh
# 只读仓库；任何一条 FAIL → 退出码 1。
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT" || { echo "FAIL C0  无法进入仓库"; exit 1; }

PANEL="Sources/LeapinApp/Views/MenuBarPanel.swift"
FLOAT="Sources/LeapinApp/Views/FloatingStatusView.swift"
LINE="Sources/LeapinApp/Design/RouteLine.swift"
SCRATCH="${T20_SCRATCH:-/tmp/t20-scratch}"
LOGS="${T20_LOGDIR:-/tmp/t20-qa-logs}"
mkdir -p "$LOGS"

PASSED=0; FAILED=0
pass() { printf 'PASS %-3s %s\n' "$1" "$2"; PASSED=$((PASSED + 1)); }
fail() { printf 'FAIL %-3s %s\n' "$1" "$2"; FAILED=$((FAILED + 1)); }

for f in "$PANEL" "$FLOAT" "$LINE"; do
    [ -f "$f" ] || { echo "FAIL C0  缺少文件 $f"; exit 1; }
done

echo "T-20 验收 · 仓库 $ROOT"
echo "scratch=${SCRATCH} · 日志=${LOGS}"
echo "----------------------------------------------------------------"

# C1 构建
build_log="$LOGS/c1-build.log"
swift build --scratch-path "$SCRATCH" --disable-sandbox >"$build_log" 2>&1
rc=$?
errs=$(grep -c 'error:' "$build_log" || true)
warns=$(grep -E 'warning:' "$build_log" | grep -cE 'MenuBarPanel\.swift|FloatingStatusView\.swift|RouteLine\.swift' || true)
if [ "$rc" -eq 0 ] && [ "$errs" -eq 0 ] && [ "$warns" -eq 0 ]; then
    pass C1 "swift build --scratch-path ${SCRATCH} → exit 0；error ${errs}；本任务三个文件 warning ${warns}（要求 0）"
else
    fail C1 "swift build 退出码 ${rc}；error ${errs}；本任务文件 warning ${warns}；首个错误：$(grep -m1 'error:' "$build_log" || echo 无)"
fi

# C2 两处常驻面各有一条「路」缩略，且与首屏同一个数据源
panel_line=$(grep -cF 'compact: true)' "$PANEL" || true)
float_line=$(grep -cF 'compact: true)' "$FLOAT" || true)
panel_src=$(grep -cF 'status.exitGroup' "$PANEL" || true)
float_src=$(grep -cF 'status.exitGroup' "$FLOAT" || true)
# 同样别让 grep 多文件输出两行：先 cat 再数。
shared=$(cat "$PANEL" "$FLOAT" | grep -cF 'ResidentStatusStore.shared' || true)
if [ "$panel_line" -eq 1 ] && [ "$float_line" -eq 1 ] && [ "$panel_src" -ge 1 ] && [ "$float_src" -ge 1 ] && [ "$shared" -ge 2 ]; then
    pass C2 "菜单栏面板与浮窗各一条压缩形态的 RouteLine（各 ${panel_line}/${float_line} 处）；三项都取自 ResidentStatus（status.exitGroup 命中 ${panel_src}/${float_src}），并用同一个 ResidentStatusStore.shared（${shared} 处）"
else
    fail C2 "缩略不符：panel ${panel_line}（1）、float ${float_line}（1）、panel 取值 ${panel_src}（≥1）、float 取值 ${float_src}（≥1）、shared store ${shared}（≥2）"
fi

# C3 尺寸与条数：面板 280、浮窗最近 ≤2
width=$(grep -cF '.frame(width: 280)' "$PANEL" || true)
old_width=$(grep -cF '.frame(width: 276)' "$PANEL" || true)
recent=$(grep -cF 'ForEach(recent.prefix(2))' "$FLOAT" || true)
if [ "$width" -eq 1 ] && [ "$old_width" -eq 0 ] && [ "$recent" -eq 1 ]; then
    pass C3 "面板宽 280（旧 276 已无 ${old_width} 处）；浮窗最近列表只取前 2 条（${recent} 处）"
else
    fail C3 "尺寸/条数不符：width 280 ${width}（1）、旧 276 ${old_width}（0）、prefix(2) ${recent}（1）"
fi

# C4 空态与主按钮：未接管要说出口，两个常驻面各自最多一个主按钮
panel_empty=$(grep -cF '尚未接管' "$PANEL" || true)
float_empty=$(grep -cF '尚未接管' "$FLOAT" || true)
panel_primary=$(grep -cF 'LPPrimaryButtonStyle' "$PANEL" || true)
float_primary=$(grep -cF 'LPPrimaryButtonStyle' "$FLOAT" || true)
if [ "$panel_empty" -ge 1 ] && [ "$float_empty" -ge 1 ] && [ "$panel_primary" -le 1 ] && [ "$float_primary" -le 1 ]; then
    pass C4 "未接管时两处都写「尚未接管」（${panel_empty}/${float_empty}）；主按钮：面板 ${panel_primary} 个、浮窗 ${float_primary} 个（都要求 ≤1）"
else
    fail C4 "空态/主按钮不符：尚未接管 ${panel_empty}/${float_empty}（各 ≥1）、面板主按钮 ${panel_primary}（≤1）、浮窗主按钮 ${float_primary}（≤1）"
fi

# C5 动效遵守 reduce motion：走 lpAnimation / LPMotion，不直接用 withAnimation
panel_anim=$(grep -cF '.lpAnimation(LPMotion.quick' "$PANEL" || true)
float_anim=$(grep -cF '.lpAnimation(LPMotion.quick' "$FLOAT" || true)
# 两个文件分别数再加：grep -c 对多文件会输出两行，直接塞进 [ ] 会报 integer expression expected。
raw_anim=$(cat "$PANEL" "$FLOAT" | grep -cF 'withAnimation(' || true)
if [ "$panel_anim" -ge 1 ] && [ "$float_anim" -ge 1 ] && [ "$raw_anim" -eq 0 ]; then
    pass C5 "缩略的过渡走 lpAnimation(LPMotion.quick)（面板 ${panel_anim}、浮窗 ${float_anim} 处）；两处都没有裸 withAnimation（${raw_anim}，reduce motion 由 LPAnimationModifier 兜住）"
else
    fail C5 "动效不符：lpAnimation ${panel_anim}/${float_anim}（各 ≥1）、裸 withAnimation ${raw_anim}（0）"
fi

# C6 组件只加了一个形态，既有调用不受影响（默认 false）
default_off=$(grep -cF 'var compact: Bool = false' "$LINE" || true)
if [ "$default_off" -eq 1 ]; then
    pass C6 "RouteLine 的 compact 默认 false（${default_off} 处）——首屏与「为什么」页的既有调用不需要改"
else
    fail C6 "compact 默认值不符：${default_off}（1）"
fi

echo "----------------------------------------------------------------"
echo "T-20 结果：${PASSED} PASS / ${FAILED} FAIL（C1 构建 · C2 两处缩略同源 · C3 宽度与条数 · C4 空态与主按钮 · C5 reduce motion · C6 组件默认）"
[ "$FAILED" -eq 0 ]
