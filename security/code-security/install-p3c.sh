#!/bin/bash
# P3C - Alibaba Java代码规范检查工具
# 功能：静态代码分析，检查Java代码是否符合阿里巴巴Java开发手册规范
# 官方文档：https://github.com/alibaba/p3c

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# 配置
P3C_VERSION="2.1.0"
P3C_INSTALL_DIR="/opt/p3c"
P3C_URL="https://github.com/alibaba/p3c/releases/download/p3c-${P3C_VERSION}/p3c-pmd-plugin-${P3C_VERSION}-jar-with-dependencies.jar"

echo -e "${GREEN}=== P3C Alibaba Java代码规范检查工具 安装脚本 ===${NC}"

# 检查Java环境
if ! command -v java &> /dev/null; then
    echo -e "${RED}错误: 未找到Java环境，请先安装Java 8+${NC}"
    exit 1
fi

echo -e "${YELLOW}Java版本: $(java -version 2>&1 | head -n 1)${NC}"

# 检查Maven环境（可选，Maven插件使用）
if command -v mvn &> /dev/null; then
    echo -e "${YELLOW}检测到Maven环境，将同时安装Maven插件${NC}"
    HAS_MAVEN=true
else
    echo -e "${YELLOW}未检测到Maven环境，仅安装独立JAR包${NC}"
    HAS_MAVEN=false
fi

# 创建安装目录
echo -e "${YELLOW}创建安装目录: ${P3C_INSTALL_DIR}${NC}"
sudo mkdir -p ${P3C_INSTALL_DIR}

# 下载P3C JAR包
P3C_JAR="${P3C_INSTALL_DIR}/p3c-pmd-plugin.jar"
if [ -f "${P3C_JAR}" ]; then
    echo -e "${YELLOW}P3C JAR已存在，跳过下载${NC}"
else
    echo -e "${YELLOW}下载P3C JAR包...${NC}"
    curl -fsSL -o "${P3C_JAR}" "${P3C_URL}"
fi

# 创建启动脚本
cat << 'EOF' | sudo tee ${P3C_INSTALL_DIR}/p3c-check.sh > /dev/null
#!/bin/bash
# P3C代码检查启动脚本

P3C_JAR="/opt/p3c/p3c-pmd-plugin.jar"

if [ ! -f "${P3C_JAR}" ]; then
    echo "错误: P3C JAR包不存在: ${P3C_JAR}"
    exit 1
fi

if [ $# -eq 0 ]; then
    echo "用法: p3c-check <项目目录> [其他pmd参数]"
    echo "示例: p3c-check /path/to/project"
    echo "示例: p3c-check /path/to/project -R /path/to/custom-rules.xml"
    exit 1
fi

PROJECT_DIR="$1"
shift

echo "P3C代码检查: ${PROJECT_DIR}"
java -jar "${P3C_JAR}" -d "${PROJECT_DIR}" -R rulesets/java/ali-comment.xml -R rulesets/java/ali-concurrent.xml -R rulesets/java/ali-constant.xml -R rulesets/java/ali-exception.xml -R rulesets/java/ali-flowcontrol.xml -R rulesets/java/ali-naming.xml -R rulesets/java/ali-oop.xml -R rulesets/java/ali-orm.xml -R rulesets/java/ali-other.xml -R rulesets/java/ali-set.xml "$@"
EOF

sudo chmod +x ${P3C_INSTALL_DIR}/p3c-check.sh

# 创建软链接
sudo ln -sf ${P3C_INSTALL_DIR}/p3c-check.sh /usr/local/bin/p3c-check

# 安装Maven插件（如果存在Maven）
if [ "$HAS_MAVEN" = true ]; then
    echo -e "${YELLOW}安装Maven插件...${NC}"
    
    # 创建Maven插件配置目录
    mkdir -p ~/.m2
    
    # 创建Maven settings配置
    cat << 'EOF' > ~/.m2/p3c-settings.xml
<settings>
    <profiles>
        <profile>
            <id>p3c</id>
            <activation>
                <activeByDefault>true</activeByDefault>
            </activation>
            <properties>
                <maven.compiler.compilerVersion>1.8</maven.compiler.compilerVersion>
                <maven.compiler.source>1.8</maven.compiler.source>
                <maven.compiler.target>1.8</maven.compiler.target>
                <project.build.sourceEncoding>UTF-8</project.build.sourceEncoding>
            </properties>
        </profile>
    </profiles>
</settings>
EOF
    
    echo -e "${YELLOW}已创建Maven配置文件: ~/.m2/p3c-settings.xml${NC}"
    echo -e "${YELLOW}在项目中添加以下Maven插件配置：${NC}"
    cat << 'PLUGIN'
<plugin>
    <groupId>com.alibaba.p3c</groupId>
    <artifactId>p3c-pmd</artifactId>
    <version>2.1.0</version>
    <configuration>
        <rulesets>
            <ruleset>rulesets/java/ali-comment.xml</ruleset>
            <ruleset>rulesets/java/ali-concurrent.xml</ruleset>
            <ruleset>rulesets/java/ali-constant.xml</ruleset>
            <ruleset>rulesets/java/ali-exception.xml</ruleset>
            <ruleset>rulesets/java/ali-flowcontrol.xml</ruleset>
            <ruleset>rulesets/java/ali-naming.xml</ruleset>
            <ruleset>rulesets/java/ali-oop.xml</ruleset>
            <ruleset>rulesets/java/ali-orm.xml</ruleset>
            <ruleset>rulesets/java/ali-other.xml</ruleset>
            <ruleset>rulesets/java/ali-set.xml</ruleset>
        </rulesets>
    </configuration>
</plugin>
PLUGIN
fi

# 显示安装信息
echo -e "${GREEN}=== P3C安装完成 ===${NC}"
echo -e "安装目录: ${P3C_INSTALL_DIR}"
echo -e "JAR文件: ${P3C_JAR}"
echo ""
echo "使用方法:"
echo "  独立工具: p3c-check <项目目录>"
echo "  示例: p3c-check /path/to/your/java/project"
echo ""
echo "  Maven插件: 在pom.xml中添加上述插件配置，然后运行:"
echo "  mvn pmd:check"
echo ""
echo "卸载: rm -rf ${P3C_INSTALL_DIR} /usr/local/bin/p3c-check"