#!/bin/bash

# 显示帮助信息
show_help() {
    cat << EOF
Docker镜像恢复脚本

从备份目录加载Docker镜像到本地。

用法: ./load.sh [选项]

选项:
    -h, --help            显示此帮助信息
    -d, --dir <目录>      指定备份目录 (默认: /opt/backup)

说明:
    - 自动列出备份目录中的所有镜像文件
    - 支持交互式选择镜像进行恢复
    - 恢复后镜像可直接用于容器启动
    - 跳过container_*开头的文件（这些是容器导出文件）

示例:
    ./load.sh                                    # 使用默认备份目录
    ./load.sh -d /backup/docker                  # 指定备份目录

注意事项:
    - 需要Docker环境
    - 确保备份目录存在且包含有效的镜像文件
    - 恢复过程中可能需要较长时间，取决于镜像大小

EOF
}

# 参数解析
BACKUP_DIR="/opt/backup"
while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            show_help
            exit 0
            ;;
        -d|--dir)
            BACKUP_DIR="$2"
            shift 2
            ;;
        *)
            echo "未知参数: $1"
            show_help
            exit 1
            ;;
    esac
done

# 备份目录
read -p "请输入备份目录路径: " BACKUP_DIR
BACKUP_DIR=${BACKUP_DIR:-/opt/backup}

if [ ! -d "$BACKUP_DIR" ]; then
    echo "指定的备份目录不存在: $BACKUP_DIR"
    exit 1
fi

# 显示可用备份镜像列表
echo "可用备份镜像列表:"
ls ${BACKUP_DIR}/*.tar | grep -v '^container_' | xargs -I {} basename {}

# 使用 select 语句让用户选择镜像
PS3='请选择一个镜像 (输入编号): '
select img_tar in $(ls ${BACKUP_DIR}/*.tar | grep -v '^container_' | xargs -I {} basename {}); do
    if [ -n "$img_tar" ]; then
        echo "选择恢复的镜像: $img_tar"

        # 恢复镜像
        if docker image load -i "${BACKUP_DIR}/$img_tar"; then
            echo "镜像 $img_tar 已恢复。"
        else
            echo "恢复镜像 $img_tar 失败，请检查文件或权限。"
            continue
        fi

        # 提取镜像名称
        IMG_NAME=$(echo $img_tar | sed 's/^image_//; s/.tar$//' | tr '_' ':')

        # 检查是否有对应的容器导出文件
        CONTAINER_EXPORTS=$(ls ${BACKUP_DIR}/container_*_${img_tar%.tar}.tar 2>/dev/null)
        if [ -z "$CONTAINER_EXPORTS" ]; then
            echo "没有找到与镜像 $IMG_NAME 对应的容器导出文件。"
        else
            for EXPORT in $CONTAINER_EXPORTS; do
                # 解析文件名
                CONTAINER_NAME=$(basename "$EXPORT" .tar | cut -d '_' -f 2- | sed 's/.*_//')
                IMAGE_NAME=$(basename "$EXPORT" .tar | cut -d '_' -f 3- | sed 's/.*_//')

                # 导入容器
                if docker import "$EXPORT" "${IMAGE_NAME}:latest"; then
                    echo "容器 $CONTAINER_NAME ($IMAGE_NAME) 已恢复。"
                else
                    echo "恢复容器 $CONTAINER_NAME ($IMAGE_NAME) 失败，请检查文件或权限。"
                fi
            done
        fi
        break
    else
        echo "无效的选择，请重新选择。"
    fi
done

echo "恢复完成。"