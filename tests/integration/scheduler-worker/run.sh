#!/usr/bin/env sh
# Phase 5 scheduler/worker coexistence integration harness for the shared
# vps-gateway Caddy.
#
# Proves, against THIS repository's real, unmodified Caddyfile/sites/*.caddy/
# snippets/*.caddy/docker-compose.yml, that the REAL Tapiz LMS VPS stack (real
# Postgres, real Valkey, real PgBouncer, real auth-api-1/auth-api-2/scan-api/
# general-api lanes, real worker, real scheduler — apps/api/ops/vps/docker-
# compose.yml, referenced from tapiz-lms, never copied) keeps serving normal
# login/scan/general traffic through the real central gateway while:
#   1. the real `worker` container runs its normal background flush timers
#      (DISABLE_BACKGROUND_WORKERS unset on it, confirmed by reading the real
#      compose file — not something this harness changes), and
#   2. the scheduler's own authenticated cron-route mechanism is triggered
#      (safe test trigger, not a real cron wait — see step 12 below and the
#      README for why), one or more times during a sustained traffic window.
#
# This is a SEPARATE, later harness than ../run.sh (fake-stub),
# ../real-stack/run.sh (Phase 1), ../graceful-reload/run.sh (Phase 2),
# ../chaos/run.sh (Phase 3), and ../backup-restore/run.sh (Phase 4) — it
# duplicates the real-stack bring-up steps into this self-contained script
# (build/up/schema-push/wait-healthy), exactly like ../graceful-reload/run.sh
# and ../chaos/run.sh already chose to do (see their own READMEs'
# "Duplicated vs. shared setup" sections): a shared helper would require
# editing an already-verified-passing harness to source it, risking a
# regression for the sake of DRY. It also reuses ../backup-restore/'s proven
# seed-demo.ts + postgres-test network-alias pattern for realistic seeded
# data (real enrolled students/sessions), rather than an empty schema. None
# of the four existing harnesses or their own compose/Caddyfile files are
# touched by this script.
#
# Never touches a real VPS, DNS, GitHub, external database, or any real
# secret. Generates its own disposable, random-value .env for the Tapiz
# stack, same as the other real-stack-based harnesses. Never reads
# apps/api/ops/vps/.env.
#
# This harness does NOT add any retry logic anywhere — it only observes and
# measures the stack's EXISTING scheduler/worker/PgBouncer/Valkey behavior
# under real concurrent traffic, same rule ../chaos/run.sh already documents.
#
# Everything this script creates (networks, containers, volumes, the
# generated .env files, background traffic loops, log files) is removed by
# the `cleanup` trap, on both success and failure.
set -eu

gateway_root=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
here="$gateway_root/tests/integration/scheduler-worker"

# Locate the tapiz-lms checkout, same override pattern as every other
# real-stack-based harness (per CLAUDE.md: ~/Desktop/tapiz/tapiz-lms).
TAPIZ_LMS_DIR="${TAPIZ_LMS_DIR:-$HOME/Desktop/tapiz/tapiz-lms}"
TAPIZ_VPS_DIR="$TAPIZ_LMS_DIR/apps/api/ops/vps"
TAPIZ_COMPOSE="$TAPIZ_VPS_DIR/docker-compose.yml"

if [ ! -f "$TAPIZ_COMPOSE" ]; then
  printf 'FATAL: real Tapiz VPS compose file not found at %s\n' "$TAPIZ_COMPOSE" >&2
  printf 'Set TAPIZ_LMS_DIR to override the default checkout path.\n' >&2
  exit 1
fi

GATEWAY_COMPOSE="$gateway_root/docker-compose.yml"
GATEWAY_ENV="$here/.env.gateway-scheduler-test"
TAPIZ_ENV="$here/.env.tapiz-scheduler-test"

TAPIZ_HOST="api.tapiz-scheduler.test"
GATEWAY_TLS_PORT="58443"

# Distinct from every other harness's edge network name (tapiz-edge-test,
# tapiz-edge-real-test, tapiz-edge-reload-test, tapiz-edge-chaos-test) and the
# real tapiz-edge.
TAPIZ_EDGE_NETWORK_NAME="tapiz-edge-scheduler-test"

TAPIZ_PROJECT="tapiz-lms-scheduler-test"
GATEWAY_PROJECT="platform-gateway-scheduler-test"

LOGIN_LOG="$here/.login-traffic.log"
SCAN_LOG="$here/.scan-traffic.log"
GENERAL_LOG="$here/.general-traffic.log"
TRAFFIC_PIDS_FILE="$here/.traffic-pids"
TRAFFIC_WINDOW_SECONDS=25

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

# See ../../../README.md bug #4 / every other harness's own comment: a bare
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
    -f "$TAPIZ_COMPOSE" -f "$here/docker-compose.postgres-alias.yml" "$@"
}

tapiz_compose_with_jobs() {
  docker compose -p "$TAPIZ_PROJECT" --env-file "$TAPIZ_ENV" \
    -f "$TAPIZ_COMPOSE" -f "$here/docker-compose.postgres-alias.yml" \
    -f "$here/docker-compose.schema-push.yml" "$@"
}

# Real bug found while building this harness, inherited by
# ../real-stack/run.sh, ../graceful-reload/run.sh, ../chaos/run.sh, and
# ../backup-restore/run.sh (none of them trip over it, since none check a
# CRON_SECRET-gated route's exact response) — see this harness's own README
# "Real bugs found and fixed" section for the full writeup. The real
# apps/api/ops/vps/docker-compose.yml's every service declares
# `env_file: ${TAPIZ_ENV_FILE:-.env}`. `TAPIZ_ENV_FILE` is a Compose
# INTERPOLATION variable resolved from `--env-file "$TAPIZ_ENV"`'s own
# contents/the shell environment — merely passing `--env-file "$TAPIZ_ENV"`
# does NOT set `TAPIZ_ENV_FILE` itself, so `${TAPIZ_ENV_FILE:-.env}` silently
# falls back to the LITERAL, real `apps/api/ops/vps/.env` sitting next to the
# compose file on this dev machine (confirmed present, with a real
# `CRON_SECRET` inside it) for every container's actual runtime environment.
# `TAPIZ_ENV_FILE` must be exported so it resolves to the disposable
# `$TAPIZ_ENV` this harness generates, exactly like `GATEWAY_ENV_FILE` is
# already (correctly) exported for the gateway compose below.
export TAPIZ_ENV_FILE="$TAPIZ_ENV"

gateway_compose() {
  docker compose -p "$GATEWAY_PROJECT" --env-file "$GATEWAY_ENV" \
    -f "$GATEWAY_COMPOSE" -f "$here/docker-compose.gateway-scheduler-test-ports.yml" "$@"
}

stop_traffic() {
  if [ -f "$TRAFFIC_PIDS_FILE" ]; then
    while read -r pid; do
      [ -n "$pid" ] && kill "$pid" >/dev/null 2>&1 || true
    done < "$TRAFFIC_PIDS_FILE"
    sleep 1
    rm -f "$TRAFFIC_PIDS_FILE"
  fi
}

cleanup() {
  status=$?
  log ""
  log "== Teardown =="
  stop_traffic
  gateway_compose down -v --remove-orphans >/dev/null 2>&1 || true
  tapiz_compose_with_jobs --profile schema-push --profile seed-demo down -v --remove-orphans >/dev/null 2>&1 || true
  docker network rm "$TAPIZ_EDGE_NETWORK_NAME" >/dev/null 2>&1 || true
  docker network rm aura-edge-scheduler-test-unused >/dev/null 2>&1 || true
  rm -f "$GATEWAY_ENV" "$TAPIZ_ENV" "$LOGIN_LOG" "$SCAN_LOG" "$GENERAL_LOG" "$TRAFFIC_PIDS_FILE" \
    /tmp/gateway-scheduler-test-body.json /tmp/gateway-scheduler-test-valkey-before.txt \
    /tmp/gateway-scheduler-test-valkey-after.txt
  log "Removed disposable containers, volumes, networks, generated .env files, and traffic logs created by this run."
  exit "$status"
}
trap cleanup EXIT INT TERM

log "== 0. caddy validate (real gateway config, unmodified) =="
sh "$gateway_root/tests/validate.sh"
check "caddy validate + gateway compose config parse cleanly" $?

log ""
log "== 1. Generate a disposable, random-only .env for the real Tapiz stack =="
# Random local-only values only. Never reads or copies apps/api/ops/vps/.env —
# env.example is the only reference used for which keys exist (hard
# constraint 4).
rand() { head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n'; }
POSTGRES_PASSWORD_GEN=$(rand)
JWT_SECRET_GEN=$(rand)
JWT_REFRESH_SECRET_GEN=$(rand)
CRON_SECRET_GEN=$(rand)

cat > "$TAPIZ_ENV" <<EOF
API_DOMAIN=$TAPIZ_HOST
TAPIZ_API_IMAGE=tapiz-lms-api-scheduler-test:local
TAPIZ_EDGE_NETWORK=$TAPIZ_EDGE_NETWORK_NAME

POSTGRES_DB=tapiz_scheduler_test
POSTGRES_USER=tapiz_scheduler_test
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

API_VERSION=scheduler-test
CACHE_PREFIX=tapiz:scheduler-test
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
APP_VERSION=scheduler-test
LOG_LEVEL=info
ALLOWED_STUDENT_EMAIL_SUFFIXES=ac.rs,edu.rs
LICENSE_GRACE_DAYS=7
RESOURCE_BOOKING_ENABLED=true

BILLING_SELLER_NAME=Scheduler Test
BILLING_SELLER_LEGAL_NAME=Scheduler Test
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
check "generated disposable .env.tapiz-scheduler-test with random-only local secrets" $?

log ""
log "== 2. Create disposable external edge network =="
export TAPIZ_EDGE_NETWORK="$TAPIZ_EDGE_NETWORK_NAME"
docker network create "$TAPIZ_EDGE_NETWORK_NAME" >/dev/null
check "created disposable $TAPIZ_EDGE_NETWORK_NAME network" $?

log ""
log "== 3. Build + bring up the real Tapiz VPS stack (no standalone-ingress profile) =="
tapiz_compose build postgres valkey pgbouncer auth-api-1 auth-api-2 scan-api general-api worker scheduler
check "real Tapiz images (api lanes, worker, scheduler) built from the real Dockerfile" $?

tapiz_compose up -d --quiet-pull postgres valkey pgbouncer auth-api-1 auth-api-2 scan-api general-api worker scheduler
check "real Tapiz stack containers started" $?

log ""
log "== 4. Wait for postgres/valkey/pgbouncer to report healthy =="
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
log "== 5. Apply the Drizzle schema to the disposable Postgres (npm run db:push --force) =="
TAPIZ_LMS_ROOT_DIR="$TAPIZ_LMS_DIR" \
  tapiz_compose_with_jobs --profile schema-push run --rm schema-push
check "drizzle-kit push --force applied the schema to the disposable Postgres" $?

log ""
log "== 6. Seed a modest, real demo dataset via the product's own seed-demo.ts (npm run seed:demo) =="
# Reused as-is from the exact pattern ../backup-restore/README.md documents:
# real enrolled students, subjects, sessions, and attendance rows, so the
# attendance-flush job route triggered in step 12 has real pending-flush-
# shaped data to operate on, not an empty schema. seed-demo.ts's own
# `checkSeedTarget` guard (read, never weakened) is satisfied by DB_HOST
# `postgres-test`, a network alias added purely for this reason (see
# docker-compose.postgres-alias.yml).
TAPIZ_LMS_ROOT_DIR="$TAPIZ_LMS_DIR" \
  tapiz_compose_with_jobs --profile seed-demo run --rm seed-demo
check "npm run seed:demo populated a real demo dataset (enrolled students/sessions/attendance) in the disposable Postgres" $?

log ""
log "== 7. Wait for auth-api-1/auth-api-2/scan-api/general-api/worker/scheduler to report healthy =="
for svc in auth-api-1 auth-api-2 scan-api general-api worker; do
  if wait_healthy tapiz_compose "$svc" 60; then
    check "$svc reports healthy (real app booted, real DB connectivity through PgBouncer)" 0
  else
    check "$svc reports healthy (real app booted, real DB connectivity through PgBouncer)" 1
  fi
done

# scheduler's healthcheck is a pgrep, not an HTTP probe (see the real
# docker-compose.yml).
if wait_healthy tapiz_compose scheduler 30; then
  check "scheduler reports healthy (running, not crash-looping)" 0
else
  check "scheduler reports healthy (running, not crash-looping)" 1
fi

log ""
log "== 8. Bring up the real, unmodified vps-gateway Caddy against the real stack =="
cat > "$GATEWAY_ENV" <<EOF
CADDY_EMAIL=ops@example.invalid
TAPIZ_API_DOMAIN=$TAPIZ_HOST
AURA_API_DOMAIN=api.aura-scheduler.test
TAPIZ_EDGE_NETWORK=$TAPIZ_EDGE_NETWORK_NAME
AURA_EDGE_NETWORK=aura-edge-scheduler-test-unused
EOF
docker network create aura-edge-scheduler-test-unused >/dev/null 2>&1 || true

export GATEWAY_ENV_FILE="$GATEWAY_ENV"
gateway_compose up -d --quiet-pull
check "real gateway container started against the real Tapiz edge network" $?

# The gateway's own docker-compose.yml (real, unmodified) declares no
# healthcheck for its `caddy` service — same as every other real-stack-based
# harness observed. Reachability is proven directly by the routing
# assertions below, not by a Health field that can never populate.
gateway_caddy_state=$(gateway_compose ps --format '{{.State}}' caddy 2>/dev/null || true)
assert '[ "$gateway_caddy_state" = "running" ]' \
  "gateway caddy container is running (no healthcheck defined on this service; reachability proven by baseline traffic below)"

curl_host() {
  # $1 = Host header, $2 = path, $3 = method, $4 = optional JSON body
  set +e
  attempt=0
  code=000
  while [ "$attempt" -lt 10 ]; do
    if [ -n "${4:-}" ]; then
      code=$(curl -sk -o /tmp/gateway-scheduler-test-body.json -w "%{http_code}" \
        --max-time 8 -X "${3:-GET}" \
        -H 'Content-Type: application/json' -d "$4" \
        --resolve "$1:$GATEWAY_TLS_PORT:127.0.0.1" \
        "https://$1:$GATEWAY_TLS_PORT$2" 2>/dev/null)
    else
      code=$(curl -sk -o /tmp/gateway-scheduler-test-body.json -w "%{http_code}" \
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
log "== 9. Baseline: login + scan + general traffic through the real gateway, before any scheduler trigger =="
code=$(curl_host "$TAPIZ_HOST" "/api/auth/login" "POST" '{"email":"nobody@example.invalid","password":"wrong-password-123"}')
assert '[ "$code" = "401" ] || [ "$code" = "400" ]' \
  "baseline POST /api/auth/login with bogus credentials -> real 4xx from auth lane (got HTTP $code)"

code=$(curl_host "$TAPIZ_HOST" "/api/attendance/scan" "POST" '{"token":"bogus-qr-token"}')
assert '[ "$code" -ge 400 ] && [ "$code" -lt 500 ]' \
  "baseline POST /api/attendance/scan with bogus QR payload -> real 4xx from scan lane (got HTTP $code)"

code=$(curl_host "$TAPIZ_HOST" "/api/subjects" "GET")
assert '[ "$code" = "401" ]' \
  "baseline GET /api/subjects unauthenticated -> real 401 from general lane (got HTTP $code)"

log ""
log "== 10. Measure PgBouncer / Postgres connection state, and Valkey INFO, BEFORE the traffic+scheduler window =="
TAPIZ_PG_USER=$(grep '^POSTGRES_USER=' "$TAPIZ_ENV" | cut -d= -f2)
TAPIZ_PG_PASSWORD=$(grep '^POSTGRES_PASSWORD=' "$TAPIZ_ENV" | cut -d= -f2)
TAPIZ_PG_DB=$(grep '^POSTGRES_DB=' "$TAPIZ_ENV" | cut -d= -f2)

psql_source() {
  tapiz_compose exec -T postgres psql -U "$TAPIZ_PG_USER" -d "$TAPIZ_PG_DB" -Atq -c "$1"
}

# Mechanism choice: pg_stat_activity on the source Postgres directly, NOT
# PgBouncer's own admin console (`SHOW POOLS;`/`SHOW STATS;`). See
# ../real-stack/README.md's bug #5: the app DB user is not in PgBouncer's
# admin_users/stats_users (the real, unmodified docker-compose.yml does not
# set them), confirmed there by direct reproduction ("FATAL: not allowed").
# pg_stat_activity requires no PgBouncer admin access at all and shows real
# connection/waiting state directly — a stronger, simpler measurement for
# this phase's purpose than trying to reach an admin console this stack was
# never configured to expose.
conn_state_before=$(psql_source "SELECT state, count(*) FROM pg_stat_activity WHERE datname = '$TAPIZ_PG_DB' GROUP BY state ORDER BY state")
log "  pg_stat_activity by state (before):"
log "$conn_state_before" | sed 's/^/    /'

pgbouncer_pg_isready_before=$(tapiz_compose exec -T -e PGPASSWORD="$TAPIZ_PG_PASSWORD" pgbouncer \
  pg_isready -h 127.0.0.1 -p 5432 -U "$TAPIZ_PG_USER" 2>&1 || true)
assert 'printf "%s" "$pgbouncer_pg_isready_before" | grep -q "accepting connections"' \
  "PgBouncer accepts connections on its pooled listener BEFORE the window (pool alive)"

valkey_info_before=$(tapiz_compose exec -T valkey valkey-cli INFO 2>/dev/null | tr -d '\r')
printf '%s\n' "$valkey_info_before" > /tmp/gateway-scheduler-test-valkey-before.txt
valkey_clients_before=$(printf '%s\n' "$valkey_info_before" | grep '^connected_clients:' | cut -d: -f2)
valkey_memory_before=$(printf '%s\n' "$valkey_info_before" | grep '^used_memory_human:' | cut -d: -f2)
valkey_oom_before=$(printf '%s\n' "$valkey_info_before" | grep -ci 'oom' || true)
log "  Valkey (before): connected_clients=$valkey_clients_before used_memory_human=$valkey_memory_before oom_mentions=${valkey_oom_before:-0}"

log ""
log "== 11. Capture pre-window container identities for worker + scheduler =="
WORKER_CID_BEFORE=$(tapiz_compose ps -q worker)
SCHEDULER_CID_BEFORE=$(tapiz_compose ps -q scheduler)
WORKER_STARTED_BEFORE=$(docker inspect --format '{{.State.StartedAt}}' "$WORKER_CID_BEFORE")
SCHEDULER_STARTED_BEFORE=$(docker inspect --format '{{.State.StartedAt}}' "$SCHEDULER_CID_BEFORE")
log "  worker: $WORKER_CID_BEFORE (started $WORKER_STARTED_BEFORE)"
log "  scheduler: $SCHEDULER_CID_BEFORE (started $SCHEDULER_STARTED_BEFORE)"

worker_health_before=$(tapiz_compose ps --format '{{.Health}}' worker 2>/dev/null || true)
scheduler_health_before=$(tapiz_compose ps --format '{{.Health}}' scheduler 2>/dev/null || true)
assert '[ "$worker_health_before" = "healthy" ]' "worker healthy before the window (background flush timers running, DISABLE_BACKGROUND_WORKERS unset)"
assert '[ "$scheduler_health_before" = "healthy" ]' "scheduler healthy before the window (process running, not crash-looping)"

log ""
log "== 12. Start continuous background traffic (login + scan + general) for a sustained window =="
: > "$LOGIN_LOG"
: > "$SCAN_LOG"
: > "$GENERAL_LOG"
: > "$TRAFFIC_PIDS_FILE"

login_traffic_loop() {
  while true; do
    ts=$(date '+%Y-%m-%dT%H:%M:%S')
    code=$(curl -sk -o /dev/null -w "%{http_code}" --max-time 5 -X POST \
      -H 'Content-Type: application/json' \
      -d '{"email":"nobody@example.invalid","password":"wrong-password-123"}' \
      --resolve "$TAPIZ_HOST:$GATEWAY_TLS_PORT:127.0.0.1" \
      "https://$TAPIZ_HOST:$GATEWAY_TLS_PORT/api/auth/login" 2>/dev/null || printf '000')
    printf '%s %s\n' "$ts" "$code" >> "$LOGIN_LOG"
    sleep 0.3
  done
}

scan_traffic_loop() {
  while true; do
    ts=$(date '+%Y-%m-%dT%H:%M:%S')
    code=$(curl -sk -o /dev/null -w "%{http_code}" --max-time 5 -X POST \
      -H 'Content-Type: application/json' \
      -d '{"token":"bogus-qr-token"}' \
      --resolve "$TAPIZ_HOST:$GATEWAY_TLS_PORT:127.0.0.1" \
      "https://$TAPIZ_HOST:$GATEWAY_TLS_PORT/api/attendance/scan" 2>/dev/null || printf '000')
    printf '%s %s\n' "$ts" "$code" >> "$SCAN_LOG"
    sleep 0.3
  done
}

general_traffic_loop() {
  while true; do
    ts=$(date '+%Y-%m-%dT%H:%M:%S')
    code=$(curl -sk -o /dev/null -w "%{http_code}" --max-time 5 -X GET \
      --resolve "$TAPIZ_HOST:$GATEWAY_TLS_PORT:127.0.0.1" \
      "https://$TAPIZ_HOST:$GATEWAY_TLS_PORT/api/subjects" 2>/dev/null || printf '000')
    printf '%s %s\n' "$ts" "$code" >> "$GENERAL_LOG"
    sleep 0.3
  done
}

login_traffic_loop &
LOGIN_LOOP_PID=$!
scan_traffic_loop &
SCAN_LOOP_PID=$!
general_traffic_loop &
GENERAL_LOOP_PID=$!
printf '%s\n%s\n%s\n' "$LOGIN_LOOP_PID" "$SCAN_LOOP_PID" "$GENERAL_LOOP_PID" > "$TRAFFIC_PIDS_FILE"
check "background login + scan + general traffic loops started (pids $LOGIN_LOOP_PID / $SCAN_LOOP_PID / $GENERAL_LOOP_PID)" $?

# Let the loops run for a few seconds before triggering the scheduler's job
# route, so the window has real pre-trigger traffic, not just an instant
# snapshot around the trigger itself.
sleep 5

log ""
log "== 13. Trigger the scheduler's own job route directly (safe test trigger), while traffic + worker run concurrently =="
# Mechanism chosen: a direct, authenticated HTTP call to the SAME route the
# real scheduler.mjs would call, with the SAME auth scheme
# (Authorization: Bearer $CRON_SECRET) and the SAME target
# (http://general-api:3001 — see the real docker-compose.yml's `scheduler`
# service: API_BASE_URL=http://general-api:3001), fired from a throwaway
# curlimages/curl container attached to this project's own `private` network
# — never through the scheduler container itself, and never by trying to
# manipulate scheduler.mjs's internal minute-tick/cron-match timing (jobs.json's
# cadences are hourly/daily/weekly; waiting for a real match is not feasible
# in a test harness). This exercises exactly the mechanism the parent task
# asked for: "directly invoke the same authenticated HTTP route(s) the
# scheduler would call ... rather than trying to manipulate the scheduler's
# internal interval timing."
#
# Job chosen: attendance-flush (POST /api/attendance/flush, see jobs.json —
# verified present in the real, current jobs.json read at the start of this
# work; not assumed from any older list). This is also the one job whose
# real effect the seeded dataset (real students/sessions/attendance rows,
# step 6) gives a realistic, non-empty target to operate on. retention
# (drainLoop) and the billing/reports/license jobs are deliberately NOT
# triggered here — they are destructive/purge-shaped
# (retention) or address external services this harness has none of
# (mail/billing), and are out of scope for a scheduler-coexistence proof.
CRON_SECRET_VALUE=$(grep '^CRON_SECRET=' "$TAPIZ_ENV" | cut -d= -f2)

trigger_job() {
  docker run --rm --network "${TAPIZ_PROJECT}_private" \
    curlimages/curl:8.11.1 \
    -sk -o /tmp/job-body.json -w '%{http_code}' --max-time 15 -X POST \
    -H "Authorization: Bearer $CRON_SECRET_VALUE" \
    "http://general-api:3001/api/attendance/flush" 2>/dev/null || printf '000'
}

job_code_1=$(trigger_job)
log "  trigger #1: POST /api/attendance/flush (Bearer CRON_SECRET) -> HTTP $job_code_1"
assert '[ "$job_code_1" -ge 200 ] && [ "$job_code_1" -lt 300 ]' \
  "scheduler job route trigger #1 (attendance-flush) returned a real 2xx success (got HTTP $job_code_1)"

sleep 8

job_code_2=$(trigger_job)
log "  trigger #2: POST /api/attendance/flush (Bearer CRON_SECRET) -> HTTP $job_code_2"
assert '[ "$job_code_2" -ge 200 ] && [ "$job_code_2" -lt 300 ]' \
  "scheduler job route trigger #2 (attendance-flush) returned a real 2xx success, while traffic still running (got HTTP $job_code_2)"

log ""
log "== 14. Confirm the actual scheduler CONTAINER process stays healthy throughout (not just that the job route works) =="
scheduler_health_during=$(tapiz_compose ps --format '{{.Health}}' scheduler 2>/dev/null || true)
assert '[ "$scheduler_health_during" = "healthy" ]' \
  "scheduler container still healthy during the window (pgrep-based healthcheck, running, not crash-looping)"

log ""
log "== 15. Let the traffic window run out its full duration, then stop it =="
elapsed_so_far=13
remaining=$((TRAFFIC_WINDOW_SECONDS - elapsed_so_far))
if [ "$remaining" -gt 0 ]; then
  sleep "$remaining"
fi

stop_traffic

log ""
log "== 16. Measure PgBouncer / Postgres connection state, and Valkey INFO, AFTER the window =="
conn_state_after=$(psql_source "SELECT state, count(*) FROM pg_stat_activity WHERE datname = '$TAPIZ_PG_DB' GROUP BY state ORDER BY state")
log "  pg_stat_activity by state (after):"
log "$conn_state_after" | sed 's/^/    /'

# The real, unmodified docker-compose.yml's own pgbouncer healthcheck already
# treats `pg_isready` as the fallback proof of pool health, since the app DB
# user cannot reach PgBouncer's own admin console (see step 10's comment and
# ../real-stack/README.md bug #5) — reused as the same after-window measurement.
pgbouncer_pg_isready_after=$(tapiz_compose exec -T -e PGPASSWORD="$TAPIZ_PG_PASSWORD" pgbouncer \
  pg_isready -h 127.0.0.1 -p 5432 -U "$TAPIZ_PG_USER" 2>&1 || true)
assert 'printf "%s" "$pgbouncer_pg_isready_after" | grep -q "accepting connections"' \
  "PgBouncer accepts connections on its pooled listener AFTER the window (pool still alive, no waiter pileup crash)"

waiting_count_after=$(printf '%s\n' "$conn_state_after" | grep -c '^active|.*waiting' || true)
log "  active/waiting rows in pg_stat_activity (after): ${waiting_count_after:-0}"

valkey_info_after=$(tapiz_compose exec -T valkey valkey-cli INFO 2>/dev/null | tr -d '\r')
printf '%s\n' "$valkey_info_after" > /tmp/gateway-scheduler-test-valkey-after.txt
valkey_clients_after=$(printf '%s\n' "$valkey_info_after" | grep '^connected_clients:' | cut -d: -f2)
valkey_memory_after=$(printf '%s\n' "$valkey_info_after" | grep '^used_memory_human:' | cut -d: -f2)
valkey_evicted_after=$(printf '%s\n' "$valkey_info_after" | grep '^evicted_keys:' | cut -d: -f2)
valkey_oom_after=$(printf '%s\n' "$valkey_info_after" | grep -ci 'oom' || true)
log "  Valkey (after): connected_clients=$valkey_clients_after used_memory_human=$valkey_memory_after evicted_keys=$valkey_evicted_after oom_mentions=${valkey_oom_after:-0}"

assert '[ "$(printf "%s" "$valkey_evicted_after" | tr -d " ")" = "0" ]' \
  "Valkey evicted_keys is 0 after the window (noeviction policy honored, no data loss under load — got evicted_keys=$valkey_evicted_after)"

log ""
log "== 17. Confirm worker + scheduler containers were NOT restarted, and both remain healthy =="
WORKER_CID_AFTER=$(tapiz_compose ps -q worker)
SCHEDULER_CID_AFTER=$(tapiz_compose ps -q scheduler)
WORKER_STARTED_AFTER=$(docker inspect --format '{{.State.StartedAt}}' "$WORKER_CID_AFTER")
SCHEDULER_STARTED_AFTER=$(docker inspect --format '{{.State.StartedAt}}' "$SCHEDULER_CID_AFTER")
log "  worker before: $WORKER_CID_BEFORE ($WORKER_STARTED_BEFORE)  after: $WORKER_CID_AFTER ($WORKER_STARTED_AFTER)"
log "  scheduler before: $SCHEDULER_CID_BEFORE ($SCHEDULER_STARTED_BEFORE)  after: $SCHEDULER_CID_AFTER ($SCHEDULER_STARTED_AFTER)"

assert '[ "$WORKER_CID_BEFORE" = "$WORKER_CID_AFTER" ] && [ "$WORKER_STARTED_BEFORE" = "$WORKER_STARTED_AFTER" ]' \
  "worker container unchanged/not restarted across the window"
assert '[ "$SCHEDULER_CID_BEFORE" = "$SCHEDULER_CID_AFTER" ] && [ "$SCHEDULER_STARTED_BEFORE" = "$SCHEDULER_STARTED_AFTER" ]' \
  "scheduler container unchanged/not restarted across the window"

worker_health_after=$(tapiz_compose ps --format '{{.Health}}' worker 2>/dev/null || true)
scheduler_health_after=$(tapiz_compose ps --format '{{.Health}}' scheduler 2>/dev/null || true)
assert '[ "$worker_health_after" = "healthy" ]' "worker still healthy after the window"
assert '[ "$scheduler_health_after" = "healthy" ]' "scheduler still healthy after the window"

for svc in auth-api-1 auth-api-2 scan-api general-api; do
  h=$(tapiz_compose ps --format '{{.Health}}' "$svc" 2>/dev/null || true)
  assert '[ "$h" = "healthy" ]' "$svc still healthy after the window (no lane starvation)"
done

log ""
log "== 18. Assert no starvation of the scan/auth lanes: every logged request during the window was a real 4xx =="
login_total=$(wc -l < "$LOGIN_LOG" | tr -d ' ')
scan_total=$(wc -l < "$SCAN_LOG" | tr -d ' ')
general_total=$(wc -l < "$GENERAL_LOG" | tr -d ' ')
login_bad=$(grep -Ev ' (400|401)$' "$LOGIN_LOG" | wc -l | tr -d ' ')
scan_bad=$(grep -Ev ' 4[0-9][0-9]$' "$SCAN_LOG" | wc -l | tr -d ' ')
general_bad=$(grep -Ev ' 401$' "$GENERAL_LOG" | wc -l | tr -d ' ')

log "  login requests logged:   $login_total (bad/unexpected: $login_bad)"
log "  scan requests logged:    $scan_total (bad/unexpected: $scan_bad)"
log "  general requests logged: $general_total (bad/unexpected: $general_bad)"
if [ "$login_bad" != "0" ]; then
  log "  --- unexpected login log lines ---"
  grep -Ev ' (400|401)$' "$LOGIN_LOG" | sed 's/^/    /'
fi
if [ "$scan_bad" != "0" ]; then
  log "  --- unexpected scan log lines ---"
  grep -Ev ' 4[0-9][0-9]$' "$SCAN_LOG" | sed 's/^/    /'
fi
if [ "$general_bad" != "0" ]; then
  log "  --- unexpected general log lines ---"
  grep -Ev ' 401$' "$GENERAL_LOG" | sed 's/^/    /'
fi

assert '[ "$login_total" -gt 0 ]' "background login traffic actually logged requests ($login_total total)"
assert '[ "$scan_total" -gt 0 ]' "background scan traffic actually logged requests ($scan_total total)"
assert '[ "$general_total" -gt 0 ]' "background general traffic actually logged requests ($general_total total)"
assert '[ "$login_bad" = "0" ]' \
  "every logged login response during the window was a real 400/401 (zero 502/503/timeout/000 -> no auth-lane starvation)"
assert '[ "$scan_bad" = "0" ]' \
  "every logged scan response during the window was a real 4xx (zero 502/503/timeout/000 -> no scan-lane starvation)"
assert '[ "$general_bad" = "0" ]' \
  "every logged general response during the window was a real 401 (zero 502/503/timeout/000)"

log ""
log "== 19. No host ports on any real Tapiz application/data container =="
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
log ""
log "Measured values:"
log "  pg_stat_activity by state, before:"
log "$conn_state_before" | sed 's/^/    /'
log "  pg_stat_activity by state, after:"
log "$conn_state_after" | sed 's/^/    /'
log "  Valkey connected_clients: before=$valkey_clients_before after=$valkey_clients_after"
log "  Valkey used_memory_human: before=$valkey_memory_before after=$valkey_memory_after"
log "  Valkey evicted_keys after: $valkey_evicted_after"
log "  Scheduler job trigger #1 (attendance-flush): HTTP $job_code_1"
log "  Scheduler job trigger #2 (attendance-flush): HTTP $job_code_2"
log "  Login requests during window: $login_total (unexpected: $login_bad)"
log "  Scan requests during window: $scan_total (unexpected: $scan_bad)"
log "  General requests during window: $general_total (unexpected: $general_bad)"
if [ "$fail_count" != "0" ]; then
  log "$failures"
  exit 1
fi
log "All checks passed."
