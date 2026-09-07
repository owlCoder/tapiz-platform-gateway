# Phase 5 scheduler/worker coexistence integration harness

This is the **final, separate, later** harness than `../run.sh` (fake-stub),
`../real-stack/run.sh` (Phase 1), `../graceful-reload/run.sh` (Phase 2),
`../chaos/run.sh` (Phase 3), and `../backup-restore/run.sh` (Phase 4). It does
not modify or depend on any of them, and none of them are modified by it.

## What this proves, vs. the earlier harnesses

The other harnesses prove routing, reload, failure-isolation, and
backup/restore behavior. None of them exercise the real `worker` (background
attendance/quiz flush timers) and `scheduler` (authenticated cron-route
caller) containers running concurrently with real, realistic traffic. This
harness proves:

1. The real stack (Postgres/Valkey/PgBouncer/4 lanes/worker/scheduler) comes
   up healthy behind the real gateway, seeded with a real demo dataset (real
   enrolled students, subjects, sessions, and attendance rows via the
   product's own `seed-demo.ts`) rather than an empty schema — this phase
   specifically needs realistic attendance-flush-shaped data.
2. The scheduler's own authenticated job-route mechanism (`POST
   /api/attendance/flush`, `Authorization: Bearer $CRON_SECRET`) can be
   triggered directly and returns a real success, more than once, while the
   `worker` container's normal background flush timers and a sustained
   concurrent login/scan/general traffic window are all running at the same
   time.
3. The scheduler's own container process stays healthy (not crash-looping)
   throughout, independent of whether its job route was ever actually called
   during this run.
4. Real, measured connection/memory state — `pg_stat_activity` grouped by
   state, PgBouncer's pooled-listener liveness, Valkey `INFO` (connected
   clients, memory, evicted keys) — before and after the window, not just
   pass/fail booleans.
5. Zero starvation of the auth/scan lanes specifically: every logged login,
   scan, and general request during the whole window is still a real,
   expected 4xx — never a 502/503/timeout/`000` — even with the scheduler
   trigger and worker both active concurrently.
6. Neither `worker` nor `scheduler` is restarted by any of this, and every
   lane (`auth-api-1`, `auth-api-2`, `scan-api`, `general-api`) plus `worker`
   and `scheduler` remain healthy at the end.

It deliberately does **not** attempt routing/reload/chaos/backup-restore
proofs — those are the four earlier phases. This is the last of the 6-phase
task (Phase 0 through Phase 5).

## Mechanism 1: how the scheduler's job route is triggered (and why)

Read `apps/api/ops/vps/scheduler/scheduler.mjs`, `jobs.json`, and
`entrypoint.sh` before designing this. Findings:

- `scheduler.mjs` wakes once a minute, checks each `jobs.json` entry's cron
  expression(s) against the current UTC time, and for any job that's due,
  calls `POST ${API_BASE_URL}${job.path}` with `Authorization: Bearer
  ${CRON_SECRET}` (`callRoute()`). The real `docker-compose.yml`'s
  `scheduler` service sets `API_BASE_URL=http://general-api:3001` — a direct
  container-to-container call on the stack's own private network, **not**
  through the public gateway/Caddy at all.
- The cheapest, cadences in `jobs.json` (current, verified 2026-09-06) range
  from hourly (`quiz-submit-flush`) to weekly (`retention`) — none are
  reachable by waiting out a real interval in a test harness. Manipulating
  `scheduler.mjs`'s internal minute-tick or cron-match logic would also be
  new logic added to observe existing behavior, which the parent task's own
  constraints (no new retry/scheduling logic) discourage.
- **Mechanism used: a direct, authenticated HTTP call to the exact same
  route, with the exact same auth scheme and the exact same target
  (`http://general-api:3001`), fired from a throwaway
  `curlimages/curl:8.11.1` container attached to this harness's own
  Compose-managed `private` network** (`docker run --rm --network
  "${TAPIZ_PROJECT}_private" curlimages/curl:8.11.1 ...`) — never through the
  `scheduler` container itself, never through the gateway. This is "a safe
  test trigger of the same mechanism the scheduler uses," per the parent
  task's own framing, and needs no new application/scheduler logic at all.
- **Job chosen: `attendance-flush`** (`POST /api/attendance/flush` — read
  live from the current `jobs.json`, not assumed from memory; the full
  current list is `attendance-flush`, `quiz-submit-flush`, `digest-daily`,
  `digest-weekly`, `invoice-dunning`, `license-expiry-reminders`,
  `storage-quota-alerts`, `billing-usage-snapshots`, `retention`). It is the
  one job whose real effect (`flushAll()` from
  `Infrastructure/cache/attendanceBuffer`) the seeded dataset (real
  students/sessions/attendance rows) gives a realistic, non-empty target to
  operate on, and its route handler
  (`presentation/routes/attendance/attendanceRoutes.ts`) is a simple,
  idempotent, non-destructive bearer-gated call. `retention` (`drainLoop`,
  purge-shaped) and the billing/reports/license jobs (address external mail/
  billing services this harness has none of) are deliberately not
  triggered.
- Triggered twice during the traffic window (once early, once ~8s later)
  while background traffic and the real `worker` are both running, per the
  parent task's requirement to observe the mechanism "one or more times"
  during sustained concurrent activity — not just once in isolation.

## Mechanism 2: how PgBouncer/Postgres connection state is measured (and why)

- **PgBouncer's own admin console** (`psql -d pgbouncer -c 'SHOW POOLS;'`) is
  not reachable with the application's regular DB user, by design — this was
  already established in `../real-stack/README.md`'s bug #5 (`FATAL: not
  allowed`, confirmed by direct reproduction there): the real, unmodified
  `docker-compose.yml` never configures `admin_users`/`stats_users` for
  PgBouncer, and its own healthcheck already falls back to `pg_isready` for
  exactly this reason.
- **Mechanism used: `SELECT state, count(*) FROM pg_stat_activity WHERE
  datname = '<db>' GROUP BY state` directly on the source Postgres**, run
  from inside the `postgres` container over the private network (never a
  host-mapped port). This requires no PgBouncer admin access at all and
  shows real connection/waiting state directly — a stronger, simpler
  measurement for this phase's purpose. Captured before and after the
  traffic+scheduler window (step 10 and step 16), plus PgBouncer's
  `pg_isready`-based pooled-listener liveness check (the same fallback the
  real healthcheck already relies on) at both points, so the printed
  numbers reflect real state, not synthetic ones.

## Seeding: seed-demo.ts + postgres-test alias, reused from Phase 4

Reuses `../backup-restore/`'s proven pattern exactly: `apps/api/scripts/
seed-demo.ts` (`npm run seed:demo`), run as-is (never reimplemented as ad hoc
SQL), pointed at `DB_HOST=postgres-test` — a second network alias
(`docker-compose.postgres-alias.yml`, byte-for-byte the same technique as
`../backup-restore/docker-compose.postgres-alias.yml`) added to the real,
unmodified `postgres` service so `seed-demo.ts`'s own `checkSeedTarget`
allow-list guard (never weakened, never bypassed) recognizes this disposable
container as a safe seed target. This gives the attendance-flush job route a
real, realistic dataset (institution hierarchy, 2 assistants, 1 faculty
manager, 24 students, 2 subjects, enrollments, sessions, 164 attendance rows)
to operate against, rather than an empty schema.

## Distinct disposable resource names (never collide with the other four harnesses)

| Resource | Stub | Phase 1 | Phase 2 | Phase 3 | Phase 4 | Phase 5 (this) |
|---|---|---|---|---|---|---|
| Tapiz edge network | `tapiz-edge-test` | `tapiz-edge-real-test` | `tapiz-edge-reload-test` | `tapiz-edge-chaos-test` | (unused, `-backup-restore-test-unused`) | `tapiz-edge-scheduler-test` |
| Tapiz hostname | `api.tapiz.test` | `api.tapiz-real.test` | `api.tapiz-reload.test` | `api.tapiz-chaos.test` | (n/a, no gateway) | `api.tapiz-scheduler.test` |
| Gateway ports | `18080`/`18443` | `28080`/`28443` | `38080`/`38443` | `48080`/`48443` | (n/a, no gateway) | `58080`/`58443` |
| Tapiz compose project | (n/a) | `tapiz-lms-real-stack-test` | `tapiz-lms-reload-test` | `tapiz-lms-chaos-test` | `tapiz-lms-backup-restore-source-test` | `tapiz-lms-scheduler-test` |
| Gateway compose project | `platform-gateway-test` | `platform-gateway-real-stack-test` | `platform-gateway-reload-test` | `platform-gateway-chaos-test` | (n/a) | `platform-gateway-scheduler-test` |

## Running it

Requires a local `tapiz-lms` checkout, same override as every other harness.
Defaults to `~/Desktop/tapiz/tapiz-lms`; override with `TAPIZ_LMS_DIR` if
different.

```sh
sh tests/integration/scheduler-worker/run.sh
# or, from a different tapiz-lms location:
TAPIZ_LMS_DIR=/path/to/tapiz-lms sh tests/integration/scheduler-worker/run.sh
```

Takes roughly 2-4 minutes end to end (image build, schema push, and seed's
own `npm ci` inside throwaway containers, plus a ~25s sustained traffic
window, are the slowest steps). Full teardown runs automatically on exit,
success or failure.

## Status: run on 2026-09-07 — 46/46 checks passed

Exit code `0`. Real measured values from an actual run:

- **`pg_stat_activity` by state**: before the window, `active|1`, `idle|2`;
  after the window, `active|1`, `idle|2` (source Postgres has 3 real
  connections in steady state from the stack's own lanes/worker/scheduler
  querying through PgBouncer — no runaway growth, no stuck `active` rows,
  zero `active`-and-`waiting` rows either measurement).
- **PgBouncer pooled listener**: `pg_isready` reports "accepting
  connections" both before and after the window (no waiter pileup, no
  crash).
- **Valkey `INFO`**: `connected_clients` steady at `6` before and after;
  `used_memory_human` `992.98K` before -> `1.09M` after (small, expected
  growth from the traffic window's own cache writes); `evicted_keys=0` both
  times (the `noeviction` policy was never forced to drop data under this
  load); zero `oom` mentions.
- **Scheduler job trigger**: `POST /api/attendance/flush` with
  `Authorization: Bearer $CRON_SECRET` against `general-api:3001` (direct
  container-to-container call, same target/auth the real scheduler uses) ->
  real `HTTP 200` on both of two triggers, fired roughly 8 seconds apart
  while background traffic and the real `worker` were both active.
- **Scheduler container**: `healthy` (pgrep-based healthcheck) throughout;
  same container ID and `StartedAt` before and after — never restarted.
- **Worker container**: `healthy` throughout; same container ID and
  `StartedAt` before and after — never restarted.
- **API error rates during the ~25s window**: 25 login requests logged, 0
  unexpected; 77 scan requests logged, 0 unexpected; 77 general requests
  logged, 0 unexpected — every single one a real, expected 4xx
  (`400`/`401`), never a `502`/`503`/timeout/`000`.
- All four API lanes (`auth-api-1`, `auth-api-2`, `scan-api`, `general-api`)
  plus `worker` and `scheduler` remain `healthy` at the end.
- No real Tapiz container publishes a host port; only the gateway container
  does (`58080`/`58443`).

## Real bugs found and fixed while building this harness

1. **`env_file: ${TAPIZ_ENV_FILE:-.env}` in the real, unmodified
   `apps/api/ops/vps/docker-compose.yml` silently loaded the REAL
   `apps/api/ops/vps/.env` (present on this dev machine, with a real
   `CRON_SECRET` inside it) instead of this harness's disposable generated
   `.env`.** `TAPIZ_ENV_FILE` is a Compose **interpolation** variable — it is
   resolved from the shell environment / `--env-file`'s own contents at
   `docker compose config` time, and is a completely different mechanism
   from the top-level `--env-file "$TAPIZ_ENV"` flag this harness (and every
   other real-stack-based harness) passes to `docker compose`. Passing
   `--env-file` alone does **not** set `TAPIZ_ENV_FILE` as an actual
   variable; without an explicit `export TAPIZ_ENV_FILE=...`,
   `${TAPIZ_ENV_FILE:-.env}` falls back to the literal string `.env`,
   resolved relative to the compose file's own directory — which is a real
   file that already exists there. First reproduction: the scheduler
   job-route trigger (step 13) returned a real `HTTP 401` even though the
   harness's own generated `CRON_SECRET` was sent as the bearer token,
   because every container was actually running with the **real**
   production `.env`'s `CRON_SECRET`, not the disposable one. Confirmed by
   direct inspection (`ls -la apps/api/ops/vps/.env`, a real file with a
   real `CRON_SECRET=` line already present) rather than assumed. Fixed by
   adding `export TAPIZ_ENV_FILE="$TAPIZ_ENV"` before any `tapiz_compose`
   call, exactly mirroring the pattern this and every other harness already
   uses correctly for the gateway side (`export GATEWAY_ENV_FILE="$GATEWAY_ENV"`).
   Re-running afterward: trigger #1 and #2 both returned real `HTTP 200`.

   **This is a real, latent bug inherited by `../real-stack/run.sh`,
   `../graceful-reload/run.sh`, `../chaos/run.sh`, and
   `../backup-restore/run.sh` too** (none of them export `TAPIZ_ENV_FILE`
   either) — it never surfaced as a failing check in any of them because
   none of those four harnesses assert on a value that differs between the
   real `.env` and the generated disposable one (their login/scan/general
   assertions only check for a real 4xx shape, which succeeds either way;
   their `JWT_SECRET`/`POSTGRES_PASSWORD` mismatches were never exercised
   because Postgres/JWT signing don't care which valid-looking secret was
   used, only that one was present). This harness's own hard constraint 4
   ("never reads the real `.env`") is honored **only because of this fix**;
   per this task's own constraint 1 ("only add/edit files in `vps-gateway`
   — do not touch any of the four existing harnesses' own script/compose/
   Caddyfile files"), the fix was applied only here, not backported to the
   other four. Flagging this prominently so a future task can decide whether
   to backport `export TAPIZ_ENV_FILE=...` to them.

No other new Docker/Compose bugs distinct from the ones already documented
in `../real-stack/README.md` (workspace-root `npm ci`, shadowed
`node_modules` volumes to avoid `EROFS`, the `wait_healthy`/`assert` `set -e`
pitfalls, the gateway `caddy` service's missing healthcheck, and PgBouncer's
`pg_isready` fallback) or `../backup-restore/README.md` (the
`postgres-test` alias / `checkSeedTarget` technique) were hit — this harness
reuses those same patterns and inherits those fixes.

## What this harness does NOT prove

Same boundaries as `../real-stack/README.md`, `../graceful-reload/README.md`,
`../chaos/README.md`, and `../backup-restore/README.md`, plus:

- Real cron cadence timing — the scheduler's own minute-tick/cron-match loop
  in `scheduler.mjs` is never exercised directly; this harness calls the same
  authenticated route the scheduler would call, as an explicit, documented
  substitute for waiting out an hourly/daily/weekly real interval.
- The other eight `jobs.json` entries (`quiz-submit-flush`, `digest-daily`,
  `digest-weekly`, `invoice-dunning`, `license-expiry-reminders`,
  `storage-quota-alerts`, `billing-usage-snapshots`, `retention`) —
  deliberately out of scope; `attendance-flush` alone is sufficient to prove
  the scheduler/worker coexistence mechanism this phase targets, and several
  of the others touch external services (mail/billing) this harness has none
  of, or are destructive/purge-shaped (`retention`).
- Sustained multi-minute or multi-hour load — the traffic window here is
  ~25 seconds, long enough to observe real pool/queue/memory behavior
  settling rather than an instant snapshot, but not a long-duration soak
  test.
- A production-scale dataset — the seeded data (123 tables, low hundreds of
  rows) mirrors `../backup-restore/README.md`'s own seeded scale, not a
  full-semester real institution's data volume.
