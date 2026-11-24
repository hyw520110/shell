#!/bin/bash

# 设置颜色输出
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

echo -e "${GREEN}🚀 开始配置 MarkItDown...${NC}"

# 1. 检查 uv 是否已安装
if ! command -v uv &> /dev/null; then
    echo -e "${YELLOW}⚠️  未检测到 uv，正在自动安装 uv...${NC}"
    curl -LsSf https://astral.sh/uv/install.sh | sh
    
    # 将 uv 加入当前 shell 的 PATH (适配 macOS 和 Linux 常见配置)
    export PATH="$HOME/.local/bin:$PATH"
    
    if ! command -v uv &> /dev/null; then
        echo -e "${RED}❌ uv 安装失败，请检查网络或手动安装后重试。${NC}"
        exit 1
    fi
fi

echo -e "${GREEN}✅ 检测到 uv: $(uv --version)${NC}"

# 2. 检查 markitdown 是否已安装
if uv tool list | grep -q "markitdown"; then
    echo -e "${YELLOW}💡 MarkItDown 已经安装，无需重复配置。${NC}"
else
    echo -e "${GREEN}📦 正在使用 uv 全局安装 MarkItDown (全量依赖)...${NC}"
    # 使用 uv tool install 自动处理虚拟环境隔离，并优先选择 3.12 版本
    uv tool install 'markitdown[all]' --python 3.12
    
    if [ $? -ne 0 ]; then
        echo -e "${RED}❌ MarkItDown 安装失败，请检查上方报错信息。${NC}"
        exit 1
    fi
    echo -e "${GREEN}✅ MarkItDown 安装成功！${NC}"
fi

# 3. 验证安装
echo -e "${GREEN}🔍 验证安装状态...${NC}"
uv tool list | grep markitdown

# 4. 输出使用指南
echo -e "\n${GREEN}=========================================${NC}"
echo -e "${GREEN}🎉 MarkItDown 配置完成！常用命令指南：${NC}"
echo -e "${GREEN}=========================================${NC}"
echo -e "1. 转换单个文件:"
echo -e "   ${YELLOW}markitdown input.pdf -o output.md${NC}"
echo -e "2. 批量转换当前目录下所有 PDF:"
echo -e "   ${YELLOW}for f in *.pdf; do markitdown \"\$f\" -o \"\${f%.pdf}.md\"; done${NC}"
echo -e "3. 查看支持的格式与帮助:"
echo -e "   ${YELLOW}markitdown --help${NC}"
echo -e "=========================================\n"
