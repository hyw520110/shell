# AI CLI 配置文件 V2

## 目录结构

```
ai-cli-config-v2/
├── global.json              # 全局配置（代理、镜像、场景注册表、路径等）
├── tools/                   # 工具元数据（按分类分目录）
│   ├── _template.json       # 新工具模板
│   ├── cli/
│   ├── ide/
│   ├── agent/
│   ├── gateway/
│   └── runtime/
└── shared/                  # 公共配置（被多个工具共享）
    ├── mcp-servers/         # 公共 MCP 服务器
    │   ├── filesystem.json
    │   ├── github.json
    │   └── ...
    └── skills/              # 公共 Skills
        ├── git.json
        ├── pdf.json
        └── ...
```

## 工具配置结构

每个工具配置文件包含：

| 字段 | 说明 |
|------|------|
| `id` | 工具唯一标识 |
| `name` | 工具显示名称 |
| `description` | 工具描述 |
| `category` | 分类（ai-coding, ai-agent, ai-ide, ai-gateway, ai-runtime 等） |
| `tags` | 标签数组 |
| `install` | 安装配置（支持多安装方式） |
| `update` | 更新配置 |
| `config` | 配置文件管理（view/edit/reset） |
| `commands` | 常用命令（start/version/login 等） |
| `status_check` | 状态检查命令列表 |
| `mcp_servers` | 该工具专属的 MCP 服务器定义 |
| `skills` | 该工具专属的 Skills 定义 |
| `recommended_extension_commands` | Skill 推荐扩展命令（如 draw.io CLI），只在安装 Skill/Bundle 时提示可选安装，不进入主菜单 |
| `references` | 引用公共 MCP/Skills |
| `notes` | 使用说明和注意事项 |

## 场景配置机制

`global.json.scenarios` 只注册合法场景和展示策略，不再维护 MCP/Skills 显式清单。具体某个 MCP 或 Skill 属于哪些场景，由它自己的 `scenarios` 字段声明。

新增 MCP/Skill 时只需要维护对应配置文件：

- `shared/mcp-servers/<id>.json`
- `shared/skills/<id>.json`

批量配置时，`ai-hub.sh` 会：

1. 扫描所有 MCP/Skill 配置。
2. 选择 `scenarios` 包含目标场景的条目。
3. 自动合并 Skill 的 `dependencies.mcp_servers`。
4. 跳过 `optional=true` 或 `experimental=true` 的默认启用项。
5. 先做结构校验；环境变量只在本次选中的 MCP 即将写入时检查。

如果某个 MCP 声明了 `requires_env` 但当前环境未设置，批量配置会跳过该 MCP，避免写入后在 AI Agent 中显示 `Disconnected`。可以通过“检查 MCP / Skills 配置”菜单主动查看全量环境变量警告。

## 共享 MCP 配置模板

复制模板：

```bash
cp shared/mcp-servers/_template.json shared/mcp-servers/<id>.json
```

必填字段：

| 字段 | 说明 |
|------|------|
| `id` | MCP 唯一标识，建议与文件名一致 |
| `name` | 显示名称 |
| `description` | 能力说明 |
| `category` | 分类 |
| `scenarios` | 所属场景，必须来自 `global.json.scenarios` |
| `tags` | 标签数组，用于按标签配置 |
| `homepage` 或 `repository` | 官方主页或 GitHub 仓库链接 |
| `config.command` | MCP 启动命令 |

需要密钥的 MCP 应设置：

```json
{
  "optional": true,
  "requires_env": ["BRAVE_API_KEY"]
}
```

实验性或不稳定 MCP 应设置：

```json
{
  "experimental": true,
  "default_enabled": false
}
```

## 共享 Skill 配置模板

复制模板：

```bash
cp shared/skills/_template.json shared/skills/<id>.json
```

必填字段：

| 字段 | 说明 |
|------|------|
| `id` | Skill 唯一标识，建议与文件名一致 |
| `name` | 显示名称 |
| `description` | 使用场景和目标输出 |
| `category` | 分类 |
| `scenarios` | 所属场景，必须来自 `global.json.scenarios` |
| `tags` | 标签数组 |
| `homepage` 或 `repository` | 官方主页或 GitHub 仓库链接 |
| `dependencies` | 依赖的 MCP、系统命令或外部服务 |

如果 Skill 依赖已配置的 MCP：

```json
{
  "dependencies": {
    "mcp_servers": ["codegraph"]
  }
}
```

批量配置会自动把这些 MCP 合并到目标 AI Agent 配置中。若依赖的 MCP 声明了 `requires_env` 且当前环境缺失，脚本会提示并跳过该 MCP，本次仍会继续安装/配置 Skill。

## 添加新工具

1. 复制模板：`cp tools/_template.json tools/<category>/new-tool.json`
2. 选择正确分类目录：`cli` / `ide` / `agent` / `gateway` / `runtime`
3. 编辑配置文件
4. 验证格式：`jq '.' tools/<category>/new-tool.json`

## 变量替换

配置中使用 `{{variable}}` 语法：

| 变量 | 说明 |
|------|------|
| `{{npm_registry}}` | 从 global.json 读取 |
| `{{chrome_path}}` | 自动检测 Chrome 路径 |
| `{{github_token}}` | 用户输入 |
| `{{env.HOME}}` | 环境变量 |

## 加载逻辑

```
加载 global.json
  ├─ 解析全局配置
  ├─ 加载 scenarios 场景注册表
  ├─ 加载 tools/ 下所有工具配置
  ├─ 加载 shared/mcp-servers/ 下所有公共 MCP
  └─ 加载 shared/skills/ 下所有公共 Skills
```

## 元数据与实现分离

- `conf/tools/**.json` 只负责描述工具元数据。
- 工具专属脚本、模板、部署资源应放到分类实现目录：
  - `ai/agent/<tool>/`
  - `ai/ide/<tool>/`
  - `ai/runtime/<tool>/`
  - `ai/gateway/<tool>/`
- `ai/scripts/` 只保留公共脚本，不再放单个工具的长期实现。
