# vLLM 一键安装配置脚本

跨平台 (macOS / Linux) vLLM 安装脚本，自动检测 GPU、安装依赖、配置服务。

## ✨ 智能特性

- 🔍 **自动版本检测** - 发现新版本默认自动更新
- 🖥️ **智能硬件检测** - 自动识别 CPU、内存、GPU 配置
- 📊 **模型智能推荐** - 优先使用独立 `whichllm.sh`（如存在），否则使用脚本内置推荐逻辑
- ⚡ **最低要求检查** - 不满足配置明确提示
- 🚀 **一键安装部署** - 自动配置服务和管理脚本
- 🧭 **共享模型目录** - `install_vllm.sh` 与 `../common/whichllm.sh` 共用同一份 `models.catalog.tsv`
- 🧩 **多模型实例** - 通过多个 vLLM 进程和不同端口部署多个模型，便于前置网关统一路由

## 快速开始

### 默认安装
```bash
bash install_vllm.sh
```

### 先看推荐再安装（如已安装 whichllm）
```bash
bash ../common/whichllm.sh
bash ../common/whichllm.sh --scenario coding
bash ../common/whichllm.sh --scenario deepseek
```

### 自定义安装
```bash
# 指定版本、模型、端口
bash install_vllm.sh -v 0.6.0 -m meta-llama/Llama-3.1-8B-Instruct -o 8080

# Apple Silicon / Mac Studio 编码优先（默认使用 vllm-metal）
bash install_vllm.sh -m qwen3.6-27b -g 0.85 -l 32768

# 需要 MLX 多模态、Anthropic API 或 MCP 工具调用时显式使用 vllm-mlx
bash install_vllm.sh -e vllm-mlx -m qwen3.6-27b

# 查看内置模型别名
bash install_vllm.sh --list-models

# 使用别名部署 DeepSeek V4 Flash 进行实验
bash install_vllm.sh -m deepseek-v4-flash -l 16384

# 只下载模型
bash install_vllm.sh --download qwen2.5-coder-32b
```

### 卸载
```bash
bash install_vllm.sh --uninstall
bash install_vllm.sh --uninstall --uninstall-engine vllm-metal --yes
bash install_vllm.sh --uninstall -e vllm-mlx --yes
bash install_vllm.sh --uninstall --uninstall-engine all --yes
```

## 选项说明

| 选项 | 说明 | 默认值 |
|------|------|--------|
| `-v, --version` | vLLM 版本 | 最新 |
| `-p, --python` | Python 版本 | 系统默认 |
| `-i, --install-dir` | 安装目录 | `~/vllm` |
| `-m, --model` | 模型名称 | `qwen3.6-27b` |
| `-o, --port` | API 端口 | `8001` |
| `-g, --gpu-util` | GPU 内存利用率 (0.1-1.0) | `0.85` |
| `-l, --max-len` | 最大序列长度 | `32768` |
| `--list-models` | 查看内置模型目录 | - |
| `--download MODEL` | 只下载指定模型/别名 | - |
| `-u, --uninstall` | 交互选择并卸载 vLLM/vllm-mlx/vllm-metal | - |
| `--uninstall-engine ENGINE` | 非交互指定卸载目标：`vllm`/`vllm-mlx`/`vllm-metal`/`all` | - |
| `-n, --no-update` | 禁用自动更新 | 默认启用 |

## 支持平台

| 平台 | GPU | 说明 |
|------|-----|------|
| macOS Apple Silicon | Metal/MPS | Mac Studio/M1/M2/M3/M4 系列，默认优先 vllm-metal |
| Linux | CUDA | NVIDIA GPU |
| Linux | ROCm | AMD GPU |
| 通用 | CPU | 无 GPU 时降级 |

## 安装后目录

```
~/vllm/
├── venv/                  # Python 虚拟环境
├── models/                # 下载的模型
├── vllm_config.env        # 配置文件
├── start.sh               # 启动脚本
├── start_model.sh         # 启动指定模型/端口
├── start_multi.sh         # 按配置启动多个模型实例
├── models.catalog.tsv     # 内置模型别名目录
├── models.multi.example   # 多模型启动示例
├── stop.sh                # 停止脚本
└── test_api.sh            # API 测试脚本
```

## 常用命令

```bash
# 启动服务
~/vllm/start.sh

# 启动单个模型到指定端口
~/vllm/start_model.sh qwen3.6-27b 8000 auto 0.70

# 启动多个模型实例
~/vllm/start_multi.sh ~/vllm/models.multi.example

# 停止服务
~/vllm/stop.sh

# 测试 API
~/vllm/test_api.sh

# 修改配置
vim ~/vllm/vllm_config.env
~/vllm/stop.sh && ~/vllm/start.sh  # 重启生效
```

## API 调用示例

### OpenAI Python SDK
```python
from openai import OpenAI

client = OpenAI(
    base_url="http://localhost:8000/v1",
    api_key="none"  # 本地无需 key
)

response = client.chat.completions.create(
    model="Qwen/Qwen3.6-27B",
    messages=[{"role": "user", "content": "你好"}]
)
print(response.choices[0].message.content)
```

### curl
```bash
# 聊天补全
curl http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "Qwen/Qwen3.6-27B",
    "messages": [{"role": "user", "content": "你好"}],
    "max_tokens": 100
  }'

# 流式输出
curl http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "Qwen/Qwen3.6-27B",
    "messages": [{"role": "user", "content": "你好"}],
    "stream": true
  }'
```

## 模型下载

如果 `../common/whichllm.sh` 存在，可先用它查看硬件推荐；否则 `install_vllm.sh` 会使用内置推荐逻辑。

```bash
bash ../common/whichllm.sh
bash ../common/whichllm.sh --format shell
```

### 内置别名
```bash
bash install_vllm.sh --list-models
column -t -s $'\t' ~/vllm/models.catalog.tsv
```

DeepSeek 相关建议：

- 编码优先：`qwen3.6-27b` -> `qwen3.6-35b-a3b` -> `qwen3-coder-30b-a3b`。
- PRD/方案/画图文本：`qwen3-30b-a3b` -> `glm-4.6` -> `gemma3-27b`。
- `deepseek-v4-flash`：可在 M4 Max 128GB 上尝试，但建议先用 `-l 16384` 或 `32768` 验证，不要直接拉满 1M 上下文。
- `deepseek-r1-distill-qwen-32b`：更现实的本机 DeepSeek 推理替代。
- `deepseek-v4-pro`、`deepseek-v3.1`、`deepseek-r1` 完整权重：更适合多 GPU 服务器，不建议 128GB 本机常驻。
- DS4 路径使用专用 GGUF/量化模型；vLLM 路径使用 HuggingFace Transformers 模型，两者不要混用模型文件。

### 从 HuggingFace
```bash
pip install huggingface_hub
huggingface-cli download Qwen/Qwen3.6-27B \
  --local-dir ~/vllm/models/Qwen_Qwen3.6-27B
```

### 使用国内镜像
```bash
export HF_ENDPOINT=https://hf-mirror.com
huggingface-cli download Qwen/Qwen3.6-27B \
  --local-dir ~/vllm/models/Qwen_Qwen3.6-27B
```

## 故障排除

### macOS MPS 内存限制
Apple Silicon 上默认优先 `vllm-metal`。大内存 Mac Studio 可用 `0.85-0.90`，小内存机器建议设置 `VLLM_GPU_MEMORY_UTILIZATION=0.7` 避免 OOM。

### CUDA out of memory
降低 `VLLM_GPU_MEMORY_UTILIZATION` 或 `VLLM_MAX_MODEL_LEN`。

### 下载模型失败
使用国内镜像站:
```bash
export HF_ENDPOINT=https://hf-mirror.com
```

### 端口被占用
修改 `VLLM_PORT` 或停止占用服务:
```bash
lsof -i :8000  # macOS/Linux
```

## 性能优化建议

1. **多 GPU**: 设置 `VLLM_TENSOR_PARALLEL_SIZE=<GPU数量>`
2. **大内存 GPU**: 可提高 `VLLM_GPU_MEMORY_UTILIZATION` 到 0.95
3. **长上下文**: 增大 `VLLM_MAX_MODEL_LEN` (需足够显存)
4. **高并发**: 增大 `VLLM_MAX_NUM_SEQS` 和 `VLLM_MAX_NUM_BATCHED_TOKENS`

## 参考

- [vLLM 官方文档](https://docs.vllm.ai/)
- [vLLM GitHub](https://github.com/vllm-project/vllm)
