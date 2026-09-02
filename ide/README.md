# 集成开发环境 (IDE) 安装脚本

> 主流集成开发环境的自动化安装和配置工具

## 📋 目录说明

| 脚本文件 | 说明 | 版本检测 | 帮助函数 |
|---------|------|---------|---------|
| `install-vscode.sh` | Visual Studio Code 安装脚本 | ✅ | ✅ |
| `install-intellij-idea.sh` | IntelliJ IDEA 安装脚本 | ✅ | ✅ |
| `install-eclipse.sh` | Eclipse IDE 安装脚本 | ✅ | ✅ |
| `install-cursor.sh` | Cursor AI 编辑器安装脚本 | ❌ | ❌ |
| `install-HBuilderX-cli.sh` | HBuilderX CLI 安装脚本 | ✅ | ✅ |
| `install-watt-toolkit.sh` | Watt Toolkit 安装脚本 | ❌ | ❌ |
| `beyond4.sh` | Beyond4 管理脚本 | ✅ | ✅ |

## 🚀 快速开始

### Visual Studio Code（推荐）

```bash
cd ide
./install-vscode.sh
```

### IntelliJ IDEA（Java开发）

```bash
cd ide
./install-intellij-idea.sh
```

### Eclipse（经典IDE）

```bash
cd ide
./install-eclipse.sh
```

## 🔧 详细说明

### 1. Visual Studio Code

**功能**：微软开发的轻量级代码编辑器，支持丰富的插件生态

**安装方式**：
```bash
./install-vscode.sh
```

**特色功能**：
- 轻量级，启动速度快
- 丰富的插件市场
- 内置 Git 支持
- 智能代码补全
- 支持多种语言

**适用场景**：
- 全栈开发
- 前端开发
- Python 开发
- Go 开发
- Rust 开发

### 2. IntelliJ IDEA

**功能**：JetBrains 公司开发的旗舰级 Java IDE

**安装方式**：
```bash
./install-intellij-idea.sh
```

**特色功能**：
- 强大的 Java 支持
- 智能代码分析
- 内置版本控制
- 数据库工具
- 支持 Spring Boot

**适用场景**：
- Java 企业级开发
- Kotlin 开发
- Android 开发
- Web 开发

### 3. Eclipse

**功能**：经典的开源集成开发环境

**安装方式**：
```bash
./install-eclipse.sh
```

**特色功能**：
- 完全开源免费
- 丰富的插件生态
- 企业级支持
- 成熟稳定

**适用场景**：
- Java 开发
- C/C++ 开发
- PHP 开发
- 大型企业项目

### 4. Cursor

**功能**：基于 VS Code 的 AI 驱动代码编辑器

**安装方式**：
```bash
./install-cursor.sh
```

**特色功能**：
- AI 代码助手
- 智能代码补全
- 自动代码生成
- 基于 VS Code

**适用场景**：
- AI 辅助编程
- 快速原型开发
- 代码重构

### 5. HBuilderX CLI

**功能**：DCloud 开发的 H5 前端开发工具

**安装方式**：
```bash
./install-HBuilderX-cli.sh
```

**特色功能**：
- 5+ App 开发
- 小程序开发
- H5 混合开发
- 内置调试工具

**适用场景**：
- uni-app 开发
- 微信小程序开发
- 移动应用开发

### 6. Watt Toolkit

**功能**：游戏平台加速工具

**安装方式**：
```bash
./install-watt-toolkit.sh
```

**特色功能**：
- Steam 加速
- Epic 加速
- 游戏下载加速
- 社区访问加速

**适用场景**：
- 游戏玩家
- 开发者测试
- 网络优化

### 7. Beyond4

**功能**：Beyond4 管理工具

**使用方式**：
```bash
./beyond4.sh --help
```

## 📊 IDE 开发工具分析

| 类别 | 工具 | 状态 | 脚本路径 |
|------|------|------|----------|
| **通用编辑器** | VS Code | ✅ | ide/install-vscode.sh |
| | Sublime Text | ❌ | - |
| | Atom | ⚠️ | 已停止维护 |
| | Cursor | ✅ | ide/install-cursor.sh |
| **Java IDE** | IntelliJ IDEA | ✅ | ide/install-intellij-idea.sh |
| | Eclipse | ✅ | ide/install-eclipse.sh |
| | NetBeans | ❌ | - |
| **Python IDE** | PyCharm | ⚠️ | 需要安装 |
| | VS Code + Python | ✅ | ide/install-vscode.sh |
| | Jupyter Notebook | ⚠️ | Python环境 |
| **前端 IDE** | VS Code | ✅ | ide/install-vscode.sh |
| | WebStorm | ⚠️ | 需要安装 |
| | HBuilderX | ✅ | ide/install-HBuilderX-cli.sh |
| **Go IDE** | GoLand | ⚠️ | 需要安装 |
| | VS Code + Go | ✅ | ide/install-vscode.sh |
| **C/C++ IDE** | CLion | ⚠️ | 需要安装 |
| | VS Code + C++ | ✅ | ide/install-vscode.sh |
| | Qt Creator | ❌ | - |
| **游戏工具** | Watt Toolkit | ✅ | ide/install-watt-toolkit.sh |
| | Steam | ⚠️ | 需要安装 |

## 🔗 相关链接

### Visual Studio Code
- [VS Code 官方网站](https://code.visualstudio.com/)
- [VS Code 插件市场](https://marketplace.visualstudio.com/)
- [VS Code 中文文档](https://code.visualstudio.com/docs)

### IntelliJ IDEA
- [IntelliJ IDEA 官方网站](https://www.jetbrains.com/idea/)
- [IntelliJ IDEA 文档](https://www.jetbrains.com/idea/documentation/)
- [JetBrains 学生认证](https://www.jetbrains.com/student/)

### Eclipse
- [Eclipse 官方网站](https://www.eclipse.org/)
- [Eclipse 插件市场](https://marketplace.eclipse.org/)
- [Eclipse 中文文档](https://wiki.eclipse.org/)

### 其他工具
- [Cursor 官方网站](https://cursor.sh/)
- [HBuilderX 官方网站](https://www.dcloud.io/hbuilderx.html)
- [Watt Toolkit 官方网站](https://steampp.net/)

## ❓ 常见问题

### Q: 如何选择合适的 IDE？

**A**: 根据开发语言和需求选择：

- **全栈开发**: VS Code
- **Java 企业开发**: IntelliJ IDEA
- **经典 Java 项目**: Eclipse
- **前端开发**: VS Code
- **移动应用**: HBuilderX
- **AI 辅助编程**: Cursor

### Q: 如何配置 VS Code？

**A**: 推荐安装常用插件：

```bash
# 代码格式化
- Prettier
- ESLint

# 主题
- One Dark Pro
- Material Icon Theme

# 开发工具
- GitLens
- Live Server
- Remote SSH

# 语言支持
- Python
- Java
- Go
- Rust
```

### Q: 如何配置 IntelliJ IDEA？

**A**: 推荐安装插件：

```
- Lombok
- MyBatis
- Maven Helper
- GitToolBox
- Translation
- Rainbow Brackets
- CodeGlance
```

### Q: 如何切换默认 IDE？

**A**: 修改系统默认应用：

```bash
# macOS
打开 "系统偏好设置" > "通用" > "默认网页浏览器"

# Linux
xdg-mime default code.desktop text/plain

# Windows
设置 > 应用 > 默认应用
```

### Q: 如何同步 IDE 配置？

**A**: 使用配置同步：

- **VS Code**: Settings Sync 插件
- **IntelliJ IDEA**: Settings Repository
- **Eclipse**: 导出/导入配置文件

## 📝 最佳实践

### 工作区配置

```bash
# VS Code
.vscode/
├── settings.json      # 工作区设置
├── extensions.json    # 插件推荐
├── launch.json        # 调试配置
└── tasks.json         # 任务配置

# IntelliJ IDEA
.idea/
├── workspace.xml     # 工作区配置
└── libraries/        # 库配置
```

### 插件管理

```bash
# VS Code 插件列表
code --list-extensions

# 安装插件
code --install-extension extension-id

# 禁用插件
code --disable-extension extension-id
```

### 配置备份

```bash
# 备份 VS Code 配置
cp -r ~/.vscode ~/backup/

# 备份 IntelliJ IDEA 配置
cp -r ~/.IntelliJIdea ~/backup/

# 恢复配置
cp -r ~/backup/.vscode ~/
```

## 🚧 TODO

- [ ] 为 install-cursor.sh 添加帮助函数和版本检测
- [ ] 为 install-watt-toolkit.sh 添加帮助函数和版本检测
- [ ] 添加 VS Code 常用插件安装脚本
- [ ] 添加 IntelliJ IDEA 常用插件安装脚本
- [ ] 添加 Eclipse 常用插件安装脚本
- [ ] 添加 IDE 配置模板和预设
- [ ] 添加 VS Code 远程开发配置
- [ ] 添加 IDE 性能优化建议

## 🤝 贡献

欢迎提交 Issue 和 Pull Request！

## 📄 许可证

本仓库采用 MIT 许可证，详见根目录 LICENSE 文件。