#!/bin/bash
# MySQL卸载脚本，支持多实例选择

set -euo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

# 显示帮助
show_help() {
    cat << EOF
用法: $0 [选项] [安装目录]

选项:
  -h, --help     显示此帮助信息
  安装目录       可选，指定要卸载的MySQL安装目录

示例:
  $0                    # 自动查找并列出所有安装供选择
  $0 /Users/mac/mysql   # 卸载指定目录
  $0 --brew             # 卸载 Homebrew 安装的 MySQL
EOF
    exit 0
}

# 检查是否请求帮助
if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
    show_help
fi

# 查找所有MySQL安装
find_all_mysql_installs() {
    local found_dirs=()
    
    # 常见安装目录
    local possible_dirs=(
      "$HOME"
      "/home/$USER"
      "/usr/local/mysql"
      "/usr/local"
      "/opt/mysql"
      "/opt"
    )
    
    for dir in "${possible_dirs[@]}"; do
        [ ! -d "$dir" ] && continue
        local found=$(find "$dir" -maxdepth 3 -type f -name mysqld 2>/dev/null | awk -F'/bin/mysqld' '{print $1}' | sort -u)
        if [ -n "$found" ]; then
            for f in $found; do
                # 规范化路径
                local normalized=$(cd "$f" 2>/dev/null && pwd)
                if [ -n "$normalized" ] && [[ ! " ${found_dirs[*]:-} " =~ " ${normalized} " ]]; then
                    found_dirs+=("$normalized")
                fi
            done
        fi
    done
    
    # 输出结果
    for dir in "${found_dirs[@]:-}"; do
        echo "$dir"
    done
}

# 选择安装目录
select_install_dir() {
    local installs=("$@")
    
    # 先过滤掉 Homebrew 路径
    local filtered_installs=()
    for dir in "${installs[@]:-}"; do
        # 跳过空值和 Homebrew 安装的 MySQL
        [ -z "$dir" ] && continue
        if [[ "$dir" == *"homebrew"* ]] || [[ "$dir" == *"Cellar"* ]] || [[ "$dir" == *"/opt/homebrew"* ]] || [[ "$dir" == *"/usr/local/Cellar"* ]]; then
            continue
        fi
        filtered_installs+=("$dir")
    done
    
    if [ ${#filtered_installs[@]} -eq 0 ]; then
        # 检查是否通过 Homebrew 安装
        local brew_packages=($(find_installed_brew_mysql_packages))
        if [ ${#brew_packages[@]} -gt 0 ]; then
            uninstall_brew_mysql
            exit 0
        fi
        echo "未找到MySQL安装"
        exit 1
    fi
    
    if [ ${#filtered_installs[@]} -eq 1 ]; then
        INSTALL_DIR="${filtered_installs[0]}"
        return
    fi
    
    echo "找到以下MySQL安装:"
    echo ""
    local i=1
    for dir in "${filtered_installs[@]}"; do
        echo "  $i) $dir"
        ((i++))
    done
    echo ""
    read -p "请选择要卸载的MySQL [1-${#filtered_installs[@]}]: " choice
    choice=${choice:-1}
    
    if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le ${#filtered_installs[@]} ]; then
        INSTALL_DIR="${filtered_installs[$((choice-1))]}"
    else
        echo "无效选择。"
        exit 1
    fi
}

# 查找所有已安装的 Homebrew MySQL 包
find_installed_brew_mysql_packages() {
    local packages=()
    
    # 检查所有可能的 MySQL 包
    for pkg in mysql mysql@5.7 mysql@8.0 mysql@8.4 mysql@9.0 mysql@9.1 mysql@9.2 mysql@9.3 mysql@9.4 mysql@9.5 mysql@9.6; do
        if brew list "$pkg" &>/dev/null 2>/dev/null; then
            packages+=("$pkg")
        fi
    done
    
    echo "${packages[@]}"
}

# 卸载 Homebrew 安装的 MySQL
uninstall_brew_mysql() {
    echo "检测到 Homebrew 安装的 MySQL"
    echo ""
    
    # 查找所有已安装的 MySQL 包
    local installed_packages=($(find_installed_brew_mysql_packages))
    
    if [ ${#installed_packages[@]} -eq 0 ]; then
        echo "未找到 Homebrew 安装的 MySQL"
        exit 1
    fi
    
    # 显示信息
    echo "已安装的 MySQL 包:"
    for pkg in "${installed_packages[@]}"; do
        local version=$(brew list "$pkg" 2>/dev/null && mysql --version 2>/dev/null | head -1 || echo "未知")
        echo "  - $pkg: $version"
    done
    echo ""
    echo "数据目录: $(brew --prefix)/var/mysql"
    echo "配置文件: $(brew --prefix)/etc/my.cnf"
    echo ""
    
    # 检查运行中的进程
    local running_pids=$(pgrep -f "mysqld" 2>/dev/null || echo "")
    if [ -n "$running_pids" ]; then
        echo "警告: 检测到运行中的MySQL进程:"
        ps -p $running_pids -o pid,comm 2>/dev/null || echo "  PID: $running_pids"
        echo ""
    fi
    
    # 确认卸载
    read -p "是否继续卸载 Homebrew MySQL? [Y/n] " confirm
    confirm=${confirm:-Y}
    if [ "$confirm" = "n" ] || [ "$confirm" = "N" ]; then
        echo "取消卸载。"
        exit 0
    fi
    
    echo ""
    echo "执行卸载..."
    
    # 停止所有 MySQL 服务
    echo "停止 MySQL 服务..."
    for pkg in "${installed_packages[@]}"; do
        brew services stop "$pkg" 2>/dev/null || true
    done
    sleep 2
    
    # 强制终止进程
    if pgrep -f "mysqld" > /dev/null 2>&1; then
        echo "强制终止 mysqld 进程..."
        pkill -9 -f "mysqld" 2>/dev/null || true
        sleep 1
    fi
    
    # 卸载所有 MySQL 包
    echo "卸载 MySQL..."
    for pkg in "${installed_packages[@]}"; do
        echo "  卸载 $pkg..."
        brew uninstall "$pkg" 2>/dev/null || true
    done
    
    echo ""
    echo "MySQL 已卸载"
    
    # 询问是否删除数据目录
    local data_dir="$(brew --prefix)/var/mysql"
    if [ -d "$data_dir" ]; then
        echo ""
        echo "数据目录仍存在: $data_dir"
        ls -la "$data_dir" 2>/dev/null | head -5
        echo ""
        read -p "是否删除数据目录? [y/N] (默认不删除) " delete_data
        if [ "$delete_data" = "y" ] || [ "$delete_data" = "Y" ]; then
            rm -rf "$data_dir"
            echo "数据目录已删除"
        else
            echo "数据目录保留: $data_dir"
        fi
    fi
    
    # 询问是否删除配置文件
    local cnf_file="$(brew --prefix)/etc/my.cnf"
    if [ -f "$cnf_file" ]; then
        echo ""
        echo "配置文件仍存在: $cnf_file"
        read -p "是否删除配置文件? [y/N] (默认不删除) " delete_cnf
        if [ "$delete_cnf" = "y" ] || [ "$delete_cnf" = "Y" ]; then
            rm -f "$cnf_file"
            # 同时删除备份文件
            rm -f "${cnf_file}.bak" 2>/dev/null || true
            echo "配置文件已删除"
        else
            echo "配置文件保留: $cnf_file"
        fi
    fi
    
    echo ""
    echo "卸载完成！"
}

# 主逻辑
main() {
    # 检查是否是 Homebrew 卸载
    if [ "${1:-}" = "--brew" ]; then
        local brew_packages=($(find_installed_brew_mysql_packages))
        if [ ${#brew_packages[@]} -gt 0 ]; then
            uninstall_brew_mysql
            exit 0
        else
            echo "未检测到 Homebrew 安装的 MySQL"
            exit 1
        fi
    fi
    
    # 如果传入了参数，先验证是否为有效安装目录
    if [ -n "${1:-}" ]; then
        if [ -d "$1" ] && [ -f "$1/bin/mysqld" ]; then
            INSTALL_DIR=$(cd "$1" && pwd)
        else
            echo "指定的目录不是有效的MySQL安装: $1"
            exit 1
        fi
    else
        # 自动查找所有安装（兼容旧版bash）
        all_installs=()
        while IFS= read -r line; do
            [ -n "$line" ] && all_installs+=("$line")
        done < <(find_all_mysql_installs)
        select_install_dir "${all_installs[@]:-}"
        
        # 检查 INSTALL_DIR 是否有效
        if [ -z "$INSTALL_DIR" ] || [ ! -d "$INSTALL_DIR" ]; then
            echo "无效的安装目录"
            exit 1
        fi
    fi
    
    BIN_DIR="$INSTALL_DIR/bin"
    
    echo ""
    echo "即将卸载: $INSTALL_DIR"
    echo ""
    
    # 显示安装信息
    if [ -f "$INSTALL_DIR/bin/mysqld" ]; then
        local version=$("$INSTALL_DIR/bin/mysqld" --version 2>/dev/null | head -1 || echo "未知")
        echo "版本: $version"
    fi
    
    # 检查是否有运行中的进程
    local running_pids=$(pgrep -f "$INSTALL_DIR.*mysqld" 2>/dev/null || echo "")
    if [ -n "$running_pids" ]; then
        echo "警告: 检测到运行中的MySQL进程:"
        ps -p $running_pids -o pid,comm 2>/dev/null || echo "  PID: $running_pids"
    fi
    
    echo ""
    
    # 确认是否继续卸载
    read -p "是否继续卸载? [Y/n] " confirm
    confirm=${confirm:-Y}
    if [ "$confirm" == "n" ] || [ "$confirm" == "N" ]; then
        echo "取消卸载。"
        exit 0
    fi
    
    echo ""
    echo "执行卸载脚本..."
    
    # 停止服务
    if [ -f "$BIN_DIR/stop.sh" ]; then
        echo "调用 $BIN_DIR/stop.sh 停止MySQL..."
        bash "$BIN_DIR/stop.sh" || true
        echo "MySQL服务已停止。"
    else
        echo "未找到 $BIN_DIR/stop.sh，尝试终止mysqld进程..."
        pkill -f "$INSTALL_DIR/bin/mysqld" 2>/dev/null || true
        sleep 2
    fi
    
    # 再次检测并强制kill进程
    if pgrep -f "$INSTALL_DIR/bin/mysqld" > /dev/null 2>&1; then
        echo "mysqld进程仍在运行，强制终止..."
        pkill -9 -f "$INSTALL_DIR/bin/mysqld" 2>/dev/null || true
        sleep 2
        if pgrep -f "$INSTALL_DIR/bin/mysqld" > /dev/null 2>&1; then
            echo "警告: mysqld进程未能完全终止"
        else
            echo "mysqld进程已终止。"
        fi
    else
        echo "mysqld进程已终止。"
    fi
    
    # 检查端口占用
    if command -v lsof >/dev/null 2>&1; then
        if lsof -i :3306 2>/dev/null | grep -q mysqld; then
            echo "警告: 3306端口仍被mysqld占用"
        else
            echo "3306端口未被mysqld占用。"
        fi
    fi
    
    # 从配置文件中读取日志目录
    local cnf="$INSTALL_DIR/conf/my.cnf"
    local log_dir=""
    if [ -f "$cnf" ]; then
        log_dir=$(grep '^log-error' "$cnf" 2>/dev/null | awk -F'=' '{print $2}' | xargs dirname 2>/dev/null || echo "")
    fi
    [ -z "$log_dir" ] && log_dir="/var/log/mysql"
    
    echo ""
    echo "准备删除安装目录: $INSTALL_DIR"
    ls -la "$INSTALL_DIR" 2>/dev/null | head -10
    
    # 删除安装目录
    if [ -d "$INSTALL_DIR" ]; then
        rm -rf "$INSTALL_DIR"
        if [ -d "$INSTALL_DIR" ]; then
            echo "目录删除失败，请检查权限或进程占用。"
            lsof +D "$INSTALL_DIR" 2>/dev/null || echo "无法检查占用情况。"
            exit 1
        else
            echo "安装目录已成功删除。"
        fi
    else
        echo "安装目录不存在，无需删除。"
    fi
    
    # 删除日志目录（如果不是系统公共目录）
    if [ -n "$log_dir" ] && [ -d "$log_dir" ]; then
        case "$log_dir" in
            /var/log|/var/log/mysql|/usr/local/*)
                # 系统公共目录，只清理mysql相关文件
                rm -rf "$log_dir"/*.log 2>/dev/null || true
                echo "已清理日志文件。"
                ;;
            *)
                # 用户自定义目录，可以删除整个目录
                rm -rf "$log_dir"
                echo "日志目录已删除: $log_dir"
                ;;
        esac
    fi
    
    echo ""
    echo "MySQL已卸载: $INSTALL_DIR"
}

main "$@"