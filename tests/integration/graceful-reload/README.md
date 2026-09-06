# Phase 2 graceful-reload integration harness

This is a **separate, later** harness than `../run.sh` (fake-stub) and
`../real-stack/run.sh` (Phase 1, real stack, no reload). It does not modify
or depend on either of them, and neither is modified by it.

## What this proves, vs. Phase 1

`../real-stack/run.sh` proves the real Tapiz LMS VPS stack comes up healthy
and correctly routed behind this repository's real, unmodified gateway Caddy
config. It deliberately does not touch reload behavior.

This harness proves, on top of that same real-stack foundation:

1. An invalid Caddy config (deliberate syntax error) is **rejected by `caddy
   validate`** in a throwaway container, and never gets a chance to reach the
   live, running gateway process.
2. The live gateway's already-active config **stays active and continues
   serving real traffic correctly** when a bad config is never loaded.
3. A real, valid, harmless config change (one extra response header, added via
   the existing `gateway_common` snippet pattern — no routing/lane behavior
   change) is applied to the **live** gateway container via `caddy reload`,
   and this reload is a same-process operation: the gateway container's own
   ID and `StartedAt` timestamp are identical before and after — it is never
   restarted.
4. A continuous background stream of real login (`POST /api/auth/login`) and
   real scan (`POST /api/attendance/scan`) requests against the real Tapiz
   stack, running throughout the entire reload window (including several
   seconds before and after the actual `caddy reload` call), sees **zero**
   connection failures, 502s, 503s, timeouts, or gaps — every single logged
   response is a real, expected 4xx.
5. None of the four real API lane containers (`auth-api-1`, `auth-api-2`,
   `scan-api`, `general-api`) are restarted by the gateway-only reload — their
   container IDs and `StartedAt` timestamps, and their health status, are
   unchanged across the whole test.

It deliberately does **not** attempt chaos/failure injection, backup/restore,
or scheduler/worker-under-load testing — those are later, separate phases
(Phase 3-5).

## Duplicated vs. shared setup (design decision)

`../real-stack/run.sh` is already a verified-passing 27/27 harness. Rather
than refactor its real-stack bring-up steps (build/up/schema-push/wait-healthy)
into a shared sourced helper used by both scripts, this harness **duplicates**
that setup logic into its own self-contained `run.sh`, with entirely distinct
resource names (network, project names, hostname, ports, volumes).

Reasoning: introducing a shared helper would require editing
`../real-stack/run.sh` itself to source it, which risks regressing an
already-verified harness for the sake of DRY between two test scripts. A
passing, fully isolated Phase 2 harness is more valuable than eliminating the
duplication. `../real-stack/run.sh` was NOT modified by this work — confirmed
by `git diff --stat` showing no changes to it or its existing files, and by
re-running it standalone after this harness was built (still 27/27, see the
root `README.md`'s own status line, unchanged).

## Distinct disposable resource names (never collide with the other two harnesses)

| Resource | Stub harness (`../run.sh`) | Phase 1 (`../real-stack/`) | Phase 2 (this harness) |
|---|---|---|---|
| Tapiz edge network | `tapiz-edge-test` | `tapiz-edge-real-test` | `tapiz-edge-reload-test` |
| Tapiz hostname | `api.tapiz.test` | `api.tapiz-real.test` | `api.tapiz-reload.test` |
| Aura hostname (unused placeholder) | `api.aura.test` | `api.aura-real.test` | `api.aura-reload.test` |
| Gateway ports | `18080`/`18443` | `28080`/`28443` | `38080`/`38443` |
| Tapiz compose project | (n/a, stub compose) | `tapiz-lms-real-stack-test` | `tapiz-lms-reload-test` |
| Gateway compose project | `platform-gateway-test` | `platform-gateway-real-stack-test` | `platform-gateway-reload-test` |

All three could in principle coexist on one host without collision, though
they are not intended to run concurrently.

## How the mid-run config edits work without ever touching the real repo files

The gateway container in this harness mounts a **scratch `sites-live/`
directory** (created fresh by `run.sh` at the start of every run, deleted by
teardown) as `/etc/caddy/sites`, seeded as a byte-for-byte copy of the real
`../../../sites/tapiz.caddy` and `../../../sites/aura.caddy`. `snippets/` is
still bind-mounted straight from the real, unmodified repo directory.

- The **deliberately-broken** config (step 12) is built in a separate
  `mktemp -d` scratch directory, copied from `sites-live/`, with an appended
  syntax error (unclosed brace) — validated in its own throwaway
  `caddy validate` container invocation, never against the live gateway
  container and never written into `sites-live/` itself.
- The **harmless, valid** config change (step 14) — one extra
  `header X-Gateway-Reload-Test "phase2-harmless"` line plus the existing
  `import gateway_common` — is written directly into `sites-live/tapiz.caddy`
  (the file the live container has bind-mounted read-only), validated once
  more in a throwaway container, and only then is `caddy reload` invoked
  against the live gateway container. Caddy reads Caddyfile content fresh on
  `reload`; no container filesystem write is needed beyond the host-side bind
  mount edit.
- At no point does this script open `../../../sites/tapiz.caddy` or
  `../../../sites/aura.caddy` (the real repository files) for writing.

## Caddy 2.10-alpine reload syntax (confirmed by running `--help` against the real image, not assumed)

```
caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile
```

matches `caddy reload --help`'s documented usage exactly (`-c/--config`
required, `-a/--adapter` optional, `-f/--force` available but not needed here
since the config content genuinely changes). Run via
`docker compose exec -T caddy caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile`
against the live, already-running gateway container.

## Running it

Requires a local `tapiz-lms` checkout, same override as the other harnesses.
Defaults to `~/Desktop/tapiz/tapiz-lms`; override with `TAPIZ_LMS_DIR` if
different.

```sh
sh tests/integration/graceful-reload/run.sh
# or, from a different tapiz-lms location:
TAPIZ_LMS_DIR=/path/to/tapiz-lms sh tests/integration/graceful-reload/run.sh
```

Takes roughly 1-4 minutes end to end depending on whether the Tapiz images are
already built/cached from a prior run of any of the three harnesses (they
share the same Dockerfile, but NOT the same image tag — this harness's images
are tagged `tapiz-lms-api-reload-test:local`, distinct from Phase 1's
`tapiz-lms-api-real-stack-test:local`). Full teardown runs automatically on
exit, success or failure.

## Status: run on 2026-09-06 — 45/45 checks passed

Exit code `0`, twice in a row (once with a short traffic window, once after
widening it to a several-second pre/post-reload settle window for a more
meaningful continuity sample). Full pass list:

- `caddy validate` + gateway compose config parse cleanly.
- Disposable `.env.tapiz-reload-test` generated with random-only local
  secrets.
- Disposable `tapiz-edge-reload-test` network created.
- Real Tapiz images built, stack containers started (postgres, valkey,
  pgbouncer, 4 lanes, worker, scheduler — no `caddy` service, no
  `standalone-ingress` profile).
- postgres/valkey/pgbouncer report healthy.
- `npm run db:push -- --force` applied the Drizzle schema to the disposable
  Postgres.
- auth-api-1, auth-api-2, scan-api, general-api, worker all report healthy;
  scheduler reports healthy (running, not crash-looping).
- Scratch `sites-live/` seeded from the real, unmodified `sites/*.caddy`.
- Real gateway container started against the real Tapiz edge network,
  serving from the `sites-live/` copy.
- Baseline: one real login (`401`) and one real scan (`4xx`) succeed through
  the gateway before any reload activity.
- Pre-reload container identities captured for the gateway and all 4 API
  lanes (container ID + `StartedAt`).
- Continuous background login + scan traffic loops started successfully.
- A deliberately broken config (unclosed brace in a scratch copy of
  `tapiz.caddy`) is **rejected** by `caddy validate` (non-zero exit, clear
  Caddyfile syntax error identifying the exact broken line) — never touching
  the live gateway container.
- The live gateway, unaffected by the rejected validation, still serves real
  `401`/`4xx` for both login and scan immediately afterward.
- A real, valid, harmless header-only config change passes `caddy validate`.
- `caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile` against
  the live gateway container succeeds (exit `0`).
- The gateway container's own ID and `StartedAt` are **identical** before and
  after the reload — same process, not recreated/restarted.
- The new response header (`X-Gateway-Reload-Test: phase2-harmless`) is
  actually present in a post-reload response, proving the reload really
  applied the new config (not a no-op).
- Every logged response across the whole background-traffic window (spanning
  several seconds before, during, and after the reload) is a real, expected
  4xx for both login and scan — zero connection failures, 502s, 503s,
  timeouts, or unexpected codes.
- All four API lane containers (`auth-api-1`, `auth-api-2`, `scan-api`,
  `general-api`) have unchanged container IDs, unchanged `StartedAt`
  timestamps, and remain `healthy` after the reload — a gateway-only reload
  never touches upstream containers.
- worker and scheduler remain healthy after the reload.
- No real Tapiz container publishes a host port; only the gateway container
  does (`38080`/`38443`).

Exact counts from the widened-window run are logged in the harness's own
"Summary" section each time it runs (`Login requests during window: N`,
`Scan requests during window: N`) — not restated here as a fixed number,
since it depends on machine speed; what is fixed and asserted every run is
that both counts are `> 0` and that zero of either were unexpected/bad codes.

## Real bugs found and fixed while building this harness

No new Docker/Compose/Caddy bugs distinct from the five already documented in
`../real-stack/README.md` were hit — this harness reuses the same real-stack
bring-up pattern (and therefore inherits those fixes: workspace-root `npm ci`,
shadowed `node_modules` volumes to avoid `EROFS`, the `wait_healthy` /
`assert` `set -e` pitfalls, the gateway `caddy` service's missing healthcheck,
and PgBouncer's `pg_isready` fallback). One reload-specific detail worth
recording:

1. **Caddy re-reads Caddyfile content fresh from disk on `reload`; the
   read-only bind mount does not need to be remounted or the container
   restarted for a host-side file edit to be picked up.** Confirmed directly:
   editing `sites-live/tapiz.caddy` on the host, then running
   `docker compose exec -T caddy caddy reload --config ... --adapter
   caddyfile` against the already-running container, was sufeicient for the
   new `X-Gateway-Reload-Test` header to appear in the very next response —
   no extra step (touch, remount, `docker cp`) was needed. This matches
   Caddy's documented reload behavior (`reload` re-adapts and re-loads the
   config file from its configured path) but is worth confirming in practice
   rather than assuming, since the file arrives via a Docker bind mount, not
   a path native to the container.

## What this harness does NOT prove

Same boundaries as `../real-stack/README.md`, plus:

- Chaos/failure injection (killing an upstream mid-request, network
  partition, etc.), backup/restore, or scheduler/worker coexistence under
  sustained load — explicitly out of scope for Phase 2 (later phases).
- Reload behavior under CPU/memory pressure or with a much larger, more
  realistic Caddyfile — this repository's real `sites/*.caddy` is small
  (two site blocks), so reload latency here is not representative of a much
  larger multi-tenant gateway config.
- Zero-downtime behavior for **long-lived** connections (e.g. an in-flight
  streaming response) across a reload — the background traffic here is
  short-lived request/response pairs (bogus login/scan), not a held-open
  connection; Caddy's documented graceful-drain behavior for in-flight
  requests during reload is not independently re-verified by this harness.
