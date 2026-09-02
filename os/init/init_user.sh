#!/bin/bash

# 脚本功能：安全地创建用户组和用户（Linux / macOS 双平台支持）。
# 用法：
#   ./init_user.sh                          # 创建默认用户（macOS: admin/deploy, Linux: user1/user2）
#   ./init_user.sh --user dev               # 仅创建 dev 用户
#   ./init_user.sh --user dev --group sa    # 指定用户名和组名
#   sudo ./init_user.sh --user dev          # Linux 需要 root 权限

set -eo pipefail

# --- 平台检测 ---
detect_os() {
    case "$(uname -s)" in
        Darwin) echo "macos" ;;
        Linux)  echo "linux" ;;
        *)      echo "unknown" ;;
    esac
}
OS_TYPE="$(detect_os)"

# --- 默认配置 ---
GROUP_NAME="sa"
GROUP_ID="901"
# 默认创建的用户列表（可通过 --user 覆盖）
MACOS_DEFAULT_USERS=("admin" "deploy")
LINUX_DEFAULT_USERS=("user1" "user2")
# 通过命令行指定的用户（优先级最高）
CUSTOM_USERS=()
CUSTOM_GROUP=""
CUSTOM_GROUP_ID=""

# --- 函数定义 ---
log_message() { echo "[信息] $1"; }
warn_message() { echo -e "\033[1;33m[警告] $1\033[0m"; }
error_exit() { echo "[错误] $1" >&2; exit 1; }

# --- 参数解析 ---
usage() {
    cat << 'EOF'
用法: $0 [选项]

选项:
  --user NAME        指定要创建的用户名（可多次使用，如 --user dev --user test）
  --group NAME       指定用户组名（默认: sa）
  --group-id ID      指定用户组 GID（默认: 901）
  -h, --help         显示此帮助信息

示例:
  $0                          # 创建默认用户（macOS: admin/deploy, Linux: user1/user2）
  $0 --user dev               # 仅创建 dev 用户
  $0 --user dev --group dev   # 创建 dev 用户并归入 dev 组
  sudo $0 --user dev          # Linux 需要 root 权限

说明:
  - macOS 使用 dscl 管理用户，自动配置 sudo 免密
  - Linux 使用 useradd/groupadd，自动配置 sudo 免密
  - 创建的用户密码为随机，首次登录需修改
EOF
    exit 0
}

parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --user)
                [ -z "${2:-}" ] && error_exit "--user 需要指定用户名"
                CUSTOM_USERS+=("$2")
                shift 2
                ;;
            --group)
                [ -z "${2:-}" ] && error_exit "--group 需要指定组名"
                CUSTOM_GROUP="$2"
                shift 2
                ;;
            --group-id)
                [ -z "${2:-}" ] && error_exit "--group-id 需要指定 GID"
                CUSTOM_GROUP_ID="$2"
                shift 2
                ;;
            -h|--help)
                usage
                ;;
            *)
                error_exit "未知参数: $1（使用 -h 查看帮助）"
                ;;
        esac
    done

    # 覆盖默认配置
    [ -n "$CUSTOM_GROUP" ] && GROUP_NAME="$CUSTOM_GROUP" || true
    [ -n "$CUSTOM_GROUP_ID" ] && GROUP_ID="$CUSTOM_GROUP_ID" || true
}

# --- macOS: dscl 用户管理 ---
configure_users_macos() {
    local users=("$@")
    log_message "正在配置 macOS 用户和组..."

    # 检查组是否存在
    if ! dscl . -read "/Groups/${GROUP_NAME}" >/dev/null 2>&1; then
        log_message "用户组 '${GROUP_NAME}' 不存在，正在创建..."
        sudo dscl . -create "/Groups/${GROUP_NAME}"
        sudo dscl . -create "/Groups/${GROUP_NAME}" PrimaryGroupID "$GROUP_ID"
        sudo dscl . -create "/Groups/${GROUP_NAME}" RealName "System Administrators"
        sudo dscl . -create "/Groups/${GROUP_NAME}" Password "*"
        log_message "用户组 '${GROUP_NAME}' 已创建 (GID: $GROUP_ID)。"
    else
        log_message "用户组 '${GROUP_NAME}' 已存在，跳过创建。"
    fi

    # 创建用户
    local uid_start=910
    for user in "${users[@]}"; do
        if ! id "$user" &>/dev/null; then
            log_message "用户 '${user}' 不存在，正在创建..."

            # 查找下一个可用 UID
            while dscl . -search /Users UniqueID "$uid_start" 2>/dev/null | grep -q "$uid_start"; do
                uid_start=$((uid_start + 1))
            done

            sudo dscl . -create "/Users/${user}"
            sudo dscl . -create "/Users/${user}" UserShell "/bin/zsh"
            sudo dscl . -create "/Users/${user}" RealName "${user}"
            sudo dscl . -create "/Users/${user}" UniqueID "$uid_start"
            sudo dscl . -create "/Users/${user}" PrimaryGroupID "$GROUP_ID"
            sudo dscl . -create "/Users/${user}" NFSHomeDirectory "/Users/${user}"

            # 创建家目录
            sudo mkdir -p "/Users/${user}"
            sudo chown "${uid_start}:${GROUP_ID}" "/Users/${user}"

            # 设置密码为需要首次登录修改
            local temp_password
            temp_password=$(openssl rand -base64 12 2>/dev/null || echo "ChangeMeNow!")
            sudo dscl . -passwd "/Users/${user}" "$temp_password" 2>/dev/null || {
                warn_message "无法为用户 ${user} 设置密码。请手动执行: sudo passwd ${user}"
            }
            # 强制用户下次登录修改密码
            sudo pwpolicy -u "$user" -setpolicy "newPasswordRequired=1" 2>/dev/null || {
                warn_message "无法设置密码策略。请手动执行: sudo pwpolicy -u ${user} -setpolicy 'newPasswordRequired=1'"
            }

            log_message "用户 '${user}' 已创建 (UID: $uid_start)。"
            uid_start=$((uid_start + 1))
        else
            log_message "用户 '${user}' 已存在，跳过创建。"
        fi
    done

    # 授予 sudo 权限
    configure_sudo_macos

    log_message "macOS 用户和组配置完成。"
}

configure_sudo_macos() {
    local sudo_file="/private/etc/sudoers.d/90-${GROUP_NAME}-privileges"
    local sudo_rule="%${GROUP_NAME} ALL=(ALL) NOPASSWD: ALL"

    log_message "正在配置 sudo 权限..."
    if [ -f "$sudo_file" ] && grep -qFx -- "$sudo_rule" "$sudo_file" 2>/dev/null; then
        log_message "Sudo 规则已存在于 $sudo_file，跳过。"
    else
        log_message "正在向 $sudo_file 中添加 Sudo 规则..."
        echo "$sudo_rule" | sudo tee "$sudo_file" >/dev/null
        sudo chmod 440 "$sudo_file"
        log_message "Sudo 规则已创建。"
    fi
}

# --- Linux: useradd/groupadd 用户管理 ---
configure_users_linux() {
    local users=("$@")
    log_message "正在配置 Linux 用户和组..."

    if [ "$(id -u)" -ne 0 ]; then
        error_exit "此脚本必须以 root 权限运行。请使用 'sudo $0'。"
    fi

    if ! getent group "$GROUP_NAME" >/dev/null; then
        log_message "用户组 '${GROUP_NAME}' 不存在，正在创建..."
        groupadd -g "$GROUP_ID" "$GROUP_NAME"
    else
        log_message "用户组 '${GROUP_NAME}' 已存在，跳过创建。"
    fi

    local uid_start=910
    for user in "${users[@]}"; do
        if ! id "$user" &>/dev/null; then
            log_message "用户 '${user}' 不存在，正在创建..."
            useradd -g "$GROUP_NAME" -u "$uid_start" -m -s /bin/bash "$user"
            log_message "用户 '${user}' 已创建 (UID: $uid_start)。"
            log_message "正在设置 '${user}' 的密码为下次登录时修改状态..."
            chage -d 0 "$user"
            uid_start=$((uid_start + 1))
        else
            log_message "用户 '${user}' 已存在，跳过创建。"
        fi
    done

    configure_sudo_linux

    log_message "Linux 用户和组配置完成。"
}

configure_sudo_linux() {
    local sudo_file="/etc/sudoers.d/90-${GROUP_NAME}-privileges"
    local sudo_rule="%${GROUP_NAME} ALL=(ALL) NOPASSWD: ALL"

    log_message "正在配置 sudo 权限..."
    if [ -f "$sudo_file" ] && grep -qFx -- "$sudo_rule" "$sudo_file" 2>/dev/null; then
        log_message "Sudo 规则已存在于 $sudo_file，跳过。"
    else
        log_message "正在向 $sudo_file 中添加 Sudo 规则..."
        echo "$sudo_rule" > "$sudo_file"
        chmod 440 "$sudo_file"
        log_message "Sudo 规则已创建。"
    fi
}

# --- 主逻辑 ---
main() {
    parse_args "$@"

    # 获取要创建的用户列表
    local users=()
    if [ ${#CUSTOM_USERS[@]} -gt 0 ]; then
        users=("${CUSTOM_USERS[@]}")
    else
        if [ "$OS_TYPE" == "macos" ]; then
            users=("${MACOS_DEFAULT_USERS[@]}")
        else
            users=("${LINUX_DEFAULT_USERS[@]}")
        fi
    fi

    if [ ${#users[@]} -eq 0 ]; then
        error_exit "未指定要创建的用户。使用 --user NAME 指定，或 -h 查看帮助。"
    fi

    log_message "检测到操作系统: $(uname -s) ($OS_TYPE)"
    log_message "用户组: $GROUP_NAME (GID: $GROUP_ID)"
    log_message "待创建用户: ${users[*]}"
    echo ""

    case "$OS_TYPE" in
        macos)
            configure_users_macos "${users[@]}"
            ;;
        linux)
            configure_users_linux "${users[@]}"
            ;;
        *)
            error_exit "不支持的操作系统: $(uname -s)。目前仅支持 Linux 和 macOS。"
            ;;
    esac
}

main "$@"
