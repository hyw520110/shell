## 运维自动化脚本仓库

这是一个综合性的运维自动化脚本仓库，按照功能领域进行了分类管理，包含了服务器管理、中间件部署、开发环境配置等多种用途的脚本。

### 目录结构

- **根目录**: 包含通用的运维脚本
- **子目录**: 按功能领域分类，每个子目录包含相关的安装、配置、启动、停止等脚本

### 功能分类目录

#### ai/ (AI和机器学习)
- `ollama/`: Ollama大语言模型管理脚本
- `asr/`: 语音识别工具管理脚本
  - `install-funasr.sh`: FunASR安装脚本
  - `install-paddlespeech.sh`: PaddleSpeech安装脚本
- `cosyVoice/`: CosyVoice语音合成工具管理脚本
- `home-assistant/`: Home Assistant智能家居平台
- `opencv/`: OpenCV计算机视觉库
- `ai-docs/`: AI相关文档
- `ai-tools.conf`: AI工具配置文件
- `ai-cli.sh`: AI工具命令行接口

#### apm/ (应用性能监控)
- `skywalking/`: Apache SkyWalking APM系统

#### dev/ (开发环境)
- `jdk/`: JDK安装和管理脚本
  - `install-jdk.sh`: 自动安装和配置JDK
    - 用法: `sudo ./install-jdk.sh <version> [install_dir]`
    - 支持版本: 7, 8, 11, 17, 19, 21
- `node/`: Node.js环境管理脚本
- `flutter/`: Flutter开发环境管理脚本
- `python/`: Python环境管理脚本
- `maven/`: Maven构建工具管理脚本
- `git/`: Git相关工具脚本
  - `git-bc.sh`: Git分支管理脚本
  - `git-diff.sh`: Git差异比较脚本
  - `setup_git.sh`: Git环境配置脚本

#### db/ (数据库)
- `mysql/`: MySQL数据库管理脚本
  - `bin/install.sh`: MySQL安装脚本
  - `bin/startup.sh`: MySQL启动脚本
  - `bin/stop.sh`: MySQL停止脚本
- `mongodb/`: MongoDB数据库管理脚本
- `postgresql/`: PostgreSQL数据库管理脚本
- `redis/`: Redis数据库管理脚本
- `neo4j/`: Neo4j图数据库

#### web/ (Web服务器)
- `nginx/`: Nginx Web服务器管理脚本
  - `bin/install.sh`: Nginx安装脚本
  - `bin/startup.sh`: Nginx启动脚本
  - `bin/stop.sh`: Nginx停止脚本
  - `bin/check_cert.sh`: SSL证书检查脚本
  - `bin/ngx-black-ip.sh`: IP黑名单管理脚本

#### config/ (配置中心与服务发现)
- `nacos/`: Nacos配置中心管理脚本
  - `bin/install.sh`: Nacos安装脚本
  - `bin/startup.sh`: Nacos启动脚本
  - `bin/stop.sh`: Nacos停止脚本

#### monitor/ (监控系统)
- `prometheus/`: Prometheus监控系统管理脚本
- `grafana/`: Grafana可视化工具管理脚本

#### storage/ (存储系统)
- `minio/`: MinIO对象存储管理脚本
  - `install.sh`: MinIO安装脚本
  - `start.sh`: MinIO启动脚本
  - `stop.sh`: MinIO停止脚本
- `es/`: Elasticsearch搜索引擎管理脚本

#### network/ (网络工具)
- `frp/`: 内网穿透工具FRP管理脚本
- `openvpn/`: OpenVPN管理脚本
- `shadowsocks/`: Shadowsocks代理工具管理脚本

#### cicd/ (持续集成/持续部署)
- `jenkins/`: Jenkins CI/CD管理脚本
  - `startAll.sh`: 批量启动所有应用服务（仅用于开发、测试环境）
  - `killAll.sh`: 批量停止所有应用服务（仅用于开发、测试环境）
  - `jenkins-build.sh`: Jenkins构建脚本
  - `deploy.sh`: 自动发布部署脚本
    - 用法: `./deploy.sh [环境] [应用名] [IP]`
  - `deploy_docker.sh`: Docker环境部署脚本

#### system/ (系统管理)
- `os/`: 通用系统操作脚本
  - `ip.sh`: 获取本机IP、扫描网段、查询公网IP等网络管理脚本
    - 用法: `ip.sh [OPTIONS]` 如 `-p` 获取公网IP，`-s` 扫描网段
  - `install-hosts-font.sh`: 在CentOS/RHEL系统上安装中文字体
    - 用法: `sudo ./install-hosts-font.sh`
  - 其他系统管理脚本
- `teamview/`: TeamViewer远程桌面管理

#### messaging/ (消息队列)
- `activemq/`: ActiveMQ消息队列管理脚本
- `rocketmq/`: RocketMQ消息队列管理脚本
  - 包含 install.sh, os.sh 等管理脚本
  - 包含各种启动、停止和管理脚本

#### security/ (安全工具)
- `certs/`: 证书管理脚本
- `druid/`: Druid数据库密码加密脚本
- `goproxy/`: Go代理工具
- `dependency-track/`: 依赖组件安全检查工具
- `cobalt/`: Cobalt渗透测试工具

#### automation/ (自动化工具)
- `ansible/`: Ansible自动化运维工具
- `gitlab/`: GitLab管理脚本

#### transaction/ (分布式事务)
- `seata/`: Seata分布式事务管理
  - `bin/`: Seata启动和管理脚本
  - `lib/`: Seata依赖库

#### traffic-control/ (流量控制)
- `sentinel-dashboard/`: Sentinel流量控制面板
  - `bin/`: Sentinel启动和管理脚本

#### php/ (PHP环境)
- `install.sh`: PHP环境安装脚本
- `uninstall.sh`: PHP环境卸载脚本
- `Dockerfile`: PHP环境Docker镜像构建文件
- `docker-compose.yml`: PHP环境Docker Compose配置

#### tools/ (通用工具)
- `arthas/`: Arthas Java诊断工具
- `ffmpeg/`: FFmpeg音视频处理工具
- `selenium/`: Selenium自动化测试工具
- `locust/`: Locust性能测试工具
- `wrk/`: WRK网络压测工具
- `sonarqube/`: SonarQube代码质量检测
- `viper/`: Viper配置管理工具
- `webTest/`: Web测试工具
- `ide/`: IDE开发工具
  - `install-cursor.sh`: Cursor IDE安装脚本
  - `install-watt-toolkit.sh`: Watt Toolkit安装脚本
- `beyond4.sh`: Beyond Compare安装脚本
- `gh-proxy/`: GitHub代理工具
- `docker/`: Docker相关管理脚本
- `beyond4/`: Beyond Compare文件对比工具

### 中间件管理脚本通用结构

每个中间件都有标准化的脚本组织方式，典型的结构如下：

```
<middleware>/
├── bin/
│   ├── install.sh       # 安装脚本
│   ├── startup.sh       # 启动脚本（会先检查是否已安装，未安装会先安装）
│   ├── stop.sh          # 停止脚本
│   └── common.sh        # 通用函数库
```

### 支持的安装模式

- **主机安装模式**: 直接在宿主机安装
  - 支持在线安装（需要互联网连接）
  - 支持离线安装（需预先准备好/opt/softs目录下的离线安装包）
- **Docker-Compose模式**: 使用容器化部署（需要互联网连接）

### 脚本编写规范

- 脚本第一行声明命令解释器，默认使用 `#!/bin/bash`
- 脚本第二行注释说明具体用途和调用参数（如有，每个参数的含义、是否可选、是否有默认值）
- 脚本公共变量统一声明，命名简洁易懂并要有简洁的注释说明，其中可能变更的变量靠前
- 参数校验（如有）、检查（系统、用户、权限、目录等）
- 函数或过程按功能分段实现，尽量以函数形式复用
- 脚本必须在开发或测试环境测试验证后，才能用于正式环境
- 需充分考虑异常情况，比如不可见字符或变量为空，特别是涉及删除命令中包含变量，变量可能为空的情况，如 `rm -rf $log_dir/*`，当 `log_dir` 为空时，会造成运维事故

## TODO

1. 编写集成自动化脚本，调用各中间件脚本（自动化安装、配置、启动）
2. 部分中间件未编写初始配置自启动服务
3. 中间件需支持主机和docker-compose 2种模式，其中主机模式需支持在线和离线安装2种模式
4. 完善各脚本的参数说明文档
5. 增加更多中间件管理脚本