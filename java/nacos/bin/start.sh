#!/bin/bash

# Nacos 启动脚本 - 自动修复 cgroup 问题
# 确保基本命令可用
export PATH="/usr/local/bin:/usr/bin:/bin:/usr/local/sbin:/usr/sbin:/sbin"

# 获取脚本所在目录
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NACOS_HOME="$(dirname "$SCRIPT_DIR")"

# 配置参数
STARTUP_SH="$SCRIPT_DIR/startup.sh"
LOG_DIR="$NACOS_HOME/logs"
STARTUP_LOG="$LOG_DIR/nacos_startup.log"
TAIL_LINES=50
RESET_DERBY=false

for arg in "$@"; do
    case "$arg" in
        --reset-derby)
            RESET_DERBY=true
            ;;
        -h|--help)
            echo "用法: ./start.sh [--reset-derby]"
            echo "  --reset-derby  备份并重建本地 Derby 数据库（会清空本地 Nacos 配置数据）"
            exit 0
            ;;
    esac
done

require_cmd() {
    local cmd="$1"
    local path
    path=$(command -v "$cmd" 2>/dev/null || true)
    if [ -z "$path" ]; then
        echo "错误: 未找到必需命令: $cmd" >&2
        exit 1
    fi
    printf '%s\n' "$path"
}

CP_CMD=$(require_cmd cp)
GREP_CMD=$(require_cmd grep)
SED_CMD=$(require_cmd sed)
AWK_CMD=$(require_cmd awk)
MV_CMD=$(require_cmd mv)

print_startup_error() {
    echo -e "${C_RED}✗ Nacos 启动失败${C_NC}"
    echo -e "${C_YELLOW}日志: $STARTUP_LOG${C_NC}"
    local derby_schema_error=false
    for log_file in \
        "$STARTUP_LOG" \
        "$NACOS_HOME/logs/startup.log" \
        "$NACOS_HOME/logs/nacos.log" \
        "$NACOS_HOME/logs/nacos-persistence.log" \
        "$NACOS_HOME/logs/config-fatal.log"; do
        [ -f "$log_file" ] || continue
        "$GREP_CMD" -E "Unrecognized VM option|ERROR|Error:|Exception|Caused by|FAILED|failed|db-error" "$log_file" | tail -5 || true
        if "$GREP_CMD" -q "CONFIG_INFO_BETA.*does not exist\\|config_info_beta.*does not exist" "$log_file" 2>/dev/null; then
            derby_schema_error=true
        fi
    done
    if [ "$derby_schema_error" = true ]; then
        echo -e "${C_YELLOW}提示: 本地 Derby 表结构不完整，可执行: ./start.sh --reset-derby${C_NC}"
    fi
}

find_nacos_pid() {
    pgrep -f "nacos-server.jar.*-Dnacos.home=${NACOS_HOME}" 2>/dev/null || true
}

nacos_ready() {
    if command -v curl >/dev/null 2>&1; then
        curl -fsS --max-time 2 "http://127.0.0.1:8848/nacos/actuator/health" | "$GREP_CMD" -q '"status":"UP"' && return 0
        curl -fsS --max-time 2 "http://127.0.0.1:8848/nacos/v1/console/health/readiness" >/dev/null 2>&1 && return 0
    fi
    return 1
}

get_config_value() {
    local config_file="$1"
    local key="$2"

    [ -f "$config_file" ] || return 1
    "$AWK_CMD" -F= -v key="$key" '
        {
            line = $0
            sub(/^[[:space:]]*#[[:space:]]*/, "", line)
            split(line, parts, "=")
            prop = parts[1]
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", prop)
            if (prop == key) {
                sub(/^[^=]*=/, "", line)
                print line
                exit
            }
        }
    ' "$config_file"
}

check_mysql_config() {
    local conf_file="$NACOS_HOME/conf/application.properties"
    local platform db_url db_user db_password host_port host port

    [ -f "$conf_file" ] || return 0
    platform="$(get_config_value "$conf_file" "spring.sql.init.platform")"
    [ -n "$platform" ] || platform="$(get_config_value "$conf_file" "spring.datasource.platform")"
    [ "$platform" = "mysql" ] || return 0

    db_url="$(get_config_value "$conf_file" "db.url.0")"
    db_user="$(get_config_value "$conf_file" "db.user.0")"
    db_password="$(get_config_value "$conf_file" "db.password.0")"
    host_port="$(printf '%s\n' "$db_url" | "$SED_CMD" -E 's|.*jdbc:mysql://([^/?]+).*|\1|')"
    host="${host_port%%:*}"
    port="${host_port##*:}"
    [ "$host" != "$port" ] || port="3306"

    if [ -z "$db_url" ] || [ -z "$host" ] || [ -z "$port" ]; then
        echo -e "${C_RED}错误: MySQL 配置不完整，请检查 $conf_file${C_NC}"
        exit 1
    fi

    if command -v nc >/dev/null 2>&1 && ! nc -z "$host" "$port" >/dev/null 2>&1; then
        echo -e "${C_RED}错误: MySQL 不可达: $host:$port${C_NC}"
        echo -e "${C_YELLOW}请检查 db.url.0 或启动对应 MySQL 服务。${C_NC}"
        exit 1
    fi

    if command -v mysql >/dev/null 2>&1 && [ -n "$db_user" ]; then
        if ! MYSQL_PWD="$db_password" mysql --protocol=tcp -h "$host" -P "$port" -u "$db_user" -e "SELECT 1;" >/dev/null 2>&1; then
            echo -e "${C_RED}错误: MySQL 账号或密码不可用: $db_user@$host:$port${C_NC}"
            echo -e "${C_YELLOW}请检查 db.user.0/db.password.0，或用安装脚本重新写入正确 MySQL 参数。${C_NC}"
            exit 1
        fi
    fi
}

reset_derby_data() {
    local derby_dir="$NACOS_HOME/data/derby-data"
    local backup_dir
    [ -d "$derby_dir" ] || return 0
    backup_dir="${derby_dir}.bak.$(date +%Y%m%d_%H%M%S)"
    echo -e "${C_YELLOW}备份并重建 Derby 数据库: $backup_dir${C_NC}"
    "$MV_CMD" "$derby_dir" "$backup_dir" || {
        echo -e "${C_RED}错误: 无法备份 Derby 数据目录${C_NC}"
        exit 1
    }
}

# 颜色定义
C_RED='\033[0;31m'
C_GREEN='\033[0;32m'
C_YELLOW='\033[1;33m'
C_BLUE='\033[0;34m'
C_NC='\033[0m'

echo -e "${C_BLUE}=== Nacos 启动脚本 ===${C_NC}"
echo -e "${C_BLUE}Nacos Home: $NACOS_HOME${C_NC}"

# 检查 startup.sh 是否存在
if [ ! -f "$STARTUP_SH" ]; then
    echo -e "${C_RED}错误: $STARTUP_SH 不存在${C_NC}"
    exit 1
fi

# 检查 startup.sh 是否可执行
if [ ! -x "$STARTUP_SH" ]; then
    echo -e "${C_YELLOW}警告: $STARTUP_SH 不可执行，正在添加执行权限...${C_NC}"
    chmod +x "$STARTUP_SH" || {
        echo -e "${C_RED}错误: 无法添加执行权限${C_NC}"
        exit 1
    }
    echo -e "${C_GREEN}✓ 已添加执行权限${C_NC}"
fi

# 确保日志目录存在
if [ ! -d "$LOG_DIR" ]; then
    echo -e "${C_YELLOW}日志目录不存在，正在创建: $LOG_DIR${C_NC}"
    mkdir -p "$LOG_DIR" || {
        echo -e "${C_RED}错误: 无法创建日志目录${C_NC}"
        exit 1
    }
    echo -e "${C_GREEN}✓ 日志目录已创建${C_NC}"
fi

# 检测 Java 版本
JAVA_CMD=$(command -v java)
if [ -z "$JAVA_CMD" ]; then
    echo -e "${C_RED}错误: 未找到 Java 命令${C_NC}"
    exit 1
fi

JAVA_VERSION=$("$JAVA_CMD" -version 2>&1 | head -n 1 | cut -d'"' -f2)
JAVA_MAJOR_VERSION=$(echo "$JAVA_VERSION" | cut -d'.' -f1)
echo -e "${C_BLUE}Java: $JAVA_VERSION${C_NC}"

# 检查是否需要添加 cgroup 参数（仅 Java 11+ 需要）
NEED_CGROUP_PARAM=false
if [ "$JAVA_MAJOR_VERSION" -ge 11 ]; then
    NEED_CGROUP_PARAM=true
else
    echo -e "${C_YELLOW}⚠ Java 版本 < 11，Nacos 3.x 建议使用 Java 17+${C_NC}"
fi

# 检查是否已经包含 Java 17+ 兼容性参数
if "$GREP_CMD" -q "add-opens java.base/jdk.internal.platform" "$STARTUP_SH" 2>/dev/null; then
    echo -e "${C_GREEN}✓ startup.sh 已包含 Java 兼容性参数${C_NC}"
elif [ "$NEED_CGROUP_PARAM" = true ]; then
    echo -e "${C_YELLOW}⚠ 添加 Java 兼容性参数...${C_NC}"

    # 备份原文件（带时间戳）
    BACKUP_FILE="${STARTUP_SH}.bak.$(date +%Y%m%d_%H%M%S)"
    "$CP_CMD" "$STARTUP_SH" "$BACKUP_FILE" || {
        echo -e "${C_RED}错误: 无法创建备份文件${C_NC}"
        exit 1
    }

    # 在第3行添加 Java 17 容器兼容性参数
    TMP_STARTUP="${STARTUP_SH}.tmp.$$"
    "$AWK_CMD" '
        NR == 3 {
            print
            print ""
            print "# 添加解决 Java 17+ 模块访问兼容性问题的 JVM 参数"
            print "JAVA_OPT=\"${JAVA_OPT} --add-opens java.base/jdk.internal.platform=ALL-UNNAMED\""
            next
        }
        { print }
    ' "$STARTUP_SH" > "$TMP_STARTUP" && "$MV_CMD" "$TMP_STARTUP" "$STARTUP_SH" || {
        rm -f "$TMP_STARTUP"
        echo -e "${C_RED}错误: 无法修改 startup.sh${C_NC}"
        exit 1
    }
    chmod +x "$STARTUP_SH"
    echo -e "${C_GREEN}✓ 已添加 Java 兼容性参数${C_NC}"
fi

# 自动检测并设置 JAVA_HOME
if [ -z "$JAVA_HOME" ]; then
    # 尝试从 java 命令路径推断 JAVA_HOME
    JAVA_CMD_PATH=$(command -v java 2>/dev/null)
    if [ -n "$JAVA_CMD_PATH" ]; then
        # 如果 java 在 /opt/jdk/.../bin/java，提取 JAVA_HOME
        if [[ "$JAVA_CMD_PATH" == /opt/jdk/* ]]; then
            export JAVA_HOME=$(echo "$JAVA_CMD_PATH" | "$SED_CMD" 's|/bin/java$||')
            echo -e "${C_BLUE}✓ 自动设置 JAVA_HOME: $JAVA_HOME${C_NC}"
        fi
    fi
fi

# 确保 java 命令在 PATH 中
if [ -n "$JAVA_HOME" ] && [ -x "$JAVA_HOME/bin/java" ]; then
    export PATH="$JAVA_HOME/bin:$PATH"
fi

if [ "$RESET_DERBY" = true ]; then
    reset_derby_data
fi

check_mysql_config

# 停止当前安装目录下已运行的 Nacos，避免误杀其他 Nacos 实例。
PIDS=$(find_nacos_pid)
if [ -n "$PIDS" ]; then
    echo -e "${C_YELLOW}停止旧 Nacos 进程: $PIDS${C_NC}"
    kill $PIDS || {
        echo -e "${C_RED}警告: 停止进程失败，将继续尝试启动${C_NC}"
    }
    sleep 2
    # 再次检查是否停止成功
    REMAINING=$(find_nacos_pid)
    if [ -n "$REMAINING" ]; then
        echo -e "${C_YELLOW}警告: 部分进程仍在运行: $REMAINING${C_NC}"
    else
        echo -e "${C_GREEN}✓ 所有 Nacos 进程已停止${C_NC}"
    fi
fi

# 启动 Nacos
echo -e "${C_BLUE}启动 Nacos...${C_NC}"
"$STARTUP_SH" -m standalone > "$STARTUP_LOG" 2>&1 || {
    print_startup_error
    exit 1
}

# 检查真实 Nacos Java 进程和 HTTP 端口。startup.sh 自身会很快退出，不能用包装脚本 PID 判断。
NACOS_PID=""
SEEN_PID=false
for _ in $(seq 1 60); do
    NACOS_PID=$(find_nacos_pid | head -1)
    if [ -n "$NACOS_PID" ]; then
        SEEN_PID=true
        if nacos_ready; then
            break
        fi
    elif [ "$SEEN_PID" = true ]; then
        print_startup_error
        exit 1
    fi
    sleep 1
done
if [ -z "$NACOS_PID" ] || ! nacos_ready; then
    print_startup_error
    exit 1
fi

echo -e "${C_GREEN}✓ Nacos 已启动 (PID: $NACOS_PID)${C_NC}"
echo -e "${C_BLUE}控制台: http://localhost:8848/nacos${C_NC}"
echo -e "${C_BLUE}日志: $NACOS_HOME/logs/startup.log${C_NC}"
