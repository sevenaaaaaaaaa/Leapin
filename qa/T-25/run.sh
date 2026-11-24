#!/usr/bin/env bash
# T-25 验收：M3 汇总——复用三份子脚本 + 五屏截图 + 汇总断言。
# 用法：bash qa/T-25/run.sh
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT" || { echo "FAIL C0  无法进入仓库"; exit 1; }

LOGS="${T25_LOGDIR:-/tmp/t25-qa-logs}"
mkdir -p "$LOGS"
PASSED=0; FAILED=0
pass() { printf 'PASS %-3s %s\n' "$1" "$2"; PASSED=$((PASSED + 1)); }
fail() { printf 'FAIL %-3s %s\n' "$1" "$2"; FAILED=$((FAILED + 1)); }

echo "T-25 验收 · M3 汇总"
echo "----------------------------------------------------------------"

run_child() {
    local task=$1 script="qa/$1/run.sh"
    if [ ! -f "$script" ]; then fail "$2" "缺 $script"; return; fi
    if bash "$script" >"$LOGS/${task}.log" 2>&1; then
        pass "$2" "$task 全 PASS（见 $LOGS/${task}.log）"
    else
        local red
        red=$(grep -c '^FAIL' "$LOGS/${task}.log" || true)
        fail "$2" "$task 有 ${red} 条 FAIL（见 $LOGS/${task}.log）"
    fi
}

run_child T-22 C1
run_child T-23 C2
run_child T-24 C3

shots="m3-home m3-guide m3-connections m3-policies m3-diagnostics"
missing=""
for s in $shots; do
    [ -f "docs/shots/${s}.png" ] || missing="$missing $s"
done
if [ -z "$missing" ]; then
    pass C4 "五屏截图齐（home / guide / connections / policies / diagnostics）"
else
    fail C4 "缺截图：$missing"
fi

stale=""
for f in Mobile/LeapinMobile/Views/DashboardView.swift Mobile/LeapinMobile/Views/LocalProxyGuide.swift; do
    for s in m3-home m3-guide; do
        [ "docs/shots/${s}.png" -nt "$f" ] || stale="$stale $s"
    done
done
if [ -z "$stale" ]; then
    pass C5 "首页与引导截图晚于源码改动（不是旧图）"
else
    fail C5 "截图早于源码，需重拍：$stale"
fi

report="qa/T-25/report.md"
if [ -f "$report" ] && grep -qF '真机' "$report"; then
    pass C6 "report.md 含真机步骤"
else
    fail C6 "缺 report.md 或其中没有真机步骤"
fi

echo "----------------------------------------------------------------"
echo "T-25 结果：${PASSED} PASS / ${FAILED} FAIL（C1–C3 子脚本 · C4 截图 · C5 时序 · C6 真机步骤）"
[ "$FAILED" -eq 0 ] || exit 1
