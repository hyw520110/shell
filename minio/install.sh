#!/bin/bash

# MinIO 一键安装/卸载脚本
# 支持主流 Linux 发行版和 macOS
# 支持多线程断点续传下载
# 作者: Assistant
# 日期: 2025年11月13日

set -e  # 遇到错误时终止脚本执行

# 默认安装目录
DEFAULT_INSTALL_DIR="$HOME/minio"
# 默认下载目录
DEFAULT_DOWNLOAD_DIR="$HOME/Downloads"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 打印带颜色的信息
print_info() {
    echo -e "${BLUE}[信息]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[成功]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[警告]${NC} $1"
}

print_error() {
    echo -e "${RED}[错误]${NC} $1"
}

# 检测操作系统类型
detect_os() {
    UNAME=$(uname -s)
    case "${UNAME}" in
        Linux*)     OS=linux;;
        Darwin*)    OS=darwin;;
        *)          OS="unknown"
    esac
    print_info "检测到的操作系统: ${OS}"
}

# 检测系统架构
detect_arch() {
    ARCH=$(uname -m)
    case "${ARCH}" in
        x86_64)     ARCH=amd64;;
        aarch64|arm64) ARCH=arm64;;
        armv6l)     ARCH=armv6l;;
        armv7l)     ARCH=armv7l;;
        *)          ARCH="unknown"
    esac
    print_info "检测到的系统架构: ${ARCH}"
}

# 检查是否已安装 Go
check_go() {
    if command -v go &> /dev/null; then
        GO_VERSION=$(go version | cut -d' ' -f3 | sed 's/go//')
        print_info "检测到 Go 版本: ${GO_VERSION}"

        # 检查 Go 版本是否满足要求 (>= 1.24)
        if [[ $(printf '%s\n' "1.24" "${GO_VERSION}" | sort -V | head -n1) == "1.24" ]] || [[ "${GO_VERSION}" == "1.24" ]]; then
            print_success "Go 版本满足要求"
            return 0
        else
            print_error "Go 版本过低，需要至少 1.24 版本"
            return 1
        fi
    else
        print_error "未检测到 Go 环境，请先安装 Go 1.24 或更高版本"
        return 1
    fi
}

# 检查是否支持 aria2c 或 wget 下载工具
check_download_tool() {
    if command -v aria2c &> /dev/null; then
        DOWNLOAD_TOOL="aria2c"
        print_info "检测到 aria2c 工具，将使用多线程下载"
        return 0
    elif command -v wget &> /dev/null; then
        DOWNLOAD_TOOL="wget"
        print_info "检测到 wget 工具，将使用 wget 下载"
        return 0
    elif command -v curl &> /dev/null; then
        DOWNLOAD_TOOL="curl"
        print_info "检测到 curl 工具，将使用 curl 下载"
        return 0
    else
        print_error "系统中没有找到 aria2c、wget 或 curl 工具，无法下载 MinIO"
        return 1
    fi
}

# 使用 aria2c 多线程断点续传下载
download_with_aria2c() {
    local url=$1
    local output_dir=$2
    local filename=$3
    
    print_info "正在使用 aria2c 进行多线程断点续传下载: $filename"
    
    # 确保下载目录存在
    mkdir -p "$output_dir"
    
    # 使用 aria2c 进行下载，支持断点续传
    aria2c -c -x 16 -s 16 --max-tries=3 --timeout=10 --connect-timeout=5 \
           -d "$output_dir" -o "$filename" "$url"
    
    if [ $? -eq 0 ]; then
        print_success "下载成功: $filename"
        return 0
    else
        print_error "aria2c 下载失败: $filename"
        return 1
    fi
}

# 使用 wget 断点续传下载
download_with_wget() {
    local url=$1
    local output_dir=$2
    local filename=$3
    
    print_info "正在使用 wget 进行断点续传下载: $filename"
    
    # 确保下载目录存在
    mkdir -p "$output_dir"
    local filepath="$output_dir/$filename"
    
    # 使用 wget 进行断点续传下载
    wget -c --tries=3 --timeout=10 --read-timeout=10 \
         -O "$filepath" "$url"
    
    if [ $? -eq 0 ]; then
        print_success "下载成功: $filename"
        return 0
    else
        print_error "wget 下载失败: $filename"
        return 1
    fi
}

# 使用 curl 断点续传下载
download_with_curl() {
    local url=$1
    local output_dir=$2
    local filename=$3
    
    print_info "正在使用 curl 进行断点续传下载: $filename"
    
    # 确保下载目录存在
    mkdir -p "$output_dir"
    local filepath="$output_dir/$filename"
    
    # 使用 curl 进行断点续传下载
    curl -L -C - --retry 3 --connect-timeout 10 --max-time 60 \
         -o "$filepath" "$url"
    
    if [ $? -eq 0 ]; then
        print_success "下载成功: $filename"
        return 0
    else
        print_error "curl 下载失败: $filename"
        return 1
    fi
}

# 使用 Go 安装 MinIO
install_minio_go() {
    print_info "正在使用 Go 安装 MinIO..."
    if check_go; then
        go install github.com/minio/minio@latest
        if [ $? -eq 0 ]; then
            print_success "MinIO 安装成功"
            return 0
        else
            print_error "MinIO 安装失败"
            return 1
        fi
    else
        return 1
    fi
}

# 下载并安装 MinIO 二进制文件到指定目录
install_minio_binary() {
    local install_dir=${1:-$DEFAULT_INSTALL_DIR}
    local download_dir=${2:-$DEFAULT_DOWNLOAD_DIR}

    print_info "正在下载并安装 MinIO 二进制文件到: $install_dir"
    print_info "下载目录: $download_dir"

    # 确保安装目录存在
    mkdir -p "$install_dir"

    # 为不同的系统构建下载 URL
    BINARY_URL="https://dl.min.io/server/minio/release/${OS}-${ARCH}/minio"
    BINARY_NAME="minio"

    # 检查下载工具
    if ! check_download_tool; then
        return 1
    fi

    # 创建临时目录用于下载
    TMP_DIR=$(mktemp -d)
    cd "$TMP_DIR"

    # 根据可用的工具下载 MinIO 二进制文件
    case "$DOWNLOAD_TOOL" in
        "aria2c")
            if download_with_aria2c "$BINARY_URL" "$download_dir" "$BINARY_NAME"; then
                # 移动下载的文件到临时目录
                mv "$download_dir/$BINARY_NAME" "$TMP_DIR/$BINARY_NAME"
            else
                print_error "下载 MinIO 二进制文件失败"
                rm -rf "$TMP_DIR"
                return 1
            fi
            ;;
        "wget")
            if download_with_wget "$BINARY_URL" "$download_dir" "$BINARY_NAME"; then
                # 移动下载的文件到临时目录
                mv "$download_dir/$BINARY_NAME" "$TMP_DIR/$BINARY_NAME"
            else
                print_error "下载 MinIO 二进制文件失败"
                rm -rf "$TMP_DIR"
                return 1
            fi
            ;;
        "curl")
            if download_with_curl "$BINARY_URL" "$download_dir" "$BINARY_NAME"; then
                # 移动下载的文件到临时目录
                mv "$download_dir/$BINARY_NAME" "$TMP_DIR/$BINARY_NAME"
            else
                print_error "下载 MinIO 二进制文件失败"
                rm -rf "$TMP_DIR"
                return 1
            fi
            ;;
    esac

    # 检查下载是否成功
    if [ ! -f "$BINARY_NAME" ]; then
        print_error "下载 MinIO 二进制文件失败"
        rm -rf "$TMP_DIR"
        return 1
    fi

    # 设置执行权限
    chmod +x "$BINARY_NAME"

    # 移动到指定安装目录
    mv "$BINARY_NAME" "$install_dir/"

    # 更新 PATH 环境变量（添加到 .bashrc 或 .zshrc）
    if [ -f "$HOME/.bashrc" ]; then
        echo "export PATH=\"\$PATH:$install_dir\"" >> "$HOME/.bashrc"
        print_info "已将 $install_dir 添加到 .bashrc"
    elif [ -f "$HOME/.zshrc" ]; then
        echo "export PATH=\"\$PATH:$install_dir\"" >> "$HOME/.zshrc"
        print_info "已将 $install_dir 添加到 .zshrc"
    elif [ -f "$HOME/.profile" ]; then
        echo "export PATH=\"\$PATH:$install_dir\"" >> "$HOME/.profile"
        print_info "已将 $install_dir 添加到 .profile"
    fi

    # 清理临时文件
    rm -rf "$TMP_DIR"

    print_success "MinIO 二进制文件安装成功到: $install_dir"
    return 0
}

# 验证 MinIO 是否安装成功
verify_installation() {
    if command -v minio &> /dev/null; then
        MINIO_VERSION=$(minio --version 2>&1 | head -n 1)
        print_success "MinIO 安装验证成功: ${MINIO_VERSION}"
        return 0
    else
        # 检查指定安装目录中的 minio 命令
        if [ -f "$DEFAULT_INSTALL_DIR/minio" ] && [ -x "$DEFAULT_INSTALL_DIR/minio" ]; then
            # 尝试更新当前会话的 PATH
            export PATH="$PATH:$DEFAULT_INSTALL_DIR"
            MINIO_VERSION=$("$DEFAULT_INSTALL_DIR/minio" --version 2>&1 | head -n 1)
            print_success "MinIO 安装验证成功: ${MINIO_VERSION}"
            return 0
        fi
        print_error "MinIO 命令不可用，请检查安装"
        return 1
    fi
}

# 创建 MinIO 用户目录和配置
setup_minio_user_dir() {
    local data_dir=${1:-"$HOME/minio-data"}
    MINIO_USER_DIR="$HOME/.minio"

    # 创建 MinIO 用户配置目录
    if [ ! -d "$MINIO_USER_DIR" ]; then
        mkdir -p "$MINIO_USER_DIR"
        print_info "创建 MinIO 用户配置目录: $MINIO_USER_DIR"
    fi

    # 创建默认数据目录
    if [ ! -d "$data_dir" ]; then
        mkdir -p "$data_dir"
        print_info "创建默认 MinIO 数据目录: $data_dir"
    fi

    print_success "MinIO 用户目录设置完成"
}

# 检查 MinIO 是否正在运行
check_minio_running() {
    if command -v pgrep &> /dev/null; then
        MINIO_PID=$(pgrep -f "minio server" 2>/dev/null)
    elif command -v ps &> /dev/null; then
        MINIO_PID=$(ps aux | grep "minio server" | grep -v grep | awk '{print $2}' 2>/dev/null)
    fi

    if [ -n "$MINIO_PID" ]; then
        print_warning "检测到正在运行的 MinIO 服务，PID: $MINIO_PID"
        return 0
    else
        return 1
    fi
}

# 停止 MinIO 服务
stop_minio_service() {
    if command -v pgrep &> /dev/null; then
        MINIO_PID=$(pgrep -f "minio server" 2>/dev/null)
    elif command -v ps &> /dev/null; then
        MINIO_PID=$(ps aux | grep "minio server" | grep -v grep | awk '{print $2}' 2>/dev/null)
    fi

    if [ -n "$MINIO_PID" ]; then
        print_info "正在停止 MinIO 服务 (PID: $MINIO_PID)..."

        # 首先尝试优雅停止
        kill -TERM "$MINIO_PID" 2>/dev/null || true
        sleep 3

        # 检查是否仍然运行，如果运行则强制停止
        if kill -0 "$MINIO_PID" 2>/dev/null; then
            kill -9 "$MINIO_PID" 2>/dev/null || true
            print_info "MinIO 服务已强制停止"
        else
            print_info "MinIO 服务已优雅停止"
        fi
    fi
}

# 卸载 MinIO
uninstall_minio() {
    print_info "开始卸载 MinIO..."

    # 检查是否正在运行 MinIO
    if check_minio_running; then
        read -p "是否要先停止 MinIO 服务? [y/N]: " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            stop_minio_service
        else
            print_error "请先停止 MinIO 服务再进行卸载"
            exit 1
        fi
    fi

    # 删除安装目录
    if [ -d "$DEFAULT_INSTALL_DIR" ]; then
        rm -rf "$DEFAULT_INSTALL_DIR"
        print_info "已删除安装目录: $DEFAULT_INSTALL_DIR"
    fi

    # 尝试从系统路径中删除 MinIO (如果安装在 /usr/local/bin)
    if [ -f "/usr/local/bin/minio" ]; then
        SUDO_CMD=""
        if [ $EUID -ne 0 ]; then
            if command -v sudo &> /dev/null; then
                SUDO_CMD="sudo"
            else
                print_error "当前用户不是 root，且系统中没有找到 sudo 命令"
                return 1
            fi
        fi

        $SUDO_CMD rm -f /usr/local/bin/minio
        print_info "已从 /usr/local/bin 删除 MinIO"
    fi

    # 查找并删除 Go 安装的 MinIO（如果存在）
    if command -v go &> /dev/null; then
        GO_BIN_DIR=$(go env GOPATH 2>/dev/null)
        if [ -z "$GO_BIN_DIR" ] || [ "$GO_BIN_DIR" = "default" ]; then
            GO_BIN_DIR="$HOME/go"
        fi
        GO_BIN_DIR="$GO_BIN_DIR/bin"

        if [ -f "$GO_BIN_DIR/minio" ]; then
            rm -f "$GO_BIN_DIR/minio"
            print_info "已从 $GO_BIN_DIR 删除 MinIO"
        fi
    fi

    # 从 shell 配置文件中移除 PATH 添加项
    local shell_configs=("$HOME/.bashrc" "$HOME/.zshrc" "$HOME/.profile")

    for config_file in "${shell_configs[@]}"; do
        if [ -f "$config_file" ]; then
            # 检查是否存在添加 MinIO 到 PATH 的行
            if grep -q "minio" "$config_file" && grep -q "export PATH" "$config_file"; then
                print_info "正在从 $config_file 中移除 MinIO PATH 配置..."

                # 创建备份
                cp "$config_file" "$config_file.backup"

                # 移除包含 minio 的行
                sed -i.bak '/minio/d' "$config_file"

                print_success "已从 $config_file 中移除 MinIO PATH 配置"
            fi
        fi
    done

    # 询问是否删除用户配置目录
    if [ -d "$HOME/.minio" ]; then
        read -p "是否要删除 MinIO 配置目录 (~/.minio)? [y/N]: " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            rm -rf "$HOME/.minio"
            print_info "已删除 MinIO 配置目录"
        fi
    fi

    # 询问是否删除数据目录
    if [ -d "$HOME/minio-data" ]; then
        read -p "是否要删除 MinIO 数据目录 (~/minio-data)? [y/N]: " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            rm -rf "$HOME/minio-data"
            print_info "已删除 MinIO 数据目录"
        else
            print_info "MinIO 数据目录 (~/.minio-data) 已保留"
        fi
    fi

    print_success "MinIO 卸载完成"
    return 0
}

# 显示安装后说明
show_post_install_info() {
    local install_dir=${1:-$DEFAULT_INSTALL_DIR}
    local data_dir=${2:-"$HOME/minio-data"}

    cat << EOF

=======================================================
              MinIO 安装完成
=======================================================
安装目录: $install_dir
默认数据目录: $data_dir
配置目录: $HOME/.minio

启动 MinIO 服务器:
    minio server $data_dir

使用示例:
    minio server $data_dir --console-address :9001

默认登录凭据:
    用户名: minioadmin
    密码: minioadmin

访问控制台:
    打开浏览器访问 http://127.0.0.1:9001
访问 API:
    http://127.0.0.1:9000

使用 MinIO 客户端 (mc):
    mc alias set myminio http://127.0.0.1:9000 minioadmin minioadmin
=======================================================
EOF
}

# 显示帮助信息
show_help() {
    cat << EOF
用法: $0 [选项]

选项:
  -i, --install         安装 MinIO (默认)
  -u, --uninstall       卸载 MinIO
  -d, --install-dir DIR 指定 MinIO 安装目录 (默认: $DEFAULT_INSTALL_DIR)
  -w, --download-dir DIR 指定下载目录 (默认: $DEFAULT_DOWNLOAD_DIR)
  -h, --help            显示此帮助信息

示例:
  $0                    # 安装 MinIO 到默认目录
  $0 --install          # 安装 MinIO
  $0 --uninstall        # 卸载 MinIO
  $0 -d /path/to/minio  # 安装 MinIO 到指定目录
  $0 -w /path/to/download  # 指定下载目录
EOF
}

# 解析命令行参数
parse_arguments() {
    local action="install"  # 默认是安装
    local install_dir="$DEFAULT_INSTALL_DIR"
    local download_dir="$DEFAULT_DOWNLOAD_DIR"

    while [[ $# -gt 0 ]]; do
        case $1 in
            -i|--install)
                action="install"
                shift
                ;;
            -u|--uninstall)
                action="uninstall"
                shift
                ;;
            -d|--install-dir)
                install_dir="$2"
                shift 2
                ;;
            -w|--download-dir)
                download_dir="$2"
                shift 2
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            *)
                print_error "未知参数: $1"
                show_help
                exit 1
                ;;
        esac
    done

    # 更新默认安装目录和下载目录
    DEFAULT_INSTALL_DIR="$install_dir"
    DEFAULT_DOWNLOAD_DIR="$download_dir"

    # 返回操作、安装目录和下载目录
    echo "$action $install_dir $download_dir"
}

# 主函数
main() {
    # 解析命令行参数并获取操作类型
    local parse_result=($(parse_arguments "$@"))
    local action="${parse_result[0]}"
    local install_dir="${parse_result[1]}"
    local download_dir="${parse_result[2]}"

    detect_os
    detect_arch

    if [ "$action" = "uninstall" ]; then
        uninstall_minio
    else
        print_info "开始安装 MinIO..."

        # 尝试使用 Go 安装
        if install_minio_go; then
            print_success "MinIO 安装完成"
        else
            # 如果 Go 安装失败，尝试使用二进制文件方式
            print_warning "Go 安装方式失败，尝试下载二进制文件..."
            if install_minio_binary "$install_dir" "$download_dir"; then
                print_success "MinIO 安装完成"
            else
                print_error "MinIO 安装失败"
                exit 1
            fi
        fi

        if verify_installation; then
            setup_minio_user_dir
            show_post_install_info "$install_dir" "$HOME/minio-data"
            print_success "MinIO 安装成功！"
        else
            print_error "MinIO 安装验证失败"
            exit 1
        fi
    fi
}

# 执行主函数
main "$@"