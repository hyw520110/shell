#!/bin/bash
# 启动 Gitea 服务
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
"$SCRIPT_DIR/install-gitea.sh" --start
