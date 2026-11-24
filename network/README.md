# 网络工具集

> 网络代理、VPN、远程访问和网络相关工具的安装与配置脚本

## 📋 目录说明

| 目录/文件 | 说明 | 功能 |
|------|------|------|
| `frp/` | FRP 反向代理 | 内网穿透、远程访问 |
| `openvpn/` | OpenVPN | 安全 VPN 连接 |
| `shadowsocks/` | Shadowsocks | 科学上网代理 |
| `tools/` | 网络工具集 | 测速、扫描、代理、DNS、TCP 调优等 |
| `tools/net_proxy.sh` | 代理环境变量 | 设置/取消 shell 的 `HTTP(S)_PROXY`，并把 `NO_PROXY` 直连例外（默认值 + `~/.net_proxy/no_proxy`）写进 `~/.zshrc` |
| `clashx-meta/clashx-meta.sh` | ClashX Meta | macOS 代理客户端安装、更新、卸载 |
| `update-proxy-nodes.sh` | 免费代理节点维护 | 拉取免费订阅（Clash YAML 或链接列表均可，自动转换），逐个真实握手测活，按 `<配置名>.state.json` 履历增删节点：暂时挂了的保留观察、从没用过的当新面孔保留、连败满 3 轮**并且**失效满 3 天（`--keep-fails` / `--keep-hours`）或上游下架满 3 天的才删除、通过率骤降时判定为本机出网问题本轮不判；默认生成独立 profile `free-nodes.yaml`，`--inject` 改写主配置托管区块，`--no-test` 跳过测活；自动探测 ClashX Meta / Clash Verge Rev / 独立 mihomo 的配置目录和 API 端口，`--client` 可强制指定；生成的配置国内域名与地址一律 DIRECT，`--extra-direct` 再追加自定义直连域，`--proxy-only`/`--extra-proxy` 可改成只代理点名的类别；节点先按状态分层（测通 > 本轮不判 > 观察期 > 源未拉到 > 新面孔），同层内亚洲靠前、同国聚拢、组内按延迟；定时任务用 `--install-schedule` / `--remove-schedule` / `--schedule-status` 装卸，默认每 6 小时一次且不落日志 |
| `publish-dev-https.sh` | 开发环境 HTTPS 发布 | 通过 nginx + 可选 frp 发布服务并申请证书 |
| `register-domain.sh` | 域名注册 | 域名注册/购买脚本 |
| `find_ports.sh` | 端口查找 | 查找占用端口的进程 |
| `ssh-key-setup.sh` | SSH 密钥配置 | 配置免密登录，自动探测 22/2222 端口 |
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
cd network/clashx-meta
./clashx-meta.sh              # 安装；已安装则更新
./clashx-meta.sh uninstall    # 卸载软件，保留用户配置
./clashx-meta.sh purge        # 完全卸载
```

### 免费代理节点维护

```bash
cd network
./update-proxy-nodes.sh --dry-run          # 先看本轮会怎么写，不动任何文件
./update-proxy-nodes.sh                    # 拉订阅 + 测活 + 按履历增删，生成 free-nodes.yaml
./update-proxy-nodes.sh --install-schedule # 装定时任务（默认每 6 小时：01:30/07:30/13:30/19:30）
./update-proxy-nodes.sh --schedule-status  # 看当前装没装、下次几点跑
./update-proxy-nodes.sh --remove-schedule  # 取消定时任务
./update-proxy-nodes.sh --proxy-only        # 白名单模式：只有非大陆域名和点名类别走节点
./update-proxy-nodes.sh --prefer JP,KR,SG   # 点名国家提到同一层最前
./update-proxy-nodes.sh --per-country 3     # 同一国家先只排 3 个（默认 5，0 为不限）
./update-proxy-nodes.sh --keep-new 5        # 从没用过的节点多观察几轮（默认 3，0 为一轮就删）
./update-proxy-nodes.sh --keep-hours 168    # 失效满 7 天才允许删（默认 72 小时＝3 天，0 为只看轮数）
```

客户端目录和 API 端口由脚本探测（ClashX Meta → Clash Verge Rev → 独立 mihomo，按存在顺序取第一个），
`--client meta|verge|mihomo` 可强制指定；`--config` 指定目标配置，`--inject` 改为往主配置写托管区块，
`--no-test` 跳过测活。生成配置里的分流规则是「private/cn 的域名和地址一律 DIRECT，其余走节点」，
所以国内访问与节点死活无关，`--extra-direct example.com` 可以再加自己指定的直连域。
节点排序先分层再按地区：本轮测通的在最前，其次是不予判定的、观察期的、这次没从源里拉到的、从没用过的新面孔；
同一层内亚洲靠前（中国/港澳/台湾 → 东亚 → 东南亚 → 南亚中东中亚 → 欧洲 → 北美 → 南美 → 大洋洲 → 非洲 → 未知）、
同一个国家排在一起、组内按延迟。同一国家默认最多先排 5 个（`--per-country`，超出的补在本层末尾、不会丢），
`--prefer JP,KR,SG` 可以点名把某些国家提到最前——但只在同一层内提权，不会让没测通的节点盖过测通的。
地区来自节点名：先认国旗 emoji（`🇯🇵JP-1.2.3.4` → JP，聚合源里九成以上是这种写法），再看两位 ISO 前缀
（`US - xxx`），再拿中文国名反查（`意大利-1.2.3.4` → IT，`伊朗+xxx` → IR），最后兜底认国内省市名
（`广东省广州市+华为云`、`上海电信` → CN），认不出来的记 `XX` 排在地区序最末。
测活地址默认 `https://www.google.com/generate_204`（`--health-url` / `PROXY_NODES_HEALTH_URL` 可改），
**必须是「只有出境才连得上」的地址**：早先用 `http://cp.cloudflare.com/generate_204`，免费池里那批中国
出口节点（`广东省广州市+华为云` 这种）也能拿到 204 被判「测通」，自动组选中它们之后 Google/OpenAI 一个都
打不开——「节点明明测通却上不了网」就是这么来的。改完之后最快 881ms，这个数才是真实出境延迟。
standalone 模式下不再从自己的配置里回读 `test-url`（那会让上一轮的地址永久生效），只有 `--inject`
沿用宿主配置的 `test-url`。
删除有两个门槛：连续失败满 `--keep-fails` 轮**并且**已经无效满 `--keep-hours` 小时（默认 72＝3 天），
只满足一个都不删。只按轮数删会把观察期绑死在定时频率上——每 6 小时一轮时 3 轮才 18 小时，改成每小时
一轮就只剩 3 小时，节点会被过早清空；按时长才真正保证「一个节点至少被观察 3 天」。无效时长按最后一次
测通的时刻算，从没测通过的按第一次见到的时刻算。上游这次没列出的节点也要满同一时长才按下架删掉，
免得某个源漏列一次就把还能用的节点清光。`--keep-hours 0` 退回只看轮数。
从没用过的节点不再一轮就删，而是标着「（没用过）」垫在菜单最末观察 `--keep-new` 轮：免费源整池通过率
只有百分之几，一轮就删会让菜单只剩十几条，观察期里的亚洲节点也就没有第二次机会被测到。
这些新面孔只进「节点选择」手动菜单，不进「免费节点」自动测速组——客户端每 `interval` 秒要把组内每个节点
重测一遍，把几十个没验证过的候选塞进去等于成倍放大探针流量。
菜单默认最多 120 条（`--max-nodes`，0 为不限）：名额从上往下按层填，放宽到 3 天删除后「暂时不通」
一层会多占位置，只给 60 条的话新面孔会被挤光，等于又回到菜单只剩十几条。
同名不同服在免费池里很常见（多个源都写「俄罗斯+V2CROSS.COM」这种标签），而去重是按指纹去的，
撞名会让整份配置在 `mihomo -t` 阶段报 `is the duplicate name` 而白跑一轮，所以入选列表最后统一编号
（`名字 #2`）。生成的 profile 里 `tun.enable` 写死 false：ClashX Meta / Clash Verge 有自己的 TUN 开关
并会改写这一段，写 true 只会让裸跑 mihomo 的人没 root 时报错；`dns-hijack` 也修成了 `any:53`
（原先写裸 IP，内核报 `not an ip:port`）。
YAML 型订阅（`proxies:` 区块，AutoMergePublicNodes、yuanhang.yaml 都是这种）按缩进切节点时，
`- ` 开头的行**只有和第一个列表项同缩进才算新节点**：更深的那些是 `alpn:` / `requests:` 之类的嵌套列表，
早先一律当成节点起点，等于把节点拦腰切断，后半截成了没有 `key:` 的孤儿行，整份测活配置在
`mihomo -t` 阶段就报 `Parse config error: yaml: line 2004: could not find expected ':'`，一轮白跑
（上游那条 `- alpn:` / `  - v2rayNplus--v2rayNplus--...` 就是触发点）。删节点自带的 `name:` 行时
也要连着它的多行续行（`name: >-` 那种）一起删，否则同样留下孤儿行。现在抽取后还会做一次结构自检，
顶层出现既不是 `key: 值`、也不是空值 key 后面 `- 项` 的行就丢掉那一个节点（计入 `bad-block`），
最坏只少一个候选，不会再拖垮整轮。

默认源是 6 家（`--source` 一旦使用就整体取代默认列表）：zhuhaiuk/free-nodes、PuddinCat/BestClash、
mahdibland/V2RayAggregator、Pawdroid/Free-servers，加上 2026-11-02 实测后补的
[ClashX-V2Ray-TopFreeProxy](https://github.com/VPN-Subcription-Links/ClashX-V2Ray-TopFreeProxy)
和 [ermaozi/get_subscribe](https://github.com/ermaozi/get_subscribe)。挑源只看一个指标：**用出境测活地址
实测的测通数**，不是仓库 star 数。当天四轮 `--dry-run` 的结果——原四源 230 个候选 15 个测通（最快 787ms）、
[AutoMergePublicNodes](https://github.com/chengaopan/AutoMergePublicNodes) 单跑 137/9（最快 912ms，
与四源合并后仍是 14~15 个测通，净新候选约 79 条，只会加宽备用池、不会变快，所以没进默认列表）、
TopFree 单跑 2713/40（最快 **253ms**，是免费池里第一次出现三位数延迟）、ermaozi 298/17、
[awesome-vpn](https://github.com/awesome-vpn/awesome-vpn) 50/1（净增 49 条只 1 个测通，性价比不及成本，也没加）。
八个源合并 2936 个候选、45 个测通、`mihomo -t` 通过、菜单仍按 `--max-nodes 120` 截断，一轮约 6 分半
（原四源 1 分半）。TopFree 自己 `health.json` 里 `connectivity_tested: false`——它只做过引擎校验、
没测过连通性，所以它的「健康」标记不能当数，出境可达性一律由本脚本的隔离内核重测。
新源排在默认列表最后是有意的：同名节点的显示名由先列出的源决定，放后面不会改动现有节点的叫法。
[free-nodes/clashfree](https://github.com/free-nodes/clashfree) 不要接：`clash20261030.yml` 之后每天的文件
都是 0 字节、文件名带日期没法固定 URL，节点还写成 `- {name: …, server: 192.0.2.1, port: 1, …}` 这种
flow 单行 + 占位假端点（抽取器整份识别不了，现在统一按 `bad-block` 丢弃）。

「哪些需要代理」在 profile 里也能显式指定：默认是「内网+国内直连，其余走节点」，
加 `--proxy-only` 换成白名单模式（只有 `geolocation-!cn` 和 google/github/telegram/openai/category-ai-!cn
这些类别走节点，`MATCH` 兜底 DIRECT）；`--extra-proxy 域名` 点名的域排在 cn 规则之前（`.cn` 里想代理的站
也能拉回隧道），`--extra-direct 域名` 点名的域永远直连。类别名由内核在 `mihomo -t` 阶段校验，本地
`geosite.dat` 缺哪个会直接报错，不会静默失效。
`--extra-direct` 还会自动读 `~/.net_proxy/no_proxy`（去掉网段和 IPv6，剩下的域名后缀逐条展开成
`DOMAIN-SUFFIX,域名,DIRECT`），和 `net_proxy.sh` 共用同一份例外清单：命令行侧靠它拼进 `NO_PROXY`，
profile 侧靠它兜住「国内但 `GEOSITE` 没认出来」的域名。连接表里确实抓到过这种漏网域名——
`openapi.qoder.sh` / `api1.qoder.sh` 落到 `MATCH` 绕了境外节点（改动前 `Match→意大利`，改动后
`DomainSuffix/qoder.sh→DIRECT`），而淘宝/字节/阿里/千问系基本被 `GEOSITE,cn` 收走，
`mmstat.com`、`volces.com` 这类 `.com`/国产 CDN 也被 `GEOIP,CN` 或 `GEOSITE,cn` 兜住，
所以绝大多数国内站不需要逐条配。
**别拿耗时差判定绕道**：`api.deepseek.com`、`www.doubao.com`、`sf3-fe.tos-cn-beijing.volces.com` 走 7890 时
分别慢 0.1s/0.16s/0.8s，看着像绕路，实际新旧配置都命中 `GeoSite/cn → DIRECT`——差的是 mihomo 用国内 DoH
解析到的 CDN 边缘节点不同。要拿证据只看连接表：
`curl -s http://127.0.0.1:9090/connections`，每个连接带 `rule` / `rulePayload` / `chains`，
短连接来不及抓就用 `CONNECT 域名:443` 把连接挂住再查（脚本的测活内核同样适用这招）。
确认漏配就往 `~/.net_proxy/no_proxy` 补一行，再跑 `net_proxy.sh -s` 和这个脚本。

命令行侧的直连例外由 `tools/net_proxy.sh` 维护（见下一小节），和 profile 规则是两层：profile 规则决定
已经进了代理的流量怎么走，`NO_PROXY` 决定哪些地址根本不进代理——后者在代理客户端整个退出时依然有效。
勾选「设置为系统代理」不会让国内站变慢：命中 `GEOSITE,cn`/`GEOIP,CN`/例外域名的流量仍从本机出去，
实测代价只是一个本地回环（±0.05s），而且 profile 的 DNS 是 fake-ip + `fake-ip-filter: +.cn, +.com.cn`，
解析用的也是国内 DoH。

定时任务由脚本生成 plist（label `com.mac.proxy-nodes-refresh`）并 `launchctl bootstrap`，
标准输出和错误都指向 `/dev/null`，不落日志文件；到点在睡眠则唤醒后补跑，要在终端看过程就手动执行脚本。
客户端不会自动重载配置，跑完需要在客户端里手动点一次重载（`--reload` 只在显式带上时尽力而为）。

### 代理环境变量与直连例外

```bash
cd network/tools
./net_proxy.sh -s          # 设置代理，同时把 NO_PROXY 例外写进 ~/.zshrc
./net_proxy.sh -v          # 查看当前代理和例外
./net_proxy.sh -u          # 取消（NO_PROXY 一并删除）
echo '.example.com' >> ~/.net_proxy/no_proxy && ./net_proxy.sh -s   # 给自己加一条直连域
```

`NO_PROXY` 的取值 = 脚本里的 `DEFAULT_NO_PROXY`（本机地址 + `.cn` / `.com.cn`）合并 `~/.net_proxy/no_proxy`
（一行一个域名后缀，`#` 开头是注释；首次 `-s` 会自动放一份起点内容）。例外列表刻意保持短：国内站点的长尾
由 Clash 的 `GEOSITE,cn` / `GEOIP,CN` 规则负责直连，写到 shell 层只是为了「客户端没起来也必须连得上」的
那几个地址（Qoder 域名、自建服务、内网网段）。往里加域之前先 `curl --noproxy '*' https://该域/` 验一下，
直连不通的域千万别写——那等于把它从代理里踢出去打死。内网**只写网段、不写单个 IP**（`192.168.1.0/16`
而不是 `192.168.1.44`）：curl 8.x 实测认 CIDR，Node（undici）不认但只是当不匹配、不会报错，而不认网段的
工具在客户端开着时由 profile 的 `GEOSITE,private` + `GEOIP,private` 兜住，客户端退出后根本没有代理，
两边都不需要再手工维护一份 IP 清单。主机名（`/etc/hosts` 里的 `redis-server` 这类）不受网段管辖，要单独列。
`-s` 每次先把 rc 里所有
`export *_PROXY` 行删掉再重写，手工加在 `~/.zshrc` 里的例外会被覆盖，想长期保留就写进 `~/.net_proxy/no_proxy`。

### 网络工具（SSH / hosts / VPN / 唤醒）

```bash
cd network
./ssh-key-setup.sh            # 配置 SSH 免密登录，自动探测 22；失败后尝试 2222
./ssh-key-setup.sh -h 192.168.0.105 -u sky -p 2222
./ssh-exec-remote.sh          # 远程执行命令（支持密钥/密码认证）
./update-hosts.sh             # 下载更新 /etc/hosts 并配置每小时定时任务
./set-hosts-aliases.sh        # 将主机名别名指向本机 IP（需 root）
./vpn.sh                      # openconnect VPN 连接（凭据通过环境变量提供）
./wol.sh                      # Wake-on-LAN 远程开机
./find_ports.sh               # 查找占用端口的进程
./install-hosts-font.sh       # CentOS/RHEL 安装中文字体
```

`ssh-key-setup.sh` 的交互式端口探测顺序为：先检查 22 端口；22 不通时确认主机在线，再检查 2222；两个端口都不可用时提示输入自定义端口。命令行显式传入 `-p/--port` 时，以指定端口为准。
如果 `~/.ssh/config` 中已经存在同名 Host，脚本会备份并更新该 Host 的用户名和端口，不会继续沿用旧配置。

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
