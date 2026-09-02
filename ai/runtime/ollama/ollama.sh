#!/bin/bash
set -euo pipefail

# 定义下载目录变量
DOWNLOAD_DIR="${HOME}/Downloads"
MODEL_DIR="${HOME}/.ollama/models"
MODEL_NAME=${1:-}
readonly DEFAULT_MODEL="qwen3:8b"
# Ollama 0.9.5 是官方发布说明中仍支持 macOS 12 Monterey 的版本。
# 当前版本要求 macOS 14 Sonoma，因此 macOS 12/13 不应直接跟随 latest。
readonly MACOS_MIN_OLLAMA_MAJOR=12
readonly MACOS_LATEST_OLLAMA_MAJOR=14
readonly MACOS_LEGACY_OLLAMA_VERSION="v0.9.5"
readonly OLLAMA_RELEASE_API="https://api.github.com/repos/ollama/ollama/releases/latest"
# 设置环境变量
# 默认只监听本机，保证 Ollama CLI 使用同一个地址连接服务。
# 如需局域网访问，可执行：OLLAMA_HOST=0.0.0.0:11434 ./ollama.sh
export OLLAMA_HOST="${OLLAMA_HOST:-127.0.0.1:11434}"
export OLLAMA_PORT=11434
# 模型目录，默认为空。
export OLLAMA_MODELS=$MODEL_DIR
# 是否开启调试模式，默认为 false。
export OLLAMA_DEBUG=1
# 保持连接的时间，默认为 5m。
export OLLAMA_KEEP_ALIVE=24h
# 并行数，默认为 1。
export OLLAMA_NUM_PARALLEL=4
# 最大加载模型数，默认为 1。
export OLLAMA_MAX_LOADED_MODELS=2
# 调度分布，默认为空。
export OLLAMA_SCHED_SPREAD=1
# 是否闪烁注意力，默认为 true。
export OLLAMA_FLASH_ATTENTION=1
export OLLAMA_ACCELERATE=1

#OLLAMA_LLM_LIBRARY：LLM 库，默认为空。
#OLLAMA_MAX_QUEUE：最大队列数，默认为空。
#OLLAMA_MAX_VRAM：最大虚拟内存，默认为空。
#OLLAMA_NOHISTORY：是否保存历史记录，默认为 false。
#OLLAMA_NOPRUNE：是否启用剪枝，默认为 false。
#OLLAMA_ORIGINS：允许的来源，默认为空。
#OLLAMA_RUNNERS_DIR：运行器目录，默认为空。
#OLLAMA_TMPDIR：临时文件目录，默认为空。

# 检查ollama服务是否已启动
check_ollama_service() {
    # 0.0.0.0 是监听地址，不能作为客户端访问地址；同时绕过代理检查本机服务。
    local health_url="http://127.0.0.1:${OLLAMA_PORT}/api/tags"
    if curl --noproxy '*' -fsS --connect-timeout 3 "$health_url" >/dev/null 2>&1; then
        return 0
    fi
    return 1
}


# 通用下载函数（支持镜像降级）
# 参数:
#   $1 - 下载链接
#   $2 - 下载目录
#   $3 - 重试次数（可选，默认3次）
#   $4 - 超时时间（可选，默认无）
#   $5 - 文件名（可选，默认从URL提取）
# 输出:
#   0 - 下载成功
#   1 - 下载失败
download_file() {
    local url="$1"
    local download_dir="$2"
    local max_retries=${3:-3}
    local timeout_sec=${4:-30}
    local filename="${5:-$(basename "$url")}"
    
    # GitHub 镜像列表（依次尝试，直连放最后作为兜底）
    local mirrors=(
        ""  # 先尝试直连
        "https://ghproxy.com/"
        "https://mirror.ghproxy.com/"
    )
    
    # 检查是否已有代理设置
    local has_proxy=0
    for var in https_proxy http_proxy HTTPS_PROXY HTTP_PROXY; do
        eval "val=\"\${$var:-}\""
        if [ -n "$val" ]; then
            has_proxy=1
            break
        fi
    done
    
    # 创建下载目录
    mkdir -p "$download_dir"
    local download_path="$download_dir/$filename"
    
    # 检查文件是否已存在且大小正常
    if [ -f "$download_path" ] && [ -s "$download_path" ]; then
        echo "文件已存在，跳过下载: $download_path"
        return 0
    fi
    
    local start_time=$(date +%s)
    local mirror_idx=0
    
    while [ $mirror_idx -lt ${#mirrors[@]} ]; do
        local mirror="${mirrors[$mirror_idx]}"
        
        # 选择当前使用的URL（有代理/镜像就用，没有就用原始URL）
        local try_url="$url"
        if [ -n "$mirror" ]; then
            try_url="${mirror}${url}"
            echo "[镜像模式] $try_url"
        elif [ $has_proxy -eq 1 ]; then
            echo "[代理模式] $url"
        else
            echo "[直连模式] $url"
        fi
        
        echo "尝试下载 $filename (超时: ${timeout_sec}s)"
        echo "目标路径: $download_path"
        
        # 尝试下载（使用 wget，支持断点续传）
        if wget -c --no-check-certificate -q -O "$download_path" --timeout="$timeout_sec" "$try_url" 2>&1; then
            local end_time=$(date +%s)
            local duration=$((end_time - start_time))
            echo "[$(date +'%Y-%m-%d %H:%M:%S')] 下载完成: $filename"
            echo "[$(date +'%Y-%m-%d %H:%M:%S')] 下载耗时: $((duration / 60))分$((duration % 60))秒"
            return 0
        fi
        
        echo "[$(date +'%Y-%m-%d %H:%M:%S')] 下载失败，尝试下一个源..."
        rm -f "$download_path"
        mirror_idx=$((mirror_idx + 1))
    done
    
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] 所有源均下载失败"
    return 1
}

# 比较两个点分版本号，判断 $1 >= $2。
# 不依赖 macOS 没有提供的 sort -V。
version_greater_or_equal() {
    local left="${1#v}"
    local right="${2#v}"

    awk -v left="$left" -v right="$right" '
        BEGIN {
            left_count = split(left, left_parts, ".")
            right_count = split(right, right_parts, ".")
            count = left_count > right_count ? left_count : right_count
            for (i = 1; i <= count; i++) {
                l = (i <= left_count ? left_parts[i] + 0 : 0)
                r = (i <= right_count ? right_parts[i] + 0 : 0)
                if (l > r) exit 0
                if (l < r) exit 1
            }
            exit 0
        }
    '
}

# 选择 macOS 版本并解析下载地址。
# 结果通过 MACOS_OLLAMA_VERSION / MACOS_OLLAMA_URL 返回。
resolve_macos_ollama_release() {
    local detected_macos_version
    local detected_macos_major
    local requested_version="${OLLAMA_VERSION:-}"

    detected_macos_version=$(sw_vers -productVersion 2>/dev/null || true)
    detected_macos_major=$(printf '%s\n' "$detected_macos_version" | awk -F. '{print $1 + 0}')

    if [ -z "$detected_macos_version" ] || [ "$detected_macos_major" -eq 0 ]; then
        echo "无法检测 macOS 版本，已停止安装" >&2
        return 1
    fi

    if [ "$detected_macos_major" -lt "$MACOS_MIN_OLLAMA_MAJOR" ]; then
        echo "当前 macOS $detected_macos_version 低于 Ollama macOS 最低支持版本 12.0" >&2
        echo "请升级 macOS，或改用 Linux/Docker 运行 Ollama" >&2
        return 1
    fi

    if [ -n "$requested_version" ]; then
        MACOS_OLLAMA_VERSION="v${requested_version#v}"
        echo "检测到 OLLAMA_VERSION=${MACOS_OLLAMA_VERSION}，使用手动指定版本"
    elif [ "$detected_macos_major" -lt "$MACOS_LATEST_OLLAMA_MAJOR" ]; then
        echo "检测到 macOS ${detected_macos_version}，使用兼容版本 Ollama ${MACOS_LEGACY_OLLAMA_VERSION}"
        MACOS_OLLAMA_VERSION="$MACOS_LEGACY_OLLAMA_VERSION"
    else
        echo "检测到 macOS ${detected_macos_version}，获取 Ollama 最新版本"
        MACOS_OLLAMA_VERSION=""
    fi

    # macOS 14+ 默认从 GitHub API 获取最新版。
    if [ -z "$MACOS_OLLAMA_VERSION" ]; then
        local api_urls=(
            "$OLLAMA_RELEASE_API"
            "https://ghproxy.com/$OLLAMA_RELEASE_API"
        )
        local api_json=""
        local api_url
        local candidate_url
        MACOS_OLLAMA_URL=""

        for api_url in "${api_urls[@]}"; do
            echo "获取版本信息: $api_url"
            candidate_url=""
            if api_json=$(wget -q -O- --timeout=15 "$api_url" 2>/dev/null) && [ -n "$api_json" ]; then
                candidate_url=$(printf '%s' "$api_json" \
                    | grep -m1 -E '"browser_download_url"[[:space:]]*:[[:space:]]*"[^"]*Ollama-darwin\.zip"' \
                    | sed -E 's/.*"browser_download_url"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/')
                MACOS_OLLAMA_VERSION=$(printf '%s' "$api_json" \
                    | grep -m1 '"tag_name"' \
                    | sed -E 's/.*"tag_name"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/')
                if [ -n "$candidate_url" ] && [ -n "$MACOS_OLLAMA_VERSION" ]; then
                    MACOS_OLLAMA_URL="$candidate_url"
                    break
                fi
            fi
        done

        if [ -z "${MACOS_OLLAMA_URL:-}" ]; then
            echo "获取 Ollama 最新版下载地址失败" >&2
            return 1
        fi
    else
        MACOS_OLLAMA_URL="https://github.com/ollama/ollama/releases/download/${MACOS_OLLAMA_VERSION}/Ollama-darwin.zip"
    fi

    echo "选择 Ollama 版本: $MACOS_OLLAMA_VERSION"
    echo "下载地址: $MACOS_OLLAMA_URL"
}

# 在安装前检查 ZIP 中的最低系统版本，避免下载成功后才启动失败。
validate_macos_ollama_archive() {
    local archive="$1"
    local inspect_dir
    local plist_path
    local required_version
    local release_version="${MACOS_OLLAMA_VERSION:-unknown}"

    inspect_dir=$(mktemp -d "${TMPDIR:-/tmp}/ollama-archive-check.XXXXXX")
    plist_path="$inspect_dir/Ollama.app/Contents/Info.plist"

    if ! unzip -q "$archive" 'Ollama.app/Contents/Info.plist' -d "$inspect_dir" >/dev/null 2>&1; then
        rm -rf "$inspect_dir"
        echo "Ollama 安装包不是有效的 ZIP: $archive" >&2
        return 1
    fi

    required_version=$(plutil -extract LSMinimumSystemVersion raw -o - "$plist_path" 2>/dev/null || true)
    if [ -z "$required_version" ]; then
        rm -rf "$inspect_dir"
        echo "无法读取 Ollama 安装包的最低系统版本" >&2
        return 1
    fi

    if ! version_greater_or_equal "${2:-}" "$required_version"; then
        rm -rf "$inspect_dir"
        echo "Ollama $release_version 需要 macOS $required_version 或更高版本" >&2
        echo "当前系统为 macOS ${2:-未知}，请更换兼容版本或升级系统" >&2
        return 1
    fi

    echo "兼容性检查通过: macOS ${2:-未知} >= 最低要求 $required_version"
    rm -rf "$inspect_dir"
}

# 读取已安装 App 的版本。
get_installed_macos_ollama_version() {
    local plist="/Applications/Ollama.app/Contents/Info.plist"
    if [ -f "$plist" ]; then
        plutil -extract CFBundleShortVersionString raw -o - "$plist" 2>/dev/null || true
    fi
}

# App 启动时通常会创建 CLI 链接；这里补一个兜底，避免 GUI 启动成功但命令仍不可用。
ensure_macos_ollama_cli() {
    local app_cli="/Applications/Ollama.app/Contents/Resources/ollama"
    local cli_dir="/usr/local/bin"
    local cli_path="$cli_dir/ollama"

    [ -x "$app_cli" ] || return 1
    command -v ollama >/dev/null 2>&1 && return 0

    if [ -d "$cli_dir" ] && [ -w "$cli_dir" ]; then
        ln -sf "$app_cli" "$cli_path"
    elif [ -d "$cli_dir" ] && command -v sudo >/dev/null 2>&1; then
        sudo ln -sf "$app_cli" "$cli_path"
    else
        echo "未能创建 $cli_path，请手动将 Ollama CLI 加入 PATH" >&2
        return 1
    fi
    hash -r 2>/dev/null || true
    command -v ollama >/dev/null 2>&1
}

# 清理本脚本生成的旧 Ollama 安装包，不删除模型和配置。
cleanup_macos_ollama_archives() {
    local keep_archive="$1"
    local old_archive

    for old_archive in "$DOWNLOAD_DIR/Ollama-darwin.zip" "$DOWNLOAD_DIR"/Ollama-darwin-*.zip; do
        [ -f "$old_archive" ] || continue
        [ "$old_archive" = "$keep_archive" ] && continue
        rm -f "$old_archive"
        echo "已清理旧安装包: $old_archive"
    done
}

# 增强的服务启动逻辑
start_ollama_service() {
    if command -v systemctl &> /dev/null; then
        # 检查是否存着ollama服务
        if sudo systemctl status ollama.service >/dev/null 2>&1; then
            if ! sudo systemctl is-active --quiet ollama.service 2>/dev/null; then
                echo "启动ollama服务..."
                sudo systemctl start ollama.service 2>/dev/null
                sleep 5
                if sudo systemctl is-active --quiet ollama.service 2>/dev/null; then
                    echo "ollama服务已启动"
                    return 0
                else
                    echo "ollama服务启动失败"
                    return 1
                fi
            else
                echo "ollama服务已在运行"
                return 0
            fi
        fi
    fi

    # 如果 systemd 服务未找到，使用 nohup 启动
    echo "使用nohup启动ollama服务..."
    nohup ollama serve > "$HOME/ollama.log" 2>&1 &

    # 等待服务启动
    for i in {1..10}; do
        if check_ollama_service; then
            echo "ollama服务已启动"
            return 0
        fi
        sleep 1
    done

    echo "ollama服务启动失败，请查看$HOME/ollama.log了解详情"
    return 1
}

# 安装启动 ollama
start_ollama() {
    # 尝试Docker方式启动
    if command -v docker &> /dev/null; then
        if docker info > /dev/null 2>&1; then
            # 检查Ollama容器状态
            if docker ps --filter "name=ollama" --filter "status=running" | grep -q ollama; then
                echo "ollama容器已在运行"
                return 0
            fi

            # 检查是否存在已停止的ollama容器
            if docker ps -a --filter "name=ollama" | grep -q ollama; then
                echo "启动已存在的ollama容器..."
                docker start ollama && echo "ollama容器已启动" && return 0
            fi

            # 尝试使用docker-compose启动
            if command -v docker-compose &>/dev/null && [ -f "docker-compose.yml" ]; then
                echo "使用docker-compose启动ollama..."
                docker-compose up -d && echo "ollama容器已启动" && return 0
            fi
        fi
    fi
    # 主机安装
    if ! command -v ollama &> /dev/null; then
        # 判断是否是macos系统
        if [[ "$OSTYPE" == "darwin"* ]]; then
            local macos_version
            local zip_file
            local archive_path
            local installed_version

            macos_version=$(sw_vers -productVersion 2>/dev/null || true)
            if ! resolve_macos_ollama_release; then
                return 1
            fi

            # 使用带版本号的缓存文件，避免把旧的 latest ZIP 当成新版本复用。
            zip_file="Ollama-darwin-${MACOS_OLLAMA_VERSION#v}.zip"
            archive_path="$DOWNLOAD_DIR/$zip_file"

            if [ ! -f "$archive_path" ] || [ ! -s "$archive_path" ]; then
                download_file "$MACOS_OLLAMA_URL" "$DOWNLOAD_DIR" 3 60 "$zip_file" || {
                    echo "下载失败，请检查网络连接"
                    return 1
                }
            else
                echo "发现已缓存安装包: $archive_path"
            fi

            # 即使是手动指定版本，也必须以安装包实际声明的最低系统版本为准。
            if ! validate_macos_ollama_archive "$archive_path" "$macos_version"; then
                rm -f "$archive_path"
                return 1
            fi

            installed_version=$(get_installed_macos_ollama_version)
            if [ "$installed_version" != "${MACOS_OLLAMA_VERSION#v}" ]; then
                if [ -d /Applications/Ollama.app/Contents ]; then
                    echo "当前已安装 Ollama ${installed_version:-未知版本}，将替换为 Ollama ${MACOS_OLLAMA_VERSION#v}..."
                    rm -rf /Applications/Ollama.app
                else
                    echo "正在安装 Ollama ${MACOS_OLLAMA_VERSION#v}..."
                fi

                unzip -q -o "$archive_path" -d /Applications/ || {
                    echo "解压失败，请检查文件完整性"
                    return 1
                }
            else
                echo "Ollama ${installed_version} 已安装，跳过解压"
            fi

            cleanup_macos_ollama_archives "$archive_path"

            # 确保命令行可用；旧系统上 GUI 可能无法自动创建 CLI 链接。
            ensure_macos_ollama_cli || true
            if ! ollama --version >/dev/null 2>&1; then
                echo "首次启动 Ollama 应用以完成安装..."
                open /Applications/Ollama.app
                sleep 10
                ensure_macos_ollama_cli || true
            fi

            if ! command -v ollama >/dev/null 2>&1; then
                echo "Ollama CLI 未加入 PATH，请检查 /usr/local/bin/ollama" >&2
                return 1
            fi
        else
            echo "开始安装ollama..."
            # 尝试直连下载安装脚本，失败则用镜像
            install_script="${DOWNLOAD_DIR}/ollama_install.sh"
            if ! download_file "https://ollama.com/install.sh" "$DOWNLOAD_DIR" 1 15 "ollama_install.sh"; then
                echo "安装脚本下载失败，尝试镜像..."
                if ! download_file "https://ghproxy.com/https://ollama.com/install.sh" "$DOWNLOAD_DIR" 1 15 "ollama_install.sh"; then
                    download_file "https://mirror.ghproxy.com/https://ollama.com/install.sh" "$DOWNLOAD_DIR" 1 15 "ollama_install.sh"
                fi
            fi
            if [ -f "$install_script" ]; then
                chmod +x "$install_script" && sh "$install_script"
            fi
            if [ $? -ne 0 ] && ! command -v ollama &> /dev/null; then
              url=https://ollama.com/download/ollama-linux-amd64.tgz
              file_name=$(basename $url)
              echo "正在下载 $file_name..."
              if [ ! -f "$DOWNLOAD_DIR/$file_name" ]; then
                  download_file "$url" "$DOWNLOAD_DIR" 3 60 "$file_name" || {
                      echo "下载ollama-linux-amd64.tgz失败，请检查网络连接"
                      return 1
                  }
              fi
              echo "解压到/usr/local/..."
              #sudo tar -C /usr/local/ -xzf "$DOWNLOAD_DIR/$file_name"
              if ! sudo tar -C /usr/local/ -xzf "$DOWNLOAD_DIR/$file_name"; then
                  echo "解压Ollama失败，文件可能损坏"
                  rm -f "$DOWNLOAD_DIR/$file_name"
                  return 1
              fi

              # 配置环境变量
#              [Unit]
#              Description=Ollama Service
#              After=network-online.target
#
#              [Service]
#              ExecStart=/usr/local/bin/ollama serve
#              User=ollama
#              Group=ollama
#              Restart=always
#              RestartSec=3
#              Environment="PATH=/data/1-software/1-setup/1-miniconda/bin:/data/1-software/1-setup/1-miniconda/condabin:/data/1-software/1-setup/1-miniconda/bin:/usr/bin:/usr/local/bin:/usr/local/cuda/bin:/usr/bin/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/usr/games:/usr/local/games:/snap/bin"
#
#
#              Environment="OLLAMA_MODELS=/data/4-ollama-models"
#              Environment="OLLAMA_HOST=0.0.0.0:11434"
#              Environment="OLLAMA_KEEP_ALIVE=24h"
#              Environment="OLLAMA_NUM_PARALLEL=100"
#              Environment="OLLAMA_MAX_LOADED_MODELS=4"
#              Environment="OLLAMA_SCHED_SPREAD=1"
#              Environment="OLLAMA_FLASH_ATTENTION=1"
#              Environment="OLLAMA_DEBUG=1"
#              Environment="OLLAMA_ACCELERATE=1"
#
#              [Install]
#              WantedBy=default.target
            fi
        fi
    fi
    [ $? -ne 0 ] && echo "ollama安装失败，访问:https://ollama.com/download 下载安装" && exit 1

    # 即使 Ollama 已经安装，也清理本脚本之前生成的旧安装包。
    if [[ "$OSTYPE" == "darwin"* ]] && [ -d /Applications/Ollama.app/Contents ]; then
        local installed_app_version
        local keep_archive
        installed_app_version=$(get_installed_macos_ollama_version)
        if [ -n "$installed_app_version" ]; then
            keep_archive="$DOWNLOAD_DIR/Ollama-darwin-${installed_app_version}.zip"
            cleanup_macos_ollama_archives "$keep_archive"
        fi
    fi

    if command -v systemctl &> /dev/null; then
        # 检查是否存着ollama服务
        if sudo systemctl status ollama.service >/dev/null 2>&1 && ! sudo systemctl is-active --quiet ollama.service 2>/dev/null; then
	        echo "启动ollama服务..."
	        sudo systemctl start ollama.service 2>/dev/null
	        sleep 5
	    fi
    fi

    # 检查并启动ollama服务
    if ! check_ollama_service; then
        echo "正在启动ollama服务..."
        nohup ollama serve > ollama.log 2>&1 &
        # 等待服务启动
        for i in {1..10}; do
            if check_ollama_service; then
                echo "ollama服务已启动"
                return 0
            fi
            sleep 1
        done
        echo "ollama服务启动失败，请查看ollama.log了解详情"
        return 1
    fi
    return 0
}

# 检查并安装 curl
install_curl() {
    if ! command -v curl &> /dev/null; then
        echo "正在安装 curl..."
        if [[ "$OSTYPE" == "darwin"* ]]; then
            brew install curl
        elif command -v apt &> /dev/null; then
            sudo apt-get update && sudo apt-get install -y curl
        elif command -v yum &> /dev/null; then
            sudo yum install -y curl
        else
            echo "请手动安装 curl。"
            exit 1
        fi
    fi
}

# 检测系统配置并分析性能瓶颈
detect_system_config() {
    echo "[系统配置]"

    # 操作系统
    if [[ "$OSTYPE" != "darwin"* ]]; then
        local os_name=$(cat /etc/os-release 2>/dev/null | grep "^NAME=" | cut -d'"' -f2)
        echo "OS: $os_name"
    fi

    # CPU和内存
    local cpu_cores
    if [[ "$OSTYPE" == "darwin"* ]]; then
        cpu_cores=$(sysctl -n hw.ncpu 2>/dev/null || echo "未知")
    else
        cpu_cores=$(nproc 2>/dev/null || echo "未知")
    fi
    # CPU频率检测
    local cpu_freq=0
    if [ -f /proc/cpuinfo ]; then
        cpu_freq=$(grep "cpu MHz" /proc/cpuinfo 2>/dev/null | head -1 | awk '{print int($4)}')
        if [ -z "$cpu_freq" ] || [ "$cpu_freq" -eq 0 ]; then
            cpu_freq=$(grep "model name" /proc/cpuinfo 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+GHz' | head -1 | sed 's/GHz//' | awk '{print int($1*1000)}')
        fi
    fi
    if [ "$cpu_freq" -gt 0 ] 2>/dev/null; then
        local freq_ghz=$(awk "BEGIN {printf \"%.1f\", $cpu_freq/1000}" 2>/dev/null || echo "$(($cpu_freq/1000)).$(($cpu_freq%1000/100))")
        echo "CPU: $cpu_cores 核心 @ ${freq_ghz}GHz"
    else
        echo "CPU: $cpu_cores 核心"
    fi

    local mem_gb=0
    local mem_avail_gb=0
    if [[ "$OSTYPE" == "darwin"* ]]; then
        mem_gb=$(sysctl -n hw.memsize 2>/dev/null | awk '{printf "%.0f", $1/1024/1024/1024}')
        if [ -z "$mem_gb" ] || [ "$mem_gb" -eq 0 ]; then
            mem_gb=$(free -g 2>/dev/null | awk 'NR==2{print $2}' || echo "0")
        fi
        local page_size=$(sysctl -n vm.pagesize 2>/dev/null || echo "4096")
        local vm_stat=$(vm_stat 2>/dev/null)
        local pages_free=$(echo "$vm_stat" | grep "Pages free" | awk '{gsub(/[A-Za-z:.]/,""); print $1}')
        local pages_inactive=$(echo "$vm_stat" | grep "Pages inactive" | awk '{gsub(/[A-Za-z:.]/,""); print $1}')
        if [ -n "$pages_free" ] && [ -n "$pages_inactive" ] && [ -n "$page_size" ]; then
            local avail_pages=$((pages_free + pages_inactive))
            mem_avail_gb=$(echo "scale=0; $avail_pages * $page_size / 1024 / 1024 / 1024" | bc 2>/dev/null | cut -d. -f1 || echo "0")
        fi
        if [ "$mem_gb" -gt 0 ] 2>/dev/null; then
            echo "内存: ${mem_gb}GB（可用${mem_avail_gb}GB）"
        fi
    elif [ -f /proc/meminfo ]; then
        mem_gb=$(grep MemTotal /proc/meminfo | awk '{printf "%.0f", $2/1024/1024}')
        mem_avail_gb=$(grep MemAvailable /proc/meminfo 2>/dev/null | awk '{printf "%.0f", $2/1024/1024}' || echo "$mem_gb")
        echo "内存: ${mem_gb}GB（可用${mem_avail_gb}GB）"
    fi

    # Swap信息
    local swap_total_gb=0
    local swap_used_gb=0
    if [ -f /proc/meminfo ]; then
        swap_total_gb=$(grep SwapTotal /proc/meminfo | awk '{printf "%.0f", $2/1024/1024}')
        swap_used_gb=$(grep SwapFree /proc/meminfo | awk '{s=$2; getline < "/proc/meminfo"; if(/SwapTotal/) {t=$2; printf "%.1f", (t-s)/1024/1024} else printf "0"}' 2>/dev/null || echo "0")
        if [ "$swap_total_gb" -gt 0 ]; then
            echo "Swap: ${swap_total_gb}GB（已用${swap_used_gb}GB）"
        fi
    fi

    # 虚拟化检测
    local is_vm=0
    if [ -f /proc/cpuinfo ] && grep -q "flags.*hypervisor" /proc/cpuinfo 2>/dev/null; then
        echo "环境: 虚拟机"
        is_vm=1
    fi

    # GPU
    local has_gpu=0
    if command -v lspci &> /dev/null; then
        local gpu=$(lspci 2>/dev/null | grep -i "vga\|3d\|display" | head -1)
        if [[ "$gpu" == *"VMware"* ]]; then
            echo "GPU: VMware虚拟显卡（无加速）"
        elif [ -n "$gpu" ]; then
            local gpu_name=$(echo "$gpu" | cut -d: -f3-)
            echo "GPU: $gpu_name"
            if [[ "$gpu_name" == *"NVIDIA"* ]] || [[ "$gpu_name" == *"AMD"* ]] || [[ "$gpu_name" == *"Intel"* ]]; then
                has_gpu=1
            fi
        fi
    fi
    echo ""

    # 虚拟机配置建议
    if [ "$is_vm" -eq 1 ] 2>/dev/null; then
        echo ""
        echo "虚拟机优化建议:"
        # Swap建议
        local swap_suggest=4
        if [ "$mem_gb" -lt 8 ] 2>/dev/null; then
            swap_suggest=$mem_gb
        elif [ "$mem_gb" -lt 32 ] 2>/dev/null; then
            swap_suggest=$(( mem_gb / 2 ))
            if [ "$swap_suggest" -lt 4 ]; then swap_suggest=4; fi
        fi
        if [ "$swap_total_gb" -lt "$swap_suggest" ] 2>/dev/null; then
            echo "  - Swap: 当前${swap_total_gb}GB → 建议${swap_suggest}GB（内存35GB配2GBSwap过少）"
        fi
        # CPU频率建议
        if [ "$cpu_freq" -gt 0 ] 2>/dev/null && [ "$cpu_freq" -lt 2000 ]; then
            echo "  - CPU: 当前${freq_ghz}GHz偏低，虚拟机CPU频率受限，建议宿主机分配更多CPU资源"
        fi
        # 内存建议
        local model_mem_required=$(get_model_mem_requirement "$DEFAULT_MODEL")
        if [ "$mem_gb" -lt "$model_mem_required" ] 2>/dev/null; then
            echo "  - 内存: 当前${mem_gb}GB不足以运行${DEFAULT_MODEL}（推荐${model_mem_required}GB），建议扩容"
        fi
    fi

    # 性能瓶颈分析
    analyze_performance "$is_vm" "$has_gpu" "$mem_gb" "$mem_avail_gb" "$swap_used_gb" "$swap_total_gb" "$cpu_freq"
}

# 根据模型名称估算推荐内存(GB)
# 不依赖bc，将小数转换为整数比较（1.8 -> 18）
get_model_mem_requirement() {
    local model_name=$1
    local param=$(echo "$model_name" | grep -oE '[0-9]+(\.[0-9]+)?[bB]' | sed 's/[bB]//' | head -1)
    # 默认8B模型推荐16GB
    local req=16
    if [ -n "$param" ]; then
        # 将参数x10转为整数比较（1.8->18, 0.5->5, 8->80）
        local param_int=$(echo "$param * 10" | bc 2>/dev/null | cut -d. -f1)
        # bc不可用则尝试awk
        if [ -z "$param_int" ] || ! [[ "$param_int" =~ ^[0-9]+$ ]]; then
            param_int=$(awk "BEGIN {printf \"%.0f\", $param * 10}" 2>/dev/null)
        fi
        # awk也不可用则按字符串简单判断
        if [ -z "$param_int" ] || ! [[ "$param_int" =~ ^[0-9]+$ ]]; then
            # 简单字符串判断：包含小数点且第一位是0 -> <1
            if [[ "$param" == "0"* ]]; then
                param_int=5
            else
                # 取整数部分x10
                param_int=$(echo "$param" | cut -d. -f1)
                param_int=$((param_int * 10))
            fi
        fi

        if [ "$param_int" -lt 10 ]; then
            req=4   # <1B 如 0.5b
        elif [ "$param_int" -lt 40 ]; then
            req=6   # 1-3B (10-39)
        elif [ "$param_int" -lt 80 ]; then
            req=12  # 4-7B (40-79)
        elif [ "$param_int" -lt 150 ]; then
            req=16  # 8-14B (80-149)
        elif [ "$param_int" -lt 350 ]; then
            req=24  # 15-34B (150-349)
        else
            req=64  # 35B+ (>=350)
        fi
    fi
    echo $req
}

# 分析性能瓶颈并输出警告
analyze_performance() {
    local is_vm=$1
    local has_gpu=$2
    local mem_gb=$3
    local mem_avail_gb=$4
    local swap_used_gb=$5
    local swap_total_gb=$6
    local cpu_freq=$7
    local cpu_cores
    if [[ "$OSTYPE" == "darwin"* ]]; then
        cpu_cores=$(sysctl -n hw.ncpu 2>/dev/null || echo "0")
    else
        cpu_cores=$(nproc 2>/dev/null || echo "0")
    fi
    local model_mem_required=$(get_model_mem_requirement "$DEFAULT_MODEL")

    local has_issue=0
    local issues=""

    # 1. 虚拟机 + 无GPU → CPU推理性能受限
    if [ "$is_vm" -eq 1 ] && [ "$has_gpu" -eq 0 ]; then
        has_issue=1
        issues="${issues}  - 虚拟机环境无GPU加速，推理依赖虚拟化CPU性能\n"
    fi

    # 2. 内存不足（根据默认模型参数动态估算）
    if [ "$mem_avail_gb" -lt "$model_mem_required" ] 2>/dev/null; then
        has_issue=1
        issues="${issues}  - 可用内存(${mem_avail_gb}GB)不足，运行 $DEFAULT_MODEL 推荐至少 ${model_mem_required}GB 物理内存\n"
    fi

    # 3. Swap使用中 → 性能严重下降
    local swap_used_int=$(echo "$swap_used_gb" | cut -d. -f1)
    if [ "$swap_used_int" -gt 0 ] 2>/dev/null; then
        has_issue=1
        issues="${issues}  - Swap正在使用(${swap_used_gb}GB)，内存不足导致磁盘IO，推理会严重变慢\n"
    fi

    # 3.5 Swap配置检测与建议
    if [ "$mem_gb" -gt 0 ] 2>/dev/null && [ "$swap_total_gb" -gt 0 ] 2>/dev/null; then
        local ratio=$(( swap_total_gb * 100 / mem_gb ))
        if [ "$mem_gb" -lt 8 ] && [ "$ratio" -lt 100 ]; then
            echo "提示: 内存较小(${mem_gb}GB)，Swap(${swap_total_gb}GB)建议≥内存大小(1.0~1.5倍)"
        elif [ "$mem_gb" -ge 8 ] && [ "$mem_gb" -lt 32 ] && [ "$ratio" -lt 50 ]; then
            echo "提示: 当前Swap(${swap_total_gb}GB)约为内存(${mem_gb}GB)的${ratio}%，建议Swap为内存的50%~100%"
        elif [ "$mem_gb" -ge 32 ] && [ "$swap_total_gb" -lt 4 ]; then
            echo "提示: 内存充足(${mem_gb}GB)但Swap(${swap_total_gb}GB)过小，建议至少4GB用于系统应急"
        fi
    elif [ "$mem_gb" -gt 0 ] 2>/dev/null && [ "$swap_total_gb" -eq 0 ] 2>/dev/null; then
        echo "提示: 未检测到Swap。建议配置Swap以防止OOM导致进程被杀"
    fi

    # 4. 无GPU + 低核心数
    if [ "$has_gpu" -eq 0 ] && [ "$cpu_cores" -lt 4 ] 2>/dev/null; then
        has_issue=1
        issues="${issues}  - CPU核心数较少(${cpu_cores}核)且无GPU，推理速度受限\n"
    fi

    # 5. CPU频率过低（虚拟机常见）
    if [ "$cpu_freq" -gt 0 ] 2>/dev/null && [ "$cpu_freq" -lt 2000 ]; then
        has_issue=1
        local freq_ghz=$(awk "BEGIN {printf \"%.1f\", $cpu_freq/1000}" 2>/dev/null || echo "$(($cpu_freq/1000)).$(($cpu_freq%1000/100))")
        issues="${issues}  - CPU频率较低(${freq_ghz}GHz)，虚拟机CPU性能受限，推理会很慢\n"
    fi

    if [ "$has_issue" -eq 1 ]; then
        echo "⚠️ 性能警告："
        echo -e "$issues"
        echo "结论: 当前环境存在性能瓶颈，模型调用响应可能较慢。建议换用更小的模型(如qwen3:1.7b)或在物理机/带GPU环境运行。"
        echo ""
    fi
}

# 检查并安装 tmux
install_tmux() {
    if ! command -v tmux &> /dev/null; then
        echo "正在安装 tmux..."
        if [[ "$OSTYPE" == "darwin"* ]]; then
         	brew install tmux
        elif command -v apt &> /dev/null; then
            sudo apt-get update && sudo apt-get install -y tmux
        elif command -v yum &> /dev/null; then
            sudo yum install -y tmux
        else
            echo "请手动安装 tmux。"
            exit 1
        fi
    fi
}
# 通过 ModelScope 下载模型并导入 Ollama
pull_model_via_modelscope() {
    local model_full_name=$1
    local model_name=$(echo "$model_full_name" | cut -d':' -f1)
    local param_size=$(echo "$model_full_name" | cut -d':' -f2)
    local param_size_number="${param_size%[bB]}"
    
    echo "========================================"
    echo "ollama pull 失败，尝试通过 ModelScope 下载..."
    echo "========================================"
    
    # 检查并安装 modelscope
    if ! command -v ms &> /dev/null && ! python -c "import modelscope" 2>/dev/null; then
        echo "正在安装 ModelScope..."
        pip install modelscope -q
        if [ $? -ne 0 ]; then
            echo "ModelScope 安装失败，尝试 pip3..."
            pip3 install modelscope -q
        fi
    fi
    
    # 构造可能的 ModelScope 模型名称
    # Ollama 模型名如 qwen3:8b -> ModelScope 可能为 Qwen/Qwen3-8B-GGUF
    local ms_model_name=""
    case "$model_name" in
        qwen|Qwen|qwen3|Qwen3)
            ms_model_name="Qwen/Qwen3-${param_size_number}B-GGUF"
            ;;
        deepseek|DeepSeek|deepseek-r1|DeepSeek-R1)
            ms_model_name="deepseek-ai/DeepSeek-R1-GGUF"
            ;;
        llama|Llama|llama3|Llama3)
            ms_model_name="unsloth/Llama-3.3-${param_size_number}B-GGUF"
            ;;
        *)
            ms_model_name="${model_name^^}/${model_name^}-${param_size_number}B-GGUF"
            ;;
    esac
    
    echo "尝试 ModelScope 模型: $ms_model_name"
    
    # 临时目录存放下载文件
    local temp_dir="${HOME}/.ollama/ms_downloads"
    mkdir -p "$temp_dir"
    
    # 尝试下载（ModelScope CLI）
    echo "开始下载，这可能需要几分钟..."
    
    # 使用 modelscope CLI 下载
    # 格式: ms download --model <model_id> --local_dir <path>
    if python -c "
import modelscope
from modelscope.hub.api import HubApi
import os

api = HubApi()
try:
    # 获取模型文件列表
    files = api.get_model_files('$ms_model_name', recursive=True)
    gguf_files = [f for f in files if f.endswith('.gguf') or f.endswith('.ggml')]
    if gguf_files:
        print('FOUND_GGUF')
        for f in gguf_files[:3]:  # 只打印前3个
            print(f)
    else:
        print('NO_GGUF')
        for f in files[:10]:  # 打印前10个文件
            print(f)
except Exception as e:
    print(f'ERROR: {e}')
" 2>/dev/null | grep -q "FOUND_GGUF"; then
        echo "找到 GGUF 文件，准备下载..."
    else
        echo "未找到预编译的 GGUF 文件，尝试直接下载模型..."
        
        # 尝试使用 snapshot_download
        local download_path="${temp_dir}/${model_name}"
        if python -c "
from modelscope import snapshot_download
import os
try:
    cache_dir = snapshot_download('$ms_model_name', cache_dir='${temp_dir}')
    print(f'DOWNLOADED:{cache_dir}')
except Exception as e:
    print(f'FAILED:{e}')
" 2>/dev/null | grep -q "DOWNLOADED:"; then
            local downloaded_path=$(python -c "
from modelscope import snapshot_download
cache_dir = snapshot_download('$ms_model_name', cache_dir='${temp_dir}')
print(cache_dir)
" 2>/dev/null)
            echo "下载完成: $downloaded_path"
        else
            echo "ModelScope 下载也失败了"
            return 1
        fi
    fi
    
    echo "提示: ModelScope 直接下载可能需要找对应 GGUF 格式的模型"
    echo "建议手动访问 https://modelscope.cn/models/${ms_model_name} 查看"
    return 1
}

# 通过 HuggingFace 镜像下载模型并导入 Ollama
pull_model_via_huggingface() {
    local model_full_name=$1
    local model_name=$(echo "$model_full_name" | cut -d':' -f1)
    local param_size=$(echo "$model_full_name" | cut -d':' -f2)
    local param_size_number="${param_size%[bB]}"
    
    echo "========================================"
    echo "ModelScope 下载失败，尝试通过 HuggingFace 镜像..."
    echo "========================================"
    
    # 检查并安装 huggingface_hub
    if ! python -c "import huggingface_hub" 2>/dev/null; then
        echo "正在安装 huggingface_hub..."
        pip install huggingface_hub -q
    fi
    
    # HuggingFace 镜像列表
    local hf_mirrors=(
        "https://hf-mirror.com"
    )
    
    # 构造可能的 HuggingFace 模型名称
    local hf_model_name=""
    case "$model_name" in
        qwen|Qwen|qwen3|Qwen3)
            hf_model_name="Qwen/Qwen3-${param_size_number}B-GGUF"
            ;;
        deepseek|DeepSeek|deepseek-r1|DeepSeek-R1)
            hf_model_name="deepseek-ai/DeepSeek-R1-${param_size_number}B"
            ;;
        llama|Llama|llama3|Llama3)
            hf_model_name="unsloth/Llama-3.3-${param_size_number}B-GGUF"
            ;;
        *)
            hf_model_name="${model_name^}/${model_name}-${param_size_number}B-GGUF"
            ;;
    esac
    
    local temp_dir="${HOME}/.ollama/hf_downloads"
    mkdir -p "$temp_dir"
    
    # 尝试每个镜像
    local downloaded=0
    for mirror in "${hf_mirrors[@]}"; do
        echo "尝试 HuggingFace 镜像: $mirror"
        echo "模型: $hf_model_name"
        
        # 设置镜像环境变量
        export HF_ENDPOINT="$mirror"
        
        # 尝试下载 GGUF 文件
        if python -c "
from huggingface_hub import hf_hub_download, list_repo_files
import os

try:
    files = list_repo_files(repo_id='$hf_model_name', repo_type='model')
    gguf_files = [f for f in files if f.endswith('.gguf') or f.endswith('.ggml')]
    
    if gguf_files:
        print('FOUND_GGUF')
        for f in gguf_files[:5]:
            print(f)
    else:
        print('NO_GGUF')
        for f in list(files)[:10]:
            print(f)
except Exception as e:
    print(f'ERROR: {e}')
" 2>/dev/null | grep -q "FOUND_GGUF"; then
            echo "找到 GGUF 文件，准备下载..."
            
            # 获取文件列表并下载
            python -c "
from huggingface_hub import hf_hub_download, list_repo_files
import os

model_id = '$hf_model_name'
save_dir = '$temp_dir'
os.makedirs(save_dir, exist_ok=True)

files = list_repo_files(repo_id=model_id, repo_type='model')
gguf_files = [f for f in files if f.endswith('.gguf') or f.endswith('.ggml')]

for i, f in enumerate(gguf_files[:3]):  # 只下载前3个
    print(f'下载 [{i+1}/{min(3, len(gguf_files))}]: {f}')
    try:
        path = hf_hub_download(
            repo_id=model_id,
            filename=f,
            local_dir=save_dir,
            local_dir_use_symlinks=False
        )
        print(f'  完成: {path}')
    except Exception as e:
        print(f'  失败: {e}')
" 2>&1 | tee "${temp_dir}/download.log"
            
            downloaded=1
            break
        else
            echo "该镜像未找到 GGUF 文件，尝试其他方式..."
            
            # 尝试直接下载整个模型仓库
            if python -c "
from huggingface_hub import snapshot_download
import os

try:
    cache_dir = snapshot_download(
        '$hf_model_name',
        local_dir='$temp_dir/${model_name}',
        local_dir_use_symlinks=False
    )
    print(f'DOWNLOADED:{cache_dir}')
except Exception as e:
    print(f'FAILED:{e}')
" 2>/dev/null | grep -q "DOWNLOADED:"; then
                echo "模型下载完成"
                downloaded=1
                break
            fi
        fi
    done
    
    if [ $downloaded -eq 1 ]; then
        # 查找下载的 GGUF 文件
        local gguf_file=$(find "$temp_dir" -name "*.gguf" -o -name "*.ggml" 2>/dev/null | head -1)
        if [ -n "$gguf_file" ]; then
            echo "找到模型文件: $gguf_file"
            echo "创建 Modelfile 导入 Ollama..."
            
            local model_file="${temp_dir}/Modelfile"
            echo "FROM ./$(basename "$gguf_file")" > "$model_file"
            
            cd "$temp_dir" && ollama create "$model_full_name" -f Modelfile 2>&1
            if [ $? -eq 0 ]; then
                echo "HuggingFace 导入成功!"
                return 0
            fi
        fi
    fi
    
    echo "HuggingFace 镜像下载也失败了"
    return 1
}

# 在 tmux 中启动模型会话（如果尚未运行），并在需要时拉取模型
start_model_in_tmux() {
    local model_full_name=$1
    local model_name=$(echo "$model_full_name" | cut -d':' -f1)
    local param_size=$(echo "$model_full_name" | cut -d':' -f2)
    local session_name="$model_name"
    local model_command="ollama run $model_full_name"

    # 拉取模型（如果尚未存在）
    if ! ollama list | grep -v NAME | grep -q "$model_full_name"; then
        echo "正在拉取模型 $model_full_name..."
        if ollama pull "$model_full_name"; then
            echo "模型拉取成功"
        else
            echo "========================================"
            echo "ollama pull 失败 (网络超时或连接错误)"
            echo "========================================"
            echo ""
            echo "尝试降级方案..."
            echo ""
            
            # 方案1: ModelScope
            echo "[方案 1/3] 尝试 ModelScope..."
            if pull_model_via_modelscope "$model_full_name"; then
                echo "ModelScope 导入成功"
            else
                # 方案2: HuggingFace 镜像
                echo ""
                echo "[方案 2/3] ModelScope 失败，尝试 HuggingFace 镜像..."
                if pull_model_via_huggingface "$model_full_name"; then
                    echo "HuggingFace 导入成功"
                else
                    # 方案3: 提示设置代理
                    echo ""
                    echo "========================================"
                    echo "所有自动下载方案均失败"
                    echo "========================================"
                    echo ""
                    echo "请设置代理后重试:"
                    echo "  export https_proxy=http://你的代理:端口"
                    echo "  例如: export https_proxy=http://127.0.0.1:7890"
                    echo "  然后重新运行: ./startup.sh"
                    echo ""
                    return 1
                fi
            fi
        fi
    fi

    # 启动模型会话（如果尚未运行）
    if ! pgrep -f "$model_command" > /dev/null; then
        install_tmux
        tmux new-session -d -s "$session_name" "bash -c \"$model_command; exec bash\""
        echo "要连接到 $session_name 会话，请执行：tmux attach-session -t $session_name"
    fi
}


# 示例 API 调用
demo_api_call() {
    local api_url="http://127.0.0.1:${OLLAMA_PORT}/api/generate"
    local model=$(ollama list | grep -v NAME | head -n 1 | awk '{print $1}')
    echo "调用 $model 进行文本生成:"
    # ollama默认限制上下文的长度是2048 num_predict 4096
    local command_non_stream="curl -X POST $api_url -H \"Content-Type: application/json\" -d  '{\"model\": \"$model\",\"prompt\": \"天为什么那么蓝?\",\"stream\": false,\"options\": {\"num_ctx\": 32768}}'"
    echo ""
    echo "非流式测试（复制以下命令执行）:"
    echo "time $command_non_stream"
    echo ""
    
    local command_stream="curl -X POST $api_url -H \"Content-Type: application/json\" -d  '{\"model\": \"$model\",\"prompt\": \"天为什么那么蓝?\",\"stream\": true,\"options\": {\"num_ctx\": 32768}}'"
    echo "流式测试（复制以下命令执行）:"
    echo "time $command_stream"
}
get_model_version() {
    local model_name=$1
    ollama list | grep "$model_name" | awk '{print $2}'
}
check_model_exists() {
    local model_name=$1
    if ollama list | grep -v NAME | grep -q "$model_name"; then
        return 0
    else
        return 1
    fi
}
# 主程序流程
main() {
     # 检查并安装必要工具
     install_curl
     # 检测系统配置（使用 || true 避免 set -e 在检测到瓶颈时退出）
     detect_system_config || true
     # 动态安装启动ollama服务
     start_ollama
     # 显示Ollama版本
     echo "Ollama版本:"
     if command -v ollama &> /dev/null; then
         ollama --version 2>/dev/null || echo "无法获取Ollama版本"
     else
         echo "Ollama未安装"
     fi
     echo ""
     # 模型检测与用户输入处理
    local model_count=$(ollama list | grep -v NAME | wc -l)
    if [ "$model_count" -eq 0 ]; then
        echo "本地未检测到模型"
        read -t 30 -p "请输入模型名称及参数量（如qwen3:8b, deepseek-r1:8b或llama3:8b, 30秒后使用默认值${DEFAULT_MODEL}）：" MODEL_NAME
        MODEL_NAME=${MODEL_NAME:-$DEFAULT_MODEL}
    elif [ "$model_count" -eq 1 ]; then
        echo "本地已存在模型，模型列表如下："
        ollama list
        MODEL_NAME=$(ollama list | grep -v NAME | awk '{print $1}')
        echo "自动选择唯一模型: $MODEL_NAME"
    else
        echo "本地已存在模型，模型列表如下："
        ollama list
        read -t 30 -p "请输入模型名称及参数量（如qwen3:8b, deepseek-r1:8b或llama3:8b, 30秒后使用默认值${DEFAULT_MODEL}）：" MODEL_NAME
        MODEL_NAME=${MODEL_NAME:-$DEFAULT_MODEL}
    fi
    if ! check_model_exists "$MODEL_NAME"; then
        start_model_in_tmux "$MODEL_NAME"
    fi
    # 打印监听端口和进程信息
    lsof -i:11434
    ollama ps
    demo_api_call
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main
fi
