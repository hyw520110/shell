# Skills 配置目录

本目录保存可复用的 AI Agent Skills。`ai-hub.sh` 会扫描这里的 JSON 配置，并根据每个 Skill 自己声明的 `scenarios`、`tags` 和依赖关系进行批量配置。

## 新增 Skill

复制模板：

```bash
cp _template.json <skill-id>.json
```

必须填写：

| 字段 | 说明 |
|------|------|
| `id` | Skill 唯一标识，建议与文件名一致 |
| `name` | 显示名称 |
| `description` | Skill 能力、适用场景和预期输出 |
| `category` | 分类 |
| `scenarios` | 所属场景，必须来自 `../../global.json.scenarios` |
| `tags` | 标签数组，用于按标签批量配置 |
| `homepage` 或 `repository` | 官方主页或 GitHub 仓库链接 |
| `dependencies` | 依赖的 MCP、系统命令或外部服务 |

依赖 MCP 示例：

```json
{
  "dependencies": {
    "mcp_servers": ["codegraph"],
    "system_commands": ["node", "npm"]
  }
}
```

`ai-hub.sh` 执行批量配置时会自动把 `dependencies.mcp_servers` 合并到目标工具的 MCP 配置中，避免只安装 Skill 但漏配 MCP。若依赖的 MCP 声明了 `requires_env` 且当前环境缺失，脚本会跳过该 MCP 并提示，避免目标 Agent 启动后出现 `Disconnected`。

## 场景规则

不要在 `global.json` 里维护某个场景包含哪些 Skills。新增 Skill 时在自己的配置里声明：

```json
{
  "scenarios": ["coding", "productivity"]
}
```

这样新增能力只需要维护一个配置文件。

## 可选和实验项

默认批量配置会跳过：

- `optional=true`
- `experimental=true`

适合用于需要 API Key、外部服务、手工安装或当前稳定性不足的 Skill。

## 验证

`ai-hub.sh` 的批量配置会内置验证：

- JSON 格式是否合法。
- 是否缺少 `id/name/description/category/tags/scenarios`。
- `tags` 是否存在大小写/别名不规范；常用英文缩写统一写为 `PRD`、`UI`、`UX`、`API`、`PDF`、`MCP`、`GitHub`、`SSH`、`OCR`。
- `scenarios` 是否引用了未注册场景。
- `dependencies.mcp_servers` 是否引用了不存在的 MCP 配置。
- 是否缺少 `homepage`、`repository` 或 GitHub 链接。
