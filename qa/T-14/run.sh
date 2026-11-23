#!/usr/bin/env bash
# T-14 汇总验收：S2 走查的自动化部分 + M2 全局结构断言
# 用法：bash qa/T-14/run.sh
#
# 两种模式，避免同一个任务在一次回归里跑两遍：
#   1) 单独跑：逐个调用 qa/T-05 .. qa/T-13 的 run.sh，汇总每个任务的 PASS/FAIL；
#   2) 由 qa/run-all.sh 调用（QA_RUN_ALL=1）：父脚本已经在本轮逐个执行过它们，
#      结果写在 QA_RUN_ALL_RESULTS（TSV：task<TAB>PASS|FAIL），这里只核对那份账，
#      再补本任务的全局结构断言。
#
# 静态断言（DoD 第 1 条）：
#   - 侧栏 11 行 / 3 组 / 四个动词
#   - Privacy 不可达（枚举、壳、Debug 快照）
#   - 五个并入页没有独立侧栏入口（去广告 / 抓包 / 活动 / 排障 / 隐私）
#
# S2 的人工部分在 qa/T-14/report.md（计时模板），脚本不伪造耗时。
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT" || { echo "FAIL C0  无法进入仓库"; exit 1; }

TASKS=(T-05 T-06 T-07 T-08 T-09 T-10 T-11 T-12 T-13)
WORKBENCH="Sources/LeapinRuntime/Workbench.swift"
APP="Sources/LeapinApp/LeapinApp.swift"
PLATFORM="Sources/LeapinApp/Platform.swift"
PRIVACY="Sources/LeapinApp/Views/PrivacyView.swift"

PASSED=0
FAILED=0
pass() { printf 'PASS %-3s %s\n' "$1" "$2"; PASSED=$((PASSED + 1)); }
fail() { printf 'FAIL %-3s %s\n' "$1" "$2"; FAILED=$((FAILED + 1)); }

for f in "$WORKBENCH" "$APP" "$PLATFORM"; do
    [ -f "$f" ] || { echo "FAIL C0  缺少文件 $f"; exit 1; }
done

echo "T-14 汇总验收 · 仓库 $ROOT"
echo "----------------------------------------------------------------"

# ---------------------------------------------------------------- C1 子任务账本
if [ "${QA_RUN_ALL:-0}" = "1" ] && [ -n "${QA_RUN_ALL_RESULTS:-}" ] && [ -f "${QA_RUN_ALL_RESULTS}" ]; then
    mode="run-all 账本 ${QA_RUN_ALL_RESULTS}（父脚本已逐个执行，这里不重复跑）"
    missing=""
    failed_tasks=""
    for t in "${TASKS[@]}"; do
        row=$(awk -F '\t' -v task="$t" '$1 == task { print $2; exit }' "${QA_RUN_ALL_RESULTS}")
        if [ -z "$row" ]; then
            missing="${missing} ${t}"
        elif [ "$row" != "PASS" ]; then
            failed_tasks="${failed_tasks} ${t}"
        fi
    done
    if [ -z "$missing" ] && [ -z "$failed_tasks" ]; then
        pass C1 "9 个子任务（T-05..T-13）在本轮回归中逐个通过：${mode}"
    else
        fail C1 "子任务未全绿：缺账=[${missing:- 无}]、失败=[${failed_tasks:- 无}]（${mode}）"
    fi
else
    mode="单独执行：逐个调用子任务脚本"
    failed_tasks=""
    ran=0
    for t in "${TASKS[@]}"; do
        script="qa/${t}/run.sh"
        echo "---- 运行 ${script}"
        if [ ! -f "$script" ]; then
            failed_tasks="${failed_tasks} ${t}(missing)"
            continue
        fi
        ran=$((ran + 1))
        if bash "$script" >/tmp/t14-${t}.log 2>&1; then
            echo "     PASS ${t}（日志 /tmp/t14-${t}.log）"
        else
            echo "     FAIL ${t}（日志 /tmp/t14-${t}.log）"
            failed_tasks="${failed_tasks} ${t}"
        fi
    done
    if [ "$ran" -ge 4 ] && [ -z "$failed_tasks" ]; then
        pass C1 "${ran} 个子任务脚本全部通过（${mode}）"
    else
        fail C1 "子任务未全绿：执行 ${ran} 个、失败=[${failed_tasks:- 无}]（${mode}）"
    fi
fi

# ---------------------------------------------------------------- C2 侧栏 11 行 / 3 组
row_n=$(grep -cE '^[[:space:]]+Row\(title:' "$WORKBENCH" || true)
group_n=$(grep -cE '^[[:space:]]+Group\(name:' "$WORKBENCH" || true)
verb_n=$(grep -cE '^[[:space:]]+case (goWhere|howJudged|whatChanged|why)$' "$WORKBENCH" || true)
titles=$(grep -oE 'Row\(title: "[^"]+"' "$WORKBENCH" | sed -E 's/.*"([^"]+)"/\1/' | tr '\n' ' ')
if [ "$row_n" -eq 11 ] && [ "$group_n" -eq 3 ] && [ "$verb_n" -eq 4 ]; then
    pass C2 "侧栏 = ${row_n} 行 / ${group_n} 组；四个动词 case ${verb_n} 个；固定标题：${titles}"
else
    fail C2 "侧栏结构不符：行 ${row_n}（11）、组 ${group_n}（3）、动词 ${verb_n}（4）；标题 ${titles}"
fi

# ---------------------------------------------------------------- C3 四个动词 + 快捷键
shortcuts=$(grep -cE 'case \..*: return "[1-4]"' "$WORKBENCH" || true)
verb_case_n=$(grep -cE '^        case \.(goWhere|howJudged|whatChanged|why): return "' "$WORKBENCH" || true)
if [ "$shortcuts" -ge 4 ] && [ "$verb_case_n" -ge 4 ]; then
    pass C3 "四动词的标题 / 问题 / 落点由同一枚举给出：快捷键分支 ${shortcuts} 处、文案分支 ${verb_case_n} 处（≥4）"
else
    fail C3 "动词定义不全：快捷键分支 ${shortcuts}（≥4）、文案分支 ${verb_case_n}（≥4）"
fi

# ---------------------------------------------------------------- C4 Privacy 不可达
app_privacy=$(grep -c 'privacy' "$APP" || true)
plat_privacy=$(grep -c 'privacy' "$PLATFORM" || true)
src_hits=$(grep -rl 'PrivacyView' Sources/ Tests/ 2>/dev/null | tr '\n' ' ')
file_gone=0; [ -f "$PRIVACY" ] || file_gone=1
if [ "$app_privacy" -eq 0 ] && [ "$plat_privacy" -eq 0 ] && [ "$file_gone" -eq 1 ] && [ -z "$src_hits" ]; then
    pass C4 "Privacy 不可达：LeapinApp.swift ${app_privacy} 处、Platform.swift ${plat_privacy} 处（各要求 0）；PrivacyView.swift 已删除；Sources/ Tests/ 无引用"
else
    fail C4 "Privacy 仍可达：LeapinApp ${app_privacy}（0）、Platform ${plat_privacy}（0）、文件还在=$((1 - file_gone))（0）、引用=[${src_hits:- 无}]"
fi

# ---------------------------------------------------------------- C5 并入页没有独立侧栏入口
merged_hits=""
for t in 去广告 抓包 网络活动 活动 排障 诊断 · 隐私 评分 线路与订阅; do
    n=$(grep -cF "Row(title: "${t}"" "$WORKBENCH" || true)
    [ "$n" -eq 0 ] || merged_hits="${merged_hits} ${t}=${n}"
done
merged_dest=$(grep -cE 'destination: [.]section\(("adblock"|"capture"|"activity"|"diagnostics"|"privacy")' "$WORKBENCH" || true)
if [ -z "$merged_hits" ] && [ "$merged_dest" -eq 0 ]; then
    pass C5 "五个并入页没有独立侧栏行：${merged_hits:- 无}；侧栏也不直接落 adblock/capture/activity/diagnostics/privacy（${merged_dest} 处，要求 0）"
else
    fail C5 "并入页仍有独立入口：[${merged_hits:- 无}]；侧栏直落退役 rawValue ${merged_dest} 处（要求 0）"
fi

# ---------------------------------------------------------------- C6 四个动词落点可走
dash=$(grep -cF 'case .dashboard: GoWherePage(initialTab: .overview)' "$APP" || true)
rules=$(grep -cF 'case .rules: RulesView()' "$APP" || true)
rewrite=$(grep -cF 'case .rewrite: RewriteView()' "$APP" || true)
why=$(grep -cF 'case .why, .capture: WhyPage(initialTab: .connections)' "$APP" || true)
if [ "$dash" -eq 1 ] && [ "$rules" -eq 1 ] && [ "$rewrite" -eq 1 ] && [ "$why" -eq 1 ]; then
    pass C6 "四动词落点各 1 条：dashboard → 走哪、rules → 怎么判、rewrite → 改成什么、why → 为什么"
else
    fail C6 "动词落点不符：dashboard ${dash}、rules ${rules}、rewrite ${rewrite}、why ${why}（各要求 1）"
fi

echo "----------------------------------------------------------------"
echo "T-14 结果：${PASSED} PASS / ${FAILED} FAIL（C1 子任务账本 · C2 11 行 3 组 · C3 四动词 · C4 Privacy 不可达 · C5 并入页无入口 · C6 动词落点）"
[ "$FAILED" -gt 0 ] && exit 1
exit 0
