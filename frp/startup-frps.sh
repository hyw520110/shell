#!/bin/bash

# 定义公共变量
INSTALL_DIR=$(dirname "$(readlink -f "$0")")
FRP_BIN_NAME="frps"
FRP_CONF_NAME="frps.toml"


# 函数：启动服务
start_service() {
    ${INSTALL_DIR}/${FRP_BIN_NAME} -c ${INSTALL_DIR}/${FRP_CONF_NAME}  2>&1 &
    if [ $? -ne 0 ]; then
        echo "启动 frps 服务失败。"
        exit 1
    fi
}

# 函数：检查服务状态
check_service_status() {
    if pgrep -f "${INSTALL_DIR}/${FRP_BIN_NAME} -c ${INSTALL_DIR}/${FRP_CONF_NAME}" > /dev/null; then
        echo "frps 服务正在运行。"
    else
        echo "frps 服务未运行。"
    fi
}

echo "正在启动 frps 服务..."
start_service
check_service_status