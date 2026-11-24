#!/bin/bash

# ============================================================================
# Git 配置脚本
# 功能：多平台支持、多账户管理、SSH 密钥管理、GPG 签名、代理配置等
#
# 使用方法:
#   ./setup_git.sh [选项]
#
# 选项:
#   --key-type TYPE      SSH 密钥类型 (ed25519|rsa|ecdsa|ecdsa521) [默认: ed25519]
#   --email EMAIL        Git 用户邮箱
#   --name NAME          Git 用户名
#   --platform PLATFORM  配置平台 (github|gitee|gitlab|bitbucket|gitea)
#   --gitea-url URL      Gitea 服务器地址 (如 https://git.example.com)
#   --skip-menu          跳过菜单，直接执行配置
#   --help               显示帮助信息
# ============================================================================

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# 全局变量
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SSH_CONFIG_FILE="$HOME/.ssh/config"
BACKUP_DIR="$HOME/.git_setup_backups"
CURRENT_DATE=$(date +%Y%m%d_%H%M%S)

# 命令行参数变量
DEFAULT_KEY_TYPE="ed25519"
PARAM_KEY_TYPE=""
PARAM_EMAIL=""
PARAM_NAME=""
PARAM_PLATFORM=""
PARAM_GITEA_URL=""
SKIP_MENU=false

# ============================================================================
# 辅助函数
# ============================================================================

print_header() {
    echo -e "${CYAN}-- $1 --${NC}"
}

print_success() {
    echo -e "${GREEN}[OK]${NC} $1"
}

# ============================================================================
# 兼容性函数
# ============================================================================

# 超时命令包装 (macOS 兼容)
# 使用方法: timeout_cmd <秒数> <命令> [参数...]
timeout_cmd() {
    local timeout_seconds="$1"
    shift

    if command -v timeout >/dev/null 2>&1; then
        # Linux 系统有 timeout 命令
        timeout "$timeout_seconds" "$@"
    else
        # macOS 或其他没有 timeout 命令的系统
        local cmd="$1"
        shift
        (
            "$cmd" "$@" &
            local pid=$!
            (
                sleep "$timeout_seconds"
                kill -0 $pid 2>/dev/null && kill -TERM $pid 2>/dev/null
            ) &
            local timer_pid=$!
            wait $pid 2>/dev/null
            local exit_code=$?
            kill -0 $timer_pid 2>/dev/null && kill -TERM $timer_pid 2>/dev/null
            exit $exit_code
        )
    fi
}

print_error() {
    echo -e "${RED}[ERR]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

print_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

check_command() {
    if ! command -v "$1" &>/dev/null; then
        print_warning "$1 未安装，尝试自动安装..."
        install_command "$1"
        return $?
    fi
    return 0
}

install_command() {
    local cmd="$1"
    local os_type=$(uname -s)
    
    print_info "正在安装 $cmd..."
    
    case "$os_type" in
        Darwin)
            # macOS系统
            if ! command -v brew &>/dev/null; then
                print_error "Homebrew未安装，无法自动安装 $cmd"
                print_info "请先安装Homebrew: /bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""
                return 1
            fi
            
            case "$cmd" in
                git)
                    brew install git
                    ;;
                ssh-keygen)
                    brew install openssh
                    ;;
                gpg)
                    brew install gnupg
                    ;;
                git-lfs)
                    brew install git-lfs
                    ;;
                *)
                    print_error "不支持的自动安装: $cmd"
                    return 1
                    ;;
            esac
            ;;
        Linux)
            # Linux系统
            if command -v apt-get &>/dev/null; then
                # Debian/Ubuntu系列
                sudo apt-get update
                case "$cmd" in
                    git)
                        sudo apt-get install -y git
                        ;;
                    ssh-keygen)
                        sudo apt-get install -y openssh-client
                        ;;
                    gpg)
                        sudo apt-get install -y gnupg
                        ;;
                    git-lfs)
                        sudo apt-get install -y git-lfs
                        ;;
                    *)
                        print_error "不支持的自动安装: $cmd"
                        return 1
                        ;;
                esac
            elif command -v yum &>/dev/null; then
                # CentOS/RHEL系列
                case "$cmd" in
                    git)
                        sudo yum install -y git
                        ;;
                    ssh-keygen)
                        sudo yum install -y openssh-clients
                        ;;
                    gpg)
                        sudo yum install -y gnupg2
                        ;;
                    git-lfs)
                        sudo yum install -y git-lfs
                        ;;
                    *)
                        print_error "不支持的自动安装: $cmd"
                        return 1
                        ;;
                esac
            elif command -v dnf &>/dev/null; then
                # Fedora系列
                case "$cmd" in
                    git)
                        sudo dnf install -y git
                        ;;
                    ssh-keygen)
                        sudo dnf install -y openssh-clients
                        ;;
                    gpg)
                        sudo dnf install -y gnupg2
                        ;;
                    git-lfs)
                        sudo dnf install -y git-lfs
                        ;;
                    *)
                        print_error "不支持的自动安装: $cmd"
                        return 1
                        ;;
                esac
            else
                print_error "未检测到支持的包管理器（apt/yum/dnf）"
                return 1
            fi
            ;;
        *)
            print_error "不支持的操作系统: $os_type"
            return 1
            ;;
    esac
    
    # 验证安装是否成功
    if command -v "$cmd" &>/dev/null; then
        print_success "$cmd 安装成功"
        return 0
    else
        print_error "$cmd 安装失败"
        return 1
    fi
}

# ============================================================================
# 参数解析
# ============================================================================

parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --key-type)
                PARAM_KEY_TYPE="$2"
                shift 2
                ;;
            --email)
                PARAM_EMAIL="$2"
                shift 2
                ;;
            --name)
                PARAM_NAME="$2"
                shift 2
                ;;
            --platform)
                PARAM_PLATFORM="$2"
                shift 2
                ;;
            --gitea-url)
                PARAM_GITEA_URL="$2"
                shift 2
                ;;
            --skip-menu)
                SKIP_MENU=true
                shift
                ;;
            --help)
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
}

show_help() {
    cat << EOF
Git Setup Enhanced - 增强版 Git 配置工具

使用方法:
  ./setup_git_enhanced.sh [选项]

选项:
  --key-type TYPE      SSH 密钥类型 (ed25519|rsa|ecdsa|ecdsa521) [默认: ed25519]
  --email EMAIL        Git 用户邮箱
  --name NAME          Git 用户名
  --platform PLATFORM  配置平台 (github|gitee|gitlab|bitbucket)
  --gitea-url URL      Gitea 服务器地址 (如 https://git.example.com)
  --skip-menu          跳过菜单，直接执行配置
  --help               显示此帮助信息

示例:
  # 使用默认密钥类型 (ed25519)
  ./setup_git_enhanced.sh

  # 指定密钥类型为 RSA
  ./setup_git_enhanced.sh --key-type rsa

  # 跳过菜单，直接配置
  ./setup_git_enhanced.sh --skip-menu --email user@example.com --name "User Name"

  # 配置特定平台
  ./setup_git_enhanced.sh --platform github --email user@example.com

  # 配置 Gitea 自托管服务器
  ./setup_git_enhanced.sh --platform gitee --gitea-url https://git.example.com

  # 一键配置（跳过菜单）
  ./setup_git_enhanced.sh --skip-menu --email user@example.com --name "User Name" --platform gitee --gitea-url https://git.example.com

EOF
}

# ============================================================================
# 配置备份与恢复
# ============================================================================

backup_config() {
    local config_type="$1"
    local config_file="$2"

    mkdir -p "$BACKUP_DIR"
    local backup_file="$BACKUP_DIR/${config_type}_backup_${CURRENT_DATE}"

    if [ -f "$config_file" ]; then
        cp "$config_file" "$backup_file"
        print_success "已备份 $config_type 到 $backup_file"
    fi
}

restore_config() {
    print_header "配置恢复"

    if [ ! -d "$BACKUP_DIR" ]; then
        print_error "没有找到备份目录"
        return 1
    fi

    echo "可用的备份："
    local index=1
    declare -A backups

    for file in "$BACKUP_DIR"/*_backup_*; do
        if [ -f "$file" ]; then
            local filename=$(basename "$file")
            backups[$index]="$file"
            echo "  $index) $filename"
            ((index++))
        fi
    done

    if [ $index -eq 1 ]; then
        print_warning "没有找到可用的备份"
        return 1
    fi

    read -p "请选择要恢复的备份编号: " choice
    if [ -n "${backups[$choice]}" ]; then
        local backup_file="${backups[$choice]}"
        local config_type=$(echo "$backup_file" | sed 's/.*\/\([^_]*\)_backup_.*/\1/')

        case "$config_type" in
            ssh)
                cp "$backup_file" "$SSH_CONFIG_FILE"
                chmod 600 "$SSH_CONFIG_FILE"
                print_success "SSH 配置已恢复"
                ;;
            git)
                cp "$backup_file" "$HOME/.gitconfig"
                print_success "Git 配置已恢复"
                ;;
            *)
                print_error "未知的配置类型: $config_type"
                ;;
        esac
    else
        print_error "无效的选择"
    fi
}

# ============================================================================
# SSH 密钥管理
# ============================================================================

select_key_type() {
    # 如果通过命令行参数指定了密钥类型，直接使用
    if [ -n "$PARAM_KEY_TYPE" ]; then
        case "$PARAM_KEY_TYPE" in
            ed25519)
                echo "ed25519"
                return 0
                ;;
            rsa)
                echo "rsa"
                return 0
                ;;
            ecdsa)
                echo "ecdsa"
                return 0
                ;;
            ecdsa521)
                echo "ecdsa -b 521"
                return 0
                ;;
            *)
                print_warning "无效的密钥类型: $PARAM_KEY_TYPE，将使用默认值 ed25519"
                echo "ed25519"
                return 0
                ;;
        esac
    fi

    # 否则交互式选择
    echo "请选择 SSH 密钥类型："
    echo "  1) ED25519 (推荐，更安全且性能更好) [默认]"
    echo "  2) RSA (兼容性最好)"
    echo "  3) ECDSA"
    echo "  4) ECDSA 521"
    read -p "请输入选项 [1-4]: " key_choice

    case "$key_choice" in
        1|"") echo "ed25519" ;;
        2) echo "rsa" ;;
        3) echo "ecdsa" ;;
        4) echo "ecdsa -b 521" ;;
        *) echo "ed25519" ;;
    esac
}

generate_ssh_key() {
    local email="$1"
    local key_type="$2"
    local account_name="$3"

    if [ -z "$account_name" ]; then
        account_name="default"
    fi

    local key_file_base="~/.ssh/id_${key_type%% *}_${account_name}"
    key_file_base=$(eval echo "$key_file_base")
    local key_file="$key_file_base"
    local pub_key_file="$key_file.pub"

    if [ -f "$pub_key_file" ]; then
        print_warning "SSH 密钥已存在于 $key_file"
        read -p "是否重新生成？(y/N): " regenerate
        if [[ ! "$regenerate" =~ ^[Yy]$ ]]; then
            echo "$key_file"
            return 0
        fi
    fi

    print_info "正在生成新的 SSH 密钥 ($key_type)..."
    mkdir -p ~/.ssh
    chmod 700 ~/.ssh

    ssh-keygen -t $key_type -C "$email" -f "$key_file" -q -N ""
    chmod 600 "$key_file"
    chmod 644 "$pub_key_file"

    print_success "新的 SSH 密钥已生成于 $key_file"
    echo "公钥内容："
    cat "$pub_key_file"

    echo "$key_file"
}

# ============================================================================
# 平台配置
# ============================================================================

configure_ssh_host() {
    local platform="$1"
    local hostname="$2"
    local key_file="$3"
    local custom_host="$4"
    local port="${5:-22}"

    backup_config "ssh" "$SSH_CONFIG_FILE"

    mkdir -p ~/.ssh
    chmod 700 ~/.ssh
    touch "$SSH_CONFIG_FILE"
    chmod 600 "$SSH_CONFIG_FILE"

    local host_alias="${custom_host:-$hostname}"
    local port_config=""
    if [[ "$port" != "22" ]]; then
        port_config="    Port $port
"
    fi
    local required_config="Host $host_alias
    HostName $hostname
    User git
${port_config}    IdentityFile $key_file
"

    # 检查配置是否已存在
    if grep -q "^Host[[:space:]]*$host_alias$" "$SSH_CONFIG_FILE" 2>/dev/null; then
        # 检查配置是否正确
        local config_ok=true
        grep -A5 "^Host[[:space:]]*$host_alias$" "$SSH_CONFIG_FILE" | grep -q "HostName $hostname" || config_ok=false
        grep -A5 "^Host[[:space:]]*$host_alias$" "$SSH_CONFIG_FILE" | grep -q "User git" || config_ok=false
        grep -A5 "^Host[[:space:]]*$host_alias$" "$SSH_CONFIG_FILE" | grep -qF "$key_file" || config_ok=false
        if [[ "$port" != "22" ]]; then
            grep -A5 "^Host[[:space:]]*$host_alias$" "$SSH_CONFIG_FILE" | grep -q "Port $port" || config_ok=false
        fi

        if [ "$config_ok" = true ]; then
            print_success "$platform 配置已存在且正确"
        else
            print_info "修正 $platform 配置..."
            # 删除旧配置
            local tmp_file=$(mktemp)
            awk -v host="$host_alias" '
            $0 ~ "^Host[[:space:]]*"host"$" { skip=1; next }
            /^Host[[:space:]]/ { skip=0 }
            !skip { print }
            ' "$SSH_CONFIG_FILE" > "$tmp_file" && mv "$tmp_file" "$SSH_CONFIG_FILE"
            # 添加新配置
            echo "$required_config" >> "$SSH_CONFIG_FILE"
            print_success "$platform 配置已修正"
        fi
    else
        # 添加新配置
        echo "$required_config" >> "$SSH_CONFIG_FILE"
        print_success "$platform SSH 配置已添加"
    fi
}

test_ssh_connection() {
    local platform="$1"
    local hostname="$2"
    local success_pattern="$3"

    print_info "正在测试 $platform SSH 连接..."
    local result=$(ssh -T git@"$hostname" 2>&1 | sed 's/\x1b\[[0-9;]*m//g')

    if echo "$result" | grep -Eq "$success_pattern"; then
        print_success "SSH 连接 $platform 成功！"
        return 0
    else
        print_error "SSH 连接 $platform 失败！"
        print_info "请确保已将公钥添加到 $platform"
        return 1
    fi
}

# ============================================================================
# 多平台配置
# ============================================================================

configure_platforms() {
    print_header "多平台 SSH 配置"

    local email="$1"
    local key_type="$2"
    local key_file="$3"

    echo "请选择要配置的平台（可多选）："
    echo "  1) GitHub"
    echo "  2) Gitee (官方)"
    echo "  3) Gitee (自定义地址)"
    echo "  4) GitLab"
    echo "  5) Bitbucket"
    echo "  6) 自定义平台"
    read -p "请输入选项（多个选项用空格分隔）: " platform_choices

    for choice in $platform_choices; do
        case "$choice" in
            1)
                configure_ssh_host "GitHub" "github.com" "$key_file"
                test_ssh_connection "GitHub" "github.com" "successfully authenticated|You've successfully authenticated"
                ;;
            2)
                configure_ssh_host "Gitee" "gitee.com" "$key_file"
                test_ssh_connection "Gitee" "gitee.com" "successfully authenticated|Welcome to Gitee.com"
                ;;
            3)
                # Gitee 自定义地址
                read -p "请输入 Gitea 服务器地址 (如 https://git.example.com): " gitea_url
                if [ -n "$gitea_url" ]; then
                    local gitea_host=$(echo "$gitea_url" | sed -E 's|https?://||' | cut -d':' -f1 | cut -d'/' -f1)
                    configure_ssh_host "Gitea (${gitea_host})" "$gitea_host" "$key_file" "gitea"
                    print_info "Gitea 配置使用自定义地址: $gitea_url"
                    git config --global url."${gitea_url}".insteadOf "https://gitee.com"
                fi
                ;;
            4)
                configure_ssh_host "GitLab" "gitlab.com" "$key_file"
                test_ssh_connection "GitLab" "gitlab.com" "Welcome to GitLab"
                ;;
            5)
                configure_ssh_host "Bitbucket" "bitbucket.org" "$key_file"
                test_ssh_connection "Bitbucket" "bitbucket.org" "logged in as"
                ;;
            6)
                read -p "请输入平台名称: " custom_name
                read -p "请输入平台主机名: " custom_hostname
                configure_ssh_host "$custom_name" "$custom_hostname" "$key_file" "$custom_hostname"
                ;;
            *)
                print_warning "无效的选项: $choice"
                ;;
        esac
    done
}

# ============================================================================
# 多账户管理
# ============================================================================

manage_multiple_accounts() {
    print_header "多账户管理"

    echo "请选择操作："
    echo "  1) 添加新账户"
    echo "  2) 列出现有账户"
    echo "  3) 删除账户"
    read -p "请输入选项 [1-3]: " account_choice

    case "$account_choice" in
        1)
            add_new_account
            ;;
        2)
            list_accounts
            ;;
        3)
            delete_account
            ;;
        *)
            print_error "无效的选项"
            ;;
    esac
}

add_new_account() {
    print_info "添加新账户"

    read -p "请输入账户名称（用于标识，如 work, personal）: " account_name
    read -p "请输入邮箱地址: " email
    read -p "请输入用户名: " username

    local key_type=$(select_key_type)
    local key_file=$(generate_ssh_key "$email" "$key_type" "$account_name")

    echo "请选择要配置的平台："
    echo "  1) GitHub"
    echo "  2) Gitee (官方)"
    echo "  3) Gitee (自定义地址)"
    echo "  4) GitLab"
    echo "  5) Bitbucket"
    read -p "请输入选项 [1-5]: " platform_choice

    local hostname=""
    local platform_name=""

    case "$platform_choice" in
        1)
            hostname="github.com"
            platform_name="GitHub"
            ;;
        2)
            hostname="gitee.com"
            platform_name="Gitee"
            ;;
        3)
            read -p "请输入 Gitea 服务器地址 (如 https://git.example.com): " gitea_url
            if [ -n "$gitea_url" ]; then
                hostname=$(echo "$gitea_url" | sed -E 's|https?://||' | cut -d':' -f1 | cut -d'/' -f1)
                platform_name="Gitea (${hostname})"
                # 设置 URL 重写，将 gitee.com 克隆地址重写为自定义地址
                git config --global url."${gitea_url}".insteadOf "https://gitee.com"
            else
                print_error "Gitea 地址不能为空"
                return 1
            fi
            ;;
        4)
            hostname="gitlab.com"
            platform_name="GitLab"
            ;;
        5)
            hostname="bitbucket.org"
            platform_name="Bitbucket"
            ;;
        *)
            print_error "无效的选项"
            return 1
            ;;
    esac

    local host_alias="${hostname}_${account_name}"
    configure_ssh_host "$platform_name" "$hostname" "$key_file" "$host_alias"

    # 设置SSH Agent
    setup_ssh_agent "$key_file"

    # 保存账户信息
    local accounts_file="$HOME/.git_accounts"
    echo "$account_name|$email|$username|$key_file|$host_alias" >> "$accounts_file"

    print_success "账户 $account_name 添加成功"
    print_info "使用方式: git clone git@${host_alias}:username/repository.git"
}

list_accounts() {
    print_info "现有账户列表"

    local accounts_file="$HOME/.git_accounts"
    if [ ! -f "$accounts_file" ]; then
        print_warning "没有找到账户配置"
        return 1
    fi

    echo "账户名称 | 邮箱 | 用户名 | SSH 别名"
    echo "---------|------|--------|---------"
    while IFS='|' read -r account_name email username key_file host_alias; do
        echo "$account_name | $email | $username | $host_alias"
    done < "$accounts_file"
}

delete_account() {
    print_info "删除账户"

    local accounts_file="$HOME/.git_accounts"
    if [ ! -f "$accounts_file" ]; then
        print_warning "没有找到账户配置"
        return 1
    fi

    list_accounts
    read -p "请输入要删除的账户名称: " account_name

    # 从配置文件中删除
    grep -v "^${account_name}|" "$accounts_file" > "${accounts_file}.tmp"
    mv "${accounts_file}.tmp" "$accounts_file"

    print_success "账户 $account_name 已删除"
}

# ============================================================================
# Git 代理配置
# ============================================================================

configure_proxy() {
    print_header "Git 代理配置"

    echo "请选择代理类型："
    echo "  1) HTTP/HTTPS 代理"
    echo "  2) SOCKS5 代理"
    echo "  3) SSH 代理"
    read -p "请输入选项 [1-3]: " proxy_choice

    case "$proxy_choice" in
        1)
            configure_http_proxy
            ;;
        2)
            configure_socks5_proxy
            ;;
        3)
            configure_ssh_proxy
            ;;
        *)
            print_error "无效的选项"
            ;;
    esac
}

configure_http_proxy() {
    read -p "请输入 HTTP 代理地址 (如 http://127.0.0.1:7890): " http_proxy
    read -p "请输入 HTTPS 代理地址 (如 http://127.0.0.1:7890): " https_proxy

    if [ -n "$http_proxy" ]; then
        git config --global http.proxy "$http_proxy"
        print_success "HTTP 代理已设置: $http_proxy"
    fi

    if [ -n "$https_proxy" ]; then
        git config --global https.proxy "$https_proxy"
        print_success "HTTPS 代理已设置: $https_proxy"
    fi
}

configure_socks5_proxy() {
    read -p "请输入 SOCKS5 代理地址 (如 socks5://127.0.0.1:1080): " socks_proxy

    if [ -n "$socks_proxy" ]; then
        git config --global http.proxy "$socks_proxy"
        git config --global https.proxy "$socks_proxy"
        print_success "SOCKS5 代理已设置: $socks_proxy"
    fi
}

configure_ssh_proxy() {
    read -p "请输入 SSH 代理命令 (如 nc -X 5 -x 127.0.0.1:1080 %h %p): " ssh_proxy_cmd

    if [ -n "$ssh_proxy_cmd" ]; then
        git config --global core.sshCommand "ssh -o ProxyCommand='$ssh_proxy_cmd'"
        print_success "SSH 代理已设置"
    fi
}

# ============================================================================
# GPG 签名配置
# ============================================================================

configure_gpg() {
    print_header "GPG 签名配置"

    if ! check_command gpg; then
        print_error "GPG 未安装，跳过 GPG 配置"
        return 1
    fi

    echo "请选择操作："
    echo "  1) 生成新的 GPG 密钥"
    echo "  2) 列出现有 GPG 密钥"
    echo "  3) 使用现有 GPG 密钥"
    read -p "请输入选项 [1-3]: " gpg_choice

    case "$gpg_choice" in
        1)
            generate_gpg_key
            ;;
        2)
            list_gpg_keys
            ;;
        3)
            use_existing_gpg_key
            ;;
        *)
            print_error "无效的选项"
            ;;
    esac
}

generate_gpg_key() {
    print_info "生成新的 GPG 密钥"

    read -p "请输入姓名: " gpg_name
    read -p "请输入邮箱: " gpg_email

    gpg --batch --gen-key <<EOF
Key-Type: RSA
Key-Length: 4096
Name-Real: $gpg_name
Name-Email: $gpg_email
Expire-Date: 0
%no-protection
EOF

    print_success "GPG 密钥已生成"
    list_gpg_keys
}

list_gpg_keys() {
    print_info "现有 GPG 密钥列表"
    gpg --list-secret-keys --keyid-format LONG
}

use_existing_gpg_key() {
    list_gpg_keys
    read -p "请输入要使用的 GPG 密钥 ID: " gpg_key_id

    git config --global user.signingkey "$gpg_key_id"
    git config --global commit.gpgsign true
    git config --global tag.gpgsign true

    print_success "GPG 签名已配置"
    print_info "密钥 ID: $gpg_key_id"
}

# ============================================================================
# .gitignore 模板
# ============================================================================

generate_gitignore() {
    print_header ".gitignore 模板生成"

    echo "请选择项目类型："
    echo "  1) Python"
    echo "  2) Node.js"
    echo "  3) Java"
    echo "  4) Go"
    echo "  5) C/C++"
    echo "  6) Rust"
    echo "  7) 通用"
    read -p "请输入选项 [1-7]: " gitignore_choice

    local gitignore_file=".gitignore"

    case "$gitignore_choice" in
        1)
            cat > "$gitignore_file" << 'EOF'
# Byte-compiled / optimized / DLL files
__pycache__/
*.py[cod]
*$py.class

# C extensions
*.so

# Distribution / packaging
.Python
build/
develop-eggs/
dist/
downloads/
eggs/
.eggs/
lib/
lib64/
parts/
sdist/
var/
wheels/
*.egg-info/
.installed.cfg
*.egg

# PyInstaller
*.manifest
*.spec

# Unit test / coverage reports
htmlcov/
.tox/
.coverage
.coverage.*
.cache
nosetests.xml
coverage.xml
*.cover
.hypothesis/
.pytest_cache/

# Environments
.env
.venv
env/
venv/
ENV/
env.bak/
venv.bak/

# IDEs
.vscode/
.idea/
*.swp
*.swo
*~

# OS
.DS_Store
Thumbs.db
EOF
            ;;
        2)
            cat > "$gitignore_file" << 'EOF'
# Dependencies
node_modules/
jspm_packages/

# Build output
dist/
build/

# Logs
logs/
*.log
npm-debug.log*
yarn-debug.log*
yarn-error.log*

# Runtime data
pids/
*.pid
*.seed
*.pid.lock

# Coverage directory
coverage/

# IDEs
.vscode/
.idea/
*.swp
*.swo

# OS
.DS_Store
Thumbs.db

# Environment variables
.env
.env.local
.env.development.local
.env.test.local
.env.production.local
EOF
            ;;
        3)
            cat > "$gitignore_file" << 'EOF'
# Compiled class file
*.class

# Log file
*.log

# BlueJ files
*.ctxt

# Mobile Tools for Java (J2ME)
.mtj.tmp/

# Package Files
*.jar
*.war
*.nar
*.ear
*.zip
*.tar.gz
*.rar

# Virtual machine crash logs
hs_err_pid*

# Maven
target/
pom.xml.tag
pom.xml.releaseBackup
pom.xml.versionsBackup
pom.xml.next
release.properties
dependency-reduced-pom.xml
buildNumber.properties
.mvn/timing.properties
.mvn/wrapper/maven-wrapper.jar

# Gradle
.gradle
build/
!gradle/wrapper/gradle-wrapper.jar

# IDEs
.idea/
*.iml
*.iws
*.ipr
.vscode/

# OS
.DS_Store
Thumbs.db
EOF
            ;;
        4)
            cat > "$gitignore_file" << 'EOF'
# Binaries for programs and plugins
*.exe
*.exe~
*.dll
*.so
*.dylib

# Test binary, built with `go test -c`
*.test

# Output of the go coverage tool
*.out

# Dependency directories
vendor/

# Go workspace file
go.work

# IDEs
.idea/
.vscode/
*.swp
*.swo

# OS
.DS_Store
Thumbs.db
EOF
            ;;
        5)
            cat > "$gitignore_file" << 'EOF'
# Prerequisites
*.d

# Compiled Object files
*.slo
*.lo
*.o
*.obj

# Precompiled Headers
*.gch
*.pch

# Compiled Dynamic libraries
*.so
*.dylib
*.dll

# Compiled Static libraries
*.lai
*.la
*.a
*.lib

# Executables
*.exe
*.out
*.app

# CMake
CMakeCache.txt
CMakeFiles/
cmake_install.cmake
Makefile

# IDEs
.vscode/
.idea/
*.swp
*.swo

# OS
.DS_Store
Thumbs.db
EOF
            ;;
        6)
            cat > "$gitignore_file" << 'EOF'
# Generated by Cargo
/target/

# RustRover
.idea/

# VS Code
.vscode/

# OS
.DS_Store
Thumbs.db

# Backup files
*~
*.swp
*.swo
EOF
            ;;
        7)
            cat > "$gitignore_file" << 'EOF'
# OS
.DS_Store
.DS_Store?
._*
.Spotlight-V100
.Trashes
ehthumbs.db
Thumbs.db

# IDEs
.vscode/
.idea/
*.swp
*.swo
*~
.project
.classpath
.settings/

# Logs
*.log
npm-debug.log*
yarn-debug.log*
yarn-error.log*

# Environment
.env
.env.local
.env.*.local

# Build
dist/
build/
out/

# Dependencies
node_modules/
vendor/

# Backup
*.bak
*.backup
EOF
            ;;
        *)
            print_error "无效的选项"
            return 1
            ;;
    esac

    print_success ".gitignore 文件已生成: $gitignore_file"
}

# ============================================================================
# Git LFS 支持
# ============================================================================

configure_git_lfs() {
    print_header "Git LFS 配置"

    if ! check_command git-lfs; then
        print_error "Git LFS 未安装"
        print_info "安装命令:"
        print_info "  macOS: brew install git-lfs"
        print_info "  Linux: curl -s https://packagecloud.io/install/repositories/github/git-lfs/script.deb.sh | sudo bash"
        print_info "         sudo apt-get install git-lfs"
        return 1
    fi

    read -p "是否安装 Git LFS？: " install_lfs
    if [[ "$install_lfs" =~ ^[Yy]$ ]]; then
        git lfs install
        print_success "Git LFS 已安装"

        read -p "是否要跟踪特定文件类型？: " track_files
        if [[ "$track_files" =~ ^[Yy]$ ]]; then
            read -p "请输入文件扩展名（多个用空格分隔，如 psd zip）: " extensions
            for ext in $extensions; do
                git lfs track "*.$ext"
                print_success "已跟踪 .$ext 文件"
            done
        fi
    fi
}

# ============================================================================
# 诊断工具
# ============================================================================

run_diagnostics() {
    print_header "Git 诊断工具"

    echo "正在收集诊断信息..."
    echo ""

    # 系统信息
    print_info "=== 系统信息 ==="
    echo "操作系统: $(uname -s)"
    echo "内核版本: $(uname -r)"
    echo "架构: $(uname -m)"
    echo ""

    # Git 信息
    print_info "=== Git 信息 ==="
    echo "Git 版本: $(git --version)"
    echo "Git 配置文件: $HOME/.gitconfig"
    echo "Git 用户名: $(git config --global user.name)"
    echo "Git 邮箱: $(git config --global user.email)"
    echo ""

    # SSH 信息
    print_info "=== SSH 信息 ==="
    if [ -f "$SSH_CONFIG_FILE" ]; then
        echo "SSH 配置文件: $SSH_CONFIG_FILE"
        echo "SSH 配置内容:"
        cat "$SSH_CONFIG_FILE"
    else
        echo "SSH 配置文件不存在"
    fi
    echo ""

    # SSH 密钥
    print_info "=== SSH 密钥 ==="
    find ~/.ssh -name "id_*" -type f 2>/dev/null | while read -r key_file; do
        echo "密钥文件: $key_file"
        ls -la "$key_file"
    done
    echo ""

    # 网络连接测试
    print_info "=== 网络连接测试 ==="
    for host in github.com gitee.com gitlab.com; do
        if ping -c 1 -W 2 "$host" &>/dev/null; then
            print_success "$host: 可访问"
        else
            print_error "$host: 无法访问"
        fi
    done
    echo ""

    # SSH 连接测试
    print_info "=== SSH 连接测试 ==="
    for host in github.com gitee.com; do
        local result=$(timeout_cmd 5 ssh -T git@"$host" 2>&1 | sed 's/\x1b\[[0-9;]*m//g' || echo "Timeout")
        if echo "$result" | grep -Eq "successfully authenticated|Welcome"; then
            print_success "$host: SSH 连接成功"
        else
            print_error "$host: SSH 连接失败"
            echo "  错误信息: $result"
        fi
    done
    echo ""

    # Git 代理配置
    print_info "=== Git 代理配置 ==="
    local http_proxy=$(git config --global http.proxy)
    local https_proxy=$(git config --global https.proxy)
    if [ -n "$http_proxy" ]; then
        echo "HTTP 代理: $http_proxy"
    else
        echo "HTTP 代理: 未配置"
    fi
    if [ -n "$https_proxy" ]; then
        echo "HTTPS 代理: $https_proxy"
    else
        echo "HTTPS 代理: 未配置"
    fi
    echo ""

    # GPG 配置
    print_info "=== GPG 配置 ==="
    if command -v gpg &>/dev/null; then
        local gpg_key=$(git config --global user.signingkey)
        if [ -n "$gpg_key" ]; then
            echo "GPG 密钥 ID: $gpg_key"
            echo "Commit 签名: $(git config --global commit.gpgsign)"
            echo "Tag 签名: $(git config --global tag.gpgsign)"
        else
            echo "GPG: 未配置"
        fi
    else
        echo "GPG: 未安装"
    fi
    echo ""

    print_success "诊断信息收集完成"
}

# ============================================================================
# CI/CD 配置模板
# ============================================================================

generate_cicd_config() {
    print_header "CI/CD 配置模板生成"

    echo "请选择 CI/CD 平台："
    echo "  1) GitHub Actions"
    echo "  2) GitLab CI"
    echo "  3) Jenkins"
    read -p "请输入选项 [1-3]: " cicd_choice

    case "$cicd_choice" in
        1)
            generate_github_actions
            ;;
        2)
            generate_gitlab_ci
            ;;
        3)
            generate_jenkinsfile
            ;;
        *)
            print_error "无效的选项"
            ;;
    esac
}

generate_github_actions() {
    local workflow_dir=".github/workflows"
    mkdir -p "$workflow_dir"

    cat > "$workflow_dir/ci.yml" << 'EOF'
name: CI

on:
  push:
    branches: [ main, develop ]
  pull_request:
    branches: [ main, develop ]

jobs:
  build:
    runs-on: ubuntu-latest

    steps:
    - uses: actions/checkout@v3

    - name: Set up Node.js
      uses: actions/setup-node@v3
      with:
        node-version: '18'
        cache: 'npm'

    - name: Install dependencies
      run: npm ci

    - name: Run linter
      run: npm run lint

    - name: Run tests
      run: npm test

    - name: Build
      run: npm run build
EOF

    print_success "GitHub Actions 配置已生成: $workflow_dir/ci.yml"
}

generate_gitlab_ci() {
    cat > ".gitlab-ci.yml" << 'EOF'
stages:
  - test
  - build
  - deploy

before_script:
  - echo "Before script"

test:
  stage: test
  script:
    - echo "Running tests"
    - npm install
    - npm test

build:
  stage: build
  script:
    - echo "Building"
    - npm run build
  artifacts:
    paths:
      - dist/

deploy:
  stage: deploy
  script:
    - echo "Deploying"
  only:
    - main
EOF

    print_success "GitLab CI 配置已生成: .gitlab-ci.yml"
}

generate_jenkinsfile() {
    cat > "Jenkinsfile" << 'EOF'
pipeline {
    agent any

    stages {
        stage('Checkout') {
            steps {
                checkout scm
            }
        }

        stage('Install') {
            steps {
                sh 'npm install'
            }
        }

        stage('Test') {
            steps {
                sh 'npm test'
            }
        }

        stage('Build') {
            steps {
                sh 'npm run build'
            }
        }

        stage('Deploy') {
            when {
                branch 'main'
            }
            steps {
                sh 'echo "Deploying"'
            }
        }
    }

    post {
        always {
            echo 'Pipeline completed'
        }
    }
}
EOF

    print_success "Jenkinsfile 已生成"
}

# ============================================================================
# SSH Agent 管理
# ============================================================================

setup_ssh_agent() {
    local key_file="$1"
    
    if [ -z "$key_file" ]; then
        print_warning "未提供SSH密钥文件，跳过SSH Agent配置"
        return 0
    fi

    # 检查ssh-agent是否可用（处理 SSH_AUTH_SOCK 存在但进程已死的情况）
    local agent_status=0
    ssh-add -l >/dev/null 2>&1 || agent_status=$?
    if [ $agent_status -eq 2 ]; then
        print_info "启动SSH Agent..."
        eval "$(ssh-agent -s)" >/dev/null
        print_success "SSH Agent 已启动"
    else
        print_info "SSH Agent 已在运行"
    fi

    # 检查密钥是否已添加到agent
    local key_fingerprint=$(ssh-keygen -lf "$key_file" 2>/dev/null | awk '{print $2}')
    if ssh-add -l | grep -q "$key_fingerprint"; then
        print_info "SSH密钥已添加到Agent"
    else
        print_info "添加SSH密钥到Agent..."
        if ssh-add "$key_file"; then
            print_success "SSH密钥已添加到Agent"
        else
            print_warning "添加SSH密钥到Agent失败"
        fi
    fi
}

# ============================================================================
# 颜色主题配置
# ============================================================================

configure_color_theme() {
    print_header "Git 颜色主题配置"

    echo "请选择颜色主题："
    echo "  1) 默认"
    echo "  2) Solarized Light"
    echo "  3) Solarized Dark"
    echo "  4) 自定义"
    read -p "请输入选项 [1-4]: " theme_choice

    case "$theme_choice" in
        1)
            git config --global color.ui auto
            print_success "已设置为默认主题"
            ;;
        2)
            configure_solarized_light
            ;;
        3)
            configure_solarized_dark
            ;;
        4)
            configure_custom_colors
            ;;
        *)
            print_error "无效的选项"
            ;;
    esac
}

configure_solarized_light() {
    git config --global color.ui true
    git config --global color.diff.meta "yellow bold"
    git config --global color.diff.frag "magenta bold"
    git config --global color.diff.old "red bold"
    git config --global color.diff.new "green bold"
    git config --global color.status.added "green"
    git config --global color.status.changed "yellow"
    git config --global color.status.untracked "cyan"
    print_success "已设置为 Solarized Light 主题"
}

configure_solarized_dark() {
    git config --global color.ui true
    git config --global color.diff.meta "11 bold"
    git config --global color.diff.frag "magenta bold"
    git config --global color.diff.old "red bold"
    git config --global color.diff.new "green bold"
    git config --global color.status.added "green"
    git config --global color.status.changed "yellow"
    git config --global color.status.untracked "cyan"
    print_success "已设置为 Solarized Dark 主题"
}

configure_custom_colors() {
    echo "请输入自定义颜色配置（格式: 选项=颜色）"
    echo "可用选项: diff.meta, diff.frag, diff.old, diff.new, status.added, status.changed, status.untracked"
    echo "可用颜色: normal, black, red, green, yellow, blue, magenta, cyan, white"
    echo "可以添加 'bold' 后缀，如 'red bold'"

    read -p "diff.meta 颜色: " diff_meta
    read -p "diff.frag 颜色: " diff_frag
    read -p "diff.old 颜色: " diff_old
    read -p "diff.new 颜色: " diff_new
    read -p "status.added 颜色: " status_added
    read -p "status.changed 颜色: " status_changed
    read -p "status.untracked 颜色: " status_untracked

    if [ -n "$diff_meta" ]; then
        git config --global color.diff.meta "$diff_meta"
    fi
    if [ -n "$diff_frag" ]; then
        git config --global color.diff.frag "$diff_frag"
    fi
    if [ -n "$diff_old" ]; then
        git config --global color.diff.old "$diff_old"
    fi
    if [ -n "$diff_new" ]; then
        git config --global color.diff.new "$diff_new"
    fi
    if [ -n "$status_added" ]; then
        git config --global color.status.added "$status_added"
    fi
    if [ -n "$status_changed" ]; then
        git config --global color.status.changed "$status_changed"
    fi
    if [ -n "$status_untracked" ]; then
        git config --global color.status.untracked "$status_untracked"
    fi

    print_success "自定义颜色主题已配置"
}

# ============================================================================
# 清除配置
# ============================================================================

clear_config() {
    echo "清除配置选项:"
    echo "1) 清除用户名/邮箱  2) 清除代理  3) 清除GPG  4) 清除合并工具"
    echo "5) 清除所有别名     6) 清除全部Git配置  0) 返回"
    read -p "选项: " clear_choice

    case "$clear_choice" in
        1)
            git config --global --unset user.name
            git config --global --unset user.email
            print_success "已清除用户名和邮箱"
            ;;
        2)
            git config --global --unset http.proxy
            git config --global --unset https.proxy
            print_success "已清除代理配置"
            ;;
        3)
            git config --global --unset user.signingkey
            git config --global --unset commit.gpgsign
            print_success "已清除GPG配置"
            ;;
        4)
            git config --global --unset diff.tool
            git config --global --unset merge.tool
            print_success "已清除合并工具配置"
            ;;
        5)
            git config --global --unset-regexp "^alias\."
            print_success "已清除所有别名"
            ;;
        6)
            read -p "确认清除所有Git全局配置? [y/N]: " confirm
            if [[ "$confirm" =~ ^[Yy]$ ]]; then
                git config --global --unset-regexp ".*"
                print_success "已清除全部Git配置"
            fi
            ;;
        0)
            return
            ;;
        *)
            print_error "无效选项"
            ;;
    esac
}

# ============================================================================
# 快速配置
# ============================================================================

quick_setup() {
    local current_name=$(git config --global user.name 2>/dev/null)
    local current_email=$(git config --global user.email 2>/dev/null)

    print_header "快速配置"

    # 显示当前配置
    if [ -n "$current_name" ] || [ -n "$current_email" ]; then
        echo "当前: ${current_name:-未设置} <${current_email:-未设置}>"
    fi

    # Git 基础配置
    read -p "Git用户名 [${current_name:-}]: " username
    read -p "Git邮箱 [${current_email:-}]: " email

    username="${username:-$current_name}"
    email="${email:-$current_email}"

    if [ -z "$username" ] || [ -z "$email" ]; then
        print_error "用户名和邮箱不能为空"
        return 1
    fi

    git config --global user.name "$username"
    git config --global user.email "$email"
    print_success "Git 配置: $username <$email>"

    # 默认配置
    git config --global init.defaultBranch main 2>/dev/null
    git config --global core.editor "vim"
    git config --global color.ui auto
    git config --global core.fileMode false
    git config --global core.quotepath false
    [[ "$(uname)" == "Darwin" ]] && git config --global credential.helper osxkeychain

    # 常用别名
    git config --global alias.st status
    git config --global alias.ci commit
    git config --global alias.co checkout
    git config --global alias.br branch
    git config --global alias.lg "log --oneline --graph --all --decorate"

    # 合并工具 - 统一走自动检测优先级
    local detected_tools=($(detect_merge_tools))
    local configured_tool=""
    for tool in bcomp bcompare code smerge ksdiff meld kdiff3 diffuse vimdiff nvimdiff; do
        if [[ " ${detected_tools[@]} " =~ " ${tool} " ]]; then
            configured_tool="$tool"
            break
        fi
    done

    if [ -n "$configured_tool" ]; then
        apply_merge_tool_config "$configured_tool"
        print_success "合并工具: $configured_tool"
    else
        apply_merge_tool_config "vimdiff"
        print_success "合并工具: vimdiff"
    fi

    git config --global mergetool.keepBackup false

    # SSH 密钥
    local key_file="$HOME/.ssh/id_ed25519"
    read -p "配置SSH密钥? [Y/n]: " gen_ssh
    if [[ ! "$gen_ssh" =~ ^[Nn]$ ]]; then
        if [ -f "$key_file" ]; then
            print_info "SSH密钥已存在"
        else
            ssh-keygen -t ed25519 -C "$email" -f "$key_file" -q -N ""
            print_success "SSH密钥已生成"
        fi
        echo "公钥:"
        cat "$key_file.pub"
        echo ""

        # 将密钥添加到 ssh-agent (macOS 兼容性)
        print_info "添加密钥到 SSH Agent..."
        # 确保 agent 可用
        local agent_status=0
        ssh-add -l >/dev/null 2>&1 || agent_status=$?
        if [ $agent_status -eq 2 ]; then
            eval "$(ssh-agent -s)" >/dev/null
        fi

        if [[ "$(uname)" == "Darwin" ]]; then
            ssh-add --apple-use-keychain "$key_file" 2>/dev/null || ssh-add "$key_file"
        else
            ssh-add "$key_file"
        fi
        print_success "密钥已添加到 SSH Agent"
    fi

    # 平台配置
    if [ -f "$key_file" ]; then
        echo "配置平台: 1)GitHub 2)Gitee 3)GitLab 4)Gitea(自定义) 5)跳过 [回车=全部]"
        read -p "选项: " platform_choice

        # 回车表示全部配置
        if [ -z "$platform_choice" ]; then
            platform_choice="1 2 3"
        fi

        for choice in $platform_choice; do
            case "$choice" in
                1)
                    configure_ssh_host "GitHub" "github.com" "$key_file"
                    print_info "测试 GitHub 连接..."
                    local result=$(ssh -o StrictHostKeyChecking=accept-new -T git@github.com 2>&1)
                    if echo "$result" | grep -q "successfully authenticated"; then
                        print_success "GitHub 连接成功"
                    else
                        print_warning "GitHub 连接失败"
                        echo "配置步骤: GitHub -> Settings -> SSH keys -> New SSH key -> 粘贴公钥"
                    fi
                    ;;
                2)
                    configure_ssh_host "Gitee" "gitee.com" "$key_file"
                    print_info "测试 Gitee 连接..."
                    local result=$(ssh -o StrictHostKeyChecking=accept-new -T git@gitee.com 2>&1)
                    if echo "$result" | grep -q "successfully authenticated\|Welcome to Gitee"; then
                        print_success "Gitee 连接成功"
                    else
                        print_warning "Gitee 连接失败"
                        echo "配置步骤: Gitee -> 设置 -> SSH公钥 -> 添加公钥 -> 粘贴公钥"
                    fi
                    ;;
                3)
                    configure_ssh_host "GitLab" "gitlab.com" "$key_file"
                    print_info "测试 GitLab 连接..."
                    local result=$(ssh -o StrictHostKeyChecking=accept-new -T git@gitlab.com 2>&1)
                    if echo "$result" | grep -q "Welcome to GitLab"; then
                        print_success "GitLab 连接成功"
                    else
                        print_warning "GitLab 连接失败"
                        echo "配置步骤: GitLab -> Settings -> SSH Keys -> Add new key -> 粘贴公钥"
                    fi
                    ;;
                4)
                    # Gitea 自定义地址
                    read -p "请输入 Gitea Web 地址 (如 http://192.168.1.247:3000): " gitea_url
                    if [ -n "$gitea_url" ]; then
                        local gitea_host=$(echo "$gitea_url" | sed -E 's|https?://||' | cut -d':' -f1 | cut -d'/' -f1)
                        local gitea_web_port=$(echo "$gitea_url" | grep -o ':[0-9]*' | head -1 | tr -d ':' || echo "")
                        read -p "请输入 Gitea SSH 端口 [默认: 22]: " gitea_ssh_port
                        gitea_ssh_port=${gitea_ssh_port:-22}
                        
                        # 配置 SSH 主机，传入 SSH 端口
                        configure_ssh_host "Gitea (${gitea_host})" "$gitea_host" "$key_file" "gitea" "$gitea_ssh_port"
                        git config --global url."${gitea_url}".insteadOf "https://gitee.com"
                        
                        print_info "测试 Gitea SSH 连接 (${gitea_host}:${gitea_ssh_port})..."
                        # 尝试 SSH 连接测试
                        local result
                        if [[ "$gitea_ssh_port" != "22" ]]; then
                            result=$(ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 -p "$gitea_ssh_port" -T git@"$gitea_host" 2>&1)
                        else
                            result=$(ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 -T git@"$gitea_host" 2>&1)
                        fi
                        if echo "$result" | grep -q "successfully authenticated\|Welcome\|Hi"; then
                            print_success "Gitea SSH 连接成功"
                        else
                            print_warning "Gitea SSH 连接失败"
                            echo ""
                            echo "可能原因:"
                            echo "  1. Gitea 管理员未启用 SSH 服务器"
                            echo "  2. SSH 密钥未正确添加到 Gitea"
                            echo "  3. Gitea SSH 端口不是 ${gitea_ssh_port}"
                            echo ""
                            echo "排查步骤:"
                            echo "  手动测试: ssh -vT git@${gitea_host} -p ${gitea_ssh_port}"
                            echo "  检查 Gitea: 管理员面板 -> 系统设置 -> SSH 密钥 -> 启用 SSH 服务器"
                            echo ""
                            echo "如果 Gitea 未启用 SSH，可以使用 HTTPS 克隆:"
                            echo "  git clone ${gitea_url}/用户名/仓库名.git"
                        fi
                    else
                        print_warning "Gitea 地址为空，跳过配置"
                    fi
                    ;;
                5)
                    ;;
            esac
        done
    fi

    print_success "快速配置完成!"
}

# ============================================================================
# Git 基础配置
# ============================================================================

configure_git_basic() {
    local current_name=$(git config --global user.name 2>/dev/null)
    local current_email=$(git config --global user.email 2>/dev/null)

    if [ -n "$current_name" ] || [ -n "$current_email" ]; then
        print_header "Git 基础配置"
        echo "当前配置: ${current_name:-未设置} <${current_email:-未设置}>"
        read -p "是否修改? [y/N]: " modify
        [[ ! "$modify" =~ ^[Yy]$ ]] && return 0
    fi

    # 获取用户输入
    local default_name="${current_name:-}"
    local default_email="${current_email:-}"
    read -p "Git用户名 [$default_name]: " username
    read -p "Git邮箱 [$default_email]: " email

    username="${username:-$default_name}"
    email="${email:-$default_email}"

    if [ -z "$username" ] || [ -z "$email" ]; then
        print_error "用户名和邮箱不能为空"
        return 1
    fi

    git config --global user.name "$username"
    git config --global user.email "$email"
    print_success "Git 配置: $username <$email>"
    configure_git_defaults
}

configure_git_defaults() {
    # 分支默认名
    if ! git config --global init.defaultBranch | grep -q main; then
        git config --global init.defaultBranch main
    fi

    # 编辑器
    git config --global core.editor "vim"

    # 颜色高亮
    git config --global color.ui auto

    # 忽略文件权限变更
    git config --global core.fileMode false

    # 换行符处理
    if [[ "$(uname)" == "Darwin" || "$(uname)" == "Linux" ]]; then
        git config --global core.autocrlf input
    else
        git config --global core.autocrlf true
    fi
    git config --global core.safecrlf warn

    # 显示中文路径
    git config --global core.quotepath false

    # 凭证缓存
    if [[ "$(uname)" == "Darwin" ]]; then
        git config --global credential.helper osxkeychain
    else
        git config --global credential.helper cache
    fi

    # 常用别名
    local aliases=(
        "st=status"
        "ci=commit"
        "co=checkout"
        "br=branch"
        "last=log -1 HEAD"
        "lg=log --oneline --graph --all --decorate"
        "unstage=reset HEAD --"
        "diff=diff --cached"
        "type=cat-file -t"
        "dump=cat-file -p"
    )

    for a in "${aliases[@]}"; do
        local k="${a%%=*}"
        local v="${a#*=}"
        git config --global alias.$k "$v"
    done

    # 合并工具 - 自动检测并配置最佳工具
    local detected_tools=($(detect_merge_tools))
    local configured_tool=""

    # 优先级顺序
    for tool in bcomp bcompare code smerge ksdiff meld kdiff3 diffuse vimdiff nvimdiff; do
        if [[ " ${detected_tools[@]} " =~ " ${tool} " ]]; then
            configured_tool="$tool"
            break
        fi
    done

    if [ -n "$configured_tool" ]; then
        apply_merge_tool_config "$configured_tool"
    else
        apply_merge_tool_config "vimdiff"
    fi
    print_success "Git 默认配置已完成"
}

# ============================================================================
# 对比和合并工具配置
# ============================================================================

detect_merge_tools() {
    local detected_tools=()
    local tool_info=""

    # Beyond Compare
    if command -v bcompare >/dev/null 2>&1; then
        detected_tools+=("bcompare")
        tool_info="${tool_info}bcompare "
    fi

    if command -v bcomp >/dev/null 2>&1; then
        detected_tools+=("bcomp")
        tool_info="${tool_info}bcomp "
    fi

    if [[ -d "/Applications/Beyond Compare.app" ]]; then
        if [[ -x "/Applications/Beyond Compare.app/Contents/MacOS/BCompare" ]]; then
            detected_tools+=("bcompare")
            tool_info="${tool_info}bcompare(app) "
        fi
        if [[ -x "/Applications/Beyond Compare.app/Contents/MacOS/bcomp" ]]; then
            detected_tools+=("bcomp")
            tool_info="${tool_info}bcomp(app) "
        fi
    fi

    # VS Code
    if command -v code >/dev/null 2>&1; then
        detected_tools+=("code")
        tool_info="${tool_info}code "
    fi

    # Sublime Merge
    if command -v smerge >/dev/null 2>&1; then
        detected_tools+=("smerge")
        tool_info="${tool_info}smerge "
    fi

    # Kaleidoscope
    if command -v ksdiff >/dev/null 2>&1; then
        detected_tools+=("ksdiff")
        tool_info="${tool_info}ksdiff "
    fi

    # Delta
    if command -v delta >/dev/null 2>&1; then
        detected_tools+=("delta")
        tool_info="${tool_info}delta "
    fi

    # Diffuse
    if command -v diffuse >/dev/null 2>&1; then
        detected_tools+=("diffuse")
        tool_info="${tool_info}diffuse "
    fi

    # Meld
    if command -v meld >/dev/null 2>&1; then
        detected_tools+=("meld")
        tool_info="${tool_info}meld "
    fi

    # KDiff3
    if command -v kdiff3 >/dev/null 2>&1; then
        detected_tools+=("kdiff3")
        tool_info="${tool_info}kdiff3 "
    fi

    # Vimdiff (总是可用)
    detected_tools+=("vimdiff")
    tool_info="${tool_info}vimdiff "

    # Neovim
    if command -v nvim >/dev/null 2>&1; then
        detected_tools+=("nvimdiff")
        tool_info="${tool_info}nvimdiff "
    fi

    if [ ${#detected_tools[@]} -gt 0 ]; then
        print_info "检测到工具: ${tool_info}"
    fi

    # 返回检测到的工具列表（空格分隔）
    echo "${detected_tools[@]}"
}

ensure_beyond_compare_wrapper() {
    local wrapper_dir="${HOME}/.local/bin"
    local bcomp_bin="/Applications/Beyond Compare.app/Contents/MacOS/bcomp"

    if [[ ! -x "$bcomp_bin" ]]; then
        return 1
    fi

    mkdir -p "$wrapper_dir"

    cat > "$wrapper_dir/bcompare" <<EOF
#!/usr/bin/env bash
exec -a bcompare "$bcomp_bin" "\$@"
EOF
    chmod +x "$wrapper_dir/bcompare"

    cat > "$wrapper_dir/bcomp" <<EOF
#!/usr/bin/env bash
exec -a bcomp "$bcomp_bin" "\$@"
EOF
    chmod +x "$wrapper_dir/bcomp"

    cat > "$wrapper_dir/git-bc-difftool" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

left="${1:?left file required}"
right="${2:?right file required}"
name="${3:-$(basename "$right")}"
base_dir="${TMPDIR:-/tmp}/git-bc-difftool"
run_dir="$base_dir/$(date +%Y%m%d_%H%M%S)_$$"
mkdir -p "$run_dir"
find "$base_dir" -mindepth 1 -maxdepth 1 -type d -mtime +3 -exec rm -rf {} + 2>/dev/null || true

safe_name=$(basename "$name")
left_copy="$run_dir/LOCAL_${safe_name}"
right_copy="$run_dir/REMOTE_${safe_name}"
cp "$left" "$left_copy"
cp "$right" "$right_copy"

exec bcomp "$left_copy" "$right_copy"
EOF
    chmod +x "$wrapper_dir/git-bc-difftool"

    case ":$PATH:" in
        *":$wrapper_dir:"*) ;;
        *) export PATH="$wrapper_dir:$PATH" ;;
    esac

    return 0
}

configure_merge_tool() {
    print_header "对比和合并工具配置"

    local detected_tools=($(detect_merge_tools))

    if [ ${#detected_tools[@]} -eq 0 ]; then
        print_error "未检测到任何对比和合并工具"
        return 1
    fi

    echo "请选择默认工具："
    local index=1
    declare -A tool_map

    for tool in "${detected_tools[@]}"; do
        echo "  $index) $tool"
        tool_map[$index]="$tool"
        ((index++))
    done

    read -p "请输入选项: " tool_choice

    if [ -n "${tool_map[$tool_choice]}" ]; then
        apply_merge_tool_config "${tool_map[$tool_choice]}"
    else
        apply_merge_tool_config "vimdiff"
    fi
}

apply_merge_tool_config() {
    local tool="$1"

    case "$tool" in
        bcompare)
            ensure_beyond_compare_wrapper || { print_error "未找到 Beyond Compare 可执行文件"; return 1; }
            git config --global diff.tool bc
            git config --global merge.tool bc
            git config --global difftool.bc.cmd 'git-bc-difftool "$LOCAL" "$REMOTE" "$MERGED"'
            git config --global mergetool.bc.cmd 'bcomp "$LOCAL" "$REMOTE" "$BASE" "$MERGED"'
            git config --global mergetool.bc.trustExitCode true
            ;;
        bcomp)
            ensure_beyond_compare_wrapper || { print_error "未找到 Beyond Compare 可执行文件"; return 1; }
            git config --global diff.tool bc
            git config --global merge.tool bc
            git config --global difftool.bc.cmd 'git-bc-difftool "$LOCAL" "$REMOTE" "$MERGED"'
            git config --global mergetool.bc.cmd 'bcomp "$LOCAL" "$REMOTE" "$BASE" "$MERGED"'
            git config --global mergetool.bc.trustExitCode true
            ;;
        code)
            git config --global diff.tool vscode
            git config --global merge.tool vscode
            git config --global difftool.vscode.cmd 'code --wait --diff $LOCAL $REMOTE'
            git config --global mergetool.vscode.cmd 'code --wait $MERGED'
            ;;
        smerge)
            git config --global diff.tool smerge
            git config --global merge.tool smerge
            git config --global difftool.smerge.cmd 'smerge mergetool "$LOCAL" "$REMOTE" -o "$MERGED" -b "$BASE"'
            git config --global mergetool.smerge.cmd 'smerge mergetool "$LOCAL" "$REMOTE" -o "$MERGED" -b "$BASE"'
            ;;
        ksdiff)
            git config --global diff.tool kaleidoscope
            git config --global merge.tool kaleidoscope
            git config --global difftool.kaleidoscope.cmd 'ksdiff "$LOCAL" "$REMOTE"'
            git config --global mergetool.kaleidoscope.cmd 'ksdiff --merge --output "$MERGED" --base "$BASE" "$LOCAL" -- "$REMOTE"'
            ;;
        delta)
            git config --global core.pager delta
            git config --global delta.navigate true
            git config --global delta.light true
            ;;
        diffuse)
            git config --global diff.tool diffuse
            git config --global merge.tool diffuse
            git config --global difftool.diffuse.cmd 'diffuse "$LOCAL" "$REMOTE"'
            git config --global mergetool.diffuse.cmd 'diffuse "$LOCAL" "$REMOTE" "$BASE" "$MERGED"'
            ;;
        meld)
            git config --global diff.tool meld
            git config --global merge.tool meld
            git config --global difftool.meld.cmd 'meld "$LOCAL" "$REMOTE"'
            git config --global mergetool.meld.cmd 'meld "$LOCAL" "$REMOTE" "$BASE" "$MERGED"'
            ;;
        kdiff3)
            git config --global diff.tool kdiff3
            git config --global merge.tool kdiff3
            git config --global difftool.kdiff3.cmd 'kdiff3 "$LOCAL" "$REMOTE"'
            git config --global mergetool.kdiff3.cmd 'kdiff3 "$BASE" "$LOCAL" "$REMOTE" -o "$MERGED"'
            ;;
        vimdiff)
            git config --global diff.tool vimdiff
            git config --global merge.tool vimdiff
            git config --global difftool.prompt false
            git config --global mergetool.prompt false
            ;;
        nvimdiff)
            git config --global diff.tool nvimdiff
            git config --global merge.tool nvimdiff
            git config --global difftool.nvimdiff.cmd 'nvim -d "$LOCAL" "$REMOTE"'
            git config --global mergetool.nvimdiff.cmd 'nvim -d "$LOCAL" "$REMOTE" "$BASE" "$MERGED"'
            ;;
        *)
            print_error "未知的工具: $tool"
            return 1
            ;;
    esac
    print_success "已配置 $tool 作为对比合并工具"

    # 配置通用选项
    git config --global mergetool.keepBackup false
    git config --global mergetool.keepTemporaries false
}

# ============================================================================
# 主菜单
# ============================================================================

show_main_menu() {
    local user_name=$(git config --global user.name 2>/dev/null)
    local user_email=$(git config --global user.email 2>/dev/null)
    local merge_tool=$(git config --global merge.tool 2>/dev/null)
    local proxy=$(git config --global http.proxy 2>/dev/null)
    local gpg_key=$(git config --global user.signingkey 2>/dev/null)
    local ssh_key=""
    [ -f "$HOME/.ssh/id_ed25519.pub" ] && ssh_key="✓"

    local git_mark="" proxy_mark="" gpg_mark="" merge_mark=""
    [ -n "$user_name" ] && git_mark="✓"
    [ -n "$proxy" ] && proxy_mark="✓"
    [ -n "$gpg_key" ] && gpg_mark="✓"
    [ -n "$merge_tool" ] && merge_mark="✓"

    echo ""
    echo "1) Git配置 $git_mark"
    echo "2) SSH密钥 $ssh_key"
    echo "3) 多账户"
    echo "4) 代理 $proxy_mark"
    echo "5) GPG $gpg_mark"
    echo "6) LFS"
    echo "7) 颜色"
    echo "8) 合并工具 $merge_mark"
    echo "9) .gitignore"
    echo "10) CI/CD"
    echo "11) 诊断"
    echo "12) 备份"
    echo "c) 清除配置"
    echo "f) 快速配置"
    echo "q) 退出"
    read -p "选项: " choice
}

# ============================================================================
# 主程序
# ============================================================================

main() {
    # 解析命令行参数
    parse_arguments "$@"

    # 检查并显示 Git 版本
    print_header "Git 环境检查"
    if command -v git &>/dev/null; then
        local git_version=$(git --version)
        print_success "Git 已安装: $git_version"
    else
        print_warn "Git 未安装，正在尝试自动安装..."
        if ! check_command git; then
            print_error "Git 安装失败，请手动安装后重试"
            exit 1
        fi
        local git_version=$(git --version)
        print_success "Git 安装成功: $git_version"
    fi

    # 检查其他依赖
    if ! check_command ssh-keygen; then
        exit 1
    fi

    # 如果指定了 --skip-menu，则执行快速配置
    if [ "$SKIP_MENU" = true ]; then
        print_info "执行快速配置模式..."

        # 使用参数或交互式输入
        local email="${PARAM_EMAIL}"
        local name="${PARAM_NAME}"

        if [ -z "$email" ]; then
            read -p "请输入邮箱地址: " email
        fi

        if [ -z "$name" ]; then
            read -p "请输入用户名: " name
        fi

        # 配置 Git 基础设置
        git config --global user.name "$name"
        git config --global user.email "$email"
        print_success "Git 配置已更新：用户名=$name，邮箱=$email"

        # 生成 SSH 密钥
        local key_type=$(select_key_type)
        local key_file=$(generate_ssh_key "$email" "$key_type")

        # 配置平台
        if [ -n "$PARAM_PLATFORM" ]; then
            case "$PARAM_PLATFORM" in
                github)
                    configure_ssh_host "GitHub" "github.com" "$key_file"
                    ;;
                gitee)
                    # 如果指定了自定义 Gitea URL
                    if [ -n "$PARAM_GITEA_URL" ]; then
                        local gitea_host=$(echo "$PARAM_GITEA_URL" | sed -E 's|https?://||' | cut -d':' -f1 | cut -d'/' -f1)
                        configure_ssh_host "Gitea (${gitea_host})" "$gitea_host" "$key_file" "gitea"
                        print_info "Gitea 配置使用自定义地址: $PARAM_GITEA_URL"
                        git config --global url."$PARAM_GITEA_URL".insteadOf "https://gitee.com"
                    else
                        configure_ssh_host "Gitee" "gitee.com" "$key_file"
                    fi
                    ;;
                gitlab)
                    configure_ssh_host "GitLab" "gitlab.com" "$key_file"
                    ;;
                bitbucket)
                    configure_ssh_host "Bitbucket" "bitbucket.org" "$key_file"
                    ;;
                *)
                    print_warning "未知的平台: $PARAM_PLATFORM"
                    ;;
            esac
        else
            configure_platforms "$email" "$key_type" "$key_file"
        fi

        # 配置默认设置
        configure_git_defaults

        # 设置SSH Agent
        setup_ssh_agent "$key_file"

        print_success "快速配置完成！"
        exit 0
    fi

    while true; do
        show_main_menu

        case "$choice" in
            1)
                configure_git_basic
                ;;
            2)
                read -p "请输入邮箱地址: " email
                local key_type=$(select_key_type)
                local key_file=$(generate_ssh_key "$email" "$key_type")
                configure_platforms "$email" "$key_type" "$key_file"
                setup_ssh_agent "$key_file"
                ;;
            3)
                manage_multiple_accounts
                ;;
            4)
                configure_proxy
                ;;
            5)
                configure_gpg
                ;;
            6)
                configure_git_lfs
                ;;
            7)
                configure_color_theme
                ;;
            8)
                configure_merge_tool
                ;;
            9)
                generate_gitignore
                ;;
            10)
                generate_cicd_config
                ;;
            11)
                run_diagnostics
                ;;
            12)
                restore_config
                ;;
            f|F)
                quick_setup
                ;;
            c|C)
                clear_config
                ;;
            q|Q)
                exit 0
                ;;
            *)
                print_error "无效的选项"
                ;;
        esac
    done
}

# 运行主程序
main "$@"
