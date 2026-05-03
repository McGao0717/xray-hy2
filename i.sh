#!/usr/bin/env bash
set -euo pipefail

SCRIPT_URL="${SCRIPT_URL:-https://raw.githubusercontent.com/McGao0717/xray-hy2/main/install-proxy-interactive.sh}"

exec bash <(curl -fsSL "${SCRIPT_URL}")
