#!/usr/bin/env bash
# T-09 验收：「改成什么」四 tab + 四类共用 applyRewrite
# 用法：bash qa/T-09/run.sh
# 默认复用 scratch（${T09_SCRATCH:-/tmp/t09-scratch}），不删目录（共用机器上构建）。
# 只读仓库，不改 Sources/ Tests/ docs/。任何一条 FAIL → 退出码 1。
#
# 口径写死在这里，评审时可以逐条对照：
#   - applyRewrite( 在 RewriteView.swift 与 RewriteDeck.swift 合计 4 次
#     = Deck 里的定义 1 次 + 重写 / Mock / 脚本三个 tab 的调用 3 次。
#     去广告 tab 的那次调用在 AdBlockView.swift（第 4 个 tab 走同一个入口），
#     所以单独断言它存在，但不让它把合计推成 5。
#   - 第二个保存 / 应用入口：三个文件里禁止出现 func save( / func apply( /
#     func applyAllowList( / func saveAllowList(；两个视图禁止直写引擎
#     （engine.replaceRewrites / engine.replaceScripts），写引擎的只有 Deck。
#   - 过滤引擎不动：AdBlockView 仍然只调用 engine.adblockVerdict，不自己判域名。
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT" || { echo "FAIL C0  无法进入仓库"; exit 1; }

SCRATCH="${T09_SCRATCH:-/tmp/t09-scratch}"
LOGDIR="${T09_LOGDIR:-/tmp/t09-qa-logs}"
mkdir -p "$LOGDIR"

DECK="Sources/LeapinApp/Views/RewriteDeck.swift"
VIEW="Sources/LeapinApp/Views/RewriteView.swift"
ADBLOCK="Sources/LeapinApp/Views/AdBlockView.swift"

PASSED=0
FAILED=0
pass() { printf 'PASS %-3s %s\n' "$1" "$2"; PASSED=$((PASSED + 1)); }
fail() { printf 'FAIL %-3s %s\n' "$1" "$2"; FAILED=$((FAILED + 1)); }

for f in "$DECK" "$VIEW" "$ADBLOCK"; do
    [ -f "$f" ] || { echo "FAIL C0  缺少文件 $f"; exit 1; }
done

echo "T-09 验收 · 仓库 $ROOT"
echo "scratch=${SCRATCH}（复用，不清理）· 日志=${LOGDIR}"
echo "----------------------------------------------------------------"

# ---------------------------------------------------------------- C1 构建
build_log="$LOGDIR/c1-build.log"
swift build --scratch-path "$SCRATCH" --disable-sandbox >"$build_log" 2>&1
rc=$?
errs=$(grep -c 'error:' "$build_log" || true)
warns=$(grep -c 'warning:' "$build_log" || true)
task_warns=$(grep -E 'warning:' "$build_log" | grep -cE 'RewriteDeck\.swift|RewriteView\.swift|AdBlockView\.swift' || true)
if [ "$rc" -eq 0 ] && [ "$errs" -eq 0 ] && [ "$task_warns" -eq 0 ]; then
    pass C1 "swift build --scratch-path ${SCRATCH} --disable-sandbox → exit 0；日志 error: ${errs} 个、warning: ${warns} 个，其中落在本任务三个源文件上的 ${task_warns} 个（要求 0）；日志 ${build_log}"
else
    fail C1 "swift build 退出码 ${rc}；error: ${errs} 个（要求 0）、本任务文件 warning ${task_warns} 个（要求 0）；首个错误：$(grep -m1 'error:' "$build_log" || echo '（无 error: 行）')"
fi

# ---------------------------------------------------------------- C2 applyRewrite 合计 4
view_calls=$(grep -cF 'applyRewrite(' "$VIEW" || true)
deck_calls=$(grep -cF 'applyRewrite(' "$DECK" || true)
adblock_calls=$(grep -cF 'applyRewrite(' "$ADBLOCK" || true)
total=$((view_calls + deck_calls))
deck_defs=$(grep -cF 'func applyRewrite(' "$DECK" || true)
view_defs=$(grep -cF 'func applyRewrite(' "$VIEW" || true)
if [ "$total" -eq 4 ] && [ "$view_calls" -eq 3 ] && [ "$deck_calls" -eq 1 ] \
   && [ "$deck_defs" -eq 1 ] && [ "$view_defs" -eq 0 ] && [ "$adblock_calls" -ge 1 ]; then
    pass C2 "applyRewrite( 合计 ${total} 次（RewriteView ${view_calls} + RewriteDeck ${deck_calls}）：Deck 定义 ${deck_defs} 次 + 重写 / Mock / 脚本三个 tab 各调用一次；去广告 tab 的那次在 AdBlockView（${adblock_calls} 处，不计入 4，且走同一个入口）"
else
    fail C2 "applyRewrite( 合计 ${total}（要求 4）= RewriteView ${view_calls}（3）+ RewriteDeck ${deck_calls}（1）；Deck 定义 ${deck_defs}（1）、View 定义 ${view_defs}（0）、AdBlockView ${adblock_calls}（≥1）"
fi

# ---------------------------------------------------------------- C3 没有第二个保存 / 应用入口
# 名字类的第二入口：三个文件里都不许出现（模式写死）
patterns=(
    'func save('
    'func apply('
    'func applyAllowList('
    'func saveAllowList('
)
second_entry=0
detail=""
for p in "${patterns[@]}"; do
    for f in "$DECK" "$VIEW" "$ADBLOCK"; do
        n=$(grep -cF "$p" "$f" || true)
        if [ "$n" -ne 0 ]; then
            second_entry=$((second_entry + n))
            detail="$detail ${f##*/}:${p}x${n}"
        fi
    done
done
# 直写引擎的入口只允许在 Deck 里；两个视图一处都不许有
view_writes=0
for p in 'engine.replaceRewrites(' 'engine.replaceScripts('; do
    for f in "$VIEW" "$ADBLOCK"; do
        n=$(grep -cF "$p" "$f" || true)
        view_writes=$((view_writes + n))
        [ "$n" -eq 0 ] || detail="$detail ${f##*/}:${p}x${n}"
    done
done
deck_replace=$(grep -cF 'engine.replaceRewrites(' "$DECK" || true)
deck_scripts=$(grep -cF 'engine.replaceScripts(' "$DECK" || true)
deck_apply=$(grep -cF 'apply' "$DECK" || true)
change_cases=$(grep -cE '^        case (rewrite|mock|script|addBlockList|removeBlockList|allowList)\(' "$DECK" || true)
if [ "$second_entry" -eq 0 ] && [ "$view_writes" -eq 0 ] && [ "$deck_replace" -eq 1 ] \
   && [ "$deck_scripts" -eq 1 ] && [ "$deck_apply" -eq 1 ] && [ "$change_cases" -eq 6 ]; then
    pass C3 "没有第二个保存 / 应用入口：三个文件里 ${patterns[*]} 全 0，两个视图直写引擎 ${view_writes} 处（0）；Deck 里 apply 只出现 ${deck_apply} 次（唯一入口 applyRewrite），写规则与写脚本各一次（replaceRewrites ${deck_replace}、replaceScripts ${deck_scripts}）；Change 覆盖四类共 ${change_cases} 个 case"
else
    fail C3 "第二入口残留 ${second_entry} 处（${detail:- 无}）；视图直写引擎 ${view_writes}（0）；Deck apply ${deck_apply}（1）、replaceRewrites ${deck_replace}（1）、replaceScripts ${deck_scripts}（1）、Change case ${change_cases}（6）"
fi

# ---------------------------------------------------------------- C4 四 tab
kind_cases=$(grep -cF 'case rewrite, mock, script, adblock' "$DECK" || true)
kind_titles=$(grep -cE 'return "(重写|Mock|脚本|去广告)"' "$DECK" || true)
# 2026-11-24 口径改（CRD 002 第 2 条，用户选 A）：不再锁控件形态，只判「四个入口
# 存在、可切换、有选中态」。T-18 把 segmented 换成左对齐 chips 后，这条要跟着走行为。
picker=$(grep -cF 'ForEach(RewriteDeck.Kind.allCases)' "$VIEW" || true)
segmented=$(grep -cF '.pickerStyle(.segmented)' "$VIEW" || true)
chips=$(grep -cF 'LPChip(title: kind.title, selected: tab == kind)' "$VIEW" || true)
tab_rewrite=$(grep -cF 'case .rewrite: listTab(for: .rewrite)' "$VIEW" || true)
tab_mock=$(grep -cF 'case .mock: listTab(for: .mock)' "$VIEW" || true)
tab_script=$(grep -cF 'case .script: scriptTab' "$VIEW" || true)
tab_adblock=$(grep -cF 'case .adblock:' "$VIEW" || true)
embed=$(grep -cF 'AdBlockView(embedded: true' "$VIEW" || true)
if [ "$kind_cases" -eq 1 ] && [ "$kind_titles" -eq 4 ] && [ "$picker" -eq 1 ] && [ "$segmented" -eq 0 ] && [ "$chips" -eq 1 ] \
   && [ "$tab_rewrite" -eq 1 ] && [ "$tab_mock" -eq 1 ] && [ "$tab_script" -eq 1 ] \
   && [ "$tab_adblock" -eq 1 ] && [ "$embed" -eq 1 ]; then
    pass C4 "Deck 定义四类（${kind_cases} 组 case，${kind_titles} 个标题）；四个入口读 Kind.allCases（picker ${picker}），选中态用的是左对齐 chip（chips ${chips}），不再有 segmented（${segmented}）；四个分支齐全（重写 ${tab_rewrite} / Mock ${tab_mock} / 脚本 ${tab_script} / 去广告 ${tab_adblock}），去广告分支复用 AdBlockView(embedded: true)（${embed}）"
else
    fail C4 "四 tab 不全：Kind case ${kind_cases}（1）、标题 ${kind_titles}（4）、picker ${picker}（1）、chips ${chips}（1）、segmented ${segmented}（0）、重写 ${tab_rewrite}、Mock ${tab_mock}、脚本 ${tab_script}、去广告 ${tab_adblock}（各 1）、embedded ${embed}（1）"
fi

# ---------------------------------------------------------------- C5 脚本 tab 只读 + 启停
script_rows=$(grep -cF 'engine.profile.scripts.enumerated()' "$DECK" || true)
# 2026-11-23 更正：Change.script 的键从 name 改成 index（T-14 评审 B1：Row.id 是位置，
# 名字键会把开关接到第一条同名脚本上，且 id 与名字不一致时整体失效）。判据意图不变：
# 脚本 tab 的改动只有「切换启用状态」这一种。
script_change=$(grep -cF 'case let .script(index: index, enabled: enabled)' "$DECK" || true)
script_apply=$(grep -cF 'engine.replaceScripts(next)' "$DECK" || true)
script_toggle=$(grep -cF '.script(index: index, enabled: enabled)' "$VIEW" || true)
script_switch=$(grep -cF 'LPSwitch(isOn: Binding(' "$VIEW" || true)
readonly_note=$(grep -cF '只读 · 只能启停' "$VIEW" || true)
editors=$(grep -cF 'TextEditor(text: $text)' "$VIEW" || true)
script_editor=$(grep -cE 'ScriptEditor|脚本编辑器' "$VIEW" || true)
if [ "$script_rows" -eq 1 ] && [ "$script_change" -eq 1 ] && [ "$script_apply" -eq 1 ] \
   && [ "$script_toggle" -eq 1 ] && [ "$script_switch" -eq 1 ] && [ "$readonly_note" -eq 1 ] \
   && [ "$editors" -eq 1 ] && [ "$script_editor" -eq 0 ]; then
    pass C5 "脚本 tab 从 profile.scripts 派生（${script_rows}）、只切启用状态（Change ${script_change}、replaceScripts ${script_apply}）；页面上是 LPSwitch 启停（${script_switch} 个开关、接线 ${script_toggle}），写着只读只能启停（${readonly_note}）；全文只有规则编辑器那一个 TextEditor（${editors}），没有脚本编辑器（${script_editor}）"
else
    fail C5 "脚本 tab 不符：profile.scripts ${script_rows}（1）、Change ${script_change}（1）、replaceScripts ${script_apply}（1）、启停接线 ${script_toggle}（1）、LPSwitch ${script_switch}（1）、只读标注 ${readonly_note}（1）、TextEditor ${editors}（1）、脚本编辑器 ${script_editor}（0）"
fi

# ---------------------------------------------------------------- C6 去广告 tab 复用 AdBlockView
deck_rows=$(grep -cF 'deck.rows(for: .adblock)' "$ADBLOCK" || true)
deck_allow=$(grep -cF 'deck.allowList' "$ADBLOCK" || true)
deck_rules=$(grep -cF 'deck.adblockRuleCount' "$ADBLOCK" || true)
deck_commit=$(grep -cF 'deck.applyRewrite(change)' "$ADBLOCK" || true)
embedded_param=$(grep -cF 'let embedded: Bool' "$ADBLOCK" || true)
embedded_title=$(grep -cF 'page.navigationTitle("去广告")' "$ADBLOCK" || true)
engine_verdict=$(grep -cF 'engine.adblockVerdict(domain: domain)' "$ADBLOCK" || true)
direct_lists=$(grep -cF 'engine.profile.adblock.blockLists' "$ADBLOCK" || true)
allow_field=$(grep -cE 'func (applyAllowList|saveAllowList)\(' "$ADBLOCK" || true)
if [ "$deck_rows" -eq 1 ] && [ "$deck_allow" -ge 2 ] && [ "$deck_rules" -eq 1 ] && [ "$deck_commit" -eq 1 ] \
   && [ "$embedded_param" -eq 1 ] && [ "$embedded_title" -eq 1 ] && [ "$engine_verdict" -eq 1 ] \
   && [ "$direct_lists" -eq 0 ] && [ "$allow_field" -eq 0 ]; then
    pass C6 "AdBlockView 的列表改从 Deck 取（rows ${deck_rows}、allowList ${deck_allow} 处、adblockRuleCount ${deck_rules}），落地只有 deck.applyRewrite(change) 一处（${deck_commit}）；embedded 参数与内嵌时不再写标题（${embedded_param}/${embedded_title}）；过滤引擎未重写（仍调 engine.adblockVerdict ${engine_verdict}，直接读写 blockLists ${direct_lists} 处，旧的白名单保存函数 ${allow_field} 个）"
else
    fail C6 "去广告复用不符：deck.rows ${deck_rows}（1）、deck.allowList ${deck_allow}（≥2）、adblockRuleCount ${deck_rules}（1）、deck.applyRewrite ${deck_commit}（1）、embedded ${embedded_param}（1）、内嵌标题 ${embedded_title}（1）、adblockVerdict ${engine_verdict}（1）、直连 blockLists ${direct_lists}（0）、旧保存函数 ${allow_field}（0）"
fi

# ---------------------------------------------------------------- C7 全量 swift test
test_log="$LOGDIR/c7-test.log"
swift test --scratch-path "$SCRATCH" --disable-sandbox >"$test_log" 2>&1
rc=$?
failed_cases=$(grep -cE "Test Case .* failed \(" "$test_log" || true)
summary=$(grep -E 'Executed [0-9]+ tests?, with [0-9]+ failures?' "$test_log" | tail -1)
if [ "$rc" -eq 0 ] && [ "$failed_cases" -eq 0 ] && [ -n "$summary" ]; then
    pass C7 "swift test --scratch-path ${SCRATCH} --disable-sandbox → exit 0；失败用例 ${failed_cases} 个；最后一行：${summary}；日志 ${test_log}"
else
    fail C7 "swift test 未全绿：退出码 ${rc}、失败用例 ${failed_cases}、汇总行「${summary:-无}」；首个失败：$(grep -m1 'failed (' "$test_log" || echo '（无 failed 行）')"
fi

# ---------------------------------------------------------------- 汇总
echo "----------------------------------------------------------------"
echo "T-09 结果：${PASSED} PASS / ${FAILED} FAIL（C1 构建 · C2 applyRewrite 合计 4 · C3 无第二入口 · C4 四 tab · C5 脚本只读 · C6 去广告复用 · C7 全量 test）"
echo "人工项（脚本判不了，留给走查）：四类各建一条，确认提示条与失败原因一致（DoD 3）。"
if [ "$FAILED" -gt 0 ]; then
    exit 1
fi
exit 0
