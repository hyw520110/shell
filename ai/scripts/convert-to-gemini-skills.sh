#!/bin/bash
# ai-hub Skills → Gemini CLI Skills 转换脚本
# 将 ai/conf/shared/skills/*.json 转换为 Gemini CLI 格式

set -e

AI_HUB_SKILLS_DIR="${AI_HUB_SKILLS_DIR:-$(dirname "$0")/../conf/shared/skills}"
GEMINI_SKILLS_DIR="${GEMINI_SKILLS_DIR:-$HOME/.gemini/skills}"

echo "=========================================="
echo "ai-hub Skills → Gemini CLI Skills 转换器"
echo "=========================================="
echo ""
echo "源目录: $AI_HUB_SKILLS_DIR"
echo "目标目录: $GEMINI_SKILLS_DIR"
echo ""

# 检查源目录
if [[ ! -d "$AI_HUB_SKILLS_DIR" ]]; then
    echo "❌ 错误: 找不到 ai-hub Skills 目录: $AI_HUB_SKILLS_DIR"
    exit 1
fi

# 创建目标目录
mkdir -p "$GEMINI_SKILLS_DIR"

# 转换计数
converted=0
skipped=0

# 遍历所有 JSON 文件
for json_file in "$AI_HUB_SKILLS_DIR"/*.json; do
    [[ -f "$json_file" ]] || continue
    
    skill_id=$(basename "$json_file" .json)
    skill_dir="$GEMINI_SKILLS_DIR/$skill_id"
    
    # 解析 JSON
    name=$(jq -r '.name // empty' "$json_file" 2>/dev/null || echo "")
    description=$(jq -r '.description // empty' "$json_file" 2>/dev/null || echo "")
    category=$(jq -r '.category // "general"' "$json_file" 2>/dev/null || echo "general")
    
    # 如果没有名称，使用文件名
    [[ -z "$name" ]] && name="$skill_id"
    [[ -z "$description" ]] && description="$name Skill"
    
    echo "🔄 转换: $skill_id"
    
    # 创建 Skill 目录
    mkdir -p "$skill_dir"
    
    # 生成 SKILL.md
    cat > "$skill_dir/SKILL.md" << EOF
# $name

$description

## 分类

$category

## 使用方式

此 Skill 由 ai-hub 管理，原始配置位于:
\`$json_file\`

## 提示词示例

EOF

    # 添加 prompts（如果有）
    if jq -e '.prompts' "$json_file" >/dev/null 2>&1; then
        jq -r '.prompts | to_entries[] | "- **\(.key)**: \(.value)"' "$json_file" >> "$skill_dir/SKILL.md"
    fi
    
    # 添加依赖信息
    cat >> "$skill_dir/SKILL.md" << EOF

## 依赖

EOF
    
    if jq -e '.dependencies.mcp_servers' "$json_file" >/dev/null 2>&1; then
        echo "**MCP Servers:**" >> "$skill_dir/SKILL.md"
        jq -r '.dependencies.mcp_servers[] | "- \(.)"' "$json_file" >> "$skill_dir/SKILL.md"
        echo "" >> "$skill_dir/SKILL.md"
    fi
    
    if jq -e '.dependencies.system_commands' "$json_file" >/dev/null 2>&1; then
        echo "**系统命令:**" >> "$skill_dir/SKILL.md"
        jq -r '.dependencies.system_commands[] | "- \(.)"' "$json_file" >> "$skill_dir/SKILL.md"
    fi
    
    # 添加 capabilities（如果有）
    if jq -e '.capabilities' "$json_file" >/dev/null 2>&1; then
        cat >> "$skill_dir/SKILL.md" << EOF

## 能力

EOF
        jq -r '.capabilities[] | "- \(.)"' "$json_file" >> "$skill_dir/SKILL.md"
    fi
    
    # 添加 tips（如果有）
    if jq -e '.tips' "$json_file" >/dev/null 2>&1; then
        cat >> "$skill_dir/SKILL.md" << EOF

## 提示

$(jq -r '.tips // empty' "$json_file")
EOF
    fi
    
    # 复制原始 JSON 作为元数据
    cp "$json_file" "$skill_dir/ai-hub-config.json"
    
    ((converted++))
    echo "   ✅ 已创建: $skill_dir/"
done

echo ""
echo "=========================================="
echo "转换完成!"
echo "=========================================="
echo "已转换: $converted 个 Skills"
echo ""
echo "使用方式:"
echo "  1. 在 Gemini CLI 中运行: /skills reload"
echo "  2. 查看 Skills: /skills list"
echo "  3. 使用 Skill: /skills use <skill-name>"
echo ""
echo "注意: 部分依赖 MCP Server 的 Skills 在 Gemini CLI 中可能无法完全使用"
