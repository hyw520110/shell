#!/bin/bash
# 迁移 Gitea 数据到外置硬盘
set -e

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${CYAN}>>> Gitea 数据迁移工具${NC}"

# 检测原路径
if [[ -d "/opt/homebrew/var/gitea" ]]; then
    OLD_PATH="/opt/homebrew/var/gitea"
    SERVICE_CMD="brew services"
elif [[ -d "/usr/local/var/gitea" ]]; then
    OLD_PATH="/usr/local/var/gitea"
    SERVICE_CMD="brew services"
else
    echo -e "${RED}[ERROR] 未检测到标准的 macOS Homebrew Gitea 数据目录。${NC}"
    exit 1
fi

echo -e "${YELLOW}当前 Gitea 数据目录: $OLD_PATH${NC}"

# 获取新路径
read -rp "请输入外置8T硬盘的 Gitea 目标存储路径 (例如 /Volumes/SSD8T/gitea): " NEW_PATH
if [[ -z "$NEW_PATH" ]]; then
    echo -e "${RED}[ERROR] 目标路径不能为空！${NC}"
    exit 1
fi

# 确保目标路径的父目录存在
PARENT_DIR="$(dirname "$NEW_PATH")"
if [[ ! -d "$PARENT_DIR" ]]; then
    echo -e "${RED}[ERROR] 外置硬盘路径 $PARENT_DIR 不存在，请检查硬盘是否已挂载。${NC}"
    exit 1
fi

echo ""
echo -e "${YELLOW}警告: 即将把 $OLD_PATH 迁移到 $NEW_PATH${NC}"
read -rp "确认要继续吗？ (y/N): " choice
if [[ ! "$choice" =~ ^[Yy]$ ]]; then
    echo "已取消。"
    exit 0
fi

# 1. 停止 Gitea 服务
echo -e "\n${CYAN}[1/5] 正在停止 Gitea 服务...${NC}"
$SERVICE_CMD stop gitea || true

# 2. 复制数据
echo -e "${CYAN}[2/5] 正在复制数据到外置硬盘 (可能需要一些时间)...${NC}"
mkdir -p "$NEW_PATH"
# 使用 rsync 保证权限和属性一致
rsync -avz --progress "$OLD_PATH/" "$NEW_PATH/"

# 3. 备份原目录并创建软链接
echo -e "${CYAN}[3/5] 创建软链接...${NC}"
mv "$OLD_PATH" "${OLD_PATH}_backup_$(date +%Y%m%d)"
ln -s "$NEW_PATH" "$OLD_PATH"

# 4. 修复权限
echo -e "${CYAN}[4/5] 修复外置硬盘的目录权限...${NC}"
chown -R "$(whoami):admin" "$NEW_PATH"

# 5. 重启服务
echo -e "${CYAN}[5/5] 重新启动 Gitea 服务...${NC}"
$SERVICE_CMD start gitea

echo ""
echo -e "${GREEN}[SUCCESS] 迁移完成！${NC}"
echo "您的 Gitea 数据现已完全存储在 $NEW_PATH 中。"
echo "原数据已备份为 ${OLD_PATH}_backup_$(date +%Y%m%d)，确认系统运行正常后，您可以手动将其删除以释放 Mac 内部磁盘空间。"
