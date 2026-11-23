#!/usr/bin/env bash
# T-07 验收：「为什么」页壳 —— 四 tab（切 tab 不销毁）+ 连接搜索注入
# 用法：bash qa/T-07/run.sh
# 默认复用 scratch（${T07_SCRATCH:-/tmp/t07-scratch}），不删目录（共用机器上构建）。
# 只读仓库，不改 Sources/ Tests/ docs/。任何一条 FAIL → 退出码 1。
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT" || { echo "FAIL C0  无法进入仓库"; exit 1; }

SCRATCH="${T07_SCRATCH:-/tmp/t07-scratch}"
LOGDIR="${T07_LOGDIR:-/tmp/t07-qa-logs}"
mkdir -p "$LOGDIR"

WHY="Sources/LeapinApp/Views/WhyPage.swift"
CAP="Sources/LeapinApp/Views/CaptureView.swift"
APP="Sources/LeapinApp/LeapinApp.swift"

# M1 文件：本任务一个都不许碰（只做符号级反查 + 打印哈希留档）。
M1_FILES=(
    "Sources/LeapinApp/Views/MenuBarPanel.swift"
    "Sources/LeapinApp/Views/FloatingStatusView.swift"
    "Sources/LeapinRuntime/ResidentStatus.swift"
    "Sources/LeapinRuntime/TouchFlowEngine.swift"
    "Sources/LeapinApp/Platform.swift"
)

PASSED=0
FAILED=0
pass() { printf 'PASS %-3s %s\n' "$1" "$2"; PASSED=$((PASSED + 1)); }
fail() { printf 'FAIL %-3s %s\n' "$1" "$2"; FAILED=$((FAILED + 1)); }

for f in "$WHY" "$CAP" "$APP"; do
    [ -f "$f" ] || { echo "FAIL C0  缺少文件 $f"; exit 1; }
done

echo "T-07 验收 · 仓库 $ROOT"
echo "scratch=${SCRATCH}（复用，不清理）· 日志=${LOGDIR}"
echo "----------------------------------------------------------------"

# ---------------------------------------------------------------- C1 构建
build_log="$LOGDIR/c1-build.log"
swift build --scratch-path "$SCRATCH" --disable-sandbox >"$build_log" 2>&1
rc=$?
errs=$(grep -c 'error:' "$build_log" || true)
warns=$(grep -c 'warning:' "$build_log" || true)
task_warns=$(grep -E 'warning:' "$build_log" | grep -cE 'WhyPage\.swift|CaptureView\.swift' || true)
if [ "$rc" -eq 0 ] && [ "$errs" -eq 0 ] && [ "$task_warns" -eq 0 ]; then
    pass C1 "swift build --scratch-path ${SCRATCH} --disable-sandbox → exit 0；日志 error: ${errs} 个、warning: ${warns} 个，其中落在 WhyPage/CaptureView 上的 ${task_warns} 个（要求 0）；日志 ${build_log}"
else
    fail C1 "swift build 退出码 ${rc}；error: ${errs} 个（要求 0）、本任务两个文件 warning ${task_warns} 个（要求 0）；首个错误：$(grep -m1 'error:' "$build_log" || echo '（无 error: 行）')"
fi

# ---------------------------------------------------------------- C2 四 tab：定义、顺序、默认连接、initialTab 生效
tab_cases=$(grep -cF 'case connections, metrics, probes, diagnostics' "$WHY" || true)
tab_titles=$(grep -cE 'return "(连接|指标|探测|诊断)"' "$WHY" || true)
tab_picker=$(grep -cF 'ForEach(Tab.allCases)' "$WHY" || true)
tab_binding=$(grep -cF 'Picker("视图", selection: selection)' "$WHY" || true)
init_default=$(grep -cF 'init(initialTab: Tab = .connections)' "$WHY" || true)
init_applied=$(grep -cF '_tab = State(initialValue: initialTab)' "$WHY" || true)
branch_connections=$(grep -cF 'case .connections:' "$WHY" || true)
branch_metrics=$(grep -cF 'case .metrics:' "$WHY" || true)
branch_probes=$(grep -cF 'case .probes:' "$WHY" || true)
branch_diagnostics=$(grep -cF 'case .diagnostics:' "$WHY" || true)
if [ "$tab_cases" -eq 1 ] && [ "$tab_titles" -eq 4 ] && [ "$tab_picker" -ge 1 ] && [ "$tab_binding" -eq 1 ] \
   && [ "$init_default" -eq 1 ] && [ "$init_applied" -eq 1 ] \
   && [ "$branch_connections" -ge 1 ] && [ "$branch_metrics" -ge 1 ] && [ "$branch_probes" -ge 1 ] && [ "$branch_diagnostics" -ge 1 ]; then
    pass C2 "四 tab 一行定义（${tab_cases}）、四个中文标题（${tab_titles}）、Picker 绑 selection（${tab_binding}）、allCases 遍历 ${tab_picker} 处；initialTab 默认 .connections（${init_default}）且写进 _tab 初值（${init_applied}）；四个分支都在（连接 ${branch_connections} / 指标 ${branch_metrics} / 探测 ${branch_probes} / 诊断 ${branch_diagnostics}）"
else
    fail C2 "四 tab 不符：case 行 ${tab_cases}（1）、标题 ${tab_titles}（4）、allCases ${tab_picker}（≥1）、Picker 绑定 ${tab_binding}（1）、init 默认 ${init_default}（1）、_tab 初值 ${init_applied}（1）、分支 连接 ${branch_connections} / 指标 ${branch_metrics} / 探测 ${branch_probes} / 诊断 ${branch_diagnostics}（各 ≥1）"
fi

# ---------------------------------------------------------------- C3 连接 tab = CaptureView(initialSearch: seed, isActive:)
conn_line=$(grep -cF 'case .connections: CaptureView(initialSearch: seed, isActive: item == tab)' "$WHY" || true)
conn_plain=$(grep -cE 'CaptureView\(\)' "$WHY" || true)
conn_sites=$(grep -cE 'CaptureView\(' "$WHY" || true)
if [ "$conn_line" -eq 1 ] && [ "$conn_plain" -eq 0 ] && [ "$conn_sites" -eq 1 ]; then
    pass C3 "连接 tab 走注入式构造：case .connections: CaptureView(initialSearch: seed, isActive: item == tab)（${conn_line} 处）；WhyPage 里 CaptureView 构造点唯一（${conn_sites} 处），无 CaptureView() 直连（${conn_plain}）"
else
    fail C3 "连接 tab 未走注入：注入式构造 ${conn_line}（1）、CaptureView() ${conn_plain}（0）、构造点总数 ${conn_sites}（1）"
fi

# ---------------------------------------------------------------- C4 WhyPage 只 take 一次
env_routes=$(grep -cF '@EnvironmentObject private var routes: RouteContext' "$WHY" || true)
take_count=$(grep -cF 'routes.take(for: .why)' "$WHY" || true)
task_hook=$(grep -cF '.task {' "$WHY" || true)
consume_call=$(grep -cF 'consumeRouteIfNeeded()' "$WHY" || true)
guard_line=$(grep -nF 'guard !consumedRoute else { return }' "$WHY" | head -1 | cut -d: -f1)
take_line=$(grep -nF 'routes.take(for: .why)' "$WHY" | head -1 | cut -d: -f1)
seed_line=$(grep -nF 'seed = subject.host' "$WHY" | head -1 | cut -d: -f1)
seed_writes=$(grep -cF 'seed = subject.host' "$WHY" || true)
if [ -n "$guard_line" ] && [ -n "$take_line" ] && [ -n "$seed_line" ] \
   && [ "$guard_line" -lt "$take_line" ] && [ "$take_line" -lt "$seed_line" ]; then
    order_ok="yes"
else
    order_ok="no"
fi
if [ "$env_routes" -eq 1 ] && [ "$take_count" -eq 1 ] && [ "$task_hook" -eq 1 ] && [ "$consume_call" -ge 2 ] \
   && [ "$seed_writes" -eq 1 ] && [ "$order_ok" = "yes" ]; then
    pass C4 "RouteContext 走 @EnvironmentObject（${env_routes}）；take(for: .why) 全文只出现 ${take_count} 次；.task 挂载（${task_hook}）并调用 consumeRouteIfNeeded（${consume_call} 处）；seed 写入点唯一（${seed_writes} 处，第 ${seed_line} 行）且在守卫（第 ${guard_line} 行）与 take（第 ${take_line} 行）之后"
else
    fail C4 "取一次不成立：EnvironmentObject ${env_routes}（1）、take 次数 ${take_count}（1）、.task ${task_hook}（1）、consumeRouteIfNeeded ${consume_call}（≥2）、seed 写入 ${seed_writes}（1）、守卫行 ${guard_line:-无} < take 行 ${take_line:-无} < seed 行 ${seed_line:-无}"
fi

# ---------------------------------------------------------------- C5 CaptureView 注入点：只写一次、只在没输入时写
var_line=$(grep -cF 'var initialSearch: String = ""' "$CAP" || true)
init_line=$(grep -cF 'init(initialSearch: String = "", isActive: Bool = true)' "$CAP" || true)
state_search=$(grep -cE '^    @State private var search = ""$' "$CAP" || true)
flag_refs=$(grep -cF 'appliedInitialSearch' "$CAP" || true)
write_once=$(grep -cF 'search = initialSearch' "$CAP" || true)
apply_refs=$(grep -cF 'applyInitialSearchIfNeeded' "$CAP" || true)
on_appear=$(grep -cF '.onAppear { applyInitialSearchIfNeeded() }' "$CAP" || true)
on_change=$(grep -cF '.onChange(of: initialSearch)' "$CAP" || true)
empty_guard=$(grep -nF 'guard search.isEmpty else {' "$CAP" | head -1 | cut -d: -f1)
write_line=$(grep -nF 'search = initialSearch' "$CAP" | head -1 | cut -d: -f1)
if [ -n "$empty_guard" ] && [ -n "$write_line" ] && [ "$empty_guard" -lt "$write_line" ]; then
    guard_before_write="yes"
else
    guard_before_write="no"
fi
if [ "$var_line" -eq 1 ] && [ "$init_line" -eq 1 ] && [ "$state_search" -eq 1 ] && [ "$flag_refs" -ge 3 ] \
   && [ "$write_once" -eq 1 ] && [ "$apply_refs" -ge 3 ] && [ "$on_appear" -eq 1 ] && [ "$on_change" -eq 1 ] \
   && [ "$guard_before_write" = "yes" ]; then
    pass C5 "注入点：var initialSearch: String = \"\"（${var_line}）+ init(initialSearch:isActive:)（${init_line}）；私有 search 仍是 @State（${state_search}）；一次性标志 appliedInitialSearch ${flag_refs} 处；写入口唯一 ${write_once} 处（第 ${write_line} 行），「search 非空就不写」的守卫在它之前（第 ${empty_guard} 行）；入口挂 onAppear ${on_appear} + onChange(of: initialSearch) ${on_change}"
else
    fail C5 "注入点不符：var ${var_line}（1）、init ${init_line}（1）、@State search ${state_search}（1）、appliedInitialSearch ${flag_refs}（≥3）、写 search 次数 ${write_once}（1）、apply 引用 ${apply_refs}（≥3）、onAppear ${on_appear}（1）、onChange(initialSearch) ${on_change}（1）、空守卫 ${empty_guard:-无} < 写入 ${write_line:-无}"
fi

# ---------------------------------------------------------------- C6 过滤/列表逻辑一字未改
q_line=$(grep -cF 'let q = search.lowercased()' "$CAP" || true)
filter_line=$(grep -cF 'return source.filter { request in' "$CAP" || true)
status_guard=$(grep -cF 'guard statusFilter.matches(request) else { return false }' "$CAP" || true)
empty_guard_filter=$(grep -cF 'guard !q.isEmpty else { return true }' "$CAP" || true)
match_line=$(grep -cF 'return request.url.lowercased().contains(q) || request.host.lowercased().contains(q)' "$CAP" || true)
source_filter=$(grep -cF 'source.filter' "$CAP" || true)
if [ "$q_line" -eq 1 ] && [ "$filter_line" -eq 1 ] && [ "$status_guard" -eq 1 ] && [ "$empty_guard_filter" -eq 1 ] \
   && [ "$match_line" -eq 1 ] && [ "$source_filter" -eq 1 ]; then
    pass C6 "过滤逻辑未动：source.filter 唯一（${source_filter}），状态过滤、空查询短路、URL/主机 contains 三句原样在场（${status_guard}/${empty_guard_filter}/${match_line}）—— 注入点只喂初始词，不改筛选"
else
    fail C6 "过滤逻辑被改：source.filter ${source_filter}（1）、let q ${q_line}（1）、状态过滤 ${status_guard}（1）、空查询短路 ${empty_guard_filter}（1）、contains 句 ${match_line}（1）"
fi

# ---------------------------------------------------------------- C7 M1 文件未被碰（符号级反查 + 哈希留档）
m1_hits=""
for f in "${M1_FILES[@]}"; do
    [ -f "$f" ] || { m1_hits="$m1_hits ${f}(missing)"; continue; }
    n=$(grep -cE 'initialSearch|appliedInitialSearch|take\(for: \.why\)|consumeRouteIfNeeded|isActive' "$f" || true)
    [ "$n" -eq 0 ] || m1_hits="$m1_hits ${f}(${n})"
done
m1_hashes=$(shasum -a 256 "${M1_FILES[@]}" 2>/dev/null | awk '{print substr($1,1,12)" "$2}' | tr '\n' ';')
if [ -z "$m1_hits" ]; then
    pass C7 "M1 五个文件里没有任何本任务的符号（initialSearch / appliedInitialSearch / take(for: .why) / consumeRouteIfNeeded / isActive）；sha256 前 12 位留档：${m1_hashes}"
else
    fail C7 "M1 文件被本任务碰到：${m1_hits}（要求 0 处）；留档：${m1_hashes}"
fi

# ---------------------------------------------------------------- C8 take 语义未变：WorkbenchTests 24 条仍绿
test_log="$LOGDIR/c8-test.log"
swift test --scratch-path "$SCRATCH" --disable-sandbox --filter WorkbenchTests >"$test_log" 2>&1
rc=$?
cases=$(grep -cE "Test Case '-\[LeapinRuntimeTests\.WorkbenchTests .*\]' passed" "$test_log" || true)
total=$(grep -cF 'Executed 24 tests, with 0 failures' "$test_log" || true)
if [ "$rc" -eq 0 ] && [ "$cases" -eq 24 ] && [ "$total" -ge 1 ]; then
    pass C8 "swift test --filter WorkbenchTests → exit 0；逐条 passed ${cases} 条，汇总行含 Executed 24 tests, with 0 failures（命中 ${total} 次）—— take 的「每个动词一次」语义没有被本任务改动"
else
    fail C8 "WorkbenchTests 未全绿：退出码 ${rc}、逐条 passed ${cases}（要求 24）、汇总行命中 ${total}；失败用例：$(grep -m3 'failed (' "$test_log" || echo '无')"
fi

# ---------------------------------------------------------------- C9 切 tab 不销毁 CaptureView（T-07 第 1 轮评审 blocking）
old_switch=$(grep -cF 'switch tab {' "$WHY" || true)
zstack=$(grep -cF 'ZStack(alignment: .topLeading)' "$WHY" || true)
mounted_guard=$(grep -cF 'if mounted.contains(item)' "$WHY" || true)
opacity_line=$(grep -cF '.opacity(tab == item ? 1 : 0)' "$WHY" || true)
hit_line=$(grep -cF '.allowsHitTesting(tab == item)' "$WHY" || true)
mount_init=$(grep -cF '_mounted = State(initialValue: [initialTab])' "$WHY" || true)
mount_insert=$(grep -cF 'mounted.insert(new)' "$WHY" || true)
binding_prop=$(grep -cF 'private var selection: Binding<Tab>' "$WHY" || true)
suppressed=$(grep -cF 'guard isActive else { return }' "$CAP" || true)
if [ "$old_switch" -eq 0 ] && [ "$zstack" -eq 1 ] && [ "$mounted_guard" -eq 1 ] && [ "$opacity_line" -eq 1 ] \
   && [ "$hit_line" -eq 1 ] && [ "$mount_init" -eq 1 ] && [ "$mount_insert" -eq 1 ] && [ "$binding_prop" -eq 1 ] \
   && [ "$suppressed" -eq 1 ]; then
    pass C9 "切 tab 不销毁：WhyPage 里已无 switch tab（${old_switch}），四个 tab 叠在 ZStack（${zstack}）里按 mounted 挂载（${mounted_guard}）+ opacity 显隐（${opacity_line}）+ 隐藏层不吃点击（${hit_line}）；mounted 从 initialTab 起手（${mount_init}）、选中时只增不减（${mount_insert}，经 selection 绑定 ${binding_prop}）→ 切走再回来不会重建 CaptureView，它的 @State（search / appliedInitialSearch / 选中行）原样留着；隐藏 tab 也不抢全局搜索焦点（CaptureView 里 ${suppressed} 处 isActive 守卫）"
else
    fail C9 "切 tab 仍会销毁/重建：switch tab ${old_switch}（0）、ZStack ${zstack}（1）、mounted 判据 ${mounted_guard}（1）、opacity ${opacity_line}（1）、hitTesting ${hit_line}（1）、mounted 初值 ${mount_init}（1）、mounted.insert ${mount_insert}（1）、selection 绑定 ${binding_prop}（1）、isActive 守卫 ${suppressed}（1）"
fi

# ---------------------------------------------------------------- 汇总
echo "----------------------------------------------------------------"
echo "T-07 结果：${PASSED} PASS / ${FAILED} FAIL（C1 构建 · C2 四 tab · C3 连接=注入式 CaptureView · C4 take 一次 · C5 注入点 · C6 过滤未改 · C7 M1 未碰 · C8 WorkbenchTests 24 · C9 切 tab 不销毁）"
if [ "$FAILED" -gt 0 ]; then
    exit 1
fi
exit 0
