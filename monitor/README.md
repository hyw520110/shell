# 监控系统管理脚本

> 应用和系统监控的自动化安装、配置和管理工具

## 📋 目录说明

| 监控工具 | 功能 | 安装脚本 | 版本检测 | 帮助函数 |
|----------|------|----------|---------|---------|
| **Prometheus** | 指标收集和存储 | ✅ | ❌ | ❌ |
| **Grafana** | 数据可视化 | ✅ | ❌ | ❌ |

## 🚀 快速开始

### 完整监控栈安装

```bash
# 1. 安装 Prometheus
cd monitor/prometheus
./bin/install.sh

# 2. 安装 Grafana
cd ../grafana
./install.sh

# 3. 访问监控界面
# Prometheus: http://localhost:9090
# Grafana: http://localhost:3000 (默认用户名/密码: admin/admin)
```

## 🔧 详细说明

### 1. Prometheus

**功能**: 开源监控和警报系统

**特点**:
- 时间序列数据库
- 多维数据模型
- 灵活的查询语言
- 强大的警报系统
- 服务发现机制

**适用场景**:
- 应用监控
- 系统监控
- 性能分析
- 告警通知

**目录结构**:
```
prometheus/
├── bin/                 # 管理脚本
├── conf/                # 配置文件
└── docker-compose.yml   # Docker 部署配置
```

**常用操作**:
```bash
# 安装 Prometheus
cd prometheus
./bin/install.sh

# 启动 Prometheus
./bin/startup.sh

# 停止 Prometheus
./bin/stop.sh

# 查看状态
./bin/status.sh

# 查询指标
# 访问 http://localhost:9090
# 查询示例: up{job="node_exporter"}
```

**配置文件**:
```yaml
# prometheus.yml
global:
  scrape_interval: 15s
  evaluation_interval: 15s

scrape_configs:
  - job_name: 'prometheus'
    static_configs:
      - targets: ['localhost:9090']

  - job_name: 'node_exporter'
    static_configs:
      - targets: ['localhost:9100']

alerting:
  alertmanagers:
    - static_configs:
        - targets: ['localhost:9093']
```

### 2. Grafana

**功能**: 开源分析和可视化平台

**特点**:
- 丰富的仪表盘
- 多种数据源支持
- 灵活的查询编辑器
- 警报和通知
- 用户权限管理

**适用场景**:
- 数据可视化
- 监控仪表盘
- 性能分析
- 业务监控

**目录结构**:
```
grafana/
└── install.sh          # 安装脚本
```

**常用操作**:
```bash
# 安装 Grafana
cd grafana
./install.sh

# 启动 Grafana
systemctl start grafana

# 停止 Grafana
systemctl stop grafana

# 访问界面
# http://localhost:3000
# 默认用户名: admin
# 默认密码: admin
```

**配置 Prometheus 数据源**:
1. 访问 Grafana 界面
2. 进入 Configuration > Data Sources
3. 添加 Prometheus 数据源
4. 配置 URL: `http://localhost:9090`
5. 点击 "Save & Test"

## 📊 监控架构

### 完整监控栈

```
应用程序
    ↓ (暴露指标)
Prometheus (采集和存储)
    ↓ (查询)
Grafana (可视化)
    ↓ (告警)
AlertManager (通知)
    ↓
通知渠道 (邮件、钉钉、微信等)
```

### 数据流程

1. **指标采集**: 应用程序暴露 HTTP 指标端点
2. **数据收集**: Prometheus 定期拉取指标数据
3. **数据存储**: 时间序列数据库存储
4. **数据查询**: PromQL 查询语言
5. **数据展示**: Grafana 仪表盘可视化
6. **告警触发**: 规则引擎检测异常
7. **通知发送**: AlertManager 发送告警

## ⚙️ 环境配置

### Prometheus 配置

**基础配置**:
```yaml
global:
  scrape_interval: 15s
  evaluation_interval: 15s
  external_labels:
    cluster: 'production'
    replica: '1'

scrape_configs:
  - job_name: 'node_exporter'
    static_configs:
      - targets: ['localhost:9100']
    relabel_configs:
      - source_labels: [__address__]
        target_label: __param_target
      - source_labels: [__param_target]
        target_label: instance
      - target_label: __address__
        replacement: 'localhost:9100'
```

**告警规则**:
```yaml
groups:
  - name: node_alerts
    interval: 30s
    rules:
      - alert: HighCPUUsage
        expr: 100 - (avg by (instance) (rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100) > 80
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "High CPU usage detected"
          description: "CPU usage is above 80% for 5 minutes"
```

### Grafana 配置

**数据源配置**:
```json
{
  "name": "Prometheus",
  "type": "prometheus",
  "url": "http://localhost:9090",
  "access": "proxy",
  "isDefault": true
}
```

**仪表盘配置**:
```json
{
  "dashboard": {
    "title": "System Monitor",
    "panels": [
      {
        "title": "CPU Usage",
        "targets": [
          {
            "expr": "100 - (avg by (instance) (rate(node_cpu_seconds_total{mode=\"idle\"}[5m])) * 100)"
          }
        ]
      }
    ]
  }
}
```

## 🔗 相关链接

### 官方网站
- [Prometheus 官方网站](https://prometheus.io/)
- [Grafana 官方网站](https://grafana.com/)
- [Node Exporter](https://github.com/prometheus/node_exporter)
- [AlertManager](https://prometheus.io/docs/alerting/latest/alertmanager/)

### 文档资源
- [Prometheus 文档](https://prometheus.io/docs/)
- [Grafana 文档](https://grafana.com/docs/)
- [PromQL 文档](https://prometheus.io/docs/prometheus/latest/querying/basics/)
- [Grafana 官方仪表盘](https://grafana.com/grafana/dashboards/)

### 社区资源
- [Prometheus 社区](https://prometheus.io/community/)
- [Grafana 社区](https://community.grafana.com/)
- [Grafana Labs 插件](https://grafana.com/plugins/)

## ❓ 常见问题

### Q: 如何选择合适的监控方案？

**A**: 根据需求选择：

- **基础监控**: Prometheus + Grafana
- **日志监控**: ELK Stack
- **APM 监控**: SkyWalking
- **链路追踪**: Zipkin, Jaeger

### Q: 如何采集自定义指标？

**A**: 自定义指标采集：

```java
// Java 应用暴露指标
import io.prometheus.client.Counter;
import io.prometheus.client.exporter.HTTPServer;

public class Application {
    static final Counter requests = Counter.build()
        .name("requests_total")
        .help("Total requests.")
        .register();

    public static void main(String[] args) throws Exception {
        HTTPServer server = new HTTPServer(8080);
        server.start();
        
        // 使用指标
        requests.inc();
    }
}
```

### Q: 如何配置告警通知？

**A**: 告警配置：

```yaml
# AlertManager 配置
route:
  group_by: ['alertname', 'cluster', 'service']
  group_wait: 10s
  group_interval: 10s
  repeat_interval: 12h
  receiver: 'default-receiver'

receivers:
  - name: 'default-receiver'
    email_configs:
      - to: 'admin@example.com'
    webhook_configs:
      - url: 'http://localhost:5000/webhook'
```

### Q: 如何优化存储空间？

**A**: 存储优化：

```yaml
# Prometheus 存储配置
storage:
  tsdb:
    retention.time: 30d
    retention.size: 10GB
```

### Q: 如何监控 Docker 容器？

**A**: Docker 监控：

```yaml
# cAdvisor 配置
scrape_configs:
  - job_name: 'cadvisor'
    static_configs:
      - targets: ['localhost:8080']
```

## 📝 最佳实践

### 指标命名规范

```yaml
# 推荐的命名格式
<metric_name>{<label_name>="<label_value>", ...}

# 示例
http_requests_total{method="GET", endpoint="/api/users"}
node_memory_usage_bytes{instance="localhost:9100"}
```

### 告警规则设计

```yaml
# 告警级别
severity: critical  # 严重，需要立即处理
severity: warning   # 警告，需要关注
severity: info      # 信息，记录即可

# 告警条件
- alert: HighErrorRate
  expr: rate(http_requests_total{status="500"}[5m]) > 0.1
  for: 5m
  annotations:
    summary: "High error rate detected"
    description: "Error rate is above 10% for 5 minutes"
```

### 仪表盘设计

```json
{
  "title": "Application Dashboard",
  "panels": [
    {
      "title": "Request Rate",
      "type": "graph",
      "targets": [
        {
          "expr": "rate(http_requests_total[5m])"
        }
      ]
    },
    {
      "title": "Error Rate",
      "type": "stat",
      "targets": [
        {
          "expr": "rate(http_requests_total{status=\"500\"}[5m])"
        }
      ]
    }
  ]
}
```

### 服务发现配置

```yaml
# Consul 服务发现
scrape_configs:
  - job_name: 'consul'
    consul_sd_configs:
      - server: 'localhost:8500'
    relabel_configs:
      - source_labels: [__meta_consul_service]
        target_label: job
```

## 🚧 TODO

- [ ] 为 Prometheus 添加帮助函数和版本检测
- [ ] 为 Grafana 添加帮助函数和版本检测
- [ ] 添加 Node Exporter 安装脚本
- [ ] 添加 AlertManager 安装脚本
- [ ] 添加常用监控模板
- [ ] 添加监控脚本生成工具
- [ ] 添加监控数据备份脚本
- [ ] 添加监控故障恢复指南

## 🤝 贡献

欢迎提交 Issue 和 Pull Request！

## 📄 许可证

本仓库采用 MIT 许可证，详见根目录 LICENSE 文件。