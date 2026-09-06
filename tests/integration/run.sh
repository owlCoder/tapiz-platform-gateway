#!/usr/bin/env sh
# Disposable local integration harness for the shared vps-gateway Caddy.
#
# Proves, against the REAL gateway Caddyfile/docker-compose.yml (unmodified —
# this script never edits the repo's own config), that a standalone gateway can
# independently route Tapiz and Aura over their own external edge networks,
# using minimal HTTP stub upstreams instead of the real applications/databases.
#
# Never touches a real VPS, DNS, GitHub, external database, or any secret.
# Everything this script creates (networks, containers, the gateway's own
# .env) is removed by the `cleanup` trap, on both success and failure.
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
integration_dir="$root/tests/integration"

TAPIZ_STUB_COMPOSE="$integration_dir/docker-compose.tapiz-stub.yml"
AURA_STUB_COMPOSE="$integration_dir/docker-compose.aura-stub.yml"
GATEWAY_COMPOSE="$root/docker-compose.yml"
GATEWAY_ENV="$integration_dir/.env.integration"

TAPIZ_HOST="api.tapiz.test"
AURA_HOST="api.aura.test"
GATEWAY_PORT="18080"
GATEWAY_TLS_PORT="18443"

pass_count=0
fail_count=0
failures=""

log() { printf '%s\n' "$*"; }

check() {
  description=$1
  if [ "$2" = "0" ]; then
    pass_count=$((pass_count + 1))
    log "  PASS: $description"
  else
    fail_count=$((fail_count + 1))
    failures="$failures\n  FAIL: $description"
    log "  FAIL: $description"
  fi
}

# Evaluates $1 as a test expression (e.g. '[ "$code" = "200" ]') and reports
# $2 as the description, WITHOUT ever letting a false result trip `set -e` and
# silently abort the whole script before `check` runs — confirmed by direct
# reproduction: a bare `[ ... ] && [ ... ]` immediately followed by
# `check ... $?` aborts the entire script the first time the test is actually
# false, since a failing command not inside an if/while/&&/|| chain triggers
# `set -e` on its own, and by then it is too late to call `check` at all. Every
# assertion in this script goes through this helper instead of a bare `[ ]`.
assert() {
  expr=$1
  description=$2
  if eval "$expr"; then
    check "$description" 0
  else
    check "$description" 1
  fi
}

cleanup() {
  status=$?
  log ""
  log "== Teardown =="
  docker compose -p platform-gateway-test --env-file "$GATEWAY_ENV" \
    -f "$GATEWAY_COMPOSE" down -v --remove-orphans >/dev/null 2>&1 || true
  docker compose -f "$TAPIZ_STUB_COMPOSE" down -v --remove-orphans >/dev/null 2>&1 || true
  docker compose -f "$AURA_STUB_COMPOSE" down -v --remove-orphans >/dev/null 2>&1 || true
  docker network rm tapiz-edge-test aura-edge-test >/dev/null 2>&1 || true
  rm -f "$GATEWAY_ENV"
  log "Removed disposable containers, volumes, and edge networks created by this run."
  exit "$status"
}
trap cleanup EXIT INT TERM

log "== 0. caddy validate (real config, unmodified) =="
sh "$root/tests/validate.sh"
check "caddy validate + compose config parse cleanly" $?

log ""
log "== 1. Create disposable external edge networks =="
# Named distinctly from the real 'tapiz-edge'/'aura-edge' defaults so this test
# can never collide with, attach to, or be mistaken for a real product network
# already present on this machine.
export TAPIZ_EDGE_NETWORK="tapiz-edge-test"
export AURA_EDGE_NETWORK="aura-edge-test"
docker network create "$TAPIZ_EDGE_NETWORK" >/dev/null
docker network create "$AURA_EDGE_NETWORK" >/dev/null
check "created disposable tapiz-edge-test and aura-edge-test networks" $?

log ""
log "== 2. Bring up Tapiz + Aura stub upstreams (no host ports) =="
docker compose -f "$TAPIZ_STUB_COMPOSE" up -d --quiet-pull
docker compose -f "$AURA_STUB_COMPOSE" up -d --quiet-pull
sleep 2
check "stub upstreams started" $?

log ""
log "== 3. Bring up the real gateway compose against the stub networks =="
cat > "$GATEWAY_ENV" <<EOF
CADDY_EMAIL=ops@example.invalid
TAPIZ_API_DOMAIN=$TAPIZ_HOST
AURA_API_DOMAIN=$AURA_HOST
TAPIZ_EDGE_NETWORK=$TAPIZ_EDGE_NETWORK
AURA_EDGE_NETWORK=$AURA_EDGE_NETWORK
EOF

# Override published ports to unprivileged, collision-avoiding local ports
# instead of the real 80/443 — this harness must never bind the ports a real
# gateway or another local service would use.
export GATEWAY_ENV_FILE="$GATEWAY_ENV"
docker compose -p platform-gateway-test --env-file "$GATEWAY_ENV" \
  -f "$GATEWAY_COMPOSE" \
  -f "$integration_dir/docker-compose.gateway-test-ports.yml" \
  up -d --quiet-pull
sleep 3
check "gateway container started against disposable stub networks" $?

curl_host() {
  # $1 = Host header, $2 = path, $3 = method (default GET)
  # The real Caddyfile enables automatic HTTPS (its default for any site with a
  # hostname) and issues a 308 redirect off plain HTTP — exactly what it would
  # do in production. Rather than special-case that away, this harness talks
  # to the gateway's real HTTPS listener instead, using Caddy's local
  # self-signed/internal cert (no real ACME/DNS available here, hence -k) with
  # SNI set to the site's hostname so Caddy's per-site TLS/routing picks the
  # right config, exactly as a real browser/client would present it. Caddy
  # issues its internal cert on-demand for the first request per site, which
  # can take a moment, so this retries briefly instead of failing on the first
  # cold connection; `set -e` is suspended around the curl call itself so a
  # transient connection error surfaces as a normal non-200 code to `check`,
  # not a hard script abort.
  set +e
  attempt=0
  code=000
  while [ "$attempt" -lt 10 ]; do
    code=$(curl -sk -o /tmp/gateway-test-body.json -w "%{http_code}" \
      --max-time 5 -X "${3:-GET}" \
      --resolve "$1:$GATEWAY_TLS_PORT:127.0.0.1" \
      "https://$1:$GATEWAY_TLS_PORT$2" 2>/dev/null)
    [ "$code" != "000" ] && break
    attempt=$((attempt + 1))
    sleep 1
  done
  set -e
  printf '%s' "$code"
}

lane_of_last_response() {
  # Extracts the "lane" field the stub server echoed in its JSON body.
  grep -o '"lane":"[^"]*"' /tmp/gateway-test-body.json | cut -d'"' -f4
}

log ""
log "== 4. Tapiz routing assertions (api.tapiz.test) =="

code=$(curl_host "$TAPIZ_HOST" "/api/auth/login" "POST")
lane=$(lane_of_last_response)
assert '[ "$code" = "200" ] && { [ "$lane" = "tapiz-auth-api-1" ] || [ "$lane" = "tapiz-auth-api-2" ]; }' \
  "POST /api/auth/login -> auth lane (got HTTP $code, lane=$lane)"

code=$(curl_host "$TAPIZ_HOST" "/api/attendance/scan" "POST")
lane=$(lane_of_last_response)
assert '[ "$code" = "200" ] && [ "$lane" = "tapiz-scan-api" ]' \
  "POST /api/attendance/scan -> scan lane (got HTTP $code, lane=$lane)"

code=$(curl_host "$TAPIZ_HOST" "/api/attendance/scan-student" "POST")
lane=$(lane_of_last_response)
assert '[ "$code" = "200" ] && [ "$lane" = "tapiz-scan-api" ]' \
  "POST /api/attendance/scan-student -> scan lane (got HTTP $code, lane=$lane)"

code=$(curl_host "$TAPIZ_HOST" "/api/subjects" "GET")
lane=$(lane_of_last_response)
assert '[ "$code" = "200" ] && [ "$lane" = "tapiz-general-api" ]' \
  "GET /api/subjects -> general lane (got HTTP $code, lane=$lane)"

code=$(curl_host "$TAPIZ_HOST" "/api/auth/login" "GET")
lane=$(lane_of_last_response)
assert '[ "$code" = "200" ] && [ "$lane" = "tapiz-general-api" ]' \
  "GET /api/auth/login (wrong method) -> falls through to general lane, not auth (got HTTP $code, lane=$lane)"

log ""
log "== 5. Aura routing assertions (api.aura.test) =="

code=$(curl_host "$AURA_HOST" "/hls/master.m3u8" "GET")
lane=$(lane_of_last_response)
assert '[ "$code" = "200" ] && [ "$lane" = "aura-media-delivery" ]' \
  "GET /hls/master.m3u8 -> media lane (got HTTP $code, lane=$lane)"

code=$(curl_host "$AURA_HOST" "/hls/segment_1.ts" "GET")
lane=$(lane_of_last_response)
assert '[ "$code" = "200" ] && [ "$lane" = "aura-media-delivery" ]' \
  "GET /hls/segment_1.ts -> media lane (got HTTP $code, lane=$lane)"

code=$(curl_host "$AURA_HOST" "/api/tracks" "GET")
lane=$(lane_of_last_response)
assert '[ "$code" = "200" ] && [ "$lane" = "aura-api" ]' \
  "GET /api/tracks -> aura-api lane (got HTTP $code, lane=$lane)"

log ""
log "== 6. Independence: stop Aura entirely, Tapiz must stay healthy =="
docker compose -f "$AURA_STUB_COMPOSE" down >/dev/null
sleep 2

code=$(curl_host "$TAPIZ_HOST" "/api/subjects" "GET")
lane=$(lane_of_last_response)
assert '[ "$code" = "200" ] && [ "$lane" = "tapiz-general-api" ]' \
  "with Aura stopped, Tapiz general lane still routes correctly (got HTTP $code, lane=$lane)"

code=$(curl_host "$TAPIZ_HOST" "/api/auth/login" "POST")
lane=$(lane_of_last_response)
assert '[ "$code" = "200" ] && { [ "$lane" = "tapiz-auth-api-1" ] || [ "$lane" = "tapiz-auth-api-2" ]; }' \
  "with Aura stopped, Tapiz auth lane still routes correctly (got HTTP $code, lane=$lane)"

code=$(curl_host "$AURA_HOST" "/api/tracks" "GET")
assert '[ "$code" != "200" ]' \
  "with Aura stopped, api.aura.test itself now fails (expected non-200, got HTTP $code)"

log ""
log "== 7. Restart Aura, restart-independence: stop Tapiz entirely, Aura must stay healthy =="
docker compose -f "$AURA_STUB_COMPOSE" up -d --quiet-pull >/dev/null
sleep 2
docker compose -f "$TAPIZ_STUB_COMPOSE" down >/dev/null
sleep 2

code=$(curl_host "$AURA_HOST" "/api/tracks" "GET")
lane=$(lane_of_last_response)
assert '[ "$code" = "200" ] && [ "$lane" = "aura-api" ]' \
  "with Tapiz stopped, Aura api lane still routes correctly (got HTTP $code, lane=$lane)"

code=$(curl_host "$AURA_HOST" "/hls/master.m3u8" "GET")
lane=$(lane_of_last_response)
assert '[ "$code" = "200" ] && [ "$lane" = "aura-media-delivery" ]' \
  "with Tapiz stopped, Aura media lane still routes correctly (got HTTP $code, lane=$lane)"

code=$(curl_host "$TAPIZ_HOST" "/api/subjects" "GET")
assert '[ "$code" != "200" ]' \
  "with Tapiz stopped, api.tapiz.test itself now fails (expected non-200, got HTTP $code)"

log ""
log "== 8. No public ports on any application stub =="
# Only the gateway container may publish a host port. Scoped by the stub
# Compose projects' own project label (gateway-test-tapiz-stub /
# gateway-test-aura-stub, set by `name:` in each stub compose file) rather
# than a name substring match, which is unambiguous regardless of which
# stubs are currently up (tapiz was stopped in section 7 — that is expected;
# this only asserts that whichever stub containers ARE running publish no
# host port at all) and cannot collide with the gateway container's own name.
stub_ports_tapiz=$(docker ps --filter "label=com.docker.compose.project=gateway-test-tapiz-stub" --format '{{.Ports}}' 2>/dev/null || true)
stub_ports_aura=$(docker ps --filter "label=com.docker.compose.project=gateway-test-aura-stub" --format '{{.Ports}}' 2>/dev/null || true)
stub_ports="$stub_ports_tapiz
$stub_ports_aura"
bad=$(printf '%s\n' "$stub_ports" | grep -c '0.0.0.0\|:::' || true)
assert '[ "${bad:-0}" = "0" ]' \
  "no application stub container publishes a host port"

gateway_ports=$(docker port platform-gateway-test-caddy-1 2>/dev/null || true)
assert '[ -n "$gateway_ports" ]' \
  "only the gateway container publishes host ports ($gateway_ports)"

log ""
log "== Summary =="
log "Passed: $pass_count"
log "Failed: $fail_count"
if [ "$fail_count" != "0" ]; then
  log "$failures"
  exit 1
fi
log "All checks passed."
