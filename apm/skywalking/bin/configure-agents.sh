#!/bin/bash

# 获取脚本所在目录
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 加载配置文件
CONFIG_FILE="$SCRIPT_DIR/skywalking.conf"
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
else
    echo "错误: 配置文件不存在: $CONFIG_FILE"
    exit 1
fi

# 定义日志函数
log_info() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] $1"
}

log_warn() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [WARN] $1" >&2
}

log_error() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] $1" >&2
}

# 检查必要的目录和文件
check_prerequisites() {
    # 检查 webapps 目录
    if [ ! -d "/opt/webapps" ]; then
        log_error "webapps 目录不存在: /opt/webapps"
        exit 1
    fi
    
    # 检查是否有应用程序
    if [ -z "$(ls -A /opt/webapps 2>/dev/null)" ]; then
        log_warn "webapps 目录为空"
        return 1
    fi
    
    # 检查 skywalking-es7 目录
    local skywalking_es7_dir="/opt/skywalking-es7"
    if [ ! -d "$skywalking_es7_dir" ]; then
        log_error "skywalking-es7 目录不存在: $skywalking_es7_dir"
        exit 1
    fi
    
    # 检查配置脚本
    local config_script="$skywalking_es7_dir/cp-app-conf.sh"
    if [ ! -f "$config_script" ]; then
        log_error "配置脚本不存在: $config_script"
        exit 1
    fi
    
    if [ ! -x "$config_script" ]; then
        log_warn "配置脚本不可执行，尝试设置执行权限"
        chmod +x "$config_script"
    fi
    
    return 0
}

# 备份配置文件
backup_config() {
    local config_file=$1
    if [ -f "$config_file" ]; then
        local backup_file="${config_file}.backup.$(date +%Y%m%d_%H%M%S)"
        cp "$config_file" "$backup_file"
        log_info "已备份配置文件: $backup_file"
    fi
}

# 配置应用程序
configure_applications() {
    log_info "开始配置应用程序..."
    
    local app_count=0
    local success_count=0
    
    # 遍历应用程序目录
    for app_dir in /opt/webapps/*; do
        if [ -d "$app_dir" ]; then
            local app_name=$(basename "$app_dir")
            app_count=$((app_count + 1))
            
            log_info "配置应用: $app_name"
            
            # 执行配置脚本
            if /opt/skywalking-es7/cp-app-conf.sh "$app_name"; then
                success_count=$((success_count + 1))
                log_info "应用 $app_name 配置成功"
            else
                log_error "应用 $app_name 配置失败"
            fi
        fi
    done
    
    log_info "应用程序配置完成: $success_count/$app_count 成功"
    
    if [ $success_count -eq 0 ]; then
        log_error "没有应用程序配置成功"
        return 1
    fi
    
    return 0
}

# 配置 Agent
configure_agents() {
    log_info "开始配置 SkyWalking Agent..."
    
    local agent_configs=()
    local update_count=0
    
    # 查找所有 agent.config 文件
    while IFS= read -r -d '' config_file; do
        agent_configs+=("$config_file")
    done < <(find /opt/skywalking-es7/ -name "agent.config" -type f -print0)
    
    if [ ${#agent_configs[@]} -eq 0 ]; then
        log_warn "未找到任何 agent.config 文件"
        return 1
    fi
    
    log_info "找到 ${#agent_configs[@]} 个 agent 配置文件"
    
    # 更新每个配置文件
    for config_file in "${agent_configs[@]}"; do
        log_info "处理配置文件: $config_file"
        
        # 备份原配置
        backup_config "$config_file"
        
        # 更新 collector backend service 配置
        local old_pattern='collector\.backend_service=\${SW_AGENT_COLLECTOR_BACKEND_SERVICES:.*}'
        local new_value="collector.backend_service=\${SW_AGENT_COLLECTOR_BACKEND_SERVICES:localhost:$OAP_PORT}"
        
        if grep -q "$old_pattern" "$config_file"; then
            if sed -i "s#$old_pattern#$new_value#g" "$config_file"; then
                update_count=$((update_count + 1))
                log_info "已更新 collector 配置: $new_value"
            else
                log_error "更新配置文件失败: $config_file"
            fi
        else
            log_warn "配置文件中未找到匹配的模式: $config_file"
        fi
    done
    
    log_info "Agent 配置完成: $update_count/${#agent_configs[@]} 个文件已更新"
    
    if [ $update_count -eq 0 ]; then
        log_warn "没有配置文件被更新"
        return 1
    fi
    
    return 0
}

# 验证配置
verify_configuration() {
    log_info "验证配置..."
    
    # 检查端口连通性
    if netstat -tlnp 2>/dev/null | grep -q ":$OAP_PORT "; then
        log_info "OAP 服务端口 $OAP_PORT 可访问"
    else
        log_warn "OAP 服务端口 $OAP_PORT 不可访问"
    fi
    
    # 检查配置文件语法
    local agent_configs=()
    while IFS= read -r -d '' config_file; do
        agent_configs+=("$config_file")
    done < <(find /opt/skywalking-es7/ -name "agent.config" -type f -print0)
    
    for config_file in "${agent_configs[@]}"; do
        if grep -q "collector.backend_service=.*:$OAP_PORT" "$config_file"; then
            log_info "配置验证通过: $config_file"
        else
            log_warn "配置可能不正确: $config_file"
        fi
    done
}

# 主函数
main() {
    log_info "开始 SkyWalking 配置脚本..."
    
    # 检查先决条件
    if ! check_prerequisites; then
        log_error "先决条件检查失败"
        exit 1
    fi
    
    # 配置应用程序
    if ! configure_applications; then
        log_error "应用程序配置失败"
        exit 1
    fi
    
    # 配置 Agent
    if ! configure_agents; then
        log_error "Agent 配置失败"
        exit 1
    fi
    
    # 验证配置
    verify_configuration
    
    log_info "SkyWalking 配置脚本执行完成"
}

# 执行主函数
main "$@"
