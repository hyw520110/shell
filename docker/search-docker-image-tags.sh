#!/bin/sh
#
# 显示 Docker仓库/镜像标签。
#
# 使用方法：
#   $ docker-show-repo-tags.sh [仓库名] [...]
#   如果没有提供仓库名，脚本将提示用户输入。

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