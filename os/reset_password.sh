#!/bin/bash

# Deepin/Linux系统密码重置脚本 (通用版)
# 自动检测根分区，兼容主流Linux发行版

# 检查是否以root权限运行
if [ "$(id -u)" != "0" ]; then
    echo "错误：请以root权限运行此脚本 (sudo ./reset_password.sh)"
    exit 1
fi

# 检查openssl是否安装（生成密码哈希所需）
if ! command -v openssl &> /dev/null; then
    echo "错误：未找到openssl，请先安装: sudo apt install openssl"
    exit 1
fi

# 自动检测可能的根分区
echo "正在自动检测原系统根分区..."
ROOT_PARTITIONS=()
PARTITION_COUNT=0

# 获取所有磁盘分区信息
lsblk -f | awk '/^sd|nvme|hd/ && $3 == "ext4" {print $1, $7}' | while read -r DEV FS; do
    # 检查该分区是否包含/etc/shadow（确认是系统根分区）
    if [ -f "/dev/$DEV/etc/shadow" ]; then
        ROOT_PARTITIONS+=("$DEV")
        ((PARTITION_COUNT++))
    fi
done

# 如果没有找到任何分区，尝试所有ext4分区
if [ $PARTITION_COUNT -eq 0 ]; then
    echo "警告：未找到包含/etc/shadow的ext4分区，将尝试所有ext4分区"
    lsblk -f | awk '/^sd|nvme|hd/ && $3 == "ext4" {print $1}' | while read -r DEV; do
        ROOT_PARTITIONS+=("$DEV")
        ((PARTITION_COUNT++))
    done
fi

# 检查是否找到分区
if [ $PARTITION_COUNT -eq 0 ]; then
    echo "错误：未找到任何ext4分区。请手动指定根分区。"
    echo "使用命令: lsblk -f 查看所有分区"
    exit 1
fi

# 显示可选分区
echo -e "\n检测到以下可能的根分区："
for i in "${!ROOT_PARTITIONS[@]}"; do
    echo "[$i] /dev/${ROOT_PARTITIONS[$i]}"
done

# 用户选择分区
read -p "请选择根分区编号 (默认: 0): " SELECTED_INDEX
SELECTED_INDEX=${SELECTED_INDEX:-0}

# 验证选择
if [ "$SELECTED_INDEX" -lt 0 ] || [ "$SELECTED_INDEX" -ge "${#ROOT_PARTITIONS[@]}" ]; then
    echo "错误：无效的分区编号"
    exit 1
fi

ROOT_PARTITION="dev/${ROOT_PARTITIONS[$SELECTED_INDEX]}"
echo "已选择分区: /dev/$ROOT_PARTITION"

# 挂载分区
MOUNT_POINT="/mnt/root"
echo "正在挂载 /dev/$ROOT_PARTITION 到 $MOUNT_POINT..."
if ! mkdir -p "$MOUNT_POINT"; then
    echo "错误：无法创建挂载点 $MOUNT_POINT"
    exit 1
fi

if ! mount "/dev/$ROOT_PARTITION" "$MOUNT_POINT"; then
    echo "错误：无法挂载 /dev/$ROOT_PARTITION"
    exit 1
fi

# 检查/etc/shadow是否存在
if [ ! -f "$MOUNT_POINT/etc/shadow" ]; then
    echo "错误：在 $MOUNT_POINT/etc/ 中找不到 shadow 文件"
    umount "$MOUNT_POINT"
    rmdir "$MOUNT_POINT"
    exit 1
fi

# 获取用户名（从/home目录第一个子目录）
if [ ! -d "$MOUNT_POINT/home" ]; then
    echo "错误：未找到 /home 目录"
    umount "$MOUNT_POINT"
    rmdir "$MOUNT_POINT"
    exit 1
fi

USER_NAME=$(ls "$MOUNT_POINT/home" | head -n 1)
if [ -z "$USER_NAME" ]; then
    echo "错误：未找到用户目录 (在 $MOUNT_POINT/home/ 下)"
    umount "$MOUNT_POINT"
    rmdir "$MOUNT_POINT"
    exit 1
fi

echo -e "\n检测到用户: $USER_NAME"
echo "正在重置 $USER_NAME 的密码..."

# 获取新密码
read -s -p "请输入新密码: " NEW_PASSWORD
echo
read -s -p "请再次输入新密码: " CONFIRM_PASSWORD
echo

if [ "$NEW_PASSWORD" != "$CONFIRM_PASSWORD" ]; then
    echo "错误：两次输入的密码不匹配"
    umount "$MOUNT_POINT"
    rmdir "$MOUNT_POINT"
    exit 1
fi

# 生成密码哈希 (使用openssl，兼容所有Linux发行版)
# sudo python3 -c 'import crypt; print(crypt.crypt("123456", "$6$"))'
echo "正在生成密码哈希..."
HASH=$(echo -n "$NEW_PASSWORD" | openssl passwd -6 -stdin 2>/dev/null)

if [ -z "$HASH" ]; then
    echo "错误：无法生成密码哈希"
    umount "$MOUNT_POINT"
    rmdir "$MOUNT_POINT"
    exit 1
fi

echo "密码哈希: $HASH"

# 替换shadow文件中的密码
# 找到您用户名对应的行（例如：username:x:...），将x替换为生成的哈希值
echo "正在修改密码哈希..."
if ! sed -i "s/^$USER_NAME:[^:]*:/$USER_NAME:$HASH:/" "$MOUNT_POINT/etc/shadow"; then
    echo "错误：无法修改 /etc/shadow 文件"
    umount "$MOUNT_POINT"
    rmdir "$MOUNT_POINT"
    exit 1
fi

# 验证修改
if grep -q "^$USER_NAME:$HASH:" "$MOUNT_POINT/etc/shadow"; then
    echo -e "\n密码重置成功！新密码: $NEW_PASSWORD"
    echo "请重启系统并使用新密码登录"
else
    echo "错误：密码修改验证失败"
    umount "$MOUNT_POINT"
    rmdir "$MOUNT_POINT"
    exit 1
fi

# 清理并提示重启
umount "$MOUNT_POINT"
rmdir "$MOUNT_POINT"
echo -e "\n操作完成！请重启系统"
echo "重启命令: sudo reboot"

exit 0
