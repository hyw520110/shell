#!/usr/bin/env bash
# ============================================================================
# Subfinder - 被动子域名发现工具（ProjectDiscovery）
#
# 一键安装配置： ./subfinder.sh install
# 卸载：         ./subfinder.sh uninstall --yes
# 被动枚举：     ./subfinder.sh subdomains -d example.com --ack-authorized
#
# 默认仅做被动数据源查询，不启用主动爆破，仅限你有权收集的域名。
# 环境变量：SUBFINDER_VERSION（固定版本）、SUBFINDER_CONFIG（配置文件路径）、
#           GITHUB_TOKEN（可选，仅用于避开 GitHub API 限流）
# ============================================================================
set -euo pipefail

TOOL_NAME="Subfinder"
BIN_NAME="subfinder"
REPO="projectdiscovery/subfinder"

SOURCE_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=recon-common.sh
source "$SOURCE_DIR/recon-common.sh"

TOOL_ROOT="$RECON_ROOT/$BIN_NAME"
CONFIG_DIR="${SUBFINDER_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/subfinder}"
CONFIG_FILE="${SUBFINDER_CONFIG:-$CONFIG_DIR/provider-config.yaml}"

sf_os() {
  case "$RECON_OS_TYPE" in
    Darwin) printf 'macOS' ;;
    Linux) printf 'linux' ;;
  esac
}

sf_arch() {
  case "$RECON_OS_ARCH" in
    x86_64|amd64) printf 'amd64' ;;
    arm64|aarch64) printf 'arm64' ;;
  esac
}

show_help() {
  cat <<EOF
用法：$0 <命令> [参数]

安装 / 配置 / 卸载：
  install                 一键安装并生成数据源配置模板
  update                  更新到最新版本
  config [--force]        重新生成数据源配置模板
  status / version        显示安装位置与版本
  uninstall --yes         卸载本脚本安装的部分

枚举（仅限已授权域名）：
  subdomains -d <域名> --ack-authorized   被动子域名枚举（无语爆/主动探测）

示例：
  $0 install
  $0 subdomains -d example.com --ack-authorized

环境变量：SUBFINDER_VERSION、SUBFINDER_CONFIG、GITHUB_TOKEN
          RECON_ROOT / RECON_BIN_DIR / RECON_DOWNLOAD_DIR（见 recon-common.sh）
EOF
}

usage_hint() {
  cat <<EOF

$TOOL_NAME 使用提示：
  被动枚举（需授权确认）：
    $0 subdomains -d example.com --ack-authorized
  结果默认写入 ~/security-scans/subfinder/
  如需启用更多数据源，编辑：$CONFIG_FILE
EOF
}

cmd_config() {
  mkdir -p "$CONFIG_DIR" "$TOOL_ROOT"
  if [ -f "$CONFIG_FILE" ] && [ "${1:-}" != "--force" ]; then
    recon_log "已存在配置文件，跳过：${CONFIG_FILE}（强制重写：config --force）"
    return 0
  fi
  cat > "$CONFIG_FILE" <<'EOF'
# Subfinder 数据源配置模板（recon-tools 自动生成）
# 需要启用哪些被动数据源就填写对应密钥，其余留空即可。
# 参考：https://github.com/projectdiscovery/subfinder
resolvers:
  - 8.8.8.8
  - 1.1.1.1

# 常见数据源示例（按需取消注释并填写）：
# securitytrails: ["your-key-here"]
# censys: ["user:pass"]
# c99: ["your-key-here"]
# shodan: ["your-key-here"]
# chaos: ["your-key-here"]
# 注意：密钥只保存在本机，不要提交到任何仓库。
EOF
  recon_ok "已生成数据源配置模板：${CONFIG_FILE}（填写密钥后即可使用）"
}

do_install() {
  recon_require_platform
  recon_require_prereqs curl
  local os arch version regex url
  os="$(sf_os)"
  arch="$(sf_arch)"
  regex="_${os}_${arch}\\.zip\$"
  version="$(recon_pick_version "$REPO" "${SUBFINDER_VERSION:-}" || true)"
  [ -n "$version" ] || recon_die "无法获取 $TOOL_NAME 最新版本（可设置 SUBFINDER_VERSION 固定版本）"
  url="$(recon_asset_url "$REPO" "$version" "$regex" || true)"
  [ -n "$url" ] || recon_die "未找到适用于 ${os}/${arch} 的官方安装包"
  recon_log "安装 $TOOL_NAME v${version}（${os}/${arch}）"
  recon_install_asset "$BIN_NAME" "$url"
  recon_mark_managed "$TOOL_ROOT"
  cmd_config || true
  recon_path_hint
  recon_ok "$TOOL_NAME v${version} 安装并配置完成。"
  usage_hint
}

cmd_install() { do_install; }
cmd_update()  { do_install; }

cmd_status() {
  recon_require_platform
  local bin ver
  if bin="$(recon_resolve_bin "$BIN_NAME" || true)" && [ -n "$bin" ]; then
    ver="$("$bin" -version 2>&1 | sed -nE 's/.*v?([0-9]+\.[0-9]+\.[0-9]+).*/\1/p' | head -n1)"
    printf '%s: 已安装\n  路径: %s\n  版本: %s\n' "$TOOL_NAME" "$bin" "${ver:-未知}"
  else
    printf '%s: 未安装（先执行 %s install）\n' "$TOOL_NAME" "$0"
  fi
  printf '  配置: %s\n  数据目录: %s\n' "$CONFIG_FILE" "$TOOL_ROOT"
}

cmd_subdomains() {
  local target="" ack=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -d) [ "$#" -ge 2 ] || recon_die "-d 需要域名参数"; target="$2"; shift 2 ;;
      --ack-authorized) ack=1; shift ;;
      -h|--help) show_help; return 0 ;;
      *) recon_die "未知参数：$1（运行 $0 --help 查看帮助）" ;;
    esac
  done
  [ -n "$target" ] || recon_die "需要 -d <域名>。"
  [ "$ack" -eq 1 ] || recon_die "被动枚举需要 --ack-authorized 确认已获授权。"
  local bin
  bin="$(recon_resolve_bin "$BIN_NAME" || true)"
  [ -n "$bin" ] || recon_die "$TOOL_NAME 未安装，请先执行：$0 install"
  local safe out
  safe="$(printf '%s' "$target" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9.-' '_')"
  out="$HOME/security-scans/subfinder/${safe}-$(date +%Y%m%d-%H%M%S).txt"
  mkdir -p "$(dirname "$out")"
  local -a cfg=()
  [ -f "$CONFIG_FILE" ] && cfg=(-config "$CONFIG_FILE")
  recon_log "被动枚举子域名：${target}（结果：${out}）"
  "$bin" -d "$target" -all -silent "${cfg[@]}" -o "$out" || true
  if [ -s "$out" ]; then
    recon_ok "完成：共 $(wc -l < "$out" | tr -d ' ') 条，输出：$out"
  else
    rm -f "$out"
    recon_log "未发现子域名，已清理空结果。"
  fi
}

cmd_uninstall() {
  recon_uninstall "$TOOL_NAME" "$BIN_NAME" "$TOOL_ROOT" "$@"
}

main() {
  [ "$#" -gt 0 ] || { show_help; exit 0; }
  case "$1" in
    install) cmd_install ;;
    update) cmd_update ;;
    config) shift; cmd_config "$@" ;;
    status|version) cmd_status ;;
    uninstall) shift; cmd_uninstall "$@" ;;
    subdomains) shift; cmd_subdomains "$@" ;;
    -h|--help|help) show_help ;;
    *) recon_die "未知命令：$1（运行 $0 --help 查看帮助）" ;;
  esac
}

main "$@"