#!/usr/bin/env bash
# T-21 验收：onboarding 与图标里的「路」。
# 用法：bash qa/T-21/run.sh
# 只读仓库（图标检查在 /tmp 里解包，不改 Assets/）；任何一条 FAIL → 退出码 1。
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT" || { echo "FAIL C0  无法进入仓库"; exit 1; }

ONB="Sources/LeapinApp/Design/Onboarding.swift"
MAKER="scripts/make-icon.py"
ICNS="Assets/AppIcon.icns"
PNG="Assets/AppIcon.png"
SCRATCH="${T21_SCRATCH:-/tmp/t21-scratch}"
LOGS="${T21_LOGDIR:-/tmp/t21-qa-logs}"
mkdir -p "$LOGS"

PASSED=0; FAILED=0
pass() { printf 'PASS %-3s %s\n' "$1" "$2"; PASSED=$((PASSED + 1)); }
fail() { printf 'FAIL %-3s %s\n' "$1" "$2"; FAILED=$((FAILED + 1)); }

for f in "$ONB" "$MAKER" "$ICNS" "$PNG"; do
    [ -f "$f" ] || { echo "FAIL C0  缺少文件 $f"; exit 1; }
done

echo "T-21 验收 · 仓库 $ROOT"
echo "scratch=${SCRATCH} · 日志=${LOGS}"
echo "----------------------------------------------------------------"

# C1 构建
build_log="$LOGS/c1-build.log"
swift build --scratch-path "$SCRATCH" --disable-sandbox >"$build_log" 2>&1
rc=$?
errs=$(grep -c 'error:' "$build_log" || true)
warns=$(grep -E 'warning:' "$build_log" | grep -cF 'Onboarding.swift' || true)
if [ "$rc" -eq 0 ] && [ "$errs" -eq 0 ] && [ "$warns" -eq 0 ]; then
    pass C1 "swift build --scratch-path ${SCRATCH} → exit 0；error ${errs}；Onboarding 相关 warning ${warns}（要求 0）"
else
    fail C1 "swift build 退出码 ${rc}；error ${errs}；Onboarding warning ${warns}；首个错误：$(grep -m1 'error:' "$build_log" || echo 无)"
fi

# C2 onboarding 里那条路：三节点、解释性文案、不读实时状态
line=$(grep -cF 'RouteLine(nodes: [' "$ONB" || true)
n1=$(grep -cF '"你的请求"' "$ONB" || true)
n2=$(grep -cF '"命中规则"' "$ONB" || true)
n3=$(grep -cF '"出口"' "$ONB" || true)
live=$(grep -cE 'status\.|ResidentStatusStore' "$ONB" || true)
if [ "$line" -eq 1 ] && [ "$n1" -eq 1 ] && [ "$n2" -eq 1 ] && [ "$n3" -eq 1 ] && [ "$live" -eq 0 ]; then
    pass C2 "onboarding 有一条 RouteLine（${line} 处），三节点齐全（你的请求/命中规则/出口）；文件里不读 status / ResidentStatusStore（${live} 处，要求 0）——讲机制，不是实时值"
else
    fail C2 "onboarding 里的路不符：RouteLine ${line}（1）、节点 ${n1}/${n2}/${n3}（各 1）、实时取值 ${live}（0）"
fi

# C3 图标：icns 能解出完整尺寸集，png 是 1024
work=$(mktemp -d /tmp/t21-iconset.XXXXXX)
iconutil -c iconset "$ICNS" -o "$work/out.iconset" >/dev/null 2>&1
n_sizes=$(ls "$work/out.iconset" 2>/dev/null | grep -c 'png' || true)
png_w=$(sips -g pixelWidth "$PNG" 2>/dev/null | awk '/pixelWidth/{print $2}')
rm -rf "$work"
if [ "${n_sizes:-0}" -ge 10 ] && [ "${png_w:-0}" -eq 1024 ]; then
    pass C3 "AppIcon.icns 能解出 ${n_sizes} 张尺寸（要求 ≥10，16–1024 全套）；AppIcon.png 是 ${png_w}px 源图"
else
    fail C3 "图标不符：icns 尺寸 ${n_sizes:-0}（≥10）、png 宽 ${png_w:-缺失}（1024）"
fi

# C4 色值出处：生成脚本里写的是 Theme.swift 的同一组值
ink_hex=$(grep -cF '0x19191B' "$MAKER" || true)
accent_hex=$(grep -cF '0xC63A12' "$MAKER" || true)
theme_ink=$(grep -cF 'hex(0x19191B)' Sources/LeapinApp/Design/Theme.swift || true)
theme_accent=$(grep -cF 'hex(0xC63A12)' Sources/LeapinApp/Design/Theme.swift || true)
if [ "$ink_hex" -ge 1 ] && [ "$accent_hex" -ge 1 ] && [ "$theme_ink" -ge 1 ] && [ "$theme_accent" -ge 1 ]; then
    pass C4 "生成脚本引用的 ink 0x19191B、accent 0xC63A12 与 Theme.swift 一致（脚本 ${ink_hex}/${accent_hex}，Theme ${theme_ink}/${theme_accent}）"
else
    fail C4 "色值出处不符：脚本 ${ink_hex}/${accent_hex}（各 ≥1）、Theme ${theme_ink}/${theme_accent}（各 ≥1）"
fi

# C5 图标真的会被打进 App：打包脚本要拷贝 AppIcon.icns
packaged=$(cat scripts/release.sh scripts/build-app.sh 2>/dev/null | grep -cF 'AppIcon.icns' || true)
if [ "${packaged:-0}" -ge 1 ]; then
    pass C5 "打包链路会带上图标：release.sh / build-app.sh 里 AppIcon.icns 命中 ${packaged} 处"
else
    fail C5 "图标没被打包：release.sh / build-app.sh 里 AppIcon.icns 命中 ${packaged:-0}（要求 ≥1）"
fi

echo "----------------------------------------------------------------"
echo "T-21 结果：${PASSED} PASS / ${FAILED} FAIL（C1 构建 · C2 onboarding 的路 · C3 图标尺寸集 · C4 色值出处 · C5 打包链路）"
[ "$FAILED" -eq 0 ]
