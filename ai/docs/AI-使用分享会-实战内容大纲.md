# AI 使用分享会 —— 实战内容大纲

> **定位**: 项目实战技能实操分享，非知识理论讲座。每一节都有可操作的命令、可复现的结果、可带走的配置。

---

## 1. 开场：5 分钟

### 1.1 破冰：你被 AI 写过多少无用代码？

| 场景 | 你的遭遇 | Ponytail 的解法 |
|------|---------|----------------|
| 加个日期选择器 | AI 装了 flatpickr + wrapper + 样式表 | `<input type="date">` |
| 写个 debounce | AI 写了 40 行闭包 + 类型体操 | `_.debounce` 已经装过了 |
| 加个 CSV 导出 | AI 装了 3 个库 + 150 行代码 | `python3 -c "import csv; ..."` |

**现场演示**：用 Claude Code 分别在有/无 Ponytail 的情况下完成同一个需求，对比代码量。

### 1.2 一句话概括 AI Hub 能做什么

> 从"装什么 AI 工具"到"怎么用好 AI 工具"到"让 AI 少写垃圾代码"，一站式搞定。

---

## 2. 环境搭建实战：15 分钟

### 2.1 演示：ai-hub.sh 一键批量配置

**动手操作**（观众可跟做）：
```bash
cd ai
./ai-hub.sh
# 选择 "批量配置" → "按标签动态配置" → "全选" → 确认
```

**展示结果**：
- 自动安装 MCP 服务器 (31 个)
- 自动安装 Skills (89 个)
- 一键同步到 Cursor / Trae / Windsurf 配置

### 2.2 演示：setup-ai-provider.sh 配置本地模型客户端

**场景**：你有一台 Mac Studio M4 部署了 vLLM，想用 Claude Code 连本地模型。

```bash
./ai/setup-ai-provider.sh --auto-discover
# 自动探测局域网 OpenAI-compatible 服务
# 生成 codex-local / claude-local / aider-local / qwen-local 四个命令
```

**展示结果**：`claude-local` 命令启动 Claude Code，但 API 走本地 vLLM，不消耗 API 额度。

### 2.3 演示：环境自检

```bash
./ai-hub.sh --validate
# 展示哪些 MCP 缺 Token、哪些依赖未安装
```

---

## 3. 核心技能组合技：20 分钟

### 3.1 "代码质量三件套"：ponytail + karpathy-guidelines + planning-with-files

| 技能 | 作用 | 激活方式 |
|------|------|---------|
| `ponytail` | 不写多余代码 (80-94% 代码减少) | `/plugin install ponytail@ponytail` |
| `karpathy-guidelines` | 先思后行、极简主义、外科手术式变更 | 自动生效 |
| `planning-with-files` | 多步骤任务先出计划再执行 | 自动生效 |

**现场演示**：用 Claude Code 完成一个中等复杂度需求（如"给用户列表加导出功能"），展示三件套叠加效果。

### 3.2 "调研分析三件套"：last30days + anysearch + brave-search

**现场演示**：调研一个话题（如"2026 年 AI Agent 框架对比"），展示：
1. `last30days-skill` 自动聚合 Reddit/HN/X/YouTube 最新讨论
2. `anysearch-skill` 批量搜索技术文档
3. `brave-search` 补充竞品信息

### 3.3 "原型到代码"流水线：pm-image2proto + frontend-design + hallmark

**现场演示**：给一张竞品截图 → 生成 HTML 原型 → 用 hallmark 变换主题 → 验收

---

## 4. 本地 LLM 部署实战：20 分钟

### 4.1 硬件选择速查

| 设备 | 推荐引擎 | 推荐模型 | 成本 |
|------|---------|---------|------|
| Mac Studio M4 128GB | vllm-metal | Qwen2.5-72B (4bit) | 零 API 费用 |
| MacBook M3/M4 32GB | Ollama + MLX | Qwen2.5-32B (4bit) | 零 API 费用 |
| RTX 4090 24GB | vLLM CUDA | Qwen2.5-14B (BF16) | 零 API 费用 |

### 4.2 演示：vllm-metal 一键部署

```bash
cd ai/runtime/vllm
./install_vllm.sh -e vllm-metal -m qwen2.5-72b
# 自动编译 vLLM → 下载 MLX 量化模型 → 生成启动脚本 → 启动服务
```

**展示结果**：
- `curl http://localhost:8000/v1/models` 验证模型就绪
- `curl http://localhost:8000/v1/chat/completions` 测试推理

### 4.3 演示：Open WebUI 对接本地模型

```bash
cd ai/runtime/open-webui
./install-open-webui.sh
# 浏览器打开 http://localhost:3000，选择本地 vLLM 模型
```

---

## 5. 多 Agent 协同实战：15 分钟

### 5.1 场景：一个需求，多个 Agent 分工

| 阶段 | Agent | 工具 |
|------|-------|------|
| 需求分析 | Claude Code | pm-prd-writer, last30days-skill |
| 原型设计 | Cursor | frontend-design, hallmark |
| 编码实现 | Trae + Aider | ponytail, karpathy-guidelines |
| 代码审查 | Claude Code | ponytail-review, code-review-graph |
| 测试 | Claude Code | qa-automation-expert + playwright |
| 部署 | Claude Code | ssh MCP |

**现场演示**：走通一个完整的小需求（如"做一个团队 Todo 看板"），展示每个阶段的实际输出。

### 5.2 演示：handoff-assistant 上下文交接

当从 Claude Code 切换到 Cursor 时，`handoff-assistant` 自动生成交接文档，避免重新解释上下文。

---

## 6. 踩坑与排错：10 分钟

### 6.1 常见问题速查

| 问题 | 原因 | 解决 |
|------|------|------|
| vllm-metal 编译失败 | macOS SDK 版本不匹配 | `xcode-select --install` 后重试 |
| MCP 显示 Disconnected | 缺少 Token 环境变量 | `./ai-hub.sh --validate` 查看缺失项 |
| Ponytail 反而变慢 | 用的是 thinking 模型 (GPT-5.5) | 切换到 Sonnet/Haiku 或关闭 Ponytail |
| Ollama 模型下载慢 | 默认从 HuggingFace 拉取 | 使用 `hf-mirror.com` 镜像加速 |
| Codex 插件不生效 | nvm 的 node 不在非交互 shell PATH | `which node` 确认路径，添加到 `~/.zprofile` |

### 6.2 调试三板斧

```bash
# 1. 全量配置校验
./ai-hub.sh --validate

# 2. 查看工具状态
./ai-hub.sh --status <tool-id>

# 3. 查看工具配置
./ai-hub.sh --config <tool-id>
```

---

## 7. 动手练习：15 分钟

### 练习 1：安装 Ponytail 并对比效果 (5 分钟)
```bash
# Claude Code 中执行
/plugin marketplace add DietrichGebert/ponytail
/plugin install ponytail@ponytail
# 重启后随便提一个需求，观察输出变化
```

### 练习 2：用 last30days 调研一个新话题 (5 分钟)
```bash
# Claude Code 中执行
/last30days <你感兴趣的任何话题>
# 查看生成的 HTML 简报
```

### 练习 3：配置本地模型客户端 (5 分钟)
```bash
cd ai
./setup-ai-provider.sh --auto-discover
# 如果没有本地模型，用免费的 token173 等 API 也可
./setup-ai-provider.sh token173 <your-key> https://token173.com/v1
```

---

## 8. 可带走的资源清单

### 8.1 配置文件一键复制

```bash
# 复制整个 ai 目录到你的项目
cp -r ai /your-project/

# 或只复制 skills 配置
cp ai/conf/shared/skills/*.json ~/.claude/skills/
```

### 8.2 推荐的默认配置组合

| 场景 | 推荐组合 |
|------|---------|
| 日常编码 | ponytail + karpathy-guidelines + planning-with-files |
| 产品设计 | pm-prd-writer + frontend-design + hallmark |
| 技术调研 | last30days-skill + anysearch-skill + brave-search |
| 安全审计 | security-sentinel + trivy-security + pentest-mcp |
| 本地推理 | vllm-metal + open-webui + setup-ai-provider.sh |

### 8.3 速查卡片

```
┌─────────────────────────────────────────────────────────┐
│                    AI Hub 速查卡片                        │
├─────────────────────────────────────────────────────────┤
│ 安装:    ./ai-hub.sh → 批量配置 → 全选                     │
│ 校验:    ./ai-hub.sh --validate                          │
│ MCP:     ./ai-hub.sh --mcp                               │
│ Skills:  ./ai-hub.sh --skills                            │
│ 客户端:  ./setup-ai-provider.sh --auto-discover           │
│ vLLM:    ./runtime/vllm/install_vllm.sh -e vllm-metal     │
│                          -m qwen2.5-72b                   │
│ Ponytail: /plugin install ponytail@ponytail               │
│ 调研:    /last30days <话题>                                │
└─────────────────────────────────────────────────────────┘
```

---

## 9. Q&A 储备问题

预先准备以下高频问题的答案：

1. **Q: 这些工具会不会和现有的 IDE 配置冲突？**
   A: ai-hub 使用穿透式同步，不会覆盖已有配置，只会追加新条目。

2. **Q: 本地模型和云端 API 差距大吗？**
   A: 4bit 量化后 72B 模型在大部分编码任务上接近 Sonnet 水平，但复杂推理仍有差距。建议：编码用本地模型省 Token，复杂架构用云端 API。

3. **Q: 需要多少硬盘空间？**
   A: ai-hub 本身 < 10MB，Skills + MCP 配置 < 2MB。本地模型需要额外空间：72B 4bit ≈ 40GB，32B 4bit ≈ 18GB。

4. **Q: Ponytail 会不会让 AI 过于激进，跳过必要的代码？**
   A: 不会。安全边界（输入验证、错误处理、安全措施、无障碍）明确不受阶梯约束。默认 full 模式已平衡好。

5. **Q: 公司内网环境怎么用？**
   A: 大部分 Skills 零 API 依赖，MCP 中 filesystem/git/ssh 纯本地运行。网络搜索类 Skills 需要外网，可用内网镜像。

---

## 附录：分享会所需物料清单

| 物料 | 说明 |
|------|------|
| 投影/屏幕 | 展示终端操作 |
| 终端环境 | 提前安装好 ai-hub 依赖 (jq, node, python) |
| 网络环境 | 能访问 GitHub / HuggingFace (或提前下载好模型) |
| 演示项目 | 准备一个简单的示例项目，便于演示 |
| 速查卡片 | 打印/电子版，发给参会者 |
| 配置文件 | 准备一个 `ai-conf-bundle.tar.gz` 可直接分发 |