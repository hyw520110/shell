#!/usr/bin/env bash
# ============================================================================
# Gitleaks - 代码 / Git 仓库密钥泄露扫描（gitleaks）
#
# 一键安装配置： ./gitleaks.sh install
# 卸载：         ./gitleaks.sh uninstall --yes
# 扫描仓库：     ./gitleaks.sh detect [路径]
#
# 扫描的是本地仓库/目录，不触碰网络目标。发现结果仅作提示，不做任何外传。
# 环境变量：GITLEAKS_VERSION（固定版本）、GITLEAKS_CONFIG（自定义配置）、GITHUB_TOKEN
# ============================================================================
set -euo pipefail

TOOL_NAME="Gitleaks"
BIN_NAME="gitleaks"
REPO="gitleaks/gitleaks"

SOURCE_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=recon-common.sh
source "$SOURCE_DIR/recon-common.sh"

TOOL_ROOT="$RECON_ROOT/$BIN_NAME"
CONFIG_DIR="${GITLEAKS_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/gitleaks}"
CONFIG_FILE="${GITLEAKS_CONFIG:-}"

gl_os() {
  case "$RECON_OS_TYPE" in
    Darwin) printf 'darwin' ;;
    Linux) printf 'linux' ;;
  esac
}

gl_arch() {
  case "$RECON_OS_ARCH" in
    x86_64|amd64) printf 'x64' ;;
    arm64|aarch64) printf 'arm64' ;;
  esac
}

show_help() {
  cat <<EOF
用法：$0 <命令> [参数]

安装 / 配置 / 卸载：
  install                 一键安装（Gitleaks 自带默认规则，无需额外配置）
  update                  更新到最新版本
  status / version        显示安装位置与版本
  uninstall --yes         卸载本脚本安装的部分

扫描（本地仓库 / 目录）：
  detect [路径] [--no-banner]

示例：
  $0 install
  $0 detect                      # 扫描当前目录（Git 仓库）
  $0 detect /path/to/repo

环境变量：GITLEAKS_VERSION、GITLEAKS_CONFIG、GITHUB_TOKEN
          RECON_ROOT / RECON_BIN_DIR / RECON_DOWNLOAD_DIR（见 recon-common.sh）
EOF
}

usage_hint() {
  cat <<EOF

$TOOL_NAME 使用提示：
  扫描当前/指定 Git 仓库（不触碰网络）：
    $0 detect
    $0 detect /path/to/repo
  默认规则覆盖 AWS/GitHub/API Key 等常见密钥类型，无需额外配置。
EOF
}

do_install() {
  recon_require_platform
  recon_require_prereqs curl
  local os arch version regex url
  os="$(gl_os)"
  arch="$(gl_arch)"
  regex="_${os}_${arch}\\.tar\\.gz\$"
  version="$(recon_pick_version "$REPO" "${GITLEAKS_VERSION:-}" || true)"
  [ -n "$version" ] || recon_die "无法获取 $TOOL_NAME 最新版本（可设置 GITLEAKS_VERSION 固定版本）"
  url="$(recon_asset_url "$REPO" "$version" "$regex" || true)"
  [ -n "$url" ] || recon_die "未找到适用于 ${os}/${arch} 的官方安装包"
  recon_log "安装 $TOOL_NAME v${version}（${os}/${arch}）"
  recon_install_asset "$BIN_NAME" "$url"
  recon_mark_managed "$TOOL_ROOT"
  mkdir -p "$CONFIG_DIR"
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
    ver="$("$bin" version 2>&1 | sed -nE 's/.*v?([0-9]+\.[0-9]+\.[0-9]+).*/\1/p' | head -n1)"
    printf '%s: 已安装\n  路径: %s\n  版本: %s\n' "$TOOL_NAME" "$bin" "${ver:-未知}"
  else
    printf '%s: 未安装（先执行 %s install）\n' "$TOOL_NAME" "$0"
  fi
  printf '  配置目录: %s\n  数据目录: %s\n' "$CONFIG_DIR" "$TOOL_ROOT"
}

cmd_detect() {
  local target="" no_banner=0 rc=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --no-banner) no_banner=1; shift ;;
      -h|--help) show_help; return 0 ;;
      -*) recon_die "未知参数：$1（运行 $0 --help 查看帮助）" ;;
      *) [ -z "$target" ] && target="$1" || recon_die "只能指定一个路径：$1"; shift ;;
    esac
  done
  [ -n "$target" ] || target="."
  [ -d "$target" ] || recon_die "路径不是目录：$target"
  local bin
  bin="$(recon_resolve_bin "$BIN_NAME" || true)"
  [ -n "$bin" ] || recon_die "$TOOL_NAME 未安装，请先执行：$0 install"
  local -a args=(detect "$target")
  [ "$no_banner" -eq 1 ] && args+=("--no-banner")
  if [ -n "$CONFIG_FILE" ]; then
    [ -f "$CONFIG_FILE" ] || recon_die "自定义配置不存在：$CONFIG_FILE"
    args+=(--config "$CONFIG_FILE")
  fi
  recon_log "扫描本地位置：$target"
  "$bin" "${args[@]}" || rc=$?
  case "$rc" in
    0) recon_ok "未发现密钥泄漏。" ;;
    1) recon_warn "检测到潜在密钥泄漏（仅提示，不外传）。" ;;
    *) recon_warn "gitleaks 执行异常（退出码 ${rc}），可能是路径无 Git 仓库或权限问题。" ;;
  esac
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
    detect) shift; cmd_detect "$@" ;;
    -h|--help|help) show_help ;;
    *) recon_die "未知命令：$1（运行 $0 --help 查看帮助）" ;;
  esac
}

main "$@"