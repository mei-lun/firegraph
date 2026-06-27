#!/usr/bin/env bash
# 构建 firegraph 后端二进制
# 用法：bash scripts/build.sh [output_path]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
OUT="${1:-${ROOT_DIR}/bin/firegraph}"

cd "${ROOT_DIR}"
echo "==> 构建到 ${OUT}"
CGO_ENABLED=0 go build -trimpath -ldflags "-s -w" -o "${OUT}" ./cmd/firegraph
echo "==> 完成: ${OUT}"
