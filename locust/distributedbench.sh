#!/bin/bash

# 增强健壮性：遇到错误立即退出、未定义变量报错、管道失败报错
set -euo pipefail

# 获取脚本所在目录
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 获取当前 shell 进程组 ID，用于清理所有子进程
MAIN_PID=$$

# ==============================================================================
# 1. 核心安全边界配置 (Global Constants)
# ==============================================================================
readonly MIN_USERS=1                # 最少 1 个用户
readonly MAX_USERS_DEFAULT=50000    # 单机/集群安全上限 5万
readonly MIN_DURATION=10            # 最短压测 10 秒
readonly MAX_DURATION=3600          # 最长压测 1 小时
readonly MIN_RATE=1                 # 最慢爬坡 1/s
readonly MAX_RATE=500               # 最快爬坡 500/s
readonly MIN_MULT=1.1               # 最小递进倍率 1.1x
readonly MAX_MULT=5.0               # 最大递进倍率 5.0x
readonly MIN_MEM_CRITICAL=50         # 内存低于 50MB 强制退出 (极端情况)
readonly MIN_MEM_WARN=1024          # 内存低于 1GB 发出警告 (发出建议提示)

# ==============================================================================
# 2. 基础路径与默认值
# ==============================================================================
VENV_PATH="$HOME/.locust-env"
VENV_PYTHON="$VENV_PATH/bin/python3"
BASE_REPORT_DIR="$HOME/locust_reports"  # 报告目录改到用户主目录
SESSION_ID=$(date +%Y%m%d_%H%M%S)
TARGET_HOST="https://www.baidu.com"
REMOTE_SUBDIR="locust_bench"

# Worker 日志目录（分布式模式）
WORKER_LOG_DIR=""

# 运行控制参数
USERS=100; MULTIPLIER=1.5; SPAWN_RATE=20; RUN_TIME=60
MAX_CONCURRENCY=$MAX_USERS_DEFAULT
ADAPTIVE_MODE="false"               # 默认不开启自适应递进模式
MODE="standalone"; REMOTE_NODES=()
SESSION_LABEL=""                    # 测试备注标签（空则自动生成）
QUIET_MODE="false"                  # 是否开启简洁模式（带进度条）
DESTRUCTIVE="false"                 # 是否开启破坏性测试模式（默认关闭）

# SLA 阈值与配置 (支持通过环境变量或命令行覆盖)
export MAX_AVERAGE_RESPONSE_TIME=${MAX_AVERAGE_RESPONSE_TIME:-3000}
export MAX_FAILURE_RATE=${MAX_FAILURE_RATE:-5}
export LOCUST_MIN_WAIT=${LOCUST_MIN_WAIT:-1.0}
export LOCUST_MAX_WAIT=${LOCUST_MAX_WAIT:-2.0}

# 统计变量
SESSION_START_TIME=""
ITERATION_DURATIONS=()
CONCURRENT_HISTORY=()

# ==============================================================================
# 3. 辅助函数定义 (置于头部以便全局调用)
# ==============================================================================

log_info() { echo -e "\033[0;32m[信息] $1\033[0m"; }
log_warn() { echo -e "\033[0;33m[警告] $1\033[0m"; }
log_err()  { echo -e "\033[0;31m[错误] $1\033[0m"; }
log_diag() { echo -e "\033[0;36m[诊断] $1\033[0m"; }
log_time() { echo -e "\033[0;36m[耗时] $1\033[0m"; }

# 进度条显示函数（简洁模式）
show_progress_bar() {
    local elapsed=$1
    local total=$2
    local current_tps=$3
    local current_rt=$4
    local fail_count=$5
    
    local progress=$((elapsed * 100 / total))
    local remaining=$((total - elapsed))
    local filled=$((progress / 2))
    local empty=$((50 - filled))
    
    # 构建进度条
    local bar=""
    for ((i=0; i<filled; i++)); do bar+="█"; done
    for ((i=0; i<empty; i++)); do bar+="░"; done
    
    # 原地刷新显示
    printf "\r⏱️  进度：[%s] %d%% 剩余：%ds | TPS: %s | RT: %sms | 失败：%s  " \
        "$bar" "$progress" "$remaining" "$current_tps" "$current_rt" "$fail_count"
}

# 清理进度条并换行
clear_progress_bar() {
    if [ "$QUIET_MODE" == "true" ]; then
        printf "\r\033[K"  # 清除当前行
        echo ""
    fi
}

# 获取当前轮次的实时统计（从 locust CSV）
get_current_stats() {
    local csv_file=$1
    if [ -f "$csv_file" ]; then
        # 读取最新的 stats 数据
        local stats=$(tail -n 2 "$csv_file" | head -n 1)
        local tps=$(echo "$stats" | cut -d',' -f3)
        local rt=$(echo "$stats" | cut -d',' -f8)
        local fails=$(echo "$stats" | cut -d',' -f6)
        echo "${tps:-0} ${rt:-0} ${fails:-0}"
    else
        echo "0 0 0"
    fi
}

# 后台监控函数（简洁模式）
monitor_progress() {
    local csv_file=$1
    local duration=$2
    local start_time=$(date +%s)
    
    while true; do
        local now=$(date +%s)
        local elapsed=$((now - start_time))
        
        if [ $elapsed -ge $duration ]; then
            break
        fi
        
        # 每 0.5 秒刷新一次
        local stats=$(get_current_stats "$csv_file")
        local tps=$(echo "$stats" | cut -d' ' -f1)
        local rt=$(echo "$stats" | cut -d' ' -f2)
        local fails=$(echo "$stats" | cut -d' ' -f3)
        
        show_progress_bar "$elapsed" "$duration" "${tps%.*}" "${rt%.*}" "$fails"
        sleep 0.5
    done
    
    clear_progress_bar
}

# 依赖检查函数
check_dependencies() {
    log_info "检查系统依赖..."
    local missing=()
    local reinstall_locust="false"

    # 检查 python3
    if ! command -v python3 >/dev/null 2>&1; then
        missing+=("python3")
    fi

    # 检查 bc (用于数值计算)
    if ! command -v bc >/dev/null 2>&1; then
        missing+=("bc")
    fi

    # 检查虚拟环境中的 locust
    if [ -f "$VENV_PYTHON" ]; then
        if ! "$VENV_PYTHON" -c "import locust" 2>/dev/null; then
            log_warn "检测到 locust 未正确安装，正在重新安装..."
            reinstall_locust="true"
        fi
    fi
    
    # 报告缺失的依赖
    if [ ${#missing[@]} -gt 0 ]; then
        log_err "缺少必要依赖: ${missing[*]}"
        
        # 根据操作系统提供安装建议
        if [[ "$OSTYPE" == "darwin"* ]]; then
            log_err "请使用以下命令安装: brew install ${missing[*]}"
        elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
            if command -v apt-get >/dev/null 2>&1; then
                log_err "请使用以下命令安装: sudo apt-get install ${missing[*]}"
            elif command -v yum >/dev/null 2>&1; then
                log_err "请使用以下命令安装: sudo yum install ${missing[*]}"
            else
                log_err "请根据您的 Linux 发行版安装: ${missing[*]}"
            fi
        fi
        
        exit 1
    fi
    
    log_info "✅ 系统依赖检查通过"
    
    # 如果需要重新安装 locust
    if [ "$reinstall_locust" == "true" ]; then
        log_info "正在重新安装 locust 及相关依赖..."
        "$VENV_PATH/bin/pip" install -q locust pandas beautifulsoup4 lxml requests || {
            log_err "locust 安装失败"
            exit 1
        }
        log_info "✅ locust 安装成功"
    fi
}

# 声音提醒函数 (MacOS 专用)
play_notification() {
    if [[ "$OSTYPE" == "darwin"* ]] && command -v afplay >/dev/null 2>&1; then
        (afplay /System/Library/Sounds/Hero.aiff &)
    fi
}

get_load_average() {
    if [[ "$OSTYPE" == "darwin"* ]]; then
        sysctl -n vm.loadavg | awk '{print $2}'
    else
        awk '{print $1}' /proc/loadavg 2>/dev/null || uptime | awk -F'load average:' '{ print $2 }' | cut -d, -f1 | sed 's/ //g'
    fi
}

show_top_memory_processes() {
    log_diag "当前系统内存占用最高的进程 Top 5:"
    echo "----------------------------------------------------------------"
    if [[ "$OSTYPE" == "darwin"* ]]; then
        ps -eo pmem,rss,comm -m | sort -rk 1 | head -n 6
    else
        ps -eo pmem,rss,comm --sort=-pmem | head -n 6
    fi
    echo "----------------------------------------------------------------"
}

check_and_optimize_env() {
    log_info "正在进行发起端环境预检与调优..."
    
    # 自动清理历史残留进程
    pkill -f "locust.*distributedbench.py" >/dev/null 2>&1 || true

    # 1. ulimit 提升
    local current_ulimit=$(ulimit -n)
    if [ "$current_ulimit" -lt 1024 ]; then
        log_warn "当前系统文件句柄限制过低 ($current_ulimit)，尝试提升..."
        ulimit -n 65535 >/dev/null 2>&1 || true
        [ "$(ulimit -n)" -gt "$current_ulimit" ] && log_info "成功提升文件句柄限制至 $(ulimit -n)"
    fi

    # 2. 内存状态
    local free_mem_mb=0
    local total_mem_mb=0
    if [[ "$OSTYPE" == "darwin"* ]]; then
        local free_pages=$(vm_stat | awk '/Pages free/ {print $3}' | sed 's/\.//')
        local spec_pages=$(vm_stat | awk '/Pages speculative/ {print $3}' | sed 's/\.//')
        local page_size=$(sysctl -n hw.pagesize)
        free_mem_mb=$(( (free_pages + spec_pages) * page_size / 1024 / 1024 ))
        total_mem_mb=$(sysctl -n hw.memsize | awk '{print $1/1024/1024}')
    else
        free_mem_mb=$(free -m | awk '/^Mem:/{print $4 + $7}')
        total_mem_mb=$(free -m | awk '/^Mem:/{print $2}')
    fi

    log_info "系统内存状态: 可用 ${free_mem_mb}MB / 总计 ${total_mem_mb}MB"

    if [ "$free_mem_mb" -lt "$MIN_MEM_CRITICAL" ]; then
        log_err "❌ 剩余可用内存仅为 ${free_mem_mb}MB，无法启动压测！(极端情况下强制退出)"
        show_top_memory_processes
        exit 1
    elif [ "$free_mem_mb" -lt "$MIN_MEM_WARN" ]; then
        log_warn "⚠️ 内存较低 (${free_mem_mb}MB)，建议监控系统稳定性，防止 Swap 干扰。(发出建议提示)"
    fi

    # 3. 基础负载检查
    local cpu_cores=$(sysctl -n hw.ncpu || nproc || echo 1)
    local load=$(get_load_average)
    if [ ! -z "$load" ] && (( $(echo "$load > $cpu_cores" | bc -l) )); then
        log_warn "发现系统初始负载较高 (Load: $load / Cores: $cpu_cores)。建议清理后台应用。"
    fi
}

check_runtime_bottleneck() {
    [ "$MODE" == "worker" ] && return 0
    local cpu_cores=$(sysctl -n hw.ncpu || nproc || echo 1)
    local load=$(get_load_average)
    if [ ! -z "$load" ] && (( $(echo "$load > $cpu_cores * 1.5" | bc -l) )); then
        echo ""
        log_err "⚠️  [发起端瓶颈] 检测到主机负载过重 (Load: $load)！"
        if [ "$DESTRUCTIVE" != "true" ]; then
            log_err ">>> 已自动熔断，防止产出误导性数据。"
            return 1
        fi
    fi
    return 0
}

format_duration() {
    local seconds=$1
    local hours=$((seconds / 3600))
    local minutes=$(((seconds % 3600) / 60))
    local secs=$((seconds % 60))
    printf "%02d:%02d:%02d" $hours $minutes $secs
}

show_duration_summary() {
    local session_end_time=$(date +%s)
    [ -z "$SESSION_START_TIME" ] && return
    local total_duration=$((session_end_time - SESSION_START_TIME))
    echo -e "\n=============================================================================="
    echo "⏱️  压测耗时汇总报告 | 标签: $SESSION_LABEL"
    echo "=============================================================================="
    echo "任务开始时间: $(date -r $SESSION_START_TIME '+%Y-%m-%d %H:%M:%S')"
    echo ""
    echo "各轮次执行明细:"
    echo "  轮次 | 并发数  | 耗时"
    echo "  ------|---------|------------------"
    for i in "${!ITERATION_DURATIONS[@]}"; do
        printf "  %-4d | %-7s | %s\n" $((i+1)) "${CONCURRENT_HISTORY[$i]}" "$(format_duration ${ITERATION_DURATIONS[$i]})"
    done
    echo "------------------------------------------------------------------------------"
    echo "总运行耗时: $(format_duration $total_duration)"
    echo "=============================================================================="
}

show_help() {
    echo "用法: $0 [选项]"
    echo ""
    echo "核心选项:"
    echo "  -H <URL>       目标主机地址 (默认: $TARGET_HOST)"
    echo "  -u <数字>      起始并发用户数 [$MIN_USERS ~ $MAX_USERS_DEFAULT]"
    echo "  -t <秒>        单轮测试时长 [$MIN_DURATION ~ $MAX_DURATION]"
    echo "  -r <数字>      用户增长速率/秒 [$MIN_RATE ~ $MAX_RATE]"
    echo ""
    echo "自适应控制:"
    echo "  -m <倍数>      指定递进倍率 (设置此项即开启阶梯模式) [当前: $MULTIPLIER]"
    echo "  -c <数字>      设置硬性并发上限 [默认: $MAX_USERS_DEFAULT]"
    echo "  -L <标签>      为本次任务添加备注标签 (如: v1.2-fix)"
    echo ""
    echo "SLA 控制与参数:"
    echo "  -S <毫秒>      SLA 平均延迟阈值 (当前: $MAX_AVERAGE_RESPONSE_TIME ms)"
    echo "  -F <百分比>    SLA 错误率阈值 (当前: $MAX_FAILURE_RATE %)"
    echo "  -w <min:max>   用户思考时间范围 (秒) (当前: $LOCUST_MIN_WAIT:$LOCUST_MAX_WAIT)"
    echo ""
    echo "模式切换:"
    echo "  -d             开启本地多核分布式模式"
    echo "  -x             开启破坏性测试模式 (无视 SLA 熔断)"
    echo "  -q             开启简洁模式 (显示实时进度条)"
    exit 0
}

# ==============================================================================
# 4. 参数解析与执行入口
# ==============================================================================

while getopts "hH:u:t:r:m:c:L:S:F:w:dxq" opt; do
    case $opt in
        h) show_help ;;
        H) TARGET_HOST=$OPTARG ;;
        u) USERS=$OPTARG ;;
        t) RUN_TIME=$OPTARG ;;
        r) SPAWN_RATE=$OPTARG ;;
        m) MULTIPLIER=$OPTARG; ADAPTIVE_MODE="true" ;;
        c) MAX_CONCURRENCY=$OPTARG ;;
        L) SESSION_LABEL=$OPTARG ;;
        S) export MAX_AVERAGE_RESPONSE_TIME=$OPTARG ;;
        F) export MAX_FAILURE_RATE=$OPTARG ;;
        w) IFS=':' read -r LOCUST_MIN_WAIT LOCUST_MAX_WAIT <<< "$OPTARG"
           export LOCUST_MIN_WAIT; export LOCUST_MAX_WAIT ;;
        d) MODE="master" ;;
        x) export DESTRUCTIVE=true ;;
        q) QUIET_MODE=true ;;
        *) exit 1 ;;
    esac
done

# 环境初始化
init_env() {
    # 先检查系统依赖
    check_dependencies

    if [ ! -f "$VENV_PYTHON" ]; then
        log_info "正在初始化全局虚拟环境..."
        python3 -m venv "$VENV_PATH"
        "$VENV_PATH/bin/pip" install -q locust pandas beautifulsoup4 lxml requests
        log_info "✅ 虚拟环境初始化完成"
    fi
    check_and_optimize_env
}
init_env

# 运行准备
DOMAIN=$(echo "$TARGET_HOST" | awk -F[/:] '{print $4}')
REPORT_DIR="$BASE_REPORT_DIR/${DOMAIN}_${SESSION_ID}"
mkdir -p "$REPORT_DIR"

# 优化建议 6: 使用进程组清理所有子进程，避免遗留 Python 子进程
SUMMARY_SHOWN="false"  # 标记汇总报告是否已显示
CLEANUP_DONE="false"   # 标记清理是否已完成
cleanup_all() {
    # 防止重复执行
    [ "$CLEANUP_DONE" == "true" ] && return 0
    
    log_info "正在清理所有子进程..."
    # 清理整个进程组，包括所有 Python 子进程
    pkill -P $MAIN_PID 2>/dev/null || true
    # 额外清理可能残留的 locust 进程
    pkill -f "locust" 2>/dev/null || true
    # 只在未显示过时才显示汇总报告
    if [ "$SUMMARY_SHOWN" == "false" ]; then
        show_duration_summary
        play_notification
    fi
    CLEANUP_DONE="true"
    log_info "清理完成，退出。"
    exit 0
}
trap cleanup_all INT TERM

SESSION_START_TIME=$(date +%s)
CURRENT_USERS=$USERS; ITER=1; CURRENT_RUN_TIME=$RUN_TIME

# 主循环
while true; do
    rm -f .bench_threshold_reached
    REPORT_BASE="${REPORT_DIR}/${DOMAIN}_u${CURRENT_USERS}_i${ITER}_$(date +%H%M%S)"
    CSV_STATS="${REPORT_BASE}_stats.csv"
    
    echo -e "\n=============================================================================="
    echo -e "\033[1;35m🚀 [轮次 $ITER] 并发: $CURRENT_USERS | 时长: ${CURRENT_RUN_TIME}s | 标签: $SESSION_LABEL\033[0m"
    echo "=============================================================================="
    
    T_START=$(date +%s)
    v_locust="$VENV_PATH/bin/locust"
    v_python="$VENV_PATH/bin/python3"

    if [ "$MODE" == "master" ]; then
        workers=$(sysctl -n hw.ncpu || nproc || echo 4)
        log_info "启动分布式模式 (Workers: $workers)..."
        
        # 创建 Worker 日志目录
        WORKER_LOG_DIR="${REPORT_DIR}/worker_logs"
        mkdir -p "$WORKER_LOG_DIR"
        
        # 启动 Worker 并记录日志
        for i in $(seq 1 "$workers"); do
            "$v_locust" -f distributedbench.py --worker --master-host=127.0.0.1 \
                --logfile "${WORKER_LOG_DIR}/worker_${i}.log" > /dev/null 2>&1 &
        done
        log_info "Worker 日志目录：$WORKER_LOG_DIR"
        
        "$v_locust" -f distributedbench.py --master --headless -u "$CURRENT_USERS" -r "$SPAWN_RATE" --run-time "${CURRENT_RUN_TIME}s" \
               --host="$TARGET_HOST" --html "${REPORT_BASE}.html" --csv "${REPORT_BASE}" --expect-workers "$workers"
        pkill -f "locust.*--worker" || true
    else
        # 简洁模式下静默 locust 输出，避免与进度条交叉
        if [ "$QUIET_MODE" == "true" ]; then
            "$v_locust" -f distributedbench.py --host="$TARGET_HOST" --headless -u "$CURRENT_USERS" -r "$SPAWN_RATE" --run-time "${CURRENT_RUN_TIME}s" \
                   --html "${REPORT_BASE}.html" --csv "${REPORT_BASE}" > /dev/null 2>&1 &
            LOCUST_PID=$!
            wait $LOCUST_PID 2>/dev/null || true
        else
            "$v_locust" -f distributedbench.py --host="$TARGET_HOST" --headless -u "$CURRENT_USERS" -r "$SPAWN_RATE" --run-time "${CURRENT_RUN_TIME}s" \
                   --html "${REPORT_BASE}.html" --csv "${REPORT_BASE}" 2>&1 | "$v_python" translate_console.py
        fi
    fi
    
    T_END=$(date +%s)
    
    CONCURRENT_HISTORY+=("$CURRENT_USERS")
    ITERATION_DURATIONS+=($((T_END - T_START)))
    
    "$VENV_PATH/bin/python3" translate_report.py "${REPORT_BASE}.html" > /dev/null 2>&1

    if [ "$ADAPTIVE_MODE" == "false" ]; then
        log_info "单轮压测完成。"
        break
    fi

    if [ -f .bench_threshold_reached ] && [ "$DESTRUCTIVE" != "true" ]; then
        log_err ">>> SLA 触发熔断，终止探测。"
        break
    fi

    if ! check_runtime_bottleneck; then break; fi

    NEXT_USERS=$(awk "BEGIN {print int($CURRENT_USERS * $MULTIPLIER)}")
    [ "$NEXT_USERS" -le "$CURRENT_USERS" ] && NEXT_USERS=$((CURRENT_USERS + 10))

    if [ "$NEXT_USERS" -gt "$MAX_CONCURRENCY" ]; then
        log_warn "已达到并发上限 ($MAX_CONCURRENCY)。"
        break
    fi
    
    CURRENT_RUN_TIME=$((CURRENT_RUN_TIME + 30))
    [ "$CURRENT_RUN_TIME" -gt "$MAX_DURATION" ] && CURRENT_RUN_TIME=$MAX_DURATION

    log_info "本轮完成，5秒后开始下一轮 ($NEXT_USERS 并发)..."
    CURRENT_USERS=$NEXT_USERS; ITER=$((ITER + 1)); sleep 5
done

# 生成汇总看板
# 如果 SESSION_LABEL 为空，自动生成标签
if [ -z "$SESSION_LABEL" ]; then
    export EXPORT_LABEL="${CURRENT_USERS}U_$(date +%m%d)"
else
    export EXPORT_LABEL="$SESSION_LABEL"
fi
export SESSION_ID="$SESSION_ID"
log_info "正在生成性能演进趋势看板..."
"$VENV_PATH/bin/python3" aggregate_reports.py "$BASE_REPORT_DIR" && log_info "✅ 汇总报告生成成功" || log_warn "⚠️  汇总报告生成失败"

show_duration_summary
SUMMARY_SHOWN="true"  # 标记已显示汇总报告
play_notification
log_info "任务结束。详情请查看域名看板: $BASE_REPORT_DIR/${DOMAIN}.html"
