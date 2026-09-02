# SQLMap SQL 注入测试

> SQL 注入漏洞检测和利用工具

## 📋 目录说明

| 脚本文件 | 说明 | 版本检测 | 帮助函数 |
|---------|------|---------|---------|
| `../security/web-security/install-sqlmap.sh` | SQLMap 安装、更新、状态和授权测试脚本 | ✅ | ✅ |

## 🚀 快速开始

### 安装 SQLMap

```bash
bash security/web-security/install-sqlmap.sh install
```

## 🔧 详细说明

### install-sqlmap.sh - SQLMap 安装、更新与授权测试脚本

**功能**: 安装、更新、卸载 SQLMap，并对已授权目标执行基础或专项测试

```bash
bash security/web-security/install-sqlmap.sh install
bash security/web-security/install-sqlmap.sh test 'https://授权目标.example/item?id=1'
bash security/web-security/install-sqlmap.sh status
bash security/web-security/install-sqlmap.sh uninstall
```

**SQLMap 特点**:
- 自动化 SQL 注入检测
- 支持多种数据库
- 强大的指纹识别
- 丰富的绕过技术

**支持数据库**:
- MySQL
- PostgreSQL
- Oracle
- SQL Server
- SQLite
- 等多种数据库

**检测技术**:
- 基于布尔盲注
- 基于时间盲注
- 基于错误注入
- 联合查询注入
- 堆叠查询注入

## 🔗 相关链接

- [SQLMap 官方网站](http://sqlmap.org/)
- [SQLMap GitHub](https://github.com/sqlmapproject/sqlmap)

## 📝 使用场景

- **安全测试**: Web 应用 SQL 注入漏洞检测
- **渗透测试**: 自动化渗透测试
- **漏洞扫描**: 大规模漏洞扫描
- **安全审计**: 代码安全审计

**注意**: 本工具仅用于合法的安全测试和授权的渗透测试，禁止用于非法用途。
