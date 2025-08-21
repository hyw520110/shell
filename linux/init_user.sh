#!/bin/bash

# 脚本功能：安全地创建用户组和用户，并通过在 /etc/sudoers.d/ 目录下创建文件的方式授予sudo权限。

set -eo pipefail

# --- 配置 ---
GROUP_NAME="sa"
GROUP_ID="901"
# 将要创建的用户列表，可在此处增删
USERS_TO_CREATE=("user1" "user2")
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

    # 2. 创建用户组（如果不存在）
    if ! getent group "$GROUP_NAME" >/dev/null; then
        log_message "用户组 '$GROUP_NAME' 不存在，正在创建..."
        groupadd -g "$GROUP_ID" "$GROUP_NAME"
    else
        log_message "用户组 '$GROUP_NAME' 已存在，跳过创建。"
    fi

    # 3. 循环创建用户（如果不存在）
    local uid_start=910 # 为新用户定义一个起始UID
    for user in "${USERS_TO_CREATE[@]}"; do
        if ! id "$user" &>/dev/null; then
            log_message "用户 '$user' 不存在，正在创建..."
            # -m: 创建家目录; -s: 指定shell
            useradd -g "$GROUP_NAME" -u "$uid_start" -m -s /bin/bash "$user"
            log_message "用户 '$user' 已创建，UID为 $uid_start。"
            
            # 安全实践：不设置初始密码，而是强制用户在首次登录时自行修改
            log_message "正在设置 '$user' 的密码为“下次登录时修改”状态..."
            chage -d 0 "$user"
            
            # UID自增，确保下一个用户UID不重复
            uid_start=$((uid_start + 1))
        else
            log_message "用户 '$user' 已存在，跳过创建。"
        fi
    done

    # 4. 使用安全的方式授予sudo权限
    local sudo_file="/etc/sudoers.d/90-${GROUP_NAME}-privileges"
    local sudo_rule="%${GROUP_NAME} ALL=(ALL) NOPASSWD: ALL"
    
    log_message "正在配置sudo权限..."
    if [ -f "$sudo_file" ] && grep -qFx -- "$sudo_rule" "$sudo_file"; then
        log_message "Sudo规则已存在于 $sudo_file，跳过。"
    else
        log_message "正在向 $sudo_file 中添加Sudo规则..."
        echo "$sudo_rule" > "$sudo_file"
        # /etc/sudoers.d/ 下的文件必须有严格的权限
        chmod 440 "$sudo_file"
        log_message "Sudo规则已创建。"
    fi

    log_message "用户和组初始化完成。"
}

# 执行主函数
main "$@"
