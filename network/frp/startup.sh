#!/bin/bash

# 通用启动脚本，用于启动 frpc 或 frps 服务

set -euo pipefail

get_script_dir() {
    local source="${BASH_SOURCE[0]:-$0}"
    local dir
    if command -v readlink >/dev/null 2>&1; then
        local resolved
        resolved=$(readlink -f "$source" 2>/dev/null || true)
        if [ -n "$resolved" ]; then
            dirname "$resolved"
            return
        fi
    fi
    dir=$(cd "$(dirname "$source")" && pwd)
    echo "$dir"
}

ORIGINAL_HOME="${FRP_ORIGINAL_HOME:-$HOME}"
if [ -n "${SUDO_USER:-}" ] && [ "${SUDO_USER}" != "root" ]; then
    ORIGINAL_HOME=$(eval echo "~${SUDO_USER}")
fi

SCRIPT_DIR=$(get_script_dir)
INSTALL_DIR="$SCRIPT_DIR"
DOWNLOAD_DIR="${DOWNLOAD_DIR:-$ORIGINAL_HOME/Downloads}"
SERVICE_TYPE=""

show_help() {
    cat <<EOF
FRP 启动脚本

用法: $0 [选项]

选项:
  -h, --help                  显示此帮助信息
  -s, --server                启动 frps 服务端
  -c, --client                启动 frpc 客户端
  -d, --install-dir DIR       指定安装目录 (默认: 脚本目录 $SCRIPT_DIR)
  -D, --download-dir DIR      指定下载目录，调用安装脚本时使用 (默认: $ORIGINAL_HOME/Downloads)

无参数执行时:
  自动检测安装目录下 frps/frpc 二进制和 frps.toml/frpc.toml。
  如没有可启动目标，则直接调用 install.sh，由安装脚本处理安装模式选择。
EOF
}

expand_path() {
    local path="$1"
    path="${path/#\~/$ORIGINAL_HOME}"
    if [[ "$path" != /* ]]; then
        path="$(pwd)/$path"
    fi
    printf '%s\n' "${path%/}"
}

parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            -h|--help)
                show_help
                exit 0
                ;;
            -s|--server)
                SERVICE_TYPE="frps"
                shift
                ;;
            -c|--client)
                SERVICE_TYPE="frpc"
                shift
                ;;
            -d|--dir|--install-dir)
                [ $# -gt 1 ] || { echo "错误: $1 需要指定目录" >&2; exit 1; }
                INSTALL_DIR=$(expand_path "$2")
                shift 2
                ;;
            --dir=*|--install-dir=*)
                INSTALL_DIR=$(expand_path "${1#*=}")
                shift
                ;;
            -D|--download-dir)
                [ $# -gt 1 ] || { echo "错误: $1 需要指定下载目录" >&2; exit 1; }
                DOWNLOAD_DIR=$(expand_path "$2")
                shift 2
                ;;
            --download-dir=*)
                DOWNLOAD_DIR=$(expand_path "${1#*=}")
                shift
                ;;
            *)
                echo "未知参数: $1" >&2
                show_help
                exit 1
                ;;
        esac
    done
}

has_startable_service() {
    local type="$1"
    [ -x "${INSTALL_DIR}/${type}" ] && [ -f "${INSTALL_DIR}/${type}.toml" ]
}

run_installer() {
    local mode="${1:-}"
    local install_script="${SCRIPT_DIR}/install.sh"
    if [ ! -f "$install_script" ]; then
        install_script="${INSTALL_DIR}/install.sh"
    fi

    if [ ! -f "$install_script" ]; then
        echo "错误: 未找到安装脚本 install.sh，无法自动安装。"
        exit 1
    fi

    echo "未检测到可启动的 frps/frpc，交给安装脚本处理。"
    case "$mode" in
        frps) exec "$install_script" --server --install-dir "$INSTALL_DIR" --download-dir "$DOWNLOAD_DIR" ;;
        frpc) exec "$install_script" --client --install-dir "$INSTALL_DIR" --download-dir "$DOWNLOAD_DIR" ;;
        *)    exec "$install_script" --install-dir "$INSTALL_DIR" --download-dir "$DOWNLOAD_DIR" ;;
    esac
}

auto_detect_service() {
    local has_frpc=0
    local has_frps=0

    has_startable_service frpc && has_frpc=1
    has_startable_service frps && has_frps=1

    if [ "$has_frpc" -eq 1 ] && [ "$has_frps" -eq 0 ]; then
        SERVICE_TYPE="frpc"
    elif [ "$has_frps" -eq 1 ] && [ "$has_frpc" -eq 0 ]; then
        SERVICE_TYPE="frps"
    elif [ "$has_frpc" -eq 1 ] && [ "$has_frps" -eq 1 ]; then
        echo "同时检测到 frpc 和 frps，默认启动 frpc。可用 --server 指定 frps。"
        SERVICE_TYPE="frpc"
    else
        run_installer
    fi

    echo "自动检测到可启动目标: ${SERVICE_TYPE}"
}

parse_args "$@"

if [ -z "$SERVICE_TYPE" ]; then
    auto_detect_service
fi

if [ "$SERVICE_TYPE" != "frpc" ] && [ "$SERVICE_TYPE" != "frps" ]; then
    echo "错误: 服务类型必须是 frpc 或 frps"
    exit 1
fi

FRP_BIN_NAME="$SERVICE_TYPE"
FRP_CONF_NAME="${SERVICE_TYPE}.toml"
LOG_FILE="$INSTALL_DIR/${SERVICE_TYPE}.log"

is_service_running() {
    pgrep -f "${INSTALL_DIR}/${FRP_BIN_NAME} -c ${INSTALL_DIR}/${FRP_CONF_NAME}" >/dev/null
}

get_service_pid() {
    pgrep -f "${INSTALL_DIR}/${FRP_BIN_NAME} -c ${INSTALL_DIR}/${FRP_CONF_NAME}"
}

get_local_ip() {
    local ip=""
    if [[ "$OSTYPE" == "darwin"* ]]; then
        ip=$(ifconfig | grep "inet " | grep -v 127.0.0.1 | awk '{print $2}' | head -1)
    else
        ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    fi

    if [ -n "$ip" ]; then
        echo "$ip"
        return
    fi

    ip=$(ip route get 8.8.8.8 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1); exit}')
    if [ -n "$ip" ]; then
        echo "$ip"
        return
    fi

    ip=$(netstat -rn | grep -E "^0.0.0.0|UG" | awk '{print $8}' | head -1 | xargs -I {} sh -c 'ip addr show {} | grep "inet " | grep -v "127.0.0.1" | awk "{print \$2}" | cut -d/ -f1' | head -1)
    if [ -n "$ip" ]; then
        echo "$ip"
        return
    fi

    echo ""
}

ip_to_name_format() {
    echo "$1" | tr '.' '-'
}

extract_ip_from_name() {
    local name="$1"
    local ip_pattern='([0-9]+)-([0-9]+)-([0-9]+)-([0-9]+)'
    if [[ "$name" =~ $ip_pattern ]]; then
        echo "${BASH_REMATCH[1]}.${BASH_REMATCH[2]}.${BASH_REMATCH[3]}.${BASH_REMATCH[4]}"
        return 0
    fi
    echo ""
    return 1
}

get_server_addr() {
    local config_file="$1"
    grep "^serverAddr[[:space:]]*=" "$config_file" | head -1 | sed -E 's/serverAddr[[:space:]]*=[[:space:]]*"([^"]+)"/\1/'
}

get_server_port() {
    local config_file="$1"
    local port
    port=$(grep "^serverPort[[:space:]]*=" "$config_file" | head -1 | sed -E 's/serverPort[[:space:]]*=[[:space:]]*"?([0-9]+)"?/\1/')
    echo "${port:-7000}"
}

check_remote_port() {
    local server_addr="$1"
    local server_port="$2"
    local remote_port="$3"
    local timeout=2

    if command -v nc >/dev/null 2>&1; then
        if ! nc -z -w $timeout "$server_addr" "$remote_port" 2>/dev/null; then
            return 0
        else
            return 1
        fi
    elif command -v bash >/dev/null 2>&1; then
        if ! timeout $timeout bash -c "echo > /dev/tcp/$server_addr/$remote_port" 2>/dev/null; then
            return 0
        else
            return 1
        fi
    fi

    return 0
}

find_available_port() {
    local server_addr="$1"
    local server_port="$2"
    local start_port="$3"
    local end_port="${4:-65535}"

    for port in $(seq "$start_port" "$end_port"); do
        if check_remote_port "$server_addr" "$server_port" "$port"; then
            echo "$port"
            return 0
        fi
    done

    echo ""
    return 1
}

update_frpc_local_ip() {
    local config_file="${INSTALL_DIR}/frpc.toml"
    if [ "$SERVICE_TYPE" != "frpc" ] || [ ! -f "$config_file" ]; then
        return 0
    fi

    local current_ip
    current_ip=$(get_local_ip)
    if [ -z "$current_ip" ]; then
        return 0
    fi

    local server_addr
    local server_port
    server_addr=$(get_server_addr "$config_file")
    server_port=$(get_server_port "$config_file")

    local temp_config="${INSTALL_DIR}/frpc.toml.tmp"
    local in_proxy_section=false
    local config_updated=false
    : > "$temp_config"

    while IFS= read -r line || [ -n "$line" ]; do
        if [[ $line =~ ^\[\[proxies\]\] ]]; then
            in_proxy_section=true
            echo "$line" >> "$temp_config"
        elif [[ $line =~ ^\[.*\] ]] && [[ ! $line =~ ^\[\[proxies\]\] ]]; then
            in_proxy_section=false
            echo "$line" >> "$temp_config"
        elif [[ $line =~ ^name[[:space:]]*= ]] && [ "$in_proxy_section" = true ]; then
            local existing_name
            existing_name=$(echo "$line" | sed -E 's/name[[:space:]]*=[[:space:]]*"([^"]+)"/\1/')
            local ip_in_name
            ip_in_name=$(extract_ip_from_name "$existing_name")

            if [ -n "$ip_in_name" ] && [ "$ip_in_name" != "$current_ip" ]; then
                local new_name="ssh$(ip_to_name_format "$current_ip")"
                echo "更新 name: $existing_name -> $new_name"
                echo "$line" | sed -E "s/name[[:space:]]*=[[:space:]]*\"[^\"]+\"/name = \"$new_name\"/" >> "$temp_config"
                config_updated=true
            else
                echo "$line" >> "$temp_config"
            fi
        elif [[ $line =~ ^localIP[[:space:]]*= ]] && [ "$in_proxy_section" = true ]; then
            local existing_ip
            existing_ip=$(echo "$line" | sed -E 's/localIP[[:space:]]*=[[:space:]]*"([^"]+)"/\1/')
            if [ "$existing_ip" != "$current_ip" ]; then
                echo "更新 localIP: $existing_ip -> $current_ip"
                echo "$line" | sed -E "s/localIP[[:space:]]*=[[:space:]]*\"[^\"]+\"/localIP = \"$current_ip\"/" >> "$temp_config"
                config_updated=true
            else
                echo "$line" >> "$temp_config"
            fi
        elif [[ $line =~ ^remotePort[[:space:]]*= ]] && [ "$in_proxy_section" = true ] && [ -n "$server_addr" ]; then
            local existing_remote_port
            existing_remote_port=$(echo "$line" | sed -E 's/remotePort[[:space:]]*=[[:space:]]*"?([0-9]+)"?/\1/')

            if [ -n "$existing_remote_port" ]; then
                if check_remote_port "$server_addr" "$server_port" "$existing_remote_port"; then
                    echo "$line" >> "$temp_config"
                else
                    echo "检测到远程端口 $existing_remote_port 被占用，正在查找可用端口..."
                    local new_port
                    new_port=$(find_available_port "$server_addr" "$server_port" "$existing_remote_port")
                    if [ -n "$new_port" ]; then
                        echo "更新 remotePort: $existing_remote_port -> $new_port"
                        echo "$line" | sed -E "s/remotePort[[:space:]]*=[[:space:]]*\"?[0-9]+\"?/remotePort = $new_port/" >> "$temp_config"
                        config_updated=true
                    else
                        echo "警告: 未找到可用的远程端口，保持原端口 $existing_remote_port"
                        echo "$line" >> "$temp_config"
                    fi
                fi
            else
                echo "$line" >> "$temp_config"
            fi
        else
            echo "$line" >> "$temp_config"
        fi
    done < "$config_file"

    if [ "$config_updated" = true ]; then
        mv "$temp_config" "$config_file"
    else
        rm -f "$temp_config"
    fi
}

check_required_files() {
    if [ ! -x "${INSTALL_DIR}/${FRP_BIN_NAME}" ]; then
        echo "错误: 二进制文件不存在或不可执行: ${INSTALL_DIR}/${FRP_BIN_NAME}"
        return 1
    fi

    if [ ! -f "${INSTALL_DIR}/${FRP_CONF_NAME}" ]; then
        echo "错误: 配置文件不存在: ${INSTALL_DIR}/${FRP_CONF_NAME}"
        return 1
    fi

    return 0
}

init_log_dir() {
    local log_dir
    log_dir=$(dirname "$LOG_FILE")
    if [ ! -d "$log_dir" ]; then
        mkdir -p "$log_dir"
    fi
}

if ! check_required_files; then
    run_installer "$SERVICE_TYPE"
fi

echo "使用安装目录: ${INSTALL_DIR}"

if is_service_running; then
    PID=$(get_service_pid)
    echo "${SERVICE_TYPE} 服务已在运行，PID: $PID"
    exit 0
fi

if [ "$SERVICE_TYPE" = "frpc" ]; then
    update_frpc_local_ip
fi

init_log_dir

echo "正在启动 ${SERVICE_TYPE} 服务..."
"${INSTALL_DIR}/${FRP_BIN_NAME}" -c "${INSTALL_DIR}/${FRP_CONF_NAME}" > "$LOG_FILE" 2>&1 &
START_PID=$!

sleep 2

if ps -p "$START_PID" >/dev/null; then
    echo "${SERVICE_TYPE} 服务启动成功，PID: $START_PID"
    echo "日志文件: $LOG_FILE"
else
    echo "${SERVICE_TYPE} 启动失败，日志 $LOG_FILE:"
    cat "$LOG_FILE"
    exit 1
fi
