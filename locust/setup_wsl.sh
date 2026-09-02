#!/bin/bash
# WSL2 环境快速设置脚本（一次性运行）
# 用法：wsl bash setup_wsl.sh

set -e

echo "=============================================="
echo "WSL2 环境设置"
echo "=============================================="

# 1. 更新包列表
echo "[1/5] 更新包列表..."
sudo apt-get update

# 2. 安装系统依赖
echo "[2/5] 安装系统依赖..."
sudo apt-get install -y python3 python3-pip bc curl

# 3. 安装 Python 依赖
echo "[3/5] 安装 Python 依赖..."
pip3 install -r requirements.txt

# 4. 创建报告目录
echo "[4/5] 创建报告目录..."
mkdir -p ~/locust_reports

# 5. 验证安装
echo "[5/5] 验证安装..."
echo ""
echo "检查系统依赖:"
python3 --version
pip3 --version
bc --version | head -1
echo ""
echo "检查 Python 依赖:"
python3 -c "import locust; print(f'locust: {locust.__version__}')"
python3 -c "import pandas; print(f'pandas: {pandas.__version__}')"
python3 -c "import jinja2; print(f'jinja2: {jinja2.__version__}')"
echo ""

# 6. 测试运行
echo "=============================================="
echo "✅ 环境设置完成！"
echo "=============================================="
echo ""
echo "测试运行:"
echo "  ./distributedbench.sh -H https://www.baidu.com -u 10 -t 10"
echo ""
echo "查看报告:"
echo "  报告目录：~/locust_reports/"
echo "  汇总报告：~/locust_reports/<domain>.html"
echo ""
