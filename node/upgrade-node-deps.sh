#!/bin/bash

WORKSPACE_PATH="${1:-$HOME/workspace}"
LOG_FILE="$HOME/node-deps-upgrade.log"

exec > >(tee -a "$LOG_FILE") 2>&1
echo "[$(date +'%Y-%m-%d %H:%M:%S')] === 开始升级并统一 Node.js 依赖 ==="

if ! command -v npx >/dev/null; then
    echo "错误: 未找到 npm/npx 命令，请确保已安装 Node.js"
    exit 1
fi

# === 排除目录配置 ===
# 在这里添加你不希望被自动升级的第三方开源项目路径的关键词
EXCLUDE_PATTERNS=(
    "spring-cloud-alibaba"
    "qwen2"
    "openWakeWord"
    # "other-opensource-project"
)

# 查找所有 package.json
ROOT_PKGS=()
while read -r pkg; do
    # 检查是否命中排除规则
    skip=false
    for pattern in "${EXCLUDE_PATTERNS[@]}"; do
        if [[ "$pkg" == *"/$pattern/"* ]]; then
            skip=true
            break
        fi
    done
    [[ "$skip" == true ]] && continue
    
    # 过滤掉子模块 (比如 workspaces)
    is_submodule=false
    pkg_dir="$(dirname "$pkg")"
    for root_pkg in "${ROOT_PKGS[@]}"; do
        root_dir="$(dirname "$root_pkg")"
        if [[ "$pkg_dir" == "$root_dir"/* ]]; then
            is_submodule=true
            break
        fi
    done
    
    if [[ "$is_submodule" == false ]]; then
        ROOT_PKGS+=("$pkg")
    fi
done < <(find "$WORKSPACE_PATH" -type f -name 'package.json' ! -path '*/node_modules/*' ! -path '*/dist/*' ! -path '*/build/*' | awk '{ print length, $0 }' | sort -n -s | cut -d" " -f2-)

PROJECTS=()
declare -A PROJECT_TO_PKGS

for pkg in "${ROOT_PKGS[@]}"; do
    rel_path="${pkg#$WORKSPACE_PATH/}"
    project_name="${rel_path%%/*}"
    
    if [[ ! " ${PROJECTS[@]} " =~ " ${project_name} " ]]; then
        PROJECTS+=("$project_name")
    fi
    
    if [ -z "${PROJECT_TO_PKGS["$project_name"]}" ]; then
        PROJECT_TO_PKGS["$project_name"]="$pkg"
    else
        PROJECT_TO_PKGS["$project_name"]="${PROJECT_TO_PKGS["$project_name"]} $pkg"
    fi
done

if [ ${#PROJECTS[@]} -eq 0 ]; then
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] 没有发现可升级的项目。"
    exit 0
fi

echo ""
echo "发现以下 Node 项目可进行依赖升级:"
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
    proj_pkgs=(${PROJECT_TO_PKGS["$proj"]})
    for pkg in "${proj_pkgs[@]}"; do
        echo "[$(date +'%Y-%m-%d %H:%M:%S')] 正在升级: $pkg (所属项目: $proj)"
        
        dir=$(dirname "$pkg")
        
        (
            cd "$dir" || exit
            npx --yes npm-check-updates@latest -u -t minor --silent
            
            if [ -f "pnpm-lock.yaml" ]; then
                pnpm install --no-frozen-lockfile >/dev/null 2>&1
            elif [ -f "yarn.lock" ]; then
                yarn install >/dev/null 2>&1
            else
                npm install --legacy-peer-deps >/dev/null 2>&1
            fi
        )
        echo "[$(date +'%Y-%m-%d %H:%M:%S')] 完成: $pkg"
    done
done

echo "[$(date +'%Y-%m-%d %H:%M:%S')] === 升级完成 ==="
echo "提示: 请使用 git diff 检查 package.json 的变动。"
