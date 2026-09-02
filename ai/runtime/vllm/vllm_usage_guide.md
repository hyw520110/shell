# vLLM 使用指南

## 📋 目录

1. [安装后快速上手](#安装后快速上手)
2. [启动和停止服务](#启动和停止服务)
3. [API 调用方式](#api-调用方式)
4. [常用配置修改](#常用配置修改)
5. [模型管理](#模型管理)
6. [性能优化](#性能优化)
7. [故障排查](#故障排查)
8. [生产环境部署](#生产环境部署)

---

## 安装后快速上手

运行安装脚本后，会看到以下提示：

```
========================================
  vLLM 一键安装配置脚本
========================================

[OK] vLLM 安装完成!

[INFO] 安装目录: ~/vllm
[INFO] 虚拟环境: ~/vllm/venv
[INFO] 模型目录: ~/vllm/models
[INFO] 配置文件: ~/vllm/vllm_config.env
[INFO] GPU 类型: mps (macOS Apple Silicon) / cuda (NVIDIA) / cpu

[INFO] 管理命令:
  启动服务: ~/vllm/start.sh
  停止服务: ~/vllm/stop.sh
  测试 API:  ~/vllm/test_api.sh

[INFO] API 地址: http://localhost:8000
[INFO] API 文档:   http://localhost:8000/docs

[INFO] 使用 OpenAI SDK 调用示例:
  from openai import OpenAI
  client = OpenAI(base_url="http://localhost:8000/v1", api_key="none")
  response = client.chat.completions.create(
      model="Qwen/Qwen2.5-7B-Instruct",
      messages=[{"role": "user", "content": "你好"}]
  )
  print(response.choices[0].message.content)

[WARN] 提示:
  - 修改配置: 编辑 ~/vllm/vllm_config.env 后重启服务
  - 下载模型: huggingface-cli download <model> --local-dir ~/vllm/models/<name>
  - 查看日志: tail -f ~/vllm/vllm*.log (macOS) 或 journalctl -u vllm (Linux)
```

---

## 启动和停止服务

### 方式一：使用管理脚本（推荐）

```bash
# 启动服务
~/vllm/start.sh

# 停止服务
~/vllm/stop.sh

# 测试 API 是否正常
~/vllm/test_api.sh
```

### 方式二：系统服务（如果配置了自动启动）

**Linux (systemd):**
```bash
# 启动
sudo systemctl start vllm

# 停止
sudo systemctl stop vllm

# 重启
sudo systemctl restart vllm

# 查看状态
sudo systemctl status vllm

# 查看日志
journalctl -u vllm -f
```

**macOS (LaunchAgent):**
```bash
# 启动
launchctl start vllm

# 停止
launchctl stop vllm

# 查看日志
tail -f ~/vllm/vllm.log
```

### 方式三：手动启动（调试用）

```bash
# 激活虚拟环境
source ~/vllm/venv/bin/activate

# 启动服务
python -m vllm.entrypoints.openai.api_server \
  --model Qwen/Qwen2.5-7B-Instruct \
  --host 0.0.0.0 \
  --port 8000
```

---

## API 调用方式

vLLM 提供 **完全兼容 OpenAI API** 的接口。

### 1. curl 命令行

```bash
# 查看可用模型
curl http://localhost:8000/v1/models

# 聊天补全（非流式）
curl http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "Qwen/Qwen2.5-7B-Instruct",
    "messages": [
      {"role": "user", "content": "你好，请介绍一下你自己"}
    ],
    "max_tokens": 500,
    "temperature": 0.7
  }'

# 聊天补全（流式输出）
curl http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "Qwen/Qwen2.5-7B-Instruct",
    "messages": [
      {"role": "user", "content": "讲个故事"}
    ],
    "stream": true,
    "max_tokens": 500
  }'

# 文本生成（Completions 接口）
curl http://localhost:8000/v1/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "Qwen/Qwen2.5-7B-Instruct",
    "prompt": "从前有座山，",
    "max_tokens": 200,
    "temperature": 0.8
  }'
```

### 2. Python - OpenAI SDK

```python
from openai import OpenAI

# 初始化客户端
client = OpenAI(
    base_url="http://localhost:8000/v1",
    api_key="none"  # 本地无需 API key
)

# 聊天补全
response = client.chat.completions.create(
    model="Qwen/Qwen2.5-7B-Instruct",
    messages=[
        {"role": "system", "content": "你是一个有用的助手"},
        {"role": "user", "content": "Python 和 JavaScript 哪个更适合初学者？"}
    ],
    max_tokens=500,
    temperature=0.7
)

print(response.choices[0].message.content)
```

### 3. Python - 流式输出

```python
from openai import OpenAI

client = OpenAI(base_url="http://localhost:8000/v1", api_key="none")

stream = client.chat.completions.create(
    model="Qwen/Qwen2.5-7B-Instruct",
    messages=[{"role": "user", "content": "写一首诗"}],
    stream=True
)

for chunk in stream:
    if chunk.choices[0].delta.content is not None:
        print(chunk.choices[0].delta.content, end="", flush=True)
```

### 4. LangChain 集成

```python
from langchain_openai import ChatOpenAI
from langchain_core.messages import HumanMessage

# 初始化
llm = ChatOpenAI(
    model="Qwen/Qwen2.5-7B-Instruct",
    openai_api_base="http://localhost:8000/v1",
    openai_api_key="none",
    temperature=0.7
)

# 调用
response = llm.invoke([HumanMessage(content="解释一下量子计算")])
print(response.content)
```

### 5. 其他语言

**JavaScript (Node.js):**
```javascript
import OpenAI from 'openai';

const openai = new OpenAI({
  baseURL: 'http://localhost:8000/v1',
  apiKey: 'none'
});

const response = await openai.chat.completions.create({
  model: 'Qwen/Qwen2.5-7B-Instruct',
  messages: [{ role: 'user', content: '你好' }]
});

console.log(response.choices[0].message.content);
```

**Go:**
```go
import openai "github.com/sashabaranov/go-openai"

client := openai.NewClientWithConfig(openai.ClientConfig{
    APIKey: "none",
    BaseURL: "http://localhost:8000/v1",
})

resp, err := client.CreateChatCompletion(
    context.Background(),
    openai.ChatCompletionRequest{
        Model: "Qwen/Qwen2.5-7B-Instruct",
        Messages: []openai.ChatCompletionMessage{
            {Role: openai.ChatMessageRoleUser, Content: "你好"},
        },
    },
)
```

---

## 常用配置修改

编辑配置文件 `~/vllm/vllm_config.env`：

```bash
vim ~/vllm/vllm_config.env
```

### 关键参数说明

```bash
# 模型路径或 HuggingFace 模型名
VLLM_MODEL="Qwen/Qwen2.5-7B-Instruct"

# API 配置
VLLM_HOST=0.0.0.0          # 监听地址
VLLM_PORT=8000             # 监听端口

# 性能配置（最重要）
VLLM_GPU_MEMORY_UTILIZATION=0.90   # GPU 内存利用率 (0.1-1.0)
VLLM_MAX_MODEL_LEN=4096            # 最大序列长度
VLLM_TENSOR_PARALLEL_SIZE=1        # 多 GPU 并行数

# 并发配置
VLLM_MAX_NUM_SEQS=256              # 最大并发请求数
VLLM_MAX_NUM_BATCHED_TOKENS=4096   # 最大批处理 token 数
```

### 修改配置后重启

```bash
# 使用管理脚本重启
~/vllm/stop.sh && ~/vllm/start.sh

# 或使用系统服务
sudo systemctl restart vllm  # Linux
launchctl stop vllm && launchctl start vllm  # macOS
```

---

## 模型管理

### 下载模型

```bash
# 方法一：使用 huggingface-cli（推荐）
source ~/vllm/venv/bin/activate
pip install huggingface_hub

# 从 HuggingFace 下载
huggingface-cli download Qwen/Qwen2.5-7B-Instruct \
  --local-dir ~/vllm/models/Qwen_Qwen2.5-7B-Instruct

# 使用国内镜像站
export HF_ENDPOINT=https://hf-mirror.com
huggingface-cli download Qwen/Qwen2.5-7B-Instruct \
  --local-dir ~/vllm/models/Qwen_Qwen2.5-7B-Instruct
```

### 使用本地模型

修改配置文件：
```bash
VLLM_MODEL="/Users/mac/vllm/models/Qwen_Qwen2.5-7B-Instruct"
```

### 热门模型推荐

```bash
# 对话模型
Qwen/Qwen2.5-7B-Instruct      # 通义千问（中文优秀）
Qwen/Qwen2.5-14B-Instruct     # 通义千问 14B
meta-llama/Llama-3.1-8B-Instruct
meta-llama/Llama-3.1-70B-Instruct

# 代码模型
Qwen/Qwen2.5-Coder-7B
deepseek-ai/deepseek-coder-6.7b-instruct

# 多模态模型
Qwen/Qwen2-VL-7B-Instruct
```

---

## 性能优化

### Apple Silicon (M1/M2/M3)

```bash
# 降低内存利用率避免 OOM
VLLM_GPU_MEMORY_UTILIZATION=0.70
VLLM_MAX_MODEL_LEN=4096
```

### NVIDIA GPU

```bash
# 8GB 显存
VLLM_GPU_MEMORY_UTILIZATION=0.85
VLLM_MAX_MODEL_LEN=2048

# 16GB 显存
VLLM_GPU_MEMORY_UTILIZATION=0.90
VLLM_MAX_MODEL_LEN=4096

# 24GB 显存 (RTX 3090/4090)
VLLM_GPU_MEMORY_UTILIZATION=0.95
VLLM_MAX_MODEL_LEN=8192
```

### 多 GPU 并行

```bash
# 使用 2 张 GPU
VLLM_TENSOR_PARALLEL_SIZE=2

# 使用 4 张 GPU
VLLM_TENSOR_PARALLEL_SIZE=4
```

### 高并发场景

```bash
# 提高并发数
VLLM_MAX_NUM_SEQS=512
VLLM_MAX_NUM_BATCHED_TOKENS=8192
```

---

## 故障排查

### 1. 端口被占用

```bash
# 查看占用端口的进程
lsof -i :8000  # macOS/Linux
sudo lsof -i :8000

# 修改端口
vim ~/vllm/vllm_config.env
# 修改 VLLM_PORT=8001
```

### 2. 内存不足 (OOM)

```bash
# 降低 GPU 内存利用率
VLLM_GPU_MEMORY_UTILIZATION=0.70

# 减小序列长度
VLLM_MAX_MODEL_LEN=2048
```

### 3. 模型加载失败

```bash
# 检查模型文件是否存在
ls -lh ~/vllm/models/

# 查看错误日志
tail -f ~/vllm/vllm.log  # macOS
journalctl -u vllm -f    # Linux
```

### 4. CUDA 相关错误

```bash
# 检查 CUDA 是否可用
source ~/vllm/venv/bin/activate
python -c "import torch; print(f'CUDA: {torch.cuda.is_available()}')"
python -c "import torch; print(f'GPU: {torch.cuda.get_device_name(0)}')"

# 查看 GPU 状态
nvidia-smi
```

### 5. 服务启动失败

```bash
# 手动启动查看详细错误
source ~/vllm/venv/bin/activate
python -m vllm.entrypoints.openai.api_server \
  --model Qwen/Qwen2.5-7B-Instruct \
  --port 8000 \
  --log-level debug
```

---

## 生产环境部署

### Nginx 反向代理

```nginx
server {
    listen 80;
    server_name your-domain.com;

    location / {
        proxy_pass http://localhost:8000;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        
        # 流式输出需要禁用缓冲
        proxy_buffering off;
        proxy_cache off;
        
        # 增加超时时间
        proxy_read_timeout 300s;
        proxy_connect_timeout 120s;
    }
}
```

### Docker 部署

```bash
docker run -d \
  --name vllm \
  --gpus all \
  -p 8000:8000 \
  -v ~/vllm/models:/models \
  vllm/vllm-openai \
  --model /models/Qwen_Qwen2.5-7B-Instruct \
  --host 0.0.0.0 \
  --port 8000 \
  --gpu-memory-utilization 0.90
```

### 监控和指标

```bash
# vLLM 提供 Prometheus 指标
curl http://localhost:8000/metrics

# 常用指标
# - vllm:num_requests_running  - 当前运行请求数
# - vllm:num_requests_waiting  - 等待请求数
# - vllm:gpu_cache_usage_perc  - GPU 缓存使用率
```

---

## 快速参考卡

```bash
# ==================== 常用命令 ====================

# 启动/停止
~/vllm/start.sh              # 启动服务
~/vllm/stop.sh               # 停止服务
~/vllm/test_api.sh           # 测试 API

# 查看状态
lsof -i :8000                # 查看端口占用
tail -f ~/vllm/vllm.log     # 查看日志

# 修改配置
vim ~/vllm/vllm_config.env   # 编辑配置
~/vllm/stop.sh && ~/vllm/start.sh  # 重启生效

# 下载模型
export HF_ENDPOINT=https://hf-mirror.com
huggingface-cli download Qwen/Qwen2.5-7B-Instruct \
  --local-dir ~/vllm/models/Qwen_Qwen2.5-7B-Instruct

# ==================== API 调用示例 ====================

# curl 测试
curl http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"Qwen/Qwen2.5-7B-Instruct","messages":[{"role":"user","content":"你好"}]}'

# Python 调用
python -c "
from openai import OpenAI
client = OpenAI(base_url='http://localhost:8000/v1', api_key='none')
print(client.chat.completions.create(
    model='Qwen/Qwen2.5-7B-Instruct',
    messages=[{'role':'user','content':'你好'}]
).choices[0].message.content)
"
```

---

## 参考链接

- [vLLM 官方文档](https://docs.vllm.ai/)
- [vLLM GitHub](https://github.com/vllm-project/vllm)
- [OpenAI API 文档](https://platform.openai.com/docs/api-reference)
