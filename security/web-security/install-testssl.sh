#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/web-tools-common.sh"

web_parse_args "$@" || {
  [[ "$?" -eq 10 ]] && cat <<'EOF'
用法：install-testssl.sh [--dry-run]
安装 testssl.sh TLS/SSL 配置检查工具。
EOF
  exit 0
}
web_show_plan testssl.sh 'TLS/SSL 配置检查'
[[ "$WEB_TOOLS_DRY_RUN" -eq 1 ]] && { web_log '预演模式：未执行任何安装。'; exit 0; }
web_require_platform
web_install_prerequisites git
web_prepare
target="$WEB_TOOLS_ROOT/testssl.sh"
if [[ ! -f "$target/testssl.sh" ]]; then
  git clone --depth 1 https://github.com/testssl/testssl.sh.git "$target"
else
  web_log 'testssl.sh 已存在，跳过下载。'
fi
web_link "$target/testssl.sh" testssl.sh
web_finish testssl.sh
