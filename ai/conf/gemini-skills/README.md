# Gemini CLI 适配方案

本目录包含 ai-hub MCP Servers 和 Skills 到 Gemini CLI 的适配配置。

## Gemini CLI 支持的能力

| 类型 | 支持 | 配置方式 |
|------|------|----------|
| **MCP Servers** | ✅ 完全支持 | `~/.gemini/settings.json` 的 `mcpServers` |
| **Skills** | ✅ 支持 | `~/.gemini/skills/` 目录 |

## MCP Servers 配置

在 `~/.gemini/settings.json` 中配置 MCP Servers：

```json
{
  "mcpServers": {
    "github": {
      "command": "docker",
      "args": ["run", "-i", "--rm", "-e", "GITHUB_PERSONAL_ACCESS_TOKEN", "ghcr.io/github/github-mcp-server:latest"],
      "env": {
        "GITHUB_PERSONAL_ACCESS_TOKEN": "${GITHUB_PERSONAL_ACCESS_TOKEN}"
      }
    }
  }
}
```

## ai-hub MCP Servers 对应的 Gemini CLI 配置

| MCP | Gemini CLI 配置 | 依赖 |
|-----|----------------|------|
| `ssh` | `npx -y @modelcontextprotocol/server-ssh` | Node.js, SSH |
| `fetch` | `npx -y @modelcontextprotocol/server-fetch` | Node.js |
| `postgres` | `npx -y @modelcontextprotocol/server-postgres` | Node.js, PostgreSQL |
| `brave-search` | `npx -y @modelcontextprotocol/server-brave-search` | Node.js, BRAVE_API_KEY |
| `codegraph` | `npx -y @colbymchenry/codegraph` | Node.js |
| `filesystem` | 内置或 `npx -y @modelcontextprotocol/server-filesystem` | Node.js |

## 使用方式

### 1. 安装 MCP Servers

参考上表配置 `~/.gemini/settings.json`，然后在 Gemini CLI 中验证：

```bash
/mcp list    # 查看已连接的 MCP
/mcp reload  # 重新加载
```

### 2. 安装 Skills

**方式一：批量转换**
```bash
./ai/scripts/convert-to-gemini-skills.sh
/skills reload
```

**方式二：从 Git 安装**
```bash
gemini skills install https://github.com/yizhiyanhua-ai/fireworks-tech-graph.git --consent
```

## 已适配的 Skills

| Skill | 类型 | 安装方式 | 说明 |
|-------|------|----------|------|
| fireworks-tech-graph | 技术绘图 | Git 安装 | 自然语言生成架构图/流程图 |

## 格式差异

| 特性 | ai-hub MCP | Gemini CLI MCP |
|------|------------|---------------|
| **配置位置** | `ai/conf/shared/mcp-servers/` | `~/.gemini/settings.json` |
| **配置格式** | JSON (标准化) | JSON (命令行格式) |
| **工具调用** | MCP 协议 | MCP 协议 |

## 常用 MCP Servers 推荐

| 服务 | Docker 命令 | npm 命令 |
|------|------------|----------|
| GitHub | `docker run ghcr.io/github/github-mcp-server` | - |
| Slack | `docker run ghcr.io/modelcontextprotocol/server-slack` | - |
| Filesystem | - | `npx -y @modelcontextprotocol/server-filesystem` |
| Fetch | - | `npx -y @modelcontextprotocol/server-fetch` |
| Postgres | - | `npx -y @modelcontextprotocol/server-postgres` |
| Brave Search | - | `npx -y @modelcontextprotocol/server-brave-search` |

完整服务器列表：[modelcontextprotocol/servers](https://github.com/modelcontextprotocol/servers)

## 目录结构

```
ai/conf/gemini-skills/
├── README.md                          # 本文件
├── fireworks-tech-graph/              # 已适配 Skill
│   └── SKILL.md
└── settings-template.json              # MCP 配置模板
```

## 参考文档

- [Gemini CLI MCP 接入教程](https://www.studynil.com/ai/ai-tools/gemini-cli/tutorials/mcp-setup.html)
- [Gemini CLI Skills 官方文档](https://github.com/google-gemini/gemini-cli/blob/main/docs/cli/skills.md)
- [MCP Servers 官方仓库](https://github.com/modelcontextprotocol/servers)
