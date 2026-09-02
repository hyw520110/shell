#!/bin/bash
# Python项目版本分析脚本
# 用于查找和分析指定目录下的所有Python项目及其Python版本要求

set -e

# 脚本目录
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 默认参数
TARGET_DIR="${1:-$HOME}"
TARGET_VERSION="3.11.11"
OUTPUT_FORMAT=""
OUTPUT_FILE=""
MAX_DEPTH=5

# 帮助信息
show_help() {
    cat << EOF
用法: $(basename "$0") [目录] [选项]

分析指定目录下的所有Python项目及其Python版本要求

参数:
    目录                要分析的目录路径 (默认: 用户主目录)

选项:
    -t, --target-version VERSION   目标升级版本 (默认: 3.11.11)
    -j, --json                     输出JSON格式
    -o, --output FILE              输出到文件
    -d, --max-depth N              最大搜索深度 (默认: 5)
    -h, --help                     显示帮助信息

示例:
    # 分析当前目录
    $(basename "$0")

    # 分析指定目录
    $(basename "$0") /path/to/projects

    # 输出JSON格式到文件
    $(basename "$0") -j -o report.json

    # 指定目标版本和搜索深度
    $(basename "$0") -v 3.12.0 -d 3

EOF
}

# 解析参数
while [[ $# -gt 0 ]]; do
    case $1 in
        -t|--target-version)
            TARGET_VERSION="$2"
            shift 2
            ;;
        -j|--json)
            OUTPUT_FORMAT="--json"
            shift
            ;;
        -o|--output)
            OUTPUT_FILE="$2"
            shift 2
            ;;
        -d|--max-depth)
            MAX_DEPTH="$2"
            shift 2
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        -*)
            echo "错误: 未知选项 $1" >&2
            show_help
            exit 1
            ;;
        *)
            if [[ -d "$1" ]]; then
                TARGET_DIR="$1"
            else
                echo "错误: 目录不存在: $1" >&2
                exit 1
            fi
            shift
            ;;
    esac
done

# 检查Python
if ! command -v python3 &> /dev/null; then
    echo "错误: 未找到python3命令" >&2
    echo "请安装Python 3: https://www.python.org/downloads/" >&2
    exit 1
fi

# 构建命令
CMD="python3 ${SCRIPT_DIR}/analyze_python_projects.py '${TARGET_DIR}'"
CMD+=" --target-version ${TARGET_VERSION}"
CMD+=" --max-depth ${MAX_DEPTH}"

if [[ -n "$OUTPUT_FORMAT" ]]; then
    CMD+=" $OUTPUT_FORMAT"
fi

if [[ -n "$OUTPUT_FILE" ]]; then
    CMD+=" --output '${OUTPUT_FILE}'"
fi

# 执行分析
echo "Python项目版本分析工具"
echo "目标目录: $TARGET_DIR"
echo "目标版本: $TARGET_VERSION"
echo "搜索深度: $MAX_DEPTH"
echo "========================================"
echo ""

eval $CMD
