# 安全工具集

> 安全扫描、防护和监控工具的安装和配置脚本

## 📋 目录说明

| 目录 | 说明 | 脚本数量 |
|------|------|----------|
| `code-security/` | 代码安全扫描工具 | - |
| `host-security/` | 主机安全加固工具 | - |
| `monitor/` | 安全监控工具 | - |
| `protection/` | 安全防护工具 | - |
| `scanner/` | 漏洞扫描工具 | - |
| `web-security/` | Web 应用安全工具 | - |

## 🚀 快速开始

### 使用安全工具

```bash
cd security
# 根据具体安全需求选择相应工具目录
```

## 🔧 详细说明

### 子目录功能

#### code-security/
**代码安全扫描**
- 静态代码分析
- 依赖漏洞扫描
- 代码质量检查
- 安全合规检查
- Shell 脚本检查可执行: `bash code-security/install-shellcheck.sh`
- Guardrails AI 输出校验/安全门禁: `bash code-security/guardrails-ai.sh install`

#### host-security/
**主机安全加固**
- 系统安全配置
- 防火墙配置
- 用户权限管理
- 审计日志配置

#### monitor/
**安全监控**
- 入侵检测
- 异常行为监控
- 安全日志分析
- 威胁情报收集

#### protection/
**安全防护**
- 入侵防御
- 恶意软件防护
- 数据加密
- 访问控制

#### scanner/
**漏洞扫描**
- 系统漏洞扫描
- 网络漏洞扫描
- Web 漏洞扫描
- 数据库漏洞扫描
- TscanClient/TscanPlus：跨平台资产识别、URL 指纹和低影响 JS 收集

##### TscanPlus/TscanClient

TscanClient 官方提供 macOS Intel/Apple Silicon 与 Linux x64/arm64 构建。仓库内封装脚本：`scanner/tscanplus/tscanplus.sh`。

```bash
# 安装命令行版（默认）
bash scanner/tscanplus/tscanplus.sh install client

# 查看状态
bash scanner/tscanplus/tscanplus.sh status

# 仅运行低影响 URL 指纹 + JS 收集；必须显式确认授权
bash scanner/tscanplus/tscanplus.sh scan-url --ack-authorized https://example.com/

# 可选增加低并发目录枚举
bash scanner/tscanplus/tscanplus.sh scan-url --ack-authorized --include-dir https://example.com/

# 安装 TscanPlus MCP/GUI 版（安装后重启 Codex）
bash scanner/tscanplus/tscanplus.sh install mcp
```

脚本默认不启用 POC、POC 全量、弱口令/爆破、默认口令、全端口、大网段、空间测绘或凭据验证；报告写入 `~/security-scans/tscanplus/`。AI Hub 已增加可选 `tscanplus` Skill 和 `tscanplus` MCP 条目，均为关闭状态，安装/启用前须确认授权范围。

#### web-security/
**Web 应用安全**
- SQL 注入防护
- XSS 攻击防护
- CSRF 攻击防护
- 安全头配置
- Nessus：标准扫描、版本/插件更新，以及 Nessus Expert Web Application Scanning 前置检查
- Nessus 脚本位置：`web-security/nessus/nessus.sh`
- Nuclei：模板化 Web 漏洞扫描、版本/模板更新和 TXT/JSON/Markdown/HTML 报告
- Nuclei 脚本位置：`web-security/nuclei/nuclei.sh`
- SRC 自动扫描编排器：`web-security/nuclei/src-hunter.sh`；按目标表和扫描历史选择下一个目标，生成 Markdown/JSON 报告并调用低影响复核
- SRC 报告分析器：`web-security/nuclei/src-hunter-report.py`
- Katana：授权目标爬取、URL/JSONL 输出和限速控制
- Katana 脚本位置：`web-security/katana/katana.sh`
- OWASP ZAP：官方 Docker 基线扫描（爬取 + 被动分析）和 HTML/JSON/XML 报告
- ZAP 脚本位置：`web-security/zap/zap.sh`
- Burp Suite：Homebrew 安装、GUI/JAR 启动和本地代理配置提示
- Burp 脚本位置：`web-security/burp/burp.sh`
- 其他 Web/代码安全工具：每个工具单独安装，支持 macOS 和常见 Linux 发行版
- Wapiti：`web-security/install-wapiti.sh`
- sqlmap：`web-security/install-sqlmap.sh`
- ffuf：`web-security/install-ffuf.sh`
- Gobuster：`web-security/install-gobuster.sh`
- Schemathesis：`web-security/install-schemathesis.sh`
- testssl.sh：`web-security/install-testssl.sh`
- Semgrep：`web-security/install-semgrep.sh`
- CodeQL CLI：`web-security/install-codeql.sh`

### 文章中的 Skills/MCP 对照

文章引用的 TscanPlus Skill、Code Audit 和 Java Audit Skills 已分别纳入 `ai/conf/shared/skills/`；TscanPlus MCP 已纳入 `ai/conf/shared/mcp-servers/`。SQLMap、Nuclei、ZAP、Burp、Semgrep、CodeQL、Trivy 等当前仓库已有对应脚本或 AI Hub 配置，因此没有重复新增。

CTF/漏洞利用类 Skill、弱口令和主动利用模块没有默认接入公网 SRC 流程；它们适合隔离靶场或明确授权的内部测试，不能由“发现了资产”推定获得授权。文章中提到的 Skills 目录/市场和 Seebug TrustTools 是来源或在线服务，不是可离线安装的本地扫描器，仓库仅保留来源信息，不自动下载或上传数据。

### Web 扫描建议流程

四套工具职责不同，不建议用同一套参数重复高并发扫描：

```bash
# 1. 发现站内链接，默认结果写到仓库外
bash web-security/katana/katana.sh install
bash web-security/katana/katana.sh -u https://example.com/ -d 2 -r 10 -c 5

# 2. 对已授权站点做模板化高危扫描
bash web-security/nuclei/nuclei.sh -l high -u https://example.com/

# 3. 对授权站点做低影响的 ZAP 基线检查
bash web-security/zap/zap.sh install
bash web-security/zap/zap.sh -u https://example.com/ -T 5 -f all

# 4. 需要人工验证时使用 Burp 代理
bash web-security/burp/burp.sh install
bash web-security/burp/burp.sh start
bash web-security/burp/burp.sh proxy
```

Katana、Nuclei 和 ZAP 的默认输出目录分别是 `~/security-scans/katana`、`~/nuclei_scan`、`~/security-scans/zap`，不会在当前运维脚本仓库生成扫描报告。ZAP 脚本默认使用 baseline 模式，不执行主动攻击；Burp 的主动扫描、拦截和重放必须在已确认授权范围后手动进行。

### 公益 SRC 自动化扫描

`src-hunter.sh` 默认读取 `~/nuclei_scan/butian-public-src-targets.tsv` 和 `~/nuclei_scan/scanned-domains.txt`，同时识别输出目录中已有的成功报告或旧版非空 Nuclei 结果，按文件顺序跳过已扫描主域名。失败或中断留下的 Markdown/日志不会阻止重试。它会使用 `<history>.lock` 和 `<history>.claims` 防止并发任务重复领取目标，并把 Markdown、JSON 和扫描日志写入 `~/nuclei_scan/<主域名>/`；报告会记录请求覆盖率、错误数和跳过的无响应端点。它只调用 Nuclei 的安全默认模式，不自动提交补天。

```bash
# 查看下一个未扫描目标
bash web-security/nuclei/src-hunter.sh select-next

# 扫描下一个公益 SRC 目标，并生成一份 Markdown 主报告
bash web-security/nuclei/src-hunter.sh scan-next

# 直接扫描目标表中的指定资产
bash web-security/nuclei/src-hunter.sh scan --url https://<TSV中的目标> --vendor "厂商名称"
```

未列入目标表的资产必须同时提供 `--allow-unlisted --ack-authorized`；脚本不会自动执行代码执行、DoS、爆破、默认口令、钓鱼或其他主动利用，也不会自动提交漏洞报告。

## 🔗 相关链接

- [OWASP 官方网站](https://owasp.org/)
- [CVE 数据库](https://cve.mitre.org/)
- [参考文章：效率翻倍！AI+Skills 赋能安全测试](https://cloud.tencent.com/developer/article/2659591)
- [TscanPlus 官方仓库](https://github.com/TideSec/TscanPlus)
- [Code Audit Skill 官方仓库](https://github.com/3stoneBrother/code-audit)
- [Audit Skills 官方仓库](https://github.com/RuoJi6/audit-skills)

## 📝 使用场景

- **代码审计**: 静态代码分析和漏洞扫描
- **系统加固**: 服务器安全配置和加固
- **入侵检测**: 实时安全监控和告警
- **漏洞管理**: 定期安全扫描和修复
