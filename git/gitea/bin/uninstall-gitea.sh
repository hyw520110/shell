#!/bin/bash

# Gitea 卸载脚本
# 支持 Docker、macOS Homebrew、Linux 主机模式

# === 颜色定义 ===
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly BOLD='\033[1m'
readonly NC='\033[0m'

# === 日志函数 ===
log() { echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*"; }
print_header() { echo -e "${CYAN}${BOLD}>>> $*${NC}"; }
print_info() { echo -e "${BLUE}[INFO]${NC} $*"; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $*"; }
print_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
print_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# === 常量定义 ===
# 同步安装脚本的默认路径
readonly DEFAULT_INSTALL_DIR="$HOME/gitea"
readonly GITEA_BREW_DIR="/opt/homebrew/var/gitea"

# === 帮助逻辑与变量 ===
FORCE_YES="${GITEA_UNINSTALL_YES:-false}"

# === 检测 Gitea 安装路径 ===
# 动态寻找可能的安装目录
find_gitea_dir() {
    local paths=("$DEFAULT_INSTALL_DIR" "/data/gitea" "/usr/local/gitea" "$HOME/gitea")
    for p in "${paths[@]}"; do
        if [[ -d "$p" && (-f "$p/docker-compose.yml" || -d "$p/data") ]]; then
            echo "$p"
            return 0
        fi
    done
    echo "$DEFAULT_INSTALL_DIR" # 回退到默认
}
readonly GITEA_INSTALL_DIR=$(find_gitea_dir)

# === 显示帮助 ===
show_help() {
    cat << EOF
Gitea 卸载脚本

用法: $0 [选项]

选项:
  -h, --help          显示此帮助信息
  -y, --yes           直接卸载，不询问确认
  --keep-data         保留数据目录
  --docker            只卸载 Docker 模式
  --host              只卸载主机模式

示例:
  $0                  # 交互模式卸载
  $0 -y               # 直接卸载
  $0 --keep-data      # 卸载但保留数据
  $0 --docker         # 只卸载 Docker 模式

EOF
}

# === 检测操作系统 ===
detect_os() {
    if [[ "$OSTYPE" == "darwin"* ]]; then
        echo "macos"
    elif [[ -f /etc/redhat-release ]]; then
        echo "centos"
    elif [[ -f /etc/debian_version ]]; then
        echo "ubuntu"
    else
        echo "linux"
    fi
}

# === 检测 Gitea 安装模式 ===
detect_install_mode() {
    local modes=()
    
    # 检测 Docker 模式
    if [[ -f "$GITEA_INSTALL_DIR/docker-compose.yml" ]]; then
        modes+=("docker")
    fi
    
    # 检测 macOS Homebrew 模式
    if [[ "$OSTYPE" == "darwin"* ]] && command -v brew &>/dev/null; then
        if brew list gitea &>/dev/null 2>&1 || [[ -d "$GITEA_BREW_DIR" ]]; then
            modes+=("brew")
        fi
    fi
    
    # 检测 Linux systemd 模式
    if command -v systemctl &>/dev/null && systemctl list-unit-files gitea.service &>/dev/null 2>&1; then
        modes+=("systemd")
    fi
    
    # 检测 Linux 手动安装模式
    if [[ -f /usr/local/bin/gitea ]] || [[ -f /usr/bin/gitea ]]; then
        modes+=("linux")
    fi
    
    echo "${modes[@]}"
}

# === 卸载 Docker 模式 ===
uninstall_docker() {
    print_info "开始卸载 Docker 模式 Gitea..."
    
    if [[ ! -f "$GITEA_INSTALL_DIR/docker-compose.yml" ]]; then
        print_info "未检测到 Docker 模式安装"
        return 1
    fi
    
    cd "$GITEA_INSTALL_DIR"
    
    # 停止并删除容器
    print_info "停止 Docker 容器..."
    docker compose down -v 2>/dev/null || docker-compose down -v 2>/dev/null
    
    # 删除安装目录
    if [[ -d "$GITEA_INSTALL_DIR" ]]; then
        local confirm
        if [[ "$FORCE_YES" == "true" ]]; then
            confirm="y"
        else
            read -p "是否删除安装目录 $GITEA_INSTALL_DIR? [y/N] " confirm
        fi
        confirm=${confirm:-N}
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            rm -rf "$GITEA_INSTALL_DIR"
            print_success "安装目录已删除"
        else
            print_info "保留安装目录"
        fi
    fi
    
    print_success "Docker 模式 Gitea 已卸载"
}

# === 卸载 macOS Homebrew 模式 ===
uninstall_brew() {
    print_info "开始卸载 macOS Homebrew 模式 Gitea..."
    
    if ! command -v brew &>/dev/null; then
        print_info "未检测到 Homebrew"
        return 1
    fi
    
    # 检查 Gitea 是否已安装
    if ! brew list gitea &>/dev/null 2>&1; then
        print_info "未检测到 Homebrew 安装的 Gitea"
        return 1
    fi
    
    # 停止服务
    print_info "停止 Gitea 服务..."
    brew services stop gitea 2>/dev/null || true
    
    # 卸载 Gitea
    print_info "卸载 Gitea..."
    brew uninstall gitea
    
    # 删除数据目录
    if [[ -d "$GITEA_BREW_DIR" ]]; then
        echo ""
        echo "数据目录: $GITEA_BREW_DIR"
        
        # 检查是否包含实际数据文件
        local data_files=$(find "$GITEA_BREW_DIR" -type f 2>/dev/null | wc -l | tr -d ' ')
        local subdirs=$(find "$GITEA_BREW_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')
        
        echo "包含 $subdirs 个子目录, $data_files 个数据文件"
        echo ""
        
        if [[ "$data_files" -gt 0 ]]; then
            echo "目录包含用户数据:"
            ls -la "$GITEA_BREW_DIR" 2>/dev/null | head -10
            echo ""
            echo "⚠️  重要提示:"
            echo "   - 删除数据目录将清除所有仓库、用户、问题等数据"
            echo "   - 如需重新安装并显示安装向导，必须删除数据目录"
            echo ""
            read -p "是否删除数据目录（彻底清除所有数据）? [y/N] " confirm
            confirm=${confirm:-N}
            if [[ "$confirm" =~ ^[Yy]$ ]]; then
                rm -rf "$GITEA_BREW_DIR"
                print_success "数据目录已删除"
            else
                print_warn "保留数据目录，重新安装时将使用旧数据（包括之前创建的管理员账号）"
            fi
        else
            echo "目录为空或只有配置文件，将被自动清理"
            rm -rf "$GITEA_BREW_DIR"
            print_success "空数据目录已清理"
        fi
    fi
    
    print_success "Homebrew 模式 Gitea 已卸载"
}

# === 卸载 Linux systemd 模式 ===
uninstall_systemd() {
    print_info "开始卸载 Linux systemd 模式 Gitea..."
    
    # 检查是否有 root 权限
    if [[ $EUID -ne 0 ]]; then
        print_info "需要 root 权限，将使用 sudo..."
        exec sudo "$0" "$@"
    fi
    
    # 停止服务
    if systemctl is-active gitea &>/dev/null 2>&1; then
        print_info "停止 Gitea 服务..."
        systemctl stop gitea
        systemctl disable gitea
    fi
    
    # 删除 systemd 服务文件
    if [[ -f /etc/systemd/system/gitea.service ]]; then
        print_info "删除 systemd 服务文件..."
        rm -f /etc/systemd/system/gitea.service
        systemctl daemon-reload
    fi
    
    # 删除 Gitea 二进制文件
    for bin_path in /usr/local/bin/gitea /usr/bin/gitea; do
        if [[ -f "$bin_path" ]]; then
            print_info "删除 $bin_path..."
            rm -f "$bin_path"
        fi
    done
    
    # 删除配置和数据目录
    for dir_path in /etc/gitea "$GITEA_INSTALL_DIR"; do
        if [[ -d "$dir_path" ]]; then
            echo ""
            echo "目录: $dir_path"
            
            # 检查是否包含实际数据文件
            local data_files=$(find "$dir_path" -type f 2>/dev/null | wc -l | tr -d ' ')
            local subdirs=$(find "$dir_path" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')
            
            echo "包含 $subdirs 个子目录, $data_files 个数据文件"
            
            if [[ "$data_files" -gt 0 ]]; then
                ls -la "$dir_path" 2>/dev/null | head -5
                echo ""
                echo "⚠️  重要提示:"
                echo "   - 删除数据目录将清除所有仓库、用户、问题等数据"
                echo "   - 如需重新安装并显示安装向导，必须删除数据目录"
                echo ""
                read -p "是否删除 $dir_path? [y/N] " confirm
                confirm=${confirm:-N}
                if [[ "$confirm" =~ ^[Yy]$ ]]; then
                    rm -rf "$dir_path"
                    print_success "$dir_path 已删除"
                else
                    print_warn "保留 $dir_path，重新安装时将使用旧数据"
                fi
            else
                echo "目录为空或只有配置文件，将被自动清理"
                rm -rf "$dir_path"
                print_success "$dir_path 已清理"
            fi
        fi
    done
    
    print_success "systemd 模式 Gitea 已卸载"
}

# === 卸载 Linux 手动安装 ===
uninstall_linux() {
    print_info "开始卸载 Linux 手动安装 Gitea..."
    
    if [[ $EUID -ne 0 ]]; then
        print_info "需要 root 权限，将使用 sudo..."
        exec sudo "$0" "$@"
    fi
    
    # 查找 Gitea 二进制文件
    local gitea_bin=""
    for path in /usr/local/bin/gitea /usr/bin/gitea ~/gitea/gitea; do
        if [[ -f "$path" ]]; then
            gitea_bin="$path"
            break
        fi
    done
    
    if [[ -z "$gitea_bin" ]]; then
        print_info "未找到 Gitea 二进制文件"
        return 1
    fi
    
    print_info "找到 Gitea: $gitea_bin"
    
    # 删除二进制文件
    print_info "删除 Gitea 二进制文件..."
    rm -f "$gitea_bin"
    
    # 删除配置目录
    for dir_path in /etc/gitea ~/.gitea "$HOME/gitea"; do
        if [[ -d "$dir_path" ]]; then
            echo ""
            read -p "是否删除 $dir_path? [y/N] " confirm
            confirm=${confirm:-N}
            if [[ "$confirm" =~ ^[Yy]$ ]]; then
                rm -rf "$dir_path"
                print_success "$dir_path 已删除"
            fi
        fi
    done
    
    print_success "Linux 手动安装 Gitea 已卸载"
}

# === 交互模式卸载 ===
uninstall_interactive() {
    print_header "Gitea 卸载"
    
    local os=$(detect_os)
    local modes=($(detect_install_mode))
    
    if [[ ${#modes[@]} -eq 0 ]]; then
        print_error "未检测到 Gitea 安装"
        exit 1
    fi
    
    echo ""
    print_info "检测到以下安装模式:"
    for mode in "${modes[@]}"; do
        echo "  - $mode"
    done
    echo ""
    
    # 如果只有一种模式，直接卸载
    if [[ ${#modes[@]} -eq 1 ]]; then
        local mode="${modes[0]}"
        echo "检测到单一安装模式: $mode"
        echo ""
        
        read -p "确认卸载 $mode 模式? [y/N] " confirm
        confirm=${confirm:-N}
        
        if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
            print_info "取消卸载"
            exit 0
        fi
        
        case "$mode" in
            docker) uninstall_docker ;;
            brew) uninstall_brew ;;
            systemd) uninstall_systemd ;;
            linux) uninstall_linux ;;
        esac
        return 0
    fi
    
    # 多种模式，让用户选择
    echo "请选择要卸载的安装模式:"
    echo ""
    local i=1
    for mode in "${modes[@]}"; do
        echo "  $i) $mode"
        ((i++))
    done
    echo "  $i) 全部卸载"
    echo ""
    
    read -p "请选择 [1-$i]: " choice
    choice=${choice:-$i}
    
    if [[ "$choice" =~ ^[0-9]+$ ]] && [[ "$choice" -ge 1 ]] && [[ "$choice" -le $i ]]; then
        if [[ "$choice" -eq $i ]]; then
            # 全部卸载
            for mode in "${modes[@]}"; do
                echo ""
                echo "========================================"
                case "$mode" in
                    docker) uninstall_docker ;;
                    brew) uninstall_brew ;;
                    systemd) uninstall_systemd ;;
                    linux) uninstall_linux ;;
                esac
            done
        else
            # 单个卸载
            local selected_mode="${modes[$((choice-1))]}"
            case "$selected_mode" in
                docker) uninstall_docker ;;
                brew) uninstall_brew ;;
                systemd) uninstall_systemd ;;
                linux) uninstall_linux ;;
            esac
        fi
    else
        print_error "无效选择"
        exit 1
    fi
}

# === 主函数 ===
main() {
    local keep_data=false
    local uninstall_all=true
    local target_mode=""
    
    # 解析参数
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                show_help
                exit 0
                ;;
            -y|--yes)
                keep_data=false
                FORCE_YES=true
                shift
                ;;
            --keep-data)
                keep_data=true
                shift
                ;;
            --docker)
                target_mode="docker"
                uninstall_all=false
                shift
                ;;
            --host)
                target_mode="host"
                uninstall_all=false
                shift
                ;;
            *)
                print_error "未知选项: $1"
                show_help
                exit 1
                ;;
        esac
    done
    
    # 执行卸载
    if [[ -n "$target_mode" ]]; then
        case "$target_mode" in
            docker) uninstall_docker ;;
            host)
                local os=$(detect_os)
                if [[ "$os" == "macos" ]]; then
                    uninstall_brew
                else
                    uninstall_systemd
                fi
                ;;
        esac
    else
        uninstall_interactive
    fi
    
    echo ""
    print_success "Gitea 卸载完成!"
    print_info "如需重新安装，请运行: ./install-gitea.sh"
}

main "$@"
