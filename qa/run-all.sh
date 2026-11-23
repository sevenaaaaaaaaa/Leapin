#!/usr/bin/env bash
# 运行 qa/ 下每个任务的验收脚本并汇总。任何一项失败 → 退出码 1。
# 用法：bash qa/run-all.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1

found=0
failed=0
failed_tasks=""

# T-14 是本轮的总账：父脚本把每个子任务的结果写进这份 TSV，T-14 只核对、不重跑，
# 否则一次 run-all 会把九个子任务各跑两遍（每个都要重建 + 全量测试）。
RESULTS="${QA_RUN_ALL_RESULTS:-${TMPDIR:-/tmp}/qa-run-all-results.tsv}"
: > "$RESULTS"
export QA_RUN_ALL=1
export QA_RUN_ALL_RESULTS="$RESULTS"

for dir in qa/T-*/; do
    [ -d "$dir" ] || continue
    script="${dir}run.sh"
    task="$(basename "$dir")"
    if [ ! -f "$script" ]; then
        echo "MISS ${task} 缺少 ${script}"
        failed=$((failed + 1))
        failed_tasks="${failed_tasks} ${task}(missing)"
        continue
    fi
    found=$((found + 1))
    echo "=================================================================="
    echo "== ${task}"
    echo "=================================================================="
    if bash "$script"; then
        printf '%s\tPASS\n' "$task" >> "$RESULTS"
    else
        failed=$((failed + 1))
        failed_tasks="${failed_tasks} ${task}"
        printf '%s\tFAIL\n' "$task" >> "$RESULTS"
    fi
done

echo "=================================================================="
if [ "$found" -eq 0 ]; then
    echo "qa/run-all: 没有任何任务验收脚本"
    exit 1
fi
if [ "$failed" -ne 0 ]; then
    echo "qa/run-all: ${found} 个任务，${failed} 个失败：${failed_tasks# }"
    exit 1
fi
echo "qa/run-all: ${found} 个任务全部通过"
exit 0
