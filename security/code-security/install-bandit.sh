#!/bin/bash
# Bandit - Python代码安全检查工具
# 功能：静态分析Python代码，发现常见安全漏洞
# 官方文档：https://github.com/PyCQA/bandit

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# 配置
VENV_DIR="$HOME/.bandit_venv"
BANDIT_VERSION="latest"

echo -e "${GREEN}=== Bandit Python代码安全检查工具 安装脚本 ===${NC}"

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

# 激活虚拟环境并安装bandit
echo -e "${YELLOW}安装Bandit...${NC}"
source ${VENV_DIR}/bin/activate

# 升级pip
pip install --upgrade pip

# 安装bandit及其扩展
pip install bandit bandit-sarif-formatter

# 安装额外的插件
pip install bandit-toml

# 验证安装
echo -e "${YELLOW}验证Bandit安装...${NC}"
bandit --version

# 创建启动脚本
cat << 'EOF' | sudo tee /usr/local/bin/bandit-check > /dev/null
#!/bin/bash
# Bandit代码安全检查启动脚本

VENV_DIR="$HOME/.bandit_venv"

if [ ! -d "${VENV_DIR}" ]; then
    echo "错误: Bandit虚拟环境不存在: ${VENV_DIR}"
    echo "请运行安装脚本: install-bandit.sh"
    exit 1
fi

source ${VENV_DIR}/bin/activate

if [ $# -eq 0 ]; then
    echo "用法: bandit-check [选项] <文件或目录>"
    echo ""
    echo "选项:"
    echo "  -r, --recursive          递归检查目录"
    echo "  -f, --format FORMAT      输出格式 (screen, json, csv, html, txt, sarif)"
    echo "  -o, --output FILE        输出到文件"
    echo "  -s, --severity LEVEL     严重级别 (low, medium, high)"
    echo "  -c, --confidence LEVEL   置信度 (low, medium, high)"
    echo "  -i, --ignore TEST        忽略指定的测试ID"
    echo "  -ll, --low               包含低严重级别"
    echo "  -iii, --insecure         包含不安全配置"
    echo ""
    echo "常用命令:"
    echo "  bandit-check -r /path/to/project"
    echo "  bandit-check -r /path/to/project -f json -o report.json"
    echo "  bandit-check -r /path/to/project -s medium -c high"
    echo ""
    echo "示例:"
    echo "  bandit-check -r . -f json -o security-report.json"
    echo "  bandit-check script.py"
    exit 1
fi

bandit "$@"
deactivate
EOF

sudo chmod +x /usr/local/bin/bandit-check

# 创建Bandit配置文件模板
cat << 'EOF' > ${VENV_DIR}/bandit.yaml
# Bandit配置文件
# 将此文件复制到项目根目录为 .bandit 或 bandit.yaml

# 排除的目录和文件
exclude_dirs:
  - /test/
  - /tests/
  - /venv/
  - /.venv/
  - /env/
  - /.env/
  - /__pycache__/

# 测试ID排除
# B101: assert_used
# B102: exec_used
# B103: set_bad_file_permissions
# B104: bind_all_interfaces
# B105: hardcoded_password_string
# B106: hardcoded_password_funcarg
# B107: hardcoded_password_default
# B108: hardcoded_tmp_file
# B110: try_except_pass
# B112: try_except_continue
# B201: flask_debug_true
# B301: pickle
# B302: marshal
# B303: md5
# B304: ciphers
# B305: cipher_modes
# B306: mktemp_q
# B307: eval
# B308: mark_safe
# B309: httpsconnection
# B310: urllib_urlopen
# B311: random
# B312: telnetlib
# B313: xml_bad_cElementTree
# B314: xml_bad_ElementTree
# B315: xml_bad_expatreader
# B316: xml_bad_expatbuilder
# B317: xml_bad_sax
# B318: xml_bad_minidom
# B319: xml_bad_pulldom
# B320: xml_bad_etree
# B321: ftplib
# B322: input
# B323: unverified_context
# B324: hashlib_new_insecure_functions
# B325: tempnam
# B401: import_telnetlib
# B402: import_ftplib
# B403: import_pickle
# B404: import_subprocess
# B405: import_xml_etree
# B406: import_xml_sax
# B407: import_xml_expat
# B408: import_xml_minidom
# B409: import_xml_pulldom
# B410: import_lxml
# B411: import_xmlrpclib
# B412: import_httpoxy
# B413: import_pycrypto
# B501: request_with_no_cert_validation
# B502: ssl_with_bad_version
# B503: ssl_with_bad_defaults
# B504: ssl_with_no_version
# B505: weak_cryptographic_key
# B506: yaml_load
# B507: ssh_no_host_key_verification
# B601: paramiko_calls
# B602: subprocess_popen_with_shell_equals_true
# B603: subprocess_without_shell_equals_true
# B604: any_other_function_with_shell_equals_true
# B605: start_process_with_a_shell
# B606: start_process_with_no_shell
# B607: start_process_with_partial_path
# B608: hardcoded_sql_expressions
# B609: linux_commands_wildcard_injection
# B610: django_extra_used
# B611: django_rawsql_used
# B701: jinja2_autoescape_false
# B702: use_of_mako_templates
# B703: django_mark_safe

# 排除测试ID
skips:
  - B101  # 允许使用assert
  - B601  # paramiko误报较多

# 测试包含
tests: []

# 严重级别过滤
# severity: medium

# 置信度过滤
# confidence: high
EOF

# 创建GitHub Actions工作流模板
cat << 'EOF' > ${VENV_DIR}/templates/github-actions.yml
name: Bandit Security Scan

on:
  push:
    branches: [ main, develop ]
  pull_request:
    branches: [ main, develop ]

jobs:
  bandit:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3
      - name: Set up Python
        uses: actions/setup-python@v4
        with:
          python-version: '3.9'
      - name: Install Bandit
        run: |
          pip install --upgrade pip
          pip install bandit bandit-sarif-formatter
      - name: Run Bandit
        run: |
          bandit -r . -f json -o bandit-report.json || true
      - name: Upload Bandit Report
        if: always()
        uses: actions/upload-artifact@v3
        with:
          name: bandit-report
          path: bandit-report.json
EOF

# 创建pre-commit钩子
cat << 'EOF' > ${VENV_DIR}/templates/pre-commit-config.yaml
# Pre-commit配置文件
# 将此内容添加到 .pre-commit-config.yaml

repos:
  - repo: https://github.com/PyCQA/bandit
    rev: ''  # 使用最新版本
    hooks:
      - id: bandit
        args: ['-r', '.', '-s', 'medium', '-c', 'bandit.yaml']
        exclude: ^tests/
EOF

# 显示安装信息
echo -e "${GREEN}=== Bandit安装完成 ===${NC}"
echo -e "虚拟环境: ${VENV_DIR}"
echo -e "启动命令: bandit-check"
echo ""
echo "使用方法:"
echo "  基本检查: bandit-check -r /path/to/project"
echo "  JSON报告: bandit-check -r /path/to/project -f json -o report.json"
echo "  HTML报告: bandit-check -r /path/to/project -f html -o report.html"
echo "  高严重级别: bandit-check -r /path/to/project -s high"
echo "  高置信度: bandit-check -r /path/to/project -c high"
echo "  排除测试: bandit-check -r /path/to/project -i B101,B601"
echo ""
echo "配置文件: ${VENV_DIR}/bandit.yaml"
echo "GitHub Actions模板: ${VENV_DIR}/templates/github-actions.yml"
echo "Pre-commit模板: ${VENV_DIR}/templates/pre-commit-config.yaml"
echo ""
echo "卸载: rm -rf ${VENV_DIR} /usr/local/bin/bandit-check"
echo ""
echo -e "${YELLOW}提示: 建议将bandit集成到CI/CD流程中，每次提交代码时自动检查${NC}"