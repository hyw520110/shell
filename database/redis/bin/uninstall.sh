#!/usr/bin/env bash
# redis uninstall script
# 用法: ./uninstall.sh [INSTALL_DIR]

# 默认安装目录
DEFAULT_INSTALL_DIR="/opt/redis"
# 获取脚本所在目录
SCRIPT_DIR="$(cd "$(dirname "$0")"; pwd)"
# 获取安装目录
if [ -d "$DEFAULT_INSTALL_DIR" ]; then
    INSTALL_DIR="$DEFAULT_INSTALL_DIR"
fi

# 检查安装目录是否存在
if [ ! -d "$INSTALL_DIR" ]; then
  path=$(find $HOME -name redis-server 2>/dev/null  | head -1)
  [ -n "$path" ] && INSTALL_DIR=$(dirname $(dirname $path))
fi
# 检测操作系统类型
OS_TYPE=$(uname)

# 清理环境变量
cleanup_environment() {
    echo "正在清理环境变量..."

    # 优先尝试清理系统级配置
    local profile_script="/etc/profile.d/redis.sh"
    if [ -f "$profile_script" ]; then
        if [ -w "$profile_script" ] || sudo -n true 2>/dev/null; then
            echo "正在删除系统级环境变量配置文件 $profile_script..."
            sudo rm -f "$profile_script"
            echo "系统级配置已删除。"
            echo -e "\033[33m请重新登录或启动新 shell 以使更改完全生效。\033[0m"
            return
        fi
    fi

    # 如果系统级文件不存在或无法删除，则回退到用户级清理
    echo "未找到或无法删除系统级配置文件，将尝试清理用户级配置..."
    local shell_type
    shell_type=$(basename "$SHELL")
    local rc_file
    
    if [ "$shell_type" = "bash" ]; then
        rc_file="$HOME/.bashrc"
    elif [ "$shell_type" = "zsh" ]; then
        rc_file="$HOME/.zshrc"
    else
        echo "不支持的 shell 类型: $shell_type。无法自动清理用户级环境变量。"
        return
    fi
    
    if [ -f "$rc_file" ]; then
        # 使用标记来查找并删除整个Redis配置块
        if [[ "$OS_TYPE" == "Darwin" ]]; then
            sed -i.bak '/# START REDIS CONFIG/,/# END REDIS CONFIG/d' "$rc_file"
        else
            sed -i.bak '/^# START REDIS CONFIG$/,/^# END REDIS CONFIG$/d' "$rc_file"
        fi
        echo "已从 $rc_file 中删除 Redis 用户级环境变量配置。"
        echo -e "\033[33m请运行 source $rc_file 或重新启动终端使更改生效。\033[0m"
    else
        echo "配置文件 $rc_file 未找到，无需清理。"
    fi
}

# 检查安装目录是否存在
if [ ! -d "$INSTALL_DIR" ]; then
    echo "错误: 未安装"
    exit 1
fi
echo "安装目录:$INSTALL_DIR"
echo "注意即将开始卸载,数据如需备份需手动备份"
# 确认是否执行卸载
read -p "确定要卸载 Redis 吗? (y/N): " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "取消卸载操作"
    exit 0
fi

# 检查是否需要sudo权限
need_sudo=false
if [ ! -w "$INSTALL_DIR" ] || [ ! -w "$(dirname "$INSTALL_DIR")" ]; then
    need_sudo=true
fi

# 1. 先调用停止脚本停止Redis服务
echo "正在停止 Redis 服务..."
if [ -f "$INSTALL_DIR/bin/stop.sh" ] && [ -x "$INSTALL_DIR/bin/stop.sh" ]; then
    if [ "$need_sudo" = true ] && sudo -n true 2>/dev/null; then
        sudo "$INSTALL_DIR/bin/stop.sh"
    else
        "$INSTALL_DIR/bin/stop.sh"
    fi
else
    echo "警告: 未找到停止脚本，尝试使用 kill 命令停止 Redis 进程..."
    # 尝试直接杀死Redis进程
    if [ "$need_sudo" = true ] && sudo -n true 2>/dev/null; then
        pids=$(sudo ps -ef | grep "redis-server" | grep -v grep | awk '{print $2}')
    else
        pids=$(ps -ef | grep "redis-server" | grep -v grep | awk '{print $2}')
    fi
    
    if [ -n "$pids" ]; then
        echo "正在终止 Redis 进程: $pids"
        if [ "$need_sudo" = true ] && sudo -n true 2>/dev/null; then
            sudo kill $pids 2>/dev/null || sudo kill -9 $pids 2>/dev/null
        else
            kill $pids 2>/dev/null || kill -9 $pids 2>/dev/null
        fi
        sleep 2
    else
        echo "未发现运行中的 Redis 进程"
    fi
fi

# 2. 停止systemd服务（如果存在）
if [[ "$OS_TYPE" != "Darwin" ]]; then
    echo "正在停止 systemd 服务..."
    sudo -n systemctl stop redis.service 2>/dev/null || systemctl stop redis.service 2>/dev/null || echo "未找到 redis systemd 服务"
    sudo -n systemctl disable redis.service 2>/dev/null || systemctl disable redis.service 2>/dev/null || echo "未启用 redis systemd 服务"
    sudo -n rm -f /usr/lib/systemd/system/redis.service 2>/dev/null || rm -f /usr/lib/systemd/system/redis.service 2>/dev/null
    sudo -n systemctl daemon-reload 2>/dev/null || systemctl daemon-reload 2>/dev/null || echo "systemd 重新加载失败"
fi

# 3. 删除安装目录
echo "正在删除 Redis 安装目录..."
if [ "$INSTALL_DIR" != "/" ] && [ -n "$INSTALL_DIR" ]; then
    if [ "$need_sudo" = true ]; then
        echo "需要sudo权限来删除安装目录..."
        sudo rm -rf "$INSTALL_DIR"
    else
        rm -rf "$INSTALL_DIR"
    fi
    [ $? -eq 0 ] && echo "已删除安装目录: $INSTALL_DIR" || echo "删除安装目录 $INSTALL_DIR 失败"
else
    echo "错误: 无效的安装目录路径"
    exit 1
fi

# 4. 删除可能存在的系统级配置
if [[ "$OS_TYPE" != "Darwin" ]]; then
    echo "正在清理系统级配置..."
    # 删除可能的系统级配置文件
    sudo -n rm -f /etc/redis.conf 2>/dev/null || rm -f /etc/redis.conf 2>/dev/null
    sudo -n rm -f /etc/redis/*.conf 2>/dev/null || rm -f /etc/redis/*.conf 2>/dev/null
    sudo -n rmdir /etc/redis 2>/dev/null || rmdir /etc/redis 2>/dev/null || echo "目录 /etc/redis 不存在或不为空"
    
    # 删除日志轮转配置
    sudo -n rm -f /etc/logrotate.d/redis 2>/dev/null || rm -f /etc/logrotate.d/redis 2>/dev/null
    
    # 删除可能的系统服务文件
    sudo -n find /etc/systemd/system -name "*redis*" -delete 2>/dev/null || find /etc/systemd/system -name "*redis*" -delete 2>/dev/null
fi

# 清理环境变量
cleanup_environment

echo "✅ Redis 卸载完成"
