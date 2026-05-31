#!/usr/bin/env bash
# EC2 user-data bootstrap script for LobeChat.
# Runs as root on first boot. Replace every CHANGE_ME before deploying.
# Progress is logged to /var/log/cloud-init-output.log (default).

set -euo pipefail

# ---------------------------------------------------------------------------
# Secrets — REPLACE BEFORE DEPLOYING
# ---------------------------------------------------------------------------
DUCKDNS_TOKEN="84312cb0-aa15-4be4-b0f0-c8672b90c674"
KEY_VAULTS_SECRET="2VoGUkROiIMsGQiOQfBwktyUuUZDO+lFSJuBiUtnT8M="        # min 32 chars
NEXT_AUTH_SECRET="lwU6w5Ce0YGHNcUYrhTCFSB+tfrC9MADuR2Xpulbsoc="         # min 32 chars
POSTGRES_PASSWORD="cUJ81n4QNXyhaQF9fE1lHw=="
MINIO_ROOT_USER="minioadmin"
MINIO_ROOT_PASSWORD="EtNhiYnt0NzupeA1rV4uCQ=="
MCPHUB_ADMIN_USER="admin"
MCPHUB_ADMIN_PASSWORD="mKk8FeeLBzzlmv0+PXv5HQ=="
AUTH_CASDOOR_ID="a387a4892ee19b1a2249"
AUTH_CASDOOR_SECRET="dbf205949d704de81b0b5b3603174e23fbecc354"
OPENROUTER_API_KEY="not-used"
DEEPSEEK_API_KEY="sk-82572e2fac79473984470098f67c2412"
HF_TOKEN="not-used"
OPENAPI_MCP_HEADERS='{"Authorization":"Bearer CHANGE_ME","Notion-Version":"2022-06-28"}'
# ---------------------------------------------------------------------------

DOMAIN="lucasescayola-lobechat.duckdns.org"
REPO="https://github.com/LucasEscayola/lobechat-aws"
INSTALL_DIR="/opt/lobechat"

echo ">>> [1/8] Installing system packages..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq git curl jq ca-certificates gnupg

# ---------------------------------------------------------------------------
# Docker Engine + Compose plugin
# ---------------------------------------------------------------------------
echo ">>> [2/8] Installing Docker..."
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
  -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc

echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
  https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}") stable" \
  | tee /etc/apt/sources.list.d/docker.list > /dev/null

apt-get update -qq
apt-get install -y -qq \
  docker-ce docker-ce-cli containerd.io \
  docker-buildx-plugin docker-compose-plugin

systemctl enable --now docker

# ---------------------------------------------------------------------------
# Caddy
# ---------------------------------------------------------------------------
echo ">>> [3/8] Installing Caddy..."
apt-get install -y -qq debian-keyring debian-archive-keyring apt-transport-https
curl -1sLf "https://dl.cloudsmith.io/public/caddy/stable/gpg.key" \
  | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
curl -1sLf "https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt" \
  | tee /etc/apt/sources.list.d/caddy-stable.list > /dev/null

apt-get update -qq
apt-get install -y -qq caddy
systemctl stop caddy 2>/dev/null || true

# ---------------------------------------------------------------------------
# Clone repository
# ---------------------------------------------------------------------------
echo ">>> [4/8] Cloning repository..."
git clone "$REPO" "$INSTALL_DIR"

# ---------------------------------------------------------------------------
# Create .env
# ---------------------------------------------------------------------------
echo ">>> [5/8] Writing .env..."
cat > "${INSTALL_DIR}/.env" <<EOF
# ── LobeChat ──────────────────────────────────────────────────────────────
KEY_VAULTS_SECRET=${KEY_VAULTS_SECRET}
NEXT_AUTH_SECRET=${NEXT_AUTH_SECRET}
APP_URL=https://${DOMAIN}
NEXTAUTH_URL=https://${DOMAIN}
HOST_DOMAIN=${DOMAIN}
FEATURE_FLAGS=-changelog,-check_updates

# ── Casdoor SSO ───────────────────────────────────────────────────────────
AUTH_CASDOOR_ID=${AUTH_CASDOOR_ID}
AUTH_CASDOOR_SECRET=${AUTH_CASDOOR_SECRET}
AUTH_CASDOOR_ISSUER=http://casdoor:8000

# ── PostgreSQL ────────────────────────────────────────────────────────────
POSTGRES_PASSWORD=${POSTGRES_PASSWORD}

# ── MinIO ─────────────────────────────────────────────────────────────────
MINIO_ROOT_USER=${MINIO_ROOT_USER}
MINIO_ROOT_PASSWORD=${MINIO_ROOT_PASSWORD}

# ── MCPHub ────────────────────────────────────────────────────────────────
MCPHUB_ADMIN_USER=${MCPHUB_ADMIN_USER}
MCPHUB_ADMIN_PASSWORD=${MCPHUB_ADMIN_PASSWORD}

# ── External APIs ─────────────────────────────────────────────────────────
OPENROUTER_API_KEY=${OPENROUTER_API_KEY}
DEEPSEEK_API_KEY=${DEEPSEEK_API_KEY}
HF_TOKEN=${HF_TOKEN}
OPENAPI_MCP_HEADERS=${OPENAPI_MCP_HEADERS}

# ── AWS ───────────────────────────────────────────────────────────────────
AWS_REGION=eu-west-1

# ── DuckDNS ───────────────────────────────────────────────────────────────
DUCKDNS_TOKEN=${DUCKDNS_TOKEN}
EOF

chmod 600 "${INSTALL_DIR}/.env"

# ---------------------------------------------------------------------------
# Update DuckDNS with this instance's public IP
# ---------------------------------------------------------------------------
echo ">>> [6/8] Updating DuckDNS..."
# IMDSv2 token required on modern instances
IMDS_TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 60")
PUBLIC_IP=$(curl -s -H "X-aws-ec2-metadata-token: ${IMDS_TOKEN}" \
  "http://169.254.169.254/latest/meta-data/public-ipv4")

DUCKDNS_RESP=$(curl -s \
  "https://www.duckdns.org/update?domains=lucasescayola-lobechat&token=${DUCKDNS_TOKEN}&ip=${PUBLIC_IP}")
echo "    DuckDNS response: ${DUCKDNS_RESP} (ip=${PUBLIC_IP})"

# ---------------------------------------------------------------------------
# Configure and start Caddy
# ---------------------------------------------------------------------------
echo ">>> [7/8] Configuring Caddy..."
cp "${INSTALL_DIR}/infra/Caddyfile" /etc/caddy/Caddyfile
systemctl enable caddy
systemctl start caddy

# ---------------------------------------------------------------------------
# Start Docker Compose (all services except vllm)
# ---------------------------------------------------------------------------
echo ">>> [8/8] Starting Docker Compose stack (vllm excluded)..."
cd "$INSTALL_DIR"
docker compose up -d --scale vllm=0

echo ""
echo "=== Bootstrap complete ==="
echo "    Domain : https://${DOMAIN}"
echo "    Stack  : $(docker compose ps --services | tr '\n' ' ')"
echo ""
echo "If CHANGE_ME placeholders were not replaced, edit .env and run:"
echo "    cd ${INSTALL_DIR} && docker compose up -d --scale vllm=0"
