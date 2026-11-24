#!/bin/bash

# Git 差异对比工具（整合版）
# 支持四种模式：
#   1. Git 分支/提交差异对比（文本或图形化）
#   2. 两个目录的差异对比（文本或图形化）
#   3. 两个文件的差异对比（文本或图形化）
#   4. 分支交互对比与合并（-b 模式，原 git-bc.sh）

set -euo pipefail

# --- 1. 配置区域 ---

SCRIPT_SOURCE="${BASH_SOURCE[0]}"
SCRIPT_SOURCE="${SCRIPT_SOURCE/#\~/$HOME}"
if [[ "$SCRIPT_SOURCE" == /* ]]; then
    SCRIPT_DIR=$(dirname "$SCRIPT_SOURCE")
else
    SCRIPT_DIR=$(dirname "$(command -v "$BASH_SOURCE" 2>/dev/null || echo "$BASH_SOURCE")")
    [[ "$SCRIPT_DIR" != /* ]] && SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi
DEFAULT_CONTEXT_LINES=3

# 输出限制常量
readonly MAX_DIFF_LINES=1000
readonly MAX_VERBOSE_FILES=10
readonly MAX_LISTED_FILES=100

# --- 2. 颜色定义（TTY 检测）---

if [[ -t 2 ]]; then
    readonly RED='\033[0;31m'
    readonly GREEN='\033[0;32m'
    readonly YELLOW='\033[1;33m'
    readonly BLUE='\033[0;34m'
    readonly CYAN='\033[0;36m'
    readonly NC='\033[0m'
else
    readonly RED=''
    readonly GREEN=''
    readonly YELLOW=''
    readonly BLUE=''
    readonly CYAN=''
    readonly NC=''
fi

# --- 3. 全局变量 ---

MODE=""              # "git"、"dir"、"file" 或 "branch"
OUTPUT_MODE=""       # "text" 或 "gui"
LEFT=""              # 左侧分支/目录/文件
RIGHT=""             # 右侧分支/目录/文件
CONTEXT_LINES=$DEFAULT_CONTEXT_LINES
FILE_FILTER=""
VERBOSE=0
EXCLUDE_PATTERNS=()
DIFF_CACHE=""        # 缓存 diff 结果

# Branch 模式变量
BRANCH_CURRENT=""
BRANCH_COMPARE=""
BRANCH_LOCAL=""
BRANCH_GIT_DIR=""
BRANCH_ANALYZE_WORKLOAD=false
BRANCH_CUSTOM_EXCLUDES=()

# 默认排除模式（Java、Python、前端、Node.js、通用）
DEFAULT_EXCLUDE_PATTERNS=(
    ".*"
    "target/" "build/" "dist/" "out/" "bin/" "obj/"
    "node_modules/" "venv/" ".venv/" "__pycache__/" ".m2/" ".gradle/" ".cargo/"
    ".idea/" ".vscode/" ".vs/" "*.iml" "*.swp" "*.swo" "*~"
    "yarn.lock" "package-lock.json" "pnpm-lock.yaml" "poetry.lock" "Pipfile.lock"
    "*.log" "logs/"
    "*.tmp" "*.bak" "*.orig" ".DS_Store" "Thumbs.db"
    ".git/" "*.patch"
    "*.class" "*.jar" "*.war" "*.ear"
    "*.pyc" "*.pyo" ".pytest_cache/" ".eggs/" "*.egg-info/"
    ".npm/" ".yarn/" "coverage/" ".nyc_output/"
)

# Branch 模式默认排除模式（正则风格）
BRANCH_EXCLUDE_PATTERNS=(
    '^dist/'
    '^build/'
    '^target/'
    '^out/'
    '^node_modules/'
    '^\.m2/'
    '^\.gradle/'
    'yarn\.lock$'
    'package-lock\.json$'
    '\.lock$'
    '^\.vscode/'
    '^\.idea/'
    '^\.hbuilderx/'
    '\.swp$'
    '\.swo$'
    '^\.git/'
    '\.patch$'
    '\.log$'
)

# --- 4. 辅助函数 ---

log_info() { echo -e "${GREEN}[INFO] $*${NC}" >&2; }
log_warn() { echo -e "${YELLOW}[WARN] $*${NC}" >&2; }
log_error() { echo -e "${RED}[ERROR] $*${NC}" >&2; }
log_debug() { [ "$VERBOSE" -eq 1 ] && echo -e "${BLUE}[DEBUG] $*${NC}" >&2; return 0; }

safe_escape() {
    printf "%q" "$1"
}

# --- 5. 验证函数 ---

validate_git_repo() {
    if ! git rev-parse --git-dir > /dev/null 2>&1; then
        log_error "当前目录不是 Git 仓库"
        exit 1
    fi
}

validate_git_dir() {
    local dir="$1"

    if [ -z "$dir" ]; then
        log_error "目录路径不能为空"
        return 1
    fi

    local normalized_dir
    if command -v realpath >/dev/null 2>&1; then
        normalized_dir=$(realpath "$dir" 2>/dev/null)
    else
        normalized_dir=$(cd "$dir" 2>/dev/null && pwd -P)
    fi

    if [ -z "$normalized_dir" ]; then
        log_error "无法解析目录路径: $dir"
        return 1
    fi

    if [ ! -d "$normalized_dir" ]; then
        log_error "$normalized_dir 不是一个有效的目录"
        return 1
    fi

    if ! git -C "$normalized_dir" rev-parse --git-dir > /dev/null 2>&1; then
        log_error "$normalized_dir 不是一个 Git 仓库"
        return 1
    fi

    printf '%s\n' "$normalized_dir"
}

validate_branch_name() {
    local branch="$1"

    if [ -z "$branch" ]; then
        log_error "分支名称不能为空"
        return 1
    fi

    if [ ${#branch} -gt 256 ]; then
        log_error "分支名称过长（超过 256 字符）"
        return 1
    fi

    if [[ "$branch" =~ [^a-zA-Z0-9._/-] ]]; then
        log_error "分支名称包含非法字符: $branch"
        return 1
    fi

    if [[ "$branch" =~ ^[./-]|[-/]$ ]]; then
        log_error "分支名称不能以斜杠、点或连字符开头或结尾"
        return 1
    fi

    if [[ "$branch" =~ \.\.|//|-- ]]; then
        log_error "分支名称不能包含连续的点或斜杠"
        return 1
    fi

    if [[ "$branch" == "HEAD" || "$branch" == "MERGE_HEAD" || "$branch" == "FETCH_HEAD" ]]; then
        log_error "'$branch' 是 Git 保留名称"
        return 1
    fi

    return 0
}

validate_dirs() {
    if [ -z "$LEFT" ] || [ -z "$RIGHT" ]; then
        log_error "目录模式需要指定 -l 和 -r"
        exit 1
    fi

    if [ ! -d "$LEFT" ]; then
        log_error "目录不存在：$LEFT"
        exit 1
    fi

    if [ ! -d "$RIGHT" ]; then
        log_error "目录不存在：$RIGHT"
        exit 1
    fi

    LEFT="${LEFT/#\~/$HOME}"
    RIGHT="${RIGHT/#\~/$HOME}"

    if [ "${#EXCLUDE_PATTERNS[@]}" -eq 0 ]; then
        if [ -f "$LEFT/.gitignore" ]; then
            extract_gitignore_patterns "$LEFT"
            log_debug "使用 $LEFT/.gitignore 作为排除模式"
        else
            EXCLUDE_PATTERNS=("${DEFAULT_EXCLUDE_PATTERNS[@]}")
            log_debug "使用默认排除模式"
        fi
    fi
}

validate_files() {
    if [ -z "$LEFT" ] || [ -z "$RIGHT" ]; then
        log_error "文件模式需要指定 -l 和 -r"
        exit 1
    fi

    LEFT="${LEFT/#\~/$HOME}"
    RIGHT="${RIGHT/#\~/$HOME}"

    if [ ! -f "$LEFT" ]; then
        log_error "文件不存在：$LEFT"
        exit 1
    fi

    if [ ! -f "$RIGHT" ]; then
        log_error "文件不存在：$RIGHT"
        exit 1
    fi
}

validate_git_refs() {
    if [ -z "$LEFT" ]; then
        LEFT="HEAD"
    fi

    if [ -z "$RIGHT" ]; then
        if git show-ref --verify --quiet "refs/remotes/origin/HEAD"; then
            RIGHT="origin/HEAD"
        else
            RIGHT="HEAD"
            log_warn "未指定右侧分支且无默认远程分支，使用 HEAD"
        fi
    fi

    if ! git rev-parse --verify --quiet "$LEFT" > /dev/null 2>&1; then
        log_error "无效的 Git 引用：$LEFT"
        exit 1
    fi

    if ! git rev-parse --verify --quiet "$RIGHT" > /dev/null 2>&1; then
        log_error "无效的 Git 引用：$RIGHT"
        exit 1
    fi
}

# --- 6. 排除/过滤函数 ---

extract_gitignore_patterns() {
    local dir="$1"
    local gitignore_file="$dir/.gitignore"

    if [ -f "$gitignore_file" ]; then
        log_debug "从 .gitignore 提取排除模式：$gitignore_file"
        while IFS= read -r line || [ -n "$line" ]; do
            [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
            line=$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            [ -n "$line" ] && EXCLUDE_PATTERNS+=("$line")
        done < "$gitignore_file"
    fi
}

should_exclude() {
    local file="$1"

    [ "${#EXCLUDE_PATTERNS[@]}" -eq 0 ] && return 1

    for pattern in "${EXCLUDE_PATTERNS[@]}"; do
        if [[ "$pattern" == ".*" ]]; then
            local basename="${file##*/}"
            if [[ "$basename" == .* ]]; then
                return 0
            fi
        elif [[ "$pattern" == */ ]]; then
            local dir_pattern="${pattern%/}"
            if [[ "$file" == *"$dir_pattern"* ]]; then
                return 0
            fi
        elif [[ "$pattern" == *"*"* || "$pattern" == *"?"* ]]; then
            shopt -s extglob nullglob
            # shellcheck disable=SC2053
            if [[ "$file" == $pattern ]]; then
                shopt -u extglob nullglob
                return 0
            fi
            shopt -u extglob nullglob
        else
            if [[ "$file" == *"$pattern"* ]]; then
                return 0
            fi
        fi
    done
    return 1
}

# --- 7. Git diff 函数 ---

check_dependencies() {
    if [ "$OUTPUT_MODE" = "gui" ]; then
        if ! command -v bcompare &> /dev/null; then
            log_error "Beyond Compare (bcompare) 未安装"
            log_info "请安装 Beyond Compare 或将命令行工具加入 PATH"
            exit 127
        fi
    fi

    if ! command -v git &> /dev/null; then
        log_error "Git 未安装"
        exit 127
    fi
}

git_diff_text() {
    log_info "Git 差异对比（文本模式）"
    log_info "左侧：$LEFT  |  右侧：$RIGHT"
    echo ""

    echo -e "${CYAN}=== 差异统计 ===${NC}"
    if ! git diff --stat "$LEFT" "$RIGHT" -- ${FILE_FILTER:+"$FILE_FILTER"}; then
        log_warn "获取差异统计失败"
    fi

    echo ""
    echo -e "${CYAN}=== 详细差异 ===${NC}"
    local diff_output
    if ! diff_output=$(git diff --color=always "$LEFT" "$RIGHT" -- ${FILE_FILTER:+"$FILE_FILTER"} 2>&1); then
        log_warn "获取详细差异失败"
    fi

    local line_count
    line_count=$(echo "$diff_output" | wc -l)
    if [ "$line_count" -gt "$MAX_DIFF_LINES" ]; then
        echo "$diff_output" | head -"$MAX_DIFF_LINES"
        log_warn "输出已截断：共 $line_count 行，仅显示前 $MAX_DIFF_LINES 行"
    else
        echo "$diff_output"
    fi

    echo ""
    echo -e "${CYAN}=== 变更文件列表 ===${NC}"
    if ! git diff --name-only "$LEFT" "$RIGHT" -- ${FILE_FILTER:+"$FILE_FILTER"}; then
        log_warn "获取文件列表失败"
    fi
}

git_diff_gui() {
    log_info "Git 差异对比（图形化模式）"
    log_info "左侧：$LEFT  |  右侧：$RIGHT"
    [ -n "$FILE_FILTER" ] && log_info "文件过滤：$FILE_FILTER"

    bcompare "git($LEFT)" "git($RIGHT)" "${FILE_FILTER:-}"
    log_info "Beyond Compare 已启动"
}

# --- 8. 目录 diff 函数 ---

cache_diff_results() {
    log_debug "缓存 diff 结果..."
    DIFF_CACHE=$(diff -rq "$LEFT" "$RIGHT" 2>&1) || true
}

get_diff_cache() {
    if [ -z "$DIFF_CACHE" ]; then
        cache_diff_results
    fi
    echo "$DIFF_CACHE"
}

dir_diff_text() {
    log_info "目录差异对比（文本模式）"
    log_info "左侧：$LEFT"
    log_info "右侧：$RIGHT"
    [ "${#EXCLUDE_PATTERNS[@]}" -gt 0 ] && log_info "排除模式：${EXCLUDE_PATTERNS[*]}"
    [ "$VERBOSE" -eq 1 ] && log_info "详细模式：将显示文件具体差异内容"
    echo ""

    local diff_opts="-ruN"
    [ "$CONTEXT_LINES" -gt 0 ] && diff_opts="$diff_opts -$CONTEXT_LINES"

    echo -e "${CYAN}=== 目录差异 ===${NC}"

    cache_diff_results

    if [ -n "$DIFF_CACHE" ]; then
        local filtered_count=0
        local excluded_count=0
        local detailed_files=()
        local only_left_files=()
        local only_right_files=()
        local differ_files=()

        while IFS= read -r line; do
            [ -z "$line" ] && continue

            local file_path=""
            local file_type=""

            if [[ "$line" == "Binary files"* ]]; then
                continue
            elif [[ "$line" == "Only in "* ]]; then
                local dir_part="${line#Only in }"
                dir_part="${dir_part%%: *}"
                local file_name="${line##*: }"

                local base_dir=""
                if [[ "$dir_part" == "$LEFT"* ]]; then
                    base_dir="$LEFT"
                    file_type="left_only"
                elif [[ "$dir_part" == "$RIGHT"* ]]; then
                    base_dir="$RIGHT"
                    file_type="right_only"
                fi

                local rel_dir="${dir_part#$base_dir/}"
                if [ "$rel_dir" = "$dir_part" ]; then
                    rel_dir=""
                fi
                file_path="${rel_dir}${rel_dir:+/}${file_name}"
            elif [[ "$line" == *"differ"* ]]; then
                file_path="${line#* }"
                file_path="${file_path%% *}"
                file_path="${file_path#$LEFT/}"
                file_path="${file_path#$RIGHT/}"
                file_type="differ"
            fi

            [ -z "$file_path" ] && continue

            if should_exclude "$file_path"; then
                ((excluded_count++))
                continue
            fi

            case "$file_type" in
                "left_only")  only_left_files+=("$file_path") ;;
                "right_only") only_right_files+=("$file_path") ;;
                "differ")     detailed_files+=("$file_path"); differ_files+=("$file_path") ;;
            esac

            ((filtered_count++))

            if [ $filtered_count -ge "$MAX_LISTED_FILES" ]; then
                echo "  ... (更多差异，已排除 $excluded_count 个文件)"
                break
            fi
        done < <(echo "$DIFF_CACHE")

        if [ "${#only_left_files[@]}" -gt 0 ]; then
            for file_path in "${only_left_files[@]}"; do
                echo "  [左侧独有] $file_path"
            done
        fi
        if [ "${#only_right_files[@]}" -gt 0 ]; then
            for file_path in "${only_right_files[@]}"; do
                echo "  [右侧独有] $file_path"
            done
        fi
        if [ "${#differ_files[@]}" -gt 0 ]; then
            for file_path in "${differ_files[@]}"; do
                echo "  [内容不同] $file_path"
            done
        fi

        echo ""
        echo "已显示：$filtered_count 个文件，排除：$excluded_count 个文件"

        if [ "$VERBOSE" -eq 1 ] && [ "${#detailed_files[@]}" -gt 0 ]; then
            echo ""
            echo -e "${CYAN}=== 详细差异内容 ===${NC}"

            local show_count=0
            for file_path in "${detailed_files[@]}"; do
                if [ $show_count -ge "$MAX_VERBOSE_FILES" ]; then
                    echo ""
                    echo "  ... (仅显示前 $MAX_VERBOSE_FILES 个文件的详细差异)"
                    break
                fi

                echo ""
                echo -e "${YELLOW}▼ $file_path${NC}"
                echo "----------------------------------------"

                local file1="$LEFT/$file_path"
                local file2="$RIGHT/$file_path"

                if [ -f "$file1" ] && [ -f "$file2" ]; then
                    if ! diff -u "$file1" "$file2" 2>&1 | head -30; then
                        log_debug "显示 $file_path 差异时出错"
                    fi
                fi

                ((show_count++))
            done
        fi

        echo ""
        echo -e "${CYAN}=== 文件列表对比 ===${NC}"

        if [ "${#only_left_files[@]}" -gt 0 ]; then
            echo -e "\n${GREEN}左侧独有文件:${NC}"
            for file_path in "${only_left_files[@]}"; do
                echo "  - $file_path"
            done
        else
            echo -e "\n${GREEN}左侧独有文件:${NC} 无"
        fi

        if [ "${#only_right_files[@]}" -gt 0 ]; then
            echo -e "\n${RED}右侧独有文件:${NC}"
            for file_path in "${only_right_files[@]}"; do
                echo "  + $file_path"
            done
        else
            echo -e "\n${RED}右侧独有文件:${NC} 无"
        fi

        if [ "${#differ_files[@]}" -gt 0 ]; then
            echo -e "\n${YELLOW}内容不同的文件:${NC}"
            for file_path in "${differ_files[@]}"; do
                echo "  ~ $file_path"
            done
        else
            echo -e "\n${YELLOW}内容不同的文件:${NC} 无"
        fi
    else
        echo "  无差异"
    fi
}

dir_diff_gui() {
    log_info "目录差异对比（图形化模式）"
    log_info "左侧：$LEFT"
    log_info "右侧：$RIGHT"
    [ "${#EXCLUDE_PATTERNS[@]}" -gt 0 ] && log_info "排除模式：${EXCLUDE_PATTERNS[*]}"

    local filter_args=""
    if [ "${#EXCLUDE_PATTERNS[@]}" -gt 0 ]; then
        local exclude_filter=""
        for pattern in "${EXCLUDE_PATTERNS[@]}"; do
            pattern="${pattern%/}"
            if [ -n "$exclude_filter" ]; then
                exclude_filter="$exclude_filter|$pattern"
            else
                exclude_filter="$pattern"
            fi
        done
        filter_args="-filter=-$exclude_filter"
    fi

    if [ -n "$filter_args" ]; then
        bcompare "$filter_args" "$LEFT" "$RIGHT"
    else
        bcompare "$LEFT" "$RIGHT"
    fi

    log_info "Beyond Compare 已启动"
}

# --- 9. 文件 diff 函数 ---

file_diff_text() {
    log_info "文件差异对比（文本模式）"
    log_info "左侧：$LEFT"
    log_info "右侧：$RIGHT"
    echo ""

    echo -e "${CYAN}=== 文件统计 ===${NC}"
    local left_size right_size
    left_size=$(stat -f%z "$LEFT" 2>/dev/null || stat -c%s "$LEFT" 2>/dev/null || echo "未知")
    right_size=$(stat -f%z "$RIGHT" 2>/dev/null || stat -c%s "$RIGHT" 2>/dev/null || echo "未知")
    echo "  左侧大小：$left_size 字节"
    echo "  右侧大小：$right_size 字节"
    echo ""

    echo -e "${CYAN}=== 详细差异 ===${NC}"
    local diff_output
    local diff_exit_code=0

    if command -v git &> /dev/null; then
        diff_output=$(git diff --no-index --color=always "$LEFT" "$RIGHT" 2>&1) || diff_exit_code=$?
    else
        diff_output=$(diff -u "$LEFT" "$RIGHT" 2>&1) || diff_exit_code=$?
    fi

    if [ $diff_exit_code -eq 0 ]; then
        echo "  文件内容相同"
    else
        local line_count
        line_count=$(echo "$diff_output" | wc -l)
        if [ "$line_count" -gt "$MAX_DIFF_LINES" ]; then
            echo "$diff_output" | head -"$MAX_DIFF_LINES"
            log_warn "输出已截断：共 $line_count 行，仅显示前 $MAX_DIFF_LINES 行"
        else
            echo "$diff_output"
        fi
    fi
}

file_diff_gui() {
    log_info "文件差异对比（图形化模式）"
    log_info "左侧：$LEFT"
    log_info "右侧：$RIGHT"

    bcompare "$LEFT" "$RIGHT"
    log_info "Beyond Compare 已启动"
}

# --- 10. Branch 模式函数 ---

format_timestamp() {
    local ts="$1"
    if [ "$ts" = "0" ]; then
        echo "未知"
        return
    fi

    local formatted_date
    formatted_date=$(date -d "@$ts" "+%Y-%m-%d %H:%M:%S" 2>/dev/null) || true

    if [ -n "$formatted_date" ]; then
        echo "$formatted_date"
    else
        date -j -f "%s" "$ts" "+%Y-%m-%d %H:%M:%S" 2>/dev/null || echo "未知"
    fi
}

handle_merge_conflict() {
    local target_branch="$1"
    local source_branch="$2"

    echo "❌ 合并失败，存在冲突。"
    echo "请按照以下步骤解决冲突："
    echo "1. 使用 'git status' 查看有冲突的文件。"

    local merge_tool
    merge_tool=$(git config --get merge.tool 2>/dev/null || true)
    if [ -n "$merge_tool" ]; then
        echo "2. 您已配置合并工具 '$merge_tool'。"
    else
        echo "2. 手动编辑这些文件以解决冲突。"
        echo "   您可以运行 'git config --global merge.tool <tool>' 配置一个可视化合并工具。"
    fi

    echo "3. 解决所有冲突后，使用 'git add .' 将更改标记为已解决。"
    if [ "$source_branch" != "unknown" ]; then
        echo "4. 运行以下命令完成合并提交:"
        echo "   git commit -m '合并分支 ${source_branch} 到 ${target_branch}'"
    else
        echo "4. 运行 'git commit' 来完成合并。"
    fi
    echo "如果想放弃本次合并，可以运行 'git merge --abort'。"
    echo ""
    if [ -n "$merge_tool" ]; then
        local run_mergetool
        read -r -p "是否现在运行 'git mergetool' 来解决冲突? [Y/n]: " run_mergetool
        run_mergetool=${run_mergetool:-Y}
        if [[ "$run_mergetool" =~ ^[Yy]$ ]]; then
            git mergetool
        fi
    fi
}

execute_merge() {
    local target_branch="$1"
    local source_branch="$2"
    local original_branch
    original_branch=$(git rev-parse --abbrev-ref HEAD)

    if [ "$target_branch" = "$source_branch" ]; then
        log_error "目标分支和源分支相同 ($target_branch)"
        return 1
    fi

    if [[ "$target_branch" == origin/* ]]; then
        local local_name="${target_branch#origin/}"
        if ! git show-ref --verify --quiet "refs/heads/$local_name"; then
            git checkout -b "$local_name" --track "$target_branch"
        fi
        target_branch="$local_name"
    fi

    local needs_checkout_back=false
    if [ "$original_branch" != "$target_branch" ]; then
        needs_checkout_back=true
    fi

    if [ "$needs_checkout_back" = true ]; then
        echo "正在切换到分支 '$target_branch'..."
        if ! git checkout "$target_branch"; then
            log_error "切换到分支 '$target_branch' 失败。"
            return 1
        fi
    fi

    echo "正在将分支 '$source_branch' 合并到 '$target_branch'..."
    if ! git merge "$source_branch"; then
        handle_merge_conflict "$target_branch" "$source_branch"
        echo "合并出现冲突。正在中止合并操作..."
        if ! git merge --abort; then
            log_error "'git merge --abort' 失败。仓库可能处于不稳定状态。"
            needs_checkout_back=false
        else
            echo "已自动中止合并。"
        fi
    else
        echo "✅ 自动合并成功！"
    fi

    if [ "$needs_checkout_back" = true ]; then
        echo "操作完成，正在切换回原始分支 '$original_branch'..."
        if ! git checkout "$original_branch"; then
            log_error "无法自动切换回原始分支 '$original_branch'。请手动执行 'git checkout $original_branch'。"
        fi
    fi
}

sync_and_commit() {
    local source_branch="$1"
    local target_branch="$2"
    local file="$3"
    local commit_message="$4"
    local original_branch
    original_branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)

    if ! git checkout "$target_branch" >/dev/null 2>&1; then
        log_error "无法切换到 $target_branch 分支"
        git checkout "$original_branch" >/dev/null 2>&1 || true
        return 1
    fi

    if ! git checkout "$source_branch" -- "$file" >/dev/null 2>&1; then
        log_error "无法同步文件 $file"
        git checkout "$original_branch" >/dev/null 2>&1 || true
        return 1
    fi

    if git add "$file" && git commit -m "$commit_message" >/dev/null 2>&1; then
        echo "✅ 已提交更改到 $target_branch 分支"
    else
        log_warn "无法自动提交更改，请手动提交"
    fi

    if ! git checkout "$original_branch" >/dev/null 2>&1; then
        log_warn "无法切换回原分支 $original_branch"
        return 1
    fi

    return 0
}

branch_process_file() {
    local file="$1"
    local index="$2"
    local total="$3"
    local current_branch="$4"
    local compare_branch="$5"

    if git ls-files --error-unmatch "$file" &>/dev/null; then
        echo "[$index/$total] 正在对比: $file"
        echo "  左边: $current_branch 分支"
        echo "  右边: $compare_branch 分支"

        local original_hash new_hash
        original_hash=$(git hash-object "$file" 2>/dev/null || echo "")

        git difftool --no-prompt "$current_branch" "$compare_branch" -- "$file"

        new_hash=$(git hash-object "$file" 2>/dev/null || echo "")

        if [ "$original_hash" != "$new_hash" ]; then
            echo ""
            echo "✅ 检测到文件内容已修改"
            echo "正在将 '$current_branch' 分支的更新自动同步到 '$compare_branch' 分支..."

            echo "  - 步骤 1/2: 提交更改到当前分支 ($current_branch)..."
            local commit_msg_current="[自动同步] 更新文件 $file"

            if git add "$file" && git commit -m "$commit_msg_current"; then
                echo "    ✅ 已提交更改到 '$current_branch'"
            else
                log_warn "无法自动提交更改到 '$current_branch'。同步中止。"
                return
            fi

            echo "  - 步骤 2/2: 将文件从 '$current_branch' 同步到 '$compare_branch'..."
            sync_and_commit "$current_branch" "$compare_branch" "$file" "同步 $file 文件从 $current_branch 分支"
        else
            echo ""
            echo "ℹ️  文件在对比工具中未检测到修改，无需同步。"
        fi
    else
        echo "[$index/$total] 文件已删除或不存在: $file"
    fi
}

analyze_merge_workload() {
    local branch1="$1"
    local branch2="$2"

    echo ""
    echo "📊 分析合并工作量..."

    echo "分支信息:"
    echo "  当前分支: $branch1"
    echo "  目标分支: $branch2"

    local branch1_time branch2_time
    branch1_time=$(git log -1 --format="%ct" "$branch1" 2>/dev/null || echo "0")
    branch2_time=$(git log -1 --format="%ct" "$branch2" 2>/dev/null || echo "0")

    if [ "$branch1_time" != "0" ]; then
        echo "  $branch1 最新提交: $(format_timestamp "$branch1_time")"
    fi

    if [ "$branch2_time" != "0" ]; then
        echo "  $branch2 最新提交: $(format_timestamp "$branch2_time")"
    fi

    local merge_base
    merge_base=$(git merge-base "$branch1" "$branch2" 2>/dev/null || true)
    if [ -n "$merge_base" ]; then
        local base_time
        base_time=$(git log -1 --format="%ct" "$merge_base" 2>/dev/null || echo "0")
        if [ "$base_time" != "0" ]; then
            echo "  共同祖先: $(format_timestamp "$base_time") ($merge_base)"
        fi
    fi

    echo ""
    echo "提交统计:"

    local branch1_commits branch2_commits
    branch1_commits=$(git rev-list --count "$branch1" ^"$branch2" 2>/dev/null || echo "0")
    branch2_commits=$(git rev-list --count "$branch2" ^"$branch1" 2>/dev/null || echo "0")

    echo "  $branch1 独有提交: $branch1_commits 个"
    echo "  $branch2 独有提交: $branch2_commits 个"

    echo ""
    echo "文件差异统计:"

    local files_count
    files_count=$(git diff --name-only "$branch1" "$branch2" 2>/dev/null | wc -l | tr -d ' ')
    echo "  差异文件总数: $files_count 个"

    local diff_stats
    diff_stats=$(git diff --stat "$branch1" "$branch2" 2>/dev/null | tail -1)
    if [ -n "$diff_stats" ]; then
        echo "  $diff_stats"
    fi

    # 过滤后的文件列表
    local all_files filtered_files=()
    all_files=$(git diff --name-only "$branch1" "$branch2" 2>/dev/null || true)

    if [ -n "$all_files" ]; then
        while IFS= read -r file; do
            [ -z "$file" ] && continue
            local skip=false
            for pattern in "${BRANCH_EXCLUDE_PATTERNS[@]}"; do
                if [[ "$file" =~ $pattern ]]; then
                    skip=true
                    break
                fi
            done
            [ "$skip" = false ] && filtered_files+=("$file")
        done <<< "$all_files"
    fi

    echo "  需要处理的文件: ${#filtered_files[@]} 个（排除构建文件等）"

    echo ""
    echo "合并复杂度分析:"

    local conflict_files=0
    local modified_same_files=()

    # 使用 merge-tree 检测冲突（Git 2.39+）
    if git merge-tree --write-tree "$branch1" "$branch2" >/dev/null 2>&1; then
        echo "  无冲突"
    else
        # 回退方案：统计双方都修改的文件
        if [ -n "$merge_base" ] && [ ${#filtered_files[@]} -gt 0 ]; then
            local files_in_1 files_in_2
            files_in_1=$(git diff --name-only "$merge_base" "$branch1" 2>/dev/null || true)
            files_in_2=$(git diff --name-only "$merge_base" "$branch2" 2>/dev/null || true)
            for file in "${filtered_files[@]}"; do
                if echo "$files_in_1" | grep -qxF "$file" && echo "$files_in_2" | grep -qxF "$file"; then
                    modified_same_files+=("$file")
                    conflict_files=$((conflict_files + 1))
                fi
            done
        fi
        echo "  可能冲突的文件: $conflict_files 个"
    fi

    # 计算合并工作量评分
    echo ""
    echo "合并工作量评估:"

    local base_score=$((${#filtered_files[@]} * 1))
    local commit_diff_score=$(( (branch1_commits > branch2_commits ? branch1_commits - branch2_commits : branch2_commits - branch1_commits) * 2 ))
    local conflict_score=$((conflict_files * 2))

    local time_diff_score=0
    if [ "$branch1_time" != "0" ] && [ "$branch2_time" != "0" ] && [ -n "$merge_base" ]; then
        local base_time_val
        base_time_val=$(git log -1 --format="%ct" "$merge_base" 2>/dev/null || echo "0")
        if [ "$base_time_val" != "0" ]; then
            local days_since_split=$(( (branch1_time > branch2_time ? branch1_time : branch2_time) - base_time_val ))
            days_since_split=$((days_since_split / 86400))
            if [ $days_since_split -gt 30 ]; then
                time_diff_score=$((days_since_split / 10))
            fi
        fi
    fi

    local total_score=$((base_score + commit_diff_score + conflict_score + time_diff_score))

    echo ""
    echo "工作量评分详情:"
    echo "  基础文件差异: $base_score 分"
    echo "  提交数差异: $commit_diff_score 分"
    echo "  潜在冲突: $conflict_score 分"
    echo "  时间差异: $time_diff_score 分"
    echo "  总评分: $total_score 分"

    echo ""
    echo "合并建议:"
    if [ $total_score -lt 10 ]; then
        echo "  🟢 合并复杂度较低，可以直接合并"
    elif [ $total_score -lt 30 ]; then
        echo "  🟡 合并复杂度中等，建议仔细检查差异后合并"
    elif [ $total_score -lt 60 ]; then
        echo "  🟠 合并复杂度较高，建议分步骤合并或寻求协助"
    else
        echo "  🔴 合并复杂度很高，强烈建议详细规划合并策略"
    fi

    # 双向合并工作量对比
    echo ""
    echo "双向合并工作量对比:"

    local scenario1_total=$((branch2_commits + conflict_files * 3))
    echo "方案1: 将 $branch2 合并到 $branch1"
    echo "  需要处理的新提交: $branch2_commits 个"
    echo "  可能的冲突文件: $conflict_files 个"
    echo "  工作量评估: $scenario1_total 分"

    local scenario2_total=$((branch1_commits + conflict_files * 3))
    echo ""
    echo "方案2: 将 $branch1 合并到 $branch2"
    echo "  需要处理的新提交: $branch1_commits 个"
    echo "  可能的冲突文件: $conflict_files 个"
    echo "  工作量评估: $scenario2_total 分"

    echo ""
    if [ $scenario1_total -lt $scenario2_total ]; then
        echo "🎯 推荐方案: 方案1 ($branch2 合并到 $branch1)"
        echo "   原因: 工作量较小（${scenario1_total}分 vs ${scenario2_total}分）"
    elif [ $scenario2_total -lt $scenario1_total ]; then
        echo "🎯 推荐方案: 方案2 ($branch1 合并到 $branch2)"
        echo "   原因: 工作量较小（${scenario2_total}分 vs ${scenario1_total}分）"
    else
        echo "🎯 两种方案工作量相当（均为${scenario1_total}分），可根据项目流程选择"
    fi

    if [ ${#modified_same_files[@]} -gt 0 ]; then
        echo ""
        echo "需要特别注意的文件（可能冲突）:"
        for file in "${modified_same_files[@]}"; do
            echo "  - $file"
        done
    fi

    echo ""
    local merge_choice
    read -r -p "请选择合并方案 [1|2] 或按 Enter 退出: " merge_choice

    case "$merge_choice" in
        1)
            execute_merge "$branch1" "$branch2"
            ;;
        2)
            local local_branch2="$branch2"
            if [[ "$branch2" == origin/* ]]; then
                local_branch2="${branch2#origin/}"
            fi
            execute_merge "$local_branch2" "$branch1"
            ;;
        *)
            echo "已退出合并操作"
            ;;
    esac
}

branch_diff_main() {
    local current_branch="$BRANCH_CURRENT"
    local compare_branch="$BRANCH_COMPARE"
    local local_branch="$BRANCH_LOCAL"
    local git_dir="$BRANCH_GIT_DIR"

    # 验证并进入 Git 目录
    if [ -z "$git_dir" ]; then
        git_dir="$(pwd)"
    else
        git_dir=$(validate_git_dir "$git_dir") || exit 1
    fi

    cd "$git_dir" || { log_error "无法进入目录 $git_dir"; exit 1; }
    echo "Git 目录: $(pwd)"

    validate_git_repo

    # 获取当前分支
    if [ -z "$current_branch" ]; then
        current_branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null) || {
            log_error "无法获取当前分支信息"
            exit 1
        }
    fi

    validate_branch_name "$current_branch" || exit 1

    if ! git show-ref --verify --quiet "refs/heads/$current_branch"; then
        log_error "当前分支 '$current_branch' 不存在"
        exit 1
    fi

    # 处理分支对比逻辑
    if [ -n "$local_branch" ]; then
        validate_branch_name "$local_branch" || exit 1
        compare_branch="$local_branch"
        echo "当前分支 (左边): $current_branch"
        echo "对比分支 (右边): $compare_branch (本地分支)"

        if ! git show-ref --verify --quiet "refs/heads/$local_branch"; then
            log_error "本地分支 '$local_branch' 不存在"
            exit 1
        fi
    elif [ -n "$compare_branch" ]; then
        validate_branch_name "$compare_branch" || exit 1
        local remote_branch="$compare_branch"
        compare_branch="origin/$compare_branch"
        echo "当前分支 (左边): $current_branch"
        echo "对比分支 (右边): $compare_branch (远程分支)"

        if ! git show-ref --verify --quiet "refs/remotes/origin/$remote_branch"; then
            log_warn "远程分支 'origin/$remote_branch' 不存在，将继续执行但可能无结果"
        fi
    else
        compare_branch="origin/$current_branch"
        echo "当前分支 (左边): $current_branch"
        echo "对比分支 (右边): $compare_branch (默认远程分支)"

        if ! git show-ref --verify --quiet "refs/remotes/origin/$current_branch"; then
            log_warn "远程分支 '$compare_branch' 不存在，将继续执行但可能无结果"
        fi
    fi

    # Fetch 远程
    if [[ "$compare_branch" == origin/* ]]; then
        echo "正在获取远程分支状态..."
        if ! git fetch origin 2>/dev/null; then
            log_warn "无法获取远程分支状态，使用本地缓存"
        fi
    fi

    # 添加用户自定义排除模式
    for pattern in "${BRANCH_CUSTOM_EXCLUDES[@]+"${BRANCH_CUSTOM_EXCLUDES[@]}"}"; do
        BRANCH_EXCLUDE_PATTERNS+=("$pattern")
    done

    # 如果是工作量分析模式
    if [ "$BRANCH_ANALYZE_WORKLOAD" = true ]; then
        analyze_merge_workload "$current_branch" "$compare_branch"
        return 0
    fi

    # 获取差异文件列表
    echo "正在获取差异文件列表..."
    local all_files filtered_files=()
    all_files=$(git diff --name-only "$current_branch" "$compare_branch" 2>/dev/null || true)

    if [ -n "$all_files" ]; then
        while IFS= read -r file; do
            [ -z "$file" ] && continue
            local skip=false
            for pattern in "${BRANCH_EXCLUDE_PATTERNS[@]}"; do
                if [[ "$file" =~ $pattern ]]; then
                    skip=true
                    echo "排除文件: $file (匹配模式: $pattern)"
                    break
                fi
            done
            [ "$skip" = false ] && filtered_files+=("$file")
        done <<< "$all_files"
    fi

    if [ ${#filtered_files[@]} -eq 0 ]; then
        echo "🎉 没有需要对比的文件，$current_branch 分支与 $compare_branch 分支无差异"
        return 0
    fi

    local total_files=${#filtered_files[@]}

    echo "🔍 发现以下差异文件:"
    for i in "${!filtered_files[@]}"; do
        printf "%4d. %s\n" $((i+1)) "${filtered_files[i]}"
    done
    echo ""
    echo "共计: $total_files 个文件"

    # 交互菜单
    echo ""
    local choice
    read -r -p "请选择操作 [a]查看所有差异 [m]评估合并工作量 [n]退出程序 [数字]查看指定文件: " choice

    choice=$(echo "$choice" | tr -d ' ' | tr '[:upper:]' '[:lower:]')

    if [[ -n "$choice" && "$choice" != "a" && "$choice" != "n" && "$choice" != "m" ]]; then
        if [[ "$choice" =~ ^[0-9]+$ ]]; then
            if [ "$choice" -lt 1 ] || [ "$choice" -gt "$total_files" ]; then
                log_error "文件编号应在 1 到 $total_files 之间"
                exit 1
            fi
        else
            local found=false
            for i in "${!filtered_files[@]}"; do
                if [[ "${filtered_files[i]}" == "$choice"* ]]; then
                    found=true
                    break
                fi
            done
            if [ "$found" = false ]; then
                log_error "无效的文件路径或选项"
                exit 1
            fi
        fi
    fi

    if [[ "$choice" == "n" || -z "$choice" ]]; then
        echo "已取消操作"
        return 0
    fi

    if [[ "$choice" == "m" ]]; then
        analyze_merge_workload "$current_branch" "$compare_branch"
        return 0
    fi

    if [[ "$choice" == "a" ]]; then
        echo "开始对比所有文件差异..."
        for i in "${!filtered_files[@]}"; do
            branch_process_file "${filtered_files[i]}" "$((i+1))" "$total_files" "$current_branch" "$compare_branch"
        done
        echo "✅ 差异对比完成！已处理 $total_files 个文件。"
    else
        local found=false
        for i in "${!filtered_files[@]}"; do
            local file_index=$((i+1))
            if [ "$choice" == "$file_index" ] || [[ "${filtered_files[i]}" == "$choice"* ]]; then
                branch_process_file "${filtered_files[i]}" "$file_index" "$total_files" "$current_branch" "$compare_branch"
                found=true
                break
            fi
        done
        if [ "$found" = false ]; then
            log_error "无效的文件路径或编号"
            exit 1
        fi
    fi
}

# --- 11. 参数解析 ---

show_help() {
    echo -e "${CYAN}Git 差异对比工具（整合版）${NC}"
    echo ""
    echo -e "${YELLOW}用法:${NC}"
    echo "  $0 [选项]"
    echo "  $0 -b [分支模式选项]"
    echo ""
    echo -e "${YELLOW}通用模式（自动检测 git/目录/文件）:${NC}"
    echo "  -t, --text          文本输出 (默认)"
    echo "  -u, --gui           图形化 (Beyond Compare)"
    echo "  -l, --left          左侧分支/目录/文件"
    echo "  -r, --right         右侧分支/目录/文件"
    echo "  -e, --exclude       排除模式 (可多次使用，如：*.log,node_modules)"
    echo "  -c, --context       上下文行数 (默认：3)"
    echo "  -F, --filter        文件过滤 (如：*.java，仅 Git 模式)"
    echo "  -v, --verbose       详细输出"
    echo "  -h, --help          帮助信息"
    echo ""
    echo -e "${YELLOW}分支交互模式 (-b):${NC}"
    echo "  -b, --branch-diff   进入分支交互对比模式"
    echo "  -c, --current       指定当前分支（默认为当前检出的分支）"
    echo "  -r, --remote        指定要对比的远程分支"
    echo "  --lb                指定要对比的本地分支"
    echo "  -m, --merge-workload 评估合并工作量"
    echo "  -d, --dir           指定 Git 目录"
    echo "  -e, --exclude       添加排除模式（正则表达式）"
    echo ""
    echo -e "${YELLOW}通用模式示例:${NC}"
    echo "  $0 -t -l main -r develop               # Git 分支对比 - 文本"
    echo "  $0 -u -l HEAD~1 -r HEAD                # Git 分支对比 - 图形化"
    echo "  $0 -t -l ./old -r ./new                # 目录对比 - 文本"
    echo "  $0 -u -l ./old -r ./new                # 目录对比 - 图形化"
    echo "  $0 -t -l old.txt -r new.txt            # 文件对比 - 文本"
    echo "  $0 -t                                  # 简写：HEAD vs origin/HEAD"
    echo ""
    echo -e "${YELLOW}分支模式示例:${NC}"
    echo "  $0 -b                                  # 当前分支 vs origin/当前分支"
    echo "  $0 -b -r develop                       # 当前分支 vs origin/develop"
    echo "  $0 -b -c feature-a -r develop          # feature-a vs origin/develop"
    echo "  $0 -b -c feature-a --lb develop        # feature-a vs 本地 develop"
    echo "  $0 -b -m                               # 合并工作量评估"
    echo "  $0 -b -d /path/to/repo                 # 指定 Git 目录"
}

parse_args() {
    # 检查是否为 branch 模式
    if [[ "${1:-}" == "-b" || "${1:-}" == "--branch-diff" ]]; then
        MODE="branch"
        shift
        # 解析 branch 模式参数
        while [[ $# -gt 0 ]]; do
            case "$1" in
                -c|--current)
                    BRANCH_CURRENT="$2"
                    shift 2
                    ;;
                -r|--remote)
                    BRANCH_COMPARE="$2"
                    shift 2
                    ;;
                --lb|--local-branch)
                    BRANCH_LOCAL="$2"
                    shift 2
                    ;;
                -d|--dir)
                    BRANCH_GIT_DIR="$2"
                    shift 2
                    ;;
                -m|--merge-workload)
                    BRANCH_ANALYZE_WORKLOAD=true
                    shift
                    ;;
                -e|--exclude)
                    BRANCH_CUSTOM_EXCLUDES+=("$2")
                    shift 2
                    ;;
                -v|--verbose)
                    VERBOSE=1
                    shift
                    ;;
                -h|--help)
                    show_help
                    exit 0
                    ;;
                *)
                    log_error "未知分支模式选项：$1"
                    show_help
                    exit 1
                    ;;
            esac
        done
        return
    fi

    # 通用模式参数解析
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -t|--text)
                OUTPUT_MODE="text"
                shift
                ;;
            -u|--gui)
                OUTPUT_MODE="gui"
                shift
                ;;
            -l|--left)
                LEFT="$2"
                shift 2
                ;;
            -r|--right)
                RIGHT="$2"
                shift 2
                ;;
            -e|--exclude)
                IFS=',' read -ra patterns <<< "$2"
                for pattern in "${patterns[@]}"; do
                    pattern=$(echo "$pattern" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
                    [ -n "$pattern" ] && EXCLUDE_PATTERNS+=("$pattern")
                done
                shift 2
                ;;
            -c|--context)
                CONTEXT_LINES="$2"
                shift 2
                ;;
            -F|--filter)
                FILE_FILTER="$2"
                shift 2
                ;;
            -v|--verbose)
                VERBOSE=1
                shift
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            *)
                log_error "未知选项：$1"
                show_help
                exit 1
                ;;
        esac
    done
}

# --- 12. 自动检测模式 ---

auto_detect_mode() {
    # branch 模式已在 parse_args 中设置
    [ "$MODE" = "branch" ] && return

    if [ -n "$LEFT" ] && [ -n "$RIGHT" ]; then
        if [ -f "$LEFT" ] && [ -f "$RIGHT" ]; then
            MODE="file"
            log_debug "自动检测到文件模式"
            return
        fi
        if [ -d "$LEFT" ] && [ -d "$RIGHT" ]; then
            MODE="dir"
            log_debug "自动检测到目录模式"
            return
        fi
    fi
    MODE="git"
    log_debug "使用默认 Git 模式"
}

# --- 13. 主程序 ---

main() {
    parse_args "$@"

    auto_detect_mode

    [ -z "$OUTPUT_MODE" ] && OUTPUT_MODE="text"

    check_dependencies

    case "$MODE" in
        "git")
            validate_git_repo
            validate_git_refs
            if [ "$OUTPUT_MODE" = "text" ]; then
                git_diff_text
            else
                git_diff_gui
            fi
            ;;
        "dir")
            validate_dirs
            if [ "$OUTPUT_MODE" = "text" ]; then
                dir_diff_text
            else
                dir_diff_gui
            fi
            ;;
        "file")
            validate_files
            if [ "$OUTPUT_MODE" = "text" ]; then
                file_diff_text
            else
                file_diff_gui
            fi
            ;;
        "branch")
            branch_diff_main
            ;;
        *)
            log_error "未知模式：$MODE"
            exit 1
            ;;
    esac
}

main "$@"
