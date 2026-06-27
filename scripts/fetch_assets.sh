#!/usr/bin/env bash
# 下载 speedscope 离线包到 web/assets/vendor/speedscope/
# 用法：bash scripts/fetch_assets.sh [version]
set -euo pipefail

VERSION="${1:-1.25.0}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
DEST="${ROOT_DIR}/web/assets/vendor/speedscope"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

ZIP_URL="https://github.com/jlfwong/speedscope/releases/download/v${VERSION}/speedscope-v${VERSION}.zip"

echo "==> 下载 speedscope v${VERSION}"
echo "    URL: ${ZIP_URL}"
if ! command -v curl >/dev/null 2>&1; then
  echo "错误：未找到 curl，请先安装 curl" >&2
  exit 1
fi
curl -fL "${ZIP_URL}" -o "${TMP}/speedscope.zip"

if ! command -v unzip >/dev/null 2>&1; then
  echo "错误：未找到 unzip，请先安装 unzip" >&2
  exit 1
fi

echo "==> 解压到 ${DEST}"
rm -rf "${DEST}"
mkdir -p "${DEST}"
unzip -q "${TMP}/speedscope.zip" -d "${DEST}"

# speedscope release 解压后通常是 release/package/* 直接平铺
# 若存在子目录 release/package，将其提升到 DEST
if [ -d "${DEST}/release/package" ]; then
  mv "${DEST}/release/package"/* "${DEST}/"
  rm -rf "${DEST}/release"
fi

echo "==> 完成"
echo "    速度图表查看页: http://<server>/profiles.html -> 查看火焰图"
echo "    直接访问 speedscope: http://<server>/assets/vendor/speedscope/index.html"
