#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# Manual-Key Docker Deploy:
# Xray VLESS Reality TCP + Hysteria2 UDP
#
# 默认：
#   Xray Reality: 1443/tcp
#   Hysteria2:    1443/udp
#
# 特点：
#   - 不自动生成 Reality Key
#   - 手动填写 PrivateKey / PublicKey
#   - 不强依赖 docker compose
#   - 直接 docker run 部署
# ============================================================

INSTALL_DIR="${INSTALL_DIR:-/opt/proxy-stack}"
XRAY_IMAGE="${XRAY_IMAGE:-ghcr.io/xtls/xray-core:latest}"
HY2_IMAGE="${HY2_IMAGE:-tobyxdd/hysteria:v2}"

XRAY_PORT="${XRAY_PORT:-1443}"
HY2_PORT="${HY2_PORT:-1443}"
REALITY_SNI="${REALITY_SNI:-www.cloudflare.com}"
REALITY_DEST="${REALITY_DEST:-www.cloudflare.com:443}"

mkdir -p "${INSTALL_DIR}/xray" "${INSTALL_DIR}/hysteria" "${INSTALL_DIR}/result"

if [ "$(id -u)" -ne 0 ]; then
  echo "ERROR: 请使用 root 运行。"
  exit 1
fi

echo "============================================================"
echo "Xray + HY2 Docker 一键部署脚本：手动 Reality Key 版"
echo "============================================================"

echo ""
echo "当前默认配置："
echo "Xray TCP 端口: ${XRAY_PORT}"
echo "HY2 UDP 端口:  ${HY2_PORT}"
echo "Reality SNI:   ${REALITY_SNI}"
echo "Reality Dest:  ${REALITY_DEST}"
echo ""

# ------------------------------------------------------------
# 1. 检查 Docker
# ------------------------------------------------------------
echo "============================================================"
echo "[1/7] 检查 Docker..."
echo "============================================================"

if ! command -v docker >/dev/null 2>&1; then
  echo "Docker 未安装，开始安装 Docker..."
  apt update -y
  apt install -y ca-certificates curl gnupg lsb-release docker.io
fi

systemctl enable docker >/dev/null 2>&1 || true
systemctl restart docker >/dev/null 2>&1 || true

if ! docker ps >/dev/null 2>&1; then
  echo "ERROR: Docker 没有正常运行。"
  echo "请先检查："
  echo "systemctl status docker --no-pager -l"
  exit 1
fi

echo "Docker 正常。"

# ------------------------------------------------------------
# 2. 安装基础依赖
# ------------------------------------------------------------
echo "============================================================"
echo "[2/7] 安装基础依赖..."
echo "============================================================"

apt update -y
apt install -y curl openssl jq uuid-runtime

# ------------------------------------------------------------
# 3. 获取公网 IP
# ------------------------------------------------------------
echo "============================================================"
echo "[3/7] 获取服务器公网 IP..."
echo "============================================================"

SERVER_IP="$(curl -4 -s --max-time 8 https://api.ipify.org || true)"
if [ -z "${SERVER_IP}" ]; then
  SERVER_IP="$(curl -4 -s --max-time 8 https://ifconfig.me || true)"
fi

if [ -z "${SERVER_IP}" ]; then
  SERVER_IP="YOUR_SERVER_IP"
fi

echo "检测到公网 IP: ${SERVER_IP}"

# ------------------------------------------------------------
# 4. 手动填写 Reality 参数
# ------------------------------------------------------------
echo "============================================================"
echo "[4/7] 填写 Reality / HY2 参数"
echo "============================================================"

DEFAULT_UUID="$(cat /proc/sys/kernel/random/uuid)"
DEFAULT_SHORT_ID="$(openssl rand -hex 8)"
DEFAULT_HY2_PASSWORD="$(openssl rand -base64 32 | tr -dc 'A-Za-z0-9' | head -c 24)"

echo ""
echo "请填写 Xray Reality 参数。"
echo "注意："
echo "1. 服务端 config 需要 Reality PrivateKey。"
echo "2. 客户端链接需要 Reality PublicKey。"
echo "3. PrivateKey 和 PublicKey 必须是一对。"
echo ""

read -rp "请输入 Xray UUID，直接回车自动生成 [${DEFAULT_UUID}]: " XRAY_UUID
XRAY_UUID="${XRAY_UUID:-$DEFAULT_UUID}"

read -rp "请输入 Reality PrivateKey，必填: " REALITY_PRIVATE_KEY
if [ -z "${REALITY_PRIVATE_KEY}" ]; then
  echo "ERROR: Reality PrivateKey 不能为空。"
  exit 1
fi

read -rp "请输入 Reality PublicKey，客户端链接需要，建议填写: " REALITY_PUBLIC_KEY
if [ -z "${REALITY_PUBLIC_KEY}" ]; then
  REALITY_PUBLIC_KEY="PLEASE_FILL_PUBLIC_KEY"
fi

read -rp "请输入 Short ID，直接回车自动生成 [${DEFAULT_SHORT_ID}]: " SHORT_ID
SHORT_ID="${SHORT_ID:-$DEFAULT_SHORT_ID}"

read -rp "请输入 HY2 密码，直接回车自动生成 [${DEFAULT_HY2_PASSWORD}]: " HY2_PASSWORD
HY2_PASSWORD="${HY2_PASSWORD:-$DEFAULT_HY2_PASSWORD}"

echo ""
echo "确认参数："
echo "SERVER_IP:            ${SERVER_IP}"
echo "XRAY_UUID:            ${XRAY_UUID}"
echo "REALITY_PRIVATE_KEY:  ${REALITY_PRIVATE_KEY}"
echo "REALITY_PUBLIC_KEY:   ${REALITY_PUBLIC_KEY}"
echo "SHORT_ID:             ${SHORT_ID}"
echo "HY2_PASSWORD:         ${HY2_PASSWORD}"
echo ""

# ------------------------------------------------------------
# 5. 写入 Xray 配置
# ------------------------------------------------------------
echo "============================================================"
echo "[5/7] 写入 Xray 配置..."
echo "============================================================"

cat > "${INSTALL_DIR}/xray/config.json" <<XRAYEOF
{
  "log": {
    "loglevel": "info"
  },
  "inbounds": [
    {
      "tag": "vless-reality-in",
      "listen": "0.0.0.0",
      "port": ${XRAY_PORT},
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${XRAY_UUID}",
            "flow": "xtls-rprx-vision"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "${REALITY_DEST}",
          "xver": 0,
          "serverNames": [
            "${REALITY_SNI}"
          ],
          "privateKey": "${REALITY_PRIVATE_KEY}",
          "shortIds": [
            "${SHORT_ID}"
          ]
        }
      }
    }
  ],
  "outbounds": [
    {
      "tag": "direct",
      "protocol": "freedom",
      "settings": {}
    },
    {
      "tag": "block",
      "protocol": "blackhole",
      "settings": {}
    }
  ]
}
XRAYEOF

# ------------------------------------------------------------
# 6. 写入 HY2 配置和证书
# ------------------------------------------------------------
echo "============================================================"
echo "[6/7] 写入 HY2 配置..."
echo "============================================================"

openssl req -x509 -nodes -newkey ec:<(openssl ecparam -name prime256v1) \
  -keyout "${INSTALL_DIR}/hysteria/hy2.key" \
  -out "${INSTALL_DIR}/hysteria/hy2.crt" \
  -subj "/CN=${REALITY_SNI}" \
  -days 3650 >/dev/null 2>&1

chmod 600 "${INSTALL_DIR}/hysteria/hy2.key"

cat > "${INSTALL_DIR}/hysteria/config.yaml" <<HY2EOF
listen: :${HY2_PORT}

tls:
  cert: /etc/hysteria/hy2.crt
  key: /etc/hysteria/hy2.key

auth:
  type: password
  password: "${HY2_PASSWORD}"

masquerade:
  type: proxy
  proxy:
    url: https://${REALITY_SNI}/
    rewriteHost: true
HY2EOF

# ------------------------------------------------------------
# 7. 拉取镜像并启动容器
# ------------------------------------------------------------
echo "============================================================"
echo "[7/7] 拉取镜像并启动容器..."
echo "============================================================"

docker pull "${XRAY_IMAGE}"
docker pull "${HY2_IMAGE}"

docker rm -f xray-reality >/dev/null 2>&1 || true
docker rm -f hysteria2-server >/dev/null 2>&1 || true

docker run -d \
  --name xray-reality \
  --restart always \
  --network host \
  -v "${INSTALL_DIR}/xray/config.json:/etc/xray/config.json:ro" \
  "${XRAY_IMAGE}" run -config /etc/xray/config.json

docker run -d \
  --name hysteria2-server \
  --restart always \
  --network host \
  -v "${INSTALL_DIR}/hysteria/config.yaml:/etc/hysteria/config.yaml:ro" \
  -v "${INSTALL_DIR}/hysteria/hy2.crt:/etc/hysteria/hy2.crt:ro" \
  -v "${INSTALL_DIR}/hysteria/hy2.key:/etc/hysteria/hy2.key:ro" \
  "${HY2_IMAGE}" server -c /etc/hysteria/config.yaml

# 本机防火墙放行
if command -v ufw >/dev/null 2>&1; then
  ufw allow "${XRAY_PORT}/tcp" || true
  ufw allow "${HY2_PORT}/udp" || true
fi

if command -v firewall-cmd >/dev/null 2>&1; then
  firewall-cmd --permanent --add-port="${XRAY_PORT}/tcp" || true
  firewall-cmd --permanent --add-port="${HY2_PORT}/udp" || true
  firewall-cmd --reload || true
fi

VLESS_LINK="vless://${XRAY_UUID}@${SERVER_IP}:${XRAY_PORT}?type=tcp&security=reality&pbk=${REALITY_PUBLIC_KEY}&fp=chrome&sni=${REALITY_SNI}&sid=${SHORT_ID}&flow=xtls-rprx-vision#NL-Xray-Reality-TCP"
HY2_LINK="hy2://${HY2_PASSWORD}@${SERVER_IP}:${HY2_PORT}?insecure=1&sni=${REALITY_SNI}#NL-HY2-UDP"

cat > "${INSTALL_DIR}/result/client-info.txt" <<INFOEOF
============================================================
Xray + HY2 Docker Deploy Result
============================================================

Server IP:
${SERVER_IP}

------------------------------------------------------------
Xray VLESS Reality TCP
------------------------------------------------------------
Address: ${SERVER_IP}
Port: ${XRAY_PORT}
UUID: ${XRAY_UUID}
Network: tcp
Security: reality
Flow: xtls-rprx-vision
SNI: ${REALITY_SNI}
Reality Public Key: ${REALITY_PUBLIC_KEY}
Short ID: ${SHORT_ID}
Fingerprint: chrome

VLESS Link:
${VLESS_LINK}

------------------------------------------------------------
Hysteria2 UDP
------------------------------------------------------------
Address: ${SERVER_IP}
Port: ${HY2_PORT}
Password: ${HY2_PASSWORD}
SNI: ${REALITY_SNI}
TLS: self-signed
Client setting: insecure / skip-cert-verify = true

HY2 Link:
${HY2_LINK}

------------------------------------------------------------
Docker Commands
------------------------------------------------------------

查看状态:
docker ps

查看 Xray 日志:
docker logs xray-reality --tail=100

查看 HY2 日志:
docker logs hysteria2-server --tail=100

重启:
docker restart xray-reality hysteria2-server

停止:
docker stop xray-reality hysteria2-server

删除:
docker rm -f xray-reality hysteria2-server

配置目录:
${INSTALL_DIR}

重要：
云服务器安全组必须放行：
${XRAY_PORT}/tcp
${HY2_PORT}/udp

============================================================
INFOEOF

echo ""
echo "============================================================"
echo "部署完成"
echo "============================================================"
cat "${INSTALL_DIR}/result/client-info.txt"

