# AI 短视频工具链与生产路线

本文说明 AI 短视频从选题、脚本、画面生成、配音到剪辑发布的工具组合，并提供云端生产和本地 GPU 生产两条路线。

## Ollama 的职责

Ollama 主要用于选题、脚本、分镜、提示词、标题和发布文案生成；视频画面生成、配音和剪辑需要组合其他工具完成。

## 推荐工具

| 环节 | 推荐工具 | 适用场景 |
|------|----------|----------|
| 脚本、分镜、提示词 | Ollama、ChatGPT、Claude、Gemini | 选题、脚本、镜头表、标题和发布文案 |
| 图片和角色设定 | Midjourney、Flux、Ideogram、即梦 | 角色设计、关键帧、封面 |
| 视频生成 | Runway、Google Veo、可灵 | 文生视频、图生视频、镜头延展 |
| 数字人 | HeyGen、Synthesia | 口播、课程、产品介绍 |
| 配音和声音 | ElevenLabs、Fish Audio、火山引擎 | TTS、配音、授权声音克隆 |
| 剪辑 | OpenCut、剪映/CapCut、Premiere | 时间线剪辑、字幕、转场、调色和导出 |
| 批量处理 | FFmpeg、Whisper/faster-whisper、Remotion、MoviePy | 转码、字幕、批量渲染和视频模板 |

## OpenCut 定位

[OpenCut](https://github.com/OpenCut-app/OpenCut) 是开源视频编辑器，适合本地剪辑、隐私场景和减少对商业剪辑软件的依赖。它属于“剪辑和编排”工具，不是主要的视频生成模型。

官方仓库目前说明 OpenCut 正在重写，Editor API、插件、MCP、无头批量渲染等能力仍在演进；当前使用时优先选择其 classic 版本，并为重要项目保留 CapCut 或 Premiere 作为稳定备选。[OpenCut 官方说明](https://github.com/OpenCut-app/OpenCut)

## 按视频类型选择

### 知识、测评、教程

```text
Ollama/ChatGPT → ElevenLabs 或真人配音 → OpenCut/剪映 → 字幕和发布
```

### AI 故事、动漫、科幻短片

```text
LLM 剧本和分镜 → 图片/关键帧 → Runway/Veo/可灵生成短镜头
→ 配音和音效 → OpenCut/剪映/Premiere
```

### 数字人口播和产品介绍

```text
LLM 销售或讲解脚本 → HeyGen/Synthesia → OpenCut/剪映 → 商品画面和字幕
```

## 两条生产路线

### 路线 A：云端生产（推荐当前普通/8GB 电脑）

适合无独立 GPU、内存较小、希望快速发布短视频的场景。电脑只负责脚本、配音、剪辑、字幕和转码，视频生成交给云端服务。

```text
Ollama/ChatGPT → Runway/Veo/可灵 → ElevenLabs/真人配音
→ OpenCut/剪映/Premiere → FFmpeg/Whisper
```

- 优点：无需下载大模型和准备高显存 GPU，上手快，适合先验证内容方向。
- 缺点：有 API/订阅费用，受网络和平台限制；上传素材前应确认服务商的数据和版权条款。
- 数字人口播：在视频生成环节增加 HeyGen 或 Synthesia。

### 路线 B：本地 GPU 生产（适合 NVIDIA 高显存主机）

适合重视隐私、需要批量生成、希望降低长期云端费用，并且有 NVIDIA GPU、充足磁盘空间的场景。

```text
Ollama/本地 LLM → ComfyUI + Wan/LTX-Video/HunyuanVideo
→ 本地 TTS/Whisper → OpenCut/FFmpeg/Remotion
```

- 优点：素材和模型可留在本地，流程可重复，适合批量自动化。
- 缺点：部署复杂，对显存、磁盘和散热要求较高；模型权重、缓存和生成素材不应放进本仓库。
- 建议：把模型、缓存和成片放到独立数据目录或外置磁盘；仓库只保存脚本、配置模板和提示词。

两条路线都可以用 Python/Node.js 编排，由 FFmpeg、Whisper 或 Remotion 统一完成字幕、配音、拼接和导出。

无论采用哪条路线，都建议将视频拆成 5–10 秒镜头后再剪辑，不要依赖一次生成完整长视频。

## 推荐起步组合

```text
Ollama/ChatGPT：脚本和分镜
Runway 或 Veo：视频镜头
ElevenLabs：配音
OpenCut：本地剪辑
FFmpeg：批量转码
```

如果需要数字人，再增加 HeyGen；如果需要完全本地生成，再部署 ComfyUI 和视频模型。
