# Ollama 大语言模型

> 本地大语言模型运行和管理工具

## 📋 目录说明

| 脚本文件 | 说明 | 版本检测 | 帮助函数 |
|---------|------|---------|---------|
| `ollama_cli.sh` | Ollama CLI 工具 | ✅ | ❌ |
| `ollama.sh` | 自动检测系统并安装/启动 Ollama | ✅ | ✅ |
| `startup.sh` | 启动 Ollama 服务 | ❌ | ❌ |
| `stop.sh` | 停止 Ollama 服务 | ❌ | ❌ |
| `uninstall_ollama.sh` | 完整卸载脚本（含模型/配置） | ✅ | ✅ |
| `docker-compose.yml` | Docker 部署配置 | - | - |

## 🚀 快速开始

### 卸载 Ollama（含模型和配置）

```bash
# 交互式卸载（有确认提示）
bash uninstall_ollama.sh

# 强制卸载（无提示）
bash uninstall_ollama.sh --force

# 仅删除模型
bash uninstall_ollama.sh --models --force

# 预览将删除的内容
bash uninstall_ollama.sh --dry-run
```

### 使用 Docker 启动

```bash
cd ollama
docker-compose up -d
```

### 使用 CLI 工具

```bash
cd ollama
./ollama_cli.sh --help
```

## 🔧 详细说明

### macOS 版本兼容

`ollama.sh` 会在下载前检测 macOS 版本：

- macOS 12/13：自动使用 Ollama `v0.9.5`
- macOS 14 及以上：自动获取最新版本
- macOS 低于 12：提示升级系统或改用 Docker/Linux
- 可通过 `OLLAMA_VERSION=v0.9.5` 手动指定版本

安装包解压前还会校验其 `LSMinimumSystemVersion`，避免下载成功后才发现系统不兼容；安装完成后会清理本脚本生成的旧 Ollama ZIP，但不会删除模型和配置。

### 功能特性

**支持的模型**:
- Llama 系列
- Mistral
- Gemma
- 其他开源模型

**使用方式**:
```bash
# 启动 Ollama 服务
./startup.sh

# 停止服务
./stop.sh

# 运行模型
./ollama_cli.sh run llama2

# 查看可用模型
./ollama_cli.sh list
```

## 🔗 相关链接

- [Ollama 官方网站](https://ollama.com/)
- [Ollama GitHub](https://github.com/ollama/ollama)

## 📝 使用场景

- **本地开发**: 本地运行大语言模型
- **隐私保护**: 数据不离开本地环境
- **离线使用**: 无需网络连接
- **性能优化**: 利用 GPU 加速
