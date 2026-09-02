#!/bin/bash

# RocketMQ 启动脚本
# 版本: 1.2
# 用途: 启动 RocketMQ 服务 (单机/集群模式)
# 模式: 1=2m-noslave, 2=2m-2s-async, 3=2m-2s-sync, standalone=单机

set -euo pipefail

# === 引入公共函数库 ===
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

# === 全局变量 ===
INSTALL_DIR="$DEFAULT_INSTALL_DIR"
CONF_DIR=""
IP=""
OS=""
MODE=""           # 空=未指定 (待交互或默认)
BROKER_ID=""      # 空=未指定
NAMESRV_IP=""
AUTO_YES=0

# === 模式映射 ===
declare -a MODE_NAMES=("" "2m-noslave" "2m-2s-async" "2m-2s-sync")
declare -a MODE_DESC=(
    ""
    "2m-noslave (双主无从)"
    "2m-2s-async (双主双从异步)"
    "2m-2s-sync (双主双从同步)"
)

# === 帮助信息 ===
show_help() {
    cat << EOF
RocketMQ 启动脚本

用法:
  $0 [选项]

选项:
    -d, --dir DIR       指定安装目录 (默认: $DEFAULT_INSTALL_DIR)
    -m, --mode MODE     指定部署模式:
                          standalone  单机模式 (1 NameServer + 1 Broker)
                          1           2m-noslave (双主无从)
                          2           2m-2s-async (双主双从异步)
                          3           2m-2s-sync (双主双从同步)
    -b, --broker ID     指定 broker ID (a 或 b)，仅 mode=2/3 需要
    -n, --namesrv IP    额外的 namesrv IP (可选，多节点集群使用)
    -y, --yes           跳过确认提示 (自动化/CI 场景)
    -h, --help          显示此帮助信息

交互模式:
    未指定 --mode 时，脚本会交互式引导选择模式并补全参数。
    未指定 --broker 且 mode=2/3 时，会提示输入 broker ID。
    未指定 --namesrv 时，会询问是否配置额外 namesrv。

示例:
    # 交互式 (首次部署推荐)
    $0

    # 单机模式 (开发测试)
    $0 -m standalone

    # 自动化 (参数齐全 + 跳过确认)
    $0 -m 1 -d /opt/rocketmq -y
    $0 -m 2 -b a -n 192.168.1.45 -y

    # 部分参数交互
    $0 -m 2
    # > 请输入 broker ID (a/b) [a]:
    # > 请输入额外 namesrv IP (可选，回车跳过):
EOF
}

# === 命令行参数解析 ===
parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -d|--dir)
                [[ -n "${2:-}" ]] || { log_error "-d|--dir 参数需要提供目录路径"; show_help; exit 1; }
                INSTALL_DIR="$2"
                shift 2
                ;;
            -m|--mode)
                [[ -n "${2:-}" ]] || { log_error "-m|--mode 参数需要提供模式"; show_help; exit 1; }
                case "$2" in
                    standalone|1|2|3) MODE="$2" ;;
                    *) log_error "无效的模式 '$2'，支持: standalone, 1, 2, 3"; show_help; exit 1 ;;
                esac
                shift 2
                ;;
            -b|--broker)
                [[ -n "${2:-}" ]] || { log_error "-b|--broker 参数需要提供 broker ID"; show_help; exit 1; }
                [[ "$2" =~ ^[ab]$ ]] || { log_error "无效的 broker ID '$2'，支持: a, b"; exit 1; }
                BROKER_ID="$2"
                shift 2
                ;;
            -n|--namesrv)
                [[ -n "${2:-}" ]] || { log_error "-n|--namesrv 参数需要提供 IP 地址"; show_help; exit 1; }
                validate_ip "$2" || { log_error "无效的 IP 地址: $2"; exit 1; }
                NAMESRV_IP="$2"
                shift 2
                ;;
            -y|--yes)
                AUTO_YES=1
                shift
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            *)
                log_error "未知参数: $1"
                show_help
                exit 1
                ;;
        esac
    done
}

# === 交互式补全 ===
prompt_mode() {
    [[ -n "$MODE" ]] && return 0

    echo
    echo "请选择部署模式:"
    echo "  standalone  单机模式 (1 NameServer + 1 Broker，开发测试用)"
    echo "  1           ${MODE_DESC[1]}"
    echo "  2           ${MODE_DESC[2]}"
    echo "  3           ${MODE_DESC[3]}"
    printf "请输入 [standalone/1/2/3] (默认: standalone): "
    read -r answer
    case "$answer" in
        "") MODE="standalone" ;;
        standalone|1|2|3) MODE="$answer" ;;
        *) log_error "无效的选择: $answer"; exit 1 ;;
    esac
}

prompt_broker_id() {
    [[ "$MODE" == "standalone" || "$MODE" == "1" ]] && return 0
    [[ -n "$BROKER_ID" ]] && return 0

    printf "请输入 broker ID (a/b) [默认: a]: "
    read -r answer
    case "$answer" in
        "") BROKER_ID="a" ;;
        a|b) BROKER_ID="$answer" ;;
        *) log_error "无效的 broker ID: $answer (仅支持 a/b)"; exit 1 ;;
    esac
}

prompt_namesrv() {
    [[ -n "$NAMESRV_IP" ]] && return 0
    # 自动化模式下未显式指定额外 NameServer，按“无需额外节点”处理。
    [[ "$AUTO_YES" -eq 1 ]] && return 0

    printf "请输入额外 namesrv IP (可选，多节点集群使用，回车跳过): "
    read -r answer
    if [[ -n "$answer" ]]; then
        validate_ip "$answer" || { log_error "无效的 IP 地址: $answer"; exit 1; }
        NAMESRV_IP="$answer"
    fi
}

confirm_start() {
    [[ "$AUTO_YES" -eq 1 ]] && return 0

    echo
    echo "========================================"
    echo " 配置摘要"
    echo "========================================"
    echo " 安装目录: $INSTALL_DIR"
    echo " 部署模式: $(mode_display_name)"
    if [[ "$MODE" != "standalone" ]]; then
        echo " Broker ID: $BROKER_ID"
    fi
    echo " NameServer: $IP:9876${NAMESRV_IP:+;$NAMESRV_IP:9876}"
    echo " 操作系统: $OS"
    echo "========================================"
    printf "确认启动？[Y/n]: "
    read -r answer
    case "$answer" in
        ""|y|Y|yes|YES) return 0 ;;
        *) log_info "已取消启动"; exit 0 ;;
    esac
}

mode_display_name() {
    case "$MODE" in
        standalone) printf "单机模式 (standalone)" ;;
        1|2|3) printf "%s" "${MODE_DESC[$MODE]}" ;;
        *) printf "未知" ;;
    esac
}

# === 配置修改函数 ===
modify_config_value() {
    local key="$1"
    local value="$2"
    local conf_file="$3"

    log_info "修改配置: $conf_file: $key=$value"
    [ ! -f "$conf_file" ] && touch "$conf_file"
    sed -i.bak "/^[[:space:]]*#*[[:space:]]*$key=/d" "$conf_file" 2>/dev/null || true
    echo "$key=$value" >> "$conf_file"
    rm -f "${conf_file}.bak" 2>/dev/null || true
}

# === 单机模式启动 ===
start_standalone() {
    local bin_dir="$INSTALL_DIR/bin"
    local log_dir="$INSTALL_DIR/logs"

    if [ ! -f "$bin_dir/mqnamesrv" ]; then
        log_error "NameServer 启动脚本不存在: $bin_dir/mqnamesrv"
        exit 1
    fi

    mkdir -p "$log_dir"

    # 设置 JAVA_HOME
    if [[ -z "${JAVA_HOME:-}" ]]; then
        if command -v java >/dev/null 2>&1; then
            export JAVA_HOME="$(dirname "$(dirname "$(command -v java)")")"
        else
            log_error "未找到 java 命令，请先安装 JDK 8+"
            exit 1
        fi
    fi
    export ROCKETMQ_HOME="$INSTALL_DIR"

    log_info "启动 NameServer (单机模式)"
    nohup "$bin_dir/mqnamesrv" > "$log_dir/namesrv.log" 2>&1 &
    local namesrv_pid=$!
    sleep 3

    if ! kill -0 "$namesrv_pid" 2>/dev/null; then
        log_error "NameServer 启动失败，查看日志: $log_dir/namesrv.log"
        exit 1
    fi
    log_info "NameServer 启动成功，PID: $namesrv_pid"
    create_pid_file "namesrv" "$namesrv_pid" "$INSTALL_DIR"

    log_info "启动 Broker (单机模式)"
    nohup sh "$bin_dir/mqbroker" -n "127.0.0.1:9876" autoCreateTopicEnable=true > "$log_dir/broker.log" 2>&1 &
    local broker_pid=$!
    sleep 5

    if ! kill -0 "$broker_pid" 2>/dev/null; then
        log_error "Broker 启动失败，查看日志: $log_dir/broker.log"
        exit 1
    fi
    log_info "Broker 启动成功，PID: $broker_pid"
    create_pid_file "broker-standalone" "$broker_pid" "$INSTALL_DIR"

    echo
    echo "单机模式启动完成:"
    echo "  NameServer: 127.0.0.1:9876 (PID: $namesrv_pid)"
    echo "  Broker:     127.0.0.1:10911 (PID: $broker_pid)"
    echo "  日志目录: $log_dir"
}

# === NameServer 启动 ===
start_namesrv() {
    local bin_dir="$INSTALL_DIR/bin"
    local namesrv_port="${1:-9876}"

    if [ ! -f "$bin_dir/mqnamesrv" ]; then
        log_error "NameServer 启动脚本不存在: $bin_dir/mqnamesrv"
        exit 1
    fi

    setup_jdk_env "$bin_dir/mqnamesrv" "$OS"
    export ROCKETMQ_HOME="$INSTALL_DIR"

    log_info "启动 NameServer"
    nohup "$bin_dir/mqnamesrv" -n "$IP:$namesrv_port" > /dev/null 2>&1 &
    local pid=$!
    create_pid_file "namesrv" "$pid" "$INSTALL_DIR"
    sleep 3

    if kill -0 "$pid" 2>/dev/null || pgrep -f "mqnamesrv" > /dev/null; then
        log_info "NameServer 启动成功，PID: $pid"
        return 0
    else
        log_error "NameServer 启动失败"
        return 1
    fi
}

# === Broker 启动 ===
start_broker() {
    local broker_conf="$1"
    local auto_create_topic="${2:-true}"
    local bin_dir="$INSTALL_DIR/bin"

    if [ ! -f "$bin_dir/mqbroker" ]; then
        log_error "Broker 启动脚本不存在: $bin_dir/mqbroker"
        exit 1
    fi
    if [ ! -f "$broker_conf" ]; then
        log_error "Broker 配置文件不存在: $broker_conf"
        return 1
    fi

    setup_jdk_env "$bin_dir/mqbroker" "$OS"
    setup_jdk_env "$bin_dir/runbroker.sh" "$OS"
    export ROCKETMQ_HOME="$INSTALL_DIR"

    log_info "启动 Broker: $broker_conf"
    nohup sh "$bin_dir/mqbroker" -c "$broker_conf" -n "$IP:9876" \
        autoCreateTopicEnable="$auto_create_topic" > /dev/null 2>&1 &
    local pid=$!
    create_pid_file "broker-$(basename "$broker_conf" .properties)" "$pid" "$INSTALL_DIR"
    sleep 5

    if kill -0 "$pid" 2>/dev/null || pgrep -f "mqbroker" > /dev/null; then
        log_info "Broker 启动成功，配置: $broker_conf, PID: $pid"
        return 0
    else
        log_error "Broker 启动失败"
        return 1
    fi
}

# === 2m-noslave 模式 ===
start_2m_noslave_mode() {
    local conf_subdir="2m-noslave"
    local conf_dir="$INSTALL_DIR/conf/$conf_subdir"
    mkdir -p "$conf_dir"

    local broker_a_conf="$conf_dir/broker-a.properties"
    local broker_b_conf="$conf_dir/broker-b.properties"

    if [ -f "$INSTALL_DIR/conf/broker.conf" ]; then
        cp "$INSTALL_DIR/conf/broker.conf" "$broker_a_conf" 2>/dev/null || > "$broker_a_conf"
        cp "$INSTALL_DIR/conf/broker.conf" "$broker_b_conf" 2>/dev/null || > "$broker_b_conf"
    else
        > "$broker_a_conf"; > "$broker_b_conf"
    fi

    validate_config "$broker_a_conf" || { log_error "Broker A 配置验证失败"; exit 1; }
    validate_config "$broker_b_conf" || { log_error "Broker B 配置验证失败"; exit 1; }

    modify_config_value "listenPort" "10911" "$broker_a_conf"
    modify_config_value "brokerId" "0" "$broker_a_conf"
    modify_config_value "namesrvAddr" "$IP:9876${NAMESRV_IP:+;$NAMESRV_IP:9876}" "$broker_a_conf"

    modify_config_value "listenPort" "10912" "$broker_b_conf"
    modify_config_value "brokerId" "0" "$broker_b_conf"
    modify_config_value "namesrvAddr" "$IP:9876${NAMESRV_IP:+;$NAMESRV_IP:9876}" "$broker_b_conf"

    start_namesrv
    start_broker "$broker_a_conf"
    start_broker "$broker_b_conf"
}

# === 主从模式 (2/3) ===
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

    local master_conf="$conf_dir/broker-$BROKER_ID.properties"
    local slave_conf="$conf_dir/broker-$BROKER_ID-s.properties"

    if [ -f "$INSTALL_DIR/conf/broker.conf" ]; then
        cp "$INSTALL_DIR/conf/broker.conf" "$master_conf" 2>/dev/null || > "$master_conf"
        cp "$INSTALL_DIR/conf/broker.conf" "$slave_conf" 2>/dev/null || > "$slave_conf"
    else
        > "$master_conf"; > "$slave_conf"
    fi

    validate_config "$master_conf" || { log_error "Master Broker 配置验证失败"; exit 1; }
    validate_config "$slave_conf" || { log_error "Slave Broker 配置验证失败"; exit 1; }

    modify_config_value "listenPort" "10911" "$master_conf"
    modify_config_value "brokerId" "0" "$master_conf"
    if [ "$mode" = "2" ]; then
        modify_config_value "brokerRole" "ASYNC_MASTER" "$master_conf"
    else
        modify_config_value "brokerRole" "SYNC_MASTER" "$master_conf"
    fi
    modify_config_value "namesrvAddr" "$IP:9876${NAMESRV_IP:+;$NAMESRV_IP:9876}" "$master_conf"

    modify_config_value "listenPort" "10912" "$slave_conf"
    modify_config_value "brokerId" "1" "$slave_conf"
    modify_config_value "brokerRole" "SLAVE" "$slave_conf"
    modify_config_value "namesrvAddr" "$IP:9876${NAMESRV_IP:+;$NAMESRV_IP:9876}" "$slave_conf"

    start_namesrv
    start_broker "$master_conf"
    start_broker "$slave_conf"
}

# === 健康检查 ===
health_check() {
    log_info "健康检查..."
    local namesrv_addr="$IP:9876"
    if check_namesrv_health "$namesrv_addr"; then
        log_info "NameServer 健康检查通过"
    else
        log_warn "NameServer 健康检查失败"
    fi

    case "$MODE" in
        standalone)
            check_broker_health "127.0.0.1:10911" && log_info "Broker 健康检查通过" || log_warn "Broker 健康检查未就绪"
            ;;
        1)
            check_broker_health "$IP:10911" && log_info "Broker A 健康检查通过" || log_warn "Broker A 健康检查失败"
            check_broker_health "$IP:10912" && log_info "Broker B 健康检查通过" || log_warn "Broker B 健康检查失败"
            ;;
        2|3)
            check_broker_health "$IP:10911" && log_info "Master Broker 健康检查通过" || log_warn "Master Broker 健康检查失败"
            check_broker_health "$IP:10912" && log_info "Slave Broker 健康检查通过" || log_warn "Slave Broker 健康检查失败"
            ;;
    esac
}

# === 主函数 ===
main() {
    parse_arguments "$@"

    log_info "开始启动 RocketMQ"

    # 检查安装目录
    if [ ! -d "$INSTALL_DIR" ]; then
        log_error "安装目录不存在: $INSTALL_DIR"
        exit 1
    fi
    log_info "安装目录: $INSTALL_DIR"

    # 获取系统信息
    IP=$(get_ip)
    if [ -z "$IP" ]; then
        log_error "无法获取本机 IP 地址"
        exit 1
    fi
    OS=$(get_os)
    log_info "操作系统: $OS, IP 地址: $IP"

    # 交互式补全缺失参数
    prompt_mode
    prompt_broker_id
    prompt_namesrv

    # 确认启动
    confirm_start

    log_info "部署模式: $(mode_display_name)"

    # 检查是否已在运行
    if pgrep -f 'mqnamesrv|org\.apache\.rocketmq\.namesrv\.NamesrvStartup' >/dev/null 2>&1 \
        || pgrep -f 'mqbroker|org\.apache\.rocketmq\.broker\.BrokerStartup' >/dev/null 2>&1; then
        log_warn "检测到 RocketMQ 进程已在运行:"
        pgrep -f 'mqnamesrv|mqbroker|org\.apache\.rocketmq\.(namesrv\.NamesrvStartup|broker\.BrokerStartup)' -l 2>/dev/null || true
        log_warn "如需重启，请先执行: $SCRIPT_DIR/stop.sh --dir \"$INSTALL_DIR\""
        exit 0
    fi

    # 根据模式启动
    case "$MODE" in
        standalone)
            start_standalone
            ;;
        1)
            start_2m_noslave_mode
            ;;
        2|3)
            start_m_s_mode "$MODE"
            ;;
    esac

    # 等待服务完全启动
    log_info "等待服务启动..."
    sleep 5

    # 健康检查
    health_check

    # 显示进程
    log_info "当前运行的 RocketMQ 进程:"
    pgrep -f 'mqnamesrv|mqbroker|org\.apache\.rocketmq\.(namesrv\.NamesrvStartup|broker\.BrokerStartup)' -l || true

    echo
    log_info "RocketMQ 启动完成"
    echo "  NameServer: $IP:9876"
    echo "  配置文件: $INSTALL_DIR/conf/"
    echo "  停止命令: $SCRIPT_DIR/stop.sh --dir \"$INSTALL_DIR\""
}

main "$@"
