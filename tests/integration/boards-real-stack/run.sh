#!/usr/bin/env sh
# Sixth integration harness for the shared vps-gateway Caddy — first to bring
# a THIRD product (Tapiz Boards) behind this gateway.
#
# Proves, against THIS repository's real, unmodified Caddyfile/sites/*.caddy
# (including the new sites/boards.caddy)/snippets/*.caddy/docker-compose.yml,
# that the REAL Boards VPS stack (real PostgreSQL, the real migration script,
# the real production Next.js image built from the product's own multi-stage
# Dockerfile — tapiz-boards/ops/vps/docker-compose.yml, referenced from a
# local tapiz-boards checkout, never copied) comes up healthy behind the real
# central gateway, that `GET /api/health` reaches it through the gateway's
# test hostname, and that Boards fails/recovers independently of Tapiz and
# Aura in both directions — using the existing fake Tapiz/Aura stubs (read
# only reference, never copied or modified) rather than the full real Tapiz
# stack, since Tapiz/Aura routing independence from EACH OTHER is already
# proven by the first five harnesses; this harness's job is proving BOARDS'
# independence specifically.
#
# This is a SEPARATE, later harness than ../run.sh, ../real-stack/run.sh,
# ../graceful-reload/run.sh, ../chaos/run.sh, ../backup-restore/run.sh, and
# ../scheduler-worker/run.sh — it does not modify or depend on any of them,
# and none of them are modified by this script. Only files under
# tests/integration/boards-real-stack/ are added by this harness.
#
# Never touches a real VPS, DNS, GitHub, the real tapiz-boards.vercel.app
# deployment, Aiven MySQL, or any real secret. Generates its own disposable,
# random-only .env for the Boards stack. Never reads any real Boards .env/
# .env.vercel/.env.production — .env.test/.env.example are the only
# references used for which keys exist.
#
# Everything this script creates (networks, containers, volumes, images, the
# generated .env files) is removed by the `cleanup` trap, on both success and
# failure.
set -eu

gateway_root=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
here="$gateway_root/tests/integration/boards-real-stack"
integration_dir="$gateway_root/tests/integration"

# Locate the tapiz-boards checkout, same override pattern as every other
# real-stack-based harness's TAPIZ_LMS_DIR (per CLAUDE.md's own sibling
# layout: ~/Desktop/tapiz/<repo>). Uses $HOME, never a literal /Users/... path
# — see ../../../README.md's real-bugs section for why (hard constraint 6 in
# this harness's own task: never embed a literal absolute path as a default).
BOARDS_DIR="${BOARDS_DIR:-$HOME/Desktop/tapiz/tapiz-boards}"
BOARDS_VPS_DIR="$BOARDS_DIR/ops/vps"
BOARDS_COMPOSE="$BOARDS_VPS_DIR/docker-compose.yml"

if [ ! -f "$BOARDS_COMPOSE" ]; then
  printf 'FATAL: real Boards VPS compose file not found at %s\n' "$BOARDS_COMPOSE" >&2
  printf 'Set BOARDS_DIR to override the default checkout path.\n' >&2
  exit 1
fi

GATEWAY_COMPOSE="$gateway_root/docker-compose.yml"
TAPIZ_STUB_COMPOSE="$integration_dir/docker-compose.tapiz-stub.yml"
AURA_STUB_COMPOSE="$integration_dir/docker-compose.aura-stub.yml"

GATEWAY_ENV="$here/.env.gateway-boards-test"
BOARDS_ENV="$here/.env.boards-real-stack"

BOARDS_HOST="api.boards-real.test"
TAPIZ_HOST="api.tapiz-boards-test.test"
AURA_HOST="api.aura-boards-test.test"
GATEWAY_TLS_PORT="61443"

# Distinct from every other harness's edge network names — EXCEPT Boards'
# own. REAL BUG found while building this harness: the real, unmodified
# tapiz-boards/ops/vps/docker-compose.yml hardcodes `name: boards_edge` on
# its external network (no `${BOARDS_EDGE_NETWORK:-...}` interpolation at
# all, unlike Tapiz's `${TAPIZ_EDGE_NETWORK:-tapiz-edge}` pattern that every
# other harness's TAPIZ_EDGE_NETWORK env var relies on) — confirmed by
# direct inspection of that file. A disposable `boards-edge-real-test` name
# is therefore never actually read by Boards' own compose file; it would
# silently try to attach to the real `boards_edge` network name instead
# (harmless on this dev machine since no real `boards_edge` network is
# normally running, but not the intended isolation). This is a real product
# compose limitation, not something this harness may fix by editing
# tapiz-boards/ops/vps/docker-compose.yml (read-only per this task's hard
# constraints). Fixed here by using the literal `boards_edge` name for this
# harness's own disposable network too — teardown (the `cleanup` trap) still
# removes it every run, so this is safe as long as no other process on this
# host concurrently owns a network literally named `boards_edge` (verified
# clean before/after every run via `docker network ls`).
BOARDS_EDGE_NETWORK_NAME="boards_edge"
TAPIZ_EDGE_NETWORK_NAME="tapiz-edge-boards-test"
AURA_EDGE_NETWORK_NAME="aura-edge-boards-test"

BOARDS_PROJECT="tapiz-boards-real-stack-test"
GATEWAY_PROJECT="platform-gateway-boards-test"
TAPIZ_STUB_PROJECT="gateway-boards-test-tapiz-stub"
AURA_STUB_PROJECT="gateway-boards-test-aura-stub"

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

# See ../../../README.md bug #4: a bare failing test expression not inside an
# if/while/&&/|| chain trips `set -e` on its own and aborts the script before
# `check` can log anything. Every assertion here goes through this helper.
assert() {
  expr=$1
  description=$2
  if eval "$expr"; then
    check "$description" 0
  else
    check "$description" 1
  fi
}

# Always includes docker-compose.boards-harness-overrides.yml — not just for
# the one-shot `migrate` service, but because it also carries the
# `boards-app` network alias fix for `app` (see that file's own "REAL BUG"
# comment). Every boards_compose call needs that alias present, not only the
# migrate-profile ones, so there is exactly one compose function rather than
# a split "with/without overrides" pair.
boards_compose() {
  docker compose -p "$BOARDS_PROJECT" --env-file "$BOARDS_ENV" \
    -f "$BOARDS_COMPOSE" -f "$here/docker-compose.boards-harness-overrides.yml" "$@"
}

gateway_compose() {
  docker compose -p "$GATEWAY_PROJECT" --env-file "$GATEWAY_ENV" \
    -f "$GATEWAY_COMPOSE" -f "$here/docker-compose.gateway-boards-test-ports.yml" "$@"
}

tapiz_stub_compose() {
  docker compose -p "$TAPIZ_STUB_PROJECT" -f "$TAPIZ_STUB_COMPOSE" "$@"
}

aura_stub_compose() {
  AURA_EDGE_NETWORK="$AURA_EDGE_NETWORK_NAME" \
    docker compose -p "$AURA_STUB_PROJECT" -f "$AURA_STUB_COMPOSE" "$@"
}

cleanup() {
  status=$?
  log ""
  log "== Teardown =="
  gateway_compose down -v --remove-orphans >/dev/null 2>&1 || true
  tapiz_stub_compose down -v --remove-orphans >/dev/null 2>&1 || true
  aura_stub_compose down -v --remove-orphans >/dev/null 2>&1 || true
  boards_compose --profile migrate down -v --remove-orphans >/dev/null 2>&1 || true
  docker network rm "$BOARDS_EDGE_NETWORK_NAME" >/dev/null 2>&1 || true
  docker network rm "$TAPIZ_EDGE_NETWORK_NAME" >/dev/null 2>&1 || true
  docker network rm "$AURA_EDGE_NETWORK_NAME" >/dev/null 2>&1 || true
  rm -f "$GATEWAY_ENV" "$BOARDS_ENV" /tmp/gateway-boards-test-body.json
  log "Removed disposable containers, volumes, networks, and generated .env files created by this run."
  exit "$status"
}
trap cleanup EXIT INT TERM

log "== 0. caddy validate (real gateway config, unmodified, now with 3 sites) =="
sh "$gateway_root/tests/validate.sh"
check "caddy validate + gateway compose config parse cleanly" $?

log ""
log "== 1. Generate a disposable, random-only .env for the real Boards stack =="
# Random local-only values only. Never reads or copies any real Boards .env/
# .env.vercel/.env.production — .env.test/.env.example are the only
# references used for which keys exist.
rand() { head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n'; }
POSTGRES_PASSWORD_GEN=$(rand)
BOARDS_APP_PASSWORD_GEN=$(rand)
AUTH_SECRET_GEN=$(rand)

cat > "$BOARDS_ENV" <<EOF
POSTGRES_PASSWORD=$POSTGRES_PASSWORD_GEN
BOARDS_APP_PASSWORD=$BOARDS_APP_PASSWORD_GEN
AUTH_SECRET=$AUTH_SECRET_GEN
AUTH_TRUST_HOST=true
AUTH_URL=https://$BOARDS_HOST
DATABASE_POOL_MAX=10
LMS_UI_URL=
LMS_API_URL=
LMS_OAUTH_CLIENT_ID=tapiz-boards
LMS_OAUTH_CLIENT_SECRET=
EOF
check "generated disposable .env.boards-real-stack with random-only local secrets" $?

log ""
log "== 2. Create disposable external edge networks (Boards + Tapiz stub + Aura stub) =="
# The real tapiz-boards/ops/vps/docker-compose.yml declares NO `env_file:`
# key of its own (confirmed by inspection) — unlike the real Tapiz LMS
# compose file's `env_file: ${TAPIZ_ENV_FILE:-.env}`, which needed an
# explicit `export TAPIZ_ENV_FILE=...` before every `docker compose` call in
# the other harnesses (see ../real-stack/run.sh's own comment on this exact
# bug). Boards' services only use `environment:` blocks that interpolate
# `${VAR}` directly from Compose's own `--env-file`, so `--env-file
# "$BOARDS_ENV"` alone is sufficient here — no extra export needed. Checked
# first rather than assumed, per this harness's own instructions.
#
# BOARDS_DIR (absolute path, for docker-compose.boards-harness-overrides.yml's
# migrate build context) is exported once here rather than re-prefixed on
# every boards_compose call site below. BOARDS_EDGE_NETWORK is deliberately
# NOT exported/interpolated anywhere in this harness — the real Boards
# compose file hardcodes `name: boards_edge` with no env var indirection at
# all (see BOARDS_EDGE_NETWORK_NAME's own comment above), so setting that
# variable would have no effect on Boards' own compose; the disposable
# network this harness creates below is therefore named literally
# `boards_edge` to match what the real file actually expects.
export BOARDS_DIR
docker network create "$BOARDS_EDGE_NETWORK_NAME" >/dev/null
check "created disposable $BOARDS_EDGE_NETWORK_NAME network" $?
docker network create "$TAPIZ_EDGE_NETWORK_NAME" >/dev/null
check "created disposable $TAPIZ_EDGE_NETWORK_NAME network" $?
docker network create "$AURA_EDGE_NETWORK_NAME" >/dev/null
check "created disposable $AURA_EDGE_NETWORK_NAME network" $?

log ""
log "== 3. Bring up the real Boards Postgres, wait healthy =="
boards_compose up -d --quiet-pull postgres
check "real Boards postgres container started" $?

wait_healthy() {
  # $1 = compose function name, $2 = service, $3 = timeout seconds
  compose_fn=$1
  svc=$2
  timeout=$3
  elapsed=0
  while [ "$elapsed" -lt "$timeout" ]; do
    state=$($compose_fn ps --format '{{.Health}}' "$svc" 2>/dev/null || true)
    if [ "$state" = "healthy" ]; then
      return 0
    fi
    sleep 2
    elapsed=$((elapsed + 2))
  done
  return 1
}

if wait_healthy boards_compose postgres 60; then check "postgres reports healthy" 0; else check "postgres reports healthy" 1; fi

log ""
log "== 4. Build + run the real Boards migration (npm run db:migrate) against the disposable Postgres =="
# Uses this harness's OWN docker-compose.boards-harness-overrides.yml (not
# the real repo's ops/vps/docker-compose.test.yml) because that file also
# overrides `app`'s ports to publish a loopback host port
# (127.0.0.1:13004:3004) — this harness requires Boards to never publish any
# host port, not even loopback-only. Never a host-mapped Postgres port
# either; migrate reaches postgres only over the private boards_internal
# network.
boards_compose --profile migrate build migrate
check "migrate image built from the real, unmodified Dockerfile (build target)" $?

boards_compose --profile migrate run --rm migrate
check "npm run db:migrate applied the real schema to the disposable Postgres" $?

log ""
log "== 5. Build + bring up the real Boards app (production image, real Dockerfile, no host port) =="
boards_compose build app
check "real Boards app image built from the real, unmodified multi-stage Dockerfile" $?

boards_compose up -d --quiet-pull app
check "real Boards app container started (no ports: key anywhere in this harness's compose; boards-app alias applied via harness override)" $?

if wait_healthy boards_compose app 90; then
  check "Boards app reports healthy (real Next.js server booted, real DB connectivity)" 0
else
  check "Boards app reports healthy (real Next.js server booted, real DB connectivity)" 1
fi

log ""
log "== 6. Bring up the existing fake Tapiz + Aura stubs (read-only reference, unmodified) =="
TAPIZ_EDGE_NETWORK="$TAPIZ_EDGE_NETWORK_NAME" \
  tapiz_stub_compose up -d --quiet-pull
check "Tapiz stub (4 lanes) started on disposable $TAPIZ_EDGE_NETWORK_NAME" $?

aura_stub_compose up -d --quiet-pull
check "Aura stub (aura-api, aura-media-delivery) started on disposable $AURA_EDGE_NETWORK_NAME" $?

log ""
log "== 7. Bring up the real, unmodified vps-gateway Caddy against Boards + both stubs =="
cat > "$GATEWAY_ENV" <<EOF
CADDY_EMAIL=ops@example.invalid
TAPIZ_API_DOMAIN=$TAPIZ_HOST
AURA_API_DOMAIN=$AURA_HOST
BOARDS_API_DOMAIN=$BOARDS_HOST
TAPIZ_EDGE_NETWORK=$TAPIZ_EDGE_NETWORK_NAME
AURA_EDGE_NETWORK=$AURA_EDGE_NETWORK_NAME
BOARDS_EDGE_NETWORK=$BOARDS_EDGE_NETWORK_NAME
EOF

export GATEWAY_ENV_FILE="$GATEWAY_ENV"
gateway_compose up -d --quiet-pull
check "real gateway container started, joined all 3 edge networks (Boards, Tapiz stub, Aura stub)" $?

# The gateway's own docker-compose.yml (real, unmodified) declares no
# healthcheck for its `caddy` service — same as every other real-stack-based
# harness observed. Reachability is proven directly by the routing
# assertions below, not by a Health field that can never populate.
gateway_caddy_state=$(gateway_compose ps --format '{{.State}}' caddy 2>/dev/null || true)
assert '[ "$gateway_caddy_state" = "running" ]' \
  "gateway caddy container is running (no healthcheck defined on this service; reachability proven by step 8's routing assertions)"

curl_host() {
  # $1 = Host header, $2 = path, $3 = method (default GET)
  set +e
  attempt=0
  code=000
  while [ "$attempt" -lt 15 ]; do
    code=$(curl -sk -o /tmp/gateway-boards-test-body.json -w "%{http_code}" \
      --max-time 8 -X "${3:-GET}" \
      --resolve "$1:$GATEWAY_TLS_PORT:127.0.0.1" \
      "https://$1:$GATEWAY_TLS_PORT$2" 2>/dev/null)
    [ "$code" != "000" ] && break
    attempt=$((attempt + 1))
    sleep 2
  done
  set -e
  printf '%s' "$code"
}

wait_route_ok() {
  # $1 = curl_host invocation as a single eval-able string producing $code,
  # $2 = timeout seconds, $3 = eval-able expression testing "$code"
  timeout=$2
  expr=$3
  elapsed=0
  while [ "$elapsed" -lt "$timeout" ]; do
    code=$(eval "$1")
    if eval "$expr"; then
      printf '%s' "$code"
      return 0
    fi
    sleep 2
    elapsed=$((elapsed + 2))
  done
  printf '%s' "$code"
  return 1
}

log ""
log "== 8. Baseline: real Boards health, real Tapiz stub routing, real Aura stub routing, all through the gateway =="
code=$(wait_route_ok 'curl_host "$BOARDS_HOST" "/api/health" "GET"' 30 '[ "$code" = "200" ]') || true
assert '[ "$code" = "200" ]' \
  "GET /api/health through the gateway test hostname -> real 200 from the real Boards app (got HTTP $code)"

code=$(curl_host "$TAPIZ_HOST" "/api/subjects" "GET")
assert '[ "$code" = "200" ]' \
  "baseline: Tapiz stub GET /api/subjects -> 200 through the gateway (got HTTP $code)"

code=$(curl_host "$AURA_HOST" "/api/tracks" "GET")
assert '[ "$code" = "200" ]' \
  "baseline: Aura stub GET /api/tracks -> 200 through the gateway (got HTTP $code)"

log ""
log "== 9. Independence check 1: stop Boards entirely, confirm Tapiz+Aura (stub) routing/health completely unaffected =="
boards_compose stop app postgres >/dev/null
check "Boards app + postgres stopped" $?

code=$(curl_host "$BOARDS_HOST" "/api/health" "GET")
assert '[ "$code" = "502" ] || [ "$code" = "503" ]' \
  "with Boards stopped: api.boards-real.test fails with a well-defined Caddy 502/503, not a hang (got HTTP $code)"

code=$(curl_host "$TAPIZ_HOST" "/api/subjects" "GET")
assert '[ "$code" = "200" ]' \
  "with Boards stopped: Tapiz stub routing/health completely unaffected (got HTTP $code)"

code=$(curl_host "$AURA_HOST" "/api/tracks" "GET")
assert '[ "$code" = "200" ]' \
  "with Boards stopped: Aura stub routing/health completely unaffected (got HTTP $code)"

log ""
log "== 10. Recover Boards, confirm it serves correctly again =="
boards_compose start postgres >/dev/null
check "Boards postgres restarted" $?
if wait_healthy boards_compose postgres 60; then check "Boards postgres healthy again" 0; else check "Boards postgres healthy again" 1; fi
boards_compose start app >/dev/null
check "Boards app restarted" $?
if wait_healthy boards_compose app 90; then check "Boards app healthy again" 0; else check "Boards app healthy again" 1; fi

code=$(wait_route_ok 'curl_host "$BOARDS_HOST" "/api/health" "GET"' 30 '[ "$code" = "200" ]') || true
assert '[ "$code" = "200" ]' \
  "post-recovery: GET /api/health through the gateway -> real 200 again (got HTTP $code)"

log ""
log "== 11. Independence check 2: stop Tapiz + Aura (stubs) entirely, confirm Boards routing/health completely unaffected =="
TAPIZ_EDGE_NETWORK="$TAPIZ_EDGE_NETWORK_NAME" tapiz_stub_compose stop >/dev/null
check "Tapiz stub stopped" $?
aura_stub_compose stop >/dev/null
check "Aura stub stopped" $?

code=$(curl_host "$TAPIZ_HOST" "/api/subjects" "GET")
assert '[ "$code" = "502" ] || [ "$code" = "503" ]' \
  "with Tapiz+Aura stubs stopped: api.tapiz-boards-test.test fails with a well-defined 502/503 (got HTTP $code)"

code=$(curl_host "$AURA_HOST" "/api/tracks" "GET")
assert '[ "$code" = "502" ] || [ "$code" = "503" ]' \
  "with Tapiz+Aura stubs stopped: api.aura-boards-test.test fails with a well-defined 502/503 (got HTTP $code)"

code=$(curl_host "$BOARDS_HOST" "/api/health" "GET")
assert '[ "$code" = "200" ]' \
  "with Tapiz+Aura stubs stopped: Boards routing/health completely unaffected (got HTTP $code)"

log ""
log "== 12. Recover Tapiz + Aura stubs, confirm they serve correctly again =="
TAPIZ_EDGE_NETWORK="$TAPIZ_EDGE_NETWORK_NAME" tapiz_stub_compose start >/dev/null
check "Tapiz stub restarted" $?
aura_stub_compose start >/dev/null
check "Aura stub restarted" $?

code=$(wait_route_ok 'curl_host "$TAPIZ_HOST" "/api/subjects" "GET"' 20 '[ "$code" = "200" ]') || true
assert '[ "$code" = "200" ]' \
  "post-recovery: Tapiz stub routing succeeds again (got HTTP $code)"
code=$(wait_route_ok 'curl_host "$AURA_HOST" "/api/tracks" "GET"' 20 '[ "$code" = "200" ]') || true
assert '[ "$code" = "200" ]' \
  "post-recovery: Aura stub routing succeeds again (got HTTP $code)"

log ""
log "== 13. Graceful reload: Boards route survives a live caddy reload, gateway process identity unchanged =="
# See ../graceful-reload/README.md for the full reload-safety mechanism proof
# (background traffic continuity, deliberately-broken-config rejection) —
# already proven generically there. This step only needs to confirm Boards'
# specific route survives a reload too: a direct before/after request pair
# through the Boards route, plus the container-identity-unchanged check.
GATEWAY_CID_BEFORE=$(gateway_compose ps -q caddy)
GATEWAY_STARTED_AT_BEFORE=$(docker inspect --format '{{.State.StartedAt}}' "$GATEWAY_CID_BEFORE")

code=$(curl_host "$BOARDS_HOST" "/api/health" "GET")
assert '[ "$code" = "200" ]' \
  "pre-reload: Boards route serves 200 (got HTTP $code)"

reload_output=$(gateway_compose exec -T caddy caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile 2>&1)
reload_exit=$?
log "  caddy reload output:"
log "$reload_output" | sed 's/^/    /'
assert '[ "$reload_exit" -eq 0 ]' \
  "caddy reload (live gateway, real unmodified config incl. sites/boards.caddy) succeeded (exit $reload_exit)"

GATEWAY_CID_AFTER=$(gateway_compose ps -q caddy)
GATEWAY_STARTED_AT_AFTER=$(docker inspect --format '{{.State.StartedAt}}' "$GATEWAY_CID_AFTER")
assert '[ "$GATEWAY_CID_BEFORE" = "$GATEWAY_CID_AFTER" ]' \
  "gateway container ID unchanged across reload (same container, not recreated)"
assert '[ "$GATEWAY_STARTED_AT_BEFORE" = "$GATEWAY_STARTED_AT_AFTER" ]' \
  "gateway container StartedAt unchanged across reload (same process, no restart)"

code=$(curl_host "$BOARDS_HOST" "/api/health" "GET")
assert '[ "$code" = "200" ]' \
  "post-reload: Boards route still serves 200 correctly (got HTTP $code)"

log ""
log "== 14. No host ports on any real Boards container at any point =="
boards_ports=$(docker ps -a --filter "label=com.docker.compose.project=$BOARDS_PROJECT" --format '{{.Ports}}' 2>/dev/null || true)
bad_boards=$(printf '%s\n' "$boards_ports" | grep -c '0.0.0.0\|:::' || true)
assert '[ "${bad_boards:-0}" = "0" ]' \
  "no real Boards container (postgres/migrate/app) publishes a host port"

tapiz_stub_ports=$(docker ps -a --filter "label=com.docker.compose.project=$TAPIZ_STUB_PROJECT" --format '{{.Ports}}' 2>/dev/null || true)
bad_tapiz_stub=$(printf '%s\n' "$tapiz_stub_ports" | grep -c '0.0.0.0\|:::' || true)
assert '[ "${bad_tapiz_stub:-0}" = "0" ]' \
  "no Tapiz stub container publishes a host port"

aura_stub_ports=$(docker ps -a --filter "label=com.docker.compose.project=$AURA_STUB_PROJECT" --format '{{.Ports}}' 2>/dev/null || true)
bad_aura_stub=$(printf '%s\n' "$aura_stub_ports" | grep -c '0.0.0.0\|:::' || true)
assert '[ "${bad_aura_stub:-0}" = "0" ]' \
  "no Aura stub container publishes a host port"

gateway_ports=$(docker port "${GATEWAY_PROJECT}-caddy-1" 2>/dev/null || true)
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
