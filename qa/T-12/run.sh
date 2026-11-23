#!/usr/bin/env bash
# T-12 验收：为什么 · 探测 / 诊断 tab + 原地 RuleDraft 重测（S2）
# 用法：bash qa/T-12/run.sh
#
#   1) 构建（DoD 第 4 条前半）：swift build --scratch-path /tmp/t12-scratch --disable-sandbox
#      顺带要求本任务四个源文件零 warning。
#   2) 静态断言：
#      C2 探测 / 诊断两个 tab 接到同一个工作区（不再有占位壳）
#      C3 原地链路：submit(host:policy:) → RuleDraft → makeRuleSetEntry → diagnose(target)
#      C4 NetworkRuleChange 的 policy 从入参来，不再写死 DIRECT
#      C5 报告卡接受工作区传参：原地重测 + 导出
#      C6 不跳页：为什么页里没有任何 app.go(to:)
#   3) 全量单测（DoD 第 4 条后半）另行：swift test --scratch-path /tmp/t12-scratch --disable-sandbox
#
# 只读仓库，不改任何文件。任何一条 FAIL → 退出码 1。T12_SKIP_BUILD=1 只跳过 C1。
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT" || { echo "FAIL C0  无法进入仓库"; exit 1; }

WHY="Sources/LeapinApp/Views/WhyPage.swift"
ASSIST="Sources/LeapinApp/Design/NetworkAssistant.swift"
TASK="Sources/LeapinRuntime/NetworkTask.swift"
REPORT="Sources/LeapinApp/Views/DiagnosticReportView.swift"
SCRATCH="${T12_SCRATCH:-/tmp/t12-scratch}"
SKIP_BUILD="${T12_SKIP_BUILD:-0}"

PASSED=0
FAILED=0
pass() { printf 'PASS %-3s %s\n' "$1" "$2"; PASSED=$((PASSED + 1)); }
fail() { printf 'FAIL %-3s %s\n' "$1" "$2"; FAILED=$((FAILED + 1)); }

for f in "$WHY" "$ASSIST" "$TASK" "$REPORT"; do
    [ -f "$f" ] || { echo "FAIL C0  缺少文件 $f"; exit 1; }
done

echo "T-12 验收 · 仓库 $ROOT"
echo "被检查文件：WhyPage / NetworkAssistant / NetworkTask / DiagnosticReportView（只读）"
echo "构建 scratch ${SCRATCH}"
echo "----------------------------------------------------------------"

# 判代码不判注释
strip() { sed -E 's://.*$::' "$1"; }
why_code=$(strip "$WHY")
assist_code=$(strip "$ASSIST")
task_code=$(strip "$TASK")
report_code=$(strip "$REPORT")

# ---------------------------------------------------------------- C1 构建
if [ "$SKIP_BUILD" = "1" ]; then
    echo "SKIP C1  按 T12_SKIP_BUILD=1 跳过构建（只做静态断言）"
elif ! command -v swift >/dev/null 2>&1; then
    fail C1 "找不到 swift 命令，无法构建"
else
    log="$(mktemp "${TMPDIR:-/tmp}/t12-build.XXXXXX")"
    swift build --scratch-path "$SCRATCH" --disable-sandbox > "$log" 2>&1
    status=$?
    own_warn=$(grep -F 'warning:' "$log" | grep -cE 'WhyPage\.swift|NetworkAssistant\.swift|NetworkTask\.swift|DiagnosticReportView\.swift' || true)
    if [ "$status" -eq 0 ] && [ "$own_warn" -eq 0 ]; then
        pass C1 "swift build 成功（退出码 0）；本任务四个文件的 warning ${own_warn} 条（要求 0）"
    else
        fail C1 "构建不干净：退出码 ${status}、本任务文件 warning ${own_warn} 条（要求 0）。日志尾部：$(tail -4 "$log" | tr '\n' ' ')"
    fi
    rm -f "$log"
fi

# ---------------------------------------------------------------- C2 两个 tab 接到工作区
probes_n=$(printf '%s\n' "$why_code" | grep -cF 'case .probes: DiagnosticsWorkspace(assistant: assistant, scope: .probes, embedded: true, isActive: item == tab)' || true)
diag_n=$(printf '%s\n' "$why_code" | grep -cF 'case .diagnostics: DiagnosticsWorkspace(assistant: assistant, scope: .full, embedded: true, isActive: item == tab)' || true)
focus_gate=$(printf '%s\n' "$assist_code" | grep -cF 'guard isActive else { return }' || true)
stub_n=$(printf '%s\n' "$why_code" | grep -cF 'WhyPendingTab' || true)
shared=$(printf '%s\n' "$why_code" | grep -cF '@StateObject private var assistant = NetworkAssistantModel()' || true)
if [ "$probes_n" -eq 1 ] && [ "$diag_n" -eq 1 ] && [ "$stub_n" -eq 0 ] && [ "$shared" -eq 1 ] && [ "$focus_gate" -eq 1 ]; then
    pass C2 "探测 / 诊断接到同一个工作区：probes ${probes_n} 处、diagnostics ${diag_n} 处、占位壳 ${stub_n} 处（要求 0）、两 tab 共用 ${shared} 个模型（要求 1）；可见性只让当前 tab 接聚焦请求（${focus_gate} 处）"
else
    fail C2 "tab 未接上：probes ${probes_n}（1）、diagnostics ${diag_n}（1）、占位壳 ${stub_n}（0）、共用模型 ${shared}（1）、聚焦门 ${focus_gate}（1）"
fi

# ---------------------------------------------------------------- C3 原地链路
submit_fn=$(printf '%s\n' "$assist_code" | grep -cF 'func submit(host: String, policy: String) -> Bool' || true)
draft_n=$(printf '%s\n' "$assist_code" | grep -cF 'let draft = RuleDraft(host: target.host, policy: policy, source: .manual)' || true)
change_n=$(printf '%s\n' "$assist_code" | grep -cF 'NetworkRuleChange(profile: snapshot, target: target, policy: policy)' || true)
commit_n=$(printf '%s\n' "$assist_code" | grep -cF 'engine.commitTaskRules(expected: snapshot, rules: change.after)' || true)
# diagnose(target) 全文会出现多次（检查按钮 / 报告卡重测也调它），所以必须锚在 submit 函数体内，
# 否则删掉 submit 里的那一次调用断言仍然常绿（T-14 评审 B4 实测过）。
submit_body=$(printf '%s\n' "$assist_code" | awk '/func submit\(host: String, policy: String\)/{f=1} f{print} f && /^    }$/{exit}')
diagnose_n=$(printf '%s\n' "$submit_body" | grep -cF 'diagnose(target)' || true)
call_n=$(printf '%s\n' "$why_code" | grep -cF 'assistant.submit(host: draft.host, policy: draft.policy)' || true)
make_n=$(printf '%s\n' "$task_code" | grep -cF '.makeRuleSetEntry(existing: before)' || true)
if [ "$submit_fn" -eq 1 ] && [ "$draft_n" -eq 1 ] && [ "$change_n" -eq 1 ] && [ "$commit_n" -eq 1 ] \
   && [ "$diagnose_n" -eq 1 ] && [ "$call_n" -eq 1 ] && [ "$make_n" -eq 1 ]; then
    pass C3 "S2 原地链路齐：submit(host:policy:) ${submit_fn} 处；RuleDraft ${draft_n} 处 → NetworkRuleChange ${change_n} 处 → commit ${commit_n} 处 → submit 体内 diagnose(target) ${diagnose_n} 处；WhyPage 的单次调用 ${call_n} 处；规则体由 makeRuleSetEntry 生成 ${make_n} 处（置顶与去重走 T-05 的同一实现）"
else
    fail C3 "原地链路缺环：submit ${submit_fn}（1）、RuleDraft ${draft_n}（1）、NetworkRuleChange ${change_n}（1）、commit ${commit_n}（1）、submit 体内 diagnose ${diagnose_n}（1）、WhyPage 调用 ${call_n}（1）、makeRuleSetEntry ${make_n}（1）"
fi

# ---------------------------------------------------------------- C4 policy 从入参来
policy_param=$(printf '%s\n' "$task_code" | grep -cF 'policy: String = "DIRECT"' || true)
policy_field=$(printf '%s\n' "$task_code" | grep -cF 'public let policy: String' || true)
policy_use=$(printf '%s\n' "$task_code" | grep -cF 'RuleDraft(host: target.host, policy: policy, source: .manual)' || true)
hard_direct=$(printf '%s\n' "$task_code" | grep -cF 'policy: "DIRECT",' || true)
if [ "$policy_param" -eq 1 ] && [ "$policy_field" -eq 1 ] && [ "$policy_use" -eq 1 ] && [ "$hard_direct" -eq 0 ]; then
    pass C4 "NetworkRuleChange 的 policy 参数化：init(policy: String = "DIRECT") ${policy_param} 处、字段 ${policy_field} 处、规则由传入 policy 生成 ${policy_use} 处；写死 DIRECT 的旧构造 ${hard_direct} 处（要求 0）"
else
    fail C4 "policy 没有真正参数化：init 默认 ${policy_param}（1）、字段 ${policy_field}（1）、按入参生成 ${policy_use}（1）、写死 ${hard_direct}（0）"
fi

# ---------------------------------------------------------------- C5 报告卡接受工作区传参
retest_param=$(printf '%s\n' "$report_code" | grep -cF 'var onRetest: (() -> Void)? = nil' || true)
export_fn=$(printf '%s\n' "$report_code" | grep -cF 'private func export()' || true)
save_panel=$(printf '%s\n' "$report_code" | grep -cF 'NSSavePanel()' || true)
retest_btn=$(printf '%s\n' "$report_code" | grep -cF 'Button("重新检查") { onRetest() }' || true)
ws_call=$(printf '%s\n' "$assist_code" | grep -cF 'DiagnosticReportView(report: report,' || true)
ws_retest_param=$(printf '%s\n' "$assist_code" | grep -cF 'onRetest: retestAction' || true)
ws_retest_gate=$(printf '%s\n' "$assist_code" | grep -cF 'assistant.lastTarget == nil ? nil : { retest() }' || true)
ws_retest=$(printf '%s\n' "$assist_code" | grep -cF 'assistant.diagnose(target)' || true)
outside_n=$(grep -rl 'DiagnosticReportView(report:' Sources/ | grep -v 'NetworkAssistant.swift' | wc -l | tr -d ' ')
if [ "$retest_param" -eq 1 ] && [ "$export_fn" -eq 1 ] && [ "$save_panel" -ge 1 ] && [ "$retest_btn" -eq 1 ] \
   && [ "$ws_call" -eq 1 ] && [ "$ws_retest_param" -eq 1 ] && [ "$ws_retest_gate" -eq 1 ] \
   && [ "$ws_retest" -ge 1 ] && [ "$outside_n" -eq 0 ]; then
    pass C5 "结果卡是工作区内部的一块：onRetest 参数 ${retest_param} 处、导出 ${export_fn} 处（NSSavePanel ${save_panel}）、原地重测按钮 ${retest_btn} 处；工作区传参 ${ws_call} 处、仅在 lastTarget 存在时给动作 ${ws_retest_param}/${ws_retest_gate} 处，并接回 diagnose ${ws_retest} 处；工作区之外独立实例化 ${outside_n} 处（要求 0）"
else
    fail C5 "结果卡接口不符：onRetest ${retest_param}（1）、export ${export_fn}（1）、NSSavePanel ${save_panel}（≥1）、重测按钮 ${retest_btn}（1）、工作区调用 ${ws_call}（1）、传动作 ${ws_retest_param}（1）、无 host 时空动作 ${ws_retest_gate}（1）、工作区 diagnose ${ws_retest}（≥1）、外部实例化 ${outside_n}（0）"
fi

# ---------------------------------------------------------------- C6 编辑器在本页 + 不跳页
entry_btn=$(printf '%s\n' "$why_code" | grep -cF 'Button("改成走公司…")' || true)
sheet_n=$(printf '%s\n' "$why_code" | grep -cF '.sheet(item: $ruleEditor)' || true)
seed_n=$(printf '%s\n' "$why_code" | grep -cF 'struct RuleDraftSeed: Identifiable, Equatable' || true)
editor_n=$(printf '%s\n' "$why_code" | grep -cF 'RuleDraftEditor(seed: draft, policies: policyChoices)' || true)
policy_n=$(printf '%s\n' "$why_code" | grep -cF 'profile.groups' || true)
nav_n=$(printf '%s\n' "$why_code" | grep -cF 'app.go(to:' || true)
did_not_leave=$(printf '%s\n' "$why_code" | grep -cF 'mounted.insert(.diagnostics)' || true)
if [ "$entry_btn" -eq 1 ] && [ "$sheet_n" -eq 1 ] && [ "$seed_n" -eq 1 ] && [ "$editor_n" -eq 1 ] \
   && [ "$policy_n" -ge 1 ] && [ "$nav_n" -eq 0 ] && [ "$did_not_leave" -ge 1 ]; then
    pass C6 "原地改路在本页：入口 ${entry_btn} 处、sheet ${sheet_n} 处、RuleDraftSeed ${seed_n} 处、编辑器 ${editor_n} 处；出口清单取自现配置（profile.groups ${policy_n} 处）；WhyPage 里 app.go(to:) ${nav_n} 处（要求 0，不跳页）；保存后切到本页诊断 tab ${did_not_leave} 处"
else
    fail C6 "原地编辑器不符：入口 ${entry_btn}（1）、sheet ${sheet_n}（1）、seed ${seed_n}（1）、editor ${editor_n}（1）、policy 来源 ${policy_n}（≥1）、跳页 ${nav_n}（0）、保存后落点 ${did_not_leave}（≥1）"
fi

# ---------------------------------------------------------------- C7 全量单测
test_log="${T12_LOGDIR:-/tmp}/t12-test.log"
swift test --scratch-path "$SCRATCH" --disable-sandbox > "$test_log" 2>&1
rc=$?
failed_cases=$(grep -cE "Test Case '.*' failed" "$test_log" || true)
summary=$(grep -E 'Executed [0-9]+ tests?, with [0-9]+ failures?' "$test_log" | tail -1)
if [ "$rc" -eq 0 ] && [ "$failed_cases" -eq 0 ] && [ -n "$summary" ] && printf '%s' "$summary" | grep -q 'with 0 failures'; then
    pass C7 "swift test → exit 0；失败用例 ${failed_cases} 个；汇总：${summary}（日志 ${test_log}）"
else
    fail C7 "全量测试未全绿：退出码 ${rc}、失败用例 ${failed_cases}、汇总 ${summary:-（无）}；首个失败：$(grep -m1E "Test Case .* failed" "$test_log" || echo '无')"
fi

echo "----------------------------------------------------------------"
echo "T-12 结果：${PASSED} PASS / ${FAILED} FAIL（C1 构建 · C2 两 tab 接工作区 · C3 原地链路 · C4 policy 参数化 · C5 结果卡 · C6 编辑器与不跳页 · C7 全量测试）"
[ "$FAILED" -gt 0 ] && exit 1
exit 0

# 反向验证（证明断言能红）：
#   cp Sources/LeapinApp/Views/WhyPage.swift /tmp/T12-why-broken.swift
#   perl -0pi -e 's/DiagnosticsWorkspace\(assistant: assistant, scope: .probes, embedded: true\)/WhyPendingTab(tab: .probes)/' /tmp/T12-why-broken.swift
#   (cd . && T12_SKIP_BUILD=1 ...) —— 脚本不读 WHY 环境变量；反向验证用仓库临时副本：
#   rsync -a --exclude .build ./ /tmp/t12-red/ && 改 /tmp/t12-red 的 WhyPage 后 (cd /tmp/t12-red && bash qa/T-12/run.sh)
#   预期 C2 FAIL、退出码 1。
