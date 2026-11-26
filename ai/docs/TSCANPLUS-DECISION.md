# TscanPlus MCP/Skill 处理决策

> 日期：2026-11-25（2026-11-26 随脚本迁移更新）。决策：**方案 D**（用户选择）。

## 决策

- `tscanplus.sh` 归入 AI 工具链仓库的 `ai/scripts/tscanplus.sh`，作为 ai-hub MCP 的安装入口。
- `ai/conf/shared/mcp-servers/tscanplus.json` 的安装命令为 `bash scripts/tscanplus.sh install mcp`（相对 `ai/` 目录），并说明安装后启动器自包含于 `~/.local/share/tscanplus/`。
- 安全工具仓库不再保留 `tscanplus.sh` 副本，避免双份漂移。
- **不安装、不启用** TscanPlus MCP：仍 `experimental=true`、`default_enabled=false`。其 POC/弱口令/目录枚举能力与公益 SRC 低影响红线冲突，需明确授权实验室 + 人工审查后才可启用。

## 原因

- ai-hub 只应引用自身仓库内的脚本，跨仓库路径在目录调整后必然失效。
- 安装后 `tscanplus-mcp` 启动器自包含于用户目录，运行时不依赖仓库路径。
- 扫描与复核流程仍在安全工具仓库，TscanPlus 只作为侦察入口，职责分离更清晰。
