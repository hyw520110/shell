# SonarQube 代码质量分析

> 持续代码质量检查平台

## 📋 目录说明

| 目录 | 说明 |
|------|------|
| `bin/` | 安装、启动、停止脚本目录 |
| `conf/` | 配置文件目录 |
| `data/` | 数据存储目录 |
| `docker-compose.yml` | Docker 部署配置 |
| `bin/install-sonarqube.sh` | SonarQube 安装脚本 |
| `bin/setup-sonarlint-ide.sh` | SonarLint IDE 联动配置脚本 |

## 🚀 快速开始

### 使用 Docker 部署

```bash
cd sonarqube
docker-compose up -d
```

### 使用安装脚本

```bash
cd sonarqube
./bin/install-sonarqube.sh
```

### 安装中文汉化插件

安装脚本会默认集成 `sonar-l10n-zh` 中文汉化插件。已有 SonarQube 实例可单独执行：

```bash
cd sonarqube
./bin/install-sonarqube.sh --install-zh
```

### 配置 IDE 联动

脚本会自动发现 VS Code、Cursor、Windsurf、Trae 等 VS Code 兼容 IDE，安装 SonarLint 扩展并写入 SonarQube Connected Mode 配置：

```bash
cd sonarqube
./bin/setup-sonarlint-ide.sh --url http://studio:9000
```

如需直接写入认证 token：

```bash
SONARQUBE_TOKEN=sqp_xxx ./bin/setup-sonarlint-ide.sh --url http://studio:9000
```

## 🔧 详细说明

### 功能特性

**代码分析**:
- 代码复杂度分析
- 代码重复检测
- 代码覆盖率
- 技术债务评估

**质量规则**:
- 代码规范检查
- 安全漏洞扫描
- Bug 检测
- 代码异味识别

**支持语言**:
- Java
- Python
- JavaScript
- C/C++
- 等多种语言

### 访问界面

- **SonarQube 控制台**: http://localhost:9000
- **默认用户**: admin
- **默认密码**: admin

## 🔗 相关链接

- [SonarQube 官方网站](https://www.sonarqube.org/)
- [SonarQube 文档](https://docs.sonarqube.org/)

## 📝 使用场景

- **代码审查**: 自动化代码质量检查
- **持续集成**: 集成到 CI/CD 流程
- **技术债务**: 评估和管理技术债务
- **团队协作**: 统一的代码质量标准
