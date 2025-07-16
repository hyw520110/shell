#!/bin/bash

# 忽略列表
IGNORE_PACKAGES="_libgcc_mutex|_openmp_mutex|pip|setuptools|wheel|python|openssl|libgcc-ng|libstdcxx-ng|zlib|ca-certificates|certifi|tzdata|readline|sqlite|ncurses|libffi|tk|libgomp|lz4-c|packaging|pluggy|pycosat|pycparser|pyopenssl|pysocks|requests|ruamel.yaml|ruamel.yaml.clib|tqdm|urllib3|xz|zstandard|zstd|conda|conda-package-handling|conda-package-streaming|boltons|brotli-python|cffi|charset-normalizer|cryptography|idna|jsonpatch|jsonpointer"

# 默认目录为当前目录
TARGET_DIR=${1:-$(pwd)}

# 允许用户通过命令行参数指定日志文件路径
LOG_FILE=${2:-"$HOME/logs/uninstall_packages.log"}

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
read -p "是否继续卸载这些包？(y/n): " CONFIRM
if [[ "$CONFIRM" == "n" ]]; then
    echo "操作已取消。" | tee -a "$LOG_FILE"
    rm "$LOG_FILE"  # 删除空日志文件
    exit 0
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