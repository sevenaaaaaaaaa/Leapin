#!/usr/bin/env bash
# T-01 验收：常驻层 —— 一个状态源、三块面板
# 用法：bash qa/T-01/run.sh
# 只读仓库，不改 Sources/ Tests/ docs/；构建与测试产物落在 /tmp/t01-scratch，
# 日志落在 /tmp/t01-qa-logs。任何一条 FAIL → 退出码 1。
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT" || { echo "FAIL C0  无法进入仓库"; exit 1; }

SCRATCH="${T01_SCRATCH:-/tmp/t01-scratch}"
LOGDIR="${T01_LOGDIR:-/tmp/t01-qa-logs}"
CLEAN="${T01_CLEAN:-0}"
mkdir -p "$LOGDIR"

# 默认复用 scratch（T01_CLEAN=0），不删目录：/tmp/t01-scratch 同时被 eng-1 / eng-2
# 的构建使用，构建期间 rm -rf 会把别人正在编译的文件删掉。2026-11-23 21:03 已发生一次，
# 表现为对端 swift build 报 ProxyServer.swift 编译失败。
# 需要一次干净的全量构建（例如核对 warning 数）时，显式 T01_CLEAN=1 跑，
# 并且先确认此刻没有别的构建在用这个目录。
if [ "$CLEAN" = "1" ]; then
    case "$SCRATCH" in
        /tmp/*) rm -rf "$SCRATCH" ;;
        *) echo "拒绝删除非 /tmp 的 scratch：$SCRATCH"; exit 1 ;;
    esac
fi

PANEL="Sources/LeapinApp/Views/MenuBarPanel.swift"
FLOAT="Sources/LeapinApp/Views/FloatingStatusView.swift"
RESIDENT="Sources/LeapinRuntime/ResidentStatus.swift"
TESTS="Tests/LeapinRuntimeTests/ResidentStatusTests.swift"

PASSED=0
FAILED=0
pass() { printf 'PASS %-3s %s\n' "$1" "$2"; PASSED=$((PASSED + 1)); }
fail() { printf 'FAIL %-3s %s\n' "$1" "$2"; FAILED=$((FAILED + 1)); }

for f in "$PANEL" "$FLOAT" "$RESIDENT" "$TESTS"; do
    [ -f "$f" ] || { echo "FAIL C0  缺少文件 $f"; exit 1; }
done

echo "T-01 验收 · 仓库 $ROOT"
echo "scratch=${SCRATCH}（T01_CLEAN=${CLEAN}）· 日志=${LOGDIR}"
echo "----------------------------------------------------------------"

# ---------------------------------------------------------------- C1 构建
build_log="$LOGDIR/c1-build.log"
swift build --scratch-path "$SCRATCH" --disable-sandbox >"$build_log" 2>&1
rc=$?
errs=$(grep -c 'error:' "$build_log" || true)
warns=$(grep -c 'warning:' "$build_log" || true)
touched_warns=$(grep -E 'warning:' "$build_log" | grep -cE 'MenuBarPanel\.swift|FloatingStatusView\.swift|ResidentStatus\.swift' || true)
if [ "$rc" -eq 0 ]; then
    if [ "$CLEAN" = "1" ]; then build_mode="全量构建（T01_CLEAN=1）"; else build_mode="复用 scratch（T01_CLEAN=0：未重编的目标不产生 warning，本行 warning 计数只覆盖本轮实际编译的文件）"; fi
    pass C1 "swift build --scratch-path ${SCRATCH} --disable-sandbox → exit 0；${build_mode}；日志 ${errs} 个 error:、${warns} 个 warning:，其中落在本次改动三个文件上的 ${touched_warns} 个"
else
    fail C1 "swift build 退出码 ${rc}，见 ${build_log}；首个错误：$(grep -m1 'error:' "$build_log" || echo '（无 error: 行，可能失败在链接或打包阶段）')"
fi

# ---------------------------------------------------------------- C2 单测
test_log="$LOGDIR/c2-test.log"
swift test --scratch-path "$SCRATCH" --disable-sandbox --filter ResidentStatusTests >"$test_log" 2>&1
rc=$?
total_line=$(grep -E "Test Suite 'ResidentStatusTests' passed" -A2 "$test_log" | grep -m1 'Executed' | sed 's/^[[:space:]]*//')
cases=$(grep -cE "Test Case '-\[LeapinRuntimeTests\.ResidentStatusTests .*\]' passed" "$test_log" || true)
if [ "$rc" -eq 0 ] && grep -qF 'Executed 15 tests, with 0 failures' "$test_log"; then
    pass C2 "swift test --filter ResidentStatusTests → exit 0；汇总行「${total_line}」；逐条 passed 用例 ${cases} 个"
else
    fail C2 "swift test --filter ResidentStatusTests 退出码 ${rc}；汇总行「${total_line:-无}」；未匹配 'Executed 15 tests, with 0 failures'；失败用例：$(grep -m3 'failed (' "$test_log" || echo '无')"
fi

# ---------------------------------------------------------------- C3 速率差分唯一
diffs=$(grep -nE 'lastBytesIn|lastBytesOut|lastSample' "$PANEL" "$FLOAT" 2>/dev/null | wc -l | tr -d ' ')
meter=$(grep -c 'ResidentRateMeter' "$RESIDENT" || true)
if [ "$diffs" -eq 0 ] && [ "$meter" -ge 1 ]; then
    pass C3 "两个视图里 lastBytesIn|lastBytesOut|lastSample 命中 ${diffs} 次（要求 0），${RESIDENT} 里 ResidentRateMeter 出现 ${meter} 次"
else
    fail C3 "视图里仍有 ${diffs} 处自行差分状态（要求 0）：$(grep -nE 'lastBytesIn|lastBytesOut|lastSample' "$PANEL" "$FLOAT" 2>/dev/null | head -5 | tr '\n' ' ')；ResidentRateMeter 命中 ${meter} 次（要求 ≥1）"
fi

# ---------------------------------------------------------------- C4 三块 + footer
body=$(awk '/^    var body: some View \{/{flag=1} flag{print} flag && /^    \}$/{exit}' "$PANEL")
top=$(printf '%s\n' "$body" | grep -E '^            [^ ]' | sed -E 's/^ {12}//')
expected=$(printf '%s\n' 'nowCard' 'switchCard' 'if showsIssues { issueCard }' 'footer')
top_n=$(printf '%s\n' "$top" | grep -c '[^[:space:]]' || true)
cond=$(grep -cF 'if showsIssues' "$PANEL" || true)
width=$(grep -oE '\.frame\(width: [0-9]+\)' "$PANEL" | head -1 | grep -oE '[0-9]+')
# 2026-11-24：设计 §9 把常驻面板定成 280 宽，T-20 照做。旧断言钉死 276 —— 这是
# 又一处「把实现形态当判据」；改成钉设计值 280，别的宽度仍然红。
if [ "$top" = "$expected" ] && [ "$top_n" -eq 4 ] && [ "$cond" -ge 1 ] && [ "${width:-999}" -eq 280 ]; then
    pass C4 "body 顶层恰 ${top_n} 项且顺序为 $(printf '%s' "$top" | tr '\n' '|')；'if showsIssues' 命中 ${cond} 次（issueCard 条件渲染）；面板 .frame(width: ${width}) ≤ 280"
else
    fail C4 "body 顶层实得 ${top_n} 项：[$(printf '%s' "$top" | tr '\n' '|')]（期望 4 项 nowCard|switchCard|if showsIssues { issueCard }|footer）；'if showsIssues' 命中 ${cond} 次；宽度 ${width:-未找到}"
fi

# ---------------------------------------------------------------- C5 一步到达
c5_bad=""
c5_ev=""
check_anchor() {
    local label="$1" needle="$2"
    local n
    n=$(grep -cF "$needle" "$PANEL" || true)
    c5_ev="$c5_ev $label=$n"
    [ "$n" -ge 1 ] || c5_bad="$c5_bad $label"
}
check_anchor "node:menuBarSelect" 'menuBarSelect'
check_anchor "port:open(.settings)" 'open(.settings)'
check_anchor "port:mixedPort" 'mixedPort'
check_anchor "proxy:toggleSystemProxy" 'toggleSystemProxy'
check_anchor "nav:ForEach(4页)" 'ForEach([AppModel.Section.dashboard, .rules, .capture, .settings])'
if [ -z "$c5_bad" ]; then
    pass C5 "${PANEL} 同时含节点/端口/系统代理/导航四类入口，命中次数：${c5_ev}"
else
    fail C5 "缺入口：${c5_bad}（命中次数：${c5_ev}）"
fi

# ---------------------------------------------------------------- C6 覆盖声明
d_unknown=$(grep -cF '接管范围：系统代理 · 部分进程未覆盖' "$RESIDENT" || true)
d_counted=$(grep -cF '个进程未覆盖' "$RESIDENT" || true)
d_none=$(grep -cF '接管范围：系统代理 · 未检测到绕过进程' "$RESIDENT" || true)
t_uncovered=$(grep -cE 'func test[A-Za-z]*Uncovered' "$TESTS" || true)
t_decl=$(grep -cF '接管范围：系统代理 · ' "$TESTS" || true)
ui_decl=$(grep -cF 'status.coverage.declaration' "$PANEL" || true)
if [ "$d_none" -ge 1 ] && [ "$d_counted" -ge 1 ] && [ "$d_unknown" -ge 1 ] && [ "$t_uncovered" -ge 1 ] && [ "$t_decl" -ge 3 ] && [ "$ui_decl" -ge 1 ]; then
    pass C6 "declaration 三分支齐全：未检测到绕过进程=${d_none}、有 N 个进程未覆盖=${d_counted}、部分进程未覆盖=${d_unknown}；面板按 status.coverage.declaration 渲染 ${ui_decl} 处（§2.5 写进 App）；测试里 Uncovered 用例 ${t_uncovered} 个、systemProxy 三文案断言 ${t_decl} 处"
else
    fail C6 "declaration 分支缺失或未测：未检测到绕过进程=${d_none}、有N个=${d_counted}、部分=${d_unknown}；Uncovered 用例=${t_uncovered}、测试内 systemProxy 文案断言=${t_decl}（要求 ≥3）、面板渲染处=${ui_decl}（要求 ≥1）"
fi

# ---------------------------------------------------------------- C7 T-01 自己的边界
# 2026-11-23 第三次口径调整：累计里程碑里「整棵树只许有我一个任务的改动」必然反复误报
# （T-02 / T-03 / T-04 各自新增文件，M2 还会更多）。所以 C7 只判两件事：
#   1) T-01 的四个交付物存在且非空；
#   2) Platform.swift 里那行他人改动（host.appearance）还在、T-01 的符号没进去。
#
# 2026-11-23 第四次口径调整（PM 更正，见任务行 T-01 DoD 7 的追加）：M2·T-13 按任务书
# 拥有 Platform.swift 的 Debug 快照同步，该文件因此有了 +18/−10 的正常改动。原先
# 「+1 行 / 0 删除」的代理检查从此不可能通过。判据改为机制无关的两条：
#   · host.appearance = NSAppearance(named: .aqua) 在文件里恰好 1 处（那行仍在）；
#   · 文件里没有任何 T-01 的符号（ResidentStatus / ResidentIcon / MenuBarLabel）。
# 判的仍是「T-01 没有改这个文件的内容」，只是不再用「整文件 diff 行数」当替身。
c7_files="Sources/LeapinApp/Views/MenuBarPanel.swift
Sources/LeapinApp/Views/FloatingStatusView.swift
Sources/LeapinRuntime/ResidentStatus.swift
Tests/LeapinRuntimeTests/ResidentStatusTests.swift"
c7_missing=""
c7_detail=""
while IFS= read -r f; do
    [ -z "$f" ] && continue
    if [ -s "$f" ]; then
        c7_detail="${c7_detail} $(basename "$f")=$(grep -c '' "$f") 行"
    else
        c7_missing="${c7_missing} $f"
    fi
done <<< "$c7_files"

platform_host=$(grep -cF 'host.appearance = NSAppearance(named: .aqua)' Sources/LeapinApp/Platform.swift || true)
platform_t01=$(grep -cE 'ResidentStatus|ResidentIcon|MenuBarLabel' Sources/LeapinApp/Platform.swift || true)
if [ -z "$c7_missing" ] && [ "$platform_host" -eq 1 ] && [ "$platform_t01" -eq 0 ]; then
    pass C7 "T-01 交付物四个存在且非空：${c7_detail# }；Platform.swift 保留那行他人改动 host.appearance（${platform_host} 处，要求 1）、T-01 符号命中 ${platform_t01} 处（要求 0）；文件本身的 M2 快照同步属 T-13，不在本任务判"
else
    fail C7 "交付物缺失或为空=[${c7_missing:- 无}]；Platform.swift host.appearance ${platform_host}（要求 1）、T-01 符号 ${platform_t01}（要求 0）"
fi


# ---------------------------------------------------------------- 汇总
echo "----------------------------------------------------------------"
echo "T-01 结果：${PASSED} PASS / ${FAILED} FAIL（C1 构建 · C2 单测 · C3 速率唯一 · C4 三块+footer · C5 一步到达 · C6 覆盖声明 · C7 未改禁区）"
if [ "$FAILED" -gt 0 ]; then
    exit 1
fi
exit 0
