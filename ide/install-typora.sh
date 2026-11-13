#!/bin/bash
# Typora 安装脚本（macOS）
# 官方最新版：https://downloads.typora.io/mac/Typora.dmg（通用链接，自动最新）
# 用法：./install-typora.sh [--status|--uninstall|--crack]
# 说明：Typora 付费（15天试用）。--crack 执行破解（修改 app.asar license 校验），需先安装。

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/install-app-common.sh"

APP_NAME="Typora"
APP_GLOB="Typora.app"
TARGET="/Applications/Typora.app"

# 官方最新版通用链接（downloads.typora.io 复数，非 download 单数）
URL="https://downloads.typora.io/mac/Typora.dmg"

# === 破解 Typora（RSA 公钥替换 + 自签 Token）===
# 原理：Typora 1.x 原生版（非 Electron）用 RSA 公钥验证 Activation Token。
# 替换二进制中的公钥为自己的密钥对，再用私钥生成合法 Token。
# 破解脚本：tools/typora-crack-mac.js（Mr-xn gist，已改非交互版）
# 用法：--crack <机器码> <邮箱>（机器码从 Typora "帮助→我的许可证" 复制）
crack_typora() {
    local machine_code="${1:-}"
    local email="${2:-}"
    local crack_js="$SCRIPT_DIR/tools/typora-crack-mac.js"

    [[ -d "$TARGET" ]] || { log_error "Typora 未安装，请先安装再破解"; return 1; }
    [[ -f "$crack_js" ]] || { log_error "未找到破解脚本: $crack_js"; return 1; }
    command -v node >/dev/null 2>&1 || { log_error "需要 node 来破解"; return 1; }

    if [[ -z "$machine_code" ]]; then
        log_error "缺少机器码。请在 Typora 中打开 帮助→我的许可证，复制机器码后运行:"
        log_error "  $0 --crack <机器码> <邮箱>"
        return 1
    fi
    [[ -z "$email" ]] && email="cracked@local.local"

    log_info "关闭 Typora..."
    pkill -x Typora 2>/dev/null

    log_info "执行破解（替换公钥 + 生成 Token）..."
    TYPORA_MACHINE_CODE="$machine_code" TYPORA_EMAIL="$email" node "$crack_js" 2>&1
    local rc=$?
    if [[ $rc -ne 0 ]]; then
        log_error "破解失败（exit=$rc）"
        return 1
    fi
    log_ok "破解完成。请打开 Typora → 帮助→我的许可证 → 获取 Activation Token → 粘贴生成的 Token"
    log_info "Token 已复制到剪贴板（直接 Cmd+V 粘贴到 Typora 即可）"
    return 0
}

case "${1:-}" in
    --status)
        if [[ -d "$TARGET" ]]; then
            echo "安装状态: 已安装"
            defaults read "$TARGET/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null | sed 's/^/  版本: /'
        else
            echo "安装状态: 未安装"
        fi
        exit 0
        ;;
    --uninstall)
        if [[ -d "$TARGET" ]]; then
            rm -rf "$TARGET" && echo "已卸载 $APP_NAME"
        else
            echo "未安装 $APP_NAME"
        fi
        exit 0
        ;;
    --crack)
        crack_typora "${2:-}" "${3:-}"
        exit $?
        ;;
    --print-url)
        echo "$URL"
        exit 0
        ;;
esac

if [[ -d "$TARGET" ]]; then
    echo "$APP_NAME 已安装，跳过（如需破解运行 --crack）"
    exit 0
fi

install_app "$APP_NAME" "$URL" "dmg" "$APP_GLOB"
