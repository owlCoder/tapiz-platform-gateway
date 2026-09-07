#!/usr/bin/env sh
# Phase 1 real-stack integration harness for the shared vps-gateway Caddy.
#
# Proves, against THIS repository's real, unmodified Caddyfile/sites/*.caddy/
# snippets/*.caddy/docker-compose.yml, that the REAL Tapiz LMS VPS stack (real
# Postgres, real Valkey, real PgBouncer, real auth-api-1/auth-api-2/scan-api/
# general-api lanes, real worker, real scheduler — apps/api/ops/vps/docker-compose.yml,
# referenced from tapiz-lms, never copied) comes up healthy behind the real
# central gateway, that login/scan/general traffic reaches the correct lane,
# that PgBouncer/worker/scheduler run normally, and that the product's own
# standalone-ingress Caddy is never started.
#
# This is a SEPARATE, later harness than ../run.sh (the fake-stub harness) —
# it does not modify or depend on ../run.sh or any of its files, and ../run.sh
# is not modified by this script either.
#
# Never touches a real VPS, DNS, GitHub, external database, or any real secret.
# Generates its own disposable, random-value .env for the Tapiz stack. Never
# reads apps/api/ops/vps/.env (a real file that may exist on this machine) —
# env.example is the only reference used for which keys exist.
#
# Everything this script creates (networks, containers, volumes, the
# generated Tapiz .env, the gateway's own .env) is removed by the `cleanup`
# trap, on both success and failure.
set -eu

gateway_root=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
here="$gateway_root/tests/integration/real-stack"

# Locate the tapiz-lms checkout. Defaults to the sibling layout this machine
# uses (per CLAUDE.md: ~/Desktop/tapiz/tapiz-lms); override with
# TAPIZ_LMS_DIR=/path/to/tapiz-lms if run elsewhere. This script only ever
# READS from this tree (compose -f reference + a read-only bind mount for the
# schema push) — see hard constraint 2, never edited.
TAPIZ_LMS_DIR="${TAPIZ_LMS_DIR:-$HOME/Desktop/tapiz/tapiz-lms}"
TAPIZ_VPS_DIR="$TAPIZ_LMS_DIR/apps/api/ops/vps"
TAPIZ_COMPOSE="$TAPIZ_VPS_DIR/docker-compose.yml"

if [ ! -f "$TAPIZ_COMPOSE" ]; then
  printf 'FATAL: real Tapiz VPS compose file not found at %s\n' "$TAPIZ_COMPOSE" >&2
  printf 'Set TAPIZ_LMS_DIR to override the default checkout path.\n' >&2
  exit 1
fi

GATEWAY_COMPOSE="$gateway_root/docker-compose.yml"
GATEWAY_ENV="$here/.env.gateway-real-stack"
TAPIZ_ENV="$here/.env.tapiz-real-stack"

TAPIZ_HOST="api.tapiz-real.test"
GATEWAY_TLS_PORT="28443"

# Distinct from the stub harness's tapiz-edge-test and from the real tapiz-edge —
# see hard constraint 6.
TAPIZ_EDGE_NETWORK_NAME="tapiz-edge-real-test"

TAPIZ_PROJECT="tapiz-lms-real-stack-test"
GATEWAY_PROJECT="platform-gateway-real-stack-test"

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

# See ../../../README.md's bug #4 and ../run.sh's own comment: a bare failing
# test expression not inside an if/while/&&/|| chain trips `set -e` on its own
# and aborts the script before `check` can log anything. Every assertion here
# goes through this helper instead of a bare `[ ]`.
assert() {
  expr=$1
  description=$2
  if eval "$expr"; then
    check "$description" 0
  else
    check "$description" 1
  fi
}

tapiz_compose() {
  docker compose -p "$TAPIZ_PROJECT" --env-file "$TAPIZ_ENV" \
    -f "$TAPIZ_COMPOSE" "$@"
}

tapiz_compose_with_schema_push() {
  docker compose -p "$TAPIZ_PROJECT" --env-file "$TAPIZ_ENV" \
    -f "$TAPIZ_COMPOSE" -f "$here/docker-compose.schema-push.yml" "$@"
}

gateway_compose() {
  docker compose -p "$GATEWAY_PROJECT" --env-file "$GATEWAY_ENV" \
    -f "$GATEWAY_COMPOSE" -f "$here/docker-compose.gateway-real-test-ports.yml" "$@"
}

cleanup() {
  status=$?
  log ""
  log "== Teardown =="
  gateway_compose down -v --remove-orphans >/dev/null 2>&1 || true
  tapiz_compose_with_schema_push --profile schema-push down -v --remove-orphans >/dev/null 2>&1 || true
  docker network rm "$TAPIZ_EDGE_NETWORK_NAME" >/dev/null 2>&1 || true
  docker network rm aura-edge-real-test-unused >/dev/null 2>&1 || true
  rm -f "$GATEWAY_ENV" "$TAPIZ_ENV" /tmp/gateway-real-stack-test-body.json
  log "Removed disposable containers, volumes, networks, and generated .env files created by this run."
  exit "$status"
}
trap cleanup EXIT INT TERM

log "== 0. caddy validate (real gateway config, unmodified) =="
sh "$gateway_root/tests/validate.sh"
check "caddy validate + gateway compose config parse cleanly" $?

log ""
log "== 1. Generate a disposable, random-only .env for the real Tapiz stack =="
# Random local-only values only. Never reads or copies apps/api/ops/vps/.env —
# env.example is the only reference used for which keys exist (hard constraint 5).
rand() { head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n'; }
POSTGRES_PASSWORD_GEN=$(rand)
JWT_SECRET_GEN=$(rand)
JWT_REFRESH_SECRET_GEN=$(rand)
CRON_SECRET_GEN=$(rand)

cat > "$TAPIZ_ENV" <<EOF
API_DOMAIN=$TAPIZ_HOST
TAPIZ_API_IMAGE=tapiz-lms-api-real-stack-test:local
TAPIZ_EDGE_NETWORK=$TAPIZ_EDGE_NETWORK_NAME

POSTGRES_DB=tapiz_real_stack_test
POSTGRES_USER=tapiz_real_stack_test
POSTGRES_PASSWORD=$POSTGRES_PASSWORD_GEN
DB_POOL_MAX=10
AUTH_API_DB_POOL_MAX=5
SCAN_API_DB_POOL_MAX=5
GENERAL_API_DB_POOL_MAX=5
WORKER_DB_POOL_MAX=5
PGBOUNCER_DEFAULT_POOL_SIZE=40
PGBOUNCER_RESERVE_POOL_SIZE=10
DISABLE_BACKGROUND_WORKERS=

CLIENT_URL=https://$TAPIZ_HOST

JWT_SECRET=$JWT_SECRET_GEN
JWT_REFRESH_SECRET=$JWT_REFRESH_SECRET_GEN
JWT_EXPIRY=8h
JWT_REFRESH_EXPIRY=7d
WEBAUTHN_RP_ID=$TAPIZ_HOST
WEBAUTHN_ORIGINS=https://$TAPIZ_HOST
SALT_ROUNDS=10
CRON_SECRET=$CRON_SECRET_GEN

API_VERSION=real-stack-test
CACHE_PREFIX=tapiz:real-stack-test
QR_EXPIRY_SECONDS=300
ATTENDANCE_FLUSH_INTERVAL_MS=300000
ATTENDANCE_FLUSH_THRESHOLD=50
QUIZ_SUBMIT_FLUSH_INTERVAL_MS=60000

MAIL_SERVICE_URL=
MAIL_SERVICE_SECRET=
STORAGE_SERVICE_URL=
STORAGE_SERVICE_SECRET=
MAILBOX_SERVICE_URL=
MAILBOX_SERVICE_SECRET=
PDF_SERVICE_URL=
PDF_SERVICE_SECRET=
EXCEL_SERVICE_URL=
BOARDS_SERVICE_URL=

OAUTH_CLIENTS=
TELEMETRY_URL=
TELEMETRY_KEY=
APP_VERSION=real-stack-test
LOG_LEVEL=info
ALLOWED_STUDENT_EMAIL_SUFFIXES=ac.rs,edu.rs
LICENSE_GRACE_DAYS=7
RESOURCE_BOOKING_ENABLED=true

BILLING_SELLER_NAME=Real Stack Test
BILLING_SELLER_LEGAL_NAME=Real Stack Test
BILLING_SELLER_ADDRESS=Test
BILLING_SELLER_CITY=Test
BILLING_SELLER_COUNTRY=Serbia
BILLING_SELLER_PIB=000000000
BILLING_SELLER_VAT_ID=000000000
BILLING_SELLER_REGISTRATION_NO=00000000
BILLING_SELLER_EMAIL=ops@example.invalid
BILLING_SELLER_BANK_ACCOUNT=000-0000000000000-00
BILLING_SELLER_PAYMENT_MODEL=97
EOF
check "generated disposable .env.tapiz-real-stack with random-only local secrets" $?

log ""
log "== 2. Create disposable external edge network =="
export TAPIZ_EDGE_NETWORK="$TAPIZ_EDGE_NETWORK_NAME"
# `--env-file "$TAPIZ_ENV"` above only controls Compose's OWN variable
# interpolation (e.g. resolving `${TAPIZ_ENV_FILE:-.env}` itself) — it does
# NOT become part of the shell environment the real docker-compose.yml's own
# `env_file: ${TAPIZ_ENV_FILE:-.env}` key interpolates against. Without this
# export, that key silently falls back to the literal default `.env`,
# resolved relative to the compose file's own directory
# (apps/api/ops/vps/.env) — a REAL file that may exist on this machine with
# real secrets. Confirmed by direct reproduction: `docker compose config`
# without this export showed real production values (`CLIENT_URL:
# https://tapiz.site`, `CACHE_PREFIX: tapiz:production`) even though
# `--env-file "$TAPIZ_ENV"` (the disposable generated file) was already
# passed. Every container must load ONLY the disposable .env this script
# generates, never the real one.
export TAPIZ_ENV_FILE="$TAPIZ_ENV"
docker network create "$TAPIZ_EDGE_NETWORK_NAME" >/dev/null
check "created disposable $TAPIZ_EDGE_NETWORK_NAME network" $?

log ""
log "== 3. Build + bring up the real Tapiz VPS stack (no standalone-ingress profile) =="
# Building here (not --build alongside up) so the ~60-120s image build's own
# output does not get swallowed by `up`'s attached-container log interleaving.
tapiz_compose build postgres valkey pgbouncer auth-api-1 auth-api-2 scan-api general-api worker scheduler
check "real Tapiz images (api lanes, worker, scheduler) built from the real Dockerfile" $?

# Deliberately NOT passing the `caddy` service and NOT activating
# `standalone-ingress` — hard constraint 10(f). Only postgres/valkey/pgbouncer/
# the 4 lanes/worker/scheduler are started.
tapiz_compose up -d --quiet-pull postgres valkey pgbouncer auth-api-1 auth-api-2 scan-api general-api worker scheduler
check "real Tapiz stack containers started" $?

log ""
log "== 4. Wait for postgres/valkey/pgbouncer to report healthy =="
# Same `set -e` pitfall as bug #4 in ../../../README.md's bug list, one level
# removed: a helper FUNCTION whose own final statement is a bare `return 1`
# aborts the whole script the first time it legitimately returns non-zero,
# before `check` ever runs, exactly like a bare `[ ]` would. Every call site
# below therefore wraps `wait_healthy` in an `if`, never calling it as a bare
# statement immediately followed by `check ... $?`.
wait_healthy() {
  # $1 = compose function name to use ("tapiz_compose"/"gateway_compose"), $2 = service name, $3 = timeout seconds
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

if wait_healthy tapiz_compose postgres 60; then check "postgres reports healthy" 0; else check "postgres reports healthy" 1; fi
if wait_healthy tapiz_compose valkey 30; then check "valkey reports healthy" 0; else check "valkey reports healthy" 1; fi
if wait_healthy tapiz_compose pgbouncer 60; then check "pgbouncer reports healthy" 0; else check "pgbouncer reports healthy" 1; fi

log ""
log "== 5. Apply the Drizzle schema to the disposable Postgres (npm run db:push --force) =="
# Runs from inside a throwaway container on the stack's own private network —
# never a host-mapped Postgres port (hard constraint 4). See
# docker-compose.schema-push.yml for why this differs from the existing
# apps/api/ops/vps/loadtest/ pattern (host-port push), which Phase 1's
# constraints do not allow here.
TAPIZ_LMS_ROOT_DIR="$TAPIZ_LMS_DIR" \
  tapiz_compose_with_schema_push --profile schema-push run --rm schema-push
check "drizzle-kit push --force applied the schema to the disposable Postgres" $?

log ""
log "== 6. Wait for auth-api-1/auth-api-2/scan-api/general-api/worker/scheduler to report healthy =="
for svc in auth-api-1 auth-api-2 scan-api general-api worker; do
  if wait_healthy tapiz_compose "$svc" 60; then
    check "$svc reports healthy (real app booted, real DB connectivity through PgBouncer)" 0
  else
    check "$svc reports healthy (real app booted, real DB connectivity through PgBouncer)" 1
  fi
done

# scheduler's healthcheck is a pgrep, not an HTTP probe (see the real
# docker-compose.yml) — still surfaced through `docker compose ps`'s Health
# column the same way.
if wait_healthy tapiz_compose scheduler 30; then
  check "scheduler reports healthy (running, not crash-looping)" 0
else
  check "scheduler reports healthy (running, not crash-looping)" 1
fi

log ""
log "== 7. Confirm the product's own standalone-ingress caddy was never created =="
standalone_caddy=$(tapiz_compose ps -a --format '{{.Service}}' 2>/dev/null | grep -c '^caddy$' || true)
assert '[ "${standalone_caddy:-0}" = "0" ]' \
  "tapiz-lms's own standalone-ingress caddy service was never created"

log ""
log "== 8. Bring up the real, unmodified vps-gateway Caddy against the real stack =="
cat > "$GATEWAY_ENV" <<EOF
CADDY_EMAIL=ops@example.invalid
TAPIZ_API_DOMAIN=$TAPIZ_HOST
AURA_API_DOMAIN=api.aura-real.test
TAPIZ_EDGE_NETWORK=$TAPIZ_EDGE_NETWORK_NAME
AURA_EDGE_NETWORK=aura-edge-real-test-unused
EOF
# AURA_EDGE_NETWORK is never created in this harness (Phase 1 is Tapiz-only) —
# the gateway compose still declares it as an external network dependency, so
# it must exist for `up` to succeed even though no Aura routing is exercised.
docker network create aura-edge-real-test-unused >/dev/null 2>&1 || true

export GATEWAY_ENV_FILE="$GATEWAY_ENV"
gateway_compose up -d --quiet-pull
check "real gateway container started against the real Tapiz edge network" $?

# The gateway's own docker-compose.yml (real, unmodified) declares no
# healthcheck for its `caddy` service at all — confirmed by inspection, not
# an oversight in this harness. `{{.Health}}` is therefore always empty for
# this container, so `wait_healthy` (which polls that field) can never
# observe "healthy" here and would time out every run regardless of whether
# Caddy is actually serving traffic. Reachability is proven directly instead,
# by the routing assertions in step 9 below (real HTTP responses through the
# gateway) — this step only confirms the container is still Up, not crash-looping.
gateway_caddy_state=$(gateway_compose ps --format '{{.State}}' caddy 2>/dev/null || true)
assert '[ "$gateway_caddy_state" = "running" ]' \
  "gateway caddy container is running (no healthcheck defined on this service; reachability proven by step 9's routing assertions)"

curl_host() {
  # $1 = Host header, $2 = path, $3 = method (default GET), $4 = optional JSON body
  set +e
  attempt=0
  code=000
  while [ "$attempt" -lt 10 ]; do
    if [ -n "${4:-}" ]; then
      code=$(curl -sk -o /tmp/gateway-real-stack-test-body.json -w "%{http_code}" \
        --max-time 8 -X "${3:-GET}" \
        -H 'Content-Type: application/json' -d "$4" \
        --resolve "$1:$GATEWAY_TLS_PORT:127.0.0.1" \
        "https://$1:$GATEWAY_TLS_PORT$2" 2>/dev/null)
    else
      code=$(curl -sk -o /tmp/gateway-real-stack-test-body.json -w "%{http_code}" \
        --max-time 8 -X "${3:-GET}" \
        --resolve "$1:$GATEWAY_TLS_PORT:127.0.0.1" \
        "https://$1:$GATEWAY_TLS_PORT$2" 2>/dev/null)
    fi
    [ "$code" != "000" ] && break
    attempt=$((attempt + 1))
    sleep 2
  done
  set -e
  printf '%s' "$code"
}

log ""
log "== 9. Real login/scan/general traffic through the real gateway into the real lanes =="
# Wrong/nonexistent credentials are enough — a real 401/400 from the real
# auth-api Hono app (not a network-level failure) proves routing + the real
# app booted + real DB connectivity through PgBouncer, which is what Phase 1
# requires. See prompt's "What real login/scan traffic means" section for why
# a seeded account is not required here.
code=$(curl_host "$TAPIZ_HOST" "/api/auth/login" "POST" '{"email":"nobody@example.invalid","password":"wrong-password-123"}')
assert '[ "$code" = "401" ] || [ "$code" = "400" ]' \
  "POST /api/auth/login with bogus credentials -> real 4xx from auth lane (got HTTP $code)"

code=$(curl_host "$TAPIZ_HOST" "/api/attendance/scan" "POST" '{"token":"bogus-qr-token"}')
assert '[ "$code" -ge 400 ] && [ "$code" -lt 500 ]' \
  "POST /api/attendance/scan with bogus QR payload -> real 4xx from scan lane (got HTTP $code)"

code=$(curl_host "$TAPIZ_HOST" "/api/attendance/scan-student" "POST" '{"token":"bogus-qr-token","studentId":"00000000-0000-0000-0000-000000000000"}')
assert '[ "$code" -ge 400 ] && [ "$code" -lt 500 ]' \
  "POST /api/attendance/scan-student with bogus payload -> real 4xx from scan lane (got HTTP $code)"

code=$(curl_host "$TAPIZ_HOST" "/api/subjects" "GET")
assert '[ "$code" = "401" ]' \
  "GET /api/subjects unauthenticated -> real 401 from general lane, not a routing failure (got HTTP $code)"

log ""
log "== 10. PgBouncer / worker / scheduler behind the central gateway =="
tapiz_pg_user=$(grep '^POSTGRES_USER=' "$TAPIZ_ENV" | cut -d= -f2)
tapiz_pg_password=$(grep '^POSTGRES_PASSWORD=' "$TAPIZ_ENV" | cut -d= -f2)
# `psql ... -d pgbouncer -c 'SHOW POOLS;'` (the admin console) is NOT reachable
# with the app's regular DB user by design — confirmed by direct reproduction:
# it fails with "FATAL: not allowed" because that user is not in PgBouncer's
# `admin_users`/`stats_users`, which the real (unmodified) docker-compose.yml
# does not set. This is exactly why that file's own healthcheck already reads
# `... SHOW POOLS ... || pg_isready ...` — the psql half is expected to fail
# and the pg_isready half is what actually passes in every real run observed.
# This assertion uses the same fallback the real healthcheck relies on, rather
# than asserting on the admin console this stack was never configured to expose.
pgbouncer_pg_isready=$(tapiz_compose exec -T -e PGPASSWORD="$tapiz_pg_password" pgbouncer \
  pg_isready -h 127.0.0.1 -p 5432 -U "$tapiz_pg_user" 2>&1 || true)
assert 'printf "%s" "$pgbouncer_pg_isready" | grep -q "accepting connections"' \
  "PgBouncer accepts connections on its pooled listener (pool alive, not crash-looping)"

worker_health=$(tapiz_compose ps --format '{{.Health}}' worker 2>/dev/null || true)
assert '[ "$worker_health" = "healthy" ]' \
  "worker still healthy after traffic (not crash-looping)"

scheduler_health=$(tapiz_compose ps --format '{{.Health}}' scheduler 2>/dev/null || true)
assert '[ "$scheduler_health" = "healthy" ]' \
  "scheduler still healthy after traffic (not crash-looping)"

log ""
log "== 11. No host ports on any real Tapiz application/data container =="
# Only the gateway container may publish a host port (hard constraint 3/4).
tapiz_ports=$(docker ps --filter "label=com.docker.compose.project=$TAPIZ_PROJECT" --format '{{.Ports}}' 2>/dev/null || true)
bad=$(printf '%s\n' "$tapiz_ports" | grep -c '0.0.0.0\|:::' || true)
assert '[ "${bad:-0}" = "0" ]' \
  "no real Tapiz container (postgres/valkey/pgbouncer/lanes/worker/scheduler) publishes a host port"

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
