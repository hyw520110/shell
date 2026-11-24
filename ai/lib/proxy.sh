#!/bin/bash

# ==================== 代理检测模块 ====================
# 代理相关变量已在首次引用时初始化
# 这里提供检测和验证功能

# 代理连通性测试配置
readonly PROXY_TEST_URL="https://www.google.com"
readonly PROXY_TEST_TIMEOUT=2

# 检测代理连通性
# 参数: $1 - 代理地址 (如 http://127.0.0.1:7890)
# 返回: 0 表示可用, 1 表示不可用
test_proxy_connectivity() {
    local proxy_addr="$1"
    local test_url="${PROXY_TEST_URL}"
    local timeout_sec="${PROXY_TEST_TIMEOUT}"
    
    if [[ -z "$proxy_addr" ]]; then
        return 1
    fi
    
    # 提取代理主机和端口
    local proxy_host=""
    local proxy_port=""
    
    if [[ "$proxy_addr" =~ ^https?://([^:]+):([0-9]+) ]]; then
        proxy_host="${BASH_REMATCH[1]}"
        proxy_port="${BASH_REMATCH[2]}"
    elif [[ "$proxy_addr" =~ ^([^:]+):([0-9]+) ]]; then
        proxy_host="${BASH_REMATCH[1]}"
        proxy_port="${BASH_REMATCH[2]}"
    else
        debug_log "无法解析代理地址: $proxy_addr"
        return 1
    fi
    
    # 方法1: 使用 nc 检测端口连通性（最快）
    if command -v nc >/dev/null 2>&1; then
        if nc -z -w $timeout_sec "$proxy_host" "$proxy_port" 2>/dev/null; then
            debug_log "代理端口连通 (nc): $proxy_host:$proxy_port"
            return 0
        fi
    fi
    
    # 方法2: 使用 curl 检测代理
    if command -v curl >/dev/null 2>&1; then
        if curl -x "$proxy_addr" --max-time 5 -s -o /dev/null -w "%{http_code}" \
           --connect-timeout $timeout_sec -m $((timeout_sec + 2)) \
           "$test_url" 2>/dev/null | grep -q "200\|301\|302\|403"; then
            debug_log "代理连通 (curl): $proxy_addr"
            return 0
        fi
    fi
    
    # 方法3: 使用 wget 检测代理
    if command -v wget >/dev/null 2>&1; then
        if wget -e use_proxy=yes -e http_proxy="$proxy_addr" \
           -q --timeout=$timeout_sec --spider "$test_url" 2>/dev/null; then
            debug_log "代理连通 (wget): $proxy_addr"
            return 0
        fi
    fi
    
    debug_log "代理不可达: $proxy_addr"
    return 1
}

# 检测并验证代理配置
check_proxy_connectivity() {
    # 如果已经检测过，直接返回缓存结果
    if [[ "$proxy_checked" == true ]]; then
        return 0
    fi
    
    proxy_checked=true
    local proxy_list=()
    local detected_from=""  # 记录代理来源
    
    debug_log "检测代理配置..."
    
    # 1. 收集配置文件中的代理
    if [[ -n "$proxy_http" && "$proxy_http" != "null" && "$proxy_http" != "" ]]; then
        proxy_list+="http:$proxy_http"
        detected_from="配置文件"
    fi
    if [[ -n "$proxy_https" && "$proxy_https" != "null" && "$proxy_https" != "" ]]; then
        proxy_list+="https:$proxy_https"
        [[ -z "$detected_from" ]] && detected_from="配置文件"
    fi
    if [[ -n "$proxy_pip" && "$proxy_pip" != "null" && "$proxy_pip" != "" ]]; then
        proxy_list+="pip:$proxy_pip"
        [[ -z "$detected_from" ]] && detected_from="配置文件"
    fi
    
    # 2. 如果配置文件中没有代理，检测系统环境变量
    if [[ ${#proxy_list[@]} -eq 0 ]]; then
        debug_log "配置文件中未找到代理，检测系统环境变量..."
        
        local env_http="${HTTP_PROXY:-${http_proxy:-}}"
        local env_https="${HTTPS_PROXY:-${https_proxy:-}}"
        local env_all="${ALL_PROXY:-${all_proxy:-}}"
        
        if [[ -n "$env_http" ]]; then
            proxy_list+="http:$env_http"
            proxy_http="$env_http"
            detected_from="环境变量 HTTP_PROXY"
        fi
        if [[ -n "$env_https" ]]; then
            proxy_list+="https:$env_https"
            proxy_https="$env_https"
            [[ -z "$detected_from" ]] && detected_from="环境变量 HTTPS_PROXY"
        fi
        if [[ -n "$env_all" && -z "$env_http" && -z "$env_https" ]]; then
            proxy_list+="all:$env_all"
            proxy_http="$env_all"
            proxy_https="$env_all"
            detected_from="环境变量 ALL_PROXY"
        fi
    fi
    
    # 3. 如果没有代理，静默返回
    if [[ ${#proxy_list[@]} -eq 0 ]]; then
        debug_log "未检测到代理配置，使用直连模式"
        proxy_available=false
        return 0
    fi
    
    debug_log "代理来源: ${detected_from}"
    
    # 4. 检测每个代理的连通性
    local available_count=0
    for proxy_entry in "${proxy_list[@]}"; do
        local proxy_type="${proxy_entry%%:*}"
        local proxy_addr="${proxy_entry#*:}"
        
        if [[ -n "$proxy_addr" ]]; then
            if test_proxy_connectivity "$proxy_addr"; then
                debug_log "代理 ${proxy_type} ($proxy_addr) 可用"
                ((available_count++))
            else
                warn_log "代理 ${proxy_type} ($proxy_addr) 不可达，已禁用"
                
                # 禁用不可用的代理
                case "$proxy_type" in
                    "http") proxy_http="" ;;
                    "https") proxy_https="" ;;
                    "pip") proxy_pip="" ;;
                    "all") proxy_http=""; proxy_https="" ;;
                esac
            fi
        fi
    done
    
    # 5. 检查是否还有可用的代理
    if [[ $available_count -eq 0 ]]; then
        warn_log "所有代理均不可用，将使用直连模式"
        proxy_http=""
        proxy_https=""
        proxy_pip=""
        proxy_available=false
    else
        proxy_available=true
    fi
    
    return 0
}

# ==================== GitHub 镜像源模块 ====================

# GitHub 镜像源全局常量（可在 global.json 中覆盖）
# 使用方法: ${GITHUB_MIRROR_RAW}/user/repo/branch/path
GITHUB_MIRROR_RAW="${GITHUB_MIRROR_RAW:-https://gh-proxy.com/https://raw.githubusercontent.com}"
GITHUB_MIRROR_REPO="${GITHUB_MIRROR_REPO:-https://gh-proxy.com/https://github.com}"

# GitHub 镜像源列表（按优先级排序，用于自动选择）
readonly GITHUB_MIRRORS=(
    "https://gh-proxy.com/https://raw.githubusercontent.com"
    "https://mirror.ghproxy.com/https://raw.githubusercontent.com"
    "https://raw.githubusercontent.com"
)



