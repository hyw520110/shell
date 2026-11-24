# FFmpeg 视频处理工具

> FFmpeg 多媒体框架的安装和配置脚本

## 📋 目录说明

| 脚本文件 | 说明 | 版本检测 | 帮助函数 |
|---------|------|---------|---------|
| `install_ffmpeg.sh` | FFmpeg 安装脚本 | ❌ | ❌ |

## 🚀 快速开始

### 安装 FFmpeg

```bash
cd ffmpeg
./install_ffmpeg.sh
```

## 🔧 详细说明

### install_ffmpeg.sh - FFmpeg 安装脚本

**功能**: 安装 FFmpeg 多媒体处理工具

**FFmpeg 功能**:
- 视频转换和处理
- 音频转换和处理
- 视频剪辑和编辑
- 流媒体处理
- 格式转换

**支持格式**:
- **视频**: MP4, AVI, MKV, MOV, FLV 等
- **音频**: MP3, AAC, FLAC, OGG 等
- **图片**: PNG, JPG, GIF, BMP 等

**常用命令**:
```bash
# 转换视频格式
ffmpeg -i input.mp4 -c:v libx264 -c:a aac output.mp4

# 提取音频
ffmpeg -i video.mp4 -vn -acodec copy audio.aac

# 调整视频分辨率
ffmpeg -i input.mp4 -vf scale=1920:1080 output.mp4

# 视频剪辑
ffmpeg -i input.mp4 -ss 00:00:10 -to 00:00:20 -c copy output.mp4

# 提取视频截图
ffmpeg -i video.mp4 -ss 00:00:05 -vframes 1 image.png
```

## 🔗 相关链接

- [FFmpeg 官方网站](https://ffmpeg.org/)
- [FFmpeg 文档](https://ffmpeg.org/documentation.html)

## 📝 使用场景

- **视频处理**: 视频转码、剪辑、压缩
- **音频处理**: 音频转换、降噪、混音
- **格式转换**: 不同格式之间的转换
- **流媒体**: 直播推流、录屏处理
