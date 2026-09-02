#!/bin/bash
# Jenkins 动态构建脚本
# 功能：根据 git 变更动态构建 Maven 多模块工程中变更的子模块
# 特性：
#   - 使用 git diff 检测变更（比 MD5 更准确、更快）
#   - 支持跨平台（Linux/macOS）
#   - 严格模式，错误处理完善
#   - 支持 dry-run 模式预览构建计划

set -euo pipefail

# ============================================================================
# 配置
# ============================================================================
readonly SCRIPT_NAME="$(basename "$0")"
readonly TIMESTAMP="$(date '+%Y-%m-%d %H:%M:%S')"

# 默认值
readonly DEFAULT_WORKSPACE="/var/lib/jenkins/workspace/pip-dev"
readonly DEFAULT_PROFILE="dev"
readonly DEFAULT_MAVEN_THREADS=12

# 颜色输出
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly NC='\033[0m' # No Color

# ============================================================================
# 日志函数
# ============================================================================
log_info() {
    echo -e "${GREEN}[INFO]${NC} ${TIMESTAMP} - $*"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} ${TIMESTAMP} - $*"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} ${TIMESTAMP} - $*" >&2
}

log_debug() {
    if [[ "${DEBUG:-0}" == "1" ]]; then
        echo -e "[DEBUG] ${TIMESTAMP} - $*"
    fi
}

# ============================================================================
# 帮助信息
# ============================================================================
usage() {
    cat <<EOF
用法: $SCRIPT_NAME [选项] [WORKSPACE] [PROFILE] [MODULES]

Jenkins 动态构建脚本：根据 git 变更动态构建 Maven 多模块工程的变更子模块

参数:
    WORKSPACE     工作目录（默认: $DEFAULT_WORKSPACE）
    PROFILE       Maven profile（默认: $DEFAULT_PROFILE）
    MODULES       指定构建的模块，逗号分隔（可选，为空时自动检测 git 变更）

选项:
    -h, --help           显示帮助信息
    -n, --dry-run        仅打印构建计划，不实际执行
    -d, --debug          启用调试模式
    --use-md5            使用 MD5 比对模式（兼容旧行为）
    --skip-parent        跳过父 POM 安装
    --skip-pmd           跳过 PMD 检查（默认已跳过）

示例:
    # 自动检测变更并构建
    $SCRIPT_NAME /path/to/project dev

    # 指定构建模块
    $SCRIPT_NAME /path/to/project dev "module-a,module-b"

    # 预览构建计划（不实际构建）
    $SCRIPT_NAME --dry-run /path/to/project dev

    # 使用 MD5 模式（兼容旧版本）
    $SCRIPT_NAME --use-md5 /path/to/project dev

特性:
    - 使用 git diff 检测变更（更准确、更快）
    - 支持跨平台（Linux/macOS）
    - 自动处理 api→app 模块名映射
    - 智能排除 common、resources 等公共模块
    - 首次构建自动全量构建
    - 完善的错误处理和日志输出

EOF
    exit 0
}

# ============================================================================
# 参数解析
# ============================================================================
parse_args() {
    DRY_RUN=0
    USE_MD5=0
    SKIP_PARENT=0
    WORKSPACE=""
    PROFILE=""
    MODULES=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                usage
                ;;
            -n|--dry-run)
                DRY_RUN=1
                shift
                ;;
            -d|--debug)
                export DEBUG=1
                shift
                ;;
            --use-md5)
                USE_MD5=1
                shift
                ;;
            --skip-parent)
                SKIP_PARENT=1
                shift
                ;;
            --skip-pmd)
                # 默认已跳过，保留参数兼容性
                shift
                ;;
            -*)
                log_error "未知选项: $1"
                usage
                ;;
            *)
                # 位置参数
                if [[ -z "$WORKSPACE" ]]; then
                    WORKSPACE="$1"
                elif [[ -z "$PROFILE" ]]; then
                    PROFILE="$1"
                elif [[ -z "$MODULES" ]]; then
                    MODULES="$1"
                else
                    log_error "未知参数: $1"
                    usage
                fi
                shift
                ;;
        esac
    done

    # 设置默认值
    WORKSPACE="${WORKSPACE:-$DEFAULT_WORKSPACE}"
    PROFILE="${PROFILE:-$DEFAULT_PROFILE}"
}

# ============================================================================
# 跨平台 MD5 计算
# ============================================================================
md5_cmd() {
    if command -v md5sum >/dev/null 2>&1; then
        # Linux
        md5sum "$@" | awk '{print $1}'
    elif command -v md5 >/dev/null 2>&1; then
        # macOS
        md5 -r "$@" | awk '{print $1}'
    else
        log_error "未找到 md5 或 md5sum 命令"
        return 1
    fi
}

# 计算目录下所有文件的 MD5（稳定排序）
compute_dir_md5() {
    local dir="$1"
    find "$dir" -type f | sort | while read -r f; do
        md5_cmd "$f"
    done | md5_cmd - 2>/dev/null || echo ""
}

# ============================================================================
# Git 变更检测
# ============================================================================
detect_changes_git() {
    local workspace="$1"
    local changed_modules=()

    cd "$workspace"

    # 检查是否是 git 仓库
    if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        log_warn "不是 git 仓库，回退到 MD5 模式"
        detect_changes_md5 "$workspace"
        return
    fi

    # 获取上次构建的 commit
    local last_commit=""
    local commit_file="$MD5_DIR/last_commit"
    if [[ -f "$commit_file" ]]; then
        last_commit=$(cat "$commit_file")
    fi

    # 获取变更的文件
    local changed_files=""
    if [[ -n "$last_commit" ]] && git rev-parse "$last_commit" >/dev/null 2>&1; then
        changed_files=$(git diff --name-only "$last_commit" HEAD 2>/dev/null || echo "")
    else
        # 首次构建，获取所有文件
        log_info "首次构建，检测所有模块"
        changed_files=$(git ls-files 2>/dev/null || echo "")
    fi

    if [[ -z "$changed_files" ]]; then
        log_info "未检测到文件变更"
        echo "" > "$MODULE_FILE"
        return
    fi

    log_debug "变更文件:\n$changed_files"

    # 提取变更的模块
    local src_dirs
    src_dirs=$(find "$workspace" -type d -name src 2>/dev/null || echo "")

    while IFS= read -r file; do
        [[ -z "$file" ]] && continue

        # 查找文件属于哪个 src 目录
        while IFS= read -r src_dir; do
            [[ -z "$src_dir" ]] && continue
            if [[ "$file" == "${src_dir#$workspace/}"* ]] || [[ "$file" == "$src_dir"* ]]; then
                local sub="${src_dir#$workspace/}"
                local module="${sub%/src}"

                # 排除公共模块
                if should_exclude_module "$sub"; then
                    continue 2
                fi

                # api→app 映射
                module=$(map_module_name "$module")

                # 去重添加
                if [[ ! " ${changed_modules[*]:-} " =~ " $module " ]]; then
                    changed_modules+=("$module")
                    log_info "检测到变更模块: $module"
                fi
                break
            fi
        done <<< "$src_dirs"
    done <<< "$changed_files"

    # 保存当前 commit
    git rev-parse HEAD > "$commit_file"

    # 写入模块文件
    if [[ ${#changed_modules[@]} -gt 0 ]]; then
        local module_list
        module_list=$(IFS=,; echo "${changed_modules[*]}")
        echo "module=$module_list" > "$MODULE_FILE"
    else
        echo "module=" > "$MODULE_FILE"
    fi
}

# ============================================================================
# MD5 变更检测（兼容模式）
# ============================================================================
detect_changes_md5() {
    local workspace="$1"
    local changed_modules=()

    # 清空模块文件
    echo -n "module=" > "$MODULE_FILE"

    local src_dirs
    src_dirs=$(find "$workspace" -type d -name src 2>/dev/null || echo "")

    while IFS= read -r src_dir; do
        [[ -z "$src_dir" ]] && continue

        local sub="${src_dir#$workspace/}"

        # 排除公共模块
        if should_exclude_module "$sub"; then
            log_debug "排除模块: $sub"
            continue
        fi

        local module="${sub%/src}"
        local name="${module#*/}"

        # 计算目录 MD5
        local current_md5
        current_md5=$(compute_dir_md5 "$src_dir")
        local cache_file="$MD5_DIR/$name"

        # 比对变更
        if [[ -f "$cache_file" ]]; then
            local cached_md5
            cached_md5=$(cat "$cache_file")
            if [[ "$cached_md5" == "$current_md5" ]]; then
                log_debug "$name 未变更"
                continue
            fi
            log_info "$name 已变更"
        else
            log_info "$name 首次构建"
        fi

        # api→app 映射
        module=$(map_module_name "$module")

        # 去重添加
        if [[ ! " ${changed_modules[*]:-} " =~ " $module " ]]; then
            changed_modules+=("$module")
        fi

        # 更新缓存
        echo "$current_md5" > "$cache_file"

    done <<< "$src_dirs"

    # 写入模块文件
    if [[ ${#changed_modules[@]} -gt 0 ]]; then
        local module_list
        module_list=$(IFS=,; echo "${changed_modules[*]}")
        echo "module=$module_list" > "$MODULE_FILE"
    else
        echo "module=" > "$MODULE_FILE"
    fi
}

# ============================================================================
# 模块名映射和排除
# ============================================================================
should_exclude_module() {
    local sub="$1"
    # 精确匹配路径组件
    case "$sub" in
        common/*|*/common/*|common)
            return 0
            ;;
        resources/*|*/resources/*|resources)
            return 0
            ;;
    esac
    return 1
}

map_module_name() {
    local module="$1"
    # 精确匹配 *-api 或 *-api-* 模式
    case "$module" in
        *-api|*-api-*)
            module="${module/api/app}"
            log_debug "模块名映射: $1 -> $module"
            ;;
    esac
    echo "$module"
}

# ============================================================================
# Maven 构建
# ============================================================================
run_maven_build() {
    local workspace="$1"
    local profile="$2"
    local modules="$3"

    # 加载 Maven 环境
    if [[ -f /etc/profile.d/maven.sh ]]; then
        # shellcheck disable=SC1091
        source /etc/profile.d/maven.sh
    fi

    cd "$workspace"

    # 安装父 POM
    if [[ "$SKIP_PARENT" != "1" ]]; then
        log_info "安装父 POM..."
        if [[ "$DRY_RUN" == "1" ]]; then
            log_info "[DRY-RUN] mvn install -N"
        else
            mvn install -N -q || {
                log_error "父 POM 安装失败"
                return 1
            }
        fi
    fi

    # 构建命令
    local maven_opts=(
        "clean"
        "install"
        "-Dmaven.test.skip=true"
        "-Dpmd.skip=true"
        "-e"
        "-T" "$DEFAULT_MAVEN_THREADS"
        "-Dmaven.compile.fork=true"
        "-U"
        "-pl" "$modules"
        "-am"
        "-P$profile"
    )

    local cmd="mvn ${maven_opts[*]}"

    if [[ "$DRY_RUN" == "1" ]]; then
        log_info "[DRY-RUN] $cmd"
        return 0
    fi

    log_info "开始构建: $cmd"
    # shellcheck disable=SC2086
    exec $cmd
}

# ============================================================================
# 清理函数
# ============================================================================
cleanup() {
    local exit_code=$?
    if [[ $exit_code -ne 0 ]]; then
        log_warn "脚本异常退出 (code: $exit_code)"
    fi
    exit $exit_code
}

# ============================================================================
# 主函数
# ============================================================================
main() {
    trap cleanup EXIT

    parse_args "$@"

    log_info "Jenkins 动态构建脚本启动"
    log_info "工作目录: $WORKSPACE"
    log_info "构建环境: $PROFILE"
    log_info "指定模块: ${MODULES:-<自动检测>}"
    log_info "检测模式: $([ "$USE_MD5" == "1" ] && echo "MD5" || echo "Git Diff")"
    [[ "$DRY_RUN" == "1" ]] && log_info "模式: DRY-RUN（仅预览）"

    # 验证工作目录
    if [[ ! -d "$WORKSPACE" ]]; then
        log_error "工作目录不存在: $WORKSPACE"
        exit 1
    fi

    # 初始化 MD5 目录
    MD5_DIR="$HOME/.md5/${WORKSPACE##*/}"
    MODULE_FILE="$MD5_DIR/module"
    mkdir -p "$MD5_DIR"

    # 检测变更
    local modules_to_build=""
    if [[ -n "$MODULES" ]]; then
        log_info "使用指定模块: $MODULES"
        modules_to_build="$MODULES"
        echo "module=$MODULES" > "$MODULE_FILE"
    else
        log_info "检测变更模块..."
        if [[ "$USE_MD5" == "1" ]]; then
            detect_changes_md5 "$WORKSPACE"
        else
            detect_changes_git "$WORKSPACE"
        fi

        modules_to_build=$(cat "$MODULE_FILE" | awk -F'=' '{print $2}')
    fi

    # 检查是否有模块需要构建
    if [[ -z "$modules_to_build" ]]; then
        log_warn "未检测到需要构建的模块"
        exit 0
    fi

    log_info "待构建模块: $modules_to_build"

    # 执行构建
    run_maven_build "$WORKSPACE" "$PROFILE" "$modules_to_build"
}

main "$@"
