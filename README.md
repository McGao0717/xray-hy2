# xray-hy2

One-click Docker deployment for Xray VLESS Reality TCP, Hysteria2 UDP, and an Nginx decoy/status site.

一键 Docker 部署 Xray VLESS Reality TCP、Hysteria2 UDP 和 Nginx 伪装/状态页面。

## Features / 功能

- Runs Xray, Hysteria2, and Nginx as Docker containers.
- Checks Docker before deployment. If Docker is missing or older than the minimum version, the script installs or updates it.
- Automatically generates Xray UUID, Reality private/public keys, short ID, and Hysteria2 password.
- Saves generated values first, then asks whether to use them or enter existing values.
- Supports non-interactive deployment with environment variables.
- Outputs ready-to-import VLESS and HY2 client links.
- Uses Docker host network mode by default.

- Xray、Hysteria2、Nginx 全部运行在 Docker 容器内。
- 安装前检查 Docker；如果没有安装或版本过旧，会自动安装/更新。
- 自动生成 Xray UUID、Reality 私钥/公钥、Short ID、Hysteria2 密码。
- 先保存自动生成的参数，再询问是否使用，或手动输入已有参数。
- 支持通过环境变量进行无人值守部署。
- 自动输出可导入客户端的 VLESS 和 HY2 链接。
- 默认使用 Docker host 网络模式。

## Requirements / 系统要求

- Debian or Ubuntu server
- Root user
- Public IPv4 address recommended
- Open firewall/security group ports:
  - `1443/tcp` for Xray Reality
  - `1443/udp` for Hysteria2
  - `80/tcp` for Nginx, if enabled

- Debian 或 Ubuntu 服务器
- root 用户
- 建议具备公网 IPv4
- 防火墙/安全组需要放行：
  - `1443/tcp` 用于 Xray Reality
  - `1443/udp` 用于 Hysteria2
  - `80/tcp` 用于 Nginx，如果启用

## Quick Start / 快速开始

Short interactive command:

短交互命令：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/McGao0717/xray-hy2/main/i.sh)
```

Run the interactive installer:

运行交互式安装：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/McGao0717/xray-hy2/main/install-proxy-interactive.sh)
```

Or use the bootstrap script, which downloads the latest repo first:

也可以使用自动拉取仓库的一键脚本：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/McGao0717/xray-hy2/main/auto-install.sh)
```

During installation, the script will:

安装过程中脚本会：

1. Check root and Debian/Ubuntu environment.
2. Install required base packages.
3. Check Docker version and install/update Docker when needed.
4. Generate UUID, Reality keys, short ID, and HY2 password.
5. Save generated values to `/opt/proxy-stack/result/generated-params.txt`.
6. Ask whether to use generated values or enter existing values.
7. Create configs and start Docker containers.
8. Print client links and save them to `/opt/proxy-stack/result/client-info.txt`.

## Use Existing Values / 使用已有参数

When asked `Use generated values?`, answer `n`, then enter your existing values:

当提示 `Use generated values? / 是否使用以上自动生成的参数？` 时，输入 `n`，然后填写已有参数：

- `XRAY_UUID`
- `REALITY_PRIVATE_KEY`
- `REALITY_PUBLIC_KEY`
- `SHORT_ID`
- `HY2_PASSWORD`

Press Enter on any prompt to keep the generated default for that field.

任意字段直接回车，会使用自动生成的默认值。

## Non-Interactive Install / 无人值守安装

Use generated values automatically:

自动使用生成参数：

```bash
AUTO_ACCEPT_GENERATED=1 SKIP_CONFIRM=1 bash <(curl -fsSL https://raw.githubusercontent.com/McGao0717/xray-hy2/main/install-proxy-interactive.sh)
```

Use your own values:

使用你自己的已有参数：

```bash
XRAY_UUID="your-uuid" \
REALITY_PRIVATE_KEY="your-private-key" \
REALITY_PUBLIC_KEY="your-public-key" \
SHORT_ID="your-short-id" \
HY2_PASSWORD="your-hy2-password" \
SKIP_CONFIRM=1 \
bash <(curl -fsSL https://raw.githubusercontent.com/McGao0717/xray-hy2/main/install-proxy-interactive.sh)
```

## Custom Options / 自定义选项

You can override defaults with environment variables:

可以通过环境变量覆盖默认值：

```bash
XRAY_PORT=2443 \
HY2_PORT=2443 \
NGINX_PORT=8080 \
REALITY_SNI=www.cloudflare.com \
REALITY_DEST=www.cloudflare.com:443 \
NODE_NAME=my-node \
bash <(curl -fsSL https://raw.githubusercontent.com/McGao0717/xray-hy2/main/install-proxy-interactive.sh)
```

Available options:

可用选项：

- `INSTALL_DIR`: default `/opt/proxy-stack`
- `XRAY_PORT`: default `1443`
- `HY2_PORT`: default `1443`
- `NGINX_PORT`: default `80`
- `REALITY_SNI`: default `www.cloudflare.com`
- `REALITY_DEST`: default `www.cloudflare.com:443`
- `NODE_NAME`: default `Xray-HY2-Docker`
- `MIN_DOCKER_VERSION`: default `20.10.0`
- `INSTALL_NGINX`: default `1`; set `0` to skip Nginx
- `SERVER_IP`: set manually if public IP detection fails
- `XRAY_IMAGE`: default `ghcr.io/xtls/xray-core:latest`
- `HY2_IMAGE`: default `tobyxdd/hysteria:v2`
- `NGINX_IMAGE`: default `nginx:alpine`

## Output Files / 输出文件

After installation:

安装完成后：

- Generated values: `/opt/proxy-stack/result/generated-params.txt`
- Final environment values: `/opt/proxy-stack/result/server-env.sh`
- Client links and connection details: `/opt/proxy-stack/result/client-info.txt`
- Xray config: `/opt/proxy-stack/xray/config.json`
- Hysteria2 config: `/opt/proxy-stack/hysteria/config.yaml`
- Nginx config: `/opt/proxy-stack/nginx/conf.d/default.conf`

These files contain secrets. Keep them private.

这些文件包含密钥和密码，请妥善保管。

## Docker Commands / 常用 Docker 命令

```bash
docker ps
docker logs xray-reality --tail=100
docker logs hysteria2-server --tail=100
docker logs nginx-decoy --tail=100
docker restart xray-reality hysteria2-server nginx-decoy
docker rm -f xray-reality hysteria2-server nginx-decoy
```

## Version Notes / 版本更新说明

### v2.1.0

- Added automatic Docker version check and install/update flow.
- Added generate-first parameter workflow: UUID, Reality keys, short ID, and HY2 password are generated and saved before confirmation.
- Added choice to use generated values or manually enter existing values.
- Added short install entrypoint: `i.sh`.
- Fixed Reality key parsing for newer Xray output such as `PrivateKey` and `Password (PublicKey)`.
- Simplified `auto-install.sh` so it downloads the repo and delegates all deployment logic to the main installer.
- Fixed broken Chinese prompts and improved bilingual output.
- Updated README with Chinese and English usage, features, options, and troubleshooting commands.

- 新增 Docker 版本检查与自动安装/更新流程。
- 新增“先自动生成并保存参数，再询问是否使用”的流程。
- 支持选择自动生成参数，或手动输入已有 UUID、Reality key、Short ID、HY2 密码。
- 新增短命令入口 `i.sh`。
- 修复新版 Xray 输出 `PrivateKey` 和 `Password (PublicKey)` 时 Reality 密钥解析失败的问题。
- 简化 `auto-install.sh`，统一由主安装脚本处理部署逻辑。
- 修复中文提示乱码，完善中英文输出。
- 更新 README，补充中英文使用方法、功能介绍、配置选项和常用命令。
