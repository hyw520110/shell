#!/bin/bash
# Taste Skill 安装脚本
# 项目: https://github.com/Leonxlnx/taste-skill
# 描述: AI Agent 反粗糙前端框架，提升 AI 生成界面质量

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

TASTE_REPO="https://github.com/Leonxlnx/taste-skill.git"
TASTE_SKILL_DIR="${HOME}/.claude/skills/taste-skill"
TASTE_TMP_DIR=$(mktemp -d)

cleanup() {
    if [ -d "${TASTE_TMP_DIR}" ]; then
        rm -rf "${TASTE_TMP_DIR}"
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

install_taste() {
    log_step "安装 Taste Skill"

    log_info "克隆仓库..."
    git clone --depth 1 "${TASTE_REPO}" "${TASTE_TMP_DIR}"

    log_info "复制 Skills..."
    mkdir -p "${TASTE_SKILL_DIR}"
    cp -r "${TASTE_TMP_DIR}/skills/"* "${TASTE_SKILL_DIR}/"

    log_info "安装完成"
}

show_info() {
    echo ""
    log_info "========================================"
    log_info "Taste Skill 安装完成！"
    log_info "========================================"
    echo ""
    log_info "安装位置:"
    log_info "  Skills:     ${TASTE_SKILL_DIR}"
    echo ""
    log_info "安装方式 (Claude Code):"
    log_info "  npx skills add https://github.com/Leonxlnx/taste-skill"
    echo ""
    log_info "主要 Skills:"
    log_info "  1. taste-skill (v2) - 通用默认"
    log_info "  2. gpt-taste - GPT/Codex 专用"
    log_info "  3. image-to-code - 图片→代码工作流"
    log_info "  4. redesign-skill - 改进现有项目"
    log_info "  5. soft-skill - 高端精致 UI"
    log_info "  6. minimalist-skill - 极简风格"
    log_info "  7. brutalist-skill - 粗野主义"
    echo ""
    log_info "视觉风格:"
    log_info "  - Soft (高端精致)"
    log_info "  - Minimalist (极简编辑)"
    log_info "  - Brutalist (粗野主义)"
    echo ""
    log_info "可调参数:"
    log_info "  - DESIGN_VARIANCE - 布局实验度"
    log_info "  - MOTION_INTENSITY - 动画深度"
    log_info "  - VISUAL_DENSITY - 信息密度"
    echo ""
    log_info "文档:       https://tasteskill.dev"
    log_info "========================================"
    echo ""
}

show_help() {
    cat << EOF
Taste Skill 安装脚本

用法: $0 [命令]

命令:
    install     安装 Taste Skill (默认)
    update      更新 Taste Skill
    uninstall   卸载 Taste Skill
    status      查看安装状态
    help        显示此帮助信息

示例:
    $0 install      # 安装
    $0 update       # 更新
    $0 status       # 查看状态
EOF
}

cmd_status() {
    if [ -d "${TASTE_SKILL_DIR}" ]; then
        log_info "Taste Skill 已安装"
        echo ""
        log_info "安装位置: ${TASTE_SKILL_DIR}"
        echo ""
        log_info "Skills:"
        ls -la "${TASTE_SKILL_DIR}/"
    else
        log_warn "Taste Skill 未安装"
    fi
}

cmd_update() {
    log_info "更新 Taste Skill..."

    if [ ! -d "${TASTE_SKILL_DIR}" ]; then
        log_warn "Taste Skill 未安装，进行安装..."
        install_taste
        show_info
        return 0
    fi

    log_info "备份现有版本..."
    local backup_dir="${TASTE_SKILL_DIR}.backup.$(date +%Y%m%d_%H%M%S)"
    mv "${TASTE_SKILL_DIR}" "${backup_dir}"

    install_taste
    show_info
}

cmd_uninstall() {
    log_warn "即将卸载 Taste Skill..."
    read -r -p "确认删除 Taste Skills? [y/N]: " confirm
    if [[ "${confirm:-N}" =~ ^[Yy]$ ]]; then
        if rm -rf "${TASTE_SKILL_DIR}"; then
            log_info "Taste Skill 已卸载"
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
            install_taste
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
