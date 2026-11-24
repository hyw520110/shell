#!/bin/bash
# pip-audit - Python依赖审计工具
# 功能：审计Python包依赖，检查已知安全漏洞
# 官方文档：https://github.com/pypa/pip-audit
# 数据源：PyPI Advisory Database (https://github.com/pypa/advisory-database)

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# 配置
VENV_DIR="$HOME/.pip_audit_venv"

echo -e "${GREEN}=== pip-audit Python依赖审计工具 安装脚本 ===${NC}"

# 检查Python环境
if ! command -v python3 &> /dev/null && ! command -v python &> /dev/null; then
    echo -e "${RED}错误: 未找到Python环境，请先安装Python 3.7+${NC}"
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

# 激活虚拟环境并安装pip-audit
echo -e "${YELLOW}安装pip-audit...${NC}"
source ${VENV_DIR}/bin/activate

# 升级pip
pip install --upgrade pip

# 安装pip-audit
pip install pip-audit

# 验证安装
echo -e "${YELLOW}验证pip-audit安装...${NC}"
pip-audit --version

# 创建启动脚本
cat << 'EOF' | sudo tee /usr/local/bin/pip-audit-check > /dev/null
#!/bin/bash
# pip-audit依赖审计启动脚本

VENV_DIR="$HOME/.pip_audit_venv"

if [ ! -d "${VENV_DIR}" ]; then
    echo "错误: pip-audit虚拟环境不存在: ${VENV_DIR}"
    echo "请运行安装脚本: install-pip-audit.sh"
    exit 1
fi

source ${VENV_DIR}/bin/activate

if [ $# -eq 0 ]; then
    echo "用法: pip-audit-check [选项]"
    echo ""
    echo "选项:"
    echo "  -r, --requirement FILE  指定requirements.txt文件"
    echo "  -f, --format FORMAT     输出格式 (json, columns, markdown, cyclonedx)"
    echo "  -o, --output FILE       输出到文件"
    echo "  --desc                  包含漏洞详细描述"
    echo "  --fix                   自动修复漏洞"
    echo "  --no-deps               不检查依赖的依赖"
    echo "  --strict                严格模式，发现漏洞立即退出"
    echo ""
    echo "示例:"
    echo "  pip-audit-check -r requirements.txt"
    echo "  pip-audit-check -r requirements.txt --fix"
    echo "  pip-audit-check -r requirements.txt -f json -o report.json"
    echo "  pip-audit-check -r requirements.txt --desc"
    exit 1
fi

pip-audit "$@"
deactivate
EOF

sudo chmod +x /usr/local/bin/pip-audit-check

# 创建GitHub Actions工作流模板
cat << 'EOF' > ${VENV_DIR}/templates/github-actions.yml
name: pip-audit Security Check

on:
  push:
    branches: [ main, develop ]
  pull_request:
    branches: [ main, develop ]
  schedule:
    - cron: '0 0 * * 0'  # 每周日凌晨检查

jobs:
  pip-audit:
    runs-on: ubuntu-latest
    strategy:
      matrix:
        python-version: ['3.8', '3.9', '3.10', '3.11']
    steps:
      - uses: actions/checkout@v3
      - name: Set up Python ${{ matrix.python-version }}
        uses: actions/setup-python@v4
        with:
          python-version: ${{ matrix.python-version }}
      - name: Install pip-audit
        run: |
          pip install --upgrade pip
          pip install pip-audit
      - name: Run pip-audit
        run: |
          pip-audit -r requirements.txt -f json -o pip-audit-report.json || true
        continue-on-error: true
      - name: Upload pip-audit Report
        if: always()
        uses: actions/upload-artifact@v3
        with:
          name: pip-audit-report-py${{ matrix.python-version }}
          path: pip-audit-report.json
      - name: Comment PR with results
        if: github.event_name == 'pull_request'
        uses: actions/github-script@v6
        with:
          script: |
            const fs = require('fs');
            const report = JSON.parse(fs.readFileSync('pip-audit-report.json', 'utf8'));
            const vulnerabilities = report.dependencies.filter(d => d.vulns && d.vulns.length > 0);
            
            if (vulnerabilities.length > 0) {
              let comment = '## 🚨 pip-audit Security Report\n\n';
              comment += `Found ${vulnerabilities.length} vulnerable packages:\n\n`;
              
              vulnerabilities.forEach(pkg => {
                comment += `### ${pkg.name} (${pkg.version})\n`;
                pkg.vulns.forEach(vuln => {
                  comment += `- ${vuln.advisory_id}: ${vuln.advisory.summary}\n`;
                  comment += `  Details: ${vuln.advisory.url}\n`;
                });
                comment += '\n';
              });
              
              github.rest.issues.createComment({
                issue_number: context.issue.number,
                owner: context.repo.owner,
                repo: context.repo.repo,
                body: comment
              });
            }
EOF

# 创建CI/CD集成脚本
cat << 'EOF' > ${VENV_DIR}/templates/ci-check.sh
#!/bin/bash
# CI/CD依赖审计脚本

set -e

echo "=== pip-audit 依赖安全审计 ==="

if [ -f "requirements.txt" ]; then
    echo "审计 requirements.txt..."
    
    # 生成报告
    pip-audit -r requirements.txt -f json -o pip-audit-report.json || true
    
    # 检查是否有漏洞
    if [ -s "pip-audit-report.json" ]; then
        VULN_COUNT=$(cat pip-audit-report.json | grep -o '"name"' | wc -l)
        
        if [ $VULN_COUNT -gt 0 ]; then
            echo "警告: 发现 $VULN_COUNT 个存在已知漏洞的包!"
            echo "详细报告: pip-audit-report.json"
            
            # 尝试自动修复
            echo ""
            echo "尝试自动修复..."
            pip-audit -r requirements.txt --fix || echo "部分漏洞无法自动修复"
            
            exit 1
        else
            echo "未发现已知安全漏洞"
        fi
    else
        echo "未发现已知安全漏洞"
    fi
else
    echo "未找到 requirements.txt 文件"
    exit 1
fi

echo "=== pip-audit 审计完成 ==="
EOF

chmod +x ${VENV_DIR}/templates/ci-check.sh

# 创建自动修复脚本
cat << 'EOF' > ${VENV_DIR}/templates/auto-fix.sh
#!/bin/bash
# 自动修复已知漏洞脚本

set -e

echo "=== pip-audit 自动修复脚本 ==="

if [ -f "requirements.txt" ]; then
    echo "检查并修复 requirements.txt 中的漏洞..."
    pip-audit -r requirements.txt --fix
    
    if [ $? -eq 0 ]; then
        echo "所有漏洞已修复，更新 requirements.txt"
        pip freeze > requirements.txt
        echo "修复完成!"
    else
        echo "部分漏洞无法自动修复，请手动检查"
        exit 1
    fi
else
    echo "未找到 requirements.txt 文件"
    exit 1
fi
EOF

chmod +x ${VENV_DIR}/templates/auto-fix.sh

# 显示安装信息
echo -e "${GREEN}=== pip-audit安装完成 ===${NC}"
echo -e "虚拟环境: ${VENV_DIR}"
echo -e "启动命令: pip-audit-check"
echo ""
echo "使用方法:"
echo "  基本审计: pip-audit-check -r requirements.txt"
echo "  详细描述: pip-audit-check -r requirements.txt --desc"
echo "  JSON报告: pip-audit-check -r requirements.txt -f json -o report.json"
echo "  Markdown报告: pip-audit-check -r requirements.txt -f markdown"
echo "  自动修复: pip-audit-check -r requirements.txt --fix"
echo "  严格模式: pip-audit-check -r requirements.txt --strict"
echo ""
echo "集成脚本:"
echo "  CI/CD检查: ${VENV_DIR}/templates/ci-check.sh"
echo "  自动修复: ${VENV_DIR}/templates/auto-fix.sh"
echo "  GitHub Actions: ${VENV_DIR}/templates/github-actions.yml"
echo ""
echo "卸载: rm -rf ${VENV_DIR} /usr/local/bin/pip-audit-check"
echo ""
echo -e "${YELLOW}提示: pip-audit官方数据源为PyPI Advisory Database，数据及时可靠${NC}"
echo -e "${YELLOW}建议: 与safety配合使用，相互验证结果${NC}"