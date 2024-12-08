#!/bin/bash

# 默认值
SOURCE_DIR=$(pwd)
TARGET_HOST=""
TARGET_DIR="${1:-${SOURCE_DIR}}"
PROJECT_NAME=""
# 创建备份目录
BACKUP_DIR="/opt/backup"
[ ! -d "${BACKUP_DIR}" ] && mkdir -p "${BACKUP_DIR}"

# 检查备份目录的可用空间
free_space=$(df -k "${BACKUP_DIR}" | awk 'NR==2{print $4}')
if [ "$free_space" -lt 1024 ]; then
    echo "警告: 备份目录 ${BACKUP_DIR} 的可用空间小于 1GB, 可能无法完成备份。"
    read -p "是否继续? (y/n): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
fi

# 如果当前目录下没有 docker-compose.yml 文件，则提示用户输入
if [ ! -f "${SOURCE_DIR}/docker-compose.yml" ]; then
    [ -f ./docker-compose.yml ] && SOURCE_DIR="."
    [ ! -f "${SOURCE_DIR}/docker-compose.yml" ] && read -p "输入docker-compose.yml文件所在目录: " SOURCE_DIR
fi
echo "当前目录: ${SOURCE_DIR}"
if [ -f "${SOURCE_DIR}/docker-compose.yml" ]; then
    if [ -z "$PROJECT_NAME" ]; then
        PROJECT_NAME=$(basename ${SOURCE_DIR})
    fi
    # 获取镜像名和标签
    IMAGES=$(docker-compose -f "${SOURCE_DIR}/docker-compose.yml" images --quiet | xargs -n1 docker inspect --format '{{.RepoTags}}' | tr -d '[]"' | tr ' ' '\n' | sort -u)

    # 检查是否获取到镜像
    if [ -n "$IMAGES" ]; then
        for img in $IMAGES; do
            backup_file="${BACKUP_DIR}/image_$(echo $img | tr '/' '-' | tr ':' '_').tar"
            echo "备份Docker Compose镜像: $img"
            mkdir -p "$(dirname $backup_file)"
            docker save -o "$backup_file" $img
        done
        # 备份Docker Compose数据卷
        echo "备份Docker Compose数据卷..."
        for volume in $(docker volume ls --filter "label=com.docker.compose.project=${PROJECT_NAME}" -q); do
            echo "备份卷: ${volume}"
            docker run --rm -v ${volume}:/data -v ${BACKUP_DIR}:/backup alpine tar czvf /backup/${volume}.tar.gz -C /data .
        done
        echo "备份Docker Compose网络配置..."
        for network in $(docker network ls --filter "label=com.docker.compose.project=${PROJECT_NAME}" -q); do
            echo "备份网络: ${network}"
            docker network inspect ${network} > ${BACKUP_DIR}/${network}.json
        done
        exit 0
    fi
else
    echo "未找到 docker-compose.yml 文件，请手动选择镜像进行备份."
fi

# 显示可用镜像列表
echo "可用镜像列表:"
IMAGES=($(docker images --format "{{.Repository}}:{{.Tag}}"))
for i in "${!IMAGES[@]}"; do
    echo "$((i+1))) ${IMAGES[$i]}"
done

# 使用 select 语句让用户选择镜像
if [ ${#IMAGES[@]} -eq 1 ]; then
    img=${IMAGES[0]}
    echo "只有一个镜像，自动选择: $img"
else
    PS3='请选择一个镜像 (输入编号): '
    select img in "${IMAGES[@]}"; do
        if [ -n "$img" ]; then
            break
        else
            echo "无效的选择，请重试。"
        fi
    done
fi

# 确保备份文件的目录存在
backup_file="${BACKUP_DIR}/image_$(echo $img | tr '/' '-' | tr ':' '_').tar"
mkdir -p "$(dirname $backup_file)"

echo "选择备份的镜像: $img"
if [ -f $backup_file ]; then
    read -p "备份文件已存在，是否跳过? (Y/n): " resave
    if [[ -z $resave || $resave =~ ^[Yy]$ ]]; then
        exit 0
    fi
fi

echo "正在保存镜像 $img 到 $backup_file"
docker image save -o "$backup_file" $img

# 备份容器数据卷
CONTAINER_IDS=$(docker ps -aq -f ancestor=$img)
if [ -n "$CONTAINER_IDS" ]; then
    echo "正在运行的容器:"
    docker ps -a -f ancestor=$img --format "table {{.ID}}\t{{.Image}}\t{{.Names}}"
    read -p "是否备份这些容器的数据卷? (y/n): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        for ID in $CONTAINER_IDS; do
            VOLUME_DIRS=$(docker inspect --format '{{range .Mounts}}{{.Source}}{{"\n"}}{{end}}' $ID)
            # 检查是否有数据卷
            if [ -z "$VOLUME_DIRS" ]; then
                echo "容器 $ID 没有挂载任何数据卷。"
            else
                for VOLUME_DIR in $VOLUME_DIRS; do
                    if [ -d "$VOLUME_DIR" ]; then
                        tar -czf "${BACKUP_DIR}/container_data_$(basename $VOLUME_DIR)_$(echo $img | tr '/' '-' | tr ':' '_').tar.gz" -C "$VOLUME_DIR" .
                        echo "备份了容器数据到 ${BACKUP_DIR}/container_data_$(basename $VOLUME_DIR)_$(echo $img | tr '/' '-' | tr ':' '_').tar.gz"
                    fi
                done
            fi

            # 导出容器
            container_export="${BACKUP_DIR}/container_$(echo $img | tr '/' '-' | tr ':' '_').tar"
            echo "导出容器 $ID 到 $container_export..."
            if ! docker export -o "$container_export" $ID; then
                echo "导出容器 $ID 失败，请检查磁盘空间或权限。"
                continue
            fi
            echo "容器 $ID 已导出到 $container_export"
        done
    fi
fi

if [ -z "$TARGET_HOST" ]; then
    read -p "请输入目标主机 (user@host) 或直接按回车跳过传输: " TARGET_HOST
    if [ -z "$TARGET_HOST" ]; then
        echo "备份目录：$BACKUP_DIR "
        ls -lh $BACKUP_DIR
        exit 0
    fi
fi

if [ -z "$TARGET_DIR" ]; then
    read -p "请输入目标目录: " TARGET_DIR
    TARGET_DIR=${TARGET_DIR:-${BACKUP_DIR}}
fi

echo "传输文件到目标主机${TARGET_DIR}..."
ssh ${TARGET_HOST} "mkdir -p ${TARGET_DIR}"
scp -r "${BACKUP_DIR}/" ${TARGET_HOST}:${TARGET_DIR}/