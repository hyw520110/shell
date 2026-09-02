#!/bin/bash
# Ganache 一键管理脚本
# 支持 Linux 和 macOS，支持重复执行
# 用法：./ganache.sh [命令] [选项]

set -e
set -u
set -o pipefail

# 获取脚本所在目录
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
BIN_DIR="$SCRIPT_DIR/bin"

# 导入通用函数
# shellcheck source=bin/common.sh
source "$BIN_DIR/common.sh"

# 配置
CONFIG_DIR="$HOME/.ganache"
CONFIG_FILE="$CONFIG_DIR/config.json"
LOG_FILE="$CONFIG_DIR/logs/ganache.log"
PID_FILE="$CONFIG_DIR/ganache.pid"

# 显示帮助信息
show_usage() {
    cat << EOF
Ganache 一键管理脚本

用法：$0 [命令] [选项]

命令:
  install         安装 Ganache
  configure       配置 Ganache
  uninstall       卸载 Ganache
  start           启动 Ganache
  stop            停止 Ganache
  restart         重启 Ganache
  status          查看 Ganache 状态
  logs            查看 Ganache 日志
  version         显示 Ganache 版本

选项:
  -h, --help      显示帮助信息
  -v, --version   显示 Ganache 版本

安装选项:
  -v, --version <版本>   指定 Ganache 版本 (默认：latest)
  -m, --mirror <镜像>    指定 npm 镜像源 (cnpm|taobao|official)
  -f, --force            强制重新安装

配置选项:
  --port <端口>          RPC 监听端口 (默认：8545)
  --network-id <ID>      网络 ID (默认：5777)
  --accounts <数量>      生成账户数量 (默认：10)
  --balance <ETH>        每个账户的 ETH 余额 (默认：100)
  --gas-limit <限制>     Gas 限制 (默认：6721975)
  --gas-price <价格>     Gas 价格 (默认：20000000000)
  --host <主机>          监听主机 (默认：127.0.0.1)
  --db-path <路径>       数据库路径
  --reset                重置为默认配置

卸载选项:
  -f, --force            强制卸载，不确认
  --keep-config          保留配置文件和数据

启动选项:
  -d, --detach           后台运行
  --port <端口>          覆盖配置文件的端口
  --host <主机>          覆盖配置文件的主机

示例:
  # 安装和管理
  $0 install                      # 安装 Ganache
  $0 install -v 7.9.1             # 安装指定版本
  $0 install -m taobao            # 使用淘宝镜像源安装
  $0 configure                    # 配置 Ganache
  $0 uninstall                    # 卸载 Ganache
  $0 uninstall --keep-config      # 卸载但保留配置

  # 运行控制
  $0 start                        # 启动 Ganache
  $0 start -d                     # 后台启动
  $0 start --port 7545            # 指定端口启动
  $0 stop                         # 停止 Ganache
  $0 restart                      # 重启 Ganache
  $0 status                       # 查看状态
  $0 logs                         # 查看日志
  $0 logs -f                      # 实时查看日志

  # 其他
  $0 version                      # 显示版本
  $0 --help                       # 显示帮助

快速开始:
  1. 安装：$0 install
  2. 配置：$0 configure
  3. 启动：$0 start
  4. 查看状态：$0 status

配置文件:
  位置：$CONFIG_FILE
  日志：$LOG_FILE

EOF
}

# 显示版本
show_version() {
    echo "Ganache 管理脚本 v1.0.0"
    echo ""
    
    if check_ganache_installed; then
        echo "Ganache 版本：$(get_ganache_version)"
    else
        echo "Ganache 未安装"
    fi
}

# 安装 Ganache
cmd_install() {
    shift # 移除命令本身
    "$BIN_DIR/install.sh" "$@"
}

# 配置 Ganache
cmd_configure() {
    shift # 移除命令本身
    "$BIN_DIR/configure.sh" "$@"
}

# 卸载 Ganache
cmd_uninstall() {
    shift # 移除命令本身
    "$BIN_DIR/uninstall.sh" "$@"
}

# 启动 Ganache
cmd_start() {
    shift # 移除命令本身
    local detach=false
    local port=""
    local host=""
    
    # 解析参数
    while [[ $# -gt 0 ]]; do
        case $1 in
            -d|--detach)
                detach=true
                shift
                ;;
            --port)
                port="$2"
                shift 2
                ;;
            --host)
                host="$2"
                shift 2
                ;;
            *)
                log_error "未知参数：$1"
                echo "使用 '$0 start --help' 查看帮助"
                exit 1
                ;;
        esac
    done
    
    # 检查 Ganache 是否已安装
    if ! check_ganache_installed; then
        log_error "Ganache 未安装，请先运行：$0 install"
        exit 1
    fi
    
    # 检查是否已在运行
    if check_ganache_running; then
        log_warn "Ganache 已在运行"
        show_status
        return 0
    fi
    
    # 创建配置目录
    mkdir -p "$CONFIG_DIR"
    mkdir -p "$(dirname "$LOG_FILE")"

    # 构建启动命令
    local ganache_cmd="ganache"
    local args=()

    # Ganache v7.x 不支持 --config 参数，使用命令行参数启动
    # 从配置文件读取参数（如果存在）
    if [[ -f "$CONFIG_FILE" ]] && command -v python3 &> /dev/null; then
        log "使用配置文件：$CONFIG_FILE"
        
        # 从配置文件读取参数
        local config_port config_host config_network_id config_accounts config_balance config_gas_limit config_gas_price config_db_path
        config_port=$(python3 -c "import json; print(json.load(open('$CONFIG_FILE')).get('port', 8545))" 2>/dev/null || echo "")
        config_host=$(python3 -c "import json; print(json.load(open('$CONFIG_FILE')).get('host', '127.0.0.1'))" 2>/dev/null || echo "")
        config_network_id=$(python3 -c "import json; print(json.load(open('$CONFIG_FILE')).get('networkId', 5777))" 2>/dev/null || echo "")
        config_accounts=$(python3 -c "import json; print(json.load(open('$CONFIG_FILE')).get('totalAccounts', 10))" 2>/dev/null || echo "")
        config_balance=$(python3 -c "import json; print(json.load(open('$CONFIG_FILE')).get('defaultBalanceETH', 100))" 2>/dev/null || echo "")
        config_gas_limit=$(python3 -c "import json; print(json.load(open('$CONFIG_FILE')).get('gasLimit', 6721975))" 2>/dev/null || echo "")
        config_gas_price=$(python3 -c "import json; print(json.load(open('$CONFIG_FILE')).get('gasPrice', 20000000000))" 2>/dev/null || echo "")
        config_db_path=$(python3 -c "import json; print(json.load(open('$CONFIG_FILE')).get('dbPath', ''))" 2>/dev/null || echo "")
        
        # 使用配置文件的参数，命令行参数可覆盖
        args+=("--port" "${port:-$config_port}")
        args+=("--host" "${host:-$config_host}")
        args+=("--networkId" "${config_network_id}")
        args+=("--wallet.totalAccounts" "${config_accounts}")
        args+=("--wallet.defaultBalance" "${config_balance}")
        args+=("--gasLimit" "${config_gas_limit}")
        args+=("--gasPrice" "${config_gas_price}")
        
        if [[ -n "$config_db_path" ]]; then
            args+=("--db" "$config_db_path")
        fi
    else
        # 没有配置文件或 python3，使用默认参数
        log "使用默认配置启动"
        args+=("--port" "${port:-8545}")
        args+=("--host" "${host:-127.0.0.1}")
        args+=("--networkId" "5777")
        args+=("--wallet.totalAccounts" "10")
        args+=("--wallet.defaultBalance" "100")
    fi

    log "启动 Ganache..."

    if [[ "$detach" == true ]]; then
        # 后台运行
        log "后台运行模式"
        
        # 使用 ganache 直接启动，通过 PID 文件跟踪
        # 注意：在 macOS 上，后台运行可能会在终端关闭后停止
        # 建议使用系统服务 (systemd/launchd) 来长期运行
        
        "$ganache_cmd" "${args[@]}" > "$LOG_FILE" 2>&1 &
        local pid=$!
        
        # 短暂等待，确认进程启动
        sleep 1
        
        if ps -p "$pid" > /dev/null; then
            echo "$pid" > "$PID_FILE"
            log_success "Ganache 已启动 (PID: $pid)"
            log "日志文件：$LOG_FILE"
            log "注意：后台模式在终端关闭后可能会停止"
            log "长期运行请使用：launchctl load ~/Library/LaunchAgents/com.trufflesuite.ganache.plist"
        else
            log_error "Ganache 启动失败，查看日志：$LOG_FILE"
            exit 1
        fi
    else
        # 前台运行
        log "前台运行模式 (Ctrl+C 停止)"
        log ""
        "$ganache_cmd" "${args[@]}"
    fi
}

# 停止 Ganache
cmd_stop() {
    log "停止 Ganache..."
    
    # 尝试从 PID 文件停止
    if [[ -f "$PID_FILE" ]]; then
        local pid
        pid=$(cat "$PID_FILE")
        if ps -p "$pid" > /dev/null 2>&1; then
            kill "$pid" 2>/dev/null || true
            sleep 2
            if ! ps -p "$pid" > /dev/null 2>&1; then
                rm -f "$PID_FILE"
                log_success "Ganache 已停止 (PID: $pid)"
                return 0
            fi
        fi
        rm -f "$PID_FILE"
    fi
    
    # 使用 pkill 停止
    if pgrep -f "ganache" > /dev/null; then
        pkill -TERM -f "ganache" 2>/dev/null || true
        sleep 3
        
        if pgrep -f "ganache" > /dev/null; then
            log_warn "Ganache 未响应，强制停止"
            pkill -KILL -f "ganache" 2>/dev/null || true
        fi
        
        log_success "Ganache 已停止"
    else
        log "Ganache 未运行"
    fi
}

# 重启 Ganache
cmd_restart() {
    log "重启 Ganache..."
    cmd_stop
    sleep 2
    cmd_start "$@"
}

# 查看状态
cmd_status() {
    show_status
}

# 显示状态
show_status() {
    echo ""
    log "Ganache 状态"
    echo "================================"
    
    # 检查是否安装
    if check_ganache_installed; then
        echo -e "安装状态： ${GREEN}已安装${NC}"
        echo "版本：$(get_ganache_version)"
    else
        echo -e "安装状态： ${RED}未安装${NC}"
    fi
    
    # 检查是否运行
    if check_ganache_running; then
        echo -e "运行状态： ${GREEN}运行中${NC}"
        
        # 显示进程信息
        local pid
        pid=$(pgrep -f "ganache" | head -1)
        echo "进程 ID: $pid"
        
        # 显示监听端口
        if command -v lsof &> /dev/null; then
            local port_info
            port_info=$(lsof -i -P -n | grep -i ganache | grep LISTEN | awk '{print $9}' | cut -d':' -f2)
            if [[ -n "$port_info" ]]; then
                echo "监听端口：$port_info"
            fi
        fi
    else
        echo -e "运行状态： ${YELLOW}未运行${NC}"
    fi
    
    # 配置文件
    echo ""
    echo "配置文件:"
    if [[ -f "$CONFIG_FILE" ]]; then
        echo -e "  位置： ${CONFIG_FILE}"
        
        # 显示关键配置
        if command -v python3 &> /dev/null; then
            echo "  配置:"
            python3 -c "
import json
with open('$CONFIG_FILE') as f:
    config = json.load(f)
    print(f\"    端口：{config.get('port', 'N/A')}\")
    print(f\"    主机：{config.get('host', 'N/A')}\")
    print(f\"    网络 ID: {config.get('networkId', 'N/A')}\")
    print(f\"    账户数：{config.get('totalAccounts', 'N/A')}\")
" 2>/dev/null || true
        fi
    else
        echo -e "  位置： ${YELLOW}未生成${NC}"
    fi
    
    # 日志文件
    echo ""
    echo "日志文件:"
    if [[ -f "$LOG_FILE" ]]; then
        local size
        size=$(du -h "$LOG_FILE" | cut -f1)
        echo -e "  位置：$LOG_FILE (${size})"
        echo "  最后更新：$(stat -f '%Sm' -t '%Y-%m-%d %H:%M:%S' "$LOG_FILE" 2>/dev/null || stat -c '%y' "$LOG_FILE" 2>/dev/null | cut -d'.' -f1)"
    else
        echo -e "  位置： ${YELLOW}不存在${NC}"
    fi
    
    echo ""
}

# 查看日志
cmd_logs() {
    shift # 移除命令本身
    local follow=false

    # 解析参数
    while [[ $# -gt 0 ]]; do
        case $1 in
            -f|--follow)
                follow=true
                shift
                ;;
            *)
                shift
                ;;
        esac
    done
    
    if [[ ! -f "$LOG_FILE" ]]; then
        log "日志文件不存在：$LOG_FILE"
        
        # 尝试查看系统日志
        if check_ganache_running; then
            log "Ganache 正在运行，但日志文件不存在"
            log "进程输出可能直接显示在终端"
        fi
        return 0
    fi
    
    if [[ "$follow" == true ]]; then
        log "实时查看日志 (Ctrl+C 退出)..."
        tail -f "$LOG_FILE"
    else
        log "显示日志内容..."
        cat "$LOG_FILE"
    fi
}

# 主函数
main() {
    # 没有参数时显示帮助
    if [[ $# -eq 0 ]]; then
        show_usage
        exit 0
    fi
    
    local command="$1"
    
    case $command in
        install)
            cmd_install "$@"
            ;;
        configure)
            cmd_configure "$@"
            ;;
        uninstall)
            cmd_uninstall "$@"
            ;;
        start)
            cmd_start "$@"
            ;;
        stop)
            cmd_stop
            ;;
        restart)
            cmd_restart "${@:2}"
            ;;
        status)
            cmd_status
            ;;
        logs)
            cmd_logs "$@"
            ;;
        version|-v|--version)
            show_version
            ;;
        -h|--help|help)
            show_usage
            ;;
        *)
            log_error "未知命令：$command"
            echo ""
            show_usage
            exit 1
            ;;
    esac
}

# 执行主函数
main "$@"
