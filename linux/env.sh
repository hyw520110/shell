#!/bin/bash

# 定义变量
SYSTEM=false
ADD_TO_PATH=false
NAME=""
VALUE=""
CONFIG_FILE=""

# 检测操作系统类型，以支持 macOS 的 sed 差异
if [[ "$OSTYPE" == "darwin"* ]]; then
    SED_INPLACE="sed -i ''"
else
    SED_INPLACE="sed -i"
fi

# 解析参数
while [[ "$#" -gt 0 ]]; do
    case $1 in
        -s|--system) SYSTEM=true ;;
        -a|--add-to-path) ADD_TO_PATH=true ;;
        -n|--name) NAME="$2"; shift ;;
        -v|--value) VALUE="$2"; shift ;;
        -h|--help)
            echo "Usage: $0 [OPTIONS]"
            echo "Options:"
            echo "  -s, --system          Use system-wide environment variables (requires sudo)"
            echo "  -a, --add-to-path     Add the value to PATH (if bin directory exists)"
            echo "  -n, --name NAME       Environment variable name"
            echo "  -v, --value VALUE     Directory value for the environment variable"
            echo "  -h, --help            Show this help message"
            exit 0
            ;;
        *) echo "Unknown parameter: $1" >&2; exit 1 ;;
    esac
    shift
done

# 验证参数
if [ -z "$NAME" ] || [ -z "$VALUE" ]; then
    echo "Error: Both --name and --value are required." >&2
    exit 1
fi

if [ ! -d "$VALUE" ]; then
    echo "Error: The specified value is not a valid directory: $VALUE" >&2
    exit 1
fi

# 确定配置文件路径
if [ "$SYSTEM" = true ]; then
    if [ "$EUID" -ne 0 ]; then
        # 需要提权
        exec sudo -- "$0" "$@"
    fi
    CONFIG_FILE="/etc/profile.d/custom_env.sh"
else
    # 检测 shell 类型
    SHELL_TYPE=$(basename "$SHELL")
    if [ "$SHELL_TYPE" = "bash" ]; then
        CONFIG_FILE="$HOME/.bashrc"
    elif [ "$SHELL_TYPE" = "zsh" ]; then
        CONFIG_FILE="$HOME/.zshrc"
    else
        # 其他 shell，假设为 bash
        CONFIG_FILE="$HOME/.bashrc"
    fi
fi

# 创建配置文件（如果不存在）
if [ "$SYSTEM" = true ]; then
    if [ ! -f "$CONFIG_FILE" ]; then
        sudo touch "$CONFIG_FILE"
        sudo chmod 644 "$CONFIG_FILE"
    fi
fi

# 转义变量用于 sed
escaped_name=$(echo "$NAME" | sed -e 's/[\/&]/\\&/g')

# 删除旧的环境变量定义
$SED_INPLACE "/^${escaped_name}=/d" "$CONFIG_FILE"
$SED_INPLACE "/^export ${escaped_name}=/d" "$CONFIG_FILE"

# 添加新的环境变量定义
echo "export $NAME=$VALUE" >> "$CONFIG_FILE"

# 处理添加到 PATH 的情况
if [ "$ADD_TO_PATH" = true ]; then
    BIN_DIR="$VALUE/bin"
    if [ -d "$BIN_DIR" ]; then
        # 转义 bin 目录用于 sed
        escaped_bin_dir=$(echo "$BIN_DIR" | sed -e 's/[\/&]/\\&/g')
        # 删除配置文件中已有的该路径的 PATH 导出语句
        $SED_INPLACE -E "/export PATH.*${escaped_bin_dir}/d" "$CONFIG_FILE"
        # 添加新的 PATH 导出语句
        echo "export PATH=\"$BIN_DIR:\$PATH\"" >> "$CONFIG_FILE"
    fi
fi

# 提示用户
if [ "$SYSTEM" = true ]; then
    echo "System environment variable added/updated. You may need to re-login or source /etc/profile.d/custom_env.sh."
else
    echo "User environment variable added/updated. You may need to re-login or run 'source $CONFIG_FILE' to apply changes."
fi

exit 0
