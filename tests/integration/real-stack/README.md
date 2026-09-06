# Phase 1 real-stack integration harness

This is a **separate, later** harness than `../run.sh` (the fake-stub
harness documented in the repository root `README.md`). It does not modify
or depend on `../run.sh` or any of its files, and is not modified by it.

## What this proves, vs. the stub harness

`../run.sh` proves this gateway's routing/independence logic using minimal
Node HTTP stub upstreams — no real application, no database.

This harness proves the same gateway config (`Caddyfile`, `sites/*.caddy`,
`snippets/*.caddy`, `docker-compose.yml`, all real and unmodified) routes
correctly in front of the **real Tapiz LMS VPS stack**:
`apps/api/ops/vps/docker-compose.yml`, referenced (via `-f`) from the
`tapiz-lms` checkout, never copied into this repository — real Postgres,
real Valkey, real PgBouncer, the real traffic-isolated `auth-api-1`/
`auth-api-2`/`scan-api`/`general-api` lanes, the real `worker`, and the real
`scheduler`, all built from the product's own Dockerfile.

Specifically, Phase 1 proves:

1. The real stack comes up healthy behind the real central gateway.
2. `POST /api/auth/login` reaches the auth lane.
3. `POST /api/attendance/scan` and `/api/attendance/scan-student` reach the
   scan lane.
4. Everything else (`GET /api/subjects`) reaches the general lane.
5. PgBouncer/worker/scheduler run normally (healthy, not crash-looping)
   behind the central gateway.
6. The product's own Caddy (`standalone-ingress` profile) is never started
   and is not required.

It deliberately does **not** attempt graceful reload, chaos testing,
backup/restore, or scheduler/worker coexistence testing — those are later,
separate phases.

### Why a real 4xx, not a real 200 login

Wrong/nonexistent credentials still reach the real auth-api Hono app and get
a real `401`/`400` response — not a network-level failure. That is enough to
prove routing, that the real app booted, and real DB connectivity through
PgBouncer. Seeding a real login-able account (`seed-admin`/`seed-demo`) was
considered and intentionally skipped for Phase 1 to keep this harness
simple and avoid any risk of accidentally targeting the wrong database; the
scripts themselves only take `DATABASE_URL` from the environment with no
extra guard, so this would be low-risk to add later if a future phase needs
a real `200`.

## Hard constraints this harness honors

- Only files under `vps-gateway/tests/integration/real-stack/` were added.
  `../run.sh` and its stub files are untouched (verified: `git diff --stat`
  against them is empty).
- Nothing under `tapiz-lms/apps/api/ops/vps/` is ever edited — this harness
  only references `docker-compose.yml` via an absolute `-f` path and
  read-only bind-mounts the repo root for the one-shot schema push.
- The gateway's host ports are overridden to `28080`/`443` -> `28443` (never
  80/443), distinct from the stub harness's `18080`/`18443` so both could
  coexist if ever run back to back.
- No Postgres/Valkey/PgBouncer/worker/scheduler container ever gets a host
  port — verified directly (`docker ps`/`docker port`) in step 11 of every
  run.
- `apps/api/ops/vps/.env` (a real file that may exist on this machine) is
  never read or copied. The generated `.env.tapiz-real-stack` is built from
  scratch, using `env.example` only as the reference for which keys exist,
  with every secret (`POSTGRES_PASSWORD`, `JWT_SECRET`, `JWT_REFRESH_SECRET`,
  `CRON_SECRET`) freshly randomized per run via `/dev/urandom`.
- Disposable network name `tapiz-edge-real-test` (distinct from the stub
  harness's `tapiz-edge-test` and the real `tapiz-edge`). Disposable test
  hostname `api.tapiz-real.test` (distinct from the stub harness's
  `api.tapiz.test`).
- Full teardown on exit, success or failure, via the same `trap cleanup EXIT
  INT TERM` pattern `../run.sh` uses — verified clean via `docker ps -a`,
  `docker network ls`, `docker volume ls`, and the generated `.env` files
  after every run in this harness's own development.

## Files

- `run.sh` — the harness script.
- `docker-compose.gateway-real-test-ports.yml` — overrides this repository's
  real `docker-compose.yml` `caddy` service's `ports:`/`volumes:` to bind
  `28080`/`28443` and load a test-only Caddyfile entry point instead of the
  real one, using `!override` for both keys and repo-root-relative paths —
  see the file's own comments for why (the same two lessons `../run.sh`
  already documented, reused rather than rediscovered).
- `Caddyfile.real-stack.test` — a whole substitute Caddy entry file (not an
  extra `snippets/*.caddy` file) whose only content beyond the real
  `import` lines is a `local_certs` global option, for the same reason
  `../stubs/Caddyfile.test` needed one (a global options block cannot arrive
  via `import`, and `.test` is a reserved, non-issuable TLD).
- `docker-compose.schema-push.yml` — a one-shot `schema-push` service added
  to the real Tapiz compose file (via `-f`) that runs `npm run db:push --
  --force` from a throwaway `node:24.19.0-alpine3.23` container, over the
  stack's own private Docker network, against the disposable `postgres`
  service — never a host-mapped Postgres port. Mounts the tapiz-lms repo
  root read-only (an npm-workspaces monorepo — the lockfile lives at the
  root, not in `apps/api/`) and shadows every workspace's existing
  `node_modules/` with its own disposable named volume so `npm ci` never
  needs to write into the real, read-only-mounted tapiz-lms tree.

## Running it

Requires a local `tapiz-lms` checkout. Defaults to `~/Desktop/tapiz/tapiz-lms`
(this machine's actual layout); override with `TAPIZ_LMS_DIR` if different.

```sh
sh tests/integration/real-stack/run.sh
# or, from a different tapiz-lms location:
TAPIZ_LMS_DIR=/path/to/tapiz-lms sh tests/integration/real-stack/run.sh
```

Takes roughly 3-4 minutes end to end (image build + `npm ci` inside the
schema-push container are the two slowest steps). Full teardown runs
automatically on exit, success or failure.

## Status: run on 2026-09-06 — 27/27 checks passed

Exit code `0`. Full pass list:

- `caddy validate` + gateway compose config parse cleanly.
- Disposable `.env.tapiz-real-stack` generated with random-only local
  secrets.
- Disposable `tapiz-edge-real-test` network created.
- Real Tapiz images (auth-api-1/2, scan-api, general-api, worker, scheduler)
  built from the real, unmodified `Dockerfile`.
- Real Tapiz stack containers started (postgres, valkey, pgbouncer, the 4
  lanes, worker, scheduler — no `caddy` service, no `standalone-ingress`
  profile).
- postgres/valkey/pgbouncer report healthy.
- `npm run db:push -- --force` applied the Drizzle schema to the disposable
  Postgres.
- auth-api-1, auth-api-2, scan-api, general-api, worker all report healthy
  (real app booted, real DB connectivity through PgBouncer).
- scheduler reports healthy (pgrep-based healthcheck, running not
  crash-looping).
- tapiz-lms's own standalone-ingress `caddy` service was never created.
- Real gateway container started against the real Tapiz edge network; the
  gateway `caddy` container itself is running (this service declares no
  Docker healthcheck in the real, unmodified `docker-compose.yml` —
  reachability is proven directly by the routing assertions below instead).
- `POST /api/auth/login` with bogus credentials -> real `401` from the auth
  lane.
- `POST /api/attendance/scan` and `/api/attendance/scan-student` with bogus
  payloads -> real `401` from the scan lane.
- `GET /api/subjects` unauthenticated -> real `401` from the general lane
  (not a routing failure).
- PgBouncer accepts connections on its pooled listener (pool alive, not
  crash-looping — see "Real bugs found and fixed" below for why this is
  `pg_isready`, not `SHOW POOLS`).
- worker and scheduler both still healthy after traffic.
- No real Tapiz container (postgres/valkey/pgbouncer/lanes/worker/scheduler)
  publishes a host port; only the gateway container does (`28080`/`28443`).

## Real bugs found and fixed while building this harness

1. **`npm ci` from `apps/api/` alone fails outright**: `apps/api` has no
   `package-lock.json` of its own — this is an npm-workspaces monorepo and
   the lockfile lives at the repo root, alongside the other workspaces'
   `package.json` files it references (exactly what the real Dockerfile's
   own `dependencies` stage `COPY`s). Fixed by mounting the whole `tapiz-lms`
   repo root (not just `apps/api/`) read-only into the schema-push container
   and running `npm ci --workspace=apps/api --include-workspace-root=false`
   from there, matching the Dockerfile's own install command.
2. **`EROFS` on `npm ci` even after mounting the repo root read-only**: this
   development machine already has real `node_modules/` directories on disk
   for the root workspace, `apps/api`, `apps/web`, and
   `packages/sdk/typescript` from ordinary local dev work. Because the whole
   repo root was bind-mounted read-only, npm's own install/relink step tried
   to remove a stale file inside one of them
   (`packages/sdk/typescript/node_modules/.vite`) and failed with `EROFS:
   read-only file system`. Fixed by shadowing every one of those four
   `node_modules/` paths with its own disposable named Docker volume, mounted
   on top of the read-only bind mount, so npm only ever writes into throwaway
   volumes and the real tapiz-lms checkout's `node_modules/` directories are
   never touched, read or written.
3. **A helper *function* returning non-zero as its own last statement trips
   `set -e` the same way a bare `[ ]` does** — one level removed from bug #4
   already documented in the repository root `README.md`. `wait_healthy()`'s
   final `return 1` aborted the whole script the first time a wait
   legitimately timed out, before the following `check ... $?` could ever
   run, silently truncating the rest of the harness. Fixed by wrapping every
   `wait_healthy` call site in an explicit `if wait_healthy ...; then check
   ... 0; else check ... 1; fi`, exactly like `assert()` already does for
   bare test expressions, rather than calling the function as a bare
   statement immediately followed by `check ... $?`.
4. **The gateway's own `docker-compose.yml` (real, unmodified) declares no
   Docker healthcheck for its `caddy` service.** A first attempt at waiting
   for `{{.Health}}` to report `healthy` on the gateway container timed out
   on every run regardless of whether Caddy was actually serving traffic
   correctly (confirmed: the real HTTP routing assertions right after it
   passed every time). This is not a bug in the gateway config — it is simply
   how that service is defined — so the harness does not invent a
   healthcheck for it. Fixed by asserting the container is `running` (not
   crash-looping) and treating the real HTTP routing assertions in step 9 as
   the actual reachability proof, which is a stronger signal than a
   healthcheck passing anyway.
5. **PgBouncer's admin console (`psql -d pgbouncer -c 'SHOW POOLS;'`) is not
   reachable with the application's regular DB user, by design** — it failed
   with `FATAL: not allowed` on direct reproduction, because that user is not
   listed in PgBouncer's `admin_users`/`stats_users`, which the real,
   unmodified `docker-compose.yml` does not set. This is not a harness bug;
   it is exactly why that same compose file's own `pgbouncer` healthcheck
   already reads `... SHOW POOLS ... || pg_isready ...` — the `psql` half is
   expected to fail there too, and the `pg_isready` half is what actually
   passes on every real run (confirmed by inspecting
   `docker inspect ...State.Health.Log` on a manually-started container: the
   healthcheck's logged output is always `pg_isready`'s "accepting
   connections" line, never a `SHOW POOLS` result). Fixed by asserting
   `pg_isready` directly (the same fallback the real healthcheck relies on)
   instead of asserting on an admin console this stack was never configured
   to expose.

## What this harness does NOT prove

Same boundaries as `../run.sh`, plus:

- Graceful Caddy reload, chaos/failure-injection testing, backup/restore,
  or scheduler+worker coexistence under load — explicitly out of scope for
  Phase 1 (later phases).
- A real, seeded login (`200` from `/api/auth/login`) — see "Why a real
  4xx, not a real 200 login" above.
- Any load/burst behavior — `apps/api/ops/vps/loadtest/` already covers that
  against the product's own compose file directly (not through this
  gateway); re-measuring the login-lane burst specifically through this
  shared gateway is unmeasured, same as noted in the repository root
  `README.md`'s "What remains before this can safely happen" section.
- Real DNS, TLS/ACME issuance, or anything about the real `tapiz-edge`
  network name — this harness's `-real-test`-suffixed names can never
  collide with or be mistaken for a real activation.
