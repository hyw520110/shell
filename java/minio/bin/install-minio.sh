#!/bin/bash

# MinIO 一键安装/卸载/管理脚本
# 支持主流 Linux 发行版和 macOS
# 支持多线程断点续传下载
# 包含服务管理功能
# 作者: Assistant
# 日期: 2025年12月5日

set -e  # 遇到错误时终止脚本执行

# 默认安装目录
DEFAULT_INSTALL_DIR="$HOME/minio"
# 默认数据目录（在安装目录下）
DEFAULT_DATA_DIR="$HOME/minio/data"
# 默认配置目录
DEFAULT_CONFIG_DIR="$HOME/.minio"
# 默认下载目录
DEFAULT_DOWNLOAD_DIR="$HOME/Downloads"
# 默认访问密钥和秘密密钥
DEFAULT_ACCESS_KEY="minioadmin"
DEFAULT_SECRET_KEY="minioadmin"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 全局变量
ACCESS_KEY="$DEFAULT_ACCESS_KEY"
SECRET_KEY="$DEFAULT_SECRET_KEY"

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

# 检查是否支持 adl、aria2c、wget 或 curl 下载工具
check_download_tool() {
    if command -v adl &> /dev/null && adl --help >/dev/null 2>&1; then
        DOWNLOAD_TOOL="adl"
        print_info "检测到 adl 工具，将优先使用 adl 下载"
        return 0
    elif command -v aria2c &> /dev/null; then
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
        print_error "系统中没有找到 adl、aria2c、wget 或 curl 工具，无法下载 MinIO"
        return 1
    fi
}

# 使用 adl 下载
download_with_adl() {
    local url=$1
    local output_dir=$2
    local filename=$3

    print_info "正在使用 adl 下载: $filename"
    mkdir -p "$output_dir"

    if adl "$url" "$output_dir" "$filename"; then
        print_success "下载成功: $filename"
        return 0
    fi

    print_error "adl 下载失败: $filename"
    return 1
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
    go install github.com/minio/minio@latest
    if [ $? -eq 0 ]; then
        print_success "MinIO 安装成功"
        return 0
    else
        print_error "MinIO 安装失败"
        return 1
    fi
}

# 统一下载函数
download_minio() {
    local url=$1
    local output_dir=$2
    local filename=$3

    print_info "检测到 ${DOWNLOAD_TOOL} 工具，将使用 $DOWNLOAD_TOOL 下载 minio"

    # 确保下载目录存在
    mkdir -p "$output_dir"

    case "$DOWNLOAD_TOOL" in
        "adl")
            download_with_adl "$url" "$output_dir" "$filename"
            ;;
        "aria2c")
            download_with_aria2c "$url" "$output_dir" "$filename"
            ;;
        "wget")
            download_with_wget "$url" "$output_dir" "$filename"
            ;;
        "curl")
            download_with_curl "$url" "$output_dir" "$filename"
            ;;
    esac
}

# 下载并安装 MinIO 二进制文件到指定目录
install_minio_binary() {
    local install_dir=${1:-$DEFAULT_INSTALL_DIR}
    local download_dir=${2:-$DEFAULT_DOWNLOAD_DIR}

    print_info "正在下载并安装 MinIO 二进制文件到: $install_dir"
    print_info "下载目录: $download_dir"

    # 确保安装目录存在
    [ ! -d "$install_dir" ] && mkdir -p "$install_dir"

    # 检查是否已存在可用的 minio 二进制文件，如果存在且可执行，跳过下载
    if [ -f "$install_dir/minio" ] && [ -x "$install_dir/minio" ]; then
        # 验证现有二进制文件是否正常
        if "$install_dir/minio" --version >/dev/null 2>&1; then
            print_info "MinIO 二进制文件已存在，跳过下载"

            # 立即更新当前会话的 PATH
            export PATH="$PATH:$install_dir"

            # 更新 PATH 环境变量（添加到 .bashrc 或 .zshrc）
            if [ -f "$HOME/.bashrc" ]; then
                if ! grep -q "$install_dir" "$HOME/.bashrc"; then
                    echo "export PATH=\"\$PATH:$install_dir\"" >> "$HOME/.bashrc"
                    print_info "已将 $install_dir 添加到 .bashrc"
                fi
            elif [ -f "$HOME/.zshrc" ]; then
                if ! grep -q "$install_dir" "$HOME/.zshrc"; then
                    echo "export PATH=\"\$PATH:$install_dir\"" >> "$HOME/.zshrc"
                    print_info "已将 $install_dir 添加到 .zshrc"
                fi
            elif [ -f "$HOME/.profile" ]; then
                if ! grep -q "$install_dir" "$HOME/.profile"; then
                    echo "export PATH=\"\$PATH:$install_dir\"" >> "$HOME/.profile"
                    print_info "已将 $install_dir 添加到 .profile"
                fi
            fi

            print_success "使用已存在的 MinIO 二进制文件: $install_dir/minio"
            return 0
        else
            print_warning "已存在的 MinIO 二进制文件不可用，将重新下载"
        fi
    fi

    # 为不同的系统构建下载 URL
    BINARY_URL="https://dl.min.io/server/minio/release/${OS}-${ARCH}/minio"
    BINARY_NAME="minio"

    # 检查下载工具
    if ! check_download_tool; then
        return 1
    fi

    # 直接下载到下载目录，避免临时目录
    if download_minio "$BINARY_URL" "$download_dir" "$BINARY_NAME"; then
        print_success "下载成功: $BINARY_NAME"
    else
        print_error "下载 MinIO 二进制文件失败"
        return 1
    fi

    # 检查下载是否成功
    local downloaded_file="$download_dir/$BINARY_NAME"
    if [ ! -f "$downloaded_file" ]; then
        print_error "下载 MinIO 二进制文件失败"
        return 1
    fi

    # 设置执行权限
    chmod +x "$downloaded_file"

    # 移动到指定安装目录
    mv "$downloaded_file" "$install_dir/"

    # 更新 PATH 环境变量（添加到 .bashrc 或 .zshrc）
    if [ -f "$HOME/.bashrc" ]; then
        if ! grep -q "$install_dir" "$HOME/.bashrc"; then
            echo "export PATH=\"\$PATH:$install_dir\"" >> "$HOME/.bashrc"
            print_info "已将 $install_dir 添加到 .bashrc"
        fi
    elif [ -f "$HOME/.zshrc" ]; then
        if ! grep -q "$install_dir" "$HOME/.zshrc"; then
            echo "export PATH=\"\$PATH:$install_dir\"" >> "$HOME/.zshrc"
            print_info "已将 $install_dir 添加到 .zshrc"
        fi
    elif [ -f "$HOME/.profile" ]; then
        if ! grep -q "$install_dir" "$HOME/.profile"; then
            echo "export PATH=\"\$PATH:$install_dir\"" >> "$HOME/.profile"
            print_info "已将 $install_dir 添加到 .profile"
        fi
    fi

    # 立即更新当前会话的 PATH
    export PATH="$PATH:$install_dir"

    print_success "MinIO 二进制文件安装成功到: $install_dir"
    return 0
}

# 使用 Go 安装 MinIO Client (mc)
install_mc_go() {
    print_info "正在使用 Go 安装 MinIO Client (mc)..."
    go install github.com/minio/mc@latest
    if [ $? -eq 0 ]; then
        print_success "MinIO Client (mc) 安装成功"
        return 0
    else
        print_error "MinIO Client (mc) 安装失败"
        return 1
    fi
}

# 下载并安装 MinIO Client (mc)
install_mc_binary() {
    local install_dir=${1:-$DEFAULT_INSTALL_DIR}
    local download_dir=${2:-$DEFAULT_DOWNLOAD_DIR}

    print_info "正在下载并安装 MinIO Client (mc) 到: $install_dir"
    print_info "下载目录: $download_dir"

    # 检查是否已存在可用的 mc 二进制文件，如果存在且可执行，跳过下载
    if [ -f "$install_dir/mc" ] && [ -x "$install_dir/mc" ]; then
        # 验证现有二进制文件是否正常
        if "$install_dir/mc" --version >/dev/null 2>&1; then
            print_info "MinIO Client (mc) 已存在，跳过下载"
            return 0
        else
            print_warning "已存在的 MinIO Client (mc) 不可用，将重新下载"
        fi
    fi

    # 为不同的系统构建下载 URL
    MC_BINARY_URL="https://dl.min.io/client/mc/release/${OS}-${ARCH}/mc"
    MC_BINARY_NAME="mc"

    # 检查下载工具
    if ! check_download_tool; then
        return 1
    fi

    # 直接下载到下载目录
    if download_minio "$MC_BINARY_URL" "$download_dir" "$MC_BINARY_NAME"; then
        print_success "下载成功: $MC_BINARY_NAME"
    else
        print_error "下载 MinIO Client (mc) 失败"
        return 1
    fi

    # 检查下载是否成功
    local downloaded_file="$download_dir/$MC_BINARY_NAME"
    if [ ! -f "$downloaded_file" ]; then
        print_error "下载 MinIO Client (mc) 失败"
        return 1
    fi

    # 设置执行权限
    chmod +x "$downloaded_file"

    # 移动到指定安装目录
    mv "$downloaded_file" "$install_dir/"

    print_success "MinIO Client (mc) 安装成功到: $install_dir"
    return 0
}

# 验证 MinIO 和 MinIO Client 是否安装成功
verify_installation() {
    local verification_success=true

    if command -v minio &> /dev/null; then
        MINIO_VERSION=$(minio --version 2>&1 | head -n 1)
        print_success "MinIO 安装验证成功: ${MINIO_VERSION}"
    else
        # 检查指定安装目录中的 minio 命令
        if [ -f "$DEFAULT_INSTALL_DIR/minio" ] && [ -x "$DEFAULT_INSTALL_DIR/minio" ]; then
            # 确保当前会话已添加安装目录到 PATH
            export PATH="$PATH:$DEFAULT_INSTALL_DIR"
            MINIO_VERSION=$("$DEFAULT_INSTALL_DIR/minio" --version 2>&1 | head -n 1)
            print_success "MinIO 安装验证成功: ${MINIO_VERSION}"
        else
            print_error "MinIO 命令不可用，请检查安装"
            verification_success=false
        fi
    fi

    # 验证 mc 安装
    if command -v mc &> /dev/null; then
        MC_VERSION=$(mc --version 2>&1 | head -n 1)
        print_success "MinIO Client (mc) 安装验证成功: ${MC_VERSION}"
    else
        # 检查指定安装目录中的 mc 命令
        if [ -f "$DEFAULT_INSTALL_DIR/mc" ] && [ -x "$DEFAULT_INSTALL_DIR/mc" ]; then
            MC_VERSION=$("$DEFAULT_INSTALL_DIR/mc" --version 2>&1 | head -n 1)
            print_success "MinIO Client (mc) 安装验证成功: ${MC_VERSION}"
        else
            print_warning "MinIO Client (mc) 命令不可用，安装可能未完成"
        fi
    fi

    if [ "$verification_success" = true ]; then
        return 0
    else
        return 1
    fi
}

# 创建 MinIO 用户目录和配置
setup_minio_user_dir() {
    local data_dir=${1:-"$DEFAULT_DATA_DIR"}
    local config_dir=${2:-"$DEFAULT_CONFIG_DIR"}

    # 创建 MinIO 配置目录
    if [ ! -d "$config_dir" ]; then
        mkdir -p "$config_dir"
        print_info "创建 MinIO 用户配置目录: $config_dir"
    fi

    # 创建默认数据目录
    if [ ! -d "$data_dir" ]; then
        mkdir -p "$data_dir"
        print_info "创建默认 MinIO 数据目录: $data_dir"
    fi

    print_success "MinIO 用户目录设置完成"
}

# 创建 systemd 服务文件
create_systemd_service() {
    local install_dir=${1:-$DEFAULT_INSTALL_DIR}
    local data_dir=${2:-$DEFAULT_DATA_DIR}

    # 检查是否在 Linux 系统上且有 systemd
    if [ "$OS" = "linux" ] && [ -d "/etc/systemd/system" ]; then
        SERVICE_FILE="/etc/systemd/system/minio.service"

        # 使用 sudo 创建服务文件（如果需要）
        if [ $EUID -ne 0 ]; then
            if command -v sudo &> /dev/null; then
                sudo tee "$SERVICE_FILE" > /dev/null << EOF
[Unit]
Description=MinIO
Documentation=https://min.io/docs/minio/linux/index.html
Wants=network-online.target
After=network-online.target
AssertFileIsExecutable=$install_dir/minio

[Service]
WorkingDirectory=$HOME
User=$USER
Group=$USER
ProtectProc=invisible
RemoveIPC=no
NoNewPrivileges=yes
Environment=MINIO_ROOT_USER=$ACCESS_KEY
Environment=MINIO_ROOT_PASSWORD=$SECRET_KEY
ExecStart=$install_dir/minio server --console-address :9001 $data_dir
ExecReload=/bin/kill -HUP \$MAINPID
TimeoutStopSec=30
KillMode=process
Restart=always
RestartSec=5
StartLimitInterval=0
StartLimitBurst=3

[Install]
WantedBy=multi-user.target
EOF
                print_info "创建 systemd 服务文件: $SERVICE_FILE"

                # 重新加载 systemd 配置
                sudo systemctl daemon-reload
                print_info "已重载 systemd 配置"
            else
                print_warning "当前用户不是 root，且系统中没有找到 sudo 命令，无法创建 systemd 服务文件"
                return 1
            fi
        else
            tee "$SERVICE_FILE" > /dev/null << EOF
[Unit]
Description=MinIO
Documentation=https://min.io/docs/minio/linux/index.html
Wants=network-online.target
After=network-online.target
AssertFileIsExecutable=$install_dir/minio

[Service]
WorkingDirectory=$HOME
User=$USER
Group=$USER
ProtectProc=invisible
RemoveIPC=no
NoNewPrivileges=yes
Environment=MINIO_ROOT_USER=$ACCESS_KEY
Environment=MINIO_ROOT_PASSWORD=$SECRET_KEY
ExecStart=$install_dir/minio server --console-address :9001 $data_dir
ExecReload=/bin/kill -HUP \$MAINPID
TimeoutStopSec=30
KillMode=process
Restart=always
RestartSec=5
StartLimitInterval=0
StartLimitBurst=3

[Install]
WantedBy=multi-user.target
EOF
            print_info "创建 systemd 服务文件: $SERVICE_FILE"

            # 重新加载 systemd 配置
            systemctl daemon-reload
            print_info "已重载 systemd 配置"
        fi

        print_success "systemd 服务文件创建成功"
        return 0
    else
        print_info "非 Linux 系统或不支持 systemd，跳过服务文件创建"
        return 0
    fi
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
    else
        print_info "没有正在运行的 MinIO 服务"
    fi
}

# 创建 MinIO 启动脚本
create_minio_start_script() {
    local install_dir=${1:-$DEFAULT_INSTALL_DIR}
    local data_dir=${2:-$DEFAULT_DATA_DIR}

    # 创建启动脚本
    cat > "$install_dir/minio-start.sh" << EOF
#!/bin/bash
# MinIO 启动脚本

# 设置默认环境变量
export MINIO_ROOT_USER=\${MINIO_ROOT_USER:-$ACCESS_KEY}
export MINIO_ROOT_PASSWORD=\${MINIO_ROOT_PASSWORD:-$SECRET_KEY}

# 启动 MinIO 服务器
$install_dir/minio server --console-address :9001 $data_dir
EOF

    chmod +x "$install_dir/minio-start.sh"
    print_info "创建 MinIO 启动脚本: $install_dir/minio-start.sh"
}

# 启动 MinIO 服务
start_minio_service() {
    local data_dir=${1:-$DEFAULT_DATA_DIR}

    # 检查是否已有运行的 MinIO 服务
    if check_minio_running; then
        print_info "MinIO 服务已在运行，无需重复启动"
        return 0
    fi

    print_info "正在启动 MinIO 服务..."

    # 导入环境变量，优先使用命令行参数指定的值
    export MINIO_ROOT_USER=${MINIO_ROOT_USER:-$ACCESS_KEY}
    export MINIO_ROOT_PASSWORD=${MINIO_ROOT_PASSWORD:-$SECRET_KEY}

    # 启动 MinIO 服务器
    nohup "$DEFAULT_INSTALL_DIR/minio" server --console-address :9001 "$data_dir" > /tmp/minio.log 2>&1 &

    # 等待几秒钟让服务器启动
    sleep 3

    # 检查 MinIO 是否成功启动
    if check_minio_running; then
        print_success "MinIO 服务启动成功"

        # 检查端口是否开放
        if nc -z 127.0.0.1 9001 2>/dev/null; then
            print_success "MinIO 控制台端口 (9001) 已开放"
        else
            print_warning "MinIO 控制台端口 (9001) 未开放，可能还在启动中..."
        fi

        if nc -z 127.0.0.1 9000 2>/dev/null; then
            print_success "MinIO API 端口 (9000) 已开放"
        else
            print_warning "MinIO API 端口 (9000) 未开放，可能还在启动中..."
        fi
        return 0
    else
        print_error "MinIO 服务启动失败"
        return 1
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

    # 尝试删除 systemd 服务文件
    if [ -f "/etc/systemd/system/minio.service" ]; then
        read -p "是否要删除 MinIO systemd 服务文件? [y/N]: " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            SUDO_CMD=""
            if [ $EUID -ne 0 ]; then
                if command -v sudo &> /dev/null; then
                    SUDO_CMD="sudo"
                else
                    print_error "当前用户不是 root，且系统中没有找到 sudo 命令，无法删除 systemd 服务文件"
                    return 1
                fi
            fi

            $SUDO_CMD rm -f /etc/systemd/system/minio.service
            $SUDO_CMD systemctl daemon-reload
            print_info "已删除 MinIO systemd 服务文件并重载配置"
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
    if [ -d "$DEFAULT_CONFIG_DIR" ]; then
        read -p "是否要删除 MinIO 配置目录 ($DEFAULT_CONFIG_DIR)? [y/N]: " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            rm -rf "$DEFAULT_CONFIG_DIR"
            print_info "已删除 MinIO 配置目录"
        fi
    fi

    # 询问是否删除数据目录
    if [ -d "$DEFAULT_DATA_DIR" ]; then
        read -p "是否要删除 MinIO 数据目录 ($DEFAULT_DATA_DIR)? [y/N]: " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            rm -rf "$DEFAULT_DATA_DIR"
            print_info "已删除 MinIO 数据目录"
        else
            print_info "MinIO 数据目录 ($DEFAULT_DATA_DIR) 已保留"
        fi
    fi

    print_success "MinIO 卸载完成"
    return 0
}

# 显示安装后说明
show_post_install_info() {
    local install_dir=${1:-$DEFAULT_INSTALL_DIR}
    local data_dir=${2:-$DEFAULT_DATA_DIR}

    cat << EOF

=======================================================
              MinIO 安装完成
=======================================================
安装目录: $install_dir
数据目录: $data_dir
配置目录: $DEFAULT_CONFIG_DIR

启动 MinIO 服务器:
    $install_dir/minio server $data_dir

使用启动脚本:
    $install_dir/minio-start.sh

启动 MinIO 服务（后台运行）:
    $0 start

使用示例:
    $install_dir/minio server $data_dir --console-address :9001

登录凭据:
    用户名: $ACCESS_KEY
    密码: $SECRET_KEY

访问控制台:
    打开浏览器访问 http://127.0.0.1:9001
访问 API:
    http://127.0.0.1:9000

使用 MinIO 客户端 (mc):
    mc alias set myminio http://127.0.0.1:9000 $ACCESS_KEY $SECRET_KEY
    $install_dir/mc alias set myminio http://127.0.0.1:9000 $ACCESS_KEY $SECRET_KEY
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
  -s, --start           启动 MinIO 服务
  -t, --stop            停止 MinIO 服务
  -r, --restart         重启 MinIO 服务
  -d, --install-dir DIR 指定 MinIO 安装目录 (默认: $DEFAULT_INSTALL_DIR)
  -w, --download-dir DIR 指定下载目录 (默认: $DEFAULT_DOWNLOAD_DIR)
  -a, --access-key KEY  指定 MinIO 访问密钥 (默认: $DEFAULT_ACCESS_KEY)
  -k, --secret-key KEY  指定 MinIO 秘密密钥 (默认: $DEFAULT_SECRET_KEY)
  -h, --help            显示此帮助信息

示例:
  $0                    # 安装 MinIO 到默认目录
  $0 --install          # 安装 MinIO
  $0 --uninstall        # 卸载 MinIO
  $0 --start            # 启动 MinIO 服务
  $0 --stop             # 停止 MinIO 服务
  $0 --restart          # 重启 MinIO 服务
  $0 -d /path/to/minio  # 安装 MinIO 到指定目录
  $0 -w /path/to/download  # 指定下载目录
  $0 -a myaccesskey -k mysecretkey  # 指定自定义访问密钥和秘密密钥
EOF
}

# 解析命令行参数
parse_arguments() {
    local action="install"  # 默认是安装
    local install_dir="$DEFAULT_INSTALL_DIR"
    local download_dir="$DEFAULT_DOWNLOAD_DIR"

    # 检查是否有参数
    if [ $# -eq 0 ]; then
        echo "$action $install_dir $download_dir"
        return
    fi

    # 处理参数列表
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
            -s|--start)
                action="start"
                shift
                ;;
            -t|--stop)
                action="stop"
                shift
                ;;
            -r|--restart)
                action="restart"
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
            -a|--access-key)
                ACCESS_KEY="$2"
                shift 2
                ;;
            -k|--secret-key)
                SECRET_KEY="$2"
                shift 2
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            start|stop|restart|uninstall)  # 支持无标志操作
                action="$1"
                shift
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

# 显示启动说明
show_start_info() {
    cat << EOF

=======================================================
              MinIO 启动说明
=======================================================
MinIO 服务器已启动，请使用以下信息访问：

访问控制台:
    打开浏览器访问 http://127.0.0.1:9001
访问 API:
    http://127.0.0.1:9000

登录凭据:
    用户名: $ACCESS_KEY
    密码: $SECRET_KEY
=======================================================
EOF
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

    case $action in
        "uninstall")
            uninstall_minio
            ;;
        "start")
            # 为启动操作设置正确的路径
            if [ ! -f "$install_dir/minio" ] || [ ! -x "$install_dir/minio" ]; then
                print_error "MinIO 二进制文件不存在于 $install_dir"
                exit 1
            fi
            start_minio_service "$DEFAULT_DATA_DIR"
            show_start_info
            ;;
        "stop")
            stop_minio_service
            ;;
        "restart")
            stop_minio_service
            sleep 2
            start_minio_service "$DEFAULT_DATA_DIR"
            show_start_info
            ;;
        *)
            print_info "开始安装 MinIO..."

            # 检测 Go 环境一次
            GO_AVAILABLE=false
            if check_go; then
                GO_AVAILABLE=true
            fi

            # 尝试使用 Go 安装 MinIO
            if [ "$GO_AVAILABLE" = true ]; then
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
            else
                # 如果没有 Go 环境，尝试使用二进制文件方式
                print_warning "未检测到 Go 环境，请先安装 Go 1.24 或更高版本"
                print_warning "尝试下载二进制文件..."
                if install_minio_binary "$install_dir" "$download_dir"; then
                    print_success "MinIO 安装完成"
                else
                    print_error "MinIO 安装失败"
                    exit 1
                fi
            fi

            # 安装 MinIO Client (mc)
            print_info "正在安装 MinIO Client (mc)..."
            if [ "$GO_AVAILABLE" = true ]; then
                if install_mc_go; then
                    print_success "MinIO Client (mc) Go 安装完成"
                else
                    # 如果 Go 安装失败，尝试使用二进制文件方式
                    print_warning "Go 安装方式失败，尝试下载 mc 二进制文件..."
                    if install_mc_binary "$install_dir" "$download_dir"; then
                        print_success "MinIO Client (mc) 安装完成"
                    else
                        print_warning "MinIO Client (mc) 安装失败，但不影响 MinIO 使用"
                    fi
                fi
            else
                # 如果没有 Go 环境，尝试使用二进制文件方式
                print_warning "尝试下载 mc 二进制文件..."
                if install_mc_binary "$install_dir" "$download_dir"; then
                    print_success "MinIO Client (mc) 安装完成"
                else
                    print_warning "MinIO Client (mc) 安装失败，但不影响 MinIO 使用"
                fi
            fi

            if verify_installation; then
                setup_minio_user_dir "$DEFAULT_DATA_DIR" "$DEFAULT_CONFIG_DIR"
                create_minio_start_script "$install_dir" "$DEFAULT_DATA_DIR"
                create_systemd_service "$install_dir" "$DEFAULT_DATA_DIR"
                show_post_install_info "$install_dir" "$DEFAULT_DATA_DIR"

                # 安装完成后自动启动 MinIO 服务
                print_info "正在启动 MinIO 服务..."
                if start_minio_service "$DEFAULT_DATA_DIR"; then
                    show_start_info
                else
                    print_warning "MinIO 服务启动失败，请检查日志"
                fi

                print_success "MinIO 安装成功！"
            else
                print_error "MinIO 安装验证失败"
                exit 1
            fi
            ;;
    esac
}

# 执行主函数
main "$@"
