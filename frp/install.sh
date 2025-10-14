#!/bin/bash

# 定义公共变量
FRP_VERSION="0.63.0"
FRP_DOWNLOAD_URL="https://github.com/fatedier/frp/releases/download/v${FRP_VERSION}/frp_${FRP_VERSION}_linux_amd64.tar.gz"
# 若安装目录不是当前目录，则拷贝当前目录下所有文件到安装目录
SCRIPT_DIR=$(dirname "$(readlink -f "$0")")
DEFAULT_INSTALL_DIR="$HOME/frp"
FRPS_NAME="frps"
FRPS_CONF_NAME="${FRPS_NAME}.toml"
FRPC_NAME="frpc"
FRPC_CONF_NAME="${FRPC_NAME}.toml"
SERVICE_DIR="/usr/lib/systemd/system"
FRPS_SERVICE_FILE="$SERVICE_DIR/${FRPS_NAME}.service"
FRPC_SERVICE_FILE="$SERVICE_DIR/${FRPC_NAME}.service"
LOG_FILE="/var/log/frp.log"

# 帮助信息函数
show_help() {
    echo "FRP 安装脚本"
    echo "用法: $0 [选项] [安装目录]"
    echo ""
    echo "选项:"
    echo "  -h, --help     显示此帮助信息"
    echo "  -s             安装服务端 (frps)"
    echo "  -c             安装客户端 (frpc)"
    echo "  -d [目录]       指定安装目录 (默认: $HOME/frp)"
    echo "  -u, --uninstall 执行卸载操作"
    echo ""
    echo "参数:"
    echo "  [安装目录]      指定 FRP 的安装目录 (向后兼容，但优先级低于 -d 参数)"
    echo ""
    echo "示例:"
    echo "  $0                    # 交互式安装 (服务端或客户端)"
    echo "  $0 -s                 # 直接安装服务端"
    echo "  $0 -c                 # 直接安装客户端"
    echo "  $0 -d /custom/path    # 指定安装目录"
    echo "  $0 /custom/path       # 指定安装目录 (向后兼容)"
    echo "  $0 -s -d /custom/path # 安装服务端到指定目录"
    echo "  $0 -u                 # 卸载 FRP"
    exit 0
}

# 卸载 FRP
uninstall_frps() {
    echo "正在卸载 frps..."
    
    # 停止服务
    if systemctl is-active --quiet "${FRPS_NAME}.service"; then
        echo "正在停止 frps 服务..."
        if [ "$USE_SUDO" = true ]; then
            sudo systemctl stop "${FRPS_NAME}.service"
        else
            systemctl stop "${FRPS_NAME}.service"
        fi
    fi
    
    # 禁用服务
    if [ "$USE_SUDO" = true ]; then
        sudo systemctl disable "${FRPS_NAME}.service" 2>/dev/null
        sudo rm -f "${FRPS_SERVICE_FILE}" 2>/dev/null
    else
        systemctl disable "${FRPS_NAME}.service" 2>/dev/null
        rm -f "${FRPS_SERVICE_FILE}" 2>/dev/null
    fi
    
    # 删除相关文件
    local install_path=$(systemctl show -p FragmentPath "${FRPS_NAME}.service" 2>/dev/null | cut -d'=' -f2)
    if [ -n "$install_path" ] && [ -f "$install_path" ]; then
        install_path=$(dirname "$install_path")
        sudo rm -rf "$install_path/${FRPS_NAME}"* 2>/dev/null
    fi
    
    # 尝试从默认目录删除
    sudo rm -rf "$DEFAULT_INSTALL_DIR/${FRPS_NAME}"* 2>/dev/null
    
    echo "frps 卸载完成。"
}

uninstall_frpc() {
    echo "正在卸载 frpc..."
    
    # 停止服务
    if systemctl is-active --quiet "${FRPC_NAME}.service"; then
        echo "正在停止 frpc 服务..."
        if [ "$USE_SUDO" = true ]; then
            sudo systemctl stop "${FRPC_NAME}.service"
        else
            systemctl stop "${FRPC_NAME}.service"
        fi
    fi
    
    # 禁用服务
    if [ "$USE_SUDO" = true ]; then
        sudo systemctl disable "${FRPC_NAME}.service" 2>/dev/null
        sudo rm -f "${FRPC_SERVICE_FILE}" 2>/dev/null
    else
        systemctl disable "${FRPC_NAME}.service" 2>/dev/null
        rm -f "${FRPC_SERVICE_FILE}" 2>/dev/null
    fi
    
    # 删除相关文件
    local install_path=$(systemctl show -p FragmentPath "${FRPC_NAME}.service" 2>/dev/null | cut -d'=' -f2)
    if [ -n "$install_path" ] && [ -f "$install_path" ]; then
        install_path=$(dirname "$install_path")
        sudo rm -rf "$install_path/${FRPC_NAME}"* 2>/dev/null
    fi
    
    # 尝试从默认目录删除
    sudo rm -rf "$DEFAULT_INSTALL_DIR/${FRPC_NAME}"* 2>/dev/null
    
    echo "frpc 卸载完成。"
}

# 执行完整卸载
uninstall_all() {
    uninstall_frps
    uninstall_frpc
    
    # 停止任何可能正在运行的进程
    sudo pkill -f frps 2>/dev/null
    sudo pkill -f frpc 2>/dev/null
    
    # 删除日志文件
    sudo rm -f "$LOG_FILE" 2>/dev/null
    echo "卸载完成。"
}

# 初始化变量
USE_SUDO=false
UNINSTALL_MODE=""

# 解析命令行参数
INSTALL_MODE=""
CUSTOM_INSTALL_DIR=""
POSITIONAL_ARGS=()
while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            show_help
            ;;
        -s)
            INSTALL_MODE="s"
            shift
            ;;
        -c)
            INSTALL_MODE="c"
            shift
            ;;
        -u|--uninstall)
            UNINSTALL_MODE="true"
            shift
            ;;
        -d)
            CUSTOM_INSTALL_DIR="$2"
            if [ -z "$CUSTOM_INSTALL_DIR" ]; then
                echo "错误: -d 参数需要指定目录路径"
                echo "使用 -h 或 --help 查看帮助信息"
                exit 1
            fi
            shift 2
            ;;
        -*)
            echo "未知参数: $1"
            echo "使用 -h 或 --help 查看帮助信息"
            exit 1
            ;;
        *)
            POSITIONAL_ARGS+=("$1")
            shift
            ;;
    esac
done
set -- "${POSITIONAL_ARGS[@]}"

# 确定安装目录
if [ -n "$CUSTOM_INSTALL_DIR" ]; then
    INSTALL_DIR="$CUSTOM_INSTALL_DIR"
elif [ $# -gt 0 ]; then
    INSTALL_DIR="$1"
else
    INSTALL_DIR="$DEFAULT_INSTALL_DIR"
fi

# 如果是卸载模式，直接执行卸载
if [ "$UNINSTALL_MODE" = "true" ]; then
    uninstall_all
    exit 0
fi


# 检查安装目录权限
if [ ! -d "$INSTALL_DIR" ]; then
    # 目录不存在，尝试创建
    if ! mkdir -p "$INSTALL_DIR" 2>/dev/null; then
        echo "错误: 没有权限创建目录 $INSTALL_DIR"
        read -p "是否使用用户目录 $HOME/frp? (Y/n) " USE_HOME_DIR
        USE_HOME_DIR=${USE_HOME_DIR:-y}
        
        if [[ $USE_HOME_DIR =~ ^[Yy]$ ]]; then
            INSTALL_DIR="$HOME/frp"
            echo "安装目录更改为: $INSTALL_DIR"
            mkdir -p "$INSTALL_DIR"
        else
            echo "正在使用sudo权限创建目录..."
            sudo mkdir -p "$INSTALL_DIR"
            USE_SUDO=true
        fi
    fi
else
    # 目录已存在，检查是否有写权限
    if [ ! -w "$INSTALL_DIR" ]; then
        echo "错误: 没有写权限访问目录 $INSTALL_DIR"
        read -p "是否使用用户目录 $HOME/frp? (Y/n) " USE_HOME_DIR
        USE_HOME_DIR=${USE_HOME_DIR:-y}
        
        if [[ $USE_HOME_DIR =~ ^[Yy]$ ]]; then
            INSTALL_DIR="$HOME/frp"
            echo "安装目录更改为: $INSTALL_DIR"
        else
            echo "正在使用sudo权限..."
            USE_SUDO=true
        fi
    fi
fi

if [ "$INSTALL_DIR" != "$SCRIPT_DIR" ]; then
    echo "安装目录为: $INSTALL_DIR"
    if [ "$USE_SUDO" = true ]; then
        sudo cp -r "$SCRIPT_DIR"/* "$INSTALL_DIR"/
        # 设置脚本执行权限
        sudo chmod +x "$INSTALL_DIR/startup.sh" 2>/dev/null || true
        sudo chmod +x "$INSTALL_DIR/stop.sh" 2>/dev/null || true
        sudo chmod +x "$INSTALL_DIR/install.sh" 2>/dev/null || true
    else
        cp -r "$SCRIPT_DIR"/* "$INSTALL_DIR"/
        # 设置脚本执行权限
        chmod +x "$INSTALL_DIR/startup.sh" 2>/dev/null || true
        chmod +x "$INSTALL_DIR/stop.sh" 2>/dev/null || true
        chmod +x "$INSTALL_DIR/install.sh" 2>/dev/null || true
    fi
    SCRIPT_DIR="$INSTALL_DIR"
    cd $INSTALL_DIR
else
    # 即使SCRIPT_DIR等于INSTALL_DIR，仍然确保脚本有执行权限
    if [ "$USE_SUDO" = true ]; then
        sudo chmod +x "$INSTALL_DIR/startup.sh" 2>/dev/null || true
        sudo chmod +x "$INSTALL_DIR/stop.sh" 2>/dev/null || true
        sudo chmod +x "$INSTALL_DIR/install.sh" 2>/dev/null || true
    else
        chmod +x "$INSTALL_DIR/startup.sh" 2>/dev/null || true
        chmod +x "$INSTALL_DIR/stop.sh" 2>/dev/null || true
        chmod +x "$INSTALL_DIR/install.sh" 2>/dev/null || true
    fi
fi

# 检查并安装必要工具
check_dependencies() {
    if ! command -v wget &> /dev/null; then
        echo "wget 未安装，正在安装..."
        if [ "$USE_SUDO" = true ]; then
            sudo yum install -y wget || sudo apt-get install -y wget
        else
            sudo yum install -y wget || sudo apt-get install -y wget
        fi
    fi
}

# 复制或下载 frp 二进制文件
copy_or_download_frps() {
    local source_dir=$1
    if [ -n "$source_dir" ] && [ -f "$source_dir/frps" ]; then
        echo "发现现有 frps 二进制文件，正在复制..."
        if [ "$USE_SUDO" = true ]; then
            sudo cp "$source_dir/frps" "${INSTALL_DIR}/"
        else
            cp "$source_dir/frps" "${INSTALL_DIR}/"
        fi
        echo "frps 已从 $source_dir 复制到 ${INSTALL_DIR}"
    else
        echo "正在下载 frps..."
        if [ "$USE_SUDO" = true ]; then
            wget -O - "${FRP_DOWNLOAD_URL}" | sudo tar -zx --strip-components=1 -C "${INSTALL_DIR}" "frp_${FRP_VERSION}_linux_amd64/${FRP_BIN_NAME}" "frp_${FRP_VERSION}_linux_amd64/${FRPS_CONF_NAME}"
        else
            wget -O - "${FRP_DOWNLOAD_URL}" | tar -zx --strip-components=1 -C "${INSTALL_DIR}" "frp_${FRP_VERSION}_linux_amd64/${FRP_BIN_NAME}" "frp_${FRP_VERSION}_linux_amd64/${FRPS_CONF_NAME}"
        fi
        if [ $? -ne 0 ]; then
            echo "下载并解压 frps 失败。"
            exit 1
        fi
    fi
}

copy_or_download_frpc() {
    local source_dir=$1
    if [ -n "$source_dir" ] && [ -f "$source_dir/frpc" ]; then
        echo "发现现有 frpc 二进制文件，正在复制..."
        if [ "$USE_SUDO" = true ]; then
            sudo cp "$source_dir/frpc" "${INSTALL_DIR}/"
        else
            cp "$source_dir/frpc" "${INSTALL_DIR}/"
        fi
        echo "frpc 已从 $source_dir 复制到 ${INSTALL_DIR}"
    else
        echo "正在下载 frpc..."
        if [ "$USE_SUDO" = true ]; then
            wget -O - "${FRP_DOWNLOAD_URL}" | sudo tar -zx --strip-components=1 -C "${INSTALL_DIR}" "frp_${FRP_VERSION}_linux_amd64/${FRPC_NAME}" "frp_${FRP_VERSION}_linux_amd64/${FRPC_CONF_NAME}"
        else
            wget -O - "${FRP_DOWNLOAD_URL}" | tar -zx --strip-components=1 -C "${INSTALL_DIR}" "frp_${FRP_VERSION}_linux_amd64/${FRPC_NAME}" "frp_${FRP_VERSION}_linux_amd64/${FRPC_CONF_NAME}"
        fi
        if [ $? -ne 0 ]; then
            echo "下载并解压 frpc 失败。"
            exit 1
        fi
    fi
}

# 生成8位随机字符串
generate_random_string() {
    tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c 8
}

# 生成frps 配置文件
generate_default_config() {
    AUTH_TOKEN=$(generate_random_string)
    echo "生成的 auth.token: ${AUTH_TOKEN}"

    read -p "是否需要启用 dashboard？(Y/n) " DASHBOARD_CHOICE
    DASHBOARD_CHOICE=${DASHBOARD_CHOICE:-y}
    #bandwidth_limit=1MB
    
    if [ "$USE_SUDO" = true ]; then
        echo 'bindAddr = "0.0.0.0"' | sudo tee "${INSTALL_DIR}/${FRPS_CONF_NAME}" > /dev/null
        echo 'bindPort=7000' | sudo tee -a "${INSTALL_DIR}/${FRPS_CONF_NAME}" > /dev/null
        echo 'auth.method = "token"' | sudo tee -a "${INSTALL_DIR}/${FRPS_CONF_NAME}" > /dev/null
        echo "auth.token=\"${AUTH_TOKEN}\"" | sudo tee -a "${INSTALL_DIR}/${FRPS_CONF_NAME}" > /dev/null
        echo 'vhostHTTPPort=7800' | sudo tee -a "${INSTALL_DIR}/${FRPS_CONF_NAME}" > /dev/null
        echo 'vhostHTTPSPort=7443' | sudo tee -a "${INSTALL_DIR}/${FRPS_CONF_NAME}" > /dev/null
        echo 'webServer.addr="0.0.0.0"' | sudo tee -a "${INSTALL_DIR}/${FRPS_CONF_NAME}" > /dev/null
        echo 'webServer.port=7500' | sudo tee -a "${INSTALL_DIR}/${FRPS_CONF_NAME}" > /dev/null
        echo "log.to=\"${LOG_FILE}\"" | sudo tee -a "${INSTALL_DIR}/${FRPS_CONF_NAME}" > /dev/null
        echo 'log.level="info"' | sudo tee -a "${INSTALL_DIR}/${FRPS_CONF_NAME}" > /dev/null
        echo 'log.maxDays=30' | sudo tee -a "${INSTALL_DIR}/${FRPS_CONF_NAME}" > /dev/null
    else
        cat > "${INSTALL_DIR}/${FRPS_CONF_NAME}" << EOF
bindAddr = "0.0.0.0"
bindPort=7000
auth.method = "token"
auth.token="${AUTH_TOKEN}"
vhostHTTPPort=7800
vhostHTTPSPort=7443
webServer.addr="0.0.0.0"
webServer.port=7500
log.to="${LOG_FILE}"
log.level="info"
log.maxDays=30
EOF
    fi
    
    if [[ $DASHBOARD_CHOICE =~ ^[Yy]$ ]]; then
        WEB_SERVER_PASSWORD=$(generate_random_string)
        echo "生成的 webServer.password: ${WEB_SERVER_PASSWORD}"
        if [ "$USE_SUDO" = true ]; then
            echo "webServer.user=\"webuser\"" | sudo tee -a "${INSTALL_DIR}/${FRPS_CONF_NAME}" > /dev/null
            echo "webServer.password=\"${WEB_SERVER_PASSWORD}\"" | sudo tee -a "${INSTALL_DIR}/${FRPS_CONF_NAME}" > /dev/null
        else
            cat >> "${INSTALL_DIR}/${FRPS_CONF_NAME}" << EOF
webServer.user="webuser"
webServer.password="${WEB_SERVER_PASSWORD}"
EOF
        fi
    fi

    if [ $? -ne 0 ]; then
        echo "生成${FRPS_CONF_NAME}配置文件失败。"
        exit 1
    fi
}
# 获取当前IP地址
function get_current_ip() {
    local ip_tool=$(command -v ip)  # 检查ip工具是否存在
    local ifconfig_tool=$(command -v ifconfig)  # 检查ifconfig工具是否存在

    if [ -n "$ip_tool" ]; then
        # 使用ip工具获取IP地址
        ip_addr=$($ip_tool addr show up | grep inet | grep -Ev "inet6|127|172" | grep -v "\.250\." | awk '{print $2}' | awk -F'/' '{print $1}')
    elif [ -n "$ifconfig_tool" ]; then
        # 使用ifconfig工具获取IP地址
        ip_addr=$($ifconfig_tool -a | grep inet | grep -v 127.0.0.1 | grep -v "\.250\." | grep -v inet6 | awk '{print $2}')
    else
        echo "ip或ifconfig命令未找到."
        return 1
    fi

    echo "$ip_addr"
}
# 生成默认的 frpc 配置文件
generate_default_client_config() {
    read -p "请输入 frps 服务端的 IP 地址: " SERVER_IP
    read -p "请输入 frps 服务端的端口号 (默认 7000): " SERVER_PORT
    SERVER_PORT=${SERVER_PORT:-7000}

    read -p "请输入frps服务端的认证 token: " SERVER_TOKEN

    # 获取当前主机的 IP 地址
    CURRENT_IP=$(hostname -I | awk '{print $1}')
    TUNNEL_NAME="ssh$(echo ${CURRENT_IP} | tr '.' '-')"

    # 从 sshd 配置文件中提取端口号
    sshd_port=$(grep -oP 'Port \K\d+' /etc/ssh/sshd_config | head -n 1)
    if [ -z "$SSHD_PORT" ]; then
        sshd_port=22
    fi

    # 检测端口号是否已启动
    if ! netstat -tuln | grep -q ":${sshd_port}"; then
        echo "警告: 端口 ${sshd_port} 未启动，开启 sshd 服务。"
    fi
    local_ip=$(get_current_ip)
    #transport.useEncryption=true
    #transport.useCompression=true
    
    if [ "$USE_SUDO" = true ]; then
        echo "serverAddr=\"${SERVER_IP}\"" | sudo tee "${INSTALL_DIR}/${FRPC_CONF_NAME}" > /dev/null
        echo "serverPort=${SERVER_PORT}" | sudo tee -a "${INSTALL_DIR}/${FRPC_CONF_NAME}" > /dev/null
        echo 'auth.method = "token"' | sudo tee -a "${INSTALL_DIR}/${FRPC_CONF_NAME}" > /dev/null
        echo "auth.token=\"${SERVER_TOKEN}\"" | sudo tee -a "${INSTALL_DIR}/${FRPC_CONF_NAME}" > /dev/null
        echo "log.to=\"${LOG_FILE}\"" | sudo tee -a "${INSTALL_DIR}/${FRPC_CONF_NAME}" > /dev/null
        echo 'log.level="info"' | sudo tee -a "${INSTALL_DIR}/${FRPC_CONF_NAME}" > /dev/null
        echo 'log.maxDays=30' | sudo tee -a "${INSTALL_DIR}/${FRPC_CONF_NAME}" > /dev/null
        echo "[[proxies]]" | sudo tee -a "${INSTALL_DIR}/${FRPC_CONF_NAME}" > /dev/null
        echo "name=\"${TUNNEL_NAME}\"" | sudo tee -a "${INSTALL_DIR}/${FRPC_CONF_NAME}" > /dev/null
        echo 'type="tcp"' | sudo tee -a "${INSTALL_DIR}/${FRPC_CONF_NAME}" > /dev/null
        echo "localIP=\"${local_ip}\"" | sudo tee -a "${INSTALL_DIR}/${FRPC_CONF_NAME}" > /dev/null
        echo "localPort=${sshd_port}" | sudo tee -a "${INSTALL_DIR}/${FRPC_CONF_NAME}" > /dev/null
        echo "remotePort=6000" | sudo tee -a "${INSTALL_DIR}/${FRPC_CONF_NAME}" > /dev/null
    else
        cat > "${INSTALL_DIR}/${FRPC_CONF_NAME}" << EOF
serverAddr="${SERVER_IP}"
serverPort=${SERVER_PORT}
auth.method = "token"
auth.token="${SERVER_TOKEN}"
log.to="${LOG_FILE}"
log.level="info"
log.maxDays=30
[[proxies]]
name="${TUNNEL_NAME}"
type="tcp"
localIP="${local_ip}"
localPort=${sshd_port}
remotePort=6000
EOF
    fi
    
    if [ $? -ne 0 ]; then
        echo "生成${FRPC_CONF_NAME}配置文件失败。"
        exit 1
    fi
}

# 创建 Systemd 服务文件
create_systemd_service() {
    if systemctl list-unit-files | grep -q "${FRPS_NAME}.service"; then
        # 系统服务文件操作始终需要sudo权限
        sudo systemctl disable "${FRPS_NAME}.service" 2>/dev/null
        sudo rm -f "${FRPS_SERVICE_FILE}" 2>/dev/null
    fi
    
    # 系统服务文件始终需要sudo权限写入
    echo "[Unit]" | sudo tee "${FRPS_SERVICE_FILE}" > /dev/null
    echo "Description=frps daemon" | sudo tee -a "${FRPS_SERVICE_FILE}" > /dev/null
    echo "After = network.target syslog.target" | sudo tee -a "${FRPS_SERVICE_FILE}" > /dev/null
    echo "Wants = network.target" | sudo tee -a "${FRPS_SERVICE_FILE}" > /dev/null
    echo "" | sudo tee -a "${FRPS_SERVICE_FILE}" > /dev/null
    echo "[Service]" | sudo tee -a "${FRPS_SERVICE_FILE}" > /dev/null
    echo "Type=simple" | sudo tee -a "${FRPS_SERVICE_FILE}" > /dev/null
    echo "ExecStart=${INSTALL_DIR}/startup.sh frps" | sudo tee -a "${FRPS_SERVICE_FILE}" > /dev/null
    echo "ExecStop=${INSTALL_DIR}/stop.sh" | sudo tee -a "${FRPS_SERVICE_FILE}" > /dev/null
    echo "WorkingDirectory=${INSTALL_DIR}" | sudo tee -a "${FRPS_SERVICE_FILE}" > /dev/null
    echo "Restart=on-failure" | sudo tee -a "${FRPS_SERVICE_FILE}" > /dev/null
    echo "" | sudo tee -a "${FRPS_SERVICE_FILE}" > /dev/null
    echo "[Install]" | sudo tee -a "${FRPS_SERVICE_FILE}" > /dev/null
    echo "WantedBy=multi-user.target" | sudo tee -a "${FRPS_SERVICE_FILE}" > /dev/null
    
    if [ $? -ne 0 ]; then
        echo "创建 Systemd 服务文件失败。"
        exit 1
    fi
    
    sudo systemctl daemon-reload
}

create_systemd_client_service() {
    if systemctl list-unit-files | grep -q "${FRPC_NAME}.service"; then
        sudo systemctl disable "${FRPC_NAME}.service" 2>/dev/null
        sudo rm -f "${FRPC_SERVICE_FILE}" 2>/dev/null
    fi
    
    # 系统服务文件始终需要sudo权限写入
    echo "[Unit]" | sudo tee "${FRPC_SERVICE_FILE}" > /dev/null
    echo "Description=frpc client" | sudo tee -a "${FRPC_SERVICE_FILE}" > /dev/null
    echo "After = network.target syslog.target" | sudo tee -a "${FRPC_SERVICE_FILE}" > /dev/null
    echo "Wants = network.target" | sudo tee -a "${FRPC_SERVICE_FILE}" > /dev/null
    echo "" | sudo tee -a "${FRPC_SERVICE_FILE}" > /dev/null
    echo "[Service]" | sudo tee -a "${FRPC_SERVICE_FILE}" > /dev/null
    echo "Type=simple" | sudo tee -a "${FRPC_SERVICE_FILE}" > /dev/null
    echo "ExecStart=${INSTALL_DIR}/startup.sh frpc" | sudo tee -a "${FRPC_SERVICE_FILE}" > /dev/null
    echo "ExecStop=${INSTALL_DIR}/stop.sh" | sudo tee -a "${FRPC_SERVICE_FILE}" > /dev/null
    echo "WorkingDirectory=${INSTALL_DIR}" | sudo tee -a "${FRPC_SERVICE_FILE}" > /dev/null
    echo "Restart=on-failure" | sudo tee -a "${FRPC_SERVICE_FILE}" > /dev/null
    echo "" | sudo tee -a "${FRPC_SERVICE_FILE}" > /dev/null
    echo "[Install]" | sudo tee -a "${FRPC_SERVICE_FILE}" > /dev/null
    echo "WantedBy=multi-user.target" | sudo tee -a "${FRPC_SERVICE_FILE}" > /dev/null
    
    if [ $? -ne 0 ]; then
        echo "创建 Systemd 服务文件失败。"
        exit 1
    fi
    
    sudo systemctl daemon-reload
}
# 检测防火墙类型并自动开放端口（仅在防火墙服务处于 active 时操作）
# 使用方法：setup_firewall_ports "7000/tcp" "7800/tcp" "22/tcp"
setup_firewall_ports() {
    echo "正在检测系统防火墙状态..."

    # 检查是否传入了端口
    if [ $# -eq 0 ]; then
        echo "未指定要开放的端口。"
        return 1
    fi

    local ports=("$@")

    # 检测 firewalld
    if command -v firewall-cmd &> /dev/null && systemctl is-active --quiet firewalld; then
        echo "检测到 firewalld 防火墙正在运行，正在检查并开放端口..."
        for port in "${ports[@]}"; do
            if [ "$USE_SUDO" = true ]; then
                if ! sudo firewall-cmd --permanent --query-port="$port"; then
                    echo "正在添加端口 $port..."
                    sudo firewall-cmd --permanent --add-port="$port"
                else
                    echo "端口 $port 已开放。"
                fi
            else
                if ! firewall-cmd --permanent --query-port="$port"; then
                    echo "正在添加端口 $port..."
                    firewall-cmd --permanent --add-port="$port"
                else
                    echo "端口 $port 已开放。"
                fi
            fi
        done
        if [ "$USE_SUDO" = true ]; then
            sudo firewall-cmd --reload
        else
            firewall-cmd --reload
        fi
        echo "firewalld 防火墙端口设置完成。"

    # 检测 ufw
    elif command -v ufw &> /dev/null && systemctl is-active --quiet ufw; then
        echo "检测到 ufw 防火墙正在运行，正在检查并开放端口..."
        for port in "${ports[@]}"; do
            port_num=$(echo "$port" | cut -d'/' -f1)
            proto=$(echo "$port" | cut -d'/' -f2)
            if [ "$USE_SUDO" = true ]; then
                if ! sudo ufw status verbose | grep -q "$port_num/$proto"; then
                    echo "正在添加端口 $port..."
                    sudo ufw allow "$port"
                else
                    echo "端口 $port 已开放。"
                fi
            else
                if ! ufw status verbose | grep -q "$port_num/$proto"; then
                    echo "正在添加端口 $port..."
                    ufw allow "$port"
                else
                    echo "端口 $port 已开放。"
                fi
            fi
        done
        if [ "$USE_SUDO" = true ]; then
            sudo ufw reload
        else
            ufw reload
        fi
        echo "ufw 防火墙端口设置完成。"

    else
        echo "防火墙服务未运行，跳过自动配置。"
    fi
}
# 主逻辑
# 检查并安装必要工具
check_dependencies

# 保存运行进程的配置文件
save_running_config() {
    local service_type=$1
    local source_dir=$2
    local config_file
    
    if [ "$service_type" = "frps" ]; then
        config_file="${FRPS_CONF_NAME}"
    else
        config_file="${FRPC_CONF_NAME}"
    fi
    
    # 检查源配置文件是否存在
    if [ -f "$source_dir/$config_file" ]; then
        echo "发现运行进程的配置文件: $source_dir/$config_file"
        
        # 拷贝配置文件到新安装目录
        if [ "$USE_SUDO" = true ]; then
            sudo cp "$source_dir/$config_file" "$INSTALL_DIR/"
        else
            cp "$source_dir/$config_file" "$INSTALL_DIR/"
        fi
        
        echo "已将配置文件从 $source_dir 复制到 $INSTALL_DIR"
    else
        echo "警告: 未找到 $service_type 的配置文件在 $source_dir"
        echo "将使用默认配置创建新配置文件"
    fi
}

# 确保日志文件和目录存在
if [ ! -d "$(dirname $LOG_FILE)" ]; then
    if [ "$USE_SUDO" = true ]; then
        sudo mkdir -p "$(dirname $LOG_FILE)"
    else
        mkdir -p "$(dirname $LOG_FILE)"
    fi
fi
if [ ! -f "${LOG_FILE}" ]; then
    if [ "$USE_SUDO" = true ]; then
        sudo touch "${LOG_FILE}"
        sudo chown root:root "${LOG_FILE}"
        sudo chmod 644 "${LOG_FILE}"
    else
        touch "${LOG_FILE}"
        chown root:root "${LOG_FILE}" 2>/dev/null || true  # 尝试更改所有者，如果失败则忽略
        chmod 644 "${LOG_FILE}"
    fi
fi

# 检测是否有运行中的 frp 进程
check_running_processes() {
    local running_processes=()
    local has_frps_running=false
    local has_frpc_running=false
    local frps_process_dir=""
    local frpc_process_dir=""
    
    # 检查 frps 进程
    if pgrep -f frps > /dev/null; then
        local frps_pids=$(pgrep -f frps)
        for pid in $frps_pids; do
            local cmd=$(ps -p $pid -o args= 2>/dev/null)
            running_processes+=("PID: $pid, Command: $cmd")
            # 获取进程所在目录
            local process_path=$(readlink -f "/proc/$pid/exe" 2>/dev/null)
            if [ -n "$process_path" ]; then
                frps_process_dir=$(dirname "$process_path")
            fi
        done
        has_frps_running=true
    fi
    
    # 检查 frpc 进程
    if pgrep -f frpc > /dev/null; then
        local frpc_pids=$(pgrep -f frpc)
        for pid in $frpc_pids; do
            local cmd=$(ps -p $pid -o args= 2>/dev/null)
            running_processes+=("PID: $pid, Command: $cmd")
            # 获取进程所在目录
            local process_path=$(readlink -f "/proc/$pid/exe" 2>/dev/null)
            if [ -n "$process_path" ]; then
                frpc_process_dir=$(dirname "$process_path")
            fi
        done
        has_frpc_running=true
    fi
    
    # 将当前运行进程的目录保存到全局变量，用于后续复制二进制文件
    if [ -n "$frps_process_dir" ]; then
        CURRENT_FRPS_DIR="$frps_process_dir"
    fi
    if [ -n "$frpc_process_dir" ]; then
        CURRENT_FRPC_DIR="$frpc_process_dir"
    fi
    
    if [ ${#running_processes[@]} -gt 0 ]; then
        echo "检测到以下运行中的 FRP 进程："
        for process in "${running_processes[@]}"; do
            echo "  $process"
        done
        echo ""
        
        # 检查是否与安装路径冲突
        local has_conflict=false
        if [ "$has_frps_running" = true ] && [ -n "$frps_process_dir" ] && [ "$frps_process_dir" != "$INSTALL_DIR" ] && [ "$frps_process_dir" != "$DEFAULT_INSTALL_DIR" ]; then
            has_conflict=true
        elif [ "$has_frpc_running" = true ] && [ -n "$frpc_process_dir" ] && [ "$frpc_process_dir" != "$INSTALL_DIR" ] && [ "$frpc_process_dir" != "$DEFAULT_INSTALL_DIR" ]; then
            has_conflict=true
        fi
        
        if [ "$has_conflict" = true ]; then
            echo "警告: 检测到运行中的 FRP 进程路径与安装路径不一致:"
            if [ -n "$frps_process_dir" ]; then
                echo "  frps 进程路径: $frps_process_dir"
            fi
            if [ -n "$frpc_process_dir" ]; then
                echo "  frpc 进程路径: $frpc_process_dir"
            fi
            echo "  当前安装路径: $INSTALL_DIR"
            
            if [ "$has_frps_running" = true ] && [ "$has_frpc_running" = true ]; then
                # 同时有frps和frpc运行
                read -p "请选择操作 - 1) 停止进程并卸载继续安装 2) 继续安装并迁移复用配置 3) 按q退出 [1/2/q]: " action
            elif [ "$has_frps_running" = true ]; then
                # 只有frps运行，询问是否安装frpc
                read -p "请选择操作 - 1) 停止进程并卸载继续安装 2) 继续安装并迁移复用配置 3) 继续安装frpc(进程是frps) 4) 按q退出 [1/2/3/q]: " action
            elif [ "$has_frpc_running" = true ]; then
                # 只有frpc运行，询问是否安装frps
                read -p "请选择操作 - 1) 停止进程并卸载继续安装 2) 继续安装并迁移复用配置 3) 继续安装frps(进程是frpc) 4) 按q退出 [1/2/3/q]: " action
            else
                read -p "请选择操作 - 1) 停止进程并卸载继续安装 2) 继续安装并迁移复用配置 3) 按q退出 [1/2/q]: " action
            fi
            
            case $action in
                1)
                    echo "正在停止运行中的 FRP 进程..."
                    sudo pkill -f frps 2>/dev/null
                    sudo pkill -f frpc 2>/dev/null
                    sleep 2  # 等待进程结束
                    
                    # 备份并迁移配置文件
                    if [ "$has_frps_running" = true ] && [ -n "$frps_process_dir" ]; then
                        save_running_config "frps" "$frps_process_dir"
                    fi
                    if [ "$has_frpc_running" = true ] && [ -n "$frpc_process_dir" ]; then
                        save_running_config "frpc" "$frpc_process_dir"
                    fi
                    ;;
                2)
                    # 备份并迁移配置文件
                    if [ "$has_frps_running" = true ] && [ -n "$frps_process_dir" ]; then
                        save_running_config "frps" "$frps_process_dir"
                    fi
                    if [ "$has_frpc_running" = true ] && [ -n "$frpc_process_dir" ]; then
                        save_running_config "frpc" "$frpc_process_dir"
                    fi
                    ;;
                3)
                    # 如果运行的是frpc，提示安装frps；如果运行的是frps，提示安装frpc
                    if [ "$has_frpc_running" = true ]; then
                        echo "检测到当前运行的是frpc，将安装frps服务端..."
                        INSTALL_MODE="s"  # 设置为安装服务端
                    elif [ "$has_frps_running" = true ]; then
                        echo "检测到当前运行的是frps，将安装frpc客户端..."
                        INSTALL_MODE="c"  # 设置为安装客户端
                    else
                        # 如果都有或都没有，按原计划执行
                        echo "继续按原计划安装..."
                    fi
                    ;;
                q|Q)
                    echo "用户选择退出安装。"
                    exit 1
                    ;;
                *)
                    echo "用户选择退出安装。"
                    exit 1
                    ;;
            esac
        else
            echo "运行中的 FRP 进程路径与安装路径一致或为默认路径，继续安装..."
        fi
    fi
}

# 设置安装目录权限
if [ "$USE_SUDO" = true ]; then
    sudo chown root:root "${INSTALL_DIR}"
    sudo chmod 700 "${INSTALL_DIR}"
else
    chown root:root "${INSTALL_DIR}" 2>/dev/null || true  # 尝试更改所有者，如果失败则忽略
    chmod 700 "${INSTALL_DIR}"
fi

# 检查运行中的进程
check_running_processes

# 如果指定了安装模式则跳过交互，否则提示用户选择
if [ -z "$INSTALL_MODE" ]; then
    read -p "请选择要安装的服务 (s服务端/c客户端，默认c): " CHOICE
    CHOICE=${CHOICE:-c}
else
    CHOICE=$INSTALL_MODE
fi

# 保存当前运行进程目录的全局变量
CURRENT_FRPS_DIR=""
CURRENT_FRPC_DIR=""

case $CHOICE in
    s)
        FRP_BIN_NAME="frps"

        if [ ! -f "${INSTALL_DIR}/${FRP_BIN_NAME}" ]; then
            echo "正在下载并安装$FRP_BIN_NAME ..."
            copy_or_download_frps "$CURRENT_FRPS_DIR"
            echo "$FRP_BIN_NAME 已安装到 ${INSTALL_DIR}"
        fi

        # 检查是否有已备份的配置文件，如果有则不重新生成
        if [ -f "${INSTALL_DIR}/${FRPS_CONF_NAME}" ]; then
            echo "${FRPS_CONF_NAME} 配置文件已存在，跳过重新生成。"
        else
            echo "生成${FRPS_CONF_NAME}配置文件..."
            generate_default_config
        fi

        echo "正在创建或更新 $FRP_BIN_NAME Systemd 服务..."
        create_systemd_service

        # 启动服务（使用通用启动脚本，自动检测配置文件）
        if [ -f "${INSTALL_DIR}/startup.sh" ]; then
            echo "正在启动 $FRP_BIN_NAME 服务..."
            if [ "$USE_SUDO" = true ]; then
                sudo "${INSTALL_DIR}/startup.sh"
            else
                "${INSTALL_DIR}/startup.sh"
            fi
        else
            echo "警告: 启动脚本 ${INSTALL_DIR}/startup.sh 不存在"
        fi

        echo "安装并启动 frps 完成。"
        setup_firewall_ports "6000/tcp" "7000/tcp" "7800/tcp" "7443/tcp" "7500/tcp"
        ;;
    c)
        if [ ! -f "${INSTALL_DIR}/${FRPC_NAME}" ]; then
            echo "正在下载并安装 frpc..."
            copy_or_download_frpc "$CURRENT_FRPC_DIR"
            echo "frpc 已安装到 ${INSTALL_DIR}"
        fi

        # 检查是否有已备份的配置文件，如果有则不重新生成
        if [ -f "${INSTALL_DIR}/${FRPC_CONF_NAME}" ]; then
            echo "${FRPC_CONF_NAME} 配置文件已存在，跳过重新生成。"
        else
            echo "生成${FRPC_CONF_NAME}配置文件..."
            generate_default_client_config
        fi

        echo "正在创建或更新 frpc Systemd 服务..."
        create_systemd_client_service

        # 启动服务（使用通用启动脚本，自动检测配置文件）
        if [ -f "${INSTALL_DIR}/startup.sh" ]; then
            echo "正在启动 frpc 服务..."
            if [ "$USE_SUDO" = true ]; then
                sudo "${INSTALL_DIR}/startup.sh"
            else
                "${INSTALL_DIR}/startup.sh"
            fi
        else
            echo "警告: 启动脚本 ${INSTALL_DIR}/startup.sh 不存在"
        fi

        echo "安装并启动 frpc 完成。"
        sshd_port=$(grep -oP 'Port \K\d+' /etc/ssh/sshd_config | head -n 1)
        [ -z "$sshd_port" ] && sshd_port=22
        setup_firewall_ports "${sshd_port}/tcp"
        ;;
    *)
        echo "无效的选择，退出安装。"
        exit 1
        ;;
esac
