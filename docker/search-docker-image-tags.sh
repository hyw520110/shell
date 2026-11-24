#!/bin/sh
#
# 显示 Docker仓库/镜像标签。
#
# 使用方法：
#   $ docker-show-repo-tags.sh [仓库名] [...]
#   如果没有提供仓库名，脚本将提示用户输入。

# 显示帮助信息
show_help() {
    cat << EOF
Docker镜像标签搜索脚本

搜索和显示Docker Hub仓库中可用的镜像标签。

用法: ./search-docker-image-tags.sh [选项] [仓库名...]

选项:
    -h, --help            显示此帮助信息

参数:
    仓库名                Docker仓库名称（多个仓库名用空格分隔）

说明:
    - 从Docker Hub API获取镜像标签列表
    - 支持批量查询多个仓库
    - 需要jq工具来解析JSON响应
    - 如果没有jq，使用sed进行简单解析

示例:
    ./search-docker-image-tags.sh nginx            # 搜索nginx标签
    ./search-docker-image-tags.sh nginx redis      # 搜索多个仓库
    ./search-docker-image-tags.sh                  # 交互式输入仓库名

注意事项:
    - 需要网络连接访问Docker Hub API
    - 建议安装jq工具获得更好的显示效果
    - 某些仓库可能有大量标签，显示可能需要时间

EOF
}

# 参数解析
if [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
    show_help
    exit 0
fi

# 函数：检查命令是否存在
command_exists() {
  command -v "$1" >/dev/null 2>&1
}

# 函数：显示仓库标签
show_repo_tags() {
  local repo=$1
  local url="https://registry.hub.docker.com/v2/repositories/$repo/tags/"
  local response

  # 发送请求并捕获响应
  response=$(curl -s -S "$url")
  if [ $? -ne 0 ]; then
    echo "错误：无法获取 $repo 的标签"
    return 1
  fi

  # 使用 jq 解析 JSON
  if command_exists jq; then
    echo "$response" | jq -r '.results[].name' | sort -fu | sed -e "s/^/$repo:/"
  else
    # 使用 sed 和 awk 解析 JSON
    echo "$response" | sed -e 's/,/,\n/g' -e 's/\[/\[\n/g' | \
      grep '"name"' | \
      awk -F\" '{print $4;}' | \
      sort -fu | \
      sed -e "s|^|$repo:|"
  fi
}

# 主函数
main() {
  if [ $# -eq 0 ]; then
    # 提示用户输入镜像仓库名
    read -p "请输入 Docker 镜像仓库名（空格分隔）: " repos
    set -- $repos
  fi

  # 并行处理多个仓库
  for repo in "$@"; do
    show_repo_tags "$repo" &
  done

  # 等待所有后台任务完成
  wait
}

# 运行主函数
main "$@"