#!/usr/bin/env bash
set -euo pipefail

REPO_URL="https://github.com/McGao0717/xray-hy2.git"
WORK_DIR="/tmp/xray-hy2"
XRAY_IMAGE="ghcr.io/xtls/xray-core:latest"

echo "============================================================"
echo "Auto install: Xray Reality TCP + HY2 UDP"
echo "============================================================"

if [ "$(id -u)" -ne 0 ]; then
  echo "ERROR: 请使用 root 运行"
  exit 1
fi

if ! command -v apt >/dev/null 2>&1; then
  echo "ERROR: 当前脚本只支持 Debian / Ubuntu"
  exit 1
fi

echo "[1/5] 安装基础组件..."
apt update -y
apt install -y git curl bash openssl uuid-runtime ca-certificates

if ! command -v docker >/dev/null 2>&1; then
  echo "Docker 未安装，开始安装 docker.io..."
  apt install -y docker.io
fi

systemctl enable docker >/dev/null 2>&1 || true
systemctl restart docker >/dev/null 2>&1 || true

if ! docker ps >/dev/null 2>&1; then
  echo "ERROR: Docker 没有正常运行"
  systemctl status docker --no-pager -l || true
  exit 1
fi

echo "[2/5] 拉取部署脚本..."
rm -rf "${WORK_DIR}"
git clone --depth=1 "${REPO_URL}" "${WORK_DIR}"

chmod +x "${WORK_DIR}/install-proxy-interactive.sh"
bash -n "${WORK_DIR}/install-proxy-interactive.sh"

echo "[3/5] 生成参数..."
XRAY_UUID="$(cat /proc/sys/kernel/random/uuid)"
SHORT_ID="$(openssl rand -hex 8)"
HY2_PASSWORD="$(openssl rand -base64 32 | tr -dc 'A-Za-z0-9' | head -c 24)"

docker pull "${XRAY_IMAGE}"

KEY_OUTPUT="$(docker run --rm "${XRAY_IMAGE}" x25519 2>&1 || true)"
REALITY_PRIVATE_KEY="$(echo "${KEY_OUTPUT}" | awk -F': ' '/Private key/ {print $2}' | tr -d '\r' | head -n 1)"
REALITY_PUBLIC_KEY="$(echo "${KEY_OUTPUT}" | awk -F': ' '/Public key/ {print $2}' | tr -d '\r' | head -n 1)"

if [ -z "${REALITY_PRIVATE_KEY}" ] || [ -z "${REALITY_PUBLIC_KEY}" ]; then
  KEY_OUTPUT="$(docker run --rm --entrypoint /usr/local/bin/xray "${XRAY_IMAGE}" x25519 2>&1 || true)"
  REALITY_PRIVATE_KEY="$(echo "${KEY_OUTPUT}" | awk -F': ' '/Private key/ {print $2}' | tr -d '\r' | head -n 1)"
  REALITY_PUBLIC_KEY="$(echo "${KEY_OUTPUT}" | awk -F': ' '/Public key/ {print $2}' | tr -d '\r' | head -n 1)"
fi

if [ -z "${REALITY_PRIVATE_KEY}" ] || [ -z "${REALITY_PUBLIC_KEY}" ]; then
  echo "ERROR: Reality Key 自动生成失败"
  echo "${KEY_OUTPUT}"
  exit 1
fi

echo "XRAY_UUID=${XRAY_UUID}"
echo "REALITY_PUBLIC_KEY=${REALITY_PUBLIC_KEY}"
echo "SHORT_ID=${SHORT_ID}"
echo "HY2_PASSWORD=${HY2_PASSWORD}"

echo "[4/5] 自动执行安装脚本..."

printf "%s\n%s\n%s\n%s\n%s\ny\n" \
  "${XRAY_UUID}" \
  "${REALITY_PRIVATE_KEY}" \
  "${REALITY_PUBLIC_KEY}" \
  "${SHORT_ID}" \
  "${HY2_PASSWORD}" \
  | bash "${WORK_DIR}/install-proxy-interactive.sh"

echo "[5/5] 检查状态..."
docker ps
ss -lntup | grep 1443 || true

echo "============================================================"
echo "完成。节点信息："
echo "============================================================"
cat /opt/proxy-stack/result/client-info.txt
