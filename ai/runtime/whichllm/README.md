# WhichLLM

一键安装配置 [whichllm](https://github.com/Andyyyy64/whichllm) — 自动检测 GPU/CPU/RAM，从 HuggingFace 排名推荐最适合本地运行的 LLM。

## 安装

```bash
# 通过 ai-hub.sh（推荐）
./ai-hub.sh  # 选择 WhichLLM 安装

# 或直接运行安装脚本
./whichllm.sh

# 支持的安装方式：
# 1) uv tool install (推荐 - 自动管理环境)
# 2) pip install
# 3) Homebrew (macOS)
# 4) uvx whichllm@latest (无需安装，直接运行)
```

## 常用命令

```bash
whichllm                      # 推荐本机最佳模型
whichllm --gpu "RTX 4090"     # 模拟 GPU 查看推荐
whichllm hardware             # 查看硬件信息
whichllm run "qwen 7b"       # 下载并对话
whichllm snippet "qwen 7b"   # 生成可运行代码
whichllm plan "llama 70b"    # 规划运行某模型所需硬件
whichllm upgrade             # 对比硬件升级方案
```

## AI Hub 配置

配置文件: `../../conf/tools/cli/whichllm.json`
