# 安全工具集

> 安全扫描、防护和监控工具的安装和配置脚本

## 📋 目录说明

| 目录 | 说明 | 脚本数量 |
|------|------|----------|
| `code-security/` | 代码安全扫描工具 | - |
| `host-security/` | 主机安全加固工具 | - |
| `monitor/` | 安全监控工具 | - |
| `platform/` | 安全测试与运营平台 | - |
| `protection/` | 安全防护工具 | - |
| `recon-tools/` | 资产侦察与代码泄露扫描工具 | - |
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
- AutoCVE：授权源码项目的 CVE 发现、验证和报告平台
- AutoCVE 脚本位置：`code-security/autocve/autocve.sh`

##### AutoCVE

AutoCVE 面向源码审计和 CVE 研究，不用于公网 Web URL 扫描。脚本下载固定版本的官方 Docker Compose 文件，默认只准备配置，不自动启动容器；启动必须显式确认授权。

```bash
# 准备固定版本 Compose（不启动）
bash code-security/autocve/autocve.sh install

# 编辑 ~/.local/share/autocve/.env 配置模型后，在隔离且已授权环境启动
bash code-security/autocve/autocve.sh start --ack-authorized

# 查看状态/日志
bash code-security/autocve/autocve.sh status
bash code-security/autocve/autocve.sh logs
```

上游 AutoCVE Compose 包含 Agent Worker，并挂载宿主机 Docker socket；本封装将端口限制在 `127.0.0.1`，不自动导入源码、执行 PoC 或提交漏洞。`uninstall --yes` 保留数据卷，确认无需保留数据后再使用 `purge --yes`。

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

#### platform/
**安全测试与运营平台**

- CyberStrikeAI：授权资产、漏洞、工具编排和证据报告管理平台
- 脚本位置：`platform/cyberstrikeai/cyberstrike-ai.sh`
- 支持 macOS/Linux；源码构建需要 Go 1.25+、Python 3.10+ 和 Git
- 默认仅绑定 `127.0.0.1`，使用本地 HTTPS；安装后需手动配置 AI 通道
- 不自动启用 C2、WebShell、外部 MCP、命令执行或远程扫描

```bash
# 安装/构建
bash platform/cyberstrikeai/cyberstrike-ai.sh install

# 查看状态并启动本地服务
bash platform/cyberstrikeai/cyberstrike-ai.sh status
bash platform/cyberstrikeai/cyberstrike-ai.sh start
```

CyberStrikeAI 属于高权限安全平台，使用前必须确认目标授权、工具白名单、人工审批和审计配置；不要将其直接接入公益 SRC 自动扫描编排器。

#### scanner/
**漏洞扫描**
- 系统漏洞扫描
- 网络漏洞扫描
- Web 漏洞扫描
- 数据库漏洞扫描
- Terrapin-Scanner（RUB-NDS）：检测 SSH 端点是否受 Terrapin 攻击（CVE-2023-48795），单连接、不做认证与攻击。脚本位置：`scanner/terrapin/terrapin.sh`
- TscanClient/TscanPlus：跨平台资产识别、URL 指纹和低影响 JS 收集

##### Terrapin-Scanner

Terrapin-Scanner 用于判定单个 SSH 端点是否受 Terrapin 攻击（CVE-2023-48795）影响。它只对目标做一次 TCP 连接并收集其支持的算法与 countermeasure（strict key exchange）支持情况，不执行完整密钥交换、不尝试认证、也不实际发起攻击，属于低影响探测。

```bash
# 安装（默认 go install；也可指定 Homebrew）
bash scanner/terrapin/terrapin.sh install
bash scanner/terrapin/terrapin.sh install brew

# 查看状态
bash scanner/terrapin/terrapin.sh status

# 扫描单个 SSH 端点（host:port，缺失端口默认 22），可输出 JSON
bash scanner/terrapin/terrapin.sh scan --connect example.com:22
bash scanner/terrapin/terrapin.sh scan --connect 192.168.1.10:2222 --json
```

报告默认写入 `~/security-scans/terrapin/`，不会写入当前仓库。请仅扫描你有权测试的主机。卸载需显式 `uninstall --yes`。

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

#### recon-tools/
**资产侦察与代码泄露扫描**

- Subfinder（被动子域名发现）、Naabu（端口扫描）、Amass（被动资产枚举）、Feroxbuster（目录爆破）、Gitleaks（Git 密钥泄露扫描）
- 脚本位置：`recon-tools/subfinder.sh`、`recon-tools/naabu.sh`、`recon-tools/amass.sh`、`recon-tools/feroxbuster.sh`、`recon-tools/gitleaks.sh`
- 共享函数：`recon-tools/recon-common.sh`
- 支持 macOS / Linux，安装到 `~/.local/bin`，数据与配置写入 `~/.local/share/recon-tools/` 与 `~/.config/<工具>/`

```bash
# 一键安装并生成基础配置
bash security/recon-tools/subfinder.sh install

# 查看状态 / 更新 / 卸载
bash security/recon-tools/subfinder.sh status
bash security/recon-tools/subfinder.sh update
bash security/recon-tools/subfinder.sh uninstall --yes
```

各工具默认只启用低影响模式，涉及目标的主动动作均需 `--ack-authorized` 显式确认授权：

```bash
# Subfinder：被动子域名枚举
bash security/recon-tools/subfinder.sh subdomains -d example.com --ack-authorized

# Naabu：端口扫描（默认只扫 80/443）
bash security/recon-tools/naabu.sh scan example.com -p 80,443,8080-8090 --ack-authorized

# Amass：被动资产枚举（不主动爆破）
bash security/recon-tools/amass.sh enum -d example.com --ack-authorized

# Feroxbuster：目录爆破（低并发）
bash security/recon-tools/feroxbuster.sh fuzz -u https://example.com -t 10 --ack-authorized

# Gitleaks：扫描本地仓库，不触碰网络
bash security/recon-tools/gitleaks.sh detect /path/to/repo
```

扫描结果默认写入 `~/security-scans/<工具>/`，不会写入仓库。Subfinder/Amass 配置模板位于 `~/.config/subfinder/provider-config.yaml`、`~/.config/amass/config.ini`，请勿把 API 密钥提交到仓库。

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
