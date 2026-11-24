#!/usr/bin/env bash
#
# setup-ai-provider.sh
# Configure a Codex CLI provider in an isolated CODEX_HOME.
#
# Custom providers are written to ~/.codex-<provider> so Codex Desktop can keep
# using the default ~/.codex official account without auth.json conflicts.
#

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

DEFAULT_CODEX_DIR="${HOME}/.codex"
ZSHRC="${HOME}/.zshrc"
BASHRC="${HOME}/.bashrc"

DEFAULT_MODEL="gpt-5.5"
DEFAULT_REASONING_EFFORT="high"
DEFAULT_WIRE_API="responses"
DEFAULT_OFFICIAL_BASE_URL="https://api.openai.com/v1"
DEFAULT_CLIENTS="codex"
DEFAULT_CONTEXT_WINDOW="32768"
DEFAULT_MAX_INPUT_TOKENS=""
DEFAULT_MAX_OUTPUT_TOKENS="8192"
DEFAULT_AIDER_TIMEOUT_SECONDS="180"
DEFAULT_AIDER_MAX_CHAT_HISTORY_TOKENS="12000"
DEFAULT_QWEN_TIMEOUT_MS="180000"
DEFAULT_HERMES_PROVIDER="openai-api"

info() {
    printf '%b[INFO]%b %s\n' "$BLUE" "$NC" "$1"
}

success() {
    printf '%b[OK]%b %s\n' "$GREEN" "$NC" "$1"
}

warn() {
    printf '%b[WARN]%b %s\n' "$YELLOW" "$NC" "$1"
}

error() {
    printf '%b[ERROR]%b %s\n' "$RED" "$NC" "$1" >&2
}

usage() {
    cat <<EOF
用法:
  $0 [选项]

选项:
  -p, --provider NAME       Provider 名称；默认从 base_url 的域名主体提取
  -k, --api-key KEY         API Key；不推荐在命令行传真实 key，优先交互输入
  --api-key-env NAME        写入 shell rc 管理块的密钥变量名；默认: API_KEY_<PROVIDER>
  -b, --base-url URL        请求基础地址；默认: ${DEFAULT_OFFICIAL_BASE_URL}
  -m, --model MODEL         模型名称；默认: ${DEFAULT_MODEL}
  --reasoning-effort VALUE  reasoning effort；默认: ${DEFAULT_REASONING_EFFORT}
  --wire-api VALUE          wire_api；默认: ${DEFAULT_WIRE_API}
  --codex-home DIR          自定义 CODEX_HOME；默认: ~/.codex-<provider>
  --clients LIST            生成哪些客户端 wrapper；默认: ${DEFAULT_CLIENTS}
                            可选值: codex,claude,aider,qwen,hermes，用逗号分隔
  --no-prefix               函数名不加 client 前缀，直接用 provider 名称
                            （仅单 client 时推荐；多 client 会函数名冲突）
  --claude-base-url URL     Claude Code 使用的 ANTHROPIC_BASE_URL；
                            默认从 base_url 去掉结尾 /v1
  --context-window TOKENS   Aider/Qwen 使用的上下文窗口；默认: ${DEFAULT_CONTEXT_WINDOW}
  --max-input-tokens TOKENS Aider 最大输入 tokens；默认与 --context-window 相同
  --max-output-tokens TOKENS
                            Aider/Qwen 默认最大输出 tokens；默认: ${DEFAULT_MAX_OUTPUT_TOKENS}
  --aider-timeout SECONDS   Aider 请求超时秒数；默认: ${DEFAULT_AIDER_TIMEOUT_SECONDS}
  --aider-max-chat-history-tokens TOKENS
                            Aider 历史上限；默认: ${DEFAULT_AIDER_MAX_CHAT_HISTORY_TOKENS}
  --aider-metadata-file FILE
                            Aider 模型元数据文件；默认: ~/.aider.model.metadata.json
  --aider-settings-file FILE
                            Aider 模型设置文件；默认: ~/.aider.model.settings.yml
  --qwen-home DIR           Qwen Code 隔离配置目录；默认: ~/.qwen-<provider>
  --qwen-timeout-ms MS      Qwen Code 请求超时毫秒数；默认: ${DEFAULT_QWEN_TIMEOUT_MS}
  --hermes-provider VALUE   Hermes Agent model.provider；默认: ${DEFAULT_HERMES_PROVIDER}
                            NVIDIA 官方接口使用: nvidia
  --auto-discover           自动发现本机/局域网 OpenAI-compatible 服务并补齐缺省参数
  --no-auto-discover        跳过自动发现，缺少参数时进入交互输入
  -y, --yes                 非交互确认应用配置
  -r, --remove [NAME]       移除 shell wrapper；不会删除 ~/.codex-<provider>
  --archive                 与 --remove 搭配，将 ~/.codex-<provider> 归档重命名
  -s, --show [NAME]         脱敏显示配置；指定 NAME 时显示 ~/.codex-NAME
  -h, --help                显示帮助

示例:
  $0 -p token173 -k sk-xxx -b https://token173.com/v1 -m hermes
  $0 -p nvidia --clients hermes --hermes-provider nvidia \\
     -b https://integrate.api.nvidia.com/v1 -m deepseek-ai/deepseek-v4
  $0                         # 自动发现本机/局域网模型服务
  $0 --auto-discover
  $0 -b https://token173.com/v1
  $0 -s token173
  $0 -r token173
  $0 -r token173 --archive

说明:
  自定义 provider 不会修改 ~/.codex/config.toml 或 ~/.codex/auth.json。
  API Key 和 provider 环境变量直接写入 shell rc 的 ai-provider 管理块。
  配置阶段会写入 ~/.codex-<provider>/auth.json；生成的 codex-<provider>
  函数只通过 CODEX_HOME=~/.codex-<provider> 启动 Codex。
  生成的 claude-<provider> 函数只在进程环境中设置 ANTHROPIC_API_KEY
  和 ANTHROPIC_BASE_URL，不会写入 ~/.claude。
EOF
}

mask_secret() {
    local secret="$1"
    local length=${#secret}

    if [[ -z "$secret" ]]; then
        printf '(empty)'
    elif (( length <= 12 )); then
        printf '****'
    else
        printf '%s****%s' "${secret:0:6}" "${secret: -4}"
    fi
}

toml_escape() {
    local value="$1"
    value=${value//\\/\\\\}
    value=${value//\"/\\\"}
    value=${value//$'\t'/\\t}
    value=${value//$'\r'/\\r}
    value=${value//$'\n'/\\n}
    printf '%s' "$value"
}

json_escape() {
    local value="$1"
    value=${value//\\/\\\\}
    value=${value//\"/\\\"}
    value=${value//$'\t'/\\t}
    value=${value//$'\r'/\\r}
    value=${value//$'\n'/\\n}
    printf '%s' "$value"
}

shell_quote() {
    local value="$1"
    printf "'%s'" "${value//\'/\'\\\'\'}"
}

shell_double_quote() {
    local value="$1"
    value=${value//\\/\\\\}
    value=${value//\"/\\\"}
    value=${value//$'\t'/\\t}
    value=${value//$'\r'/\\r}
    value=${value//$'\n'/\\n}
    printf '"%s"' "$value"
}

strip_trailing_slashes() {
    local path="$1"

    while [[ "$path" != "/" && "$path" == */ ]]; do
        path="${path%/}"
    done
    printf '%s' "$path"
}

expand_home_path() {
    local path="$1"

    case "$path" in
        "~")
            path="$HOME"
            ;;
        "~/"*)
            path="${HOME}/${path#"~/"}"
            ;;
        '$HOME')
            path="$HOME"
            ;;
        '$HOME/'*)
            path="${HOME}/${path#"\$HOME/"}"
            ;;
        "\$HOME")
            path="$HOME"
            ;;
        "\$HOME/"*)
            path="${HOME}/${path#"\$HOME/"}"
            ;;
    esac

    strip_trailing_slashes "$path"
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

slugify_provider_name() {
    local raw="$1"
    local slug

    slug=$(printf '%s' "$raw" \
        | tr '[:upper:]' '[:lower:]' \
        | sed -E 's/[^a-z0-9_-]+/-/g; s/^-+//; s/-+$//; s/-+/-/g')

    printf '%s' "${slug:-custom}"
}

validate_provider_name() {
    local provider_name="$1"

    if [[ ! "$provider_name" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        error "Provider 名称只能包含字母、数字、下划线和连字符: $provider_name"
        exit 1
    fi
}

validate_key_env() {
    local key_env="$1"

    if [[ ! "$key_env" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]]; then
        error "API Key 环境变量名不合法: $key_env"
        exit 1
    fi
}

validate_clients() {
    local clients="$1"
    local client
    local normalized
    local -a client_list
    normalized="${clients//[[:space:]]/}"

    if [[ -z "$normalized" ]]; then
        error "clients 不能为空"
        exit 1
    fi

    IFS=',' read -r -a client_list <<< "$normalized"
    for client in "${client_list[@]}"; do
        case "$client" in
            codex|claude|aider|qwen|hermes)
                ;;
            *)
                error "不支持的 client: $client；可选值: codex, claude, aider, qwen, hermes"
                exit 1
                ;;
        esac
    done
}

validate_hermes_provider() {
    local hermes_provider="$1"

    if [[ ! "$hermes_provider" =~ ^[a-zA-Z0-9_.-]+$ ]]; then
        error "Hermes provider 名称不合法: $hermes_provider"
        exit 1
    fi
}

client_enabled() {
    local clients="$1"
    local target="$2"
    local client
    local normalized
    local -a client_list
    normalized="${clients//[[:space:]]/}"

    IFS=',' read -r -a client_list <<< "$normalized"
    for client in "${client_list[@]}"; do
        [[ "$client" == "$target" ]] && return 0
    done
    return 1
}

extract_provider_name() {
    local url="$1"
    local host labels_count
    local -a labels

    host="${url#https://}"
    host="${host#http://}"
    host="${host#*@}"
    host="${host%%/*}"
    host="${host%%:*}"
    host="${host#www.}"

    IFS='.' read -r -a labels <<< "$host"
    labels_count=${#labels[@]}

    if (( labels_count >= 3 )) && [[ "${labels[0]}" =~ ^(api|gateway|openai|llm|models)$ ]]; then
        printf '%s\n' "${labels[1]}"
    elif (( labels_count >= 1 )); then
        printf '%s\n' "${labels[0]}"
    else
        printf 'custom\n'
    fi
}

provider_home_for() {
    local provider_name="$1"
    local home_suffix="$provider_name"

    if [[ "$home_suffix" == codex-* || "$home_suffix" == codex_* ]]; then
        home_suffix="${home_suffix#codex[-_]}"
    fi

    printf '%s/.codex-%s' "$HOME" "$home_suffix"
}

assert_safe_codex_home() {
    local codex_home="$1"
    local safe_home default_home

    safe_home=$(expand_home_path "$codex_home")
    default_home=$(expand_home_path "$DEFAULT_CODEX_DIR")

    if [[ -z "$safe_home" || "$safe_home" == "/" || "$safe_home" == "$HOME" ]]; then
        error "拒绝使用危险 CODEX_HOME: ${codex_home}"
        exit 1
    fi

    if [[ "$safe_home" == "$default_home" ]]; then
        error "拒绝写入默认 CODEX_HOME: ${DEFAULT_CODEX_DIR}"
        error "Codex App 使用默认 ~/.codex；自定义 Codex CLI provider 必须使用隔离目录，例如 ~/.codex-token173。"
        exit 1
    fi
}

key_env_for() {
    local provider_name="$1"
    local suffix
    suffix=$(printf '%s' "$provider_name" | tr '[:lower:]-' '[:upper:]_')
    printf 'API_KEY_%s' "$suffix"
}

provider_env_prefix_for() {
    local provider_name="$1"
    local suffix
    suffix=$(printf '%s' "$provider_name" | tr '[:lower:]-' '[:upper:]_')
    printf 'AI_%s' "$suffix"
}

claude_base_url_for() {
    local base_url="$1"
    local claude_base_url
    claude_base_url="${base_url%/}"

    if [[ "$claude_base_url" == */v1 ]]; then
        claude_base_url="${claude_base_url%/v1}"
    fi

    printf '%s' "$claude_base_url"
}

qwen_home_for() {
    local provider_name="$1"
    printf '%s/.qwen-%s' "$HOME" "$provider_name"
}

qwen_home_expr_for() {
    local provider_name="$1"
    local qwen_home="$2"
    local default_home
    qwen_home=$(expand_home_path "$qwen_home")
    default_home=$(qwen_home_for "$provider_name")

    if [[ "$qwen_home" == "$default_home" ]]; then
        printf '"$HOME/.qwen-%s"' "$provider_name"
    else
        home_path_expr_for "$qwen_home"
    fi
}

home_path_expr_for() {
    local path="$1"

    if [[ "$path" == "$HOME"/* ]]; then
        printf '"$HOME/%s"' "${path#"$HOME"/}"
    else
        shell_double_quote "$path"
    fi
}

codex_home_expr_for() {
    local provider_name="$1"
    local codex_home="$2"
    local default_home
    codex_home=$(expand_home_path "$codex_home")
    default_home=$(provider_home_for "$provider_name")

    if [[ "$codex_home" == "$default_home" ]]; then
        home_path_expr_for "$default_home"
    else
        home_path_expr_for "$codex_home"
    fi
}

detect_shell() {
    if [[ -n "${ZSH_VERSION:-}" ]] || [[ "${SHELL:-}" == */zsh ]]; then
        printf 'zsh\n'
    elif [[ -n "${BASH_VERSION:-}" ]] || [[ "${SHELL:-}" == */bash ]]; then
        printf 'bash\n'
    else
        printf 'unknown\n'
    fi
}

get_rc_file() {
    local shell_type="$1"

    case "$shell_type" in
        zsh)
            printf '%s\n' "$ZSHRC"
            ;;
        bash)
            printf '%s\n' "$BASHRC"
            ;;
        *)
            if [[ -f "$ZSHRC" ]]; then
                printf '%s\n' "$ZSHRC"
            elif [[ -f "$BASHRC" ]]; then
                printf '%s\n' "$BASHRC"
            else
                printf '%s\n' "$ZSHRC"
            fi
            ;;
    esac
}

generate_config_toml() {
    local provider_name="$1"
    local base_url="$2"
    local model="$3"
    local reasoning_effort="$4"
    local wire_api="$5"
    local project_dir="${6:-}"

    local provider_name_toml base_url_toml model_toml reasoning_toml wire_api_toml
    provider_name_toml=$(toml_escape "$provider_name")
    base_url_toml=$(toml_escape "$base_url")
    model_toml=$(toml_escape "$model")
    reasoning_toml=$(toml_escape "$reasoning_effort")
    wire_api_toml=$(toml_escape "$wire_api")

    cat <<EOF
model_provider = "${provider_name_toml}"
model = "${model_toml}"
model_reasoning_effort = "${reasoning_toml}"
disable_response_storage = true
personality = "pragmatic"

[model_providers.${provider_name}]
name = "${provider_name_toml}"
base_url = "${base_url_toml}"
wire_api = "${wire_api_toml}"
requires_openai_auth = false
EOF

    if [[ -n "$project_dir" ]]; then
        local project_dir_toml
        project_dir_toml=$(toml_escape "$project_dir")
        cat <<EOF

[projects."${project_dir_toml}"]
trust_level = "trusted"
EOF
    fi
}

generate_auth_json() {
    local api_key="$1"
    local api_key_json
    api_key_json=$(json_escape "$api_key")

    cat <<EOF
{
  "auth_mode": "apikey",
  "OPENAI_API_KEY": "${api_key_json}"
}
EOF
}

ensure_custom_home() {
    local codex_home="$1"

    assert_safe_codex_home "$codex_home"
    mkdir -p "$codex_home" "$codex_home/log"
    chmod 700 "$codex_home"
}

write_custom_config() {
    local codex_home="$1"
    local provider_name="$2"
    local base_url="$3"
    local model="$4"
    local reasoning_effort="$5"
    local wire_api="$6"
    local project_dir="$7"

    local config_file="${codex_home}/config.toml"
    local tmp_file="${config_file}.tmp.$$"
    local backup_file
    local project_dir_toml current_project_section

    project_dir_toml=$(toml_escape "$project_dir")
    current_project_section="[projects.\"${project_dir_toml}\"]"

    generate_config_toml "$provider_name" "$base_url" "$model" "$reasoning_effort" "$wire_api" "$project_dir" > "$tmp_file"
    if [[ -f "$config_file" ]]; then
        awk -v current_project="$current_project_section" '
            function starts_section(line) { return line ~ /^\[/ }
            function starts_project(line) { return line ~ /^\[projects\."/ }
            function starts_mcp(line) { return line ~ /^\[mcp_servers\./ }
            function starts_tui(line) { return line ~ /^\[tui\./ }

            starts_section($0) {
                keep = (starts_project($0) && $0 != current_project) || starts_mcp($0) || starts_tui($0)
                pending_blank = 0
                if (keep) {
                    print ""
                    print
                }
                next
            }

            keep {
                if ($0 == "") {
                    pending_blank = 1
                    next
                }
                if (pending_blank) {
                    print ""
                    pending_blank = 0
                }
                print
            }
        ' "$config_file" >> "$tmp_file"
    fi
    chmod 600 "$tmp_file"

    if [[ -f "$config_file" ]] && cmp -s "$tmp_file" "$config_file"; then
        rm -f "$tmp_file"
        success "配置文件未变化: $config_file"
        return
    fi

    if [[ -f "$config_file" ]]; then
        backup_file="${config_file}.backup.$(date +%Y%m%d_%H%M%S)"
        cp "$config_file" "$backup_file"
        info "备份旧配置: $backup_file"
    fi

    mv "$tmp_file" "$config_file"
    success "写入配置文件: $config_file"
}

write_custom_auth() {
    local codex_home="$1"
    local api_key="$2"

    local auth_file="${codex_home}/auth.json"
    local tmp_file="${auth_file}.tmp.$$"
    local backup_file

    generate_auth_json "$api_key" > "$tmp_file"
    chmod 600 "$tmp_file"

    if [[ -f "$auth_file" ]] && cmp -s "$tmp_file" "$auth_file"; then
        rm -f "$tmp_file"
        success "认证文件未变化: $auth_file"
        return
    fi

    if [[ -f "$auth_file" ]]; then
        backup_file="${auth_file}.backup.$(date +%Y%m%d_%H%M%S)"
        cp "$auth_file" "$backup_file"
        info "备份旧认证文件: $backup_file"
    fi

    mv "$tmp_file" "$auth_file"
    success "写入认证文件: $auth_file"
}

write_aider_config() {
    local model="$1"
    local context_window="$2"
    local max_input_tokens="$3"
    local max_output_tokens="$4"
    local metadata_file="$5"
    local settings_file="$6"

    local metadata_dir settings_dir tmp_file model_key
    model_key="openai/${model}"
    metadata_dir=$(dirname "$metadata_file")
    settings_dir=$(dirname "$settings_file")
    mkdir -p "$metadata_dir" "$settings_dir"

    tmp_file="${metadata_file}.tmp.$$"
    if [[ -f "$metadata_file" ]]; then
        jq \
            --arg model_key "$model_key" \
            --argjson context_window "$context_window" \
            --argjson max_input_tokens "$max_input_tokens" \
            --argjson max_output_tokens "$max_output_tokens" \
            '. + {($model_key): {
                "max_tokens": $context_window,
                "max_input_tokens": $max_input_tokens,
                "max_output_tokens": $max_output_tokens,
                "input_cost_per_token": 0,
                "output_cost_per_token": 0,
                "litellm_provider": "openai",
                "mode": "chat"
            }}' "$metadata_file" > "$tmp_file"
    else
        jq -n \
            --arg model_key "$model_key" \
            --argjson context_window "$context_window" \
            --argjson max_input_tokens "$max_input_tokens" \
            --argjson max_output_tokens "$max_output_tokens" \
            '{($model_key): {
                "max_tokens": $context_window,
                "max_input_tokens": $max_input_tokens,
                "max_output_tokens": $max_output_tokens,
                "input_cost_per_token": 0,
                "output_cost_per_token": 0,
                "litellm_provider": "openai",
                "mode": "chat"
            }}' > "$tmp_file"
    fi
    chmod 600 "$tmp_file"
    if [[ -f "$metadata_file" ]] && cmp -s "$tmp_file" "$metadata_file"; then
        rm -f "$tmp_file"
        success "Aider 元数据未变化: $metadata_file"
    else
        mv "$tmp_file" "$metadata_file"
        success "写入 Aider 元数据: $metadata_file"
    fi

    tmp_file="${settings_file}.tmp.$$"
    if [[ -f "$settings_file" ]]; then
        awk -v model_key="$model_key" '
            /^- name:[[:space:]]*/ {
                if ($0 == "- name: " model_key) {
                    skip = 1
                    next
                }
                skip = 0
            }
            !skip { print }
        ' "$settings_file" > "$tmp_file"
        awk '
            NF { for (i = 0; i < blank; i++) print ""; blank = 0; print; next }
            { blank++ }
        ' "$tmp_file" > "${tmp_file}.normalized"
        mv "${tmp_file}.normalized" "$tmp_file"
        [[ -s "$tmp_file" ]] && printf '\n' >> "$tmp_file"
    else
        : > "$tmp_file"
    fi
    cat >> "$tmp_file" <<EOF
- name: ${model_key}
  edit_format: diff
  weak_model_name: ${model_key}
  use_repo_map: false
  lazy: true
  reminder: sys
  examples_as_sys_msg: true
  extra_params:
    max_tokens: ${max_output_tokens}
    temperature: 0.2
EOF
    chmod 600 "$tmp_file"
    if [[ -f "$settings_file" ]] && cmp -s "$tmp_file" "$settings_file"; then
        rm -f "$tmp_file"
        success "Aider 模型设置未变化: $settings_file"
    else
        mv "$tmp_file" "$settings_file"
        success "写入 Aider 模型设置: $settings_file"
    fi
}

write_qwen_config() {
    local provider_name="$1"
    local key_env="$2"
    local base_url="$3"
    local model="$4"
    local context_window="$5"
    local max_output_tokens="$6"
    local qwen_home="$7"
    local qwen_timeout_ms="$8"

    local settings_file tmp_file qwen_display_name
    settings_file="${qwen_home}/settings.json"
    qwen_display_name=$(printf '%s' "$model" | awk 'BEGIN { FS="[-_ ]+"; OFS=" " } { for (i = 1; i <= NF; i++) { $i = toupper(substr($i, 1, 1)) substr($i, 2) } print }')
    mkdir -p "$qwen_home"
    chmod 700 "$qwen_home"

    tmp_file="${settings_file}.tmp.$$"
    if [[ -f "$settings_file" ]]; then
        jq \
            --arg key_env "$key_env" \
            --arg base_url "$base_url" \
            --arg model "$model" \
            --arg qwen_display_name "$qwen_display_name" \
            --argjson context_window "$context_window" \
            --argjson max_output_tokens "$max_output_tokens" \
            --argjson qwen_timeout_ms "$qwen_timeout_ms" \
            '
            def provider: {
                "id": $model,
                "name": $qwen_display_name,
                "envKey": $key_env,
                "baseUrl": $base_url,
                "generationConfig": {
                    "timeout": $qwen_timeout_ms,
                    "contextWindowSize": $context_window,
                    "maxOutputTokens": $max_output_tokens,
                    "samplingParams": {
                        "max_tokens": $max_output_tokens,
                        "temperature": 0.2,
                        "top_p": 0.8
                    },
                    "temperature": 0.2,
                    "topP": 0.8,
                    "extra_body": {
                        "chat_template_kwargs": {
                            "enable_thinking": false
                        }
                    }
                }
            };
            .["$version"] = (.["$version"] // 4)
            | .env = ((.env // {}) + {($key_env): ("$" + $key_env)})
            | .model = {
                "name": $model,
                "skipStartupContext": true,
                "skipNextSpeakerCheck": true,
                "skipLoopDetection": true,
                "generationConfig": {
                    "timeout": $qwen_timeout_ms,
                    "contextWindowSize": $context_window,
                    "maxOutputTokens": $max_output_tokens,
                    "samplingParams": {
                        "max_tokens": $max_output_tokens,
                        "temperature": 0.2,
                        "top_p": 0.8
                    },
                    "temperature": 0.2,
                    "topP": 0.8,
                    "extra_body": {
                        "chat_template_kwargs": {
                            "enable_thinking": false
                        }
                    }
                }
            }
            | .modelProviders = (.modelProviders // {})
            | .modelProviders.openai = [provider]
            | .mcpServers = {}
            | del(.contentGenerator)
            | .memory = ((.memory // {}) + {
                "enableManagedAutoMemory": false,
                "enableManagedAutoDream": false,
                "enableAutoSkill": false
            })
            | .security = ((.security // {}) + {"auth": ((.security.auth // {}) + {"selectedType": "openai"})})
            | .telemetry = ((.telemetry // {}) + {"enabled": false})
            | .privacy = ((.privacy // {}) + {"usageStatisticsEnabled": false})
            ' "$settings_file" > "$tmp_file"
    else
        jq -n \
            --arg key_env "$key_env" \
            --arg base_url "$base_url" \
            --arg model "$model" \
            --arg qwen_display_name "$qwen_display_name" \
            --argjson context_window "$context_window" \
            --argjson max_output_tokens "$max_output_tokens" \
            --argjson qwen_timeout_ms "$qwen_timeout_ms" \
            '{
                "$version": 4,
                "env": {($key_env): ("$" + $key_env)},
                "model": {
                    "name": $model,
                    "skipStartupContext": true,
                    "skipNextSpeakerCheck": true,
                    "skipLoopDetection": true,
                    "generationConfig": {
                        "timeout": $qwen_timeout_ms,
                        "contextWindowSize": $context_window,
                        "maxOutputTokens": $max_output_tokens,
                        "samplingParams": {
                            "max_tokens": $max_output_tokens,
                            "temperature": 0.2,
                            "top_p": 0.8
                        },
                        "temperature": 0.2,
                        "topP": 0.8,
                        "extra_body": {
                            "chat_template_kwargs": {
                                "enable_thinking": false
                            }
                        }
                    }
                },
                "modelProviders": {
                    "openai": [{
                        "id": $model,
                        "name": $qwen_display_name,
                        "envKey": $key_env,
                        "baseUrl": $base_url,
                        "generationConfig": {
                            "timeout": $qwen_timeout_ms,
                            "contextWindowSize": $context_window,
                            "maxOutputTokens": $max_output_tokens,
                            "samplingParams": {
                                "max_tokens": $max_output_tokens,
                                "temperature": 0.2,
                                "top_p": 0.8
                            },
                            "temperature": 0.2,
                            "topP": 0.8,
                            "extra_body": {
                                "chat_template_kwargs": {
                                    "enable_thinking": false
                                }
                            }
                        }
                    }]
                },
                "mcpServers": {},
                "memory": {
                    "enableManagedAutoMemory": false,
                    "enableManagedAutoDream": false,
                    "enableAutoSkill": false
                },
                "security": {"auth": {"selectedType": "openai"}},
                "telemetry": {"enabled": false},
                "privacy": {"usageStatisticsEnabled": false}
            }' > "$tmp_file"
    fi
    chmod 600 "$tmp_file"
    if [[ -f "$settings_file" ]] && cmp -s "$tmp_file" "$settings_file"; then
        rm -f "$tmp_file"
        success "Qwen 配置未变化: $settings_file"
    else
        mv "$tmp_file" "$settings_file"
        success "写入 Qwen 配置: $settings_file"
    fi
}

write_hermes_config() {
    local provider_name="$1"
    local key_env="$2"
    local base_url="$3"
    local model="$4"
    local hermes_provider="$5"
    local hermes_home="${HOME}/.hermes-${provider_name}"

    mkdir -p "$hermes_home"

    local config_file="$hermes_home/config.toml"
    local tmp_file="${config_file}.tmp.$$"

    cat > "$tmp_file" <<EOF
[model]
provider = "${hermes_provider}"
default = "${model}"
base_url = "${base_url}"
EOF

    chmod 600 "$tmp_file"
    if [[ -f "$config_file" ]] && cmp -s "$tmp_file" "$config_file"; then
        rm -f "$tmp_file"
        success "Hermes 配置未变化: $config_file"
    else
        mv "$tmp_file" "$config_file"
        success "写入 Hermes 配置: $config_file"
    fi
}

generate_ai_provider_rc_block() {
    local provider_name="$1"
    local key_env="$2"
    local api_key="$3"
    local base_url="$4"
    local model="$5"
    local codex_home="$6"
    local clients="$7"
    local claude_base_url="$8"
    local aider_metadata_file="$9"
    local aider_settings_file="${10}"
    local aider_timeout_seconds="${11}"
    local qwen_home="${12}"
    local qwen_timeout_ms="${13}"
    local aider_max_chat_history_tokens="${14}"
    local max_output_tokens="${15}"
    local _include_helpers="${16:-false}"
    local no_prefix="${17:-false}"
    local hermes_provider="${18:-$DEFAULT_HERMES_PROVIDER}"
    local codex_home_expr claude_base_url_expr base_url_expr model_expr key_expr
    local env_prefix qwen_home_expr metadata_expr settings_expr timeout_seconds_expr qwen_timeout_ms_expr max_output_tokens_expr
    local qwen_only=false
    # 函数名：单 client 且启用 no_prefix 时直接用 provider_name；否则用 <client>-<provider>
    local codex_func claude_func aider_func qwen_func hermes_func
    if [[ "$no_prefix" == "true" ]]; then
        codex_func="$provider_name"
        claude_func="$provider_name"
        aider_func="$provider_name"
        qwen_func="$provider_name"
        hermes_func="$provider_name"
    else
        codex_func="codex-${provider_name}"
        claude_func="claude-${provider_name}"
        aider_func="aider-${provider_name}"
        qwen_func="qwen-${provider_name}"
        hermes_func="hermes-${provider_name}"
    fi
    codex_home_expr=$(codex_home_expr_for "$provider_name" "$codex_home")
    claude_base_url_expr=$(shell_double_quote "$claude_base_url")
    base_url_expr=$(shell_double_quote "$base_url")
    model_expr=$(shell_double_quote "$model")
    key_expr=$(shell_quote "$api_key")
    env_prefix=$(provider_env_prefix_for "$provider_name")
    qwen_home_expr=$(qwen_home_expr_for "$provider_name" "$qwen_home")
    metadata_expr=$(home_path_expr_for "$aider_metadata_file")
    settings_expr=$(home_path_expr_for "$aider_settings_file")
    timeout_seconds_expr="$aider_timeout_seconds"
    qwen_timeout_ms_expr=$(shell_double_quote "$qwen_timeout_ms")
    max_output_tokens_expr=$(shell_double_quote "$max_output_tokens")
    [[ "$clients" == "qwen" ]] && qwen_only=true

cat <<EOF
# >>> ai-provider: ${provider_name} >>>
EOF

    if [[ "$qwen_only" != "true" ]]; then
        cat <<EOF
export ${key_env}=${key_expr}
export ${env_prefix}_OPENAI_BASE_URL=${base_url_expr}
export ${env_prefix}_MODEL=${model_expr}
EOF
    fi

    if client_enabled "$clients" codex; then
        cat <<EOF
${codex_func}() {
  CODEX_HOME=${codex_home_expr} codex "\$@"
}
EOF
    fi

    if client_enabled "$clients" claude; then
        cat <<EOF
${claude_func}() {
  ANTHROPIC_API_KEY="\$${key_env}" ANTHROPIC_BASE_URL=${claude_base_url_expr} claude --bare "\$@"
}
EOF
    fi

    if client_enabled "$clients" aider; then
        cat <<EOF
${aider_func}() {
  AIDER_MODEL_METADATA_FILE=${metadata_expr} \\
  AIDER_MODEL_SETTINGS_FILE=${settings_expr} \\
  AIDER_OPENAI_API_BASE="\$${env_prefix}_OPENAI_BASE_URL" \\
  AIDER_OPENAI_API_KEY="\$${key_env}" \\
  aider --model "openai/\$${env_prefix}_MODEL" \\
        --openai-api-base "\$${env_prefix}_OPENAI_BASE_URL" \\
        --api-key "openai=\$${key_env}" \\
        --model-metadata-file ${metadata_expr} \\
        --model-settings-file ${settings_expr} \\
        --no-show-model-warnings \\
        --no-check-update \\
        --no-stream \\
        --map-tokens 0 \\
        --max-chat-history-tokens ${aider_max_chat_history_tokens} \\
        --no-restore-chat-history \\
        --timeout ${timeout_seconds_expr} \\
        "\$@"
}
EOF
    fi

    if client_enabled "$clients" qwen; then
        if [[ "$qwen_only" == "true" ]]; then
            cat <<EOF
${qwen_func}() {
  QWEN_HOME=${qwen_home_expr} \\
  QWEN_CODE_API_TIMEOUT_MS=${qwen_timeout_ms_expr} \\
  QWEN_CODE_MAX_OUTPUT_TOKENS=${max_output_tokens_expr} \\
  OPENAI_API_KEY=${key_expr} \\
  OPENAI_BASE_URL=${base_url_expr} \\
  OPENAI_MODEL=${model_expr} \\
  qwen --auth-type openai "\$@"
}
EOF
        else
            cat <<EOF
export ${env_prefix}_QWEN_HOME=${qwen_home_expr}
export ${env_prefix}_QWEN_TIMEOUT_MS=${qwen_timeout_ms_expr}
export ${env_prefix}_QWEN_MAX_OUTPUT_TOKENS=${max_output_tokens_expr}
${qwen_func}() {
  QWEN_HOME="\$${env_prefix}_QWEN_HOME" \\
  QWEN_CODE_API_TIMEOUT_MS="\$${env_prefix}_QWEN_TIMEOUT_MS" \\
  QWEN_CODE_MAX_OUTPUT_TOKENS="\$${env_prefix}_QWEN_MAX_OUTPUT_TOKENS" \\
  OPENAI_API_KEY="\$${key_env}" \\
  OPENAI_BASE_URL="\$${env_prefix}_OPENAI_BASE_URL" \\
  OPENAI_MODEL="\$${env_prefix}_MODEL" \\
  qwen --auth-type openai "\$@"
}
EOF
        fi
    fi
    if client_enabled "$clients" hermes; then
        cat <<EOF
unalias hermes-${provider_name} 2>/dev/null || true
${hermes_func}() {
  HERMES_HOME="\$HOME/.hermes-${provider_name}" OPENAI_API_KEY="\$${key_env}" hermes "\$@"
}
EOF
    fi
    cat <<EOF
# <<< ai-provider: ${provider_name} <<<
EOF
}

remove_managed_shell_function() {
    local rc_file="$1"
    local provider_name="$2"
    local remove_helpers="${3:-true}"

    [[ -f "$rc_file" ]] || return 0

    local tmp_file="${rc_file}.tmp.$$"
    local helpers_start="# >>> ai-provider helpers >>>"
    local helpers_end="# <<< ai-provider helpers <<<"
    local provider_start="# >>> ai-provider: ${provider_name} >>>"
    local provider_end="# <<< ai-provider: ${provider_name} <<<"
    local old_marker="# Codex custom provider function - ${provider_name}"
    local legacy_codex_func="codex-${provider_name}() {"
    local legacy_claude_func="claude-${provider_name}() {"
    local legacy_hermes_alias="alias hermes-${provider_name}="

    awk \
        -v helpers_start="$helpers_start" -v helpers_end="$helpers_end" \
        -v provider_start="$provider_start" -v provider_end="$provider_end" \
        -v old="$old_marker" \
        -v legacy_codex_func="$legacy_codex_func" \
        -v legacy_claude_func="$legacy_claude_func" \
        -v legacy_hermes_alias="$legacy_hermes_alias" \
        -v remove_helpers="$remove_helpers" '
        remove_helpers == "true" && index($0, helpers_start) == 1 { skip=1; removed=1; next }
        skip && index($0, helpers_end) == 1 { skip=0; next }
        index($0, provider_start) == 1 { skip=1; removed=1; next }
        skip && index($0, provider_end) == 1 { skip=0; next }
        skip { next }
        index($0, old) == 1 { oldskip=1; removed=1; next }
        index($0, legacy_codex_func) == 1 { oldskip=1; removed=1; next }
        index($0, legacy_claude_func) == 1 { oldskip=1; removed=1; next }
        index($0, legacy_hermes_alias) == 1 { removed=1; next }
        oldskip && /^}/ { oldskip=0; next }
        oldskip { next }
        { print }
        END { if (removed) exit 3 }
    ' "$rc_file" > "$tmp_file" || {
        local status=$?
        if [[ "$status" != 3 ]]; then
            mv "$tmp_file" "${tmp_file}.failed" 2>/dev/null || true
            return "$status"
        fi
    }

    mv "$tmp_file" "$rc_file"
}

update_shell_function() {
    local rc_file="$1"
    local provider_name="$2"
    local key_env="$3"
    local api_key="$4"
    local base_url="$5"
    local model="$6"
    local codex_home="$7"
    local clients="$8"
    local claude_base_url="${9}"
    local aider_metadata_file="${10}"
    local aider_settings_file="${11}"
    local aider_timeout_seconds="${12}"
    local qwen_home="${13}"
    local qwen_timeout_ms="${14}"
    local aider_max_chat_history_tokens="${15}"
    local no_prefix="${16:-false}"
    local hermes_provider="${17:-$DEFAULT_HERMES_PROVIDER}"
    local include_helpers=true

    if [[ ! -f "$rc_file" ]]; then
        info "创建文件: $rc_file"
        touch "$rc_file"
    fi

    remove_managed_shell_function "$rc_file" "$provider_name" true
    local normalized_file="${rc_file}.normalized.$$"
    awk '
        NF { for (i = 0; i < blank; i++) print ""; blank = 0; print; next }
        { blank++ }
    ' "$rc_file" > "$normalized_file"
    mv "$normalized_file" "$rc_file"
    [[ -s "$rc_file" ]] && printf '\n' >> "$rc_file"
    generate_ai_provider_rc_block \
        "$provider_name" "$key_env" "$api_key" "$base_url" "$model" "$codex_home" "$clients" "$claude_base_url" \
        "$aider_metadata_file" "$aider_settings_file" "$aider_timeout_seconds" \
        "$qwen_home" "$qwen_timeout_ms" "$aider_max_chat_history_tokens" "$max_output_tokens" "$include_helpers" "$no_prefix" \
        "$hermes_provider" >> "$rc_file"
    success "写入 shell 配置: ${key_env}, clients=${clients} (到 ${rc_file})"
}

redact_file() {
    local file="$1"

    sed -E \
        -e 's#(base_url[[:space:]]*=[[:space:]]*").*(")#\1<redacted>\2#' \
        -e 's#("OPENAI_API_KEY"[[:space:]]*:[[:space:]]*").*(")#\1<redacted>\2#' \
        -e 's#(api[_-]?key|token)([[:space:]]*=[[:space:]]*").*(")#\1\2<redacted>\3#Ig' \
        "$file"
}

show_config() {
    local codex_home="$1"
    local config_file="${codex_home}/config.toml"
    local auth_file="${codex_home}/auth.json"

    echo ""
    echo "========================================"
    echo "         Codex 配置"
    echo "========================================"
    echo "CODEX_HOME: $codex_home"

    if [[ -f "$config_file" ]]; then
        printf '\n%b--- config.toml ---%b\n' "$BLUE" "$NC"
        redact_file "$config_file"
    else
        warn "config.toml 不存在: $config_file"
    fi

    if [[ -f "$auth_file" ]]; then
        printf '\n%b--- auth.json ---%b\n' "$BLUE" "$NC"
        redact_file "$auth_file"
    else
        warn "auth.json 不存在: $auth_file"
    fi

    echo "========================================"
}

validate_config() {
    local provider_name="$1"
    local api_key="$2"
    local base_url="$3"
    local codex_home="$4"
    local model="$5"
    local reasoning_effort="$6"
    local wire_api="$7"
    local key_env="$8"
    local clients="$9"
    local claude_base_url="${10}"
    local context_window="${11}"
    local max_output_tokens="${12}"
    local aider_timeout_seconds="${13}"
    local aider_metadata_file="${14}"
    local aider_settings_file="${15}"
    local qwen_home="${16}"
    local qwen_timeout_ms="${17}"
    local max_input_tokens="${18}"
    local aider_max_chat_history_tokens="${19}"
    local rc_file="${20}"
    local no_prefix="${21:-false}"
    local hermes_provider="${22:-$DEFAULT_HERMES_PROVIDER}"
    local _codex_fn _claude_fn _aider_fn _qwen_fn _hermes_fn
    if [[ "$no_prefix" == "true" ]]; then
        _codex_fn="$provider_name"; _claude_fn="$provider_name"; _aider_fn="$provider_name"
        _qwen_fn="$provider_name"; _hermes_fn="$provider_name"
    else
        _codex_fn="codex-${provider_name}"; _claude_fn="claude-${provider_name}"
        _aider_fn="aider-${provider_name}"; _qwen_fn="qwen-${provider_name}"; _hermes_fn="hermes-${provider_name}"
    fi

    echo ""
    echo "========================================"
    echo "         配置验证"
    echo "========================================"
    echo "Provider 名称: $provider_name"
    if client_enabled "$clients" codex; then
        echo "CODEX_HOME: $codex_home"
    fi
    echo "Base URL: $base_url"
    echo "Model: $model"
    if client_enabled "$clients" codex; then
        echo "Reasoning effort: $reasoning_effort"
        echo "Wire API: $wire_api"
    fi
    echo "API Key 变量: $key_env"
    echo "API Key: $(mask_secret "$api_key")"
    echo "shell rc 文件: $rc_file"
    echo "Clients: $clients"
    if client_enabled "$clients" claude; then
        echo "Claude base URL: $claude_base_url"
    fi
    if client_enabled "$clients" aider || client_enabled "$clients" qwen; then
        echo "Context window: $context_window"
        echo "Max input tokens: $max_input_tokens"
        echo "Max output tokens: $max_output_tokens"
    fi
    if client_enabled "$clients" aider; then
        echo "Aider timeout: ${aider_timeout_seconds}s"
        echo "Aider max chat history: $aider_max_chat_history_tokens"
        echo "Aider metadata: $aider_metadata_file"
        echo "Aider settings: $aider_settings_file"
    fi
    if client_enabled "$clients" qwen; then
        echo "Qwen home: $qwen_home"
        echo "Qwen timeout: ${qwen_timeout_ms}ms"
    fi
    if client_enabled "$clients" hermes; then
        echo "Hermes provider: $hermes_provider"
    fi
    if client_enabled "$clients" codex || client_enabled "$clients" aider || client_enabled "$clients" qwen || client_enabled "$clients" hermes; then
        echo ""
        echo "将写入/更新配置:"
    fi
    if client_enabled "$clients" codex; then
        echo "  ${codex_home}/config.toml"
        echo "  ${codex_home}/auth.json"
    fi
    if client_enabled "$clients" aider; then
        echo "  ${aider_metadata_file}"
        echo "  ${aider_settings_file}"
    fi
    if client_enabled "$clients" qwen; then
        echo "  ${qwen_home}/settings.json"
    fi
    if client_enabled "$clients" hermes; then
        echo "  ${HOME}/.hermes-${provider_name}/config.toml"
    fi
    echo ""
    echo "将更新 shell wrapper:"
    if client_enabled "$clients" codex; then
        echo "  ${_codex_fn}"
    fi
    if client_enabled "$clients" claude; then
        echo "  ${_claude_fn}"
    fi
    if client_enabled "$clients" aider; then
        echo "  ${_aider_fn}"
    fi
    if client_enabled "$clients" qwen; then
        echo "  ${_qwen_fn}"
    fi
    if client_enabled "$clients" hermes; then
        echo "  ${_hermes_fn}"
    fi
    echo "========================================"
}

confirm_apply() {
    local assume_yes="${1:-false}"
    local confirm

    if [[ "$assume_yes" == true ]]; then
        return 0
    fi

    echo ""
    printf '确认应用以上配置? [Y/n]: '
    read -r confirm
    if [[ "$confirm" =~ ^[Nn]$ ]]; then
        info "已取消"
        exit 0
    fi
}

normalize_base_url() {
    local url="$1"
    url="${url%/}"
    if [[ "$url" != */v1 ]]; then
        url="${url}/v1"
    fi
    printf '%s' "$url"
}

select_preferred_model_from_json() {
    local json="$1"
    local models

    if ! command_exists jq; then
        return 1
    fi

    models=$(printf '%s' "$json" | jq -r '
        [
          (.data[]?.id?),
          (.models[]?.id?),
          (.models[]?.name?),
          (.[]?.id?)
        ]
        | map(select(type == "string" and length > 0))
        | unique
        | .[]
    ' 2>/dev/null) || return 1

    printf '%s\n' "$models" | awk '
        BEGIN { best = "" }
        /coder|code|coding/i { print; found = 1; exit }
        /qwen/i && best == "" { best = $0 }
        /deepseek/i && best == "" { best = $0 }
        best == "" { best = $0 }
        END { if (!found && best != "") print best }
    '
}

select_max_model_len_from_json() {
    local json="$1"
    local model_id="${2:-}"

    if ! command_exists jq; then
        return 1
    fi

    if [[ -n "$model_id" ]]; then
        printf '%s' "$json" | jq -r --arg model_id "$model_id" '
            [
              (.data[]? | select(.id == $model_id) | .max_model_len?),
              (.data[]? | select(.id == $model_id) | .max_context_length?),
              (.data[]? | select(.id == $model_id) | .context_length?),
              (.models[]? | select((.id? // .name?) == $model_id) | .max_model_len?),
              (.models[]? | select((.id? // .name?) == $model_id) | .context_length?)
            ]
            | map(select(type == "number" and . > 0))
            | first // empty
        ' 2>/dev/null
        return
    fi

    printf '%s' "$json" | jq -r '
        [
          (.data[]?.max_model_len?),
          (.data[]?.max_context_length?),
          (.data[]?.context_length?),
          (.models[]?.max_model_len?),
          (.models[]?.context_length?)
        ]
        | map(select(type == "number" and . > 0))
        | max // empty
    ' 2>/dev/null
}

discover_openai_compatible() {
    local api_key_hint="$1"
    local discovery_urls="${AI_PROVIDER_DISCOVERY_URLS:-}"
    local -a candidates
    local url models_json discovered_model discovered_context_window

    if [[ -n "$discovery_urls" ]]; then
        IFS=',' read -r -a candidates <<< "$discovery_urls"
    else
        candidates=(
            "http://studio:8001/v1"
            "http://studio:8000/v1"
            "http://studio.local:8000/v1"
            "http://studio.local:8001/v1"
            "http://localhost:8000/v1"
            "http://localhost:8001/v1"
            "http://127.0.0.1:8000/v1"
            "http://127.0.0.1:8001/v1"
            "http://localhost:8080/v1"
            "http://127.0.0.1:8080/v1"
            "http://localhost:11434/v1"
            "http://127.0.0.1:11434/v1"
        )
    fi

    command_exists curl || return 1

    for url in "${candidates[@]}"; do
        url=$(normalize_base_url "$url")
        info "自动发现: 探测 ${url}/models"
        if models_json=$(curl -fsS --connect-timeout 1 --max-time 2 \
            -H "Authorization: Bearer ${api_key_hint:-sk-local}" \
            "${url}/models" 2>/dev/null); then
            discovered_model=$(select_preferred_model_from_json "$models_json" || true)
            discovered_context_window=$(select_max_model_len_from_json "$models_json" "$discovered_model" || true)
            AUTO_DISCOVERED_BASE_URL="$url"
            AUTO_DISCOVERED_MODEL="${discovered_model:-studio-qwen-coder}"
            AUTO_DISCOVERED_CONTEXT_WINDOW="$discovered_context_window"
            return 0
        fi
    done

    return 1
}

prompt_for_missing_values() {
    if [[ -z "$base_url" ]]; then
        printf '请输入请求地址 (默认: %s): ' "$DEFAULT_OFFICIAL_BASE_URL"
        read -r base_url
        base_url="${base_url:-$DEFAULT_OFFICIAL_BASE_URL}"
    fi

    if [[ "$base_url" == "$DEFAULT_OFFICIAL_BASE_URL" || "$base_url" == https://api.openai.com* ]]; then
        warn "官方地址建议保留给默认 ~/.codex 和 Codex Desktop；本脚本不会修改 ~/.codex。"
        if [[ -z "$api_key" ]]; then
            error "自定义隔离配置需要 API Key；官方账号请直接使用 codex login 或 codex app。"
            exit 1
        fi
    fi

    if [[ -z "$api_key" ]]; then
        printf '请输入 API Key (输入时不回显): '
        read -rs api_key
        echo ""
    fi

    if [[ -z "$api_key" ]]; then
        error "API Key 不能为空"
        exit 1
    fi

    if [[ -z "$provider_name" ]]; then
        local default_name
        default_name=$(slugify_provider_name "$(extract_provider_name "$base_url")")
        printf '请输入 Provider 名称 (默认: %s): ' "$default_name"
        read -r provider_name
        provider_name="${provider_name:-$default_name}"
    fi

    provider_name=$(slugify_provider_name "$provider_name")
    validate_provider_name "$provider_name"

    if [[ "${model_set:-}" != true ]]; then
        printf '请输入模型名称 (默认: %s): ' "$DEFAULT_MODEL"
        read -r model
        model="${model:-$DEFAULT_MODEL}"
    fi

    if client_enabled "$clients" codex && [[ "${reasoning_set:-}" != true ]]; then
        printf '请输入 reasoning effort [minimal|low|medium|high|xhigh] (默认: %s): ' "$DEFAULT_REASONING_EFFORT"
        read -r reasoning_effort
        reasoning_effort="${reasoning_effort:-$DEFAULT_REASONING_EFFORT}"
    fi
}

remove_provider() {
    local provider_name="$1"
    local codex_home="$2"
    local archive="$3"
    codex_home=$(expand_home_path "$codex_home")

    local shell_type rc_file
    shell_type=$(detect_shell)
    rc_file=$(get_rc_file "$shell_type")

    remove_managed_shell_function "$rc_file" "$provider_name" false
    success "移除 shell wrapper: *-${provider_name} (从 ${rc_file})"

    if [[ "$archive" == true ]]; then
        if [[ "$codex_home" == "$(expand_home_path "$DEFAULT_CODEX_DIR")" ]]; then
            error "拒绝归档默认 CODEX_HOME: $codex_home"
            exit 1
        fi

        if [[ -d "$codex_home" ]]; then
            local archived_home
            archived_home="${codex_home}.archived.$(date +%Y%m%d_%H%M%S)"
            mv "$codex_home" "$archived_home"
            success "归档隔离目录: $archived_home"
        else
            warn "隔离目录不存在: $codex_home"
        fi
    else
        info "隔离目录未删除: $codex_home"
        info "如需归档，请确认不再使用后执行: $0 --remove $provider_name --archive"
    fi

    info "请执行: source ${rc_file}"
}

main() {
    local original_arg_count=$#
    local provider_name=""
    local api_key=""
    local base_url=""
    local model="$DEFAULT_MODEL"
    local reasoning_effort="$DEFAULT_REASONING_EFFORT"
    local wire_api="$DEFAULT_WIRE_API"
    local codex_home=""
    local key_env=""
    local clients="$DEFAULT_CLIENTS"
    local claude_base_url=""
    local context_window="$DEFAULT_CONTEXT_WINDOW"
    local max_input_tokens="$DEFAULT_MAX_INPUT_TOKENS"
    local max_output_tokens="$DEFAULT_MAX_OUTPUT_TOKENS"
    local aider_timeout_seconds="$DEFAULT_AIDER_TIMEOUT_SECONDS"
    local aider_max_chat_history_tokens="$DEFAULT_AIDER_MAX_CHAT_HISTORY_TOKENS"
    local aider_metadata_file="${HOME}/.aider.model.metadata.json"
    local aider_settings_file="${HOME}/.aider.model.settings.yml"
    local qwen_home=""
    local qwen_timeout_ms="$DEFAULT_QWEN_TIMEOUT_MS"
    local hermes_provider="$DEFAULT_HERMES_PROVIDER"
    local remove_mode=false
    local show_mode=false
    local archive=false
    local assume_yes=false
    local auto_discover=false
    local no_auto_discover=false
    local clients_set=false
    local model_set=false
    local reasoning_set=false
    local no_prefix=false
    local provider_set=false
    local base_url_set=false
    local api_key_set=false
    local context_window_set=false
    local AUTO_DISCOVERED_BASE_URL=""
    local AUTO_DISCOVERED_MODEL=""
    local AUTO_DISCOVERED_CONTEXT_WINDOW=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                usage
                exit 0
                ;;
            -p|--provider)
                shift
                provider_name="${1:-}"
                [[ -n "$provider_name" ]] || { error "--provider 需要参数"; exit 1; }
                provider_set=true
                shift
                ;;
            -k|--api-key)
                shift
                api_key="${1:-}"
                [[ -n "$api_key" ]] || { error "--api-key 需要参数"; exit 1; }
                api_key_set=true
                shift
                ;;
            --api-key-env)
                shift
                key_env="${1:-}"
                [[ -n "$key_env" ]] || { error "--api-key-env 需要参数"; exit 1; }
                validate_key_env "$key_env"
                shift
                ;;
            -b|--base-url)
                shift
                base_url="${1:-}"
                [[ -n "$base_url" ]] || { error "--base-url 需要参数"; exit 1; }
                base_url_set=true
                shift
                ;;
            -m|--model)
                shift
                model="${1:-}"
                [[ -n "$model" ]] || { error "--model 需要参数"; exit 1; }
                model_set=true
                shift
                ;;
            --reasoning-effort)
                shift
                reasoning_effort="${1:-}"
                [[ -n "$reasoning_effort" ]] || { error "--reasoning-effort 需要参数"; exit 1; }
                reasoning_set=true
                shift
                ;;
            --wire-api)
                shift
                wire_api="${1:-}"
                [[ -n "$wire_api" ]] || { error "--wire-api 需要参数"; exit 1; }
                shift
                ;;
            --codex-home)
                shift
                codex_home="${1:-}"
                [[ -n "$codex_home" ]] || { error "--codex-home 需要参数"; exit 1; }
                shift
                ;;
            --clients)
                shift
                clients="${1:-}"
                [[ -n "$clients" ]] || { error "--clients 需要参数"; exit 1; }
                clients_set=true
                shift
                ;;
            --no-prefix)
                no_prefix=true
                shift
                ;;
            --claude-base-url)
                shift
                claude_base_url="${1:-}"
                [[ -n "$claude_base_url" ]] || { error "--claude-base-url 需要参数"; exit 1; }
                shift
                ;;
            --context-window)
                shift
                context_window="${1:-}"
                [[ "$context_window" =~ ^[0-9]+$ ]] || { error "--context-window 需要正整数"; exit 1; }
                context_window_set=true
                shift
                ;;
            --max-input-tokens)
                shift
                max_input_tokens="${1:-}"
                [[ "$max_input_tokens" =~ ^[0-9]+$ ]] || { error "--max-input-tokens 需要正整数"; exit 1; }
                shift
                ;;
            --max-output-tokens)
                shift
                max_output_tokens="${1:-}"
                [[ "$max_output_tokens" =~ ^[0-9]+$ ]] || { error "--max-output-tokens 需要正整数"; exit 1; }
                shift
                ;;
            --aider-timeout)
                shift
                aider_timeout_seconds="${1:-}"
                [[ "$aider_timeout_seconds" =~ ^[0-9]+$ ]] || { error "--aider-timeout 需要正整数"; exit 1; }
                shift
                ;;
            --aider-max-chat-history-tokens)
                shift
                aider_max_chat_history_tokens="${1:-}"
                [[ "$aider_max_chat_history_tokens" =~ ^[0-9]+$ ]] || { error "--aider-max-chat-history-tokens 需要正整数"; exit 1; }
                shift
                ;;
            --aider-metadata-file)
                shift
                aider_metadata_file="${1:-}"
                [[ -n "$aider_metadata_file" ]] || { error "--aider-metadata-file 需要参数"; exit 1; }
                shift
                ;;
            --aider-settings-file)
                shift
                aider_settings_file="${1:-}"
                [[ -n "$aider_settings_file" ]] || { error "--aider-settings-file 需要参数"; exit 1; }
                shift
                ;;
            --qwen-home)
                shift
                qwen_home="${1:-}"
                [[ -n "$qwen_home" ]] || { error "--qwen-home 需要参数"; exit 1; }
                shift
                ;;
            --qwen-timeout-ms)
                shift
                qwen_timeout_ms="${1:-}"
                [[ "$qwen_timeout_ms" =~ ^[0-9]+$ ]] || { error "--qwen-timeout-ms 需要正整数"; exit 1; }
                shift
                ;;
            --hermes-provider)
                shift
                hermes_provider="${1:-}"
                [[ -n "$hermes_provider" ]] || { error "--hermes-provider 需要参数"; exit 1; }
                validate_hermes_provider "$hermes_provider"
                shift
                ;;
            -y|--yes)
                assume_yes=true
                shift
                ;;
            --auto-discover)
                auto_discover=true
                shift
                ;;
            --no-auto-discover)
                no_auto_discover=true
                shift
                ;;
            -r|--remove)
                remove_mode=true
                shift
                if [[ $# -gt 0 && ! "$1" =~ ^- ]]; then
                    provider_name="$1"
                    shift
                fi
                ;;
            --archive|--purge)
                archive=true
                shift
                ;;
            -s|--show)
                show_mode=true
                shift
                if [[ $# -gt 0 && ! "$1" =~ ^- ]]; then
                    provider_name="$1"
                    shift
                fi
                ;;
            -*)
                error "未知选项: $1"
                echo "使用 -h 查看帮助"
                exit 1
                ;;
            *)
                error "未知选项或不支持使用位置参数: $1"
                echo "使用 -h 查看帮助，请使用 -p、-k、-b 等长短参数格式传递"
                exit 1
                ;;
        esac
    done

    if [[ "$show_mode" == true ]]; then
        provider_name=$(slugify_provider_name "${provider_name:-custom}")
        validate_provider_name "$provider_name"
        codex_home="${codex_home:-$(provider_home_for "$provider_name")}"
        codex_home=$(expand_home_path "$codex_home")
        show_config "$codex_home"
        exit 0
    fi

    if [[ "$remove_mode" == true ]]; then
        provider_name=$(slugify_provider_name "${provider_name:-custom}")
        validate_provider_name "$provider_name"
        codex_home="${codex_home:-$(provider_home_for "$provider_name")}"
        codex_home=$(expand_home_path "$codex_home")
        remove_provider "$provider_name" "$codex_home" "$archive"
        exit 0
    fi

    if [[ -n "$provider_name" ]]; then
        provider_name=$(slugify_provider_name "$provider_name")
        validate_provider_name "$provider_name"
    fi

    if [[ "$no_auto_discover" != true ]] && { [[ "$auto_discover" == true ]] || (( original_arg_count == 0 )); }; then
        local discovery_key_hint
        discovery_key_hint="${api_key:-${OPENAI_API_KEY:-sk-local}}"
        if discover_openai_compatible "$discovery_key_hint"; then
            base_url="${base_url:-$AUTO_DISCOVERED_BASE_URL}"
            if [[ "$model_set" != true ]]; then
                model="$AUTO_DISCOVERED_MODEL"
            fi
            if [[ "$provider_set" != true ]]; then
                provider_name=$(slugify_provider_name "$(extract_provider_name "$base_url")")
                [[ "$provider_name" == "localhost" || "$provider_name" == "127" ]] && provider_name="studio"
            fi
            if [[ "$api_key_set" != true ]]; then
                api_key="${api_key:-${OPENAI_API_KEY:-sk-studio}}"
            fi
            if [[ "$clients_set" != true ]]; then
                clients="qwen"
            fi
            if [[ "$context_window_set" != true && -n "$AUTO_DISCOVERED_CONTEXT_WINDOW" ]]; then
                context_window="$AUTO_DISCOVERED_CONTEXT_WINDOW"
            fi
            success "自动发现到 OpenAI-compatible 服务: ${base_url}，模型: ${model}，context=${context_window}，clients=${clients}"
        else
            warn "自动发现未找到可用 OpenAI-compatible 服务，将进入交互配置。"
        fi
    fi

    prompt_for_missing_values
    codex_home="${codex_home:-$(provider_home_for "$provider_name")}"
    codex_home=$(expand_home_path "$codex_home")
    qwen_home="${qwen_home:-$(qwen_home_for "$provider_name")}"
    qwen_home=$(expand_home_path "$qwen_home")
    aider_metadata_file=$(expand_home_path "$aider_metadata_file")
    aider_settings_file=$(expand_home_path "$aider_settings_file")
    key_env="${key_env:-$(key_env_for "$provider_name")}"
    clients="${clients//[[:space:]]/}"
    claude_base_url="${claude_base_url:-$(claude_base_url_for "$base_url")}"
    max_input_tokens="${max_input_tokens:-$context_window}"
    validate_key_env "$key_env"
    validate_clients "$clients"
    validate_hermes_provider "$hermes_provider"
    if client_enabled "$clients" codex; then
        assert_safe_codex_home "$codex_home"
    fi
    if [[ "$provider_name" == "studio" ]] && client_enabled "$clients" codex; then
        error "studio provider 只用于 Aider/Qwen 等 OpenAI-compatible 客户端；Codex 请继续使用官方账号或代理服务商。"
        exit 1
    fi

    local shell_type rc_file
    shell_type=$(detect_shell)
    rc_file=$(get_rc_file "$shell_type")

    info "检测到 shell: $shell_type"
    info "使用 rc 文件: $rc_file"

    validate_config \
        "$provider_name" "$api_key" "$base_url" "$codex_home" "$model" "$reasoning_effort" \
        "$wire_api" "$key_env" "$clients" "$claude_base_url" "$context_window" "$max_output_tokens" \
        "$aider_timeout_seconds" "$aider_metadata_file" "$aider_settings_file" "$qwen_home" "$qwen_timeout_ms" \
        "$max_input_tokens" "$aider_max_chat_history_tokens" "$rc_file" "$no_prefix" "$hermes_provider"
    confirm_apply "$assume_yes"

    if client_enabled "$clients" codex; then
        ensure_custom_home "$codex_home"
        write_custom_config "$codex_home" "$provider_name" "$base_url" "$model" "$reasoning_effort" "$wire_api" "$PWD"
        write_custom_auth "$codex_home" "$api_key"
    fi
    if client_enabled "$clients" aider; then
        write_aider_config "$model" "$context_window" "$max_input_tokens" "$max_output_tokens" "$aider_metadata_file" "$aider_settings_file"
    fi
    if client_enabled "$clients" qwen; then
        write_qwen_config "$provider_name" "$key_env" "$base_url" "$model" "$context_window" "$max_output_tokens" "$qwen_home" "$qwen_timeout_ms"
    fi
    if client_enabled "$clients" hermes; then
        write_hermes_config "$provider_name" "$key_env" "$base_url" "$model" "$hermes_provider"
    fi
    update_shell_function \
        "$rc_file" "$provider_name" "$key_env" "$api_key" "$base_url" "$model" "$codex_home" "$clients" "$claude_base_url" \
        "$aider_metadata_file" "$aider_settings_file" "$aider_timeout_seconds" \
        "$qwen_home" "$qwen_timeout_ms" "$aider_max_chat_history_tokens" "$no_prefix" "$hermes_provider"

    # 计算实际函数名用于提示
    local _fn_codex _fn_claude _fn_aider _fn_qwen _fn_hermes
    if [[ "$no_prefix" == "true" ]]; then
        _fn_codex="$provider_name"; _fn_claude="$provider_name"; _fn_aider="$provider_name"
        _fn_qwen="$provider_name"; _fn_hermes="$provider_name"
    else
        _fn_codex="codex-${provider_name}"; _fn_claude="claude-${provider_name}"
        _fn_aider="aider-${provider_name}"; _fn_qwen="qwen-${provider_name}"; _fn_hermes="hermes-${provider_name}"
    fi

    echo ""
    success "配置完成！"
    echo ""
    echo "使用方式:"
    echo "  1. 执行: source ${rc_file}"
    if client_enabled "$clients" codex; then
        echo "  2. 运行: ${_fn_codex}"
    fi
    if client_enabled "$clients" claude; then
        echo "  运行 Claude: ${_fn_claude}"
    fi
    if client_enabled "$clients" aider; then
        echo "  运行 Aider: ${_fn_aider}"
    fi
    if client_enabled "$clients" qwen; then
        echo "  运行 Qwen Code: ${_fn_qwen}"
    fi
    if client_enabled "$clients" hermes; then
        echo "  运行 Hermes: ${_fn_hermes}"
    fi
    echo ""
    if client_enabled "$clients" codex; then
        echo "直接运行 Codex:"
        echo "  CODEX_HOME=$(shell_quote "$codex_home") codex"
        echo ""
    fi
    if client_enabled "$clients" claude; then
        echo "直接运行 Claude:"
        echo "  ANTHROPIC_API_KEY=\"\$${key_env}\" ANTHROPIC_BASE_URL=$(shell_quote "$claude_base_url") claude --bare"
        echo ""
    fi
    if client_enabled "$clients" aider; then
        echo "直接运行 Aider:"
        echo "  AIDER_OPENAI_API_BASE=$(shell_quote "$base_url") AIDER_OPENAI_API_KEY=\"\$${key_env}\" aider --model $(shell_quote "openai/${model}") --no-stream"
        echo ""
    fi
    if client_enabled "$clients" qwen; then
        echo "直接运行 Qwen Code:"
        echo "  source $(shell_quote "$rc_file")"
        echo "  ${_fn_qwen}"
        echo ""
    fi
    if client_enabled "$clients" hermes; then
        echo "直接运行 Hermes:"
        echo "  HERMES_HOME=\"\$HOME/.hermes-${provider_name}\" hermes"
        echo ""
    fi
    echo ""
    if client_enabled "$clients" codex; then
        info "脱敏后的当前配置:"
        show_config "$codex_home"
    fi
}

main "$@"
