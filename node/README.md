# Node.js 环境管理脚本

> Node.js 运行时环境的自动化安装和配置工具

## 📋 目录说明

| 脚本文件 | 说明 | 版本检测 | 帮助函数 |
|---------|------|---------|---------|
| `node.sh` | Node.js 安装与卸载脚本 | ✅ | ✅ |

## 🚀 快速开始

### 一键安装 Node.js

```bash
cd node
./node.sh
```

### 安装指定版本

```bash
./node.sh 20.10.0
```

## 🔧 详细说明

### node.sh - Node.js 安装与卸载脚本

**功能**：安装或卸载 Node.js 及版本管理器，支持 fnm 和 nvm

**安装方式**：
```bash
# 使用默认设置安装
./node.sh

# 安装指定版本
./node.sh 22.17.0

# 使用 nvm 而不是 fnm
./node.sh --use-nvm

# 使用华为镜像源
./node.sh --registry huawei
```

### 卸载 Node.js 或版本管理器

```bash
# 使用默认的 fnm 卸载指定 Node.js 版本
./node.sh --uninstall 20.10.0

# 使用 nvm 卸载指定 Node.js 版本
./node.sh --use-nvm --uninstall 20.10.0

# 卸载 nvm 及其管理的全部 Node.js 版本
./node.sh --uninstall-manager nvm

# 直接卸载 nvm 及其管理的全部 Node.js 版本
./node.sh --uninstall-nvm

# 卸载 fnm 及其管理的全部 Node.js 版本，并跳过确认
./node.sh --uninstall-manager fnm --yes
```

卸载版本管理器时，脚本会删除对应的管理器目录和脚本自动写入的 Shell 配置块；不会删除 npm、Yarn、pnpm 缓存或项目目录。卸载正在使用的 Node.js 版本前，请先切换到其他版本。

**支持的版本管理工具**：
- **fnm** (Fast Node Manager) - 默认推荐，快速且轻量
- **nvm** (Node Version Manager) - 经典版本管理工具

**Shell 环境配置**：
- 脚本会自动检测当前 shell，并写入对应配置文件。
- zsh 默认更新 `~/.zshrc`。
- macOS bash 默认更新 `~/.bash_profile` 和 `~/.bashrc`。
- Linux bash 默认更新 `~/.bashrc` 和 `~/.profile`。
- 配置块使用 `# >>> shell/node ... >>>` / `# <<< shell/node ... <<<` 标记管理，重复运行会更新原块，不会重复追加。
- 安装后重新打开终端，或执行 `source ~/.zshrc` / `source ~/.bashrc` 生效。

**支持的镜像源**：
- **淘宝镜像** (默认) - `https://registry.npmmirror.com/`
- **华为镜像** - `https://mirrors.huaweicloud.com/repository/npm/`
- **腾讯镜像** - `https://mirrors.cloud.tencent.com/npm/`
- **官方源** - `https://registry.npmjs.org/`

**常用命令**：
```bash
# 查看已安装版本
fnm list

# 安装特定版本
fnm install 20.10.0

# 切换版本
fnm use 20.10.0

# 设置默认版本
fnm default 20.10.0

# 安装最新LTS版本
fnm install --lts

# 查看远程版本
fnm list-remote
```

## ⚙️ 环境配置

### 镜像源配置

```bash
# 查看当前镜像源
npm config get registry

# 设置淘宝镜像（推荐）
npm config set registry https://registry.npmmirror.com/

# 设置华为镜像
npm config set registry https://mirrors.huaweicloud.com/repository/npm/

# 设置腾讯镜像
npm config set registry https://mirrors.cloud.tencent.com/npm/

# 恢复官方源
npm config set registry https://registry.npmjs.org/
```

### 全局包安装

```bash
# 安装常用全局工具
npm install -g yarn
npm install -g pnpm
npm install -g @vue/cli
npm install -g create-react-app
npm install -g typescript

# 查看全局包
npm list -g --depth=0
```

### 环境变量

```bash
# 设置全局包安装路径
mkdir -p ~/.npm-global
npm config set prefix '~/.npm-global'

# 添加到PATH
export PATH=~/.npm-global/bin:$PATH
```

## 📊 Node.js开发环境分析

| 类别 | 工具 | 状态 | 脚本路径 |
|------|------|------|----------|
| **运行环境** | Node.js | ✅ | node/node.sh |
| | Deno | ❌ | - |
| | Bun | ❌ | - |
| **版本管理** | fnm | ✅ | node/node.sh |
| | nvm | ✅ | node/node.sh |
| | n | ❌ | - |
| **包管理器** | npm | ✅ | Node.js内置 |
| | yarn | ⚠️ | 需要手动安装 |
| | pnpm | ⚠️ | 需要手动安装 |
| | bun | ❌ | - |
| **开发工具** | ESLint | ❌ | - |
| | Prettier | ❌ | - |
| | TypeScript | ⚠️ | npm install -g typescript |
| **测试框架** | Jest | ❌ | - |
| | Mocha | ❌ | - |
| | Vitest | ❌ | - |
| **前端框架** | React | ⚠️ | npm install -g create-react-app |
| | Vue | ⚠️ | npm install -g @vue/cli |
| | Angular | ⚠️ | npm install -g @angular/cli |
| | Svelte | ❌ | - |
| **IDE** | VS Code | ✅ | ../ide/install-vscode.sh |
| | WebStorm | ⚠️ | ../ide/install-intellij-idea.sh |
| | Sublime Text | ❌ | - |
| **构建工具** | Webpack | ⚠️ | 项目依赖 |
| | Vite | ⚠️ | npm install -g create-vite |
| | Rollup | ❌ | - |
| | esbuild | ❌ | - |
| **部署工具** | PM2 | ❌ | - |
| | Docker | ⚠️ | ../docker/ |
| | Vercel | ❌ | - |

## 🔗 相关链接

- [Node.js 官方网站](https://nodejs.org/)
- [fnm 官方仓库](https://github.com/Schniz/fnm)
- [nvm 官方仓库](https://github.com/nvm-sh/nvm)
- [npm 官方网站](https://www.npmjs.com/)
- [Yarn 官方网站](https://yarnpkg.com/)
- [pnpm 官方网站](https://pnpm.io/)

## ❓ 常见问题

### Q: 如何选择版本管理工具？

**A**: 推荐 fnm（默认），因为它：
- 基于 Rust 编写，性能更好
- 支持 .node-version 文件
- 跨平台支持更好
- 兼容 nvm 命令

### Q: 如何切换不同的 Node.js 版本？

**A**: 使用 fnm 管理：

```bash
# 列出已安装版本
fnm list

# 安装新版本
fnm install 18.20.0

# 切换到指定版本
fnm use 18.20.0

# 设置默认版本
fnm default 20.10.0
```

### Q: 如何解决包安装速度慢的问题？

**A**: 使用国内镜像源：

```bash
# 设置淘宝镜像（推荐）
npm config set registry https://registry.npmmirror.com/

# 临时使用镜像
npm install --registry=https://registry.npmmirror.com/ package
```

### Q: 如何创建新项目？

**A**: 使用框架脚手架：

```bash
# React 项目
npm create vite@latest my-react-app -- --template react

# Vue 项目
npm create vite@latest my-vue-app -- --template vue

# Node.js 项目
npm init -y
```

### Q: 如何管理全局包？

**A**: 查看和管理全局包：

```bash
# 查看全局包
npm list -g --depth=0

# 安装全局包
npm install -g package-name

# 卸载全局包
npm uninstall -g package-name

# 更新全局包
npm update -g package-name
```

## 📝 最佳实践

### 项目结构

```
myproject/
├── package.json          # 项目配置
├── package-lock.json     # 依赖锁定
├── node_modules/         # 依赖包
├── src/                  # 源代码
├── public/               # 静态资源
├── tests/                # 测试代码
└── .gitignore           # Git忽略配置
```

### 依赖管理

```bash
# 安装依赖
npm install

# 安装生产依赖
npm install --save package

# 安装开发依赖
npm install --save-dev package

# 卸载依赖
npm uninstall package

# 更新依赖
npm update
```

### 版本锁定

```bash
# 生成 package-lock.json
npm install

# 使用精确版本
npm install --save-exact package
```

## 🚧 TODO

- [ ] 添加 Deno 运行时安装脚本
- [ ] 添加 Bun 运行时安装脚本
- [ ] 添加 ESLint 和 Prettier 配置脚本
- [ ] 添加常用开发工具全局安装
- [ ] 添加 PM2 进程管理器安装
- [ ] 添加 Webpack/Vite 配置模板
- [ ] 添加 Docker Node.js 应用模板
- [ ] 添加 CI/CD 配置模板

## 🤝 贡献

欢迎提交 Issue 和 Pull Request！

## 📄 许可证

本仓库采用 MIT 许可证，详见根目录 LICENSE 文件。
