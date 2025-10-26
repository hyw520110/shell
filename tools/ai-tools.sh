#!/bin/bash

# AI工具安装器，支持多种AI CLI工具
# 兼容Linux和macOS系统

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # 无颜色

# 加载外部配置
source ai-tools.conf

# 将配置文件中的数组赋值给脚本变量
TOOLS=("${tools[@]}")

# 提取MCP服务器名称列表
MCP_SERVERS_NAMES=()
for server in "${mcp_servers[@]}"; do
    name=$(echo $server | cut -d: -f1)
    MCP_SERVERS_NAMES+=("$name")
done

# 通用MCP配置映射函数 - 将MCP名称转换为变量名
get_server_config_var() {
    local server_name=$1
    # 将连字符替换为无字符，生成bash兼容的变量名
    local var_name="mcp_$(echo $server_name | sed 's/-//g')"
    # 验证变量是否存在 - 使用兼容方式检查变量是否存在
    if eval "[[ -n \"\${$var_name+x}\" ]]"; then
        echo $var_name
    else
        # 如果转换后的变量不存在，返回空
        echo ""
    fi
}

# 通用获取服务器配置的函数
get_server_config() {
    local server_name=$1
    local var_name=$(get_server_config_var "$server_name")
    if [[ -n "$var_name" ]]; then
        local value
        eval "value=\${$var_name}"
        echo "$value"
    else
        echo ""
    fi
}


# 工具状态全局变量
TOOL_STATUS=()

# 已安装且支持MCP的工具列表
INSTALLED_MCP_TOOLS=()
INSTALLED_MCP_CONFIGS=()

# 检测操作系统
detect_os() {
    if [[ "$(uname)" == "Darwin" ]]; then
        OS="macOS"
    elif [[ "$(uname)" == "Linux" ]]; then
        OS="Linux"
    else
        echo -e "${RED}❌ 不支持的操作系统${NC}"
        exit 1
    fi
}

# 检查命令是否存在
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# 通用npm安装函数
install_with_npm() {
    local tool_name=$1
    local package_name=$2
    
    echo -e "${CYAN}🚀 安装 $tool_name...${NC}"
    
    # 检查npm是否已安装
    if ! command_exists npm; then
        echo -e "${RED}❌ 未找到 npm。请先安装 Node.js。${NC}"
        return 1
    fi
    
    echo -e "${CYAN}📦 通过 npm 安装 $tool_name...${NC}"
    
    # 尝试安装，捕获输出用于调试
    if npm install -g "$package_name" > /tmp/install.log 2>&1; then
        echo -e "${GREEN}✅ $tool_name 安装成功!${NC}"
        return 0
    else
        echo -e "${RED}❌ $tool_name 安装失败${NC}"
        echo -e "${YELLOW}查看 /tmp/install.log 获取详细信息${NC}"
        return 1
    fi
}

# 通用npm更新函数
update_with_npm() {
    local tool_name=$1
    local package_name=$2
    
    echo -e "${CYAN}🔄 更新 $tool_name...${NC}"
    
    # 检查npm是否已安装
    if ! command_exists npm; then
        echo -e "${RED}❌ 未找到 npm${NC}"
        return 1
    fi
    
    echo -e "${CYAN}🔄 通过 npm 更新 $tool_name...${NC}"
    
    # 尝试更新，捕获输出用于调试
    if npm update -g "$package_name" > /tmp/update.log 2>&1; then
        echo -e "${GREEN}✅ $tool_name 更新成功!${NC}"
        return 0
    else
        echo -e "${RED}❌ $tool_name 更新失败${NC}"
        echo -e "${YELLOW}查看 /tmp/update.log 获取详细信息${NC}"
        return 1
    fi
}

# 通用brew安装函数（仅macOS）
install_with_brew() {
    local tool_name=$1
    local package_name=$2
    
    echo -e "${CYAN}🚀 安装 $tool_name...${NC}"
    
    # 检查Homebrew是否已安装
    if ! command_exists brew; then
        echo -e "${YELLOW}⚠️ 未找到 Homebrew。正在安装 Homebrew...${NC}"
        if ! /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" > /dev/null 2>&1; then
            echo -e "${RED}❌ Homebrew 安装失败${NC}"
            return 1
        fi
    fi
    
    echo -e "${CYAN}📦 通过 Homebrew 安装 $tool_name...${NC}"
    
    # 尝试安装，如果brew失败则回退到npm
    if brew install "$package_name" > /tmp/install.log 2>&1; then
        echo -e "${GREEN}✅ $tool_name 安装成功!${NC}"
        return 0
    else
        echo -e "${YELLOW}⚠️ Homebrew 安装失败，尝试通过 npm 安装...${NC}"
        install_with_npm "$tool_name" "$package_name"
        return $?
    fi
}

# 通用brew更新函数（仅macOS）
update_with_brew() {
    local tool_name=$1
    local package_name=$2
    
    echo -e "${CYAN}🔄 更新 $tool_name...${NC}"
    
    # 检查Homebrew是否已安装
    if ! command_exists brew; then
        echo -e "${RED}❌ 未找到 Homebrew${NC}"
        return 1
    fi
    
    echo -e "${CYAN}🔄 通过 Homebrew 更新 $tool_name...${NC}"
    
    # 尝试更新，如果brew失败则回退到npm
    if brew upgrade "$package_name" > /tmp/update.log 2>&1; then
        echo -e "${GREEN}✅ $tool_name 更新成功!${NC}"
        return 0
    else
        echo -e "${YELLOW}⚠️ Homebrew 更新失败，尝试通过 npm 更新...${NC}"
        update_with_npm "$tool_name" "$package_name"
        return $?
    fi
}

# 检查已安装的工具
check_tools() {
    echo -e "${CYAN}🔍 检查已安装的AI工具...${NC}"
    TOOL_STATUS=()
    INSTALLED_MCP_TOOLS=()
    INSTALLED_MCP_CONFIGS=()
    
    local i=1
    for tool in "${TOOLS[@]}"; do
        local cmd=$(echo $tool | cut -d: -f1)
        local name=$(echo $tool | cut -d: -f2)
        local config_path=$(echo $tool | cut -d: -f5)
        
        if command_exists "$cmd"; then
            local version=$($cmd --version 2>/dev/null || echo "unknown")
            echo -e "$i. ${GREEN}✅ $name${NC} ($version) - 已安装"
            TOOL_STATUS+=("true")
            
            # 如果该工具支持MCP（配置路径非空），则添加到MCP工具列表
            if [[ -n "$config_path" ]]; then
                INSTALLED_MCP_TOOLS+=("$name")
                INSTALLED_MCP_CONFIGS+=("$config_path")
            fi
        else
            echo -e "$i. ${YELLOW}⚠️ $name${NC} - 未安装"
            TOOL_STATUS+=("false")
        fi
        ((i++))
    done
}

# 根据索引安装工具
install_tool() {
    local index=$1
    local tool=${TOOLS[$index]}
    
    local cmd=$(echo $tool | cut -d: -f1)
    local name=$(echo $tool | cut -d: -f2)
    local package=$(echo $tool | cut -d: -f3)
    local type=$(echo $tool | cut -d: -f4)
    
    case $type in
        npm)
            install_with_npm "$name" "$package"
            ;;
        brew)
            if [[ "$OS" == "macOS" ]]; then
                install_with_brew "$name" "$package"
            else
                install_with_npm "$name" "$package"
            fi
            ;;
        config)
            case $cmd in
                mcp-servers)
                    manage_mcp_servers
                    ;;
                *)
                    echo -e "${RED}❌ 未知的配置类型: $cmd${NC}"
                    return 1
                    ;;
            esac
            ;;
        *)
            echo -e "${RED}❌ 不支持的安装类型: $type${NC}"
            return 1
            ;;
    esac
    
    # 重新检查工具状态
    check_tools
}

# 根据索引更新工具
update_tool() {
    local index=$1
    local tool=${TOOLS[$index]}
    
    local cmd=$(echo $tool | cut -d: -f1)
    local name=$(echo $tool | cut -d: -f2)
    local package=$(echo $tool | cut -d: -f3)
    local type=$(echo $tool | cut -d: -f4)
    
    case $type in
        npm)
            update_with_npm "$name" "$package"
            ;;
        brew)
            if [[ "$OS" == "macOS" ]]; then
                update_with_brew "$name" "$package"
            else
                update_with_npm "$name" "$package"
            fi
            ;;
        config)
            case $cmd in
                mcp-servers)
                    manage_mcp_servers
                    ;;
                *)
                    echo -e "${RED}❌ 未知的配置类型: $cmd${NC}"
                    return 1
                    ;;
            esac
            ;;
        *)
            echo -e "${RED}❌ 不支持的更新类型: $type${NC}"
            return 1
            ;;
    esac
    
    # 重新检查工具状态
    check_tools
}

# 显示主菜单
show_menu() {
    echo -e "\n按需选择:"
    
    local i=1
    for tool in "${TOOLS[@]}"; do
        local cmd=$(echo $tool | cut -d: -f1)
        local name=$(echo $tool | cut -d: -f2)
        
        if [ "${TOOL_STATUS[$((i-1))]}" = "true" ]; then
            echo -e "$i. ${GREEN}✅ 更新 $name${NC}"
        else
            echo -e "$i. ${YELLOW}📥 安装 $name${NC}"
        fi
        ((i++))
    done
    
    # 添加MCP服务器配置选项
    echo -e "m. 🔧 ${CYAN}管理 MCP 服务器配置${NC}"
    echo -e "r. 🔄 ${CYAN}刷新${NC}"
    echo -e "q. 🚪 ${RED}退出${NC}"
    echo ""
}

# 创建默认配置文件
create_default_config() {
    local config_file=$1
    local tool_name=$2
    
    local config_dir=$(dirname "$config_file")
    if [[ ! -d "$config_dir" ]]; then
        echo -e "${YELLOW}⚠️ 配置目录不存在，创建: $config_dir${NC}"
        mkdir -p "$config_dir"
    fi
    
    if [[ ! -f "$config_file" ]]; then
        echo -e "${YELLOW}⚠️ 配置文件不存在，创建默认配置: $config_file${NC}"
        case $tool_name in
            "Qwen CLI")
                cat > "$config_file" << 'EOF'
{
  "hasSeenIdeIntegrationNudge": true,
  "selectedAuthType": "qwen-oauth",
  "mcpServers": {}
}
EOF
                ;;
            "Gemini CLI")
                cat > "$config_file" << 'EOF'
{
  "hasSeenIdeIntegrationNudge": true,
  "mcpServers": {}
}
EOF
                ;;
            *)
                cat > "$config_file" << 'EOF'
{
  "mcpServers": {}
}
EOF
                ;;
        esac
    fi
}

# 管理 MCP 服务器配置
manage_mcp_servers() {
    echo -e "${CYAN}🔧 管理 MCP 服务器配置...${NC}"
    
    
    # 为每个支持的AI工具检查并创建配置目录和文件
    local idx
    for idx in "${!INSTALLED_MCP_TOOLS[@]}"; do
        local ai_tool="${INSTALLED_MCP_TOOLS[$idx]}"
        local config_file="${INSTALLED_MCP_CONFIGS[$idx]}"
        create_default_config "$config_file" "$ai_tool"
    done
    
    # 显示所有AI工具的配置文件路径
    echo -e "${GREEN}✅ AI 工具配置文件路径:${NC}"
    for idx in "${!INSTALLED_MCP_TOOLS[@]}"; do
        local config_file="${INSTALLED_MCP_CONFIGS[$idx]}"
        echo -e "  $idx: $config_file"
    done
    echo ""
    
    # 显示所有AI工具的当前 MCP 服务器配置
    echo -e "${CYAN}📋 所有 AI 工具的当前 MCP 服务器配置:${NC}"
    if command -v jq >/dev/null 2>&1; then
        local has_config=false
        for idx in "${!INSTALLED_MCP_TOOLS[@]}"; do
            local ai_tool="${INSTALLED_MCP_TOOLS[$idx]}"
            local config_file="${INSTALLED_MCP_CONFIGS[$idx]}"
            if [[ -f "$config_file" ]] && [[ -s "$config_file" ]]; then
                local server_count=$(jq -r '.mcpServers | length' "$config_file" 2>/dev/null)
                if [[ "$server_count" != "0" ]] && [[ "$server_count" != "null" ]]; then
                    echo -e "  ${ai_tool} (${config_file}):"
                    jq -r '.mcpServers | to_entries[] | "    - \(.key): \(.value.command) \(.value.args // [])"' "$config_file" 2>/dev/null || echo "    无配置的 MCP 服务器"
                    has_config=true
                fi
            fi
        done
        
        if [[ "$has_config" == false ]]; then
            echo "  无配置的 MCP 服务器"
        fi
    else
        echo -e "${YELLOW}⚠️ 未安装 jq，无法解析配置文件。请先安装 jq 以获得更好的体验。${NC}"
        # 简单显示各配置文件是否存在
        for idx in "${!INSTALLED_MCP_TOOLS[@]}"; do
            local ai_tool="${INSTALLED_MCP_TOOLS[$idx]}"
            local config_file="${INSTALLED_MCP_CONFIGS[$idx]}"
            if [[ -f "$config_file" ]] && [[ -s "$config_file" ]]; then
                echo -e "  ${ai_tool}: $config_file (存在)"
            else
                echo -e "  ${ai_tool}: $config_file (不存在或为空)"
            fi
        done
    fi

    # 提供选项来管理 MCP 服务器
    echo -e "MCP 服务器管理选项:"
    echo -e "1. ${GREEN}添加常用 MCP 服务器支持${NC}"
    echo -e "2. ${YELLOW}查看详细的 MCP 配置${NC}"
    echo -e "3. ${RED}重置 MCP 配置${NC}"
    echo -e "4. ${BLUE}返回主菜单${NC}"
    echo ""
    
    read -p "请选择操作 (1-4): " mcp_choice
    
    case $mcp_choice in
        1)
            add_common_mcp_servers
            ;;
        2)
            echo -e "${CYAN}🔍 详细 MCP 配置信息:${NC}"
            for idx in "${!INSTALLED_MCP_TOOLS[@]}"; do
                local ai_tool="${INSTALLED_MCP_TOOLS[$idx]}"
                local config_file="${INSTALLED_MCP_CONFIGS[$idx]}"
                echo -e "${CYAN}$ai_tool 配置 (${config_file}):${NC}"
                if [[ -f "$config_file" ]]; then
                    cat "$config_file" | jq '.' 2>/dev/null || cat "$config_file"
                else
                    echo "  配置文件不存在"
                fi
                echo ""
            done
            ;;
        3)
            echo -e "${YELLOW}⚠️ 选择要重置 MCP 配置的 AI 工具:${NC}"
            local i=0
            local tool_names=()
            local config_paths=()
            for ai_tool in "${INSTALLED_MCP_TOOLS[@]}"; do
                echo -e "$i. $ai_tool"
                tool_names[$i]="$ai_tool"
                config_paths[$i]="${INSTALLED_MCP_CONFIGS[$i]}"
                ((i++))
            done
            echo ""
            
            read -p "请选择 AI 工具 (0-$((i-1))): " tool_choice
            
            if [[ $tool_choice -ge 0 && $tool_choice -lt $i ]]; then
                local selected_tool="${tool_names[$tool_choice]}"
                local config_file="${config_paths[$tool_choice]}"
                
                echo -e "${YELLOW}⚠️ 此操作将清除 $selected_tool 的所有 MCP 服务器配置，是否继续？(y/N)${NC}"
                read -p "确认 (y/N): " confirm
                if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
                    # 重置配置，只保留基本结构
                    local tool_base_name=$(echo "$selected_tool" | cut -d' ' -f1)
                    case $tool_base_name in
                        "Qwen")
                            cat > "$config_file" << 'EOF'
{
  "hasSeenIdeIntegrationNudge": true,
  "selectedAuthType": "qwen-oauth",
  "mcpServers": {}
}
EOF
                            ;;
                        "Gemini")
                            cat > "$config_file" << 'EOF'
{
  "hasSeenIdeIntegrationNudge": true,
  "mcpServers": {}
}
EOF
                            ;;
                        *)
                            cat > "$config_file" << 'EOF'
{
  "mcpServers": {}
}
EOF
                            ;;
                    esac
                    echo -e "${GREEN}✅ $selected_tool 的 MCP 配置已重置${NC}"
                else
                    echo -e "${YELLOW}❌ 操作已取消${NC}"
                fi
            else
                echo -e "${RED}❌ 无效选项${NC}"
            fi
            ;;
        4)
            echo -e "${GREEN}🔙 返回主菜单${NC}"
            ;;
        *)
            echo -e "${RED}❌ 无效选项${NC}"
            ;;
    esac
}

# 添加常用 MCP 服务器
add_common_mcp_servers() {
    echo -e "${CYAN}🔧 添加常用 MCP 服务器支持:${NC}"
    
    # 显示可用的MCP服务器
    local i=0
    for server in "${mcp_servers[@]}"; do
        local name=$(echo $server | cut -d: -f1)
        local display_name=$(echo $server | cut -d: -f2)
        
        # 使用默认颜色显示所有服务器
        echo -e "$i. $display_name"
        ((i++))
    done
    echo -e "$i. ${CYAN}以上全部${NC}"
    echo -e "$((i+1)). ${RED}返回上一级${NC}"
    echo ""
    
    read -p "请选择要添加的 MCP 服务器支持 (0-$((i+1))): " server_choice
    
    if [[ $server_choice -ge 0 && $server_choice -lt $i ]]; then
        # 添加单个MCP服务器
        local server_name="${MCP_SERVERS_NAMES[$server_choice]}"
        add_mcp_server_by_name "$server_name"
    elif [[ $server_choice -eq $i ]]; then
        # 添加所有MCP服务器 - 优化版本
        
        # 先收集所有需要添加的MCP服务器配置
        local all_servers_configs=()
        for server_name in "${MCP_SERVERS_NAMES[@]}"; do
            local server_config=$(get_server_config "$server_name")
            if [[ -n "$server_config" ]]; then
                all_servers_configs+=("$server_name:$server_config")
            fi
        done
        
        # 一次性更新每个已安装工具的配置文件
        for idx in "${!INSTALLED_MCP_TOOLS[@]}"; do
            local ai_tool="${INSTALLED_MCP_TOOLS[$idx]}"
            local config_file="${INSTALLED_MCP_CONFIGS[$idx]}"
            
            if [[ -f "$config_file" ]]; then
                # 更新配置文件，添加所有服务器配置
                add_all_mcp_configs_to_file "$config_file" "${all_servers_configs[@]}"
                if [[ $? -eq 0 ]]; then
                    echo -e "${GREEN}✅ $ai_tool 的所有 MCP 服务器配置已添加到配置${NC}"
                else
                    echo -e "${RED}❌ 更新 $ai_tool 的 MCP 配置失败${NC}"
                fi
            else
                echo -e "${YELLOW}⚠️ $ai_tool 的配置文件不存在: $config_file，跳过${NC}"
            fi
        done
        
        # 批量安装所有MCP服务器包
        for server_name in "${MCP_SERVERS_NAMES[@]}"; do
            install_mcp_server_package "$server_name"
        done
    elif [[ $server_choice -eq $((i+1)) ]]; then
        # 返回上级菜单
        echo -e "${GREEN}🔙 返回上级菜单${NC}"
        return
    else
        echo -e "${RED}❌ 无效选项${NC}"
    fi
}

# 通用函数：添加MCP服务器到配置
add_mcp_server_to_config() {
    local config_file=$1
    local server_name=$2
    local server_config=$3
    
    # 调试输出
    echo -e "${YELLOW}🔧 正在为 $server_name 添加配置到 $config_file${NC}"
    echo -e "${YELLOW}🔧 服务器配置内容: $server_config${NC}"
    
    if [ -z "$server_config" ]; then
        echo -e "${RED}❌ 服务器配置为空${NC}"
        return 1
    fi
    
    if command -v jq >/dev/null 2>&1; then
        # 尝试使用--argjson方法（如果服务器配置是有效JSON）
        if jq --argjson server_config "$server_config" --arg server_name "$server_name" \
           '.mcpServers[$server_name] = $server_config' "$config_file" > "${config_file}.tmp" 2>/dev/null; then
            mv "${config_file}.tmp" "$config_file"
            echo -e "${GREEN}✅ $server_name 配置更新成功${NC}"
            return 0
        else
            # 如果--argjson失败，说明server_config可能不是有效JSON
            # 尝试使用--arg和fromjson方法
            if jq --arg server_config_str "$server_config" --arg server_name "$server_name" \
               '.mcpServers[$server_name] = ($server_config_str | fromjson)' "$config_file" > "${config_file}.tmp" 2>/dev/null; then
                mv "${config_file}.tmp" "$config_file"
                echo -e "${GREEN}✅ $server_name 配置更新成功${NC}"
                return 0
            else
                echo -e "${YELLOW}⚠️  jq更新失败，尝试后备方案${NC}"
                # jq方法都失败，使用sed作为后备
                add_mcp_server_to_config_fallback "$config_file" "$server_name" "$server_config"
                return $?
            fi
        fi
    else
        echo -e "${YELLOW}⚠️ 未安装 jq，使用后备方案更新配置${NC}"
        # jq不可用，使用sed作为后备
        add_mcp_server_to_config_fallback "$config_file" "$server_name" "$server_config"
        return $?
    fi
}

# 通过名称添加MCP服务器
add_mcp_server_by_name() {
    local server_name=$1
    local server_config=$(get_server_config "$server_name")
    
    if [[ -z "$server_config" ]]; then
        echo -e "${RED}❌ 未找到服务器配置: $server_name${NC}"
        return 1
    fi
    
    echo -e "${CYAN}➕ 添加 $server_name MCP 服务器支持${NC}"
    
    # 确保已安装的MCP工具列表是最新的
    check_tools
    
    for idx in "${!INSTALLED_MCP_TOOLS[@]}"; do
        local ai_tool="${INSTALLED_MCP_TOOLS[$idx]}"
        local config_file="${INSTALLED_MCP_CONFIGS[$idx]}"
        
        # 检查是否已存在配置
        if command -v jq >/dev/null 2>&1 && [[ -f "$config_file" ]]; then
            local exists=$(jq -r '.mcpServers | has("'$server_name'")' "$config_file" 2>/dev/null)
            if [[ "$exists" == "true" ]]; then
                echo -e "${YELLOW}⚠️ $ai_tool 的 $server_name 配置已存在，跳过${NC}"
                continue
            fi
        fi
        
        # 直接使用获取到的服务器配置
        if add_mcp_server_to_config "$config_file" "$server_name" "$server_config"; then
            echo -e "${GREEN}✅ $ai_tool 的 $server_name MCP 服务器已添加到配置${NC}"
        else
            echo -e "${RED}❌ 更新 $ai_tool 的 MCP 配置失败${NC}"
        fi
    done
    
    # 从mcp_servers配置中获取包信息和安装类型
    local package=""
    local install_type=""
    for mcp_server in "${mcp_servers[@]}"; do
        local name=$(echo $mcp_server | cut -d: -f1)
        if [[ "$name" == "$server_name" ]]; then
            package=$(echo $mcp_server | cut -d: -f3)
            install_type=$(echo $mcp_server | cut -d: -f4)
            break
        fi
    done
    
    # 如果找到了服务器配置，执行安装
    if [[ -n "$package" && -n "$install_type" ]]; then
        case $install_type in
            npm)
                # 检查 MCP 包是否已安装
                if npm list -g "$package" >/dev/null 2>&1; then
                    echo -e "${GREEN}✅ $server_name MCP 包 ($package) 已安装${NC}"
                else
                    # 安装 MCP 包
                    echo -e "${CYAN}📦 安装 $package...${NC}"
                    npm install -g "$package"
                    if [[ $? -eq 0 ]]; then
                        echo -e "${GREEN}✅ $server_name MCP 包安装成功${NC}"
                    else
                        echo -e "${YELLOW}⚠️ $server_name MCP 包安装可能失败，请手动安装${NC}"
                    fi
                fi
                ;;
            *)
                echo -e "${YELLOW}⚠️ 不支持的安装类型: $install_type${NC}"
                ;;
        esac
    else
        echo -e "${YELLOW}⚠️ 未找到 $server_name 的安装配置${NC}"
    fi
}

# 仅添加MCP配置，不处理包安装
add_mcp_config_only() {
    local server_name=$1
    local server_config=$(get_server_config "$server_name")
    
    if [[ -z "$server_config" ]]; then
        echo -e "${RED}❌ 未找到服务器配置: $server_name${NC}"
        return 1
    fi
    
    echo -e "${CYAN}➕ 添加 $server_name MCP 服务器配置到已安装工具...${NC}"
    
    # 使用已有的已安装MCP工具列表
    for idx in "${!INSTALLED_MCP_TOOLS[@]}"; do
        local ai_tool="${INSTALLED_MCP_TOOLS[$idx]}"
        local config_file="${INSTALLED_MCP_CONFIGS[$idx]}"
        
        # 只在配置文件存在时才添加MCP服务器配置
        if [[ -f "$config_file" ]]; then
            # 检查是否已存在配置
            if command -v jq >/dev/null 2>&1; then
                local exists=$(jq -r '.mcpServers | has(\"'$server_name'\")' "$config_file" 2>/dev/null)
                if [[ "$exists" == "true" ]]; then
                    echo -e "${YELLOW}⚠️ $ai_tool 的 $server_name 配置已存在，跳过${NC}"
                    continue
                fi
            fi
            
            # 直接使用获取到的服务器配置
            if add_mcp_server_to_config "$config_file" "$server_name" "$server_config"; then
                echo -e "${GREEN}✅ $ai_tool 的 $server_name MCP 服务器已添加到配置${NC}"
            else
                echo -e "${RED}❌ 更新 $ai_tool 的 MCP 配置失败${NC}"
            fi
        else
            echo -e "${YELLOW}⚠️ $ai_tool 的配置文件不存在: $config_file，跳过${NC}"
        fi
    done
}

# 仅安装MCP服务器包，不处理配置添加
install_mcp_server_package() {
    local server_name=$1
    
    # 从mcp_servers配置中获取包信息和安装类型
    local package=""
    local install_type=""
    for mcp_server in "${mcp_servers[@]}"; do
        local name=$(echo $mcp_server | cut -d: -f1)
        if [[ "$name" == "$server_name" ]]; then
            package=$(echo $mcp_server | cut -d: -f3)
            install_type=$(echo $mcp_server | cut -d: -f4)
            break
        fi
    done
    
    # 清理包名中的前后空格
    package=$(echo "$package" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    
    # 如果找到了服务器配置，执行安装
    if [[ -n "$package" && -n "$install_type" ]]; then
        case $install_type in
            npm)
                # 检查 MCP 包是否已安装
                if npm list -g "$package" >/dev/null 2>&1; then
                    echo -e "${GREEN}✅ $server_name MCP 包 ($package) 已安装${NC}"
                else
                    # 安装 MCP 包
                    echo -e "${CYAN}📦 安装 $package...${NC}"
                    # 先尝试安装，如果失败可能是目录非空问题，再尝试强制安装
                    if ! npm install -g "$package" 2>/dev/null; then
                        # 如果是ENOTEMPTY错误（目录非空），尝试先卸载再安装
                        echo -e "${YELLOW}⚠️ 安装失败，尝试先卸载再安装...${NC}"
                        npm uninstall -g "$package" 2>/dev/null
                        # 再次尝试安装
                        if npm install -g "$package"; then
                            echo -e "${GREEN}✅ $server_name MCP 包安装成功${NC}"
                        else
                            echo -e "${YELLOW}⚠️ $server_name MCP 包 ($package) 安装失败，请手动安装${NC}"
                        fi
                    else
                        echo -e "${GREEN}✅ $server_name MCP 包安装成功${NC}"
                    fi
                fi
                ;;
            *)
                echo -e "${YELLOW}⚠️ 不支持的安装类型: $install_type${NC}"
                ;;
        esac
    else
        echo -e "${YELLOW}⚠️ 未找到 $server_name 的安装配置${NC}"
    fi
}

# 添加新的 MCP 服务器
add_mcp_server() {
    local settings_file="$1"
    local ai_tool="$2"
    
    # 如果没有提供AI工具名称，则默认为"Unknown"
    if [[ -z "$ai_tool" ]]; then
        ai_tool="Unknown"
    fi
    
    echo -e "${CYAN}➕ 为 $ai_tool 添加新的 MCP 服务器${NC}"
    
    read -p "请输入服务器名称 (如: mysql, chrome-devtools, 等): " server_name
    
    # 验证服务器名称
    if [[ -z "$server_name" ]]; then
        echo -e "${RED}❌ 服务器名称不能为空${NC}"
        return 1
    fi
    
    echo -e "${YELLOW}常用 MCP 服务器示例:${NC}"
    echo "  1. MySQL 数据库: npx @f4ww4z/mcp-mysql-server"
    echo "  2. Chrome DevTools: npx chrome-devtools-mcp@latest"
    echo "  3. 自定义命令"
    
    read -p "请输入命令 (如: npx, node 等): " server_command
    
    if [[ -z "$server_command" ]]; then
        echo -e "${RED}❌ 命令不能为空${NC}"
        return 1
    fi
    
    # 添加参数输入
    echo -e "${YELLOW}请输入参数 (多个参数用空格分隔，如: -y @f4ww4z/mcp-mysql-server)${NC}"
    read -p "参数: " server_args
    
    # 询问是否需要环境变量
    read -p "是否需要设置环境变量? (y/N): " need_env
    local env_vars=""
    if [[ "$need_env" == "y" || "$need_env" == "Y" ]]; then
        echo -e "${YELLOW}请输入环境变量 (格式: KEY1=VALUE1,KEY2=VALUE2):${NC}"
        read -p "环境变量: " env_input
        if [[ -n "$env_input" ]]; then
            # 转换逗号分隔的环境变量为 JSON 格式
            IFS=',' read -ra ENV_PAIRS <<< "$env_input"
            env_vars="{"
            local first=true
            for pair in "${ENV_PAIRS[@]}"; do
                IFS='=' read -r key value <<< "$pair"
                if [[ "$first" == true ]]; then
                    env_vars="${env_vars}\\\"$key\\\":\\\"$value\\\""
                    first=false
                else
                    env_vars="${env_vars},\\\"$key\\\":\\\"$value\\\""
                fi
            done
            env_vars="${env_vars}}"
        fi
    fi
    
    # 询问传输类型
    echo -e "${YELLOW}传输类型 (stdio/tcp) [默认: stdio]:${NC}"
    read -p "传输类型: " transport_type
    transport_type=${transport_type:-"stdio"}
    
    # 询问自动批准的权限
    echo -e "${YELLOW}请输入自动批准的权限 (用逗号分隔，如: connect_db,execute,query)${NC}"
    read -p "自动批准权限: " auto_approve
    
    # 构建 MCP 服务器配置
    local new_config=""
    if [[ -n "$auto_approve" ]]; then
        if [[ -n "$env_vars" ]]; then
            # 处理参数数组
            local args_array=""
            if [[ -n "$server_args" ]]; then
                # 将空格分隔的参数转换为 JSON 数组
                IFS=' ' read -ra ARGS_ARRAY <<< "$server_args"
                args_array="\\\"${ARGS_ARRAY[0]}\\\""
                for arg in "${ARGS_ARRAY[@]:1}"; do
                    if [[ -n "$arg" ]]; then
                        args_array="${args_array},\\\"$arg\\\""
                    fi
                done
            fi
            
            new_config=$(cat << EOF
{
  "command": "$server_command",
  "args": [$args_array],
  "env": $env_vars,
  "transportType": "$transport_type",
  "autoApprove": [$(echo "$auto_approve" | sed 's/,/\\",\\"/g' | sed 's/^/\\\"/' | sed 's/$/\\\"/')]
}
EOF
)
        else
            # 处理参数数组
            local args_array=""
            if [[ -n "$server_args" ]]; then
                # 将空格分隔的参数转换为 JSON 数组
                IFS=' ' read -ra ARGS_ARRAY <<< "$server_args"
                args_array="\\\"${ARGS_ARRAY[0]}\\\""
                for arg in "${ARGS_ARRAY[@]:1}"; do
                    if [[ -n "$arg" ]]; then
                        args_array="${args_array},\\\"$arg\\\""
                    fi
                done
            fi
            
            new_config=$(cat << EOF
{
  "command": "$server_command",
  "args": [$args_array],
  "transportType": "$transport_type",
  "autoApprove": [$(echo "$auto_approve" | sed 's/,/\\",\\"/g' | sed 's/^/\\\"/' | sed 's/$/\\\"/')]
}
EOF
)
        fi
    else
        if [[ -n "$env_vars" ]]; then
            # 处理参数数组
            local args_array=""
            if [[ -n "$server_args" ]]; then
                # 将空格分隔的参数转换为 JSON 数组
                IFS=' ' read -ra ARGS_ARRAY <<< "$server_args"
                args_array="\\\"${ARGS_ARRAY[0]}\\\""
                for arg in "${ARGS_ARRAY[@]:1}"; do
                    if [[ -n "$arg" ]]; then
                        args_array="${args_array},\\\"$arg\\\""
                    fi
                done
            fi
            
            new_config=$(cat << EOF
{
  "command": "$server_command",
  "args": [$args_array],
  "env": $env_vars,
  "transportType": "$transport_type"
}
EOF
)
        else
            # 处理参数数组
            local args_array=""
            if [[ -n "$server_args" ]]; then
                # 将空格分隔的参数转换为 JSON 数组
                IFS=' ' read -ra ARGS_ARRAY <<< "$server_args"
                args_array="\\\"${ARGS_ARRAY[0]}\\\""
                for arg in "${ARGS_ARRAY[@]:1}"; do
                    if [[ -n "$arg" ]]; then
                        args_array="${args_array},\\\"$arg\\\""
                    fi
                done
            fi
            
            new_config=$(cat << EOF
{
  "command": "$server_command",
  "args": [$args_array],
  "transportType": "$transport_type"
}
EOF
)
        fi
    fi
    
    # 如果 jq 可用，使用它来更新配置
    if command -v jq >/dev/null 2>&1; then
        # 更新配置
        jq --argjson server_config "$new_config" --arg server_name "$server_name" \
           '.mcpServers[$server_name] = $server_config' "$settings_file" > "${settings_file}.tmp" && \
        mv "${settings_file}.tmp" "$settings_file"
        
        if [[ $? -eq 0 ]]; then
            echo -e "${GREEN}✅ $ai_tool 的 MCP 服务器 '$server_name' 已添加到配置${NC}"
        else
            echo -e "${RED}❌ 更新 $ai_tool 的 MCP 配置失败${NC}"
        fi
    else
        echo -e "${RED}❌ 未安装 jq，无法更新配置。请安装 jq 后重试。${NC}"
        return 1
    fi
}

# 处理用户选择
process_choice() {
    local choice=$1
    local tool_count=${#TOOLS[@]}
    
    # 检查是否为字母选择
    if [[ "$choice" == "m" || "$choice" == "M" ]]; then
        manage_mcp_servers
    elif [[ "$choice" == "r" || "$choice" == "R" ]]; then
        echo -e "${CYAN}🔄 刷新...${NC}"
        source ai-tools.conf
        # 重新获取MCP服务器名称列表
        MCP_SERVERS_NAMES=()
        for server in "${mcp_servers[@]}"; do
            local name=$(echo $server | cut -d: -f1)
            MCP_SERVERS_NAMES+=("$name")
        done
        check_tools
    elif [[ "$choice" == "q" || "$choice" == "Q" ]]; then
        echo -e "${GREEN}👋 再见!${NC}"
        exit 0
    # 检查选择是否为工具（数字）
    elif [[ $choice =~ ^[0-9]+$ ]] && [[ $choice -ge 1 && $choice -le $tool_count ]]; then
        local index=$((choice-1))
        if [ "${TOOL_STATUS[$index]}" = "true" ]; then
            update_tool $index
        else
            install_tool $index
        fi
    else
        echo -e "${RED}❌ 无效选项，请重试。${NC}"
    fi
}

# 主程序
main() {
    detect_os
    
    # 检查是否提供了命令行参数
    if [[ $# -ge 1 ]]; then
        # 对于帮助参数，不执行检查工具
        case $1 in
            "h"|"help"|"--help"|"-h")
                echo "AI工具管理脚本"
                echo "用法:"
                echo "  $0              # 交互式菜单"
                echo "  $0 m            # 直接进入MCP管理"
                echo "  $0 r            # 刷新工具列表"
                echo "  $0 --help       # 显示此帮助"
                echo "  $0 -h           # 显示此帮助"
                exit 0
                ;;
        esac
        
        # 执行工具检查，为其他参数做准备
        check_tools
        
        case $1 in
            "m"|"M")
                # 直接进入MCP管理
                manage_mcp_servers
                ;;
            "r"|"R")
                # 刷新并重新显示主菜单
                source ai-tools.conf
                # 重新获取MCP服务器名称列表
                MCP_SERVERS_NAMES=()
                for server in "${mcp_servers[@]}"; do
                    local name=$(echo $server | cut -d: -f1)
                    MCP_SERVERS_NAMES+=("$name")
                done
                check_tools
                show_menu
                ;;
            *)
                echo -e "${RED}❌ 未知参数: $1${NC}"
                echo "使用 '$0 --help' 查看帮助"
                exit 1
                ;;
        esac
    else
        # 交互式菜单模式 - 先执行工具检查
        check_tools
        
        # 交互式菜单模式
        while true; do
            show_menu
            echo ""
            read -p "请选择操作 (1-$(( ${#TOOLS[@]} ))、m管理MCP、r刷新、q退出): " choice
            
            # Check if user wants to quit
            if [[ "$choice" == "q" ]] || [[ "$choice" == "Q" ]]; then
                echo -e "${GREEN}👋 再见!${NC}"
                exit 0
            fi
            
            # Allow letter commands (m, r) or number commands
            if ! [[ "$choice" =~ ^[0-9]+$ ]] && [[ "$choice" != "m" ]] && [[ "$choice" != "M" ]] && [[ "$choice" != "r" ]] && [[ "$choice" != "R" ]]; then
                echo -e "${RED}❌ 无效选项，请输入数字、m管理MCP、r刷新或q退出。${NC}"
                continue
            fi
            
            process_choice $choice
            echo ""
        done
    fi
}

# 不使用jq的后备方案，使用sed和awk处理JSON
add_mcp_server_to_config_fallback() {
    local config_file=$1
    local server_name=$2
    local server_config=$3
    
    echo -e "${YELLOW}🔧 使用后备方案更新 $server_name 配置${NC}"
    
    # 简单的sed方案：如果mcpServers是空对象，直接替换
    if grep -q '"mcpServers": {}' "$config_file"; then
        sed "s/\"mcpServers\": {}/\"mcpServers\": {\"$server_name\": $server_config}/" "$config_file" > "${config_file}.tmp" && \
        mv "${config_file}.tmp" "$config_file"
        if [ $? -eq 0 ]; then
            echo -e "${GREEN}✅ $server_name 配置更新成功（后备方案）${NC}"
            return 0
        else
            echo -e "${RED}❌ 后备方案失败${NC}"
            return 1
        fi
    elif grep -q '"mcpServers": *{' "$config_file"; then
        # 如果mcpServers对象非空，插入新项
        # 检查是否已经存在该服务器配置
        if grep -q "\"$server_name\":" "$config_file"; then
            echo -e "${YELLOW}⚠️ $server_name 配置已存在${NC}"
            return 0
        else
            # 在mcpServers对象的最后一个}前插入新的服务器配置
            # 临时文件
            local temp_file="${config_file}.tmp"
            
            # 简单方法：在最后一个}前插入新配置
            awk -v server="$server_name" -v config="$server_config" '
            BEGIN { in_mcp_servers = 0; found_last = 0 }
            {
                if (!found_last && in_mcp_servers && match($0, /.*}[ \t]*,?[ \t]*(\}|$)/)) {
                    # 这是mcpServers的结束大括号
                    gsub(/[ \t]*}[ \t]*(\}|$)/, "");  # 移除原来的结束括号
                    if (NF > 0) print $0 ",";
                    print "    \"" server "\": " config;
                    print "}";
                    in_mcp_servers = 0;
                    found_last = 1;
                } else if (match($0, /.*"mcpServers"[ \t]*:[ \t]*{/) && !in_mcp_servers) {
                    in_mcp_servers = 1;
                    print $0;
                } else {
                    print $0;
                }
                
                if (in_mcp_servers && found_last) print $0;
            }' "$config_file" > "$temp_file" 2>/dev/null
            
            if [ $? -eq 0 ]; then
                mv "$temp_file" "$config_file"
                echo -e "${GREEN}✅ $server_name 配置更新成功（后备方案）${NC}"
                return 0
            else
                # 如果awk失败，尝试更简单的sed方法
                sed "s/\(\"mcpServers\": {\)/\1\n    \"$server_name\": $server_config,/" "$config_file" > "$temp_file" && \
                mv "$temp_file" "$config_file"
                if [ $? -eq 0 ]; then
                    echo -e "${GREEN}✅ $server_name 配置更新成功（简单后备方案）${NC}"
                    return 0
                else
                    echo -e "${RED}❌ 所有后备方案都失败了${NC}"
                    return 1
                fi
            fi
        fi
    else
        echo -e "${RED}❌ 配置文件格式不正确，无法更新${NC}"
        return 1
    fi
}

# 一次性向配置文件添加所有MCP服务器配置
add_all_mcp_configs_to_file() {
    local config_file=$1
    shift
    local all_configs=("$@")
    
    # 对每个配置使用jq更新
    local temp_config="$config_file.tmp"
    cp "$config_file" "$temp_config"
    
    local success_count=0
    local total_count=${#all_configs[@]}
    local ai_tool_name=$(basename $(dirname "$config_file"))  # 提取工具名称如qwen, gemini等
    
    # 先显示开始更新配置文件的消息
    echo -e "${CYAN}➕ 开始更新 $ai_tool_name 的所有 MCP 服务器配置...${NC}"
    
    for config_entry in "${all_configs[@]}"; do
        local server_name="${config_entry%%:*}"
        local server_config="${config_entry#*:}"
        
        # 检查配置是否已存在
        if command -v jq >/dev/null 2>&1; then
            # 使用jq检查配置是否存在
            local exists=$(jq -r ".mcpServers | has(\"$server_name\")" "$temp_config" 2>/dev/null)
            if [[ "$exists" == "true" ]]; then
                echo -e "${YELLOW}⚠️ $server_name 配置已存在${NC}"
                ((success_count++))
                continue
            fi
            
            # 更新配置
            if jq --argjson server_config "$server_config" --arg server_name "$server_name" \
               '.mcpServers[$server_name] = $server_config' "$temp_config" > "${temp_config}.tmp" 2>/dev/null; then
                echo -e "${GREEN}✅ $server_name 配置已添加${NC}"
                mv "${temp_config}.tmp" "$temp_config"
                ((success_count++))
            else
                # 如果jq --argjson失败，尝试使用--arg和fromjson
                if jq --arg server_config_str "$server_config" --arg server_name "$server_name" \
                   '.mcpServers[$server_name] = ($server_config_str | fromjson)' "$temp_config" > "${temp_config}.tmp" 2>/dev/null; then
                    echo -e "${GREEN}✅ $server_name 配置已添加${NC}"
                    mv "${temp_config}.tmp" "$temp_config"
                    ((success_count++))
                else
                    echo -e "${RED}❌ 更新 $server_name 配置失败${NC}"
                fi
            fi
        else
            # 如果jq不可用，使用后备函数逐个添加
            local result=$(add_mcp_server_to_config_fallback "$temp_config" "$server_name" "$server_config" 2>&1)
            local exit_code=$?
            if [ $exit_code -eq 0 ]; then
                # 检查是否是"已存在"消息
                if echo "$result" | grep -q "配置已存在"; then
                    echo -e "${YELLOW}⚠️ $server_name 配置已存在${NC}"
                else
                    echo -e "${GREEN}✅ $server_name 配置已添加${NC}"
                fi
                ((success_count++))
            else
                echo -e "${RED}❌ 更新 $server_name 配置失败${NC}"
            fi
        fi
    done
    
    # 如果所有配置都成功添加或已存在，移动临时文件到原文件
    if [[ $success_count -eq $total_count ]]; then
        mv "$temp_config" "$config_file"
        echo -e "${GREEN}✅ $ai_tool_name 的所有 MCP 服务器配置已处理完成${NC}"
        return 0
    else
        # 部分失败，保留临时文件用于调试
        echo -e "${YELLOW}⚠️ $ai_tool_name 部分配置更新失败，保留临时文件 $temp_config 用于调试${NC}"
        return 1
    fi
}

# 运行主程序
main "$@"
