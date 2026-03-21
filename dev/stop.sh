#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEV="$ROOT/dev"
BBB_DOCKER="$DEV/bbb-docker"

VOLUMES=""
if [ "${1:-}" = "--volumes" ] || [ "${1:-}" = "-v" ]; then
    VOLUMES="-v"
    echo "Stopping BBB and removing volumes..."
else
    echo "Stopping BBB..."
fi

COMPOSE_FILES=(
    -f "$DEV/docker-compose.bbb.yml"
    -f "$DEV/docker-compose.override.yml"
)
if [ "${REVERSE_PROXY:-haproxy}" = "traefik" ]; then
    COMPOSE_FILES+=(-f "$DEV/docker-compose.traefik.yml")
fi

docker compose \
    --project-directory "$BBB_DOCKER" \
    "${COMPOSE_FILES[@]}" \
    down $VOLUMES

echo "BBB stopped."
