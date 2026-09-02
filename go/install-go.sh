#!/bin/bash

# Go一键安装配置脚本
# 支持多版本安装、国内镜像源、环境变量自动配置

set -e

# === 颜色定义 ===
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly BOLD='\033[1m'
readonly NC='\033[0m' # 无颜色

# === 常量定义 ===
readonly DEFAULT_GO_VERSION="1.23.5"
readonly GITHUB_RELEASE_URL="https://go.dev/dl/"
readonly GITHUB_API_URL="https://api.github.com/repos/golang/go/releases/latest"
readonly DEFAULT_INSTALL_DIR="$HOME/go"
readonly DEFAULT_GOPATH="$HOME/go-workspace"
readonly GO_PROXY_ALIYUN="https://mirrors.aliyun.com/goproxy/,direct"
readonly GO_PROXY_TENCENT="https://mirrors.cloud.tencent.com/go/,direct"
readonly GO_PROXY_QINIU="https://goproxy.cn,direct"
readonly GO_PROXY_OFFICIAL="https://proxy.golang.org,direct"

# === 全局变量 ===
GO_VERSION="$DEFAULT_GO_VERSION"
INSTALL_DIR="$DEFAULT_INSTALL_DIR"
GOPATH="$DEFAULT_GOPATH"
USE_PROXY="$GO_PROXY_QINIU"
DRY_RUN=false
UNINSTALL_MODE=false
SKIP_SHELL_CONFIG=false
FORCE_REINSTALL=false

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
Go一键安装配置脚本

用法: ./install-go.sh [选项]

选项:
    -h, --help                  显示此帮助信息
    -v, --version VERSION       指定Go版本 (默认: 1.23.5)
    -d, --dir DIR               安装目录 (默认: ~/go)
    -p, --gopath GOPATH         GOPATH路径 (默认: ~/go-workspace)
    -m, --mirror MIRROR         Go代理源 (aliyun|tencent|qiniu|official)
    --dry-run                   试运行模式，显示将要执行的操作但不实际执行
    --uninstall                 卸载Go
    --skip-shell-config         跳过shell配置文件修改
    --force                     强制重新安装，即使已安装

Go代理说明:
    aliyun    - 阿里云镜像 (https://mirrors.aliyun.com/goproxy/)
    tencent   - 腾讯云镜像 (https://mirrors.cloud.tencent.com/go/)
    qiniu     - 七牛云镜像 (https://goproxy.cn) [默认]
    official  - 官方代理 (https://proxy.golang.org)

示例:
    ./install-go.sh                           # 使用默认设置安装
    ./install-go.sh --version 1.22.0         # 安装特定版本
    ./install-go.sh --mirror aliyun          # 使用阿里云镜像
    ./install-go.sh --gopath ~/dev/go        # 自定义GOPATH
    ./install-go.sh --uninstall              # 卸载Go
    ./install-go.sh --dry-run                # 试运行模式

使用指南:
    1. 安装完成后，重启终端或执行: source ~/.zshrc (或 ~/.bashrc)
    2. 验证安装: go version
    3. 创建项目: mkdir myproject && cd myproject && go mod init myproject
    4. 设置Go代理: go env -w GOPROXY=https://goproxy.cn,direct
    5. 下载依赖: go mod tidy

更多信息: https://golang.org/
EOF
}

# === 检测操作系统 ===
detect_os() {
    case "$(uname -s)" in
        Linux*)     echo "linux";;
        Darwin*)    echo "darwin";;
        CYGWIN*|MINGW*) echo "windows";;
        *)          echo "unknown";;
    esac
}

# === 检测系统架构 ===
detect_architecture() {
    case "$(uname -m)" in
        x86_64)     echo "amd64";;
        aarch64|arm64) echo "arm64";;
        armv7l)     echo "armv6l";;
        *)          echo "unknown";;
    esac
}

# === 获取shell配置文件 ===
get_shell_config_file() {
    local shell_name
    shell_name="$(basename "$SHELL")"

    case "$shell_name" in
        zsh)
            if [ -f "$HOME/.zshrc" ]; then
                echo "$HOME/.zshrc"
            elif [ -f "$HOME/.zprofile" ]; then
                echo "$HOME/.zprofile"
            else
                echo "$HOME/.zshrc"
            fi
            ;;
        bash)
            if [ -f "$HOME/.bash_profile" ]; then
                echo "$HOME/.bash_profile"
            elif [ -f "$HOME/.bashrc" ]; then
                echo "$HOME/.bashrc"
            else
                echo "$HOME/.profile"
            fi
            ;;
        *)
            echo "$HOME/.profile"
            ;;
    esac
}

# === 解析命令行参数 ===
parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help)
                show_usage
                exit 0
                ;;
            -v|--version)
                GO_VERSION="$2"
                shift 2
                ;;
            -d|--dir)
                INSTALL_DIR="$2"
                shift 2
                ;;
            -p|--gopath)
                GOPATH="$2"
                shift 2
                ;;
            -m|--mirror)
                case "$2" in
                    aliyun)
                        USE_PROXY="$GO_PROXY_ALIYUN"
                        ;;
                    tencent)
                        USE_PROXY="$GO_PROXY_TENCENT"
                        ;;
                    qiniu)
                        USE_PROXY="$GO_PROXY_QINIU"
                        ;;
                    official)
                        USE_PROXY="$GO_PROXY_OFFICIAL"
                        ;;
                    *)
                        print_error "不支持的镜像源: $2"
                        print_info "支持的镜像源: aliyun, tencent, qiniu, official"
                        exit 1
                        ;;
                esac
                shift 2
                ;;
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            --uninstall)
                UNINSTALL_MODE=true
                shift
                ;;
            --skip-shell-config)
                SKIP_SHELL_CONFIG=true
                shift
                ;;
            --force)
                FORCE_REINSTALL=true
                shift
                ;;
            *)
                print_error "未知选项: $1"
                show_usage
                exit 1
                ;;
        esac
    done
}

# === 检查依赖 ===
check_dependencies() {
    local missing_deps=()
    
    for dep in curl tar; do
        if ! command -v "$dep" &> /dev/null; then
            missing_deps+=("$dep")
        fi
    done
    
    if [ ${#missing_deps[@]} -gt 0 ]; then
        print_error "缺少依赖: ${missing_deps[*]}"
        print_info "请先安装缺少的依赖，然后重试"
        exit 1
    fi
}

# === 获取Go版本URL ===
get_go_download_url() {
    local version="$1"
    local os="$2"
    local arch="$3"
    
    # 格式化版本号（移除v前缀）
    version="${version#v}"
    
    # 构建下载URL
    local filename="go${version}.${os}-${arch}.tar.gz"
    echo "https://go.dev/dl/${filename}"
}

# === 检查Go是否已安装 ===
check_go_installed() {
    if command -v go &> /dev/null; then
        return 0
    else
        return 1
    fi
}

# === 安装Go ===
install_go() {
    local os
    local arch
    local download_url
    local temp_dir
    local archive_file
    
    os=$(detect_os)
    arch=$(detect_architecture)
    
    if [ "$os" = "unknown" ] || [ "$arch" = "unknown" ]; then
        print_error "不支持的操作系统或架构"
        print_info "操作系统: $(uname -s), 架构: $(uname -m)"
        exit 1
    fi
    
    download_url=$(get_go_download_url "$GO_VERSION" "$os" "$arch")
    
    print_info "准备安装 Go $GO_VERSION"
    print_info "操作系统: $os, 架构: $arch"
    print_info "安装目录: $INSTALL_DIR"
    print_info "GOPATH: $GOPATH"
    print_info "Go代理: $USE_PROXY"
    
    if [ "$DRY_RUN" = true ]; then
        print_info "试运行模式: 将下载 $download_url"
        print_info "将解压到 $INSTALL_DIR"
        return 0
    fi
    
    # 创建临时目录
    temp_dir=$(mktemp -d)
    archive_file="$temp_dir/go.tar.gz"
    
    print_header "下载Go..."
    if ! curl -fsSL "$download_url" -o "$archive_file"; then
        print_error "下载失败: $download_url"
        rm -rf "$temp_dir"
        exit 1
    fi
    
    print_success "下载完成"
    
    # 检查压缩包是否有效
    if ! tar -tzf "$archive_file" &> /dev/null; then
        print_error "下载的文件不是有效的tar.gz文件"
        rm -rf "$temp_dir"
        exit 1
    fi
    
    print_header "解压Go..."
    
    # 删除旧的安装目录
    if [ -d "$INSTALL_DIR" ]; then
        print_warning "删除现有安装目录: $INSTALL_DIR"
        rm -rf "$INSTALL_DIR"
    fi
    
    # 创建安装目录
    mkdir -p "$INSTALL_DIR"
    
    # 解压Go
    if ! tar -xzf "$archive_file" -C "$INSTALL_DIR" --strip-components=1; then
        print_error "解压失败"
        rm -rf "$temp_dir" "$INSTALL_DIR"
        exit 1
    fi
    
    print_success "解压完成"
    
    # 清理临时文件
    rm -rf "$temp_dir"
    
    # 创建GOPATH目录
    mkdir -p "$GOPATH"/{bin,src,pkg}
    print_success "创建GOPATH目录: $GOPATH"
}

# === 配置shell环境 ===
configure_shell() {
    if [ "$SKIP_SHELL_CONFIG" = true ]; then
        print_info "跳过shell配置"
        return 0
    fi
    
    if [ "$DRY_RUN" = true ]; then
        print_info "试运行: 将配置shell环境变量"
        return 0
    fi
    
    local config_file
    config_file=$(get_shell_config_file)
    
    print_info "配置shell环境: $config_file"
    
    # 检查是否已配置
    if grep -q "GOROOT" "$config_file" 2>/dev/null; then
        if [ "$FORCE_REINSTALL" = false ]; then
            print_warning "Go环境变量已配置，跳过添加"
            print_info "使用 --force 选项强制重新配置"
            return 0
        fi
        
        # 删除旧的Go配置
        print_info "删除旧的Go配置..."
        sed -i.bak '/# Go环境配置/,/^$/d' "$config_file" 2>/dev/null || true
    fi
    
    # 添加新的Go配置
    cat >> "$config_file" << 'EOF'

# Go环境配置
export GOROOT=$HOME/go
export GOPATH=$HOME/go-workspace
export PATH=$GOROOT/bin:$GOPATH/bin:$PATH
export GO111MODULE=on
export GOPROXY=https://goproxy.cn,direct
EOF
    
    # 替换为实际的路径
    if [[ "$(uname)" == "Darwin" ]]; then
        sed -i '' "s|export GOROOT=\$HOME/go|export GOROOT=$INSTALL_DIR|" "$config_file"
        sed -i '' "s|export GOPATH=\$HOME/go-workspace|export GOPATH=$GOPATH|" "$config_file"
        sed -i '' "s|export GOPROXY=https://goproxy.cn,direct|export GOPROXY=$USE_PROXY|" "$config_file"
    else
        sed -i "s|export GOROOT=\$HOME/go|export GOROOT=$INSTALL_DIR|" "$config_file"
        sed -i "s|export GOPATH=\$HOME/go-workspace|export GOPATH=$GOPATH|" "$config_file"
        sed -i "s|export GOPROXY=https://goproxy.cn,direct|export GOPROXY=$USE_PROXY|" "$config_file"
    fi
    
    print_success "Go环境变量已配置"
}

# === 配置Go环境 ===
configure_go_env() {
    if [ "$DRY_RUN" = true ]; then
        print_info "试运行: 将配置Go环境"
        return 0
    fi
    
    print_header "配置Go环境..."
    
    # 设置环境变量
    export GOROOT="$INSTALL_DIR"
    export GOPATH="$GOPATH"
    export PATH="$INSTALL_DIR/bin:$GOPATH/bin:$PATH"
    export GO111MODULE=on
    export GOPROXY="$USE_PROXY"
    
    # 配置go env
    if command -v go &> /dev/null; then
        go env -w GO111MODULE=on
        go env -w GOPROXY="$USE_PROXY"
        go env -w GOSUMDB=off
        print_success "Go环境配置完成"
    fi
}

# === 验证安装 ===
verify_installation() {
    print_header "验证安装..."
    
    # 临时添加到PATH
    export PATH="$INSTALL_DIR/bin:$PATH"
    
    if ! command -v go &> /dev/null; then
        print_error "Go未正确安装或不在PATH中"
        print_info "请执行以下命令使配置生效:"
        print_info "  source $(get_shell_config_file)"
        print_info "或者重启终端"
        return 1
    fi
    
    local installed_version
    installed_version=$(go version | awk '{print $3}')
    print_success "Go安装成功!"
    print_info "版本: $installed_version"
    print_info "GOROOT: $(go env GOROOT)"
    print_info "GOPATH: $(go env GOPATH)"
    print_info "GOPROXY: $(go env GOPROXY)"
    
    # 测试Go命令
    if go version &> /dev/null; then
        print_success "Go命令测试通过"
    else
        print_warning "Go命令测试失败，请检查环境配置"
    fi
    
    return 0
}

# === 卸载Go ===
uninstall_go() {
    print_header "卸载Go..."
    
    if [ "$DRY_RUN" = true ]; then
        print_info "试运行: 将删除以下内容:"
        print_info "  安装目录: $INSTALL_DIR"
        print_info "  GOPATH: $GOPATH"
        return 0
    fi
    
    # 删除安装目录
    if [ -d "$INSTALL_DIR" ]; then
        print_info "删除安装目录: $INSTALL_DIR"
        rm -rf "$INSTALL_DIR"
    else
        print_warning "安装目录不存在: $INSTALL_DIR"
    fi
    
    # 删除GOPATH（可选）
    read -p "是否删除GOPATH目录 ($GOPATH)? (y/N): " delete_gopath
    if [[ "$delete_gopath" =~ ^[Yy]$ ]]; then
        if [ -d "$GOPATH" ]; then
            print_info "删除GOPATH目录: $GOPATH"
            rm -rf "$GOPATH"
        else
            print_warning "GOPATH目录不存在: $GOPATH"
        fi
    fi
    
    # 清理shell配置
    local config_file
    config_file=$(get_shell_config_file)
    
    if [ -f "$config_file" ] && grep -q "Go环境配置" "$config_file"; then
        print_info "清理shell配置: $config_file"
        if [[ "$(uname)" == "Darwin" ]]; then
            sed -i '' '/# Go环境配置/,/^$/d' "$config_file"
        else
            sed -i '/# Go环境配置/,/^$/d' "$config_file"
        fi
        print_success "Shell配置已清理"
    fi
    
    print_success "Go卸载完成"
    print_info "请重启终端或执行: source $config_file"
}

# === 主函数 ===
main() {
    print_header "Go一键安装配置脚本"
    
    # 解析参数
    parse_arguments "$@"
    
    # 检查依赖
    check_dependencies
    
    # 卸载模式
    if [ "$UNINSTALL_MODE" = true ]; then
        uninstall_go
        return 0
    fi
    
    # 检查是否已安装
    if check_go_installed && [ "$FORCE_REINSTALL" = false ]; then
        local current_version
        current_version=$(go version | awk '{print $3}')
        print_info "Go已安装: $current_version"
        print_info "使用 --force 选项强制重新安装"
        
        # 显示当前配置
        print_info "当前配置:"
        print_info "  GOROOT: $(go env GOROOT)"
        print_info "  GOPATH: $(go env GOPATH)"
        print_info "  GOPROXY: $(go env GOPROXY)"
        
        return 0
    fi
    
    # 安装Go
    install_go
    
    # 配置shell环境
    configure_shell
    
    # 配置Go环境
    configure_go_env
    
    # 验证安装
    verify_installation
    
    print_header "安装完成!"
    print_success "Go已成功安装并配置"
    
    if [ "$SKIP_SHELL_CONFIG" = false ]; then
        print_info "请执行以下命令使配置生效:"
        print_info "  source $(get_shell_config_file)"
        print_info "或者重启终端"
    fi
    
    print_info "开始使用Go吧!"
}

# === 执行主函数 ===
main "$@"