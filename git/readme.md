# Git 版本控制

> Git 版本控制工具的安装、配置和管理脚本

## 📋 目录说明

| 脚本文件 | 说明 | 版本检测 | 帮助函数 |
|---------|------|---------|---------|
| `setup_git.sh` | Git 安装脚本 | ❌ | ❌ |
| `uninstall_git.sh` | Git 卸载脚本 | ❌ | ❌ |
| `git-diff.sh` | Git 差异对比与分支合并工具 | ❌ | ✅ |
| `export_git_files.sh` | Git 文件导出工具 | ❌ | ❌ |
| `giter.sh` | Git 自动同步提交推送工具 | ❌ | ✅ |
| `git-beyond4.bat` | Git 批处理脚本 | ❌ | ❌ |

## 🚀 快速开始

### 安装 Git

```bash
cd git
./setup_git.sh
```

### 卸载 Git

```bash
cd git
./uninstall_git.sh
```

## 🔧 详细说明

### 核心脚本

#### setup_git.sh - Git 安装脚本

**功能**: 安装 Git 版本控制系统

**安装内容**:
- Git 核心程序
- Git 配置文件
- Git 常用工具
- Git 别名配置

#### git-diff.sh - 差异对比与分支合并工具

**功能**: Git 差异对比工具（整合版），支持四种模式

**模式**:
- Git 分支/提交差异对比（文本或图形化）
- 两个目录的差异对比（文本或图形化）
- 两个文件的差异对比（文本或图形化）
- 分支交互对比与合并（`-b` 模式）

**特点**:
- 彩色输出（自动检测 TTY）
- 文本/GUI 双输出模式（Beyond Compare）
- 智能排除（.gitignore 集成、默认排除构建产物）
- 分支交互对比：逐文件 difftool 对比、修改后自动同步提交
- 合并工作量评估：冲突检测、双向方案对比、评分建议
- 交互式合并执行：冲突处理、mergetool 集成

**示例**:
```bash
# 通用模式
git-diff.sh -t -l main -r develop          # Git 分支对比
git-diff.sh -t -l ./old -r ./new           # 目录对比
git-diff.sh -u -l old.txt -r new.txt       # 文件对比 - 图形化

# 分支交互模式
git-diff.sh -b                             # 当前分支 vs origin/当前分支
git-diff.sh -b -r develop                  # 当前分支 vs origin/develop
git-diff.sh -b -c feature-a --lb develop   # feature-a vs 本地 develop
git-diff.sh -b -m                          # 合并工作量评估
```

#### export_git_files.sh - 文件导出工具

**功能**: 导出 Git 仓库中的文件

**用途**:
- 提取特定版本文件
- 批量文件导出
- 版本文件对比
- 备份恢复

#### giter.sh - Git 自动同步提交推送工具

**功能**: 自动发现 Git 仓库，执行远端同步、提交本地安全变更并推送。

**仓库发现规则**:
- 无参数运行时，工作根目录为脚本所在目录，例如 `/Users/sky/work/shell/git`。
- 脚本目录、执行目录、`-d` 指定目录都可以是 Git 仓库的子目录，脚本会先解析到对应仓库根目录，例如 `/Users/sky/work/shell/git` 会解析为 `/Users/sky/work/shell`。
- 脚本会同时显示脚本目录、执行目录和工作根目录，便于确认当前处理范围。
- 如果从另一个 Git 仓库中调用脚本，例如在 `wakeword` 仓库执行 `~/work/shell/git/giter.sh`，脚本会识别：
  - 执行目录仓库：`wakeword`
  - 脚本所属仓库：`shell`
- 交互终端会提示选择处理哪个仓库，或选择全部按顺序执行。
- 使用 `-d, --dir PATH` 时，交互终端会把指定目录所属 Git 仓库作为第一个候选仓库；如果同时存在执行目录仓库、脚本所属仓库，会排在指定目录候选之后。
- 如果一个项目目录下嵌套了多个独立 Git 仓库，例如后端根目录下包含前端仓库和 Python 仓库，仓库级配置 `GITER_PUSH_DIRS` 中声明的内部子仓库会作为独立候选仓库处理。
- 第三方开源项目、分析借鉴用仓库建议写入 `GITER_EXCLUDE_DIRS`，父仓库提交时会自动跳过这些目录，并且不会作为默认提交推送候选。
- 需要临时扫描未声明的嵌套 Git 仓库时，可以使用 `--all-nested`；`GITER_EXCLUDE_DIRS` 中声明的目录仍会被排除。
- 父仓库提交时会自动跳过所有嵌套 Git 仓库目录，避免把子仓库内容误提交到父仓库。
- 为防止在父仓库手动执行 `git add .` 误加入子仓库，脚本默认会把所有嵌套 Git 仓库目录写入父仓库 `.gitignore`；如需关闭可设置 `GITER_AUTO_UPDATE_GITIGNORE=0`。
- 如果子仓库目录已经被父仓库跟踪，脚本会自动执行 `git rm -r --cached <子仓库目录>` 将其移出父仓库索引并保留工作区文件，同时确认 `.gitignore` 已维护。
- `--dry-run` 可预演将处理的仓库、`.gitignore` 写入、`git rm --cached`、暂存、同步、提交和推送计划，不实际修改。
- `--show-config` 可输出仓库配置文件路径、推送目录、排除目录、嵌套 Git 仓库和候选仓库，用于排查配置。
- 脚本真实执行时会给每个仓库加锁，避免多个终端同时处理同一仓库。
- 未指定分支参数时，交互终端会显示本地分支列表并默认选择当前分支；非交互终端默认使用当前分支。
- 使用 `-b, --branch NAME` 可指定要处理的本地分支。若指定分支不是当前分支，脚本会先切换过去执行同步、提交和推送；交互终端结束后会询问是否切回原分支，非交互终端可用 `GITER_RETURN_ORIGINAL_BRANCH=1` 自动切回。
- 执行结束会输出摘要，列出每个仓库的完成、跳过、失败或预演状态。
- 非交互终端会保持脚本化行为，只处理指定目录或自动发现结果，不弹出选择菜单。

**示例**:

```bash
~/work/shell/git/giter.sh
~/work/shell/git/giter.sh -d /path/to/repo
~/work/shell/git/giter.sh -b develop "更新 develop"
~/work/shell/git/giter.sh "提交说明" -- path/to/file.sh
```

## 🔗 相关链接

- [Git 官方网站](https://git-scm.com/)
- [GitHub](https://github.com/)
- [GitLab](https://about.gitlab.com/)

## 📝 使用场景

- **版本控制**: 代码版本管理和协作
- **代码审查**: 代码差异对比和审查
- **文件导出**: 提取特定版本文件
- **分支管理**: 分支对比、合并工作量评估与执行
