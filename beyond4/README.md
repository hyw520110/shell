# Beyond4 工具

> Beyond4 专用工具集

## 📋 目录说明

| 脚本文件 | 说明 | 版本检测 | 帮助函数 |
|---------|------|---------|---------|
| `beyond4.sh` | Beyond4 工具脚本 | ❌ | ❌ |

## 🚀 快速开始

### 使用 Beyond4 工具

```bash
cd beyond4
./beyond4.sh
```

查看 Git difftool/mergetool 配置指南：

```bash
./beyond4.sh git
```

## 🔧 详细说明

### beyond4.sh - Beyond4 工具脚本

**功能**: Beyond4 专用工具集

**工具特性**:
- 自动化部署
- 环境配置
- 系统管理
- 监控告警

**适用场景**:
- 系统初始化
- 环境部署
- 运维管理
- 监控告警

## Git 集成注意事项

macOS 建议先在 Beyond Compare 菜单中执行：

```text
Beyond Compare > Install Command Line Tools
```

官方命令行工具会安装：

```text
/usr/local/bin/bcomp
/usr/local/bin/bcompare
```

如果没有官方命令行工具，可以使用 `~/.local/bin` wrapper，但 `bcompare` 和 `bcomp` 都应调用 App 包内的：

```text
/Applications/Beyond Compare.app/Contents/MacOS/bcomp
```

不要让 `bcompare` 直接调用 `BCompare` 主程序，否则容易只打开默认首页，不进入文件对比。

Git difftool 还需要注意临时文件生命周期。`$LOCAL` / `$REMOTE` 通常是 `/var/folders/.../git-blob-*` 临时文件，`bcomp` 过早返回后 Git 可能会清理这些文件，导致 Beyond Compare 报“文件找不到”。推荐使用稳定副本包装器：

```bash
git config --global difftool.bc.cmd 'git-bc-difftool "$LOCAL" "$REMOTE" "$MERGED"'
git config --global mergetool.bc.cmd 'bcomp "$LOCAL" "$REMOTE" "$BASE" "$MERGED"'
```

当前详细配置和 wrapper 示例见：

```bash
./beyond4.sh git
```

## 📝 使用场景

- **系统管理**: Beyond4 系统管理
- **自动化运维**: 自动化运维工具
- **环境部署**: 环境配置和部署
- **监控管理**: 系统监控和管理
