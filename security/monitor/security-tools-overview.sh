#!/bin/bash
# 安全工具总览脚本
# 按重要性和常用性排序的安全工具安装指南

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${GREEN}"
cat << 'EOF'
╔═══════════════════════════════════════════════════════════════╗
║           安全工具安装指南 - 基于安全架构V1.2                 ║
╚═══════════════════════════════════════════════════════════════╝
EOF
echo -e "${NC}"

echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}第一优先级（非常重要，强烈推荐）${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
echo ""

cat << 'EOF'
1. P3C - Alibaba Java代码规范检查
   用途: 静态代码分析，检查Java代码规范
   适用: Java项目
   安装: ./code-security/install-p3c.sh
   官方: https://github.com/alibaba/p3c

2. Safety - Python包安全检查
   用途: 检查Python包是否存在已知漏洞
   适用: Python项目
   安装: ./code-security/install-safety.sh
   官方: https://github.com/pyupio/safety

3. Bandit - Python代码安全检查
   用途: 静态分析Python代码，发现安全漏洞
   适用: Python项目
   安装: ./code-security/install-bandit.sh
   官方: https://github.com/PyCQA/bandit

4. pip-audit - Python依赖审计
   用途: 审计Python依赖，检查已知漏洞
   适用: Python项目
   安装: ./code-security/install-pip-audit.sh
   官方: https://github.com/pypa/pip-audit

5. OWASP Dependency-Check - 依赖漏洞检查
   用途: 检查项目依赖是否存在已知安全漏洞
   适用: Java/Python/Node.js/.NET等多语言
   安装: ./code-security/install-dependency-check.sh
   官方: https://owasp.org/www-project-dependency-check/
EOF

echo ""
echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}第二优先级（重要，推荐）${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
echo ""

cat << 'EOF'
6. AIDE - 文件完整性检查
   用途: 监控文件系统变更，检测未授权修改
   适用: Linux服务器
   安装: ./host-security/install-aide.sh
   官方: http://aide.sourceforge.net/

7. OSSEC - 主机入侵检测系统(HIDS)
   用途: 实时监控文件完整性、日志分析、恶意行为检测
   适用: Linux服务器
   安装: ./host-security/install-ossec.sh
   官方: https://www.ossec.net/

8. RKhunter - Rootkit检测
   用途: 检测系统中的rootkit和木马
   适用: Linux服务器
   安装: ./host-security/install-rkhunter.sh
   官方: http://rkhunter.sourceforge.net/
EOF

echo ""
echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}第三优先级（可选，已有替代工具）${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
echo ""

cat << 'EOF'
9. Chkrootkit - Rootkit检测
   用途: 检测rootkit和木马（与RKhunter功能类似）
   适用: Linux服务器
   安装: ./host-security/install-chkrootkit.sh
   官方: http://www.chkrootkit.org/

10. DenyHosts - SSH暴力破解防护
    用途: 自动阻止SSH暴力破解攻击（与Fail2ban功能类似）
    适用: Linux服务器
    安装: ./host-security/install-denyhosts.sh
    官方: http://denyhosts.sourceforge.net/

11. OWASP ZAP - Web应用安全扫描
    用途: 自动和手动Web应用安全测试
    适用: Web应用
    安装: ./web-security/zap/zap.sh install
    官方: https://www.zaproxy.org/

12. OpenSCAP - 安全合规检查
    用途: 安全合规检查、漏洞扫描、配置评估
    适用: 企业级安全合规
    安装: ./web-security/install-openscap.sh
    官方: https://www.open-scap.org/
EOF

echo ""
echo -e "${GREEN}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}已安装的安全工具（当前目录）${NC}"
echo -e "${GREEN}═══════════════════════════════════════════════════════════════${NC}"
echo ""

cd /Users/mac/workspace/shell

cat << 'EOF'
✓ nmap - 端口扫描
✓ fail2ban - SSH暴力破解防护
✓ clamav - 病毒扫描
✓ nikto - Web漏洞扫描
✓ nessus - 漏洞扫描
✓ openvas - 漏洞扫描
✓ sonarqube - 代码质量分析
✓ dependency-track - 依赖漏洞跟踪
✓ trivy - 容器镜像安全扫描
✓ sqlmap - SQL注入测试
✓ nuclei - 漏洞扫描
✓ lynis - 安全审计
EOF

echo ""
echo -e "${YELLOW}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${YELLOW}快速安装指南${NC}"
echo -e "${YELLOW}═══════════════════════════════════════════════════════════════${NC}"
echo ""

cat << 'EOF'
# 安装所有第一优先级工具（代码安全）
cd security/code-security
./install-p3c.sh
./install-safety.sh
./install-bandit.sh
./install-pip-audit.sh
./install-dependency-check.sh

# 安装所有第二优先级工具（主机安全）
cd ../host-security
./install-aide.sh
./install-ossec.sh
./install-rkhunter.sh

# 安装所有第三优先级工具（Web安全）
cd ../web-security
./install-chkrootkit.sh
./install-denyhosts.sh
./zap/zap.sh install
./install-openscap.sh
EOF

echo ""
echo -e "${YELLOW}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${YELLOW}集成到CI/CD${NC}"
echo -e "${YELLOW}═══════════════════════════════════════════════════════════════${NC}"
echo ""

cat << 'EOF'
# Python项目CI/CD示例
- safety: safety-check -f requirements.txt
- pip-audit: pip-audit-check -r requirements.txt
- bandit: bandit-check -r . -f json -o report.json

# Java项目CI/CD示例
- p3c: p3c-check /path/to/project
- dependency-check: dependency-check --scan . --out ./reports

# 主机安全定时任务
- aide: 0 2 * * * aide-check
- rkhunter: 0 3 * * * rkhunter-check --cronjob
EOF

echo ""
echo -e "${GREEN}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}注意事项${NC}"
echo -e "${GREEN}═══════════════════════════════════════════════════════════════${NC}"
echo ""

cat << 'EOF'
1. 定期更新安全工具和漏洞数据库
2. 将安全检查集成到开发流程中
3. 定期检查日志和报告
4. 根据实际需求选择合适的工具
5. 避免功能重复的工具（如fail2ban和denyhosts）
6. 仅对你有权限的系统进行安全扫描
7. 重要系统在操作前先备份
EOF

echo ""
echo -e "${BLUE}安全工具总览: $(ls -1 security/code-security/*.sh security/host-security/*.sh security/web-security/*.sh 2>/dev/null | wc -l) 个${NC}"
echo -e "${BLUE}已安装工具: $(ls -d /Users/mac/workspace/shell/{nmap,fail2ban,clamav,nikto,nessus,openvas,sonarqube,dependency-track,trivy,sqlmap,nuclei,lynis} 2>/dev/null | wc -l) 个${NC}"
echo ""
