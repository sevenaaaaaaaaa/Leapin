#!/usr/bin/env bash
# T-13 验收：旧页收口（每个 rawValue 只落一个视图）+ Privacy 删除 + 设置组 + Platform 快照同步
# 用法：bash qa/T-13/run.sh
# 默认用独立 scratch（${T13_SCRATCH:-/tmp/t13-scratch}），不删目录（共用机器上构建）。
# 只读仓库，不改 Sources/ Tests/ docs/。任何一条 FAIL → 退出码 1。
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT" || { echo "FAIL C0  无法进入仓库"; exit 1; }

SCRATCH="${T13_SCRATCH:-/tmp/t13-scratch}"
LOGDIR="${T13_LOGDIR:-/tmp/t13-qa-logs}"
mkdir -p "$LOGDIR"

APP="Sources/LeapinApp/LeapinApp.swift"
PLATFORM="Sources/LeapinApp/Platform.swift"
SETTINGS="Sources/LeapinApp/Views/SettingsView.swift"
PRIVACY="Sources/LeapinApp/Views/PrivacyView.swift"
WORKBENCH="Sources/LeapinRuntime/Workbench.swift"

PASSED=0
FAILED=0
pass() { printf 'PASS %-3s %s\n' "$1" "$2"; PASSED=$((PASSED + 1)); }
fail() { printf 'FAIL %-3s %s\n' "$1" "$2"; FAILED=$((FAILED + 1)); }

for f in "$APP" "$PLATFORM" "$SETTINGS" "$WORKBENCH"; do
    [ -f "$f" ] || { echo "FAIL C0  缺少文件 $f"; exit 1; }
done

echo "T-13 验收 · 仓库 $ROOT"
echo "scratch=${SCRATCH}（复用，不清理）· 日志=${LOGDIR}"
echo "----------------------------------------------------------------"

# ---------------------------------------------------------------- C1 旧 rawValue 的 alias 表
map_dash=$(grep -cF 'case .dashboard: GoWherePage(initialTab: .overview)' "$APP" || true)
map_profiles=$(grep -cF 'case .profiles: GoWherePage(initialTab: .profiles)' "$APP" || true)
map_rules=$(grep -cF 'case .rules: RulesView()' "$APP" || true)
map_rewrite=$(grep -cF 'case .rewrite: RewriteView()' "$APP" || true)
map_adblock=$(grep -cF 'case .adblock: RewriteView()' "$APP" || true)
map_why=$(grep -cF 'case .why, .capture: WhyPage(initialTab: .connections)' "$APP" || true)
map_activity=$(grep -cF 'case .activity: WhyPage(initialTab: .metrics)' "$APP" || true)
map_diagnostics=$(grep -cF 'case .diagnostics: WhyPage(initialTab: .diagnostics)' "$APP" || true)
map_learn=$(grep -cF 'case .learn: LearnView()' "$APP" || true)
map_ssh=$(grep -cF 'case .ssh: SSHView()' "$APP" || true)
map_nas=$(grep -cF 'case .nas: NASView()' "$APP" || true)
map_settings=$(grep -cF 'case .settings: SettingsView()' "$APP" || true)
adblock_note=$(grep -cF 'RewriteView 没有 initialTab' "$APP" || true)
if [ "$map_dash" -eq 1 ] && [ "$map_profiles" -eq 1 ] && [ "$map_rules" -eq 1 ] && [ "$map_rewrite" -eq 1 ] \
   && [ "$map_adblock" -eq 1 ] && [ "$map_why" -eq 1 ] && [ "$map_activity" -eq 1 ] && [ "$map_diagnostics" -eq 1 ] \
   && [ "$map_learn" -eq 1 ] && [ "$map_ssh" -eq 1 ] && [ "$map_nas" -eq 1 ] && [ "$map_settings" -eq 1 ] \
   && [ "$adblock_note" -eq 1 ]; then
    pass C1 "12 条落点各 1 处：dashboard→GoWherePage(overview)、profiles→GoWherePage(profiles)、adblock→RewriteView()（无 initialTab，注释 ${adblock_note} 处）、activity→WhyPage(metrics)、diagnostics→WhyPage(diagnostics)、why/capture→WhyPage(connections)、learn 保留独立页、rules/rewrite/ssh/nas/settings 原页不动"
else
    fail C1 "alias 表不符：dash=${map_dash} profiles=${map_profiles} rules=${map_rules} rewrite=${map_rewrite} adblock=${map_adblock} why=${map_why} activity=${map_activity} diagnostics=${map_diagnostics} learn=${map_learn} ssh=${map_ssh} nas=${map_nas} settings=${map_settings}（各要求 1）；adblock 注释 ${adblock_note}（要求 1）"
fi

# ---------------------------------------------------------------- C2 每个 rawValue 只落一个视图
section_line=$(grep -A1 -m1 'enum Section: String, CaseIterable' "$APP" | tail -1)
section_raws=$(printf '%s' "$section_line" | sed -E 's/.*case //' | tr ',' ' ' | xargs)
section_count=$(printf '%s\n' $section_raws | grep -c . || true)
section_block=$(awk '/@ViewBuilder private var sectionContent: some View/{f=1} f{print} f && /^    }$/{exit}' "$APP")
branch_count=$(printf '%s\n' "$section_block" | grep -cE '^        case [.]' || true)
default_branch=$(printf '%s\n' "$section_block" | grep -cE '^        default:' || true)
dups=""
for raw_case in $section_raws; do
    n=$(printf '%s\n' "$section_block" | grep -cE "^        case [^:]*[.]${raw_case}([,:]| )" || true)
    [ "$n" -eq 1 ] || dups="${dups} ${raw_case}=${n}"
done
# 分支数与 case 数不必相等：.why 与 .capture 是同一页的两个 rawValue，共用一条 alias 分支（有意为之）。
# 判据是「每个 rawValue 恰好出现在一条分支上」+「没有 default: 兜底」——后者才会让漏页静默过关。
if [ -z "$dups" ] && [ "$default_branch" -eq 0 ] && [ "$branch_count" -ge 1 ]; then
    pass C2 "Section ${section_count} 个 rawValue 落在 sectionContent 的 ${branch_count} 条 case 分支上（.why/.capture 共用 1 条 alias 分支）；逐个 rawValue 回查都恰好 1 条（重复=[${dups:- 无}]）；没有 default: 兜底（${default_branch} 处），漏一个 case 编译就过不去"
else
    fail C2 "落点不唯一或靠 default 兜底：Section ${section_count} 个、分支 ${branch_count} 条、default ${default_branch}（要求 0）；重复落点=[${dups:- 无}]（每个 rawValue 必须恰好 1 条）；case 列表=[${section_raws}]"
fi

# ---------------------------------------------------------------- C3 Privacy 不可达
app_privacy=$(grep -c 'privacy' "$APP" || true)
plat_privacy=$(grep -c 'privacy' "$PLATFORM" || true)
src_hits=$(grep -rl 'PrivacyView' Sources/ Tests/ 2>/dev/null | tr '\n' ' ')
file_gone=0; [ -f "$PRIVACY" ] || file_gone=1
section_has=$(printf '%s' "$section_line" | grep -cE '(^|[, ])privacy(,|$)' || true)
if [ "$app_privacy" -eq 0 ] && [ "$plat_privacy" -eq 0 ] && [ "$file_gone" -eq 1 ] && [ -z "$src_hits" ] && [ "$section_has" -eq 0 ]; then
    pass C3 "privacy 在 LeapinApp.swift 0 次、Platform.swift 0 次、Section 枚举 0 次；PrivacyView.swift 已删除；Sources/ Tests/ 里再无 PrivacyView 引用（NetworkTask.privacy 与 NetworkScenes.privacy 是别的枚举，按口径不算命中）"
else
    fail C3 "privacy 仍可达：LeapinApp=${app_privacy}（0）、Platform=${plat_privacy}（0）、Section=${section_has}（0）、PrivacyView.swift 是否还在=$((1 - file_gone))（要求 0）、PrivacyView 引用=[${src_hits:- 无}]"
fi

# ---------------------------------------------------------------- C4 设置：起页来源 + 快捷键 + 隐私与数据四行
start_from_plan=$(grep -cF 'WorkbenchSidebar.rows.compactMap' "$SETTINGS" || true)
start_allcases=$(grep -cF 'AppModel.Section.allCases' "$SETTINGS" || true)
shortcut_verbs=$(grep -cF 'shortcutLine("⌘1 – ⌘4", "动词 · ⌘K 命令面板")' "$SETTINGS" || true)
shortcut_old=$(grep -cF '直接跳到十个页面' "$SETTINGS" || true)
privacy_card=$(grep -cF 'Card(title: "隐私与数据"' "$SETTINGS" || true)
fact_rows=$(grep -c 'FactRow(label:' "$SETTINGS" || true)
fact_proxy=$(grep -c 'FactRow(label: "系统代理"' "$SETTINGS" || true)
fact_dns=$(grep -c 'FactRow(label: "DNS"' "$SETTINGS" || true)
fact_log=$(grep -c 'FactRow(label: "日志"' "$SETTINGS" || true)
fact_key=$(grep -c 'FactRow(label: "凭据"' "$SETTINGS" || true)
section_dest=$(grep -c 'destination: [.]section(' "$WORKBENCH" || true)
if [ "$start_from_plan" -eq 1 ] && [ "$start_allcases" -eq 0 ] && [ "$shortcut_verbs" -eq 1 ] && [ "$shortcut_old" -eq 0 ] \
   && [ "$privacy_card" -eq 1 ] && [ "$fact_rows" -eq 4 ] && [ "$fact_proxy" -eq 1 ] && [ "$fact_dns" -eq 1 ] \
   && [ "$fact_log" -eq 1 ] && [ "$fact_key" -eq 1 ] && [ "$section_dest" -eq 7 ]; then
    pass C4 "「启动时打开」读 WorkbenchSidebar.rows（${start_from_plan} 处），不再用 Section.allCases（${start_allcases} 处，要求 0）；侧栏落点是 Section 的行 ${section_dest} 行（=可作起页的行数）；快捷键行是「⌘1 – ⌘4 · 动词 · ⌘K 命令面板」（旧文案命中 ${shortcut_old}，要求 0）；「隐私与数据」卡 ${fact_rows} 行事实：系统代理 / DNS / 日志 / 凭据各 1"
else
    fail C4 "设置页不符：计划来源 ${start_from_plan}（1）、Section.allCases ${start_allcases}（0）、⌘1–⌘4 文案 ${shortcut_verbs}（1）、旧文案 ${shortcut_old}（0）、隐私卡 ${privacy_card}（1）、事实行 ${fact_rows}（4，系统代理 ${fact_proxy}/DNS ${fact_dns}/日志 ${fact_log}/凭据 ${fact_key}）、侧栏 Section 落点 ${section_dest}（7）"
fi

# ---------------------------------------------------------------- C5 Platform 快照映射 + RouteContext + Dock 文案 + 页头
snap_region=$(awk '/LEAPIN_SNAPSHOT_VIEW/{f=1} f{print} /let host = NSHostingView/{if (f) exit}' "$PLATFORM")
snap_dash=$(printf '%s\n' "$snap_region" | grep -cF 'case "dashboard": content = AnyView(GoWherePage(initialTab: .overview)' || true)
snap_profiles=$(printf '%s\n' "$snap_region" | grep -cF 'case "profiles": content = AnyView(GoWherePage(initialTab: .profiles)' || true)
snap_why=$(printf '%s\n' "$snap_region" | grep -cF 'case "capture", "why": content = AnyView(WhyPage(initialTab: .connections)' || true)
snap_activity=$(printf '%s\n' "$snap_region" | grep -cF 'case "activity": content = AnyView(WhyPage(initialTab: .metrics)' || true)
snap_diag=$(printf '%s\n' "$snap_region" | grep -cF 'case "diagnostics": content = AnyView(WhyPage(initialTab: .diagnostics)' || true)
snap_adblock=$(printf '%s\n' "$snap_region" | grep -cF 'case "adblock": content = AnyView(RewriteView()' || true)
snap_privacy=$(printf '%s\n' "$snap_region" | grep -cF '"privacy"' || true)
routes_env=$(grep -cF '.environmentObject(model.routes)' "$PLATFORM" || true)
host_line=$(grep -cF 'host.appearance = NSAppearance(named: .aqua)' "$PLATFORM" || true)
dock_line=$(grep -cF 'for section in [AppModel.Section.dashboard, .rules, .why, .settings]' "$PLATFORM" || true)
dock_title=$(grep -cF 'NSMenuItem(title: section.headerTitle' "$PLATFORM" || true)
header_title=$(grep -cF 'PageHeader(title: section.headerTitle' "$APP" || true)
header_props=$(grep -cF 'var headerTitle: String { verb?.title ?? title }' "$APP" || true)
if [ "$snap_dash" -eq 1 ] && [ "$snap_profiles" -eq 1 ] && [ "$snap_why" -eq 1 ] && [ "$snap_activity" -eq 1 ] \
   && [ "$snap_diag" -eq 1 ] && [ "$snap_adblock" -eq 1 ] && [ "$snap_privacy" -eq 0 ] && [ "$routes_env" -eq 1 ] \
   && [ "$host_line" -eq 1 ] && [ "$dock_line" -eq 1 ] && [ "$dock_title" -eq 1 ] \
   && [ "$header_title" -eq 1 ] && [ "$header_props" -eq 1 ]; then
    pass C5 "Debug 快照：dashboard→GoWherePage(overview)、profiles→GoWherePage(profiles)、capture/why→WhyPage(connections)、activity→WhyPage(metrics)、diagnostics→WhyPage(diagnostics)、adblock→RewriteView()，privacy ${snap_privacy} 处；WhyPage 需要的 RouteContext 已补 .environmentObject(model.routes)（${routes_env} 处）；:137 的 host.appearance 仍在（${host_line} 处）；Dock 菜单改列 .why 且标题读 headerTitle；页头用 section.headerTitle"
else
    fail C5 "Platform/页头不符：snapshot dash=${snap_dash} profiles=${snap_profiles} why=${snap_why} activity=${snap_activity} diag=${snap_diag} adblock=${snap_adblock}（各 1）、privacy=${snap_privacy}（0）、routes=${routes_env}（1）、host.appearance=${host_line}（1）、dock 列=${dock_line}（1）、dock 标题=${dock_title}（1）、PageHeader headerTitle=${header_title}（1）、headerTitle 定义=${header_props}（1）"
fi

# ---------------------------------------------------------------- C6 构建
build_log="$LOGDIR/c6-build.log"
swift build --scratch-path "$SCRATCH" --disable-sandbox >"$build_log" 2>&1
rc=$?
errs=$(grep -c 'error:' "$build_log" || true)
task_warns=$(grep -E 'warning:' "$build_log" | grep -cE 'LeapinApp.swift|Platform.swift|SettingsView.swift' || true)
if [ "$rc" -eq 0 ] && [ "$errs" -eq 0 ] && [ "$task_warns" -eq 0 ]; then
    pass C6 "swift build --scratch-path ${SCRATCH} --disable-sandbox → exit 0；error: ${errs} 个、本任务三个源文件上的 warning ${task_warns} 个（要求 0）；日志 ${build_log}"
else
    fail C6 "swift build 退出码 ${rc}；error: ${errs} 个、本任务文件 warning ${task_warns} 个（要求 0）；首个错误：$(grep -m1 'error:' "$build_log" || echo '（无 error: 行）')"
fi

# ---------------------------------------------------------------- C7 全量测试
test_log="$LOGDIR/c7-test.log"
swift test --scratch-path "$SCRATCH" --disable-sandbox >"$test_log" 2>&1
rc=$?
failed_cases=$(grep -cE "Test Case '.*' failed" "$test_log" || true)
summary=$(grep -E 'Executed [0-9]+ tests?, with [0-9]+ failures?' "$test_log" | tail -1)
if [ "$rc" -eq 0 ] && [ "$failed_cases" -eq 0 ] && [ -n "$summary" ] && printf '%s' "$summary" | grep -q 'with 0 failures'; then
    pass C7 "swift test --scratch-path ${SCRATCH} --disable-sandbox → exit 0；失败用例 ${failed_cases} 个；汇总：${summary}"
else
    fail C7 "全量测试未全绿：退出码 ${rc}、失败用例 ${failed_cases}、汇总：${summary:-（没有汇总行）}；首个失败：$(grep -m1E "Test Case .* failed" "$test_log" || echo '无')"
fi

# ---------------------------------------------------------------- 汇总
echo "----------------------------------------------------------------"
echo "T-13 结果：${PASSED} PASS / ${FAILED} FAIL（C1 alias 表 · C2 一 rawValue 一落点 · C3 Privacy 不可达 · C4 设置起页与隐私事实 · C5 Platform 与页头 · C6 构建 · C7 全量测试）"
if [ "$FAILED" -gt 0 ]; then
    exit 1
fi
exit 0

# 反向验证（证明这些断言能红，不只是恒绿）：
#   cp Sources/LeapinApp/LeapinApp.swift /tmp/T13-app-broken.swift
#   把 .activity 那行复制成两条（同一个 rawValue 落两次），再 T13_APP 指向它跑本脚本 →
#   预期 C2 FAIL（activity=2）。本脚本不读 T13_APP；反向验证时用临时仓库副本：
#   rsync -a --exclude .build ./ /tmp/t13-red/ && perl -0pi -e 's/(case [.]activity: WhyPage\(initialTab: [.]metrics\))/$1\n        case .ssh: WhyPage(initialTab: .metrics)/' /tmp/t13-red/Sources/LeapinApp/LeapinApp.swift
#   (cd /tmp/t13-red && bash qa/T-13/run.sh)   # 预期 C2 FAIL、退出码 1
