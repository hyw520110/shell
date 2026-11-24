#!/bin/bash
# Safety - Python包安全检查工具
# 功能：检查已安装的Python包是否存在已知安全漏洞
# 官方文档：https://github.com/pyupio/safety
# 数据库：https://pyup.io/safety/

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# 配置
VENV_DIR="$HOME/.safety_venv"
REQUIREMENTS_FILE="requirements.txt"

echo -e "${GREEN}=== Safety Python包安全检查工具 安装脚本 ===${NC}"

# 检查Python环境
if ! command -v python3 &> /dev/null && ! command -v python &> /dev/null; then
    echo -e "${RED}错误: 未找到Python环境，请先安装Python 3.6+${NC}"
    exit 1
fi

# 优先使用python3
PYTHON_CMD="python3"
if ! command -v python3 &> /dev/null; then
    PYTHON_CMD="python"
fi

PYTHON_VERSION=$($PYTHON_CMD --version 2>&1)
echo -e "${YELLOW}Python版本: ${PYTHON_VERSION}${NC}"

# 创建虚拟环境
echo -e "${YELLOW}创建虚拟环境: ${VENV_DIR}${NC}"
if [ -d "${VENV_DIR}" ]; then
    echo -e "${YELLOW}虚拟环境已存在，删除重建...${NC}"
    rm -rf "${VENV_DIR}"
fi

$PYTHON_CMD -m venv ${VENV_DIR}

# 激活虚拟环境并安装safety
echo -e "${YELLOW}安装safety...${NC}"
source ${VENV_DIR}/bin/activate

# 升级pip
pip install --upgrade pip

# 安装safety
pip install safety

# 降级兼容处理（safety最新版可能有API变化）
echo -e "${YELLOW}验证safety安装...${NC}"
safety --version

# 创建启动脚本
cat << 'EOF' | sudo tee /usr/local/bin/safety-check > /dev/null
#!/bin/bash
# Safety包安全检查启动脚本

VENV_DIR="$HOME/.safety_venv"

if [ ! -d "${VENV_DIR}" ]; then
    echo "错误: Safety虚拟环境不存在: ${VENV_DIR}"
    echo "请运行安装脚本: install-safety.sh"
    exit 1
fi

source ${VENV_DIR}/bin/activate

if [ $# -eq 0 ]; then
    echo "用法: safety-check [选项] [目录]"
    echo ""
    echo "选项:"
    echo "  -f, --file FILE          指定requirements.txt文件"
    echo "  -r, --recursive DIR      递归检查目录中的所有requirements.txt"
    echo "  -i, --ignore ID          忽略指定的漏洞ID"
    echo "  --continue-on-error      遇到错误继续检查"
    echo "  --output FILE            输出到文件"
    echo ""
    echo "示例:"
    echo "  safety-check -f requirements.txt"
    echo "  safety-check -r /path/to/project"
    echo "  safety-check -f requirements.txt --output report.txt"
    exit 1
fi

safety check "$@"
deactivate
EOF

sudo chmod +x /usr/local/bin/safety-check

# 创建GitHub Actions工作流模板
mkdir -p ${VENV_DIR}/templates
cat << 'EOF' > ${VENV_DIR}/templates/github-actions.yml
name: Safety Check

on:
  push:
    branches: [ main, develop ]
  pull_request:
    branches: [ main, develop ]
  schedule:
    - cron: '0 0 * * *'  # 每天午夜检查

jobs:
  safety:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3
      - name: Set up Python
        uses: actions/setup-python@v4
        with:
          python-version: '3.9'
      - name: Install Safety
        run: |
          pip install --upgrade pip
          pip install safety
      - name: Run Safety
        run: |
          safety check --file requirements.txt --continue-on-error
        continue-on-error: true
EOF

# 创建CI/CD脚本
cat << 'EOF' > ${VENV_DIR}/templates/ci-check.sh
#!/bin/bash
# CI/CD安全检查脚本

echo "=== Safety 包安全检查 ==="

if [ -f "requirements.txt" ]; then
    echo "检查 requirements.txt..."
    safety check --file requirements.txt --continue-on-error
    if [ $? -ne 0 ]; then
        echo "警告: 发现已知安全漏洞!"
        echo "请访问 https://pyup.io/safety/ 查看详情"
    else
        echo "未发现已知安全漏洞"
    fi
else
    echo "未找到 requirements.txt 文件"
fi

echo "=== Safety 检查完成 ==="
EOF

chmod +x ${VENV_DIR}/templates/ci-check.sh

# 显示安装信息
echo -e "${GREEN}=== Safety安装完成 ===${NC}"
echo -e "虚拟环境: ${VENV_DIR}"
echo -e "启动命令: safety-check"
echo ""
echo "使用方法:"
echo "  检查requirements.txt: safety-check -f requirements.txt"
echo "  递归检查目录: safety-check -r /path/to/project"
echo "  忽略特定漏洞: safety-check -f requirements.txt -i 12345"
echo "  输出到文件: safety-check -f requirements.txt --output report.txt"
echo ""
echo "GitHub Actions模板: ${VENV_DIR}/templates/github-actions.yml"
echo "CI/CD检查脚本: ${VENV_DIR}/templates/ci-check.sh"
echo ""
echo "卸载: rm -rf ${VENV_DIR} /usr/local/bin/safety-check"
echo ""
echo -e "${YELLOW}提示: 定期运行 'safety-check -f requirements.txt' 检查依赖安全${NC}"