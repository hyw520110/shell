#!/bin/bash
# GitLab 统计脚本
# 参数1: GitLab URL
# 参数2: Private Token（需要 user、project 等权限）
#
# 功能：
#   - 获取所有仓库元信息（名称、描述、分支、URL、创建时间、最新变更时间）
#   - 检测空置项目（无分支的仓库）
#   - 生成 HTML 格式报表并打包
#
# 用法：
#   ./GitLabAPI.sh <GitLab_URL> <TOKEN>
#   ./GitLabAPI.sh                           # 使用默认 URL 和交互式输入 Token
#
# 参考：
#   https://www.cnblogs.com/sanzangtdashi/p/11807106.html
#   https://blog.csdn.net/hello_1995/article/details/127489666#t7

set -euo pipefail

# === 颜色定义 ===
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly NC='\033[0m'

print_info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
print_warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
print_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# === 获取脚本所在目录 ===
basePath=$(cd "$(dirname "$0")" && pwd)
cd "$basePath"

# === 获取参数 ===
GitLab_URL=${1:-"http://dev1.shangjinuu.com/"}
TOKEN=${2:-""}

# 如果未提供 Token，交互式输入
if [[ -z "$TOKEN" ]]; then
    read -rp "请输入 GitLab Private Token: " TOKEN
    if [[ -z "$TOKEN" ]]; then
        print_error "Token 不能为空"
        exit 1
    fi
fi

print_info "GitLab URL: $GitLab_URL"
print_info "Token: ${TOKEN:0:8}..."

# === 初始化日志文件 ===
mkdir -p "$basePath/log"
rm -rf "$basePath/log/"*

# === 记录日志函数 ===
function logger() {
    printf "%s %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$basePath/log/StatisticsNum.log"
}

# === 创建目录函数 ===
function mkdirs() {
    if [[ -n "$1" ]]; then
        mkdir -p "$1"
        rm -rf "$1"/*
    fi
}

# === HTML 格式化函数 ===
# 参数：name_with_namespace description branch http_url_to_repo created_at last_activity_at 结果文件路径
function HTMLFormat() {
    local file="$7"
    cat >> "$file" << HTMLEOF
<tr>
  <th align="center">$1</th>
  <th align="center">$2</th>
  <th align="center">$3</th>
  <th align="center">$4</th>
  <th align="center">$5</th>
  <th align="center">$6</th>
</tr>
HTMLEOF
}

# === 检查 jq 是否安装，未安装则自动安装 ===
ensure_jq() {
    if command -v jq &>/dev/null; then
        return 0
    fi

    print_info "jq 未安装，正在安装..."
    if command -v apt-get &>/dev/null; then
        apt-get update -qq && apt-get install -y -qq jq
    elif command -v yum &>/dev/null; then
        yum install -y -q jq
    elif command -v apk &>/dev/null; then
        apk add --quiet jq
    else
        print_error "无法自动安装 jq，请手动安装后重试"
        exit 1
    fi

    if ! command -v jq &>/dev/null; then
        print_error "jq 安装失败"
        exit 1
    fi
    print_info "jq 安装成功: $(jq --version)"
}

# === 检查 zip 是否安装 ===
ensure_zip() {
    if command -v zip &>/dev/null; then
        return 0
    fi

    print_info "zip 未安装，正在安装..."
    if command -v apt-get &>/dev/null; then
        apt-get install -y -qq zip
    elif command -v yum &>/dev/null; then
        yum install -y -q zip
    elif command -v apk &>/dev/null; then
        apk add --quiet zip
    else
        print_warn "无法自动安装 zip，报表将不会打包为 zip"
        return 1
    fi
}

# === 定义获取信息函数 ===
# 参数：TOKEN、GitLab 库 URL
function gitlabRepositry() {
    cd "$basePath"

    # 初始化相关路径
    mkdirs "$basePath/report"
    mkdirs "$basePath/temp"

    # 获取总页数
    print_info "正在获取仓库列表..."
    local http_code
    http_code=$(curl -s -o /dev/null -w "%{http_code}" --head --header "PRIVATE-TOKEN:$2" "$1/api/v4/projects?per_page=50")

    if [[ "$http_code" -ne 200 ]]; then
        print_error "获取仓库数据失败 (HTTP $http_code)，请确认 Token 是否正确且有权限"
        print_error "URL: $1"
        exit 1
    fi

    local total_pages
    total_pages=$(curl --head --header "PRIVATE-TOKEN:$2" "$1/api/v4/projects?per_page=50" | grep -i '^X-Total-Pages' | sed 's/X-Total-Pages: //gi' | tr -d '\r')

    if [[ -z "$total_pages" ]]; then
        print_error "无法获取仓库总数，请确认 Token 和 URL 是否正确"
        exit 1
    fi

    print_info "共计 $total_pages 页数据"

    # 遍历处理每页元数据
    for ((p = 1; p <= total_pages; p++)); do
        print_info "正在获取第 $p/$total_pages 页仓库元信息..."

        local api_result
        api_result=$(curl -s --header "PRIVATE-TOKEN:$2" "$1/api/v4/projects?per_page=50&page=$p")

        if [[ -z "$api_result" ]]; then
            print_warn "第 $p 页数据为空，跳过"
            continue
        fi

        echo "$api_result" | jq > "$basePath/temp/gitlab_projects.json"

        # 提取各字段
        cat "$basePath/temp/gitlab_projects.json" | grep -w -B 1 -A 15 '"description"' > "$basePath/temp/detailedInformation"
        cat "$basePath/temp/detailedInformation" | grep -w '"id"' > "$basePath/temp/PROJECT_ID"
        cat "$basePath/temp/detailedInformation" | grep -w '"description"' > "$basePath/temp/PROJECT_DESCRIPTION"
        cat "$basePath/temp/detailedInformation" | grep -w '"name_with_namespace"' > "$basePath/temp/PROJECT_NAME_WITH_NAMESPACE"
        cat "$basePath/temp/detailedInformation" | grep -w '"created_at"' > "$basePath/temp/PROJECT_CREATED_AT"
        cat "$basePath/temp/detailedInformation" | grep -w '"default_branch"' > "$basePath/temp/PROJECT_DEFAULT_BRANCH"
        cat "$basePath/temp/detailedInformation" | grep -w '"http_url_to_repo"' > "$basePath/temp/PROJECT_HTTP_URL_TO_REPO"
        cat "$basePath/temp/detailedInformation" | grep -w '"last_activity_at"' > "$basePath/temp/PROJECT_LAST_ACTIVITY_AT"

        cd "$basePath/temp"
        paste PROJECT_ID PROJECT_DESCRIPTION PROJECT_NAME_WITH_NAMESPACE PROJECT_CREATED_AT PROJECT_DEFAULT_BRANCH PROJECT_HTTP_URL_TO_REPO PROJECT_LAST_ACTIVITY_AT >> "$basePath/temp/simplify_information"
    done

    # === 遍历获取并格式化数据展示 ===
    # 添加列说明信息
    HTMLFormat "项目群组和名称" "项目描述" "项目分支" "URL路径" "创建时间" "最新变更时间" "$basePath/report/unoccupied_projects_lists.html"
    HTMLFormat "项目群组和名称" "项目描述" "项目分支" "URL路径" "创建时间" "最新变更时间" "$basePath/report/GitLab_result.html"

    while IFS= read -r LINE; do
        # 获取单项数据信息
        PROJECT_ID=$(echo "$LINE" | awk -F',' '{print $1}' | awk '{print $2}')
        PROJECT_DESCRIPTION=$(echo "$LINE" | awk -F'"description"' '{print $2}' | awk '{print $2}' | awk -F'"' '{print $2}' | sed 's/ //g')
        PROJECT_NAME_WITH_NAMESPACE=$(echo "$LINE" | awk -F'"name_with_namespace"' '{print $2}' | awk -F'"' '{print $2}' | sed 's/ //g')
        PROJECT_CREATED_AT=$(echo "$LINE" | awk -F'"created_at"' '{print $2}' | awk -F'"' '{print $2}' | sed 's/ //g')
        PROJECT_DEFAULT_BRANCH=$(echo "$LINE" | awk -F'"default_branch"' '{print $2}' | awk -F',' '{print $1}' | awk -F'"' '{print $2}' | sed 's/ //g')
        PROJECT_HTTP_URL_TO_REPO=$(echo "$LINE" | awk -F'"http_url_to_repo"' '{print $2}' | awk -F'"' '{print $2}' | sed 's/ //g')
        PROJECT_LAST_ACTIVITY_AT=$(echo "$LINE" | awk -F'"last_activity_at"' '{print $2}' | awk -F'"' '{print $2}' | sed 's/ //g')

        if [[ -z "$PROJECT_DESCRIPTION" ]]; then
            PROJECT_DESCRIPTION="无描述信息"
            print_warn "$PROJECT_HTTP_URL_TO_REPO 无描述信息"
        fi

        # 获取代码库分支元数据
        local branch_data
        branch_data=$(curl -s --header "PRIVATE-TOKEN:$2" "$1/api/v4/projects/$PROJECT_ID/repository/branches" | jq -r '.[].name' 2>/dev/null || true)

        if [[ -z "$branch_data" ]]; then
            print_warn "代码库 $PROJECT_HTTP_URL_TO_REPO 已空置！"
            echo "$PROJECT_HTTP_URL_TO_REPO $PROJECT_DESCRIPTION $PROJECT_CREATED_AT $PROJECT_LAST_ACTIVITY_AT" >> "$basePath/report/unoccupied_projects_lists"
            HTMLFormat "$PROJECT_NAME_WITH_NAMESPACE" "$PROJECT_DESCRIPTION" "NaN" "$PROJECT_HTTP_URL_TO_REPO" "$PROJECT_CREATED_AT" "$PROJECT_LAST_ACTIVITY_AT" "$basePath/report/unoccupied_projects_lists.html"
        else
            while IFS= read -r BRANCH; do
                echo "$PROJECT_NAME_WITH_NAMESPACE $PROJECT_DESCRIPTION $BRANCH $PROJECT_HTTP_URL_TO_REPO $PROJECT_CREATED_AT $PROJECT_LAST_ACTIVITY_AT" >> "$basePath/temp/atom_Metadata"
                HTMLFormat "$PROJECT_NAME_WITH_NAMESPACE" "$PROJECT_DESCRIPTION" "$BRANCH" "$PROJECT_HTTP_URL_TO_REPO" "$PROJECT_CREATED_AT" "$PROJECT_LAST_ACTIVITY_AT" "$basePath/report/GitLab_result.html"
            done <<< "$branch_data"
        fi
    done < "$basePath/temp/simplify_information"

    logger "Run by user $(id -un) at $(/bin/date)"

    # 排序
    sort "$basePath/temp/atom_Metadata" > "$basePath/report/GitLab_result"
}

# === 前置检查 ===
ensure_jq

# === 调取函数生成分析数据 ===
gitlabRepositry "$GitLab_URL" "$TOKEN"

# === 有效项目报表格式化 ===
TOTAL_ROWS=$(wc -l < "$basePath/report/GitLab_result" 2>/dev/null || echo 0)
TOTAL_PROJECTS=$(wc -l < "$basePath/temp/simplify_information" 2>/dev/null || echo 0)

# 有效项目报表 HTML 格式化头
sed -i '1i <table border="1">' "$basePath/report/GitLab_result.html"
echo "</table>" >> "$basePath/report/GitLab_result.html"
echo "<p>Statistics GitLab Server: [$GitLab_URL] <br /></p>" >> "$basePath/report/GitLab_result.html"
echo "<p>Statistics time: [$(date +%Y-%m-%d/%H:%M)] <br /></p>" >> "$basePath/report/GitLab_result.html"
echo "<p>Statistics total not unoccupied projects: [$TOTAL_PROJECTS]<br /></p>" >> "$basePath/report/GitLab_result.html"
echo "<p>Statistics total Rows: [$TOTAL_ROWS]<br /></p>" >> "$basePath/report/GitLab_result.html"

# === 空置项目报表格式化 ===
TOTAL_ROWS=$(wc -l < "$basePath/report/unoccupied_projects_lists" 2>/dev/null || echo 0)

# 空置项目报表 HTML 格式化头
sed -i '1i <table border="1">' "$basePath/report/unoccupied_projects_lists.html"
echo "</table>" >> "$basePath/report/unoccupied_projects_lists.html"
echo "<p>Statistics GitLab Server: [$GitLab_URL] <br /></p>" >> "$basePath/report/unoccupied_projects_lists.html"
echo "<p>Statistics time: [$(date +%Y-%m-%d/%H:%M)] <br /></p>" >> "$basePath/report/unoccupied_projects_lists.html"
echo "<p>Statistics total Rows: [$TOTAL_ROWS]<br /></p>" >> "$basePath/report/unoccupied_projects_lists.html"

# === 格式化展示数据 ===
echo "-------------------------------- FORMAT SHOW DATA --------------------------------"
column -t "$basePath/report/GitLab_result" 2>/dev/null || cat "$basePath/report/GitLab_result"
echo "-------------------------------- FORMAT SHOW END ---------------------------------"

echo ""
echo "-------------------------------- SHOW unoccupied branches DATA --------------------------------"
column -t "$basePath/report/unoccupied_projects_lists" 2>/dev/null || cat "$basePath/report/unoccupied_projects_lists"
echo "-------------------------------- SHOW unoccupied branches END ---------------------------------"

# === 压缩报告文件 ===
if ensure_zip; then
    zip -q -j -r "$basePath/report/report-$(date "+%Y%m%d%H%M").zip" "$basePath/report"
    if [[ $? -eq 0 ]]; then
        print_info "报表打包成功: $basePath/report/report-$(date "+%Y%m%d%H%M").zip"
    else
        print_error "报表打包失败，请检查"
        exit 1
    fi
fi

print_info "统计完成！"
