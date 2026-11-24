#!/bin/bash

# 显示帮助信息
show_help() {
    cat << EOF
pyenv 安装脚本

安装 pyenv Python 版本管理工具，支持多个 Python 版本的同时管理。

用法: ./install-pyenv.sh [选项]

选项:
    -h, --help            显示此帮助信息
    -v, --version         显示版本信息

说明:
    - 自动安装系统依赖（编译Python所需的库）
    - 支持Linux和macOS系统
    - 自动配置shell环境变量
    - 支持多种安装方式（脚本、Git克隆）
    - 自动配置国内镜像源

支持的操作系统:
    - Linux: Ubuntu, Debian, CentOS, Rocky Linux, Fedora
    - macOS: 10.15+

示例:
    ./install-pyenv.sh              # 安装pyenv
    ./install-pyenv.sh --version     # 显示版本信息

安装后使用:
    # 列出可用版本
    pyenv install --list

    # 安装特定版本
    pyenv install 3.11.0

    # 设置全局版本
    pyenv global 3.11.0

    # 设置当前目录版本
    pyenv local 3.10.0

验证安装:
    source ~/.bashrc    # 或 source ~/.zshrc
    pyenv --version

注意事项:
    - 需要网络连接下载依赖
    - Linux系统需要sudo权限安装系统依赖
    - 安装完成后需要重新加载shell配置
    - 首次安装Python版本可能需要较长时间

EOF
}

# 参数解析
while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            show_help
            exit 0
            ;;
        -v|--version)
            echo "pyenv安装脚本版本: 1.0"
            exit 0
            ;;
        *)
            echo "未知参数: $1"
            show_help
            exit 1
            ;;
    esac
done

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
      # 尝试使用镜像源或备选方法安装 Homebrew
      log $YELLOW "正在安装 Homebrew..."
      if ! /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"; then
        log $YELLOW "尝试使用镜像源安装 Homebrew..."
        export HOMEBREW_BOTTLE_DOMAIN=https://mirrors.ustc.edu.cn/homebrew-bottles
        if ! /bin/bash -c "$(curl -fsSL https://gitee.com/cunkai/HomebrewCN/raw/master/Homebrew.sh)"; then
          log $RED "无法安装 Homebrew，请手动安装后重试"
          exit 1
        fi
      fi
    fi
  else
    # Linux
    if command -v apt &> /dev/null; then
      sudo apt update || { log $RED "APT 更新失败"; exit 1; }
      sudo apt install -y make build-essential libssl-dev zlib1g-dev \
        libbz2-dev libreadline-dev libsqlite3-dev wget curl llvm \
        libncursesw5-dev xz-utils tk-dev libxml2-dev libxmlsec1-dev libffi-dev liblzma-dev || { log $RED "APT 安装依赖失败"; exit 1; }
    elif command -v yum &> /dev/null; then
      sudo yum install -y gcc make openssl-devel zlib-devel bzip2-devel readline-devel sqlite-devel \
        wget curl llvm-devel ncurses-devel xz-devel tk-devel libxml2-devel libxmlsec1-devel libffi-devel liblzma-devel || { log $RED "YUM 安装依赖失败"; exit 1; }
    elif command -v dnf &> /dev/null; then
      sudo dnf install -y gcc make openssl-devel zlib-devel bzip2-devel readline-devel sqlite-devel \
        wget curl llvm-devel ncurses-devel xz-devel tk-devel libxml2-devel libxmlsec1-devel libffi-devel liblzma-devel || { log $RED "DNF 安装依赖失败"; exit 1; }
    else
      log $YELLOW "无法识别的包管理器，请手动安装依赖"
    fi
  fi
  log $GREEN "依赖安装完成"
}

install_pyenv() {
  if ! command -v pyenv > /dev/null 2>&1; then
    if [[ "$OSTYPE" == "darwin"* ]]; then
        log $YELLOW "检测到 macOS 系统，使用 Homebrew 安装 pyenv..."
        if ! command -v brew > /dev/null 2>&1; then
            log $RED "未找到 Homebrew，请先安装 Homebrew"
            exit 1
        fi
        brew install pyenv || { log $RED "Homebrew 安装 pyenv 失败"; exit 1; }
    else
        # 检查并清理可能存在的不完整安装
        if [ -d "$HOME/.pyenv" ]; then
            log $YELLOW "发现现有的 .pyenv 目录，备份并清理..."
            mv ~/.pyenv ~/.pyenv_backup_$(date +%s)
        fi

        # 尝试多种安装方式
        log $YELLOW "正在安装 pyenv..."
        successful_install=false

        # 方法1: 直接从 GitHub 安装 with increased timeout and retry
        log $YELLOW "尝试方法1: 使用 curl 安装脚本..."
        if curl -sSL --connect-timeout 30 --max-time 300 https://pyenv.run | bash; then
            log $GREEN "方法1 成功"
            successful_install=true
        else
            log $YELLOW "方法1 失败，尝试方法2: 从镜像源克隆..."
        fi

        # 如果方法1失败，尝试多种 git 克隆方式
        if [ "$successful_install" = false ]; then
            # 尝试 from multiple mirrors with fallback
            if git clone https://ghproxy.com/github.com/pyenv/pyenv.git ~/.pyenv; then
                log $GREEN "方法2a (ghproxy) 成功"
                successful_install=true
            elif git clone https://github.com/pyenv/pyenv.git ~/.pyenv; then
                log $GREEN "方法2b (direct github) 成功"
                successful_install=true
            elif git clone https://gitee.com/mirrors/pyenv.git ~/.pyenv; then
                log $GREEN "方法2c (gitee) 成功"
                successful_install=true
            else
                log $RED "所有安装方法均失败"
                exit 1
            fi
        fi
    fi
  else
    log $GREEN "pyenv 已安装，跳过安装步骤"
  fi

  $SHELL -c 'echo $0' | grep -q zsh && SHELL_CONFIG="$HOME/.zshrc" || SHELL_CONFIG="$HOME/.bashrc"
  log $YELLOW "配置$SHELL_CONFIG..."
  # 检查是否已添加配置
  if grep -q 'pyenv' "$SHELL_CONFIG"; then
    log $YELLOW "pyenv 配置已存在，跳过添加。"
  else
    echo 'export PYENV_ROOT="$HOME/.pyenv"' >> "$SHELL_CONFIG"
    echo 'command -v pyenv >/dev/null || export PATH="$PYENV_ROOT/bin:$PATH"' >> $SHELL_CONFIG
    echo 'eval "$(pyenv init --path)"' >> $SHELL_CONFIG
    echo 'eval "$(pyenv init -)"' >> $SHELL_CONFIG
    log $GREEN "pyenv 配置已写入 $SHELL_CONFIG"
  fi
  log $YELLOW "验证安装..."
  # 重新加载 shell 配置
  export PYENV_ROOT="$HOME/.pyenv"
  export PATH="$PYENV_ROOT/bin:$PATH"
  eval "$(pyenv init --path)"
  eval "$(pyenv init -)"

  if command -v pyenv > /dev/null 2>&1; then
    log $GREEN "pyenv 安装成功！版本: $(pyenv --version)"
    log $YELLOW "建议运行 'source $SHELL_CONFIG' 或重新打开终端以使配置生效"
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