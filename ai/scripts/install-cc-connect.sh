#!/usr/bin/env bash
# 安装独立消息桥接工具，不修改机器人凭据或启动接收服务。
set -euo pipefail
umask 077

ACTION=install
VERSION="${CC_CONNECT_VERSION:-latest}"
BIN_DIR="${CC_CONNECT_BIN_DIR:-$HOME/.local/bin}"
DRY_RUN=false
WORK_DIR=""
STAGED_BIN=""
REPO_URL="https://github.com/chenhg5/cc-connect"

log() { printf '[INFO] %s\n' "$*"; }
die() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }
require() { command -v "$1" >/dev/null 2>&1 || die "缺少依赖: $1"; }
cleanup() {
    [[ -z "$STAGED_BIN" ]] || rm -f -- "$STAGED_BIN"
    if [[ -n "$WORK_DIR" && -d "$WORK_DIR" ]]; then
        rm -f -- "$WORK_DIR/release.json" "$WORK_DIR/checksums.txt" "$WORK_DIR/package.tar.gz" "$WORK_DIR/cc-connect"
        rmdir -- "$WORK_DIR"
    fi
    return 0
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

usage() {
    cat <<'EOF'
用法: bash install-cc-connect.sh [install|update|status|guide|uninstall] [--version latest|vX.Y.Z] [--dry-run]
默认安装到 ~/.local/bin，已有可用安装时跳过下载并显示配置指南。
update 备份旧程序后替换，不自动重启服务；uninstall 停止并移除服务，保留配置、会话和备份。
CC_CONNECT_BIN_DIR 可指定绝对安装目录；CC_CONNECT_VERSION 可指定版本。
下载使用 curl 的标准代理环境变量，不修改系统代理。
EOF
}

guide() {
    cat <<EOF
cc-connect 配置指南
程序: $BIN_DIR/cc-connect
配置: $HOME/.cc-connect/config.toml
来源: $REPO_URL

1. 确认 codex --version 可用，并执行 codex login 完成登录。
2. 创建私有配置目录: mkdir -p "\$HOME/.cc-connect" && chmod 700 "\$HOME/.cc-connect"
   首次配置可参考以下最小模板；已有配置请先备份，不要覆盖。
EOF
    cat <<'EOF'
language = "zh"

[[projects]]
name = "my-project"

[projects.agent]
type = "codex"

[projects.agent.options]
work_dir = "/absolute/path/to/project"
mode = "auto-edit"

[[projects.platforms]]
type = "dingtalk"

[projects.platforms.options]
client_id = "填写该机器人的 AppKey"
client_secret = "填写该机器人的 AppSecret"
allow_from = "填写本人钉钉员工 ID，不要使用星号"
reaction_emoji = "none"
done_emoji = "none"

3. 在钉钉开放平台启用该应用的机器人与 Stream 模式，发布到本人可见范围。
   Codex 与其他助手使用不同机器人；不要同时运行同一机器人的两个接收服务。
   work_dir 是手机任务的项目目录，与本安装脚本和程序所在目录无关。
   auto-edit 允许修改项目文件；仅需只读时使用 suggest，不使用 yolo。
4. 保存配置后执行: chmod 600 "$HOME/.cc-connect/config.toml"
   先前台验证: "$HOME/.local/bin/cc-connect" --config "$HOME/.cc-connect/config.toml"
   然后用手机给机器人发送“执行 pwd 并回复”，核对项目路径和手机回复。
5. 退出前台进程后，启用用户登录自启动:
   cc-connect daemon install --config "$HOME/.cc-connect/config.toml" --no-capture-secrets
   cc-connect daemon status
   cc-connect daemon logs -n 30
   若用 fnm/nvm，安装自启动前请将 PATH 中的 Node 路径换成固定版本路径，避免临时会话目录。
   macOS 登录后、电脑唤醒且网络可用时工作；休眠或未登录时不能执行。
6. 如 Codex 需要代理，仅在 [projects.agent.options.env] 中设置 HTTP_PROXY/HTTPS_PROXY；
   不要让钉钉连接无依据地经过代理。配置中不粘贴登录 Cookie，也不把密钥提交进仓库。

安装脚本不会自动创建凭据、复制登录文件或启用服务。
EOF
    if [[ "$BIN_DIR" != "$HOME/.local/bin" ]]; then
        log "使用了自定义安装目录，以上命令中的 ~/.local/bin 请替换为: $BIN_DIR"
    fi
    case ":$PATH:" in
        *":$BIN_DIR:"*) ;;
        *) printf '当前 PATH 未包含安装目录，可执行: export PATH=%q:"$PATH"\n' "$BIN_DIR" ;;
    esac
}

installed_version() {
    [[ -x "$BIN_DIR/cc-connect" ]] || return 1
    "$BIN_DIR/cc-connect" --version 2>/dev/null | sed -n '1p' | grep -E '^cc-connect v[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9.-]+)?$'
}

download() {
    curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' \
        --connect-timeout 10 --max-time 90 --retry 1 --retry-max-time 180 \
        --output "$2" "$1"
}

sha256() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    else
        shasum -a 256 "$1" | awk '{print $1}'
    fi
}

install_binary() {
    local os arch asset member expected actual backup available
    case "$(uname -s)" in Darwin) os=darwin ;; Linux) os=linux ;; *) die "仅支持 macOS 和 Linux" ;; esac
    case "$(uname -m)" in x86_64|amd64) arch=amd64 ;; arm64|aarch64) arch=arm64 ;; *) die "不支持的 CPU 架构" ;; esac
    if [[ "$ACTION" == install ]] && installed_version; then
        log "已有可用安装，保留现有程序、配置和服务。"
        guide
        return
    fi
    [[ ! -L "$BIN_DIR/cc-connect" ]] || die "安装目标是符号链接，请先确认其归属"
    if [[ -e "$BIN_DIR/cc-connect" ]]; then
        installed_version >/dev/null || die "目标文件不是可识别的 cc-connect，拒绝覆盖"
    fi
    if $DRY_RUN; then
        log "预览: 下载官方 $VERSION $os/${arch}，校验 SHA-256 后安装到 $BIN_DIR/cc-connect；不修改配置或启动服务。"
        return
    fi
    require curl; require tar; require awk
    command -v sha256sum >/dev/null 2>&1 || require shasum
    if [[ "$VERSION" == latest ]]; then require jq; fi
    available=$(df -Pk "$HOME" | awk 'END {print $4}')
    [[ "$available" =~ ^[0-9]+$ && "$available" -ge 153600 ]] || die "安装需要至少 150 MiB 可用空间"
    WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/cc-connect-install.XXXXXX")
    if [[ "$VERSION" == latest ]]; then
        download "https://api.github.com/repos/chenhg5/cc-connect/releases/latest" "$WORK_DIR/release.json"
        VERSION=$(jq -er '.tag_name | select(type == "string")' "$WORK_DIR/release.json")
    fi
    [[ "$VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9.-]+)?$ ]] || die "无效版本号: $VERSION"
    member="cc-connect-${VERSION}-${os}-${arch}"
    asset="${member}.tar.gz"
    log "下载 cc-connect $VERSION ($os/$arch)，单次超时 90 秒"
    download "$REPO_URL/releases/download/$VERSION/checksums.txt" "$WORK_DIR/checksums.txt"
    download "$REPO_URL/releases/download/$VERSION/$asset" "$WORK_DIR/package.tar.gz"
    expected=$(awk -v name="$asset" '$2 == name {print $1}' "$WORK_DIR/checksums.txt")
    [[ "$expected" =~ ^[a-fA-F0-9]{64}$ ]] || die "官方校验文件缺少唯一 SHA-256"
    actual=$(sha256 "$WORK_DIR/package.tar.gz")
    [[ "$actual" == "$expected" ]] || die "安装包 SHA-256 不符，保留原安装"
    # 只读取预期的单个程序，避免将压缩包路径写入安装目录。
    tar -xOf "$WORK_DIR/package.tar.gz" "$member" > "$WORK_DIR/cc-connect"
    chmod 755 "$WORK_DIR/cc-connect"
    [[ "$("$WORK_DIR/cc-connect" --version | sed -n '1p')" == "cc-connect $VERSION" ]] || die "安装包版本验证失败"
    mkdir -p "$BIN_DIR"
    if [[ -e "$BIN_DIR/cc-connect" ]]; then
        backup="$HOME/.local/share/cc-connect/backups/cc-connect.$(date +%Y%m%d-%H%M%S).$$"
        mkdir -p "$(dirname "$backup")"
        cp -p "$BIN_DIR/cc-connect" "$backup"
        log "原程序备份: $backup"
    fi
    STAGED_BIN=$(mktemp "$BIN_DIR/.cc-connect-install.XXXXXX")
    cp "$WORK_DIR/cc-connect" "$STAGED_BIN"
    chmod 755 "$STAGED_BIN"
    mv -f "$STAGED_BIN" "$BIN_DIR/cc-connect"
    STAGED_BIN=""
    log "已安装: $BIN_DIR/cc-connect ($VERSION)"
    [[ "$ACTION" != update ]] || log "运行中的服务保持原状；待任务结束后执行 cc-connect daemon restart 加载新版。"
    guide
}

if [[ $# -gt 0 && "$1" != -* ]]; then ACTION=$1; shift; fi
while [[ $# -gt 0 ]]; do
    case "$1" in
        --version) [[ $# -ge 2 ]] || die "--version 缺少参数"; VERSION=$2; shift 2 ;;
        --dry-run) DRY_RUN=true; shift ;;
        --help|-h) usage; exit 0 ;;
        *) die "未知参数: $1" ;;
    esac
done
[[ -n "${HOME:-}" && "$HOME" != / ]] || die "需要有效的用户目录"
[[ "$BIN_DIR" == /* && "$BIN_DIR" != / && "$BIN_DIR" != "$HOME" ]] || die "安装目录必须为明确的绝对目录"
[[ "$VERSION" == latest || "$VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9.-]+)?$ ]] || die "无效版本号: $VERSION"
case "$ACTION" in
    install|update) install_binary ;;
    guide) guide ;;
    status) installed_version || die "尚未安装 cc-connect" ;;
    uninstall)
        if $DRY_RUN; then log "预览: 停止并移除 cc-connect 服务和 $BIN_DIR/cc-connect，保留用户配置、会话与备份。"; exit 0; fi
        if [[ ! -e "$BIN_DIR/cc-connect" ]]; then log "尚未安装，无需卸载"; exit 0; fi
        [[ ! -L "$BIN_DIR/cc-connect" ]] || die "拒绝卸载未知归属的符号链接"
        installed_version >/dev/null || die "拒绝删除无法识别的程序"
        "$BIN_DIR/cc-connect" daemon uninstall
        rm -f -- "$BIN_DIR/cc-connect"
        log "已卸载程序及服务，配置、会话和备份保留。"
        ;;
    *) usage; exit 1 ;;
esac
