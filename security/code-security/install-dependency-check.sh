#!/bin/bash
# OWASP Dependency-Check - 依赖漏洞检查工具
# 功能：检查项目依赖是否存在已知安全漏洞，支持Java、Python、JavaScript等多种语言
# 官方文档：https://owasp.org/www-project-dependency-check/
# GitHub: https://github.com/jeremylong/DependencyCheck

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# 配置
DEPENDENCY_CHECK_VERSION="8.4.0"
DEPENDENCY_CHECK_INSTALL_DIR="/opt/dependency-check"
DEPENDENCY_CHECK_URL="https://github.com/jeremylong/DependencyCheck/releases/download/v${DEPENDENCY_CHECK_VERSION}/dependency-check-${DEPENDENCY_CHECK_VERSION}-release.zip"
DEPENDENCY_CHECK_HOME="${DEPENDENCY_CHECK_INSTALL_DIR}/dependency-check"

echo -e "${GREEN}=== OWASP Dependency-Check 依赖漏洞检查工具 安装脚本 ===${NC}"

# 检查Java环境
if ! command -v java &> /dev/null; then
    echo -e "${RED}错误: 未找到Java环境，请先安装Java 11+${NC}"
    exit 1
fi

JAVA_VERSION=$(java -version 2>&1 | head -n 1 | cut -d'"' -f2)
echo -e "${YELLOW}Java版本: ${JAVA_VERSION}${NC}"

# 检查是否有unzip
if ! command -v unzip &> /dev/null; then
    echo -e "${RED}错误: 未找到unzip命令，请先安装${NC}"
    exit 1
fi

# 创建安装目录
echo -e "${YELLOW}创建安装目录: ${DEPENDENCY_CHECK_INSTALL_DIR}${NC}"
sudo mkdir -p ${DEPENDENCY_CHECK_INSTALL_DIR}

# 下载Dependency-Check
TEMP_DIR="/tmp/dependency-check"
mkdir -p ${TEMP_DIR}
ZIP_FILE="${TEMP_DIR}/dependency-check.zip"

if [ -f "${ZIP_FILE}" ]; then
    echo -e "${YELLOW}Dependency-Check已下载，跳过下载${NC}"
else
    echo -e "${YELLOW}下载Dependency-Check v${DEPENDENCY_CHECK_VERSION}...${NC}"
    curl -fsSL -o "${ZIP_FILE}" "${DEPENDENCY_CHECK_URL}"
fi

# 解压
if [ -d "${DEPENDENCY_CHECK_HOME}" ]; then
    echo -e "${YELLOW}Dependency-Check已安装，删除旧版本...${NC}"
    sudo rm -rf "${DEPENDENCY_CHECK_HOME}"
fi

echo -e "${YELLOW}解压到 ${DEPENDENCY_CHECK_INSTALL_DIR}...${NC}"
sudo unzip -q "${ZIP_FILE}" -d ${DEPENDENCY_CHECK_INSTALL_DIR}

# 创建启动脚本
cat << 'EOF' | sudo tee /usr/local/bin/dependency-check > /dev/null
#!/bin/bash
# OWASP Dependency-Check启动脚本

DEPENDENCY_CHECK_HOME="/opt/dependency-check/dependency-check"
SCRIPT_DIR="${DEPENDENCY_CHECK_HOME}/bin"

if [ ! -d "${DEPENDENCY_CHECK_HOME}" ]; then
    echo "错误: Dependency-Check未安装: ${DEPENDENCY_CHECK_HOME}"
    echo "请运行安装脚本: install-dependency-check.sh"
    exit 1
fi

if [ ! -f "${SCRIPT_DIR}/dependency-check.sh" ]; then
    echo "错误: Dependency-Check脚本不存在: ${SCRIPT_DIR}/dependency-check.sh"
    exit 1
fi

# 默认数据目录
DATA_DIR="${HOME}/.dependency-check"
mkdir -p ${DATA_DIR}

if [ $# -eq 0 ]; then
    echo "用法: dependency-check [选项]"
    echo ""
    echo "选项:"
    echo "  --project PROJECT_NAME        项目名称"
    echo "  --scan DIRECTORY              扫描目录"
    echo "  --out REPORT_DIR              报告输出目录"
    echo "  --format FORMAT               报告格式 (HTML, XML, JSON, CSV, JUNIT, SARIF)"
    echo "  --data DATA_DIR               数据缓存目录"
    echo "  --noupdate                    不更新漏洞数据库"
    echo "  --suppression FILE            抑制规则文件"
    echo "  --failBuildOnCVSS SCORE       CVSS分数阈值，超过则失败"
    echo "  --enableExperimental          启用实验性分析器"
    echo ""
    echo "常用命令:"
    echo "  Java项目: dependency-check --scan . --out reports --format HTML"
    echo "  Python项目: dependency-check --scan . --out reports --format HTML --enableExperimental"
    echo "  Node.js项目: dependency-check --scan . --out reports --format HTML --enableExperimental"
    echo ""
    echo "示例:"
    echo "  dependency-check --scan /path/to/project --out ./reports --format HTML,JSON"
    echo "  dependency-check --scan . --out ./reports --format HTML --noupdate"
    echo "  dependency-check --scan . --out ./reports --format HTML --failBuildOnCVSS 7"
    exit 1
fi

# 执行Dependency-Check
bash "${SCRIPT_DIR}/dependency-check.sh" --data "${DATA_DIR}" "$@"
EOF

sudo chmod +x /usr/local/bin/dependency-check

# 创建抑制规则文件模板
mkdir -p ${DEPENDENCY_CHECK_INSTALL_DIR}/templates
cat << 'EOF' > ${DEPENDENCY_CHECK_INSTALL_DIR}/templates/suppressions.xml
<?xml version="1.0" encoding="UTF-8"?>
<!--
  OWASP Dependency-Check 抑制规则文件
  用于忽略特定的误报或已知无害的漏洞
-->
<suppressions>
    <!-- 示例：抑制特定的CVE -->
    <!--
    <suppress>
        <notes><![CDATA[
            忽略某个包的特定漏洞，例如误报
        ]]></notes>
        <cve>CVE-2021-12345</cve>
    </suppress>
    -->
    
    <!-- 示例：抑制某个包的所有漏洞 -->
    <!--
    <suppress>
        <notes><![CDATA[
            忽略某个包的所有漏洞，例如内部私有包
        ]]></notes>
        <packageUrl regex="true">^pkg:maven/com\.example/.*@.*$</packageUrl>
    </suppress>
    -->
    
    <!-- 示例：抑制特定的CVSS分数以下的漏洞 -->
    <!--
    <suppress>
        <notes><![CDATA[
            忽略CVSS分数低于7.0的漏洞
        ]]></notes>
        <cvssBelow>7.0</cvssBelow>
    </suppress>
    -->
</suppressions>
EOF

# 创建GitHub Actions工作流模板
cat << 'EOF' > ${DEPENDENCY_CHECK_INSTALL_DIR}/templates/github-actions.yml
name: OWASP Dependency-Check

on:
  push:
    branches: [ main, develop ]
  pull_request:
    branches: [ main, develop ]
  schedule:
    - cron: '0 0 * * 0'  # 每周日凌晨检查

jobs:
  dependency-check:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3
      - name: Set up JDK 11
        uses: actions/setup-java@v3
        with:
          java-version: '11'
          distribution: 'temurin'
      - name: Download Dependency-Check
        run: |
          wget https://github.com/jeremylong/DependencyCheck/releases/download/v8.4.0/dependency-check-8.4.0-release.zip
          unzip dependency-check-8.4.0-release.zip
      - name: Run Dependency-Check
        run: |
          ./dependency-check/bin/dependency-check.sh --scan . --out reports --format HTML,JSON,SARIF --failBuildOnCVSS 7 || true
      - name: Upload Dependency-Check Report
        if: always()
        uses: actions/upload-artifact@v3
        with:
          name: dependency-check-report
          path: reports/
      - name: Upload SARIF to GitHub Security
        if: always()
        uses: github/codeql-action/upload-sarif@v2
        with:
          sarif_file: reports/dependency-check-report.sarif
EOF

# 创建Maven插件配置模板
cat << 'EOF' > ${DEPENDENCY_CHECK_INSTALL_DIR}/templates/maven-plugin.xml
<!-- Maven插件配置，添加到pom.xml的plugins部分 -->
<plugin>
    <groupId>org.owasp</groupId>
    <artifactId>dependency-check-maven</artifactId>
    <version>8.4.0</version>
    <executions>
        <execution>
            <goals>
                <goal>check</goal>
            </goals>
        </execution>
    </executions>
    <configuration>
        <format>HTML</format>
        <format>JSON</format>
        <format>SARIF</format>
        <failBuildOnCVSS>7</failBuildOnCVSS>
        <suppressionFiles>
            <suppressionFile>suppressions.xml</suppressionFile>
        </suppressionFiles>
    </configuration>
</plugin>
EOF

# 创建Gradle插件配置模板
cat << 'EOF' > ${DEPENDENCY_CHECK_INSTALL_DIR}/templates/gradle-plugin.gradle
// Gradle插件配置，添加到build.gradle

plugins {
    id 'org.owasp.dependencycheck' version '8.4.0'
}

dependencyCheck {
    format = 'HTML'
    formats = ['HTML', 'JSON', 'SARIF']
    failBuildOnCVSS = 7
    suppressionFile = 'suppressions.xml'
    analyzers {
        assemblyEnabled = false
        experimentalEnabled = true
    }
}

// 检查任务
check.dependsOn dependencyCheckAnalyze
EOF

# 清理临时文件
rm -rf ${TEMP_DIR}

# 显示安装信息
echo -e "${GREEN}=== OWASP Dependency-Check安装完成 ===${NC}"
echo -e "安装目录: ${DEPENDENCY_CHECK_INSTALL_DIR}"
echo -e "启动命令: dependency-check"
echo ""
echo "使用方法:"
echo "  基本扫描: dependency-check --scan /path/to/project --out ./reports"
echo "  多格式报告: dependency-check --scan . --out ./reports --format HTML,JSON,SARIF"
echo "  不更新数据库: dependency-check --scan . --out ./reports --noupdate"
echo "  使用抑制规则: dependency-check --scan . --out ./reports --suppression suppressions.xml"
echo "  CVSS阈值: dependency-check --scan . --out ./reports --failBuildOnCVSS 7"
echo ""
echo "支持的项目类型:"
echo "  - Java (Maven/Gradle): 自动识别pom.xml或build.gradle"
echo "  - Python: 需要启用--enableExperimental"
echo "  - Node.js: 需要启用--enableExperimental"
echo "  - .NET: 自动识别.csproj或packages.config"
echo "  - Ruby: 需要启用--enableExperimental"
echo ""
echo "配置模板:"
echo "  抑制规则: ${DEPENDENCY_CHECK_INSTALL_DIR}/templates/suppressions.xml"
echo "  Maven插件: ${DEPENDENCY_CHECK_INSTALL_DIR}/templates/maven-plugin.xml"
echo "  Gradle插件: ${DEPENDENCY_CHECK_INSTALL_DIR}/templates/gradle-plugin.gradle"
echo "  GitHub Actions: ${DEPENDENCY_CHECK_INSTALL_DIR}/templates/github-actions.yml"
echo ""
echo "卸载: rm -rf ${DEPENDENCY_CHECK_INSTALL_DIR} /usr/local/bin/dependency-check ${HOME}/.dependency-check"
echo ""
echo -e "${YELLOW}提示: 首次运行会下载漏洞数据库（约500MB），请耐心等待${NC}"
echo -e "${YELLOW}建议: 定期运行以保持数据库更新，建议集成到CI/CD流程${NC}"