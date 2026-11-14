#!/bin/bash
# 一次发布做完四件事：构建三端 → 更新本机 App → 打 tag 发版 → 交付三个安装包。
#
#   ./scripts/release.sh 1.10.1          # 交互确认后推送发版
#   ./scripts/release.sh 1.10.1 --yes    # 不询问（用于无人值守）
#   ./scripts/release.sh --check         # 只检查前置条件，不做任何构建
#   ./scripts/release.sh 1.10.1 --no-push  # 构建 + 安装本机 + 打包，不提交不打 tag
#
# 失败时脚本会停在那一步并保留已完成的产物（dist/ 里的包不会丢）。
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"

VERSION=""
ASSUME_YES=0
NO_PUSH=0
CHECK_ONLY=0

for arg in "$@"; do
    case "$arg" in
        --yes) ASSUME_YES=1 ;;
        --no-push) NO_PUSH=1 ;;
        --check) CHECK_ONLY=1 ;;
        -*) echo "未知参数: $arg" >&2; exit 2 ;;
        *) VERSION="$arg" ;;
    esac
done

say() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
die() { printf '\n\033[31m错误: %s\033[0m\n' "$*" >&2; exit 1; }
ok()  { printf '  ✓ %s\n' "$*"; }

CURRENT_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' scripts/Info.plist)"

# ---------------------------------------------------------------- 前置检查
check_environment() {
    say "检查前置条件"

    [[ -d .git ]] || die "不在仓库根目录"
    ok "git 仓库"

    command -v xcodebuild >/dev/null || die "找不到 xcodebuild（需要 Xcode 26+）"
    # 先整段捕获再解析：管道接 head 会触发 SIGPIPE，配合 pipefail 会让脚本以 141 退出。
    local xcode_info
    xcode_info="$(xcodebuild -version 2>/dev/null)"
    XCODE_VER="$(printf '%s\n' "${xcode_info}" | awk '/^Xcode/{print $2}')"
    XCODE_MAJOR="${XCODE_VER%%.*}"
    [[ "${XCODE_MAJOR:-0}" -ge 26 ]] || die "Xcode 是 ${XCODE_VER}，桌面端用了 Liquid Glass，必须 26+"
    ok "Xcode ${XCODE_VER}"

    command -v xcodegen >/dev/null || die "找不到 xcodegen（brew install xcodegen）"
    ok "xcodegen"

    command -v gh >/dev/null || die "找不到 gh（GitHub CLI）"
    gh auth status >/dev/null 2>&1 || die "gh 未登录"
    ok "gh 已登录"

    local java_home="${JAVA_HOME:-/opt/homebrew/opt/openjdk@17}"
    [[ -x "${java_home}/bin/java" ]] || die "找不到 JDK 17（设置 JAVA_HOME 或 brew install openjdk@17）"
    ok "JDK 17（${java_home}）"

    local sdk="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
    [[ -d "${sdk}/platforms" ]] || die "找不到 Android SDK（设置 ANDROID_HOME）"
    ok "Android SDK（${sdk}）"

    [[ -f Android/keystore.properties ]] || \
        echo "  ! 没有 Android/keystore.properties，APK 会用 debug key 签名（升级会冲突）"
    [[ -f Android/keystore.properties ]] && ok "Android 签名密钥"

    if [[ -n "$(git status --porcelain)" ]]; then
        echo "  ! 工作区有未提交改动，会一起进入 release 提交："
        git status --short | awk 'NR<=10' 
    else
        ok "工作区干净"
    fi
}

# ---------------------------------------------------------------- 版本号
bump_version() {
    [[ "${VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "版本号要写成 1.10.1 这种形式"
    [[ "${VERSION}" != "${CURRENT_VERSION}" ]] || die "版本号还是 ${CURRENT_VERSION}，没变"
    git rev-parse -q --verify "refs/tags/v${VERSION}" >/dev/null && die "tag v${VERSION} 已存在"

    local build
    build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' scripts/Info.plist)"
    /usr/libexec/PlistBuddy \
        -c "Set :CFBundleShortVersionString ${VERSION}" \
        -c "Set :CFBundleVersion $((build + 1))" scripts/Info.plist
    ok "${CURRENT_VERSION} → ${VERSION}（build $((build + 1))）"
}

# ---------------------------------------------------------------- macOS
build_macos() {
    say "构建 macOS App + CLI"
    local scratch="${LEAPIN_SCRATCH:-/tmp/leapin-release-build}"

    # SwiftPM 在仓库 .build 里偶尔会卡死；独立 scratch 目录稳定得多。
    swift build -c release --product LeapinApp --scratch-path "${scratch}" --disable-sandbox
    swift build -c release --product leapin   --scratch-path "${scratch}" --disable-sandbox

    local bin="${scratch}/release"
    local app="dist/Leapin.app"
    rm -rf "${app}"
    mkdir -p "${app}/Contents/MacOS" "${app}/Contents/Resources"
    cp "${bin}/LeapinApp" "${app}/Contents/MacOS/LeapinApp"
    cp "${bin}/leapin"    "${app}/Contents/MacOS/leapin"
    cp scripts/Info.plist "${app}/Contents/Info.plist"
    [[ -f Assets/AppIcon.icns ]] && cp Assets/AppIcon.icns "${app}/Contents/Resources/AppIcon.icns"
    for bundle in "${bin}"/*.bundle; do
        [[ -e "${bundle}" ]] && cp -R "${bundle}" "${app}/Contents/Resources/"
    done
    codesign --force --deep --sign - "${app}" >/dev/null 2>&1
    ok "dist/Leapin.app（$(defaults read "${ROOT}/${app}/Contents/Info.plist" CFBundleShortVersionString)）"
}

# ---------------------------------------------------------------- 本机安装
install_local() {
    say "更新本机 App"
    osascript -e 'quit app "Leapin"' 2>/dev/null || true
    sleep 1
    rm -rf /Applications/Leapin.app
    ditto dist/Leapin.app /Applications/Leapin.app

    local installed
    installed="$(defaults read /Applications/Leapin.app/Contents/Info.plist CFBundleShortVersionString)"
    [[ "${installed}" == "${VERSION}" ]] || die "安装后版本是 ${installed}，不是 ${VERSION}"
    codesign -v /Applications/Leapin.app || die "本机 App 签名校验失败"
    open /Applications/Leapin.app
    ok "/Applications/Leapin.app 已是 ${installed}，已启动"
}

# ---------------------------------------------------------------- 移动端
build_mobile() {
    say "构建 iOS IPA"
    bash ./Mobile/build-ios.sh
    ok "iOS 完成"

    say "构建 Android APK"
    bash ./scripts/build-apk.sh
    ok "Android 完成"
}

# ---------------------------------------------------------------- 打包
package_artifacts() {
    say "打包与校验和"
    ditto -c -k --sequesterRsrc --keepParent dist/Leapin.app "dist/Leapin-${VERSION}-macOS.zip"
    tar -czf "dist/leapin-${VERSION}-macOS-cli.tar.gz" -C dist/Leapin.app/Contents/MacOS leapin
    (cd dist && shasum -a 256 ./*.zip ./*.tar.gz ./*.ipa ./*.apk > SHA256SUMS.txt)
    ok "dist/Leapin-${VERSION}-macOS.zip"
    ok "dist/leapin-${VERSION}-macOS-cli.tar.gz"
    ok "$(ls dist/*.ipa dist/*.apk | tr '\n' ' ')"
}

# ---------------------------------------------------------------- 发版
publish() {
    say "打 tag 并发版"
    git add -A
    if ! git diff --cached --quiet; then
        git commit -q -m "release: ${VERSION}"
        ok "已提交 release: ${VERSION}"
    else
        ok "没有需要提交的改动"
    fi
    git push origin HEAD
    git tag -a "v${VERSION}" -m "Leapin ${VERSION}"
    git push origin "v${VERSION}"
    ok "tag v${VERSION} 已推送"

    say "等待 CI 构建（约 8-12 分钟）"
    sleep 5
    local run_id
    run_id="$(gh run list --workflow=release.yml --limit 1 --json databaseId --jq '.[0].databaseId')"
    echo "  run: ${run_id}"
    gh run watch "${run_id}" --interval 20 --exit-status || die "CI 失败，看 https://github.com/$(gh repo view --json nameWithOwner --jq .nameWithOwner)/actions/runs/${run_id}"

    say "核对 Release 资产"
    gh release view "v${VERSION}" --json assets --jq '.assets[].name' | sed 's/^/  /'
}

# ---------------------------------------------------------------- 交付
handover() {
    say "给用户的三个安装包"
    if [[ "$NO_PUSH" == "1" || "$CHECK_ONLY" == "1" ]]; then
        echo "  （未发版，以下为本地产物）"
    fi
    echo "  macOS   : ${ROOT}/dist/Leapin-${VERSION}-macOS.zip"
    echo "  iOS     : $(ls "${ROOT}"/dist/*.ipa | tail -1)"
    echo "  Android : $(ls "${ROOT}"/dist/*.apk | tail -1)"
    cat <<'TXT'

  安装方式：
    macOS  —— 解压后把 Leapin.app 拖进「应用程序」；首次打开被拦截时右键 → 打开
    iOS    —— AltStore / Sideloadly，用你自己的 Apple ID 签名后安装
    Android—— 允许「安装未知来源应用」后直接安装（可直接覆盖升级）
TXT
}

# ---------------------------------------------------------------- main
check_environment

if [[ "$CHECK_ONLY" == "1" ]]; then
    say "前置条件全部通过（未做任何构建）"
    echo "  当前版本: ${CURRENT_VERSION}"
    exit 0
fi

[[ -n "${VERSION}" ]] || die "用法: ./scripts/release.sh <版本> [--yes] [--no-push]"

bump_version
build_macos
install_local
build_mobile
package_artifacts

if [[ "$NO_PUSH" == "1" ]]; then
    handover
    say "已完成构建、本机更新与打包；按 --no-push 未提交、未发版"
    exit 0
fi

if [[ "$ASSUME_YES" != "1" ]]; then
    printf '\n将提交并推送 v%s 并发版，继续? [y/N] ' "${VERSION}"
    read -r reply
    [[ "${reply}" =~ ^[Yy]$ ]] || {
        handover
        say "未推送。本地已构建并安装，提交前不会有任何远端改动"
        exit 1
    }
fi

publish
handover
say "发布完成"
