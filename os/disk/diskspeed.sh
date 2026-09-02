#!/bin/bash

# diskspeed.sh - 硬盘读写性能测试工具 (优化版)
# 支持: macOS / Linux
# 特性: 多硬盘选择、自动识别挂载点、智能清理缓存、跨平台兼容

# ── 颜色定义 ──────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

# ── 变量默认值 ────────────────────────────────────────────────────────
BLOCK_SIZES=(4 64 256 1024 2048 3072 4196 5120) # 测试文件大小 (MB)
ITERATIONS=3                                     # 每个大小测试 3 次取平均
TEST_FILENAME=".diskspeed_test.tmp"

# 存储结果
DISK_RESULTS=()

# ── 工具函数 ──────────────────────────────────────────────────────────
info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
success() { echo -e "${GREEN}[OK]${NC} $*"; }

detect_os() {
    case "$(uname -s)" in
        Darwin*) echo "macos" ;;
        Linux*)  echo "linux" ;;
        *)       echo "unknown" ;;
    esac
}

OS=$(detect_os)

# 获取当前高精度时间
get_time() {
    if [[ "$OS" == "macos" ]]; then
        # 尝试使用 python3 或 perl 获取毫秒级时间，因为 macOS 原生 date 可能不支持 %N
        if command -v python3 >/dev/null 2>&1; then
            python3 -c 'import time; print(time.time())'
        elif command -v perl >/dev/null 2>&1; then
            perl -MTime::HiRes=time -e 'printf "%.9f\n", time'
        else
            date +%s
        fi
    else
        date +%s.%N
    fi
}

# 清理缓存
clear_cache() {
    local silent="$1"
    [[ -z "$silent" ]] && info "正在清理系统磁盘缓存..."
    sync
    if [[ "$OS" == "macos" ]]; then
        sudo purge >/dev/null 2>&1 || true
    else
        echo 3 | sudo tee /proc/sys/vm/drop_caches > /dev/null 2>&1 || true
    fi
}

# 获取磁盘空间 (MB)
get_free_space() {
    local path="$1"
    if [[ "$OS" == "macos" ]]; then
        df -m "$path" | tail -1 | awk '{print $4}'
    else
        df -BM "$path" | tail -1 | awk '{print $4}' | sed 's/M//'
    fi
}

# ── 交互式选择 ────────────────────────────────────────────────────────

# 解析复杂输入：处理 0,2 3-5 这种格式
parse_selection() {
    local input="$1"
    local max_idx="$2"
    local -a res=()
    
    # 将逗号替换为空格
    input="${input//,/ }"
    
    for item in $input; do
        if [[ "$item" =~ ^([0-9]+)-([0-9]+)$ ]]; then
            local start=${BASH_REMATCH[1]}
            local end=${BASH_REMATCH[2]}
            for ((i=start; i<=end; i++)); do
                if [[ $i -ge 0 && $i -lt $max_idx ]]; then res+=($i); fi
            done
        elif [[ "$item" =~ ^[0-9]+$ ]]; then
            if [[ $item -ge 0 && $item -lt $max_idx ]]; then res+=($item); fi
        fi
    done
    # 去重并返回
    echo "${res[@]}" | tr ' ' '\n' | sort -nu | tr '\n' ' '
}

select_devices() {
    local partitions=()
    if [[ "$OS" == "macos" ]]; then
        # 1. 获取所有挂载的磁盘设备
        local mount_list=$(df -m | grep '^/dev/disk')
        
        # 临时存储：物理磁盘|设备|挂载点|空间
        local temp_results=()

        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            local dev=$(echo "$line" | awk '{print $1}')
            
            # 过滤掉系统内部卷和低容量卷
            if [[ "$line" =~ Preboot|Recovery|VM|Update|iSCPreboot|xarts|Hardware ]]; then continue; fi
            
            local mnt=$(echo "$line" | awk '{$1=$2=$3=$4=$5=$6=$7=$8=""; sub(/^[ \t]+/, ""); print}')
            local space=$(get_free_space "$mnt")
            
            # 追踪物理磁盘
            local p_store=$(diskutil info "$dev" 2>/dev/null | grep "APFS Physical Store" | awk '{print $NF}')
            [[ -z "$p_store" ]] && p_store=$(diskutil info "$dev" 2>/dev/null | grep "Part of Whole" | awk '{print $NF}')
            
            local p_disk=$(diskutil info "${p_store:-$dev}" 2>/dev/null | grep "Part of Whole" | awk '{print $NF}')
            p_disk=${p_disk:-$p_store}
            p_disk=${p_disk:-$dev}
            
            local p_disk_name=$(basename "$p_disk" | sed 's/s[0-9]*$//')
            local p_disk_path="/dev/$p_disk_name"

            temp_results+=("$p_disk_path|$dev|$mnt|$space")
        done <<< "$mount_list"

        # 按物理磁盘去重
        local seen_disks=""
        for item in "${temp_results[@]}"; do
            IFS='|' read -r p_disk dev mnt space <<< "$item"
            if [[ ! "$seen_disks" =~ "$p_disk" ]]; then
                partitions+=("$dev,$mnt,$p_disk")
                seen_disks="$seen_disks $p_disk"
            fi
        done
    else
        while IFS= read -r line; do
            [[ -n "$line" ]] && partitions+=("$line")
        done < <(df -h --output=source,target | grep '^/dev/' | awk '{print $1","$2}')
    fi

    if [[ ${#partitions[@]} -eq 0 ]]; then
        error "未发现可测试的已挂载磁盘。"
        exit 1
    fi

    echo -e "\n${BOLD}发现以下可测试的物理磁盘:${RESET}"
    echo "----------------------------------------------------------------------"
    printf "  %-4s | %-16s | %-20s | %-10s\n" "编号" "物理磁盘" "测试挂载点" "可用空间"
    echo "----------------------------------------------------------------------"
    for i in "${!partitions[@]}"; do
        IFS=',' read -r dev mnt p_disk <<< "${partitions[$i]}"
        local space=$(get_free_space "$mnt")
        local display_disk=${p_disk:-$dev}
        printf "  %-4d | %-16s | %-20s | %s MB\n" "$i" "$display_disk" "$mnt" "$space"
    done
    echo "  a    | 测试所有发现的磁盘"
    echo "----------------------------------------------------------------------"
    
    read -p "请选择要测试的编号 (支持 0,2 4-6 或直接回车选当前目录): " choice
    
    SELECTED_DEVICES=()
    if [[ -z "$choice" ]]; then
        # 默认当前目录
        local current_mnt
        local current_dev
        local current_p_disk=""
        if [[ "$OS" == "macos" ]]; then
            current_mnt=$(df . | tail -1 | awk '{$1=$2=$3=$4=$5=$6=$7=$8=""; sub(/^[ \t]+/, ""); print}')
            current_dev=$(df . | tail -1 | awk '{print $1}')
            local p_store=$(diskutil info "$current_dev" 2>/dev/null | grep "APFS Physical Store" | awk '{print $NF}')
            [[ -z "$p_store" ]] && p_store=$(diskutil info "$current_dev" 2>/dev/null | grep "Part of Whole" | awk '{print $NF}')
            local p_disk=$(diskutil info "${p_store:-$current_dev}" 2>/dev/null | grep "Part of Whole" | awk '{print $NF}')
            p_disk=${p_disk:-$p_store}
            p_disk=${p_disk:-$current_dev}
            current_p_disk="/dev/$(basename "$p_disk" | sed 's/s[0-9]*$//')"
        else
            current_mnt=$(df . --output=target | tail -1)
            current_dev=$(df . | tail -1 | awk '{print $1}')
            current_p_disk="$current_dev"
        fi
        SELECTED_DEVICES+=("$current_dev,$current_mnt,$current_p_disk")
    elif [[ "$choice" == "a" ]]; then
        for p in "${partitions[@]}"; do
            IFS=',' read -r dev mnt p_disk <<< "$p"
            SELECTED_DEVICES+=("$dev,$mnt,$p_disk")
        done
    else
        local idxs=$(parse_selection "$choice" "${#partitions[@]}")
        for idx in $idxs; do
            IFS=',' read -r dev mnt p_disk <<< "${partitions[$idx]}"
            SELECTED_DEVICES+=("$dev,$mnt,$p_disk")
        done
    fi

    if [[ ${#SELECTED_DEVICES[@]} -eq 0 ]]; then
        error "无效的选择，请检查编号。"
        exit 1
    fi
}

# ── 核心测试逻辑 ──────────────────────────────────────────────────────

run_test() {
    local dev_mnt_p="$1"
    IFS=',' read -r dev mnt p_disk <<< "$dev_mnt_p"
    
    local test_file="${mnt}/${TEST_FILENAME}"
    
    echo -e "\n${BOLD}>>> 正在测试磁盘: ${CYAN}${p_disk}${NC} (挂载点: ${mnt})${RESET}"
    
    for size in "${BLOCK_SIZES[@]}"; do
        local free_space=$(get_free_space "$mnt")
        if [[ $free_space -lt $((size + 100)) ]]; then
            warn "跳过 ${size}MB 测试: 空间不足 (剩余 ${free_space}MB)"
            continue
        fi

        # 写入测试
        echo -ne "${BLUE}[INFO]${NC} 写入测试 (${size} MB): "
        local w_sum=0
        for ((i=1; i<=ITERATIONS; i++)); do
            clear_cache "silent"
            local start_time=$(get_time)
            if [[ "$OS" == "macos" ]]; then
                # 使用 conv=fsync 强制内核将数据刷新到物理磁盘，绕过内存伪速
                dd if=/dev/zero of="$test_file" bs=4194304 count=$((size / 4)) conv=fsync >/dev/null 2>&1
            else
                dd if=/dev/zero of="$test_file" bs=4M count=$((size / 4)) oflag=direct,sync >/dev/null 2>&1
            fi
            local end_time=$(get_time)
            local duration=$(awk "BEGIN {print $end_time - $start_time}")
            local speed=$(awk "BEGIN {print $size / $duration}")
            w_sum=$(awk "BEGIN {print $w_sum + $speed}")
            echo -n "."
        done
        local w_avg=$(awk "BEGIN {printf \"%.2f\", $w_sum / $ITERATIONS}")
        echo -e " 平均: ${GREEN}${w_avg} MB/s${NC}"

        # 读取测试
        echo -ne "${BLUE}[INFO]${NC} 读取测试 (${size} MB): "
        local r_sum=0
        for ((i=1; i<=ITERATIONS; i++)); do
            clear_cache "silent"
            local start_time=$(get_time)
            if [[ "$OS" == "macos" ]]; then
                dd if="$test_file" of=/dev/null bs=4194304 count=$((size / 4)) >/dev/null 2>&1
            else
                dd if="$test_file" of=/dev/null bs=4M count=$((size / 4)) iflag=direct >/dev/null 2>&1
            fi
            local end_time=$(get_time)
            local duration=$(awk "BEGIN {print $end_time - $start_time}")
            local speed=$(awk "BEGIN {print $size / $duration}")
            r_sum=$(awk "BEGIN {print $r_sum + $speed}")
            echo -n "."
        done
        local r_avg=$(awk "BEGIN {printf \"%.2f\", $r_sum / $ITERATIONS}")
        echo -e " 平均: ${GREEN}${r_avg} MB/s${NC}"
        
        # 记录结果
        DISK_RESULTS+=("$p_disk|$mnt|$size|$w_avg|$r_avg")

        rm -f "$test_file"
    done
}

# ── 主流程 ────────────────────────────────────────────────────────────

main() {
    echo -e "${BOLD}=========================================="
    echo -e "      磁盘读写速度性能测试工具"
    echo -e "==========================================${RESET}"

    select_devices

    info "正在请求 sudo 权限以执行清理缓存操作..."
    sudo -v || { error "获取 sudo 权限失败，脚本退出"; exit 1; }

    for dev_mnt_p in "${SELECTED_DEVICES[@]}"; do
        run_test "$dev_mnt_p"
    done

    # ── 打印汇总报告 ──────────────────────────────────────────────────
    echo -e "\n${BOLD}====================== 性能测试报告 ======================${NC}"
    printf "${CYAN}%-12s | %-20s | %-10s | %-14s | %-14s${NC}\n" "设备" "挂载点" "测试容量" "平均写入" "平均读取"
    echo "--------------------------------------------------------------------------------"
    
    local last_dev=""
    for res in "${DISK_RESULTS[@]}"; do
        IFS='|' read -r p_disk mnt size w r <<< "$res"
        
        if [[ -n "$last_dev" && "$last_dev" != "$p_disk" ]]; then
            echo "--------------------------------------------------------------------------------"
        fi
        
        printf "%-12s | %-20s | %-10s | ${GREEN}%10s MB/s${NC} | ${GREEN}%10s MB/s${NC}\n" \
            "$p_disk" "$mnt" "${size}MB" "$w" "$r"
        
        last_dev="$p_disk"
    done
    echo "--------------------------------------------------------------------------------"

    # ── 打印峰值性能汇总 ──────────────────────────────────────────────
    echo -e "\n${BOLD}>>> 磁盘性能峰值摘要:${NC}"
    
    local seen_p_disks=""
    for dev_mnt_p in "${SELECTED_DEVICES[@]}"; do
        IFS=',' read -r dev mnt p_disk <<< "$dev_mnt_p"
        if [[ ! "$seen_p_disks" =~ "$p_disk" ]]; then
            local max_w=0
            local max_r=0
            for res in "${DISK_RESULTS[@]}"; do
                IFS='|' read -r r_p_disk r_mnt r_size r_w r_r <<< "$res"
                if [[ "$r_p_disk" == "$p_disk" ]]; then
                    max_w=$(awk "BEGIN {print ($r_w > $max_w) ? $r_w : $max_w}")
                    max_r=$(awk "BEGIN {print ($r_r > $max_r) ? $r_r : $max_r}")
                fi
            done
            printf "  ${YELLOW}%-12s${NC} -> 写入峰值: ${BOLD}${GREEN}%-10s MB/s${NC} | 读取峰值: ${BOLD}${GREEN}%-10s MB/s${NC}\n" \
                "$p_disk" "$max_w" "$max_r"
            seen_p_disks="$seen_p_disks $p_disk"
        fi
    done

    echo -e "\n${BOLD}====================== 专业工具推荐 ======================${NC}"
    if [[ "$OS" == "macos" ]]; then
        echo -e "${CYAN}macOS 用户建议搭配以下工具进行深度验证：${NC}"
        echo -e "  1. ${BOLD}Blackmagic Disk Speed Test${NC} (App Store 免费，行业标准视频工作流测试)"
        echo -e "  2. ${BOLD}AmorphousDiskMark${NC} (类似 Windows 下的 CrystalDiskMark，适合压测峰值)"
        echo -e "  3. ${BOLD}AJA System Test Lite${NC} (专业影视行业磁盘吞吐量测试)"
    else
        echo -e "${CYAN}Linux 用户建议使用：${NC}"
        echo -e "  1. ${BOLD}fio${NC} (最专业的命令行压力测试工具)"
        echo -e "  2. ${BOLD}KDiskMark${NC} (GUI 界面，类似 CrystalDiskMark)"
    fi
    echo -e "--------------------------------------------------------------------------------"
    echo -e "${BLUE}[提示]${NC} 本脚本采用 dd + fsync 模拟真实写入，结果受系统负载影响，建议多测几次。"
}

main "$@"
