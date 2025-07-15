#!/bin/bash

# 定义公共变量
FRP_VERSION="0.61.0"
FRP_DOWNLOAD_URL="https://github.com/fatedier/frp/releases/download/v${FRP_VERSION}/frp_${FRP_VERSION}_linux_amd64.tar.gz"
INSTALL_DIR=$(dirname "$(readlink -f "$0")")
FRP_SERVICE_NAME="frps"
FRP_CONF_NAME="${FRP_SERVICE_NAME}.toml"
FRP_CLIENT_NAME="frpc"
FRP_CLIENT_CONF_NAME="${FRP_CLIENT_NAME}.toml"
FRP_SERVICE_FILE="/usr/lib/systemd/system/${FRP_SERVICE_NAME}.service"
FRP_CLIENT_FILE="/usr/lib/systemd/system/${FRP_CLIENT_NAME}.service"
LOG_FILE="/var/log/frp.log"

# 检查并安装必要工具
check_dependencies() {
    if ! command -v wget &> /dev/null; then
        echo "wget 未安装，正在安装..."
        sudo yum install -y wget || sudo apt-get install -y wget
    fi
}

# 下载并解压 frp
download_and_extract_frps() {
    echo "正在下载 frps..."
    wget -O - "${FRP_DOWNLOAD_URL}" | tar -zx --strip-components=1 -C "${INSTALL_DIR}" "frp_${FRP_VERSION}_linux_amd64/${FRP_BIN_NAME}" "frp_${FRP_VERSION}_linux_amd64/${FRP_CONF_NAME}"
    if [ $? -ne 0 ]; then
        echo "下载并解压 frps 失败。"
        exit 1
    fi
}

download_and_extract_frpc() {
    echo "正在下载 frpc..."
    wget -O - "${FRP_DOWNLOAD_URL}" | tar -zx --strip-components=1 -C "${INSTALL_DIR}" "frp_${FRP_VERSION}_linux_amd64/${FRP_CLIENT_NAME}" "frp_${FRP_VERSION}_linux_amd64/${FRP_CLIENT_CONF_NAME}"
    if [ $? -ne 0 ]; then
        echo "下载并解压 frpc 失败。"
        exit 1
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
    cat > "${INSTALL_DIR}/${FRP_CONF_NAME}" << EOF
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
  if [[ $DASHBOARD_CHOICE =~ ^[Yy]$ ]]; then
    WEB_SERVER_PASSWORD=$(generate_random_string)
    echo "生成的 webServer.password: ${WEB_SERVER_PASSWORD}"
    cat >> "${INSTALL_DIR}/${FRP_CONF_NAME}" << EOF
webServer.user="webuser"
webServer.password="${WEB_SERVER_PASSWORD}"
EOF
  fi

  if [ $? -ne 0 ]; then
      echo "生成${FRP_CONF_NAME}配置文件失败。"
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
    cat > "${INSTALL_DIR}/${FRP_CLIENT_CONF_NAME}" << EOF
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
    if [ $? -ne 0 ]; then
        echo "生成${FRP_CLIENT_CONF_NAME}配置文件失败。"
        exit 1
    fi
}

# 创建 Systemd 服务文件
create_systemd_service() {
    if systemctl list-unit-files | grep -q "${FRP_SERVICE_NAME}.service"; then
        systemctl disable "${FRP_SERVICE_NAME}.service"
        rm "${FRP_SERVICE_FILE}"
    fi
    cat > "${FRP_SERVICE_FILE}" << EOF
[Unit]
Description=frps daemon
After = network.target syslog.target
Wants = network.target

[Service]
Type=simple
ExecStart=${INSTALL_DIR}/startup-frps.sh
ExecStop=${INSTALL_DIR}/stop.sh
WorkingDirectory=${INSTALL_DIR}
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
    if [ $? -ne 0 ]; then
        echo "创建 Systemd 服务文件失败。"
        exit 1
    fi
    systemctl daemon-reload
}

create_systemd_client_service() {
    if systemctl list-unit-files | grep -q "${FRP_CLIENT_NAME}.service"; then
        systemctl disable "${FRP_CLIENT_NAME}.service"
        rm "${FRP_CLIENT_FILE}"
    fi
    cat > "${FRP_CLIENT_FILE}" << EOF
[Unit]
Description=frpc client
After = network.target syslog.target
Wants = network.target

[Service]
Type=simple
ExecStart=${INSTALL_DIR}/startup-frpc.sh
ExecStop=${INSTALL_DIR}/stop.sh
WorkingDirectory=${INSTALL_DIR}
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
    if [ $? -ne 0 ]; then
        echo "创建 Systemd 服务文件失败。"
        exit 1
    fi
    systemctl daemon-reload
}

# 主逻辑
# 检查并安装必要工具
check_dependencies

# 确保日志文件和目录存在
if [ ! -d "/var/log" ]; then
    sudo mkdir -p /var/log
fi
if [ ! -f "${LOG_FILE}" ]; then
    sudo touch "${LOG_FILE}"
    sudo chown root:root "${LOG_FILE}"
    sudo chmod 644 "${LOG_FILE}"
fi
sudo chown root:root "${INSTALL_DIR}"
sudo chmod 700 "${INSTALL_DIR}"

# 用户选择安装服务端还是客户端
read -p "请选择要安装的服务 (s服务端/c客户端，默认c): " CHOICE
CHOICE=${CHOICE:-c}

case $CHOICE in
    s)
        FRP_BIN_NAME="frps"

        if [ ! -f "${INSTALL_DIR}/${FRP_BIN_NAME}" ]; then
            echo "正在下载并安装 frps..."
            download_and_extract_frps
            echo "frps 已安装到 ${INSTALL_DIR}"
        fi

        if [ -f "${INSTALL_DIR}/${FRP_CONF_NAME}" ]; then
            echo "生成${FRP_CONF_NAME}配置文件..."
            rm -rf "${INSTALL_DIR}/${FRP_CONF_NAME}"
        fi
        generate_default_config

        echo "正在创建或更新 frps Systemd 服务..."
        create_systemd_service

        # 启动服务
        echo "正在启动 frps 服务..."
        ./startup-frps.sh

        echo "安装并启动 frps 完成。"
        ;;
    c)
        if [ ! -f "${INSTALL_DIR}/${FRP_CLIENT_NAME}" ]; then
            echo "正在下载并安装 frpc..."
            download_and_extract_frpc
            echo "frpc 已安装到 ${INSTALL_DIR}"
        fi

        if [ -f "${INSTALL_DIR}/${FRP_CLIENT_CONF_NAME}" ]; then
            echo "生成${FRP_CLIENT_CONF_NAME}配置文件..."
            rm -rf "${INSTALL_DIR}/${FRP_CLIENT_CONF_NAME}"
        fi
        generate_default_client_config

        echo "正在创建或更新 frpc Systemd 服务..."
        create_systemd_client_service

        # 启动服务
        echo "正在启动 frpc 服务..."
        ./startup-frpc.sh

        echo "安装并启动 frpc 完成。"
        ;;
    *)
        echo "无效的选择，退出安装。"
        exit 1
        ;;
esac