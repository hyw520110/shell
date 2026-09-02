# 网络工具集

> 网络代理、VPN、远程访问和网络相关工具的安装与配置脚本

## 📋 目录说明

| 目录/文件 | 说明 | 功能 |
|------|------|------|
| `frp/` | FRP 反向代理 | 内网穿透、远程访问 |
| `openvpn/` | OpenVPN | 安全 VPN 连接 |
| `shadowsocks/` | Shadowsocks | 科学上网代理 |
| `tools/` | 网络工具集 | 测速、扫描、代理、DNS、TCP 调优等 |
| `clashx-meta.sh` | ClashX Meta | macOS 代理客户端安装、更新、卸载 |
| `publish-dev-https.sh` | 开发环境 HTTPS 发布 | 通过 nginx + 可选 frp 发布服务并申请证书 |
| `register-domain.sh` | 域名注册 | 域名注册/购买脚本 |
| `find_ports.sh` | 端口查找 | 查找占用端口的进程 |
| `ssh_key_setup.sh` | SSH 密钥配置 | 配置免密登录 |
| `ssh-exec-remote.sh` | 远程命令执行 | 自动连接目标主机执行命令 |
| `vpn.sh` | VPN 连接 | 通过 openconnect 连接 VPN（凭据走环境变量） |
| `wol.sh` | 网络唤醒 | Wake-on-LAN 远程开机 |
| `update-hosts.sh` | hosts 更新 | 下载并更新 /etc/hosts + 定时任务 |
| `set-hosts-aliases.sh` | hosts 别名 | 将主机名列表指向本机 IP |
| `install-hosts-font.sh` | 中文字体安装 | CentOS/RHEL 安装中文字体 |

## 🚀 快速开始

### FRP 反向代理

```bash
cd network/frp
./install.sh
./startup.sh
```

### OpenVPN

```bash
cd network/openvpn
./install_openvpn.sh
```

### Shadowsocks

```bash
cd network/shadowsocks
./shadowsocks-all.sh
```

### ClashX Meta

```bash
cd network
./clashx-meta.sh              # 安装；已安装则更新
./clashx-meta.sh uninstall    # 卸载软件，保留用户配置
./clashx-meta.sh purge        # 完全卸载
```

### 网络工具（SSH / hosts / VPN / 唤醒）

```bash
cd network
./ssh_key_setup.sh            # 配置 SSH 免密登录
./ssh-exec-remote.sh          # 远程执行命令（支持密钥/密码认证）
./update-hosts.sh             # 下载更新 /etc/hosts 并配置每小时定时任务
./set-hosts-aliases.sh        # 将主机名别名指向本机 IP（需 root）
./vpn.sh                      # openconnect VPN 连接（凭据通过环境变量提供）
./wol.sh                      # Wake-on-LAN 远程开机
./find_ports.sh               # 查找占用端口的进程
./install-hosts-font.sh       # CentOS/RHEL 安装中文字体
```

## 🔧 详细说明

### 1. FRP - 反向代理工具

**功能**: 内网穿透和远程访问工具

**特点**:
- 支持 TCP/UDP 协议
- 支持多种协议
- 配置简单
- 高性能

**适用场景**:
- 远程桌面访问
- 内网服务外网访问
- 开发环境映射
- 临时端口转发

### 2. OpenVPN - 安全 VPN

**功能**: 企业级 VPN 解决方案

**特点**:
- 强加密算法
- 灵活的路由配置
- 客户端支持广泛
- 开源免费

**适用场景**:
- 远程办公
- 安全文件传输
- 企业网络互联
- 跨地域协作

### 3. Shadowsocks - 代理工具

**功能**: 科学上网和代理访问

**特点**:
- 协议混淆
- 性能优秀
- 配置灵活
- 多平台支持

**适用场景**:
- 访问国外资源
- API 调用代理
- 网络加速
- 隐私保护

## 🔗 相关链接

- [FRP 官方网站](https://github.com/fatedier/frp)
- [OpenVPN 官方网站](https://openvpn.net/)
- [Shadowsocks 项目](https://shadowsocks.org/)

## 📝 使用场景

- **内网穿透**: FRP - 将内网服务映射到公网
- **安全连接**: OpenVPN - 企业级安全 VPN 连接
- **代理访问**: Shadowsocks - 访问被限制的网络资源
- **macOS 代理客户端**: ClashX Meta - 菜单栏代理客户端
