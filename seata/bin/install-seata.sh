#!/bin/bash

# Seata 自动化安装脚本
# 兼容主流 Linux 和 macOS 系统
# 支持指定安装目录、卸载、自动启动服务和下载目录

set -euo pipefail  # 启用严格模式：错误退出、管道失败退出、未声明变量报错

# 导入公共函数库
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"  # 项目根目录
if [ -f "$SCRIPT_DIR/common.sh" ]; then
    source "$SCRIPT_DIR/common.sh"
else
    echo -e "\033[0;31m[错误]\033[0m 找不到公共函数库 $SCRIPT_DIR/common.sh" >&2
    exit 1
fi

# 公共变量
DEFAULT_INSTALL_DIR="$HOME/seata"
DEFAULT_DOWNLOAD_DIR="$HOME/Downloads"
DEFAULT_VERSION="2.5.0"  
INSTALL_DIR="$DEFAULT_INSTALL_DIR"
DOWNLOAD_DIR="$DEFAULT_DOWNLOAD_DIR"
VERSION="$DEFAULT_VERSION"
UNINSTALL=false
INSTALL_SERVICE=false
INSTALL_NAMING_SERVER=false
FORCE_INSTALL=false

# 支持的配置中心类型
CONFIG_TYPES="file,nacos,consul,apollo,etcd3,zookeeper"
DEFAULT_CONFIG_TYPE="file"
CONFIG_TYPE="$DEFAULT_CONFIG_TYPE"

# 支持的注册中心类型

REGISTRY_TYPES="file,nacos,eureka,redis,zk,consul,etcd3,sofa"
DEFAULT_REGISTRY_TYPE="file"
REGISTRY_TYPE="$DEFAULT_REGISTRY_TYPE"

# 支持的存储方式
STORE_TYPES="file,db,redis"
DEFAULT_STORE_TYPE="file"
STORE_TYPE="$DEFAULT_STORE_TYPE"

# 数据库连接参数（默认值在 .env 文件中定义）
DB_HOST=""
DB_PORT=""
DB_USER=""
DB_PASSWORD=""
DB_DATABASE=""
# 环境文件路径
ENV_FILE=".env"
CURRENT_USER=$(whoami)
SUDO_CMD="sudo"
USE_SUDO=false
OS=""

# 下载URL 
DOWNLOAD_URLS=(
    "https://mirrors.tuna.tsinghua.edu.cn/apache/incubator/seata/${DEFAULT_VERSION}/apache-seata-${DEFAULT_VERSION}-incubating-bin.tar.gz"  
    "https://archive.apache.org/dist/incubator/seata/${DEFAULT_VERSION}/apache-seata-${DEFAULT_VERSION}-incubating-bin.tar.gz" 
    "https://github.com/seata/seata/releases/download/v${DEFAULT_VERSION}/seata-server-${DEFAULT_VERSION}.tar.gz"  
)

# 下载文件路径
GZ_FILE_PATH=""

# 显示使用帮助
print_usage() {
    cat << EOF
用法: $0 [选项]

自动安装脚本。

选项:
    -d, --dir PATH          安装目录 (默认: $DEFAULT_INSTALL_DIR)
    -w, --download-dir PATH 下载目录 (默认: $DEFAULT_DOWNLOAD_DIR)
    -v, --version VERSION   安装版本 (默认: $DEFAULT_VERSION)
    -u, --uninstall         卸载 Seata
    -s, --service           安装自启动服务 (默认: false)
    -n, --naming-server     安装命名服务器 (默认: false)
    -f                      强制安装 (如果目录已存在则覆盖)
    -ct, --config-type TYPE 配置中心类型: $CONFIG_TYPES (默认: $DEFAULT_CONFIG_TYPE)
    -rt, --registry-type TYPE 注册中心类型: $REGISTRY_TYPES (默认: $DEFAULT_REGISTRY_TYPE)
    -st, --store-type TYPE  存储方式: $STORE_TYPES (默认: $DEFAULT_STORE_TYPE)
    --db-host HOST          数据库主机 (默认: $DB_HOST)
    --db-port PORT          数据库端口 (默认: $DB_PORT)
    --db-user USER          数据库用户 (默认: $DB_USER)
    --db-password PASS      数据库密码 (默认: $DB_PASSWORD)
    --db-database DB        数据库名 (默认: $DB_DATABASE)
    -x, --debug             调试模式 (不使用 set -e，显示详细输出)
    -h, --help              显示此帮助消息

示例:
    $0                                    # 安装到默认目录
    $0 -d /opt/seata                     # 安装到 /opt/seata
    $0 --uninstall                       # 卸载 Seata
    $0 -d /opt/seata -s                  # 安装到 /opt/seata 并安装服务
    $0 -n                                  # 安装到默认目录并安装命名服务器
    $0 -w /tmp/downloads                 # 使用自定义下载目录
    $0 -v $DEFAULT_VERSION -f            # 安装指定版本并强制覆盖
    $0 -ct nacos -rt nacos -st db        # 使用 Nacos 作为配置和注册中心，数据库作为存储
    $0 -st db --db-host mydb --db-user root # 使用自定义数据库连接信息
    $0 -x                                  # 以调试模式运行
EOF
}

# 检测操作系统是否为 macOS 或 Linux
detect_os() {
    local os_type
    os_type=$(get_os_type 2>/dev/null)
    if [[ $? -ne 0 ]]; then
        print_error "无法检测操作系统类型"
        exit 1
    fi
    OS="$os_type"
    SUDO_CMD="sudo"
}

# 检查 sudo 是否可用
check_sudo() {
    if ! command -v sudo &> /dev/null; then
        SUDO_CMD=""
        log_warn "未找到 sudo 命令，将不使用权限提升"
    fi
}


exec_cmd() {
    local cmd="$1"
    shift
    local args=("$@")
    local cmd_string="$cmd ${args[*]}"  
    # 检查是否需要使用sudo
    if [[ "$USE_SUDO" == "true" ]]; then
        "$SUDO_CMD" "$cmd" "${args[@]}"
    else
        "$cmd" "${args[@]}" || {
            # 如果命令执行失败，尝试使用sudo执行并设置USE_SUDO为true
            if [[ -n "$SUDO_CMD" ]]; then
                log_warn "命令执行失败，尝试使用sudo执行: $cmd_string"
                "$SUDO_CMD" "$cmd" "${args[@]}"
                USE_SUDO=true
            else
                return 1  
            fi
        }
    fi
}

# 验证归档文件完整性
verify_archive() {
    local archive_path="$1"
    
    if command -v tar &> /dev/null; then
        # 尝试列出归档内容以验证完整性
        if tar -tf "$archive_path" >/dev/null 2>&1; then
            return 0
        else
            return 1
        fi
    else
        # 如果没有 tar 命令，则简单检查文件大小
        if [[ -s "$archive_path" ]]; then
            return 0
        else
            return 1
        fi
    fi
}

# 从官方版本下载 Seata
download_seata() {
    local url=$1
    
    # 指定版本不是默认版本则下载指定版本
    if [ "$VERSION" != "$DEFAULT_VERSION" ]; then
        # 替换URL中的DEFAULT_VERSION为VERSION
        url="${url//DEFAULT_VERSION/$VERSION}"
        # 也替换可能的其他版本占位符
        url="${url//${DEFAULT_VERSION}/$VERSION}"
    fi
    # 从URL中获取tar文件名
    local tar_file=$(basename "$url" | sed 's/action=download//g' | sed 's/\&.*//g' | sed 's/\?//g')
   GZ_FILE_PATH="$DOWNLOAD_DIR/$tar_file"
    
    # 确保下载目录存在
    [ ! -d "$DOWNLOAD_DIR" ] && mkdir -p "$DOWNLOAD_DIR"
    
    # 检查文件是否已存在（仅当指定了版本时）
    if [ -f "$GZ_FILE_PATH" ]; then
        log_info "指定版本的 Seata 安装包已存在: $GZ_FILE_PATH"
        # 尝试解压以验证文件完整性
        if verify_archive "$GZ_FILE_PATH"; then
            log_info "安装包验证成功，跳过下载"
            return 0
        fi
    fi
    
    log_info "下载 Seata: $url"
    log_info "下载目录: $DOWNLOAD_DIR"
    
    # 尝试多线程并行下载（如果 aria2c 可用）- 优先使用性能最高的工具
    if command -v aria2c &> /dev/null; then
        log_info "使用 aria2c 进行多线程并行下载 (8线程)"
        aria2c -x 8 -s 8 -c --max-connection-per-server=8 --split=8 --continue=true -d "$DOWNLOAD_DIR" -o "$tar_file" "$url" && return 0
        log_warn "$url下载失败"
    # 如果 axel 可用
    elif command -v axel &> /dev/null; then
        log_info "使用 axel 进行多线程并行下载 (8线程)"
        axel -n 8 -o "$DOWNLOAD_DIR/$tar_file" "$url" && return 0
        log_warn "$url下载失败"
    # 使用 wget 断点续传
    elif command -v wget &> /dev/null; then
        log_info "使用 wget 断点续传下载"
        # 使用 -c 进行断点续传，添加更多重试和超时设置
        wget -c --tries=5 --timeout=30 --continue -O "$DOWNLOAD_DIR/$tar_file" "$url" && return 0
        log_warn "$url下载失败"
    elif command -v curl &> /dev/null; then
        log_info "使用 curl 断点续传下载"
        # 如果文件已存在部分，使用 -C - 进行断点续传
        if [[ -f "$DOWNLOAD_DIR/$tar_file" ]]; then
            curl -L --fail --continue-at - --connect-timeout 10 --max-time 3600 -o "$DOWNLOAD_DIR/$tar_file" "$url" && return 0
        else
            curl -L --fail --connect-timeout 10 --max-time 3600 -o "$DOWNLOAD_DIR/$tar_file" "$url" && return 0
        fi
        log_warn "$url下载失败"
    else
        print_error "无可用下载工具 (aria2c, axel, curl, wget)"
        return 1
    fi
    
    # 验证文件完整性
    if ! verify_archive "$GZ_FILE_PATH"; then
        print_error "下载的文件验证失败，可能是不完整的文件"
        rm -f "$GZ_FILE_PATH"
        return 1
    fi
    log_info "Seata 下载成功: $GZ_FILE_PATH"
    return 0
}

# 执行 sed 命令取消注释指定的行
execute_sed() {
    local file="$1"
    local pattern="$2"
    sed -i.bak "s/# ${pattern}/${pattern}/" "$file"
}

# 为自动启动创建系统服务
create_service() {
    if [[ "$INSTALL_SERVICE" == false ]]; then
        return 0    
    fi
    if [[ "$OS" == "macOS" ]]; then
        log_warn "macOS 上跳过自启动服务安装（权限设置复杂）"
        return 0
    fi
    
    log_info "为 Seata 创建自动启动服务..."
    
    if [[ "$OS" == "Linux" ]]; then
        # 创建 systemd 服务
        SERVICE_FILE="/etc/systemd/system/seata.service"
        
        if [[ "$USE_SUDO" != "true" ]]; then
            log_warn "创建系统服务需要 root 权限"
            $SUDO_CMD -v || {
                print_error "获取 root 权限失败"
                exit 1
            }
        fi
        
        # Create the service file using exec_cmd
        cat > /tmp/seata.service << EOF
[Unit]
Description=Seata Server
After=network.target

[Service]
Type=forking
User=$CURRENT_USER
ExecStart=$START_SCRIPT_PATH
ExecReload=/bin/kill -s HUP $MAINPID
KillMode=process
Restart=on-failure
RestartSec=42s

[Install]
WantedBy=multi-user.target
EOF
        exec_cmd cp /tmp/seata.service "$SERVICE_FILE"
        exec_cmd rm -f /tmp/seata.service
        
        exec_cmd systemctl daemon-reload
        log_info "Seata 服务已创建。启用命令: sudo systemctl enable seata"
        log_info "启动命令: sudo systemctl start seata"
    fi
}

# 解压并安装 Seata
install_seata() {
    # 首先下载 Seata 包
    for url in "${DOWNLOAD_URLS[@]}"; do
        # 下载指定版本
        local download_url="${url//DEFAULT_VERSION/$VERSION}"
        download_url="${download_url//${DEFAULT_VERSION}/$VERSION}"
        if download_seata "$download_url"; then
            break
        fi
    done
    
    if [[ -z "$GZ_FILE_PATH" || ! -f "$GZ_FILE_PATH" ]]; then
        print_error "下载文件不存在: $GZ_FILE_PATH"
        exit 1
    fi
    
    if [[ -d "$INSTALL_DIR" ]]; then
        if [[ "$FORCE_INSTALL" == true ]]; then
            log_info "强制安装模式：安装目录 $INSTALL_DIR 已存在，将被覆盖"
        else
            read -p "安装目录 $INSTALL_DIR 已存在,是否继续安装？[Y/n] " -n 1 -r REPLY
            echo
            if [[ ! $REPLY =~ ^[Yy]$ ]] && [[ -n $REPLY ]]; then
                log_info "安装已取消"
                exit 0
            fi
        fi
    else
    	exec_cmd mkdir -p "$INSTALL_DIR"
    fi
    
    log_info "安装 Seata 到: $INSTALL_DIR"
   
    # 解压 Seata 服务器核心文件到临时目录
    TEMP_DIR=$(mktemp -d)
    
    if ! tar -xzf "$GZ_FILE_PATH" -C "$TEMP_DIR"; then
        print_error "解压失败，重新下载安装包"
        exit 1
    fi
     
    SEATA_SERVER_SH_PATH=$(find "$TEMP_DIR" -name "$SEATA_SERVER_SH" -type f | head -n 1)
    if [ -n "$SEATA_SERVER_SH_PATH" ]; then
        SEATA_SERVER_DIR=$(dirname $(dirname "$SEATA_SERVER_SH_PATH"))
        log_info "解压目录: $SEATA_SERVER_DIR 同步到安装目录..."
        rsync -a --ignore-existing "$SEATA_SERVER_DIR/" "$INSTALL_DIR/"
    else
        print_error "未在解压文件中找到 $SEATA_SERVER_SH 文件"
        log_info "解压的内容包括:"
        find "$TEMP_DIR" -type f | head -20
        exit 1
    fi
    
    # 清理临时目录
    rm -rf "$TEMP_DIR"
  
    log_info "同步项目配置文件和脚本到安装目录..."
    # 同步项目根目录的配置文件和脚本到安装目录，但不覆盖已存在的 Seata 服务器文件
    rsync -av --ignore-existing --include='.env' --include='docker-compose.yml' --include='bin/'  "$PROJECT_DIR/" "$INSTALL_DIR/" 2>/dev/null || true

    ENV_FILE="$INSTALL_DIR/.env"
    log_info "更新 .env 配置文件..."
    update_env_file "STORE_MODE" "$STORE_TYPE"
    update_env_file "REGISTRY_TYPE" "$REGISTRY_TYPE"
    update_env_file "CONFIG_TYPE" "$CONFIG_TYPE"
    
    # 如果数据库参数已设置，则更新对应的环境变量
    if [ -n "$DB_HOST" ]; then
        update_env_file "MYSQL_HOST" "$DB_HOST"
    fi
    if [ -n "$DB_PORT" ]; then
        update_env_file "MYSQL_PORT" "$DB_PORT"
    fi
    if [ -n "$DB_USER" ]; then
        update_env_file "MYSQL_USER" "$DB_USER"
    fi
    if [ -n "$DB_PASSWORD" ]; then
        update_env_file "MYSQL_PASSWORD" "$DB_PASSWORD"
    fi
    if [ -n "$DB_DATABASE" ]; then
        update_env_file "MYSQL_DATABASE" "$DB_DATABASE"
    fi
    
    # 配置 docker-compose.yml 根据存储类型和注册中心类型
    if [ -f "$INSTALL_DIR/docker-compose.yml" ]; then
        # 根据存储类型配置 docker-compose.yml
        if [ "$STORE_TYPE" = "db" ]; then
            # 启用 MySQL 服务
            execute_sed "$INSTALL_DIR/docker-compose.yml" "mysql-server:"
            execute_sed "$INSTALL_DIR/docker-compose.yml" "    image:"
            execute_sed "$INSTALL_DIR/docker-compose.yml" "    container_name:"
            execute_sed "$INSTALL_DIR/docker-compose.yml" "    ports:"
            execute_sed "$INSTALL_DIR/docker-compose.yml" "    env_file:"
            execute_sed "$INSTALL_DIR/docker-compose.yml" "volumes:"
            execute_sed "$INSTALL_DIR/docker-compose.yml" "  mysql-data:"
        fi
        
        # 根据注册中心类型配置
        if [ "$REGISTRY_TYPE" != "file" ]; then
            # 这里可以添加根据注册中心类型修改配置的逻辑
            log_info "注册中心类型已设置为: $REGISTRY_TYPE"
        fi
    fi
    
    # 设置适当的权限
    exec_cmd chown -R "$CURRENT_USER:$(id -gn)" "$INSTALL_DIR"
    exec_cmd find "$INSTALL_DIR" -name "*.sh" -type f -exec chmod +x {} \;
    exec_cmd chmod 600 "$INSTALL_DIR/.env"  
    
    create_service "$INSTALL_DIR"
  
    log_info "Seata 安装到: $INSTALL_DIR"
    log_info "使用以下命令管理 Seata 服务:"
    log_info "  启动服务: $START_SCRIPT_PATH"
    log_info "  停止服务: $STOP_SCRIPT_PATH"
    log_info "  查看状态: $START_SCRIPT_PATH -s"
}


# 卸载 Seata
uninstall_seata() {
    log_info "卸载 Seata服务..."
    
    # 停止系统服务（如果存在）
    if [[ "$OS" == "Linux" ]]; then
        if systemctl is-enabled --quiet seata; then
            log_info "正在禁用 Seata 服务..."
            exec systemctl disable seata
        fi
        
        # 移除服务文件
        if [[ -f "/etc/systemd/system/seata.service" ]]; then
            log_info "正在移除 Seata 服务文件..."
            exec_cmd rm -f /etc/systemd/system/seata.service
            exec_cmd systemctl daemon-reload
        fi
    fi
    
    # 移除安装目录
    if [ -d "$INSTALL_DIR" ]; then
  	if  [[ -f "$STOP_SCRIPT_PATH" ]]; then
  	      log_info "$STOP_SCRIPT_PATH -f "
        	exec_cmd "$STOP_SCRIPT_PATH" -f
    	fi
        exec_cmd rm -rf "$INSTALL_DIR"
        log_info "Seata 卸载成功"
    else
        log_warn "安装目录不存在: $INSTALL_DIR"
    fi
}

# 更新 .env 文件中的变量值
update_env_file() {
    local key="$1"
    local value="$2"
    
    if [ ! -f "$ENV_FILE" ]; then
        print_error "环境文件不存在: $ENV_FILE"
        return 1
    fi
    
    # 使用 sed 更新环境变量
    if grep -q "^${key}=" "$ENV_FILE"; then
        # 如果键已存在，更新其值
        sed -i.bak "s/^${key}=.*/${key}=${value}/" "$ENV_FILE"
    else
        # 如果键不存在，添加新的键值对
        echo "${key}=${value}" >> "$ENV_FILE"
    fi
}

# 解析命令行参数
while [[ $# -gt 0 ]]; do
    case $1 in
        -d|--dir)
            INSTALL_DIR="$2"
            shift 2
            ;;
        -w|--download-dir)
            DOWNLOAD_DIR="$2"
            shift 2
            ;;
        -v|--version)
            VERSION="$2"
            shift 2
            ;;
        -u|--uninstall)
            UNINSTALL=true
            shift
            ;;
        -s|--service)
            INSTALL_SERVICE=true
            shift
            ;;
        -f)
            FORCE_INSTALL=true
            shift
            ;;
        -ct|--config-type)
            CONFIG_TYPE="$2"
            # 验证配置中心类型
            if [[ ! ",$CONFIG_TYPES," =~ ,$CONFIG_TYPE, ]]; then
                print_error "无效的配置中心类型: $CONFIG_TYPE"
                log_info "支持的类型: $CONFIG_TYPES"
                exit 1
            fi
            shift 2
            ;;
        -rt|--registry-type)
            REGISTRY_TYPE="$2"
            # 验证注册中心类型
            if [[ ! ",$REGISTRY_TYPES," =~ ,$REGISTRY_TYPE, ]]; then
                print_error "无效的注册中心类型: $REGISTRY_TYPE"
                log_info "支持的类型: $REGISTRY_TYPES"
                exit 1
            fi
            shift 2
            ;;
        -n|--naming-server)
            INSTALL_NAMING_SERVER=true
            shift
            ;;
        -st|--store-type)
            STORE_TYPE="$2"
            # 验证存储类型
            if [[ ! ",$STORE_TYPES," =~ ,$STORE_TYPE, ]]; then
                print_error "无效的存储类型: $STORE_TYPE"
                log_info "支持的类型: $STORE_TYPES"
                exit 1
            fi
            shift 2
            ;;
        --db-host)
            DB_HOST="$2"
            shift 2
            ;;
        --db-port)
            DB_PORT="$2"
            # 验证端口号
            if ! [[ "$DB_PORT" =~ ^[0-9]+$ ]] || [ "$DB_PORT" -lt 1 ] || [ "$DB_PORT" -gt 65535 ]; then
                print_error "无效的数据库端口号: $DB_PORT"
                exit 1
            fi
            shift 2
            ;;
        --db-user)
            DB_USER="$2"
            shift 2
            ;;
        --db-password)
            DB_PASSWORD="$2"
            shift 2
            ;;
        --db-database)
            DB_DATABASE="$2"
            shift 2
            ;;
        -x|--debug)
            DEBUG_MODE=true
            # 在调试模式下禁用set -e
            set +e
            log_info "调试模式已启用，禁用set -e选项"
            shift
            ;;
        -h|--help)
            print_usage
            exit 0
            ;;
        *)
            print_error "未知选项: $1"
            print_usage
            exit 1
            ;;
    esac
done

# 主执行函数
main() {
    detect_os
    check_sudo
    START_SCRIPT_PATH="$INSTALL_DIR/bin/$START_SCRIPT_PATH"
    STOP_SCRIPT_PATH="$INSTALL_DIR/bin/$STOP_SCRIPT_PATH"
    if [[ "$UNINSTALL" == true ]]; then
        uninstall_seata 
        exit 0
    fi
       
    install_seata
    
    # 自动启动服务
    log_info "正在自动启动 Seata 服务..."
    
    if [[ -f "$START_SCRIPT_PATH" ]]; then
        if [[ "$INSTALL_NAMING_SERVER" == true ]]; then
            # 启动 seata-namingserver（通过启动脚本的参数）
            "$START_SCRIPT_PATH" --with-namingserver
        else
            "$START_SCRIPT_PATH"
        fi
    else
        log_info "请手动启动服务: $(find  $INSTALL_DIR -name $SEATA_SERVER_SH)"
    fi
}

# 运行主函数
if [[ "$DEBUG_MODE" == true ]]; then
    set +e  # 调试模式下保持禁用
    main "$@"
    exit_code=$?
    if [ $exit_code -ne 0 ]; then
        log_warn "脚本在调试模式下完成，退出码: $exit_code"
    fi
    exit $exit_code
else
    set -e  # 非调试模式下启用
    main "$@"
fi
