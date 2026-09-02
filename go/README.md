# Go 语言环境管理脚本

> Go 编程语言的自动化安装和配置工具

## 📋 目录说明

| 目录/文件 | 说明 | 版本检测 | 帮助函数 |
|----------|------|---------|---------|
| `install-go.sh` | Go 语言安装脚本 | ✅ | ✅ |
| `goproxy/` | Go 代理工具 | - | - |

## 🚀 快速开始

### 一键安装 Go

```bash
cd go
./install-go.sh
```

### 安装指定版本

```bash
./install-go.sh --version 1.23.5
```

## 🔧 详细说明

### install-go.sh - Go 语言安装脚本

**功能**：安装 Go 语言环境，支持多版本管理和国内镜像源

**安装方式**：
```bash
# 使用默认设置安装
./install-go.sh

# 安装指定版本
./install-go.sh --version 1.23.5

# 使用腾讯镜像源
./install-go.sh --proxy tencent

# 自定义安装目录
./install-go.sh --install-dir /opt/go

# 仅下载不安装
./install-go.sh --download-only
```

**支持的镜像源**：
- **阿里云镜像** (默认) - `https://mirrors.aliyun.com/goproxy/`
- **腾讯镜像** - `https://mirrors.cloud.tencent.com/go/`
- **七牛镜像** - `https://goproxy.cn`
- **官方源** - `https://proxy.golang.org`

**常用命令**：
```bash
# 查看Go版本
go version

# 查看Go环境
go env

# 查看GOPATH
go env GOPATH

# 查看GOROOT
go env GOROOT

# 设置Go模块代理
go env -w GOPROXY=https://goproxy.cn,direct
```

### goproxy/ - Go 代理工具

**说明**：Go 模块代理配置工具

**使用方式**：
```bash
cd goproxy
# 具体使用方式请查看该目录下的脚本
```

## ⚙️ 环境配置

### 环境变量

```bash
# 设置 GOPATH（Go 工作目录）
export GOPATH=$HOME/go-workspace

# 设置 GOROOT（Go 安装目录）
export GOROOT=$HOME/go

# 添加到 PATH
export PATH=$GOROOT/bin:$GOPATH/bin:$PATH

# 设置 Go 模块代理（国内用户推荐）
export GOPROXY=https://goproxy.cn,direct

# 禁用 Go 模块校验（可选）
export GOSUMDB=off

# 启用 Go Modules（Go 1.16+ 默认启用）
export GO111MODULE=on
```

### 永久配置

```bash
# 添加到 ~/.bashrc 或 ~/.zshrc
cat >> ~/.bashrc << 'EOF'
# Go 环境配置
export GOPATH=$HOME/go-workspace
export GOROOT=$HOME/go
export PATH=$GOROOT/bin:$GOPATH/bin:$PATH
export GOPROXY=https://goproxy.cn,direct
export GO111MODULE=on
EOF

# 重新加载配置
source ~/.bashrc
```

## 📊 Go 开发环境分析

| 类别 | 工具 | 状态 | 脚本路径 |
|------|------|------|----------|
| **运行环境** | Go | ✅ | go/install-go.sh |
| | GCCGo | ❌ | - |
| **版本管理** | GVM | ❌ | - |
| | goup | ❌ | - |
| **包管理** | Go Modules | ✅ | Go 1.11+ 内置 |
| | dep | ⚠️ | 已废弃 |
| | glide | ⚠️ | 已废弃 |
| **开发工具** | gofmt | ✅ | Go 内置 |
| | golint | ❌ | - |
| | golangci-lint | ❌ | - |
| | goimports | ❌ | - |
| **测试框架** | testing | ✅ | Go 内置 |
| | testify | ⚠️ | 需要安装 |
| | ginkgo | ❌ | - |
| **Web框架** | Gin | ⚠️ | 需要安装 |
| | Echo | ⚠️ | 需要安装 |
| | Beego | ⚠️ | 需要安装 |
| | Fiber | ❌ | - |
| **IDE** | VS Code | ✅ | ../ide/install-vscode.sh |
| | GoLand | ⚠️ | ../ide/install-intellij-idea.sh |
| | LiteIDE | ❌ | - |
| **构建工具** | make | ⚠️ | 系统工具 |
| | Mage | ❌ | - |
| | Task | ❌ | - |
| **部署工具** | Docker | ⚠️ | ../docker/ |
| | Kubernetes | ⚠️ | ../docker/install-k8s.sh |
| | systemd | ⚠️ | 系统工具 |

## 🔗 相关链接

- [Go 官方网站](https://golang.org/)
- [Go 官方文档](https://golang.org/doc/)
- [Go 包索引](https://pkg.go.dev/)
- [Go Playground](https://play.golang.org/)
- [Go Modules 官方文档](https://golang.org/ref/mod)

## ❓ 常见问题

### Q: 如何设置 Go 模块代理？

**A**: 使用国内镜像源加速：

```bash
# 设置 GOPROXY
go env -w GOPROXY=https://goproxy.cn,direct

# 查看当前配置
go env GOPROXY
```

### Q: 如何创建新项目？

**A**: 使用 Go Modules：

```bash
# 创建项目目录
mkdir myproject
cd myproject

# 初始化模块
go mod init github.com/username/myproject

# 创建主程序
cat > main.go << 'EOF'
package main

import "fmt"

func main() {
    fmt.Println("Hello, World!")
}
EOF

# 运行程序
go run main.go
```

### Q: 如何管理依赖？

**A**: 使用 Go Modules：

```bash
# 下载依赖
go mod download

# 整理依赖
go mod tidy

# 更新依赖
go get -u

# 查看依赖
go list -m all
```

### Q: 如何跨平台编译？

**A**: 使用 GOOS 和 GOARCH：

```bash
# 编译为 Linux 可执行文件
GOOS=linux GOARCH=amd64 go build

# 编译为 Windows 可执行文件
GOOS=windows GOARCH=amd64 go build

# 编译为 macOS 可执行文件
GOOS=darwin GOARCH=amd64 go build

# 编译为 ARM64 可执行文件
GOOS=linux GOARCH=arm64 go build
```

### Q: 如何设置开发工具？

**A**: 安装常用工具：

```bash
# 安装 golint
go install golang.org/x/lint/golint@latest

# 安装 golangci-lint
go install github.com/golangci/golangci-lint/cmd/golangci-lint@latest

# 安装 goimports
go install golang.org/x/tools/cmd/goimports@latest

# 添加到 PATH
export PATH=$GOPATH/bin:$PATH
```

## 📝 最佳实践

### 项目结构

```
myproject/
├── go.mod              # Go 模块定义
├── go.sum              # 依赖校验和
├── cmd/                # 命令行工具
│   └── main.go
├── internal/           # 私有应用代码
│   ├── app/
│   └── config/
├── pkg/                # 外部可访问的库代码
│   └── util/
├── api/                # API 定义
├── configs/            # 配置文件
├── scripts/            # 脚本文件
├── test/               # 测试文件
├── docs/               # 文档
├── .gitignore
├── Makefile
└── README.md
```

### 代码规范

```bash
# 格式化代码
go fmt ./...

# 检查代码
golint ./...

# 运行测试
go test ./...

# 生成测试覆盖率
go test -cover ./...

# 运行静态检查
golangci-lint run
```

### 版本管理

```bash
# 创建 .golangci.yml 配置文件
# 添加到 .gitignore
echo "bin/" >> .gitignore
echo "*.exe" >> .gitignore
echo "*.test" >> .gitignore
```

## 🚧 TODO

- [ ] 添加 GVM 版本管理工具安装脚本
- [ ] 添加 goup 版本管理工具安装脚本
- [ ] 添加常用开发工具安装脚本
- [ ] 添加 Web 框架脚手架（Gin、Echo、Beego）
- [ ] 添加 Docker Go 应用模板
- [ ] 添加 CI/CD 配置模板
- [ ] 添加性能分析工具（pprof）
- [ ] 添加依赖管理可视化工具

## 🤝 贡献

欢迎提交 Issue 和 Pull Request！

## 📄 许可证

本仓库采用 MIT 许可证，详见根目录 LICENSE 文件。