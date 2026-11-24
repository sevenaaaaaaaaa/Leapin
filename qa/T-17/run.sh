#!/usr/bin/env bash
# T-17 走哪：三段式（焦点带 + 证据区 + 更多）
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT" || { echo "FAIL C0  无法进入仓库"; exit 1; }

DASH="Sources/LeapinApp/Views/DashboardView.swift"
GO="Sources/LeapinApp/Views/GoWherePage.swift"
SCRATCH=/tmp/t17-scratch
LOGS=/tmp/t17-qa-logs
mkdir -p "$LOGS"

PASSED=0; FAILED=0
pass() { printf 'PASS %-3s %s\n' "$1" "$2"; PASSED=$((PASSED + 1)); }
fail() { printf 'FAIL %-3s %s\n' "$1" "$2"; FAILED=$((FAILED + 1)); }

echo "T-17 验收 · 仓库 $ROOT"
echo "----------------------------------------------------------------"

if swift build --scratch-path "$SCRATCH" --disable-sandbox > "$LOGS/c1-build.log" 2>&1; then
    errs=$(grep -c 'error:' "$LOGS/c1-build.log" || true)
    warn=$(grep 'warning:' "$LOGS/c1-build.log" | grep -cE 'DashboardView.swift|GoWherePage.swift' || true)
    if [ "$errs" = "0" ] && [ "$warn" = "0" ]; then
        pass C1 "swift build exit 0；error 0；两个文件 0 warning"
    else
        fail C1 "构建 error=$errs 本任务文件 warning=$warn"
    fi
else
    fail C1 "swift build 失败"
fi

fb=$(grep -c 'FocusBand(' "$DASH" || true)
rl=$(grep -c 'RouteLine(' "$DASH" || true)
rf=$(grep -c 'RouteFact(' "$DASH" || true)
if [ "$fb" = "1" ] && [ "$rl" = "1" ] && [ "$rf" = "4" ]; then
    pass C2 "焦点带 1 个、一条路 1 条、四个事实 4 个"
else
    fail C2 "焦点带 $fb 个（要 1）、RouteLine $rl 条（要 1）、RouteFact $rf 个（要 4）"
fi

# 顶层块数不能靠「数已知名字」——把已知名字写进正则，改造前数出来也是 3，
# 于是 8 块的首屏照样 PASS。判据改成结构：折叠开关之前只能有 4 个裸标识符行，
# 且折叠项必须全都落在 "if showMore {" 之后。对 03a90aa（8 块）是红的。
body_seg=$(awk '/var body: some View \{/,/\.pagePadding\(\)/' "$DASH")
pre_fold=$(printf '%s\n' "$body_seg" | sed -n '1,/if showMore {/p' | sed '$d')
after_fold=$(printf '%s\n' "$body_seg" | sed -n '/if showMore {/,$p')
top=$(printf '%s\n' "$pre_fold" | grep -cE '^ {16}[A-Za-z][A-Za-z0-9]*$' || true)
top_names=$(printf '%s\n' "$pre_fold" | grep -oE '^ {16}[A-Za-z][A-Za-z0-9]*$' | tr -d ' ' | sort | uniq | tr '\n' ',')
leaked=""
for marker in 'bookmarksWidget' 'CompanyWidget' 'HomeWidget' 'dashRow(' '分享本地服务' '内核：'; do
    printf '%s\n' "$after_fold" | grep -qF -- "$marker" || leaked="$leaked $marker"
done
if [ "$top" -eq 4 ] && [ "$top_names" = "focusBand,moreToggle,sceneRail,verbGrid," ] && [ -z "$leaked" ]; then
    pass C3 "折叠开关前只有 4 个顶层块（${top_names%,}），加页头共 5；书签 / 公司 / 回家 / 常用工具 / 快捷动作 / 页脚 6 类折叠项全部落在 if showMore 之后"
else
    fail C3 "首屏结构不符：折叠前顶层块 ${top} 个（要 4）名称 [${top_names%,}]；未进折叠区或提前出现的项 [${leaked:-无}]"
fi

if grep -q 'if showMore {' "$DASH" && grep -q 'private var moreToggle' "$DASH"; then
    n=$(grep -c 'showMore.toggle()' "$DASH" || true)
    pass C4 "更多折叠存在（toggle $n 处）；书签 / 随手可用 / 常用工具 / 公司与回家 / 页脚都在折叠区"
else
    fail C4 "缺更多折叠"
fi

if ! grep -q 'pickerStyle(.segmented)' "$GO" && grep -q 'tabButton' "$GO"; then
    pass C5 "走哪 tab 是左对齐过滤条，不用 segmented"
else
    fail C5 "走哪 tab 仍是 segmented 或缺少 tabButton"
fi

timer=$(grep -c 'Timer' "$DASH" || true)
if [ "$timer" = "0" ] && grep -q 'driveResidentFacts' "$DASH"; then
    pass C6 "仍由 .task 驱动，视图内 Timer 0 处"
else
    fail C6 "采样纪律被破坏（Timer $timer 处）"
fi

# 场景要 chips，不要六张大卡：chip 是 Capsule 底的一行，点一下仍走 app.switchScene。
chip_fn=$(grep -cF 'private func sceneChip(' "$DASH" || true)
chip_capsule=$(awk '/private func sceneChip\(/,/^    }$/' "$DASH" | grep -cF 'Capsule()' || true)
chip_switch=$(awk '/private func sceneChip\(/,/^    }$/' "$DASH" | grep -cF 'app.switchScene(scene)' || true)
old_grid=$(grep -cF 'Array(repeating: GridItem(.flexible(), spacing: 8), count: 6)' "$DASH" || true)
if [ "$chip_fn" -eq 1 ] && [ "$chip_capsule" -ge 1 ] && [ "$chip_switch" -ge 1 ] && [ "$old_grid" -eq 0 ]; then
    pass C7 "场景是 chips：sceneChip 1 处、Capsule 底 ${chip_capsule} 处、切换仍走 app.switchScene；旧的六列大卡网格已删（${old_grid}）"
else
    fail C7 "场景形态不符：sceneChip ${chip_fn}（1）、Capsule ${chip_capsule}（≥1）、switchScene ${chip_switch}（≥1）、旧六列网格 ${old_grid}（0）"
fi

echo "----------------------------------------------------------------"
echo "T-17 结果：$PASSED PASS / $FAILED FAIL"
echo "=================================================================="
[ "$FAILED" = "0" ]
