# SkyWalking 监控脚本说明

本目录用于安装 SkyWalking，并把主机、中间件指标接入 SkyWalking。脚本优先按用户目录部署，也可在 CentOS/Ubuntu/macOS 上通过参数指定安装目录。

## 主机监控

`bin/setup-vm-monitoring.sh` 通过 OpenTelemetry Collector 抓取 `node_exporter` 指标，并推送到 SkyWalking OAP。

常用命令：

```bash
./bin/setup-vm-monitoring.sh \
  --host-name "$(hostname)" \
  --service-name "$(hostname)" \
  --node-exporter-target 127.0.0.1:9100 \
  --oap-endpoint 127.0.0.1:11800 \
  -f
```

Linux 主机直接使用 `node_exporter` 原始指标。macOS/Darwin 的 `node_exporter` 内存指标名与 SkyWalking VM 规则不同，脚本默认会启动本地兼容代理，补齐 `node_memory_MemTotal_bytes`、`node_memory_MemAvailable_bytes`、`node_memory_SwapFree_bytes` 等 Linux 风格指标，再交给 OTel Collector 抓取。

主机监控入口在 SkyWalking UI 的 Infrastructure / Linux，不在 General-Service / Services。

## 内存单位优化

`bin/setup-linux-dashboard.sh` 用于优化 OS_LINUX 面板里的内存显示单位。推荐使用 `--unit auto`：总内存达到默认 16GiB 时显示 GB，小机器继续显示 MB，避免大内存主机出现 `75610 MB` 这类难读值。

```bash
./bin/setup-linux-dashboard.sh \
  --skywalking-home "$HOME/skywalking" \
  --unit auto \
  --node-exporter-target 127.0.0.1:9100 \
  --restart
```

如果 macOS 主机启用了兼容代理，也可以把 `--node-exporter-target` 指向代理地址，例如 `127.0.0.1:19100`。脚本会备份并修改：

- `config/ui-initialized-templates/os_linux/linux-service.json`
- `config/application.yml` 中的 `enableUpdateUITemplate` 默认值

默认还会调用 SkyWalking GraphQL `changeTemplate` 更新已有 `Linux-Service` 面板。若当前 OAP 未运行或模板更新开关尚未生效，可加 `--restart` 后重新执行；也可以用 `--no-existing-template-update` 只改初始化模板文件。

## 推荐告警

`bin/setup-recommended-alarms.sh` 会在 `config/alarm-settings.yml` 的 `rules:` 下写入受管告警区块，可重复执行覆盖。默认规则覆盖：

- 主机 CPU 使用率高于 85%
- 主机内存使用率高于 90%
- 主机 Swap 使用率高于 50%
- 文件系统使用率高于 85%
- MySQL 连接占比高于 85%
- MySQL 慢查询速率大于 0/s
- Redis 内存使用率高于 85%
- Redis 阻塞客户端大于 0
- RocketMQ commitLog 磁盘比例高于 85%
- RocketMQ 最大消费延迟高于 60000ms

```bash
./bin/setup-recommended-alarms.sh \
  --skywalking-home "$HOME/skywalking" \
  --restart
```

告警规则可以先配置，但触发告警需要对应指标已经接入。主机依赖 `setup-vm-monitoring.sh`，MySQL 依赖 `setup-mysql-monitoring.sh` 和 `mysqld_exporter`，Redis/RocketMQ 还需要对应 exporter 或 OTel 采集链路。

## 告警通知

SkyWalking 告警触发后通过 `config/alarm-settings.yml` 的 `hooks` 发出通知。通用 webhook 会向配置的 URL 发送 HTTP POST，请求头为 `Content-Type: application/json`，请求体是告警消息数组，常用字段包括：

- `scope` / `scopeId`：告警对象类型
- `name`：告警对象名称，例如主机名或服务名
- `ruleName`：触发的规则名
- `alarmMessage`：告警文本
- `startTime`：告警触发时间戳，毫秒
- `tags`：规则中配置的标签

使用本仓库脚本配置通用 webhook：

```bash
./bin/setup-recommended-alarms.sh \
  --skywalking-home "$HOME/skywalking" \
  --webhook-url http://127.0.0.1:18080/skywalking/alarm \
  --restart
```

多个通知地址可以重复传入：

```bash
./bin/setup-recommended-alarms.sh \
  --webhook-url http://127.0.0.1:18080/skywalking/alarm \
  --webhook-url http://10.0.0.10:18080/skywalking/alarm \
  --restart
```

脚本会生成如下受管配置区块：

```yaml
hooks:
  webhook:
    default:
      is-default: true
      urls:
        - "http://127.0.0.1:18080/skywalking/alarm"
```

`is-default: true` 表示没有单独指定 hook 的告警规则都会发送到这个 webhook。告警配置通常需要重启 OAP 后生效；如果使用 SkyWalking 动态配置中心，动态配置可能覆盖本地 `alarm-settings.yml`。

通用 webhook 适合发给自建通知服务，由该服务再转换成企业微信、钉钉、飞书、邮件或短信格式。企业微信/钉钉/飞书机器人通常不直接兼容 SkyWalking 通用 webhook 的原始告警数组；要直接发机器人，可以手动在 `alarm-settings.yml` 配置 SkyWalking 原生 hook 类型，例如 `wechat`、`dingtalk`、`feishu`，或使用一个轻量中转服务把 SkyWalking payload 转换为机器人要求的消息格式。

最小接收端示例：

```bash
python3 -c 'from http.server import BaseHTTPRequestHandler,HTTPServer
class H(BaseHTTPRequestHandler):
    def do_POST(self):
        n=int(self.headers.get("content-length","0"))
        print(self.rfile.read(n).decode())
        self.send_response(204)
        self.end_headers()
HTTPServer(("0.0.0.0",18080),H).serve_forever()'
```

生产建议使用一个明确处理 `POST /skywalking/alarm` 的服务，并记录请求体、返回 2xx。返回非 2xx 或连接失败时，OAP 日志中会出现 webhook 调用失败信息。

## 验证

检查主机指标：

```bash
curl -fsS http://127.0.0.1:19100/metrics | grep 'node_memory_MemTotal_bytes'
curl -fsS http://127.0.0.1:12800/graphql
```

检查进程：

```bash
ps -ef | grep -E 'skywalking|otelcol|node_exporter' | grep -v grep
```

脚本会为被修改的 SkyWalking 配置文件创建 `.bak.YYYYmmddHHMMSS` 备份。
