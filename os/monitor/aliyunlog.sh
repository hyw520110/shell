#!/bin/bash

# 脚本功能：从阿里云日志服务查询日志，支持通过命令行参数灵活配置查询条件。

set -eo pipefail

# --- 配置 ---
# 默认值，如果命令行参数未提供，则使用这些值
DEFAULT_PROJECT="-pro"
DEFAULT_LOGSTORE="-pip"
DEFAULT_QUERY="] ERROR " # 实际查询字符串是 "] ERROR "
DEFAULT_REGION_ENDPOINT="cn-hangzhou.log.aliyuncs.com"
DEFAULT_OUTPUT_FILE="$HOME/Downloads/aliyun_log_errors.log"
DEFAULT_DAYS=1 # 默认查询最近1天
# --- 结束配置 ---

# --- 辅助函数 ---
log_message() { echo "[信息] $1"; }
error_exit() { echo "[错误] $1" >&2; exit 1; }

# 显示帮助信息
show_help() {
    echo "用法: $0 [选项]"
    echo "从阿里云日志服务查询日志。"
    echo
    echo "选项:"
    echo "  -p <项目名>      阿里云日志服务项目名 (默认: ${DEFAULT_PROJECT})"
    echo "  -l <Logstore名>  阿里云日志服务Logstore名 (默认: ${DEFAULT_LOGSTORE})"
    echo "  -q <查询语句>    日志查询字符串 (默认: '${DEFAULT_QUERY}')"
    echo "  -d <天数>        查询最近N天 (默认: ${DEFAULT_DAYS} 天)"
    echo "  -o <文件路径>    输出文件路径 (默认: ${DEFAULT_OUTPUT_FILE})"
    echo "  -e <Endpoint>    地域Endpoint (默认: ${DEFAULT_REGION_ENDPOINT})"
    echo "  -h               显示此帮助信息"
}

# --- 主逻辑 ---
main() {
    local project="${DEFAULT_PROJECT}"
    local logstore="${DEFAULT_LOGSTORE}"
    local query="${DEFAULT_QUERY}"
    local num_days="${DEFAULT_DAYS}"
    local output_file="${DEFAULT_OUTPUT_FILE}"
    local region_endpoint="${DEFAULT_REGION_ENDPOINT}"

    # 解析命令行参数
    while getopts "p:l:q:d:o:e:h" opt; do
        case "$opt" in
            p) project="$OPTARG" ;;
            l) logstore="$OPTARG" ;;
            q) query="$OPTARG" ;;
            d) num_days="$OPTARG" ;;
            o) output_file="$OPTARG" ;;
            e) region_endpoint="$OPTARG" ;;
            h) show_help; exit 0 ;;
            *) error_exit "无效选项。使用 -h 查看帮助。" ;;
        esac
    done
    shift $((OPTIND-1)) # 移除已解析的选项

    # 验证天数参数
    if ! [[ "$num_days" =~ ^[1-9][0-9]*$ ]]; then
        error_exit "查询天数必须是一个正整数。"
    fi

    # 检查 aliyunlog CLI 工具是否存在
    if ! command -v aliyunlog &> /dev/null; then
        error_exit "'aliyunlog' CLI 工具未找到。请安装并配置它。"
    fi

    # 计算时间范围
    local current_date=$(date +%Y-%m-%d)
    local current_time=$(date +%H:%M:%S)
    local start_date=$(date -d "$current_date -$num_days day" +%Y-%m-%d)

    # 假设cn-hangzhou地域使用UTC+8时区
    local from_time="${start_date} ${current_time}+08:00"
    local to_time="${current_date} ${current_time}+08:00"

    log_message "正在查询阿里云日志服务..."
    log_message "  项目: '$project', Logstore: '$logstore'"
    log_message "  查询语句: '$query'"
    log_message "  时间范围: 从 '$from_time' 到 '$to_time'"
    log_message "  结果将追加到: '$output_file'"

    # 执行 aliyunlog 命令，并将其拆分成多行以提高可读性
    aliyunlog log get_log_all \
        --project="$project" \
        --logstore="$logstore" \
        --query="$query" \
        --from_time="$from_time" \
        --to_time="$to_time" \
        --region-endpoint="$region_endpoint" \
        --format-output=no_escape \
        --jmes-filter="join('\n', map(&to_string(@), @))" \
        >> "$output_file"

    log_message "日志查询完成。请检查文件 '$output_file' 获取结果。"
}

# 执行主函数
main "$@"