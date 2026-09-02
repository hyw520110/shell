#!/bin/bash
# ==================== 配置默认模板模块 ====================
# 提供各工具的默认配置模板

# 获取工具的默认配置模板
# 返回: JSON 字符串
get_default_config_template() {
    local tool_name=$1

    case $tool_name in
        "Qwen CLI")
            cat << 'EOF'
{
  "ide": {
    "hasSeenNudge": true
  },
  "security": {
    "auth": {
      "selectedType": "qwen-oauth"
    }
  },
  "$version": 2,
  "model": {
    "name": "coder-model"
  },
  "mcpServers": {}
}
EOF
            ;;
        "Gemini CLI")
            cat << 'EOF'
{
  "mcpServers": {}
}
EOF
            ;;
        "Claude Code")
            cat << 'EOF'
{
  "mcpServers": {}
}
EOF
            ;;
        "Copilot CLI")
            cat << 'EOF'
{
  "mcpServers": {}
}
EOF
            ;;
        "OpenClaw")
            cat << 'EOF'
{
  "mcpServers": {}
}
EOF
            ;;
        *)
            cat << 'EOF'
{
  "mcpServers": {}
}
EOF
            ;;
    esac
}
