#!/usr/bin/env bash
# ============================================================================
# Naabu - 端口扫描工具（ProjectDiscovery）
#
# 一键安装配置： ./naabu.sh install
# 卸载：         ./naabu.sh uninstall --yes
# 端口扫描：     ./naabu.sh scan example.com [-p 80,443,8443] --ack-authorized
#
# 端口扫描属于主动行为，仅限你有权测试的主机/网络。
# 环境变量：NAABU_VERSION（固定版本）、GITHUB_TOKEN（可选，仅 API 鉴权）
# ============================================================================
set -euo pipefail

TOOL_NAME="Naabu"
BIN_NAME="naabu"
REPO="projectdiscovery/naabu"

SOURCE_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=recon-common.sh
source "$SOURCE_DIR/recon-common.sh"

TOOL_ROOT="$RECON_ROOT/$BIN_NAME"

nb_os() {
  case "$RECON_OS_TYPE" in
    Darwin) printf 'macOS' ;;
    Linux) printf 'linux' ;;
  esac
}

nb_arch() {
  case "$RECON_OS_ARCH" in
    x86_64|amd64) printf 'amd64' ;;
    arm64|aarch64) printf 'arm64' ;;
  esac
}

show_help() {
  cat <<EOF
用法：$0 <命令> [参数]

安装 / 配置 / 卸载：
  install                 一键安装
  update                  更新到最新版本
  status / version        显示安装位置与版本
  uninstall --yes         卸载本脚本安装的部分

扫描（仅限已授权主机）：
  scan <host> [-p 端口列表] [--ack-authorized]

示例：
  $0 install
  $0 scan example.com -p 80,443,8080-8090 --ack-authorized

环境变量：NAABU_VERSION、GITHUB_TOKEN
          RECON_ROOT / RECON_BIN_DIR / RECON_DOWNLOAD_DIR（见 recon-common.sh）
EOF
}

usage_hint() {
  cat <<EOF

$TOOL_NAME 使用提示：
  端口扫描（需授权确认）：
    $0 scan example.com -p 80,443,8080-8090 --ack-authorized
  结果默认写入 ~/security-scans/naabu/
  未指定 -p 时默认只扫 80/443，降低影响。
EOF
}

do_install() {
  recon_require_platform
  recon_require_prereqs curl
  local os arch version regex url
  os="$(nb_os)"
  arch="$(nb_arch)"
  regex="_${os}_${arch}\\.zip\$"
  version="$(recon_pick_version "$REPO" "${NAABU_VERSION:-}" || true)"
  [ -n "$version" ] || recon_die "无法获取 $TOOL_NAME 最新版本（可设置 NAABU_VERSION 固定版本）"
  url="$(recon_asset_url "$REPO" "$version" "$regex" || true)"
  [ -n "$url" ] || recon_die "未找到适用于 ${os}/${arch} 的官方安装包"
  recon_log "安装 $TOOL_NAME v${version}（${os}/${arch}）"
  recon_install_asset "$BIN_NAME" "$url"
  recon_mark_managed "$TOOL_ROOT"
  recon_path_hint
  recon_ok "$TOOL_NAME v${version} 安装完成。"
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
  printf '  数据目录: %s\n' "$TOOL_ROOT"
}

cmd_scan() {
  local host="" ports="80,443" ack=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -p|--ports) [ "$#" -ge 2 ] || recon_die "$1 需要参数"; ports="$2"; shift 2 ;;
      --ack-authorized) ack=1; shift ;;
      -h|--help) show_help; return 0 ;;
      -*) recon_die "未知参数：$1（运行 $0 --help 查看帮助）" ;;
      *) [ -z "$host" ] && host="$1" || recon_die "只能指定一个目标：$1"; shift ;;
    esac
  done
  [ -n "$host" ] || recon_die "需要目标主机，例如：$0 scan example.com --ack-authorized"
  [ "$ack" -eq 1 ] || recon_die "端口扫描需要 --ack-authorized 确认已获授权。"
  local bin
  bin="$(recon_resolve_bin "$BIN_NAME" || true)"
  [ -n "$bin" ] || recon_die "$TOOL_NAME 未安装，请先执行：$0 install"
  local safe out
  safe="$(printf '%s' "$host" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9.-' '_')"
  out="$HOME/security-scans/naabu/${safe}-$(date +%Y%m%d-%H%M%S).txt"
  mkdir -p "$(dirname "$out")"
  recon_log "端口扫描：${host} 端口 ${ports}（结果：${out}）"
  "$bin" -host "$host" -ports "$ports" -c 5 -rate 50 -silent -o "$out" || true
  if [ -s "$out" ]; then
    recon_ok "完成：共 $(wc -l < "$out" | tr -d ' ') 个端口，输出：$out"
  else
    rm -f "$out"
    recon_log "未发现开放端口，已清理空结果。"
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
    status|version) cmd_status ;;
    uninstall) shift; cmd_uninstall "$@" ;;
    scan) shift; cmd_scan "$@" ;;
    -h|--help|help) show_help ;;
    *) recon_die "未知命令：$1（运行 $0 --help 查看帮助）" ;;
  esac
}

main "$@"