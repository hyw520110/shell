# 技术绘图 (Fireworks)

自然语言生成技术架构图、流程图和 UML 图，支持 7 种视觉风格（扁平/暗黑/蓝图/Notion/玻璃态/Claude/OpenAI）。

## 分类

diagram

## 使用方式

使用中文描述你的系统，几秒钟得到可直接发布的 SVG + PNG 技术图。

**触发词：**
- 画图 / 帮我画 / 生成图 / 做个图
- 架构图 / 流程图 / 可视化一下 / 出图

## 提示词示例

### 风格 1 — 扁平图标风（默认）
```
画一张 style 1（扁平图标风）的 Mem0 记忆架构图。
分成四个横向区域：Input Layer、Memory Manager、Storage Layer、Output / Retrieval。
包含 User、AI App / Agent、LLM、mem0 Client、Memory Manager、Vector Store、Graph DB、Key-Value Store、History Store、Context Builder、Ranked Results、Personalized Response。
使用 read、write、control、data 四类语义箭头，整体保持产品文档风格的清晰布局。
```

### 风格 2 — 暗黑极客风
```
画一张 style 2（暗黑极客风）的 tool call flow 图。
包含 User query、Retrieve chunks、Generate answer、Knowledge base、Agent、Terminal、Source documents、Grounded answer。
使用终端窗口 chrome、Neon 强调色、等宽字体，以及 retrieval、answer synthesis、embedding update 三类语义箭头。
```

### 风格 3 — 工程蓝图风
```
画一张 style 3（蓝图）的微服务架构图。
使用带编号的工程分区标题，例如 01 // EDGE、02 // APPLICATION SERVICES、03 // DATA + EVENT INFRA、04 // OBSERVABILITY。
包含 Client Apps、API Gateway、Auth / Policy、三个业务服务、Event Router、Postgres、Redis Cache、Warehouse、Metrics / Traces。
使用蓝图网格、青色描边，并在右下角加入工程 title block。
```

### 风格 4 — Notion 极简风
```
画一张 style 4（Notion Clean）的 agent memory types 图。
以中间的 Agent Core 为中心，对比 Sensory Memory、Working Memory、Episodic Memory、Semantic Memory、Procedural Memory。
使用极简白底、浅边框、单一强调色箭头，并给每种 memory 补充简短的存储标签。
```

### 风格 5 — 玻璃态卡片风
```
画一张 style 5（Glassmorphism）的 multi-agent collaboration 图。
分成 Mission Control、Specialist Agents、Synthesis 三个区域。
包含 User brief、Coordinator Agent、Research Agent、Coding Agent、Review Agent、Shared Memory、Synthesis Engine、Final response。
使用 frosted glass 卡片、轻微 glow，以及 delegation、shared memory write、synthesis output 三类语义箭头。
```

### 风格 6 — Claude 官方风格
```
画一张 style 6（Claude Official）的 system architecture 图。
使用左侧 layer label：Interface Layer、Core Layer、Foundation Layer。
包含 Client Surface、Gateway、Task Planner、Model Runtime、Policy Guardrails、Memory Store、Tool Runtime、Observability、Registry。
使用温暖奶油色背景、克制的品牌感配色、足够留白，并在右下角放 legend。
```

### 风格 7 — OpenAI 官方风格
```
画一张 style 7（OpenAI Official）的 API integration flow 图。
分成 Entry、Model + Tools、Delivery 三个区域。
包含 Application、OpenAI SDK Layer、Prompt Builder、Model Runtime、Tool Calls、Response Formatter、Observability、Release Control。
整体保持纯白、精确、现代、极简，并使用干净的绿色语义箭头。
```

## 7 种风格速查

| 风格 | 名称 | 背景色 | 适用场景 |
|------|------|--------|----------|
| 1 | 扁平图标风 | 白色 | 博客、幻灯片、技术文档 |
| 2 | 暗黑极客风 | 深色 | GitHub README、开发者文章 |
| 3 | 工程蓝图风 | 深蓝 | 架构设计文档、工程规范 |
| 4 | Notion 极简风 | 白色 | Notion、Confluence、内部 Wiki |
| 5 | 玻璃态卡片风 | 深色渐变 | 产品官网、演讲 Keynote |
| 6 | Claude 官方风格 | 奶油色 | Anthropic 风格图表 |
| 7 | OpenAI 官方风格 | 纯白 | OpenAI 风格图表 |

## 支持的图类型

- **架构图** - 服务、组件、云基础设施
- **数据流图** - 数据在系统中的流向
- **流程图** - 决策树、流程步骤
- **Agent 架构图** - LLM + 工具 + 记忆
- **记忆架构图** - Mem0、MemGPT 风格
- **序列图** - API 调用链、时序交互
- **对比图** - 功能矩阵、方案比较
- **思维导图** - 概念地图、发散思维

## UML 图类型（14种）

类图、组件图、部署图、包图、复合结构图、对象图、用例图、活动图、状态机图、序列图、通信图、时序图、交互概览图、ER 图

## AI/Agent 领域内建 Pattern

- RAG Pipeline
- Agentic RAG
- Agentic Search
- Mem0 记忆层
- Agent 记忆类型
- Multi-Agent
- Tool Call 流程

## 形状词汇表

| 概念 | 形状 |
|------|------|
| 用户 / 人类 | 圆形 + 身体路径 |
| LLM / 模型 | 圆角矩形，双边框，⚡ |
| Agent / 编排器 | 六边形 |
| Vector Store | 带内环圆柱 |
| Graph DB | 三圆簇 |
| 工具 / 函数 | 带 ⚙ 的矩形 |

## 安装依赖

```bash
# macOS
brew install librsvg

# Ubuntu/Debian
sudo apt install librsvg2-bin

# 验证安装
rsvg-convert --version
```

## 安装 Skill

```bash
gemini skills install https://github.com/yizhiyanhua-ai/fireworks-tech-graph.git --consent
```

## 输出格式

- **SVG** - 可编辑矢量图
- **PNG** - 1920px 宽度，可直接发布

## 提示

- 使用 `--output ~/Desktop/` 指定输出路径
- 复杂架构使用泳道分组
- 每种风格都有精确的颜色 Token 和 SVG 模板

## 原始配置

此 Skill 由 ai-hub 管理，原始配置位于:
`ai/conf/shared/skills/fireworks-tech-graph.json`
