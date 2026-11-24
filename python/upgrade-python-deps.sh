#!/bin/bash

WORKSPACE_PATH="${1:-$HOME/workspace}"
LOG_FILE="$HOME/python-deps-upgrade.log"

exec > >(tee -a "$LOG_FILE") 2>&1
echo "[$(date +'%Y-%m-%d %H:%M:%S')] === 开始升级并统一 Python 依赖 ==="

# === 排除目录配置 ===
# 在这里添加你不希望被自动升级的第三方开源项目路径的关键词
EXCLUDE_PATTERNS=(
    "spring-cloud-alibaba"
    "qwen2"
    "openWakeWord"
    # "other-opensource-project"
)

# 查找所有依赖声明文件
ROOT_REQS=()
while read -r req_file; do
    # 检查是否命中排除规则
    skip=false
    for pattern in "${EXCLUDE_PATTERNS[@]}"; do
        if [[ "$req_file" == *"/$pattern/"* ]]; then
            skip=true
            break
        fi
    done
    [[ "$skip" == true ]] && continue
    
    # 过滤掉子模块
    is_submodule=false
    req_dir="$(dirname "$req_file")"
    for root_req in "${ROOT_REQS[@]}"; do
        root_dir="$(dirname "$root_req")"
        if [[ "$req_dir" == "$root_dir"/* ]]; then
            is_submodule=true
            break
        fi
    done
    
    if [[ "$is_submodule" == false ]]; then
        ROOT_REQS+=("$req_file")
    fi
done < <(find "$WORKSPACE_PATH" -type f \( -name "requirements.txt" -o -name "pyproject.toml" -o -name "Pipfile" \) ! -path '*/.venv/*' ! -path '*/venv/*' ! -path '*/env/*' | awk '{ print length, $0 }' | sort -n -s | cut -d" " -f2-)

PROJECTS=()
declare -A PROJECT_TO_REQS

for req_file in "${ROOT_REQS[@]}"; do
    rel_path="${req_file#$WORKSPACE_PATH/}"
    project_name="${rel_path%%/*}"
    
    if [[ ! " ${PROJECTS[@]} " =~ " ${project_name} " ]]; then
        PROJECTS+=("$project_name")
    fi
    
    if [ -z "${PROJECT_TO_REQS["$project_name"]}" ]; then
        PROJECT_TO_REQS["$project_name"]="$req_file"
    else
        PROJECT_TO_REQS["$project_name"]="${PROJECT_TO_REQS["$project_name"]} $req_file"
    fi
done

if [ ${#PROJECTS[@]} -eq 0 ]; then
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] 没有发现可升级的项目。"
    exit 0
fi

echo ""
echo "发现以下 Python 项目可进行依赖升级:"
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
    proj_reqs=(${PROJECT_TO_REQS["$proj"]})
    for req_file in "${proj_reqs[@]}"; do
        dir=$(dirname "$req_file")
        filename=$(basename "$req_file")
        
        echo "[$(date +'%Y-%m-%d %H:%M:%S')] 正在处理: $req_file (所属项目: $proj)"
        
        (
            cd "$dir" || exit
            
            if [ -f ".venv/bin/activate" ]; then
                source .venv/bin/activate
            elif [ -f "venv/bin/activate" ]; then
                source venv/bin/activate
            fi

            if command -v uv >/dev/null; then
                if [ "$filename" == "requirements.txt" ]; then
                    uv pip install -U -r requirements.txt >/dev/null 2>&1
                elif [ "$filename" == "pyproject.toml" ] && grep -q "\[tool.uv\]" "pyproject.toml"; then
                    uv lock --upgrade >/dev/null 2>&1
                    uv sync >/dev/null 2>&1
                fi
            elif command -v poetry >/dev/null && [ "$filename" == "pyproject.toml" ] && grep -q "\[tool.poetry\]" "pyproject.toml"; then
                poetry update >/dev/null 2>&1
            elif command -v pip >/dev/null && [ "$filename" == "requirements.txt" ]; then
                pip install -U -r requirements.txt >/dev/null 2>&1
            fi
        )
        echo "[$(date +'%Y-%m-%d %H:%M:%S')] 完成: $req_file"
    done
done

echo "[$(date +'%Y-%m-%d %H:%M:%S')] === 升级完成 ==="
echo "提示: 对于 requirements.txt，这会安装最新版本包，你可以使用 pip freeze 重写它；对于带有 lock 文件的项目(uv/poetry)，锁文件已被自动更新。"
