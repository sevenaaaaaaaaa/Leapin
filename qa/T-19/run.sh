#!/usr/bin/env bash
# T-19 验收：「为什么」页 —— 查询条 + 垂直 trace + 单一动作的空态。
# 用法：bash qa/T-19/run.sh
# 只读仓库；任何一条 FAIL → 退出码 1。
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT" || { echo "FAIL C0  无法进入仓库"; exit 1; }

WHY="Sources/LeapinApp/Views/WhyPage.swift"
SCRATCH="${T19_SCRATCH:-/tmp/t19-scratch}"
LOGS="${T19_LOGDIR:-/tmp/t19-qa-logs}"
mkdir -p "$LOGS"

PASSED=0; FAILED=0
pass() { printf 'PASS %-3s %s\n' "$1" "$2"; PASSED=$((PASSED + 1)); }
fail() { printf 'FAIL %-3s %s\n' "$1" "$2"; FAILED=$((FAILED + 1)); }

[ -f "$WHY" ] || { echo "FAIL C0  缺少 $WHY"; exit 1; }

echo "T-19 验收 · 仓库 $ROOT"
echo "scratch=${SCRATCH} · 日志=${LOGS}"
echo "----------------------------------------------------------------"

# C1 构建
build_log="$LOGS/c1-build.log"
swift build --scratch-path "$SCRATCH" --disable-sandbox >"$build_log" 2>&1
rc=$?
errs=$(grep -c 'error:' "$build_log" || true)
warns=$(grep -E 'warning:' "$build_log" | grep -cF 'WhyPage.swift' || true)
if [ "$rc" -eq 0 ] && [ "$errs" -eq 0 ] && [ "$warns" -eq 0 ]; then
    pass C1 "swift build --scratch-path ${SCRATCH} → exit 0；error ${errs} 个；WhyPage 上 warning ${warns} 个（要求 0）"
else
    fail C1 "swift build 退出码 ${rc}；error ${errs}；WhyPage warning ${warns}；首个错误：$(grep -m1 'error:' "$build_log" || echo 无)"
fi

# C2 查询条 + 垂直 trace，且判定由输入派生（原地更新，不跳页）
search=$(grep -cF 'LPSearchField(text: $query' "$WHY" || true)
vertical=$(grep -cF 'RouteLine(nodes: traceNodes, axis: .vertical, onInk: false)' "$WHY" || true)
explain=$(grep -cF 'engine.explain(host: host)' "$WHY" || true)
derived=$(grep -cF 'SiteTarget(query)?.host' "$WHY" || true)
navigate=$(grep -cE 'app\.go\(to:|openTask\(' "$WHY" || true)
if [ "$search" -eq 1 ] && [ "$vertical" -eq 1 ] && [ "$explain" -eq 1 ] && [ "$derived" -eq 1 ] && [ "$navigate" -eq 0 ]; then
    pass C2 "查询条 ${search} 处；trace 是竖过来的 RouteLine（${vertical} 处）；判定取 engine.explain(host:)（${explain} 处）；host 由 query 派生（${derived} 处）——改输入即重画，页面内没有跳转（导航 ${navigate} 处，要求 0）"
else
    fail C2 "查询条/trace 不符：search ${search}（1）、vertical ${vertical}（1）、explain ${explain}（1）、派生 ${derived}（1）、导航 ${navigate}（0）"
fi

# C3 空态：一句事实 + 示例 chips，没有主按钮
# 只数页面本体：这个文件里还住着 RuleDraftEditor 的 sheet，它的保存按钮不在「空态」范围里。
page_body=$(awk '/^struct WhyPage: View \{/,/^struct RuleDraftSeed/' "$WHY")
why_primary=$(printf '%s\n' "$page_body" | grep -cF 'LPPrimaryButtonStyle()' || true)
examples=$(grep -cF 'static let examples' "$WHY" || true)
example_chips=$(grep -cF 'LPChip(title: example, selected: false)' "$WHY" || true)
fact_line=$(grep -cF '输入一个域名，看它落在哪条规则、走哪个出口。' "$WHY" || true)
if [ "$why_primary" -eq 0 ] && [ "$examples" -eq 1 ] && [ "$example_chips" -eq 1 ] && [ "$fact_line" -eq 1 ]; then
    pass C3 "空态是「一句事实 + 示例 chips」：事实句 ${fact_line} 处、示例表 ${examples} 处、chip ${example_chips} 处；整页主按钮 ${why_primary} 个（要求 0，空态不再有大号橙色按钮）"
else
    fail C3 "空态不符：主按钮 ${why_primary}（0）、示例表 ${examples}（1）、chip ${example_chips}（1）、事实句 ${fact_line}（1）"
fi

# C4 四个 tab 仍可达，且仍然是「挂载一次、opacity 显隐」
chips=$(grep -cF 'LPChip(title: item.title, selected: tab == item)' "$WHY" || true)
allcases=$(grep -cF 'ForEach(Tab.allCases)' "$WHY" || true)
mounted=$(grep -cF 'mounted.contains(item)' "$WHY" || true)
# 只看 tabContent 的分支：Tab 枚举的 title/icon 里也有同名 case，按全文件数会数成 12。
tab_fn=$(awk '/private func tabContent\(_ item: Tab\)/,/^    }$/' "$WHY")
branches=$(printf '%s\n' "$tab_fn" | grep -cE 'case \.(connections|metrics|probes|diagnostics):' || true)
if [ "$chips" -eq 1 ] && [ "$allcases" -ge 1 ] && [ "$mounted" -eq 1 ] && [ "$branches" -eq 4 ]; then
    pass C4 "四个 tab 走 chips（${chips} 处，读 Tab.allCases ${allcases} 处）；四个分支齐全（${branches}/4）；tab 仍按挂载表显隐（${mounted} 处），切 tab 不销毁已挂载页面"
else
    fail C4 "tab 不符：chips ${chips}（1）、allCases ${allcases}（≥1）、mounted ${mounted}（1）、分支 ${branches}（4）"
fi

# C5 居中悬浮 tab 彻底消失（§12.5 收尾）
segmented=$(grep -cF '.pickerStyle(.segmented)' "$WHY" || true)
picker=$(grep -cF 'Picker("视图"' "$WHY" || true)
centered=$(grep -cF 'frame(maxWidth: 420)' "$WHY" || true)
if [ "$segmented" -eq 0 ] && [ "$picker" -eq 0 ] && [ "$centered" -eq 0 ]; then
    pass C5 "WhyPage 里 segmented ${segmented} 处、Picker「视图」${picker} 处、固定 420 居中容器 ${centered} 处（都要求 0）"
else
    fail C5 "仍是居中 tab：segmented ${segmented}（0）、Picker ${picker}（0）、居中容器 ${centered}（0）"
fi

echo "----------------------------------------------------------------"
echo "T-19 结果：${PASSED} PASS / ${FAILED} FAIL（C1 构建 · C2 查询条 + 垂直 trace · C3 单一动作空态 · C4 四 tab 可达 · C5 无居中 tab）"
[ "$FAILED" -eq 0 ]
