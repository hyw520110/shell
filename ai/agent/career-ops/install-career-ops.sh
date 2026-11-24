#!/usr/bin/env bash
set -euo pipefail

BASE_DIR="${AI_HUB_CAREER_OPS_BASE:-$HOME/.local/share/ai-hub}"
INSTALL_DIR="$BASE_DIR/career-ops"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/career-ops.XXXXXX")"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

if ! command -v npm >/dev/null 2>&1; then
  echo "[ERROR] npm 未安装，无法获取 Career-Ops 最新版本" >&2
  exit 1
fi

if ! command -v curl >/dev/null 2>&1; then
  echo "[ERROR] curl 未安装，无法下载 Career-Ops" >&2
  exit 1
fi

version="$(npm view @santifer/career-ops version --silent)"
if [[ -z "$version" ]]; then
  echo "[ERROR] 无法从 npm 获取 @santifer/career-ops 版本" >&2
  exit 1
fi

tag="career-ops-v$version"
archive_url="https://github.com/santifer/career-ops/archive/refs/tags/${tag}.tar.gz"
mirror_url="https://gh-proxy.com/$archive_url"
archive_path="$TMP_DIR/career-ops.tgz"

mkdir -p "$BASE_DIR"

echo "[INFO] 下载 Career-Ops $version"
if ! curl -fL --connect-timeout 10 --max-time 180 --retry 2 "$mirror_url" -o "$archive_path"; then
  echo "[WARN] 镜像下载失败，回退官方 GitHub 地址"
  curl -fL --connect-timeout 10 --max-time 180 --retry 2 "$archive_url" -o "$archive_path"
fi

rm -rf "$INSTALL_DIR"
mkdir -p "$INSTALL_DIR"
tar -xzf "$archive_path" --strip-components=1 -C "$INSTALL_DIR"

cd "$INSTALL_DIR"
npm install

echo "[INFO] Career-Ops 已安装到 $INSTALL_DIR"
