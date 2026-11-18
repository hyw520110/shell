#!/usr/bin/env bash
# Lightpanda Browser 更新脚本
set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info() { echo -e "${CYAN}[INFO]${NC} $*"; }
ok()   { echo -e "${GREEN}[OK]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }

BIN_DIR="$HOME/.local/bin"
INSTALL_DIR="$HOME/.ai-hub/tools/lightpanda"

CURRENT_VER=""
if command -v lightpanda >/dev/null 2>&1; then
  CURRENT_VER=$(lightpanda --version 2>&1 | head -1)
  info "当前版本: $CURRENT_VER"
else
  warn "未检测到 lightpanda，将执行全新安装"
fi

REPO="lightpanda-io/browser"
API_URL="https://api.github.com/repos/${REPO}/releases/latest"

if command -v curl >/dev/null 2>&1; then
  LATEST_VER=$(curl -fsSL "$API_URL" | grep -m1 '"tag_name":' | sed -E 's/.*"tag_name": *"([^"]+)".*/\1/')
elif command -v wget >/dev/null 2>&1; then
  LATEST_VER=$(wget -qO- "$API_URL" | grep -m1 '"tag_name":' | sed -E 's/.*"tag_name": *"([^"]+)".*/\1/')
fi

info "最新版本: ${LATEST_VER:-未知}"

if [[ -n "$CURRENT_VER" && -n "$LATEST_VER" && "$CURRENT_VER" == *"$LATEST_VER"* ]]; then
  ok "已是最新版本，无需更新"
  exit 0
fi

info "开始更新..."
bash "$(dirname "$0")/install-lightpanda.sh"
ok "更新完成"
