#!/bin/bash


# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log() {
  local color=$1
  local message=$2
  echo -e "${color}${message}${NC}"
}

install_dependencies() {
  log $YELLOW "安装依赖..."
  if [[ "$OSTYPE" == "darwin"* ]]; then
    # macOS
    if ! command -v brew &> /dev/null; then
      /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    fi
  else
    # Linux
    sudo apt update || { log $RED "APT 更新失败"; exit 1; }
    sudo apt install -y make build-essential libssl-dev zlib1g-dev \
      libbz2-dev libreadline-dev libsqlite3-dev wget curl llvm \
      libncursesw5-dev xz-utils tk-dev libxml2-dev libxmlsec1-dev libffi-dev liblzma-dev || { log $RED "APT 安装依赖失败"; exit 1; }
  fi
  log $GREEN "依赖安装完成"
}

install_pyenv() {
  if ! command -v pyenv > /dev/null 2>&1; then
    if [[ "$OSTYPE" == "darwin"* ]]; then
        brew install pyenv 
    else
        curl -sSL https://pyenv.run | bash    
    fi
  fi
  
  $SHELL -c 'echo $0' | grep -q zsh && SHELL_CONFIG="$HOME/.zshrc" || SHELL_CONFIG="$HOME/.bashrc"
  log $YELLOW "配置$SHELL_CONFIG..."
  # 检查是否已添加配置
  if grep -q 'pyenv' "$SHELL_CONFIG"; then
    log $YELLOW "pyenv 配置已存在，跳过添加。"
  else
    echo 'export PYENV_ROOT="$HOME/.pyenv"' >> "$SHELL_CONFIG"
	echo 'command -v pyenv >/dev/null || export PATH="$PYENV_ROOT/bin:$PATH"' >> $SHELL_CONFIG
	echo 'eval "$(pyenv init -)"' >> $SHELL_CONFIG
    log $GREEN "pyenv 配置已写入 $SHELL_CONFIG"
  fi
  log $YELLOW "验证安装..."
  source "$SHELL_CONFIG"
  if command -v pyenv > /dev/null 2>&1; then
    log $GREEN "pyenv 安装成功！版本: $(pyenv --version)"
  else
    log $RED "pyenv 安装失败，请检查日志: "
    exit 1
  fi
}



# 主流程
main() {
  install_dependencies
  install_pyenv
}

main