#!/usr/bin/env bash
# Fixes Casdoor SSO configuration for EC2 deployment behind a subdomain
# reverse proxy.  Run once on the EC2 instance as root after the stack is up.
#
# Usage: sudo bash /opt/lobechat/infra/configure.sh

set -euo pipefail

DOMAIN="lucasescayola-lobechat.duckdns.org"
INSTALL_DIR="/opt/lobechat"
ENV_FILE="${INSTALL_DIR}/.env"
CASDOOR_CONF="${INSTALL_DIR}/config/casdoor-app.conf"

echo "=== Casdoor SSO fix: ${DOMAIN} ==="
echo ""

# ---------------------------------------------------------------------------
# Helper: replace a key=value line in .env, or append if the key is absent.
# ---------------------------------------------------------------------------
set_env() {
    local key="$1" val="$2"
    if grep -q "^${key}=" "$ENV_FILE"; then
        sed -i "s|^${key}=.*|${key}=${val}|" "$ENV_FILE"
    else
        echo "${key}=${val}" >> "$ENV_FILE"
    fi
}

# ---------------------------------------------------------------------------
# 1. Update .env
# ---------------------------------------------------------------------------
echo "[1/5] Updating ${ENV_FILE}..."
set_env AUTH_CASDOOR_ISSUER "https://${DOMAIN}/casdoor"
set_env AUTH_TRUST_HOST     "true"
set_env APP_URL              "https://${DOMAIN}"
set_env NEXTAUTH_URL         "https://${DOMAIN}"
echo "      Done."

# ---------------------------------------------------------------------------
# 2. Update Casdoor application row in Postgres
# ---------------------------------------------------------------------------
echo "[2/5] Patching Casdoor application record in Postgres..."
PG_PASS=$(grep '^POSTGRES_PASSWORD=' "$ENV_FILE" | cut -d= -f2-)

docker exec -e PGPASSWORD="$PG_PASS" shared-postgres \
    psql -U postgres -d casdoor -c \
    "UPDATE application
     SET redirect_uris = '[\"https://${DOMAIN}/api/auth/callback/casdoor\"]',
         homepage_url  = 'https://${DOMAIN}'
     WHERE name = 'lobechat';"

docker exec -e PGPASSWORD="$PG_PASS" shared-postgres \
    psql -U postgres -d casdoor -c \
    "UPDATE application
     SET origin = 'https://${DOMAIN}/casdoor'
     WHERE name = 'lobechat';"

echo "      Done."

# ---------------------------------------------------------------------------
# 3. Update origin in casdoor-app.conf
# ---------------------------------------------------------------------------
echo "[3/5] Updating origin in ${CASDOOR_CONF}..."
sed -i "s|^origin = .*|origin = https://${DOMAIN}/casdoor|" "$CASDOOR_CONF"
echo "      Done."

# ---------------------------------------------------------------------------
# 4. Install updated Caddyfile and reload Caddy
# ---------------------------------------------------------------------------
echo "[4/5] Installing Caddyfile and reloading Caddy..."
cp "${INSTALL_DIR}/infra/Caddyfile" /etc/caddy/Caddyfile
systemctl reload caddy
echo "      Done."

# ---------------------------------------------------------------------------
# 5. Restart Casdoor, then LobeChat (dependency order)
# ---------------------------------------------------------------------------
echo "[5/5] Restarting services..."
cd "$INSTALL_DIR"

docker compose restart casdoor
echo "      Waiting 10 s for Casdoor to become ready..."
sleep 10

docker compose restart lobe-chat
echo "      Waiting 5 s for LobeChat to come up..."
sleep 5

echo ""
echo "=== Done. Visit https://${DOMAIN} ==="
