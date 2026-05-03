#!/usr/bin/env bash
set -euo pipefail

REPO_URL="${REPO_URL:-https://github.com/McGao0717/xray-hy2.git}"
BRANCH="${BRANCH:-main}"
WORK_DIR="${WORK_DIR:-/tmp/xray-hy2}"

echo "============================================================"
echo "Auto installer: Xray Reality TCP + Hysteria2 UDP + Nginx"
echo "============================================================"

if [ "$(id -u)" -ne 0 ]; then
  echo "ERROR: Please run as root. / 请使用 root 运行。" >&2
  exit 1
fi

if ! command -v apt >/dev/null 2>&1; then
  echo "ERROR: This installer currently supports Debian / Ubuntu only. / 当前脚本仅支持 Debian / Ubuntu。" >&2
  exit 1
fi

echo "[1/3] Installing bootstrap packages... / 安装启动所需组件..."
apt update -y
DEBIAN_FRONTEND=noninteractive apt install -y git curl bash ca-certificates

echo "[2/3] Downloading installer... / 下载部署脚本..."
rm -rf "${WORK_DIR}"
git clone --depth=1 --branch "${BRANCH}" "${REPO_URL}" "${WORK_DIR}"

chmod +x "${WORK_DIR}/install-proxy-interactive.sh"
bash -n "${WORK_DIR}/install-proxy-interactive.sh"

echo "[3/3] Starting interactive deployment... / 开始交互式部署..."
exec bash "${WORK_DIR}/install-proxy-interactive.sh"
