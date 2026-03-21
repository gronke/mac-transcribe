#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEV="$ROOT/dev"
BBB_DOCKER="$DEV/bbb-docker"

# ---- 1. Submodule (provides config files for BBB services) ----
if [ ! -f "$BBB_DOCKER/docker-compose.tmpl.yml" ]; then
    echo "Initialising bbb-docker submodule..."
    git -C "$ROOT" submodule update --init dev/bbb-docker
fi

# ---- 2. .env (first-run setup) ----
if [ ! -f "$BBB_DOCKER/.env" ]; then
    cp "$DEV/.env.example" "$BBB_DOCKER/.env"

    # Detect host IP
    HOST_IP=$(hostname -I | awk '{print $1}')
    sed -i "s/__DETECT__/$HOST_IP/g" "$BBB_DOCKER/.env"
    echo "Detected host IP: $HOST_IP"

    # Prompt for domain and email
    read -rp "Domain name (e.g. bbb.example.com): " DOMAIN
    read -rp "Let's Encrypt email: " LE_EMAIL
    echo "DOMAIN=$DOMAIN" >> "$BBB_DOCKER/.env"
    echo "LETSENCRYPT_EMAIL=$LE_EMAIL" >> "$BBB_DOCKER/.env"

    # Generate Greenlight password
    GL_PASSWORD="$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 16)!"
    echo "" >> "$BBB_DOCKER/.env"
    echo "# Auto-generated Greenlight credentials (shared password)" >> "$BBB_DOCKER/.env"
    echo "GL_PASSWORD=$GL_PASSWORD" >> "$BBB_DOCKER/.env"
fi

# ---- 3. Config files ----
DOMAIN=$(grep ^DOMAIN "$BBB_DOCKER/.env" | cut -d= -f2)
mkdir -p "$BBB_DOCKER/conf"
sed "s/__DOMAIN__/$DOMAIN/g" "$DEV/bbb-html5.yml" > "$BBB_DOCKER/conf/bbb-html5.yml"

# ---- 4. Start BBB (builds plugin via Dockerfile.nginx multi-stage) ----
COMPOSE_FILES=(
    -f "$DEV/docker-compose.bbb.yml"
    -f "$DEV/docker-compose.override.yml"
)

if [ "${REVERSE_PROXY:-haproxy}" = "traefik" ]; then
    if ! docker network inspect proxy &>/dev/null; then
        echo "Error: 'proxy' Docker network not found."
        echo "Create it with: docker network create proxy"
        echo "Then start the global Traefik instance."
        exit 1
    fi
    COMPOSE_FILES+=(-f "$DEV/docker-compose.traefik.yml")
    echo "Starting BigBlueButton at https://$DOMAIN (via Traefik)..."
else
    echo "Starting BigBlueButton at https://$DOMAIN (via HAProxy)..."
fi

docker compose \
    --project-directory "$BBB_DOCKER" \
    "${COMPOSE_FILES[@]}" \
    up --build -d

# ---- 5. Seed Greenlight users + harden ----
GL_PASSWORD=$(grep ^GL_PASSWORD "$BBB_DOCKER/.env" | cut -d= -f2)
GREENLIGHT="bbb-docker-greenlight-1"

echo "Waiting for Greenlight..."
for i in $(seq 1 30); do
    if docker exec "$GREENLIGHT" bundle exec rake --version &>/dev/null; then
        break
    fi
    sleep 2
done

# Create users (idempotent — fails silently if they already exist)
for args in \
    "Admin,admin@example.com,$GL_PASSWORD" \
    "Alice,alice@example.com,$GL_PASSWORD" \
    "Bob,bob@example.com,$GL_PASSWORD"; do
    docker exec "$GREENLIGHT" bundle exec rake "admin:create[$args]" 2>/dev/null || true
done

# Harden: disable open registration
docker exec "$GREENLIGHT" bundle exec rails runner '
  reg = SiteSetting.joins(:setting).find_by(settings: {name: "RegistrationMethod"})
  reg.update!(value: "invite") if reg&.value != "invite"
' 2>/dev/null || true

echo ""
echo "================================================"
echo "  BBB running at https://$DOMAIN"
echo "  Shared secret: $(grep ^SHARED_SECRET "$BBB_DOCKER/.env" | cut -d= -f2)"
echo ""
echo "  Greenlight users (password: $GL_PASSWORD):"
echo "    admin@example.com  (admin)"
echo "    alice@example.com"
echo "    bob@example.com"
echo "  Registration: invite-only"
echo ""
echo "  Test the API:"
echo "    curl -s https://$DOMAIN/bigbluebutton/api"
echo ""
echo "  Use with bbb.sh:"
echo "    ./bbb.sh --server https://$DOMAIN/bigbluebutton/api \\"
echo "             --secret local-dev-secret \\"
echo "             --meeting-id test"
echo "================================================"
