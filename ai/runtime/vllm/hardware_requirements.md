# vLLM 硬件要求和模型推荐

## 最低硬件要求

| 组件 | 最低要求 | 推荐配置 |
|------|---------|---------|
| **内存** | 4 GB | 16 GB 以上 |
| **CPU** | 支持 AVX2 指令集 | 8 核心以上 |
| **GPU** | 可选（CPU 模式支持） | NVIDIA GPU 8GB+ 显存 |
| **存储** | 10 GB 可用空间 | 50 GB SSD |

## 不同硬件配置推荐模型

### CPU 模式（无 GPU）

| 模型 | 参数量 | 内存需求 | 推理速度 |
|------|--------|---------|---------|
| Qwen/Qwen2.5-0.5B-Instruct | 0.5B | ~1 GB | 快 |
| Qwen/Qwen2.5-1.5B-Instruct | 1.5B | ~3 GB | 中 |
| meta-llama/Llama-3.2-1B-Instruct | 1B | ~2 GB | 快 |

**提示**: CPU 模式推理速度较慢，建议仅用于测试或轻量使用。

### 小显存 GPU（≤6GB）

| GPU 示例 | 推荐模型 | 参数量 | 显存需求 |
|---------|---------|--------|---------|
| GTX 1650, MX550 | Qwen/Qwen2.5-1.5B-Instruct | 1.5B | ~3 GB |
| GTX 1660, RTX 3050 | Qwen/Qwen2.5-3B-Instruct | 3B | ~6 GB |
|  | meta-llama/Llama-3.2-3B-Instruct | 3B | ~6 GB |

### 中等显存 GPU（8-12GB）

| GPU 示例 | 推荐模型 | 参数量 | 显存需求 |
|---------|---------|--------|---------|
| RTX 3060, RTX 4060 | Qwen/Qwen2.5-7B-Instruct | 7B | ~14 GB |
| RTX 3070, RTX 4070 | meta-llama/Llama-3.1-8B-Instruct | 8B | ~16 GB |
|  | google/gemma-2-9b-it | 9B | ~18 GB |

**提示**: 可降低 `--max-model-len` 或 `--gpu-memory-utilization` 运行更大模型。

### 大显存 GPU（16-24GB）

| GPU 示例 | 推荐模型 | 参数量 | 显存需求 |
|---------|---------|--------|---------|
| RTX 3080 12GB, RTX 4070 Ti | Qwen/Qwen2.5-7B-Instruct | 7B | ~14 GB |
| RTX 3090, RTX 4090 | Qwen/Qwen2.5-14B-Instruct | 14B | ~28 GB (需量化) |
|  | meta-llama/Llama-3.1-8B-Instruct | 8B | ~16 GB |

**提示**: 可使用 GPTQ/AWQ 量化版运行 14B-32B 模型。

### 超大显存 GPU（≥40GB）

| GPU 示例 | 推荐模型 | 参数量 | 显存需求 |
|---------|---------|--------|---------|
| A100 40GB, A6000 | Qwen/Qwen2.5-14B-Instruct | 14B | ~28 GB |
| A100 80GB, H100 | Qwen/Qwen2.5-32B-Instruct | 32B | ~64 GB |
| 多卡 A100 | meta-llama/Llama-3.1-70B-Instruct | 70B | ~140 GB (需多卡) |

### Apple Silicon

| 芯片 | 统一内存 | 推荐模型 |
|------|---------|---------|
| M1/M2 | 8GB | Qwen/Qwen2.5-3B-Instruct |
| M1/M2 | 16GB+ | Qwen/Qwen2.5-7B-Instruct |
| M3/M4 | 16GB+ | Qwen/Qwen2.5-7B-Instruct |
| M3/M4 | 32GB+ | Qwen/Qwen2.5-14B-Instruct |

**提示**: Apple Silicon 使用统一内存。Mac Studio / M4 Max 等大内存机器默认优先 `vllm-metal`；小内存机器建议设置 `--gpu-memory-utilization=0.7` 避免 OOM。

## 模型显存计算公式

```
FP16 模型显存 ≈ 参数量 × 2 字节
INT8 量化显存 ≈ 参数量 × 1 字节
INT4 量化显存 ≈ 参数量 × 0.5 字节

示例（7B 模型）:
  FP16: 7B × 2 = 14 GB
  INT8: 7B × 1 = 7 GB
  INT4: 7B × 0.5 = 3.5 GB
```

## 优化建议

### 1. 显存不足时

```bash
# 降低 GPU 内存利用率
--gpu-memory-utilization 0.7

# 减小序列长度
--max-model-len 2048

# 使用量化模型
# 下载 GPTQ/AWQ 量化版
huggingface-cli download TheBloke/Qwen2.5-7B-Instruct-GPTQ-Int4
```

### 2. 多 GPU 并行

```bash
# 使用 2 张 GPU
--tensor-parallel-size 2

# 使用 4 张 GPU
--tensor-parallel-size 4
```

### 3. CPU 模式优化

```bash
# 使用更多 CPU 线程
--num-cpu-cores 8

# 减少并发
--max-num-seqs 10
```

## 常见硬件问题

### Q1: 提示 "CUDA out of memory"
**解决方案**:
- 降低 `--gpu-memory-utilization` 到 0.7-0.8
- 减小 `--max-model-len` 到 2048
- 使用量化模型（GPTQ/AWQ）

### Q2: CPU 模式太慢
**解决方案**:
- 使用更小的模型（≤3B）
- 减少 `--max-num-seqs` 到 10
- 考虑购买 GPU 或使用云服务

### Q3: Apple Silicon OOM
**解决方案**:
- 小内存机器设置 `--gpu-memory-utilization 0.7`
- Mac Studio 128GB 可从 `0.85` 逐步调到 `0.90`
- 关闭其他占用内存的应用
- 使用 7B 以下模型

## 性能参考

| 硬件 | 模型 | Token/s |
|------|------|---------|
| RTX 4090 | 7B | ~150 |
| RTX 3060 | 7B | ~50 |
| M2 Max | 7B | ~30 |
| CPU (i7) | 1.5B | ~5 |
