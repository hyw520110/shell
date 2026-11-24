#!/usr/bin/env bash
# ============================================================================
# Feroxbuster - 内容/目录爆破工具（epi052）
#
# 一键安装配置： ./feroxbuster.sh install
# 卸载：         ./feroxbuster.sh uninstall --yes
# 目录枚举：     ./feroxbuster.sh fuzz -u https://example.com --ack-authorized
#
# 目录爆破属于主动行为，仅限你有权测试的目标。默认低并发，可 -t/-r 调整。
# 环境变量：FEROXBUSTER_VERSION（固定版本）、GITHUB_TOKEN（可选，仅 API 鉴权）
# ============================================================================
set -euo pipefail

TOOL_NAME="Feroxbuster"
BIN_NAME="feroxbuster"
REPO="epi052/feroxbuster"

SOURCE_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=recon-common.sh
source "$SOURCE_DIR/recon-common.sh"

TOOL_ROOT="$RECON_ROOT/$BIN_NAME"
WORDLIST_DIR="${FEROXBUSTER_WORDLIST_DIR:-$TOOL_ROOT/wordlists}"
WORDLIST="$WORDLIST_DIR/raft-medium-directories.txt"

fb_triple() {
  local os arch
  case "$RECON_OS_TYPE" in
    Darwin) os='macos' ;;
    Linux) os='linux' ;;
  esac
  case "$RECON_OS_ARCH" in
    x86_64|amd64) arch='x86_64' ;;
    arm64|aarch64) arch='aarch64' ;;
  esac
  printf '%s-%s\n' "$arch" "$os"
}

show_help() {
  cat <<EOF
用法：$0 <命令> [参数]

安装 / 配置 / 卸载：
  install                 一键安装并准备默认字典
  update                  更新到最新版本
  config [--force]        重新下载默认字典
  status / version        显示安装位置与版本
  uninstall --yes         卸载本脚本安装的部分

枚举（仅限已授权目标）：
  fuzz -u <URL> [-w 字典] [-t 线程] [--ack-authorized]

示例：
  $0 install
  $0 fuzz -u https://example.com --ack-authorized

环境变量：FEROXBUSTER_VERSION、FEROXBUSTER_WORDLIST_DIR、GITHUB_TOKEN
          RECON_ROOT / RECON_BIN_DIR / RECON_DOWNLOAD_DIR（见 recon-common.sh）
EOF
}

usage_hint() {
  cat <<EOF

$TOOL_NAME 使用提示：
  目录枚举（需授权确认）：
    $0 fuzz -u https://example.com -t 10 --ack-authorized
  默认字典：$WORDLIST
  结果默认写入 ~/security-scans/feroxbuster/
EOF
}

cmd_config() {
  mkdir -p "$WORDLIST_DIR" "$TOOL_ROOT"
  if [ -s "$WORDLIST" ] && [ "${1:-}" != "--force" ]; then
    recon_log "默认字典已存在，跳过：${WORDLIST}（强制重下：config --force）"
    return 0
  fi
  recon_log "下载默认字典（SecLists raft-medium-directories）..."
  curl -fsSL --retry 2 --connect-timeout 10 \
    -o "$WORDLIST" \
    'https://raw.githubusercontent.com/danielmiessler/SecLists/master/Discovery/Web-Content/raft-medium-directories.txt' \
    && [ -s "$WORDLIST" ] || { rm -f "$WORDLIST"; recon_warn "字典下载失败（可指定其他字典，不影响二进制安装）"; return 0; }
  recon_ok "默认字典已就绪：$WORDLIST"
}

do_install() {
  recon_require_platform
  recon_require_prereqs curl
  local triple version regex url
  triple="$(fb_triple)"
  regex="^.*${triple}-feroxbuster\\.tar\\.gz\$"
  version="$(recon_pick_version "$REPO" "${FEROXBUSTER_VERSION:-}" || true)"
  [ -n "$version" ] || recon_die "无法获取 $TOOL_NAME 最新版本（可设置 FEROXBUSTER_VERSION 固定版本）"
  url="$(recon_asset_url "$REPO" "$version" "$regex" || true)"
  [ -n "$url" ] || recon_die "未找到适用于 ${triple} 的官方安装包"
  recon_log "安装 $TOOL_NAME v${version}（${triple}）"
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
    ver="$("$bin" --version 2>&1 | sed -nE 's/.*v?([0-9]+\.[0-9]+\.[0-9]+).*/\1/p' | head -n1)"
    printf '%s: 已安装\n  路径: %s\n  版本: %s\n' "$TOOL_NAME" "$bin" "${ver:-未知}"
  else
    printf '%s: 未安装（先执行 %s install）\n' "$TOOL_NAME" "$0"
  fi
  printf '  字典: %s\n  数据目录: %s\n' "$WORDLIST" "$TOOL_ROOT"
}

cmd_fuzz() {
  local url="" threads="10" wordlist="" ack=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -u|--url) [ "$#" -ge 2 ] || recon_die "$1 需要参数"; url="$2"; shift 2 ;;
      -w|--wordlist) [ "$#" -ge 2 ] || recon_die "$1 需要参数"; wordlist="$2"; shift 2 ;;
      -t|--threads) [ "$#" -ge 2 ] || recon_die "$1 需要参数"; threads="$2"; shift 2 ;;
      --ack-authorized) ack=1; shift ;;
      -h|--help) show_help; return 0 ;;
      *) recon_die "未知参数：$1（运行 $0 --help 查看帮助）" ;;
    esac
  done
  [ -n "$url" ] || recon_die "需要 -u <URL>。"
  [ "$ack" -eq 1 ] || recon_die "目录枚举需要 --ack-authorized 确认已获授权。"
  case "$threads" in
    *[!0-9]*) recon_die "-t 必须是正整数。" ;;
    *) [ "$threads" -gt 0 ] 2>/dev/null || recon_die "-t 必须是正整数。" ;;
  esac
  local bin
  bin="$(recon_resolve_bin "$BIN_NAME" || true)"
  [ -n "$bin" ] || recon_die "$TOOL_NAME 未安装，请先执行：$0 install"
  if [ -z "$wordlist" ]; then
    if [ -s "$WORDLIST" ]; then
      wordlist="$WORDLIST"
    else
      recon_warn "未找到默认字典（${WORDLIST}）；请用 -w <字典> 指定。"
    fi
  fi
  local safe out
  safe="$(printf '%s' "$url" | tr -c 'a-zA-Z0-9.-' '_')"
  out="$HOME/security-scans/feroxbuster/${safe}-$(date +%Y%m%d-%H%M%S).txt"
  mkdir -p "$(dirname "$out")"
  local -a args=(-u "$url" -t "$threads" -T 5 -k -q -m GET -o "$out")
  [ -n "$wordlist" ] && args+=(-w "$wordlist")
  recon_log "目录枚举：${url}（线程 ${threads}，结果：${out}）"
  "$bin" "${args[@]}" || true
  if [ -s "$out" ]; then
    recon_ok "完成：共 $(wc -l < "$out" | tr -d ' ') 条结果，输出：$out"
  else
    rm -f "$out"
    recon_log "未发现匹配结果，已清理空文件。"
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
    fuzz) shift; cmd_fuzz "$@" ;;
    -h|--help|help) show_help ;;
    *) recon_die "未知命令：$1（运行 $0 --help 查看帮助）" ;;
  esac
}

main "$@"