# Edge-TTS 安装脚本

一键安装 Edge-TTS，支持 Linux 和 macOS。

## 功能特性

- ✅ 支持 Linux 和 macOS
- ✅ 支持安装和卸载
- ✅ 支持重复执行不重复安装
- ✅ 自动创建 Python 虚拟环境
- ✅ 创建全局命令链接
- ✅ 友好的用户界面

## 使用方法

### 安装

```bash
# 安装 Edge-TTS
./install-edge-tts.sh install

# 或者直接运行（默认是 install）
./install-edge-tts.sh
```

### 检查状态

```bash
./install-edge-tts.sh status
```

### 卸载

```bash
./install-edge-tts.sh uninstall
```

### 查看帮助

```bash
./install-edge-tts.sh help
```

### 列出所有语音

```bash
./install-edge-tts.sh voices
```

## 使用 Edge-TTS

安装完成后，可以直接使用全局命令：

```bash
# 列出所有可用语音
edge-tts --list-voices

# 列出所有中文语音
edge-tts --list-voices | grep zh-CN

# 将文本转换为语音
edge-tts --text "你好，欢迎使用 Edge TTS" --write-media hello.mp3

# 使用指定语音
edge-tts --voice zh-CN-XiaoxiaoNeural --text "你好" --write-media hello.mp3

# 使用 SSML
edge-tts --text '<speak version="1.0" xmlns="http://www.w3.org/2001/10/synthesis" xml:lang="zh-CN"><voice name="zh-CN-XiaoxiaoNeural">你好</voice></speak>' --write-media hello.mp3
```

### 常用中文语音

| 语音名称 | 性别 | 风格 |
|---------|------|------|
| zh-CN-XiaoxiaoNeural | 女 | 自然 |
| zh-CN-YunxiNeural | 男 | 自然 |
| zh-CN-XiaoyiNeural | 女 | 温柔 |
| zh-CN-YunjianNeural | 男 | 播音 |
| zh-CN-XiaochenNeural | 女 | 甜美 |
| zh-CN-YunyangNeural | 男 | 新闻 |

### 高级用法

```bash
# 调整语速（+10% 加速，-10% 减速）
edge-tts --text "你好" --rate="+10%" --write-media hello.mp3

# 调整音调（+10% 升高，-10% 降低）
edge-tts --text "你好" --pitch="+10Hz" --write-media hello.mp3

# 调整音量（+10% 增大，-10% 减小）
edge-tts --text "你好" --volume="+10%" --write-media hello.mp3

# 使用代理
edge-tts --text "你好" --proxy "http://proxy:port" --write-media hello.mp3

# 从文件读取文本
edge-tts --file input.txt --write-media output.mp3

# 生成字幕文件
edge-tts --text "你好" --write-media hello.mp3 --write-subtitles hello.vtt
```

## 目录结构

```
~/edge-tts/
├── venv/          # Python 虚拟环境
└── logs/          # 日志文件
```

## 前置要求

- Python 3.8 或更高版本
- pip（Python 包管理器）

## 项目链接

- GitHub 仓库：https://github.com/rany2/edge-tts
- PyPI 页面：https://pypi.org/project/edge-tts/

## 注意事项

- Edge-TTS 使用 Microsoft Edge 的在线语音合成服务，需要网络连接
- 语音质量较高，支持多种语言和语音风格
- 完全免费，无需 API 密钥
