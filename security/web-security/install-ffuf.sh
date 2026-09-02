#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/web-tools-common.sh"

web_parse_args "$@" || {
  [[ "$?" -eq 10 ]] && cat <<'EOF'
用法：install-ffuf.sh [--dry-run]
安装 ffuf Web 路径、参数模糊测试工具。
EOF
  exit 0
}
web_show_plan ffuf 'Web 路径和参数模糊测试'
[[ "$WEB_TOOLS_DRY_RUN" -eq 1 ]] && { web_log '预演模式：未执行任何安装。'; exit 0; }
web_require_platform
web_install_prerequisites go
web_prepare
if [[ ! -x "$WEB_TOOLS_BIN/ffuf" ]]; then
  GOBIN="$WEB_TOOLS_BIN" go install github.com/ffuf/ffuf/v2@latest
else
  web_log 'ffuf 已存在，跳过下载。'
fi
[[ -x "$WEB_TOOLS_BIN/ffuf" ]] || web_die 'ffuf 安装后未找到可执行文件。'
web_finish ffuf
