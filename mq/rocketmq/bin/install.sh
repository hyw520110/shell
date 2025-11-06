#!/bin/bash

# RocketMQ 安装脚本
# 版本: 2.4
# 用途: 安装和配置 RocketMQ 集群

set -euo pipefail  # 严格错误处理模式

# === 引入公共函数库 ===
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

# === 配置参数 ===
# 使用common.sh中的默认值

# === 全局变量 ===
ROCKETMQ_HOME=""
INSTALL_DIR="$DEFAULT_INSTALL_DIR"
CONF_DIR=""
IP=""
OS=""
FORCE_STOP=false
ACTION="install"  # install, uninstall, stop
DOWNLOAD_URL="$DEFAULT_DOWNLOAD_URL"
LOG_FILE="/tmp/rocketmq_install.log"

# === 帮助信息 ===
show_help() {
    cat << EOF
用法: $0 [选项]

选项:
    -d, --dir DIR     指定安装目录 (默认: $DEFAULT_INSTALL_DIR)
    -v, --version V   指定RocketMQ版本 (默认: $DEFAULT_VERSION)
    --uninstall       卸载 RocketMQ
    -h, --help        显示此帮助信息

示例:
    $0                                    # 安装到默认目录
    $0 -d /opt/rocketmq                   # 安装到 /opt/rocketmq
    $0 --dir /usr/local/rocketmq          # 安装到 /usr/local/rocketmq
    $0 -v 5.1.4                          # 安装指定版本
    $0 --uninstall                        # 卸载 RocketMQ
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
                    log_error "错误: -d|--dir 参数需要提供目录路径"
                    show_help
                    exit 1
                fi
                ;;
            -v|--version)
                if [[ -n "${2:-}" ]]; then
                    DEFAULT_VERSION="$2"
                    DOWNLOAD_URL="https://dist.apache.org/repos/dist/release/rocketmq/${DEFAULT_VERSION}/rocketmq-all-${DEFAULT_VERSION}-bin-release.zip"
                    shift 2
                else
                    log_error "错误: -v|--version 参数需要提供版本号"
                    show_help
                    exit 1
                fi
                ;;
            --uninstall)
                ACTION="uninstall"
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

# === 日志函数 ===
# 使用common.sh中的日志函数

# === 错误处理 ===
handle_error() {
    local line_number="$1"
    local command="$2"
    log_error "命令失败: $command (第 $line_number 行)"
    cleanup_and_exit 1
}

trap 'handle_error $LINENO "$BASH_COMMAND"' ERR

cleanup_and_exit() {
    log_info "清理并退出..."
    if [ "$ACTION" != "uninstall" ]; then
        call_stop_script ${FORCE_STOP:+-f} || true
    fi
    exit "$1"
}

# === 依赖检查 ===
check_dependencies() {
    local missing_deps=()
    
    # 必需工具检查
    for tool in "wget" "unzip" "rsync" "ssh" "ping"; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            missing_deps+=("$tool")
        fi
    done
    
    # 可选工具检查 - aria2c用于更快的下载
    if ! command -v aria2c >/dev/null 2>&1; then
        log_warn "未安装 aria2c，下载速度可能较慢"
    fi
    
    # 检查JDK
    if ! command -v java >/dev/null 2>&1; then
        log_error "未找到java命令，请先安装JDK 8或更高版本"
        exit 1
    fi
    
    if [ ${#missing_deps[@]} -gt 0 ]; then
        log_error "缺少必需的依赖: ${missing_deps[*]}"
        log_error "请安装这些工具后再运行脚本"
        exit 1
    fi
    
    log_info "所有必需依赖已安装"
}

# === 工具函数 ===
# 使用common.sh中的工具函数

# === 下载和验证函数 ===
download_file() {
    local url="${1:-$DEFAULT_DOWNLOAD_URL}"
    local dest="$2"
    
    log_info "正在下载: $url"
    
    # 检查是否已存在完整文件
    if [ -f "$dest" ]; then
        if check_zip_integrity "$dest"; then
            log_info "本地已存在完整的ZIP文件，跳过下载: $dest"
            return 0
        else
            log_info "本地ZIP文件不完整，重新下载"
        fi
    fi
    
    # 创建下载目录
    mkdir -p "$(dirname "$dest")"
    
    # 优先使用aria2c，否则使用wget，最后使用curl
    if command -v aria2c >/dev/null 2>&1; then
        log_info "使用 aria2c 进行多线程下载"
        aria2c -c -x 8 -s 8 --allow-overwrite=true -d "$(dirname "$dest")" -o "$(basename "$dest")" "$url" || {
            log_error "aria2c 下载失败"
            return 1
        }
    elif command -v wget >/dev/null 2>&1; then
        log_info "使用 wget 下载"
        if wget --tries=3 --timeout=30 -c -O "$dest" "$url"; then
            true
        else
            log_error "wget 下载失败"
            return 1
        fi
    elif command -v curl >/dev/null 2>&1; then
        log_info "使用 curl 下载"
        if curl --retry 3 --connect-timeout 30 -C - -o "$dest" "$url"; then
            true
        else
            log_error "curl 下载失败"
            return 1
        fi
    else
        log_error "系统中未找到 wget、curl 或 aria2c 命令，无法下载"
        return 1
    fi
    
    log_info "下载完成: $dest"
    return 0
}

check_zip_integrity() {
    local zip_file="$1"
    log_info "检查ZIP文件完整性: $zip_file"
    
    # 检查文件是否存在和大小
    if [ ! -f "$zip_file" ]; then
        log_error "ZIP文件不存在: $zip_file"
        return 1
    fi
    
    local file_size
    file_size=$(stat -c %s "$zip_file" 2>/dev/null || stat -f %z "$zip_file" 2>/dev/null || echo "0")
    if [ "$file_size" -lt 1024 ]; then
        log_error "ZIP文件太小，可能不完整: $file_size 字节"
        return 1
    fi
    
    # 使用unzip检查文件完整性
    if ! unzip -t "$zip_file" >/dev/null 2>&1; then
        log_error "ZIP文件完整性检查失败"
        return 1
    fi
    
    log_info "ZIP文件完整性检查通过"
    return 0
}

# === 安装和配置 ===
install_rocketmq() {
    local download_url="${1:-$DOWNLOAD_URL}"
    local zip_file=$(basename "$download_url")
    local extract_dir=$(basename "${download_url%.*}")
    
    # 检查是否已安装
    if [ -d "$INSTALL_DIR/bin" ] && [ -d "$INSTALL_DIR/conf" ] && [ -d "$INSTALL_DIR/lib" ]; then
        log_info "RocketMQ 已安装在 $INSTALL_DIR"
        return 0
    fi
    
    log_info "开始下载和安装 RocketMQ"
    
    # 下载文件
    local download_path="$DOWNLOAD_DIR/$zip_file"
    download_file "$download_url" "$download_path" || {
        log_error "下载失败，退出安装"
        exit 1
    }
    
    # 验证下载
    if ! check_zip_integrity "$download_path"; then
        log_error "下载文件验证失败，退出安装"
        exit 1
    fi
    
    # 解压
    log_info "解压文件到 $TEMP_EXTRACT_DIR"
    mkdir -p "$TEMP_EXTRACT_DIR"
    unzip -d "$TEMP_EXTRACT_DIR" "$download_path" || {
        log_error "解压失败，请检查文件完整性"
        exit 1
    }
    
    # 移动到安装目录
    log_info "移动文件到安装目录: $INSTALL_DIR"
    mkdir -p "$(dirname "$INSTALL_DIR")"
    mv "$TEMP_EXTRACT_DIR/$extract_dir" "$INSTALL_DIR" || {
        log_error "移动文件失败"
        exit 1
    }
    
    # 清理临时文件
    rm -f "$download_path"
    
    log_info "RocketMQ 安装完成: $INSTALL_DIR"
}

setup_config() {
    ROCKETMQ_HOME="$INSTALL_DIR"
    CONF_DIR="$INSTALL_DIR/conf"
    
    log_info "设置配置目录: $CONF_DIR"
    mkdir -p "$CONF_DIR"
}

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

# === 服务控制函数 ===
# 调用独立的 start.sh 和 stop.sh 脚本来管理服务
call_stop_script() {
    local script_path="$SCRIPT_DIR/stop.sh"
    if [ -f "$script_path" ]; then
        log_info "调用停止脚本: $script_path"
        "$script_path" -d "$INSTALL_DIR" "$@"
    else
        log_error "停止脚本不存在: $script_path"
        return 1
    fi
}

call_start_script() {
    local script_path="$SCRIPT_DIR/start.sh"
    if [ -f "$script_path" ]; then
        log_info "调用启动脚本: $script_path"
        "$script_path" -d "$INSTALL_DIR" "$@"
    else
        log_error "启动脚本不存在: $script_path"
        return 1
    fi
}

# 使用common.sh中的check_running_processes函数

# === 卸载函数 ===
uninstall_rocketmq() {
    log_info "开始卸载 RocketMQ"
    
    # 停止所有相关进程
    call_stop_script ${FORCE_STOP:+-f}
    
    # 检查安装目录是否存在
    if [ ! -d "$INSTALL_DIR" ]; then
        log_warn "安装目录不存在: $INSTALL_DIR"
        return 0
    fi
    
    # 确认卸载
    echo "即将删除安装目录: $INSTALL_DIR"
    read -p "确定要卸载 RocketMQ 吗? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_info "取消卸载操作"
        return 0
    fi
    
    # 删除安装目录
    log_info "删除安装目录: $INSTALL_DIR"
    rm -rf "$INSTALL_DIR"
    
    # 删除日志文件
    if [ -f "$LOG_FILE" ]; then
        rm "$LOG_FILE"
    fi
    
    log_info "RocketMQ 卸载完成"
}

# === 环境设置函数 ===
# 使用common.sh中的setup_jdk_env函数

# === 集群配置函数 ===
setup_2m_noslave_mode() {
    local namesrv_ip="$1"
    
    log_info "配置 2m-noslave 模式"
    
    local conf_subdir="2m-noslave"
    local conf_dir="$CONF_DIR/$conf_subdir"
    mkdir -p "$conf_dir"
    
    # 创建基础配置文件
    local broker_a_conf="$conf_dir/broker-a.properties"
    local broker_b_conf="$conf_dir/broker-b.properties"
    
    # 创建基础配置文件（从默认配置复制或新建）
    if [ -f "$CONF_DIR/broker.conf" ]; then
        cp "$CONF_DIR/broker.conf" "$broker_a_conf" 2>/dev/null || > "$broker_a_conf"
        cp "$CONF_DIR/broker.conf" "$broker_b_conf" 2>/dev/null || > "$broker_b_conf"
    else
        > "$broker_a_conf"
        > "$broker_b_conf"
    fi
    
    # 修改配置文件
    modify_config_value "listenPort" "10911" "$broker_a_conf"
    modify_config_value "brokerId" "0" "$broker_a_conf"
    modify_config_value "namesrvAddr" "$IP:9876${namesrv_ip:+;$namesrv_ip:9876}" "$broker_a_conf"
    
    modify_config_value "listenPort" "10912" "$broker_b_conf"
    modify_config_value "brokerId" "0" "$broker_b_conf"
    modify_config_value "namesrvAddr" "$IP:9876${namesrv_ip:+;$namesrv_ip:9876}" "$broker_b_conf"
    
    log_info "配置文件已生成，请使用 start.sh 脚本启动服务"
}

setup_m_s_mode() {
    local mode="$1"
    local broker_id="$2"
    local namesrv_ip="$3"
    
    local conf_subdir=""
    if [ "$mode" = "2" ]; then
        conf_subdir="2m-2s-async"
        log_info "配置 2m-2s-async 模式"
    else
        conf_subdir="2m-2s-sync"
        log_info "配置 2m-2s-sync 模式"
    fi
    
    local conf_dir="$CONF_DIR/$conf_subdir"
    mkdir -p "$conf_dir"
    
    # 创建主从broker配置
    local master_conf="$conf_dir/broker-$broker_id.properties"
    local slave_conf="$conf_dir/broker-$broker_id-s.properties"
    
    # 创建基础配置文件
    if [ -f "$CONF_DIR/broker.conf" ]; then
        cp "$CONF_DIR/broker.conf" "$master_conf" 2>/dev/null || > "$master_conf"
        cp "$CONF_DIR/broker.conf" "$slave_conf" 2>/dev/null || > "$slave_conf"
    else
        > "$master_conf"
        > "$slave_conf"
    fi
    
    # 设置主broker配置
    modify_config_value "listenPort" "10911" "$master_conf"
    modify_config_value "brokerId" "0" "$master_conf"
    if [ "$mode" = "2" ]; then
        modify_config_value "brokerRole" "ASYNC_MASTER" "$master_conf"
    else
        modify_config_value "brokerRole" "SYNC_MASTER" "$master_conf"
    fi
    modify_config_value "namesrvAddr" "$IP:9876${namesrv_ip:+;$namesrv_ip:9876}" "$master_conf"
    
    # 设置从broker配置
    modify_config_value "listenPort" "10912" "$slave_conf"
    modify_config_value "brokerId" "1" "$slave_conf"
    modify_config_value "brokerRole" "SLAVE" "$slave_conf"
    modify_config_value "namesrvAddr" "$IP:9876${namesrv_ip:+;$namesrv_ip:9876}" "$slave_conf"
    
    log_info "配置文件已生成，请使用 start.sh 脚本启动服务"
}

# === 主函数 ===
main() {
    # 解析命令行参数
    parse_arguments "$@"
    
    log_info "开始执行操作: $ACTION"
    log_info "安装目录: $INSTALL_DIR"
    
    case $ACTION in
        install)
            # 初始化变量
            IP=$(get_ip)
            if [ -z "$IP" ]; then
                log_error "无法获取本机IP地址"
                exit 1
            fi
            
            OS=$(get_os)
            log_info "操作系统: $OS, IP地址: $IP"
            
            # 检查依赖
            check_dependencies
            
            # 检查是否已运行
            if check_running_processes; then
                echo "现有 RocketMQ 进程正在运行。"
                read -p "是否停止现有进程? (y/N): " -n 1 -r
                echo
                if [[ $REPLY =~ ^[Yy]$ ]]; then
                    call_stop_script ${FORCE_STOP:+-f}
                else
                    log_info "保持现有进程运行，退出安装"
                    exit 0
                fi
            fi
            
            # 安装 RocketMQ
            install_rocketmq "$DOWNLOAD_URL"
            setup_config
            
            # 选择部署模式
            echo
            echo "选择部署模式："
            echo "1) 2m-noslave (双主无从模式) - 适合开发环境"
            echo "2) 2m-2s-async (双主双从异步复制) - 适合生产环境"
            echo "3) 2m-2s-sync (双主双从同步复制) - 高可用性"
            
            local mode_choice
            read -p "请输入选择 (1-3) [默认1]: " mode_choice
            mode_choice=${mode_choice:-1}
            
            # 验证选择
            case $mode_choice in
                1|2|3)
                    log_info "选择模式: $mode_choice"
                    ;;
                *)
                    log_error "无效选择，使用默认模式 1"
                    mode_choice=1
                    ;;
            esac
            
            # 获取额外Namesrv IP（可选）
            local namesrv_ip=""
            read -p "输入额外的 namesrv IP (可选，直接回车跳过): " namesrv_ip
            if [ -n "$namesrv_ip" ]; then
                if ! validate_ip "$namesrv_ip"; then
                    log_error "无效的IP地址: $namesrv_ip"
                    exit 1
                fi
                log_info "配置额外 namesrv IP: $namesrv_ip"
            fi
            
            # 根据选择执行配置
            case $mode_choice in
                1)
                    setup_2m_noslave_mode "$namesrv_ip"
                    ;;
                2|3)
                    # 对于主从模式，需要选择broker id
                    local broker_choice
                    read -p "选择broker (a 或 b) [默认a]: " broker_choice
                    broker_choice=${broker_choice:-a}
                    
                    if [[ ! "$broker_choice" =~ ^[ab]$ ]]; then
                        log_error "无效选择，使用默认值 a"
                        broker_choice="a"
                    fi
                    
                    setup_m_s_mode "$mode_choice" "$broker_choice" "$namesrv_ip"
                    ;;
            esac
            
            log_info "RocketMQ 安装和配置完成！"
            
            # 自动启动RocketMQ服务
            log_info "正在启动 RocketMQ 服务..."
            # 根据选择的模式调用启动脚本
            if [ "$mode_choice" = "1" ]; then
                call_start_script -m "$mode_choice"
            else
                call_start_script -m "$mode_choice" -b "$broker_choice"
            fi
            
            echo
            echo "启动脚本位于: $INSTALL_DIR/bin/"
            echo "配置文件位于: $CONF_DIR/"
            ;;
        uninstall)
            log_info "执行卸载操作"
            uninstall_rocketmq
            ;;
    esac
}

# === 执行主函数 ===
main "$@"