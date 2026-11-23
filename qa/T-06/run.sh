#!/usr/bin/env bash
# T-06 验收：11 行侧栏 + why / dashboard 落点 + 两个空壳
# 用法：bash qa/T-06/run.sh
# 默认复用 scratch（${T06_SCRATCH:-/tmp/t06-scratch}），不删目录（共用机器上构建）。
# 只读仓库，不改 Sources/ Tests/ docs/。任何一条 FAIL → 退出码 1。
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT" || { echo "FAIL C0  无法进入仓库"; exit 1; }

SCRATCH="${T06_SCRATCH:-/tmp/t06-scratch}"
LOGDIR="${T06_LOGDIR:-/tmp/t06-qa-logs}"
mkdir -p "$LOGDIR"

APP="Sources/LeapinApp/LeapinApp.swift"
PALETTE="Sources/LeapinApp/Design/CommandPalette.swift"
WHY="Sources/LeapinApp/Views/WhyPage.swift"
GOWHERE="Sources/LeapinApp/Views/GoWherePage.swift"
WORKBENCH="Sources/LeapinRuntime/Workbench.swift"

PASSED=0
FAILED=0
pass() { printf 'PASS %-3s %s\n' "$1" "$2"; PASSED=$((PASSED + 1)); }
fail() { printf 'FAIL %-3s %s\n' "$1" "$2"; FAILED=$((FAILED + 1)); }

for f in "$APP" "$PALETTE" "$WORKBENCH" "$WHY" "$GOWHERE"; do
    [ -f "$f" ] || { echo "FAIL C0  缺少文件 $f"; exit 1; }
done

echo "T-06 验收 · 仓库 $ROOT"
echo "scratch=${SCRATCH}（复用，不清理）· 日志=${LOGDIR}"
echo "----------------------------------------------------------------"

# ---------------------------------------------------------------- C1 构建
build_log="$LOGDIR/c1-build.log"
swift build --scratch-path "$SCRATCH" --disable-sandbox >"$build_log" 2>&1
rc=$?
errs=$(grep -c 'error:' "$build_log" || true)
warns=$(grep -c 'warning:' "$build_log" || true)
task_warns=$(grep -E 'warning:' "$build_log" | grep -cE 'LeapinApp\.swift|WhyPage\.swift|GoWherePage\.swift|CommandPalette\.swift' || true)
if [ "$rc" -eq 0 ] && [ "$errs" -eq 0 ] && [ "$task_warns" -eq 0 ]; then
    pass C1 "swift build --scratch-path ${SCRATCH} --disable-sandbox → exit 0；日志 error: ${errs} 个、warning: ${warns} 个，其中落在本任务四个源文件上的 ${task_warns} 个（要求 0）；日志 ${build_log}"
else
    fail C1 "swift build 退出码 ${rc}；error: ${errs} 个（要求 0）、本任务文件 warning ${task_warns} 个（要求 0）；首个错误：$(grep -m1 'error:' "$build_log" || echo '（无 error: 行）')"
fi

# ---------------------------------------------------------------- C2 侧栏换成 WorkbenchSidebar 计划
sidebar_region=$(awk '/private struct SidebarView: View/{f=1} f{print} f && /private struct StatusCard: View/{exit}' "$APP")
has_plan=$(printf '%s\n' "$sidebar_region" | grep -cF 'WorkbenchSidebar.groups' || true)
uses_rows=$(printf '%s\n' "$sidebar_region" | grep -cF 'group.rows' || true)
stale_prefix=$(grep -cF 'Section.allCases.prefix(10)' "$APP" || true)
old_table=$(grep -cE 'static let groups: \[\(title' "$APP" || true)
palette_allcases=$(grep -cF 'Section.allCases' "$PALETTE" || true)
group_count=$(grep -c 'Group(name:' "$WORKBENCH" || true)
row_count=$(grep -c '^            Row(title:' "$WORKBENCH" || true)
verb_dest=$(grep -c 'destination: \.section(WorkbenchVerb\.' "$WORKBENCH" || true)
# 侧栏每一行都要落在一个真实存在的 Section 上：把 Workbench.swift 里的字母落点逐个回查 Section 的 case 列表。
section_line=$(grep -A1 -m1 'enum Section: String, CaseIterable' "$APP" | tail -1)
section_raws=$(sed -n 's/.*destination: \.section("\([a-z0-9]*\)").*/\1/p' "$WORKBENCH" | sort -u | tr '\n' ' ')
dead_raws=""
for raw in $section_raws; do
    printf '%s' "$section_line" | grep -qE "(^|[, ])${raw}(,|$)" || dead_raws="$dead_raws $raw"
done
section_case_count=$(printf '%s' "$section_line" | tr ',' '\n' | grep -cE '^ *[a-z0-9]+ *$' || true)
if [ "$has_plan" -ge 1 ] && [ "$uses_rows" -ge 1 ] && [ "$stale_prefix" -eq 0 ] && [ "$old_table" -eq 0 ] \
   && [ "$palette_allcases" -eq 0 ] && [ "$group_count" -eq 3 ] && [ "$row_count" -eq 11 ] \
   && [ "$verb_dest" -eq 4 ] && [ -z "$dead_raws" ]; then
    pass C2 "侧栏读 WorkbenchSidebar.groups（命中 ${has_plan} 次、group.rows ${uses_rows} 次）；旧 4 组 13 行表与 Section.allCases.prefix(10) 均已消失（prefix ${stale_prefix}、旧表 ${old_table}、命令面板里的 Section.allCases ${palette_allcases}）；计划侧 ${group_count} 组 / ${row_count} 行 / ${verb_dest} 个动词落点；侧栏字母落点 [${section_raws% }] 全部能在 Section 的 ${section_case_count} 个 case 里找到"
else
    fail C2 "侧栏计划不符：WorkbenchSidebar.groups=${has_plan}（要求 ≥1）、group.rows=${uses_rows}（≥1）、prefix(10)=${stale_prefix}（0）、旧表=${old_table}（0）、palette Section.allCases=${palette_allcases}（0）、组=${group_count}（3）、行=${row_count}（11）、动词落点=${verb_dest}（4）、死落点=[${dead_raws:- 无}]"
fi

# ---------------------------------------------------------------- C3 ⌘1..⌘4 从计划读，T-02 区不动
menu_region=$(sed -n '/CommandMenu("前往")/,/MenuBarExtra {/p' "$APP")
menu_rows=$(printf '%s\n' "$menu_region" | grep -cF 'WorkbenchSidebar.rows' || true)
menu_kbd=$(printf '%s\n' "$menu_region" | grep -cF 'keyboardShortcut(Self.key(for: row.shortcut' || true)
menu_split=$(printf '%s\n' "$menu_region" | grep -cF 'filter { $0.shortcut != nil }' || true)
menu_allcases=$(printf '%s\n' "$menu_region" | grep -cF 'Section.allCases' || true)
verb_shortcuts=$(grep -c 'shortcut: WorkbenchVerb\.' "$WORKBENCH" || true)
shortcut_block=$(awk '/public var shortcut: String \{/{f=1} f{print} f && /^    \}$/{exit}' "$WORKBENCH")
keys=$(printf '%s\n' "$shortcut_block" | grep -cE ': return "[1-4]"' || true)
p_bind=$(grep -c 'keyboardShortcut("p", modifiers: \[.command, .shift\])' "$APP" || true)
y_bind=$(grep -c 'keyboardShortcut("y", modifiers: \[.command, .shift\])' "$APP" || true)
menubar_label=$(grep -c 'private struct MenuBarLabel' "$APP" || true)
menubar_extra=$(grep -c 'MenuBarExtra {' "$APP" || true)
if [ "$menu_rows" -ge 1 ] && [ "$menu_kbd" -eq 1 ] && [ "$menu_split" -ge 1 ] && [ "$menu_allcases" -eq 0 ] \
   && [ "$verb_shortcuts" -eq 4 ] && [ "$keys" -eq 4 ] \
   && [ "$p_bind" -eq 1 ] && [ "$y_bind" -eq 1 ] && [ "$menubar_label" -eq 1 ] && [ "$menubar_extra" -eq 1 ]; then
    pass C3 "「前往」菜单从 WorkbenchSidebar.rows 生成（命中 ${menu_rows} 次），四动词按 row.shortcut 挂 keyboardShortcut（命中 ${menu_kbd} 次，split ${menu_split} 处），菜单里已无 Section.allCases；计划里 ${verb_shortcuts} 行带 shortcut、shortcut 函数含 ${keys} 个 1..4；T-02 区未动：⌘⇧P ${p_bind}、⌘⇧Y ${y_bind}、MenuBarLabel ${menubar_label}、MenuBarExtra ${menubar_extra}"
else
    fail C3 "⌘1..⌘4 接线不符：菜单读计划 ${menu_rows}（≥1）、row.shortcut 键位 ${menu_kbd}（1）、split ${menu_split}（≥1）、菜单 Section.allCases ${menu_allcases}（0）、带 shortcut 的行 ${verb_shortcuts}（4）、1..4 值 ${keys}（4）、⌘⇧P ${p_bind}（1）、⌘⇧Y ${y_bind}（1）、MenuBarLabel ${menubar_label}（1）、MenuBarExtra ${menubar_extra}（1）"
fi

# ---------------------------------------------------------------- C4 导入行走导入中心
dispatch_block=$(awk '/func dispatch\(_ destination: WorkbenchDestination\)/{f=1} f{print} f && /^    \}$/{exit}' "$APP")
import_begin=$(printf '%s\n' "$dispatch_block" | grep -A1 -F 'case .importCenter:' | grep -cF 'beginImport()' || true)
home_sheet=$(printf '%s\n' "$dispatch_block" | grep -cF 'case .home: showHome = true' || true)
company_sheet=$(printf '%s\n' "$dispatch_block" | grep -cF 'case .company: showCompany = true' || true)
tools_sheet=$(printf '%s\n' "$dispatch_block" | grep -cF 'case .networkTools: showNetworkTools = true' || true)
sidebar_importer=$(printf '%s\n' "$sidebar_region" | grep -cF 'showImporter' || true)
import_row=$(grep -cF 'destination: .importCenter' "$WORKBENCH" || true)
if [ "$import_begin" -eq 1 ] && [ "$home_sheet" -eq 1 ] && [ "$company_sheet" -eq 1 ] && [ "$tools_sheet" -eq 1 ] \
   && [ "$sidebar_importer" -eq 0 ] && [ "$import_row" -eq 1 ]; then
    pass C4 ".importCenter → beginImport()（命中 ${import_begin} 处）；三件工具行各走自己的 sheet（home ${home_sheet} / company ${company_sheet} / networkTools ${tools_sheet}）；侧栏内 showImporter ${sidebar_importer} 处（要求 0）；计划里导入行 destination .importCenter ${import_row} 处"
else
    fail C4 "导入行不符：beginImport=${import_begin}（1）、home=${home_sheet}（1）、company=${company_sheet}（1）、networkTools=${tools_sheet}（1）、侧栏 showImporter=${sidebar_importer}（0）、计划导入行=${import_row}（1）"
fi

# ---------------------------------------------------------------- C5 两个壳 + sectionContent 映射 + routes
why_tabs=$(grep -cF 'case connections, metrics, probes, diagnostics' "$WHY" || true)
why_titles=$(grep -cE 'return "(连接|指标|探测|诊断)"' "$WHY" || true)
# T-07 落地后按预期更新：连接 tab 从空壳 `CaptureView()` 变成注入式
# `CaptureView(initialSearch: seed)`。这里接受「前缀 + initialSearch」，
# 同时仍然拒绝退回无参空壳（那样 initialSearch 命中会是 0）。
why_capture=$(grep -cF 'case .connections: CaptureView(' "$WHY" || true)
why_seed=$(grep -cF 'initialSearch:' "$WHY" || true)
go_tabs=$(grep -cF 'case overview, profiles' "$GOWHERE" || true)
go_titles=$(grep -cE 'return "(总览|配置与订阅)"' "$GOWHERE" || true)
go_dashboard=$(grep -cF 'case .overview: DashboardView()' "$GOWHERE" || true)
# T-08（走哪重写）的 DoD 明确给 ProfilesView 加了「作为 tab 时不显示页面大标题」的参数，
# 落点从 `ProfilesView()` 变成带参构造。这里只要求「带参数」，不钉参数名：
# 退回无参空壳仍然会 FAIL。
go_profiles=$(grep -cE 'case \.profiles: ProfilesView\([^)]' "$GOWHERE" || true)
map_why=$(grep -cF 'case .why, .capture: WhyPage(initialTab: .connections)' "$APP" || true)
map_dash=$(grep -cF 'case .dashboard: GoWherePage(initialTab: .overview)' "$APP" || true)
why_section=$(grep -cF 'case .why: return "为什么"' "$APP" || true)
routes=$(grep -cF 'let routes = RouteContext()' "$APP" || true)
routes_env=$(grep -cF '.environmentObject(app.routes)' "$APP" || true)
if [ "$why_tabs" -eq 1 ] && [ "$why_titles" -eq 4 ] && [ "$why_capture" -eq 1 ] && [ "$why_seed" -ge 1 ] \
   && [ "$go_tabs" -eq 1 ] && [ "$go_titles" -eq 2 ] && [ "$go_dashboard" -eq 1 ] && [ "$go_profiles" -eq 1 ] \
   && [ "$map_why" -eq 1 ] && [ "$map_dash" -eq 1 ] && [ "$why_section" -eq 1 ] \
   && [ "$routes" -eq 1 ] && [ "$routes_env" -eq 1 ]; then
    pass C5 "WhyPage 四 tab（${why_titles} 个标题，连接=CaptureView(initialSearch:) ${why_seed} 处）/ GoWherePage 两 tab（${go_titles} 个标题，总览=DashboardView、配置=ProfilesView(带参数)）；sectionContent 里 .why 与 .capture → WhyPage(initialTab: .connections)（${map_why}）、.dashboard → GoWherePage(initialTab: .overview)（${map_dash}）；Section 增加 why（${why_section}）；AppModel.routes = RouteContext()（${routes}）并 environmentObject 下发（${routes_env}）"
else
    fail C5 "壳或映射不全：WhyPage 四 tab ${why_tabs}/标题 ${why_titles}（4）、连接=CaptureView(前缀 ${why_capture}、initialSearch ${why_seed})；GoWherePage 两 tab ${go_tabs}/标题 ${go_titles}（2）、总览 ${go_dashboard}、配置 ${go_profiles}；映射 .why/.capture ${map_why}、.dashboard ${map_dash}；Section.why 标题 ${why_section}；routes ${routes}、environmentObject ${routes_env}"
fi

# ---------------------------------------------------------------- C6 T-05 的 24 条仍绿
test_log="$LOGDIR/c6-test.log"
swift test --scratch-path "$SCRATCH" --disable-sandbox --filter WorkbenchTests >"$test_log" 2>&1
rc=$?
cases=$(grep -cE "Test Case '-\[LeapinRuntimeTests\.WorkbenchTests .*\]' passed" "$test_log" || true)
total=$(grep -cF 'Executed 24 tests, with 0 failures' "$test_log" || true)
if [ "$rc" -eq 0 ] && [ "$cases" -eq 24 ] && [ "$total" -ge 1 ]; then
    pass C6 "swift test --filter WorkbenchTests → exit 0；逐条 passed ${cases} 条，汇总行含 Executed 24 tests, with 0 failures（命中 ${total} 次）"
else
    fail C6 "WorkbenchTests 未全绿：退出码 ${rc}、逐条 passed ${cases}（要求 24）、'Executed 24 tests, with 0 failures' 命中 ${total}；失败用例：$(grep -m3 'failed (' "$test_log" || echo '无')"
fi

# ---------------------------------------------------------------- 汇总
echo "----------------------------------------------------------------"
echo "T-06 结果：${PASSED} PASS / ${FAILED} FAIL（C1 构建 · C2 11 行侧栏 · C3 ⌘1..⌘4 · C4 导入行 · C5 两个壳与映射 · C6 WorkbenchTests 24）"
if [ "$FAILED" -gt 0 ]; then
    exit 1
fi
exit 0
