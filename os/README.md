# os 目录

Linux 系统运维脚本集合，按功能分类管理。

## 目录结构

```
os/
├── bin/              # 入口脚本和公共库
│   ├── setup.sh              # 主入口：整合安全加固 + 初始化
│   └── os_common.sh          # 公共函数库（版本检测、帮助、颜色等）
├── init/             # 系统初始化模块
│   ├── init_audit.sh         # 审计初始化
│   ├── init_kernel.sh        # 内核参数优化
│   ├── init_security.sh      # 安全初始化
│   ├── init_time.sh          # 时间同步配置
│   ├── init_user.sh          # 用户配置管理
│   └── init_yum.sh           # YUM 源配置
├── security/         # 安全相关
│   ├── chkrootkit.sh         # Rootkit 检测
│   ├── permission_manager.sh # 权限管理
│   ├── reset_password.sh     # 密码重置
│   └── centos7_auto_secure_audit.sh  # CentOS7 安全审计
├── monitor/          # 监控和性能
│   ├── cpu.sh                # CPU 信息查看
│   ├── ip.sh                 # 网络接口信息
│   ├── ping.sh               # 连通性测试
│   ├── listen_conn.sh        # 连接监听
│   ├── eatcpu.sh             # CPU 压测
│   ├── eatmemory.sh          # 内存压测
│   ├── pydf.sh               # 磁盘使用（彩色）
│   └── aliyunlog.sh          # 阿里云日志采集
├── network/          # 已整合到顶层 network/ 目录（SSH、hosts、VPN、唤醒等）
├── sshm              # SSH 连接管理器（交互式，原位于 network/ 下，现位于 os/ 根目录）
├── disk/             # 磁盘和文件管理
│   ├── disk_cleanup.sh       # 磁盘清理
│   ├── diskspeed.sh          # 磁盘测速
│   ├── delete_duplicates.sh  # 重复文件删除
│   ├── show_files.sh         # 文件展示
│   ├── rename_files.sh       # 批量重命名
│   └── setup_swap.sh         # Swap 配置
├── backup/           # 备份恢复
│   ├── backup_env_and_softs.sh  # 环境和软件备份
│   └── recovery.sh              # 恢复脚本
├── utils/            # 实用工具
│   ├── clean_logs.sh         # 日志清理
│   ├── cachemanager.sh       # 缓存管理
│   ├── random-gen.sh         # 随机生成
│   ├── kernel-clean.sh       # 内核清理
│   ├── shengji.sh            # 系统升级
│   ├── deploy.sh             # 部署脚本
│   ├── startAll.sh           # 批量启动
│   ├── use.sh                # 使用说明
│   ├── java-apps.sh          # Java 应用管理
│   ├── java-apps.conf        # Java 应用配置
│   ├── github.bat            # Windows GitHub 快捷批处理
│   ├── live-system(mv-linux).sh  # Live 系统迁移
│   └── ziti_install.sh       # Ziti 安装脚本
├── centos/           # CentOS 专用脚本
│   ├── centos-init.sh        # CentOS 初始化
│   ├── centos-secure.sh      # CentOS 安全加固
│   └── centos7_auto_secure_audit.sh
├── envs              # 环境变量管理（公共脚本）
└── README.md         # 本文件
```

## 快速使用

### 系统初始化
```bash
# 一键初始化（安全加固 + 内核优化 + 时间同步 + 用户配置 + YUM）
bash bin/setup.sh

# 单独执行某个初始化模块
bash init/init_security.sh
bash init/init_kernel.sh
```

### SSH 管理
```bash
# 交互式 SSH 连接管理器（位于 os/ 根目录）
./sshm

# 列出所有服务器
./sshm -l

# 添加新服务器
./sshm -a

# 修复 SSH 文件权限
./sshm -R

# 直连 IP；会自动探测 22/2222 端口
./sshm sky@192.168.0.105

# IP 后两段简写，默认展开为 192.168.0.105
./sshm sky@0.105
SSHM_IP_PREFIX=192.168 ./sshm 0.105
```

### 网络脚本（已整合到顶层 network/ 目录）

```bash
# 原 os/network/ 下的脚本已合并到顶层 network/，用法不变
bash ../network/ssh_key_setup.sh       # 配置 SSH 免密登录
bash ../network/ssh-exec-remote.sh     # 远程命令执行
bash ../network/update-hosts.sh        # hosts 文件更新
bash ../network/vpn.sh                 # openconnect VPN 连接
bash ../network/wol.sh                 # 网络唤醒
```

### 环境变量
```bash
# 加载环境变量
source envs
```

## 脚本规范

- 所有脚本使用 `bash` 执行
- 公共函数在 `bin/os_common.sh` 中定义
- 颜色输出、帮助信息、版本检测等遵循统一规范
