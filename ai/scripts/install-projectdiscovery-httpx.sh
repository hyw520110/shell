#!/usr/bin/env bash

# ProjectDiscovery httpx 安装与诊断。
# 注意：这里的 httpx 是 Go 编译的 ProjectDiscovery CLI，不是 Python httpx 包。

set -euo pipefail

log() { printf '[httpx] %s\n' "$*"; }
die() { printf '[httpx][ERROR] %s\n' "$*" >&2; exit 1; }

candidate_bins() {
    command -v httpx 2>/dev/null || true
    [[ -x "${HOME:-}/.local/bin/httpx" ]] && printf '%s\n' "$HOME/.local/bin/httpx"
    [[ -x "/usr/local/bin/httpx" ]] && printf '%s\n' "/usr/local/bin/httpx"
    [[ -x "/opt/homebrew/bin/httpx" ]] && printf '%s\n' "/opt/homebrew/bin/httpx"
    [[ -x "${HOME:-}/go/bin/httpx" ]] && printf '%s\n' "$HOME/go/bin/httpx"
}

is_projectdiscovery_httpx() {
    local bin="$1" output
    [[ -x "$bin" ]] || return 1
    output=$("$bin" -version 2>&1 || true)
    printf '%s\n' "$output" | grep -Eqi 'projectdiscovery|current httpx version|httpx engine version|httpx version'
}

find_httpx() {
    local bin
    while IFS= read -r bin; do
        [[ -n "$bin" ]] || continue
        if is_projectdiscovery_httpx "$bin"; then
            printf '%s\n' "$bin"
            return 0
        fi
    done < <(candidate_bins | awk 'NF && !seen[$0]++')
    return 1
}

check() {
    local bin
    if bin=$(find_httpx); then
        log "已找到 ProjectDiscovery httpx: $bin"
        "$bin" -version 2>&1 | sed -n '1,8p'
        return 0
    fi
    log "未找到 ProjectDiscovery httpx"
    log "当前 PATH: ${PATH:-<empty>}"
    return 1
}

install_httpx() {
    if check >/dev/null 2>&1; then
        log "httpx 已安装，跳过重复安装。"
        check
        return 0
    fi
    local os_name="$(uname -s 2>/dev/null || echo unknown)"
    if [[ "$os_name" == "Darwin" ]] && ! command -v go >/dev/null 2>&1; then
        command -v brew >/dev/null 2>&1 || die "macOS 未安装 Go；请先安装 Go 或 Homebrew。"
        log "macOS 未检测到 Go，先通过 Homebrew 安装 Go"
        brew install go
    fi
    command -v go >/dev/null 2>&1 || die "${os_name} 需要 Go；请先安装 Go，或手动放置官方 httpx 二进制。"
    case "$os_name" in
        Darwin|Linux)
            local bin_dir="${HOME}/.local/bin"
            mkdir -p "$bin_dir"
            log "通过 Go 安装 ProjectDiscovery httpx 到 $bin_dir"
            GOBIN="$bin_dir" go install -v github.com/projectdiscovery/httpx/cmd/httpx@latest
            ;;
        *) die "不支持的操作系统: $os_name" ;;
    esac
    check || die "httpx 安装完成但版本校验失败；请确认 PATH 中没有同名的其他程序。"
}

print_env() {
    local bin
    bin=$(find_httpx 2>/dev/null || true)
    [[ -n "$bin" ]] || die "尚未找到 ProjectDiscovery httpx，请先执行 install。"
    printf 'HTTPX_BIN=%s\n' "$bin"
    printf 'PATH_HINT=%s\n' "$(dirname "$bin")"
    printf 'export PATH="%s:\$PATH"\n' "$(dirname "$bin")"
}

case "${1:-check}" in
    check|doctor) check ;;
    install) install_httpx ;;
    env|print-env) print_env ;;
    *) printf '用法: %s {check|install|env}\n' "$0" >&2; exit 2 ;;
esac
