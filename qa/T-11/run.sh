#!/usr/bin/env bash
# T-11 验收：为什么 · 指标 tab（内嵌 ObservationView，去掉页头）
# 用法：bash qa/T-11/run.sh
#
# 这一份做两件事：
#   1) 构建（DoD 第 3 条的前半段）：
#        swift build --scratch-path /tmp/t11-scratch --disable-sandbox
#      顺带要求本次改动的两个文件零 warning（别人的历史 warning 不算在 T-11 头上）。
#   2) 静态断言（DoD 第 1、2 条 + 任务要求）：
#      - WhyPage 的指标分支引用 ObservationView(embedded:)，占位壳不再挂在指标 tab
#      - ObservationView 有 embedded 参数（默认 false），页面标题与 hero 页头都受它控制
#      - 没有新增 Timer：采样仍是全文件唯一那一个 Timer.publish，数据源没换
#      - 指标本体（实时速率 / 连接数 / 命中统计）没有被裁掉
#
# 全量单测是 DoD 第 3 条的另一半，独立命令（重复跑只会把两件事混成一件事）：
#   swift test --scratch-path /tmp/t11-scratch --disable-sandbox --filter WorkbenchTests
#
# 只读仓库，不改任何文件（构建产物落在构建 scratch）。任何一条 FAIL → 退出码 1。
# 每条断言都对着具体字符串 / 行号顺序，所以它能红；WHY / OBS 可用环境变量指向
# 被改坏的副本做反向验证（见文件末尾注释）。T11_SKIP_BUILD=1 只跳过 C0，不跳过断言。
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT" || { echo "FAIL C0  无法进入仓库"; exit 1; }

WHY="${T11_WHY:-Sources/LeapinApp/Views/WhyPage.swift}"
OBS="${T11_OBS:-Sources/LeapinApp/Views/ObservationView.swift}"
SCRATCH="${T11_SCRATCH:-/tmp/t11-scratch}"
SKIP_BUILD="${T11_SKIP_BUILD:-0}"

PASSED=0
FAILED=0
pass() { printf 'PASS %-3s %s\n' "$1" "$2"; PASSED=$((PASSED + 1)); }
fail() { printf 'FAIL %-3s %s\n' "$1" "$2"; FAILED=$((FAILED + 1)); }

echo "T-11 验收 · 仓库 $ROOT"
echo "被检查文件：${WHY}、${OBS}（只读）；构建 scratch ${SCRATCH}"
echo "----------------------------------------------------------------"

[ -f "$WHY" ] || { echo "FAIL C0  缺少文件 $WHY"; exit 1; }
[ -f "$OBS" ] || { echo "FAIL C0  缺少文件 $OBS"; exit 1; }

# ---------------------------------------------------------------- C0 构建
if [ "$SKIP_BUILD" = "1" ]; then
    echo "SKIP C0  按 T11_SKIP_BUILD=1 跳过构建（只做静态断言）"
elif ! command -v swift >/dev/null 2>&1; then
    fail C0 "找不到 swift 命令，无法构建"
else
    log="$(mktemp "${TMPDIR:-/tmp}/t11-build.XXXXXX")"
    swift build --scratch-path "$SCRATCH" --disable-sandbox > "$log" 2>&1
    status=$?
    own_warn=$(grep -F 'warning:' "$log" | grep -cE 'WhyPage\.swift|ObservationView\.swift' || true)
    if [ "$status" -eq 0 ] && [ "$own_warn" -eq 0 ]; then
        pass C0 "swift build 成功（退出码 0）；WhyPage / ObservationView 的 warning ${own_warn} 条（要求 0）"
    else
        fail C0 "构建不干净：退出码 ${status}、本次改动文件的 warning ${own_warn} 条（要求 0）。日志尾部：$(tail -4 "$log" | tr '\n' ' ')"
    fi
    rm -f "$log"
fi

# 判代码不判注释：注释里解释「为什么」不算实现，断言一律打在剥离注释后的文本上。
why_code=$(sed -E 's://.*$::' "$WHY")
obs_code=$(sed -E 's://.*$::' "$OBS")

# ---------------------------------------------------------------- C1 指标分支接上 ObservationView
branch_n=$(printf '%s\n' "$why_code" | grep -cF 'case .metrics: ObservationView(embedded: true)' || true)
call_n=$(printf '%s\n' "$why_code" | grep -cF 'ObservationView(embedded: true)' || true)
stub_n=$(printf '%s\n' "$why_code" | grep -cF 'WhyPendingTab(tab: .metrics)' || true)
if [ "$branch_n" -ge 1 ] && [ "$call_n" -eq 1 ] && [ "$stub_n" -eq 0 ]; then
    pass C1 "指标 tab 接上观测视图：case .metrics → ObservationView(embedded: true) ${branch_n} 处（全文件调用 ${call_n} 处）；指标 tab 仍挂占位壳 ${stub_n} 处（要求 0）"
else
    fail C1 "指标 tab 没接上：case .metrics → ObservationView(embedded: true) ${branch_n}（≥1）、调用总数 ${call_n}（要求 1）、占位壳 ${stub_n}（要求 0）"
fi

# ---------------------------------------------------------------- C2 embedded 参数默认 false
param_n=$(printf '%s\n' "$obs_code" | grep -cF 'let embedded: Bool' || true)
init_n=$(printf '%s\n' "$obs_code" | grep -cF 'init(embedded: Bool = false)' || true)
self_n=$(printf '%s\n' "$obs_code" | grep -cF 'self.embedded = embedded' || true)
if [ "$param_n" -eq 1 ] && [ "$init_n" -eq 1 ] && [ "$self_n" -eq 1 ]; then
    pass C2 "embedded 参数：let embedded: Bool ${param_n} 处、init(embedded: Bool = false) ${init_n} 处、self.embedded = embedded ${self_n} 处（默认 false，旧调用 ObservationView() 不变）"
else
    fail C2 "embedded 参数不完整：let embedded ${param_n}（要求 1）、init(embedded: Bool = false) ${init_n}（要求 1）、赋值 ${self_n}（要求 1）"
fi

# ---------------------------------------------------------------- C3 导航标题受 embedded 控制
nav_n=$(printf '%s\n' "$obs_code" | grep -cF '.navigationTitle("观测")' || true)
if_embed_line=$(printf '%s\n' "$obs_code" | grep -nF 'if embedded {' | head -1 | cut -d: -f1)
win=""
if [ -n "${if_embed_line:-}" ]; then
    win=$(printf '%s\n' "$obs_code" | sed -n "${if_embed_line},$((if_embed_line + 3))p")
fi
win_embed=$(printf '%s\n' "$win" | grep -cF 'if embedded {' || true)
win_page=$(printf '%s\n' "$win" | grep -cE '^[[:space:]]*page$' || true)
win_else=$(printf '%s\n' "$win" | grep -cE '^[[:space:]]*\} else \{' || true)
win_nav=$(printf '%s\n' "$win" | grep -cF 'page.navigationTitle("观测")' || true)
if [ "$nav_n" -eq 1 ] && [ "$win_embed" -eq 1 ] && [ "$win_page" -eq 1 ] && [ "$win_else" -eq 1 ] && [ "$win_nav" -eq 1 ]; then
    pass C3 "导航标题受 embedded 控制：第 ${if_embed_line} 行起四行恰好是 if embedded { / page / } else { / page.navigationTitle(观测)（各 1 处）；全文件 navigationTitle 仅 ${nav_n} 处"
else
    fail C3 "导航标题没受控：navigationTitle 次数 ${nav_n}（要求 1）、if embedded 行 [${if_embed_line:-空}]；四行窗口里 if embedded ${win_embed} / page ${win_page} / } else { ${win_else} / page.navigationTitle ${win_nav}（各要求 1）"
fi

# ---------------------------------------------------------------- C4 hero 页头受 embedded 控制
guard_n=$(printf '%s\n' "$obs_code" | grep -cF 'if !embedded {' || true)
hero_n=$(printf '%s\n' "$obs_code" | grep -cF 'hero.lpAppear(0)' || true)
hero_after_guard=$(printf '%s\n' "$obs_code" | grep -A1 -F 'if !embedded {' | grep -cF 'hero.lpAppear(0)' || true)
if [ "$guard_n" -ge 1 ] && [ "$hero_n" -eq 1 ] && [ "$hero_after_guard" -ge 1 ]; then
    pass C4 "hero 页头受 embedded 控制：if !embedded { ${guard_n} 处，hero.lpAppear(0) 紧跟其后的 ${hero_after_guard} 处，全文件共 ${hero_n} 处（没有第二处裸 hero）"
else
    fail C4 "hero 页头未受控：if !embedded ${guard_n}（≥1）、紧邻的 hero.lpAppear(0) ${hero_after_guard}（≥1）、hero.lpAppear(0) 总数 ${hero_n}（要求 1）"
fi

# ---------------------------------------------------------------- C5 没有新增 Timer
publish_n=$(printf '%s\n' "$obs_code" | grep -cF 'Timer.publish(' || true)
timer_n=$(printf '%s\n' "$obs_code" | grep -cF 'Timer' || true)
why_timer_n=$(printf '%s\n' "$why_code" | grep -cF 'Timer' || true)
scheduled_n=$(printf '%s\n' "$obs_code" | grep -cF 'Timer.scheduledTimer' || true)
def_n=$(printf '%s\n' "$obs_code" | grep -cF 'private func sampleTraffic()' || true)
all_call_n=$(printf '%s\n' "$obs_code" | grep -cF 'sampleTraffic()' || true)
call_n=$((all_call_n - def_n))
if [ "$publish_n" -eq 1 ] && [ "$timer_n" -eq 1 ] && [ "$why_timer_n" -eq 0 ] && [ "$scheduled_n" -eq 0 ] && [ "$def_n" -eq 1 ] && [ "$call_n" -eq 1 ]; then
    pass C5 "没有新增 Timer：ObservationView 里 Timer.publish( ${publish_n} 处、Timer 字样共 ${timer_n} 处、Timer.scheduledTimer ${scheduled_n} 处；WhyPage 里 Timer ${why_timer_n} 处；sampleTraffic 定义 ${def_n} 处、被调用 ${call_n} 处（仍是每秒那一个）"
else
    fail C5 "Timer 记账不对：Timer.publish ${publish_n}（要求 1）、Timer ${timer_n}（要求 1）、WhyPage Timer ${why_timer_n}（要求 0）、scheduledTimer ${scheduled_n}（要求 0）、sampleTraffic 定义 ${def_n} / 调用 ${call_n}（各要求 1）"
fi

# ---------------------------------------------------------------- C6 指标本体没被裁掉（DoD 1）
conn_n=$(printf '%s\n' "$obs_code" | grep -cF 'metric("活动连接"' || true)
blocked_n=$(printf '%s\n' "$obs_code" | grep -cF 'metric("已拦截"' || true)
seismo_n=$(printf '%s\n' "$obs_code" | grep -cF 'trafficSeismograph' || true)
panel_n=$(printf '%s\n' "$obs_code" | grep -cF 'instrumentPanel.lpAppear(0.08)' || true)
recent_n=$(printf '%s\n' "$obs_code" | grep -cF 'recentFlows.lpAppear(0.12)' || true)
if [ "$conn_n" -eq 1 ] && [ "$blocked_n" -eq 1 ] && [ "$seismo_n" -ge 2 ] && [ "$panel_n" -eq 1 ] && [ "$recent_n" -eq 1 ]; then
    pass C6 "指标本体在：连接数 metric(活动连接) ${conn_n} 处、命中统计 metric(已拦截) ${blocked_n} 处、实时速率 trafficSeismograph ${seismo_n} 处（定义 + 使用）、instrumentPanel ${panel_n} 处、recentFlows ${recent_n} 处（内嵌只摘页头，不摘指标）"
else
    fail C6 "指标本体被裁：活动连接 ${conn_n}、已拦截 ${blocked_n}、trafficSeismograph ${seismo_n}（≥2）、instrumentPanel ${panel_n}、recentFlows ${recent_n}（各项要求见括号）"
fi

# ---------------------------------------------------------------- C7 采样与数据源未改
engine_n=$(printf '%s\n' "$obs_code" | grep -cF '@ObservedObject private var engine = LeapinEngine.shared' || true)
src_in_n=$(printf '%s\n' "$obs_code" | grep -cF 'engine.stats.bytesIn' || true)
src_out_n=$(printf '%s\n' "$obs_code" | grep -cF 'engine.stats.bytesOut' || true)
if [ "$engine_n" -eq 1 ] && [ "$src_in_n" -ge 2 ] && [ "$src_out_n" -ge 2 ]; then
    pass C7 "数据源没换：LeapinEngine.shared 注入 ${engine_n} 处、采样读 engine.stats.bytesIn ${src_in_n} 处 / bytesOut ${src_out_n} 处（取样函数本体原样）"
else
    fail C7 "数据源被改：LeapinEngine.shared ${engine_n}（要求 1）、bytesIn ${src_in_n}（≥2）、bytesOut ${src_out_n}（≥2）"
fi

echo "----------------------------------------------------------------"
echo "T-11 结果：${PASSED} PASS / ${FAILED} FAIL（C0 构建 · C1 指标分支接观测视图 · C2 embedded 参数 · C3 导航标题受控 · C4 hero 受控 · C5 无新增 Timer · C6 指标本体 · C7 数据源未改）"
if [ "$FAILED" -gt 0 ]; then
    exit 1
fi
exit 0

# 反向验证（证明这些断言能红，不只是恒绿）。每条都只红自己那一条，实测过：
#   cp Sources/LeapinApp/Views/WhyPage.swift /tmp/T11-why-broken.swift
#   perl -0pi -e 's/ObservationView\(embedded: true\)/WhyPendingTab(tab: .metrics)/g' /tmp/T11-why-broken.swift
#   T11_WHY=/tmp/T11-why-broken.swift T11_SKIP_BUILD=1 bash qa/T-11/run.sh    # 预期 C1 FAIL
#   （少了结尾的 /g 只会改到文档注释里那一次，代码里的调用还在——那样反而验不出东西。）
#
#   cp Sources/LeapinApp/Views/ObservationView.swift /tmp/T11-obs-broken.swift
#   perl -0pi -e 's/init\(embedded: Bool = false\)/init(embedded: Bool)/' /tmp/T11-obs-broken.swift
#   T11_OBS=/tmp/T11-obs-broken.swift T11_SKIP_BUILD=1 bash qa/T-11/run.sh    # 预期 C2 FAIL
#
#   perl -0pi -e 's/if embedded \{\n\s*page\n\s*\} else \{\n\s*page\.navigationTitle\("观测"\)\n\s*\}/page.navigationTitle("观测")/' /tmp/T11-obs-broken.swift
#   T11_OBS=/tmp/T11-obs-broken.swift T11_SKIP_BUILD=1 bash qa/T-11/run.sh    # 预期 C3 FAIL
#
#   perl -0pi -e 's/if !embedded \{\n\s*hero\.lpAppear\(0\)/hero.lpAppear(0)/' /tmp/T11-obs-broken.swift
#   T11_OBS=/tmp/T11-obs-broken.swift T11_SKIP_BUILD=1 bash qa/T-11/run.sh    # 预期 C4 FAIL
