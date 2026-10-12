#!/usr/bin/env bash
# ============================================================================
# Terrapin-Scanner 安装与扫描封装 (RUB-NDS/Terrapin-Scanner)
#
# 用途：
#   Terrapin-Scanner 是一个用于判断 SSH 客户端/服务器是否受 Terrapin 攻击
#   (CVE-2023-48795) 影响的工具。它以单个 TCP 连接向对端收集全部支持的算法，
#   通过检查算法与是否支持 countermeasure（strict key exchange）来判断脆弱性。
#   它不执行完整 SSH 密钥交换、不尝试认证、也不实际发起攻击。
#
# 安装方式（按优先级）：
#   1. go install github.com/RUB-NDS/Terrapin-Scanner@latest  (任意平台)
#   2. brew install terrapin-scanner                            (macOS/Linux brew)
#   二进制名称为 `Terrapin-Scanner`（注意大小写与连字符）。
#
# 用法：
#   ./terrapin.sh install [go|brew]
#   ./terrapin.sh status
#   ./terrapin.sh scan --connect <host:port> [--json] [-o 报告文件]
#   ./terrapin.sh uninstall --yes
#
# 注意：本扫描仅针对单个 SSH 端点做单次连接探测，不扫描网段、不爆破、不认证，
# 属于低影响安全扫描。请仅对你有权测试的主机执行。
# ============================================================================

set -euo pipefail

SCRIPT_PATH="${BASH_SOURCE[0]}"
while [[ -L "$SCRIPT_PATH" ]]; do
  SCRIPT_PATH="$(readlink "$SCRIPT_PATH")"
done
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"

TERRAPIN_VERSION="${TERRAPIN_VERSION:-latest}"
TERRAPIN_ROOT="${TERRAPIN_ROOT:-${HOME}/.local/share/terrapin}"
TERRAPIN_BIN_DIR="${TERRAPIN_BIN_DIR:-${HOME}/.local/bin}"
TERRAPIN_BIN="$TERRAPIN_BIN_DIR/Terrapin-Scanner"
TERRAPIN_MARKER="$TERRAPIN_ROOT/.managed-by-shell"
TERRAPIN_OUTPUT_DIR="${TERRAPIN_OUTPUT_DIR:-$HOME/security-scans/terrapin}"

BIN_NAME="Terrapin-Scanner"

die() {
  printf '[terrapin][错误] %s\n' "$*" >&2
  exit 1
}

log() { printf '[terrapin] %s\n' "$*"; }

require_cmds() {
  local missing=() cmd
  for cmd in "$@"; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
  done
  [[ ${#missing[@]} -eq 0 ]] || die "缺少依赖：${missing[*]}"
}

show_help() {
  cat <<'EOF'
Terrapin-Scanner 安装与扫描封装 (CVE-2023-48795 Terrapin 攻击检测)

安装/管理：
  install [go|brew]     安装为 go install 或 Homebrew（默认 go）
  status                查看安装状态，不执行扫描
  uninstall --yes       删除本脚本创建的用户目录和命令链接

扫描（单端点，低影响，不做认证/攻击）：
  scan --connect <host:port> [--json] [-o 报告文件]

说明：二进制名为 `Terrapin-Scanner`。--connect 目标格式为 host:port（如
example.com:22 或 192.168.1.10:2222）。缺失端口默认 22。报告写入
~/security-scans/terrapin/，不会写入当前仓库。
EOF
}

detect_go_bin() {
  local gb
  gb="$(go env GOBIN 2>/dev/null || true)"
  if [[ -n "$gb" && "$gb" != "/" ]]; then
    printf '%s' "$gb"
    return
  fi
  local gp
  gp="$(go env GOPATH 2>/dev/null || true)"
  if [[ -n "$gp" && "$gp" != "/" ]]; then
    printf '%s/bin' "$gp"
    return
  fi
  printf '%s/go/bin' "$HOME"
}

install_via_go() {
  require_cmds go
  log "使用 go install 安装 Terrapin-Scanner@${TERRAPIN_VERSION} ..."
  GOFLAGS="${GOFLAGS:-} -mod=mod" go install "github.com/RUB-NDS/Terrapin-Scanner@${TERRAPIN_VERSION}"
  local gobin
  gobin="$(detect_go_bin)"
  local built="$gobin/$BIN_NAME"
  [[ -x "$built" ]] || die "go install 完成但未找到二进制：$built"
  mkdir -p "$TERRAPIN_BIN_DIR" "$TERRAPIN_ROOT"
  cp "$built" "$TERRAPIN_BIN"
  chmod 0755 "$TERRAPIN_BIN"
  : > "$TERRAPIN_MARKER"
  log "Terrapin-Scanner 已安装：$TERRAPIN_BIN"
}

install_via_brew() {
  require_cmds brew
  log "使用 Homebrew 安装 terrapin-scanner ..."
  brew install terrapin-scanner
  mkdir -p "$TERRAPIN_ROOT"
  : > "$TERRAPIN_MARKER"
  log "Terrapin-Scanner 已通过 Homebrew 安装。"
}

cmd_install() {
  local method="${1:-go}"
  case "$method" in
    go) install_via_go ;;
    brew) install_via_brew ;;
    *) die "未知安装方式：$method（可选 go、brew）" ;;
  esac
}

cmd_status() {
  printf 'Terrapin-Scanner: '
  if [[ -x "$TERRAPIN_BIN" ]]; then
    printf '已安装 (%s)\n' "$TERRAPIN_BIN"
    printf '版本: '
    "$TERRAPIN_BIN" --version 2>/dev/null || echo '(未知)'
  elif command -v "$BIN_NAME" >/dev/null 2>&1; then
    printf '已安装 (PATH: %s)\n' "$(command -v "$BIN_NAME")"
  else
    printf '未安装\n'
  fi
  printf '报告目录: %s\n' "$TERRAPIN_OUTPUT_DIR"
}

normalize_target() {
  local t="$1"
  if [[ "$t" == *":"* ]]; then
    printf '%s' "$t"
  else
    printf '%s:22' "$t"
  fi
}

run_scan() {
  local connect="$1" json_mode="$2" output="$3"
  local bin=""
  if [[ -x "$TERRAPIN_BIN" ]]; then
    bin="$TERRAPIN_BIN"
  elif command -v "$BIN_NAME" >/dev/null 2>&1; then
    bin="$(command -v "$BIN_NAME")"
  else
    die "Terrapin-Scanner 未安装，请先执行：$0 install"
  fi

  mkdir -p "$(dirname "$output")"
  local endpoint
  endpoint="$(normalize_target "$connect")"
  log "扫描 SSH 端点：$endpoint"

  if [[ "$json_mode" == "1" ]]; then
    "$bin" --connect "$endpoint" --json | tee "$output" || {
      local rc=$?
      # Terrapin 对未握手成功会返回非 0；保留原始输出到报告后仍认为"完成"
      log "扫描器返回 $rc（连接未被接受或目标不支持挑战）。原始输出已保留到 $output"
    }
  else
    "$bin" --connect "$endpoint" 2>&1 | tee "$output" || {
      local rc=$?
      log "扫描器返回 $rc（连接未被接受或目标不支持挑战）。原始输出已保留到 $output"
    }
  fi
  log "扫描完成：$output"
}

parse_scan_args() {
  local connect="" json_mode=0 output="" autoprint=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --connect) [[ $# -ge 2 ]] || die '--connect 需要 host:port'; connect="$2"; shift 2 ;;
      --json) json_mode=1; shift ;;
      -o) [[ $# -ge 2 ]] || die '-o 需要报告文件路径'; output="$2"; shift 2 ;;
      -h|--help) show_help; exit 0 ;;
      -*) die "未知扫描参数：$1" ;;
      *) [[ -z "$connect" ]] && connect="$1" || die '只能指定一个目标'; shift ;;
    esac
  done
  [[ -n "$connect" ]] || die '请指定目标主机，例如：Terrapin-Scanner --connect example.com:22'
  [[ "$connect" != *$'\n'* && "$connect" != *$'\r'* ]] || die '目标不能包含换行'
  if [[ -z "$output" ]]; then
    local stamp safe
    stamp="$(date +%Y%m%d-%H%M%S)"
    safe="$(printf '%s' "$connect" | tr -c '[:alnum:]._-' '_')"
    output="$TERRAPIN_OUTPUT_DIR/${safe}-${stamp}.txt"
  fi
  if [[ "$json_mode" == "1" && "${output##*.}" != "json" ]]; then
    output="${output%.txt}.json"
  fi
  run_scan "$connect" "$json_mode" "$output"
}

cmd_uninstall() {
  [[ "${1:-}" == "--yes" ]] || die '卸载需要显式提供 --yes'
  if [[ -x "$TERRAPIN_BIN" ]]; then
    if [[ -f "$TERRAPIN_MARKER" ]]; then
      rm -f "$TERRAPIN_BIN"
    else
      log "跳过删除 $TERRAPIN_BIN（未找到本脚本管理标记）"
    fi
  fi
  if [[ -f "$TERRAPIN_MARKER" ]]; then
    rm -rf "$TERRAPIN_ROOT"
  else
    [[ ! -e "$TERRAPIN_ROOT" ]] || log "跳过删除 $TERRAPIN_ROOT（未找到管理标记）"
  fi
  log 'Terrapin-Scanner 用户安装已清理。'
}

main() {
  local cmd="${1:-help}"; shift || true
  case "$cmd" in
    install) cmd_install "${1:-go}" ;;
    status) cmd_status ;;
    scan) parse_scan_args "$@" ;;
    uninstall) cmd_uninstall "$@" ;;
    -h|--help|help) show_help ;;
    *) die "未知命令：$cmd；运行 $0 --help 查看帮助" ;;
  esac
}

main "$@"
