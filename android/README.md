# Android 开发环境

> Android SDK 和开发环境的安装配置脚本

## 📋 目录说明

| 脚本文件 | 说明 | 版本检测 | 帮助函数 |
|---------|------|---------|---------|
| `install_android_sdk.sh` | Android SDK 安装脚本 | ❌ | ❌ |

## 🚀 快速开始

### 安装 Android SDK

```bash
cd android
./install_android_sdk.sh
```

## 🔧 详细说明

### install_android_sdk.sh - Android SDK 安装脚本

**功能**: 安装 Android SDK 开发环境

**SDK 组件**:
- Android SDK Platform
- Android SDK Build-Tools
- Android SDK Platform-Tools
- Android SDK Tools
- 模拟器镜像

**环境变量配置**:
```bash
export ANDROID_HOME=/path/to/android-sdk
export PATH=$PATH:$ANDROID_HOME/tools
export PATH=$PATH:$ANDROID_HOME/platform-tools
```

**常用命令**:
```bash
# 查看 SDK 版本
sdkmanager --list

# 安装平台
sdkmanager "platforms;android-30"

# 安装构建工具
sdkmanager "build-tools;30.0.3"
```

## 🔗 相关链接

- [Android 开发者网站](https://developer.android.com/)
- [Android Studio 下载](https://developer.android.com/studio)

## 📝 使用场景

- **Android 应用开发**: 原生 Android 应用开发
- **混合应用开发**: React Native、Flutter 等跨平台开发
- **自动化测试**: Android UI 自动化测试
- **设备调试**: Android 设备调试和测试