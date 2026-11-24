# 开发环境

开发环境所需软件清单及安装时间估算。

## 当前已有软件

| 类别 | 软件 | 数量 | 状态 |
|------|------|------|------|
| IDE | VS Code、IntelliJ IDEA、Eclipse、Cursor、HBuilderX、Watt Toolkit | 6个 | ✅ 已配置 |
| AI IDE | Trae、Windsurf、Aider-Desk、Pear AI、Codex-IDE、Zed | 6个 | ✅ 已配置 |
| JDK | 安装脚本 (支持多版本) | 1套 | ✅ 已配置 |
| 构建工具 | Maven、Gradle、mvnd | 3个 | ✅ 已配置 |
| 诊断工具 | Arthas | 1个 | ✅ 已配置 |
| 版本控制 | Git 管理脚本 | 1套 | ✅ 已配置 |

## 推荐补充软件

| 软件 | 用途 | 优先级 | 安装时间 | 下载来源 |
|------|------|--------|----------|----------|
| **IDE** |
| PyCharm | Python 专业开发 | 中 | 10分钟 | JetBrains 官网 |
| WebStorm | 前端专业开发 | 中 | 10分钟 | JetBrains 官网 |
| GoLand | Go 专业开发 | 低 | 10分钟 | JetBrains 官网 |
| DataGrip | 数据库 IDE | 中 | 10分钟 | JetBrains 官网 |
| **开发工具** |
| Postman | API 测试 | 高 | 5分钟 | 官网下载 |
| Insomnia | API 测试 (开源) | 高 | 5分钟 | 官网下载 |
| JetBrains Toolbox | IDE 统一管理 | 低 | 5分钟 | JetBrains 官网 |
| SDKMAN | JDK 版本管理 | 中 | 5分钟 | 命令行安装 |
| jEnv | Java 版本切换 | 低 | 5分钟 | GitHub |

## 安装时间汇总

| 优先级 | 软件数量 | 预估时间 |
|--------|----------|----------|
| 高优先级 | 2个 | 10分钟 |
| 中优先级 | 4个 | 35分钟 |
| 低优先级 | 3个 | 20分钟 |
| **总计** | **9个** | **约 65分钟** |

## 快速安装命令

```bash
# IDE 安装
./ide/install-pycharm.sh      # 如需添加
./ide/install-webstorm.sh     # 如需添加
./ide/install-datagrip.sh     # 如需添加

# 开发工具
./devtools/install-postman.sh # 如需添加
./devtools/install-sdkman.sh  # 如需添加
```

## 环境变量配置

```bash
# ~/.zshrc 或 ~/.bashrc
export JAVA_HOME=$(/usr/libexec/java_home -v 21)
export MAVEN_HOME=/usr/local/maven
export GRADLE_HOME=/usr/local/gradle
export PATH=$PATH:$MAVEN_HOME/bin:$GRADLE_HOME/bin
```
