#!/bin/bash
# Java环境集成自动化安装脚本
# 功能：根据用户选择的环境类型，推荐并自动安装所需的软件
# 使用：./java-env-setup.sh [--dev|--server|--auto]

set -e

# 获取脚本所在目录
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

# ============================================
# 共享工具函数
# ============================================

# 下载目录
DOWNLOAD_DIR="${DOWNLOAD_DIR:-$HOME/Downloads}"

find_adl() {
    if command -v adl >/dev/null 2>&1 && adl --help >/dev/null 2>&1; then
        command -v adl
        return 0
    fi
    return 1
}

# ADL下载函数 - 优先使用adl工具
download_with_adl() {
    local url="$1"
    local output="$2"
    local filename="$(basename "$output")"
    local output_dir="$(dirname "$output")"

    # 确保输出目录存在
    mkdir -p "$output_dir"

    local adl_path
    if adl_path=$(find_adl); then
        "$adl_path" "$url" "$output_dir" "$filename"
    elif command -v curl >/dev/null 2>&1; then
        curl -L --fail -o "$output" "$url"
    elif command -v wget >/dev/null 2>&1; then
        wget -O "$output" "$url"
    else
        echo "错误: 未找到可用下载工具，请安装 adl、curl 或 wget"
        return 1
    fi
}

# 检查文件完整性（基本大小检查）
check_file_valid() {
    local file="$1"
    local min_size="${2:-1000}"  # default 1KB
    [[ -f "$file" ]] && [[ -s "$file" ]] && [[ $(stat -f%z "$file" 2>/dev/null || stat -c%s "$file" 2>/dev/null) -gt $min_size ]]
}

get_shell_config_file() {
    local shell_name
    shell_name="$(basename "${SHELL:-}")"

    case "$shell_name" in
        zsh)
            if [ -f "$HOME/.zshrc" ]; then
                echo "$HOME/.zshrc"
            elif [ -f "$HOME/.zprofile" ]; then
                echo "$HOME/.zprofile"
            else
                echo "$HOME/.zshrc"
            fi
            ;;
        bash)
            if [ -f "$HOME/.bashrc" ]; then
                echo "$HOME/.bashrc"
            elif [ -f "$HOME/.bash_profile" ]; then
                echo "$HOME/.bash_profile"
            else
                echo "$HOME/.bashrc"
            fi
            ;;
        *)
            echo "$HOME/.zshrc"
            ;;
    esac
}

find_envs_cmd() {
    if command -v envs >/dev/null 2>&1; then
        command -v envs
    elif [ -x "/opt/homebrew/bin/envs" ]; then
        echo "/opt/homebrew/bin/envs"
    elif [ -x "$HOME/.local/bin/envs" ]; then
        echo "$HOME/.local/bin/envs"
    elif [ -x "$SCRIPT_DIR/../os/envs" ]; then
        echo "$SCRIPT_DIR/../os/envs"
    else
        return 1
    fi
}

prepend_common_tool_paths() {
    prepend_existing_path "/opt/homebrew/bin"
    prepend_existing_path "/usr/local/bin"
    prepend_existing_path "$HOME/.local/bin"
    prepend_existing_path "$HOME/bin"
    hash -r 2>/dev/null || true
}

ensure_envs_available() {
    prepend_common_tool_paths

    if command -v envs >/dev/null 2>&1; then
        echo -e "${GREEN}[OK] envs 已可用: $(command -v envs)${NC}"
        envs init >/dev/null 2>&1 || true
        return 0
    fi

    local repo_envs="$SCRIPT_DIR/../os/envs"
    if [ ! -x "$repo_envs" ]; then
        echo -e "${YELLOW}[WARN] 未找到 envs，后续环境变量写入将使用内置兜底方式${NC}"
        return 1
    fi

    echo -e "${BLUE}[INFO] envs 不可用，执行 envs install...${NC}"
    if "$repo_envs" install >/dev/null 2>&1; then
        prepend_common_tool_paths
        if command -v envs >/dev/null 2>&1; then
            echo -e "${GREEN}[OK] envs 已安装并可用: $(command -v envs)${NC}"
            envs init >/dev/null 2>&1 || true
            return 0
        fi
    fi

    echo -e "${YELLOW}[WARN] envs 安装后仍不可用，后续环境变量写入将使用内置兜底方式${NC}"
    return 1
}

ensure_adl_available() {
    prepend_common_tool_paths

    local repo_adl="$SCRIPT_DIR/../network/tools/adl"

    # 统一的 aria2 安装逻辑 (adl 已可用或刚配置成功后都执行)
    install_aria2_if_missing() {
        if command -v aria2c >/dev/null 2>&1; then
            return 0
        fi
        if [ ! -x "$repo_adl" ]; then
            echo -e "${YELLOW}[WARN] aria2 未安装且无 adl 可用，多线程下载不可用${NC}"
            return 1
        fi
        echo -e "${BLUE}[INFO] aria2 未安装，执行 adl --install-deps 启用多线程下载...${NC}"
        if "$repo_adl" --install-deps >/dev/null 2>&1; then
            if command -v aria2c >/dev/null 2>&1; then
                echo -e "${GREEN}[OK] aria2 已安装: $(command -v aria2c)${NC}"
            fi
        else
            echo -e "${YELLOW}[WARN] aria2 安装失败，adl 将回退到 curl/wget${NC}"
        fi
    }

    if find_adl >/dev/null 2>&1; then
        echo -e "${GREEN}[OK] adl 已可用: $(command -v adl)${NC}"
        install_aria2_if_missing
        return 0
    fi

    if [ ! -x "$repo_adl" ]; then
        echo -e "${YELLOW}[WARN] 未找到 adl，下载时将回退到 curl/wget${NC}"
        return 1
    fi

    echo -e "${BLUE}[INFO] adl 不可用，执行 adl --setup-env...${NC}"
    if "$repo_adl" --setup-env >/dev/null 2>&1; then
        prepend_common_tool_paths
        if find_adl >/dev/null 2>&1; then
            echo -e "${GREEN}[OK] adl 已配置并可用: $(command -v adl)${NC}"
            install_aria2_if_missing
            return 0
        fi
    fi

    echo -e "${YELLOW}[WARN] adl 配置后仍不可用，下载时将回退到 curl/wget${NC}"
    return 1
}

ensure_ip_tool_available() {
    prepend_common_tool_paths

    local repo_ip="$SCRIPT_DIR/../os/monitor/ip.sh"
    local user_bin="$HOME/.local/bin"
    local target_link="$user_bin/ip.sh"

    if command -v ip.sh >/dev/null 2>&1; then
        echo -e "${GREEN}[OK] ip.sh 已可用: $(command -v ip.sh)${NC}"
        ip.sh >/dev/null 2>&1 || true
        return 0
    fi

    if [ ! -x "$repo_ip" ]; then
        echo -e "${YELLOW}[WARN] 未找到 ip.sh，跳过本机 IP 工具前置检查${NC}"
        return 1
    fi

    mkdir -p "$user_bin"
    if ln -sf "$repo_ip" "$target_link" 2>/dev/null; then
        prepend_existing_path "$user_bin"
        add_path_entry "$user_bin" >/dev/null 2>&1 || true
    else
        prepend_existing_path "$SCRIPT_DIR/../os/monitor"
        add_path_entry "$SCRIPT_DIR/../os/monitor" >/dev/null 2>&1 || true
    fi

    if command -v ip.sh >/dev/null 2>&1; then
        echo -e "${GREEN}[OK] ip.sh 已配置并可用: $(command -v ip.sh)${NC}"
        ip.sh >/dev/null 2>&1 || true
        return 0
    fi

    echo -e "${YELLOW}[WARN] ip.sh 配置后仍不可用，后续脚本将使用自身 IP 兜底逻辑${NC}"
    return 1
}

prepare_environment_tools() {
    export DOWNLOAD_DIR="${DOWNLOAD_DIR:-$HOME/Downloads}"
    mkdir -p "$DOWNLOAD_DIR"
    prepend_common_tool_paths

    echo -e "${BLUE}[INFO] 下载目录: $DOWNLOAD_DIR${NC}"
    ensure_envs_available || true
    ensure_adl_available || true
    ensure_ip_tool_available || true
}

upsert_export_fallback() {
    local key="$1"
    local value="$2"
    local rc_file="$3"
    local tmp

    touch "$rc_file"
    tmp="$(mktemp)"

    awk -v key="$key" -v value="$value" '
        BEGIN { found = 0 }
        $0 ~ "^[[:space:]]*export[[:space:]]+" key "=" {
            if (!found) {
                print "export " key "=\"" value "\""
                found = 1
            }
            next
        }
        { print }
        END {
            if (!found) {
                print ""
                print "export " key "=\"" value "\""
            }
        }
    ' "$rc_file" > "$tmp"
    mv "$tmp" "$rc_file"
}

add_env_var() {
    local key="$1"
    local value="$2"
    local rc_file="${3:-$(get_shell_config_file)}"
    local envs_cmd

    if envs_cmd="$(find_envs_cmd 2>/dev/null)"; then
        if "$envs_cmd" add "${key}=${value}" "$rc_file" >/dev/null; then
            return 0
        fi
        echo -e "${YELLOW}[WARN] envs 写入失败，改用内置方式: ${key}${NC}"
        upsert_export_fallback "$key" "$value" "$rc_file"
    else
        upsert_export_fallback "$key" "$value" "$rc_file"
    fi
}

add_path_entry() {
    local bin_dir="$1"
    local rc_file="${2:-$(get_shell_config_file)}"
    local envs_cmd

    [ -d "$bin_dir" ] || return 0

    # 去重检查: 如果 bin_dir 已在 PATH 行中，跳过
    if [ -f "$rc_file" ]; then
        local path_line
        path_line=$(grep -E '^[[:space:]]*export[[:space:]]+PATH=' "$rc_file" | head -1 || true)
        if [[ "$path_line" == *"$bin_dir"* ]]; then
            return 0
        fi
    fi

    if envs_cmd="$(find_envs_cmd 2>/dev/null)"; then
        if "$envs_cmd" add "PATH=${bin_dir}" "$rc_file" >/dev/null; then
            return 0
        fi
        echo -e "${YELLOW}[WARN] envs 写入 PATH 失败，改用内置方式: ${bin_dir}${NC}"
    fi

    local current_value=""
    if [ -f "$rc_file" ]; then
        current_value="$(grep -E '^[[:space:]]*export[[:space:]]+PATH=' "$rc_file" | head -1 | sed 's/^[^=]*=//' | sed 's/^"//; s/"$//; s/^'\''//; s/'\''$//' || true)"
    fi
    if [ -n "$current_value" ]; then
        upsert_export_fallback "PATH" "${bin_dir}:${current_value}" "$rc_file"
    else
        upsert_export_fallback "PATH" "${bin_dir}:\$PATH" "$rc_file"
    fi
}

prepend_existing_path() {
    local bin_dir="$1"

    [ -d "$bin_dir" ] || return 0
    case ":$PATH:" in
        *":$bin_dir:"*) ;;
        *) export PATH="$bin_dir:$PATH" ;;
    esac
}

detect_java_home() {
    if [ -n "${JAVA_HOME:-}" ] && [ -x "$JAVA_HOME/bin/java" ]; then
        echo "$JAVA_HOME"
    elif [ -x "$HOME/jdk/current/bin/java" ]; then
        echo "$HOME/jdk/current"
    elif [ -x "$HOME/jdk/jdk-21/bin/java" ]; then
        echo "$HOME/jdk/jdk-21"
    elif [ -x "/opt/jdk/jdk-21/bin/java" ]; then
        echo "/opt/jdk/jdk-21"
    elif [ -x "/opt/jdk/current/bin/java" ]; then
        echo "/opt/jdk/current"
    elif command -v /usr/libexec/java_home >/dev/null 2>&1; then
        /usr/libexec/java_home 2>/dev/null || true
    fi
}

detect_maven_home() {
    if [ -n "${MAVEN_HOME:-}" ] && [ -x "$MAVEN_HOME/bin/mvn" ]; then
        echo "$MAVEN_HOME"
    elif [ -x "$HOME/maven/current/bin/mvn" ]; then
        echo "$HOME/maven/current"
    elif [ -x "$HOME/.maven/current/bin/mvn" ]; then
        echo "$HOME/.maven/current"
    elif [ -x "/opt/maven/current/bin/mvn" ]; then
        echo "/opt/maven/current"
    fi
}

detect_gradle_home() {
    if [ -n "${GRADLE_HOME:-}" ] && [ -x "$GRADLE_HOME/bin/gradle" ]; then
        echo "$GRADLE_HOME"
    elif [ -x "$HOME/gradle/gradle-current/bin/gradle" ]; then
        echo "$HOME/gradle/gradle-current"
    elif [ -x "$HOME/gradle/current/bin/gradle" ]; then
        echo "$HOME/gradle/current"
    elif [ -x "$HOME/.gradle/gradle-current/bin/gradle" ]; then
        echo "$HOME/.gradle/gradle-current"
    elif [ -x "$HOME/.gradle/current/bin/gradle" ]; then
        echo "$HOME/.gradle/current"
    fi
}

detect_mvnd_home() {
    if [ -n "${MVND_HOME:-}" ] && [ -x "$MVND_HOME/bin/mvnd" ]; then
        echo "$MVND_HOME"
    elif [ -x "$HOME/mvnd/bin/mvnd" ]; then
        echo "$HOME/mvnd"
    elif [ -x "$HOME/mvnd/current/bin/mvnd" ]; then
        echo "$HOME/mvnd/current"
    elif [ -x "$HOME/.mvnd/bin/mvnd" ]; then
        echo "$HOME/.mvnd"
    elif [ -x "$HOME/.mvnd/current/bin/mvnd" ]; then
        echo "$HOME/.mvnd/current"
    elif [ -x "/opt/mvnd/current/bin/mvnd" ]; then
        echo "/opt/mvnd/current"
    fi
}

detect_arthas_home() {
    if [ -n "${ARTHAS_HOME:-}" ] && { [ -f "$ARTHAS_HOME/arthas-boot.jar" ] || [ -x "$ARTHAS_HOME/as.sh" ]; }; then
        echo "$ARTHAS_HOME"
    elif [ -f "$HOME/arthas/arthas-boot.jar" ] || [ -x "$HOME/arthas/as.sh" ]; then
        echo "$HOME/arthas"
    elif [ -f "$HOME/.arthas/arthas-boot.jar" ] || [ -x "$HOME/.arthas/as.sh" ]; then
        echo "$HOME/.arthas"
    fi
}

detect_mysql_home() {
    if [ -n "${MYSQL_HOME:-}" ] && [ -x "$MYSQL_HOME/bin/mysql" ]; then
        echo "$MYSQL_HOME"
    elif [ -x "$HOME/mysql/bin/mysql" ]; then
        echo "$HOME/mysql"
    elif [ -x "/opt/mysql/bin/mysql" ]; then
        echo "/opt/mysql"
    fi
}

detect_redis_home() {
    if [ -n "${REDIS_HOME:-}" ] && [ -x "$REDIS_HOME/bin/redis-server" ]; then
        echo "$REDIS_HOME"
    elif [ -x "$HOME/redis/bin/redis-server" ]; then
        echo "$HOME/redis"
    elif [ -x "/opt/redis/bin/redis-server" ]; then
        echo "/opt/redis"
    fi
}

detect_rocketmq_home() {
    if [ -n "${ROCKETMQ_HOME:-}" ] && [ -x "$ROCKETMQ_HOME/bin/mqadmin" ]; then
        echo "$ROCKETMQ_HOME"
    elif [ -x "$HOME/rocketmq/bin/mqadmin" ]; then
        echo "$HOME/rocketmq"
    elif [ -x "/opt/rocketmq/bin/mqadmin" ]; then
        echo "/opt/rocketmq"
    fi
}

configure_java_tool_envs() {
    local rc_file="${1:-$(get_shell_config_file)}"
    local java_home maven_home gradle_home mvnd_home arthas_home
    local mysql_home redis_home rocketmq_home

    java_home="$(detect_java_home)"
    maven_home="$(detect_maven_home)"
    gradle_home="$(detect_gradle_home)"
    mvnd_home="$(detect_mvnd_home)"
    arthas_home="$(detect_arthas_home)"
    mysql_home="$(detect_mysql_home)"
    redis_home="$(detect_redis_home)"
    rocketmq_home="$(detect_rocketmq_home)"

    # envs 可用时 add_env_var 会自动把 $XXX_HOME/bin 加入 PATH (变量引用形式)
    # envs 不可用时需要手动 add_path_entry (展开形式)
    # 两种方式互斥，避免同一目录以两种形式重复出现在 PATH 中
    local has_envs=false
    find_envs_cmd >/dev/null 2>&1 && has_envs=true

    # 统一的 HOME + PATH 配置函数
    # 参数: env_key, home_path, path_subdir (bin 或空)
    configure_tool_env() {
        local env_key="$1"
        local home_path="$2"
        local path_subdir="${3:-bin}"

        export "$env_key"="$home_path"
        add_env_var "$env_key" "$home_path" "$rc_file"

        local bin_dir
        if [ -n "$path_subdir" ]; then
            bin_dir="$home_path/$path_subdir"
        else
            bin_dir="$home_path"
        fi

        # envs 不可用时手动把展开路径加入 PATH
        # envs 可用时 add_env_var 已自动加入变量引用形式 ($XXX_HOME/bin)
        $has_envs || add_path_entry "$bin_dir" "$rc_file"

        # 当前 session 立即生效
        prepend_existing_path "$bin_dir"
    }

    [ -n "$java_home" ]    && configure_tool_env "JAVA_HOME"    "$java_home"    "bin"
    [ -n "$maven_home" ]   && configure_tool_env "MAVEN_HOME"   "$maven_home"   "bin"
    [ -n "$gradle_home" ]  && {
        configure_tool_env "GRADLE_HOME" "$gradle_home" "bin"
        export GRADLE_USER_HOME="${GRADLE_USER_HOME:-$HOME/.gradle}"
        add_env_var "GRADLE_USER_HOME" "$GRADLE_USER_HOME" "$rc_file"
    }
    [ -n "$mvnd_home" ]    && configure_tool_env "MVND_HOME"    "$mvnd_home"    "bin"
    [ -n "$arthas_home" ]  && configure_tool_env "ARTHAS_HOME"  "$arthas_home"  ""
    [ -n "$mysql_home" ]   && configure_tool_env "MYSQL_HOME"   "$mysql_home"   "bin"
    [ -n "$redis_home" ]   && configure_tool_env "REDIS_HOME"   "$redis_home"   "bin"
    [ -n "$rocketmq_home" ] && configure_tool_env "ROCKETMQ_HOME" "$rocketmq_home" "bin"

    if $has_envs; then
        local envs_cmd
        envs_cmd="$(find_envs_cmd 2>/dev/null)"
        "$envs_cmd" dedup "$rc_file" >/dev/null || true
    fi

    # 重新排序: 确保所有 *_HOME 变量定义在 PATH 行之前
    # 否则 PATH 中的 $XXX_HOME/bin 引用会展开为空
    reorder_env_vars_before_path "$rc_file"

    hash -r 2>/dev/null || true
}

# 重新排序 rc 文件: 把 export XXX_HOME= 行移到 export PATH= 之前
reorder_env_vars_before_path() {
    local rc_file="$1"
    [ -f "$rc_file" ] || return 0

    local tmp
    tmp=$(mktemp)

    awk '
        /^export[[:space:]]+PATH=/ {
            path_lines[count++] = $0
            next
        }
        /^export[[:space:]]+[A-Z_]+_HOME=/ {
            home_lines[hcount++] = $0
            next
        }
        /^export[[:space:]]+GRADLE_USER_HOME=/ {
            home_lines[hcount++] = $0
            next
        }
        { other_lines[ocount++] = $0 }
        END {
            # 先输出其他行（保持原序）
            for (i = 0; i < ocount; i++) print other_lines[i]
            # 再输出 HOME 变量定义
            for (i = 0; i < hcount; i++) print home_lines[i]
            # 最后输出 PATH 行
            for (i = 0; i < count; i++) print path_lines[i]
        }
    ' "$rc_file" > "$tmp" && mv "$tmp" "$rc_file"
}

# 自动特权提升
require_root() {
    if [[ $EUID -ne 0 ]]; then
        echo "需要root权限，正在提权..."
        exec sudo "$0" "$@"
    fi
}

# ============================================
# 颜色定义
# ============================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
GRAY='\033[0;90m'
BOLD='\033[1m'
REVERSE='\033[7m'
NC='\033[0m'

# 全局变量
ENV_TYPE=""
AUTO_INSTALL=false
UNINSTALL_MODE=false
UNINSTALL_ALL=false
INSTALL_PARENT_DIR="$HOME"
APPS_LIST=""
JDK_VERSION_ARG=""
AUTO_START=false
NACOS_CLUSTER=false
SELECTED_APPS=()
INSTALLED_APPS=()
APP_MENU_OPTIONS=()
APP_MENU_INSTALLED=()
APP_MENU_PRESELECTED=""

INSTALL_RECORD_FILE="$HOME/.java_env_record"

# 获取缓存的版本信息
get_cached_version() {
    local app_name="$1"
    if [ -f "$INSTALL_RECORD_FILE" ]; then
        grep "^${app_name}:" "$INSTALL_RECORD_FILE" | cut -d':' -f2- | head -1
    fi
}

# 更新缓存的版本信息
update_cached_version() {
    local app_name="$1"
    local version="$2"
    touch "$INSTALL_RECORD_FILE"
    local tmp_file="${INSTALL_RECORD_FILE}.tmp"
    grep -v "^${app_name}:" "$INSTALL_RECORD_FILE" > "$tmp_file" || true
    if [ -n "$version" ]; then
        echo "${app_name}:${version}" >> "$tmp_file"
    fi
    mv "$tmp_file" "$INSTALL_RECORD_FILE"
}

# 定义Java开发环境推荐软件（按优先级排序：必需 → 推荐 → 可选）
DEV_APPS=(
    "JDK:jdk/install-jdk.sh:Java开发工具包:必需"
    "Git:../git/setup_git.sh:Git版本控制:必需"
    "Maven:build-tools/maven/maven.sh:Maven构建工具:推荐"
    "Gradle:build-tools/gradle/install-gradle.sh:Gradle构建工具:推荐"
    "Arthas:arthas/install-arthas.sh:Java诊断工具:推荐"
    "mvnd:build-tools/mvnd/install-mvnd.sh:mvnd守护进程:可选"
)

# 定义IDE软件（仅在开发环境且有图形桌面时推荐）
IDE_APPS=(
    "IntelliJ IDEA:../ide/install-intellij-idea.sh:Java集成开发环境:可选"
    "Eclipse:../ide/install-eclipse.sh:Java集成开发环境:可选"
    "VS Code:../ide/install-vscode.sh:通用代码编辑器:可选"
    "Cursor:../ide/install-cursor.sh:AI增强型编辑器:可选"
    "Trae:../ide/install-trae.sh:字节跳动AI IDE:可选"
    "Windsurf:../ide/install-windsurf.sh:Codeium AI IDE:可选"
)

# 定义Java服务器环境推荐软件（按优先级排序：必需 → 推荐 → 可选）
SERVER_APPS=(
    "JDK:jdk/install-jdk.sh:Java运行环境:必需"
    "Maven:build-tools/maven/maven.sh:Maven构建工具:推荐"
    "Arthas:arthas/install-arthas.sh:Java诊断工具:推荐"
    "MySQL:../database/mysql/bin/install.sh:关系型数据库:推荐"
    "Nacos:nacos/install-nacos.sh:配置中心和服务发现:推荐"
    "Sentinel:sentinel-dashboard/install-sentinel.sh:流量控制:推荐"
    "Seata:seata/install-seata.sh:分布式事务:推荐"
    "RocketMQ:../mq/rocketmq/bin/install.sh:消息队列:推荐"
    "Redis:../database/redis/bin/install.sh:缓存数据库:推荐"
    "Prometheus:../monitor/prometheus/bin/install.sh:监控告警:推荐"
    "Grafana:../monitor/grafana/install.sh:监控可视化:推荐"
    "Nginx:../web-server/nginx/bin/install.sh:Web服务器/反向代理:推荐"
    "MinIO:minio/bin/install-minio.sh:S3兼容对象存储:推荐"
    "ELK:elk/bin/install-elk.sh:日志收集分析平台:推荐"
    "Kafka:../mq/kafka/install-kafka.sh:分布式事件流平台:推荐"
    "XXL-Job:xxl-job/install-xxl-job.sh:分布式任务调度:推荐"
    "Nexus:nexus/bin/install-nexus.sh:私有Maven/NPM仓库:推荐"
    "SonarQube:../sonarqube/bin/install-sonarqube.sh:代码质量管控:推荐"
    "Dubbo Admin:dubbo-admin/install-dubbo-admin.sh:服务治理:推荐"
    "SkyWalking:../apm/skywalking/bin/install.sh:链路追踪:可选"
    "Jenkins:../cicd/jenkins/install.sh:持续集成/CI:可选"
    "Spug:../cicd/spug/bin/install-spug.sh:自动化发布/运维平台:可选"
    "ZooKeeper:zookeeper/install-zookeeper.sh:分布式协调服务:可选"
    "ActiveMQ:../mq/activemq/bin/install.sh:传统消息队列:可选"
    "MongoDB:../database/mongodb/install.sh:文档数据库:可选"
    "PostgreSQL:../database/postgresql/install.sh:企业级关系型数据库:可选"
    "Dependency Track:../dependency-track/bin/startup.sh:依赖安全分析:可选"
)

# 显示帮助信息
show_help() {
    echo -e "${YELLOW}用法:${NC}"
    echo "    $0 [选项]"
    echo ""
    echo -e "${YELLOW}选项:${NC}"
    echo "    --dev          安装Java开发环境"
    echo "    --server       安装Java服务器环境"
    echo "    --auto         自动安装模式（跳过确认）"
    echo "    --apps LIST    指定要安装的软件列表（逗号分隔），例如: --apps \"JDK,Maven,MySQL\""
    echo "    --jdk-version VERSION  指定JDK版本号，跳过交互询问，例如: --jdk-version 21"
    echo "    --env KEY=VALUE  传递环境变量给安装脚本，可多次使用，例如: --env MYSQL_HOST=127.0.0.1"
    echo "    --auto-start   安装完成后自动启动服务（例如 Nacos）"
    echo "    --nacos-cluster 配置 Nacos 为集群模式（默认单机）"
    echo "    --uninstall    卸载模式（需配合 --apps 指定软件，或 --uninstall-all）"
    echo "    --uninstall-all  批量卸载所有已安装软件（自动检测，非交互式）"
    echo "    --install-parent DIR  安装父目录，默认: $HOME"
    echo "    --download-dir DIR    下载目录，默认: $HOME/Downloads"
    echo "    --help, -h     显示此帮助信息"
    echo ""
    echo -e "${YELLOW}示例:${NC}"
    echo "    $0 --dev              # 交互式安装开发环境"
    echo "    $0 --server --auto    # 自动安装服务器环境"
    echo "    $0 --server --auto --install-parent /opt"
    echo "    $0 --apps \"Nacos\" --env MYSQL_HOST=192.168.1.10 --env MYSQL_PASSWORD=root # 传递环境变量"
    echo "    $0 --apps \"JDK,Maven,MySQL\" --jdk-version 17 # 批量非交互安装指定软件"
    echo "    $0 --uninstall --apps \"JDK,Maven,MySQL\"    # 批量卸载指定软件"
    echo "    $0 --uninstall-all                          # 批量卸载所有已安装软件"
    echo ""
    echo -e "${YELLOW}说明:${NC}"
    echo "    - 开发环境包含：JDK、Maven、Gradle、Git、Arthas等"
    echo "    - 服务器环境包含：JDK、Maven、Arthas、ZooKeeper、Nacos等"
    echo "    - 默认情况下会列出推荐软件，用户可以选择取消部分软件"
    echo "    - 使用 --auto 参数可以跳过确认，自动安装所有推荐软件"
    echo "    - 使用 --apps 参数时，可以跳过环境选择并精准安装指定的组件"
    echo ""
}

# 解析命令行参数
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --dev)
                ENV_TYPE="dev"
                shift
                ;;
            --server)
                ENV_TYPE="server"
                shift
                ;;
            --auto)
                AUTO_INSTALL=true
                shift
                ;;
            --apps)
                APPS_LIST="$2"
                shift 2
                ;;
            --jdk-version)
                JDK_VERSION_ARG="$2"
                shift 2
                ;;
            --env|-e)
                export "$2"
                shift 2
                ;;
            --auto-start)
                AUTO_START=true
                shift
                ;;
            --nacos-cluster)
                NACOS_CLUSTER=true
                shift
                ;;
            --uninstall)
                UNINSTALL_MODE=true
                shift
                ;;
            --uninstall-all)
                UNINSTALL_MODE=true
                UNINSTALL_ALL=true
                AUTO_INSTALL=true
                shift
                ;;
            --install-parent|--base-dir)
                INSTALL_PARENT_DIR="${2/#\~/$HOME}"
                shift 2
                ;;
            --download-dir)
                DOWNLOAD_DIR="${2/#\~/$HOME}"
                shift 2
                ;;
            --help|-h)
                show_help
                exit 0
                ;;
            *)
                echo -e "${RED}未知参数: $1${NC}"
                show_help
                exit 1
                ;;
        esac
    done
}

get_install_child_name() {
    case "$1" in
        "JDK") echo "jdk" ;;
        "Maven") echo "maven" ;;
        "Gradle") echo "gradle" ;;
        "Arthas") echo "arthas" ;;
        "mvnd") echo "mvnd" ;;
        "Nacos") echo "nacos" ;;
        "Redis") echo "redis" ;;
        "MySQL") echo "mysql" ;;
        "RocketMQ") echo "rocketmq" ;;
        "Prometheus") echo "prometheus" ;;
        "Grafana") echo "grafana" ;;
        "Nginx") echo "nginx" ;;
        "MinIO") echo "minio" ;;
        "Sentinel") echo "sentinel" ;;
        "Seata") echo "seata" ;;
        "XXL-Job") echo "xxl-job" ;;
        "ZooKeeper") echo "zookeeper" ;;
        "ActiveMQ") echo "activemq" ;;
        "Nexus") echo "nexus" ;;
        "Kafka") echo "kafka" ;;
        "SonarQube") echo "sonarqube" ;;
        "Dubbo Admin") echo "dubbo-admin" ;;
        "Dependency Track") echo "dependency-track" ;;
        "ELK") echo "elk" ;;
        *) echo "" ;;
    esac
}

normalize_install_dir() {
    local base_dir="${1/#\~/$HOME}"
    local child="$2"

    [ -n "$child" ] || return 1
    [ -n "$base_dir" ] || base_dir="$HOME"

    base_dir="${base_dir%/}"
    if [ "$(basename "$base_dir")" = "$child" ]; then
        echo "$base_dir"
    else
        echo "$base_dir/$child"
    fi
}

# 获取软件版本号（从数组中获取脚本路径并调用）
# 参数：软件名称、脚本路径
# 返回：如果已安装则输出版本号，未安装则输出空字符串
get_software_version() {
    local name="$1"
    local script="$2"
    local version=""
    local install_child=""
    local app_install_dir=""

    # 优先从记录中获取是否安装
    local cached_version
    cached_version="$(get_cached_version "$name")"
    if [ -n "$cached_version" ]; then
        if [ "$cached_version" != "FAILED" ]; then
            echo "$cached_version"
            return
        fi
        # 如果是 FAILED，重新检测，不直接返回
    fi

    install_child="$(get_install_child_name "$name")"
    if [ -n "$install_child" ]; then
        app_install_dir="$(normalize_install_dir "$INSTALL_PARENT_DIR" "$install_child")"
    fi

    # 优先直接检查命令是否存在，不调用安装脚本的 --version
    case $name in
        "JDK")
            if command -v java &>/dev/null; then
                # 捕获java -version的输出，但过滤掉macOS的错误信息
                version=$(java -version 2>&1 | head -1)
                # 如果是macOS的错误信息，说明没有真正安装
                if echo "$version" | grep -q "Unable to locate a Java Runtime\|操作无法完成"; then
                    version=""
                fi
            fi
            ;;
        "Gradle")
            if command -v gradle &>/dev/null; then
                version=$(gradle --version 2>&1 | grep "Gradle" | head -1)
            elif [ -d "$HOME/gradle/gradle-current" ] && [ -f "$HOME/gradle/gradle-current/bin/gradle" ]; then
                version="已安装 (未加载到 PATH)"
            elif [ -d "$HOME/gradle/current" ] && [ -f "$HOME/gradle/current/bin/gradle" ]; then
                version="已安装 (未加载到 PATH)"
            elif [ -d "$HOME/.gradle/gradle-current" ] && [ -f "$HOME/.gradle/gradle-current/bin/gradle" ]; then
                version="已安装 (未加载到 PATH)"
            elif [ -d "$HOME/.gradle/current" ] && [ -f "$HOME/.gradle/current/bin/gradle" ]; then
                version="已安装 (未加载到 PATH)"
            fi
            ;;
        "Git")
            if command -v git &>/dev/null; then
                version=$(git --version)
            fi
            ;;
        "Arthas")
            if [ -f "$HOME/arthas/arthas-boot.jar" ] || [ -f "$HOME/.arthas/lib/arthas-boot.jar" ] || command -v as.sh &>/dev/null; then
                version="已安装"
            elif [ -d "$HOME/arthas" ]; then
                version="已安装 (未配置启动脚本)"
            elif [ -d "$HOME/.arthas" ]; then
                version="已安装 (未配置启动脚本)"
            fi
            ;;
        "aria2")
            if command -v aria2c &>/dev/null; then
                version=$(aria2c --version | head -n 1)
            fi
            ;;
        "ZooKeeper")
            if command -v zkServer &>/dev/null; then
                version=$(zkServer --version 2>&1 | head -1)
            elif pgrep -f "zookeeper" >/dev/null 2>&1; then
                version="运行中"
            fi
            ;;
        "Nacos")
            if pgrep -f "nacos" >/dev/null 2>&1; then
                version="运行中"
            fi
            ;;
        "MySQL")
            if command -v mysql &>/dev/null; then
                version=$(mysql --version 2>&1 | head -1)
            elif command -v mysqld &>/dev/null; then
                version=$(mysqld --version 2>&1 | head -1)
            elif [ -x "$HOME/mysql/bin/mysql" ]; then
                version="已安装 (未加载到 PATH)"
            elif [ -x "/opt/mysql/bin/mysql" ]; then
                version="已安装 (未加载到 PATH)"
            elif ls /opt/homebrew/opt/mysql*/bin/mysql >/dev/null 2>&1; then
                version="已安装 (Homebrew)"
            elif pgrep -f "mysqld" >/dev/null 2>&1; then
                version="运行中"
            fi
            ;;
        "Redis")
            if command -v redis-server &>/dev/null; then
                version=$(redis-server --version 2>&1 | head -1)
            elif { [ -n "$app_install_dir" ] && [ -x "$app_install_dir/bin/redis-server" ]; } ||
                 pgrep -f "redis-server" >/dev/null 2>&1; then
                version="已安装"
            fi
            ;;
        "Sentinel")
            if pgrep -f "sentinel" >/dev/null 2>&1; then
                version="运行中"
            elif [ -n "$app_install_dir" ] && find "$app_install_dir" -maxdepth 2 -type f -name "sentinel-dashboard*.jar" 2>/dev/null | grep -q .; then
                version="已安装"
            elif [ -n "$app_install_dir" ] && [ -d "$app_install_dir" ]; then
                version="已安装"
            fi
            ;;
        "Seata")
            if pgrep -f "seata" >/dev/null 2>&1; then
                version="运行中"
            fi
            ;;
        "Maven")
            if command -v mvn &>/dev/null; then
                version=$(mvn --version 2>&1 | head -1)
            elif [ -n "${MAVEN_HOME:-}" ] && [ -f "$MAVEN_HOME/bin/mvn" ]; then
                version="已安装 (未加载到 PATH)"
            elif [ -d "$HOME/maven/current" ] && [ -f "$HOME/maven/current/bin/mvn" ]; then
                version="已安装 (未加载到 PATH)"
            elif [ -d "/opt/maven/current" ] && [ -f "/opt/maven/current/bin/mvn" ]; then
                version="已安装 (未加载到 PATH)"
            elif [ -d "$HOME/.maven/current" ] && [ -f "$HOME/.maven/current/bin/mvn" ]; then
                version="已安装 (未加载到 PATH)"
            fi
            ;;
        "mvnd")
            if command -v mvnd &>/dev/null; then
                version=$(mvnd --version 2>&1 | grep "mvnd" | head -1)
            elif [ -n "${MVND_HOME:-}" ] && [ -f "$MVND_HOME/bin/mvnd" ]; then
                version="已安装 (未加载到 PATH)"
            elif [ -d "$HOME/mvnd/current" ] && [ -f "$HOME/mvnd/current/bin/mvnd" ]; then
                version="已安装 (未加载到 PATH)"
            elif [ -f "$HOME/mvnd/bin/mvnd" ]; then
                version="已安装 (未加载到 PATH)"
            elif [ -d "/opt/mvnd/current" ] && [ -f "/opt/mvnd/current/bin/mvnd" ]; then
                version="已安装 (未加载到 PATH)"
            elif [ -d "$HOME/.mvnd/current" ] && [ -f "$HOME/.mvnd/current/bin/mvnd" ]; then
                version="已安装 (未加载到 PATH)"
            elif [ -f "$HOME/.mvnd/bin/mvnd" ]; then
                version="已安装 (未加载到 PATH)"
            fi
            ;;
        "IntelliJ IDEA")
            if command -v idea &>/dev/null || [ -d "/Applications/IntelliJ IDEA.app" ] || [ -d "/Applications/IntelliJ IDEA CE.app" ] || [ -d "$HOME/.local/share/JetBrains/Toolbox/apps/IDEA" ]; then
                version="已安装"
            fi
            ;;
        "Eclipse")
            if command -v eclipse &>/dev/null || [ -d "/Applications/Eclipse.app" ]; then
                version="已安装"
            fi
            ;;
        "VS Code")
            if command -v code &>/dev/null || [ -d "/Applications/Visual Studio Code.app" ]; then
                version="已安装"
            fi
            ;;
        "Cursor")
            if command -v cursor &>/dev/null || [ -d "/Applications/Cursor.app" ]; then
                version="已安装"
            fi
            ;;
        "Trae")
            if [ -d "/Applications/Trae.app" ] || [ -d "/Applications/TRAE SOLO CN.app" ] || ls -d /Applications/*Trae*.app &>/dev/null || ls -d /Applications/*trae*.app &>/dev/null; then
                version="已安装"
            fi
            ;;
        "Windsurf")
            if [ -d "/Applications/Windsurf.app" ]; then
                version="已安装"
            fi
            ;;
        "Nexus")
            if [ -n "$app_install_dir" ] && [ -d "$app_install_dir" ] || command -v nexus &>/dev/null; then
                version="已安装"
            fi
            ;;
        "SonarQube")
            if [ -n "$app_install_dir" ] && [ -d "$app_install_dir" ] || command -v sonar &>/dev/null; then
                version="已安装"
            fi
            ;;
        "Dependency Track")
            if [ -n "$app_install_dir" ] && [ -d "$app_install_dir" ]; then
                version="已安装"
            fi
            ;;
        "Nginx")
            if command -v nginx &>/dev/null ||
               { [ -n "$app_install_dir" ] && { [ -x "$app_install_dir/sbin/nginx" ] || [ -x "$app_install_dir/bin/nginx" ] || [ -d "$app_install_dir/conf" ]; }; } ||
               [ -d "/usr/local/nginx" ]; then
                version="已安装"
            fi
            ;;
        "MinIO")
            if command -v minio &>/dev/null ||
               { [ -n "$app_install_dir" ] && { [ -x "$app_install_dir/minio" ] || [ -x "$app_install_dir/bin/minio" ]; }; } ||
               [ -f "/usr/local/bin/minio" ]; then
                version="已安装"
            fi
            ;;
        "Prometheus")
            if command -v prometheus &>/dev/null ||
               { [ -n "$app_install_dir" ] && { [ -x "$app_install_dir/bin/prometheus" ] || [ -f "$app_install_dir/conf/prometheus.yml" ]; }; } ||
               pgrep -f "prometheus.*--config.file" >/dev/null 2>&1; then
                version="已安装"
            fi
            ;;
        "Grafana")
            if command -v grafana-server &>/dev/null ||
               { [ -n "$app_install_dir" ] && { [ -x "$app_install_dir/bin/grafana-server" ] || [ -f "$app_install_dir/conf/defaults.ini" ]; }; } ||
               pgrep -f "grafana-server" >/dev/null 2>&1; then
                version="已安装"
            fi
            ;;
        "ELK")
            if [ -n "$app_install_dir" ] && [ -d "$app_install_dir" ] || [ -d "/opt/elasticsearch" ] || [ -d "/opt/logstash" ] || [ -d "/opt/kibana" ]; then
                version="已安装"
            fi
            ;;
        "Kafka")
            if [ -n "$app_install_dir" ] && [ -d "$app_install_dir" ] || command -v kafka-server-start &>/dev/null; then
                version="已安装"
            fi
            ;;
        "RocketMQ")
            if pgrep -f "rocketmq|mqbroker|mqnamesrv" >/dev/null 2>&1 ||
               { [ -n "$app_install_dir" ] && { [ -x "$app_install_dir/bin/mqbroker" ] || [ -x "$app_install_dir/bin/mqnamesrv" ] || [ -d "$app_install_dir/lib" ]; }; } ||
               command -v mqbroker &>/dev/null || command -v mqnamesrv &>/dev/null; then
                version="已安装"
            fi
            ;;
        "XXL-Job")
            if [ -n "$app_install_dir" ] && [ -d "$app_install_dir" ]; then
                version="已安装"
            fi
            ;;
        "ActiveMQ")
            if [ -n "$app_install_dir" ] && [ -d "$app_install_dir" ] || command -v activemq &>/dev/null; then
                version="已安装"
            fi
            ;;
        "MongoDB")
            if command -v mongod &>/dev/null || { [ -n "$app_install_dir" ] && [ -d "$app_install_dir" ]; }; then
                version="已安装"
            fi
            ;;
        "PostgreSQL")
            if command -v psql &>/dev/null || { [ -n "$app_install_dir" ] && [ -d "$app_install_dir" ]; }; then
                version="已安装"
            fi
            ;;
        "Dubbo Admin")
            if [ -n "$app_install_dir" ] && [ -d "$app_install_dir" ]; then
                version="已安装"
            fi
            ;;
    esac

    # 原样输出版本号，不做任何处理
    if [ -n "$version" ]; then
        update_cached_version "$name" "$version"
    elif [ -n "$cached_version" ] && [ "$cached_version" != "FAILED" ]; then
        update_cached_version "$name" "FAILED"
    fi
    echo "$version"
}

# 检查软件是否已安装（通过版本号判断）
check_installed() {
    local app_name="$1"
    local script_path="$2"
    local version=$(get_software_version "$app_name" "$script_path")

    # 如果版本号不为空，则表示已安装
    [ -n "$version" ]
}

# 检测系统是否有图形桌面
has_graphical_desktop() {
    local os_type=$(uname -s)

    case "$os_type" in
        Darwin)
            # macOS通常都有图形界面
            return 0
            ;;
        Linux)
            # 检查DISPLAY环境变量或会话类型
            if [ -n "$DISPLAY" ] || [ -n "$WAYLAND_DISPLAY" ]; then
                return 0
            fi
            # 检查是否有桌面会话
            if [ -n "$XDG_SESSION_TYPE" ] && [ "$XDG_SESSION_TYPE" != "tty" ]; then
                return 0
            fi
            # 检查是否有X11运行
            if pgrep -x "Xorg" > /dev/null 2>&1 || pgrep -x "X11" > /dev/null 2>&1; then
                return 0
            fi
            return 1
            ;;
        *)
            return 1
            ;;
    esac
}

# 显示软件选择界面
show_app_selection() {
    local first_run="$1"
    shift
    local apps=("$@")
    local env_name=""
    local lines_printed=0

    if [ "$ENV_TYPE" == "dev" ]; then
        env_name="Java开发环境"
    else
        env_name="Java服务器环境"
    fi

    if [ "${MENU_IN_PLACE:-false}" == "true" ]; then
        if [ "${MENU_CURSOR_SAVED:-false}" == "true" ]; then
            printf "\033[u"
        else
            printf "\033[s"
            MENU_CURSOR_SAVED="true"
        fi
        printf "\033[J"
    fi

    echo -e "${GREEN}=== ${env_name}软件选择 ===${NC}"
    echo ""
    lines_printed=$((lines_printed + 2))

    # 显示表头
    printf "%1s%2s  %-4s  %-20s  %s\n" "" "#" "选择" "软件" "状态"
    printf "%1s%-2s  %-4s  %-20s  %s\n" "" "==" "====" "====" "===="
    lines_printed=$((lines_printed + 2))

    # 按数组顺序显示（已按优先级定义）
    for i in "${!apps[@]}"; do
        IFS=':' read -r name script desc priority <<< "${apps[$i]}"
        local status_text="" status_color="" select_text="" select_color="$NC"

        # 获取版本号（传入名称和脚本路径）
        local version=$(get_software_version "$name" "$script")

        if [ -n "$version" ]; then
            # 已安装显示版本号
            status_text="已安装 ($version)"
            status_color="$GREEN"
            select_color="$GRAY"
            # 始终不勾选已安装的软件
            SELECTED_APPS[$i]=0
        else
            # 未安装显示优先级
            status_text="未安装 ${priority}"
            status_color="$RED"
            # 只有在第一次运行时才设置默认选择
            if [ "$first_run" == "first" ]; then
                if [ "$priority" == "必需" ] || [ "$priority" == "推荐" ]; then
                    SELECTED_APPS[$i]=1
                else
                    SELECTED_APPS[$i]=0
                fi
            fi
        fi

        # 获取选择状态
        if [ "${SELECTED_APPS[$i]}" == "1" ]; then
            select_text="[✓]"
            select_color="$GREEN"
        else
            if [ "$UNINSTALL_MODE" == "true" ] && [ "${APP_MENU_INSTALLED[$i]:-0}" == "0" ]; then
                select_text="[-]"
            elif [ "$UNINSTALL_MODE" == "false" ] && [ "${APP_MENU_INSTALLED[$i]:-0}" == "1" ]; then
                select_text="[-]"
            else
                select_text="[ ]"
            fi
        fi

        # 显示一行
        local line_num=$((i+1))
        local cursor_text=" "
        if [ -n "${MENU_CURRENT_INDEX:-}" ] && [ "$MENU_CURRENT_INDEX" -eq "$i" ]; then
            cursor_text=">"
        fi

        # 使用printf构建格式化字符串（不含颜色）
        printf "%1s%2d  " "$cursor_text" "$line_num"

        # 输出带颜色的选择状态（不换行）
        echo -ne "${select_color}${select_text}${NC}  "

        # 输出软件信息（去掉描述列）
        printf "%-20s " "$name"

        # 输出带颜色的安装状态
        echo -e "${status_color}${status_text}${NC}"
        lines_printed=$((lines_printed + 1))
    done

    echo ""
    lines_printed=$((lines_printed + 1))

    if [ "${MENU_SHOW_PROMPT:-false}" == "true" ]; then
        if [ -n "${MENU_STATUS_MESSAGE:-}" ]; then
            echo -e "${MENU_STATUS_MESSAGE}"
            lines_printed=$((lines_printed + 1))
        fi
        echo -ne "${YELLOW}请选择 (↑/↓=移动, 数字=跳转定位, 空格=切换, a=全选, n=取消, 回车=确认): ${NC}"
        lines_printed=$((lines_printed + 1))
    fi

    MENU_RENDERED_LINES="$lines_printed"
}

java_menu_select() {
    local prompt="$1"
    local multi="$2"
    local allow_exit="$3"
    local preselected="$4"
    shift 4
    local options=("$@")

    local cur=0
    local count=${#options[@]}
    local selected=()
    local i ps

    for ((i=0; i<count; i++)); do
        selected[i]=false
        for ps in $preselected; do
            if [[ "$ps" == "$i" ]]; then
                selected[i]=true
                break
            fi
        done
    done

    if [[ ! -t 0 ]]; then
        echo "EXIT"
        return 0
    fi

    local original_tty_settings=""
    original_tty_settings="$(stty -g 2>/dev/null || echo "")"
    stty -echo -icanon min 1 time 0 2>/dev/null || true
    printf "\033[?25l" >&2
    while read -t 0.01 -n 1024 discard 2>/dev/null; do :; done

    local term_width
    term_width="$(tput cols 2>/dev/null || echo 80)"

    render_java_menu() {
        local start_line="$1"
        local is_first="$2"
        local lines_printed=0

        if [[ "$is_first" != "true" ]]; then
            printf "\r\033[%dA" "$start_line" >&2
        fi
        printf "\033[J" >&2

        printf "\r${CYAN}${prompt}${NC}\n" >&2
        if [[ "$multi" == "true" ]]; then
            printf "\r${YELLOW}(↑↓移动，数字跳转，空格勾选，回车确认%s)${NC}\n\n" "$([[ "$allow_exit" == "true" ]] && printf '，q 退出')" >&2
        else
            printf "\r${YELLOW}(↑↓移动，数字跳转，空格/回车确认%s)${NC}\n\n" "$([[ "$allow_exit" == "true" ]] && printf '，q 退出')" >&2
        fi
        lines_printed=3

        local max_len=$((term_width - 15))
        for ((i=0; i<count; i++)); do
            local display_line="${options[$i]}"
            display_line="${display_line//$'\n'/ }"
            if [[ $max_len -gt 10 && ${#display_line} -gt $max_len ]]; then
                display_line="${display_line:0:$max_len}..."
            fi

            local prefix="  "
            [[ $i -eq $cur ]] && prefix="${BLUE}> "

            local num=$((i + 1))
            if [[ "$multi" == "true" ]]; then
                local checkbox="[ ]"
                [[ "${selected[$i]}" == "true" ]] && checkbox="[x]"
                if [[ $i -eq $cur ]]; then
                    printf "\r${prefix}${checkbox} %2d. ${CYAN}${display_line}${NC}\n" "$num" >&2
                else
                    printf "\r${prefix}${checkbox} %2d. ${display_line}\n" "$num" >&2
                fi
            else
                if [[ $i -eq $cur ]]; then
                    printf "\r${prefix}%2d. ${CYAN}${display_line}${NC}\n" "$num" >&2
                else
                    printf "\r${prefix}%2d. ${display_line}\n" "$num" >&2
                fi
            fi
            lines_printed=$((lines_printed + 1))
        done

        if [[ "$allow_exit" == "true" ]]; then
            if [[ $cur -eq $count ]]; then
                printf "\r${BLUE}> q. 返回/退出${NC}\n" >&2
            else
                printf "\r  q. 返回/退出\n" >&2
            fi
            lines_printed=$((lines_printed + 1))
        fi

        return "$lines_printed"
    }

    local rendered_lines=0
    render_java_menu 0 true
    rendered_lines=$?

    local key="" char=""
    while true; do
        if ! IFS= read -rsn1 char; then
            break
        fi
        key="$char"

        if [[ "$char" == $'\x1b' ]]; then
            local old_stty_state rest=""
            old_stty_state="$(stty -g 2>/dev/null || echo "")"
            stty -icanon min 0 time 1 2>/dev/null || true
            IFS= read -rsn2 rest 2>/dev/null || true
            [[ -n "$old_stty_state" ]] && stty "$old_stty_state" 2>/dev/null || true
            key="${key}${rest}"
        fi

        local old_cur=$cur
        local old_selected_state="${selected[*]}"

        case "$key" in
            $'\x1b[A'|$'\x1bOA'|k|K)
                cur=$((cur - 1))
                ;;
            $'\x1b[B'|$'\x1bOB'|j|J)
                cur=$((cur + 1))
                ;;
            " ")
                if [[ "$multi" == "true" && $cur -lt $count ]]; then
                    if [[ "${selected[$cur]}" == "true" ]]; then
                        selected[$cur]=false
                    else
                        selected[$cur]=true
                    fi
                elif [[ "$multi" != "true" ]]; then
                    break
                fi
                ;;
            "")
                break
                ;;
            q|Q)
                if [[ "$allow_exit" == "true" ]]; then
                    cur=$count
                    break
                fi
                ;;
            [0-9])
                local num_str="$key"
                local next=""
                local prompt_line=$((rendered_lines + 2))
                printf "\r\033[${prompt_line}A\033[K${YELLOW}跳转至: ${num_str}_${NC}" >&2

                local bash_major="${BASH_VERSION%%.*}"
                if [[ "$bash_major" -ge 4 ]]; then
                    while IFS= read -rsn1 -t 0.4 next 2>/dev/null; do
                        if [[ "$next" =~ [0-9] ]]; then
                            num_str="${num_str}${next}"
                            if [[ $((10#$num_str)) -gt $count ]]; then
                                break
                            fi
                            printf "\r\033[${prompt_line}A\033[K${YELLOW}跳转至: ${num_str}_${NC}" >&2
                        else
                            break
                        fi
                    done
                else
                    local old_tty=""
                    old_tty="$(stty -g 2>/dev/null || echo "")"
                    stty -icanon min 0 time 4 2>/dev/null || true
                    while true; do
                        IFS= read -rsn1 next 2>/dev/null || break
                        [[ -n "$next" ]] || break
                        if [[ "$next" =~ [0-9] ]]; then
                            num_str="${num_str}${next}"
                            if [[ $((10#$num_str)) -gt $count ]]; then
                                break
                            fi
                            printf "\r\033[${prompt_line}A\033[K${YELLOW}跳转至: ${num_str}_${NC}" >&2
                        else
                            break
                        fi
                    done
                    [[ -n "$old_tty" ]] && stty "$old_tty" 2>/dev/null || true
                fi

                printf "\r\033[${prompt_line}A\033[K" >&2
                local num_idx=$((10#$num_str - 1))
                if [[ $num_idx -ge 0 && $num_idx -lt $count ]]; then
                    cur=$num_idx
                fi
                ;;
        esac

        local max_idx=$count
        [[ "$allow_exit" == "true" ]] && max_idx=$((max_idx + 1))
        if [[ $cur -lt 0 ]]; then
            cur=$((max_idx - 1))
        elif [[ $cur -ge $max_idx ]]; then
            cur=0
        fi

        if [[ $cur -ne $old_cur || "$old_selected_state" != "${selected[*]}" ]]; then
            render_java_menu "$rendered_lines" false
            rendered_lines=$?
        fi
    done

    [[ -n "$original_tty_settings" ]] && stty "$original_tty_settings" 2>/dev/null || true
    printf "\033[?25h" >&2

    if [[ "$cur" -eq "$count" && "$allow_exit" == "true" ]]; then
        echo "EXIT"
    else
        local results=()
        for ((i=0; i<count; i++)); do
            [[ "${selected[$i]}" == "true" ]] && results+=("$i")
        done
        results+=("$cur")
        echo "${results[@]}"
    fi
    return 0
}

build_app_menu_options() {
    local first_run="$1"
    shift
    local apps=("$@")
    local preselected=()
    local name script desc priority version status

    APP_MENU_OPTIONS=()
    APP_MENU_INSTALLED=()
    APP_MENU_PRESELECTED=""

    for i in "${!apps[@]}"; do
        IFS=':' read -r name script desc priority <<< "${apps[$i]}"
        version="$(get_software_version "$name" "$script")"

        if [ -n "$version" ]; then
            status="已安装: $version"
            APP_MENU_INSTALLED[$i]=1
            SELECTED_APPS[$i]=0
        else
            status="未安装"
            APP_MENU_INSTALLED[$i]=0
            if [ "$first_run" == "first" ]; then
                if [ "$priority" == "必需" ] || [ "$priority" == "推荐" ]; then
                    SELECTED_APPS[$i]=1
                else
                    SELECTED_APPS[$i]=0
                fi
            fi
            [ "${SELECTED_APPS[$i]:-0}" == "1" ] && preselected+=("$i")
        fi

        APP_MENU_OPTIONS+=("${name} - ${desc} [${priority}] - ${status}")
    done

    APP_MENU_PRESELECTED="${preselected[*]}"
}

# 用户选择软件
select_apps() {
    local apps=("$@")
    local env_name result preselected
    local tokens=()
    local selected_limit idx token

    if [ "$ENV_TYPE" == "dev" ]; then
        env_name="Java开发环境"
    else
        env_name="Java服务器环境"
    fi

    build_app_menu_options "first" "${apps[@]}"
    preselected="$APP_MENU_PRESELECTED"

    if [ ! -t 0 ]; then
        echo -e "${YELLOW}[WARN] 非交互终端，使用默认推荐选择${NC}"
        return 0
    fi

    result="$(java_menu_select "${env_name}软件选择" true false "$preselected" "${APP_MENU_OPTIONS[@]}")"
    if [ "$result" == "EXIT" ] || [ -z "$result" ]; then
        return 1
    fi

    for i in "${!apps[@]}"; do
        SELECTED_APPS[$i]=0
    done

    # java_menu_select 的多选结果格式: 已选择索引列表 + 当前光标索引。
    # 最后一项只表示光标位置，不代表选择状态。
    read -r -a tokens <<< "$result"
    selected_limit=$((${#tokens[@]} - 1))
    for ((i=0; i<selected_limit; i++)); do
        token="${tokens[$i]}"
        [[ "$token" =~ ^[0-9]+$ ]] || continue
        idx=$((10#$token))
        [[ "$idx" -ge 0 && "$idx" -lt "${#apps[@]}" ]] || continue
        if [ "$UNINSTALL_MODE" == "true" ]; then
            if [ "${APP_MENU_INSTALLED[$idx]:-0}" == "1" ]; then
                SELECTED_APPS[$idx]=1
            fi
        else
            if [ "${APP_MENU_INSTALLED[$idx]:-0}" == "0" ]; then
                SELECTED_APPS[$idx]=1
            fi
        fi
    done

    return 0
}

apply_app_dependencies() {
    local apps=("$@")
    local nacos_idx=-1
    local mysql_idx=-1
    local name script desc priority

    for i in "${!apps[@]}"; do
        IFS=':' read -r name script desc priority <<< "${apps[$i]}"
        case "$name" in
            "Nacos") nacos_idx="$i" ;;
            "MySQL") mysql_idx="$i" ;;
        esac
    done

    if [ "$nacos_idx" -ge 0 ] && [ "${SELECTED_APPS[$nacos_idx]}" == "1" ] && [ "$mysql_idx" -ge 0 ]; then
        IFS=':' read -r name script desc priority <<< "${apps[$mysql_idx]}"
        if [ "${SELECTED_APPS[$mysql_idx]}" != "1" ] && ! check_installed "$name" "$script"; then
            SELECTED_APPS[$mysql_idx]=1
            echo -e "${YELLOW}[WARN] Nacos 依赖 MySQL，已自动将 MySQL 加入安装队列并前置安装${NC}"
        fi
    fi
}

# 安装软件
install_apps() {
    local apps=("$@")
    local success_count=0
    local fail_count=0
    local skip_count=0

    # 获取脚本所在目录（java-env-setup.sh 所在的目录）
    local script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

    echo -e "${GREEN}=== 开始安装软件 ===${NC}"
    echo ""

    # JDK 版本询问（仅当 JDK 被选中时）
    local jdk_version="$JDK_VERSION_ARG"
    if [ -z "$jdk_version" ]; then
        for i in "${!apps[@]}"; do
            if [ "${SELECTED_APPS[$i]}" == "1" ]; then
                IFS=':' read -r name script desc priority <<< "${apps[$i]}"
                if [ "$name" == "JDK" ]; then
                    if [ "$AUTO_INSTALL" == "true" ] || [ -n "$APPS_LIST" ]; then
                        jdk_version="21"
                        echo -e "${YELLOW}非交互模式，默认选择JDK版本: $jdk_version${NC}"
                    else
                        echo -e "${BLUE}请选择要安装的JDK版本 (支持: 7 8 11 17 19 21)${NC}"
                        echo -e "${YELLOW}默认: 21 (30秒后自动选择)${NC}"
                        read -t 30 -p "请输入版本号: " jdk_version
                        if [ -z "$jdk_version" ]; then
                            jdk_version="21"
                            echo ""
                            echo "超时，使用默认版本: $jdk_version"
                        fi
                    fi
                    break
                fi
            fi
        done
    fi

    for i in "${!apps[@]}"; do
        if [ "${SELECTED_APPS[$i]}" == "1" ]; then
            IFS=':' read -r name script desc priority <<< "${apps[$i]}"

            echo -e "${BLUE}正在安装: $name${NC}"
            echo "  描述: $desc"
            echo "  优先级: $priority"
            echo "  脚本: $script"

            # 检查脚本是否存在（相对于 script_dir）
            local script_path="$script_dir/$script"
            if [ ! -f "$script_path" ]; then
                echo -e "${RED}  ✗ 脚本不存在: $script_path${NC}"
                fail_count=$((fail_count+1))
                continue
            fi

            # 检查脚本是否可执行
            if [ ! -x "$script_path" ]; then
                chmod +x "$script_path"
            fi

            # 执行安装脚本
            local install_cmd="bash \"$script_path\""
            local install_child=""
            local app_install_dir=""
            install_child="$(get_install_child_name "$name")"
            if [ -n "$install_child" ]; then
                app_install_dir="$(normalize_install_dir "$INSTALL_PARENT_DIR" "$install_child")"
                echo "  安装目录: $app_install_dir"
            fi

            # JDK 需要传递版本号
            if [ "$name" == "JDK" ] && [ -n "$jdk_version" ]; then
                install_cmd="bash \"$script_path\" -v $jdk_version"
                echo "  版本: $jdk_version"
            fi

            case "$name" in
                "Nacos")
                    if [ -n "$app_install_dir" ]; then
                        install_cmd="$install_cmd -d \"$app_install_dir\""
                    fi
                    if [ "$AUTO_START" == "true" ]; then
                        install_cmd="$install_cmd --auto-start"
                    fi
                    if [ "$NACOS_CLUSTER" == "true" ]; then
                        install_cmd="$install_cmd --cluster"
                    fi
                    ;;
                "Jenkins")
                    if [ -n "$app_install_dir" ]; then
                        install_cmd="$install_cmd -d \"$app_install_dir\""
                    fi
                    if [ "$AUTO_START" == "true" ]; then
                        install_cmd="$install_cmd --auto-start"
                    fi
                    if [ -n "$APPS_LIST" ] || [ "$AUTO_INSTALL" == "true" ]; then
                        install_cmd="$install_cmd --auto"
                    fi
                    ;;
                "Spug")
                    if [ -n "$app_install_dir" ]; then
                        install_cmd="$install_cmd -d \"$app_install_dir\""
                    fi
                    if [ "$AUTO_START" == "true" ]; then
                        install_cmd="$install_cmd --auto-start"
                    fi
                    ;;
                "JDK"|"Maven"|"Gradle"|"Arthas"|"mvnd"|"Prometheus"|"Grafana"|"Sentinel"|"Seata"|"XXL-Job"|"ZooKeeper"|"Nexus"|"Kafka"|"SonarQube"|"Dubbo Admin"|"Dependency Track"|"ELK"|"MinIO")
                    if [ -n "$app_install_dir" ]; then
                        install_cmd="$install_cmd -d \"$app_install_dir\""
                    fi
                    # ELK 主机模式有交互确认，批量安装时自动跳过
                    if [ "$name" == "ELK" ]; then
                        install_cmd="$install_cmd -y"
                    fi
                    ;;
                "Nginx")
                    if [ -n "$app_install_dir" ]; then
                        install_cmd="$install_cmd --dir \"$app_install_dir\""
                    fi
                    ;;
                "MySQL")
                    if [ -n "$app_install_dir" ]; then
                        install_cmd="$install_cmd --install-dir=\"$app_install_dir\""
                    fi
                    ;;
                "Redis")
                    if [ -n "$app_install_dir" ]; then
                        install_cmd="$install_cmd \"$app_install_dir\""
                    fi
                    ;;
                "ActiveMQ")
                    if [ -n "$app_install_dir" ]; then
                        install_cmd="$install_cmd -d \"$app_install_dir\""
                    fi
                    ;;
            esac

            if eval "$install_cmd" 2>&1; then
                echo -e "${GREEN}  ✓ $name 安装成功${NC}"
                success_count=$((success_count+1))
                INSTALLED_APPS+=("$name")
                update_cached_version "$name" "已安装"
            else
                echo -e "${RED}  ✗ $name 安装失败${NC}"
                fail_count=$((fail_count+1))
                update_cached_version "$name" "FAILED"
            fi

            echo ""
        else
            skip_count=$((skip_count+1))
        fi
    done

    # 显示安装结果
    echo -e "${GREEN}=== 安装完成 ===${NC}"
    echo ""
    echo "  成功: $success_count 个"
    echo "  失败: $fail_count 个"
    echo "  跳过: $skip_count 个"
    echo ""

    if [ $success_count -gt 0 ]; then
        echo -e "${GREEN}已安装的软件:${NC}"
        for app in "${INSTALLED_APPS[@]}"; do
            echo "  - $app"
        done
        echo ""
    fi

    if [ $fail_count -gt 0 ]; then
        echo -e "${RED}安装失败的软件，请查看日志并手动重试${NC}"
        echo ""
    fi
}

# 卸载软件
uninstall_apps() {
    local apps=("$@")
    local success_count=0
    local fail_count=0
    local skip_count=0

    # 获取脚本所在目录（java-env-setup.sh 所在的目录）
    local script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

    echo -e "${GREEN}=== 开始卸载软件 ===${NC}"
    echo ""

    for i in "${!apps[@]}"; do
        if [ "${SELECTED_APPS[$i]}" == "1" ]; then
            IFS=':' read -r name script desc priority <<< "${apps[$i]}"

            echo -e "${BLUE}正在卸载: $name${NC}"
            echo "  描述: $desc"

            local script_path="$script_dir/$script"
            local uninstall_script_path="$(dirname "$script_path")/uninstall-$(basename "$script_path" | sed 's/install-//')"
            local uninstall_cmd=""

            # 特殊处理各软件卸载脚本路径
            case "$name" in
                "JDK")
                    uninstall_script_path="$script_dir/jdk/uninstall-jdk.sh"
                    # uninstall-jdk.sh 不支持 --uninstall，用 -d 指定目录
                    uninstall_cmd="bash \"$uninstall_script_path\""
                    ;;
                "Maven")
                    # maven.sh 不符合 install-xxx.sh 命名，手动指向
                    uninstall_script_path=""
                    uninstall_cmd="bash \"$script_path\" --uninstall"
                    ;;
                "MySQL")
                    # install.sh 不支持 --uninstall，指向同目录的 uninstall.sh
                    uninstall_script_path="$(dirname "$script_path")/uninstall.sh"
                    ;;
            esac

            if [ -n "$uninstall_cmd" ]; then
                : # 已设置命令
            elif [ -f "$uninstall_script_path" ]; then
                uninstall_cmd="bash \"$uninstall_script_path\""
            elif [ -f "$script_path" ]; then
                uninstall_cmd="bash \"$script_path\" --uninstall"
            else
                echo -e "${RED}  ✗ 找不到卸载脚本或原安装脚本: $script_path${NC}"
                fail_count=$((fail_count+1))
                continue
            fi

            # 传递安装目录参数（用于精准卸载）
            local install_child=""
            local app_install_dir=""
            install_child="$(get_install_child_name "$name")"
            if [ -n "$install_child" ]; then
                app_install_dir="$(normalize_install_dir "$INSTALL_PARENT_DIR" "$install_child")"
            fi

            if [ -n "$app_install_dir" ]; then
                case "$name" in
                    "JDK")
                        # uninstall-jdk.sh 用 -d 指定安装根目录
                        uninstall_cmd="$uninstall_cmd -d \"$app_install_dir\""
                        ;;
                    "MySQL")
                        # uninstall.sh 有交互确认，通过管道传入 Y
                        uninstall_cmd="echo Y | $uninstall_cmd \"$app_install_dir\""
                        ;;
                    "Maven"|"Gradle"|"Arthas"|"mvnd")
                        uninstall_cmd="$uninstall_cmd -d \"$app_install_dir\""
                        ;;
                esac
            fi

            if eval "$uninstall_cmd" 2>&1; then
                echo -e "${GREEN}  ✓ $name 卸载成功${NC}"
                success_count=$((success_count+1))
                update_cached_version "$name" "FAILED"
            else
                echo -e "${RED}  ✗ $name 卸载失败${NC}"
                fail_count=$((fail_count+1))
            fi

            echo ""
        else
            skip_count=$((skip_count+1))
        fi
    done

    # 显示卸载结果
    echo -e "${GREEN}=== 卸载完成 ===${NC}"
    echo ""
    echo "  成功: $success_count 个"
    echo "  失败: $fail_count 个"
    echo "  跳过: $skip_count 个"
    echo ""
}

# 卸载后清理 .bashrc/.zshrc 中的环境变量
cleanup_env_vars_after_uninstall() {
    local rc_file
    rc_file="$(get_shell_config_file)"
    [ -f "$rc_file" ] || return 0

    echo -e "${BLUE}[INFO] 清理 shell 配置文件中的环境变量: $rc_file${NC}"

    # 需要清理的环境变量 key
    local env_keys=(
        JAVA_HOME MAVEN_HOME GRADLE_HOME MVND_HOME ARTHAS_HOME
        MYSQL_HOME REDIS_HOME ROCKETMQ_HOME
    )

    local envs_cmd
    if envs_cmd="$(find_envs_cmd 2>/dev/null)"; then
        for key in "${env_keys[@]}"; do
            "$envs_cmd" remove "$key" "$rc_file" >/dev/null 2>&1 || true
        done
        # dedup 清理 PATH 中的残留引用
        "$envs_cmd" dedup "$rc_file" >/dev/null 2>&1 || true
    else
        # 无 envs: 使用 sed 删除 export XXX_HOME= 行
        for key in "${env_keys[@]}"; do
            local escaped_key
            escaped_key="$(printf '%s' "$key" | sed 's/[][\.*^$(){}?+|/]/\\&/g')"
            if [[ "$(uname)" == "Darwin" ]]; then
                sed -i '' "/^[[:space:]]*export[[:space:]]*${escaped_key}=/d" "$rc_file"
            else
                sed -i "/^[[:space:]]*export[[:space:]]*${escaped_key}=/d" "$rc_file"
            fi
        done
        # 清理 PATH 行中形如 $XXX_HOME/bin 的残留引用
        cleanup_path_var_refs "$rc_file"
    fi

    echo -e "${GREEN}[OK] 环境变量清理完成${NC}"
}

# 清理 PATH 行中失效的 $XXX_HOME 引用和已不存在的目录
cleanup_path_var_refs() {
    local rc_file="$1"
    [ -f "$rc_file" ] || return 0

    local tmp
    tmp="$(mktemp)"

    # 只处理顶层的 export PATH= 行（行首无缩进），避免破坏 if/then 块内的 PATH 设置
    awk '
        /^export[[:space:]]+PATH=/ {
            line = $0
            # 提取 value 部分
            idx = index(line, "=")
            value = substr(line, idx + 1)
            # 去引号
            gsub(/^["\x27]/, "", value)
            gsub(/["\x27]$/, "", value)

            # 拆分冒号，过滤掉 $XXX_HOME 引用和不存在目录
            n = split(value, parts, ":")
            new_value = ""
            for (i = 1; i <= n; i++) {
                p = parts[i]
                # 跳过空
                if (p == "") continue
                # 跳过 $XXX_HOME 或 $XXX_HOME/xxx 形式的引用
                if (p ~ /^\$\{?[A-Za-z_][A-Za-z0-9_]*\}?/) continue
                # 跳过 $PATH 引用（保留）
                if (p == "$PATH") { new_value = (new_value == "" ? "$PATH" : new_value ":$PATH"); continue }
                # 跳过不存在的目录
                if (system("test -d " p) != 0) continue
                new_value = (new_value == "" ? p : new_value ":" p)
            }
            if (new_value == "") new_value = "$PATH"
            print "export PATH=\"" new_value "\""
            next
        }
        { print }
    ' "$rc_file" > "$tmp" && mv "$tmp" "$rc_file"
}

# 显示安装后建议
show_post_install_suggestions() {
    local env_name=""

    if [ "$ENV_TYPE" == "dev" ]; then
        env_name="开发"
    else
        env_name="服务器"
    fi

    echo -e "${YELLOW}=== ${env_name}环境配置建议 ===${NC}"
    echo ""

    if [ "$ENV_TYPE" == "dev" ]; then
        cat << 'EOF'
1. 配置环境变量
   - 将JAVA_HOME添加到PATH
   - 配置Maven的settings.xml（本地仓库、镜像源）

2. 配置Git
   - 设置用户名和邮箱: git config --global user.name "Your Name"
   - 生成SSH密钥: ssh-keygen -t rsa -C "your_email@example.com"

3. IDE配置
   - 安装IntelliJ IDEA或Eclipse
   - 配置JDK和Maven路径
   - 安装常用插件（Lombok、MyBatis等）

4. 开发工具
   - 配置Arthas用于线上问题诊断
   - 安装Postman或Swagger UI用于API测试

EOF
    else
        cat << 'EOF'
1. 配置JVM参数
   - 根据服务器内存调整JVM参数
   - 配置GC策略（如G1GC）

2. 配置中间件
   - 根据实际需要配置ZooKeeper集群
   - 配置Nacos作为配置中心
   - 配置Sentinel进行流量控制

3. 监控配置
   - 配置应用监控（如Prometheus + Grafana）
   - 配置日志收集（如ELK）

4. 安全配置
   - 配置防火墙规则
   - 限制Arthas访问权限
   - 配置HTTPS证书

EOF
    fi

    echo -e "${CYAN}查看详细配置说明: 查看各软件目录下的README.md${NC}"
    echo ""
}

# 主函数
main() {
    # 解析参数
    parse_args "$@"

    prepare_environment_tools

    # 卸载模式: 跳过环境变量配置，避免把即将卸载的路径重新写入
    [ "$UNINSTALL_MODE" == "true" ] || configure_java_tool_envs

    # 如果没有指定环境类型，且没有指定APPS_LIST，交互式选择
    # --uninstall-all 模式下自动合并所有 apps，无需选择环境类型
    if [ -z "$ENV_TYPE" ] && [ -z "$APPS_LIST" ] && [ "$UNINSTALL_ALL" != "true" ]; then
        echo -e "${YELLOW}请选择环境类型:${NC}"
        echo "  1) Java开发环境"
        echo "  2) Java服务器环境"
        echo ""

        while true; do
            read -p "请输入选择 (1-2): " env_choice
            case $env_choice in
                1)
                    ENV_TYPE="dev"
                    break
                    ;;
                2)
                    ENV_TYPE="server"
                    break
                    ;;
                *)
                    echo -e "${RED}无效选择，请重新输入${NC}"
                    ;;
            esac
        done
        echo ""
    fi

    # 显示环境类型
    if [ "$ENV_TYPE" == "dev" ]; then
        echo -e "${GREEN}环境类型: Java开发环境${NC}"
        apps=("${DEV_APPS[@]}")

        # 检测是否有图形桌面，如果有则添加IDE推荐
        if has_graphical_desktop; then
            echo -e "${CYAN}检测到图形桌面环境${NC}"
            apps=("${apps[@]}" "${IDE_APPS[@]}")
        fi
    elif [ "$ENV_TYPE" == "server" ]; then
        echo -e "${GREEN}环境类型: Java服务器环境${NC}"
        apps=("${SERVER_APPS[@]}")
    elif [ "$UNINSTALL_ALL" == "true" ]; then
        echo -e "${GREEN}批量卸载模式: 合并所有软件列表${NC}"
        local seen_names=","
        apps=()
        for app in "${DEV_APPS[@]}" "${SERVER_APPS[@]}" "${IDE_APPS[@]}"; do
            IFS=':' read -r name script desc priority <<< "$app"
            if [[ "$seen_names" != *",$name,"* ]]; then
                seen_names="$seen_names$name,"
                apps+=("$app")
            fi
        done
    else
        echo -e "${GREEN}环境类型: 自定义环境${NC}"
        # 合并所有可用的app，去重
        local seen_names=","
        apps=()
        for app in "${DEV_APPS[@]}" "${SERVER_APPS[@]}" "${IDE_APPS[@]}"; do
            IFS=':' read -r name script desc priority <<< "$app"
            if [[ "$seen_names" != *",$name,"* ]]; then
                seen_names="$seen_names$name,"
                apps+=("$app")
            fi
        done
    fi
    echo ""

    # 如果不是自动安装模式，让用户选择（select_apps内部会显示软件列表）
    if [ -n "$APPS_LIST" ]; then
        echo -e "${BLUE}通过参数指定操作以下软件: $APPS_LIST${NC}"
        IFS=',' read -r -a specified_apps <<< "$APPS_LIST"

        # 先清空所有的默认选择
        for i in "${!apps[@]}"; do
            SELECTED_APPS[$i]=0
        done

        # 匹配指定的软件名称
        for target in "${specified_apps[@]}"; do
            # 移除前后空格
            target="$(echo "$target" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
            local matched=false
            for i in "${!apps[@]}"; do
                IFS=':' read -r name script desc priority <<< "${apps[$i]}"
                # 不区分大小写匹配
                if [ "$(echo "$name" | tr '[:upper:]' '[:lower:]')" == "$(echo "$target" | tr '[:upper:]' '[:lower:]')" ]; then
                    SELECTED_APPS[$i]=1
                    matched=true
                    break
                fi
            done
            if [ "$matched" == "false" ]; then
                echo -e "${YELLOW}[WARN] 未找到指定的软件: $target${NC}"
            fi
        done
    elif [ "$UNINSTALL_ALL" == "true" ]; then
        # 批量卸载模式: 合并所有 apps，自动选中已安装的
        echo -e "${YELLOW}批量卸载模式: 自动检测已安装软件${NC}"
        for i in "${!apps[@]}"; do
            SELECTED_APPS[$i]=0
        done
        for i in "${!apps[@]}"; do
            IFS=':' read -r name script desc priority <<< "${apps[$i]}"
            if check_installed "$name" "$script"; then
                SELECTED_APPS[$i]=1
            fi
        done
    elif [ "$AUTO_INSTALL" == false ]; then
        select_apps "${apps[@]}"
    else
        # 自动安装模式，先显示软件列表，然后自动选择
        show_app_selection "first" "${apps[@]}"
        echo -e "${YELLOW}自动安装模式: 将安装所有推荐软件${NC}"
        echo ""

        # 自动选择所有未安装的软件
        for i in "${!apps[@]}"; do
            IFS=':' read -r name script desc priority <<< "${apps[$i]}"
            if ! check_installed "$name" "$script"; then
                if [ "$priority" == "必需" ] || [ "$priority" == "推荐" ]; then
                    SELECTED_APPS[$i]=1
                fi
            fi
        done
    fi

    apply_app_dependencies "${apps[@]}"

    # 显示确认信息
    if [ "$UNINSTALL_MODE" == "true" ]; then
        echo -e "${YELLOW}=== 即将卸载以下软件 ===${NC}"
    else
        echo -e "${YELLOW}=== 即将安装以下软件 ===${NC}"
    fi

    # 按数组顺序显示（已按优先级定义）
    for i in "${!apps[@]}"; do
        if [ "${SELECTED_APPS[$i]}" == "1" ]; then
            IFS=':' read -r name script desc priority <<< "${apps[$i]}"
            echo "  - $name ($desc)"
        fi
    done
    echo ""

    # 如果没有选择任何软件
    local has_selected=false
    for i in "${!apps[@]}"; do
        if [ "${SELECTED_APPS[$i]}" == "1" ]; then
            has_selected=true
            break
        fi
    done

    if [ "$has_selected" == "false" ]; then
        if [ "$UNINSTALL_MODE" == "true" ]; then
            echo -e "${YELLOW}没有选择任何软件，已取消卸载${NC}"
        else
            echo -e "${YELLOW}没有选择任何软件，已取消安装${NC}"
        fi
        exit 0
    fi

    echo ""

    if [ "$UNINSTALL_MODE" == "true" ]; then
        # 执行卸载
        uninstall_apps "${apps[@]}"

        # 卸载后清理 .bashrc 中的环境变量
        cleanup_env_vars_after_uninstall
    else
        # 执行安装
        install_apps "${apps[@]}"

        # 已安装但未加载到 PATH 的工具也在这里统一补齐。
        configure_java_tool_envs

        # 显示配置建议
        show_post_install_suggestions
    fi

    echo -e "${GREEN}=== 操作完成！ ===${NC}"
}

# 执行主函数
main "$@"
