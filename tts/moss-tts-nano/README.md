# MOSS-TTS-Nano 安装脚本

一键安装 MOSS-TTS-Nano，支持 Linux 和 macOS。

## 功能特性

- ✅ 支持 Linux 和 macOS
- ✅ 支持安装和卸载
- ✅ 支持重复执行不重复安装
- ✅ 优先使用 adl 下载（如果可用）
- ✅ 自动创建 Python 虚拟环境
- ✅ 自动检测和更新代码仓库
- ✅ 友好的用户界面

## 使用方法

### 安装

```bash
# 安装 MOSS-TTS-Nano
./install-moss-tts-nano.sh install

# 或者直接运行（默认是 install）
./install-moss-tts-nano.sh
```

### 检查状态

```bash
./install-moss-tts-nano.sh status
```

### 卸载

```bash
./install-moss-tts-nano.sh uninstall
```

### 查看帮助

```bash
./install-moss-tts-nano.sh help
```

## 使用 MOSS-TTS-Nano

安装完成后，激活虚拟环境即可使用：

```bash
# 激活虚拟环境
source ~/moss-tts-nano/venv/bin/activate

# 进入代码目录
cd ~/moss-tts-nano/repo

# 使用 ONNX 版本（推荐，CPU 友好）
python infer_onnx.py --prompt-audio-path assets/audio/zh_1.wav --text "你好，欢迎使用 MOSS-TTS-Nano"

# 启动 Web 界面
python app_onnx.py
# 然后访问 http://127.0.0.1:18083

# 使用 CLI 命令
moss-tts-nano generate --backend onnx --prompt-speech assets/audio/zh_1.wav --text "你好"
```

## 目录结构

```
~/moss-tts-nano/
├── venv/          # Python 虚拟环境
├── repo/          # 代码仓库
├── models/        # 模型文件
└── logs/          # 日志文件
```

## 前置要求

- Python 3.10 或更高版本
- Git
- curl 或 wget（如果没有 adl）

## 项目链接

- GitHub 仓库：https://github.com/OpenMOSS/MOSS-TTS-Nano
- 在线演示：https://openmoss.github.io/MOSS-TTS-Nano-Demo/

## 注意事项

- 首次运行时会自动从 Hugging Face 下载模型文件，请确保网络连接正常
- 如果有 adl 工具，会优先使用 adl 下载，下载速度更快
- 推荐使用 ONNX 版本，效率更高，不依赖 PyTorch
