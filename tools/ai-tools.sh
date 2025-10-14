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

# 工具配置: 命令:名称:包名:类型
TOOLS=(
    "qwen:Qwen CLI:qwen:npm"
    "gemini:Gemini CLI:gemini:npm"
    "claude:Claude Code:@anthropic-ai/claude-code:npm"
    "codex:OpenAI Codex CLI:@openai/codex:npm"
    "grok:Grok CLI:@vibe-kit/grok-cli:npm"
    "codebuddy:Codebuddy Code:@tencent-ai/codebuddy-code:npm"
    "copilot:GitHub Copilot:@github/copilot:npm"
    "iflow:iFlow CLI:@iflow-ai/iflow-cli:npm"
    "gpt-cli:ChatGPT CLI:gpt-cli:npm"
    "mistral:mistral-cli:mistral-cli:npm"
    "perplexity:Perplexity CLI:perplexity-cli:npm"
    "mcp-servers:MCP 服务器配置::config"
)

# 工具状态全局变量
TOOL_STATUS=()

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
    
    local i=1
    for tool in "${TOOLS[@]}"; do
        local cmd=$(echo $tool | cut -d: -f1)
        local name=$(echo $tool | cut -d: -f2)
        
        if command_exists "$cmd"; then
            local version=$($cmd --version 2>/dev/null || echo "unknown")
            echo -e "$i. ${GREEN}✅ $name${NC} ($version) - 已安装"
            TOOL_STATUS+=("true")
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
    
    echo -e "$i. 🔄 ${CYAN}刷新${NC}"
    ((i++))
    echo -e "$i. 🚪 ${RED}退出${NC}"
    echo ""
}

# 管理 MCP 服务器配置
manage_mcp_servers() {
    echo -e "${CYAN}🔧 管理 MCP 服务器配置...${NC}"
    
    # 定义各AI工具的配置文件路径
    declare -A ai_configs
    ai_configs["Qwen"]="$HOME/.qwen/settings.json"
    ai_configs["Gemini"]="$HOME/.gemini/settings.json"
    
    # 检查并创建各AI工具的配置目录和文件
    for ai_tool in "${!ai_configs[@]}"; do
        local config_file="${ai_configs[$ai_tool]}"
        local config_dir=$(dirname "$config_file")
        
        if [[ ! -d "$config_dir" ]]; then
            echo -e "${YELLOW}⚠️ $ai_tool 配置目录不存在，创建: $config_dir${NC}"
            mkdir -p "$config_dir"
        fi
        
        if [[ ! -f "$config_file" ]]; then
            echo -e "${YELLOW}⚠️ $ai_tool 配置文件不存在，创建默认配置: $config_file${NC}"
            case $ai_tool in
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
            esac
        fi
    done
    
    # 显示所有AI工具的配置文件路径
    echo -e "${GREEN}✅ AI 工具配置文件路径:${NC}"
    for ai_tool in "${!ai_configs[@]}"; do
        echo -e "  ${ai_tool}: ${ai_configs[$ai_tool]}"
    done
    echo ""
    
    # 显示所有AI工具的当前 MCP 服务器配置
    echo -e "${CYAN}📋 所有 AI 工具的当前 MCP 服务器配置:${NC}"
    if command -v jq >/dev/null 2>&1; then
        local has_config=false
        for ai_tool in "${!ai_configs[@]}"; do
            local config_file="${ai_configs[$ai_tool]}"
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
        for ai_tool in "${!ai_configs[@]}"; do
            local config_file="${ai_configs[$ai_tool]}"
            if [[ -f "$config_file" ]] && [[ -s "$config_file" ]]; then
                echo -e "  ${ai_tool}: $config_file (存在)"
            else
                echo -e "  ${ai_tool}: $config_file (不存在或为空)"
            fi
        done
    fi
    echo ""
    
    # 提供选项来管理 MCP 服务器
    echo -e "MCP 服务器管理选项:"
    echo -e "1. ${GREEN}添加新的 MCP 服务器${NC}"
    echo -e "2. ${YELLOW}查看详细的 MCP 配置${NC}"
    echo -e "3. ${RED}重置 MCP 配置${NC}"
    echo -e "4. ${BLUE}返回主菜单${NC}"
    echo ""
    
    read -p "请选择操作 (1-4): " mcp_choice
    
    case $mcp_choice in
        1)
            echo -e "${CYAN}选择要添加 MCP 服务器的 AI 工具:${NC}"
            local i=1
            local tool_names=()
            for ai_tool in "${!ai_configs[@]}"; do
                echo -e "$i. $ai_tool"
                tool_names[$i]="$ai_tool"
                ((i++))
            done
            echo ""
            
            read -p "请选择 AI 工具 (1-$((i-1))): " tool_choice
            
            if [[ $tool_choice -ge 1 && $tool_choice -lt $i ]]; then
                local selected_tool="${tool_names[$tool_choice]}"
                local config_file="${ai_configs[$selected_tool]}"
                add_mcp_server "$config_file" "$selected_tool"
            else
                echo -e "${RED}❌ 无效选项${NC}"
            fi
            ;;
        2)
            echo -e "${CYAN}🔍 详细 MCP 配置信息:${NC}"
            for ai_tool in "${!ai_configs[@]}"; do
                local config_file="${ai_configs[$ai_tool]}"
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
            local i=1
            local tool_names=()
            for ai_tool in "${!ai_configs[@]}"; do
                echo -e "$i. $ai_tool"
                tool_names[$i]="$ai_tool"
                ((i++))
            done
            echo ""
            
            read -p "请选择 AI 工具 (1-$((i-1))): " tool_choice
            
            if [[ $tool_choice -ge 1 && $tool_choice -lt $i ]]; then
                local selected_tool="${tool_names[$tool_choice]}"
                local config_file="${ai_configs[selected_tool]}"
                
                echo -e "${YELLOW}⚠️ 此操作将清除 $selected_tool 的所有 MCP 服务器配置，是否继续？(y/N)${NC}"
                read -p "确认 (y/N): " confirm
                if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
                    case $selected_tool in
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
                    env_vars="${env_vars}\"$key\":\"$value\""
                    first=false
                else
                    env_vars="${env_vars},\"$key\":\"$value\""
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
                args_array="\"${ARGS_ARRAY[0]}\""
                for arg in "${ARGS_ARRAY[@]:1}"; do
                    if [[ -n "$arg" ]]; then
                        args_array="${args_array},\"$arg\""
                    fi
                done
            fi
            
            new_config=$(cat << EOF
{
  "command": "$server_command",
  "args": [$args_array],
  "env": $env_vars,
  "transportType": "$transport_type",
  "autoApprove": [$(echo "$auto_approve" | sed 's/,/","/g' | sed 's/^/"/' | sed 's/$/"/')]
}
EOF
)
        else
            # 处理参数数组
            local args_array=""
            if [[ -n "$server_args" ]]; then
                # 将空格分隔的参数转换为 JSON 数组
                IFS=' ' read -ra ARGS_ARRAY <<< "$server_args"
                args_array="\"${ARGS_ARRAY[0]}\""
                for arg in "${ARGS_ARRAY[@]:1}"; do
                    if [[ -n "$arg" ]]; then
                        args_array="${args_array},\"$arg\""
                    fi
                done
            fi
            
            new_config=$(cat << EOF
{
  "command": "$server_command",
  "args": [$args_array],
  "transportType": "$transport_type",
  "autoApprove": [$(echo "$auto_approve" | sed 's/,/","/g' | sed 's/^/"/' | sed 's/$/"/')]
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
                args_array="\"${ARGS_ARRAY[0]}\""
                for arg in "${ARGS_ARRAY[@]:1}"; do
                    if [[ -n "$arg" ]]; then
                        args_array="${args_array},\"$arg\""
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
                args_array="\"${ARGS_ARRAY[0]}\""
                for arg in "${ARGS_ARRAY[@]:1}"; do
                    if [[ -n "$arg" ]]; then
                        args_array="${args_array},\"$arg\""
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
    
    # 检查选择是否为工具
    if [[ $choice -ge 1 && $choice -le $tool_count ]]; then
        local index=$((choice-1))
        if [ "${TOOL_STATUS[$index]}" = "true" ]; then
            update_tool $index
        else
            install_tool $index
        fi
    # 检查选择是否为刷新
    elif [[ $choice -eq $((tool_count+1)) ]]; then
        echo -e "${CYAN}🔄 刷新...${NC}"
        check_tools
    # 检查选择是否为退出
    elif [[ $choice -eq $((tool_count+2)) ]]; then
        echo -e "${GREEN}👋 再见!${NC}"
        exit 0
    else
        echo -e "${RED}❌ 无效选项，请重试。${NC}"
    fi
}

# 主程序
main() {
    detect_os
    check_tools
    
    while true; do
        show_menu
        echo ""
        read -p "请选择操作 (1-$(( ${#TOOLS[@]} + 2 ))), 或输入 q 退出: " choice
        
        # Check if user wants to quit
        if [[ "$choice" == "q" ]] || [[ "$choice" == "Q" ]]; then
            echo -e "${GREEN}👋 再见!${NC}"
            exit 0
        fi
        
        # Validate that the choice is a number
        if ! [[ "$choice" =~ ^[0-9]+$ ]]; then
            echo -e "${RED}❌ 无效选项，请输入数字或 q 退出。${NC}"
            continue
        fi
        
        process_choice $choice
        echo ""
    done
}

# 运行主程序
main "$@"
