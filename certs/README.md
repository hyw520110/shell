# 证书管理

> SSL/TLS 证书和数字证书的生成和管理脚本

## 📋 目录说明

| 脚本文件 | 说明 | 版本检测 | 帮助函数 |
|---------|------|---------|---------|
| `ca.sh` | CA 证书生成脚本 | ❌ | ❌ |

## 🚀 快速开始

### 生成 CA 证书

```bash
cd certs
./ca.sh
```

## 🔧 详细说明

### ca.sh - CA 证书生成脚本

**功能**: 生成自签名 CA 证书和客户端证书

**证书类型**:
- CA 根证书
- 服务器证书
- 客户端证书
- 中间证书

**使用场景**:
- HTTPS 服务
- 双向认证
- 内网安全通信
- 开发测试环境

**证书格式**:
- PEM 格式
- DER 格式
- PKCS#12 格式
- JKS 格式

**常用命令**:
```bash
# 生成私钥
openssl genrsa -out private.key 2048

# 生成证书签名请求
openssl req -new -key private.key -out csr.csr

# 生成自签名证书
openssl x509 -req -days 365 -in csr.csr -signkey private.key -out certificate.crt

# 查看证书信息
openssl x509 -in certificate.crt -text -noout
```

## 🔗 相关链接

- [OpenSSL 官方网站](https://www.openssl.org/)
- [Let's Encrypt](https://letsencrypt.org/)

## 📝 使用场景

- **HTTPS 服务**: Web 服务器 SSL 证书
- **双向认证**: 客户端和服务器双向认证
- **内网通信**: 内网服务安全通信
- **开发测试**: 开发环境证书配置