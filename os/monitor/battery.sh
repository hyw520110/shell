#!/bin/bash
#
# battery.sh — macOS 电池信息查看与持续检测
#
# 用法:
#   battery.sh                一次性查看电池信息（默认）
#   battery.sh -w             持续检测模式（默认每 30 秒采样一次）
#   battery.sh -w -n 10       检测模式，每 10 秒采样
#   battery.sh -w -c 60       检测模式，采样 60 次后停止
#   battery.sh -w --log FILE  检测模式，结果追加写入 FILE（CSV）
#   battery.sh -h             帮助
#
# 依赖: pmset, ioreg, system_profiler（macOS 自带）
#
set -euo pipefail

# === 颜色（仅 tty 时启用）===
if [[ -t 1 ]]; then
    readonly RED=$'\033[0;31m'
    readonly GREEN=$'\033[0;32m'
    readonly YELLOW=$'\033[1;33m'
    readonly CYAN=$'\033[0;36m'
    readonly NC=$'\033[0m'
else
    readonly RED=''; readonly GREEN=''; readonly YELLOW=''; readonly CYAN=''; readonly NC=''
fi

info()    { echo -e "${CYAN}[INFO]${NC} $*" >&2; }
success() { echo -e "${GREEN}[OK]${NC} $*" >&2; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*" >&2; }
error()   { echo -e "${RED}[ERR]${NC} $*" >&2; }

# === 读取电池数据（单次 ioreg 调用，缓存供多字段用）===
_read_batt() {
    ioreg -rn AppleSmartBattery 2>/dev/null
}

# 从 ioreg 数据中提取字段值
_extract() {
    local data="$1" pattern="$2"
    echo "$data" | grep -oE "$pattern" | head -1 | awk '{print $NF}'
}

# 提取嵌套字典字段（带引号，如 "ChargingCurrent"=0）
_extract_nested() {
    local data="$1" field="$2"
    echo "$data" | grep -oE "\"$field\"=[0-9-]+" | head -1 | cut -d= -f2
}

# === 一次性查看电池信息 ===
battery_info_once() {
    local data
    data=$(_read_batt)

    # 电量
    local batt_line charge pct src
    batt_line=$(pmset -g batt 2>/dev/null | head -2 | tr '\n' ' ')
    charge=$(echo "$batt_line" | grep -oE '[0-9]+%' | head -1)
    pct="${charge%\%}"
    if echo "$batt_line" | grep -q "AC attached"; then
        if echo "$batt_line" | grep -q "not charging"; then
            src="${YELLOW}适配器供电（未充电）${NC}"
        elif echo "$batt_line" | grep -q "charging"; then
            src="${GREEN}适配器供电（充电中）${NC}"
        else
            src="${CYAN}适配器供电${NC}"
        fi
    else
        src="${RED}电池供电${NC}"
    fi

    # 硬件字段
    local ischg amp chgcur notchg extcharge cell temp soc syspwr maxcap curcap designcap cycle health
    ischg=$(_extract "$data" '"IsCharging" = [A-Za-z]+')
    amp=$(_extract "$data" '"Amperage" = [0-9-]+')
    chgcur=$(_extract_nested "$data" "ChargingCurrent")
    notchg=$(_extract_nested "$data" "NotChargingReason")
    extcharge=$(_extract "$data" '"ExternalChargeCapable" = [A-Za-z]+')
    cell=$(_extract "$data" '"CellVoltage"=\([0-9,]+\)' | sed 's/"CellVoltage"=//;s/[()]//g;s/,/ /g')
    soc=$(_extract_nested "$data" "StateOfCharge")
    syspwr=$(_extract_nested "$data" "SystemPower")
    temp=$(_extract "$data" '"Temperature" = [0-9]+')
    maxcap=$(_extract "$data" '"MaxCapacity" = [0-9]+')
    curcap=$(_extract "$data" '"CurrentCapacity" = [0-9]+')
    cycle=$(_extract_nested "$data" "CycleCount")

    # 健康度（MaxCapacity / DesignCapacity）
    local designcap health_pct
    designcap=$(echo "$data" | grep -oE '"DesignCapacity" = [0-9]+' | head -1 | awk '{print $NF}')
    if [[ -n "$maxcap" && -n "$designcap" && "$designcap" -gt 0 ]]; then
        health_pct=$(( maxcap * 100 / designcap ))
    else
        health_pct="?"
    fi

    # 温度（ioreg 单位 0.1K → °C）
    local temp_c
    if [[ -n "$temp" ]]; then
        temp_c=$(( temp / 10 - 273 ))
    else
        temp_c="?"
    fi

    echo ""
    echo -e "  ${CYAN}═${NC} 电池状态 ${CYAN}═${NC}"
    echo -e "  电量:        ${pct}%  (${src})"
    [[ -n "$soc" ]] && echo -e "  内部电量:   ${soc}%"
    [[ -n "$ischg" ]] && echo -e "  充电中:     ${ischg}"
    [[ -n "$chgcur" ]] && echo -e "  充电电流:   ${chgcur} mA"
    [[ -n "$amp" ]] && echo -e "  电流:       ${amp} mA"
    [[ -n "$extcharge" ]] && echo -e "  外部可充:   ${extcharge}"
    [[ -n "$notchg" ]] && echo -e "  未充电原因: ${notchg}"
    [[ -n "$cell" ]] && echo -e "  电芯电压:   ${cell} mV"
    [[ -n "$syspwr" ]] && echo -e "  系统功耗:   ${syspwr} mW"
    [[ -n "$temp_c" ]] && echo -e "  电池温度:   ${temp_c}°C"
    echo -e "  ${CYAN}─${NC} 电池健康 ${CYAN}─${NC}"
    [[ -n "$cycle" ]] && echo -e "  循环次数:   ${cycle}"
    [[ -n "$maxcap" ]] && echo -e "  满电容量:   ${maxcap} mAh"
    [[ -n "$designcap" ]] && echo -e "  设计容量:   ${designcap} mAh"
    [[ -n "$health_pct" && "$health_pct" != "?" ]] && echo -e "  健康度:     ${health_pct}%"

    # 告警
    local pct_num
    pct_num=${pct%\%}
    if [[ -n "$pct_num" && "$pct_num" -le 10 ]]; then
        error "电量过低（${pct}%），请尽快接电"
    elif [[ -n "$pct_num" && "$pct_num" -le 20 ]]; then
        warn "电量偏低（${pct}%）"
    fi
    if [[ "$extcharge" == "No" ]]; then
        warn "外部电源无法给电池充电（ExternalChargeCapable=No）"
    fi
    if [[ -n "${notchg:-}" && "${notchg:-}" != "0" && "${notchg:-}" != "255" ]]; then
        warn "电池未充电（NotChargingReason=${notchg:-}）"
    fi
    if [[ -n "$cycle" && -n "$health_pct" && "$health_pct" != "?" && "$health_pct" -lt 80 ]]; then
        error "电池健康度 ${health_pct}%（低于 80%），建议更换"
    fi
    echo ""
}

# === 检测模式（持续采样）===
battery_watch() {
    local interval="${WATCH_INTERVAL:-30}" count="${WATCH_COUNT:-0}" logfile="${WATCH_LOG:-}"
    # 解析可选参数
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -n|--interval) interval="$2"; shift 2 ;;
            -c|--count) count="$2"; shift 2 ;;
            --log) logfile="$2"; shift 2 ;;
            *) shift ;;
        esac
    done
    [[ "$interval" -lt 5 ]] && interval=5

    info "开始电池检测：每 ${interval}s 采样${count:+，共 ${count} 次}${logfile:+，日志 $logfile}"
    info "按 Ctrl-C 停止"

    # CSV 表头（仅新建文件时）
    if [[ -n "$logfile" && ! -s "$logfile" ]]; then
        echo "时间,电量,电源来源,充电中,电流,充电电流,未充电原因,外部可充,电芯电压,温度,内部电量,系统功耗" > "$logfile"
    fi

    local i=0
    while true; do
        i=$((i+1))
        [[ "$count" -gt 0 && "$i" -gt "$count" ]] && break

        local data ts batt src ischg amp chgcur notchg cell temp soc syspwr
        ts=$(date '+%Y-%m-%d %H:%M:%S')
        data=$(_read_batt)

        batt=$(pmset -g batt 2>/dev/null | grep -oE '[0-9]+%' | head -1)
        if pmset -g batt 2>/dev/null | grep -q "AC attached"; then
            src="AC"
        else
            src="BAT"
        fi
        ischg=$(_extract "$data" '"IsCharging" = [A-Za-z]+')
        amp=$(_extract "$data" '"Amperage" = [0-9-]+')
        chgcur=$(_extract_nested "$data" "ChargingCurrent")
        notchg=$(_extract_nested "$data" "NotChargingReason")
        cell=$(_extract "$data" '"CellVoltage"=\([0-9,]+\)' | sed 's/"CellVoltage"=//;s/[()]//g;s/,/|/g')
        temp=$(_extract "$data" '"Temperature" = [0-9]+')
        soc=$(_extract_nested "$data" "StateOfCharge")
        syspwr=$(_extract_nested "$data" "SystemPower")

        # 温度换算
        local temp_c
        [[ -n "$temp" ]] && temp_c=$(( temp / 10 - 273 )) || temp_c="?"

        # 终端显示（单行，覆盖式刷新简单输出）
        echo -e "  ${CYAN}[${ts}]${NC} 电量 ${batt} | ${src} | 充电中 ${ischg:-?} | 电流 ${amp:-?}mA | 充电流 ${chgcur:-?}mA | 未充电原因 ${notchg:-?} | 电芯 ${cell:-?}mV | 温度 ${temp_c}°C"

        # 写日志
        if [[ -n "$logfile" ]]; then
            echo "$ts,${batt},${src},${ischg},${amp},${chgcur},${notchg},$(_extract "$data" '"ExternalChargeCapable" = [A-Za-z]+'),${cell},${temp_c},${soc},${syspwr}" >> "$logfile"
        fi

        [[ "$count" -gt 0 ]] || true
        sleep "$interval"
    done
    success "检测完成（共 $((i-1)) 次采样）"
}

# === 帮助 ===
show_help() {
    cat << EOF
用法: $(basename "$0") [选项]

macOS 电池信息查看与持续检测

无参数:  一次性查看电池信息（默认）
  -w, --watch          持续检测模式（循环采样）
  -n, --interval N     检测间隔秒数（默认 30，最小 5）
  -c, --count N        检测次数（默认不限，直到 Ctrl-C）
  --log FILE           检测结果追加写入 FILE（CSV）
  -h, --help           显示帮助

示例:
  battery.sh                查看电池当前状态
  battery.sh -w             每 30 秒检测一次
  battery.sh -w -n 10 -c 60 每 10 秒检测 60 次（10 分钟）
  battery.sh -w --log /tmp/batt.csv  检测并记录 CSV

依赖: pmset, ioreg, system_profiler
EOF
}

# === 主流程 ===
ACTION="once"
WATCH_INTERVAL=30
WATCH_COUNT=0
WATCH_LOG=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        -w|--watch) ACTION="watch"; shift ;;
        -n|--interval) WATCH_INTERVAL="$2"; shift 2 ;;
        -c|--count) WATCH_COUNT="$2"; shift 2 ;;
        --log) WATCH_LOG="$2"; shift 2 ;;
        -h|--help) show_help; exit 0 ;;
        *) error "未知选项: $1"; show_help; exit 1 ;;
    esac
done

if [[ "$ACTION" == "watch" ]]; then
    battery_watch -n "$WATCH_INTERVAL" -c "$WATCH_COUNT" --log "$WATCH_LOG"
else
    battery_info_once
fi
