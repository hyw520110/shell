# Flutter 开发环境管理脚本

> Flutter 跨平台移动应用开发环境的自动化安装和配置工具

## 📋 目录说明

| 脚本文件 | 说明 | 版本检测 | 帮助函数 |
|---------|------|---------|---------|
| `install_flutter.sh` | Flutter SDK 安装脚本 | ❌ | ❌ |

## 🚀 快速开始

### 一键安装 Flutter

```bash
cd flutter
./install_flutter.sh
```

## 🔧 详细说明

### install_flutter.sh - Flutter SDK 安装脚本

**功能**：安装 Flutter SDK，自动配置开发环境

**安装方式**：
```bash
# 使用默认设置安装
./install_flutter.sh

# 查看帮助信息
./install_flutter.sh --help
```

**安装内容包括**：
- Flutter SDK（稳定版）
- Dart SDK
- 开发工具链
- 国内镜像源配置

**安装位置**：
- macOS: `$HOME/flutter`
- Linux: `$HOME/flutter`

**验证安装**：
```bash
flutter --version
flutter doctor
```

## ⚙️ 环境配置

### 镜像源配置

```bash
# 设置 Flutter 国内镜像源
export PUB_HOSTED_URL=https://pub.flutter-io.cn
export FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn/flutter_infra_release

# 永久配置（添加到 ~/.bashrc 或 ~/.zshrc）
cat >> ~/.bashrc << 'EOF'
# Flutter 镜像配置
export PUB_HOSTED_URL=https://pub.flutter-io.cn
export FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn/flutter_infra_release
EOF

source ~/.bashrc
```

### 环境变量

```bash
# Flutter 环境变量
export FLUTTER_HOME=$HOME/flutter
export PATH=$FLUTTER_HOME/bin:$PATH

# Dart 环境变量
export DART_HOME=$FLUTTER_HOME/bin/cache/dart-sdk
export PATH=$DART_HOME/bin:$PATH
```

## 📊 Flutter 开发环境分析

| 类别 | 工具 | 状态 | 脚本路径 |
|------|------|------|----------|
| **运行环境** | Flutter SDK | ✅ | flutter/install_flutter.sh |
| | Dart SDK | ✅ | Flutter 内置 |
| **包管理** | pub | ✅ | Dart 内置 |
| | flutter pub | ✅ | Flutter 内置 |
| **开发工具** | VS Code | ✅ | ../ide/install-vscode.sh |
| | Android Studio | ⚠️ | 需要手动安装 |
| | Xcode | ⚠️ | 系统工具 |
| | IntelliJ IDEA | ✅ | ../ide/install-intellij-idea.sh |
| **测试框架** | flutter test | ✅ | Flutter 内置 |
| | Mockito | ⚠️ | pub install |
| | integration_test | ⚠️ | 需要配置 |
| **状态管理** | Provider | ⚠️ | pub install |
| | Riverpod | ⚠️ | pub install |
| | BLoC | ⚠️ | pub install |
| | GetX | ⚠️ | pub install |
| **网络请求** | dio | ⚠️ | pub install |
| | http | ⚠️ | pub install |
| | retrofit | ❌ | - |
| **数据库** | sqflite | ⚠️ | pub install |
| | hive | ⚠️ | pub install |
| | drift | ❌ | - |
| **本地存储** | shared_preferences | ⚠️ | pub install |
| | provider | ⚠️ | pub install |

## 🔗 相关链接

- [Flutter 官方网站](https://flutter.dev/)
- [Flutter 中文网](https://flutter.cn/)
- [Dart 官方网站](https://dart.dev/)
- [Flutter 包索引](https://pub.dev/)
- [Flutter API 文档](https://api.flutter.dev/)

## ❓ 常见问题

### Q: 如何创建新项目？

**A**: 使用 Flutter CLI：

```bash
# 创建新项目
flutter create myproject

# 使用特定包名
flutter create --org com.example myproject

# 进入项目目录
cd myproject

# 运行项目
flutter run
```

### Q: 如何运行项目？

**A**: 支持多种运行方式：

```bash
# 在真机运行
flutter run

# 在模拟器运行
flutter run -d <device-id>

# 在 Chrome 运行（Web）
flutter run -d chrome

# 查看可用设备
flutter devices

# 热重载（项目运行时）
# 按 'r' 键

# 热重启（项目运行时）
# 按 'R' 键
```

### Q: 如何安装依赖包？

**A**: 使用 pub：

```bash
# 安装依赖
flutter pub get

# 添加依赖包
flutter pub add package_name

# 添加开发依赖
flutter pub add --dev package_name

# 升级依赖
flutter pub upgrade

# 移除依赖
flutter pub remove package_name
```

### Q: 如何配置开发环境？

**A**: 运行环境检查：

```bash
# 检查开发环境
flutter doctor

# 详细信息
flutter doctor -v

# Android 许可证接受
flutter doctor --android-licenses
```

### Q: 如何构建发布版本？

**A**: 使用 Flutter build：

```bash
# 构建 APK（Android）
flutter build apk

# 构建 App Bundle（Android）
flutter build appbundle

# 构建 IPA（iOS）
flutter build ios

# 构建 Web 应用
flutter build web

# 构建 Windows 应用
flutter build windows

# 构建 macOS 应用
flutter build macos

# 构建 Linux 应用
flutter build linux
```

## 📝 最佳实践

### 项目结构

```
myproject/
├── lib/                 # Dart 源代码
│   ├── main.dart       # 应用入口
│   ├── app/            # 应用逻辑
│   ├── models/         # 数据模型
│   ├── screens/        # 页面
│   ├── widgets/        # 自定义组件
│   ├── services/       # 服务层
│   └── utils/          # 工具函数
├── android/            # Android 平台代码
├── ios/                # iOS 平台代码
├── web/                # Web 平台代码
├── test/               # 测试代码
├── pubspec.yaml        # 项目配置
├── analysis_options.yaml # 代码分析配置
└── .gitignore
```

### 代码规范

```bash
# 分析代码
flutter analyze

# 格式化代码
dart format .

# 运行测试
flutter test

# 测试覆盖率
flutter test --coverage
```

### 状态管理

```bash
# 添加 Provider
flutter pub add provider

# 添加 Riverpod
flutter pub add flutter_riverpod

# 添加 BLoC
flutter pub add flutter_bloc

# 添加 GetX
flutter pub add get
```

## 🚧 TODO

- [ ] 为 install_flutter.sh 添加帮助函数和版本检测
- [ ] 添加常用插件安装脚本
- [ ] 添加状态管理框架配置脚本
- [ ] 添加项目脚手架模板
- [ ] 添加 CI/CD 配置模板
- [ ] 添加性能监控工具
- [ ] 添加测试工具和脚本
- [ ] 添加国际化配置模板

## 🤝 贡献

欢迎提交 Issue 和 Pull Request！

## 📄 许可证

本仓库采用 MIT 许可证，详见根目录 LICENSE 文件。