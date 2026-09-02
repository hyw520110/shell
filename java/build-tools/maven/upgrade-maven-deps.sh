#!/bin/bash

# === Maven 依赖升级复用脚本 ===
# 作用：自动扫描并升级所有 pom.xml 中的依赖到最新的【次版本号】(Minor versions)，而不升级主版本号(避免破坏性更新)

WORKSPACE_PATH="${1:-$HOME/workspace}"
LOG_FILE="$HOME/maven-deps-upgrade.log"

exec > >(tee -a "$LOG_FILE") 2>&1

echo "[$(date +'%Y-%m-%d %H:%M:%S')] === 开始升级并统一 Maven 依赖 ==="

# 查找所有顶层 pom.xml（简单过滤）
# === 排除目录配置 ===
# 在这里添加你不希望被自动升级的第三方开源项目路径的关键词
EXCLUDE_PATTERNS=(
    "spring-cloud-alibaba"
    "qwen2"
    "openWakeWord"
    # "other-opensource-project"
)

ROOT_POMS=()
while read -r pom; do
    # 检查是否命中排除规则
    skip=false
    for pattern in "${EXCLUDE_PATTERNS[@]}"; do
        if [[ "$pom" == *"/$pattern/"* ]]; then
            skip=true
            break
        fi
    done
    [[ "$skip" == true ]] && continue
    
    # 过滤掉子模块 (因为查找结果按路径长度排序，父 pom 会先被处理)
    is_submodule=false
    pom_dir="$(dirname "$pom")"
    for root_pom in "${ROOT_POMS[@]}"; do
        root_dir="$(dirname "$root_pom")"
        if [[ "$pom_dir" == "$root_dir"/* ]]; then
            is_submodule=true
            break
        fi
    done
    
    if [[ "$is_submodule" == false ]]; then
        ROOT_POMS+=("$pom")
    fi
done < <(find "$WORKSPACE_PATH" -type f -name 'pom.xml' ! -path '*/target/*' ! -path '*/templates/*' ! -name '*{*]*' | awk '{ print length, $0 }' | sort -n -s | cut -d" " -f2-)

PROJECTS=()
declare -A PROJECT_TO_POMS

for pom in "${ROOT_POMS[@]}"; do
    rel_path="${pom#$WORKSPACE_PATH/}"
    project_name="${rel_path%%/*}"
    
    if [[ ! " ${PROJECTS[@]} " =~ " ${project_name} " ]]; then
        PROJECTS+=("$project_name")
    fi
    
    if [ -z "${PROJECT_TO_POMS["$project_name"]}" ]; then
        PROJECT_TO_POMS["$project_name"]="$pom"
    else
        PROJECT_TO_POMS["$project_name"]="${PROJECT_TO_POMS["$project_name"]} $pom"
    fi
done

if [ ${#PROJECTS[@]} -eq 0 ]; then
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] 没有发现可升级的项目。"
    exit 0
fi

echo ""
echo "发现以下 Maven 项目可进行依赖升级:"
for i in "${!PROJECTS[@]}"; do
    echo "  $((i+1))) ${PROJECTS[$i]}"
done
echo "  a) 全部升级 (默认)"
echo "  q) 取消并退出"
echo ""

if [ -t 0 ]; then
    read -p "请选择要升级的项目 [默认 a，多个用空格分隔，如: 1 2]: " choice
else
    choice="a"
fi
choice="${choice:-a}"

if [[ "$choice" == "q" || "$choice" == "Q" ]]; then
    echo "已取消升级。"
    exit 0
fi

SELECTED_PROJECTS=()
if [[ "$choice" == "a" || "$choice" == "A" ]]; then
    SELECTED_PROJECTS=("${PROJECTS[@]}")
else
    for idx in $choice; do
        if [[ "$idx" =~ ^[0-9]+$ ]] && [ "$idx" -ge 1 ] && [ "$idx" -le "${#PROJECTS[@]}" ]; then
            SELECTED_PROJECTS+=("${PROJECTS[$((idx-1))]}")
        else
            echo "无效选择: $idx，跳过。"
        fi
    done
fi

for proj in "${SELECTED_PROJECTS[@]}"; do
    proj_poms=(${PROJECT_TO_POMS["$proj"]})
    for pom in "${proj_poms[@]}"; do
        echo "[$(date +'%Y-%m-%d %H:%M:%S')] 正在升级: $pom (所属项目: $proj)"
        
        mvn -f "$pom" versions:use-latest-releases \
            -DallowMajorUpdates=false \
            -DgenerateBackupPoms=false \
            -DprocessDependencies=true \
            -DprocessDependencyManagement=true \
            -B -q
            
        echo "[$(date +'%Y-%m-%d %H:%M:%S')] 完成: $pom"
    done
done

echo "[$(date +'%Y-%m-%d %H:%M:%S')] === 升级完成 ==="
echo "提示: 请使用 git diff 检查所有被修改的 pom.xml 文件。如果没有问题，可进行提交。"
echo "然后再运行 clean-maven.sh，即可彻底删除被淘汰的旧版本小依赖，实现复用和瘦身。"
