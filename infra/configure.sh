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

# These must match clientId / clientSecret in config/init_data.json.
CASDOOR_CLIENT_ID="a387a4892ee19b1a2249"
CASDOOR_CLIENT_SECRET="dbf205949d704de81b0b5b3603174e23fbecc354"

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
set_env AUTH_CASDOOR_ISSUER  "https://${DOMAIN}/casdoor"
set_env AUTH_CASDOOR_ID      "${CASDOOR_CLIENT_ID}"
set_env AUTH_CASDOOR_SECRET  "${CASDOOR_CLIENT_SECRET}"
set_env AUTH_TRUST_HOST      "true"
set_env APP_URL               "https://${DOMAIN}"
set_env NEXTAUTH_URL          "https://${DOMAIN}"
echo "      Done."

# ---------------------------------------------------------------------------
# 2. Update origin in casdoor-app.conf
# ---------------------------------------------------------------------------
echo "[2/5] Updating origin/originFrontend in ${CASDOOR_CONF}..."
sed -i "s|^origin = .*|origin = https://${DOMAIN}/casdoor|" "$CASDOOR_CONF"
# originFrontend drives the authorization_endpoint in OIDC discovery; it must
# also carry the /casdoor prefix so the browser OAuth redirect lands on the
# correct Caddy route.
sed -i "s|^originFrontend = .*|originFrontend = https://${DOMAIN}/casdoor|" "$CASDOOR_CONF"
echo "      Done."

# ---------------------------------------------------------------------------
# 3. Install updated Caddyfile and reload Caddy
# ---------------------------------------------------------------------------
echo "[3/5] Installing Caddyfile and reloading Caddy..."
cp "${INSTALL_DIR}/infra/Caddyfile" /etc/caddy/Caddyfile
systemctl reload caddy
echo "      Done."

# ---------------------------------------------------------------------------
# 4. Recreate Casdoor so it picks up new config, then wait for reimport
#    NOTE: "restart" replays the old container spec; "up --force-recreate"
#    re-reads docker-compose.yml + .env and applies any changes.
# ---------------------------------------------------------------------------
echo "[4/5] Recreating Casdoor (picks up new config + reimports init_data.json)..."
cd "$INSTALL_DIR"
docker compose up -d --force-recreate --no-deps casdoor
echo "      Waiting 15 s for Casdoor to fully start and reimport init data..."
sleep 15

# ---------------------------------------------------------------------------
# 5. Patch DB post-reimport, then recreate LobeChat with the new .env.
# ---------------------------------------------------------------------------
echo "[5/5] Patching Casdoor DB and recreating LobeChat..."
PG_PASS=$(grep '^POSTGRES_PASSWORD=' "$ENV_FILE" | cut -d= -f2-)

docker exec -e PGPASSWORD="$PG_PASS" shared-postgres \
    psql -U postgres -d casdoor -c \
    "UPDATE application
     SET redirect_uris = '[\"https://${DOMAIN}/api/auth/callback/casdoor\"]',
         homepage_url  = 'https://${DOMAIN}'
     WHERE name = 'lobechat';"

docker compose up -d --force-recreate --no-deps lobe-chat
echo "      Waiting 5 s for LobeChat to come up..."
sleep 5

echo ""
echo "=== Done. Visit https://${DOMAIN} ==="
