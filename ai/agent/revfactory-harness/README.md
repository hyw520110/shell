# RevFactory Harness

Claude Code 的 Team-Architecture Factory，自动生成 Agent 团队架构和 Skills。

> **注意**: 这个项目与 CI/CD 的 Harness 无关。这是一个 Claude Code 插件，用于生成 Agent 团队架构。

## 项目信息

- **GitHub**: https://github.com/revfactory/harness
- **版本**: 1.2.0
- **License**: Apache 2.0

## 主要功能

| 功能 | 说明 |
|------|------|
| **Agent 团队设计** | 6 种架构模式 |
| **Skill 生成** | 自动生成带渐进式披露的 Skills |
| **编排** | Agent 间数据传递、错误处理、团队协调协议 |
| **验证** | 触发器验证、干运行测试、Skill 对比测试 |
| **Harness 进化机制** | 从实际项目中学习并改进下一生成 |

## 架构模式

| 模式 | 描述 | 适用场景 |
|------|------|----------|
| **Pipeline** | 顺序依赖任务 | 线性工作流 |
| **Fan-out/Fan-in** | 并行独立任务 | 可并行的任务 |
| **Expert Pool** | 上下文选择性调用 | 多专家协作 |
| **Producer-Reviewer** | 生成后质量评审 | 需要质量保证的内容 |
| **Supervisor** | 中心 Agent 动态任务分配 | 复杂动态场景 |
| **Hierarchical Delegation** | 顶层递归委派 | 多层级复杂任务 |

## 安装

### 方式一：ai-hub（推荐）

```bash
cd ~/workspace/shell/ai
./ai-hub.sh
# 选择 Agent 工具 → RevFactory Harness
```

### 方式二：直接运行安装脚本

```bash
bash ~/workspace/shell/ai/agent/revfactory-harness/install-revfactory-harness.sh install
```

### 方式三：Claude Code Marketplace

```shell
/plugin marketplace add revfactory/harness
/plugin install harness@harness
```

### 方式四：直接复制 Skills

```shell
git clone https://github.com/revfactory/harness.git
cp -r harness/skills/harness ~/.claude/skills/harness
```

## 常用命令

```bash
# 安装
bash ~/workspace/shell/ai/agent/revfactory-harness/install-revfactory-harness.sh install

# 更新
bash ~/workspace/shell/ai/agent/revfactory-harness/install-revfactory-harness.sh update

# 查看状态
bash ~/workspace/shell/ai/agent/revfactory-harness/install-revfactory-harness.sh status

# 卸载
bash ~/workspace/shell/ai/agent/revfactory-harness/install-revfactory-harness.sh uninstall
```

## 使用方式

在 Claude Code 中使用以下提示词触发：

```
Build a harness for this project
Design an agent team for this domain
Set up a harness
```

### 示例场景

#### 深度研究
```
Build a harness for deep research. I need an agent team that can investigate
any topic from multiple angles — web search, academic sources, community
sentiment — then cross-validate findings and produce a comprehensive report.
```

#### 网站开发
```
Build a harness for full-stack website development. The team should handle
design, frontend (React/Next.js), backend (API), and QA testing in a
coordinated pipeline from wireframe to deployment.
```

### 执行模式

| 模式 | 描述 | 推荐场景 |
|------|------|----------|
| **Agent Teams** (默认) | TeamCreate + SendMessage + TaskCreate | 2+ 个需要协作的 Agent |
| **Subagents** | 直接 Agent 工具调用 | 一次性任务，无需 Agent 间通信 |

## 工作流程

```
Phase 1: Domain Analysis
    ↓
Phase 2: Team Architecture Design (Agent Teams vs Subagents)
    ↓
Phase 3: Agent Definition Generation (.claude/agents/)
    ↓
Phase 4: Skill Generation (.claude/skills/)
    ↓
Phase 5: Integration & Orchestration
    ↓
Phase 6: Validation & Testing
```

## 生成的文件

Harness 在项目中会生成以下结构：

```
your-project/
├── .claude/
│   ├── agents/          # Agent 定义文件
│   │   ├── analyst.md
│   │   ├── builder.md
│   │   └── qa.md
│   └── skills/          # Skill 文件
│       ├── analyze/
│       │   └── SKILL.md
│       └── build/
│           ├── SKILL.md
│           └── references/
```

## Harness 进化机制

Harness 的核心功能是从实际项目中学习：

```
Initial harness ──▶ Real project use ──▶ Shipped harness
                                              │
                                              ▼ (delta capture via /harness:evolve)
                                        ┌───────────────┐
                                        │  Factory      │◀── better next-gen draft
                                        └───────────────┘
```

使用 `/harness:evolve` Skill 可以捕获初始架构和实际交付之间的差异，并反馈到工厂中，使类似领域的下一生成更接近已交付状态。

## 插件结构

```
harness/
├── .claude-plugin/
│   └── plugin.json                 # Plugin manifest
├── skills/
│   └── harness/
│       ├── SKILL.md                # Main skill definition (6-Phase workflow)
│       └── references/
│           ├── agent-design-patterns.md   # 6 architectural patterns
│           ├── orchestrator-template.md   # Team/subagent orchestrator templates
│           ├── team-examples.md           # 5 real-world team configurations
│           ├── skill-writing-guide.md     # Skill authoring guide
│           ├── skill-testing-guide.md     # Testing & evaluation methodology
│           └── qa-agent-guide.md          # QA agent integration guide
└── README.md
```

## 多语言支持

- **English**: `Build a harness for this project`
- **한국어**: `하네스 구성해줘`
- **日本語**: `ハーネスを構成して`

## 生态系统层次

| 层 | 功能 | 相关项目 |
|----|------|----------|
| **L3 — Meta-Factory / Team-Architecture Factory** (我们) | 领域描述 → Agent 团队 + Skills，通过 6 种预定义团队模式 | — |
| L3 — Meta-Factory / Runtime-Configuration Factory | 确定性、可重复的运行时配置 | [Archon](https://github.com/coleam00/Archon) |
| L3 — Meta-Factory / Codex Runtime Port | 相同概念，Codex 运行时 | [meta-harness](https://github.com/SaehwanPark/meta-harness) |
| L2 — Cross-Harness Workflow | 跨多个 Harness 标准化 Skills/Rules/Hooks | [ECC](https://github.com/affaan-m/everything-claude-code) |

> **提示**: 使用 Archon 获得运行时确定性，使用 Harness 获得团队架构，或者两者结合使用。

## 与 CI/CD Harness 的区别

| 项目 | 用途 |
|------|------|
| **revfactory/harness** | Claude Code 插件，生成 Agent 团队架构 |
| **harness/harness** (CICD 目录) | CI/CD 平台，用于 DevOps 流水线 |

两个项目同名但完全独立！

## 文档

- [官方 README](https://github.com/revfactory/harness)
- [한국어 문서](https://github.com/revfactory/harness/blob/main/README_KO.md)
- [日本語](https://github.com/revfactory/harness/blob/main/README_JA.md)
