#!/usr/bin/env bash
# ============================================================================
# Amass - 资产枚举与外部攻击面映射（OWASP）
#
# 一键安装配置： ./amass.sh install
# 卸载：         ./amass.sh uninstall --yes
# 被动枚举：     ./amass.sh enum -d example.com --ack-authorized
#
# 本脚本默认只使用 passive 模式（公开数据源，不做主动爆破/爬取）。
# 仅限你有权收集的域名。
# 环境变量：AMASS_VERSION（固定版本）、GITHUB_TOKEN（可选，仅 API 鉴权）
# ============================================================================
set -euo pipefail

TOOL_NAME="Amass"
BIN_NAME="amass"
REPO="owasp-amass/amass"

SOURCE_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=recon-common.sh
source "$SOURCE_DIR/recon-common.sh"

TOOL_ROOT="$RECON_ROOT/$BIN_NAME"
CONFIG_DIR="${AMASS_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/amass}"
CONFIG_FILE="${AMASS_CONFIG:-$CONFIG_DIR/config.ini}"

am_os() {
  case "$RECON_OS_TYPE" in
    Darwin) printf 'darwin' ;;
    Linux) printf 'linux' ;;
  esac
}

am_arch() {
  case "$RECON_OS_ARCH" in
    x86_64|amd64) printf 'amd64' ;;
    arm64|aarch64) printf 'arm64' ;;
  esac
}

show_help() {
  cat <<EOF
用法：$0 <命令> [参数]

安装 / 配置 / 卸载：
  install                 一键安装并生成配置文件
  update                  更新到最新版本
  config [--force]        重新生成配置模板
  status / version        显示安装位置与版本
  uninstall --yes         卸载本脚本安装的部分

枚举（仅限已授权域名，passive 模式）：
  enum -d <域名> --ack-authorized

示例：
  $0 install
  $0 enum -d example.com --ack-authorized

环境变量：AMASS_VERSION、AMASS_CONFIG、GITHUB_TOKEN
          RECON_ROOT / RECON_BIN_DIR / RECON_DOWNLOAD_DIR（见 recon-common.sh）
EOF
}

usage_hint() {
  cat <<EOF

$TOOL_NAME 使用提示：
  被动枚举（需授权确认）：
    $0 enum -d example.com --ack-authorized
  配置文件：${CONFIG_FILE}（passive 模式默认使用公开数据源，无需密钥）
EOF
}

cmd_config() {
  mkdir -p "$CONFIG_DIR" "$TOOL_ROOT"
  if [ -f "$CONFIG_FILE" ] && [ "${1:-}" != "--force" ]; then
    recon_log "已存在配置文件，跳过：${CONFIG_FILE}（强制重写：config --force）"
    return 0
  fi
  cat > "$CONFIG_FILE" <<'EOF'
; Amass 配置模板（recon-tools 自动生成）
; 保存为 ~/.config/amass/config.ini 即可生效。
[configuration]
greeting = false

; passive 模式使用 crt.sh、IPinfo 等公开数据源，一般无需额外密钥。
; 如需接入更多被动数据源，请参考：
; https://github.com/owasp-amass/amass/blob/master/examples/config.ini
EOF
  recon_ok "已生成配置模板：$CONFIG_FILE"
}

do_install() {
  recon_require_platform
  recon_require_prereqs curl
  local os arch version regex url
  os="$(am_os)"
  arch="$(am_arch)"
  regex="_${os}_${arch}\\.tar\\.gz\$"
  version="$(recon_pick_version "$REPO" "${AMASS_VERSION:-}" || true)"
  [ -n "$version" ] || recon_die "无法获取 $TOOL_NAME 最新版本（可设置 AMASS_VERSION 固定版本）"
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

cmd_enum() {
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
  out="$HOME/security-scans/amass/${safe}-$(date +%Y%m%d-%H%M%S).txt"
  mkdir -p "$(dirname "$out")"
  recon_log "被动枚举资产：${target}（结果：${out}）"
  "$bin" enum -passive -nocolor -d "$target" | tee "$out" || true
  if [ -s "$out" ]; then
    recon_ok "完成：共 $(wc -l < "$out" | tr -d ' ') 条，输出：$out"
  else
    rm -f "$out"
    recon_log "未发现资产，已清理空结果。"
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
    enum) shift; cmd_enum "$@" ;;
    -h|--help|help) show_help ;;
    *) recon_die "未知命令：$1（运行 $0 --help 查看帮助）" ;;
  esac
}

main "$@"