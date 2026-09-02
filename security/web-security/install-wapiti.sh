#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/web-tools-common.sh"

web_parse_args "$@" || {
  [[ "$?" -eq 10 ]] && cat <<'EOF'
用法：install-wapiti.sh [--dry-run]
安装 Wapiti 黑盒 Web 漏洞扫描器。
EOF
  exit 0
}
web_show_plan Wapiti '黑盒 Web 漏洞扫描'
[[ "$WEB_TOOLS_DRY_RUN" -eq 1 ]] && { web_log '预演模式：未执行任何安装。'; exit 0; }
web_require_platform
web_install_prerequisites python3
web_prepare
venv="$WEB_TOOLS_ROOT/python-venv"
[[ -x "$venv/bin/python" ]] || python3 -m venv "$venv"
"$venv/bin/python" -m pip install --upgrade wapiti3
web_link "$venv/bin/wapiti" wapiti
web_finish Wapiti
