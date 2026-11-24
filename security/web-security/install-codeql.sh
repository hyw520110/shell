#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/web-tools-common.sh"

web_parse_args "$@" || {
  [[ "$?" -eq 10 ]] && cat <<'EOF'
用法：install-codeql.sh [--dry-run]
安装 CodeQL CLI 源码安全分析工具。
EOF
  exit 0
}
web_show_plan CodeQL '源码安全分析（非 Web DAST 扫描）'
[[ "$WEB_TOOLS_DRY_RUN" -eq 1 ]] && { web_log '预演模式：未执行任何安装。'; exit 0; }
web_require_platform
web_install_prerequisites curl
web_prepare

case "$WEB_TOOLS_OS:$WEB_TOOLS_ARCH" in
  Darwin:x86_64|Darwin:arm64) asset_name='codeql-bundle-osx64.tar.gz' ;;
  Linux:x86_64|Linux:amd64) asset_name='codeql-bundle-linux64.tar.gz' ;;
  *) web_die "CodeQL CLI 暂不支持当前平台：$WEB_TOOLS_OS/$WEB_TOOLS_ARCH" ;;
esac

if [[ -x "$WEB_TOOLS_BIN/codeql/codeql" ]]; then
  web_log 'CodeQL CLI 已存在，跳过下载。'
else
  asset_url="$(curl -fsSL --connect-timeout 10 --max-time 30 \
    https://api.github.com/repos/github/codeql-cli-binaries/releases/latest \
    | tr ',' '\n' \
    | sed -nE 's/.*"browser_download_url"[[:space:]]*:[[:space:]]*"([^"]*'"$asset_name"'[^" ]*)".*/\1/p' \
    | head -n 1)"
  [[ -n "$asset_url" ]] || web_die "无法找到 CodeQL 官方安装包：$asset_name"
  temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/web-tools-codeql.XXXXXX")"
  trap 'rm -rf "$temp_dir"' EXIT HUP INT TERM
  web_log '下载 CodeQL CLI 官方发布包'
  curl -fL --progress-bar "$asset_url" -o "$temp_dir/codeql.tar.gz"
  mkdir -p "$WEB_TOOLS_BIN/codeql"
  tar -xzf "$temp_dir/codeql.tar.gz" -C "$WEB_TOOLS_BIN/codeql" --strip-components=1
  [[ -x "$WEB_TOOLS_BIN/codeql/codeql" ]] || web_die 'CodeQL 解压后未找到 codeql 可执行文件。'
  trap - EXIT HUP INT TERM
  rm -rf "$temp_dir"
fi
web_finish CodeQL
