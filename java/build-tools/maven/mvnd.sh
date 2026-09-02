#!/bin/bash

MVND_DIR="${MVND_DIR:-$HOME/mvnd}"
DOWNLOAD_DIR="${DOWNLOAD_DIR:-$HOME/Downloads}"

# ================== 工具函数 ==================

# 打印带颜色的信息
info()  { echo -e "\033[1;34m[INFO] $*\033[0m"; }
warn()  { echo -e "\033[1;33m[WARN] $*\033[0m"; }
error() { echo -e "\033[1;31m[ERROR] $*\033[0m"; exit 1; }
ok()    { echo -e "\033[1;32m[OK] $*\033[0m"; }

# 检查命令是否存在
has_cmd() {
  command -v "$1" &> /dev/null
}

download_file() {
  local url="$1"
  local output="$2"
  local output_dir
  local filename
  output_dir="$(dirname "$output")"
  filename="$(basename "$output")"

  mkdir -p "$output_dir"

  if has_cmd adl && adl --help >/dev/null 2>&1; then
    adl "$url" "$output_dir" "$filename"
  else
    curl -f -L -o "$output" "$url"
  fi
}

# 自动安装依赖
install_deps() {
  local deps=("$@")
  local missing=()

  for dep in "${deps[@]}"; do
    if ! has_cmd "$dep"; then
      missing+=("$dep")
    fi
  done

  if [ ${#missing[@]} -eq 0 ]; then
    info "所有依赖已安装"
    return 0
  fi

  warn "缺少以下依赖：${missing[*]}，正在尝试自动安装..."

  OS=$(uname -s)
  if [ "$OS" = "Linux" ]; then
    if has_cmd apt-get; then
      sudo apt update && sudo apt install -y "${missing[@]}"
    elif has_cmd dnf; then
      sudo dnf install -y "${missing[@]}"
    elif has_cmd yum; then
      sudo yum install -y "${missing[@]}"
    elif has_cmd pacman; then
      sudo pacman -Sy --noconfirm "${missing[@]}"
    else
      error "无法识别的 Linux 发行版，无法自动安装依赖"
    fi
  elif [ "$OS" = "Darwin" ]; then
    if ! has_cmd brew; then
      warn "未检测到 Homebrew，正在安装 Homebrew..."
      /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    fi
    brew install "${missing[@]}"
  else
    error "不支持的操作系统：$OS"
  fi

  for dep in "${missing[@]}"; do
    if ! has_cmd "$dep"; then
      error "安装依赖失败：$dep"
    fi
  done

  ok "所有依赖已成功安装"
}

# ================== 主流程 ==================

# 确定 shell 类型
SHELL_PROFILE=""
if [[ "$SHELL" == */zsh ]]; then
  SHELL_PROFILE="$HOME/.zshrc"
else
  SHELL_PROFILE="$HOME/.bashrc"
fi
source $SHELL_PROFILE
# 检查是否已安装 mvnd
if has_cmd mvnd &> /dev/null || [ -d $MVND_DIR ]; then
  # 如果有参数，则执行 mvnd 命令
  if [ $# -gt 0 ]; then
      info "执行命令: mvnd $*"
      exec mvnd "$@"
  else
      ok "mvnd 已安装在 $(command -v mvnd)"
      exit 0
  fi
fi


info "mvnd 未安装，正在自动下载并安装..."

# 检查并安装依赖
install_deps curl jq tar

# 创建安装目录
mkdir -p "$MVND_DIR"
mkdir -p "$DOWNLOAD_DIR"
cd "$MVND_DIR" || exit 1

# 检测操作系统和架构
OS=$(uname -s)
ARCH=$(uname -m)

case "$OS" in
  Linux)
    OS_NAME="linux"
    ;;
  Darwin)
    OS_NAME="darwin"
    ;;
  *)
    error "不支持的操作系统: $OS"
    ;;
esac

case "$ARCH" in
  x86_64)
    ARCH_NAME="amd64"
    ;;
  arm64|aarch64)
    ARCH_NAME="aarch64"
    ;;
  *)
    error "不支持的架构: $ARCH"
    ;;
esac

# 获取最新 release 的真实资产 URL
GITHUB_REPO="https://api.github.com/repos/apache/maven-mvnd/releases/latest"

info "正在从 GitHub API 获取最新版本信息..."
json_response=$(curl -sL -H "Accept: application/vnd.github.v3+json" -H "User-Agent: Mozilla/5.0" "${GITHUB_REPO}")

if [ -z "${json_response}" ] || echo "${json_response}" | grep -q "API rate limit exceeded"; then
    error "从 GitHub API 获取版本信息失败。可能是网络问题或达到了API速率限制。"
fi

# 修复：使用更精确的匹配逻辑并清理URL
info "正在查找适用于 ${OS_NAME}-${ARCH_NAME} 的下载链接..."
ASSET_URL=$(echo "${json_response}" | jq -r ".assets[] | select(.name | test(\"${OS_NAME}-${ARCH_NAME}\"; \"i\") and endswith(\".tar.gz\")).browser_download_url" | head -n1)

# 清理URL中的特殊字符和换行符
ASSET_URL=$(echo "$ASSET_URL" | tr -d '\r\n')

if [[ -z "$ASSET_URL" ]]; then
  error "无法找到适用于 ${OS_NAME}-${ARCH_NAME} 的 .tar.gz 下载地址，请确认 mvnd 是否已发布该平台版本"
fi

# 从URL中提取文件名用于下载
FILE=$(basename "$ASSET_URL")
DOWNLOAD_FILE="$DOWNLOAD_DIR/$FILE"
# 修复：添加重试机制和完整性检查
MAX_RETRIES=3
retry_count=0
download_success=false
# 检查文件是否已存在
if [[ -f "$DOWNLOAD_FILE" ]]; then
  info "发现已存在的下载文件: $DOWNLOAD_FILE"
  
  # 验证文件完整性
  info "验证文件完整性..."
  if tar -tzf "$DOWNLOAD_FILE" >/dev/null 2>&1; then
    ok "文件完整性验证通过，跳过下载"
    download_success=true
  else
    warn "文件已损坏，将重新下载"
    rm -f "$DOWNLOAD_FILE"
  fi
fi
while [[ $retry_count -lt $MAX_RETRIES && $download_success == false ]]; do
  ((retry_count++))
  info "正在下载文件... (尝试 $retry_count/$MAX_RETRIES)"
  
  # 检查下载是否成功且文件非空
  if download_file "$ASSET_URL" "$DOWNLOAD_FILE" && [ -s "$DOWNLOAD_FILE" ]; then
    download_success=true
    ok "下载成功: $DOWNLOAD_FILE"
    
    # 验证文件完整性
    info "验证文件完整性..."
    if ! tar -tzf "$DOWNLOAD_FILE" >/dev/null 2>&1; then
      warn "文件完整性检查失败，可能是下载损坏"
      download_success=false
    fi
  else
    warn "下载失败或文件为空，正在重试..."
  fi
done

if [ $download_success == false ]; then
  error "下载失败：无法获取有效的安装文件"
fi

# 解压文件
info "正在解压文件..."
if ! tar -xzf "$DOWNLOAD_FILE" --strip-components=1; then
  error "解压失败"
fi
ok "文件解压成功"

# 确保 mvnd 可执行文件存在并添加权限
if [[ -f "bin/mvnd" ]]; then
  chmod +x "bin/mvnd"
  ok "已添加执行权限"
else
  # 尝试在解压后的目录中查找 mvnd
  found_mvnd=$(find . -type f -name mvnd | head -1)
  if [[ -n "$found_mvnd" ]]; then
    mkdir -p bin
    mv "$found_mvnd" bin/mvnd
    chmod +x "bin/mvnd"
    ok "已移动并添加执行权限"
  else
    error "未找到 mvnd 可执行文件"
  fi
fi

# 临时添加路径到当前环境
if [[ ":$PATH:" != *":$MVND_DIR/bin:*" ]]; then
  export PATH="$MVND_DIR/bin:$PATH"
  info "已临时添加 mvnd 到当前会话的 PATH"
fi

# 检查用户配置文件中是否已有 mvnd 路径
if [ -f "$SHELL_PROFILE" ]; then
  if ! grep -q 'mvnd' "$SHELL_PROFILE"; then
    info "未在 shell 配置文件中找到 mvnd 路径，建议手动添加以实现永久使用"
    info "请将以下行添加到 $SHELL_PROFILE："
    info "export PATH=\"$MVND_DIR/bin:\$PATH\""
  fi
fi

# 验证安装
if command -v mvnd &> /dev/null; then
  ok "mvnd 安装完成！版本信息："
  mvnd --version
  ok "注意：本次安装未将 mvnd 添加到永久 PATH"
  warn "如需全局使用，请手动添加 $MVND_DIR/bin 到您的 PATH 环境变量"
else
  # 尝试直接执行
  if "$MVND_DIR/bin/mvnd" --version; then
    ok "mvnd 可执行文件已安装在 $MVND_DIR/bin"
    warn "请手动添加 $MVND_DIR/bin 到您的 PATH 环境变量以实现全局使用"
  else
    error "安装失败，请检查网络或手动安装"
  fi
fi
