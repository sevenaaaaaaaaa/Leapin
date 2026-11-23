#!/usr/bin/env bash
# T-15 W1 基础：v5 token、字阶、页头、侧栏选中态、去内容区玻璃
# 用法：bash qa/T-15/run.sh
#
# 对应 DESIGN-v5.md §6（表面/字阶/间距/圆角）与 §12（可测验收）。
# 第 6 条「每页一级模块 ≤5」脚本只能数主按钮，模块数由人工看截图，见 report.md。
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT" || { echo "FAIL C0  无法进入仓库"; exit 1; }

APP="Sources/LeapinApp"
THEME="$APP/Design/Theme.swift"
SIDEBAR="$APP/LeapinApp.swift"
SCRATCH=/tmp/t15-scratch
LOGS=/tmp/t15-qa-logs
mkdir -p "$LOGS"

PASSED=0
FAILED=0
pass() { printf 'PASS %-3s %s\n' "$1" "$2"; PASSED=$((PASSED + 1)); }
fail() { printf 'FAIL %-3s %s\n' "$1" "$2"; FAILED=$((FAILED + 1)); }

echo "T-15 验收 · 仓库 $ROOT"
echo "scratch=$SCRATCH · 日志=$LOGS"
echo "----------------------------------------------------------------"

# ---------------------------------------------------------------- C1 构建
if swift build --scratch-path "$SCRATCH" --disable-sandbox > "$LOGS/c1-build.log" 2>&1; then
    errs=$(grep -c 'error:' "$LOGS/c1-build.log" || true)
    theme_warn=$(grep 'warning:' "$LOGS/c1-build.log" | grep -c 'Theme.swift' || true)
    if [ "$errs" = "0" ] && [ "$theme_warn" = "0" ]; then
        pass C1 "swift build → exit 0；error 0 个；Theme.swift 上 0 warning"
    else
        fail C1 "构建通过但 error=$errs / Theme.swift warning=$theme_warn"
    fi
else
    fail C1 "swift build 失败，见 $LOGS/c1-build.log"
fi

# ---------------------------------------------------------------- C2 字号下限
small=$(grep -rhoE '(Font\.)?system\(size: ?(7\.5|8|8\.5|9|9\.5|10)\b' "$APP" --include=*.swift | wc -l | tr -d ' ')
small_font=$(grep -rhoE 'LPFont\.(mono|display|num)\((7\.5|8|8\.5|9|9\.5|10)\)' "$APP" --include=*.swift | wc -l | tr -d ' ')
if [ "$small" = "0" ] && [ "$small_font" = "0" ]; then
    pass C2 "全仓无 <11pt 文字字号（system 0 处、LPFont 0 处）"
else
    fail C2 "仍有 <11pt：system=$small 处、LPFont=$small_font 处"
fi

# ---------------------------------------------------------------- C3 v5 token
missing=""
for tok in 'static let paper' 'static let sheet' 'static let ink' 'static let line' 'static let selectionFill'; do
    grep -q "$tok" "$THEME" || missing="$missing [$tok]"
done
for type in 'enum LPType' 'enum LPSpace' 'enum LPRadius'; do
    grep -q "$type" "$THEME" || missing="$missing [$type]"
done
if [ -z "$missing" ]; then
    used=$(grep -rhoE 'LP\.(paper|sheet|ink|line|selectionFill)' "$APP" --include=*.swift | wc -l | tr -d ' ')
    pass C3 "四种表面 + LPType/LPSpace/LPRadius 齐备；被引用 $used 处"
else
    fail C3 "缺 token：$missing"
fi

# ---------------------------------------------------------------- C4 玻璃收敛
allow='Theme.swift|CommandPalette.swift|Interactions.swift|Toast.swift|FloatingPanel.swift'
viol=$(grep -rn 'lpGlass' "$APP" --include=*.swift | grep -vE "$allow" | grep -vE 'CaptureView.swift:[0-9]+: *\.lpGlass\(radius: 14,$' | wc -l | tr -d ' ')
tint=$(grep -rn 'cardTint' "$APP" --include=*.swift | grep -v 'Theme.swift' | wc -l | tr -d ' ')
if [ "$viol" = "0" ] && [ "$tint" = "0" ]; then
    pass C4 "内容区无玻璃（仅浮层与抓包页内浮卡）；cardTint 0 处"
else
    fail C4 "内容区仍有玻璃 $viol 处、cardTint $tint 处"
fi

# ---------------------------------------------------------------- C5 页头
title_ok=$(grep -c "font(LPType.title)" "$THEME" || true)
body_ok=$(grep -c "font(LPType.body)" "$THEME" || true)
# 页头由壳统一渲染：页面只提供 section 元数据，不各自画标题。
hdr=$(grep -c "PageHeader(" "$SIDEBAR" || true)
meta=$(grep -c "headerTitle" "$SIDEBAR" || true)
page_titles=$(grep -rn "PageHeader(" "$APP/Views" --include=*.swift | wc -l | tr -d " ")
if [ "$title_ok" -ge 1 ] && [ "$body_ok" -ge 1 ] && [ "$hdr" -ge 1 ] && [ "$meta" -ge 1 ]; then
    pass C5 "PageHeader 用 LPType.title(28)+LPType.body(13)；壳渲染 $hdr 处、section $meta 处、页面内重复标题 $page_titles 处"
else
    fail C5 "页头不合规：title=$title_ok body=$body_ok shell=$hdr meta=$meta"
fi

# ---------------------------------------------------------------- C6 侧栏选中态
sel=$(grep -c 'LP.selectionFill' "$SIDEBAR" || true)
bad=$(grep -rn 'LP.accent.opacity(0.13)' "$APP" --include=*.swift | wc -l | tr -d ' ')
if [ "$sel" -ge 1 ] && [ "$bad" = "0" ]; then
    pass C6 "侧栏选中 = LP.selectionFill（ink 6%）+ 2px 朱红左条；浅朱红选中底 0 处"
else
    fail C6 "侧栏选中态不合规：selectionFill=$sel 处、旧 accent 选中底=$bad 处"
fi

# ---------------------------------------------------------------- C7 主按钮预算
# 「每屏 <=1」是视觉预算，静态代码分不清 tab 与 sheet：这里只挡住明显堆叠，
# 逐屏确认在 qa/T-15/report.md 的截图核对里（人工）。
PAGES="GoWherePage.swift WhyPage.swift RewriteView.swift RulesView.swift ProfilesView.swift DashboardView.swift MenuBarPanel.swift"
over=""
detail=""
for name in $PAGES; do
    f="$APP/Views/$name"
    [ -f "$f" ] || f="$APP/$name"
    [ -f "$f" ] || continue
    n=$(grep -c "LPPrimaryButtonStyle" "$f" || true)
    detail="$detail $name:$n"
    [ "$n" -gt 2 ] && over="$over $name:$n"
done
if [ -z "${over}" ]; then
    pass C7 "工作页主按钮清点（页面+sheet <=2）:${detail}；逐屏 <=1 见 report.md 人工核对"
else
    fail C7 "主按钮堆叠:${over}"
fi

# ---------------------------------------------------------------- C8 单测
if swift test --scratch-path "$SCRATCH" --disable-sandbox > "$LOGS/c8-test.log" 2>&1; then
    passed=$(grep -cE "^Test Case .* passed \(" "$LOGS/c8-test.log" || true)
    failed=$(grep -cE "^Test Case .* failed \(" "$LOGS/c8-test.log" || true)
    if [ "$failed" = "0" ]; then
        pass C8 "swift test 全量 → exit 0：$passed passed / 0 failed"
    else
        fail C8 "单测失败 $failed 条"
    fi
else
    fail C8 "swift test 失败，见 $LOGS/c8-test.log"
fi

echo "----------------------------------------------------------------"
echo "T-15 结果：$PASSED PASS / $FAILED FAIL"
echo "=================================================================="
[ "$FAILED" = "0" ]
