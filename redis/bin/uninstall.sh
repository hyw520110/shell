#!/usr/bin/env bash
# redis uninstall script
# 用法: ./uninstall.sh [INSTALL_DIR]

set -e

# 默认安装目录
DEFAULT_INSTALL_DIR="/opt/redis"

# 获取脚本所在目录
SCRIPT_DIR="$(cd "$(dirname "$0")"; pwd)"
# 获取安装目录
INSTALL_DIR="${1:-$(cd "$SCRIPT_DIR/.."; pwd)}"

# 检测操作系统类型
OS_TYPE=$(uname)

echo "Redis 卸载脚本"
echo "安装目录: $INSTALL_DIR"
echo "----------------------------------------"

# 检查安装目录是否存在
if [ ! -d "$INSTALL_DIR" ]; then
    echo "错误: 安装目录 $INSTALL_DIR 不存在"
    exit 1
fi

# 确认是否执行卸载
read -p "确定要卸载 Redis 吗? (y/N): " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "取消卸载操作"
    exit 0
fi

# 1. 先调用停止脚本停止Redis服务
echo "正在停止 Redis 服务..."
if [ -f "$INSTALL_DIR/bin/stop.sh" ] && [ -x "$INSTALL_DIR/bin/stop.sh" ]; then
    "$INSTALL_DIR/bin/stop.sh"
else
    echo "警告: 未找到停止脚本，尝试使用 kill 命令停止 Redis 进程..."
    # 尝试直接杀死Redis进程
    pids=$(ps -ef | grep "redis-server" | grep -v grep | awk '{print $2}')
    if [ -n "$pids" ]; then
        echo "正在终止 Redis 进程: $pids"
        kill $pids 2>/dev/null || kill -9 $pids 2>/dev/null
        sleep 2
    else
        echo "未发现运行中的 Redis 进程"
    fi
fi

# 2. 停止systemd服务（如果存在）
if [[ "$OS_TYPE" != "Darwin" ]]; then
    echo "正在停止 systemd 服务..."
    systemctl stop redis.service 2>/dev/null || echo "未找到 redis systemd 服务"
    systemctl disable redis.service 2>/dev/null || echo "未启用 redis systemd 服务"
    rm -f /usr/lib/systemd/system/redis.service 2>/dev/null
    systemctl daemon-reload 2>/dev/null || echo "systemd 重新加载失败"
fi

# 3. 删除安装目录
echo "正在删除 Redis 安装目录..."
if [ "$INSTALL_DIR" != "/" ] && [ -n "$INSTALL_DIR" ]; then
    rm -rf "$INSTALL_DIR"
    echo "已删除安装目录: $INSTALL_DIR"
else
    echo "错误: 无效的安装目录路径"
    exit 1
fi

# 4. 删除可能存在的系统级配置
if [[ "$OS_TYPE" != "Darwin" ]]; then
    echo "正在清理系统级配置..."
    # 删除可能的系统级配置文件
    rm -f /etc/redis.conf 2>/dev/null
    rm -f /etc/redis/*.conf 2>/dev/null
    rmdir /etc/redis 2>/dev/null || echo "目录 /etc/redis 不存在或不为空"
    
    # 删除日志轮转配置
    rm -f /etc/logrotate.d/redis 2>/dev/null
    
    # 删除可能的系统服务文件
    find /etc/systemd/system -name "*redis*" -delete 2>/dev/null
fi

echo "✅ Redis 卸载完成"
echo ""
echo "注意:"
echo "1. 如果您手动修改过系统配置文件，请手动清理"
echo "2. 如果您设置了环境变量，请手动移除"
echo "3. 相关数据文件如果需要请手动备份"