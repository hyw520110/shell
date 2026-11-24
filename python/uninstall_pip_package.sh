#!/bin/bash

# 显示帮助信息
show_help() {
    cat << EOF
批量卸载 pip 包脚本

批量卸载指定环境中的 pip 包和 conda 包，支持日志记录。

用法: ./uninstall_pip_package.sh [目录] [日志文件]

参数:
    目录               目标环境目录（默认: 当前目录）
    日志文件           日志文件路径（默认: ~/logs/uninstall_packages.log）

选项:
    -h, --help         显示此帮助信息
    -v, --version      显示版本信息
    --yes              跳过确认直接卸载

说明:
    - 自动检测当前环境的 pip 和 conda 包
    - 忽略基础包（pip、setuptools、wheel等）
    - 支持批量并行卸载
    - 自动生成详细日志
    - 用户确认后执行卸载

忽略的包:
    基础运行时包和系统包会被自动忽略，避免破坏环境：
    - pip, setuptools, wheel
    - python, openssl, zlib
    - 系统依赖库等

示例:
    ./uninstall_pip_package.sh                          # 卸载当前环境
    ./uninstall_pip_package.sh /path/to/project         # 卸载指定目录
    ./uninstall_pip_package.sh . /var/log/uninstall.log # 自定义日志路径
    ./uninstall_pip_package.sh --yes                    # 自动确认卸载

使用场景:
    - 清理测试环境
    - 重置开发环境
    - 移除不需要的依赖包
    - 环境迁移前清理

注意事项:
    - 卸载操作不可逆，请确认后执行
    - 建议在虚拟环境中使用
    - 卸载前建议导出依赖列表
    - 某些包可能有依赖关系

导出依赖列表:
    pip freeze > requirements.txt

查看日志:
    cat ~/logs/uninstall_packages.log

EOF
}

# 参数解析
AUTO_CONFIRM=false
TARGET_DIR=""
LOG_FILE=""

while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            show_help
            exit 0
            ;;
        -v|--version)
            echo "批量卸载pip包脚本版本: 1.0"
            exit 0
            ;;
        --yes)
            AUTO_CONFIRM=true
            shift
            ;;
        *)
            if [ -z "$TARGET_DIR" ]; then
                TARGET_DIR="$1"
            elif [ -z "$LOG_FILE" ]; then
                LOG_FILE="$1"
            else
                echo "未知参数: $1"
                show_help
                exit 1
            fi
            shift
            ;;
    esac
done

# 忽略列表
IGNORE_PACKAGES="_libgcc_mutex|_openmp_mutex|pip|setuptools|wheel|python|openssl|libgcc-ng|libstdcxx-ng|zlib|ca-certificates|certifi|tzdata|readline|sqlite|ncurses|libffi|tk|libgomp|lz4-c|packaging|pluggy|pycosat|pycparser|pyopenssl|pysocks|requests|ruamel.yaml|ruamel.yaml.clib|tqdm|urllib3|xz|zstandard|zstd|conda|conda-package-handling|conda-package-streaming|boltons|brotli-python|cffi|charset-normalizer|cryptography|idna|jsonpatch|jsonpointer"

# 默认目录为当前目录
TARGET_DIR=${TARGET_DIR:-$(pwd)}

# 允许用户通过命令行参数指定日志文件路径
LOG_FILE=${LOG_FILE:-"$HOME/logs/uninstall_packages.log"}

# 创建日志目录（如果不存在）
LOG_DIR=$(dirname "$LOG_FILE")
if [[ ! -d "$LOG_DIR" ]]; then
    echo "日志目录 '$LOG_DIR' 不存在，正在创建..." | tee -a "$LOG_FILE"
    mkdir -p "$LOG_DIR" || { echo "无法创建日志目录 '$LOG_DIR'，请检查权限！"; exit 1; }
fi

# 清空或创建日志文件
> "$LOG_FILE"

# 检查目标目录是否存在
if [[ ! -d "$TARGET_DIR" ]]; then
    echo "错误：目录 '$TARGET_DIR' 不存在！" | tee -a "$LOG_FILE"
    exit 1
fi

# 切换到目标目录
cd "$TARGET_DIR" || exit 1

# 检查是否是 Conda 环境
if [[ -n "$CONDA_PREFIX" ]]; then
    echo "检测到 Conda 环境：$CONDA_PREFIX" | tee -a "$LOG_FILE"
else
    echo "警告：未检测到 Conda 环境！如果您希望卸载 Conda 包，请先激活目标环境。" | tee -a "$LOG_FILE"
fi

# 获取 pip 和 conda 的包列表
echo "正在列出 pip 已安装的包..." | tee -a "$LOG_FILE"
# 调试信息：打印 pip list 的原始输出
DEBUG_PIP_LIST=$(pip list --format=freeze)
echo "$DEBUG_PIP_LIST" | tee -a "$LOG_FILE"

# 过滤掉 pip、setuptools 和 wheel
PIP_PACKAGES=$(echo "$DEBUG_PIP_LIST" | grep -Ev '^(pip|setuptools|wheel)=' | cut -d'=' -f1)

# 检查 conda 是否可用
if command -v conda &> /dev/null; then
    echo "正在列出 conda 已安装的包..." | tee -a "$LOG_FILE"
    CONDA_PACKAGES=$(conda list --export | grep -v '^#' | cut -d'=' -f1 | grep -Ev "^($IGNORE_PACKAGES)$")
fi

# 如果没有安装任何包
if [[ -z "$PIP_PACKAGES" && -z "$CONDA_PACKAGES" ]]; then
    echo "当前环境中未安装任何可卸载的 pip 或 conda 包。无需卸载。" | tee -a "$LOG_FILE"
    rm "$LOG_FILE"  # 删除空日志文件
    exit 0
fi

# 显示将要卸载的包
if [[ -n "$PIP_PACKAGES" ]]; then
    echo "以下 pip 包将被卸载：" | tee -a "$LOG_FILE"
    echo "$PIP_PACKAGES" | tee -a "$LOG_FILE"
fi

if [[ -n "$CONDA_PACKAGES" ]]; then
    echo "以下 conda 包将被卸载：" | tee -a "$LOG_FILE"
    echo "$CONDA_PACKAGES" | tee -a "$LOG_FILE"
fi

# 用户确认是否继续卸载
if [ "$AUTO_CONFIRM" = false ]; then
    read -p "是否继续卸载这些包？(y/n): " CONFIRM
    if [[ "$CONFIRM" == "n" ]]; then
        echo "操作已取消。" | tee -a "$LOG_FILE"
        rm "$LOG_FILE"  # 删除空日志文件
        exit 0
    fi
fi

# 开始卸载 pip 包
if [[ -n "$PIP_PACKAGES" ]]; then
    echo "开始批量卸载 pip 包..." | tee -a "$LOG_FILE"
    echo "$PIP_PACKAGES" | xargs -n 1 -P 4 -I {} sh -c 'echo "正在卸载 {}..." && pip uninstall -y {} || echo "卸载 {} 失败"' >> "$LOG_FILE" 2>&1
fi

# 开始卸载 conda 包
if [[ -n "$CONDA_PACKAGES" ]]; then
    echo "开始批量卸载 conda 包..." | tee -a "$LOG_FILE"
    echo "$CONDA_PACKAGES" | xargs -n 1 -P 4 -I {} sh -c 'echo "正在卸载 {}..." && conda remove -y {} || echo "卸载 {} 失败"' >> "$LOG_FILE" 2>&1
fi

# 卸载完成后提示用户查看日志
echo "所有包已卸载完成。" | tee -a "$LOG_FILE"
echo "卸载日志保存在 $LOG_FILE"