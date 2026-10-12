#!/usr/bin/env bash
#
# tts-notify - 通用语音提示工具
# 支持多 AI 工具：codex / opencode / claude-code / gemini / cursor 等
# 自动检测调用方，也可显式指定；通知失败不影响构建或自动化任务。
#
# 用法:
#   tts-notify complete [--tool <name>]      任务完成提示（自动检测 AI 工具）
#   tts-notify confirm  [--tool <name>]      需要确认提示
#   tts-notify error [--tool <name>]         执行失败提示
#   tts-notify info --text '自定义提示'      普通提示
#   tts-notify run [--tool <name>] -- cmd    包装命令并在结束后通知
#   tts-notify install                       安装共享软链接并集成文档
#   tts-notify clients                       列出已安装 AI 客户端
#   tts-notify detect                        检测当前调用方
#   tts-notify integrate [--tool <name>]     更新客户端文档
#   tts-notify --text '自定义提示' [--tool <name>]
#   tts-notify voices                         列出 edge-tts 可用语音
#   tts-notify install-espeak [--check]      安装/更新本地 espeak 引擎 (macOS/Linux)
#   tts-notify --version                      显示版本
#   tts-notify help
#
# 环境变量:
#   TTS_ENABLED=false         关闭语音提示（默认开启）
#   TTS_TOOL=<name>           指定工具名（优先级高于自动检测）
#   TTS_CALLER=<name>         客户端主动传递调用方名称
#   TTS_TOOL_GENERIC=generic  无法识别时的名称或留空
#   TTS_VOICE=<voice>         指定 edge-tts 语音（默认 zh-CN-XiaoxiaoNeural）
#   TTS_MESSAGE_COMPLETE      自定义完成消息模板，{tool} 为工具名占位
#   TTS_MESSAGE_CONFIRM       自定义确认消息模板，{tool} 为工具名占位
#   TTS_MESSAGE_ERROR         自定义失败消息模板，{tool} 为工具名占位
#   TTS_ASYNC=false           同步播放（默认后台播放）
#   TTS_MAX_TEXT=160          单次播报最大字符数
#   TTS_THROTTLE=5            连续播报最小间隔秒数（0=禁用）
#   TTS_CONCURRENCY=skip      并发模式: skip 跳过 / queue 排队 / latest 只播最新
#   TTS_QUEUE_TIMEOUT=30      queue 模式最大排队等待秒数
#   TTS_PLAY_TIMEOUT=8        单条播报超时秒数（防止引擎挂起）
#   TTS_LOCK_TIMEOUT=60       播报锁超时秒数（异常残留后自动回收）
#   TTS_FORCE_LOCAL=true      强制本地语音引擎，跳过 edge-tts（离线场景）
#   TTS_NET_TTL=30            网络检测结果缓存秒数
#   TTS_NET_TIMEOUT=3         Edge TTS 服务探测超时秒数
#   TTS_EDGE_HEALTH_URL       Edge TTS 语音列表探测地址
#   TTS_EDGE_PROXY            Edge TTS 专用代理；未设置时复用 HTTPS_PROXY/HTTP_PROXY
#   TTS_MAX_BACKUPS=3         集成文档/插件备份保留份数
#   TTS_BIN_DIR=<dir>         共享软链接目录（默认 ~/.local/bin）
#   TTS_FORCE=true            允许替换同名非本脚本软链接
#   TTS_CLIENTS="codex ..."   自定义客户端发现清单
#   TTS_VERBOSE=true          输出调试日志到 stderr

set -u -o pipefail

TTS_NOTIFY_VERSION="1.3.0"

usage() {
    printf '%s\n' \
        "用法: $0 install" \
        "      $0 clients" \
        "      $0 detect" \
        "      $0 integrate [--tool <name>]" \
        "      $0 complete [--tool <name>]" \
        "      $0 confirm [--tool <name>]" \
        "      $0 error [--tool <name>]" \
        "      $0 info --text '自定义提示' [--tool <name>]" \
        "      $0 run [--tool <name>] -- <command> [args...]" \
        "      $0 --text '自定义提示' [--tool <name>]" \
        "      $0 voices" \
        "      $0 install-espeak [--check]" \
        "      $0 --version" \
        "      $0 help" >&2
}

tts_log() {
    if [ "${TTS_VERBOSE:-false}" = "true" ]; then
        printf '%s\n' "[TTS] $1" >&2
    fi
}

# 工具名 -> 显示名
tool_display_name() {
    case "$1" in
        opencode)          echo "OpenCode" ;;
        codex)             echo "Codex" ;;
        claude|claude-code) echo "Claude Code" ;;
        gemini)            echo "Gemini" ;;
        cursor)            echo "Cursor" ;;
        qwen|tongyi)       echo "Qwen" ;;
        agy)               echo "AGY" ;;
        aider)             echo "Aider" ;;
        goose)             echo "Goose" ;;
        generic|"")        echo "" ;;
        *)                 echo "$1" ;;
    esac
}

# 工具别名规范化
normalize_tool() {
    case "$1" in
        claude-code) echo "claude" ;;
        gemini-cli) echo "gemini" ;;
        agy-cli) echo "agy" ;;
        "") echo "generic" ;;
        *) echo "$1" ;;
    esac
}

# AI 客户端命令清单；可通过 TTS_CLIENTS 覆盖，避免固定客户端范围。
client_commands() {
    case "$(normalize_tool "$1")" in
        codex) echo "codex" ;;
        opencode) echo "opencode" ;;
        agy) echo "agy agy-cli" ;;
        claude) echo "claude claude-code" ;;
        gemini) echo "gemini gemini-cli" ;;
        cursor) echo "cursor" ;;
        aider) echo "aider" ;;
        goose) echo "goose" ;;
        qwen|tongyi) echo "qwen qwen-code" ;;
        *) echo "" ;;
    esac
}

first_client_command() {
    local tool="$1" command_name
    for command_name in $(client_commands "$tool"); do
        if command -v "$command_name" >/dev/null 2>&1; then
            command -v "$command_name"
            return 0
        fi
    done
    return 1
}

tool_from_command() {
    local command_name
    command_name="$(basename "$1" 2>/dev/null || printf '%s' "$1")"
    case "$command_name" in
        codex) echo codex ;;
        opencode) echo opencode ;;
        agy|agy-cli) echo agy ;;
        claude|claude-code) echo claude ;;
        gemini|gemini-cli) echo gemini ;;
        cursor) echo cursor ;;
        aider) echo aider ;;
        goose) echo goose ;;
        qwen|qwen-code) echo qwen ;;
        *) echo "" ;;
    esac
}

# 从单条进程信息中识别 AI 客户端 (返回规范化工具名或空串)
# 策略: 1) 进程名精确匹配已知客户端二进制
#       2) 解释器场景 (node/bun/deno/python) 只匹配首个非 flag 参数,
#          并兜底匹配入口脚本路径中的客户端目录名;
#          避免 "vim ~/.codex/config" 等命令行任意位置含工具名导致的误判
tool_from_proc() {
    local first="${1%% *}"
    local name="${first##*/}"
    name="${name%.js}"
    case "$name" in
        codex) echo codex; return ;;
        opencode) echo opencode; return ;;
        agy|agy-cli) echo agy; return ;;
        claude|claude-code) echo claude; return ;;
        gemini|gemini-cli) echo gemini; return ;;
        cursor|cursor-agent) echo cursor; return ;;
        aider) echo aider; return ;;
        goose) echo goose; return ;;
        qwen|qwen-code) echo qwen; return ;;
        node|bun|deno|python|python3|python3.1*)
            local rest arg sub
            rest="${1#* }"
            for arg in $rest; do
                case "$arg" in
                    -*) continue ;;
                    *)
                        sub="$(tool_from_proc "$arg")"
                        [ -n "$sub" ] && { printf '%s\n' "$sub"; return; }
                        # 兜底: 入口脚本路径中的已知客户端目录名
                        case "$arg" in
                            *claude-code*|*@anthropic-ai/claude*|*claude/cli*|*claude.js) echo claude; return ;;
                            *opencode*) echo opencode; return ;;
                            *qwen*) echo qwen; return ;;
                        esac
                        return ;;
                esac
            done
            ;;
    esac
    echo ""
}

# 自动检测调用方；无法确定时返回 generic，不从已安装列表中猜测。
detect_tool() {
    local explicit="${REQUESTED_TOOL:-}" value pid command_line found
    if [ -n "$explicit" ] && [ "$explicit" != "auto" ]; then
        normalize_tool "$explicit"
        return 0
    fi
    for value in "${TTS_CALLER:-}" "${AI_CLIENT:-}" "${CODEX_CLI:-}" \
        "${OPENCODE_CLI:-}" "${AGY_CLI:-}" "${CLAUDE_CODE:-}"; do
        if [ -n "$value" ]; then
            normalize_tool "$value"
            return 0
        fi
    done
    pid="${PPID:-0}"
    while [ "${pid:-0}" -gt 1 ] 2>/dev/null; do
        command_line="$(ps -o command= -p "$pid" 2>/dev/null || true)"
        [ -n "$command_line" ] || break
        found="$(tool_from_proc "$command_line")"
        if [ -n "$found" ]; then
            printf '%s\n' "$found"
            return 0
        fi
        pid="$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ' || true)"
    done
    printf '%s\n' "${TTS_TOOL_GENERIC:-generic}"
}

discover_clients() {
    local list="${TTS_CLIENTS:-codex opencode agy claude gemini cursor aider goose}"
    local tool binary
    for tool in $list; do
        if binary="$(first_client_command "$tool" 2>/dev/null)"; then
            printf '%s\t%s\t%s\n' "$tool" "$(tool_display_name "$tool")" "$binary"
        fi
    done
}

show_clients() {
    local found=0 line
    printf '%s\n' "已发现的 AI 客户端："
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        found=1
        printf '  %s\n' "$line"
    done <<EOF
$(discover_clients)
EOF
    if [ "$found" -eq 0 ]; then
        printf '%s\n' "  未发现已知客户端（可通过 --tool 显式指定名称）"
    fi
}

# 解析脚本真实路径，保证从软链接调用 install 时链接到源脚本。
resolve_script_path() {
    local path="$1" dir link
    case "$path" in
        /*) ;;
        *) path="$PWD/$path" ;;
    esac
    while [ -L "$path" ]; do
        dir="$(cd -P "$(dirname "$path")" 2>/dev/null && pwd)" || return 1
        link="$(readlink "$path" 2>/dev/null)" || return 1
        case "$link" in
            /*) path="$link" ;;
            *) path="$dir/$link" ;;
        esac
    done
    dir="$(cd -P "$(dirname "$path")" 2>/dev/null && pwd)" || return 1
    printf '%s/%s\n' "$dir" "$(basename "$path")"
}

install_shared_link() {
    local bin_dir="${TTS_BIN_DIR:-$HOME/.local/bin}" link target existing
    bin_dir="${bin_dir%/}"
    link="$bin_dir/tts-notify"
    target="$(resolve_script_path "${BASH_SOURCE[0]}")" || return 1
    mkdir -p "$bin_dir" || return 1

    if [ -L "$link" ]; then
        existing="$(resolve_script_path "$link" 2>/dev/null || true)"
        [ "$existing" = "$target" ] && {
            printf '%s\n' "[TTS] 共享软链接已存在：$link"
            return 0
        }
    elif [ -e "$link" ] && [ "${TTS_FORCE:-false}" != "true" ]; then
        printf '%s\n' "[TTS] 未覆盖已有文件：$link（设置 TTS_FORCE=true 后重试）" >&2
        return 1
    fi
    if [ -e "$link" ] || [ -L "$link" ]; then rm -f "$link" || return 1; fi
    ln -s "$target" "$link" || return 1
    printf '%s\n' "[TTS] 已创建共享软链接：$link -> $target"
    case ":${PATH:-}:" in
        *:"$bin_dir":*) ;;
        *) printf '%s\n' "[TTS] 如命令未找到，请执行：export PATH=\"$bin_dir:\$PATH\"" ;;
    esac
}

doc_path_for_tool() {
    local tool="$(normalize_tool "$1")" candidate
    case "$tool" in
        codex) printf '%s\n' "${TTS_DOC_CODEX:-$HOME/.codex/AGENTS.md}" ;;
        opencode)
            if [ -n "${TTS_DOC_OPENCODE:-}" ]; then
                printf '%s\n' "$TTS_DOC_OPENCODE"
            else
                for candidate in "$HOME/.config/opencode/AGENTS.md" "$HOME/.opencode/AGENTS.md"; do
                    if [ -f "$candidate" ]; then printf '%s\n' "$candidate"; return; fi
                done
                printf '%s\n' "$HOME/.local/share/tts-notify/integrations/opencode.md"
            fi
            ;;
        agy)
            if [ -n "${TTS_DOC_AGY:-}" ]; then
                printf '%s\n' "$TTS_DOC_AGY"
            else
                for candidate in "$HOME/.agy/AGENTS.md" "$HOME/.config/agy/AGENTS.md"; do
                    if [ -f "$candidate" ]; then printf '%s\n' "$candidate"; return; fi
                done
                printf '%s\n' "$HOME/.local/share/tts-notify/integrations/agy.md"
            fi
            ;;
        *) printf '%s\n' "$HOME/.local/share/tts-notify/integrations/$tool.md" ;;
    esac
}

write_integration_block() {
    local tool="$1" display
    display="$(tool_display_name "$tool")"
    cat <<EOF
## 语音通知

\`\`\`bash
# 任务完成时
tts-notify complete
# 等待用户确认时
tts-notify confirm
# 任务失败时
tts-notify error
\`\`\`
EOF
}

# 备份并轮转: 每次更新前备份，仅保留最近 TTS_MAX_BACKUPS 份，避免 .bak 无限累积
rotate_backup() {
    local file="$1" max="${TTS_MAX_BACKUPS:-3}" bak old
    [ -f "$file" ] || return 0
    bak="$file.bak.$(date +%Y%m%d_%H%M%S)"
    cp -p "$file" "$bak" 2>/dev/null || true
    # 删除超出保留份数的旧备份 (按名称时间戳倒序，保留最近 max 份)
    while IFS= read -r old; do
        [ -n "$old" ] && rm -f "$old" 2>/dev/null || true
    done < <(ls -1t "$file.bak."* 2>/dev/null | tail -n "+$((max + 1))")
}

upsert_integration_doc() {
    local doc="$1" tool="$2" tmp
    mkdir -p "$(dirname "$doc")" || return 1
    tmp="$(mktemp "$doc.tmp.XXXXXX")" || return 1
    if [ -f "$doc" ]; then
        rotate_backup "$doc"
        # 删除旧集成块 (支持连续多个块; 块内子标题不会中断删除)，其余内容保留到 tmp
        awk -v h="## 语音通知" -v hh="## $(tool_display_name "$tool") 语音通知" '
            $0 == h || $0 == hh { skip=1; next }
            skip { if ($0 ~ /^## /) skip=0 }
            !skip { print }
        ' "$doc" > "$tmp" || { rm -f "$tmp"; return 1; }
    fi
    printf '\n' >> "$tmp"
    write_integration_block "$tool" >> "$tmp"
    mv "$tmp" "$doc" || { rm -f "$tmp"; return 1; }
    printf '%s\n' "[TTS] 已更新客户端文档：$doc"
}

integrate_one_client() {
    local tool="$(normalize_tool "$1")" doc
    if ! first_client_command "$tool" >/dev/null 2>&1; then
        printf '%s\n' "[TTS] 跳过未安装客户端：$tool" >&2
        return 0
    fi
    doc="$(doc_path_for_tool "$tool")"
    upsert_integration_doc "$doc" "$tool"
    if [ "$tool" = "codex" ]; then
        install_codex_hooks
    fi
    if [ "$tool" = "opencode" ]; then
        install_opencode_tts_plugin
    fi
}

integrate_clients() {
    local selected="${1:-}" tool
    if [ -n "$selected" ]; then integrate_one_client "$selected"; return; fi
    while IFS=$'\t' read -r tool _display _binary; do
        [ -n "$tool" ] && integrate_one_client "$tool"
    done <<EOF
$(discover_clients)
EOF
}

install_codex_hooks() {
    local hooks_file="${TTS_CODEX_HOOKS:-$HOME/.codex/hooks.json}"
    local notify_bin tmp stop_cmd confirm_cmd
    if ! command -v jq >/dev/null 2>&1; then
        printf '%s\n' '[TTS] 未找到 jq，跳过自动写入 Codex hooks.json' >&2
        return 0
    fi
    notify_bin="${TTS_NOTIFY_BIN:-$HOME/.local/bin/tts-notify}"
    if [ ! -x "$notify_bin" ]; then
        notify_bin="$(resolve_script_path "${BASH_SOURCE[0]}")" || return 1
    fi
    mkdir -p "$(dirname "$hooks_file")" || return 1
    tmp="$(mktemp "$hooks_file.tmp.XXXXXX")" || return 1
    stop_cmd="\"$notify_bin\" complete --tool codex"
    confirm_cmd="\"$notify_bin\" confirm --tool codex"

    if [ -f "$hooks_file" ]; then
        jq --arg stop_cmd "$stop_cmd" --arg confirm_cmd "$confirm_cmd" '
            def without_tts:
              map(select(any(.hooks[]?; ((.command // "") | contains("tts-notify"))) | not));
            .hooks = (.hooks // {})
            | .hooks.Stop = (((.hooks.Stop // []) | without_tts) + [{
                "hooks": [{
                    "type": "command",
                    "command": $stop_cmd,
                    "timeout": 3,
                    "async": true,
                    "statusMessage": "语音播报任务完成"
                }]
            }])
            | .hooks.PermissionRequest = (((.hooks.PermissionRequest // []) | without_tts) + [{
                "hooks": [{
                    "type": "command",
                    "command": $confirm_cmd,
                    "timeout": 3,
                    "async": true,
                    "statusMessage": "语音提示需要确认"
                }]
            }])
        ' "$hooks_file" > "$tmp" || { rm -f "$tmp"; return 1; }
    else
        jq -n --arg stop_cmd "$stop_cmd" --arg confirm_cmd "$confirm_cmd" '
            {
              "hooks": {
                "Stop": [{"hooks": [{"type": "command", "command": $stop_cmd, "timeout": 3, "async": true, "statusMessage": "语音播报任务完成"}]}],
                "PermissionRequest": [{"hooks": [{"type": "command", "command": $confirm_cmd, "timeout": 3, "async": true, "statusMessage": "语音提示需要确认"}]}]
              }
            }
        ' > "$tmp" || { rm -f "$tmp"; return 1; }
    fi

    if [ -f "$hooks_file" ] && cmp -s "$hooks_file" "$tmp"; then
        rm -f "$tmp"
        printf '%s\n' "[TTS] Codex TTS Hook 已存在：$hooks_file"
        return 0
    fi
    if [ -f "$hooks_file" ]; then
        rotate_backup "$hooks_file"
    fi
    mv "$tmp" "$hooks_file" || { rm -f "$tmp"; return 1; }
    printf '%s\n' "[TTS] 已配置 Codex 完成/确认 Hook：$hooks_file"
}

# 创建或更新 OpenCode 全局插件（等价于 Codex hooks）：
#   session.idle        回合结束     -> tts-notify complete
#   permission.asked    请求确认     -> tts-notify confirm
#   session.error       会话失败     -> tts-notify error
# 文件已存在且内容一致时跳过；内容变化时备份旧文件后更新。
install_opencode_tts_plugin() {
    local plugins_file="${TTS_OPENCODE_PLUGINS:-$HOME/.config/opencode/plugins/tts-notify.js}"
    local notify_bin jbin content tmp
    notify_bin="${TTS_NOTIFY_BIN:-$HOME/.local/bin/tts-notify}"
    if [ ! -x "$notify_bin" ]; then
        notify_bin="$(resolve_script_path "${BASH_SOURCE[0]}")" || return 1
    fi
    # 转义为 JS 双引号字符串字面量（\ -> \\, " -> \"）
    jbin="${notify_bin//\\/\\\\}"
    jbin="${jbin//\"/\\\"}"
    content="$(cat <<'PLUGIN_EOF'
export const TtsNotify = async ({ $ }) => {
  const bin = "__TTS_NOTIFY_BIN__"
  return {
    event: async ({ event }) => {
      if (event.type === "session.idle") {
        await $`${bin} complete --tool opencode`
      }
      if (event.type === "permission.asked") {
        await $`${bin} confirm --tool opencode`
      }
      if (event.type === "session.error") {
        await $`${bin} error --tool opencode`
      }
    },
  }
}
PLUGIN_EOF
)"
    content="${content//__TTS_NOTIFY_BIN__/$jbin}"
    mkdir -p "$(dirname "$plugins_file")" || return 1
    tmp="$(mktemp "$plugins_file.tmp.XXXXXX")" || return 1
    printf '%s\n' "$content" > "$tmp" || { rm -f "$tmp"; return 1; }
    if [ -f "$plugins_file" ] && cmp -s "$plugins_file" "$tmp"; then
        rm -f "$tmp"
        printf '%s\n' "[TTS] OpenCode TTS 插件已存在，无需更新：$plugins_file"
        return 0
    fi
    if [ -f "$plugins_file" ]; then
        rotate_backup "$plugins_file"
    fi
    mv "$tmp" "$plugins_file" || { rm -f "$tmp"; return 1; }
    printf '%s\n' "[TTS] 已写入 OpenCode TTS 插件：$plugins_file"
}

# 解析最终播报消息
resolve_message() {
    local tool="$1"
    local display="" msg=""

    display="$(tool_display_name "$tool")"

    case "$MESSAGE" in
        __COMPLETE__)
            if [ -n "${TTS_MESSAGE_COMPLETE:-}" ]; then
                msg="$TTS_MESSAGE_COMPLETE"
            elif [ -n "$display" ]; then
                msg="${display}任务已完成，请查看结果"
            else
                msg="任务已完成，请查看结果"
            fi
            ;;
        __CONFIRM__)
            if [ -n "${TTS_MESSAGE_CONFIRM:-}" ]; then
                msg="$TTS_MESSAGE_CONFIRM"
            elif [ -n "$display" ]; then
                msg="${display}需要您的确认，请查看终端"
            else
                msg="需要您的确认，请查看终端"
            fi
            ;;
        __ERROR__)
            if [ -n "${TTS_MESSAGE_ERROR:-}" ]; then
                msg="$TTS_MESSAGE_ERROR"
            elif [ -n "$display" ]; then
                msg="${display}任务执行失败，请查看终端"
            else
                msg="任务执行失败，请查看终端"
            fi
            ;;
        *)
            msg="$MESSAGE"
            ;;
    esac

    # 自定义模板中的 {tool} 占位符替换
    if [ -n "$display" ]; then
        msg="${msg//\{tool\}/$display}"
    else
        msg="${msg//\{tool\}/}"
    fi

    msg="$(printf '%s' "$msg" | tr '\r\n' '  ' | sed -E 's/(token|password|passwd|secret|api[-_]?key|cookie)[=:][[:space:]]*[^[:space:]]+/\1=[REDACTED]/gI' | cut -c1-"${TTS_MAX_TEXT:-160}")"
    printf '%s\n' "$msg"
}

# edge-tts 语音名 -> macOS say 语音名 (无映射时用系统默认)
say_voice_for() {
    local voice="${TTS_VOICE:-zh-CN-XiaoxiaoNeural}"
    case "$voice" in
        zh-CN-*) echo "Tingting" ;;
        zh-TW-*) echo "Meijia" ;;
        zh-HK-*) echo "Sin-ji" ;;
        en-US-*|en-GB-*) echo "Samantha" ;;
        ja-*) echo "Kyoko" ;;
        ko-*) echo "Yuna" ;;
        fr-*) echo "Amelie" ;;
        de-*) echo "Anna" ;;
        es-*) echo "Diego" ;;
        *) echo "" ;;
    esac
}

# 网络可用性检测（带缓存）：离线时跳过 edge-tts 直接用本地引擎，避免连接超时干等。
# TTS_FORCE_LOCAL=true 时强制本地引擎，跳过网络检测。
# 缓存文件单行格式: "<epoch> online|offline"
net_available() {
    local cache="${TMPDIR:-/tmp}/tts-notify.net" now last state http_code
    local health_url="${TTS_EDGE_HEALTH_URL:-https://speech.platform.bing.com/consumer/speech/synthesize/readaloud/voices/list}"
    [ "${TTS_FORCE_LOCAL:-false}" = "true" ] && return 1
    if [ -f "$cache" ]; then
        read -r last state < "$cache" 2>/dev/null || { last=0; state=offline; }
        case "$last" in (*[!0-9]*|"") last=0 ;; esac
        now="$(date +%s)"
        # 缓存窗口内直接复用上次结果
        if [ $((now - last)) -lt "${TTS_NET_TTL:-30}" ] 2>/dev/null; then
            [ "$state" = "online" ] && return 0 || return 1
        fi
    fi
    # 探测 edge-tts 实际使用的语音服务地址，而不是只探测域名根路径。
    # 401/403/404 仍表示网络已连到服务端；只有 000 代表 DNS/代理/连接失败。
    http_code="$(curl --connect-timeout "${TTS_NET_TIMEOUT:-3}" \
        --max-time "${TTS_NET_TIMEOUT:-3}" -sS -o /dev/null \
        -w '%{http_code}' "$health_url" 2>/dev/null || printf '000')"
    if [ "$http_code" != "000" ] && [ -n "$http_code" ]; then
        printf '%s online\n' "$(date +%s)" > "$cache" 2>/dev/null || true
        return 0
    fi
    printf '%s offline\n' "$(date +%s)" > "$cache" 2>/dev/null || true
    return 1
}

# 单条文本的实际播放（edge-tts+play -> macOS say -> Linux espeak 回退，失败不影响退出码）
# 播放均带超时保护：防止引擎/网络挂起导致锁被永久占用
# 离线或 TTS_FORCE_LOCAL=true 时跳过 edge-tts，直达本地引擎
play_tts_once() {
    local text="$1" voice="${TTS_VOICE:-zh-CN-XiaoxiaoNeural}"
    local timeout="${TTS_PLAY_TIMEOUT:-8}" p0
    local edge_proxy="${TTS_EDGE_PROXY:-${HTTPS_PROXY:-${https_proxy:-${HTTP_PROXY:-${http_proxy:-}}}}}"
    local -a edge_args=(--voice "$voice" --text "$text")
    if [ -n "$edge_proxy" ]; then
        edge_args+=(--proxy "$edge_proxy")
    fi
    tts_log "说明: $text"

    # 1) edge-tts + play（需在线；PIPESTATUS 校验 edge-tts 退出码，防止假成功）
    if command -v edge-tts >/dev/null 2>&1 && command -v play >/dev/null 2>&1 \
        && net_available; then
        perl -e 'alarm shift; exec @ARGV' "$timeout" edge-tts "${edge_args[@]}" 2>/dev/null \
            | play -q -t mp3 - >/dev/null 2>&1
        p0="${PIPESTATUS[0]}"
        if [ "$p0" -eq 0 ]; then
            tts_log "使用 edge-tts + play"
            return 0
        fi
        tts_log "edge-tts 播放失败，回退本地引擎"
    elif [ "${TTS_FORCE_LOCAL:-false}" = "true" ]; then
        tts_log "TTS_FORCE_LOCAL=true，跳过 edge-tts 使用本地引擎"
    elif ! net_available; then
        tts_log "当前离线，使用本地语音引擎"
    fi

    # 2) macOS 内置 say（优先使用与 TTS_VOICE 对应的中文语音）
    if command -v say >/dev/null 2>&1; then
        local say_voice
        say_voice="$(say_voice_for)"
        tts_log "使用 macOS say${say_voice:+ (voice=$say_voice)}"
        if [ -n "$say_voice" ]; then
            perl -e 'alarm shift; exec @ARGV' "$timeout" say -v "$say_voice" "$text" >/dev/null 2>&1 \
                || perl -e 'alarm shift; exec @ARGV' "$timeout" say "$text" >/dev/null 2>&1
        else
            perl -e 'alarm shift; exec @ARGV' "$timeout" say "$text" >/dev/null 2>&1
        fi
        return 0
    fi

    # 3) Linux espeak / espeak-ng（espeak-ng 优先，兼容 espeak 参数）
    local espeak_bin=""
    command -v espeak-ng >/dev/null 2>&1 && espeak_bin="$(command -v espeak-ng)"
    if [ -z "$espeak_bin" ]; then
        command -v espeak >/dev/null 2>&1 && espeak_bin="$(command -v espeak)"
    fi
    if [ -n "$espeak_bin" ]; then
        tts_log "使用 espeak ($espeak_bin)"
        perl -e 'alarm shift; exec @ARGV' "$timeout" "$espeak_bin" -v zh "$text" >/dev/null 2>&1 || true
        return 0
    fi

    printf '%s\n' "[TTS] 未找到可用 TTS 引擎，跳过语音提示: $text" >&2
    return 0
}

# 抢锁；锁目录内含 owner 文件记录持有时间，超过 TTS_LOCK_TIMEOUT 视为过期锁，强制回收
acquire_lock() {
    local lock_root="$1" now created
    if mkdir "$lock_root" 2>/dev/null; then
        printf '%s %s\n' "$$" "$(date +%s)" > "$lock_root/owner" 2>/dev/null
        return 0
    fi
    # 锁已存在：检查是否过期
    if [ -f "$lock_root/owner" ]; then
        created="$(awk '{print $2}' "$lock_root/owner" 2>/dev/null || echo 0)"
        now="$(date +%s)"
        if [ $((now - created)) -gt "${TTS_LOCK_TIMEOUT:-60}" ] 2>/dev/null; then
            tts_log "检测到过期锁（超过 ${TTS_LOCK_TIMEOUT:-60}s），强制回收"
            rm -rf "$lock_root" 2>/dev/null || true
            if mkdir "$lock_root" 2>/dev/null; then
                printf '%s %s\n' "$$" "$(date +%s)" > "$lock_root/owner" 2>/dev/null
                return 0
            fi
        fi
    fi
    return 1
}

# 语音播报（按优先级回退，失败不影响退出码）
# 并发控制: 通过 mkdir 原子锁防止多个通知同时播放而叠加;
# TTS_CONCURRENCY 决定已有播报进行中时的行为:
#   skip   (默认) 跳过本次播报
#   queue          排队等待, 按顺序播报 (最多等 TTS_QUEUE_TIMEOUT 秒)
#   latest         不等待: 记录为最新待播通知 (覆盖旧待播), 当前播报结束后立即接续
# 锁老化: 锁被异常中断残留超过 TTS_LOCK_TIMEOUT 秒时自动回收，避免永久静音
tts_speak_sync() {
    local text="$1" mode="${TTS_CONCURRENCY:-skip}"
    local lock_root="${TMPDIR:-/tmp}/tts-notify.play.lock"
    local waited current next

    # 抢占锁：失败说明已有播报进行中，按模式处理
    if ! acquire_lock "$lock_root"; then
        case "$mode" in
            queue)
                tts_log "已有播报进行中，排队等待（最多 ${TTS_QUEUE_TIMEOUT:-30}s）"
                waited=0
                while [ "$waited" -lt $(( ${TTS_QUEUE_TIMEOUT:-30} * 2 )) ]; do
                    sleep 0.5
                    acquire_lock "$lock_root" && break
                    waited=$((waited + 1))
                done
                acquire_lock "$lock_root" || {
                    tts_log "排队超时，跳过本次播报"
                    return 0
                }
                ;;
            latest)
                printf '%s\n' "$text" > "$lock_root/pending" 2>/dev/null || return 0
                tts_log "已有播报进行中，已记录为最新通知，播报结束后接续"
                return 0
                ;;
            *) # skip (默认)
                tts_log "已有语音播报进行中，跳过本次播报"
                return 0
                ;;
        esac
    fi
    (
        # 锁目录内含 owner/pending 文件，必须 rm -rf 而非 rmdir 才能完整释放
        trap 'rm -rf "${TMPDIR:-/tmp}/tts-notify.play.lock" 2>/dev/null || true' EXIT
        current="$text"
        while :; do
            # 续期锁时间戳，避免正常播放被其他调用者当作过期锁回收
            printf '%s %s\n' "$$" "$(date +%s)" > "$lock_root/owner" 2>/dev/null
            play_tts_once "$current"
            next=""
            if [ -f "$lock_root/pending" ]; then
                next="$(cat "$lock_root/pending" 2>/dev/null || true)"
                rm -f "$lock_root/pending"
            fi
            [ -n "$next" ] || break
            current="$next"
            tts_log "接续播报最新通知"
        done
    )
    return 0
}

# 默认后台播放，避免通知阻塞 AI 客户端；需要严格等待时传 --sync。
# 异步子 shell 仅吞 stdout，保留 stderr 供 TTS_VERBOSE 调试（默认无输出）。
tts_speak() {
    local text="$1"
    if [ "${TTS_ASYNC:-true}" = "true" ]; then
        (tts_speak_sync "$text") >/dev/null &
    else
        tts_speak_sync "$text"
    fi
    return 0
}

notify_current() {
    local throttle_file now last
    if [ "${TTS_ENABLED:-true}" = "false" ]; then
        tts_log "TTS_ENABLED=false，跳过语音播报"
        return 0
    fi
    # 节流: 距上次播报不足 TTS_THROTTLE 秒则跳过 (0 = 不节流)
    if [ "${TTS_THROTTLE:-5}" -gt 0 ] 2>/dev/null; then
        throttle_file="${TMPDIR:-/tmp}/tts-notify.last"
        now="$(date +%s)"
        if [ -f "$throttle_file" ]; then
            last="$(cat "$throttle_file" 2>/dev/null || echo 0)"
            case "$last" in (*[!0-9]*|"") last=0 ;; esac
            if [ $((now - last)) -lt "${TTS_THROTTLE:-5}" ]; then
                tts_log "距上次播报不足 ${TTS_THROTTLE:-5}s，跳过本次播报"
                return 0
            fi
        fi
        printf '%s\n' "$now" > "$throttle_file"
    fi
    TOOL_FINAL="$(detect_tool)"
    TTS_MSG="$(resolve_message "$TOOL_FINAL")"
    tts_speak "$TTS_MSG"
}

run_wrapped_command() {
    local tool="auto" rc detected
    while [ $# -gt 0 ]; do
        case "$1" in
            --tool)
                [ $# -ge 2 ] || { printf '%s\n' "--tool 缺少参数" >&2; return 2; }
                if [ -z "$2" ] || [ "$2" = "--" ]; then
                    printf '%s\n' "--tool 参数无效: $2（工具名不能为空或为 --）" >&2
                    return 2
                fi
                tool="$2"
                shift 2
                ;;
            --)
                shift
                break
                ;;
            *)
                break
                ;;
        esac
    done
    [ $# -gt 0 ] || { printf '%s\n' "run 需要 -- 后的命令" >&2; return 2; }
    if [ "$tool" = "auto" ]; then
        detected="$(tool_from_command "$1")"
        tool="${detected:-generic}"
    fi
    "$@"
    rc=$?
    REQUESTED_TOOL="$tool"
    if [ "$rc" -eq 0 ]; then
        MESSAGE="__COMPLETE__"
    else
        MESSAGE="__ERROR__"
    fi
    notify_current
    return "$rc"
}

parse_event_args() {
    local event="$1"
    shift
    REQUESTED_TOOL="${TTS_TOOL:-auto}"
    case "$event" in
        complete) MESSAGE="__COMPLETE__" ;;
        confirm) MESSAGE="__CONFIRM__" ;;
        error) MESSAGE="__ERROR__" ;;
        info) MESSAGE="__INFO__" ;;
    esac
    while [ $# -gt 0 ]; do
        case "$1" in
            --tool)
                [ $# -ge 2 ] || { printf '%s\n' "--tool 缺少参数" >&2; return 2; }
                REQUESTED_TOOL="$2"
                shift 2
                ;;
            --text)
                [ $# -ge 2 ] || { printf '%s\n' "--text 缺少参数" >&2; return 2; }
                MESSAGE="$2"
                shift 2
                ;;
            --voice)
                [ $# -ge 2 ] || { printf '%s\n' "--voice 缺少参数" >&2; return 2; }
                TTS_VOICE="$2"
                shift 2
                ;;
            --sync)
                TTS_ASYNC=false
                shift
                ;;
            *)
                printf '%s\n' "未知参数：$1" >&2
                return 2
                ;;
        esac
    done
    if [ "$event" = "info" ] && [ "$MESSAGE" = "__INFO__" ]; then
        printf '%s\n' "info 必须提供 --text" >&2
        return 2
    fi
    notify_current
}

list_voices() {
    if ! command -v edge-tts >/dev/null 2>&1; then
        printf '%s\n' "[TTS] 未找到 edge-tts，无法列出语音" >&2
        return 0
    fi
    edge-tts --list-voices
}

main() {
    local command="${1:-help}" selected=""
    shift 2>/dev/null || true
    case "$command" in
        install|setup)
            install_shared_link || return 1
            integrate_clients
            show_clients
            ;;
        clients)
            show_clients
            ;;
        detect)
            selected="$(detect_tool)"
            printf '%s\t%s\n' "$selected" "$(tool_display_name "$selected")"
            ;;
        integrate)
            if [ "${1:-}" = "--tool" ] && [ $# -ge 2 ]; then
                selected="$2"
            elif [ $# -gt 0 ]; then
                printf '%s\n' "integrate 仅支持 --tool <name>" >&2
                return 2
            fi
            integrate_clients "$selected"
            ;;
        voices)
            list_voices
            ;;
        run)
            run_wrapped_command "$@"
            ;;
        complete|confirm|error|info)
            parse_event_args "$command" "$@"
            ;;
        --text)
            [ $# -gt 0 ] || { printf '%s\n' "--text 缺少参数" >&2; return 2; }
            MESSAGE="$1"
            shift
            REQUESTED_TOOL="${TTS_TOOL:-auto}"
            while [ $# -gt 0 ]; do
                case "$1" in
                    --tool)
                        [ $# -ge 2 ] || { printf '%s\n' "--tool 缺少参数" >&2; return 2; }
                        REQUESTED_TOOL="$2"
                        shift 2
                        ;;
                    --voice)
                        [ $# -ge 2 ] || { printf '%s\n' "--voice 缺少参数" >&2; return 2; }
                        TTS_VOICE="$2"
                        shift 2
                        ;;
                    --sync)
                        TTS_ASYNC=false
                        shift
                        ;;
                    *)
                        printf '%s\n' "未知参数：$1" >&2
                        return 2
                        ;;
                esac
            done
            notify_current
            ;;
        version|--version|-v)
            printf '%s\n' "tts-notify $TTS_NOTIFY_VERSION"
            ;;
        install-espeak|setup-espeak)
            # 跨平台 espeak 一键安装/更新 (macOS Homebrew / Linux 各包管理器)
            local espeak_script
            espeak_script="$(dirname "$(resolve_script_path "${BASH_SOURCE[0]}")")/install-espeak.sh"
            if [ -x "$espeak_script" ]; then
                "$espeak_script" "$@"
            else
                printf '%s\n' "未找到 install-espeak.sh（应位于 $espeak_script）" >&2
                return 1
            fi
            ;;
        help|--help|-h)
            usage
            ;;
        *)
            usage
            return 2
            ;;
    esac
}

main "$@"
