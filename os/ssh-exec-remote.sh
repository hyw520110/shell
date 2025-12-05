#!/bin/bash

# Filename: ssh-exec-remote.sh
# 功能: 一个通用的工具脚本，用于自动连接目标主机并执行命令。
#       支持SSH密钥认证和密码认证（当密码作为参数提供时）。
#
# 警告: 直接在命令行中传递密码是【不安全】的。
#       密码将以明文形式出现在进程列表（例如 'ps -ef'）中。
#       请尽可能使用SSH密钥认证进行自动化操作。

set -eo pipefail

# --- 配置 ---
SSH_CONNECT_TIMEOUT=10 # SSH连接超时时间（秒）
# --- 结束配置 ---

# --- 辅助函数 ---
log_message() { echo "[信息] $1"; }
warn_message() { echo "[警告] $1"; }
error_exit() { echo "[错误] $1" >&2; exit 1; }

# 显示帮助信息
show_help() {
    echo "用法: $0 <用户> <主机> [密码] <命令>"
    echo
    echo "在远程主机上执行命令，优先尝试SSH密钥认证，然后回退到密码认证。"
    echo
    echo "参数:"
    echo "  用户      : SSH登录的用户名。"
    echo "  主机      : 远程服务器的主机名或IP地址。"
    echo "  密码      : (可选) SSH登录密码。如果省略，则只尝试密钥认证。"
    echo "  命令      : 要在远程主机上执行的命令 (必须是最后一个参数)。"
    echo
    echo "示例 (密钥认证): $0 myuser myserver.com 'ls -l /tmp'"
    echo "示例 (密码认证): $0 myuser myserver.com mypassword 'df -h'"
    echo
    warn_message "警告: 提供密码在命令行中是【不安全】的。"
    warn_message "         它将以明文形式出现在进程列表（例如 'ps -ef'）中。"
    warn_message "         请使用SSH密钥进行安全自动化。"
}

# --- 主逻辑 ---
main() {
    # 解析参数
    if [ "$#" -lt 3 ]; then # 最小参数: 用户, 主机, 命令 (如果无密码)
        show_help
        exit 1
    fi

    local user="$1"
    local host="$2"
    local password=""
    local remote_command=""

    # 判断密码是否提供
    if [ "$#" -eq 3 ]; then # 用户 主机 命令
        remote_command="$3"
    elif [ "$#" -eq 4 ]; then # 用户 主机 密码 命令
        password="$3"
        remote_command="$4"
        warn_message "安全警告: 密码已在命令行中提供。它将以明文形式出现在 'ps -ef' 进程列表中。"
    else
        show_help
        exit 1
    fi

    log_message "尝试连接 ${user}@${host} 并执行 '${remote_command}'..."

    # --- 优先尝试SSH密钥认证 ---
    # -o BatchMode=yes: 批处理模式，不进行交互式密码提示
    # -o StrictHostKeyChecking=no: 首次连接时自动接受主机密钥 (生产环境不推荐，应预先添加)
    # -o ConnectTimeout: 防止挂起
    # -q: 安静模式
    # 2>/dev/null: 抑制SSH的错误输出，如“Permission denied (publickey,password).”
    ssh_output=$(ssh -q -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout="$SSH_CONNECT_TIMEOUT" \
                     "${user}@${host}" "$remote_command" 2>/dev/null)
    ssh_exit_code=$?

    if [ "$ssh_exit_code" -eq 0 ]; then
        log_message "SSH密钥认证成功。"
        echo "$ssh_output"
        exit 0
    elif [ -n "$password" ]; then
        log_message "SSH密钥认证失败或未配置。回退到密码认证..."
        
        # --- 回退到密码认证 ---
        # 首选 sshpass，因为它比 expect 更简单
        if command -v sshpass &>/dev/null; then
            log_message "使用 sshpass 进行密码认证。"
            ssh_output=$(sshpass -p "$password" ssh -q -o StrictHostKeyChecking=no -o ConnectTimeout="$SSH_CONNECT_TIMEOUT" \
                                 "${user}@${host}" "$remote_command")
            ssh_exit_code=$?
            if [ "$ssh_exit_code" -eq 0 ]; then
                log_message "密码认证成功 (通过 sshpass)。"
                echo "$ssh_output"
                exit 0
            else
                error_exit "密码认证失败。请检查密码或主机。"
            fi
        elif command -v expect &>/dev/null; then
            log_message "使用 expect 进行密码认证。"
            # expect 脚本用于密码认证
            expect_script=$(cat <<'EOF'
                set timeout [lindex $argv 0]
                set user [lindex $argv 1]
                set host [lindex $argv 2]
                set password [lindex $argv 3]
                set command [lindex $argv 4]

                spawn ssh -o StrictHostKeyChecking=no -o ConnectTimeout=$timeout $user@$host $command

                expect {
                    timeout { exit 1 }
                    "yes/no" { send "yes\r"; exp_continue }
                    "*assword" { send "$password\r" }
                    eof { exit 0 }
                }
                expect eof
EOF
            )
            # 运行 expect 脚本
            expect_output=$(expect -c "$expect_script" "$SSH_CONNECT_TIMEOUT" "$user" "$host" "$password" "$remote_command")
            expect_exit_code=$?

            if [ "$expect_exit_code" -eq 0 ]; then
                log_message "密码认证成功 (通过 expect)。"
                echo "$expect_output"
                exit 0
            else
                error_exit "密码认证失败 (通过 expect)。请检查密码或主机。"
            fi
        else
            error_exit "密码认证需要，但未找到 'sshpass' 或 'expect' 命令。无法继续。"
        fi
    else
        error_exit "SSH密钥认证失败，且未提供密码。无法继续。"
    fi
}

main "$@"