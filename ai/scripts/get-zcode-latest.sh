#!/usr/bin/env bash
#
# get-zcode-latest.sh
# 获取 ZCode 最新版本号，通过 CDN 探测确定。
#
# 用法:
#   ./get-zcode-latest.sh              # 输出版本号 (如 3.1.3)
#   ./get-zcode-latest.sh --url mac-arm64   # 输出完整下载 URL
#   ./get-zcode-latest.sh --url mac-x64     # Intel Mac
#   ./get-zcode-latest.sh --url win-x64     # Windows
#   ./get-zcode-latest.sh --json            # 输出 JSON 格式 (供 ai-hub 消费)
#
# 工作原理:
#   ZCode CDN 地址格式: https://cdn.zcode-ai.com/zcode/electron/releases/${VER}/ZCode-${VER}-mac-${ARCH}.dmg
#   从高版本向下探测，首个 HTTP 200 即为最新版本。
#

set -euo pipefail

CDN_BASE="https://cdn.zcode-ai.com/zcode/electron/releases"
CURL_OPTS="--connect-timeout 3 --max-time 5"

# 安全 curl，永远不会因超时导致脚本退出
safe_curl() {
    curl -s ${CURL_OPTS} "$@" 2>/dev/null || true
}

# 从官网文档页面抓取版本号作为探测起点
fetch_hint_version() {
    local hint
    # 优先从缓存文件读取，避免每次请求官网
    local cache_file="${HOME}/.cache/ai-hub/zcode_version_hint"
    if [[ -f "$cache_file" ]] && [[ $(find "$cache_file" -mmin -60 2>/dev/null) ]]; then
        hint=$(cat "$cache_file" 2>/dev/null || true)
        if [[ -n "$hint" ]]; then
            echo "$hint"
            return 0
        fi
    fi

    # 尝试从官网文档抓取
    hint=$(safe_curl "https://zcode.z.ai/cn/docs/install" \
        | grep -oP 'ZCode-\K[0-9]+\.[0-9]+\.[0-9]+' \
        | head -1 || true)
    if [[ -z "$hint" ]]; then
        hint=$(safe_curl "https://zcode.z.ai" \
            | grep -oP 'releases/\K[0-9]+\.[0-9]+\.[0-9]+' \
            | head -1 || true)
    fi

    # 如果官网获取失败，使用硬编码的已知版本作为起点
    hint="${hint:-3.3.0}"

    # 缓存 hint
    mkdir -p "$(dirname "$cache_file")" 2>/dev/null || true
    echo "$hint" > "$cache_file" 2>/dev/null || true

    echo "$hint"
}

# 探测指定版本是否存在 (返回 HTTP 状态码)
probe_version() {
    local ver="$1" arch="$2"
    local code
    code=$(curl -s ${CURL_OPTS} -o /dev/null -w '%{http_code}' \
        "${CDN_BASE}/${ver}/ZCode-${ver}-${arch}.dmg" 2>/dev/null) || true
    echo "${code:-000}"
}

# 获取最新版本号
get_latest_version() {
    local hint arch="${1:-mac-arm64}"
    hint=$(fetch_hint_version)

    # 解析 hint 版本号
    local major minor patch
    IFS='.' read -r major minor patch <<< "$hint"

    # 从 hint 版本向上探测
    local ver
    for v in "${major}.${minor}.$((patch + 2))" "${major}.${minor}.$((patch + 1))" "${major}.${minor}.${patch}" "${major}.${minor}.$((patch - 1))" "${major}.${minor}.$((patch - 2))"; do
        local code
        code=$(probe_version "$v" "$arch")
        if [[ "$code" == "200" ]]; then
            echo "$v"
            return 0
        fi
    done

    # 如果 hint 附近都找不到，扩大范围搜索
    for p in $(seq $((patch + 3)) 1 $((patch - 5)) | sort -rn); do
        [[ $p -lt 0 ]] && continue
        local code
        code=$(probe_version "${major}.${minor}.${p}" "$arch")
        if [[ "$code" == "200" ]]; then
            echo "${major}.${minor}.${p}"
            return 0
        fi
    done

    # 兜底：返回 hint 版本
    echo "$hint" >&2
    echo "$hint"
}

# 获取下载 URL
get_download_url() {
    local arch="${1:-mac-arm64}"
    local ver os_ext

    ver=$(get_latest_version "$arch")

    case "$arch" in
        mac-arm64|mac-x64)
            echo "${CDN_BASE}/${ver}/ZCode-${ver}-${arch}.dmg"
            ;;
        win-x64|win-arm64)
            echo "${CDN_BASE}/${ver}/ZCode-${ver}-${arch}.exe"
            ;;
        *)
            echo "错误: 不支持的架构: $arch" >&2
            echo "支持的架构: mac-arm64, mac-x64, win-x64, win-arm64" >&2
            exit 1
            ;;
    esac
}

# 输出 JSON 格式
output_json() {
    local arch ver_arm64 ver_x64 ver_win url_arm64 url_x64 url_win
    arch=$(uname -m | grep -q arm && echo 'arm64' || echo 'x64')

    ver_arm64=$(get_latest_version "mac-arm64")
    ver_x64=$(get_latest_version "mac-x64")
    ver_win=$(get_latest_version "win-x64")

    url_arm64="${CDN_BASE}/${ver_arm64}/ZCode-${ver_arm64}-mac-arm64.dmg"
    url_x64="${CDN_BASE}/${ver_x64}/ZCode-${ver_x64}-mac-x64.dmg"
    url_win="${CDN_BASE}/${ver_win}/ZCode-${ver_win}-win-x64.exe"

    cat <<JSONEOF
{
  "latest_version": "${ver_arm64}",
  "current_arch": "${arch}",
  "downloads": {
    "mac-arm64": { "version": "${ver_arm64}", "url": "${url_arm64}" },
    "mac-x64":   { "version": "${ver_x64}",   "url": "${url_x64}" },
    "win-x64":   { "version": "${ver_win}",   "url": "${url_win}" }
  }
}
JSONEOF
}

# 主入口
case "${1:-}" in
    --url)
        get_download_url "${2:-mac-arm64}"
        ;;
    --json)
        output_json
        ;;
    --version|-v)
        get_latest_version "${2:-mac-arm64}"
        ;;
    -h|--help)
        cat <<EOF
用法: $0 [选项] [架构]

选项:
  --url [ARCH]        输出完整下载 URL
  --json              输出 JSON 格式 (所有平台)
  --version [ARCH]    输出版本号
  -h, --help          显示帮助

架构 (默认: mac-arm64):
  mac-arm64, mac-x64, win-x64, win-arm64

示例:
  $0                            # 输出版本号
  $0 --url mac-arm64            # 输出 Apple Silicon 下载 URL
  $0 --json                     # 输出 JSON 格式
  \$($0 --url)                  # 在脚本中获取下载 URL
EOF
        ;;
    *)
        get_latest_version "${1:-mac-arm64}"
        ;;
esac