#!/usr/bin/env bash
# Trae 产品 / 地区选择入口，兼容 Bash 3.2。
set -euo pipefail
TRAE_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

trae_select_versions() {
    INSTALL_VERSIONS=()
    local raw="${1:-}" option seen=" "
    if [[ -z "$raw" ]]; then
        printf '%s\n' '请选择要安装/更新的 Trae 版本（可多选，用空格或逗号分隔）：' \
            '  1. TraeWork 国内版（工作助手）' \
            '  2. TraeCode 国内版（代码 IDE）' \
            '  3. TraeWork 国际版（工作助手）' \
            '  4. TraeCode 国际版（代码 IDE）' \
            '  a. 全选' '  0. 返回'
        read -r -p '选项：' raw || return 2
    fi
    raw="${raw//,/ }"
    [[ "$raw" == 0 || "$raw" == q ]] && return 2
    [[ "$raw" == a || "$raw" == all ]] && raw='1 2 3 4'
    # 先验证整个选择，再执行任何安装；重复编号只安装一次。
    local choices=()
    read -r -a choices <<< "$raw"
    [[ ${#choices[@]} -gt 0 ]] || { echo '未选择版本' >&2; return 1; }
    for option in "${choices[@]}"; do
        case "$option" in
            1|2|3|4) ;;
            *) echo "无效选项：$option" >&2; return 1 ;;
        esac
        if [[ "$seen" != *" $option "* ]]; then
            INSTALL_VERSIONS+=("$option")
            seen+="$option "
        fi
    done
}

trae_variant_info() {
    local option="$1"
    TRAE_REGION=cn
    TRAE_PAGE='https://www.trae.cn/ide/download'
    TRAE_PRODUCT=TraeWork
    case "$option" in
        2|4) TRAE_PRODUCT=TraeCode ;;
    esac
    case "$option" in
        3|4) TRAE_REGION=sg; TRAE_PAGE='https://www.trae.ai/download' ;;
    esac
    TRAE_LABEL="$TRAE_PRODUCT 国内版"
    [[ "$TRAE_REGION" == cn ]] || TRAE_LABEL="$TRAE_PRODUCT 国际版"
    return 0
}

trae_install_variant() {
    local option="$1"
    trae_variant_info "$option"
    printf '\n安装/更新 %s\n' "$TRAE_LABEL"

    if [[ "$(uname -s)" != Darwin ]]; then
        # 官网未确认的 Linux/Windows 接口不猜测；明确返回待手动安装，避免 Hub 误报成功。
        printf '请在官方下载中心选择 %s 和对应平台安装包：\n%s\n' "$TRAE_LABEL" "$TRAE_PAGE"
        if [[ "$TRAE_PRODUCT" == TraeWork ]]; then
            echo 'TraeWork 官网未提供 Linux 桌面包，可使用官网网页版。'
        fi
        echo '此项需要手动下载安装；完成后回到 AI Hub 刷新状态。'
        return 3
    fi

    # 复用已验证的官方 manifest / DMG 安装流程，不再重复询问是否重装。
    TRAE_PRODUCT="$TRAE_PRODUCT" \
    TRAE_DOWNLOAD_REGION="$TRAE_REGION" \
        bash "$TRAE_SCRIPT_DIR/../../../ide/install-trae.sh" --yes
}

trae_main() {
    local selection="" dry_run=false
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --versions) [[ $# -ge 2 ]] || return 2; selection="$2"; shift ;;
            --dry-run) dry_run=true ;;
            --help|-h)
                echo '用法：install-trae.sh [--versions "1 2 3 4"] [--dry-run]'
                echo '1=Work 国内版，2=Code 国内版，3=Work 国际版，4=Code 国际版'
                return 0 ;;
            *) echo "未知参数：$1" >&2; return 2 ;;
        esac
        shift
    done
    if [[ -z "$selection" && "${AI_HUB_NON_INTERACTIVE:-0}" == 1 ]]; then
        echo 'Trae 需要选择版本，请使用 install-trae.sh --versions "2 4"。' >&2
        return 2
    fi
    local rc=0 option result=0 manual=0
    trae_select_versions "$selection" || rc=$?
    [[ "$rc" == 2 ]] && { echo '已返回，未执行安装'; return 2; }
    [[ "$rc" == 0 ]] || return "$rc"
    for option in "${INSTALL_VERSIONS[@]}"; do
        if [[ "$dry_run" == true ]]; then
            trae_variant_info "$option"
            printf '%s | %s\n' "$TRAE_LABEL" "$TRAE_PAGE"
        else
            # 用独立的严格模式子进程执行，保留下载 / 挂载失败的退出状态。
            rc=0
            bash "$TRAE_SCRIPT_DIR/install-trae.sh" --run-variant "$option" || rc=$?
            case "$rc" in
                0) ;;
                3) manual=1 ;;
                *) result=1 ;;
            esac
        fi
    done
    [[ "$manual" == 1 ]] && return 3
    return "$result"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    if [[ "${1:-}" == --run-variant ]]; then
        case "${2:-}" in 1|2|3|4) trae_install_variant "$2" ;; *) exit 2 ;; esac
    else
        trae_main "$@"
    fi
fi
