#!/bin/bash
# ==================== JSON 配置验证模块 ====================
# 提供配置文件验证、检查和修复功能
# 兼容 V1 单体 JSON 和 V2 目录结构

# 验证单个 V2 工具配置文件
validate_v2_tool_file() {
    local file="$1"
    local errors=()
    local warnings=()

    if [[ ! -f "$file" ]]; then
        echo "❌ 文件不存在: $file"
        return 1
    fi

    if ! jq empty "$file" 2>/dev/null; then
        echo "❌ JSON 格式错误: $file"
        return 1
    fi

    # V2 必填字段
    local required=("id" "name" "description" "install" "commands")
    for field in "${required[@]}"; do
        if ! jq -e ".$field" "$file" >/dev/null 2>&1; then
            errors+=("缺少必填字段: $field")
        fi
    done

    # 检查 install.methods 数组
    local method_count
    method_count=$(jq '.install.methods | length // 0' "$file" 2>/dev/null || echo "0")
    if [[ "$method_count" -eq 0 ]]; then
        errors+=("install.methods 为空")
    else
        for i in $(seq 0 $((method_count - 1))); do
            local mtype mcmd
            mtype=$(jq -r ".install.methods[$i].type // \"unknown\"" "$file" 2>/dev/null)
            mcmd=$(jq -r ".install.methods[$i].command // \"\"" "$file" 2>/dev/null)

            if [[ "$mcmd" == "null" || -z "$mcmd" ]]; then
                warnings+=("安装命令 #$(($i+1)) 为空")
            fi

            # 检查无效占位符
            if [[ "$mcmd" == *"null"* && "$mcmd" != *"// null"* ]]; then
                warnings+=("安装命令 #$(($i+1)) 包含 'null' 占位符")
            fi
        done
    fi

    # 检查 commands 字段
    local cmd_start
    cmd_start=$(jq -r '.commands.start // ""' "$file" 2>/dev/null)
    if [[ "$cmd_start" == "null" || -z "$cmd_start" ]]; then
        warnings+=("commands.start 为空")
    fi

    # 检查硬编码路径
    local hardcoded
    hardcoded=$(jq -r '.. | strings | select(test("/Users/[a-z]+"))' "$file" 2>/dev/null | head -3)
    if [[ -n "$hardcoded" ]]; then
        warnings+=("发现硬编码个人路径:")
        while IFS= read -r p; do
            [[ -n "$p" ]] && warnings+=("  $p")
        done <<< "$hardcoded"
    fi

    # 输出结果
    local tool_name
    tool_name=$(jq -r '.name // "未知"' "$file" 2>/dev/null)
    local status="✅"
    [[ ${#errors[@]} -gt 0 ]] && status="❌"
    echo "  $status $tool_name ($(basename "$file"))"

    for e in "${errors[@]}"; do echo "    ❌ $e"; done
    for w in "${warnings[@]}"; do echo "    ⚠️  $w"; done

    [[ ${#errors[@]} -gt 0 ]] && return 1
    return 0
}

# 验证 V2 配置目录结构
validate_v2_config() {
    local config_dir="$1"
    local total=0
    local passed=0
    local failed=0

    echo "======================================"
    echo "📊 V2 配置验证报告"
    echo "======================================"
    echo ""

    if [[ ! -d "$config_dir" ]]; then
        echo "❌ 配置目录不存在: $config_dir"
        return 1
    fi

    # 验证 global.json
    echo "🌐 全局配置 (global.json):"
    if [[ -f "$config_dir/global.json" ]]; then
        if jq empty "$config_dir/global.json" 2>/dev/null; then
            echo "  ✅ JSON 格式正确"
            # 检查必要字段
            for field in npm_registry proxy; do
                if jq -e ".$field" "$config_dir/global.json" >/dev/null 2>&1; then
                    echo "  ✅ $field 配置存在"
                else
                    echo "  ⚠️  $field 配置缺失"
                fi
            done
        else
            echo "  ❌ JSON 格式错误"
            ((failed++))
        fi
    else
        echo "  ⚠️  global.json 不存在"
    fi
    echo ""

    # 验证工具配置
    echo "🛠️  工具配置 (conf/tools/):"
    if [[ -d "$config_dir/tools" ]]; then
        for f in "$config_dir/tools"/*.json; do
            [[ "$(basename "$f")" == "_template.json" ]] && continue
            [[ -f "$f" ]] || continue
            ((total++))
            if validate_v2_tool_file "$f"; then
                ((passed++))
            else
                ((failed++))
            fi
        done
    else
        echo "  ⚠️  tools 目录不存在"
    fi
    echo ""

    # 验证共享 MCP
    echo "🔌 共享 MCP 服务器:"
    if [[ -d "$config_dir/shared/mcp-servers" ]]; then
        local mcp_count=0
        local valid_scenarios
        valid_scenarios=$(jq -r '.scenarios | keys[]' "$config_dir/global.json" 2>/dev/null || echo "")

        for f in "$config_dir/shared/mcp-servers"/*.json; do
            [[ -f "$f" ]] || continue
            ((mcp_count++))
            if jq empty "$f" 2>/dev/null; then
                local mcp_name
                mcp_name=$(jq -r '.name // "未知"' "$f" 2>/dev/null)
                
                local err_flag=0
                
                # Check category
                local category
                category=$(jq -r '.category // ""' "$f" 2>/dev/null)
                if [[ -z "$category" || "$category" == "null" ]]; then
                    echo "  ❌ [$mcp_name] 缺少 category 或为空: $(basename "$f")"
                    err_flag=1
                fi
                
                # Check scenarios
                local scenarios
                scenarios=$(jq -r '.scenarios[]?' "$f" 2>/dev/null)
                if [[ -z "$scenarios" ]]; then
                    echo "  ❌ [$mcp_name] 缺少 scenarios 数组或为空: $(basename "$f")"
                    err_flag=1
                else
                    for sc in $scenarios; do
                        if ! echo "$valid_scenarios" | grep -q "^$sc$"; then
                            echo "  ❌ [$mcp_name] 未注册的 scenario '$sc' (需在 global.json 注册): $(basename "$f")"
                            err_flag=1
                        fi
                    done
                fi
                
                if [[ $err_flag -eq 0 ]]; then
                    echo "  ✅ $mcp_name"
                else
                    ((failed++))
                fi
            else
                echo "  ❌ JSON 格式错误: $(basename "$f")"
                ((failed++))
            fi
        done
        [[ $mcp_count -eq 0 ]] && echo "  ℹ️  无共享 MCP 配置"
    else
        echo "  ℹ️  shared/mcp-servers 目录不存在"
    fi
    echo ""

    # 验证共享 Skills
    echo "🎯 共享 Skills:"
    if [[ -d "$config_dir/shared/skills" ]]; then
        local skill_count=0
        for f in "$config_dir/shared/skills"/*.json; do
            [[ -f "$f" ]] || continue
            ((skill_count++))
            if jq empty "$f" 2>/dev/null; then
                local skill_name
                skill_name=$(jq -r '.name // "未知"' "$f" 2>/dev/null)
                
                local err_flag=0
                
                # Check category
                local category
                category=$(jq -r '.category // ""' "$f" 2>/dev/null)
                if [[ -z "$category" || "$category" == "null" ]]; then
                    echo "  ❌ [$skill_name] 缺少 category 或为空: $(basename "$f")"
                    err_flag=1
                fi
                
                # Check scenarios
                local scenarios
                scenarios=$(jq -r '.scenarios[]?' "$f" 2>/dev/null)
                if [[ -z "$scenarios" ]]; then
                    echo "  ❌ [$skill_name] 缺少 scenarios 数组或为空: $(basename "$f")"
                    err_flag=1
                else
                    for sc in $scenarios; do
                        if ! echo "$valid_scenarios" | grep -q "^$sc$"; then
                            echo "  ❌ [$skill_name] 未注册的 scenario '$sc' (需在 global.json 注册): $(basename "$f")"
                            err_flag=1
                        fi
                    done
                fi
                
                if [[ $err_flag -eq 0 ]]; then
                    echo "  ✅ $skill_name"
                else
                    ((failed++))
                fi
            else
                echo "  ❌ JSON 格式错误: $(basename "$f")"
                ((failed++))
            fi
        done
        [[ $skill_count -eq 0 ]] && echo "  ℹ️  无共享 Skills 配置"
    else
        echo "  ℹ️  shared/skills 目录不存在"
    fi
    echo ""

    # 总结
    echo "======================================"
    echo "📈 总计: $total 个工具配置"
    echo "   ✅ 通过: $passed"
    echo "   ❌ 失败: $failed"
    echo "======================================"

    [[ $failed -gt 0 ]] && return 1
    return 0
}

# 兼容 V1 格式验证（保留原有功能）
validate_config_file() {
    local config_file="$1"
    local errors=()
    local warnings=()

    if [[ ! -f "$config_file" ]]; then
        echo "❌ 配置文件不存在: $config_file"
        return 1
    fi

    if ! jq empty "$config_file" 2>/dev/null; then
        echo "❌ JSON 格式错误: $config_file"
        return 1
    fi

    echo "✅ JSON 格式验证通过"

    # 检查必填字段（V1）
    local required_fields=("npm_registry" "tools" "mcp_servers" "skills")
    for field in "${required_fields[@]}"; do
        if ! jq -e ".$field" "$config_file" >/dev/null 2>&1; then
            errors+=("缺少必填字段: $field")
        fi
    done

    # 检查工具配置
    local tool_count
    tool_count=$(jq '.tools | length' "$config_file" 2>/dev/null || echo 0)
    echo "📦 发现 $tool_count 个工具配置"

    for i in $(seq 0 $((tool_count - 1))); do
        local tool_id tool_name tool_type tool_package
        tool_id=$(jq -r ".tools[$i].id" "$config_file" 2>/dev/null)
        tool_name=$(jq -r ".tools[$i].name" "$config_file" 2>/dev/null)
        tool_type=$(jq -r ".tools[$i].type" "$config_file" 2>/dev/null)
        tool_package=$(jq -r ".tools[$i].package" "$config_file" 2>/dev/null)

        if [[ "$tool_type" != "npm" && "$tool_type" != "pip" && "$tool_type" != "bash" && "$tool_type" != "brew" ]]; then
            warnings+=("工具 [$tool_id] 类型未知: $tool_type")
        fi

        if [[ -z "$tool_package" || "$tool_package" == "null" ]]; then
            warnings+=("工具 [$tool_id] 缺少 package 字段")
        fi

        if ! jq -e ".tools[$i].version_check" "$config_file" >/dev/null 2>&1; then
            warnings+=("工具 [$tool_id] 缺少 version_check 配置")
        fi
    done

    # 检查 MCP 服务器
    local mcp_count
    mcp_count=$(jq '.mcp_servers | length' "$config_file" 2>/dev/null || echo 0)
    echo "🔌 发现 $mcp_count 个 MCP 服务器配置"

    # 检查硬编码路径
    local hardcoded_paths
    hardcoded_paths=$(jq -r '.. | strings | select(test("/Users/[a-z]+"))' "$config_file" 2>/dev/null | head -5)
    if [[ -n "$hardcoded_paths" ]]; then
        warnings+=("发现硬编码的个人路径:")
        while IFS= read -r path; do
            warnings+=("  - $path")
        done <<< "$hardcoded_paths"
    fi

    # Skills
    local skill_count
    skill_count=$(jq '.skills | length' "$config_file" 2>/dev/null || echo 0)
    echo "🎯 发现 $skill_count 个 Skills 配置"

    echo ""
    if [[ ${#errors[@]} -gt 0 ]]; then
        echo "❌ 错误 (${#errors[@]}):"
        for error in "${errors[@]}"; do
            echo "   - $error"
        done
    fi

    if [[ ${#warnings[@]} -gt 0 ]]; then
        echo "⚠️  警告 (${#warnings[@]}):"
        for warning in "${warnings[@]}"; do
            echo "   - $warning"
        done
    fi

    if [[ ${#errors[@]} -eq 0 && ${#warnings[@]} -eq 0 ]]; then
        echo "✅ 配置验证通过，无错误和警告"
    fi

    [[ ${#errors[@]} -gt 0 ]] && return 1
    return 0
}

# 检查占位符
check_placeholders() {
    local config_file="$1"
    echo "🔍 检查配置占位符..."

    local placeholders
    placeholders=$(grep -oE '__[A-Z_]+__|{{[a-z_]+}}' "$config_file" 2>/dev/null | sort -u)

    if [[ -n "$placeholders" ]]; then
        echo "⚠️  发现以下占位符，需要替换为实际值:"
        while IFS= read -r p; do
            echo "   - $p"
        done <<< "$placeholders"
    else
        echo "✅ 未发现占位符"
    fi
}

# 生成配置报告
generate_config_report() {
    local config_file="$1"

    if [[ ! -f "$config_file" ]]; then
        echo "❌ 配置文件不存在: $config_file"
        return 1
    fi

    echo "======================================"
    echo "📊 AI CLI 配置报告"
    echo "======================================"
    echo ""

    echo "📝 基本信息:"
    echo "   NPM 镜像: $(jq -r '.npm_registry' "$config_file" 2>/dev/null)"
    echo "   文档目录: $(jq -r '.docs_dir' "$config_file" 2>/dev/null)"
    echo ""

    echo "🌐 代理配置:"
    local http_proxy https_proxy git_proxy pip_proxy
    http_proxy=$(jq -r '.proxy.http // "未配置"' "$config_file" 2>/dev/null)
    https_proxy=$(jq -r '.proxy.https // "未配置"' "$config_file" 2>/dev/null)
    git_proxy=$(jq -r '.proxy.git_url_replace // "未配置"' "$config_file" 2>/dev/null)
    pip_proxy=$(jq -r '.proxy.pip // "未配置"' "$config_file" 2>/dev/null)
    echo "   HTTP 代理: ${http_proxy:-未配置}"
    echo "   HTTPS 代理: ${https_proxy:-未配置}"
    echo "   Git 代理: ${git_proxy:-未配置}"
    echo "   PIP 代理: ${pip_proxy:-未配置}"
    echo ""

    echo "🛠️  工具统计:"
    echo "   NPM 工具: $(jq '[.tools[] | select(.type == "npm")] | length' "$config_file" 2>/dev/null)"
    echo "   PIP 工具: $(jq '[.tools[] | select(.type == "pip")] | length' "$config_file" 2>/dev/null)"
    echo "   Bash 工具: $(jq '[.tools[] | select(.type == "bash")] | length' "$config_file" 2>/dev/null)"
    echo "   Brew 工具: $(jq '[.tools[] | select(.type == "brew")] | length' "$config_file" 2>/dev/null)"
    echo ""

    echo "🔌 MCP 服务器类型:"
    echo "   NPM 包: $(jq '[.mcp_servers[] | select(.type == "npm")] | length' "$config_file" 2>/dev/null)"
    echo "   PIP 包: $(jq '[.mcp_servers[] | select(.type == "pip")] | length' "$config_file" 2>/dev/null)"
    echo ""

    echo "🎯 Skills 分类:"
    jq -r '.skills | to_entries[] | "   \(.value.category): \(.value.name)"' "$config_file" 2>/dev/null
    echo ""

    echo "======================================"
}
