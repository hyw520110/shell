# Matt Pocock Skills 集成与使用指南

## 1. 说明

当前项目统一集成官方仓库 [mattpocock/skills](https://github.com/mattpocock/skills)，中文仓库 [vinvcn/mattpocock-skills-zh-CN](https://github.com/vinvcn/mattpocock-skills-zh-CN) 仅作为中文阅读参考，不作为安装源。

选择官方仓库的原因：

- 官方仓库是能力定义和版本更新源，技能名称、依赖关系和工作流更新最及时。
- 中文仓库是上游内容的本地化版本，存在同步时间差，部分技能名称和流程可能落后于官方版本。
- 两个仓库包含大量同名 Skill，同时安装会产生覆盖顺序和更新来源不明确的问题。
- 当前项目已经通过 `AGENTS.md` 统一中文术语、项目规则和交付要求，使用英文 Skill 不影响中文交互和中文文档输出。

## 2. 集成原则

- 采用项目级安装，Skill 文件存放在仓库根目录 `.agents/skills/`，随项目版本管理。
- 使用 `--copy` 保存独立副本，避免提交依赖本机路径的符号链接。
- 不使用 `--global`，避免影响其它仓库。
- 不在 `web/` 和独立参考项目 `generator/` 中重复安装。
- `AGENTS.md` 始终高于第三方 Skill；Skill 不得绕过项目的完成契约、模块边界、构建命令和 `giter.sh` 提交规范。
- 不自动更新第三方 Skill。更新前先检查差异，确认没有引入与项目规则冲突的行为后再提交。

## 3. 首期安装范围

| 场景 | Skill | 用途 |
|---|---|---|
| 初始化 | `setup-matt-pocock-skills` | 配置任务跟踪方式和领域文档布局 |
| 需求澄清 | `grill-with-docs` | 对重要需求进行追问，同时维护领域术语和架构决策 |
| 需求澄清依赖 | `grilling` | 提供结构化追问流程 |
| 领域建模 | `domain-modeling` | 维护稳定业务术语、边界和关键场景 |
| 需求固化 | `to-spec` | 把已讨论内容整理为可验收规格 |
| 任务拆分 | `to-tickets` | 按可独立验证的纵向任务拆分规格并标明依赖 |
| 研发实现 | `implement` | 根据规格或任务执行实现、验证和评审 |
| 测试驱动 | `tdd` | 对适合测试先行的规则、接口和缺陷执行红绿重构循环 |
| 缺陷诊断 | `diagnosing-bugs` | 按复现、缩小范围、假设、验证、修复和回归的顺序定位问题 |
| 冲突处理 | `resolving-merge-conflicts` | 处理 merge/rebase 冲突并保留双方有效变更 |
| 代码评审 | `code-review` | 分别检查项目规范符合度和需求实现一致性 |

以下 Skill 暂不安装：

- `triage`：待项目正式采用 GitHub Issues 标签流转后再启用。
- `setup-pre-commit`：可能与现有 Jenkins、`package.sh` 和 `giter.sh` 流程重复或冲突。
- `git-guardrails-claude-code`：仅面向 Claude Code，不适用于当前 Codex 主流程。
- `improve-codebase-architecture`、`wayfinder`：仅在大型架构治理或跨会话规划确有需要时再补充。
- `research`、`codebase-design`：作为后续增强项，先观察首期 Skill 的实际使用效果。

## 4. 安装命令

在仓库根目录执行：

```bash
cd /Users/mac/workspace/linghang-platform
source ~/.zshrc

DISABLE_TELEMETRY=1 npx skills@latest add mattpocock/skills \
  --agent codex \
  --copy \
  --yes \
  --skill setup-matt-pocock-skills \
  --skill grill-with-docs \
  --skill grilling \
  --skill domain-modeling \
  --skill to-spec \
  --skill to-tickets \
  --skill implement \
  --skill tdd \
  --skill diagnosing-bugs \
  --skill resolving-merge-conflicts \
  --skill code-review
```

安装后通过以下命令检查项目级 Skill：

```bash
source ~/.zshrc
npx skills list --agent codex
```

## 5. 项目初始化约定

首次安装后运行 `setup-matt-pocock-skills`，采用以下项目约定：

- `AGENTS.md` 是最高优先级项目规范。
- 采用 single-context，根目录 `CONTEXT.md` 只记录稳定业务术语、领域关系和跨模块业务约束，不重复 `AGENTS.md` 的工程规则。
- 架构决策记录放在 `docs/adr/`。
- Agent 工作流配置放在 `docs/agents/`。
- 正式产品方案和 PRD 继续使用现有 `docs/解决方案/`、`docs/产品需求文档/` 体系，不把 Skill 的中间产物混入正式文档。
- `generator/` 是独立参考项目，不纳入当前仓库的领域上下文和任务跟踪。
- 任务跟踪目标使用 GitHub Issues；在 GitHub CLI 完成安装和认证前，不自动创建远程 Issue。

## 6. 具体使用方法

### 6.1 需求澄清

适用于业务规则、状态流转、权限、资金权益、风控或跨领域协作仍不明确的需求：

```text
使用 grill-with-docs 审查“用户奖励兑换闭环”需求。
结合现有产品方案、PRD、SQL 和代码，只追问会改变业务规则、状态流转或研发方案的问题。
确认后再更新 CONTEXT.md 或 ADR，不重复记录已有项目规则。
```

不建议对简单文案修改、明确的单文件修复使用该 Skill，避免增加无效沟通成本。

### 6.2 形成规格

```text
使用 to-spec 将当前讨论整理为可验收规格。
必须包含业务范围、角色权限、正常流程、异常状态、审计要求、数据口径和验收标准。
```

`to-spec` 用于固化已经讨论清楚的内容，不替代需求访谈；仍有关键分歧时应先使用 `grill-with-docs`。

### 6.3 拆分研发任务

```text
使用 to-tickets 将该规格拆成可独立实现和验证的纵向任务。
每个任务明确前置依赖、影响模块、完成标准和验证命令，避免只按 Controller、Service、SQL 横向分层拆分。
```

### 6.4 执行开发

```text
使用 implement 实现指定规格或任务。
必须遵守 AGENTS.md，先读取相关 PRD、SQL 和代码，按风险决定是否使用 tdd，并执行 package.sh 或前端构建验证。
```

`implement` 不改变当前项目的提交方式。验证通过后仍应按照 `AGENTS.md` 使用 `./giter.sh -m "中文提交信息"`，存在无关改动时不得混合提交。

### 6.5 缺陷诊断

```text
使用 diagnosing-bugs 分析该接口异常。
先复现并收集证据，再缩小范围、提出可验证假设、定位根因，最后修复并补充回归测试。
```

### 6.6 Git 冲突处理

```text
使用 resolving-merge-conflicts 处理当前 rebase 冲突。
分析 base、ours、theirs 和相关提交意图，保留双方有效业务内容，解决后执行对应验证，不得直接选择整侧覆盖。
```

### 6.7 代码评审

```text
使用 code-review 审查相对 origin/main 的变更。
分别检查 AGENTS.md 等项目规范符合度，以及变更是否完整满足产品方案、PRD 或任务规格。
```

## 7. 更新与回退

检查更新：

```bash
source ~/.zshrc
npx skills update --project
git diff -- .agents/skills
```

不要在检查差异前提交更新。发现上游 Skill 与项目规则冲突时，以 `AGENTS.md` 为准，可以保留当前版本或在项目副本中做最小适配。

移除单个 Skill：

```bash
source ~/.zshrc
npx skills remove --agent codex <skill-name>
```

## 8. 参考资料

- 官方仓库：<https://github.com/mattpocock/skills>
- 中文参考：<https://github.com/vinvcn/mattpocock-skills-zh-CN>
- Skills CLI：<https://github.com/vercel-labs/skills>

## 9. 当前集成状态

截至 2026-07-11：

- Node.js `v22.17.0`、npm `10.9.2` 已可用。
- 已通过 Skills CLI `1.5.16` 从 `mattpocock/skills` 安装首期 11 个 Skill。
- Skill 采用项目级复制模式保存在 `.agents/skills/`，没有符号链接。
- `skills-lock.json` 已记录每个 Skill 的官方来源、路径和内容哈希。
- `AGENTS.md`、`CONTEXT.md`、`docs/agents/` 和 `docs/adr/` 的项目级 setup 已完成。
- GitHub CLI `gh` 尚不可用，远程 Issue 创建、修改和关闭功能暂不执行；当前仍可完成需求澄清、规格草拟、任务拆分、实现、诊断和评审。待网络和 Homebrew 环境允许后执行 `brew install gh`、`gh auth login`，并以 `gh auth status` 通过作为远程写入前提。
