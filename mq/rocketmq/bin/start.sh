#!/bin/bash

# RocketMQ 启动脚本
# 版本: 1.1
# 用途: 启动 RocketMQ 服务

set -euo pipefail  # 严格错误处理模式

# === 引入公共函数库 ===
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

# === 配置参数 ===
# 使用common.sh中的默认值

# === 全局变量 ===
INSTALL_DIR="$DEFAULT_INSTALL_DIR"
CONF_DIR=""
IP=""
OS=""
MODE="1"  # 默认模式: 2m-noslave
NAMESRV_IP=""
BROKER_ID="a"

# === 帮助信息 ===
show_help() {
    cat << EOF
用法: $0 [选项]

选项:
    -d, --dir DIR     指定安装目录 (默认: $DEFAULT_INSTALL_DIR)
    -m, --mode MODE   指定部署模式 (1: 2m-noslave, 2: 2m-2s-async, 3: 2m-2s-sync) (默认: 1)
    -b, --broker ID   指定broker ID (a 或 b) (仅适用于模式 2 和 3)
    -n, --namesrv IP  额外的namesrv IP (可选)
    -h, --help        显示此帮助信息

示例:
    $0                           # 以默认模式启动，默认安装目录
    $0 -d /opt/rocketmq          # 以默认模式启动，指定安装目录
    $0 -m 2                      # 启动 2m-2s-async 模式
    $0 -m 2 -b b                 # 启动 2m-2s-async 模式，选择broker b
EOF
}

# === 命令行参数解析 ===
parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -d|--dir)
                if [[ -n "${2:-}" ]]; then
                    INSTALL_DIR="$2"
                    shift 2
                else
                    echo "错误: -d|--dir 参数需要提供目录路径" >&2
                    show_help
                    exit 1
                fi
                ;;
            -m|--mode)
                if [[ -n "${2:-}" ]]; then
                    if [[ $2 =~ ^[1-3]$ ]]; then
                        MODE="$2"
                        shift 2
                    else
                        echo "错误: 无效的模式 '$2'，支持的模式: 1, 2, 3" >&2
                        show_help
                        exit 1
                    fi
                else
                    echo "错误: -m|--mode 参数需要提供模式" >&2
                    show_help
                    exit 1
                fi
                ;;
            -b|--broker)
                if [[ -n "${2:-}" ]]; then
                    if [[ $2 =~ ^[ab]$ ]]; then
                        BROKER_ID="$2"
                        shift 2
                    else
                        echo "错误: 无效的broker ID '$2'，支持: a, b" >&2
                        show_help
                        exit 1
                    fi
                else
                    echo "错误: -b|--broker 参数需要提供broker ID" >&2
                    show_help
                    exit 1
                fi
                ;;
            -n|--namesrv)
                if [[ -n "${2:-}" ]]; then
                    NAMESRV_IP="$2"
                    shift 2
                else
                    echo "错误: -n|--namesrv 参数需要提供IP地址" >&2
                    show_help
                    exit 1
                fi
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            *)
                echo "未知参数: $1" >&2
                show_help
                exit 1
                ;;
        esac
    done
}

# === 日志函数 ===
# 使用common.sh中的日志函数

# === 工具函数 ===
# 使用common.sh中的工具函数

# === 配置修改函数 ===
modify_config_value() {
    local key="$1"
    local value="$2"
    local conf_file="$3"
    
    log_info "修改配置文件 $conf_file: $key=$value"
    
    # 确保配置文件存在
    [ ! -f "$conf_file" ] && touch "$conf_file"
    
    # 删除已存在的配置（无论是否注释）
    sed -i.bak "/^[[:space:]]*#*[[:space:]]*$key=/d" "$conf_file" 2>/dev/null || true
    
    # 添加新配置
    echo "$key=$value" >> "$conf_file"
}

# === 环境设置函数 ===
# 使用common.sh中的setup_jdk_env函数

# === 服务启动函数 ===
start_namesrv() {
    local namesrv_port="${1:-9876}"
    log_info "启动 NameServer"
    
    # 检查namesrv脚本是否存在
    if [ ! -f "$INSTALL_DIR/bin/mqnamesrv" ]; then
        log_error "NameServer 启动脚本不存在: $INSTALL_DIR/bin/mqnamesrv"
        exit 1
    fi
    
    # 设置环境变量
    setup_jdk_env "$INSTALL_DIR/bin/mqnamesrv" "$OS"
    
    nohup "$INSTALL_DIR/bin/mqnamesrv" -n "$IP:$namesrv_port" > /dev/null 2>&1 &
    local pid=$!
    
    # 创建PID文件
    create_pid_file "namesrv" $pid "$INSTALL_DIR"
    
    # 等待服务启动
    sleep 3
    
    if kill -0 "$pid" 2>/dev/null || pgrep -f "mqnamesrv" > /dev/null; then
        log_info "NameServer 启动成功，PID: $pid"
        return 0
    else
        log_error "NameServer 启动失败"
        return 1
    fi
}

start_broker() {
    local broker_conf="$1"
    local auto_create_topic="${2:-true}"
    
    log_info "启动 Broker: $broker_conf"
    
    # 检查broker脚本是否存在
    if [ ! -f "$INSTALL_DIR/bin/mqbroker" ]; then
        log_error "Broker 启动脚本不存在: $INSTALL_DIR/bin/mqbroker"
        exit 1
    fi
    
    # 确保配置文件存在
    if [ ! -f "$broker_conf" ]; then
        log_error "Broker 配置文件不存在: $broker_conf"
        return 1
    fi
    
    # 设置环境变量
    setup_jdk_env "$INSTALL_DIR/bin/mqbroker" "$OS"
    setup_jdk_env "$INSTALL_DIR/bin/runbroker.sh" "$OS"
    
    nohup sh "$INSTALL_DIR/bin/mqbroker" -c "$broker_conf" -n "$IP:9876" autoCreateTopicEnable="$auto_create_topic" > /dev/null 2>&1 &
    local pid=$!
    
    # 创建PID文件
    create_pid_file "broker-$(basename "$broker_conf" .properties)" $pid "$INSTALL_DIR"
    
    # 等待服务启动
    sleep 5
    
    if kill -0 "$pid" 2>/dev/null || pgrep -f "mqbroker" > /dev/null; then
        log_info "Broker 启动成功，配置: $broker_conf, PID: $pid"
        return 0
    else
        log_error "Broker 启动失败"
        return 1
    fi
}

# === 集群启动函数 ===
start_2m_noslave_mode() {
    log_info "启动 2m-noslave 模式"
    
    local conf_subdir="2m-noslave"
    local conf_dir="$INSTALL_DIR/conf/$conf_subdir"
    mkdir -p "$conf_dir"
    
    # 创建基础配置文件
    local broker_a_conf="$conf_dir/broker-a.properties"
    local broker_b_conf="$conf_dir/broker-b.properties"
    
    # 创建基础配置文件（从默认配置复制或新建）
    if [ -f "$INSTALL_DIR/conf/broker.conf" ]; then
        cp "$INSTALL_DIR/conf/broker.conf" "$broker_a_conf" 2>/dev/null || > "$broker_a_conf"
        cp "$INSTALL_DIR/conf/broker.conf" "$broker_b_conf" 2>/dev/null || > "$broker_b_conf"
    else
        > "$broker_a_conf"
        > "$broker_b_conf"
    fi
    
    # 验证配置文件
    validate_config "$broker_a_conf" || {
        log_error "Broker A 配置文件验证失败"
        exit 1
    }
    validate_config "$broker_b_conf" || {
        log_error "Broker B 配置文件验证失败"
        exit 1
    }
    
    # 修改配置文件
    modify_config_value "listenPort" "10911" "$broker_a_conf"
    modify_config_value "brokerId" "0" "$broker_a_conf"
    modify_config_value "namesrvAddr" "$IP:9876${NAMESRV_IP:+;$NAMESRV_IP:9876}" "$broker_a_conf"
    
    modify_config_value "listenPort" "10912" "$broker_b_conf"
    modify_config_value "brokerId" "0" "$broker_b_conf"
    modify_config_value "namesrvAddr" "$IP:9876${NAMESRV_IP:+;$NAMESRV_IP:9876}" "$broker_b_conf"
    
    # 启动服务
    start_namesrv
    start_broker "$broker_a_conf"
    start_broker "$broker_b_conf"
}

start_m_s_mode() {
    local mode="$1"
    
    local conf_subdir=""
    if [ "$mode" = "2" ]; then
        conf_subdir="2m-2s-async"
        log_info "启动 2m-2s-async 模式"
    else
        conf_subdir="2m-2s-sync"
        log_info "启动 2m-2s-sync 模式"
    fi
    
    local conf_dir="$INSTALL_DIR/conf/$conf_subdir"
    mkdir -p "$conf_dir"
    
    # 创建主从broker配置
    local master_conf="$conf_dir/broker-$BROKER_ID.properties"
    local slave_conf="$conf_dir/broker-$BROKER_ID-s.properties"
    
    # 创建基础配置文件
    if [ -f "$INSTALL_DIR/conf/broker.conf" ]; then
        cp "$INSTALL_DIR/conf/broker.conf" "$master_conf" 2>/dev/null || > "$master_conf"
        cp "$INSTALL_DIR/conf/broker.conf" "$slave_conf" 2>/dev/null || > "$slave_conf"
    else
        > "$master_conf"
        > "$slave_conf"
    fi
    
    # 验证配置文件
    validate_config "$master_conf" || {
        log_error "Master Broker 配置文件验证失败"
        exit 1
    }
    validate_config "$slave_conf" || {
        log_error "Slave Broker 配置文件验证失败"
        exit 1
    }
    
    # 设置主broker配置
    modify_config_value "listenPort" "10911" "$master_conf"
    modify_config_value "brokerId" "0" "$master_conf"
    if [ "$mode" = "2" ]; then
        modify_config_value "brokerRole" "ASYNC_MASTER" "$master_conf"
    else
        modify_config_value "brokerRole" "SYNC_MASTER" "$master_conf"
    fi
    modify_config_value "namesrvAddr" "$IP:9876${NAMESRV_IP:+;$NAMESRV_IP:9876}" "$master_conf"
    
    # 设置从broker配置
    modify_config_value "listenPort" "10912" "$slave_conf"
    modify_config_value "brokerId" "1" "$slave_conf"
    modify_config_value "brokerRole" "SLAVE" "$slave_conf"
    modify_config_value "namesrvAddr" "$IP:9876${NAMESRV_IP:+;$NAMESRV_IP:9876}" "$slave_conf"
    
    # 启动服务
    start_namesrv
    start_broker "$master_conf"
    start_broker "$slave_conf"
}

# === 主函数 ===
main() {
    # 解析命令行参数
    parse_arguments "$@"
    
    log_info "开始启动 RocketMQ 服务"
    log_info "安装目录: $INSTALL_DIR"
    log_info "部署模式: $MODE"
    
    # 检查安装目录
    if [ ! -d "$INSTALL_DIR" ]; then
        log_error "安装目录不存在: $INSTALL_DIR"
        exit 1
    fi
    
    # 初始化变量
    IP=$(get_ip)
    if [ -z "$IP" ]; then
        log_error "无法获取本机IP地址"
        exit 1
    fi
    
    OS=$(get_os)
    log_info "操作系统: $OS, IP地址: $IP"
    
    # 验证额外Namesrv IP（如果提供）
    if [ -n "$NAMESRV_IP" ]; then
        if ! validate_ip "$NAMESRV_IP"; then
            log_error "无效的IP地址: $NAMESRV_IP"
            exit 1
        fi
        log_info "配置额外 namesrv IP: $NAMESRV_IP"
    fi
    
    # 根据选择执行配置
    case $MODE in
        1)
            start_2m_noslave_mode
            ;;
        2|3)
            start_m_s_mode "$MODE"
            ;;
    esac
    
    # 等待服务启动
    log_info "等待服务启动..."
    sleep 5
    
    # 进行健康检查
    log_info "进行服务健康检查..."
    local namesrv_addr="$IP:9876"
    if check_namesrv_health "$namesrv_addr"; then
        log_info "NameServer 服务健康检查通过"
    else
        log_warn "NameServer 服务健康检查失败"
    fi
    
    # 检查broker服务健康状态
    if [ "$MODE" = "1" ]; then
        # 2m-noslave模式，检查两个broker
        if check_broker_health "$IP:10911"; then
            log_info "Broker A 服务健康检查通过"
        else
            log_warn "Broker A 服务健康检查失败"
        fi
        if check_broker_health "$IP:10912"; then
            log_info "Broker B 服务健康检查通过"
        else
            log_warn "Broker B 服务健康检查失败"
        fi
    else
        # 主从模式，检查master和slave
        local broker_port=10911
        local slave_port=10912
        if check_broker_health "$IP:$broker_port"; then
            log_info "Master Broker 服务健康检查通过"
        else
            log_warn "Master Broker 服务健康检查失败"
        fi
        if check_broker_health "$IP:$slave_port"; then
            log_info "Slave Broker 服务健康检查通过"
        else
            log_warn "Slave Broker 服务健康检查失败"
        fi
    fi
    
    # 显示运行进程
    log_info "当前运行的 RocketMQ 进程:"
    pgrep -f "mqnamesrv\|mqbroker" -l
    
    log_info "RocketMQ 启动完成！"
    echo
    echo "服务信息:"
    echo "- NameServer: $IP:9876"
    echo "- Broker: 根据配置文件启动，端口 10911/10912 等"
    echo
    echo "启动脚本位于: $INSTALL_DIR/bin/"
    echo "配置文件位于: $INSTALL_DIR/conf/"
}

# === 执行主函数 ===
main "$@"