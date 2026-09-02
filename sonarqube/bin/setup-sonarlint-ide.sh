#!/usr/bin/env bash
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

SONARQUBE_URL="${SONARQUBE_URL:-http://studio:9000}"
SONARQUBE_TOKEN="${SONARQUBE_TOKEN:-}"
CONNECTION_ID="${SONARQUBE_CONNECTION_ID:-studio}"
DRY_RUN=false
INSTALL_EXTENSIONS=true
CONFIGURE_SETTINGS=true

log_info() { printf '%b[INFO]%b %s\n' "$BLUE" "$NC" "$*"; }
log_ok() { printf '%b[OK]%b %s\n' "$GREEN" "$NC" "$*"; }
log_warn() { printf '%b[WARN]%b %s\n' "$YELLOW" "$NC" "$*"; }
log_error() { printf '%b[ERROR]%b %s\n' "$RED" "$NC" "$*" >&2; }

usage() {
    cat <<EOF
用法: $0 [选项]

自动发现已安装 IDE，安装 SonarLint / SonarQube for IDE 扩展，并配置 SonarQube Connected Mode。

选项:
  --url URL             SonarQube 地址，默认: ${SONARQUBE_URL}
  --token TOKEN         SonarQube 用户 token；也可用 SONARQUBE_TOKEN 环境变量
  --connection-id ID    连接名称，默认: ${CONNECTION_ID}
  --no-install          不安装 IDE 扩展，只写配置
  --no-config           只安装扩展，不写 settings.json
  --dry-run             只显示将执行的操作
  -h, --help            显示帮助

示例:
  $0 --url http://studio:9000
  SONARQUBE_TOKEN=sqp_xxx $0 --url http://studio:9000

说明:
  VS Code / Cursor / Windsurf / Trae 走 VS Code 兼容扩展机制。
  IntelliJ IDEA / Eclipse 会被发现并提示手动完成插件连接配置。
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --url)
            SONARQUBE_URL="${2:-}"
            [[ -n "$SONARQUBE_URL" ]] || { log_error "--url 需要参数"; exit 1; }
            shift 2
            ;;
        --token)
            SONARQUBE_TOKEN="${2:-}"
            [[ -n "$SONARQUBE_TOKEN" ]] || { log_error "--token 需要参数"; exit 1; }
            shift 2
            ;;
        --connection-id)
            CONNECTION_ID="${2:-}"
            [[ -n "$CONNECTION_ID" ]] || { log_error "--connection-id 需要参数"; exit 1; }
            shift 2
            ;;
        --no-install)
            INSTALL_EXTENSIONS=false
            shift
            ;;
        --no-config)
            CONFIGURE_SETTINGS=false
            shift
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            log_error "未知选项: $1"
            usage
            exit 1
            ;;
    esac
done

json_escape() {
    local value="$1"
    value=${value//\\/\\\\}
    value=${value//\"/\\\"}
    value=${value//$'\n'/\\n}
    value=${value//$'\r'/\\r}
    value=${value//$'\t'/\\t}
    printf '%s' "$value"
}

detect_vscode_like_ides() {
    local home="$HOME"

    add_ide() {
        local id="$1" name="$2" cli="$3" settings="$4"
        if [[ -x "$cli" || -d "$(dirname "$(dirname "$settings")")" || -f "$settings" ]]; then
            printf '%s\t%s\t%s\t%s\n' "$id" "$name" "$cli" "$settings"
        fi
    }

    add_ide "vscode" "Visual Studio Code" \
        "/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code" \
        "$home/Library/Application Support/Code/User/settings.json"
    add_ide "cursor" "Cursor" \
        "/Applications/Cursor.app/Contents/Resources/app/bin/code" \
        "$home/Library/Application Support/Cursor/User/settings.json"
    add_ide "windsurf" "Windsurf/Devin Desktop" \
        "/Applications/Windsurf.app/Contents/Resources/app/bin/windsurf" \
        "$home/Library/Application Support/Windsurf/User/settings.json"
    add_ide "trae" "Trae" \
        "/Applications/Trae.app/Contents/Resources/app/bin/trae" \
        "$home/Library/Application Support/Trae/User/settings.json"

    if command -v code >/dev/null 2>&1; then
        printf '%s\t%s\t%s\t%s\n' "vscode-cli" "Visual Studio Code (PATH)" "$(command -v code)" "$home/Library/Application Support/Code/User/settings.json"
    fi
    if command -v cursor >/dev/null 2>&1; then
        printf '%s\t%s\t%s\t%s\n' "cursor-cli" "Cursor (PATH)" "$(command -v cursor)" "$home/Library/Application Support/Cursor/User/settings.json"
    fi
    if command -v windsurf >/dev/null 2>&1; then
        printf '%s\t%s\t%s\t%s\n' "windsurf-cli" "Windsurf (PATH)" "$(command -v windsurf)" "$home/Library/Application Support/Windsurf/User/settings.json"
    fi
    if command -v trae >/dev/null 2>&1; then
        printf '%s\t%s\t%s\t%s\n' "trae-cli" "Trae (PATH)" "$(command -v trae)" "$home/Library/Application Support/Trae/User/settings.json"
    fi
}

install_extension() {
    local name="$1" cli="$2"

    if [[ ! -x "$cli" ]]; then
        log_warn "$name 未发现可执行 CLI，跳过扩展安装"
        return 0
    fi

    if [[ "$DRY_RUN" == true ]]; then
        log_info "[Dry-run] $cli --install-extension SonarSource.sonarlint-vscode"
        return 0
    fi

    log_info "为 $name 安装 SonarLint 扩展..."
    if "$cli" --install-extension SonarSource.sonarlint-vscode >/dev/null 2>&1; then
        log_ok "$name 扩展安装/更新完成"
    else
        log_warn "$name 扩展安装失败，请在 IDE 扩展市场搜索 SonarQube for IDE / SonarLint 手动安装"
    fi
}

write_settings() {
    local name="$1" settings_file="$2"
    local url_json token_json connection_json

    url_json=$(json_escape "$SONARQUBE_URL")
    token_json=$(json_escape "$SONARQUBE_TOKEN")
    connection_json=$(json_escape "$CONNECTION_ID")

    if [[ "$DRY_RUN" == true ]]; then
        log_info "[Dry-run] 将更新 $settings_file"
        return 0
    fi

    mkdir -p "$(dirname "$settings_file")"
    if [[ -f "$settings_file" ]]; then
        cp "$settings_file" "$settings_file.backup.$(date +%Y%m%d_%H%M%S)"
    else
        printf '{}\n' > "$settings_file"
    fi

    local tmp_file="${settings_file}.tmp.$$"
    if command -v jq >/dev/null 2>&1; then
        if [[ -n "$SONARQUBE_TOKEN" ]]; then
            jq \
                --arg id "$CONNECTION_ID" \
                --arg serverUrl "$SONARQUBE_URL" \
                --arg token "$SONARQUBE_TOKEN" \
                '
                .["sonarlint.connectedMode.connections.sonarqube"] =
                  ((.["sonarlint.connectedMode.connections.sonarqube"] // []) | map(select(.connectionId != $id)) + [{connectionId: $id, serverUrl: $serverUrl, token: $token}])
                | .["sonarlint.connectedMode.project"] = {"connectionId": $id}
                ' "$settings_file" > "$tmp_file"
        else
            jq \
                --arg id "$CONNECTION_ID" \
                --arg serverUrl "$SONARQUBE_URL" \
                '
                .["sonarlint.connectedMode.connections.sonarqube"] =
                  ((.["sonarlint.connectedMode.connections.sonarqube"] // []) | map(select(.connectionId != $id)) + [{connectionId: $id, serverUrl: $serverUrl}])
                | .["sonarlint.connectedMode.project"] = {"connectionId": $id}
                ' "$settings_file" > "$tmp_file"
        fi
        mv "$tmp_file" "$settings_file"
    else
        cat > "$settings_file" <<EOF
{
  "sonarlint.connectedMode.connections.sonarqube": [
    {
      "connectionId": "$connection_json",
      "serverUrl": "$url_json"${SONARQUBE_TOKEN:+,
      "token": "$token_json"}
    }
  ],
  "sonarlint.connectedMode.project": {
    "connectionId": "$connection_json"
  }
}
EOF
    fi

    log_ok "$name 已写入 SonarQube 连接配置: $settings_file"
}

detect_manual_ides() {
    local found=false
    for app in "/Applications/IntelliJ IDEA.app" "/Applications/Eclipse.app"; do
        if [[ -d "$app" ]]; then
            log_warn "检测到 $(basename "$app")：请在 IDE 插件市场安装 SonarQube for IDE / SonarLint，并手动添加连接 $SONARQUBE_URL"
            found=true
        fi
    done
    [[ "$found" == true ]] || true
}

main() {
    log_info "SonarQube URL: $SONARQUBE_URL"
    log_info "连接名称: $CONNECTION_ID"
    if [[ -z "$SONARQUBE_TOKEN" ]]; then
        log_warn "未提供 token：将写入基础连接配置；如 IDE 要求认证，请在 SonarQube 个人账号中生成 token 后重新运行 --token"
    fi

    local seen="" detected=false
    while IFS=$'\t' read -r id name cli settings_file; do
        [[ -n "$id" ]] || continue
        if [[ " $seen " == *" $settings_file "* ]]; then
            continue
        fi
        seen="$seen $settings_file"
        detected=true
        log_info "发现 $name"
        [[ "$INSTALL_EXTENSIONS" == true ]] && install_extension "$name" "$cli"
        [[ "$CONFIGURE_SETTINGS" == true ]] && write_settings "$name" "$settings_file"
    done < <(detect_vscode_like_ides)

    if [[ "$detected" != true ]]; then
        log_warn "未发现 VS Code 兼容 IDE"
    fi

    detect_manual_ides
    log_ok "SonarLint IDE 联动配置完成"
}

main "$@"
