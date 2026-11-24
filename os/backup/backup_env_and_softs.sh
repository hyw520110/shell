#!/bin/bash

# 显示帮助信息
show_help() {
    cat << EOF
系统环境备份脚本

备份系统配置文件和已安装软件列表，便于环境迁移和恢复。

用法: ./backup_env_and_softs.sh [备份目录]

参数:
    备份目录         备份目标目录（默认: $HOME/system_backup_时间戳）

选项:
    -h, --help        显示此帮助信息
    -v, --version     显示版本信息

说明:
    - 备份环境配置文件（.bashrc, .zshrc 等）
    - 备份系统配置文件（/etc/profile, sshd_config 等）
    - 生成已安装软件列表
    - 扫描用户安装的应用程序
    - 支持增量备份
    - 自动添加时间戳

备份内容包括:
    - Shell 配置: .bashrc, .zshrc, .profile
    - 系统配置: /etc/profile, /etc/fstab
    - SSH 配置: /etc/ssh/sshd_config
    - 软件列表: apt/rpm/dpkg 已安装软件
    - 桌面应用: .desktop 文件扫描

示例:
    ./backup_env_and_softs.sh                    # 使用默认备份目录
    ./backup_env_and_softs.sh /backup/system     # 指定备份目录

恢复方式:
    # 恢复配置文件
    cp -r /backup/system/* /

    # 查看软件列表
    cat /backup/system/installed_packages.txt

注意事项:
    - 需要root权限备份系统配置
    - 备份文件包含敏感信息，注意安全
    - 建议定期执行备份
    - 恢复时注意文件覆盖

EOF
}

# 参数解析
if [[ "$1" == "-h" ]] || [[ "$1" == "--help" ]]; then
    show_help
    exit 0
fi

if [[ "$1" == "-v" ]] || [[ "$1" == "--version" ]]; then
    echo "系统环境备份脚本版本: 1.0"
    exit 0
fi

# This script backs up various system configurations and lists of installed software.

set -eo pipefail

# --- Configuration ---
# Default backup directory, timestamped to prevent overwriting previous backups.
BACKUP_DIR="${1:-$HOME/system_backup_$(date +%Y%m%d_%H%M%S)}"

# Files to backup (relative to HOME or absolute)
ENV_CONFIG_FILES=(
    "$HOME/.bashrc"
    "$HOME/.bash_profile"
    "$HOME/.profile"
    "$HOME/.bash_aliases"
    "$HOME/.zshrc"
    "/etc/profile"
    "/etc/bash.bashrc"
    "/etc/environment"
    "/etc/fstab" # Example: add other critical config files
    "/etc/ssh/sshd_config"
)
# Directories to scan for .desktop files (for user-installed apps)
DESKTOP_SCAN_DIRS=(
    "/var/lib/linglong/"
    "/opt/apps/"
    "$HOME/.local/share/applications/"
)
# --- End Configuration ---

# --- Helper Functions ---
log_message() { echo "[信息] $1"; }
error_exit() { echo "[错误] $1" >&2; exit 1; }

# --- Main Logic ---
main() {
    # 1. Check for root privileges
    if [ "$(id -u)" -ne 0 ]; then
        log_message "警告: 当前为非root用户。部分文件（如 /etc 下的文件）可能无法备份。"
        # error_exit "此脚本必须以root权限运行。" # Uncomment to make root mandatory
    fi

    log_message "正在创建备份目录: $BACKUP_DIR"
    mkdir -p "$BACKUP_DIR"

    # 2. 备份当前环境变量
    log_message "正在备份当前环境变量..."
    env > "$BACKUP_DIR/environment_variables.txt"

    # 3. 备份环境变量配置文件
    log_message "正在备份环境变量配置文件..."
    for file in "${ENV_CONFIG_FILES[@]}"; do
        if [[ -f "$file" ]]; then
            local backup_path="${BACKUP_DIR}/configs/${file#/}" # Reconstruct path structure
            mkdir -p "$(dirname "$backup_path")"
            cp -p "$file" "$backup_path" # -p preserves permissions, timestamps
            log_message "  已备份: $file"
        else
            log_message "  跳过 (未找到): $file"
        fi
    done

    # 4. 备份已安装的软件包清单 (Debian/Ubuntu)
    local installed_packages_file="$BACKUP_DIR/installed_packages_list.txt"
    if command -v dpkg &>/dev/null; then
        log_message "正在备份已安装的Debian软件包清单..."
        dpkg -l | awk '/^ii/{print $2}' | sort > "$installed_packages_file"
        log_message "  已生成: $installed_packages_file"
    else
        log_message "跳过Debian软件包清单备份 (dpkg 未找到)。"
    fi

    # 5. 备份通过 .desktop 文件识别的应用清单
    log_message "正在生成通过 .desktop 文件识别的应用清单..."
    local desktop_app_list_file="$BACKUP_DIR/installed_desktop_applications.txt"
    > "$desktop_app_list_file" # Create/clear the file

    for dir in "${DESKTOP_SCAN_DIRS[@]}"; do
        if [ -d "$dir" ]; then
            log_message "  正在扫描目录: $dir"
            # 使用 find -print0 | while read -r -d '' 这种安全方式处理文件名
            find "$dir" -type f -name "*.desktop" -print0 | while IFS= read -r -d '' desktop_file; do
                local name=$(grep -Po '^Name=\K.*' "$desktop_file" || true) # || true prevents script exit on grep failure
                local exec_cmd=$(grep -Po '^Exec=\K.*' "$desktop_file" || true)
                
                if [ -n "$name" ] && [ -n "$exec_cmd" ]; then
                    echo "Name: $name" >> "$desktop_app_list_file"
                    echo "Exec: $exec_cmd" >> "$desktop_app_list_file"
                    echo "Path: $desktop_file" >> "$desktop_app_list_file"
                    echo "---" >> "$desktop_app_list_file"
                fi
            done
        else
            log_message "  跳过 (目录不存在): $dir"
        fi
    done
    log_message "  已生成: $desktop_app_list_file"

    # 6. 复制配套的恢复脚本
    if [ -f "./recovery.sh" ]; then
        log_message "正在复制 recovery.sh 到备份目录..."
        cp -p "./recovery.sh" "$BACKUP_DIR/"
        chmod +x "$BACKUP_DIR/recovery.sh"
        log_message "  已复制并授权: $BACKUP_DIR/recovery.sh"
    else
        log_message "警告: 当前目录未找到 recovery.sh。跳过复制。"
    fi

    log_message "备份完成。所有备份文件存储在: $BACKUP_DIR"
}

# 执行主函数
main "$@"
