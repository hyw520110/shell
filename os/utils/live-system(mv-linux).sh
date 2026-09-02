#!/bin/bash

# 定义变量
TARGET_ROOT="/mnt/target"
EFI_PART="/dev/nvme0n1p1"
ROOT_PART="/dev/nvme0n1p3"
 


echo "🔍 当前磁盘分区信息："
sudo fdisk -l 
 


echo "挂载 SSD 根分区 $ROOT_PART 到 $TARGET_ROOT"
sudo mkdir -p $TARGET_ROOT
sudo mount $ROOT_PART $TARGET_ROOT 


echo "👉 挂载 EFI 分区 $EFI_PART 到 $TARGET_ROOT/boot/efi"
sudo mkdir -p $TARGET_ROOT/boot/efi
sudo mount $EFI_PART $TARGET_ROOT/boot/efi 


echo "👉 挂载虚拟文件系统（/dev, /proc, /sys, /run）"
sudo mkdir -p $TARGET_ROOT/dev $TARGET_ROOT/proc $TARGET_ROOT/sys $TARGET_ROOT/run
sudo mount --bind /dev $TARGET_ROOT/dev
sudo mount --bind /dev/pts $TARGET_ROOT/dev/pts
sudo mount --bind /proc $TARGET_ROOT/proc
sudo mount --bind /sys $TARGET_ROOT/sys
sudo mount --bind /run $TARGET_ROOT/run

ROOT_UUID=$(sudo blkid -s UUID -o value $ROOT_PART) || { echo "❌ 获取根分区 UUID 失败！"; exit 1; }
EFI_UUID=$(sudo blkid -s UUID -o value $EFI_PART) || { echo "❌ 获取 EFI 分区 UUID 失败！"; exit 1; }


echo "👉 更新 /etc/fstab，替换根分区和 EFI 分区的 UUID"
[ ! -f /etc/fstab.bak ] && sudo cp /etc/fstab /etc/fstab.bak 
sudo sed -i -e "s|UUID=.* / |UUID=$ROOT_UUID / |" -e "s|UUID=.* /boot/efi |UUID=$EFI_UUID /boot/efi|" $TARGET_ROOT/etc/fstab

# 进入 chroot 并安装 GRUB
echo "👉 安装 GRUB 到 EFI 分区（引导名称：deepin）"

sudo chroot $TARGET_ROOT /bin/bash << 'EOF'
grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=deepin --recheck
# update-initramfs -u
ls /boot/efi
update-grub
update-initramfs -u
EOF

# 刷新分区表（确保内核立即更新）
sudo partprobe /dev/nvme0n1 || {
    echo "⚠️ partprobe 失败，尝试强制刷新..."
    sudo blockdev --rereadpt /dev/nvme0n1 || {
        echo "❌ 分区表刷新失败！建议重启后重试。"
        exit 1
    }
}

# 卸载所有挂载点
echo "👉 卸载所有挂载点"
sudo mount  $TARGET_ROOT/dev/pts
sudo umount $TARGET_ROOT/dev 
sudo umount $TARGET_ROOT/proc
sudo umount $TARGET_ROOT/sys 
sudo umount $TARGET_ROOT/run 

# 强制卸载 EFI 和根分区
sudo umount -f $TARGET_ROOT/boot/efi  
sudo umount -f $TARGET_ROOT  

# 清理
# sudo rmdir $TARGET_ROOT 

echo "🎉 迁移和引导修复完成！"
echo "📌 请重启，进入 BIOS，将 NVMe SSD 设为第一启动项。"
