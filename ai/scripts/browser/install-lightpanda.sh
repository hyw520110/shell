#!/usr/bin/env bash
# Lightpanda Browser 安装脚本（GitHub Release 二进制下载）
# 兼容 Linux / macOS，支持 x86_64 / arm64

set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
RED='\033[0;31m'
NC='\033[0m'

info() { echo -e "${CYAN}[INFO]${NC} $*"; }
ok()   { echo -e "${GREEN}[OK]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()  { echo -e "${RED}[ERR]${NC} $*"; }

OS="$(uname -s)"
ARCH="$(uname -m)"

case "$OS" in
  Darwin) OS_NAME="macos" ;;
  Linux)  OS_NAME="linux" ;;
  *)      err "暂不支持的操作系统: $OS"; exit 1 ;;
esac

case "$ARCH" in
  x86_64|amd64) ARCH_NAME="x86_64" ;;
  arm64|aarch64) ARCH_NAME="aarch64" ;;
  *)            err "暂不支持的架构: $ARCH"; exit 1 ;;
esac

info "检测到系统: $OS_NAME / $ARCH_NAME"

REPO="lightpanda-io/browser"
API_URL="https://api.github.com/repos/${REPO}/releases/latest"

info "获取最新版本信息..."
if command -v curl >/dev/null 2>&1; then
  RELEASE_JSON=$(curl -fsSL "$API_URL")
elif command -v wget >/dev/null 2>&1; then
  RELEASE_JSON=$(wget -qO- "$API_URL")
else
  err "需要 curl 或 wget"
  exit 1
fi

VERSION=$(echo "$RELEASE_JSON" | grep -m1 '"tag_name":' | sed -E 's/.*"tag_name": *"([^"]+)".*/\1/')
if [[ -z "$VERSION" ]]; then
  err "无法获取最新版本号"
  exit 1
fi
info "最新版本: $VERSION"

# Lightpanda Release 命名通常为 lightpanda-<os>-<arch>（可能带 .zip/.tar.gz）
ASSET_NAME="lightpanda-${OS_NAME}-${ARCH_NAME}"
DOWNLOAD_URL=""

# 从 assets 匹配（优先精确匹配 x86_64/aarch64 + os，排除 debug）
if command -v python3 >/dev/null 2>&1; then
  DOWNLOAD_URL=$(OS_NAME="$OS_NAME" ARCH_NAME="$ARCH_NAME" RELEASE_JSON="$RELEASE_JSON" python3 -c "
import json,os,sys
data=json.loads(os.environ['RELEASE_JSON'])
osn=os.environ['OS_NAME']; arn=os.environ['ARCH_NAME']
for a in data.get('assets',[]):
    name=a['name']
    if name==f'lightpanda-{arn}-{osn}' and 'debug' not in name:
        print(a['browser_download_url']); sys.exit(0)
for a in data.get('assets',[]):
    name=a['name']
    if name.startswith(f'lightpanda-{arn}-{osn}') and 'debug' not in name:
        print(a['browser_download_url']); sys.exit(0)
sys.exit(1)
")
fi

if [[ -z "$DOWNLOAD_URL" ]]; then
  # 尝试常用后缀
  for ext in "" ".zip" ".tar.gz" ".tar.xz"; do
    CAND="https://github.com/${REPO}/releases/download/${VERSION}/lightpanda-${OS_NAME}-${ARCH_NAME}${ext}"
    if command -v curl >/dev/null 2>&1; then
      if curl -fsI "$CAND" >/dev/null 2>&1; then
        DOWNLOAD_URL="$CAND"
        break
      fi
    fi
  done
fi

if [[ -z "$DOWNLOAD_URL" ]]; then
  err "未找到适配 $OS_NAME/$ARCH_NAME 的 Release 资产"
  info "请查看: https://github.com/${REPO}/releases"
  exit 1
fi

info "下载地址: $DOWNLOAD_URL"

INSTALL_DIR="$HOME/.ai-hub/tools/lightpanda"
BIN_DIR="$HOME/.local/bin"
mkdir -p "$INSTALL_DIR" "$BIN_DIR"

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

FILENAME=$(basename "$DOWNLOAD_URL")
cd "$TMPDIR"

info "下载中..."
if command -v curl >/dev/null 2>&1; then
  curl -fL -o "$FILENAME" "$DOWNLOAD_URL"
else
  wget -O "$FILENAME" "$DOWNLOAD_URL"
fi
ok "下载完成"

info "解压中..."
case "$FILENAME" in
  *.zip)
    command -v unzip >/dev/null 2>&1 || { err "需要 unzip"; exit 1; }
    unzip -q "$FILENAME"
    ;;
  *.tar.gz)
    tar -xzf "$FILENAME"
    ;;
  *.tar.xz)
    tar -xJf "$FILENAME"
    ;;
  *)
    # 可能直接是可执行文件
    mv "$FILENAME" lightpanda
    ;;
esac

# 查找可执行文件
EXEC_PATH=""
for f in lightpanda */lightpanda */bin/lightpanda; do
  if [[ -f "$f" ]]; then
    EXEC_PATH="$f"
    break
  fi
done

if [[ -z "$EXEC_PATH" ]]; then
  err "解压后未找到 lightpanda 可执行文件"
  ls -la
  exit 1
fi

cp "$EXEC_PATH" "$INSTALL_DIR/lightpanda"
chmod +x "$INSTALL_DIR/lightpanda"
ln -sf "$INSTALL_DIR/lightpanda" "$BIN_DIR/lightpanda"

# macOS 去除隔离属性
if [[ "$OS_NAME" == "macos" ]]; then
  xattr -d com.apple.quarantine "$INSTALL_DIR/lightpanda" 2>/dev/null || true
  xattr -d com.apple.quarantine "$BIN_DIR/lightpanda" 2>/dev/null || true
fi

ok "安装完成: $INSTALL_DIR/lightpanda"
info "软链已创建: $BIN_DIR/lightpanda"

if ! echo "$PATH" | grep -q "$BIN_DIR"; then
  warn "$BIN_DIR 不在 PATH 中。请将以下内容添加到 shell 配置文件："
  echo "  export PATH=\"\$HOME/.local/bin:\$PATH\""
fi

"$BIN_DIR/lightpanda" --version 2>&1 | head -2 || true
ok "Lightpanda 安装成功"
