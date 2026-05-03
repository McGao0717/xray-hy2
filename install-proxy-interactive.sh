#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# Xray + Hysteria2 + Nginx Docker Installer
# Version: 2.0.0
#
# Deploys:
#   - Xray VLESS Reality TCP
#   - Hysteria2 UDP
#   - Nginx decoy/status website
#   - Docker host network mode
#
# Default ports:
#   - Xray Reality TCP: 1443/tcp
#   - Hysteria2 UDP:   1443/udp
#   - Nginx HTTP:      80/tcp
#
# Modes:
#   - Interactive: generate values first, then ask whether to use them
#   - Bring-your-own: input existing UUID / Reality keys / short ID / HY2 password
#   - Non-interactive: AUTO_ACCEPT_GENERATED=1 SKIP_CONFIRM=1 bash install-proxy-interactive.sh
# ============================================================

VERSION="2.0.0"
INSTALL_DIR="${INSTALL_DIR:-/opt/proxy-stack}"
RESULT_DIR="${INSTALL_DIR}/result"
XRAY_IMAGE="${XRAY_IMAGE:-ghcr.io/xtls/xray-core:latest}"
HY2_IMAGE="${HY2_IMAGE:-tobyxdd/hysteria:v2}"
NGINX_IMAGE="${NGINX_IMAGE:-nginx:alpine}"

XRAY_PORT="${XRAY_PORT:-1443}"
HY2_PORT="${HY2_PORT:-1443}"
NGINX_PORT="${NGINX_PORT:-80}"
REALITY_SNI="${REALITY_SNI:-www.cloudflare.com}"
REALITY_DEST="${REALITY_DEST:-www.cloudflare.com:443}"
NODE_NAME="${NODE_NAME:-GCP-Xray-HY2}"
MIN_DOCKER_VERSION="${MIN_DOCKER_VERSION:-20.10.0}"
AUTO_ACCEPT_GENERATED="${AUTO_ACCEPT_GENERATED:-0}"
SKIP_CONFIRM="${SKIP_CONFIRM:-0}"
INSTALL_NGINX="${INSTALL_NGINX:-1}"

XRAY_UUID="${XRAY_UUID:-}"
REALITY_PRIVATE_KEY="${REALITY_PRIVATE_KEY:-}"
REALITY_PUBLIC_KEY="${REALITY_PUBLIC_KEY:-}"
SHORT_ID="${SHORT_ID:-}"
HY2_PASSWORD="${HY2_PASSWORD:-}"
SERVER_IP="${SERVER_IP:-}"

log() { echo -e "\033[1;32m[INFO]\033[0m $*"; }
warn() { echo -e "\033[1;33m[WARN]\033[0m $*"; }
err() { echo -e "\033[1;31m[ERROR]\033[0m $*" >&2; }

confirm() {
  local prompt="$1"
  local default="${2:-Y}"
  local ans
  if [ "${SKIP_CONFIRM}" = "1" ]; then
    return 0
  fi
  if [ "${default}" = "Y" ]; then
    read -rp "${prompt} [Y/n]: " ans || true
    ans="${ans:-Y}"
  else
    read -rp "${prompt} [y/N]: " ans || true
    ans="${ans:-N}"
  fi
  case "${ans}" in
    y|Y|yes|YES) return 0 ;;
    *) return 1 ;;
  esac
}

need_root() {
  if [ "$(id -u)" -ne 0 ]; then
    err "Please run as root. / 请使用 root 运行。"
    exit 1
  fi
}

need_apt() {
  if ! command -v apt >/dev/null 2>&1; then
    err "This installer only supports Debian / Ubuntu with apt."
    exit 1
  fi
}

version_ge() {
  [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n1)" = "$2" ]
}

install_base_packages() {
  log "Installing base packages..."
  apt update -y
  DEBIAN_FRONTEND=noninteractive apt install -y \
    ca-certificates curl wget gnupg lsb-release openssl jq uuid-runtime \
    coreutils grep sed gawk tar gzip unzip iproute2 procps
}

install_or_update_docker() {
  local current_version=""
  if command -v docker >/dev/null 2>&1; then
    current_version="$(docker version --format '{{.Server.Version}}' 2>/dev/null || docker --version | awk '{print $3}' | tr -d ',')"
  fi

  if [ -n "${current_version}" ] && version_ge "${current_version}" "${MIN_DOCKER_VERSION}"; then
    log "Docker version ${current_version} is OK."
  else
    if [ -z "${current_version}" ]; then
      warn "Docker is not installed. Installing Docker..."
    else
      warn "Docker version ${current_version} is older than ${MIN_DOCKER_VERSION}. Updating Docker..."
    fi

    install_base_packages

    local os_id codename arch
    . /etc/os-release
    os_id="${ID}"
    codename="${VERSION_CODENAME:-}"
    arch="$(dpkg --print-architecture)"

    if [ -n "${codename}" ] && [[ "${os_id}" =~ ^(debian|ubuntu)$ ]]; then
      install -m 0755 -d /etc/apt/keyrings
      curl -fsSL "https://download.docker.com/linux/${os_id}/gpg" | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
      chmod a+r /etc/apt/keyrings/docker.gpg
      echo "deb [arch=${arch} signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/${os_id} ${codename} stable" \
        > /etc/apt/sources.list.d/docker.list
      apt update -y
      DEBIAN_FRONTEND=noninteractive apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin || \
        DEBIAN_FRONTEND=noninteractive apt install -y docker.io
    else
      DEBIAN_FRONTEND=noninteractive apt install -y docker.io
    fi
  fi

  systemctl enable docker >/dev/null 2>&1 || true
  systemctl restart docker >/dev/null 2>&1 || true

  if ! docker ps >/dev/null 2>&1; then
    err "Docker is not running."
    systemctl status docker --no-pager -l || true
    exit 1
  fi

  log "Docker is running: $(docker --version)"
}

get_server_ip() {
  if [ -n "${SERVER_IP}" ]; then
    return 0
  fi
  SERVER_IP="$(curl -4 -s --max-time 8 https://api.ipify.org || true)"
  if [ -z "${SERVER_IP}" ]; then
    SERVER_IP="$(curl -4 -s --max-time 8 https://ifconfig.me || true)"
  fi
  if [ -z "${SERVER_IP}" ]; then
    SERVER_IP="YOUR_SERVER_IP"
    warn "Could not detect public IPv4. Replace YOUR_SERVER_IP in result manually."
  fi
}

generate_reality_keys() {
  log "Pulling Xray image for Reality key generation..."
  docker pull "${XRAY_IMAGE}"

  local key_output priv pub
  key_output="$(docker run --rm "${XRAY_IMAGE}" x25519 2>&1 || true)"
  priv="$(echo "${key_output}" | awk -F': ' 'BEGIN{IGNORECASE=1}/Private key/ {print $2}' | tr -d '\r' | head -n1)"
  pub="$(echo "${key_output}" | awk -F': ' 'BEGIN{IGNORECASE=1}/Public key/ {print $2}' | tr -d '\r' | head -n1)"

  if [ -z "${priv}" ] || [ -z "${pub}" ]; then
    key_output="$(docker run --rm --entrypoint /usr/local/bin/xray "${XRAY_IMAGE}" x25519 2>&1 || true)"
    priv="$(echo "${key_output}" | awk -F': ' 'BEGIN{IGNORECASE=1}/Private key/ {print $2}' | tr -d '\r' | head -n1)"
    pub="$(echo "${key_output}" | awk -F': ' 'BEGIN{IGNORECASE=1}/Public key/ {print $2}' | tr -d '\r' | head -n1)"
  fi

  if [ -z "${priv}" ] || [ -z "${pub}" ]; then
    err "Reality key generation failed. Raw output:"
    echo "${key_output}"
    exit 1
  fi

  GENERATED_REALITY_PRIVATE_KEY="${priv}"
  GENERATED_REALITY_PUBLIC_KEY="${pub}"
}

prepare_generated_values() {
  GENERATED_XRAY_UUID="$(cat /proc/sys/kernel/random/uuid)"
  GENERATED_SHORT_ID="$(openssl rand -hex 8)"
  GENERATED_HY2_PASSWORD="$(openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c 24)"
  generate_reality_keys

  mkdir -p "${RESULT_DIR}"
  cat > "${RESULT_DIR}/generated-params.txt" <<EOF
XRAY_UUID=${GENERATED_XRAY_UUID}
REALITY_PRIVATE_KEY=${GENERATED_REALITY_PRIVATE_KEY}
REALITY_PUBLIC_KEY=${GENERATED_REALITY_PUBLIC_KEY}
SHORT_ID=${GENERATED_SHORT_ID}
HY2_PASSWORD=${GENERATED_HY2_PASSWORD}
EOF
  chmod 600 "${RESULT_DIR}/generated-params.txt"
}

read_or_generate_params() {
  prepare_generated_values

  echo ""
  echo "============================================================"
  echo "Generated deployment values / 已自动生成部署参数"
  echo "============================================================"
  echo "XRAY_UUID:           ${GENERATED_XRAY_UUID}"
  echo "REALITY_PRIVATE_KEY: ${GENERATED_REALITY_PRIVATE_KEY}"
  echo "REALITY_PUBLIC_KEY:  ${GENERATED_REALITY_PUBLIC_KEY}"
  echo "SHORT_ID:            ${GENERATED_SHORT_ID}"
  echo "HY2_PASSWORD:        ${GENERATED_HY2_PASSWORD}"
  echo "Saved to:            ${RESULT_DIR}/generated-params.txt"
  echo ""

  local have_all_existing=0
  if [ -n "${XRAY_UUID}" ] && [ -n "${REALITY_PRIVATE_KEY}" ] && [ -n "${REALITY_PUBLIC_KEY}" ] && [ -n "${SHORT_ID}" ] && [ -n "${HY2_PASSWORD}" ]; then
    have_all_existing=1
  fi

  if [ "${have_all_existing}" = "1" ]; then
    log "Using values from environment variables."
    return 0
  fi

  if [ "${AUTO_ACCEPT_GENERATED}" = "1" ]; then
    XRAY_UUID="${XRAY_UUID:-${GENERATED_XRAY_UUID}}"
    REALITY_PRIVATE_KEY="${REALITY_PRIVATE_KEY:-${GENERATED_REALITY_PRIVATE_KEY}}"
    REALITY_PUBLIC_KEY="${REALITY_PUBLIC_KEY:-${GENERATED_REALITY_PUBLIC_KEY}}"
    SHORT_ID="${SHORT_ID:-${GENERATED_SHORT_ID}}"
    HY2_PASSWORD="${HY2_PASSWORD:-${GENERATED_HY2_PASSWORD}}"
    log "AUTO_ACCEPT_GENERATED=1, using generated values."
    return 0
  fi

  if confirm "Use generated values? / 是否直接使用以上自动生成参数？" "Y"; then
    XRAY_UUID="${XRAY_UUID:-${GENERATED_XRAY_UUID}}"
    REALITY_PRIVATE_KEY="${REALITY_PRIVATE_KEY:-${GENERATED_REALITY_PRIVATE_KEY}}"
    REALITY_PUBLIC_KEY="${REALITY_PUBLIC_KEY:-${GENERATED_REALITY_PUBLIC_KEY}}"
    SHORT_ID="${SHORT_ID:-${GENERATED_SHORT_ID}}"
    HY2_PASSWORD="${HY2_PASSWORD:-${GENERATED_HY2_PASSWORD}}"
  else
    echo ""
    echo "Enter existing values. Press Enter to keep generated default where allowed."
    read -rp "Xray UUID [${GENERATED_XRAY_UUID}]: " XRAY_UUID
    XRAY_UUID="${XRAY_UUID:-${GENERATED_XRAY_UUID}}"

    read -rp "Reality Private Key [generated hidden, Enter to use generated]: " REALITY_PRIVATE_KEY
    REALITY_PRIVATE_KEY="${REALITY_PRIVATE_KEY:-${GENERATED_REALITY_PRIVATE_KEY}}"

    read -rp "Reality Public Key [generated hidden, Enter to use generated]: " REALITY_PUBLIC_KEY
    REALITY_PUBLIC_KEY="${REALITY_PUBLIC_KEY:-${GENERATED_REALITY_PUBLIC_KEY}}"

    read -rp "Short ID [${GENERATED_SHORT_ID}]: " SHORT_ID
    SHORT_ID="${SHORT_ID:-${GENERATED_SHORT_ID}}"

    read -rp "HY2 Password [${GENERATED_HY2_PASSWORD}]: " HY2_PASSWORD
    HY2_PASSWORD="${HY2_PASSWORD:-${GENERATED_HY2_PASSWORD}}"
  fi
}

validate_params() {
  local missing=0
  for name in XRAY_UUID REALITY_PRIVATE_KEY REALITY_PUBLIC_KEY SHORT_ID HY2_PASSWORD; do
    if [ -z "${!name:-}" ]; then
      err "Missing required value: ${name}"
      missing=1
    fi
  done
  if [ "${missing}" = "1" ]; then
    exit 1
  fi
}

confirm_summary() {
  echo ""
  echo "============================================================"
  echo "Deployment summary / 部署确认"
  echo "============================================================"
  echo "Version:             ${VERSION}"
  echo "Install dir:         ${INSTALL_DIR}"
  echo "Server IP:           ${SERVER_IP}"
  echo "Node name:           ${NODE_NAME}"
  echo "Xray TCP port:       ${XRAY_PORT}"
  echo "HY2 UDP port:        ${HY2_PORT}"
  echo "Nginx HTTP port:     ${NGINX_PORT}"
  echo "Reality SNI:         ${REALITY_SNI}"
  echo "Reality Dest:        ${REALITY_DEST}"
  echo "XRAY_UUID:           ${XRAY_UUID}"
  echo "Reality Public Key:  ${REALITY_PUBLIC_KEY}"
  echo "Short ID:            ${SHORT_ID}"
  echo "HY2 Password:        ${HY2_PASSWORD}"
  echo ""
  echo "Cloud firewall / security group must allow:"
  echo "  - ${XRAY_PORT}/tcp"
  echo "  - ${HY2_PORT}/udp"
  echo "  - ${NGINX_PORT}/tcp if Nginx is enabled"
  echo ""

  if ! confirm "Continue deployment? / 确认继续部署？" "Y"; then
    warn "Cancelled by user."
    exit 0
  fi
}

write_configs() {
  log "Writing configuration files..."
  mkdir -p "${INSTALL_DIR}/xray" "${INSTALL_DIR}/hysteria" "${INSTALL_DIR}/nginx/html" "${INSTALL_DIR}/nginx/conf.d" "${RESULT_DIR}"

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
          "serverNames": ["${REALITY_SNI}"],
          "privateKey": "${REALITY_PRIVATE_KEY}",
          "shortIds": ["${SHORT_ID}"]
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

  cat > "${INSTALL_DIR}/nginx/html/index.html" <<NGINXHTMLEOF
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <title>${NODE_NAME}</title>
  <style>
    body{margin:0;background:#0b0f0d;color:#dbe7dc;font-family:system-ui,-apple-system,Segoe UI,sans-serif;display:grid;place-items:center;min-height:100vh}
    main{max-width:760px;padding:48px;border:1px solid rgba(255,255,255,.12);border-radius:24px;background:rgba(255,255,255,.04)}
    h1{font-size:32px;margin:0 0 12px}p{line-height:1.7;color:#aab7ad}.tag{color:#a4c7a4;letter-spacing:.18em;text-transform:uppercase;font-size:12px}
  </style>
</head>
<body>
  <main>
    <div class="tag">Service Online</div>
    <h1>${NODE_NAME}</h1>
    <p>This server is running a containerized edge service stack.</p>
  </main>
</body>
</html>
NGINXHTMLEOF

  cat > "${INSTALL_DIR}/nginx/conf.d/default.conf" <<NGINXCONFEOF
server {
    listen ${NGINX_PORT} default_server;
    server_name _;
    root /usr/share/nginx/html;
    index index.html;

    location /healthz {
        add_header Content-Type text/plain;
        return 200 'ok\n';
    }

    location / {
        try_files \$uri /index.html;
    }
}
NGINXCONFEOF

  cat > "${RESULT_DIR}/server-env.sh" <<ENVEOF
export SERVER_IP='${SERVER_IP}'
export XRAY_PORT='${XRAY_PORT}'
export HY2_PORT='${HY2_PORT}'
export NGINX_PORT='${NGINX_PORT}'
export REALITY_SNI='${REALITY_SNI}'
export REALITY_DEST='${REALITY_DEST}'
export XRAY_UUID='${XRAY_UUID}'
export REALITY_PRIVATE_KEY='${REALITY_PRIVATE_KEY}'
export REALITY_PUBLIC_KEY='${REALITY_PUBLIC_KEY}'
export SHORT_ID='${SHORT_ID}'
export HY2_PASSWORD='${HY2_PASSWORD}'
EOF
  chmod 600 "${RESULT_DIR}/server-env.sh"
}

start_containers() {
  log "Pulling Docker images..."
  docker pull "${XRAY_IMAGE}"
  docker pull "${HY2_IMAGE}"
  if [ "${INSTALL_NGINX}" = "1" ]; then
    docker pull "${NGINX_IMAGE}"
  fi

  log "Removing old containers if any..."
  docker rm -f xray-reality hysteria2-server nginx-decoy >/dev/null 2>&1 || true

  log "Starting Xray Reality container..."
  docker run -d \
    --name xray-reality \
    --restart always \
    --network host \
    -v "${INSTALL_DIR}/xray/config.json:/etc/xray/config.json:ro" \
    "${XRAY_IMAGE}" run -config /etc/xray/config.json

  log "Starting Hysteria2 container..."
  docker run -d \
    --name hysteria2-server \
    --restart always \
    --network host \
    -v "${INSTALL_DIR}/hysteria/config.yaml:/etc/hysteria/config.yaml:ro" \
    -v "${INSTALL_DIR}/hysteria/hy2.crt:/etc/hysteria/hy2.crt:ro" \
    -v "${INSTALL_DIR}/hysteria/hy2.key:/etc/hysteria/hy2.key:ro" \
    "${HY2_IMAGE}" server -c /etc/hysteria/config.yaml

  if [ "${INSTALL_NGINX}" = "1" ]; then
    log "Starting Nginx container..."
    docker run -d \
      --name nginx-decoy \
      --restart always \
      --network host \
      -v "${INSTALL_DIR}/nginx/html:/usr/share/nginx/html:ro" \
      -v "${INSTALL_DIR}/nginx/conf.d/default.conf:/etc/nginx/conf.d/default.conf:ro" \
      "${NGINX_IMAGE}"
  else
    warn "INSTALL_NGINX=0, skipping Nginx."
  fi
}

write_result() {
  local vless_link hy2_link
  vless_link="vless://${XRAY_UUID}@${SERVER_IP}:${XRAY_PORT}?type=tcp&security=reality&pbk=${REALITY_PUBLIC_KEY}&fp=chrome&sni=${REALITY_SNI}&sid=${SHORT_ID}&flow=xtls-rprx-vision#${NODE_NAME}-Xray-Reality-TCP"
  hy2_link="hy2://${HY2_PASSWORD}@${SERVER_IP}:${HY2_PORT}?insecure=1&sni=${REALITY_SNI}#${NODE_NAME}-HY2-UDP"

  cat > "${RESULT_DIR}/client-info.txt" <<INFOEOF
============================================================
Xray + Hysteria2 + Nginx Docker Deploy Result
Version: ${VERSION}
============================================================

Server IP:
${SERVER_IP}

Required cloud firewall / security group:
- ${XRAY_PORT}/tcp for Xray Reality
- ${HY2_PORT}/udp for Hysteria2
- ${NGINX_PORT}/tcp for Nginx HTTP health/decoy page

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
${vless_link}

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
${hy2_link}

------------------------------------------------------------
Nginx
------------------------------------------------------------
URL: http://${SERVER_IP}:${NGINX_PORT}/
Health: http://${SERVER_IP}:${NGINX_PORT}/healthz
Container: nginx-decoy

------------------------------------------------------------
Files
------------------------------------------------------------
Install directory: ${INSTALL_DIR}
Generated values: ${RESULT_DIR}/generated-params.txt
Final server env: ${RESULT_DIR}/server-env.sh
Client info: ${RESULT_DIR}/client-info.txt

------------------------------------------------------------
Docker Commands
------------------------------------------------------------
Status:
docker ps

Logs:
docker logs xray-reality --tail=100
docker logs hysteria2-server --tail=100
docker logs nginx-decoy --tail=100

Restart:
docker restart xray-reality hysteria2-server nginx-decoy

Remove:
docker rm -f xray-reality hysteria2-server nginx-decoy

============================================================
INFOEOF
  chmod 600 "${RESULT_DIR}/client-info.txt"

  echo ""
  echo "============================================================"
  echo "Deployment completed / 部署完成"
  echo "============================================================"
  cat "${RESULT_DIR}/client-info.txt"
}

post_check() {
  echo ""
  log "Container status:"
  docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}' || true

  echo ""
  log "Listening ports:"
  ss -lntup | grep -E ":(${XRAY_PORT}|${HY2_PORT}|${NGINX_PORT})" || true
}

main() {
  need_root
  need_apt
  echo "============================================================"
  echo "Xray + Hysteria2 + Nginx Docker Installer v${VERSION}"
  echo "============================================================"
  install_base_packages
  install_or_update_docker
  get_server_ip
  read_or_generate_params
  validate_params
  confirm_summary
  write_configs
  start_containers
  write_result
  post_check
}

main "$@"
