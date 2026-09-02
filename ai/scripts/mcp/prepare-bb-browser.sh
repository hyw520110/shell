#!/usr/bin/env bash
set -euo pipefail

NPM_REGISTRY="${NPM_REGISTRY:-https://registry.npmmirror.com}"

info() { echo "[INFO] $*"; }
ok() { echo "[OK] $*"; }
warn() { echo "[WARN] $*"; }

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

ensure_bb_browser() {
  if command_exists bb-browser; then
    ok "bb-browser 已安装: $(command -v bb-browser)"
    return 0
  fi

  command_exists npm || {
    warn "未找到 npm，无法自动安装 bb-browser。"
    return 1
  }

  info "正在安装 bb-browser..."
  npm install -g bb-browser --registry "$NPM_REGISTRY"
}

ensure_site_adapters() {
  if bb-browser site list >/tmp/aihub-bb-browser-sites.out 2>&1; then
    if ! grep -q "未找到任何 site adapter" /tmp/aihub-bb-browser-sites.out; then
      ok "bb-browser site adapters 已可用。"
      rm -f /tmp/aihub-bb-browser-sites.out
      return 0
    fi
  fi
  rm -f /tmp/aihub-bb-browser-sites.out

  info "正在安装/更新 bb-browser community site adapters..."
  bb-browser site update
}

ensure_daemon() {
  if bb-browser daemon status 2>/dev/null | grep -q "Daemon running: yes"; then
    ok "bb-browser daemon 已运行。"
    return 0
  fi

  info "正在启动 bb-browser daemon..."
  bb-browser daemon start >/dev/null 2>&1 || bb-browser daemon start

  if bb-browser daemon status 2>/dev/null | grep -q "Daemon running: yes"; then
    ok "bb-browser daemon 启动成功。"
  else
    warn "bb-browser daemon 未确认启动成功，请执行: bb-browser daemon status"
    return 1
  fi
}

main() {
  ensure_bb_browser
  ensure_site_adapters
  ensure_daemon
  ok "bb-browser MCP 前置依赖准备完成。"
}

main "$@"
