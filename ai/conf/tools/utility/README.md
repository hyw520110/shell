# AI Hub 工具组件

本目录存放可被 AI 客户端、Agent 或工作流调用的辅助 CLI 和工具组件，不属于 AI 客户端本身。

目录约定：

- `ai/conf/tools/cli/`：仅存放面向用户的 AI 客户端 CLI
- `ai/conf/tools/utility/`：浏览器自动化、代码图谱、代码审查、安全扫描、Skill 构建等辅助工具
- `ai/conf/tools/gateway/`：模型网关和路由服务
- `ai/conf/tools/builder/`：AI 应用和 Agent 平台

工具配置的 `category` 必须与所在目录一致；`ai-hub.sh --validate` 会检查该约束。
