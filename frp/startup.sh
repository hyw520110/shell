#!/bin/bash

# 通用启动脚本，用于启动 frpc 或 frps 服务
# 使用方法: ./startup.sh [frpc|frps]

# 默认安装目录
INSTALL_DIR=$(dirname "$(readlink -f "$0")")
SERVICE_TYPE="frpc"

# 检查参数
if [ $# -eq 0 ]; then
    # 参数缺失，自动检测配置文件
    INSTALL_DIR=$(dirname "$(readlink -f "$0")")
    
    # 检查是否存在配置文件
    frpc_conf_exists=0
    frps_conf_exists=0
    
    if [ -f "${INSTALL_DIR}/frpc.toml" ]; then
        frpc_conf_exists=1
    fi
    
    if [ -f "${INSTALL_DIR}/frps.toml" ]; then
        frps_conf_exists=1
    fi
    
    # 根据配置文件存在情况决定启动哪个服务
    if [ $frpc_conf_exists -eq 1 ] && [ $frps_conf_exists -eq 0 ]; then
        # 只有frpc.toml存在
        SERVICE_TYPE="frpc"
    elif [ $frps_conf_exists -eq 1 ] && [ $frpc_conf_exists -eq 0 ]; then
        # 只有frps.toml存在
        SERVICE_TYPE="frps"
    elif [ $frpc_conf_exists -eq 1 ] && [ $frps_conf_exists -eq 1 ]; then
        # 两个配置文件都存在，默认启动frpc
        SERVICE_TYPE="frpc"
    else
        # 没有找到配置文件
        echo "错误: 在 ${INSTALL_DIR} 目录中未找到 frpc.toml 或 frps.toml 配置文件"
        echo "使用方法: $0 [frpc|frps]"
        exit 1
    fi
    
    echo "自动检测到配置文件，启动 ${SERVICE_TYPE} 服务"
elif [ $# -eq 1 ]; then
    SERVICE_TYPE=$1
else
    echo "使用方法: $0 [frpc|frps] 或不带参数自动检测配置文件"
    exit 1
fi

# 验证服务类型
if [ "$SERVICE_TYPE" != "frpc" ] && [ "$SERVICE_TYPE" != "frps" ]; then
    echo "错误: 服务类型必须是 'frpc' 或 'frps'"
    exit 1
fi
FRP_BIN_NAME="$SERVICE_TYPE"
FRP_CONF_NAME="${SERVICE_TYPE}.toml"
LOG_FILE="$INSTALL_DIR/${SERVICE_TYPE}.log"


# 函数：在指定目录列表中查找frp二进制文件
find_frp_binary() {
    # 定义要搜索的目录列表
    local search_dirs=(
        "$INSTALL_DIR"           # 当前目录
        "/opt"                   # /opt 目录
        "$HOME"                  # 用户主目录
        "/opt/frp"               # /opt/frp 目录
    )
    
    # 遍历目录列表查找二进制文件
    for dir in "${search_dirs[@]}"; do
        if [ -f "${dir}/${FRP_BIN_NAME}" ]; then
            echo "$dir"
            return
        fi
    done
    
    # 如果在指定目录中未找到，则在 PATH 中查找
    local bin_path=$(which $FRP_BIN_NAME 2>/dev/null)
    if [ -n "$bin_path" ] && [ -f "$bin_path" ]; then
        dirname "$bin_path"
        return
    fi
    
    # 未找到返回空字符串
    echo ""
}

# 函数：检查服务是否已运行
is_service_running() {
    pgrep -f "${INSTALL_DIR}/${FRP_BIN_NAME} -c ${INSTALL_DIR}/${FRP_CONF_NAME}" > /dev/null
}

# 函数：获取运行中的服务PID
get_service_pid() {
    pgrep -f "${INSTALL_DIR}/${FRP_BIN_NAME} -c ${INSTALL_DIR}/${FRP_CONF_NAME}"
}

# 函数：获取当前内网IP
get_local_ip() {
    # 尝试获取默认网关的接口IP
    local ip=$(hostname -I | awk '{print $1}')
    if [ -n "$ip" ]; then
        echo "$ip"
        return
    fi
    
    # 如果hostname -I不可用，尝试使用ip route获取
    ip=$(ip route get 8.8.8.8 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1); exit}')
    if [ -n "$ip" ]; then
        echo "$ip"
        return
    fi
    
    # 备选方案：使用netstat获取
    ip=$(netstat -rn | grep -E "^0.0.0.0|UG" | awk '{print $8}' | head -1 | xargs -I {} sh -c 'ip addr show {} | grep "inet " | grep -v "127.0.0.1" | awk "{print \$2}" | cut -d/ -f1' | head -1)
    if [ -n "$ip" ]; then
        echo "$ip"
        return
    fi
    
    # 如果都失败了，返回空字符串
    echo ""
}

# 函数：更新frpc.toml中的localIP
update_frpc_local_ip() {
    local config_file="${INSTALL_DIR}/frpc.toml"
    if [ "$SERVICE_TYPE" != "frpc" ] || [ ! -f "$config_file" ]; then
        return 0
    fi
    
    local current_ip=$(get_local_ip)
    if [ -z "$current_ip" ]; then
        echo "警告: 无法获取当前内网IP"
        return 1
    fi
    
    echo "当前内网IP: $current_ip"
    
    # 读取配置文件并处理proxies部分的localIP
    local temp_config="${INSTALL_DIR}/frpc.toml.tmp"
    local in_proxy_section=false
    local config_updated=false
    
    while IFS= read -r line || [ -n "$line" ]; do
        if [[ $line =~ ^\[\[proxies\]\] ]]; then
            in_proxy_section=true
            echo "$line" >> "$temp_config"
        elif [[ $line =~ ^\[.*\] ]] && [[ ! $line =~ ^\[\[proxies\]\] ]]; then
            # 遇到其他section，重置标记
            in_proxy_section=false
            echo "$line" >> "$temp_config"
        elif [[ $line =~ ^localIP= ]] && [ "$in_proxy_section" = true ]; then
            # 提取localIP配置中的IP地址
            local existing_ip=$(echo "$line" | sed -E 's/localIP="([^"]+)"/\1/')
            if [ "$existing_ip" != "$current_ip" ]; then
                # 如果IP不匹配当前IP，进行更新
                local new_line="localIP=\"$current_ip\""
                echo "$new_line" >> "$temp_config"
                config_updated=true
                echo "更新 localIP: $existing_ip -> $current_ip"
            else
                echo "$line" >> "$temp_config"
            fi
        else
            echo "$line" >> "$temp_config"
        fi
    done < "$config_file"
    
    # 如果配置已更新，替换原文件
    if [ "$config_updated" = true ]; then
        mv "$temp_config" "$config_file"
        echo "frpc.toml 配置文件已更新"
    else
        rm -f "$temp_config"
        echo "frpc.toml 配置文件中localIP无需更新"
    fi
}

# 函数：检查配置文件是否存在
check_config_file() {
    if [ ! -f "${INSTALL_DIR}/${FRP_CONF_NAME}" ]; then
        echo "错误: 配置文件 ${INSTALL_DIR}/${FRP_CONF_NAME} 不存在"
        return 1
    fi
    return 0
}

# 查找并设置安装目录
BIN_DIR=$(find_frp_binary)
if [ -z "$BIN_DIR" ]; then
    echo "错误: 找不到 ${FRP_BIN_NAME} 二进制文件"
    echo "请确保 frp 已正确安装在当前目录、/opt、用户目录或 PATH 中"
    exit 1
fi

INSTALL_DIR="$BIN_DIR"
echo "找到 ${FRP_BIN_NAME} 位于: ${INSTALL_DIR}"

# 检查服务是否已在运行
if is_service_running; then
    PID=$(get_service_pid)
    echo "${SERVICE_TYPE} 服务已在运行，PID: $PID"
    exit 0
fi

# 检查配置文件
if ! check_config_file; then
    exit 1
fi

# 函数：启动服务
start_service() {
    echo "正在启动 ${SERVICE_TYPE} 服务..."
    LOG_DIR=$(dirname $LOG_FILE)
    [ ! -d $LOG_DIR ] && echo "创建日志目录$LOG_DIR" && mkdir -p $LOG_DIR
    ${INSTALL_DIR}/${FRP_BIN_NAME} -c ${INSTALL_DIR}/${FRP_CONF_NAME} > $LOG_FILE 2>&1 &
    START_PID=$!
    
    # 等待一段时间以确保进程启动
    sleep 2
    
    # 检查进程是否仍在运行
    if ps -p $START_PID > /dev/null; then
        echo "${SERVICE_TYPE} 服务启动成功，PID: $START_PID"
        echo "日志文件: $LOG_FILE"
    else
        echo "${SERVICE_TYPE} 启动失败,日志$LOG_FILE :"
        cat $LOG_FILE
        exit 1
    fi
}

# 如果是frpc服务，检查并更新localIP配置
if [ "$SERVICE_TYPE" = "frpc" ]; then
    update_frpc_local_ip
fi

# 启动服务
start_service