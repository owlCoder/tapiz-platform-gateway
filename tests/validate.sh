#!/usr/bin/env sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

GATEWAY_ENV_FILE="$root/.env.example" \
  docker compose --env-file "$root/.env.example" -f "$root/docker-compose.yml" config >/dev/null

docker run --rm \
  -e CADDY_EMAIL=ops@example.invalid \
  -e TAPIZ_API_DOMAIN=api.tapiz.test \
  -e AURA_API_DOMAIN=api.aura.test \
  -v "$root/Caddyfile:/etc/caddy/Caddyfile:ro" \
  -v "$root/sites:/etc/caddy/sites:ro" \
  -v "$root/snippets:/etc/caddy/snippets:ro" \
  caddy:2.10-alpine \
  caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
