#!/bin/bash
# Promptfoo - LLM eval / redteam / code scan helper
# Docs: https://www.promptfoo.dev/docs/installation/

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

INSTALL_METHOD="${PROMPTFOO_INSTALL_METHOD:-npm}"

log_info() { echo -e "${GREEN}[INFO] $*${NC}"; }
log_warn() { echo -e "${YELLOW}[WARN] $*${NC}"; }
log_error() { echo -e "${RED}[ERROR] $*${NC}"; }

show_help() {
    cat <<EOF
Promptfoo 管理脚本

用法:
  $0 <命令> [选项]

命令:
  install              安装 promptfoo
  update               更新 promptfoo
  uninstall            卸载 promptfoo
  status               查看安装状态
  init [DIR]           初始化 promptfooconfig.yaml
  init-example [DIR]   初始化官方 getting-started 示例
  eval [ARGS...]       执行 promptfoo eval
  view [ARGS...]       启动/打开 promptfoo view
  redteam [ARGS...]    执行 promptfoo redteam
  code-scan [DIR]      执行 promptfoo code-scans run

选项:
  --method npm|brew    安装方式，默认 npm
  -h, --help           显示帮助

示例:
  $0 install
  $0 install --method brew
  $0 init .
  $0 eval
  $0 view
  $0 code-scan .

说明:
  Promptfoo 属于 CI/CD 中的 LLM 评测、红队和代码扫描工具，因此脚本放在 cicd/promptfoo。
  官方 npm/npx 安装要求 Node.js ^20.20.0 或 >=22.22.0。
EOF
}

parse_common_options() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --method)
                INSTALL_METHOD="${2:-}"
                shift 2
                ;;
            --method=*)
                INSTALL_METHOD="${1#*=}"
                shift
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            *)
                REMAINING_ARGS+=("$1")
                shift
                ;;
        esac
    done
}

version_ge() {
    local current="$1"
    local required="$2"
    local IFS=.
    local c=($current) r=($required)
    local i

    for ((i=0; i<3; i++)); do
        c[$i]="${c[$i]:-0}"
        r[$i]="${r[$i]:-0}"
        if ((10#${c[$i]} > 10#${r[$i]})); then
            return 0
        elif ((10#${c[$i]} < 10#${r[$i]})); then
            return 1
        fi
    done
    return 0
}

check_node_for_npm() {
    if ! command -v node >/dev/null 2>&1; then
        log_error "未找到 node。请先安装 Node.js。"
        return 1
    fi

    local node_version
    node_version="$(node --version | sed 's/^v//')"
    if version_ge "$node_version" "22.22.0"; then
        return 0
    fi
    if [[ "$node_version" == 20.* ]] && version_ge "$node_version" "20.20.0"; then
        return 0
    fi

    log_warn "当前 Node.js 版本为 $node_version，官方文档要求 ^20.20.0 或 >=22.22.0。"
}

require_promptfoo() {
    if ! command -v promptfoo >/dev/null 2>&1; then
        log_error "未找到 promptfoo，请先执行: $0 install"
        return 1
    fi
}

cmd_install() {
    case "$INSTALL_METHOD" in
        npm)
            check_node_for_npm
            command -v npm >/dev/null 2>&1 || { log_error "未找到 npm"; return 1; }
            log_info "使用 npm 安装 promptfoo..."
            npm install -g promptfoo
            ;;
        brew)
            command -v brew >/dev/null 2>&1 || { log_error "未找到 brew"; return 1; }
            log_info "使用 Homebrew 安装 promptfoo..."
            brew install promptfoo
            ;;
        *)
            log_error "不支持的安装方式: $INSTALL_METHOD"
            return 1
            ;;
    esac
    cmd_status
}

cmd_update() {
    case "$INSTALL_METHOD" in
        npm)
            check_node_for_npm
            npm update -g promptfoo
            ;;
        brew)
            brew upgrade promptfoo || brew install promptfoo
            ;;
        *)
            log_error "不支持的安装方式: $INSTALL_METHOD"
            return 1
            ;;
    esac
    cmd_status
}

cmd_uninstall() {
    case "$INSTALL_METHOD" in
        npm)
            command -v npm >/dev/null 2>&1 && npm uninstall -g promptfoo || true
            ;;
        brew)
            command -v brew >/dev/null 2>&1 && brew uninstall promptfoo || true
            ;;
        *)
            log_error "不支持的卸载方式: $INSTALL_METHOD"
            return 1
            ;;
    esac
    log_warn "如需删除 eval 历史和缓存，可手动删除 ~/.promptfoo。"
}

cmd_status() {
    if command -v promptfoo >/dev/null 2>&1; then
        log_info "promptfoo: $(command -v promptfoo)"
        promptfoo --version || true
    else
        log_warn "promptfoo 未安装"
        return 1
    fi
}

cmd_init() {
    require_promptfoo
    local target_dir="${1:-.}"
    mkdir -p "$target_dir"
    (cd "$target_dir" && promptfoo init)
}

cmd_init_example() {
    require_promptfoo
    local target_dir="${1:-.}"
    mkdir -p "$target_dir"
    (cd "$target_dir" && promptfoo init --example getting-started)
}

cmd_eval() {
    require_promptfoo
    promptfoo eval "$@"
}

cmd_view() {
    require_promptfoo
    promptfoo view "$@"
}

cmd_redteam() {
    require_promptfoo
    promptfoo redteam "$@"
}

cmd_code_scan() {
    require_promptfoo
    local repo_path="${1:-.}"
    promptfoo code-scans run "$repo_path"
}

main() {
    local command="${1:-help}"
    shift || true

    REMAINING_ARGS=()
    parse_common_options "$@"
    set -- "${REMAINING_ARGS[@]+"${REMAINING_ARGS[@]}"}"

    case "$command" in
        install) cmd_install "$@" ;;
        update) cmd_update "$@" ;;
        uninstall) cmd_uninstall "$@" ;;
        status) cmd_status "$@" ;;
        init) cmd_init "$@" ;;
        init-example) cmd_init_example "$@" ;;
        eval) cmd_eval "$@" ;;
        view) cmd_view "$@" ;;
        redteam) cmd_redteam "$@" ;;
        code-scan) cmd_code_scan "$@" ;;
        -h|--help|help) show_help ;;
        *)
            log_error "未知命令: $command"
            show_help
            return 1
            ;;
    esac
}

main "$@"
