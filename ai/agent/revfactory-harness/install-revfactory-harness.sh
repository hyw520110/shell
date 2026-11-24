#!/bin/bash
# RevFactory Harness 安装脚本
# 项目: https://github.com/revfactory/harness
# 描述: Claude Code 的 Team-Architecture Factory

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO] $*${NC}"; }
log_warn() { echo -e "${YELLOW}[WARN] $*${NC}"; }
log_error() { echo -e "${RED}[ERROR] $*${NC}"; }
log_step() { echo -e "${BLUE}[STEP] $*${NC}"; }

HARNESS_REPO="https://github.com/revfactory/harness.git"
HARNESS_SKILL_DIR="${HOME}/.claude/skills/harness"
HARNESS_TMP_DIR=$(mktemp -d)

cleanup() {
    if [ -d "${HARNESS_TMP_DIR}" ]; then
        rm -rf "${HARNESS_TMP_DIR}"
    fi
}
trap cleanup EXIT

check_git() {
    if ! command -v git &>/dev/null; then
        log_error "Git 未安装，请先安装 Git"
        return 1
    fi
    log_info "Git 已就绪"
}

check_claude() {
    if [ ! -d "${HOME}/.claude" ]; then
        log_warn "~/.claude 目录不存在，这可能意味着您还没有使用过 Claude Code"
        read -r -p "继续安装? [y/N]: " confirm
        if [[ ! "${confirm:-N}" =~ ^[Yy]$ ]]; then
            log_info "取消安装"
            exit 0
        fi
    fi
}

install_harness() {
    log_step "安装 RevFactory Harness"

    log_info "克隆仓库..."
    git clone --depth 1 "${HARNESS_REPO}" "${HARNESS_TMP_DIR}"

    log_info "复制 Skills..."
    mkdir -p "${HARNESS_SKILL_DIR}"
    cp -r "${HARNESS_TMP_DIR}/skills/harness/"* "${HARNESS_SKILL_DIR}/"

    log_info "安装完成"
}

show_info() {
    echo ""
    log_info "========================================"
    log_info "RevFactory Harness 安装完成！"
    log_info "========================================"
    echo ""
    log_info "安装位置:"
    log_info "  Skills:     ${HARNESS_SKILL_DIR}"
    echo ""
    log_info "使用方式（在 Claude Code 中）:"
    log_info "  'Build a harness for this project'"
    log_info "  'Design an agent team for this domain'"
    log_info "  'Set up a harness'"
    echo ""
    log_info "架构模式:"
    log_info "  1. Pipeline - 顺序任务"
    log_info "  2. Fan-out/Fan-in - 并行任务"
    log_info "  3. Expert Pool - 专家池"
    log_info "  4. Producer-Reviewer - 生成-评审"
    log_info "  5. Supervisor - 监督者"
    log_info "  6. Hierarchical Delegation - 分层委派"
    echo ""
    log_info "生成的文件:"
    log_info "  .claude/agents/    - Agent 定义"
    log_info "  .claude/skills/    - Skills"
    echo ""
    log_info "文档:       https://github.com/revfactory/harness"
    log_info "========================================"
    echo ""
}

show_help() {
    cat << EOF
RevFactory Harness 安装脚本

用法: $0 [命令]

命令:
    install     安装 Harness (默认)
    update      更新 Harness
    uninstall   卸载 Harness
    status      查看安装状态
    help        显示此帮助信息

示例:
    $0 install      # 安装
    $0 update       # 更新
    $0 status       # 查看状态
EOF
}

cmd_status() {
    if [ -d "${HARNESS_SKILL_DIR}" ]; then
        log_info "Harness 已安装"
        echo ""
        log_info "安装位置: ${HARNESS_SKILL_DIR}"
        echo ""
        log_info "Skill 文件:"
        ls -la "${HARNESS_SKILL_DIR}/"
    else
        log_warn "Harness 未安装"
    fi
}

cmd_update() {
    log_info "更新 Harness..."

    if [ ! -d "${HARNESS_SKILL_DIR}" ]; then
        log_warn "Harness 未安装，进行安装..."
        install_harness
        show_info
        return 0
    fi

    log_info "备份现有版本..."
    local backup_dir="${HARNESS_SKILL_DIR}.backup.$(date +%Y%m%d_%H%M%S)"
    mv "${HARNESS_SKILL_DIR}" "${backup_dir}"

    install_harness
    show_info
}

cmd_uninstall() {
    log_warn "即将卸载 Harness..."
    read -r -p "确认删除 Harness Skills? [y/N]: " confirm
    if [[ "${confirm:-N}" =~ ^[Yy]$ ]]; then
        if rm -rf "${HARNESS_SKILL_DIR}"; then
            log_info "Harness 已卸载"
        else
            log_error "卸载失败"
            return 1
        fi
    else
        log_info "取消卸载"
    fi
}

main() {
    local cmd="${1:-install}"

    case "$cmd" in
        install)
            check_git || exit 1
            check_claude
            install_harness
            show_info
            ;;
        update)
            check_git || exit 1
            cmd_update
            ;;
        uninstall)
            cmd_uninstall
            ;;
        status)
            cmd_status
            ;;
        help|--help|-h)
            show_help
            ;;
        *)
            log_error "未知命令: $cmd"
            show_help
            exit 1
            ;;
    esac
}

main "$@"
