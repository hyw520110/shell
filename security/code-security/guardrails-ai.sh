#!/bin/bash
# Guardrails AI - LLM output validation / safety guard helper
# Docs: https://guardrailsai.com/guardrails/docs/getting_started/quickstart

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

VENV_DIR="${GUARDRAILS_AI_VENV_DIR:-$HOME/.guardrails_ai_venv}"
INSTALL_API_EXTRA=0

log_info() { echo -e "${GREEN}[INFO] $*${NC}"; }
log_warn() { echo -e "${YELLOW}[WARN] $*${NC}"; }
log_error() { echo -e "${RED}[ERROR] $*${NC}"; }

show_help() {
    cat <<EOF
Guardrails AI 管理脚本

用法:
  $0 <命令> [选项]

命令:
  install              安装 guardrails-ai 到独立 venv
  update               更新 guardrails-ai
  uninstall            删除独立 venv
  status               查看安装状态
  configure            执行 guardrails configure
  hub-install URI...   安装 Guardrails Hub validator
  init-demo [DIR]      生成本地 Python 校验示例
  run-demo [DIR]       运行本地 Python 校验示例
  start-server CONFIG  启动 Guardrails API server

选项:
  --api                安装 guardrails-ai[api]，用于 start-server
  --venv DIR           指定虚拟环境目录，默认 ~/.guardrails_ai_venv
  -h, --help           显示帮助

示例:
  $0 install
  $0 install --api
  $0 configure
  $0 hub-install hub://guardrails/regex_match
  $0 init-demo .
  $0 run-demo .
  $0 start-server ./config.py

说明:
  Guardrails AI 属于 LLM 输出结构化、安全校验和项目质量门禁工具，因此脚本放在 security/code-security。
  安装使用独立 Python venv，避免污染系统 Python 或项目环境。
EOF
}

parse_common_options() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --api)
                INSTALL_API_EXTRA=1
                shift
                ;;
            --venv)
                VENV_DIR="${2:-}"
                shift 2
                ;;
            --venv=*)
                VENV_DIR="${1#*=}"
                shift
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            *)
                REMAINING_ARGS+=("$1")
                shift
                ;;
        esac
    done
}

python_cmd() {
    if command -v python3 >/dev/null 2>&1; then
        echo python3
    elif command -v python >/dev/null 2>&1; then
        echo python
    else
        return 1
    fi
}

ensure_python() {
    local py
    py="$(python_cmd)" || {
        log_error "未找到 Python，请先安装 Python 3.10+。"
        return 1
    }
    if ! "$py" - <<'PY'
import sys
raise SystemExit(0 if sys.version_info >= (3, 10) else 1)
PY
    then
        log_warn "Guardrails AI 官方文档建议 Python 3.10+；当前版本: $("$py" --version 2>&1)"
    fi
}

venv_python() {
    echo "$VENV_DIR/bin/python"
}

venv_guardrails() {
    echo "$VENV_DIR/bin/guardrails"
}

ensure_installed() {
    if [[ ! -x "$(venv_guardrails)" ]]; then
        log_error "Guardrails AI 未安装，请先执行: $0 install"
        return 1
    fi
}

cmd_install() {
    ensure_python
    local py package
    py="$(python_cmd)"
    package="guardrails-ai"
    [[ "$INSTALL_API_EXTRA" -eq 1 ]] && package="guardrails-ai[api]"

    log_info "创建虚拟环境: $VENV_DIR"
    "$py" -m venv "$VENV_DIR"

    log_info "安装 $package ..."
    "$(venv_python)" -m pip install --upgrade pip setuptools wheel
    "$(venv_python)" -m pip install --upgrade "$package"

    cmd_status
}

cmd_update() {
    ensure_installed
    local package="guardrails-ai"
    [[ "$INSTALL_API_EXTRA" -eq 1 ]] && package="guardrails-ai[api]"
    "$(venv_python)" -m pip install --upgrade "$package"
    cmd_status
}

cmd_uninstall() {
    if [[ -d "$VENV_DIR" ]]; then
        rm -rf "$VENV_DIR"
        log_info "已删除虚拟环境: $VENV_DIR"
    else
        log_warn "虚拟环境不存在: $VENV_DIR"
    fi
}

cmd_status() {
    if [[ -x "$(venv_guardrails)" ]]; then
        log_info "guardrails: $(venv_guardrails)"
        "$(venv_guardrails)" --version || true
        "$(venv_python)" -m pip show guardrails-ai | sed -n '1,8p' || true
    else
        log_warn "Guardrails AI 未安装: $VENV_DIR"
        return 1
    fi
}

cmd_configure() {
    ensure_installed
    "$(venv_guardrails)" configure
}

cmd_hub_install() {
    ensure_installed
    if [[ $# -eq 0 ]]; then
        log_error "请提供 validator URI，例如: hub://guardrails/regex_match"
        return 1
    fi
    "$(venv_guardrails)" hub install "$@"
}

cmd_init_demo() {
    ensure_installed
    local target_dir="${1:-.}/guardrails-demo"
    mkdir -p "$target_dir"
    cat > "$target_dir/demo.py" <<'PY'
from guardrails import Guard
from guardrails.hub import RegexMatch

guard = Guard().use(RegexMatch(regex=r"^[A-Z][a-z]*$"))

for text in ["Caesar", "Caesar Salad"]:
    result = guard.parse(text)
    print(f"{text}: validation_passed={result.validation_passed}")
PY
    cat > "$target_dir/README.md" <<'EOF'
# Guardrails AI Demo

Run:

```bash
guardrails hub install hub://guardrails/regex_match
python demo.py
```

If you use this repository script:

```bash
security/code-security/guardrails-ai.sh hub-install hub://guardrails/regex_match
security/code-security/guardrails-ai.sh run-demo .
```
EOF
    log_info "已生成示例: $target_dir"
}

cmd_run_demo() {
    ensure_installed
    local demo_file="${1:-.}/guardrails-demo/demo.py"
    if [[ ! -f "$demo_file" ]]; then
        log_error "未找到 demo.py，请先执行: $0 init-demo ${1:-.}"
        return 1
    fi
    "$(venv_python)" "$demo_file"
}

cmd_start_server() {
    ensure_installed
    local config="${1:-}"
    if [[ -z "$config" || ! -f "$config" ]]; then
        log_error "请提供 Guardrails config.py，例如: $0 start-server ./config.py"
        return 1
    fi
    "$(venv_guardrails)" start --config="$config"
}

main() {
    local command="${1:-help}"
    shift || true

    REMAINING_ARGS=()
    parse_common_options "$@"
    set -- "${REMAINING_ARGS[@]+"${REMAINING_ARGS[@]}"}"

    case "$command" in
        install) cmd_install "$@" ;;
        update) cmd_update "$@" ;;
        uninstall) cmd_uninstall "$@" ;;
        status) cmd_status "$@" ;;
        configure) cmd_configure "$@" ;;
        hub-install) cmd_hub_install "$@" ;;
        init-demo) cmd_init_demo "$@" ;;
        run-demo) cmd_run_demo "$@" ;;
        start-server) cmd_start_server "$@" ;;
        -h|--help|help) show_help ;;
        *)
            log_error "未知命令: $command"
            show_help
            return 1
            ;;
    esac
}

main "$@"
