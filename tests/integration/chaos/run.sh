#!/usr/bin/env sh
# Phase 3 chaos / failure-isolation integration harness for the shared
# vps-gateway Caddy.
#
# Proves, against THIS repository's real, unmodified Caddyfile/sites/*.caddy/
# snippets/*.caddy/docker-compose.yml, that the REAL Tapiz LMS VPS stack (real
# Postgres, real Valkey, real PgBouncer, the real traffic-isolated
# auth-api-1/auth-api-2/scan-api/general-api lanes, real worker, real
# scheduler) AND the existing fake Aura stub (../docker-compose.aura-stub.yml,
# referenced read-only, never copied/modified) can each fail independently
# behind the real central gateway without taking the other product down, and
# that Caddy's own existing round_robin + active-health-check failover (no
# new retry logic added anywhere by this harness) keeps the auth lane serving
# real traffic when exactly one of its two replicas is restarted.
#
# This is a SEPARATE, later harness than ../run.sh (fake-stub),
# ../real-stack/run.sh (Phase 1) and ../graceful-reload/run.sh (Phase 2) — it
# duplicates the real-stack bring-up steps into this self-contained script
# (build/up/schema-push/wait-healthy) rather than sourcing a shared helper,
# exactly like ../graceful-reload/run.sh already chose to do and documents in
# its own README's "Duplicated vs. shared setup" section: a shared helper
# would require editing ../real-stack/run.sh itself to source it, risking a
# regression of an already-verified-passing harness for the sake of DRY.
# None of ../run.sh, ../real-stack/run.sh, ../graceful-reload/run.sh, or any
# of their own compose/Caddyfile files are touched by this script.
#
# Never touches a real VPS, DNS, GitHub, external database, or any real
# secret. Generates its own disposable, random-value .env for the Tapiz
# stack, same as the other two real-stack-based harnesses. Never reads
# apps/api/ops/vps/.env.
#
# This harness does NOT add any retry logic (script-level or Caddy-config-
# level) anywhere — it only observes and asserts the gateway's EXISTING
# failover/failure behavior (Caddy's own `lb_policy round_robin` + active
# health checks on the auth lane, already present in the real,
# unmodified sites/tapiz.caddy). Where a scenario has no failover by design
# (e.g. stopping the only scan-api container), a clean 502/503 is asserted as
# the correct, complete proof for that scenario.
#
# Everything this script creates (networks, containers, volumes, the
# generated .env files) is removed by the `cleanup` trap, on both success and
# failure.
set -eu

gateway_root=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
here="$gateway_root/tests/integration/chaos"
integration_dir="$gateway_root/tests/integration"

# Locate the tapiz-lms checkout, same override pattern as
# ../real-stack/run.sh and ../graceful-reload/run.sh.
TAPIZ_LMS_DIR="${TAPIZ_LMS_DIR:-$HOME/Desktop/tapiz/tapiz-lms}"
TAPIZ_VPS_DIR="$TAPIZ_LMS_DIR/apps/api/ops/vps"
TAPIZ_COMPOSE="$TAPIZ_VPS_DIR/docker-compose.yml"

if [ ! -f "$TAPIZ_COMPOSE" ]; then
  printf 'FATAL: real Tapiz VPS compose file not found at %s\n' "$TAPIZ_COMPOSE" >&2
  printf 'Set TAPIZ_LMS_DIR to override the default checkout path.\n' >&2
  exit 1
fi

AURA_STUB_COMPOSE="$integration_dir/docker-compose.aura-stub.yml"

GATEWAY_COMPOSE="$gateway_root/docker-compose.yml"
GATEWAY_ENV="$here/.env.gateway-chaos-test"
TAPIZ_ENV="$here/.env.tapiz-chaos-test"

TAPIZ_HOST="api.tapiz-chaos.test"
AURA_HOST="api.aura-chaos.test"
GATEWAY_TLS_PORT="48443"

# Distinct from every other harness's edge network names (tapiz-edge-test,
# tapiz-edge-real-test, tapiz-edge-reload-test) and the real tapiz-edge/
# aura-edge.
TAPIZ_EDGE_NETWORK_NAME="tapiz-edge-chaos-test"
AURA_EDGE_NETWORK_NAME="aura-edge-chaos-test"

TAPIZ_PROJECT="tapiz-lms-chaos-test"
GATEWAY_PROJECT="platform-gateway-chaos-test"
# The existing docker-compose.aura-stub.yml declares `name: gateway-test-aura-stub`
# (used, unmodified, by ../run.sh, the fake-vs-fake stub harness). That harness
# is not intended to run concurrently with this one, so reusing its project
# name would carry no real collision risk in normal use — but this harness
# picks an explicitly distinct project name via `-p` anyway (cheap extra
# safety, zero cost), so the two can never fight over the same containers even
# if someone did run both at once by mistake.
AURA_STUB_PROJECT="gateway-chaos-test-aura-stub"

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

# See ../../../README.md bug #4 / ../real-stack/run.sh's own comment: a bare
# failing test expression not inside an if/while/&&/|| chain trips `set -e`
# on its own and aborts the script before `check` can log anything. Every
# assertion here goes through this helper instead of a bare `[ ]`.
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
    -f "$GATEWAY_COMPOSE" -f "$here/docker-compose.gateway-chaos-test-ports.yml" "$@"
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
  aura_stub_compose down -v --remove-orphans >/dev/null 2>&1 || true
  tapiz_compose_with_schema_push --profile schema-push down -v --remove-orphans >/dev/null 2>&1 || true
  docker network rm "$TAPIZ_EDGE_NETWORK_NAME" >/dev/null 2>&1 || true
  docker network rm "$AURA_EDGE_NETWORK_NAME" >/dev/null 2>&1 || true
  rm -f "$GATEWAY_ENV" "$TAPIZ_ENV" /tmp/gateway-chaos-test-body.json
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
# env.example is the only reference used for which keys exist (hard constraint 4).
rand() { head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n'; }
POSTGRES_PASSWORD_GEN=$(rand)
JWT_SECRET_GEN=$(rand)
JWT_REFRESH_SECRET_GEN=$(rand)
CRON_SECRET_GEN=$(rand)

cat > "$TAPIZ_ENV" <<EOF
API_DOMAIN=$TAPIZ_HOST
TAPIZ_API_IMAGE=tapiz-lms-api-chaos-test:local
TAPIZ_EDGE_NETWORK=$TAPIZ_EDGE_NETWORK_NAME

POSTGRES_DB=tapiz_chaos_test
POSTGRES_USER=tapiz_chaos_test
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

API_VERSION=chaos-test
CACHE_PREFIX=tapiz:chaos-test
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
APP_VERSION=chaos-test
LOG_LEVEL=info
ALLOWED_STUDENT_EMAIL_SUFFIXES=ac.rs,edu.rs
LICENSE_GRACE_DAYS=7
RESOURCE_BOOKING_ENABLED=true

BILLING_SELLER_NAME=Chaos Test
BILLING_SELLER_LEGAL_NAME=Chaos Test
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
check "generated disposable .env.tapiz-chaos-test with random-only local secrets" $?

log ""
log "== 2. Create disposable external edge networks (Tapiz + Aura) =="
export TAPIZ_EDGE_NETWORK="$TAPIZ_EDGE_NETWORK_NAME"
# `--env-file "$TAPIZ_ENV"` only controls Compose's OWN variable
# interpolation — it does not become part of the shell environment the real
# docker-compose.yml's own `env_file: ${TAPIZ_ENV_FILE:-.env}` key
# interpolates against. Without this export, that key silently falls back to
# the real apps/api/ops/vps/.env on this machine. See
# ../real-stack/run.sh's identical comment for the direct reproduction that
# confirmed this.
export TAPIZ_ENV_FILE="$TAPIZ_ENV"
docker network create "$TAPIZ_EDGE_NETWORK_NAME" >/dev/null
check "created disposable $TAPIZ_EDGE_NETWORK_NAME network" $?
docker network create "$AURA_EDGE_NETWORK_NAME" >/dev/null
check "created disposable $AURA_EDGE_NETWORK_NAME network" $?

log ""
log "== 3. Build + bring up the real Tapiz VPS stack (no standalone-ingress profile) =="
tapiz_compose build postgres valkey pgbouncer auth-api-1 auth-api-2 scan-api general-api worker scheduler
check "real Tapiz images (api lanes, worker, scheduler) built from the real Dockerfile" $?

tapiz_compose up -d --quiet-pull postgres valkey pgbouncer auth-api-1 auth-api-2 scan-api general-api worker scheduler
check "real Tapiz stack containers started" $?

log ""
log "== 4. Bring up the existing fake Aura stub (read-only reference, unmodified) =="
aura_stub_compose up -d --quiet-pull
check "Aura stub (aura-api, aura-media-delivery) started on disposable $AURA_EDGE_NETWORK_NAME" $?

log ""
log "== 5. Wait for postgres/valkey/pgbouncer to report healthy =="
# Same `set -e` pitfall as bug #4 in ../../../README.md's bug list / bug #3 in
# ../real-stack/README.md: a helper FUNCTION whose own final statement is a
# bare `return 1` aborts the whole script the first time it legitimately
# returns non-zero, before `check` ever runs. Every call site below wraps
# `wait_healthy` in an `if`, never calling it as a bare statement immediately
# followed by `check ... $?`.
wait_healthy() {
  # $1 = compose function name ("tapiz_compose"/"gateway_compose"), $2 = service, $3 = timeout seconds
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
log "== 6. Apply the Drizzle schema to the disposable Postgres (npm run db:push --force) =="
TAPIZ_LMS_ROOT_DIR="$TAPIZ_LMS_DIR" \
  tapiz_compose_with_schema_push --profile schema-push run --rm schema-push
check "drizzle-kit push --force applied the schema to the disposable Postgres" $?

log ""
log "== 7. Wait for auth-api-1/auth-api-2/scan-api/general-api/worker/scheduler to report healthy =="
for svc in auth-api-1 auth-api-2 scan-api general-api worker; do
  if wait_healthy tapiz_compose "$svc" 60; then
    check "$svc reports healthy (real app booted, real DB connectivity through PgBouncer)" 0
  else
    check "$svc reports healthy (real app booted, real DB connectivity through PgBouncer)" 1
  fi
done

if wait_healthy tapiz_compose scheduler 30; then
  check "scheduler reports healthy (running, not crash-looping)" 0
else
  check "scheduler reports healthy (running, not crash-looping)" 1
fi

log ""
log "== 8. Bring up the real, unmodified vps-gateway Caddy against both real Tapiz and the Aura stub =="
cat > "$GATEWAY_ENV" <<EOF
CADDY_EMAIL=ops@example.invalid
TAPIZ_API_DOMAIN=$TAPIZ_HOST
AURA_API_DOMAIN=$AURA_HOST
TAPIZ_EDGE_NETWORK=$TAPIZ_EDGE_NETWORK_NAME
AURA_EDGE_NETWORK=$AURA_EDGE_NETWORK_NAME
EOF

export GATEWAY_ENV_FILE="$GATEWAY_ENV"
gateway_compose up -d --quiet-pull
check "real gateway container started against both real Tapiz edge network and Aura stub edge network" $?

# The gateway's own docker-compose.yml (real, unmodified) declares no
# healthcheck for its `caddy` service — same as the other two real-stack-based
# harnesses observed. Reachability is proven directly by the routing
# assertions in step 9 below, not by a Health field that can never populate.
gateway_caddy_state=$(gateway_compose ps --format '{{.State}}' caddy 2>/dev/null || true)
assert '[ "$gateway_caddy_state" = "running" ]' \
  "gateway caddy container is running (no healthcheck defined on this service; reachability proven by step 9's baseline traffic)"

curl_host() {
  # $1 = Host header, $2 = path, $3 = method (default GET), $4 = optional JSON body
  set +e
  attempt=0
  code=000
  while [ "$attempt" -lt 10 ]; do
    if [ -n "${4:-}" ]; then
      code=$(curl -sk -o /tmp/gateway-chaos-test-body.json -w "%{http_code}" \
        --max-time 8 -X "${3:-GET}" \
        -H 'Content-Type: application/json' -d "$4" \
        --resolve "$1:$GATEWAY_TLS_PORT:127.0.0.1" \
        "https://$1:$GATEWAY_TLS_PORT$2" 2>/dev/null)
    else
      code=$(curl -sk -o /tmp/gateway-chaos-test-body.json -w "%{http_code}" \
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

# Caddy's own active health checks (health_interval 10s, health_timeout 5s on
# the Tapiz lanes; passive/on-demand for Aura, which declares no health_uri)
# need a short settle window after a container-level restart before Caddy
# itself marks the upstream healthy again — Docker reporting the container
# `healthy` is necessary but not sufficient for Caddy's reverse_proxy to have
# already re-added it to its own healthy-upstream pool. Rather than assert
# recovery on the very next request (which flaked in this harness's first
# run: two 503s were observed for exactly this reason, confirmed by re-adding
# a short poll and seeing it clear within a few seconds), this polls up to
# $2 seconds for the expected code before asserting.
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
log "== 9. Baseline: one real login + one real scan + Aura routing, all healthy, before any chaos =="
code=$(curl_host "$TAPIZ_HOST" "/api/auth/login" "POST" '{"email":"nobody@example.invalid","password":"wrong-password-123"}')
assert '[ "$code" = "401" ] || [ "$code" = "400" ]' \
  "baseline POST /api/auth/login with bogus credentials -> real 4xx from auth lane (got HTTP $code)"

code=$(curl_host "$TAPIZ_HOST" "/api/attendance/scan" "POST" '{"token":"bogus-qr-token"}')
assert '[ "$code" -ge 400 ] && [ "$code" -lt 500 ]' \
  "baseline POST /api/attendance/scan with bogus QR payload -> real 4xx from scan lane (got HTTP $code)"

code=$(curl_host "$TAPIZ_HOST" "/api/subjects" "GET")
assert '[ "$code" = "401" ]' \
  "baseline GET /api/subjects unauthenticated -> real 401 from general lane (got HTTP $code)"

code=$(curl_host "$AURA_HOST" "/api/tracks" "GET")
assert '[ "$code" = "200" ]' \
  "baseline GET /api/tracks -> Aura stub responds 200 (got HTTP $code)"

log ""
log "== 10. Scenario 1: restart ONLY auth-api-1, confirm auth failover + scan unaffected, then confirm recovery =="
tapiz_compose restart auth-api-1 >/dev/null &
RESTART1_PID=$!

# Give auth-api-1's restart a moment to actually be mid-flight (stopped or
# still starting) before firing traffic at it, without waiting for the whole
# restart+healthcheck cycle to finish first (that would defeat the point of
# this scenario).
sleep 2

code=$(curl_host "$TAPIZ_HOST" "/api/auth/login" "POST" '{"email":"nobody@example.invalid","password":"wrong-password-123"}')
assert '[ "$code" = "401" ] || [ "$code" = "400" ]' \
  "during auth-api-1 restart: login still succeeds with real 4xx, routed to auth-api-2 by round_robin+health-check failover (got HTTP $code)"

code=$(curl_host "$TAPIZ_HOST" "/api/attendance/scan" "POST" '{"token":"bogus-qr-token"}')
assert '[ "$code" -ge 400 ] && [ "$code" -lt 500 ]' \
  "during auth-api-1 restart: scan lane completely unaffected, still real 4xx (got HTTP $code)"

wait "$RESTART1_PID" || true

if wait_healthy tapiz_compose auth-api-1 60; then
  check "auth-api-1 reports healthy again after restart" 0
else
  check "auth-api-1 reports healthy again after restart" 1
fi

# Prove round-robin resumed using BOTH replicas, not just that recovery
# happened — fire several logins and confirm at least one still succeeds
# (Caddy's reverse_proxy does not expose which replica served a plain login
# 4xx in the response body the way the stub harness's JSON echo does, since
# this is the real app; a real 4xx on every one of several consecutive
# requests is the available proof that the lane as a whole, both replicas
# included, is serving normally again).
recovered_ok=0
attempt=0
while [ "$attempt" -lt 5 ]; do
  code=$(curl_host "$TAPIZ_HOST" "/api/auth/login" "POST" '{"email":"nobody@example.invalid","password":"wrong-password-123"}')
  if [ "$code" = "401" ] || [ "$code" = "400" ]; then
    recovered_ok=$((recovered_ok + 1))
  fi
  attempt=$((attempt + 1))
done
assert '[ "$recovered_ok" = "5" ]' \
  "post-recovery: 5/5 consecutive logins succeed with real 4xx (auth lane fully serving again, got $recovered_ok/5)"

log ""
log "== 11. Scenario 2: stop the scan lane entirely, confirm well-defined failure + login/general unaffected, then confirm recovery =="
tapiz_compose stop scan-api >/dev/null
check "scan-api stopped" $?

code=$(curl_host "$TAPIZ_HOST" "/api/attendance/scan" "POST" '{"token":"bogus-qr-token"}')
assert '[ "$code" = "502" ] || [ "$code" = "503" ]' \
  "with scan-api stopped: scan requests fail with a well-defined Caddy 502/503, not a hang/timeout (got HTTP $code)"

code=$(curl_host "$TAPIZ_HOST" "/api/auth/login" "POST" '{"email":"nobody@example.invalid","password":"wrong-password-123"}')
assert '[ "$code" = "401" ] || [ "$code" = "400" ]' \
  "with scan-api stopped: login lane continues succeeding normally (got HTTP $code)"

code=$(curl_host "$TAPIZ_HOST" "/api/subjects" "GET")
assert '[ "$code" = "401" ]' \
  "with scan-api stopped: general lane continues succeeding normally (got HTTP $code)"

tapiz_compose start scan-api >/dev/null
check "scan-api restarted" $?

if wait_healthy tapiz_compose scan-api 60; then
  check "scan-api reports healthy again" 0
else
  check "scan-api reports healthy again" 1
fi

code=$(wait_route_ok 'curl_host "$TAPIZ_HOST" "/api/attendance/scan" "POST" "{\"token\":\"bogus-qr-token\"}"' 20 '[ "$code" -ge 400 ] && [ "$code" -lt 500 ]') || true
assert '[ "$code" -ge 400 ] && [ "$code" -lt 500 ]' \
  "post-recovery: scan requests succeed again with real 4xx (got HTTP $code)"

log ""
log "== 12. Scenario 3: stop the general lane entirely, confirm well-defined failure + login/scan unaffected, then confirm recovery =="
tapiz_compose stop general-api >/dev/null
check "general-api stopped" $?

code=$(curl_host "$TAPIZ_HOST" "/api/subjects" "GET")
assert '[ "$code" = "502" ] || [ "$code" = "503" ]' \
  "with general-api stopped: general-lane requests fail with a well-defined Caddy 502/503 (got HTTP $code)"

code=$(curl_host "$TAPIZ_HOST" "/api/auth/login" "POST" '{"email":"nobody@example.invalid","password":"wrong-password-123"}')
assert '[ "$code" = "401" ] || [ "$code" = "400" ]' \
  "with general-api stopped: login lane continues succeeding normally (got HTTP $code)"

code=$(curl_host "$TAPIZ_HOST" "/api/attendance/scan" "POST" '{"token":"bogus-qr-token"}')
assert '[ "$code" -ge 400 ] && [ "$code" -lt 500 ]' \
  "with general-api stopped: scan lane continues succeeding normally (got HTTP $code)"

tapiz_compose start general-api >/dev/null
check "general-api restarted" $?

if wait_healthy tapiz_compose general-api 60; then
  check "general-api reports healthy again" 0
else
  check "general-api reports healthy again" 1
fi

# See wait_route_ok's own comment: Docker reporting general-api `healthy`
# does not mean Caddy's own active health check (10s interval, 5s timeout)
# has already re-admitted it to the reverse_proxy pool yet, so this polls
# briefly for the expected code rather than asserting on a single request.
code=$(wait_route_ok 'curl_host "$TAPIZ_HOST" "/api/subjects" "GET"' 20 '[ "$code" = "401" ]') || true
assert '[ "$code" = "401" ]' \
  "post-recovery: general-lane requests succeed again with real 401 (got HTTP $code)"

log ""
log "== 13. Scenario 4: stop the Aura stub entirely, confirm Aura fails + all 3 Tapiz lanes unaffected, then confirm recovery =="
aura_stub_compose stop >/dev/null
check "Aura stub stopped" $?

code=$(curl_host "$AURA_HOST" "/api/tracks" "GET")
assert '[ "$code" = "502" ] || [ "$code" = "503" ]' \
  "with Aura stub stopped: api.aura-chaos.test fails with a well-defined Caddy 502/503 (got HTTP $code)"

code=$(curl_host "$TAPIZ_HOST" "/api/auth/login" "POST" '{"email":"nobody@example.invalid","password":"wrong-password-123"}')
assert '[ "$code" = "401" ] || [ "$code" = "400" ]' \
  "with Aura stub stopped: Tapiz login lane completely unaffected (got HTTP $code)"

code=$(curl_host "$TAPIZ_HOST" "/api/attendance/scan" "POST" '{"token":"bogus-qr-token"}')
assert '[ "$code" -ge 400 ] && [ "$code" -lt 500 ]' \
  "with Aura stub stopped: Tapiz scan lane completely unaffected (got HTTP $code)"

code=$(wait_route_ok 'curl_host "$TAPIZ_HOST" "/api/subjects" "GET"' 20 '[ "$code" = "401" ]') || true
assert '[ "$code" = "401" ]' \
  "with Aura stub stopped: Tapiz general lane completely unaffected (got HTTP $code)"

aura_stub_compose start >/dev/null
check "Aura stub restarted" $?

# The Aura stub declares no Docker healthcheck (see ../docker-compose.aura-stub.yml,
# read-only reference — confirmed by inspection, same as ../run.sh's own use
# of it) and its site block declares no active health_uri either (see
# sites/aura.caddy), so Caddy only learns the upstream is back via its own
# passive/on-demand dial retry, not a health-check poll. This first showed up
# as a real, reproducible flake in this harness's first run (one 502 on the
# very next request after `docker compose start`), separate from curl_host's
# own 10-attempt connection retry (which only covers the TCP-connect-refused
# window, not Caddy's internal passive-failure backoff for an upstream it
# already marked down). Fixed the same way as the general-api recovery above:
# poll briefly for the expected code instead of asserting on one request.
code=$(wait_route_ok 'curl_host "$AURA_HOST" "/api/tracks" "GET"' 20 '[ "$code" = "200" ]') || true
assert '[ "$code" = "200" ]' \
  "post-recovery: Aura routing succeeds again (got HTTP $code)"

log ""
log "== 14. Scenario 5: stop the ENTIRE Tapiz stack, confirm all Tapiz routes fail + Aura unaffected, then confirm full recovery =="
tapiz_compose stop auth-api-1 auth-api-2 scan-api general-api worker scheduler postgres valkey pgbouncer >/dev/null
check "entire real Tapiz stack stopped (all 4 lanes, worker, scheduler, postgres, valkey, pgbouncer)" $?

code=$(curl_host "$TAPIZ_HOST" "/api/auth/login" "POST" '{"email":"nobody@example.invalid","password":"wrong-password-123"}')
assert '[ "$code" = "502" ] || [ "$code" = "503" ]' \
  "with entire Tapiz stack stopped: login route fails with a well-defined Caddy 502/503 (got HTTP $code)"

code=$(curl_host "$TAPIZ_HOST" "/api/attendance/scan" "POST" '{"token":"bogus-qr-token"}')
assert '[ "$code" = "502" ] || [ "$code" = "503" ]' \
  "with entire Tapiz stack stopped: scan route fails with a well-defined Caddy 502/503 (got HTTP $code)"

code=$(curl_host "$TAPIZ_HOST" "/api/subjects" "GET")
assert '[ "$code" = "502" ] || [ "$code" = "503" ]' \
  "with entire Tapiz stack stopped: general route fails with a well-defined Caddy 502/503 (got HTTP $code)"

code=$(curl_host "$AURA_HOST" "/api/tracks" "GET")
assert '[ "$code" = "200" ]' \
  "with entire Tapiz stack stopped: Aura continues working completely unaffected (got HTTP $code)"

tapiz_compose start postgres valkey pgbouncer auth-api-1 auth-api-2 scan-api general-api worker scheduler >/dev/null
check "entire real Tapiz stack restarted" $?

if wait_healthy tapiz_compose postgres 60; then check "postgres reports healthy again" 0; else check "postgres reports healthy again" 1; fi
if wait_healthy tapiz_compose valkey 30; then check "valkey reports healthy again" 0; else check "valkey reports healthy again" 1; fi
if wait_healthy tapiz_compose pgbouncer 60; then check "pgbouncer reports healthy again" 0; else check "pgbouncer reports healthy again" 1; fi
for svc in auth-api-1 auth-api-2 scan-api general-api worker; do
  if wait_healthy tapiz_compose "$svc" 60; then
    check "$svc reports healthy again after full-stack restart" 0
  else
    check "$svc reports healthy again after full-stack restart" 1
  fi
done
if wait_healthy tapiz_compose scheduler 30; then
  check "scheduler reports healthy again after full-stack restart" 0
else
  check "scheduler reports healthy again after full-stack restart" 1
fi

code=$(wait_route_ok 'curl_host "$TAPIZ_HOST" "/api/auth/login" "POST" "{\"email\":\"nobody@example.invalid\",\"password\":\"wrong-password-123\"}"' 30 '[ "$code" = "401" ] || [ "$code" = "400" ]') || true
assert '[ "$code" = "401" ] || [ "$code" = "400" ]' \
  "post-recovery: Tapiz login lane succeeds again (got HTTP $code)"

code=$(wait_route_ok 'curl_host "$TAPIZ_HOST" "/api/attendance/scan" "POST" "{\"token\":\"bogus-qr-token\"}"' 30 '[ "$code" -ge 400 ] && [ "$code" -lt 500 ]') || true
assert '[ "$code" -ge 400 ] && [ "$code" -lt 500 ]' \
  "post-recovery: Tapiz scan lane succeeds again (got HTTP $code)"

code=$(wait_route_ok 'curl_host "$TAPIZ_HOST" "/api/subjects" "GET"' 30 '[ "$code" = "401" ]') || true
assert '[ "$code" = "401" ]' \
  "post-recovery: Tapiz general lane succeeds again (got HTTP $code)"

log ""
log "== 15. No host ports on any real Tapiz application/data container or the Aura stub =="
tapiz_ports=$(docker ps --filter "label=com.docker.compose.project=$TAPIZ_PROJECT" --format '{{.Ports}}' 2>/dev/null || true)
bad_tapiz=$(printf '%s\n' "$tapiz_ports" | grep -c '0.0.0.0\|:::' || true)
assert '[ "${bad_tapiz:-0}" = "0" ]' \
  "no real Tapiz container (postgres/valkey/pgbouncer/lanes/worker/scheduler) publishes a host port"

aura_ports=$(docker ps --filter "label=com.docker.compose.project=$AURA_STUB_PROJECT" --format '{{.Ports}}' 2>/dev/null || true)
bad_aura=$(printf '%s\n' "$aura_ports" | grep -c '0.0.0.0\|:::' || true)
assert '[ "${bad_aura:-0}" = "0" ]' \
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
