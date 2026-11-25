# SQLMap SQL 注入测试

> SQL 注入漏洞检测和利用工具。仅可用于已授权目标。

## 安装

```bash
# macOS
brew install sqlmap

# Python
python3 -m pip install sqlmap
```

## 基本用法

```bash
sqlmap -u 'https://授权目标.example/item?id=1' --batch
```

## SQLMap 特点

- 自动化 SQL 注入检测
- 支持多种数据库
- 强大的指纹识别
- 丰富的绕过技术

## 支持数据库

- MySQL
- PostgreSQL
- Oracle
- SQL Server
- SQLite
- 等多种数据库

## 检测技术

- 基于布尔盲注
- 基于时间盲注
- 基于错误注入
- 联合查询注入
- 堆叠查询注入

## 相关链接

- [SQLMap 官方网站](http://sqlmap.org/)
- [SQLMap GitHub](https://github.com/sqlmapproject/sqlmap)
