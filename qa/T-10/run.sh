#!/usr/bin/env bash
# T-10 验收：怎么判（策略组 + 学习建议 + 带 host 跳转 + 被遮蔽/不可达标记）
# 用法：bash qa/T-10/run.sh
#
# 这一份只做**静态断言**（DoD 第 1 条），不编译、不起 App：
# 构建与单测是任务 DoD 第 3 条的独立命令，重复跑一遍只会把两件事混成一件事。
#   swift build --scratch-path /tmp/t10-scratch --disable-sandbox
#   swift test  --scratch-path /tmp/t10-scratch --disable-sandbox --filter WorkbenchTests
#
# 只读仓库，不改任何文件。任何一条 FAIL → 退出码 1。
# 每条断言都对着一个具体字符串/行号顺序，所以它能红；RULES 可用环境变量指向
# 一份被改坏的副本做反向验证（见文件末尾注释）。
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT" || { echo "FAIL C0  无法进入仓库"; exit 1; }

RULES="${T10_RULES:-Sources/LeapinApp/Views/RulesView.swift}"

PASSED=0
FAILED=0
pass() { printf 'PASS %-3s %s\n' "$1" "$2"; PASSED=$((PASSED + 1)); }
fail() { printf 'FAIL %-3s %s\n' "$1" "$2"; FAILED=$((FAILED + 1)); }

echo "T-10 验收 · 仓库 $ROOT"
echo "被检查文件：${RULES}（只读）"
echo "----------------------------------------------------------------"

[ -f "$RULES" ] || { echo "FAIL C0  缺少文件 $RULES"; exit 1; }

# 判代码不判注释：注释里解释「为什么」不算实现，断言一律打在剥离注释后的文本上。
code=$(sed -E 's://.*$::' "$RULES")
# 去掉注释后行号会漂移，涉及行号顺序的断言另取一份保留空行的版本。
codekeep=$(sed -E 's://.*$::' "$RULES")

# ---------------------------------------------------------------- C1 带 host 跳转
focus_n=$(printf '%s\n' "$code" | grep -cF 'routes.focus(RouteSubject(' || true)
src_rule_n=$(printf '%s\n' "$code" | grep -cF 'source: .rule' || true)
go_why_n=$(printf '%s\n' "$code" | grep -cF 'app.go(to: .why)' || true)
focus_line=$(printf '%s\n' "$codekeep" | grep -nF 'routes.focus(RouteSubject(' | head -1 | cut -d: -f1)
go_line=$(printf '%s\n' "$codekeep" | grep -nF 'app.go(to: .why)' | head -1 | cut -d: -f1)
gap=""
if [ -n "$focus_line" ] && [ -n "$go_line" ] && [ "$go_line" -gt "$focus_line" ]; then
    gap=$((go_line - focus_line))
fi
if [ "$focus_n" -ge 1 ] && [ "$src_rule_n" -ge 1 ] && [ "$go_why_n" -ge 1 ] && [ -n "$gap" ] && [ "$gap" -le 3 ]; then
    pass C1 "带 host 跳转：routes.focus(RouteSubject( ${focus_n} 处（source: .rule ${src_rule_n} 处），app.go(to: .why) ${go_why_n} 处；第 ${focus_line} 行取上下文、第 ${go_line} 行切页，同一函数内相隔 ${gap} 行"
else
    fail C1 "带 host 跳转不成立：focus ${focus_n}（要求 ≥1）、source: .rule ${src_rule_n}（要求 ≥1）、go(to: .why) ${go_why_n}（要求 ≥1）、focus 行 [${focus_line:-空}] / go 行 [${go_line:-空}]（要求 go 在 focus 之后 1–3 行内）"
fi

# ---------------------------------------------------------------- C2 取不出域名就禁用并说明
disabled_n=$(printf '%s\n' "$code" | grep -cF '.disabled(host == nil)' || true)
reason_n=$(printf '%s\n' "$code" | grep -cF 'whyUnavailableReason(for: rule)' || true)
host_n=$(printf '%s\n' "$code" | grep -cF 'private func whyHost(for rule: Rule)' || true)
guess_n=$(printf '%s\n' "$code" | grep -cE 'host *= *"[^"]*"' || true)
if [ "$disabled_n" -ge 1 ] && [ "$reason_n" -ge 2 ] && [ "$host_n" -ge 1 ] && [ "$guess_n" -eq 0 ]; then
    pass C2 "取不出域名即禁用：whyHost(for:) ${host_n} 处、.disabled(host == nil) ${disabled_n} 处、whyUnavailableReason 用于 help/旁白共 ${reason_n} 处；代码里硬编码 host 字面 ${guess_n} 处（要求 0，不许猜一个 host 去问）"
else
    fail C2 "禁用与说明不全：whyHost ${host_n}（≥1）、disabled(host == nil) ${disabled_n}（≥1）、whyUnavailableReason 调用 ${reason_n}（≥2：help + 旁白）、硬编码 host 字面 ${guess_n}（要求 0）"
fi

# ---------------------------------------------------------------- C3 学习建议入口
learn_n=$(printf '%s\n' "$code" | grep -cF 'app.go(to: .learn)' || true)
label_n=$(grep -cF '学习建议' "$RULES" || true)
footer_n=$(printf '%s\n' "$code" | grep -cF 'private var learnFooter' || true)
if [ "$learn_n" -ge 1 ] && [ "$label_n" -ge 1 ] && [ "$footer_n" -ge 1 ]; then
    pass C3 "学习建议入口：learnFooter ${footer_n} 处、app.go(to: .learn) ${learn_n} 处、「学习建议」文案 ${label_n} 处（目标页 Section.learn → LearnView）"
else
    fail C3 "学习建议入口缺失：learnFooter ${footer_n}（要求 1）、go(to: .learn) ${learn_n}（≥1）、文案 ${label_n}（≥1）"
fi

# ---------------------------------------------------------------- C4 被遮蔽 / 不可达标记
shadow_case=$(printf '%s\n' "$code" | grep -cF 'case .shadowed: return "被遮蔽"' || true)
unreach_case=$(printf '%s\n' "$code" | grep -cF 'case .unreachable: return "不可达"' || true)
badge_dyn=$(printf '%s\n' "$code" | grep -cF 'Badge(text: Self.diagnosticLabel(diagnostic.kind)' || true)
badge_fixed=$(printf '%s\n' "$code" | grep -cF 'Badge(text: "永不命中"' || true)
shadowed_by=$(printf '%s\n' "$code" | grep -cF 'diagnostic.reason' || true)
if [ "$shadow_case" -ge 1 ] && [ "$unreach_case" -ge 1 ] && [ "$badge_dyn" -ge 1 ] && [ "$badge_fixed" -eq 0 ] && [ "$shadowed_by" -ge 1 ]; then
    pass C4 "遮蔽标记：.shadowed→「被遮蔽」${shadow_case} 处、.unreachable→「不可达」${unreach_case} 处；行尾 Badge 按诊断类型动态取标签 ${badge_dyn} 处（写死的「永不命中」${badge_fixed} 处，要求 0），被谁遮蔽的原因进 help ${shadowed_by} 处"
else
    fail C4 "遮蔽标记不成立：shadowed 标签 ${shadow_case}（≥1）、unreachable 标签 ${unreach_case}（≥1）、动态 Badge ${badge_dyn}（≥1）、写死「永不命中」${badge_fixed}（要求 0）、reason 进 help ${shadowed_by}（≥1）"
fi

# ---------------------------------------------------------------- C5 策略组两套来源
native_group=$(printf '%s\n' "$code" | grep -cF 'ForEach(engine.profile.groups)' || true)
native_sel=$(printf '%s\n' "$code" | grep -cF 'engine.selectOutbound(group: group.name' || true)
kernel_branch=$(printf '%s\n' "$code" | grep -cF 'if engine.executionKernel == .mihomo' || true)
managed_load=$(printf '%s\n' "$code" | grep -cF 'engine.managedPolicies()' || true)
managed_sel=$(printf '%s\n' "$code" | grep -cF 'engine.selectManagedPolicy(group: group' || true)
if [ "$native_group" -ge 1 ] && [ "$native_sel" -ge 1 ] && [ "$kernel_branch" -ge 1 ] && [ "$managed_load" -ge 1 ] && [ "$managed_sel" -ge 1 ]; then
    pass C5 "策略组：原生 profile.groups ${native_group} 处 + selectOutbound ${native_sel} 处；Mihomo 分支 ${kernel_branch} 处 + managedPolicies() ${managed_load} 处 + selectManagedPolicy ${managed_sel} 处"
else
    fail C5 "策略组缺一支：profile.groups ${native_group}、selectOutbound ${native_sel}、mihomo 分支 ${kernel_branch}、managedPolicies ${managed_load}、selectManagedPolicy ${managed_sel}（各要求 ≥1）"
fi

# ---------------------------------------------------------------- C6 上下文注入与只读纪律
env_n=$(printf '%s\n' "$code" | grep -cF '@EnvironmentObject private var routes: RouteContext' || true)
eval_n=$(printf '%s\n' "$code" | grep -cE 'func (match|evaluate|judge)\(' || true)
if [ "$env_n" -eq 1 ] && [ "$eval_n" -eq 0 ]; then
    pass C6 "RouteContext：@EnvironmentObject 注入 ${env_n} 处（要求 1）；本文件新增求值函数 ${eval_n} 处（要求 0，只展示不改判）"
else
    fail C6 "RouteContext 注入 ${env_n}（要求 1，缺了会运行时崩）；本文件出现求值函数 ${eval_n} 处（要求 0）"
fi

# ---------------------------------------------------------------- C7 读动作不被写入口连坐
# 评审指出：追问按钮曾落在 ruleList 的 disabled 子树里，Mihomo 下连只读动作一起被锁。
# 这里把「只锁写」写成可复跑的结构断言，而不是靠人再看一遍。
rulelist_line=$(printf '%s\n' "$codekeep" | grep -nE '^ *ruleList$' | head -1 | cut -d: -f1)
block_disable=0
if [ -n "$rulelist_line" ]; then
    block_disable=$(printf '%s\n' "$codekeep" \
        | sed -n "$((rulelist_line + 1)),$((rulelist_line + 3))p" \
        | grep -cF '.disabled(engine.executionKernel == .mihomo)' || true)
fi
why_line=$(printf '%s\n' "$codekeep" | grep -nF 'whyButton(for: rule, host: why)' | head -1 | cut -d: -f1)
why_disabled=0
if [ -n "$why_line" ]; then
    why_disabled=$(printf '%s\n' "$codekeep" | sed -n "${why_line},$((why_line + 2))p" | grep -cF '.disabled(' || true)
fi
del_guard=$(printf '%s\n' "$code" | grep -A1 -F 'Button("删除规则", role: .destructive) { pendingDelete = rule }' | grep -cF '.disabled(engine.executionKernel == .mihomo)' || true)
guard_n=$(printf '%s\n' "$code" | grep -cF 'guard engine.executionKernel != .mihomo else { return }' || true)
if [ -n "$rulelist_line" ] && [ "$block_disable" -eq 0 ] && [ -n "$why_line" ] && [ "$why_disabled" -eq 0 ] \
   && [ "$del_guard" -ge 1 ] && [ "$guard_n" -ge 2 ]; then
    pass C7 "只锁写：ruleList 之后 3 行内区块级 disable ${block_disable} 处（要求 0，读写不再连坐）；追问按钮调用第 ${why_line} 行及其后 2 行内 disable ${why_disabled} 处（要求 0）；删除菜单项带写锁 ${del_guard} 处、⌫/空态写入口守卫 ${guard_n} 处（要求 ≥2）"
else
    fail C7 "读写仍连坐或写入口漏锁：ruleList 区块 disable ${block_disable}（要求 0）、追问按钮 disable ${why_disabled}（要求 0）、删除菜单写锁 ${del_guard}（≥1）、写入口守卫 ${guard_n}（≥2）"
fi

echo "----------------------------------------------------------------"
echo "T-10 结果：${PASSED} PASS / ${FAILED} FAIL（C1 带 host 跳转 · C2 取不到域名即禁用 · C3 学习建议入口 · C4 被遮蔽/不可达标记 · C5 策略组两套来源 · C6 上下文与只读纪律 · C7 只锁写不锁读）"
if [ "$FAILED" -gt 0 ]; then
    exit 1
fi
exit 0

# 反向验证（证明这些断言能红，不只是恒绿）：
#   cp Sources/LeapinApp/Views/RulesView.swift /tmp/T10-broken.swift
#   perl -0pi -e 's/routes\.focus\(RouteSubject\(/routes.peek(/; s/app\.go\(to: \.why\)/app.showToast("x")/' /tmp/T10-broken.swift
#   T10_RULES=/tmp/T10-broken.swift bash qa/T-10/run.sh   # 预期 C1 FAIL、退出码 1
