# DS4 (DeepSeek V4 Flash) 本地部署

基于 `antirez/ds4` 在本机部署 DeepSeek V4 Flash，并通过 `ds4-server` 提供 OpenAI 兼容 API。

本目录的管理入口是：

```bash
bash /Users/sky/work/shell/ai/runtime/ds4/install-ds4.sh <command>
```

默认安装目录是 `~/ds4`，默认 API 地址是 `http://localhost:8000/v1`。实际端口会从 `DS4_PORT` 或 `ds4-server.log` 自动探测。

## 模型信息

| 项 | 值 |
|---|---|
| 模型 | DeepSeek-V4-Flash |
| 总参数 | 671B |
| 激活参数 | 37B |
| 上下文窗口 | 模型能力 64K；实际可用长度以 `/v1/models` 返回的 `context_length` 或服务端 `--ctx` 为准 |
| 默认模型 | `q2-imatrix` |
| API 模型名 | 优先使用 `/v1/models` 返回的 `deepseek-v4-flash`；兼容别名可用 `ds4` |
| 默认 API Key | `sk-ds4-local-$(hostname -s)` |

模型类型：

| 类型 | 脚本名 | 完整性阈值 | 建议 |
|---|---|---:|---|
| Q2 Imatrix | `q2-imatrix` | >= 78GiB | 128GB 内存优先 |
| Q4 Imatrix | `q4-imatrix` | >= 150GiB | 256GB+ 或内存余量充足 |

脚本会校验 GGUF 结构，不只看文件大小。

## 快速使用

```bash
# 无参数：执行默认流程
bash install-ds4.sh

# 如需打开旧式管理菜单
bash install-ds4.sh -i

# 一键安装、下载默认模型并执行冒烟测试
bash install-ds4.sh bootstrap -t q2-imatrix

# 或分步执行
bash install-ds4.sh install
bash install-ds4.sh download -t q2-imatrix
bash install-ds4.sh server-bg
bash install-ds4.sh configure-clients
```

检查状态：

```bash
bash install-ds4.sh status
bash install-ds4.sh doctor
curl http://localhost:8000/v1/models
```

测试 API：

```bash
curl http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer sk-ds4-local-$(hostname -s)" \
  -d '{"model":"ds4","messages":[{"role":"user","content":"你好"}],"max_tokens":64}'
```

## 命令清单

| 命令 | 作用 |
|---|---|
| `bootstrap [-t q2-imatrix\|q4-imatrix]` | 一键安装、下载模型并执行冒烟测试 |
| `install` | 下载/更新源码并编译 `ds4`、`ds4-server`、`ds4-bench` |
| `download [-t q2-imatrix\|q4-imatrix]` | 下载模型，支持 `adl`/断点续传/完整性校验 |
| `use [-t q2-imatrix\|q4-imatrix]` | 切换默认模型，必要时重启服务 |
| `models` | 列出已安装模型和当前默认模型 |
| `start [args...]` | 前台启动 CLI `./ds4` |
| `server [args...]` | 前台启动 `./ds4-server` |
| `server-bg` | 后台启动 `ds4-server` |
| `stop` | 停止 `ds4-server` |
| `bench [args...]` | 运行 `ds4-bench` |
| `smoke-test` | CLI/API 冒烟测试 |
| `discover` | 发现 DS4 API、模型和本机客户端 |
| `configure-clients` / `config-clients` | 写入 `~/.ds4-env`，并尝试配置 Open WebUI |
| `client-guide [api_base] [api_key]` | 只输出客户端配置指南，便于 README 或其他脚本提取 |
| `doctor` | 诊断安装、模型、API、客户端配置 |
| `status` / `version` | 查看安装和服务状态 |
| `uninstall` | 删除 `~/ds4` |

无参数默认流程：

```text
硬件预检
-> 硬件满足且未安装时自动安装
-> 硬件不满足最低要求时只跳过本机安装/下载/启动
-> 列出已安装模型
-> 本机可用时交互选择/切换模型
-> 本机可用且选择的模型不存在时自动下载
-> 本机可用时启动 ds4-server
-> 服务端模式检测本机 DS4 API，并输出局域网客户端地址
-> 客户端模式询问 DS4 服务端口（默认 8000）并探测同网段 DS4 API
-> 输出精简发现摘要
-> 服务端模式跳过客户端配置写入；客户端模式才询问是否写入配置
-> 自动诊断
```

短参数：

| 短参数 | 等同命令 |
|---|---|
| `-h` / `--help` | `help` |
| `-i` / `--interactive` | 打开交互菜单 |
| `-s` / `--status` | `status` |
| `-m` / `--models` | `models` |
| `-d` / `--discover` | `discover` |
| `-c` / `--configure` | `configure-clients` |
| `-g` / `--guide` | `client-guide` |
| `-b` / `--server-bg` | `server-bg` |
| `-x` / `--stop` | `stop` |

参数选项：

| 参数 | 作用 |
|---|---|
| `-t` / `--type` / `--model <type>` | 指定模型类型：`q2-imatrix` 或 `q4-imatrix` |
| `-a` / `--api-base` / `--base-url <url>` | 指定 DS4 OpenAI-compatible API 地址 |
| `-k` / `--api-key <key>` | 指定 `client-guide` 输出中的 API Key |
| `-H` / `--host <host>` | 指定 DS4 远端主机，供 `configure-clients` 探测 |
| `-p` / `--port <port>` | 指定 DS4 发现端口，供 `configure-clients` 探测 |
| `--no-scan` | `configure-clients` 禁用网段扫描 |

参数策略：

- 自动执行：无参数流程中的安装检查、列出模型、启动服务、自动发现、诊断；单独命令 `models`、`status`、`client-guide <api_base> <api_key>`、`server-bg`、`stop`。
- 交互执行：无参数流程中的模型选择/切换、缺失模型下载确认、客户端模式 DS4 服务端口确认、是否写入客户端配置；单独命令 `download` 未指定模型时选择模型、`use` 未指定模型时选择模型。
- 直通参数：`start`、`server`、`bench` 后面的参数原样传给 DS4 可执行文件。

诊断建议：`doctor` 推荐自动执行。它是只读检查，不会修改配置或停止服务，适合放在默认流程末尾形成闭环；涉及写文件的 `configure-clients` 保持交互确认。
当硬件不足进入客户端模式时，`doctor` 会跳过本机 DS4 可执行文件、默认模型和本机 `ds4-server` 的失败判定，只检查 API、环境变量和客户端配置。
默认流程使用精简发现和精简诊断，避免重复输出客户端清单和配置指南；需要完整信息时单独执行 `discover` 或 `doctor`。默认流程会先把端口和同网段探测结果固化到本次进程环境中，后续摘要、配置确认和诊断复用同一个推荐地址。

## 存储与下载

模型默认放在 `~/ds4/gguf`，默认模型链接为：

```text
~/ds4/ds4flash.gguf -> gguf/<当前模型文件>
```

脚本默认只运行一个 `ds4-server` 实例和一个活动模型。Q2/Q4 可以同时保存在磁盘上，但不建议同时运行两个模型；如确实要同时运行，需要拆成两个独立服务实例、不同模型链接/工作目录和不同端口，内存占用、加载时间和运维复杂度都会明显增加。日常推荐只运行一个模型：Q2 作为默认，确实需要更高质量时再切换到 Q4。

脚本会自动检测可用外置大容量磁盘，必要时可将模型目录迁移到外置盘：

```bash
# 禁用外置盘检测
DS4_USE_EXTERNAL_DISK=0 bash install-ds4.sh download q2-imatrix

# 指定模型目录
DS4_MODEL_DIR=/Volumes/YourDisk/ds4/gguf bash install-ds4.sh download q2-imatrix
```

下载优先使用 `adl`。可通过环境变量控制：

```bash
DS4_USE_ADL=0 bash install-ds4.sh download q2-imatrix
ADL_PATH=/path/to/adl bash install-ds4.sh download q2-imatrix
```

## 常用环境变量

| 变量 | 作用 |
|---|---|
| `DS4_PORT` | 指定 `ds4-server` 端口 |
| `DS4_HOST` | 指定 `ds4-server` 监听地址，默认 `0.0.0.0` 以支持局域网访问；只允许本机访问可设为 `127.0.0.1` |
| `DS4_SERVER_ARGS` | 追加传给后台 `ds4-server` 的参数 |
| `DS4_ENV_FILE` | 指定 `configure-clients` 写入的环境文件，默认 `~/.ds4-env` |
| `DS4_REMOTE_API_BASE` | 客户端机器显式指定远端 DS4 API，例如 `http://192.168.1.20:8000/v1` |
| `DS4_REMOTE_HOST` / `DS4_REMOTE_HOSTS` | 客户端机器显式指定 DS4 主机 IP/主机名，脚本会按候选端口探测 |
| `DS4_DISCOVERY_HOSTS` | 指定额外发现目标，支持空格或逗号分隔 |
| `DS4_DISCOVERY_PORTS` | 指定局域网发现端口，默认只探测 `DS4_PORT` 或 `8000`；如需探测 `8080` 请显式设置 |
| `DS4_DISCOVERY_PORT_PROMPT_TIMEOUT` | 无参数默认流程中端口确认超时时间，默认 `15` 秒 |
| `DS4_DISCOVERY_SCAN=0` | 禁用局域网网段扫描，只使用显式远端配置和本机探测 |
| `DS4_DISCOVERY_ALL_NETWORKS=1` | 默认流程扫描所有本机 IPv4 网段；默认只扫描默认路由所在网卡，避免虚拟网卡干扰 |
| `DS4_DISCOVERY_STRICT=0` | 放宽 `/models` 返回内容校验，适合代理层隐藏模型名的场景 |
| `DS4_DISCOVERY_JOBS` | 局域网并发探测数，默认 `64` |
| `DS4_DISCOVERY_CONNECT_TIMEOUT` | 单个局域网目标连接超时，默认 `0.8` 秒 |
| `DS4_DISCOVERY_MAX_TIME` | 单个局域网目标最大探测时间，默认 `2` 秒 |
| `DS4_DISCOVERY_MAX_HOSTS` | 单个 CIDR 网段最大扫描主机数，默认 `1024` |
| `DS4_CURL_NOPROXY` | 探测 DS4 API 时传给 `curl --noproxy`，默认 `*`，避免局域网请求走代理 |
| `DS4_MIN_MEMORY_GB` | 本机安装最低内存阈值，默认 `96` |
| `DS4_FORCE_INSTALL_UNSUPPORTED=1` | 硬件不满足要求时仍强制本机安装 |
| `DS4_USE_ADL=0` | 禁用 `adl` 下载 |
| `DS4_USE_EXTERNAL_DISK=0` | 禁用外置盘检测 |
| `DS4_MODEL_DIR` | 指定模型目录 |
| `DS4_AUTO_STOP_CONFLICT=1` | 启动 server 时自动结束冲突的 DS4 CLI 进程 |
| `DS4_FORCE_REBUILD=1` | 强制重新编译 |
| `DS4_UPDATE_SOURCE=1` | 显式更新源码 |
| `DS4_FORCE_SOURCE_REFRESH=1` | git 更新失败时用 zip 缓存刷新源码 |

## 客户端配置

若当前机器硬件不满足 DS4 本机运行要求，默认流程只会跳过本机安装、下载和启动，仍会继续询问服务端口、探测同网段 DS4 API、确认客户端配置和执行诊断。也可显式把当前机器作为客户端，连接局域网内其他 DS4 主机：

```bash
bash install-ds4.sh configure-clients -a http://<DS4机器局域网IP>:8000/v1
```

建议先执行：

```bash
bash install-ds4.sh configure-clients
source ~/.ds4-env
```

只查看或提取“客户端配置指南”，不写任何配置文件：

```bash
# 自动选择本机/局域网 API 后输出指南
bash install-ds4.sh client-guide

# 指定示例地址后输出指南，适合 README 或外部脚本提取
bash install-ds4.sh client-guide -a http://192.168.1.20:8000/v1 -k sk-ds4-local-host
```

`configure-clients` 会按以下顺序选择客户端 Base URL：

1. 显式远端配置：`DS4_REMOTE_API_BASE`、`DS4_REMOTE_HOST(S)`。
2. 本机可用 DS4 API：`localhost:<port>`。
3. 局域网自动发现：先扫 `DS4_DISCOVERY_HOSTS` / ARP 邻居，再根据本机 IPv4 地址和 netmask 扫同网段主机，默认端口为 `8000`。
4. 未发现服务时回退到 `http://localhost:8000/v1`。

如果 DS4 部署在另一台主机，推荐在客户端机器上执行：

```bash
# 自动发现局域网 DS4 服务，并写入 ~/.ds4-env / Open WebUI 配置
bash install-ds4.sh configure-clients

# 或显式指定服务地址，速度更快也更稳定
DS4_REMOTE_API_BASE=http://192.168.1.20:8000/v1 bash install-ds4.sh configure-clients

# 只指定主机，让脚本按候选端口探测
DS4_REMOTE_HOST=192.168.1.20 bash install-ds4.sh configure-clients
```

`~/.ds4-env` 会包含：

```bash
export DS4_API_BASE_URL="http://localhost:8000/v1 或 http://<DS4机器局域网IP>:8000/v1"
export DS4_API_KEY="sk-ds4-local-<host>"
export DS4_MODEL="deepseek-v4-flash"
export DS4_CONTEXT_LENGTH="32768 或服务端 /v1/models 返回值"

aider-ds4() {
  AIDER_OPENAI_API_BASE="http://<DS4机器局域网IP>:8000/v1" \
  AIDER_OPENAI_API_KEY="sk-ds4-local-<host>" \
  OPENAI_API_BASE="http://<DS4机器局域网IP>:8000/v1" \
  OPENAI_API_BASE_URL="http://<DS4机器局域网IP>:8000/v1" \
  OPENAI_API_KEY="sk-ds4-local-<host>" \
  aider --model openai/deepseek-v4-flash \
        --openai-api-base "http://<DS4机器局域网IP>:8000/v1" \
        --openai-api-key "sk-ds4-local-<host>" \
        --api-key openai="sk-ds4-local-<host>" \
        --model-metadata-file "$HOME/.aider.model.metadata.json" \
        --no-show-model-warnings "$@"
}
```

### 客户端配置指南

以下内容对应 `bash install-ds4.sh client-guide <api_base> <api_key>` 的输出结构。实际地址以脚本探测或你传入的地址为准。

```text
========================================
  DS4 客户端配置指南
========================================

服务地址: http://<DS4机器局域网IP>:8000/v1
API Key:  sk-ds4-local-<host> (DS4 不需要，可填任意值)
Model:    deepseek-v4-flash
上下文:   以 /v1/models 的 context_length 为准；模型能力 64K

快速配置:
  source ~/.ds4-env
  aider-ds4

推荐客户端:
  Aider:
    推荐使用 aider-ds4 函数隔离 DS4 环境变量，避免污染已有 GPT/OpenAI 配置。
    判断是否连到 DS4 不要问模型自述，应以 /v1/models 或 Aider 启动横幅为准。

  Open WebUI:
    OPENAI_API_BASE_URLS=http://<DS4机器局域网IP>:8000/v1
    OPENAI_API_KEYS=sk-ds4-local-<host>
    bash install-ds4.sh configure-clients && ~/open-webui/start.sh

  OpenCode AI:
    适合作为第二 coding agent 客户端接入 DS4；建议手动新增 OpenAI-compatible provider。
    baseURL=http://<DS4机器局域网IP>:8000/v1
    apiKey=sk-ds4-local-<host>
    model=deepseek-v4-flash

  Hermes Agent:
    hermes setup model -> OpenAI-compatible provider
    base_url=http://<DS4机器局域网IP>:8000/v1
    api_key=sk-ds4-local-<host>
    model=deepseek-v4-flash

  Claude Code / Codex / Gemini / Cursor / Qwen / Kimi / Grok:
    如果支持自定义 Provider，选择 OpenAI Compatible / Custom Provider
    Base URL=http://<DS4机器局域网IP>:8000/v1
    API Key=sk-ds4-local-<host>
    Model=deepseek-v4-flash

  Continue / Cline / Roo / Cursor / Windsurf:
    Provider=OpenAI Compatible
    Base URL=http://<DS4机器局域网IP>:8000/v1
    API Key=sk-ds4-local-<host>
    Model=deepseek-v4-flash

使用示例:
  curl http://<DS4机器局域网IP>:8000/v1/models

  from openai import OpenAI
  client = OpenAI(base_url="http://<DS4机器局域网IP>:8000/v1", api_key="sk-ds4-local-<host>")
  response = client.chat.completions.create(
      model="ds4",
      messages=[{"role": "user", "content": "你好"}]
  )
```

推荐顺序：

```text
本地代码开发: Aider > OpenCode AI > DeepSeek TUI > DeepSeek Reasonix
局域网共享/浏览器访问: 桌面客户端(Chatbox/Cherry Studio) > Open WebUI
多人、多个模型或需要配额/日志: DS4 -> New API / One API -> Open WebUI / Aider / 桌面客户端
```

### Aider

最适合代码开发和 Git 工作流。不要把 DS4 的 `OPENAI_API_BASE` 全局写进 `~/.zshrc`，否则会影响原有 GPT/OpenAI 配置。推荐用独立函数只在启动 Aider 时临时注入 DS4 配置：

```bash
aider-ds4() {
  AIDER_OPENAI_API_BASE="http://<DS4机器局域网IP>:8000/v1" \
  AIDER_OPENAI_API_KEY="sk-ds4-local-$(hostname -s)" \
  OPENAI_API_BASE="http://<DS4机器局域网IP>:8000/v1" \
  OPENAI_API_BASE_URL="http://<DS4机器局域网IP>:8000/v1" \
  OPENAI_API_KEY="sk-ds4-local-$(hostname -s)" \
  aider --model openai/deepseek-v4-flash \
        --openai-api-base "http://<DS4机器局域网IP>:8000/v1" \
        --openai-api-key "sk-ds4-local-$(hostname -s)" \
        --api-key openai=sk-ds4-local-$(hostname -s) \
        --model-metadata-file "$HOME/.aider.model.metadata.json" \
        --no-show-model-warnings "$@"
}
```

使用：

```bash
source ~/.ds4-env
aider-ds4
```

正常启动时，Aider 横幅应显示类似：

```text
Aider v0.82.3
Model: openai/deepseek-v4-flash with whole edit format
Git repo: .git with 658 files
```

上下文窗口不要固定写 `65536`。DeepSeek V4 Flash 模型能力是 64K，但 DS4 服务实际启动上下文由 `ds4-server --ctx` 决定；`ds4-server` 默认是 `32768`。先用健康检查确认：

```bash
curl --noproxy '*' http://<DS4机器局域网IP>:8000/v1/models
```

如果返回 `context_length: 32768`，Aider 侧按 32768 理解；只有服务端以 `--ctx 65536` 启动并返回 `context_length: 65536` 时，才按 64K 配置。

服务端启用 64K 示例：

```bash
cd /Users/star/work/shell/ai/runtime/ds4
./install-ds4.sh stop
DS4_SERVER_ARGS="--ctx 65536" ./install-ds4.sh server-bg
curl --noproxy '*' http://<DS4机器局域网IP>:8000/v1/models
```

确认返回 `context_length: 65536` 后，在客户端重新生成配置：

```bash
./install-ds4.sh configure-clients -a http://<DS4机器局域网IP>:8000/v1
source ~/.ds4-env
aider-ds4
```

不要用“你是什么模型”这类问题验证连接。模型会根据训练语料或提示上下文幻觉自称 GPT-4、DeepSeek-V3 等，这不代表实际请求打到了 OpenAI。可靠判断方式：

```bash
curl --noproxy '*' http://<DS4机器局域网IP>:8000/v1/models
```

期望看到 `id: deepseek-v4-flash` 和当前 `context_length`。Aider 启动时也应显示：

```text
Model: openai/deepseek-v4-flash
```

### OpenCode AI

OpenCode AI 适合接入 DS4，定位上更接近完整 coding agent，可作为 Aider 之后的第二选择。它支持 OpenAI-compatible provider，适合把 DS4 当作本地/局域网模型后端使用；但不同版本的配置文件结构可能变化，建议先手动配置，不要由脚本自动覆盖 `~/.opencode/settings.json`。

项目级配置可在仓库根目录创建 `opencode.json`，全局配置可放到 `~/.config/opencode/opencode.json`。示例：

```json
{
  "$schema": "https://opencode.ai/config.json",
  "provider": {
    "ds4": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "DS4 DeepSeek V4 Flash",
      "options": {
        "baseURL": "http://<DS4机器局域网IP>:8000/v1"
      },
      "models": {
        "deepseek-v4-flash": {
          "name": "DeepSeek V4 Flash",
          "limit": {
            "context": 32768,
            "output": 32768
          }
        }
      }
    }
  },
  "model": "ds4/deepseek-v4-flash"
}
```

其中 `limit.context` 同样以 `/v1/models` 返回的 `context_length` 为准。配置后运行 `opencode`，在 TUI 中用 `/connect` 录入 `ds4` 的 API Key，或用 `/models` 切换到 `ds4/deepseek-v4-flash`。DS4 不校验密钥时可填 `sk-ds4-local-<host>`。

### DeepSeek TUI / CLI

适合终端聊天、临时问答和轻量命令行使用。

通用配置原则：

```text
Provider: OpenAI Compatible / OpenAI
Base URL: http://localhost:8000/v1
API Key: sk-ds4-local-<host> 或任意非空值
Model: deepseek-v4-flash
```

如果客户端支持命令行参数，可直接指定：

```bash
deepseek --provider openai --base-url http://localhost:8000/v1 --model deepseek-v4-flash
```

### DeepSeek Reasonix

Reasonix 的优势主要在官方 DeepSeek API 的前缀缓存和成本优化。本地 DS4 没有 API 成本，建议作为第三选择或实验性工具。

配置原则同上：

```json
{
  "provider": "openai",
  "apiKey": "sk-ds4-local-host",
  "baseUrl": "http://localhost:8000/v1",
  "model": "ds4"
}
```

### Open WebUI

推荐作为局域网主客户端。若已安装 `~/open-webui` 或存在 `~/open-webui/.open-webui.env`，脚本会在 `configure-clients` 时写入：

```bash
ENABLE_OPENAI_API=True
OPENAI_API_BASE_URLS=http://localhost:8000/v1
OPENAI_API_KEYS=sk-ds4-local-<host>
OPENWEBUI_DETECTED_BACKEND=ds4
```

Docker 示例：

```bash
docker run -d --name open-webui \
  -p 3000:8080 \
  -e OPENAI_API_BASE_URLS=http://host.docker.internal:8000/v1 \
  -e OPENAI_API_KEYS=sk-ds4-local-$(hostname -s) \
  -v open-webui:/app/backend/data \
  ghcr.io/open-webui/open-webui:main
```

访问：

```text
http://localhost:3000
```

## 局域网访问

DS4 和 AI 客户端经常不在同一台机器上。无参数默认流程会先询问服务端口（默认 `8000`），再获取默认路由所在网卡的 IPv4 网段并探测同网段 DS4 API。客户端机器上执行 `configure-clients` 时，脚本也会自动发现局域网 DS4 API 并把远端地址写入 `~/.ds4-env` 和 Open WebUI 配置。

如果机器上存在 Docker、虚拟机、UTM/Parallels、桥接网卡，可能会看到 `192.168.64.1/24`、`10.211.55.0/24` 之类虚拟网段。默认流程优先使用默认路由网卡，例如 Wi-Fi 的 `192.168.1.33/24`；确实需要扫描所有网段时再设置 `DS4_DISCOVERY_ALL_NETWORKS=1`。

局域网其他设备访问时，客户端 Base URL 应是部署机器 IP：

```text
http://<DS4机器局域网IP>:8000/v1
```

客户端配置统一使用 Base URL，也就是以 `/v1` 结尾的地址；`/v1/models` 是健康检查接口，只用于 `curl` 验证，不要写进客户端配置。

先在 DS4 机器上确认服务监听与防火墙设置：

```bash
bash install-ds4.sh server-bg
bash install-ds4.sh status
curl http://localhost:8000/v1/models
```

`server-bg` 默认使用 `--host 0.0.0.0 --port 8000`，便于局域网客户端访问。若服务已在运行但只监听 `localhost:8000`，再次执行默认流程会提示是否重启并绑定到 `0.0.0.0`。只想本机访问时可执行：

```bash
DS4_HOST=127.0.0.1 bash install-ds4.sh server-bg
```

如果同网段没有自动发现，优先排查：

```bash
# 1. 确认客户端直连不走代理
curl --noproxy '*' http://<DS4机器局域网IP>:8000/v1/models

# 若返回 Connection refused，说明该 IP 可达但 8000 端口未监听或被拒绝；
# 需要在 DS4 机器上确认 ds4-server 正在运行，并监听 0.0.0.0/局域网地址而不只是 localhost。
lsof -nP -iTCP:8000 -sTCP:LISTEN

# 如果 lsof 显示 localhost:8000 或 127.0.0.1:8000，局域网客户端无法直连；
# 需要改为监听 0.0.0.0/局域网 IP，或使用反向代理/SSH 隧道暴露给客户端。

# 2. 显式指定远端地址，绕过自动发现
DS4_REMOTE_API_BASE=http://<DS4机器局域网IP>:8000/v1 bash install-ds4.sh configure-clients

# 3. 指定发现目标和端口
DS4_DISCOVERY_HOSTS=<DS4机器局域网IP> DS4_DISCOVERY_PORTS=8000 bash install-ds4.sh configure-clients

# 如确实需要额外探测 8080，显式指定多个端口
DS4_DISCOVERY_PORTS=8000,8080 bash install-ds4.sh configure-clients

# 4. 放宽模型名校验，适合代理层 /models 不返回 ds4 名称时
DS4_DISCOVERY_STRICT=0 bash install-ds4.sh configure-clients
```

然后在客户端机器上执行：

```bash
bash install-ds4.sh configure-clients
source ~/.ds4-env
curl "$DS4_API_BASE_URL/models"
```

如果 DS4 只监听本机地址，可使用 SSH 隧道：

```bash
ssh -L 8000:localhost:8000 user@ds4-server
```

然后客户端仍连接：

```text
http://localhost:8000/v1
```

## 诊断流程

```bash
# 1. 查看安装、模型和服务状态
bash install-ds4.sh status

# 2. 自动诊断
bash install-ds4.sh doctor

# 3. 查看 API 和客户端发现结果
bash install-ds4.sh discover

# 4. 查看服务日志
tail -f ~/ds4/ds4-server.log

# 5. 重启服务
bash install-ds4.sh stop
bash install-ds4.sh server-bg
```

常见问题：

| 问题 | 处理 |
|---|---|
| `curl /models` 失败 | 先看 `status` 和 `~/ds4/ds4-server.log` |
| 提示缺少默认模型 | 执行 `download q2-imatrix` 或 `use q2-imatrix` |
| 下载文件未完整 | 重新执行 `download <type>`，脚本会继续校验/续传 |
| Aider 上下文太小 | 先用 `/v1/models` 确认 `context_length`；需要 64K 时先用 `--ctx 65536` 重启服务端，再按客户端能力配置 |
| Aider 问模型身份回答 GPT-4/DeepSeek-V3 | 正常幻觉现象，不代表连错；以 `/v1/models` 和 Aider 横幅 `Model: openai/deepseek-v4-flash` 为准 |
| `NotOpenSSLWarning` | macOS/Xcode Python 使用 LibreSSL 触发的 urllib3 警告，不影响 DS4 连接；如需消除可换 Homebrew/uv Python 环境 |
| 切换模型后没生效 | 执行 `use <type>`，脚本会提示是否重启服务 |
| CLI 与 server 冲突 | 停止 CLI/执行 `stop`，或设置 `DS4_AUTO_STOP_CONFLICT=1` |

## 相关链接

- DS4: https://github.com/antirez/ds4
- 模型文件: https://huggingface.co/antirez/deepseek-v4-gguf
- Aider: https://aider.chat/docs/
- Open WebUI: https://github.com/open-webui/open-webui
