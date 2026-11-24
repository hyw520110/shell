# Locust 性能测试

> Locust 分布式负载测试工具

## 📋 目录说明

| 脚本文件 | 说明 | 版本检测 | 帮助函数 |
|---------|------|---------|---------|
| `run_bench.py` | Locust 性能测试运行器 | ❌ | ❌ |
| `distributedbench.py` | 分布式性能测试 | ❌ | ❌ |
| `config.py` | 配置管理 | ❌ | ❌ |
| `docker-compose.yml` | Docker 部署配置 | - | - |
| `Dockerfile` | Docker 镜像构建 | - | - |

## 🚀 快速开始

### 使用 Docker 部署

```bash
cd locust
docker-compose up -d
```

### 运行性能测试

```bash
cd locust
python3 run_bench.py
```

## 🔧 详细说明

### 功能特性

**性能测试**:
- HTTP/HTTPS 协议支持
- 分布式执行
- 实时监控
- 报告生成

**测试场景**:
- 负载测试
- 压力测试
- 稳定性测试
- 容量测试

**监控指标**:
- RPS (每秒请求数)
- 响应时间
- 错误率
- 用户并发数

### 访问界面

- **Locust 控制台**: http://localhost:8089
- **测试报告**: 自动生成 HTML 报告

## 🔗 相关链接

- [Locust 官方网站](https://locust.io/)
- [Locust 文档](https://docs.locust.io/)

## 📝 使用场景

- **负载测试**: 测试系统承载能力
- **压力测试**: 发现系统性能瓶颈
- **稳定性测试**: 长时间运行测试
- **性能优化**: 优化系统性能