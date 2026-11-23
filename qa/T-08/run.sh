#!/usr/bin/env bash
# T-08 验收：「走哪」总览重写 + 配置与订阅 tab
# 用法：bash qa/T-08/run.sh
# 默认复用 scratch（${T08_SCRATCH:-/tmp/t08-scratch}），不删目录（共用机器上构建）。
# 只读仓库，不改 Sources/ Tests/ docs/。任何一条 FAIL → 退出码 1。
#
# 判的是任务表 T-08 的四条 DoD 里可自动化的部分：
#   五事实（ResidentStatusStore + coverage.declaration）/ 四入口（各带一句状态 + dispatch）/
#   无新增轮询（grep Timer 0）/ 构建零新增 warning / 全量单测。
# 人工项（面板与首屏四项数字逐字相同、截图对照）不在本脚本内。
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT" || { echo "FAIL C0  无法进入仓库"; exit 1; }

SCRATCH="${T08_SCRATCH:-/tmp/t08-scratch}"
LOGDIR="${T08_LOGDIR:-/tmp/t08-qa-logs}"
mkdir -p "$LOGDIR"

DASH="Sources/LeapinApp/Views/DashboardView.swift"
GOWHERE="Sources/LeapinApp/Views/GoWherePage.swift"
PROFILES="Sources/LeapinApp/Views/ProfilesView.swift"
RESIDENT="Sources/LeapinRuntime/ResidentStatus.swift"
WORKBENCH="Sources/LeapinRuntime/Workbench.swift"

PASSED=0
FAILED=0
pass() { printf 'PASS %-3s %s\n' "$1" "$2"; PASSED=$((PASSED + 1)); }
fail() { printf 'FAIL %-3s %s\n' "$1" "$2"; FAILED=$((FAILED + 1)); }

for f in "$DASH" "$GOWHERE" "$PROFILES" "$RESIDENT" "$WORKBENCH"; do
    [ -f "$f" ] || { echo "FAIL C0  缺少文件 $f"; exit 1; }
done

echo "T-08 验收 · 仓库 $ROOT"
echo "scratch=${SCRATCH}（复用，不清理）· 日志=${LOGDIR}"
echo "----------------------------------------------------------------"

# ---------------------------------------------------------------- C1 构建
build_log="$LOGDIR/c1-build.log"
swift build --scratch-path "$SCRATCH" --disable-sandbox >"$build_log" 2>&1
rc=$?
errs=$(grep -c 'error:' "$build_log" || true)
warns=$(grep -c 'warning:' "$build_log" || true)
task_warns=$(grep -E 'warning:' "$build_log" | grep -cE 'DashboardView\.swift|GoWherePage\.swift|ProfilesView\.swift' || true)
if [ "$rc" -eq 0 ] && [ "$errs" -eq 0 ] && [ "$task_warns" -eq 0 ]; then
    pass C1 "swift build --scratch-path ${SCRATCH} --disable-sandbox → exit 0；日志 error: ${errs} 个、warning: ${warns} 个，其中落在本任务三个源文件上的 ${task_warns} 个（要求 0）；日志 ${build_log}"
else
    fail C1 "swift build 退出码 ${rc}；error: ${errs} 个（要求 0）、本任务文件 warning ${task_warns} 个（要求 0）；首个错误：$(grep -m1 'error:' "$build_log" || echo '（无 error: 行）')"
fi

# ---------------------------------------------------------------- C2 首屏五个事实
store_reads=$(grep -cF 'ResidentStatusStore.shared' "$DASH" || true)
store_observed=$(grep -cF '@ObservedObject private var resident = ResidentStatusStore.shared' "$DASH" || true)
status_read=$(grep -cF 'private var status: ResidentStatus { resident.status }' "$DASH" || true)
rates_summary=$(grep -cF 'status.rates.summary' "$DASH" || true)
coverage=$(grep -cF 'status.coverage.declaration' "$DASH" || true)
blocked=$(grep -cF 'status.blocked' "$DASH" || true)
exit_read=$(grep -cF 'status.exit' "$DASH" || true)
profile_read=$(grep -cF 'status.profileName' "$DASH" || true)
fact_labels=$(grep -cE 'RouteFact\("(当前配置|当前出口|速率|拦截数)"' "$DASH" || true)
if [ "$store_reads" -ge 1 ] && [ "$store_observed" -eq 1 ] && [ "$status_read" -eq 1 ] \
   && [ "$rates_summary" -ge 1 ] && [ "$coverage" -ge 1 ] && [ "$blocked" -ge 1 ] \
   && [ "$exit_read" -ge 1 ] && [ "$profile_read" -ge 1 ] && [ "$fact_labels" -eq 4 ]; then
    pass C2 "五事实全部来自 ResidentStatusStore.shared.status（命中 ${store_reads} 次，@ObservedObject ${store_observed} 处，取值口只有一个 status 计算属性）：rates.summary ${rates_summary}、coverage.declaration ${coverage}、blocked ${blocked}、exit ${exit_read}、profileName ${profile_read}；焦点带四个事实标签（当前配置/当前出口/速率/拦截数）${fact_labels} 个 + 接管范围一行（采样纪律另见 C6）"
else
    fail C2 "五事实不符：store ${store_reads}（≥1）、@ObservedObject store ${store_observed}（1）、resident.status ${status_read}（1）、rates.summary ${rates_summary}（≥1）、coverage.declaration ${coverage}（≥1）、blocked ${blocked}（≥1）、exit ${exit_read}（≥1）、profileName ${profile_read}（≥1）、事实标签 ${fact_labels}（4）"
fi

# ---------------------------------------------------------------- C3 四个动词入口 + dispatch
verb_source=$(grep -cF 'ForEach(WorkbenchVerb.allCases)' "$DASH" || true)
verb_dispatch=$(grep -cF 'app.dispatch(.section(verb.sectionRaw))' "$DASH" || true)
verb_title=$(grep -cF 'Text(verb.title)' "$DASH" || true)
state_fn=$(grep -cF 'private func stateLine(for verb: WorkbenchVerb) -> String' "$DASH" || true)
if [ "$state_fn" -eq 1 ]; then
    state_block=$(awk '/private func stateLine\(for verb: WorkbenchVerb\) -> String \{/{f=1} f{print} f && /^    \}$/{exit}' "$DASH")
else
    state_block=""
fi
verb_cases=$(printf '%s\n' "$state_block" | grep -cE '^        case \.(goWhere|howJudged|whatChanged|why):' || true)
line_rules=$(printf '%s\n' "$state_block" | grep -cF '条规则在判' || true)
line_rewrite=$(printf '%s\n' "$state_block" | grep -cF '重写 ' || true)
line_adblock=$(printf '%s\n' "$state_block" | grep -cF '去广告 ' || true)
line_blocked=$(printf '%s\n' "$state_block" | grep -cF '最近拦截 ' || true)
line_profile=$(printf '%s\n' "$state_block" | grep -cF 'profileText' || true)
if [ "$verb_source" -eq 1 ] && [ "$verb_dispatch" -eq 1 ] && [ "$verb_title" -ge 1 ] \
   && [ "$state_fn" -eq 1 ] && [ "$verb_cases" -eq 4 ] \
   && [ "$line_rules" -ge 1 ] && [ "$line_rewrite" -ge 1 ] && [ "$line_adblock" -ge 1 ] \
   && [ "$line_blocked" -ge 1 ] && [ "$line_profile" -ge 1 ]; then
    pass C3 "四入口来自 WorkbenchVerb.allCases（${verb_source} 处），标题读 verb.title，点击走 app.dispatch(.section(verb.sectionRaw))（${verb_dispatch} 处）；stateLine 四个分支齐全（${verb_cases}/4）：走哪＝配置与出口（profileText）、怎么判＝条规则在判、改成什么＝重写 + 去广告、为什么＝最近拦截"
else
    fail C3 "四入口不符：allCases ${verb_source}（1）、dispatch ${verb_dispatch}（1）、verb.title ${verb_title}（≥1）、stateLine ${state_fn}（1）、分支 ${verb_cases}（4）、规则行 ${line_rules}、重写行 ${line_rewrite}、去广告行 ${line_adblock}、拦截行 ${line_blocked}、配置与出口行 ${line_profile}"
fi

# ---------------------------------------------------------------- C4 ProfilesView 的页头参数
param_decl=$(grep -cF 'var showsPageHeader: Bool = true' "$PROFILES" || true)
param_init=$(grep -cF 'init(showsPageHeader: Bool = true)' "$PROFILES" || true)
param_gate=$(grep -cF 'if showsPageHeader {' "$PROFILES" || true)
tab_passes_false=$(grep -cF 'ProfilesView(showsPageHeader: false)' "$GOWHERE" || true)
tab_default_call=$(grep -cF 'ProfilesView()' "$GOWHERE" || true)
business_kept=$(grep -cF 'app.beginImport()' "$PROFILES" || true)
export_kept=$(grep -cF 'app.exportProfile(format:' "$PROFILES" || true)
if [ "$param_decl" -eq 1 ] && [ "$param_init" -eq 1 ] && [ "$param_gate" -ge 1 ] \
   && [ "$tab_passes_false" -eq 1 ] && [ "$tab_default_call" -eq 0 ] \
   && [ "$business_kept" -ge 1 ] && [ "$export_kept" -ge 1 ]; then
    pass C4 "ProfilesView 只多一个 showsPageHeader（声明 ${param_decl}、init ${param_init}、条件渲染 ${param_gate} 处，默认 true）；GoWherePage 的配置 tab 传 false（${tab_passes_false} 处，无参调用 ${tab_default_call} 处）；导入 ${business_kept} / 导出 ${export_kept} 条目仍在，业务未改"
else
    fail C4 "页头参数不符：声明 ${param_decl}（1）、init ${param_init}（1）、if 条件 ${param_gate}（≥1）、tab 传 false ${tab_passes_false}（1）、GoWherePage 里无参 ProfilesView() ${tab_default_call}（0）、beginImport ${business_kept}（≥1）、exportProfile ${export_kept}（≥1）"
fi

# ---------------------------------------------------------------- C5 保留场景条与快捷操作 / 删掉重复统计块
scene_rail=$(grep -cF 'private var sceneRail: some View' "$DASH" || true)
scene_cases=$(grep -cF 'ForEach(NetworkScene.allCases)' "$DASH" || true)
quick_share=$(grep -cF '分享本地服务' "$DASH" || true)
quick_thanks=$(grep -cF '工具与致谢' "$DASH" || true)
quick_company=$(grep -cF '公司内网' "$DASH" || true)
bookmarks=$(grep -cF 'private var bookmarksWidget: some View' "$DASH" || true)
# 与首屏重复的「线路与订阅」统计块（配置名 + 节点数/策略组数/规则数）必须消失。
dup_widget=$(grep -cF 'private var subscriptionWidget: some View' "$DASH" || true)
dup_nodes=$(grep -cF '个节点 · ' "$DASH" || true)
if [ "$scene_rail" -eq 1 ] && [ "$scene_cases" -eq 1 ] \
   && [ "$quick_share" -ge 1 ] && [ "$quick_thanks" -ge 1 ] && [ "$quick_company" -ge 1 ] \
   && [ "$bookmarks" -eq 1 ] && [ "$dup_widget" -eq 0 ] && [ "$dup_nodes" -eq 0 ]; then
    pass C5 "场景条保留（sceneRail ${scene_rail} 处、NetworkScene.allCases ${scene_cases} 处）；快捷操作保留（分享本地服务 / 工具与致谢 / 公司内网 + 常用书签 ${bookmarks} 块）；与首屏重复的「线路与订阅」统计块已删（subscriptionWidget ${dup_widget}、节点/策略组/规则计数行 ${dup_nodes}）"
else
    fail C5 "首屏去留不符：sceneRail ${scene_rail}（1）、NetworkScene.allCases ${scene_cases}（1）、快捷操作 ${quick_share}/${quick_thanks}/${quick_company}（各 ≥1）、书签块 ${bookmarks}（1）、重复统计块 ${dup_widget}（0）、重复计数行 ${dup_nodes}（0）"
fi

# ---------------------------------------------------------------- C6 采样纪律
# 允许的：首屏可见时的 1 Hz 驱动（`.task` + `Task.sleep(for: .seconds(1))`）——
#   面板与浮窗都没开时 store 没人喂帧，首屏五事实会是死值，这是评审 B-1 的修法；
#   离开页面任务自动取消，不是全局轮询。
# 禁止的：① 视图里的 Timer / 第二个按秒差分器；② store 自己持 Timer；
#   ③ 全仓出现第二个 ResidentRateMeter 实例；④ 首帧不取快照就进循环（出口会缺）。
timer_hits=0
for f in "$DASH" "$GOWHERE" "$PROFILES"; do
    n=$(grep -c 'Timer' "$f" || true)
    timer_hits=$((timer_hits + n))
done
store_timer=$(grep -c 'Timer' "$RESIDENT" || true)
own_rate_state=$(grep -cE 'lastBytesIn|lastBytesOut|lastSample|lastSpeedSample|lastRates' "$DASH" || true)
meters=$(grep -rn '= ResidentRateMeter()' Sources/ | wc -l | tr -d ' ')
task_driver=$(grep -cF '.task { await driveResidentFacts() }' "$DASH" || true)
loop_sleep=$(grep -cF 'try? await Task.sleep(for: .seconds(1))' "$DASH" || true)
loop_cancel=$(grep -cF 'if Task.isCancelled { return }' "$DASH" || true)
snapshot_take=$(grep -cF 'await engine.menuBarSnapshot()' "$DASH" || true)
store_updates=$(grep -cF 'resident.update(from: engine' "$DASH" || true)
change_refresh=$(grep -cF 'Task { await refreshResidentExit() }' "$DASH" || true)
if [ "$timer_hits" -eq 0 ] && [ "$store_timer" -eq 0 ] && [ "$own_rate_state" -eq 0 ] \
   && [ "$meters" -eq 1 ] && [ "$task_driver" -eq 1 ] && [ "$loop_sleep" -eq 1 ] \
   && [ "$loop_cancel" -ge 1 ] && [ "$snapshot_take" -ge 1 ] && [ "$store_updates" -ge 2 ] \
   && [ "$change_refresh" -ge 1 ]; then
    pass C6 "采样纪律：视图里 Timer ${timer_hits} 次（0）、store 内 Timer ${store_timer} 次（0）、自行计时状态 ${own_rate_state} 次（0）、全仓 ResidentRateMeter 实例 ${meters} 个（1，差分只在 store）；首屏由「.task」驱动（${task_driver} 处）：先取快照（menuBarSnapshot ${snapshot_take} 次，出口就来自它）→ 1 Hz 循环 ${loop_sleep} 处、退出即散（isCancelled ${loop_cancel} 处）、store 入口调用 ${store_updates} 次；state/profile 变化各重取一次快照（${change_refresh} 处），无全局定时器"
else
    fail C6 "采样纪律不符：视图 Timer ${timer_hits}（0）、store Timer ${store_timer}（0）、自行计时状态 ${own_rate_state}（0）、ResidentRateMeter 实例 ${meters}（1）、.task 驱动 ${task_driver}（1）、1 Hz 睡眠 ${loop_sleep}（1）、isCancelled 退出 ${loop_cancel}（≥1）、menuBarSnapshot ${snapshot_take}（≥1）、store 入口 ${store_updates}（≥2）、state/profile 重取 ${change_refresh}（≥1）"
fi

# ---------------------------------------------------------------- C7 全量单测
test_log="$LOGDIR/c7-test.log"
swift test --scratch-path "$SCRATCH" --disable-sandbox >"$test_log" 2>&1
rc=$?
# 一个 bundle 一行 "Test Suite 'All tests' passed"，所以不拿最后一行当全量总数：
# 逐条计数才是整包的真实结果。
cases_passed=$(grep -cE "Test Case .* passed" "$test_log" || true)
cases_failed=$(grep -cE "Test Case .* failed" "$test_log" || true)
bundles=$(grep -cE "Test Suite 'All tests' passed" "$test_log" || true)
if [ "$rc" -eq 0 ] && [ "$cases_passed" -gt 0 ] && [ "$cases_failed" -eq 0 ] && [ "$bundles" -ge 1 ]; then
    pass C7 "swift test 全量 → exit 0；${bundles} 个测试 bundle 全部 passed；逐条 Test Case passed ${cases_passed} 条、failed ${cases_failed} 条；日志 ${test_log}"
else
    fail C7 "全量单测未全绿：退出码 ${rc}、bundle passed ${bundles}、逐条 passed ${cases_passed} / failed ${cases_failed}；首个失败：$(grep -m3 -E "error: .*failed|Test Case .* failed" "$test_log" || echo '无')。若失败文件不在本任务清单（DashboardView/GoWherePage/ProfilesView）内，按文件归属上报，不在这里改别人文件。"
fi

# ---------------------------------------------------------------- 汇总
echo "----------------------------------------------------------------"
echo "T-08 结果：${PASSED} PASS / ${FAILED} FAIL（C1 构建 · C2 五事实 · C3 四入口 · C4 页头参数 · C5 首屏去留 · C6 无轮询 · C7 全量单测）"
if [ "$FAILED" -gt 0 ]; then
    exit 1
fi
exit 0
