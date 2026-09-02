#!/bin/bash
# Ganache 配置脚本
# 支持 Linux 和 macOS，支持重复执行
# 用法：./configure.sh [选项]

set -e
set -u
set -o pipefail

# 获取脚本所在目录
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"

# 导入通用函数
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

# 默认配置
CONFIG_DIR="$HOME/.ganache"
CONFIG_FILE="$CONFIG_DIR/config.json"
DEFAULT_PORT=8545
DEFAULT_NETWORK_ID=5777
DEFAULT_ACCOUNTS=10
DEFAULT_BALANCE="100"
DEFAULT_GAS_LIMIT=6721975
DEFAULT_GAS_PRICE=20000000000

# 配置参数
PORT="$DEFAULT_PORT"
NETWORK_ID="$DEFAULT_NETWORK_ID"
ACCOUNTS="$DEFAULT_ACCOUNTS"
BALANCE="$DEFAULT_BALANCE"
GAS_LIMIT="$DEFAULT_GAS_LIMIT"
GAS_PRICE="$DEFAULT_GAS_PRICE"
HOST="127.0.0.1"
DB_PATH="$CONFIG_DIR/db"
RESET=false

# 解析参数
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --port)
                PORT="$2"
                shift 2
                ;;
            --network-id)
                NETWORK_ID="$2"
                shift 2
                ;;
            --accounts)
                ACCOUNTS="$2"
                shift 2
                ;;
            --balance)
                BALANCE="$2"
                shift 2
                ;;
            --gas-limit)
                GAS_LIMIT="$2"
                shift 2
                ;;
            --gas-price)
                GAS_PRICE="$2"
                shift 2
                ;;
            --host)
                HOST="$2"
                shift 2
                ;;
            --db-path)
                DB_PATH="$2"
                shift 2
                ;;
            --reset)
                RESET=true
                shift
                ;;
            -h|--help)
                show_usage
                exit 0
                ;;
            *)
                log_error "未知参数：$1"
                show_usage
                exit 1
                ;;
        esac
    done
}

# 显示使用说明
show_usage() {
    cat << EOF
Ganache 配置脚本

用法：$0 [选项]

选项:
  --port <端口>          RPC 监听端口 (默认：$DEFAULT_PORT)
  --network-id <ID>      网络 ID (默认：$DEFAULT_NETWORK_ID)
  --accounts <数量>      生成账户数量 (默认：$DEFAULT_ACCOUNTS)
  --balance <ETH>        每个账户的 ETH 余额 (默认：$DEFAULT_BALANCE)
  --gas-limit <限制>     Gas 限制 (默认：$DEFAULT_GAS_LIMIT)
  --gas-price <价格>     Gas 价格 (默认：$DEFAULT_GAS_PRICE)
  --host <主机>          监听主机 (默认：127.0.0.1)
  --db-path <路径>       数据库路径 (默认：$CONFIG_DIR/db)
  --reset                重置为默认配置
  -h, --help             显示帮助信息

示例:
  $0                                         # 使用默认配置
  $0 --port 7545 --accounts 5                # 自定义端口和账户数
  $0 --reset                                 # 重置为默认配置
  $0 --host 0.0.0.0 --port 8545              # 监听所有接口

配置说明:
  配置文件保存在：$CONFIG_FILE
  数据库目录：$DB_PATH

EOF
}

# 创建配置目录
create_config_dir() {
    if [[ ! -d "$CONFIG_DIR" ]]; then
        mkdir -p "$CONFIG_DIR"
        log "已创建配置目录：$CONFIG_DIR"
    fi
    
    if [[ ! -d "$DB_PATH" ]]; then
        mkdir -p "$DB_PATH"
        log "已创建数据库目录：$DB_PATH"
    fi
    
    local logs_dir="$CONFIG_DIR/logs"
    if [[ ! -d "$logs_dir" ]]; then
        mkdir -p "$logs_dir"
        log "已创建日志目录：$logs_dir"
    fi
}

# 生成配置文件
generate_config() {
    log "生成 Ganache 配置文件..."
    
    # 备份旧配置
    if [[ -f "$CONFIG_FILE" && "$RESET" == false ]]; then
        backup_config "$CONFIG_FILE"
    fi
    
    # 生成 JSON 配置
    cat > "$CONFIG_FILE" << EOF
{
  "chainId": $NETWORK_ID,
  "networkId": $NETWORK_ID,
  "host": "$HOST",
  "port": $PORT,
  "gasLimit": $GAS_LIMIT,
  "gasPrice": $GAS_PRICE,
  "totalAccounts": $ACCOUNTS,
  "defaultBalanceETH": $BALANCE,
  "dbPath": "$DB_PATH",
  "unlocked_accounts": [],
  "allowUnlimitedContractSize": false,
  "allowUnlimitedTransactionCount": false,
  "verbose": true,
  "logging": {
    "quiet": false,
    "emitFreeLogs": false
  },
  "miner": {
    "instamine": "strict",
    "blockGasLimit": $GAS_LIMIT,
    "gasPrice": $GAS_PRICE
  }
}
EOF
    
    log_success "配置文件已生成：$CONFIG_FILE"
}

# 生成启动脚本
generate_startup_script() {
    local startup_file="$CONFIG_DIR/start.sh"
    
    cat > "$startup_file" << EOF
#!/bin/bash
# Ganache 启动脚本 (自动生成)

set -e

# 加载配置
CONFIG_FILE="$CONFIG_FILE"

echo "启动 Ganache..."
echo "配置文件：\$CONFIG_FILE"

# 从配置文件读取参数
PORT=\$(grep -o '"port": [0-9]*' "\$CONFIG_FILE" | grep -o '[0-9]*')
HOST=\$(grep -o '"host": "[^"]*"' "\$CONFIG_FILE" | cut -d'"' -f4)
NETWORK_ID=\$(grep -o '"networkId": [0-9]*' "\$CONFIG_FILE" | grep -o '[0-9]*')

echo "主机：\$HOST"
echo "端口：\$PORT"
echo "网络 ID: \$NETWORK_ID"

# 启动 Ganache
ganache \\
  --port "\$PORT" \\
  --host "\$HOST" \\
  --networkId "\$NETWORK_ID" \\
  --wallet.totalAccounts $ACCOUNTS \\
  --wallet.defaultBalance $BALANCE \\
  --gasLimit $GAS_LIMIT \\
  --gasPrice $GAS_PRICE \\
  --db "$DB_PATH" \\
  "\$@"
EOF
    
    chmod +x "$startup_file"
    log_success "启动脚本已生成：$startup_file"
}

# 生成 systemd 服务文件 (Linux)
generate_systemd_service() {
    if [[ "$(uname)" != "Linux" ]]; then
        return 0
    fi
    
    if [[ ! -d "/etc/systemd/system" ]]; then
        log "系统不支持 systemd，跳过服务配置"
        return 0
    fi
    
    local service_file="/etc/systemd/system/ganache.service"
    
    # 备份旧服务文件
    if [[ -f "$service_file" ]]; then
        backup_config "$service_file"
    fi
    
    cat > "$service_file" << EOF
[Unit]
Description=Ganache - Ethereum Personal Blockchain
After=network.target

[Service]
Type=simple
User=root
ExecStart=/usr/bin/ganache --config $CONFIG_FILE
Restart=on-failure
RestartSec=10
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
    
    log_success "systemd 服务文件已生成：$service_file"
    log "启用服务：systemctl enable ganache"
    log "启动服务：systemctl start ganache"
}

# 生成 launchd 服务文件 (macOS)
generate_launchd_service() {
    if [[ "$(uname)" != "Darwin" ]]; then
        return 0
    fi
    
    local service_file="$HOME/Library/LaunchAgents/com.trufflesuite.ganache.plist"
    local service_dir
    service_dir="$(dirname "$service_file")"
    
    if [[ ! -d "$service_dir" ]]; then
        mkdir -p "$service_dir"
    fi
    
    # 备份旧服务文件
    if [[ -f "$service_file" ]]; then
        backup_config "$service_file"
    fi
    
    cat > "$service_file" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.trufflesuite.ganache</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/local/bin/ganache</string>
        <string>--config</string>
        <string>$CONFIG_FILE</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>$CONFIG_DIR/logs/ganache.log</string>
    <key>StandardErrorPath</key>
    <string>$CONFIG_DIR/logs/ganache.err</string>
</dict>
</plist>
EOF
    
    log_success "launchd 服务文件已生成：$service_file"
    log "启用服务：launchctl load $service_file"
    log "禁用服务：launchctl unload $service_file"
}

# 验证配置
verify_config() {
    log "验证配置..."
    
    # 检查配置文件是否存在
    if [[ ! -f "$CONFIG_FILE" ]]; then
        log_error "配置文件不存在：$CONFIG_FILE"
        return 1
    fi
    
    # 检查 Ganache 是否已安装
    if ! check_ganache_installed; then
        log_error "Ganache 未安装，请先运行安装脚本"
        return 1
    fi
    
    # 验证 JSON 格式
    if command -v python3 &> /dev/null; then
        if ! python3 -c "import json; json.load(open('$CONFIG_FILE'))" 2>/dev/null; then
            log_error "配置文件 JSON 格式错误"
            return 1
        fi
        log_success "配置文件 JSON 格式正确"
    fi
    
    return 0
}

# 显示当前配置
show_current_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        log "当前配置:"
        echo ""
        cat "$CONFIG_FILE"
        echo ""
    else
        log "尚未生成配置文件"
    fi
}

# 主函数
main() {
    log "========================================="
    log "  Ganache 配置脚本"
    log "========================================="
    
    parse_args "$@"
    
    log "配置参数:"
    log "  端口：$PORT"
    log "  网络 ID: $NETWORK_ID"
    log "  账户数：$ACCOUNTS"
    log "  余额：$BALANCE ETH"
    log "  Gas 限制：$GAS_LIMIT"
    log "  Gas 价格：$GAS_PRICE"
    log "  主机：$HOST"
    log "  数据库路径：$DB_PATH"
    log "  重置配置：$RESET"
    log ""
    
    # 创建配置目录
    create_config_dir
    
    # 生成配置文件
    generate_config
    
    # 生成启动脚本
    generate_startup_script
    
    # 生成系统服务
    generate_systemd_service
    generate_launchd_service
    
    # 验证配置
    verify_config
    
    log ""
    log_success "========================================="
    log_success "  Ganache 配置完成!"
    log_success "========================================="
    log ""
    show_current_config
    log ""
    log "启动 Ganache:"
    log "  $CONFIG_DIR/start.sh"
    log ""
    log "或直接使用命令:"
    log "  ganache --config $CONFIG_FILE"
    log ""
}

# 执行主函数
main "$@"
