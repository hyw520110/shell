#!/bin/bash

# 定义块大小参数（以MB为单位）
BLOCK_SIZES=(2 4 16 64) # 256 512 1024 2048
TESTFILE="/tmp/diskspeedtest.tmp"
# 每次测试的迭代次数
ITERATIONS=3

# 获取系统信息
SYSTEM_INFO=$(uname -a)

# 存储所有的测试结果
declare -A w_results
declare -A r_results

# 清理函数
cleanup() {
    rm -f $TESTFILE
}

# 初始化报告内容
init_report() {
    echo "硬盘读写性能测试:"
    echo "测试时间: $(date)"
    echo "系统信息: $SYSTEM_INFO"
    echo "选定设备: $DEVICE"
    if [ -n "$MOUNT_POINT" ]; then
        echo "磁盘可用空间: $(($(df --output=avail "$MOUNT_POINT" | tail -n 1) / 1024)) MB"
    else
        # 对于未挂载的设备，尝试获取总大小
        DISK_SIZE=$(( $(lsblk -ndo SIZE "$DEVICE") / (1024 * 1024) ))
        echo "磁盘总大小: ${DISK_SIZE} MB"
    fi
    echo ""
}

# 检查磁盘空间是否足够
check_disk_space() {
    local size=$1 # 测试文件大小（以MB为单位）

    if [ -z "$MOUNT_POINT" ]; then
        return 0 # 对于未挂载的设备，假设所有空间都可以使用
    fi

    local available_space=$(($(df --output=avail "$MOUNT_POINT" | tail -n 1) / 1024))

    if [ $available_space -lt $size ]; then
        echo "错误: 磁盘空间不足。需要至少 ${size} MB 的可用空间，但只有 ${available_space} MB 可用。"
        exit 1
    fi
}

# 列出所有已挂载的分区供用户选择
select_device() {
    partitions=($(df -h --output=source,target | grep '^/dev/' | awk '{print $1","$2}'))

    if [ ${#partitions[@]} -eq 0 ]; then
        echo "没有找到任何已挂载的分区。"
        exit 1
    elif [ ${#partitions[@]} -eq 1 ]; then
        IFS=',' read -r DEVICE MOUNT_POINT <<< "${partitions[0]}"
        echo "自动选择了唯一的已挂载分区: $DEVICE"
    else
        echo "选择分区或按 Enter 选择当前分区: "
        options=("当前分区" "${partitions[@]}")
        for i in "${!options[@]}"; do
            echo "$i) ${options[$i]}"
        done
        read -p "请输入选项编号或按 Enter 选择当前分区: " choice
        
        if [[ -z "$choice" ]]; then
            choice=0 # 默认选择当前分区
        fi

        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 0 && choice < ${#options[@]} )); then
            dev=${options[$choice]}
            if [[ "$dev" == "当前分区" ]]; then
                MOUNT_POINT=$(df . --output=target | tail -n 1)
                DEVICE=$(df . --output=source | tail -n 1)
            else
                IFS=',' read -r DEVICE MOUNT_POINT <<< "$dev"
            fi
        else
            echo "无效的选择，请重新运行脚本并做出正确选择。"
            exit 1
        fi
    fi
    
    echo "选定设备: $DEVICE，挂载点: $MOUNT_POINT"
}

# 运行测试
run_test() {
    local test_type=$1
    local size=$2 # 测试文件大小（以MB为单位）
    local sum=0
    local count=$ITERATIONS
    
    check_disk_space $size # 检查磁盘空间是否足够
    
    for ((i=0; i<$ITERATIONS; i++)); do
        sudo sync && echo 3 | sudo tee /proc/sys/vm/drop_caches > /dev/null 2>&1 # 清除缓存
        
        if [[ "$test_type" == "写" ]]; then
            output=$( { time dd if=/dev/zero of=$TESTFILE bs=1M count=$size oflag=direct,sync >/dev/null; } 2>&1 )
        elif [[ "$test_type" == "读" ]]; then
            output=$( { time dd if=$TESTFILE of=/dev/null bs=1M count=$size iflag=direct >/dev/null; } 2>&1 )
        elif [[ "$test_type" == "随机写" ]]; then
            output=$( { time dd if=/dev/urandom of=$TESTFILE bs=1M count=$size oflag=direct,sync >/dev/null; } 2>&1 )
        elif [[ "$test_type" == "随机读" ]]; then
            output=$( { time dd if=$TESTFILE of=/dev/null bs=1M count=$size iflag=direct conv=notrunc,fsync skip=$((RANDOM % size)) seek=$((RANDOM % size)) >/dev/null; } 2>&1 )
        fi
        
        # 提取实际运行时间并转换成秒
        time=$(echo "$output" | grep -oP 'real\s+\K[\d.]+m[\d.]+s' | awk '{split($1,a,"m"); print a[1]*60+a[2]}')
        if [[ $? -eq 0 && -n "$time" && $(echo "$time > 0" | bc) -eq 1 ]]; then
            speed=$(awk "BEGIN{print ($size/$time)}")
            sum=$(awk "BEGIN{print $sum + $speed}")
        fi
    done
    
    avg_speed=$(awk "BEGIN{print $sum / $count}")
    echo "  ${test_type}测试(${size} MB)平均速度: $avg_speed MB/s"
    
    if [[ "$test_type" == "写" || "$test_type" == "随机写" ]]; then
        w_results[$size]=$avg_speed
    else
        r_results[$size]=$avg_speed
    fi
}

# 计算平均速度
calculate_avg_speed() {
    local results_array_name=$1
    local type=$2
    
    local sum=0
    local -n results_array=$results_array_name
    local count=${#results_array[@]}
    
    for key in "${!results_array[@]}"; do
        sum=$(awk "BEGIN{print $sum + ${results_array[$key]}}")
    done
    
    if [ $count -gt 0 ]; then
        avg_speed=$(awk "BEGIN{print $sum / $count}")
        echo "平均${type}速度: $avg_speed MB/s"
    else
        echo "平均${type}速度: 无有效数据"
    fi
}

# 选择设备
select_device

init_report
test_types=("写" "读")
total_tests=$(( ${#BLOCK_SIZES[@]} * ${#test_types[@]} ))
current_test=0

for size in "${BLOCK_SIZES[@]}"; do
    for test_type in "${test_types[@]}"; do
        ((current_test++))
        echo "正在执行${test_type}测试, 文件大小: ${size} MB, 进度: $(( (current_test * 100) / total_tests ))% (${current_test}/${total_tests})"
        run_test "$test_type" "$size"
        
        cleanup 
    done
done

echo "测试结果:"
calculate_avg_speed w_results "写入"
calculate_avg_speed r_results "读取"