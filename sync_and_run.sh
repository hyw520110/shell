#!/usr/bin/env bash
# 双向同步执行脚本
# 功能: 无论在 sky 还是 star 主机执行，都能实现 sky → star 的同步
# 原理: 自动识别当前用户/主机，判断是推送还是拉取

set -euo pipefail

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_debug() { echo -e "${CYAN}[DEBUG]${NC} $1"; }

# 配置
SKY_USER="sky"
STAR_USER="star"
SKY_HOST="sky-mac.local"      # sky 主机地址（根据实际情况修改）
STAR_HOST="star-mac.local"    # star 主机地址（根据实际情况修改）
SYNC_DIR="ai"                 # 同步目录名
SSH_PORT=22                   # SSH 端口

# 获取当前用户信息
CURRENT_USER=$(whoami)
CURRENT_HOST=$(hostname -s)

# 检测当前环境
# 返回: sky | star | unknown
detect_environment() {
    local user=$(whoami)
    local host=$(hostname -s)
    
    # 通过用户名识别
    if [[ "$user" == "$SKY_USER" ]]; then
        echo "sky"
        return
    elif [[ "$user" == "$STAR_USER" ]]; then
        echo "star"
        return
    fi
    
    # 通过主机名识别（备用方案）
    if [[ "$host" == *"sky"* ]] || [[ "$host" == "sky-mac" ]]; then
        echo "sky"
        return
    elif [[ "$host" == *"star"* ]] || [[ "$host" == "star-mac" ]]; then
        echo "star"
        return
    fi
    
    # 通过 SSH 配置识别（检查 ~/.ssh/config 中的 Host 别名）
    if [[ -f "$HOME/.ssh/config" ]]; then
        if grep -q "Host sky-mac" "$HOME/.ssh/config" 2>/dev/null; then
            echo "star"  # 有 sky-mac 配置说明当前是 star
            return
        elif grep -q "Host star-mac" "$HOME/.ssh/config" 2>/dev/null; then
            echo "sky"   # 有 star-mac 配置说明当前是 sky
            return
        fi
    fi
    
    echo "unknown"
}

# 显示当前环境信息
show_environment() {
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}  双向同步执行脚本${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    log_debug "当前用户: $CURRENT_USER"
    log_debug "当前主机: $CURRENT_HOST"
    
    local env=$(detect_environment)
    case "$env" in
        sky)
            echo -e "${GREEN}✓ 检测到: sky 主机 (源端)${NC}"
            echo -e "${CYAN}  模式: 推送 (sky → star)${NC}"
            ;;
        star)
            echo -e "${GREEN}✓ 检测到: star 主机 (目标端)${NC}"
            echo -e "${CYAN}  模式: 拉取 (sky → star)${NC}"
            ;;
        *)
            echo -e "${YELLOW}⚠ 无法自动识别环境${NC}"
            echo -e "${YELLOW}  当前用户: $CURRENT_USER${NC}"
            echo -e "${YELLOW}  当前主机: $CURRENT_HOST${NC}"
            ;;
    esac
    echo ""
}

# 检查 SSH 连接
check_ssh() {
    local target="$1"
    log_info "检查 SSH 连接: $target..."
    
    if ! ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no -p "$SSH_PORT" "$target" "echo 'OK'" >/dev/null 2>&1; then
        log_error "无法连接到 $target"
        log_error "请确保:"
        log_error "  1. 目标主机已开机且网络可达"
        log_error "  2. SSH 服务正在运行 (port $SSH_PORT)"
        log_error "  3. 已配置 SSH 密钥认证"
        return 1
    fi
    
    log_info "SSH 连接正常: $target"
    return 0
}

# 从 sky 推送到 star (在 sky 主机执行)
push_from_sky() {
    local target="${STAR_USER}@${STAR_HOST}"
    local remote_dir="/Users/${STAR_USER}"
    
    log_info "开始推送: sky → star"
    log_info "源: ~/work/${SYNC_DIR}"
    log_info "目标: ${target}:${remote_dir}/work/"
    
    # 检查 SSH
    check_ssh "$target" || return 1
    
    # 确保目标目录存在
    ssh -p "$SSH_PORT" "$target" "mkdir -p ${remote_dir}/work" 2>/dev/null || true
    
    # 执行 rsync 推送
    log_info "正在同步文件..."
    rsync -avz --progress \
        -e "ssh -p ${SSH_PORT}" \
        --exclude=".git" \
        --exclude="node_modules" \
        --exclude="__pycache__" \
        --exclude="*.pyc" \
        --exclude=".cache" \
        --exclude="venv*" \
        --exclude=".DS_Store" \
        ~/work/${SYNC_DIR}/ \
        "${target}:${remote_dir}/work/${SYNC_DIR}/"
    
    log_info "推送完成"
    
    # 可选: 在目标端执行命令
    if [[ "${RUN_AFTER_SYNC:-false}" == "true" ]]; then
        log_info "在 star 主机执行后续命令..."
        ssh -p "$SSH_PORT" "$target" "cd ${remote_dir}/work/${SYNC_DIR} && ${RUN_CMD:-echo '同步完成'}"
    fi
}

# 从 star 拉取 sky (在 star 主机执行)
pull_from_star() {
    local source="${SKY_USER}@${SKY_HOST}"
    local local_dir="/Users/${STAR_USER}"
    
    log_info "开始拉取: sky → star"
    log_info "源: ${source}:~/work/${SYNC_DIR}"
    log_info "目标: ${local_dir}/work/"
    
    # 检查 SSH
    check_ssh "$source" || return 1
    
    # 确保本地目录存在
    mkdir -p "${local_dir}/work"
    
    # 执行 rsync 拉取
    log_info "正在同步文件..."
    rsync -avz --progress \
        -e "ssh -p ${SSH_PORT}" \
        --exclude=".git" \
        --exclude="node_modules" \
        --exclude="__pycache__" \
        --exclude="*.pyc" \
        --exclude=".cache" \
        --exclude="venv*" \
        --exclude=".DS_Store" \
        "${source}:~/work/${SYNC_DIR}/" \
        "${local_dir}/work/${SYNC_DIR}/"
    
    log_info "拉取完成"
    
    # 可选: 执行本地命令
    if [[ "${RUN_AFTER_SYNC:-false}" == "true" ]]; then
        log_info "执行后续命令..."
        cd "${local_dir}/work/${SYNC_DIR}" && ${RUN_CMD:-echo '同步完成'}
    fi
}

# 显示帮助
show_help() {
    cat << 'EOF'
双向同步执行脚本

用法: ./sync_and_run.sh [选项]

选项:
    -h, --help          显示帮助信息
    -d, --dry-run       试运行，不实际执行同步
    -r, --run CMD       同步后执行指定命令
    -c, --config FILE   使用指定配置文件
    -s, --sky-host HOST 指定 sky 主机地址
    -t, --star-host HOST 指定 star 主机地址

环境变量:
    RUN_AFTER_SYNC=true     同步后自动执行命令
    RUN_CMD="命令"          指定同步后执行的命令
    SYNC_DIR="目录名"       指定同步目录名 (默认: ai)

示例:
    # 在任意主机执行同步
    ./sync_and_run.sh

    # 同步后执行部署脚本
    ./sync_and_run.sh -r "bash deploy.sh"

    # 指定主机地址
    ./sync_and_run.sh -s sky@192.168.1.100 -t star@192.168.1.101

说明:
    脚本自动识别当前环境:
    - 在 sky 主机: 推送本地目录到 star
    - 在 star 主机: 从 sky 拉取目录到本地
    - 效果一致: 始终实现 sky → star 的同步

EOF
}

# 主函数
main() {
    local dry_run=false
    local custom_sky_host=""
    local custom_star_host=""
    
    # 解析参数
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                show_help
                exit 0
                ;;
            -d|--dry-run)
                dry_run=true
                shift
                ;;
            -r|--run)
                RUN_AFTER_SYNC=true
                RUN_CMD="$2"
                shift 2
                ;;
            -s|--sky-host)
                custom_sky_host="$2"
                shift 2
                ;;
            -t|--star-host)
                custom_star_host="$2"
                shift 2
                ;;
            -c|--config)
                # 加载配置文件
                if [[ -f "$2" ]]; then
                    source "$2"
                    log_info "已加载配置: $2"
                fi
                shift 2
                ;;
            *)
                log_error "未知选项: $1"
                show_help
                exit 1
                ;;
        esac
    done
    
    # 应用自定义主机配置
    [[ -n "$custom_sky_host" ]] && SKY_HOST="$custom_sky_host"
    [[ -n "$custom_star_host" ]] && STAR_HOST="$custom_star_host"
    
    # 显示环境信息
    show_environment
    
    # 检测环境并执行相应操作
    local env=$(detect_environment)
    
    if [[ "$dry_run" == true ]]; then
        log_warn "【试运行模式】"
        case "$env" in
            sky)
                log_info "将执行: rsync ~/work/${SYNC_DIR}/ → ${STAR_USER}@${STAR_HOST}:~/work/"
                ;;
            star)
                log_info "将执行: rsync ${SKY_USER}@${SKY_HOST}:~/work/${SYNC_DIR}/ → ~/work/"
                ;;
            *)
                log_error "无法确定执行方向，请检查配置"
                exit 1
                ;;
        esac
        exit 0
    fi
    
    case "$env" in
        sky)
            push_from_sky
            ;;
        star)
            pull_from_star
            ;;
        *)
            log_error "无法识别当前环境"
            log_error "请确保:"
            log_error "  1. 当前用户是 sky 或 star"
            log_error "  2. 或主机名包含 sky/star 标识"
            log_error "  3. 或配置 SSH config 中的 Host 别名"
            echo ""
            log_info "可以通过以下方式手动指定:"
            log_info "  ./sync_and_run.sh --sky-host user@host --star-host user@host"
            exit 1
            ;;
    esac
}

main "$@"
