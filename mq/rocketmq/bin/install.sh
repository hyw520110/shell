#!/usr/bin/env bash

# RocketMQ 安装脚本
# 安装官方 RocketMQ 二进制发行版到源码目录之外

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_CONF_DIR="$(cd "$SCRIPT_DIR/.." && pwd)/conf"

ROCKETMQ_VERSION="${ROCKETMQ_VERSION:-5.3.3}"
INSTALL_DIR="$HOME/rocketmq"
DOWNLOAD_DIR="${DOWNLOAD_DIR:-$HOME/Downloads}"
FORCE_INSTALL=0
UPDATE_ENV=1
AUTO_START=1
INSTALL_SERVICE_ONLY=0
UNINSTALL_SERVICE_ONLY=0
CONFIGURE_MEMORY_ONLY=0
MEMORY_CONFIG_REQUESTED=0
MEMORY_PROFILE="standard"
NAMESRV_HEAP="4g"
BROKER_HEAP="8g"
BROKER_DIRECT_MEMORY="15g"
SERVICE_MODE="${SERVICE_MODE:-standalone}"
LAUNCHAGENT_LABEL="org.apache.rocketmq"

ZIP_FILE="rocketmq-all-${ROCKETMQ_VERSION}-bin-release.zip"
EXTRACT_DIR="rocketmq-all-${ROCKETMQ_VERSION}-bin-release"
DOWNLOAD_URLS=(
    "https://dist.apache.org/repos/dist/release/rocketmq/${ROCKETMQ_VERSION}/${ZIP_FILE}"
    "https://downloads.apache.org/rocketmq/${ROCKETMQ_VERSION}/${ZIP_FILE}"
    "https://archive.apache.org/dist/rocketmq/${ROCKETMQ_VERSION}/${ZIP_FILE}"
)

log_info() { printf '[INFO] %s\n' "$*"; }
log_warn() { printf '[WARN] %s\n' "$*" >&2; }
log_error() { printf '[ERROR] %s\n' "$*" >&2; }

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

abs_path() {
    local path="$1"
    case "$path" in
        "~") path="$HOME" ;;
        "~/"*) path="$HOME/${path#~/}" ;;
    esac
    if [[ "$path" == /* ]]; then
        printf '%s\n' "$path"
    else
        printf '%s/%s\n' "$(pwd)" "$path"
    fi
}

show_usage() {
    cat <<EOF
RocketMQ 安装脚本

用法:
  $0 [选项]

选项:
  -d, --dir DIR             安装目录，默认: \$HOME/rocketmq
  -D, --download-dir DIR    下载目录，默认: \$HOME/Downloads
  -r, --rocketmq-version V  RocketMQ 版本，默认: ${ROCKETMQ_VERSION}
  -f, --force               强制替换已有安装
      --no-env              不更新 shell 环境变量
      --no-start            安装后不自动启动 (默认安装完成后自动以单机模式启动)
      --install-service     只安装/刷新自启动服务，不重新安装 RocketMQ
      --uninstall-service   只卸载自启动服务
      --service-mode MODE   自启动模式，默认: standalone
      --configure-memory    只更新现有 RocketMQ JVM 内存配置
      --memory-profile P    内存模板: standard|dev（dev: NameServer 512m, Broker 1g）
      --namesrv-heap SIZE   NameServer 堆大小，例如 512m
      --broker-heap SIZE    Broker 堆大小，例如 1g
      --broker-direct SIZE  Broker 直接内存，例如 1g
  -v, --version             打印已安装的 RocketMQ 版本
  -h, --help                显示帮助

示例:
  $0
  $0 --dir /opt/rocketmq --download-dir /data/downloads
  $0 --dir ~/rocketmq --configure-memory --memory-profile dev
EOF
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -d|--dir)
                [[ -n "${2:-}" ]] || { log_error "$1 需要指定目录"; exit 1; }
                INSTALL_DIR="$2"
                shift 2
                ;;
            -D|--download-dir)
                [[ -n "${2:-}" ]] || { log_error "$1 需要指定目录"; exit 1; }
                DOWNLOAD_DIR="$2"
                shift 2
                ;;
            -r|--rocketmq-version)
                [[ -n "${2:-}" ]] || { log_error "$1 需要指定版本"; exit 1; }
                ROCKETMQ_VERSION="$2"
                ZIP_FILE="rocketmq-all-${ROCKETMQ_VERSION}-bin-release.zip"
                EXTRACT_DIR="rocketmq-all-${ROCKETMQ_VERSION}-bin-release"
                DOWNLOAD_URLS=(
                    "https://dist.apache.org/repos/dist/release/rocketmq/${ROCKETMQ_VERSION}/${ZIP_FILE}"
                    "https://downloads.apache.org/rocketmq/${ROCKETMQ_VERSION}/${ZIP_FILE}"
                    "https://archive.apache.org/dist/rocketmq/${ROCKETMQ_VERSION}/${ZIP_FILE}"
                )
                shift 2
                ;;
            -f|--force)
                FORCE_INSTALL=1
                shift
                ;;
            --no-env)
                UPDATE_ENV=0
                shift
                ;;
            --no-start)
                AUTO_START=0
                shift
                ;;
            --install-service)
                INSTALL_SERVICE_ONLY=1
                AUTO_START=0
                shift
                ;;
            --uninstall-service)
                UNINSTALL_SERVICE_ONLY=1
                AUTO_START=0
                shift
                ;;
            --configure-memory)
                CONFIGURE_MEMORY_ONLY=1
                MEMORY_CONFIG_REQUESTED=1
                AUTO_START=0
                shift
                ;;
            --memory-profile)
                MEMORY_PROFILE="${2:-}"
                MEMORY_CONFIG_REQUESTED=1
                shift 2
                ;;
            --memory-profile=*)
                MEMORY_PROFILE="${1#*=}"
                MEMORY_CONFIG_REQUESTED=1
                shift
                ;;
            --namesrv-heap)
                NAMESRV_HEAP="${2:-}"
                MEMORY_CONFIG_REQUESTED=1
                shift 2
                ;;
            --broker-heap)
                BROKER_HEAP="${2:-}"
                MEMORY_CONFIG_REQUESTED=1
                shift 2
                ;;
            --broker-direct)
                BROKER_DIRECT_MEMORY="${2:-}"
                MEMORY_CONFIG_REQUESTED=1
                shift 2
                ;;
            --service-mode)
                [[ -n "${2:-}" ]] || { log_error "$1 需要指定模式"; exit 1; }
                SERVICE_MODE="$2"
                shift 2
                ;;
            --service-mode=*)
                SERVICE_MODE="${1#*=}"
                shift
                ;;
            -v|--version)
                print_installed_version
                exit $?
                ;;
            -h|--help)
                show_usage
                exit 0
                ;;
            *)
                log_error "未知选项: $1"
                show_usage
                exit 1
                ;;
        esac
    done

    INSTALL_DIR="$(abs_path "$INSTALL_DIR")"
    DOWNLOAD_DIR="$(abs_path "$DOWNLOAD_DIR")"

    case "$MEMORY_PROFILE" in
        dev)
            [[ "$NAMESRV_HEAP" != "4g" ]] || NAMESRV_HEAP="512m"
            [[ "$BROKER_HEAP" != "8g" ]] || BROKER_HEAP="1g"
            [[ "$BROKER_DIRECT_MEMORY" != "15g" ]] || BROKER_DIRECT_MEMORY="1g"
            ;;
        standard) ;;
        *) log_error "不支持的内存模板: $MEMORY_PROFILE"; exit 1 ;;
    esac
    [[ "$NAMESRV_HEAP" =~ ^[1-9][0-9]*[mMgG]$ ]] || { log_error "无效的 NameServer 堆大小: $NAMESRV_HEAP"; exit 1; }
    [[ "$BROKER_HEAP" =~ ^[1-9][0-9]*[mMgG]$ ]] || { log_error "无效的 Broker 堆大小: $BROKER_HEAP"; exit 1; }
    [[ "$BROKER_DIRECT_MEMORY" =~ ^[1-9][0-9]*[mMgG]$ ]] || { log_error "无效的 Broker 直接内存: $BROKER_DIRECT_MEMORY"; exit 1; }
}

print_installed_version() {
    local install_dir
    install_dir="$(abs_path "$INSTALL_DIR")"
    if [[ -f "$install_dir/.rocketmq-version" ]]; then
        cat "$install_dir/.rocketmq-version"
        return 0
    fi
    if [[ -x "$install_dir/bin/mqbroker" && -d "$install_dir/lib" ]]; then
        printf 'installed\n'
        return 0
    fi
    return 1
}

find_adl() {
    if command_exists adl && adl --help >/dev/null 2>&1; then
        command -v adl
        return 0
    fi
    return 1
}

file_size() {
    stat -f%z "$1" 2>/dev/null || stat -c%s "$1" 2>/dev/null || echo 0
}

# 字节数转人类可读格式 (KB/MB/GB)
human_size() {
    local bytes="${1:-0}"
    awk -v b="$bytes" 'BEGIN {
        if (b+0 >= 1073741824) printf "%.2f GB", b/1073741824
        else if (b+0 >= 1048576) printf "%.2f MB", b/1048576
        else if (b+0 >= 1024) printf "%.2f KB", b/1024
        else printf "%d 字节", b
    }'
}

# 检测本地代理，设置 http_proxy/https_proxy 环境变量供 curl/wget 使用
detect_proxy() {
    # 1. 已有代理环境变量 → 直接用
    if [[ -n "${https_proxy:-${HTTPS_PROXY:-${http_proxy:-${HTTP_PROXY:-}}}}" ]]; then
        log_info "使用已有代理: ${https_proxy:-${HTTPS_PROXY:-${http_proxy:-${HTTP_PROXY:-}}}}"
        return 0
    fi

    # 2. 检测常见本地代理端口 (Clash 7890, V2Ray 1087, SS 1080 等)
    local port
    for port in 7890 1087 1080 8080 8118; do
        if command_exists nc; then
            nc -z -w1 127.0.0.1 "$port" 2>/dev/null || continue
        else
            (: <"/dev/tcp/127.0.0.1/$port") 2>/dev/null || continue
        fi
        export http_proxy="http://127.0.0.1:$port"
        export https_proxy="http://127.0.0.1:$port"
        log_info "检测到本地代理: http://127.0.0.1:$port"
        return 0
    done

    log_info "未检测到代理，使用直连"
    return 0
}

valid_zip() {
    local file="$1"
    [[ -f "$file" ]] || return 1
    [[ "$(file_size "$file")" -gt 1000000 ]] || return 1
    unzip -tq "$file" >/dev/null 2>&1
}

# 单个 URL 下载：adl(静默) → curl(续传→全新) → wget(续传→全新)
download_file() {
    local url="$1"
    local output="$2"
    local output_dir filename adl_path

    output_dir="$(dirname "$output")"
    filename="$(basename "$output")"
    mkdir -p "$output_dir"

    # 1. adl 静默尝试 (失败后立即清理 aria2 控制文件，避免状态混乱)
    if adl_path="$(find_adl)"; then
        log_info "尝试 adl 下载 (aria2c + 代理)"
        if "$adl_path" "$url" "$output_dir" "$filename" >/dev/null 2>&1; then
            return 0
        fi
        log_warn "adl 下载失败，清理 aria2 状态后切换到 curl/wget"
        rm -f "$output.aria2"
    fi

    # 2. curl：先续传，失败则删除残留全新下载
    if command_exists curl; then
        if [[ -f "$output" ]]; then
            local resume_size
            resume_size=$(file_size "$output")
            log_info "尝试 curl 断点续传 (已下载 $(human_size "$resume_size"))"
            if curl -fL --retry 3 --connect-timeout 10 -C - -o "$output" "$url" 2>&1; then
                return 0
            fi
            log_warn "curl 断点续传失败 (服务器可能不支持 byte ranges 或网络中断)"
            log_info "删除残留文件，使用 curl 全新下载"
            rm -f "$output"
        fi
        curl -fL --retry 3 --connect-timeout 10 -o "$output" "$url" 2>&1
        return $?
    fi

    # 3. wget：先续传，失败则删除残留全新下载
    if command_exists wget; then
        if [[ -f "$output" ]]; then
            local resume_size
            resume_size=$(file_size "$output")
            log_info "尝试 wget 断点续传 (已下载 $(human_size "$resume_size"))"
            if wget -c -O "$output" "$url" 2>&1; then
                return 0
            fi
            log_warn "wget 断点续传失败"
            log_info "删除残留文件，使用 wget 全新下载"
            rm -f "$output"
        fi
        wget -O "$output" "$url" 2>&1
        return $?
    fi

    log_error "未找到下载工具 (adl, curl, wget)，请先安装其一"
    return 1
}

download_package() {
    local zip_path="$DOWNLOAD_DIR/$ZIP_FILE"
    local url current_size

    # 检测代理 (curl/wget 自动读取 http_proxy/https_proxy 环境变量)
    detect_proxy

    # 1. 完整包 → 直接使用
    if valid_zip "$zip_path"; then
        log_info "使用已有完整安装包: $zip_path ($(human_size "$(file_size "$zip_path")"))"
        return 0
    fi

    # 2. 不完整 → 尝试断点续传
    if [[ -f "$zip_path" ]]; then
        current_size=$(file_size "$zip_path")
        log_info "发现未完成的下载: $(basename "$zip_path") (已下载 $(human_size "$current_size"))，尝试断点续传"
    else
        log_info "未找到已有安装包，开始全新下载"
    fi

    # 3. 遍历镜像源，每个源先续传再全新下载
    local source_idx=1
    for url in "${DOWNLOAD_URLS[@]}"; do
        log_info "[源 ${source_idx}/${#DOWNLOAD_URLS[@]}] $url"
        if download_file "$url" "$zip_path" && valid_zip "$zip_path"; then
            log_info "下载完成: $(basename "$zip_path") ($(human_size "$(file_size "$zip_path")"))"
            return 0
        fi
        log_warn "[源 ${source_idx}] 下载失败或安装包无效"
        source_idx=$((source_idx + 1))
    done

    # 4. 所有源都失败，清理残留 + 取消代理 → 直连全新下载
    if [[ -f "$zip_path" ]]; then
        log_warn "所有镜像源续传均失败，清理残留文件后重新下载"
        rm -f "$zip_path" "$zip_path.aria2"
        unset http_proxy https_proxy
        log_info "已取消代理，使用直连重试"
        source_idx=1
        for url in "${DOWNLOAD_URLS[@]}"; do
            log_info "[全新下载 ${source_idx}/${#DOWNLOAD_URLS[@]}] $url"
            if download_file "$url" "$zip_path" && valid_zip "$zip_path"; then
                log_info "下载完成: $(basename "$zip_path") ($(human_size "$(file_size "$zip_path")"))"
                return 0
            fi
            log_warn "[全新下载 ${source_idx}] 下载失败或安装包无效"
            source_idx=$((source_idx + 1))
        done
    fi

    log_error "下载 RocketMQ 安装包失败 (所有镜像源均不可用)"
    return 1
}

assert_install_dir_safe() {
    local script_real install_real
    script_real="$(cd "$SCRIPT_DIR" && pwd -P)"
    mkdir -p "$INSTALL_DIR"
    install_real="$(cd "$INSTALL_DIR" && pwd -P)"

    case "$install_real" in
        "$script_real"|"$script_real"/*)
            log_error "拒绝安装到源脚本目录: $install_real"
            log_error "请使用 --dir 指定安装目录，例如: $HOME/rocketmq"
            exit 1
            ;;
    esac
}

extract_package() {
    local zip_path="$DOWNLOAD_DIR/$ZIP_FILE"
    local temp_dir extracted_root

    temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/rocketmq-install.XXXXXX")"

    log_info "解压安装包到临时目录: $temp_dir"
    if ! unzip -q "$zip_path" -d "$temp_dir"; then
        rm -rf "$temp_dir"
        return 1
    fi

    extracted_root="$temp_dir/$EXTRACT_DIR"
    if [[ ! -d "$extracted_root" ]]; then
        extracted_root="$(find "$temp_dir" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
    fi

    if [[ -z "$extracted_root" || ! -d "$extracted_root/bin" || ! -d "$extracted_root/conf" || ! -d "$extracted_root/lib" ]]; then
        log_error "解压后的安装包结构异常"
        rm -rf "$temp_dir"
        return 1
    fi

    if [[ "$FORCE_INSTALL" -eq 1 ]]; then
        log_warn "强制替换已有安装: $INSTALL_DIR"
        rm -rf "$INSTALL_DIR"
    elif [[ -d "$INSTALL_DIR/bin" && -d "$INSTALL_DIR/conf" && -d "$INSTALL_DIR/lib" ]]; then
        log_info "RocketMQ 已安装: $INSTALL_DIR"
        rm -rf "$temp_dir"
        return 0
    fi

    mkdir -p "$INSTALL_DIR"
    log_info "安装 RocketMQ 到: $INSTALL_DIR"
    if command_exists rsync; then
        if ! rsync -a "$extracted_root/" "$INSTALL_DIR/"; then
            rm -rf "$temp_dir"
            return 1
        fi
    else
        if ! cp -R "$extracted_root/." "$INSTALL_DIR/"; then
            rm -rf "$temp_dir"
            return 1
        fi
    fi

    if ! printf '%s\n' "$ROCKETMQ_VERSION" > "$INSTALL_DIR/.rocketmq-version"; then
        rm -rf "$temp_dir"
        return 1
    fi
    rm -rf "$temp_dir"
}

apply_custom_config_templates() {
    [[ -d "$SOURCE_CONF_DIR" ]] || return 0

    log_info "应用自定义配置模板: $SOURCE_CONF_DIR"
    mkdir -p "$INSTALL_DIR/conf"
    if command_exists rsync; then
        rsync -a "$SOURCE_CONF_DIR/" "$INSTALL_DIR/conf/"
    else
        cp -R "$SOURCE_CONF_DIR/." "$INSTALL_DIR/conf/"
    fi
}

configure_rocketmq_memory() {
    local runserver="$INSTALL_DIR/bin/runserver.sh"
    local runbroker="$INSTALL_DIR/bin/runbroker.sh"
    local timestamp sed_args=(-E)

    [[ -f "$runserver" && -f "$runbroker" ]] || { log_error "RocketMQ 启动脚本不存在: $INSTALL_DIR/bin"; return 1; }
    timestamp="$(date +%Y%m%d_%H%M%S)"
    cp -a "$runserver" "$runserver.memory-backup.$timestamp"
    cp -a "$runbroker" "$runbroker.memory-backup.$timestamp"
    [[ "$(uname -s)" != "Darwin" ]] || sed_args=(-E -i '')

    if [[ "$(uname -s)" == "Darwin" ]]; then
        sed "${sed_args[@]}" "s/-Xms[0-9]+[mMgG] -Xmx[0-9]+[mMgG]( -Xmn[0-9]+[mMgG])?/-Xms${NAMESRV_HEAP} -Xmx${NAMESRV_HEAP}/g" "$runserver"
        sed "${sed_args[@]}" "s/-Xms[0-9]+[mMgG] -Xmx[0-9]+[mMgG]/-Xms${BROKER_HEAP} -Xmx${BROKER_HEAP}/g; s/-XX:MaxDirectMemorySize=[0-9]+[mMgG]/-XX:MaxDirectMemorySize=${BROKER_DIRECT_MEMORY}/g" "$runbroker"
    else
        sed -i -E "s/-Xms[0-9]+[mMgG] -Xmx[0-9]+[mMgG]( -Xmn[0-9]+[mMgG])?/-Xms${NAMESRV_HEAP} -Xmx${NAMESRV_HEAP}/g" "$runserver"
        sed -i -E "s/-Xms[0-9]+[mMgG] -Xmx[0-9]+[mMgG]/-Xms${BROKER_HEAP} -Xmx${BROKER_HEAP}/g; s/-XX:MaxDirectMemorySize=[0-9]+[mMgG]/-XX:MaxDirectMemorySize=${BROKER_DIRECT_MEMORY}/g" "$runbroker"
    fi

    grep -q -- "-Xms${NAMESRV_HEAP} -Xmx${NAMESRV_HEAP}" "$runserver" || { log_error "NameServer 内存配置写入失败"; return 1; }
    grep -q -- "-Xms${BROKER_HEAP} -Xmx${BROKER_HEAP}" "$runbroker" || { log_error "Broker 堆配置写入失败"; return 1; }
    grep -q -- "MaxDirectMemorySize=${BROKER_DIRECT_MEMORY}" "$runbroker" || { log_error "Broker 直接内存配置写入失败"; return 1; }

    log_info "RocketMQ JVM 内存已配置: NameServer=${NAMESRV_HEAP}, Broker=${BROKER_HEAP}, DirectMemory=${BROKER_DIRECT_MEMORY}"
    log_info "重启 RocketMQ 后生效"
}

update_environment() {
    [[ "$UPDATE_ENV" -eq 1 ]] || return 0

    export ROCKETMQ_HOME="$INSTALL_DIR"
    if command_exists envs; then
        log_info "通过 envs 更新环境变量"
        envs add "ROCKETMQ_HOME=$ROCKETMQ_HOME" >/dev/null 2>&1 || true
        envs add "PATH=$ROCKETMQ_HOME/bin:\$PATH" >/dev/null 2>&1 || true
        return 0
    fi

    local shell_config="$HOME/.zshrc"
    [[ -n "${BASH_VERSION:-}" && -f "$HOME/.bashrc" ]] && shell_config="$HOME/.bashrc"

    log_info "更新环境变量到: $shell_config"
    touch "$shell_config"
    sed -i.bak '/# RocketMQ Environment/,/# End RocketMQ Environment/d' "$shell_config" 2>/dev/null || true
    cat >> "$shell_config" <<EOF
# RocketMQ Environment
export ROCKETMQ_HOME="$ROCKETMQ_HOME"
export PATH="\$ROCKETMQ_HOME/bin:\$PATH"
# End RocketMQ Environment
EOF
    rm -f "$shell_config.bak"
}

# 单机模式启动: 1 NameServer + 1 Broker (127.0.0.1)
start_standalone() {
    local install_dir="$1"
    local bin_dir="$install_dir/bin"
    local log_dir="$install_dir/logs"

    # 检查 Java 环境
    if ! command_exists java; then
        log_error "未找到 java 命令，请先安装 JDK 8+"
        log_error "可使用 java/jdk/install-jdk17.sh 安装"
        return 1
    fi

    # 检查是否已在运行
    if pgrep -f "mqnamesrv" >/dev/null 2>&1 || pgrep -f "mqbroker" >/dev/null 2>&1; then
        log_warn "检测到 RocketMQ 进程已在运行，跳过自动启动"
        pgrep -f "mqnamesrv|mqbroker" -l 2>/dev/null || true
        return 0
    fi

    # 设置 JAVA_HOME
    if [[ -z "${JAVA_HOME:-}" ]]; then
        export JAVA_HOME="$(dirname "$(dirname "$(command -v java)")")"
    fi
    log_info "JAVA_HOME: $JAVA_HOME"

    # 设置 ROCKETMQ_HOME (mqbroker 脚本依赖此变量定位 lib/conf)
    export ROCKETMQ_HOME="$install_dir"

    mkdir -p "$log_dir"

    # 启动 NameServer
    log_info "启动 NameServer (单机模式)"
    nohup "$bin_dir/mqnamesrv" > "$log_dir/namesrv.log" 2>&1 &
    local namesrv_pid=$!
    sleep 3

    if ! kill -0 "$namesrv_pid" 2>/dev/null; then
        log_error "NameServer 启动失败，查看日志: $log_dir/namesrv.log"
        return 1
    fi
    log_info "NameServer 启动成功，PID: $namesrv_pid"

    # 启动 Broker (连接本地 NameServer，自动创建 Topic)
    log_info "启动 Broker (单机模式)"
    nohup sh "$bin_dir/mqbroker" -n "127.0.0.1:9876" autoCreateTopicEnable=true > "$log_dir/broker.log" 2>&1 &
    local broker_pid=$!
    sleep 5

    if ! kill -0 "$broker_pid" 2>/dev/null; then
        log_error "Broker 启动失败，查看日志: $log_dir/broker.log"
        return 1
    fi
    log_info "Broker 启动成功，PID: $broker_pid"

    # 健康检查
    log_info "健康检查..."
    if command_exists nc; then
        if nc -z -w5 127.0.0.1 9876 2>/dev/null; then
            log_info "NameServer 端口 9876 正常"
        else
            log_warn "NameServer 端口 9876 未就绪"
        fi
        if nc -z -w5 127.0.0.1 10911 2>/dev/null; then
            log_info "Broker 端口 10911 正常"
        else
            log_warn "Broker 端口 10911 未就绪 (可能需要更多启动时间)"
        fi
    else
        log_warn "未安装 nc，跳过端口健康检查"
    fi

    log_info "RocketMQ 单机模式启动完成"
    log_info "  NameServer: 127.0.0.1:9876 (PID: $namesrv_pid)"
    log_info "  Broker:     127.0.0.1:10911 (PID: $broker_pid)"
    log_info "  日志目录: $log_dir"
    log_info "  停止命令: $SCRIPT_DIR/stop.sh --dir \"$install_dir\""
    return 0
}

install_autostart_service() {
    [[ -d "$INSTALL_DIR/bin" ]] || { log_error "RocketMQ 安装目录不存在: $INSTALL_DIR"; return 1; }
    mkdir -p "$INSTALL_DIR/bin" "$INSTALL_DIR/logs"

    local wrapper="$INSTALL_DIR/bin/rocketmq-launchd.sh"
    cat > "$wrapper" <<EOF
#!/usr/bin/env bash
export ROCKETMQ_HOME="$INSTALL_DIR"
export PATH="\$ROCKETMQ_HOME/bin:/opt/homebrew/bin:/usr/local/bin:\$PATH"
exec /bin/bash "$SCRIPT_DIR/start.sh" -d "$INSTALL_DIR" -m "$SERVICE_MODE" -y
EOF
    chmod +x "$wrapper"

    if [[ "$(uname -s)" == "Darwin" ]]; then
        local plist_dir="$HOME/Library/LaunchAgents"
        local plist_file="$plist_dir/$LAUNCHAGENT_LABEL.plist"
        local namesrv_label="$LAUNCHAGENT_LABEL.namesrv"
        local broker_label="$LAUNCHAGENT_LABEL.broker"
        local namesrv_plist="$plist_dir/$namesrv_label.plist"
        local broker_plist="$plist_dir/$broker_label.plist"
        local runtime_root="$plist_dir/runtime/$LAUNCHAGENT_LABEL"
        local runtime_bin="$runtime_root/bin"
        local runtime_conf="$runtime_root/conf"
        local runtime_lib="$runtime_root/lib"
        local runtime_logs="$runtime_root/logs"
        local runtime_jdk="$HOME/Library/LaunchAgents/runtime/shared-jdk"
        local real_install_dir java_home

        real_install_dir="$(cd "$INSTALL_DIR" && pwd -P)"
        java_home="${JAVA_HOME:-}"
        if [[ -z "$java_home" && -x "$HOME/jdk/current/bin/java" ]]; then
            java_home="$HOME/jdk/current"
        fi
        if [[ -n "$java_home" && -d "$java_home" ]]; then
            mkdir -p "$runtime_jdk"
            if command_exists rsync; then
                rsync -a --delete "$java_home/" "$runtime_jdk/"
            else
                rm -rf "$runtime_jdk"
                mkdir -p "$runtime_jdk"
                cp -R "$java_home/." "$runtime_jdk/"
            fi
            java_home="$runtime_jdk"
        fi
        [[ -d "$real_install_dir/bin" ]] || { log_error "RocketMQ bin 目录不存在: $real_install_dir/bin"; return 1; }
        [[ -d "$real_install_dir/conf" ]] || { log_error "RocketMQ conf 目录不存在: $real_install_dir/conf"; return 1; }
        [[ -d "$real_install_dir/lib" ]] || { log_error "RocketMQ lib 目录不存在: $real_install_dir/lib"; return 1; }

        mkdir -p "$plist_dir" "$runtime_bin" "$runtime_conf" "$runtime_lib" "$runtime_logs" "$runtime_root/store"
        if command_exists rsync; then
            rsync -a --delete "$real_install_dir/bin/" "$runtime_bin/"
            rsync -a --delete "$real_install_dir/conf/" "$runtime_conf/"
            rsync -a --delete "$real_install_dir/lib/" "$runtime_lib/"
        else
            rm -rf "$runtime_bin" "$runtime_conf" "$runtime_lib"
            mkdir -p "$runtime_bin" "$runtime_conf" "$runtime_lib"
            cp -R "$real_install_dir/bin/." "$runtime_bin/"
            cp -R "$real_install_dir/conf/." "$runtime_conf/"
            cp -R "$real_install_dir/lib/." "$runtime_lib/"
        fi
        if command_exists perl; then
            perl -0pi -e 's/-server -Xms4g -Xmx4g/-server \${ROCKETMQ_NAMESRV_JAVA_MEM:--Xms512m -Xmx512m}/g' "$runtime_bin/runserver.sh" 2>/dev/null || true
            perl -0pi -e 's/-server -Xms8g -Xmx8g/-server \${ROCKETMQ_BROKER_JAVA_MEM:--Xms1g -Xmx1g}/g' "$runtime_bin/runbroker.sh" 2>/dev/null || true
            perl -0pi -e 's/-XX:MaxDirectMemorySize=15g/-XX:MaxDirectMemorySize=\${ROCKETMQ_BROKER_DIRECT_MEM:-1g}/g' "$runtime_bin/runbroker.sh" 2>/dev/null || true
        fi
        launchctl bootout "gui/$(id -u)/$LAUNCHAGENT_LABEL" >/dev/null 2>&1 || true
        launchctl bootout "gui/$(id -u)/$namesrv_label" >/dev/null 2>&1 || true
        launchctl bootout "gui/$(id -u)/$broker_label" >/dev/null 2>&1 || true
        launchctl unload "$plist_file" >/dev/null 2>&1 || true
        launchctl unload "$namesrv_plist" >/dev/null 2>&1 || true
        launchctl unload "$broker_plist" >/dev/null 2>&1 || true
        rm -f "$plist_file"
        local old_pids
        old_pids="$(pgrep -f "org.apache.rocketmq.namesrv.NamesrvStartup|org.apache.rocketmq.broker.BrokerStartup" 2>/dev/null || true)"
        if [[ -n "$old_pids" ]]; then
            log_info "停止旧 RocketMQ 进程: $old_pids"
            kill $old_pids 2>/dev/null || true
            sleep 3
        fi
        cat > "$runtime_bin/rocketmq-namesrv-launchd.sh" <<EOF
#!/usr/bin/env bash
set -e
export ROCKETMQ_HOME="$runtime_root"
export PATH="${java_home:+$java_home/bin:}\$ROCKETMQ_HOME/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:\$PATH"
${java_home:+export JAVA_HOME="$java_home"}
mkdir -p "$runtime_root/logs" "$runtime_root/store"
cd "$runtime_root"
exec "$runtime_bin/mqnamesrv"
EOF
        cat > "$runtime_bin/rocketmq-broker-launchd.sh" <<EOF
#!/usr/bin/env bash
set -e
export ROCKETMQ_HOME="$runtime_root"
export PATH="${java_home:+$java_home/bin:}\$ROCKETMQ_HOME/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:\$PATH"
${java_home:+export JAVA_HOME="$java_home"}
mkdir -p "$runtime_root/logs" "$runtime_root/store"
cd "$runtime_root"
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30; do
    nc -z 127.0.0.1 9876 >/dev/null 2>&1 && break
    sleep 1
done
exec sh "$runtime_bin/mqbroker" -n "127.0.0.1:9876" autoCreateTopicEnable=true
EOF
        chmod +x "$runtime_bin/rocketmq-namesrv-launchd.sh" "$runtime_bin/rocketmq-broker-launchd.sh"
        cat > "$namesrv_plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$namesrv_label</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>$runtime_bin/rocketmq-namesrv-launchd.sh</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>$runtime_logs/namesrv.out.log</string>
    <key>StandardErrorPath</key>
    <string>$runtime_logs/namesrv.err.log</string>
    <key>WorkingDirectory</key>
    <string>$runtime_root</string>
</dict>
</plist>
EOF
        cat > "$broker_plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$broker_label</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>$runtime_bin/rocketmq-broker-launchd.sh</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>$runtime_logs/broker.out.log</string>
    <key>StandardErrorPath</key>
    <string>$runtime_logs/broker.err.log</string>
    <key>WorkingDirectory</key>
    <string>$runtime_root</string>
</dict>
</plist>
EOF
        launchctl bootstrap "gui/$(id -u)" "$namesrv_plist" 2>/dev/null || launchctl load -w "$namesrv_plist"
        launchctl enable "gui/$(id -u)/$namesrv_label" 2>/dev/null || true
        launchctl kickstart -k "gui/$(id -u)/$namesrv_label" 2>/dev/null || true
        launchctl bootstrap "gui/$(id -u)" "$broker_plist" 2>/dev/null || launchctl load -w "$broker_plist"
        launchctl enable "gui/$(id -u)/$broker_label" 2>/dev/null || true
        launchctl kickstart -k "gui/$(id -u)/$broker_label" 2>/dev/null || true
        log_info "macOS LaunchAgent 已安装: $namesrv_plist"
        log_info "macOS LaunchAgent 已安装: $broker_plist"
        return 0
    fi

    if command_exists systemctl && [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
        cat > /etc/systemd/system/rocketmq.service <<EOF
[Unit]
Description=Apache RocketMQ
After=network-online.target
Wants=network-online.target

[Service]
Type=forking
WorkingDirectory=$INSTALL_DIR
ExecStart=$wrapper
ExecStop=$SCRIPT_DIR/stop.sh --dir "$INSTALL_DIR"
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable rocketmq.service
        log_info "Linux systemd 服务已安装: /etc/systemd/system/rocketmq.service"
        return 0
    fi

    log_warn "当前系统未自动安装自启动服务；可手动执行: $wrapper"
}

uninstall_autostart_service() {
    if [[ "$(uname -s)" == "Darwin" ]]; then
        local plist_file="$HOME/Library/LaunchAgents/$LAUNCHAGENT_LABEL.plist"
        local namesrv_label="$LAUNCHAGENT_LABEL.namesrv"
        local broker_label="$LAUNCHAGENT_LABEL.broker"
        local namesrv_plist="$HOME/Library/LaunchAgents/$namesrv_label.plist"
        local broker_plist="$HOME/Library/LaunchAgents/$broker_label.plist"
        for label in "$LAUNCHAGENT_LABEL" "$namesrv_label" "$broker_label"; do
            launchctl bootout "gui/$(id -u)/$label" >/dev/null 2>&1 || true
        done
        for file in "$plist_file" "$namesrv_plist" "$broker_plist"; do
            launchctl unload "$file" >/dev/null 2>&1 || true
            rm -f "$file"
        done
        rm -rf "$HOME/Library/LaunchAgents/runtime/$LAUNCHAGENT_LABEL"
        log_info "macOS LaunchAgent 已卸载: $LAUNCHAGENT_LABEL"
        return 0
    fi

    if command_exists systemctl && [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
        systemctl disable --now rocketmq.service >/dev/null 2>&1 || true
        rm -f /etc/systemd/system/rocketmq.service
        systemctl daemon-reload
        log_info "Linux systemd 服务已卸载: rocketmq"
    fi
}

main() {
    parse_args "$@"
    assert_install_dir_safe

    if [[ "$UNINSTALL_SERVICE_ONLY" -eq 1 ]]; then
        uninstall_autostart_service
        return 0
    fi

    if [[ "$INSTALL_SERVICE_ONLY" -eq 1 ]]; then
        install_autostart_service
        return $?
    fi

    if [[ "$CONFIGURE_MEMORY_ONLY" -eq 1 ]]; then
        configure_rocketmq_memory
        return $?
    fi

    download_package
    extract_package
    apply_custom_config_templates
    if [[ "$MEMORY_CONFIG_REQUESTED" -eq 1 ]]; then
        configure_rocketmq_memory
    fi
    update_environment

    log_info "RocketMQ ${ROCKETMQ_VERSION} 安装完成"
    log_info "安装目录: $INSTALL_DIR"
    log_info "下载目录: $DOWNLOAD_DIR"

    # 自动启动单机模式
    if [[ "$AUTO_START" -eq 1 ]]; then
        log_info "自动启动 RocketMQ (单机模式)"
        start_standalone "$INSTALL_DIR" || log_warn "自动启动失败，请手动运行: $SCRIPT_DIR/start.sh -d \"$INSTALL_DIR\" -m standalone -y"
    else
        log_info "启动命令 (单机): $SCRIPT_DIR/start.sh -d \"$INSTALL_DIR\" -m standalone -y"
        log_info "启动命令 (集群): $SCRIPT_DIR/start.sh -d \"$INSTALL_DIR\" -m <standalone|1|2|3>"
    fi
    install_autostart_service || true
}

main "$@"
