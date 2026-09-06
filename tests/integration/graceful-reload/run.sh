#!/usr/bin/env sh
# Phase 2 graceful-reload integration harness for the shared vps-gateway Caddy.
#
# Proves, against THIS repository's real, unmodified sites/*.caddy and
# snippets/*.caddy content (imported verbatim, never edited), that a live
# gateway serving real traffic can:
#   1. reject an invalid Caddyfile change before it ever reaches the running
#      process (validated in a separate, throwaway container — never against
#      the live gateway container);
#   2. keep serving the currently-active config unchanged when a bad config is
#      never given the chance to load;
#   3. accept a real, valid config change via `caddy reload` (same process,
#      not a container restart) with zero dropped/failed requests for a
#      continuous background stream of real login + real scan traffic against
#      the real Tapiz LMS VPS stack (real Postgres/Valkey/PgBouncer/4 lanes/
#      worker/scheduler) for the whole reload window;
#   4. leave every upstream API lane's own container untouched (same
#      container ID, not restarted) by a gateway-only reload.
#
# This is a SEPARATE, later harness than ../run.sh (fake-stub) and
# ../real-stack/run.sh (Phase 1, real stack but no reload) — it duplicates
# real-stack/run.sh's real-stack bring-up steps (build/up/schema-push/wait)
# rather than sourcing a shared helper, so this file's addition can never
# regress the already-verified-passing ../real-stack/run.sh (see this
# harness's own README section "Duplicated vs. shared setup" for why).
#
# Never touches a real VPS, DNS, GitHub, external database, or any real
# secret. Generates its own disposable, random-value .env for the Tapiz
# stack. Never reads apps/api/ops/vps/.env or this repo's real sites/*.caddy
# in place — a throwaway COPY of sites/tapiz.caddy is used for the mid-run
# edits (both the deliberately-broken one and the harmless valid one).
#
# Everything this script creates (networks, containers, volumes, the
# generated .env files, the scratch sites-live/ directory, background traffic
# loops, log files) is removed by the `cleanup` trap, on both success and
# failure.
set -eu

gateway_root=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
here="$gateway_root/tests/integration/graceful-reload"

# Locate the tapiz-lms checkout, same override pattern as
# ../real-stack/run.sh (per CLAUDE.md: ~/Desktop/tapiz/tapiz-lms).
TAPIZ_LMS_DIR="${TAPIZ_LMS_DIR:-$HOME/Desktop/tapiz/tapiz-lms}"
TAPIZ_VPS_DIR="$TAPIZ_LMS_DIR/apps/api/ops/vps"
TAPIZ_COMPOSE="$TAPIZ_VPS_DIR/docker-compose.yml"

if [ ! -f "$TAPIZ_COMPOSE" ]; then
  printf 'FATAL: real Tapiz VPS compose file not found at %s\n' "$TAPIZ_COMPOSE" >&2
  printf 'Set TAPIZ_LMS_DIR to override the default checkout path.\n' >&2
  exit 1
fi

GATEWAY_COMPOSE="$gateway_root/docker-compose.yml"
GATEWAY_ENV="$here/.env.gateway-reload-test"
TAPIZ_ENV="$here/.env.tapiz-reload-test"

TAPIZ_HOST="api.tapiz-reload.test"
GATEWAY_TLS_PORT="38443"

# Distinct from both other harnesses' edge network names (tapiz-edge-test,
# tapiz-edge-real-test) and the real tapiz-edge.
TAPIZ_EDGE_NETWORK_NAME="tapiz-edge-reload-test"

TAPIZ_PROJECT="tapiz-lms-reload-test"
GATEWAY_PROJECT="platform-gateway-reload-test"

SITES_LIVE_DIR="$here/sites-live"
LOGIN_LOG="$here/.login-traffic.log"
SCAN_LOG="$here/.scan-traffic.log"
TRAFFIC_PIDS_FILE="$here/.traffic-pids"

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
    -f "$GATEWAY_COMPOSE" -f "$here/docker-compose.gateway-reload-test-ports.yml" "$@"
}

stop_traffic() {
  if [ -f "$TRAFFIC_PIDS_FILE" ]; then
    while read -r pid; do
      [ -n "$pid" ] && kill "$pid" >/dev/null 2>&1 || true
    done < "$TRAFFIC_PIDS_FILE"
    # Give the loops a moment to exit their current curl before we move on.
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
  tapiz_compose_with_schema_push --profile schema-push down -v --remove-orphans >/dev/null 2>&1 || true
  docker network rm "$TAPIZ_EDGE_NETWORK_NAME" >/dev/null 2>&1 || true
  docker network rm aura-edge-reload-test-unused >/dev/null 2>&1 || true
  rm -f "$GATEWAY_ENV" "$TAPIZ_ENV" "$LOGIN_LOG" "$SCAN_LOG" "$TRAFFIC_PIDS_FILE" \
    /tmp/gateway-reload-test-body.json /tmp/gateway-reload-test-baseline.json
  rm -rf "$SITES_LIVE_DIR"
  log "Removed disposable containers, volumes, networks, generated .env files, scratch sites dir, and traffic logs created by this run."
  exit "$status"
}
trap cleanup EXIT INT TERM

log "== 0. caddy validate (real gateway config, unmodified) =="
sh "$gateway_root/tests/validate.sh"
check "caddy validate + gateway compose config parse cleanly" $?

log ""
log "== 1. Generate a disposable, random-only .env for the real Tapiz stack =="
rand() { head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n'; }
POSTGRES_PASSWORD_GEN=$(rand)
JWT_SECRET_GEN=$(rand)
JWT_REFRESH_SECRET_GEN=$(rand)
CRON_SECRET_GEN=$(rand)

cat > "$TAPIZ_ENV" <<EOF
API_DOMAIN=$TAPIZ_HOST
TAPIZ_API_IMAGE=tapiz-lms-api-reload-test:local
TAPIZ_EDGE_NETWORK=$TAPIZ_EDGE_NETWORK_NAME

POSTGRES_DB=tapiz_reload_test
POSTGRES_USER=tapiz_reload_test
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

API_VERSION=reload-test
CACHE_PREFIX=tapiz:reload-test
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
APP_VERSION=reload-test
LOG_LEVEL=info
ALLOWED_STUDENT_EMAIL_SUFFIXES=ac.rs,edu.rs
LICENSE_GRACE_DAYS=7
RESOURCE_BOOKING_ENABLED=true

BILLING_SELLER_NAME=Reload Test
BILLING_SELLER_LEGAL_NAME=Reload Test
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
check "generated disposable .env.tapiz-reload-test with random-only local secrets" $?

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

if wait_healthy tapiz_compose scheduler 30; then
  check "scheduler reports healthy (running, not crash-looping)" 0
else
  check "scheduler reports healthy (running, not crash-looping)" 1
fi

log ""
log "== 7. Prepare the scratch sites-live/ directory (COPY of real sites/tapiz.caddy + aura.caddy, never the real files themselves) =="
# The live gateway container mounts THIS directory as /etc/caddy/sites (see
# docker-compose.gateway-reload-test-ports.yml), not the repo's real sites/.
# Content starts as a byte-for-byte copy of the real files so the routing
# behavior under test is identical to production; later steps in this script
# overwrite only this scratch copy (first with a deliberately broken variant
# for validation-rejection, then with a harmless valid variant for the real
# reload) — the real repo files under ../../../sites/ are never opened for
# writing at any point in this script.
mkdir -p "$SITES_LIVE_DIR"
cp "$gateway_root/sites/tapiz.caddy" "$SITES_LIVE_DIR/tapiz.caddy"
cp "$gateway_root/sites/aura.caddy" "$SITES_LIVE_DIR/aura.caddy"
check "scratch sites-live/ seeded from the real, unmodified sites/*.caddy" $?

log ""
log "== 8. Bring up the real, unmodified vps-gateway Caddy (serving from the sites-live/ copy) against the real stack =="
cat > "$GATEWAY_ENV" <<EOF
CADDY_EMAIL=ops@example.invalid
TAPIZ_API_DOMAIN=$TAPIZ_HOST
AURA_API_DOMAIN=api.aura-reload.test
TAPIZ_EDGE_NETWORK=$TAPIZ_EDGE_NETWORK_NAME
AURA_EDGE_NETWORK=aura-edge-reload-test-unused
EOF
docker network create aura-edge-reload-test-unused >/dev/null 2>&1 || true

export GATEWAY_ENV_FILE="$GATEWAY_ENV"
gateway_compose up -d --quiet-pull
check "real gateway container started against the real Tapiz edge network" $?

gateway_caddy_state=$(gateway_compose ps --format '{{.State}}' caddy 2>/dev/null || true)
assert '[ "$gateway_caddy_state" = "running" ]' \
  "gateway caddy container is running (no healthcheck defined on this service; reachability proven by step 9's baseline traffic)"

GATEWAY_CID_BEFORE=$(gateway_compose ps -q caddy)
GATEWAY_STARTED_AT_BEFORE=$(docker inspect --format '{{.State.StartedAt}}' "$GATEWAY_CID_BEFORE")

curl_host() {
  # $1 = Host header, $2 = path, $3 = method, $4 = optional JSON body, $5 = output file
  set +e
  attempt=0
  code=000
  out="${5:-/tmp/gateway-reload-test-body.json}"
  while [ "$attempt" -lt 10 ]; do
    if [ -n "${4:-}" ]; then
      code=$(curl -sk -o "$out" -w "%{http_code}" \
        --max-time 8 -X "${3:-GET}" \
        -H 'Content-Type: application/json' -d "$4" \
        --resolve "$1:$GATEWAY_TLS_PORT:127.0.0.1" \
        "https://$1:$GATEWAY_TLS_PORT$2" 2>/dev/null)
    else
      code=$(curl -sk -o "$out" -w "%{http_code}" \
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
log "== 9. Baseline: one real login + one real scan through the gateway, before any reload activity =="
code=$(curl_host "$TAPIZ_HOST" "/api/auth/login" "POST" '{"email":"nobody@example.invalid","password":"wrong-password-123"}')
assert '[ "$code" = "401" ] || [ "$code" = "400" ]' \
  "baseline POST /api/auth/login with bogus credentials -> real 4xx from auth lane (got HTTP $code)"

code=$(curl_host "$TAPIZ_HOST" "/api/attendance/scan" "POST" '{"token":"bogus-qr-token"}')
assert '[ "$code" -ge 400 ] && [ "$code" -lt 500 ]' \
  "baseline POST /api/attendance/scan with bogus QR payload -> real 4xx from scan lane (got HTTP $code)"

log ""
log "== 10. Capture pre-reload container identities (gateway + all 4 API lanes) =="
AUTH1_CID_BEFORE=$(tapiz_compose ps -q auth-api-1)
AUTH2_CID_BEFORE=$(tapiz_compose ps -q auth-api-2)
SCAN_CID_BEFORE=$(tapiz_compose ps -q scan-api)
GENERAL_CID_BEFORE=$(tapiz_compose ps -q general-api)
AUTH1_STARTED_BEFORE=$(docker inspect --format '{{.State.StartedAt}}' "$AUTH1_CID_BEFORE")
AUTH2_STARTED_BEFORE=$(docker inspect --format '{{.State.StartedAt}}' "$AUTH2_CID_BEFORE")
SCAN_STARTED_BEFORE=$(docker inspect --format '{{.State.StartedAt}}' "$SCAN_CID_BEFORE")
GENERAL_STARTED_BEFORE=$(docker inspect --format '{{.State.StartedAt}}' "$GENERAL_CID_BEFORE")
log "  gateway caddy container: $GATEWAY_CID_BEFORE (started $GATEWAY_STARTED_AT_BEFORE)"
log "  auth-api-1: $AUTH1_CID_BEFORE (started $AUTH1_STARTED_BEFORE)"
log "  auth-api-2: $AUTH2_CID_BEFORE (started $AUTH2_STARTED_BEFORE)"
log "  scan-api:   $SCAN_CID_BEFORE (started $SCAN_STARTED_BEFORE)"
log "  general-api: $GENERAL_CID_BEFORE (started $GENERAL_STARTED_BEFORE)"

log ""
log "== 11. Start continuous background traffic (login + scan) for the duration of the reload test =="
: > "$LOGIN_LOG"
: > "$SCAN_LOG"
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

login_traffic_loop &
LOGIN_LOOP_PID=$!
scan_traffic_loop &
SCAN_LOOP_PID=$!
printf '%s\n%s\n' "$LOGIN_LOOP_PID" "$SCAN_LOOP_PID" > "$TRAFFIC_PIDS_FILE"
check "background login + scan traffic loops started (pids $LOGIN_LOOP_PID / $SCAN_LOOP_PID)" $?
# Let the loops run for several seconds before we start touching config, so
# the log files have a meaningful pre-reload baseline sample, not just one or
# two lines. This also gives the continuity proof in step 17 a wider window
# to actually exercise (steps 12-16 alone are sub-second on a warm stack).
sleep 5

log ""
log "== 12. Deliberately broken config: confirm it is REJECTED before it ever reaches the live gateway =="
# Copy the real (already-live) sites-live/tapiz.caddy and introduce a clearly
# labeled, deliberate syntax error (unclosed brace) — this file is a THROWAWAY
# scratch copy, never sites-live/ itself and never the real repo's
# sites/tapiz.caddy. Validated in a SEPARATE, temporary `caddy validate`
# container invocation (mirroring tests/validate.sh's own pattern of a
# throwaway container with no live stack), never against the running gateway
# container — so an invalid config is never given a chance to reload the live
# process.
BROKEN_SCRATCH_DIR=$(mktemp -d)
cp -r "$SITES_LIVE_DIR" "$BROKEN_SCRATCH_DIR/sites"
cat >> "$BROKEN_SCRATCH_DIR/sites/tapiz.caddy" <<'EOF'

# DELIBERATE SYNTAX ERROR for graceful-reload harness step 12 (unclosed brace).
handle_this_is_broken {
EOF

set +e
broken_validate_output=$(docker run --rm \
  -e CADDY_EMAIL=ops@example.invalid \
  -e TAPIZ_API_DOMAIN="$TAPIZ_HOST" \
  -e AURA_API_DOMAIN=api.aura-reload.test \
  -v "$here/Caddyfile.reload-test:/etc/caddy/Caddyfile:ro" \
  -v "$BROKEN_SCRATCH_DIR/sites:/etc/caddy/sites:ro" \
  -v "$gateway_root/snippets:/etc/caddy/snippets:ro" \
  caddy:2.10-alpine \
  caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile 2>&1)
broken_validate_exit=$?
set -e
rm -rf "$BROKEN_SCRATCH_DIR"

log "  caddy validate output (expected to fail):"
log "$broken_validate_output" | sed 's/^/    /'
assert '[ "$broken_validate_exit" -ne 0 ]' \
  "deliberately broken config is REJECTED by caddy validate (exit $broken_validate_exit, non-zero as expected)"

log ""
log "== 13. Confirm the live gateway's active config is untouched and still serving correctly =="
# sites-live/ on disk was never modified by step 12 (only a throwaway
# mktemp copy was touched) — this assertion proves that in practice, not just
# in theory, by firing one more login+scan request directly through the
# still-running gateway container.
code=$(curl_host "$TAPIZ_HOST" "/api/auth/login" "POST" '{"email":"nobody@example.invalid","password":"wrong-password-123"}' /tmp/gateway-reload-test-baseline.json)
assert '[ "$code" = "401" ] || [ "$code" = "400" ]' \
  "post-rejected-validation: live gateway still serves real 4xx for login, unaffected (got HTTP $code)"

code=$(curl_host "$TAPIZ_HOST" "/api/attendance/scan" "POST" '{"token":"bogus-qr-token"}' /tmp/gateway-reload-test-baseline.json)
assert '[ "$code" -ge 400 ] && [ "$code" -lt 500 ]' \
  "post-rejected-validation: live gateway still serves real 4xx for scan, unaffected (got HTTP $code)"

log ""
log "== 14. Apply a real, valid, harmless config change and perform a graceful reload of the LIVE gateway =="
# The smallest safe, inert change: add one harmless extra response header via
# the existing gateway_common snippet PATTERN, applied to the sites-live/
# copy's own site block directly (never editing snippets/common.caddy itself,
# which stays the real, unmodified repo file) so routing/lane behavior is
# provably unchanged — only an additional response header is observable.
cp "$gateway_root/sites/tapiz.caddy" "$SITES_LIVE_DIR/tapiz.caddy.new"
awk '
  /^\{\$TAPIZ_API_DOMAIN/ && !done {
    print
    print "\timport gateway_common"
    print "\theader X-Gateway-Reload-Test \"phase2-harmless\""
    getline skip_line   # consume the original "import gateway_common" line
    done = 1
    next
  }
  { print }
' "$SITES_LIVE_DIR/tapiz.caddy.new" > "$SITES_LIVE_DIR/tapiz.caddy.tmp"
mv "$SITES_LIVE_DIR/tapiz.caddy.tmp" "$SITES_LIVE_DIR/tapiz.caddy"
rm -f "$SITES_LIVE_DIR/tapiz.caddy.new"

log "  --- resulting sites-live/tapiz.caddy (harmless, valid change) ---"
sed 's/^/    /' "$SITES_LIVE_DIR/tapiz.caddy"
log "  --- end ---"

# Validate the harmless change too, same throwaway-container pattern, before
# ever asking the live process to reload it.
set +e
valid_validate_output=$(docker run --rm \
  -e CADDY_EMAIL=ops@example.invalid \
  -e TAPIZ_API_DOMAIN="$TAPIZ_HOST" \
  -e AURA_API_DOMAIN=api.aura-reload.test \
  -v "$here/Caddyfile.reload-test:/etc/caddy/Caddyfile:ro" \
  -v "$SITES_LIVE_DIR:/etc/caddy/sites:ro" \
  -v "$gateway_root/snippets:/etc/caddy/snippets:ro" \
  caddy:2.10-alpine \
  caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile 2>&1)
valid_validate_exit=$?
set -e
assert '[ "$valid_validate_exit" -eq 0 ]' \
  "harmless valid config change passes caddy validate before reload (exit $valid_validate_exit)"

# sites-live/ is bind-mounted read-only into the running gateway container at
# /etc/caddy/sites (see docker-compose.gateway-reload-test-ports.yml); editing
# the host-side file is enough for the running container to see the new
# content on its next read (Caddy re-reads config files fresh on `reload`, it
# does not cache them from container start). No live-container filesystem
# write is needed.
reload_output=$(gateway_compose exec -T caddy caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile 2>&1)
reload_exit=$?
log "  caddy reload output:"
log "$reload_output" | sed 's/^/    /'
assert '[ "$reload_exit" -eq 0 ]' \
  "caddy reload (real, valid config change) succeeded (exit $reload_exit)"

log ""
log "== 15. Confirm the gateway's own container process was NOT restarted by the reload =="
GATEWAY_CID_AFTER=$(gateway_compose ps -q caddy)
GATEWAY_STARTED_AT_AFTER=$(docker inspect --format '{{.State.StartedAt}}' "$GATEWAY_CID_AFTER")
log "  gateway caddy container before: $GATEWAY_CID_BEFORE (started $GATEWAY_STARTED_AT_BEFORE)"
log "  gateway caddy container after:  $GATEWAY_CID_AFTER (started $GATEWAY_STARTED_AT_AFTER)"
assert '[ "$GATEWAY_CID_BEFORE" = "$GATEWAY_CID_AFTER" ]' \
  "gateway container ID unchanged across reload (same container, not recreated)"
assert '[ "$GATEWAY_STARTED_AT_BEFORE" = "$GATEWAY_STARTED_AT_AFTER" ]' \
  "gateway container StartedAt unchanged across reload (same process, no restart)"

log ""
log "== 16. Confirm the new header is now actually being served (proves the reload really applied the new config) =="
set +e
header_check=$(curl -sk -D - -o /dev/null --max-time 8 -X POST \
  -H 'Content-Type: application/json' -d '{"email":"nobody@example.invalid","password":"wrong-password-123"}' \
  --resolve "$TAPIZ_HOST:$GATEWAY_TLS_PORT:127.0.0.1" \
  "https://$TAPIZ_HOST:$GATEWAY_TLS_PORT/api/auth/login" 2>/dev/null)
set -e
assert 'printf "%s" "$header_check" | grep -qi "X-Gateway-Reload-Test: phase2-harmless"' \
  "new response header is present after reload, proving the config change actually took effect"

# Keep the background traffic running a few more seconds post-reload so the
# continuity window covers meaningful traffic both before AND after the
# reload moment, not just the instant around it.
sleep 5

log ""
log "== 17. Stop background traffic and confirm zero connection failures / 502 / 503 / timeouts during the whole window =="
stop_traffic

login_total=$(wc -l < "$LOGIN_LOG" | tr -d ' ')
scan_total=$(wc -l < "$SCAN_LOG" | tr -d ' ')
login_bad=$(grep -Ev ' (400|401)$' "$LOGIN_LOG" | wc -l | tr -d ' ')
scan_bad=$(grep -Ev ' 4[0-9][0-9]$' "$SCAN_LOG" | wc -l | tr -d ' ')

log "  login requests logged: $login_total (bad/unexpected: $login_bad)"
log "  scan requests logged:  $scan_total (bad/unexpected: $scan_bad)"
if [ "$login_bad" != "0" ]; then
  log "  --- unexpected login log lines ---"
  grep -Ev ' (400|401)$' "$LOGIN_LOG" | sed 's/^/    /'
fi
if [ "$scan_bad" != "0" ]; then
  log "  --- unexpected scan log lines ---"
  grep -Ev ' 4[0-9][0-9]$' "$SCAN_LOG" | sed 's/^/    /'
fi

assert '[ "$login_total" -gt 0 ]' \
  "background login traffic actually logged requests ($login_total total)"
assert '[ "$scan_total" -gt 0 ]' \
  "background scan traffic actually logged requests ($scan_total total)"
assert '[ "$login_bad" = "0" ]' \
  "every logged login response during the reload window was a real 400/401 (zero connection failures/502/503/timeouts/000)"
assert '[ "$scan_bad" = "0" ]' \
  "every logged scan response during the reload window was a real 4xx (zero connection failures/502/503/timeouts/000)"

log ""
log "== 18. Confirm no API lane container was restarted by the gateway-only reload =="
AUTH1_CID_AFTER=$(tapiz_compose ps -q auth-api-1)
AUTH2_CID_AFTER=$(tapiz_compose ps -q auth-api-2)
SCAN_CID_AFTER=$(tapiz_compose ps -q scan-api)
GENERAL_CID_AFTER=$(tapiz_compose ps -q general-api)
AUTH1_STARTED_AFTER=$(docker inspect --format '{{.State.StartedAt}}' "$AUTH1_CID_AFTER")
AUTH2_STARTED_AFTER=$(docker inspect --format '{{.State.StartedAt}}' "$AUTH2_CID_AFTER")
SCAN_STARTED_AFTER=$(docker inspect --format '{{.State.StartedAt}}' "$SCAN_CID_AFTER")
GENERAL_STARTED_AFTER=$(docker inspect --format '{{.State.StartedAt}}' "$GENERAL_CID_AFTER")

assert '[ "$AUTH1_CID_BEFORE" = "$AUTH1_CID_AFTER" ] && [ "$AUTH1_STARTED_BEFORE" = "$AUTH1_STARTED_AFTER" ]' \
  "auth-api-1 container unchanged/not restarted by gateway reload"
assert '[ "$AUTH2_CID_BEFORE" = "$AUTH2_CID_AFTER" ] && [ "$AUTH2_STARTED_BEFORE" = "$AUTH2_STARTED_AFTER" ]' \
  "auth-api-2 container unchanged/not restarted by gateway reload"
assert '[ "$SCAN_CID_BEFORE" = "$SCAN_CID_AFTER" ] && [ "$SCAN_STARTED_BEFORE" = "$SCAN_STARTED_AFTER" ]' \
  "scan-api container unchanged/not restarted by gateway reload"
assert '[ "$GENERAL_CID_BEFORE" = "$GENERAL_CID_AFTER" ] && [ "$GENERAL_STARTED_BEFORE" = "$GENERAL_STARTED_AFTER" ]' \
  "general-api container unchanged/not restarted by gateway reload"

auth1_health_after=$(tapiz_compose ps --format '{{.Health}}' auth-api-1 2>/dev/null || true)
auth2_health_after=$(tapiz_compose ps --format '{{.Health}}' auth-api-2 2>/dev/null || true)
scan_health_after=$(tapiz_compose ps --format '{{.Health}}' scan-api 2>/dev/null || true)
general_health_after=$(tapiz_compose ps --format '{{.Health}}' general-api 2>/dev/null || true)
worker_health_after=$(tapiz_compose ps --format '{{.Health}}' worker 2>/dev/null || true)
scheduler_health_after=$(tapiz_compose ps --format '{{.Health}}' scheduler 2>/dev/null || true)
assert '[ "$auth1_health_after" = "healthy" ]' "auth-api-1 still healthy after reload"
assert '[ "$auth2_health_after" = "healthy" ]' "auth-api-2 still healthy after reload"
assert '[ "$scan_health_after" = "healthy" ]' "scan-api still healthy after reload"
assert '[ "$general_health_after" = "healthy" ]' "general-api still healthy after reload"
assert '[ "$worker_health_after" = "healthy" ]' "worker still healthy after reload"
assert '[ "$scheduler_health_after" = "healthy" ]' "scheduler still healthy after reload"

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
log "Login requests during window: $login_total (unexpected: $login_bad)"
log "Scan requests during window: $scan_total (unexpected: $scan_bad)"
if [ "$fail_count" != "0" ]; then
  log "$failures"
  exit 1
fi
log "All checks passed."
