# WRK 压力测试

> WRK 现代化 HTTP 压力测试工具

## 📋 目录说明

| 目录 | 说明 |
|------|------|
| `bin/` | 二进制文件目录 |

## 🚀 快速开始

### 使用 WRK

```bash
cd wrk
./bin/wrk -t12 -c400 -d30s http://127.0.0.1:8080/index.html
```

## 🔧 详细说明

### WRK 特点

**性能测试**:
- 单线程多连接
- 多线程并发
- HTTP/HTTPS 支持
- 实时统计

**测试参数**:
- 线程数 (-t)
- 连接数 (-c)
- 测试时长 (-d)
- 延迟时间 (-s)
- 请求超时 (-T)

**输出指标**:
- 每秒请求数 (Requests/sec)
- 平均延迟 (Latency)
- 传输速率 (Transfer/sec)

### 使用示例

```bash
# 基础测试
./bin/wrk -t4 -c100 -d30s http://example.com/

# 使用 Lua 脚本
./bin/wrk -t4 -c100 -d30s -s script.lua http://example.com/

# POST 请求
./bin/wrk -t4 -c100 -d30s --latency -s post.lua http://example.com/
```

## 🔗 相关链接

- [WRK GitHub](https://github.com/wg/wrk)

## 📝 使用场景

- **负载测试**: HTTP 服务负载测试
- **性能基准**: 性能基准测试
- **压力测试**: 极限压力测试
- **性能优化**: 性能优化验证