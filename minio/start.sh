#!/bin/bash

# MinIO 启动脚本
# 支持主流 Linux 发行版和 macOS
# 作者: Assistant
# 日期: 2025年11月13日

set -e  # 遇到错误时终止脚本执行

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 打印带颜色的信息
print_info() {
    echo -e "${BLUE}[信息]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[成功]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[警告]${NC} $1"
}

print_error() {
    echo -e "${RED}[错误]${NC} $1"
}

# 检查 MinIO 是否已安装
check_minio_installed() {
    if ! command -v minio &> /dev/null; then
        print_error "MinIO 未安装，请先运行安装脚本"
        exit 1
    fi
}

# 检查端口是否被占用
check_port_available() {
    local port=$1
    if command -v netstat &> /dev/null; then
        if netstat -tuln | grep -q ":$port "; then
            print_error "端口 $port 已被占用"
            return 1
        fi
    elif command -v ss &> /dev/null; then
        if ss -tuln | grep -q ":$port "; then
            print_error "端口 $port 已被占用"
            return 1
        fi
    else
        print_warning "系统中没有找到 netstat 或 ss 命令，跳过端口检查"
        return 0
    fi
    return 0
}

# 检查数据目录
check_data_directory() {
    local data_dir=$1
    if [ -z "$data_dir" ]; then
        data_dir="$HOME/minio-data"
        print_info "未指定数据目录，使用默认目录: $data_dir"
    fi
    
    if [ ! -d "$data_dir" ]; then
        print_info "数据目录不存在，正在创建: $data_dir"
        mkdir -p "$data_dir"
    fi
    
    if [ ! -w "$data_dir" ]; then
        print_error "数据目录 $data_dir 没有写入权限"
        exit 1
    fi
    
    echo "$data_dir"
}

# 启动 MinIO 服务
start_minio_service() {
    local data_dir=$1
    local port=${2:-9000}
    local console_port=${3:-9001}
    
    # 检查端口是否可用
    if ! check_port_available $port; then
        print_error "API 端口 $port 不可用，无法启动 MinIO"
        exit 1
    fi
    
    if ! check_port_available $console_port; then
        print_error "控制台端口 $console_port 不可用，无法启动 MinIO"
        exit 1
    fi
    
    # 设置默认凭据
    export MINIO_ROOT_USER=${MINIO_ROOT_USER:-"minioadmin"}
    export MINIO_ROOT_PASSWORD=${MINIO_ROOT_PASSWORD:-"minioadmin"}
    
    print_info "正在启动 MinIO 服务器..."
    print_info "数据目录: $data_dir"
    print_info "API 地址: http://127.0.0.1:$port"
    print_info "控制台地址: http://127.0.0.1:$console_port"
    print_info "用户名: $MINIO_ROOT_USER"
    print_info "密码: $MINIO_ROOT_PASSWORD"
    
    # 启动 MinIO 服务器
    nohup minio server "$data_dir" --address ":$port" --console-address ":$console_port" > minio.log 2>&1 &
    
    # 获取进程 ID
    MINIO_PID=$!
    
    # 等待一段时间让服务器启动
    sleep 3
    
    # 检查进程是否仍在运行
    if kill -0 $MINIO_PID 2>/dev/null; then
        print_success "MinIO 服务器已启动，PID: $MINIO_PID"
        echo $MINIO_PID > /tmp/minio.pid
        print_info "MinIO 服务器后台运行中..."
        print_info "访问控制台: http://127.0.0.1:$console_port"
        print_info "API 服务: http://127.0.0.1:$port"
    else
        print_error "MinIO 服务器启动失败"
        exit 1
    fi
}

# 显示帮助信息
show_help() {
    cat << EOF
用法: $0 [选项]

选项:
  -d, --data-dir DIR    指定 MinIO 数据目录 (默认: $HOME/minio-data)
  -p, --port PORT       指定 API 端口 (默认: 9000)
  -c, --console-port PORT  指定控制台端口 (默认: 9001)
  -u, --username USER   指定管理员用户名 (默认: minioadmin)
  -w, --password PASS   指定管理员密码 (默认: minioadmin)
  -h, --help           显示此帮助信息

示例:
  $0                                    # 使用默认设置启动 MinIO
  $0 -d /path/to/data                   # 指定数据目录
  $0 -d /path/to/data -p 9001 -c 9002   # 指定端口
EOF
}

# 解析命令行参数
parse_arguments() {
    DATA_DIR=""
    PORT=9000
    CONSOLE_PORT=9001
    
    while [[ $# -gt 0 ]]; do
        case $1 in
            -d|--data-dir)
                DATA_DIR="$2"
                shift 2
                ;;
            -p|--port)
                PORT="$2"
                shift 2
                ;;
            -c|--console-port)
                CONSOLE_PORT="$2"
                shift 2
                ;;
            -u|--username)
                export MINIO_ROOT_USER="$2"
                shift 2
                ;;
            -w|--password)
                export MINIO_ROOT_PASSWORD="$2"
                shift 2
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            *)
                print_error "未知参数: $1"
                show_help
                exit 1
                ;;
        esac
    done
    
    # 检查并获取最终的数据目录
    FINAL_DATA_DIR=$(check_data_directory "$DATA_DIR")
    
    # 启动 MinIO 服务
    start_minio_service "$FINAL_DATA_DIR" "$PORT" "$CONSOLE_PORT"
}

# 主函数
main() {
    print_info "开始启动 MinIO 服务器..."
    
    check_minio_installed
    parse_arguments "$@"
    
    print_success "MinIO 服务器启动流程完成"
}

# 执行主函数
main "$@"