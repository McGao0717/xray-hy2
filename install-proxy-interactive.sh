#!/usr/bin/env bash
set -euo pipefail

INSTALL_DIR="${INSTALL_DIR:-/opt/proxy-stack}"
XRAY_IMAGE="${XRAY_IMAGE:-ghcr.io/xtls/xray-core:latest}"
HY2_IMAGE="${HY2_IMAGE:-tobyxdd/hysteria:v2}"

ask_default() {
  local prompt="$1"
  local default="$2"
  local value=""
  read -rp "${prompt} [${default}]: " value
  echo "${value:-$default}"
}

need_root() {
  if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: 请使用 root 运行"
    exit 1
  fi
}

install_base() {
  echo "============================================================"
  echo "[1/8] 检查并安装基础组件"
  echo "============================================================"

  if ! command -v apt >/dev/null 2>&1; then
    echo "ERROR: 当前脚本只支持 Debian / Ubuntu 系统"
    exit 1
  fi

  apt update -y
  apt install -y curl openssl jq uuid-runtime ca-certificates gnupg lsb-release

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

  echo "Docker 正常"
}

get_public_ip() {
  SERVER_IP="$(curl -4 -s --max-time 8 https://api.ipify.org || true)"
  if [ -z "${SERVER_IP}" ]; then
    SERVER_IP="$(curl -4 -s --max-time 8 https://ifconfig.me || true)"
  fi
  if [ -z "${SERVER_IP}" ]; then
    SERVER_IP="YOUR_SERVER_IP"
  fi
  SERVER_IP="$(ask_default '确认服务器公网 IP' "${SERVER_IP}")"
}

manual_reality_key() {
  read -rp "请输入 Reality PrivateKey，必填: " REALITY_PRIVATE_KEY
  if [ -z "${REALITY_PRIVATE_KEY}" ]; then
    echo "ERROR: Reality PrivateKey 不能为空"
    exit 1
  fi

  read -rp "请输入 Reality PublicKey，必填: " REALITY_PUBLIC_KEY
  if [ -z "${REALITY_PUBLIC_KEY}" ]; then
    echo "ERROR: Reality PublicKey 不能为空"
    exit 1
  fi
}

generate_reality_key() {
  echo "拉取 Xray 镜像用于生成 Reality Key..."
  docker pull "${XRAY_IMAGE}"

  KEY_OUTPUT=""
  REALITY_PRIVATE_KEY=""
  REALITY_PUBLIC_KEY=""

  try_keygen() {
    local cmd="$1"
    echo "尝试生成 Reality Key: ${cmd}"
    KEY_OUTPUT="$(eval "${cmd}" 2>&1 || true)"
    REALITY_PRIVATE_KEY="$(echo "${KEY_OUTPUT}" | awk -F': ' '/Private key/ {print $2}' | tr -d '\r' | head -n 1)"
    REALITY_PUBLIC_KEY="$(echo "${KEY_OUTPUT}" | awk -F': ' '/Public key/ {print $2}' | tr -d '\r' | head -n 1)"
  }

  try_keygen "docker run --rm ${XRAY_IMAGE} x25519"

  if [ -z "${REALITY_PRIVATE_KEY}" ] || [ -z "${REALITY_PUBLIC_KEY}" ]; then
    try_keygen "docker run --rm --entrypoint /usr/local/bin/xray ${XRAY_IMAGE} x25519"
  fi

  if [ -z "${REALITY_PRIVATE_KEY}" ] || [ -z "${REALITY_PUBLIC_KEY}" ]; then
    try_keygen "docker run --rm --entrypoint /usr/bin/xray ${XRAY_IMAGE} x25519"
  fi

  if [ -z "${REALITY_PRIVATE_KEY}" ] || [ -z "${REALITY_PUBLIC_KEY}" ]; then
    echo "自动生成 Reality Key 失败，切换为手动填写模式"
    echo "最后一次输出："
    echo "${KEY_OUTPUT}"
    manual_reality_key
  else
    echo "Reality Key 自动生成成功"
    echo "PrivateKey: ${REALITY_PRIVATE_KEY}"
    echo "PublicKey:  ${REALITY_PUBLIC_KEY}"
  fi
}

write_xray_config() {
  mkdir -p "${INSTALL_DIR}/xray"

  cat > "${INSTALL_DIR}/xray/config.json" <<XRAY_CONFIG_EOF
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
XRAY_CONFIG_EOF
}

write_hy2_config() {
  mkdir -p "${INSTALL_DIR}/hysteria"

  openssl req -x509 -nodes -newkey ec:<(openssl ecparam -name prime256v1) \
    -keyout "${INSTALL_DIR}/hysteria/hy2.key" \
    -out "${INSTALL_DIR}/hysteria/hy2.crt" \
    -subj "/CN=${REALITY_SNI}" \
    -days 3650 >/dev/null 2>&1

  chmod 600 "${INSTALL_DIR}/hysteria/hy2.key"

  cat > "${INSTALL_DIR}/hysteria/config.yaml" <<HY2_CONFIG_EOF
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
HY2_CONFIG_EOF
}

start_containers() {
  echo "拉取镜像..."
  docker pull "${XRAY_IMAGE}"
  docker pull "${HY2_IMAGE}"

  echo "清理旧容器..."
  docker rm -f xray-reality >/dev/null 2>&1 || true
  docker rm -f hysteria2-server >/dev/null 2>&1 || true

  echo "启动 Xray Reality..."
  docker run -d \
    --name xray-reality \
    --restart always \
    --network host \
    -v "${INSTALL_DIR}/xray/config.json:/etc/xray/config.json:ro" \
    "${XRAY_IMAGE}" run -config /etc/xray/config.json

  echo "启动 Hysteria2..."
  docker run -d \
    --name hysteria2-server \
    --restart always \
    --network host \
    -v "${INSTALL_DIR}/hysteria/config.yaml:/etc/hysteria/config.yaml:ro" \
    -v "${INSTALL_DIR}/hysteria/hy2.crt:/etc/hysteria/hy2.crt:ro" \
    -v "${INSTALL_DIR}/hysteria/hy2.key:/etc/hysteria/hy2.key:ro" \
    "${HY2_IMAGE}" server -c /etc/hysteria/config.yaml
}

open_firewall() {
  if command -v ufw >/dev/null 2>&1; then
    ufw allow "${XRAY_PORT}/tcp" || true
    ufw allow "${HY2_PORT}/udp" || true
  fi

  if command -v firewall-cmd >/dev/null 2>&1; then
    firewall-cmd --permanent --add-port="${XRAY_PORT}/tcp" || true
    firewall-cmd --permanent --add-port="${HY2_PORT}/udp" || true
    firewall-cmd --reload || true
  fi
}

write_result() {
  mkdir -p "${INSTALL_DIR}/result"

  VLESS_LINK="vless://${XRAY_UUID}@${SERVER_IP}:${XRAY_PORT}?type=tcp&security=reality&pbk=${REALITY_PUBLIC_KEY}&fp=chrome&sni=${REALITY_SNI}&sid=${SHORT_ID}&flow=xtls-rprx-vision#Xray-Reality-TCP"
  HY2_LINK="hy2://${HY2_PASSWORD}@${SERVER_IP}:${HY2_PORT}?insecure=1&sni=${REALITY_SNI}#HY2-UDP"

  cat > "${INSTALL_DIR}/result/client-info.txt" <<RESULT_EOF
============================================================
Xray + HY2 Deploy Result
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
Client: insecure / skip-cert-verify = true

HY2 Link:
${HY2_LINK}

------------------------------------------------------------
Check:
docker ps
ss -lntup | grep ${XRAY_PORT}
docker logs xray-reality --tail=100
docker logs hysteria2-server --tail=100

Config:
${INSTALL_DIR}

Cloud firewall must allow:
${XRAY_PORT}/tcp
${HY2_PORT}/udp

============================================================
RESULT_EOF

  echo ""
  echo "============================================================"
  echo "部署完成"
  echo "============================================================"
  docker ps
  echo ""
  cat "${INSTALL_DIR}/result/client-info.txt"
}

main() {
  need_root

  echo "============================================================"
  echo "Xray Reality TCP + Hysteria2 UDP 交互式一键部署脚本"
  echo "============================================================"

  XRAY_PORT="$(ask_default '请输入 Xray TCP 端口' '1443')"
  HY2_PORT="$(ask_default '请输入 HY2 UDP 端口' '1443')"
  REALITY_SNI="$(ask_default '请输入 Reality SNI' 'www.cloudflare.com')"
  REALITY_DEST="$(ask_default '请输入 Reality Dest' 'www.cloudflare.com:443')"

  install_base

  echo "============================================================"
  echo "[2/8] 获取服务器公网 IP"
  echo "============================================================"
  get_public_ip

  echo "============================================================"
  echo "[3/8] 生成或填写 UUID"
  echo "============================================================"
  DEFAULT_UUID="$(cat /proc/sys/kernel/random/uuid)"
  XRAY_UUID="$(ask_default '请输入 Xray UUID，直接回车自动生成' "${DEFAULT_UUID}")"

  echo "============================================================"
  echo "[4/8] Reality Key 设置"
  echo "============================================================"
  echo "请选择 Reality Key 方式："
  echo "1) 自动生成 Reality PrivateKey / PublicKey"
  echo "2) 手动填写 Reality PrivateKey / PublicKey"
  read -rp "请输入 1 或 2，直接回车默认自动生成 [1]: " KEY_MODE
  KEY_MODE="${KEY_MODE:-1}"

  if [ "${KEY_MODE}" = "1" ]; then
    generate_reality_key
  else
    manual_reality_key
  fi

  echo "============================================================"
  echo "[5/8] Short ID / HY2 密码"
  echo "============================================================"
  DEFAULT_SHORT_ID="$(openssl rand -hex 8)"
  DEFAULT_HY2_PASSWORD="$(openssl rand -base64 32 | tr -dc 'A-Za-z0-9' | head -c 24)"

  SHORT_ID="$(ask_default '请输入 Short ID，直接回车自动生成' "${DEFAULT_SHORT_ID}")"
  HY2_PASSWORD="$(ask_default '请输入 HY2 密码，直接回车自动生成' "${DEFAULT_HY2_PASSWORD}")"

  echo ""
  echo "============================================================"
  echo "确认部署参数"
  echo "============================================================"
  echo "SERVER_IP:           ${SERVER_IP}"
  echo "XRAY_PORT:           ${XRAY_PORT}/tcp"
  echo "HY2_PORT:            ${HY2_PORT}/udp"
  echo "XRAY_UUID:           ${XRAY_UUID}"
  echo "REALITY_SNI:         ${REALITY_SNI}"
  echo "REALITY_DEST:        ${REALITY_DEST}"
  echo "REALITY_PRIVATE_KEY: ${REALITY_PRIVATE_KEY}"
  echo "REALITY_PUBLIC_KEY:  ${REALITY_PUBLIC_KEY}"
  echo "SHORT_ID:            ${SHORT_ID}"
  echo "HY2_PASSWORD:        ${HY2_PASSWORD}"
  echo ""

  read -rp "确认开始部署？输入 y 继续 [y]: " CONFIRM
  CONFIRM="${CONFIRM:-y}"

  if [ "${CONFIRM}" != "y" ] && [ "${CONFIRM}" != "Y" ]; then
    echo "已取消"
    exit 0
  fi

  echo "============================================================"
  echo "[6/8] 写入配置"
  echo "============================================================"
  write_xray_config
  write_hy2_config

  echo "============================================================"
  echo "[7/8] 启动容器"
  echo "============================================================"
  start_containers

  echo "============================================================"
  echo "[8/8] 放行本机防火墙并输出结果"
  echo "============================================================"
  open_firewall
  write_result
}

main "$@"
