#!/bin/bash

# Git配置清除和卸载脚本
# 用于清除Git全局配置、SSH配置、凭证缓存等

set -e

# === 颜色定义 ===
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly BOLD='\033[1m'
readonly NC='\033[0m'

# === 常量定义 ===
readonly BACKUP_DIR="$HOME/.git_uninstall_backups"
readonly CURRENT_DATE=$(date +%Y%m%d_%H%M%S)

# === 全局变量 ===
DRY_RUN=false
BACKUP_ENABLED=true
INTERACTIVE=true

# === 工具函数 ===
print_info() {
    echo -e "${BLUE}[INFO]${NC} $*"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $*"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $*"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $*" >&2
}

print_header() {
    echo -e "${CYAN}${BOLD}>>> $*${NC}"
}

# === 显示帮助信息 ===
show_usage() {
    cat << 'EOF'
Git配置清除和卸载脚本

用法: ./uninstall_git.sh [选项]

选项:
    -h, --help                  显示此帮助信息
    --dry-run                   试运行模式，显示将要执行的操作但不实际执行
    --no-backup                 不创建备份
    --no-interactive            非交互模式，自动确认所有操作

清除选项:
    --all                       清除所有Git配置（全局配置、SSH配置、凭证、密钥）
    --config                    仅清除Git全局配置
    --ssh                       仅清除SSH配置
    --credentials               仅清除Git凭证
    --ssh-keys                  仅删除Git相关的SSH密钥

示例:
    ./uninstall_git.sh                         # 交互式选择清除内容
    ./uninstall_git.sh --all                   # 清除所有配置
    ./uninstall_git.sh --config --ssh          # 清除Git和SSH配置
    ./uninstall_git.sh --dry-run --all         # 试运行模式
    ./uninstall_git.sh --no-backup --config    # 清除配置不备份

警告:
    此脚本会删除或修改Git相关配置文件，建议先使用 --dry-run 查看操作内容
    重要配置建议先备份（默认会自动备份）
EOF
}

# === 解析命令行参数 ===
parse_arguments() {
    local clear_all=false
    local clear_config=false
    local clear_ssh=false
    local clear_credentials=false
    local clear_ssh_keys=false

    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help)
                show_usage
                exit 0
                ;;
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            --no-backup)
                BACKUP_ENABLED=false
                shift
                ;;
            --no-interactive)
                INTERACTIVE=false
                shift
                ;;
            --all)
                clear_all=true
                shift
                ;;
            --config)
                clear_config=true
                shift
                ;;
            --ssh)
                clear_ssh=true
                shift
                ;;
            --credentials)
                clear_credentials=true
                shift
                ;;
            --ssh-keys)
                clear_ssh_keys=true
                shift
                ;;
            *)
                print_error "未知选项: $1"
                show_usage
                exit 1
                ;;
        esac
    done

    # 如果指定了--all，设置所有标志
    if [ "$clear_all" = true ]; then
        clear_config=true
        clear_ssh=true
        clear_credentials=true
        clear_ssh_keys=true
    fi

    # 如果没有指定任何清除选项，使用交互式菜单
    if [ "$clear_config" = false ] && [ "$clear_ssh" = false ] && [ "$clear_credentials" = false ] && [ "$clear_ssh_keys" = false ]; then
        interactive_menu
    else
        execute_cleanup "$clear_config" "$clear_ssh" "$clear_credentials" "$clear_ssh_keys"
    fi
}

# === 交互式菜单 ===
interactive_menu() {
    print_header "Git配置清除和卸载"

    echo "请选择要清除的内容："
    echo "  1) Git全局配置"
    echo "  2) SSH配置"
    echo "  3) Git凭证"
    echo "  4) SSH密钥"
    echo "  5) 全部清除"
    echo "  6) 查看当前配置"
    echo "  0) 退出"
    echo ""
    read -p "请输入选项 [0-6]: " choice

    case "$choice" in
        1)
            execute_cleanup true false false false
            ;;
        2)
            execute_cleanup false true false false
            ;;
        3)
            execute_cleanup false false true false
            ;;
        4)
            execute_cleanup false false false true
            ;;
        5)
            execute_cleanup true true true true
            ;;
        6)
            show_current_config
            interactive_menu
            ;;
        0)
            print_info "退出脚本"
            exit 0
            ;;
        *)
            print_error "无效的选项"
            interactive_menu
            ;;
    esac
}

# === 显示当前配置 ===
show_current_config() {
    print_header "当前Git配置"

    echo ""
    echo "=== Git全局配置 ==="
    if [ -f "$HOME/.gitconfig" ]; then
        echo "配置文件: $HOME/.gitconfig"
        echo "配置内容:"
        cat "$HOME/.gitconfig"
    else
        echo "未找到Git全局配置文件"
    fi

    echo ""
    echo "=== Git用户信息 ==="
    echo "用户名: $(git config --global user.name 2>/dev/null || echo '未设置')"
    echo "邮箱: $(git config --global user.email 2>/dev/null || echo '未设置')"

    echo ""
    echo "=== SSH配置 ==="
    if [ -f "$HOME/.ssh/config" ]; then
        echo "配置文件: $HOME/.ssh/config"
        echo "Git相关配置:"
        grep -A 3 "Host.*\(github\|gitee\|gitlab\)" "$HOME/.ssh/config" 2>/dev/null || echo "未找到Git相关的SSH配置"
    else
        echo "未找到SSH配置文件"
    fi

    echo ""
    echo "=== SSH密钥 ==="
    if [ -d "$HOME/.ssh" ]; then
        echo "SSH目录: $HOME/.ssh"
        echo "SSH密钥文件:"
        find "$HOME/.ssh" -name "id_*" -type f 2>/dev/null | while read -r key_file; do
            echo "  $key_file"
        done
    else
        echo "未找到SSH目录"
    fi

    echo ""
    echo "=== Git凭证 ==="
    echo "凭证存储方式: $(git config --global credential.helper 2>/dev/null || echo '未设置')"
    if [[ "$(uname)" == "Darwin" ]]; then
        if command -v security &> /dev/null; then
            echo "macOS钥匙串中的Git凭证:"
            security find-internet-password -s github.com 2>/dev/null && echo "  GitHub凭证存在" || echo "  未找到GitHub凭证"
            security find-internet-password -s gitee.com 2>/dev/null && echo "  Gitee凭证存在" || echo "  未找到Gitee凭证"
        fi
    fi

    echo ""
    echo "=== Git代理配置 ==="
    local http_proxy=$(git config --global http.proxy 2>/dev/null)
    local https_proxy=$(git config --global https.proxy 2>/dev/null)
    echo "HTTP代理: ${http_proxy:-未设置}"
    echo "HTTPS代理: ${https_proxy:-未设置}"

    echo ""
    read -p "按Enter键继续..."
}

# === 创建备份 ===
create_backup() {
    if [ "$BACKUP_ENABLED" = false ]; then
        return 0
    fi

    local backup_file="$1"
    local backup_type="$2"

    if [ ! -f "$backup_file" ]; then
        return 0
    fi

    mkdir -p "$BACKUP_DIR"
    local backup_path="$BACKUP_DIR/${backup_type}_backup_${CURRENT_DATE}"

    cp "$backup_file" "$backup_path"
    print_success "已备份 $backup_type 到 $backup_path"
}

# === 执行清除操作 ===
execute_cleanup() {
    local clear_config=$1
    local clear_ssh=$2
    local clear_credentials=$3
    local clear_ssh_keys=$4

    print_header "开始清除Git配置"

    if [ "$DRY_RUN" = true ]; then
        print_warning "试运行模式：以下操作不会实际执行"
    fi

    if [ "$clear_config" = true ]; then
        clear_git_config
    fi

    if [ "$clear_ssh" = true ]; then
        clear_ssh_config
    fi

    if [ "$clear_credentials" = true ]; then
        clear_git_credentials
    fi

    if [ "$clear_ssh_keys" = true ]; then
        clear_ssh_keys_files
    fi

    print_header "清除完成"
    print_success "Git配置清除操作已完成"
    
    if [ "$BACKUP_ENABLED" = true ]; then
        print_info "备份文件位置: $BACKUP_DIR"
        print_info "如需恢复配置，请手动从备份目录复制文件"
    fi
}

# === 清除Git全局配置 ===
clear_git_config() {
    print_header "清除Git全局配置"

    local git_config="$HOME/.gitconfig"

    if [ ! -f "$git_config" ]; then
        print_info "未找到Git全局配置文件"
        return 0
    fi

    print_info "当前Git配置:"
    cat "$git_config"

    if [ "$INTERACTIVE" = true ] && [ "$DRY_RUN" = false ]; then
        echo ""
        read -p "确认删除Git全局配置? (y/N): " confirm
        if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
            print_info "跳过Git配置清除"
            return 0
        fi
    fi

    if [ "$DRY_RUN" = true ]; then
        print_info "[试运行] 将删除: $git_config"
        return 0
    fi

    create_backup "$git_config" "gitconfig"
    rm "$git_config"
    print_success "Git全局配置已清除"
}

# === 清除SSH配置 ===
clear_ssh_config() {
    print_header "清除SSH配置"

    local ssh_config="$HOME/.ssh/config"

    if [ ! -f "$ssh_config" ]; then
        print_info "未找到SSH配置文件"
        return 0
    fi

    print_info "当前SSH配置中的Git相关配置:"
    grep -A 3 "Host.*\(github\|gitee\|gitlab\)" "$ssh_config" 2>/dev/null || echo "未找到Git相关的SSH配置"

    if [ "$INTERACTIVE" = true ] && [ "$DRY_RUN" = false ]; then
        echo ""
        read -p "确认删除SSH中的Git相关配置? (y/N): " confirm
        if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
            print_info "跳过SSH配置清除"
            return 0
        fi
    fi

    if [ "$DRY_RUN" = true ]; then
        print_info "[试运行] 将从 $ssh_config 中删除Git相关配置"
        return 0
    fi

    create_backup "$ssh_config" "sshconfig"

    # 删除GitHub、Gitee、GitLab相关的Host配置
    if [[ "$(uname)" == "Darwin" ]]; then
        sed -i '' '/^Host.*\(github\|gitee\|gitlab\)/,/^$/d' "$ssh_config"
    else
        sed -i '/^Host.*\(github\|gitee\|gitlab\)/,/^$/d' "$ssh_config"
    fi

    print_success "SSH配置中的Git相关配置已清除"
}

# === 清除Git凭证 ===
clear_git_credentials() {
    print_header "清除Git凭证"

    local credential_helper
    credential_helper=$(git config --global credential.helper 2>/dev/null)

    print_info "当前凭证存储方式: ${credential_helper:-未设置}"

    if [ "$INTERACTIVE" = true ] && [ "$DRY_RUN" = false ]; then
        echo ""
        read -p "确认清除Git凭证? (y/N): " confirm
        if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
            print_info "跳过Git凭证清除"
            return 0
        fi
    fi

    if [ "$DRY_RUN" = true ]; then
        print_info "[试运行] 将清除Git凭证"
        return 0
    fi

    # 清除Git凭证配置
    if [ -n "$credential_helper" ]; then
        git config --global --unset credential.helper
        print_success "Git凭证配置已清除"
    fi

    # 清除macOS钥匙串中的Git凭证
    if [[ "$(uname)" == "Darwin" ]] && command -v security &> /dev/null; then
        print_info "清除macOS钥匙串中的Git凭证..."
        security delete-internet-password -s github.com 2>/dev/null && print_success "GitHub凭证已清除" || print_info "未找到GitHub凭证"
        security delete-internet-password -s gitee.com 2>/dev/null && print_success "Gitee凭证已清除" || print_info "未找到Gitee凭证"
        security delete-internet-password -s gitlab.com 2>/dev/null && print_success "GitLab凭证已清除" || print_info "未找到GitLab凭证"
    fi

    # 清除SSH agent中的密钥
    if [ -n "$SSH_AUTH_SOCK" ]; then
        print_info "清除SSH agent中的密钥..."
        ssh-add -D 2>/dev/null && print_success "SSH agent中的密钥已清除" || print_info "SSH agent未运行或无密钥"
    fi
}

# === 清除SSH密钥文件 ===
clear_ssh_keys_files() {
    print_header "清除SSH密钥文件"

    if [ ! -d "$HOME/.ssh" ]; then
        print_info "未找到SSH目录"
        return 0
    fi

    print_info "当前SSH密钥文件:"
    find "$HOME/.ssh" -name "id_*" -type f 2>/dev/null | while read -r key_file; do
        echo "  $key_file"
    done

    if [ "$INTERACTIVE" = true ] && [ "$DRY_RUN" = false ]; then
        echo ""
        print_warning "这将删除所有SSH密钥文件，包括非Git相关的密钥！"
        read -p "确认删除所有SSH密钥文件? (y/N): " confirm
        if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
            print_info "跳过SSH密钥文件清除"
            return 0
        fi
    fi

    if [ "$DRY_RUN" = true ]; then
        print_info "[试运行] 将删除以下SSH密钥文件:"
        find "$HOME/.ssh" -name "id_*" -type f 2>/dev/null
        return 0
    fi

    # 备份并删除SSH密钥文件
    mkdir -p "$BACKUP_DIR/ssh_keys_${CURRENT_DATE}"
    find "$HOME/.ssh" -name "id_*" -type f 2>/dev/null | while read -r key_file; do
        cp "$key_file" "$BACKUP_DIR/ssh_keys_${CURRENT_DATE}/"
        rm "$key_file"
        print_success "已删除: $key_file"
    done

    print_success "SSH密钥文件已清除"
    print_info "备份位置: $BACKUP_DIR/ssh_keys_${CURRENT_DATE}"
}

# === 恢复配置 ===
restore_config() {
    print_header "恢复Git配置"

    if [ ! -d "$BACKUP_DIR" ]; then
        print_error "未找到备份目录: $BACKUP_DIR"
        return 1
    fi

    echo "可用的备份："
    local index=1
    declare -A backups

    for file in "$BACKUP_DIR"/*_backup_*; do
        if [ -f "$file" ]; then
            local filename=$(basename "$file")
            backups[$index]="$file"
            echo "  $index) $filename"
            ((index++))
        fi
    done

    if [ $index -eq 1 ]; then
        print_warning "没有找到可用的备份"
        return 1
    fi

    read -p "请选择要恢复的备份编号: " choice
    if [ -n "${backups[$choice]}" ]; then
        local backup_file="${backups[$choice]}"
        local config_type=$(echo "$backup_file" | sed 's/.*\/\([^_]*\)_backup_.*/\1/')

        case "$config_type" in
            gitconfig)
                cp "$backup_file" "$HOME/.gitconfig"
                print_success "Git配置已恢复"
                ;;
            sshconfig)
                cp "$backup_file" "$HOME/.ssh/config"
                chmod 600 "$HOME/.ssh/config"
                print_success "SSH配置已恢复"
                ;;
            *)
                print_error "未知的配置类型: $config_type"
                ;;
        esac
    else
        print_error "无效的选择"
    fi
}

# === 列出备份 ===
list_backups() {
    print_header "Git配置备份列表"

    if [ ! -d "$BACKUP_DIR" ]; then
        print_info "未找到备份目录: $BACKUP_DIR"
        return 0
    fi

    echo "备份目录: $BACKUP_DIR"
    echo ""

    local backup_count=0
    for file in "$BACKUP_DIR"/*_backup_*; do
        if [ -f "$file" ]; then
            backup_count=$((backup_count + 1))
            local filename=$(basename "$file")
            local file_size=$(ls -lh "$file" | awk '{print $5}')
            local file_date=$(stat -f "%Sm" -t "%Y-%m-%d %H:%M:%S" "$file" 2>/dev/null || stat -c "%y" "$file" 2>/dev/null | cut -d'.' -f1)
            
            echo "  $filename"
            echo "    大小: $file_size"
            echo "    时间: $file_date"
            echo ""
        fi
    done

    if [ $backup_count -eq 0 ]; then
        print_info "没有找到备份文件"
    else
        print_info "共找到 $backup_count 个备份文件"
    fi
}

# === 主函数 ===
main() {
    print_header "Git配置清除和卸载脚本"

    # 解析参数
    parse_arguments "$@"
}

# === 执行主函数 ===
main "$@"