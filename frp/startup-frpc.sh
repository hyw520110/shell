#!/bin/bash

# 定义公共变量
INSTALL_DIR=$(dirname "$(readlink -f "$0")")
FRP_CLIENT_NAME="frpc"
FRP_CLIENT_CONF_NAME="frpc.toml"

# 函数：启动服务
start_service() {
    ${INSTALL_DIR}/${FRP_CLIENT_NAME} -c ${INSTALL_DIR}/${FRP_CLIENT_CONF_NAME} 2>&1 &
    if [ $? -ne 0 ]; then
        echo "启动 frpc 服务失败。"
        exit 1
    fi
}

# 函数：检查服务状态
check_service_status() {
    if pgrep -f "${INSTALL_DIR}/${FRP_CLIENT_NAME} -c ${INSTALL_DIR}/${FRP_CLIENT_CONF_NAME}" > /dev/null; then
        echo "frpc 服务正在运行。"
    else
        echo "frpc 服务未运行。"
    fi
}

# 主逻辑
# 启动服务
echo "正在启动 frpc 服务..."
start_service
check_service_status