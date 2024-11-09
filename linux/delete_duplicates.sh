#!/bin/bash

# 定义目录
HTML_DIR="/opt/nginx/html"
NGINX_DIR="/opt/nginx"

# 获取 HTML 目录下的文件和目录列表
ITEMS=$(ls -A $HTML_DIR)

# 遍历文件和目录列表，删除同名文件和目录
for ITEM in $ITEMS; do
    NGINX_ITEM_PATH="$NGINX_DIR/$ITEM"
    if [ -e "$NGINX_ITEM_PATH" ]; then
        echo "Deleting $NGINX_ITEM_PATH"
       rm -rf "$NGINX_ITEM_PATH"
    fi
done
