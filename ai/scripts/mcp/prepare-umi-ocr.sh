#!/usr/bin/env bash
set -euo pipefail

UMI_OCR_URL="${UMI_OCR_URL:-http://localhost:1224}"
UMI_OCR_START_CMD="${UMI_OCR_START_CMD:-}"

info() { echo "[INFO] $*"; }
ok() { echo "[OK] $*"; }
warn() { echo "[WARN] $*"; }

umi_ocr_ready() {
  curl -fsS "$UMI_OCR_URL/api/ocr" \
    -X POST \
    -H "Content-Type: application/json" \
    -d '{"base64":""}' >/dev/null 2>&1
}

wait_ready() {
  local seconds="${1:-15}"
  local i
  for ((i = 1; i <= seconds; i++)); do
    if umi_ocr_ready; then
      return 0
    fi
    sleep 1
  done
  return 1
}

main() {
  if umi_ocr_ready; then
    ok "Umi-OCR HTTP 服务已可用: $UMI_OCR_URL"
    return 0
  fi

  if [[ -z "$UMI_OCR_START_CMD" ]]; then
    # macOS 自动探测
    if [[ "$(uname -s)" == "Darwin" ]]; then
      local app_paths=(
        "/Applications/Umi-OCR.app"
        "$HOME/Applications/Umi-OCR.app"
      )
      for app in "${app_paths[@]}"; do
        if [[ -d "$app" ]]; then
          info "发现 macOS 应用: $app，尝试启动..."
          open "$app"
          if wait_ready "${UMI_OCR_WAIT_SECONDS:-20}"; then
            ok "Umi-OCR HTTP 服务通过应用启动成功"
            return 0
          fi
        fi
      done
    fi

    warn "Umi-OCR HTTP 服务未启动: $UMI_OCR_URL"
    warn "未设置 UMI_OCR_START_CMD，且未发现默认安装位置，无法自动启动。"
    warn "示例: UMI_OCR_START_CMD='/path/to/umi-ocr.sh' $0"
    return 2
  fi

  info "正在执行 UMI_OCR_START_CMD..."
  nohup bash -lc "$UMI_OCR_START_CMD" >/tmp/umi-ocr-start.log 2>&1 &

  if wait_ready "${UMI_OCR_WAIT_SECONDS:-20}"; then
    ok "Umi-OCR HTTP 服务启动成功: $UMI_OCR_URL"
    return 0
  fi

  warn "Umi-OCR 启动后仍未就绪，请查看: /tmp/umi-ocr-start.log"
  return 1
}

main "$@"
