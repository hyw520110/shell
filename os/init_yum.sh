#!/bin/bash

# 脚本功能：为CentOS 7系统配置YUM/DNF，切换到阿里云镜像并安装EPEL源。

set -eo pipefail

# --- 配置 ---
REPO_URL="http://mirrors.aliyun.com/repo/Centos-7.repo"
REPO_FILE="/etc/yum.repos.d/CentOS-Base.repo"
# 用于判断是否已配置阿里云镜像的标记字符串
ALIYUN_MARKER="mirrors.aliyun.com"
# --- 结束配置 ---

# --- 函数定义 ---
log_message() { echo "[信息] $1"; }
error_exit() { echo "[错误] $1" >&2; exit 1; }

# --- 主逻辑 ---
main() {
    # 1. 检查是否为root用户
    if [ "$(id -u)" -ne 0 ]; then
        error_exit "此脚本必须以root权限运行。请使用 'sudo $0'。"
    fi

    # 2. 检查是否为CentOS系统
    if ! grep -q -i "centos" /etc/os-release; then
        error_exit "此脚本似乎不是在CentOS系统上运行。正在退出..."
    fi
    
    # 3. 确定使用yum还是dnf
    if command -v dnf &>/dev/null; then
        PKG_MGR="dnf"
    elif command -v yum &>/dev/null; then
        PKG_MGR="yum"
    else
        error_exit "未找到 'yum' 或 'dnf' 包管理器。"
    fi
    log_message "检测到包管理器: $PKG_MGR"

    # 4. 配置阿里云镜像（如果尚未配置）
    if [ -f "$REPO_FILE" ] && grep -q "$ALIYUN_MARKER" "$REPO_FILE"; then
        log_message "检测到阿里云镜像已配置，跳过。"
    else
        log_message "正在备份当前的Repo文件..."
        # -n 选项确保不会覆盖已存在的备份
        cp -n "$REPO_FILE" "${REPO_FILE}.bak.$(date +%Y%m%d)"

        log_message "正在从阿里云下载新的Repo文件..."
        if ! wget -O "$REPO_FILE" "$REPO_URL"; then
            error_exit "下载Repo文件失败。请检查网络。"
        fi
        log_message "Repo文件已成功替换。"
    fi

    # 5. 安装EPEL源（如果尚未安装）
    if $PKG_MGR -q list installed epel-release &>/dev/null; then
        log_message "EPEL源已安装，跳过。"
    else
        log_message "正在安装EPEL源..."
        $PKG_MGR install -y epel-release
    fi

    # 6. 清理并重建缓存
    log_message "正在清理并重建缓存，这可能需要一点时间..."
    $PKG_MGR clean all
    $PKG_MGR makecache

    log_message "YUM/DNF源配置完成。"
}

# 执行主函数
main "$@"
