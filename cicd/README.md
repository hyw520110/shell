# CI/CD 持续集成部署

> 持续集成和持续部署工具的安装配置脚本

## 📋 目录说明

| 目录 | 说明 | 功能 |
|------|------|------|
| `jenkins/` | Jenkins | 持续集成服务器 |
| `spug/` | Spug | 轻量级自动化运维平台 |
| `promptfoo/` | Promptfoo | LLM 评测、红队和代码扫描 |

## 🚀 快速开始

### Jenkins

```bash
cd cicd/jenkins
./install_jenkins.sh
./startup.sh
```

### Spug

```bash
cd cicd/spug
./install_spug.sh
```

### Promptfoo

```bash
cd cicd/promptfoo
./promptfoo.sh install
./promptfoo.sh init .
./promptfoo.sh eval
```

## 🔧 详细说明

### 1. Jenkins - 持续集成服务器

**功能**: 自动化构建、测试和部署

**特点**:
- 丰富的插件生态
- 灵活的流水线配置
- 分布式构建支持
- 多版本控制集成

**适用场景**:
- 自动化构建
- 代码质量检查
- 自动化测试
- 自动化部署

### 2. Spug - 轻量级自动化运维平台

**功能**: 一站式运维管理平台

**特点**:
- 轻量级部署
- 可视化操作
- 权限管理
- 审计日志

**适用场景**:
- 应用部署
- 配置管理
- 监控告警
- 日志管理

### 3. Promptfoo - LLM 评测和红队

**功能**: 对 Prompt、模型输出和 LLM 应用进行回归评测、红队测试和代码扫描

**特点**:
- 支持 CI/CD 中运行 LLM eval
- 支持多模型、多 provider 对比
- 支持 redteam 和 code scan
- 适合项目级质量门禁，不作为 AI 客户端入口

**适用场景**:
- Prompt 回归测试
- LLM 应用质量门禁
- 模型输出对比
- AI 安全红队测试

## 🔗 相关链接

- [Jenkins 官方网站](https://www.jenkins.io/)
- [Spug 官方网站](https://spug.cc/)
- [Promptfoo 官方文档](https://www.promptfoo.dev/docs/)

## 📝 使用场景

- **持续集成**: Jenkins - 自动化代码构建和测试
- **自动化部署**: Spug - 可视化应用部署
- **LLM 评测**: Promptfoo - Prompt/模型输出回归测试和红队
- **DevOps**: 完整的 DevOps 工作流
- **团队协作**: 统一的 CI/CD 平台
