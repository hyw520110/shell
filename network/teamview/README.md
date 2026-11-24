# TeamViewer 远程控制

`tv-init.sh` 是适用于 macOS 和 Linux 的 TeamViewer 安装、更新、状态检查及卸载脚本。

## 功能

- 使用 TeamViewer 官方当前稳定版安装包。
- 支持 `adl`、`curl`、`wget` 下载，并复用下载目录中的有效缓存。
- 检测已安装版本，交互选择更新、卸载或跳过。
- 支持状态、版本、设备 ID 和 Linux daemon 状态输出。
- Linux 支持通过参数设置无人值守访问密码。
- 支持 macOS DMG/PKG，以及 Linux DEB/RPM。

TeamViewer 系统安装包使用固定路径：macOS 为 `/Applications`，Linux 为 `/opt/teamviewer`。脚本接受 `--install-dir` 参数用于显式校验，不支持把系统包重定向到其他目录。

## 使用

```bash
./tv-init.sh
./tv-init.sh --status
./tv-init.sh --download-dir ~/Downloads
./tv-init.sh --force-download
./tv-init.sh --uninstall
```

Linux 设置无人值守密码：

```bash
sudo ./tv-init.sh --password '<fixed-password>'
```

查看完整参数：

```bash
./tv-init.sh --help
```

## 差异说明

TeamViewer 不提供类似 GitHub Releases 的公开历史版本 API，因此脚本只解析官方当前稳定版，不显示最近 5 个版本。macOS 公共版也没有稳定的无人值守密码 CLI，需要在 TeamViewer 应用中完成该项配置。
