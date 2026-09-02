#!/bin/bash
# SQLFluff 安装脚本
# SQL 代码质量检查工具 - 支持自动检测、避免重复安装、自动更新

set -euo pipefail

# 非交互 SSH 默认 PATH 往往不加载 Homebrew / 用户 bin。
export PATH="$HOME/.local/bin:/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:$PATH"

# === 颜色定义 ===
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m'

# === 常量定义 ===
readonly DEFAULT_INSTALL_DIR="$HOME/.local/share/sqlfluff"
readonly DEFAULT_CONFIG_FILE="$HOME/.sqlfluff"

# === 全局变量 ===
INSTALL_DIR="$DEFAULT_INSTALL_DIR"
CONFIG_FILE="$DEFAULT_CONFIG_FILE"
DRY_RUN=false
UNINSTALL_MODE=false
STATUS_MODE=false
FORCE_UPDATE=false
AUTO_CONFIG=true
SQLFLUFF_BIN=""
WITH_DBT=false

# === 工具函数 ===
info() { echo -e "${BLUE}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[SUCCESS]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# === 显示帮助 ===
show_usage() {
    cat << 'EOF'
SQLFluff 安装脚本

SQLFluff 是一个 SQL linter 和格式化工具，用于检查和修复 SQL 代码质量问题。

特性:
    - 自动检测已安装版本，避免重复安装
    - 自动更新到最新版本（可选）
    - 自动创建默认配置文件
    - 支持安装/卸载/状态查看

用法: ./install-sqlfluff.sh [选项]

选项:
    -h, --help                  显示此帮助信息
    -d, --dir DIR               安装目录 (默认: ~/.local/share/sqlfluff)
    -c, --config FILE           配置文件路径 (默认: ~/.sqlfluff)
    -f, --force                 强制重新安装（忽略已安装检测）
    --update                    更新到最新版本
    --status                    显示安装状态
    --uninstall                 卸载 SQLFluff
    --with-dbt                  额外安装 sqlfluff-templater-dbt（依赖较多，默认不安装）
    --dry-run                   试运行模式

示例:
    ./install-sqlfluff.sh                          # 安装（自动检测避免重复）
    ./install-sqlfluff.sh --force                  # 强制重新安装
    ./install-sqlfluff.sh --update                 # 更新到最新版本
    ./install-sqlfluff.sh --status                 # 查看状态
    ./install-sqlfluff.sh --uninstall              # 卸载

使用指南:
    安装后使用:
      1. 检查 SQL: sqlfluff lint query.sql
      2. 修复 SQL: sqlfluff fix query.sql
      3. 格式化: sqlfluff format query.sql

    支持的数据库方言:
      - ansi (默认)
      - postgres
      - mysql
      - bigquery
      - snowflake
      - redshift
      - 更多: sqlfluff dialects

更多信息: https://sqlfluff.com/
EOF
}

# === 解析参数 ===
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help)
                show_usage
                exit 0
                ;;
            -d|--dir)
                INSTALL_DIR="${2/#\~/$HOME}"
                shift 2
                ;;
            -c|--config)
                CONFIG_FILE="${2/#\~/$HOME}"
                shift 2
                ;;
            -f|--force)
                FORCE_UPDATE=true
                shift
                ;;
            --update)
                FORCE_UPDATE=true
                shift
                ;;
            --status)
                STATUS_MODE=true
                shift
                ;;
            --uninstall)
                UNINSTALL_MODE=true
                shift
                ;;
            --with-dbt)
                WITH_DBT=true
                shift
                ;;
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            *)
                error "未知选项: $1"
                show_usage
                exit 1
                ;;
        esac
    done
}

# === 检查 Python ===
check_python() {
    if ! command -v python3 &>/dev/null; then
        error "未找到 Python 3"
        info "请先安装 Python 3.8+"
        exit 1
    fi
    
    local python_version
    python_version=$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')
    local major minor
    major=$(echo "$python_version" | cut -d. -f1)
    minor=$(echo "$python_version" | cut -d. -f2)
    
    if [[ "$major" -lt 3 ]] || [[ "$major" -eq 3 && "$minor" -lt 8 ]]; then
        error "Python 版本过低: $python_version (需要 3.8+)"
        exit 1
    fi
    
    success "检测到 Python: $python_version"
}

# === 检查 pip ===
check_pip() {
    if ! python3 -m pip --version &>/dev/null; then
        warn "当前 Python 全局 pip 不可用；将使用虚拟环境自带 pip"
        return 0
    fi
    
    success "检测到 pip"
}

# === 隔离安装路径 ===
venv_dir() {
    printf '%s\n' "$INSTALL_DIR/venv"
}

venv_pip() {
    printf '%s\n' "$(venv_dir)/bin/pip"
}

install_bin_dir() {
    printf '%s\n' "$HOME/.local/bin"
}

install_bin_path() {
    printf '%s\n' "$(install_bin_dir)/sqlfluff"
}

ensure_venv() {
    local venv
    venv="$(venv_dir)"
    if [[ -x "$venv/bin/python" ]]; then
        return 0
    fi

    info "创建隔离 Python 虚拟环境: $venv"
    mkdir -p "$INSTALL_DIR"
    python3 -m venv "$venv"
}

link_sqlfluff_bin() {
    local source_bin target_bin
    source_bin="$(venv_dir)/bin/sqlfluff"
    target_bin="$(install_bin_path)"
    [[ -x "$source_bin" ]] || return 1
    mkdir -p "$(install_bin_dir)"
    ln -sf "$source_bin" "$target_bin"
    SQLFLUFF_BIN="$target_bin"
}

ensure_user_bin_path() {
    local bin_dir rc_file marker
    bin_dir="$(install_bin_dir)"
    marker="# SQLFluff/user local bin PATH"

    if [[ -f "$HOME/.zshrc" ]]; then
        rc_file="$HOME/.zshrc"
    elif [[ -f "$HOME/.bashrc" ]]; then
        rc_file="$HOME/.bashrc"
    else
        rc_file="$HOME/.zshrc"
    fi

    if ! grep -qF "$bin_dir" "$rc_file" 2>/dev/null; then
        {
            echo ""
            echo "$marker"
            echo "export PATH=\"$bin_dir:\$PATH\""
        } >> "$rc_file"
        success "已自动添加 PATH 到 $rc_file: $bin_dir"
    else
        warn "$bin_dir 已在 $rc_file 中，但当前 shell 尚未加载"
    fi

    if [[ "$SHELL" == *zsh* || -f "$HOME/.zprofile" ]]; then
        local zprofile="$HOME/.zprofile"
        if ! grep -qF "$bin_dir" "$zprofile" 2>/dev/null; then
            {
                echo ""
                echo "$marker"
                echo "export PATH=\"$bin_dir:\$PATH\""
            } >> "$zprofile"
            success "已自动添加 PATH 到 $zprofile: $bin_dir"
        fi
    fi
}

# === 检测已安装的 SQLFluff ===
detect_installed_sqlfluff() {
    local installed_version=""
    local candidates=()
    candidates+=("$(install_bin_path)")
    candidates+=("$(venv_dir)/bin/sqlfluff")
    
    # 检查 sqlfluff 命令是否可用
    if command -v sqlfluff &>/dev/null; then
        candidates+=("$(command -v sqlfluff)")
    fi

    local candidate
    for candidate in "${candidates[@]}"; do
        if [[ -x "$candidate" ]]; then
            installed_version=$("$candidate" version 2>/dev/null || echo "")
            if [[ -n "$installed_version" ]]; then
                SQLFLUFF_BIN="$candidate"
                break
            fi
        fi
    done
    
    if [[ -n "$installed_version" ]]; then
        if [[ "$SQLFLUFF_BIN" == "$(venv_dir)/bin/sqlfluff" && ! -x "$(install_bin_path)" ]]; then
            link_sqlfluff_bin || true
        fi
        ensure_user_bin_path
        success "检测到已安装的 SQLFluff: $installed_version ($SQLFLUFF_BIN)"
        return 0
    fi
    
    return 1
}

# === 获取最新版本 ===
get_latest_version() {
    local latest_version=""
    local pip_cmd="python3 -m pip"
    if [[ -x "$(venv_pip)" ]]; then
        pip_cmd="$(venv_pip)"
    fi
    
    # 使用 pip index 获取最新版本，不向系统 Python 写入包。
    latest_version=$($pip_cmd index versions sqlfluff 2>/dev/null | head -1 | awk '{print $2}' || echo "")
    
    echo "$latest_version"
}

# === 安装 SQLFluff ===
install_sqlfluff() {
    info "安装 SQLFluff..."
    
    if [[ "$DRY_RUN" == true ]]; then
        info "[Dry-run] 将创建隔离环境: $(venv_dir)"
        info "[Dry-run] 将创建命令链接: $(install_bin_path)"
        return 0
    fi

    ensure_venv

    local pip_cmd
    pip_cmd="$(venv_pip)"

    info "升级隔离环境 pip..."
    "$pip_cmd" install --upgrade pip -q

    info "安装 SQLFluff 到隔离环境..."
    "$pip_cmd" install --upgrade sqlfluff -q

    if [[ "$WITH_DBT" == true ]]; then
        info "安装 dbt templater 插件..."
        "$pip_cmd" install --upgrade sqlfluff-templater-dbt -q 2>/dev/null || warn "dbt 插件安装失败（可选）"
    else
        info "跳过 dbt templater 插件；如需安装请重新运行: $0 --with-dbt"
    fi
    
    # 查找 sqlfluff 可执行文件
    local sqlfluff_bin=""
    local user_bin_paths=(
        "$HOME/.local/bin"
        "$HOME/Library/Python/3.9/bin"
        "$HOME/Library/Python/3.10/bin"
        "$HOME/Library/Python/3.11/bin"
        "$HOME/Library/Python/3.12/bin"
        "$HOME/Library/Python/3.13/bin"
    )
    # 动态检测 Python 版本的 bin 目录
    local py_minor
    py_minor=$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")' 2>/dev/null || echo "")
    if [[ -n "$py_minor" ]]; then
        user_bin_paths+=("$HOME/Library/Python/$py_minor/bin")
    fi

    if link_sqlfluff_bin; then
        sqlfluff_bin="$(install_bin_path)"
    elif command -v sqlfluff &>/dev/null; then
        sqlfluff_bin="$(command -v sqlfluff)"
    else
        for p in "${user_bin_paths[@]}"; do
            if [[ -x "$p/sqlfluff" ]]; then
                sqlfluff_bin="$p/sqlfluff"
                break
            fi
        done
    fi

    if [[ -n "$sqlfluff_bin" ]]; then
        ensure_user_bin_path
        local version
        version=$("$sqlfluff_bin" version 2>/dev/null || echo "未知")
        success "SQLFluff 安装成功: $version"

        # 如果不在 PATH 中，提示添加
        if ! command -v sqlfluff &>/dev/null; then
            local bin_dir
            bin_dir="$(dirname "$sqlfluff_bin")"
            warn "sqlfluff 不在 PATH 中: $bin_dir"
            info "请添加以下行到 ~/.zshrc 或 ~/.bashrc:"
            info "  export PATH=\"$bin_dir:\$PATH\""

            # 自动添加到 shell rc 文件
            local rc_file=""
            if [[ -f "$HOME/.zshrc" ]]; then
                rc_file="$HOME/.zshrc"
            elif [[ -f "$HOME/.bashrc" ]]; then
                rc_file="$HOME/.bashrc"
            fi

            if [[ -n "$rc_file" ]] && ! grep -qF "$bin_dir" "$rc_file" 2>/dev/null; then
                echo "" >> "$rc_file"
                echo "# SQLFluff PATH" >> "$rc_file"
                echo "export PATH=\"$bin_dir:\$PATH\"" >> "$rc_file"
                success "已自动添加 PATH 到 $rc_file"
            fi
        fi
    else
        error "SQLFluff 安装失败，未找到可执行文件"
        exit 1
    fi
}

# === 更新 SQLFluff ===
update_sqlfluff() {
    local current_version=""
    detect_installed_sqlfluff >/dev/null 2>&1 || true
    if [[ -n "$SQLFLUFF_BIN" ]]; then
        current_version=$("$SQLFLUFF_BIN" version 2>/dev/null || echo "")
    fi
    
    if [[ -z "$current_version" ]]; then
        info "SQLFluff 未安装，执行安装..."
        install_sqlfluff
        return
    fi
    
    info "当前版本: $current_version"
    
    # 获取最新版本
    local latest_version=""
    latest_version=$(get_latest_version)
    
    if [[ -n "$latest_version" ]]; then
        info "最新版本: $latest_version"
        
        if [[ "$current_version" == "$latest_version" ]]; then
            success "已是最新版本，无需更新"
            return 0
        fi
    else
        warn "无法获取最新版本信息，尝试直接更新..."
    fi
    
    if [[ "$DRY_RUN" == true ]]; then
        info "[Dry-run] 将更新 SQLFluff"
        return 0
    fi
    
    # 执行更新
    info "更新 SQLFluff..."
    ensure_venv
    "$(venv_pip)" install --upgrade pip sqlfluff -q
    if [[ "$WITH_DBT" == true ]]; then
        "$(venv_pip)" install --upgrade sqlfluff-templater-dbt -q 2>/dev/null || warn "dbt 插件更新失败（可选）"
    fi
    link_sqlfluff_bin || true
    
    local new_version=""
    new_version=$("$(install_bin_path)" version 2>/dev/null || echo "")
    
    if [[ -n "$new_version" ]]; then
        success "SQLFluff 更新成功: $new_version"
    else
        error "SQLFluff 更新失败"
        exit 1
    fi
}

# === 创建默认配置 ===
create_default_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        info "配置文件已存在: $CONFIG_FILE"
        return 0
    fi
    
    if [[ "$DRY_RUN" == true ]]; then
        info "[Dry-run] 将创建配置文件: $CONFIG_FILE"
        return 0
    fi
    
    info "创建默认配置文件: $CONFIG_FILE"
    
    cat > "$CONFIG_FILE" <<'EOF'
[sqlfluff]
# SQLFluff 配置文件
# 更多信息: https://docs.sqlfluff.com/en/stable/configuration.html

# 方言 (ansi, postgres, mysql, bigquery, snowflake, redshift 等)
dialect = postgres

# 最大行长度
max_line_length = 120

# 缩进类型 (space 或 tab)
indent_unit = space

# 缩进大小
tab_space_size = 4

# 排除的规则
exclude_rules = L034,L044

# 模板引擎 (raw, jinja, python, dbt)
templater = jinja

[sqlfluff:indentation]
# 缩进配置
indented_joins = False
indented_using_on = True

[sqlfluff:rules:L010]
# 关键字大小写
capitalisation_policy = consistent

[sqlfluff:rules:L014]
# 未引用的标识符大小写
extended_capitalisation_policy = consistent

[sqlfluff:rules:L030]
# 函数名大小写
capitalisation_policy = consistent

[sqlfluff:rules:L040]
# 数据类型大小写
capitalisation_policy = consistent

[sqlfluff:rules:L016]
# 行长度限制
ignore_comment_lines = True

[sqlfluff:rules:L029]
# 未引用的标识符
only_aliases = False
EOF
    
    success "创建默认配置: $CONFIG_FILE"
}

# === 显示状态 ===
show_status() {
    info "SQLFluff 安装状态"
    echo ""
    
    # 检查 SQLFluff 命令
    if detect_installed_sqlfluff >/dev/null 2>&1; then
        local version
        version=$("$SQLFLUFF_BIN" version 2>/dev/null || echo "未知")
        success "SQLFluff 已安装: $version"
        
        # 显示路径
        local sqlfluff_path
        sqlfluff_path="$SQLFLUFF_BIN"
        info "安装路径: $sqlfluff_path"
        
        # 显示可用方言
        echo ""
        info "可用方言:"
        "$SQLFLUFF_BIN" dialects 2>/dev/null | head -10 || warn "无法获取方言列表"
    else
        warn "SQLFluff 未安装"
    fi
    
    echo ""
    
    # 检查配置
    if [[ -f "$CONFIG_FILE" ]]; then
        success "配置文件存在: $CONFIG_FILE"
    else
        warn "配置文件不存在: $CONFIG_FILE"
    fi
    
    echo ""
    
    # 检查 Python 环境
    info "Python 环境:"
    info "  Python: $(python3 --version 2>/dev/null || echo '未找到')"
    info "  pip: $(python3 -m pip --version 2>/dev/null || echo '未找到')"
    info "  install dir: $INSTALL_DIR"
    info "  venv: $(venv_dir)"
}

# === 卸载 ===
uninstall_sqlfluff() {
    info "卸载 SQLFluff..."
    
    if [[ "$DRY_RUN" == true ]]; then
        info "[Dry-run] 将卸载 SQLFluff"
        return 0
    fi
    
    local target_bin
    target_bin="$(install_bin_path)"

    if [[ -d "$INSTALL_DIR" || -L "$target_bin" ]]; then
        rm -rf "$INSTALL_DIR"
        rm -f "$target_bin"
        success "SQLFluff 隔离环境已删除"
    else
        warn "SQLFluff 未安装"
    fi
    
    # 删除配置文件（可选）
    if [[ -f "$CONFIG_FILE" ]]; then
        info "配置文件保留: $CONFIG_FILE"
        info "如需删除: rm $CONFIG_FILE"
    fi
}

# === 主函数 ===
main() {
    parse_args "$@"
    
    # 状态模式
    if [[ "$STATUS_MODE" == true ]]; then
        show_status
        exit 0
    fi
    
    # 卸载模式
    if [[ "$UNINSTALL_MODE" == true ]]; then
        uninstall_sqlfluff
        exit 0
    fi
    
    # 检查依赖
    check_python
    check_pip
    
    # 检测已安装
    if [[ "$FORCE_UPDATE" == false ]] && detect_installed_sqlfluff; then
        success "SQLFluff 已安装，跳过安装"
        info "如需重新安装: $0 --force"
        info "如需更新: $0 --update"
    else
        # 安装或更新
        if [[ "$FORCE_UPDATE" == true ]]; then
            update_sqlfluff
        else
            install_sqlfluff
        fi
    fi
    
    # 自动配置
    if [[ "$AUTO_CONFIG" == true ]]; then
        create_default_config
    fi
    
    success "SQLFluff 安装完成"
    echo ""
    info "使用方法:"
    info "  检查 SQL: sqlfluff lint query.sql"
    info "  修复 SQL: sqlfluff fix query.sql"
    info "  格式化: sqlfluff format query.sql"
    echo ""
    info "查看帮助: sqlfluff --help"
}

main "$@"
