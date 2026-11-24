# Druid 密码工具

> Apache Druid 数据库密码加密工具

## 📋 目录说明

| 脚本文件 | 说明 | 版本检测 | 帮助函数 |
|---------|------|---------|---------|
| `druid_encrypt_pwd.sh` | Druid 密码加密脚本 | ❌ | ❌ |

## 🚀 快速开始

### 加密 Druid 密码

```bash
cd druid
./druid_encrypt_pwd.sh
```

## 🔧 详细说明

### druid_encrypt_pwd.sh - 密码加密脚本

**功能**: 为 Apache Druid 数据库连接配置生成加密密码

**加密算法**:
- AES 加密
- Base64 编码
- 随机密钥生成

**使用场景**:
- 数据库连接密码加密
- 配置文件安全
- 敏感信息保护

**配置示例**:
```bash
# 加密密码
./druid_encrypt_pwd.sh "your_password"

# 输出加密后的密码和密钥
```

## 🔗 相关链接

- [Apache Druid 官方网站](https://druid.apache.org/)
- [Druid 文档](https://druid.apache.org/docs/latest/)

## 📝 使用场景

- **密码加密**: Druid 数据库连接密码加密
- **配置安全**: 配置文件敏感信息保护
- **安全合规**: 满足安全合规要求
- **部署自动化**: 自动化部署密码管理