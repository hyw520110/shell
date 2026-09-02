#!/bin/bash

# MinIO 停止脚本
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

# 检查 MinIO 是否正在运行
check_minio_running() {
    local pid_file="/tmp/minio.pid"
    
    # 首先检查 PID 文件
    if [ -f "$pid_file" ]; then
        PID=$(cat "$pid_file")
        if kill -0 "$PID" 2>/dev/null; then
            print_info "发现 MinIO 进程，PID: $PID"
            echo "$PID"
            return 0
        else
            print_warning "PID 文件存在但进程未运行，清理 PID 文件"
            rm -f "$pid_file"
        fi
    fi
    
    # 如果没有 PID 文件或进程不存在，搜索 MinIO 进程
    if command -v pgrep &> /dev/null; then
        PID=$(pgrep -f "minio server")
    elif command -v ps &> /dev/null; then
        PID=$(ps aux | grep "minio server" | grep -v grep | awk '{print $2}')
    else
        print_error "系统中没有找到 pgrep 或 ps 命令，无法检测 MinIO 进程"
        return 1
    fi
    
    if [ -n "$PID" ]; then
        print_info "找到 MinIO 进程，PID: $PID"
        echo "$PID"
        return 0
    else
        print_warning "未找到运行中的 MinIO 服务器"
        return 1
    fi
}

# 停止 MinIO 服务
stop_minio_service() {
    local pid=$1
    
    if [ -z "$pid" ]; then
        print_error "没有找到 MinIO 进程，无法停止服务"
        return 1
    fi
    
    print_info "正在停止 MinIO 服务器 (PID: $pid)..."
    
    # 首先尝试优雅地停止服务（发送 SIGTERM 信号）
    kill -TERM "$pid" 2>/dev/null || {
        print_error "无法发送终止信号到进程 $pid"
        return 1
    }
    
    # 等待进程结束
    local timeout=30
    local count=0
    while kill -0 "$pid" 2>/dev/null && [ $count -lt $timeout ]; do
        sleep 1
        count=$((count + 1))
    done
    
    # 检查进程是否仍在运行
    if kill -0 "$pid" 2>/dev/null; then
        print_warning "优雅停止超时，强制终止进程 (PID: $pid)"
        kill -KILL "$pid" 2>/dev/null || {
            print_error "无法强制终止进程 $pid"
            return 1
        }
    fi
    
    # 等待确保进程已终止
    sleep 2
    
    # 验证进程是否已终止
    if ! kill -0 "$pid" 2>/dev/null; then
        print_success "MinIO 服务器已成功停止"
        return 0
    else
        print_error "无法停止 MinIO 服务器"
        return 1
    fi
}

# 清理 PID 文件
cleanup_pid_file() {
    local pid_file="/tmp/minio.pid"
    if [ -f "$pid_file" ]; then
        rm -f "$pid_file"
        print_info "已清理 PID 文件"
    fi
}

# 停止所有 MinIO 进程
stop_all_minio_processes() {
    print_info "正在停止所有 MinIO 相关进程..."
    
    if command -v pkill &> /dev/null; then
        pkill -f "minio server" 2>/dev/null || true
        sleep 2
        pkill -9 -f "minio server" 2>/dev/null || true
        print_success "已尝试停止所有 MinIO 进程"
    elif command -v ps &> /dev/null; then
        PIDS=$(ps aux | grep "minio server" | grep -v grep | awk '{print $2}')
        if [ -n "$PIDS" ]; then
            for pid in $PIDS; do
                kill -TERM "$pid" 2>/dev/null || true
            done
            sleep 2
            for pid in $PIDS; do
                kill -9 "$pid" 2>/dev/null || true
            done
            print_success "已尝试停止所有 MinIO 进程"
        else
            print_info "未找到 MinIO 进程"
        fi
    else
        print_error "系统中没有找到 pkill 或 ps 命令"
        return 1
    fi
}

# 显示帮助信息
show_help() {
    cat << EOF
用法: $0 [选项]

选项:
  -a, --all            停止所有 MinIO 进程
  -h, --help           显示此帮助信息

示例:
  $0                    # 停止 MinIO 服务器
  $0 -a                 # 停止所有 MinIO 进程
EOF
}

# 解析命令行参数
parse_arguments() {
    local stop_all=false
    
    while [[ $# -gt 0 ]]; do
        case $1 in
            -a|--all)
                stop_all=true
                shift
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
    
    if [ "$stop_all" = true ]; then
        stop_all_minio_processes
        cleanup_pid_file
    else
        PID=$(check_minio_running) || {
            print_warning "未找到运行中的 MinIO 进程"
            exit 0
        }
        
        stop_minio_service "$PID"
        cleanup_pid_file
    fi
}

# 主函数
main() {
    print_info "开始停止 MinIO 服务器..."
    
    parse_arguments "$@"
    
    print_success "MinIO 服务器停止流程完成"
}

# 执行主函数
main "$@"