#!/bin/bash

# === 配置区 ===
# 定义颜色代码
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

# Flutter相关配置
FLUTTER_HOME="$HOME/flutter"
FLUTTER_REPO="https://github.com/flutter/flutter.git"
FLUTTER_BRANCH="stable"

# 镜像源配置
PUB_HOSTED_URL="https://pub.flutter-io.cn"
FLUTTER_STORAGE_BASE_URL="https://storage.flutter-io.cn/flutter_infra_release"

# === 函数定义 ===
# 打印带步骤的标题
print_step() {
    local step=$1
    local title=$2
    echo -e "${YELLOW}[${step}/5] $title...${NC}"
}

# 检查命令是否存在
cmd_exists() {
    command -v "$1" &> /dev/null
}

# 添加环境变量（支持动态配置文件）
add_env_vars() {
    local var_name=$1
    local var_value=$2
    local config_file=$3

    # 如果配置文件不存在，则创建
    if [ ! -f "$config_file" ]; then
        touch "$config_file" || {
            echo -e "${RED}无法创建配置文件 $config_file${NC}"; exit 1;
        }
    fi

    # 检查变量是否已存在
    if grep -q "^export $var_name=\"$var_value\"$" "$config_file" 2>/dev/null; then
        echo -e "  ℹ️ $config_file 中已存在 $var_name"
    else
        echo "export $var_name=\"$var_value\"" >> "$config_file"
        echo -e "  ✅ 已添加到 $config_file"
    fi
}

# 确定当前 Shell 的配置文件
determine_shell_config() {
    if [ -n "$ZSH_NAME" ]; then
        echo "$HOME/.zshrc"
    elif [ -n "$BASH_VERSION" ]; then
        echo "$HOME/.bashrc"
    else
        case "$SHELL" in
            *bash) echo "$HOME/.bashrc";;
            *zsh) echo "$HOME/.zshrc";;
            *) echo "$HOME/.bashrc";; # 默认使用 bash
        esac
    fi
}

# 安装系统依赖
install_system_deps() {
    print_step 1 "安装系统依赖"

    # Linux: apt, dnf, or yum
    if cmd_exists apt; then
        sudo apt update || { echo -e "${RED}更新包列表失败${NC}"; exit 1; }
        sudo apt install -y curl git wget unzip libglu1-mesa xz-utils || {
            echo -e "${RED}安装依赖失败${NC}"; exit 1;
        }
    elif cmd_exists dnf; then
        sudo dnf install -y curl git wget unzip mesa-libGLU xz || {
            echo -e "${RED}安装依赖失败${NC}"; exit 1;
        }
    elif cmd_exists yum; then
        sudo yum install -y curl git wget unzip mesa-libGLU xz || {
            echo -e "${RED}安装依赖失败${NC}"; exit 1;
        }
    # macOS: brew
    elif [[ "$OSTYPE" == "darwin"* ]]; then
        if ! cmd_exists brew; then
            echo -e "${YELLOW}安装Homebrew...${NC}"
            /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" || {
                echo -e "${RED}Homebrew安装失败${NC}"; exit 1;
            }
        fi

        brew install --HEAD libimobiledevice || {
            echo -e "${RED}libimobiledevice安装失败${NC}"; exit 1;
        }
        brew install ideviceinstaller ios-deploy cocoapods || {
            echo -e "${RED}iOS开发工具安装失败${NC}"; exit 1;
        }
        pod setup || {
            echo -e "${RED}CocoaPods初始化失败${NC}"; exit 1;
        }
    else
        echo -e "${RED}未检测到支持的包管理器${NC}"
        exit 1
    fi
}

# 安装Flutter SDK
install_flutter() {
    print_step 2 "安装Flutter SDK"

    if [ -d "$FLUTTER_HOME" ]; then
        echo -e "${YELLOW}检测到已安装的Flutter SDK，正在更新...${NC}"
        cd "$FLUTTER_HOME" || {
            echo -e "${RED}进入Flutter目录失败${NC}"; exit 1;
        }
        git pull || {
            echo -e "${RED}Flutter更新失败${NC}"; exit 1;
        }
    else
        echo -e "${YELLOW}正在下载Flutter SDK...${NC}"
        git clone "$FLUTTER_REPO" -b "$FLUTTER_BRANCH" "$FLUTTER_HOME" || {
            echo -e "${RED}Flutter克隆失败${NC}"; exit 1;
        }
    fi
}

# 配置环境变量
configure_environment() {
    print_step 3 "配置环境变量"

    # 确定 Shell 配置文件
    SHELL_CONFIG=$(determine_shell_config)

    # 添加环境变量
    add_env_vars "PATH" "$PATH:$FLUTTER_HOME/bin" "$SHELL_CONFIG"
    add_env_vars "PUB_HOSTED_URL" "$PUB_HOSTED_URL" "$SHELL_CONFIG"
    add_env_vars "FLUTTER_STORAGE_BASE_URL" "$FLUTTER_STORAGE_BASE_URL" "$SHELL_CONFIG"

    # 立即生效
    export PATH="$PATH:$FLUTTER_HOME/bin"
    echo -e "${GREEN}已立即生效当前会话的环境变量${NC}"
}

# 运行flutter doctor
run_flutter_doctor() {
    print_step 4 "运行flutter doctor检查"

    flutter doctor -v 2>&1 | tee flutter_doctor_output.txt || {
        echo -e "${RED}flutter doctor执行失败${NC}"; exit 1;
    }

    # 分析doctor结果
    if grep -q "No issues found!" flutter_doctor_output.txt; then
        echo -e "${GREEN}✅ flutter doctor 检查通过${NC}"
    else
        echo -e "${YELLOW}⚠️ flutter doctor 发现问题，请检查输出文件 flutter_doctor_output.txt${NC}"
    fi
}

# 显示帮助信息
show_help() {
    echo -e "${GREEN}Flutter常用命令说明：${NC}"
    echo "flutter create <项目名>       # 创建新项目"
    echo "flutter run                  # 运行项目"
    echo "flutter devices              # 查看连接设备"
    echo "flutter pub get              # 获取依赖包"
    echo "flutter pub upgrade          # 升级依赖包"
    echo "flutter build                # 构建项目"
    echo "flutter clean                # 清理构建文件"
    echo "flutter doctor               # 检查开发环境"
    echo "flutter --version            # 查看版本信息"
    echo "flutter help                 # 查看帮助信息"
}

# === 主流程 ===
echo -e "${GREEN}=== 开始Flutter安装配置 ===${NC}"

# 安装系统依赖
install_system_deps

# 安装Flutter SDK
install_flutter

# 配置环境变量
configure_environment

# 运行flutter doctor
run_flutter_doctor

# 显示帮助信息
show_help

echo -e "${GREEN}=== Flutter安装配置完成 ===${NC}"
echo -e "请执行以下命令使配置生效:"
echo -e "source ~/.bashrc 或 source ~/.zshrc (根据你的shell选择)"