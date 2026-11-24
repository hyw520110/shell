#!/usr/bin/env bash

set -e

PKG="$1"
shift

if [[ -z "$PKG" ]]; then
    echo "Usage: $0 <package> [extra_args...]"
    exit 1
fi

echo "[INFO] Installing $PKG using uv tool..."
if command -v uv >/dev/null 2>&1; then
    # mcp-server-browser-use 0.1.9 pulls browser-use 0.1.41. On Intel
    # macOS <=13, faiss-cpu 1.12 may fall back to a broken source build;
    # 1.10.0 provides a compatible macOS x86_64 wheel. Do not force this
    # version on other platforms, whose compatible wheel set is different.
    if [[ "$PKG" == "mcp-server-browser-use" ]]; then
        use_legacy_faiss=false
        if [[ "$(uname -s)" == "Darwin" && "$(uname -m)" == "x86_64" ]]; then
            macos_major="$(sw_vers -productVersion 2>/dev/null | cut -d. -f1)"
            [[ "$macos_major" =~ ^[0-9]+$ && "$macos_major" -lt 14 ]] && use_legacy_faiss=true
        fi
        if [[ "$use_legacy_faiss" == true ]]; then
            uv tool install --python 3.12 --force --with "faiss-cpu==1.10.0" "$PKG" "$@"
        else
            uv tool install --python 3.12 --force "$PKG" "$@"
        fi
    else
        uv tool install --python 3.12 --force "$PKG" "$@"
    fi
elif command -v pipx >/dev/null 2>&1; then
    pipx install --python python3.12 --force "$PKG" "$@"
else
    echo "[ERROR] uv or pipx is required to install python MCPs globally in isolated environments."
    exit 1
fi
