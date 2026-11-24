# AI 服务器环境

AI 服务器环境所需软件清单及安装时间估算。

## 当前已有软件

| 类别 | 软件 | 数量 | 状态 |
|------|------|------|------|
| AI 客户端 (CLI) | Claude、Cursor、Gemini、DeepSeek、Kimi、GPT-CLI 等 | 37个 | ✅ 已配置 |
| AI IDE | Trae、Windsurf、Aider-Desk、Pear AI、Codex-IDE、Zed | 6个 | ✅ 已配置 |
| Agent 框架 | OpenManus、CrewAI、MetaGPT、OpenHands、Aider 等 | 13个 | ✅ 已配置 |
| 本地运行时 | Ollama、LocalAI、vLLM、Open-WebUI、DS4 | 5个 | ✅ 已配置 |
| AI 网关 | One-API、New-API、Sub2API | 3个 | ✅ 已配置 |
| MCP Servers | filesystem、github、playwright、postgres 等 | 13个 | ✅ 已配置 |
| Skills | PRD 编写、架构图生成、原型设计等 | 37个 | ✅ 已配置 |

## 推荐补充软件

| 软件 | 用途 | 优先级 | 安装时间 | 下载来源 |
|------|------|--------|----------|----------|
| **推理引擎** |
| TensorRT | NVIDIA 加速推理 | 高 | 30分钟 | NVIDIA 官网 |
| Triton Inference Server | 模型服务化 | 高 | 20分钟 | NVIDIA 官网 |
| **模型管理** |
| MLflow | 模型生命周期管理 | 中 | 15分钟 | pip/Docker |
| **向量数据库** |
| Milvus | 向量检索 | 高 | 20分钟 | Docker |
| Qdrant | 向量数据库 | 中 | 15分钟 | Docker |
| Chroma | 轻量向量 DB | 低 | 10分钟 | pip |
| **AI 中间件** |
| LangChain/LangServe | LLM 应用框架 | 高 | 10分钟 | pip |
| LlamaIndex | RAG 框架 | 高 | 10分钟 | pip |
| Haystack | NLP 流水线 | 中 | 15分钟 | pip |
| **训练与微调** |
| DeepSpeed | 分布式训练 | 中 | 20分钟 | pip |
| Axolotl | 微调框架 | 低 | 15分钟 | GitHub |
| **AI 监控** |
| Weights & Biases | 实验追踪 | 中 | 10分钟 | pip |
| LangSmith | LLM 应用监控 | 中 | 10分钟 | 官网 |
| **多模态** |
| Stable Diffusion WebUI | 图像生成 | 中 | 20分钟 | GitHub |
| ComfyUI | 工作流图像生成 | 中 | 20分钟 | GitHub |

## 安装时间汇总

| 优先级 | 软件数量 | 预估时间 |
|--------|----------|----------|
| 高优先级 | 6个 | 100分钟 |
| 中优先级 | 8个 | 115分钟 |
| 低优先级 | 3个 | 45分钟 |
| **总计** | **17个** | **约 4-5 小时** |

## 快速安装命令

```bash
# 向量数据库
./ai/vector/install-milvus.sh     # 如需添加
./ai/vector/install-qdrant.sh     # 如需添加

# AI 中间件
pip install langchain langserve   # 如需添加
pip install llama-index           # 如需添加

# 模型管理
pip install mlflow                # 如需添加

# 推理加速 (需 NVIDIA GPU)
./ai/runtime/install-tensorrt.sh  # 如需添加
```

## 已下载可用软件

从 `~/Downloads` 目录可直接安装：

| 软件 | 文件名 | 用途 |
|------|--------|------|
| Ollama | Ollama-darwin.zip | 本地 LLM |
| Open-WebUI | open-webui-0.9.5.tar.gz | Web UI |
| Draw.io | draw.io-arm64-30.0.2.dmg | 流程图 |
| Cursor | Cursor-darwin-universal.dmg | AI IDE |
| Trae | TRAE_SOLO_CN-darwin-arm64.dmg | AI IDE |
| Windsurf | Windsurf-darwin-arm64-2.2.17.dmg | AI IDE |
| ChatGPT | ChatGPT.dmg | 桌面客户端 |

## DS4 本地部署推荐客户端

| 客户端 | 推荐度 | 配置方式 |
|--------|--------|----------|
| **Aider** | ⭐⭐⭐ 首选 | `aider --model openai/ds4 --context 65536` |
| **DeepSeek-TUI** | ⭐⭐⭐ | `deepseek --model ds4` |
| **DeepSeek Reasonix** | ⭐⭐ | `reasonix code` |

### Aider 配置

```bash
# ~/.zshrc
export OPENAI_API_KEY="none"
export OPENAI_API_BASE="http://localhost:3003/v1"
export AIDER_CONTEXT_WINDOW=65536

# 启动
aider --model openai/ds4
```

### DeepSeek-TUI 配置

```bash
# ~/.deepseek/config.toml
provider = "openai"

[providers.openai]
api_key = "none"
base_url = "http://localhost:3003/v1"
model = "ds4"
```

## 服务端口速查

| 服务 | 默认端口 | 访问地址 |
|------|----------|----------|
| Ollama | 11434 | http://localhost:11434 |
| Open-WebUI | 8080 | http://localhost:8080 |
| DS4 | 3003 | http://localhost:3003/v1 |
| One-API | 3000 | http://localhost:3000 |
| LocalAI | 8080 | http://localhost:8080 |
| Milvus (如需添加) | 19530 | localhost:19530 |
| Qdrant (如需添加) | 6333 | http://localhost:6333 |
