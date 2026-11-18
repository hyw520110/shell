# tts-notify 使用说明

通用语音提示工具，被多个 AI 客户端（codex / opencode / agy / qoder / comate / deepseek / claude / gemini / cursor / aider / goose / trae）和 shell 程序调用。

## 快速开始

```bash
# 安装共享软链接 + 集成客户端文档 + Codex hooks / OpenCode 插件
tts-notify install

# 显式播报
tts-notify complete              # 任务完成
tts-notify confirm               # 需要确认
tts-notify error                 # 任务失败
tts-notify info --text '自定义'  # 普通提示

# 包装命令，结束后自动通知（退出码透传）
tts-notify run -- make build
tts-notify run --tool codex --stats --error-text '构建失败' -- make test
```

## 队列语义（多客户端/多程序并发调用）

多个 AI 客户端或 shell 程序**同时**触发通知时，由 `TTS_CONCURRENCY` 决定行为：

| 模式 | 行为 | 适用场景 |
|------|------|----------|
| `queue`（**默认**） | 全部播报，按**事件优先级**排队（error > confirm > complete > info > text，同优先级 FIFO）；高优先级后到也会插队先播 | 多任务并行，每个结果都要听到 |
| `latest` | 只播最新，新通知覆盖旧待播 | 一晚上几十个并行编译，只关心最后一个 |
| `skip` | 已有播报进行中时直接丢弃本次 | 通知风暴想最小化 |

### 事件优先级

数值越小越先播：

```
error(0) > confirm(1) > complete(2) > info(3) > text(4)
```

即：一个任务**失败**的通知永远先于同时完成的**成功**通知——你正在等的失败不会被成功通知挤到后面。

### 推荐配置（多客户端并行）

```bash
export TTS_CONCURRENCY=queue        # 默认已是 queue
export TTS_QUEUE_TIMEOUT=60         # 队列项等待上限，防积压
export TTS_THROTTLE=5               # 最短播报间隔，防连续轰炸
export TTS_MAX_TEXT=160             # 单条上限，防长文本刷屏
```

### 扩展渠道（可选，互相独立，任一步失败不影响语音）

```bash
# 静音/嘈杂环境：桌面通知兜底
export TTS_DESKTOP_NOTIFY=true      # macOS osascript / Linux notify-send

# 人不在机器旁：webhook 推到企业微信/钉钉/Telegram/Server酱
export TTS_WEBHOOK_URL="https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=xxx"
export TTS_WEBHOOK_SECRET="optional-secret"   # 可选，作为 Bearer

# 排查"为什么没响/是否被节流"：历史日志
export TTS_LOG_FILE=~/.local/share/tts-notify/history.log
```

### 播放参数（可选）

```bash
export TTS_RATE=10      # -100~100，0 为默认
export TTS_VOLUME=0     # -100~100，0 为默认
export TTS_PITCH=0      # -100~100，0 为默认
```

## 检测客户端

```bash
tts-notify clients    # 列出已发现客户端
tts-notify detect     # 检测当前调用方
tts-notify integrate  # 更新所有已安装客户端的集成文档
```

自动检测支持：进程名精确匹配、解释器场景（node/bun/deno/python）解析首个非 flag 参数、入口脚本路径中的客户端目录名兜底。显式指定用 `--tool <name>` 或 `TTS_TOOL=<name>`。

## 环境变量速查

| 变量 | 默认 | 说明 |
|------|------|------|
| `TTS_ENABLED` | true | 关闭语音提示 |
| `TTS_CONCURRENCY` | queue | skip / queue / latest |
| `TTS_ASYNC` | true | 后台播放（`--sync` 严格等待） |
| `TTS_VOICE` | zh-CN-XiaoxiaoNeural | edge-tts 语音 |
| `TTS_RATE` / `TTS_VOLUME` / `TTS_PITCH` | 0 | 播放参数（-100~100） |
| `TTS_THROTTLE` | 5 | 连续播报最小间隔秒数 |
| `TTS_QUEUE_TIMEOUT` | 30 | queue 模式最大排队秒数 |
| `TTS_PLAY_TIMEOUT` | 8 | 单条播报超时秒数 |
| `TTS_LOCK_TIMEOUT` | 60 | 播报锁超时自动回收 |
| `TTS_MAX_TEXT` | 160 | 单条播报最大字符数 |
| `TTS_FORCE_LOCAL` | false | 强制本地引擎，跳过 edge-tts |
| `TTS_DESKTOP_NOTIFY` | false | 桌面通知 |
| `TTS_WEBHOOK_URL` | 空 | Webhook 转发 |
| `TTS_LOG_FILE` | ~/.local/share/tts-notify/history.log | 播报历史 |

## run 包装增强

```bash
tts-notify run [--tool <name>] \
  [--text '成功消息'] [--error-text '失败消息'] \
  [--quiet] [--stats] \
  [--on-success 'CMD'] [--on-fail 'CMD'] \
  -- <command> [args...]
```

- `--text` / `--error-text`：自定义成功/失败播报消息
- `--quiet`：不播报（静默包装）
- `--stats`：播报含耗时（如"构建完成（用时 12s）"）
- `--on-success` / `--on-fail`：成功/失败后额外执行回调命令，不影响退出码

## 可靠性

- edge-tts + play（在线）→ macOS say → Linux espeak 逐级回退
- edge-tts 瞬时失败重试 1 次，避免网络抖动导致音质降级
- 离线时自动跳过 edge-tts 直达本地引擎（网络探测带缓存）
- 播报锁超时自动回收，避免异常中断后永久静音
- 消息脱敏：token/password/secret/api_key/cookie 等敏感值替换为 `[REDACTED]`
