#!/usr/bin/env bash
# Install and run Prometheus mysqld_exporter.

set -euo pipefail

MYSQL_EXPORTER_VERSION="${MYSQL_EXPORTER_VERSION:-latest}"
CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(dirname "$CURRENT_DIR")"
BIN_DIR="${MYSQL_EXPORTER_BIN_DIR:-$BASE_DIR/bin}"
CONF_DIR="${MYSQL_EXPORTER_CONF_DIR:-$BASE_DIR/conf}"
LOG_DIR="${MYSQL_EXPORTER_LOG_DIR:-$BASE_DIR/logs}"
DOWNLOAD_DIR="${DOWNLOAD_DIR:-$HOME/Downloads}"
MYSQL_EXPORTER_CNF="${MYSQL_EXPORTER_CNF:-$CONF_DIR/mysqld_exporter.cnf}"

MYSQL_HOST="${MYSQL_HOST:-127.0.0.1}"
MYSQL_PORT="${MYSQL_PORT:-3306}"
MYSQL_ADMIN_USER="${MYSQL_ADMIN_USER:-root}"
MYSQL_ADMIN_PASSWORD="${MYSQL_ADMIN_PASSWORD:-}"
MYSQL_EXPORTER_USER="${MYSQL_EXPORTER_USER:-exporter}"
MYSQL_EXPORTER_PASSWORD="${MYSQL_EXPORTER_PASSWORD:-}"
MYSQL_EXPORTER_LISTEN_ADDRESS="${MYSQL_EXPORTER_LISTEN_ADDRESS:-:9104}"
MYSQL_EXPORTER_SETUP_USER=false
INSTALL_ONLY=false
INSTALL_SERVICE_ONLY=false
UNINSTALL_SERVICE_ONLY=false
FORCE_RESTART=false
NEED_MANUAL_CONFIG=false
LAUNCHAGENT_LABEL="org.prometheus.mysqld_exporter"

USER_NAME="prometheus"
GROUP_NAME="prometheus"

log() {
    printf '[INFO] %s\n' "$*"
}

warn() {
    printf '[WARN] %s\n' "$*" >&2
}

die() {
    printf '[ERROR] %s\n' "$*" >&2
    exit 1
}

show_help() {
    cat <<EOF
MySQL Exporter 安装/启动脚本

用法:
  $0 [选项]

选项:
  --mysql-host HOST            MySQL 地址，默认: 127.0.0.1
  --mysql-port PORT            MySQL 端口，默认: 3306
  --admin-user USER            用于创建 exporter 账号的管理员用户，默认: root
  --admin-password PASS        管理员密码；也可设置 MYSQL_ADMIN_PASSWORD
  --exporter-user USER         exporter 用户，默认: exporter
  --exporter-password PASS     exporter 密码；不传则自动生成
  --listen-address ADDR        exporter 监听地址，默认: :9104
  --version VERSION            mysqld_exporter 版本，默认: latest
  --config FILE                exporter my.cnf 路径，默认: $MYSQL_EXPORTER_CNF
  --setup-user                 自动创建/更新 MySQL exporter 最小权限账号
  --install-only               只安装二进制和配置，不启动
  --install-service            安装/刷新自启动服务
  --uninstall-service          卸载自启动服务
  -f, --force                  已运行时先停止再启动
  -h, --help                   显示帮助

示例:
  $0 --setup-user --admin-password 'root密码'
  $0 --mysql-host 127.0.0.1 --mysql-port 3306 --listen-address :9104

说明:
  - 默认不会使用 root 作为 exporter 账号。
  - --setup-user 会创建 '$MYSQL_EXPORTER_USER'@'localhost' 和 '$MYSQL_EXPORTER_USER'@'127.0.0.1'。
  - SkyWalking 需要再通过 OpenTelemetry Collector 抓取 :9104 并推送到 OAP。
EOF
}

parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --mysql-host)
                MYSQL_HOST="${2:-}"; shift 2 ;;
            --mysql-host=*)
                MYSQL_HOST="${1#*=}"; shift ;;
            --mysql-port)
                MYSQL_PORT="${2:-}"; shift 2 ;;
            --mysql-port=*)
                MYSQL_PORT="${1#*=}"; shift ;;
            --admin-user)
                MYSQL_ADMIN_USER="${2:-}"; shift 2 ;;
            --admin-user=*)
                MYSQL_ADMIN_USER="${1#*=}"; shift ;;
            --admin-password)
                MYSQL_ADMIN_PASSWORD="${2:-}"; shift 2 ;;
            --admin-password=*)
                MYSQL_ADMIN_PASSWORD="${1#*=}"; shift ;;
            --exporter-user)
                MYSQL_EXPORTER_USER="${2:-}"; shift 2 ;;
            --exporter-user=*)
                MYSQL_EXPORTER_USER="${1#*=}"; shift ;;
            --exporter-password)
                MYSQL_EXPORTER_PASSWORD="${2:-}"; shift 2 ;;
            --exporter-password=*)
                MYSQL_EXPORTER_PASSWORD="${1#*=}"; shift ;;
            --listen-address)
                MYSQL_EXPORTER_LISTEN_ADDRESS="${2:-}"; shift 2 ;;
            --listen-address=*)
                MYSQL_EXPORTER_LISTEN_ADDRESS="${1#*=}"; shift ;;
            --version)
                MYSQL_EXPORTER_VERSION="${2:-}"; shift 2 ;;
            --version=*)
                MYSQL_EXPORTER_VERSION="${1#*=}"; shift ;;
            --config)
                MYSQL_EXPORTER_CNF="${2:-}"; shift 2 ;;
            --config=*)
                MYSQL_EXPORTER_CNF="${1#*=}"; shift ;;
            --setup-user)
                MYSQL_EXPORTER_SETUP_USER=true; shift ;;
            --install-only)
                INSTALL_ONLY=true; shift ;;
            --install-service)
                INSTALL_SERVICE_ONLY=true
                FORCE_RESTART=true
                shift ;;
            --uninstall-service)
                UNINSTALL_SERVICE_ONLY=true; shift ;;
            -f|--force)
                FORCE_RESTART=true; shift ;;
            -h|--help)
                show_help; exit 0 ;;
            *)
                die "未知选项: $1" ;;
        esac
    done

    [[ "$MYSQL_PORT" =~ ^[0-9]+$ ]] || die "MySQL 端口无效: $MYSQL_PORT"
    [ -n "$MYSQL_HOST" ] || die "MySQL 地址不能为空"
    [ -n "$MYSQL_EXPORTER_USER" ] || die "exporter 用户不能为空"
    [ -n "$MYSQL_EXPORTER_LISTEN_ADDRESS" ] || die "监听地址不能为空"
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

detect_platform_suffix() {
    local os arch
    case "$(uname -s)" in
        Darwin) os="darwin" ;;
        Linux) os="linux" ;;
        *) die "不支持的系统: $(uname -s)" ;;
    esac

    case "$(uname -m)" in
        arm64|aarch64) arch="arm64" ;;
        x86_64|amd64) arch="amd64" ;;
        *) die "不支持的架构: $(uname -m)" ;;
    esac

    echo "${os}-${arch}"
}

resolve_latest_version() {
    if [ "$MYSQL_EXPORTER_VERSION" != "latest" ]; then
        echo "$MYSQL_EXPORTER_VERSION"
        return 0
    fi

    if ! command_exists curl; then
        echo "0.16.0"
        return 0
    fi

    local latest_url version
    latest_url="$(curl -fsSIL -o /dev/null -w '%{url_effective}' https://github.com/prometheus/mysqld_exporter/releases/latest 2>/dev/null || true)"
    version="${latest_url##*/v}"
    if [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "$version"
    else
        echo "0.16.0"
    fi
}

download_file() {
    local url="$1"
    local output="$2"
    local output_dir output_file
    output_dir="$(dirname "$output")"
    output_file="$(basename "$output")"

    mkdir -p "$output_dir"

    if command_exists adl; then
        log "使用 adl 下载: $output_file"
        if adl "$url" "$output_dir" "$output_file"; then
            return 0
        fi
        warn "adl 下载失败，回退 curl/wget"
    fi

    if command_exists curl; then
        log "使用 curl 下载: $url"
        curl -fL -C - "$url" -o "$output"
    elif command_exists wget; then
        log "使用 wget 下载: $url"
        wget -c "$url" -O "$output"
    else
        die "未找到可用下载工具，请先安装 adl、curl 或 wget"
    fi
}

verify_archive() {
    local file="$1"
    [ -f "$file" ] && tar -tzf "$file" >/dev/null 2>&1
}

generate_password() {
    local password
    set +o pipefail
    password="$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 20)"
    set -o pipefail
    printf '%s' "$password"
}

mysql_escape() {
    printf "%s" "$1" | sed "s/'/''/g"
}

mysql_client_cmd() {
    if command_exists mysql; then
        command -v mysql
    elif [ -x /opt/homebrew/bin/mysql ]; then
        echo /opt/homebrew/bin/mysql
    elif [ -x /usr/local/bin/mysql ]; then
        echo /usr/local/bin/mysql
    else
        return 1
    fi
}

setup_exporter_user() {
    local mysql_cmd
    mysql_cmd="$(mysql_client_cmd)" || die "未找到 mysql 客户端，无法创建 exporter 用户"

    [ -n "$MYSQL_ADMIN_PASSWORD" ] || die "--setup-user 需要 --admin-password 或 MYSQL_ADMIN_PASSWORD"
    [ -n "$MYSQL_EXPORTER_PASSWORD" ] || MYSQL_EXPORTER_PASSWORD="$(generate_password)"

    local exporter_user exporter_password
    exporter_user="$(mysql_escape "$MYSQL_EXPORTER_USER")"
    exporter_password="$(mysql_escape "$MYSQL_EXPORTER_PASSWORD")"

    log "创建/更新 MySQL exporter 最小权限账号: $MYSQL_EXPORTER_USER"
    "$mysql_cmd" -h"$MYSQL_HOST" -P"$MYSQL_PORT" -u"$MYSQL_ADMIN_USER" -p"$MYSQL_ADMIN_PASSWORD" <<SQL
CREATE USER IF NOT EXISTS '$exporter_user'@'localhost' IDENTIFIED BY '$exporter_password' WITH MAX_USER_CONNECTIONS 3;
ALTER USER '$exporter_user'@'localhost' IDENTIFIED BY '$exporter_password' WITH MAX_USER_CONNECTIONS 3;
CREATE USER IF NOT EXISTS '$exporter_user'@'127.0.0.1' IDENTIFIED BY '$exporter_password' WITH MAX_USER_CONNECTIONS 3;
ALTER USER '$exporter_user'@'127.0.0.1' IDENTIFIED BY '$exporter_password' WITH MAX_USER_CONNECTIONS 3;
GRANT PROCESS, REPLICATION CLIENT, SELECT ON *.* TO '$exporter_user'@'localhost';
GRANT PROCESS, REPLICATION CLIENT, SELECT ON *.* TO '$exporter_user'@'127.0.0.1';
FLUSH PRIVILEGES;
SQL
}

write_exporter_cnf() {
    if [ -z "$MYSQL_EXPORTER_PASSWORD" ] && [ -f "$MYSQL_EXPORTER_CNF" ]; then
        log "保留已有 exporter 配置: $MYSQL_EXPORTER_CNF"
        return 0
    fi

    mkdir -p "$(dirname "$MYSQL_EXPORTER_CNF")"
    if [ -z "$MYSQL_EXPORTER_PASSWORD" ]; then
        NEED_MANUAL_CONFIG=true
        cat > "$MYSQL_EXPORTER_CNF" <<EOF
[client]
user=$MYSQL_EXPORTER_USER
password=
host=$MYSQL_HOST
port=$MYSQL_PORT
EOF
        chmod 600 "$MYSQL_EXPORTER_CNF"
        warn "已生成 exporter 配置模板，请填写 password 后再启动: $MYSQL_EXPORTER_CNF"
        return 0
    fi

    cat > "$MYSQL_EXPORTER_CNF" <<EOF
[client]
user=$MYSQL_EXPORTER_USER
password=$MYSQL_EXPORTER_PASSWORD
host=$MYSQL_HOST
port=$MYSQL_PORT
EOF
    chmod 600 "$MYSQL_EXPORTER_CNF"
    log "已写入 exporter 配置: $MYSQL_EXPORTER_CNF"
}

install_mysql_exporter() {
    local suffix archive url root_dir version
    version="$(resolve_latest_version)"
    MYSQL_EXPORTER_VERSION="$version"
    suffix="$(detect_platform_suffix)"
    archive="$DOWNLOAD_DIR/mysqld_exporter-${version}.${suffix}.tar.gz"
    url="https://github.com/prometheus/mysqld_exporter/releases/download/v${version}/mysqld_exporter-${version}.${suffix}.tar.gz"
    root_dir="mysqld_exporter-${version}.${suffix}"

    mkdir -p "$BIN_DIR" "$LOG_DIR" "$DOWNLOAD_DIR"

    if ! verify_archive "$archive"; then
        rm -f "$archive"
        download_file "$url" "$archive"
    fi

    tar -xzf "$archive" -C "$DOWNLOAD_DIR"
    cp "$DOWNLOAD_DIR/$root_dir/mysqld_exporter" "$BIN_DIR/mysqld_exporter"
    chmod +x "$BIN_DIR/mysqld_exporter"
    rm -rf "$DOWNLOAD_DIR/$root_dir"
    log "mysqld_exporter 已安装: $BIN_DIR/mysqld_exporter"
}

listen_port() {
    local address="$1"
    local port="${address##*:}"
    [[ "$port" =~ ^[0-9]+$ ]] || return 1
    echo "$port"
}

stop_existing_exporter() {
    local pids
    pids="$(pgrep -f "$BIN_DIR/mysqld_exporter" 2>/dev/null || true)"
    pids="$pids
$(pgrep -f "$LAUNCHAGENT_LABEL/bin/mysqld_exporter" 2>/dev/null || true)"
    pids="$(printf '%s\n' "$pids" | awk 'NF && !seen[$0]++')"
    [ -n "$pids" ] || return 0

    log "停止已有 mysqld_exporter: $pids"
    kill $pids 2>/dev/null || true
    sleep 2
}

exporter_running() {
    pgrep -f "$BIN_DIR/mysqld_exporter" >/dev/null 2>&1 && return 0
    pgrep -f "$LAUNCHAGENT_LABEL/bin/mysqld_exporter" >/dev/null 2>&1 && return 0
    return 1
}

create_linux_service() {
    [ "$(uname -s)" = "Linux" ] || return 1
    [ "$EUID" -eq 0 ] || return 1
    command_exists systemctl || return 1

    if command_exists getent; then
        getent group "$GROUP_NAME" >/dev/null 2>&1 || groupadd --system "$GROUP_NAME"
    fi
    id -u "$USER_NAME" >/dev/null 2>&1 || useradd -s /sbin/nologin --system -g "$GROUP_NAME" "$USER_NAME"

    cat > /etc/systemd/system/mysqld_exporter.service <<EOF
[Unit]
Description=Prometheus MySQL Exporter
Wants=network-online.target
After=network-online.target

[Service]
User=$USER_NAME
Group=$GROUP_NAME
Type=simple
ExecStart=$BIN_DIR/mysqld_exporter --config.my-cnf=$MYSQL_EXPORTER_CNF --web.listen-address=$MYSQL_EXPORTER_LISTEN_ADDRESS
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable mysqld_exporter
    systemctl restart mysqld_exporter
}

create_macos_service() {
    [ "$(uname -s)" = "Darwin" ] || return 1
    [ -x "$BIN_DIR/mysqld_exporter" ] || return 1

    local plist_dir="$HOME/Library/LaunchAgents"
    local plist_file="$plist_dir/$LAUNCHAGENT_LABEL.plist"
    local runtime_root="$plist_dir/runtime/$LAUNCHAGENT_LABEL"
    local runtime_bin="$runtime_root/bin"
    local runtime_conf="$runtime_root/conf"
    local runtime_logs="$runtime_root/logs"
    mkdir -p "$plist_dir" "$runtime_bin" "$runtime_conf" "$runtime_logs"
    cp "$BIN_DIR/mysqld_exporter" "$runtime_bin/mysqld_exporter"
    cp "$MYSQL_EXPORTER_CNF" "$runtime_conf/mysqld_exporter.cnf"
    chmod +x "$runtime_bin/mysqld_exporter"

    launchctl bootout "gui/$(id -u)/$LAUNCHAGENT_LABEL" >/dev/null 2>&1 || true
    launchctl unload "$plist_file" >/dev/null 2>&1 || true

    cat > "$plist_file" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LAUNCHAGENT_LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$runtime_bin/mysqld_exporter</string>
        <string>--config.my-cnf=$runtime_conf/mysqld_exporter.cnf</string>
        <string>--web.listen-address=$MYSQL_EXPORTER_LISTEN_ADDRESS</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>$runtime_logs/launchd.out.log</string>
    <key>StandardErrorPath</key>
    <string>$runtime_logs/launchd.err.log</string>
</dict>
</plist>
EOF

    launchctl bootstrap "gui/$(id -u)" "$plist_file" 2>/dev/null || launchctl load -w "$plist_file"
    launchctl enable "gui/$(id -u)/$LAUNCHAGENT_LABEL" 2>/dev/null || true
    launchctl kickstart -k "gui/$(id -u)/$LAUNCHAGENT_LABEL" 2>/dev/null || true
}

remove_macos_service() {
    local plist_file="$HOME/Library/LaunchAgents/$LAUNCHAGENT_LABEL.plist"
    launchctl bootout "gui/$(id -u)/$LAUNCHAGENT_LABEL" >/dev/null 2>&1 || true
    launchctl unload "$plist_file" >/dev/null 2>&1 || true
    rm -f "$plist_file"
    rm -rf "$HOME/Library/LaunchAgents/runtime/$LAUNCHAGENT_LABEL"
}

remove_linux_service() {
    [ "$(uname -s)" = "Linux" ] || return 1
    [ "$EUID" -eq 0 ] || return 1
    command_exists systemctl || return 1
    systemctl disable --now mysqld_exporter >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/mysqld_exporter.service
    systemctl daemon-reload >/dev/null 2>&1 || true
}

start_mysql_exporter() {
    if [ ! -x "$BIN_DIR/mysqld_exporter" ]; then
        install_mysql_exporter
    fi

    if [ "$MYSQL_EXPORTER_SETUP_USER" = true ]; then
        setup_exporter_user
    fi
    write_exporter_cnf

    if [ "$INSTALL_ONLY" = true ]; then
        log "已完成安装和配置，未启动 exporter"
        return 0
    fi

    if [ "$NEED_MANUAL_CONFIG" = true ]; then
        die "缺少 exporter 密码，已停止启动。请填写 $MYSQL_EXPORTER_CNF 后重新运行"
    fi

    if [ "$FORCE_RESTART" = true ]; then
        stop_existing_exporter
    elif exporter_running; then
        log "MySQL Exporter 已经在运行"
        return 0
    fi

    if create_linux_service; then
        log "MySQL Exporter 已通过 systemd 启动"
    elif create_macos_service; then
        log "MySQL Exporter 已通过 macOS LaunchAgent 启动"
    else
        nohup "$BIN_DIR/mysqld_exporter" \
            --config.my-cnf="$MYSQL_EXPORTER_CNF" \
            --web.listen-address="$MYSQL_EXPORTER_LISTEN_ADDRESS" \
            > "$LOG_DIR/mysqld_exporter.log" 2>&1 &
        log "MySQL Exporter 已启动，日志: $LOG_DIR/mysqld_exporter.log"
    fi

    local port
    port="$(listen_port "$MYSQL_EXPORTER_LISTEN_ADDRESS" || true)"
    if [ -n "$port" ] && command_exists curl; then
        sleep 2
        if curl -fsS "http://127.0.0.1:$port/metrics" >/dev/null 2>&1; then
            log "Exporter 指标端点可访问: http://127.0.0.1:$port/metrics"
        else
            warn "Exporter 已启动但指标端点暂不可访问，请查看日志: $LOG_DIR/mysqld_exporter.log"
        fi
    fi

    cat <<EOF

后续接入 SkyWalking:
  apm/skywalking/bin/setup-mysql-monitoring.sh \\
    --mysql-exporter-target 127.0.0.1:${port:-9104} \\
    --oap-endpoint 127.0.0.1:11800 \\
    --host-name $(hostname)
EOF
}

parse_args "$@"
if [ "$UNINSTALL_SERVICE_ONLY" = true ]; then
    remove_linux_service || remove_macos_service
    log "MySQL Exporter 自启动服务已卸载"
    exit 0
fi
start_mysql_exporter
