#!/bin/bash
#
# Docker 管理脚本 - 安装/卸载/状态管理
# 支持 Docker Desktop 和 Colima 两种方案
#
# 用法:
#   ./docker-manager.sh                    # 交互式安装（macOS 默认 colima）
#   ./docker-manager.sh --desktop          # 安装 Docker Desktop
#   ./docker-manager.sh --colima           # 安装 Colima
#   ./docker-manager.sh --uninstall        # 卸载当前安装的 Docker
#   ./docker-manager.sh --status           # 查看状态
#   ./docker-manager.sh --help             # 显示帮助

set -euo pipefail

# === 颜色定义 ===
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly BOLD='\033[1m'
readonly NC='\033[0m'

# === 日志函数 ===
log_info() { echo -e "${BLUE}[INFO]${NC} $*"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
log_header() { echo -e "${CYAN}${BOLD}>>> $*${NC}"; }

# === 检测系统 ===
detect_os() {
    case "$(uname -s)" in
        Darwin*) echo "macos" ;;
        Linux*) echo "linux" ;;
        *) echo "unknown" ;;
    esac
}

# === 检测架构 ===
detect_arch() {
    case "$(uname -m)" in
        x86_64) echo "amd64" ;;
        arm64|aarch64) echo "arm64" ;;
        *) echo "$(uname -m)" ;;
    esac
}

# === 检查当前 Docker 安装状态 ===
check_docker_status() {
    local status="none"
    
    if [[ -d "/Applications/Docker.app" ]]; then
        status="desktop"
    fi
    
    if command -v colima &> /dev/null; then
        if [[ "$status" == "desktop" ]]; then
            status="both"
        else
            status="colima"
        fi
    fi
    
    echo "$status"
}

# === 检查 Docker 是否运行 ===
is_docker_running() {
    if docker info &> /dev/null; then
        return 0
    fi
    return 1
}

# === 安装 Homebrew ===
install_homebrew() {
    if command -v brew &> /dev/null; then
        log_info "Homebrew 已安装"
        return 0
    fi

    log_info "正在安装 Homebrew..."
    
    # 使用国内镜像加速
    export HOMEBREW_INSTALL_FROM_API=1
    export HOMEBREW_API_DOMAIN="https://mirrors.tuna.tsinghua.edu.cn/homebrew-bottles/api"
    export HOMEBREW_BOTTLE_DOMAIN="https://mirrors.tuna.tsinghua.edu.cn/homebrew-bottles"
    
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" || {
        log_error "Homebrew 安装失败"
        return 1
    }
    
    # 配置环境变量
    if [[ -f "$HOME/.zshrc" ]]; then
        echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> "$HOME/.zshrc"
        eval "$(/opt/homebrew/bin/brew shellenv)"
    fi
    
    log_success "Homebrew 安装完成"
}

# === 安装 Colima ===
install_colima() {
    log_header "安装 Colima"
    
    local os=$(detect_os)
    if [[ "$os" != "macos" ]]; then
        log_error "Colima 主要支持 macOS，Linux 建议使用系统包管理器安装"
        return 1
    fi
    
    # 检查是否已安装 Docker Desktop
    if [[ -d "/Applications/Docker.app" ]]; then
        log_warn "检测到 Docker Desktop 已安装"
        log_warn "Colima 和 Docker Desktop 不建议同时运行"
        read -rp "是否继续安装 Colima？(y/N): " confirm
        [[ "$confirm" =~ ^[Yy]$ ]] || return 1
    fi
    
    # 安装 Homebrew
    install_homebrew || return 1
    
    # 安装 colima + docker + docker-compose
    log_info "安装 colima..."
    brew install colima
    
    log_info "安装 docker..."
    brew install docker
    
    log_info "安装 docker-compose..."
    brew install docker-compose
    
    # 启动 colima
    log_info "启动 Colima..."
    colima start --cpu 4 --memory 8 --disk 100
    
    # 配置 docker context
    docker context use colima 2>/dev/null || true
    
    log_success "Colima 安装完成"
}

# === 安装 Docker Desktop ===
install_docker_desktop() {
    log_header "安装 Docker Desktop"
    
    local os=$(detect_os)
    local arch=$(detect_arch)
    
    if [[ "$os" != "macos" ]]; then
        log_error "Docker Desktop 自动安装仅支持 macOS"
        log_info "Linux 请使用系统包管理器或手动下载: https://docs.docker.com/desktop/install/linux-install/"
        return 1
    fi
    
    # 检查是否已安装 Colima
    if command -v colima &> /dev/null; then
        log_warn "检测到 Colima 已安装"
        log_warn "Docker Desktop 和 Colima 不建议同时运行"
        read -rp "是否继续安装 Docker Desktop？(y/N): " confirm
        [[ "$confirm" =~ ^[Yy]$ ]] || return 1
    fi
    
    # 检查是否已安装
    if [[ -d "/Applications/Docker.app" ]]; then
        log_info "Docker Desktop 已安装"
        open /Applications/Docker.app
        return 0
    fi
    
    # 安装 Homebrew（如果需要）
    install_homebrew || true
    
    # 尝试通过 Homebrew 安装
    if command -v brew &> /dev/null; then
        log_info "尝试通过 Homebrew 安装 Docker Desktop..."
        if brew install --cask docker 2>/dev/null; then
            log_success "Docker Desktop 安装完成"
            open /Applications/Docker.app
            return 0
        fi
        log_warn "Homebrew 安装失败，尝试直接下载..."
    fi
    
    # 直接下载安装
    local dmgs
    if [[ "$arch" == "arm64" ]]; then
        dmgs=(
            "https://desktop.docker.com/mac/main/arm64/Docker.dmg"
            "https://mirrors.aliyun.com/docker-desktop/mac/arm64/Docker.dmg"
        )
    else
        dmgs=(
            "https://desktop.docker.com/mac/main/amd64/Docker.dmg"
            "https://mirrors.aliyun.com/docker-desktop/mac/amd64/Docker.dmg"
        )
    fi
    
    local downloads_dir="$HOME/Downloads"
    mkdir -p "$downloads_dir"
    local dmg_file="$downloads_dir/Docker.dmg"
    
    log_info "正在下载 Docker Desktop..."
    local downloaded=false
    for url in "${dmgs[@]}"; do
        log_info "尝试: $url"
        if curl -L -o "$dmg_file" "$url" --connect-timeout 30 --max-time 600; then
            downloaded=true
            break
        fi
    done
    
    if [[ "$downloaded" != true ]]; then
        log_error "下载失败"
        log_info "请手动下载: https://www.docker.com/products/docker-desktop"
        return 1
    fi
    
    # 安装
    log_info "安装 Docker Desktop..."
    local volume=$(hdiutil attach "$dmg_file" | grep 'Volumes' | awk -F '\t' '{print $NF}')
    cp -R "/Volumes/Docker/Docker.app" /Applications
    hdiutil detach "$volume" > /dev/null 2>&1
    rm -f "$dmg_file"
    
    # 启动
    open /Applications/Docker.app
    log_success "Docker Desktop 安装完成"
}

# === 卸载 Docker ===
uninstall_docker() {
    log_header "卸载 Docker"
    
    local status=$(check_docker_status)
    
    if [[ "$status" == "none" ]]; then
        log_warn "未检测到 Docker 安装"
        return 0
    fi
    
    log_warn "这将卸载:"
    [[ "$status" == "desktop" || "$status" == "both" ]] && echo "  - Docker Desktop"
    [[ "$status" == "colima" || "$status" == "both" ]] && echo "  - Colima"
    echo ""
    read -rp "确认卸载？(y/N): " confirm
    
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        log_info "取消卸载"
        return 0
    fi
    
    # 卸载 Docker Desktop
    if [[ "$status" == "desktop" || "$status" == "both" ]]; then
        log_info "卸载 Docker Desktop..."
        
        # 停止 Docker
        osascript -e 'quit app "Docker"' 2>/dev/null || true
        sleep 2
        
        # 删除应用
        rm -rf /Applications/Docker.app
        
        # 删除相关文件
        rm -rf ~/Library/Containers/com.docker.docker
        rm -rf ~/Library/Application\ Support/Docker\ Desktop
        rm -rf ~/.docker
        
        log_success "Docker Desktop 已卸载"
    fi
    
    # 卸载 Colima
    if [[ "$status" == "colima" || "$status" == "both" ]]; then
        log_info "卸载 Colima..."
        
        # 停止 colima
        colima stop 2>/dev/null || true
        
        # 删除虚拟机
        colima delete -f 2>/dev/null || true
        
        # 通过 Homebrew 卸载
        if command -v brew &> /dev/null; then
            brew uninstall colima 2>/dev/null || true
        fi
        
        # 删除配置
        rm -rf ~/.colima
        
        log_success "Colima 已卸载"
    fi
    
    log_success "Docker 卸载完成"
}

# === 显示状态 ===
show_status() {
    log_header "Docker 状态"
    
    local status=$(check_docker_status)
    local running="否"
    is_docker_running && running="是"
    
    echo "安装状态:"
    case "$status" in
        none) echo "  未安装" ;;
        desktop) echo "  Docker Desktop" ;;
        colima) echo "  Colima" ;;
        both) echo "  Docker Desktop + Colima（不建议）" ;;
    esac
    
    echo ""
    echo "运行状态: $running"
    
    if is_docker_running; then
        echo ""
        echo "Docker 版本:"
        docker --version 2>/dev/null || echo "  无法获取"
        
        echo ""
        echo "Docker Compose 版本:"
        docker-compose --version 2>/dev/null || docker compose version 2>/dev/null || echo "  未安装"
    fi
}

# === 交互式安装 ===
interactive_install() {
    local os=$(detect_os)
    
    log_header "Docker 安装"
    echo ""
    
    # 检查现有安装
    local status=$(check_docker_status)
    if [[ "$status" != "none" ]]; then
        log_warn "检测到已安装: $status"
        show_status
        echo ""
        read -rp "是否重新安装？(y/N): " confirm
        [[ "$confirm" =~ ^[Yy]$ ]] || return 0
        uninstall_docker
    fi
    
    # 根据系统推荐默认方案
    local choice
    if [[ "$os" == "macos" ]]; then
        echo "推荐方案:"
        echo "  1) Colima (轻量免费，推荐)"
        echo "  2) Docker Desktop (功能完整，大公司需订阅)"
        echo ""
        read -rp "请选择 [1]: " choice
        choice="${choice:-1}"
        
        case "$choice" in
            1) install_colima ;;
            2) install_docker_desktop ;;
            *) log_error "无效选择"; return 1 ;;
        esac
    else
        echo "Linux 系统推荐使用系统包管理器安装 Docker"
        echo "  - Ubuntu/Debian: sudo apt install docker.io docker-compose"
        echo "  - CentOS/RHEL: sudo yum install docker docker-compose"
        echo ""
        read -rp "是否继续安装 Colima？(y/N): " confirm
        [[ "$confirm" =~ ^[Yy]$ ]] && install_colima
    fi
}

# === 显示帮助 ===
show_help() {
    cat << 'EOF'
Docker 管理脚本 - 安装/卸载/状态管理

用法: ./docker-manager.sh [选项]

选项:
    --desktop          安装 Docker Desktop
    --colima           安装 Colima (推荐 macOS)
    --uninstall        卸载 Docker
    --status           查看 Docker 状态
    -h, --help         显示此帮助

说明:
    - macOS 默认推荐 Colima（轻量、免费、开源）
    - Docker Desktop 功能完整，但大公司需要订阅
    - Colima 和 Docker Desktop 不建议同时运行
    - 两种方式都支持 docker-compose

示例:
    ./docker-manager.sh              # 交互式安装
    ./docker-manager.sh --colima     # 直接安装 Colima
    ./docker-manager.sh --uninstall  # 卸载

EOF
}

# === 主函数 ===
main() {
    case "${1:-}" in
        --desktop)
            install_docker_desktop
            ;;
        --colima)
            install_colima
            ;;
        --uninstall)
            uninstall_docker
            ;;
        --status)
            show_status
            ;;
        -h|--help)
            show_help
            ;;
        "")
            interactive_install
            ;;
        *)
            log_error "未知参数: $1"
            show_help
            exit 1
            ;;
    esac
}

main "$@"
