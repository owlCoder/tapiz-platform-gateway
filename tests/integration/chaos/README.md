# Phase 3 chaos / failure-isolation integration harness

This is a **separate, later** harness than `../run.sh` (fake-stub),
`../real-stack/run.sh` (Phase 1) and `../graceful-reload/run.sh` (Phase 2). It
does not modify or depend on any of them, and none of them are modified by it.

## What this proves, vs. the earlier harnesses

`../real-stack/run.sh` proves the real Tapiz LMS VPS stack comes up healthy
and correctly routed behind this repository's real, unmodified gateway Caddy
config. `../graceful-reload/run.sh` proves a live gateway config reload drops
zero traffic and restarts no upstream. Neither deliberately breaks anything.

This harness proves, on top of the same real-stack foundation, **plus the
existing fake Aura stub** (`../docker-compose.aura-stub.yml`, read-only
reference, never copied or modified) running alongside it behind the same
real gateway:

1. Restarting only `auth-api-1` (not both auth replicas) is absorbed by
   Caddy's own existing `lb_policy round_robin` + active health check on the
   auth lane — login keeps succeeding with a real 4xx throughout, routed to
   `auth-api-2`; the scan lane is completely unaffected; after recovery,
   several consecutive logins all succeed, proving round-robin resumed using
   both replicas, not just that recovery happened.
2. Stopping the scan lane entirely produces a well-defined Caddy `502`, not a
   hang/timeout, while login and general-lane traffic continue succeeding
   normally; restarting it restores scan traffic.
3. Stopping the general lane entirely produces a well-defined Caddy
   `502`/`503` while login and scan continue succeeding normally; restarting
   it restores general-lane traffic.
4. Stopping the Aura stub entirely fails only Aura's own host
   (`api.aura-chaos.test`, `502`) while all three Tapiz lanes keep working,
   completely unaffected; restarting it restores Aura routing.
5. Stopping the entire real Tapiz stack (all 4 API lanes plus
   postgres/valkey/pgbouncer/worker/scheduler) fails all of Tapiz's routes
   (`503`) while Aura keeps working, completely unaffected; restarting the
   whole stack restores all three Tapiz lanes.

Every scenario asserts **both** the degraded state and the recovered state —
never just one or the other. It deliberately does **not** attempt
backup/restore or scheduler/worker coexistence under load — those are later,
separate phases (Phase 4/5).

## No new retry logic anywhere

This harness only **observes and asserts** the gateway's existing
failover/failure behavior. The auth-lane failover in scenario 1 is Caddy's
own `lb_policy round_robin` + `health_uri`/`health_interval`/`health_timeout`
already present, unmodified, in the real `sites/tapiz.caddy` — nothing was
added to make that failover happen. Where a scenario has no failover by
design (scan lane and general lane each run exactly one container; the Aura
stub site has no lane redundancy either), a clean `502`/`503` is asserted as
the correct, complete proof for that scenario — this harness never adds
retry logic, script-level or Caddy-config-level, to paper over that.

## Duplicated vs. shared setup (same design decision as Phase 2)

Real-stack bring-up (build/up/schema-push/wait-healthy) is duplicated into
this harness's own `run.sh`, with entirely distinct resource names, rather
than sharing a helper with `../real-stack/run.sh` or `../graceful-reload/run.sh`.
Same reasoning as `../graceful-reload/README.md`'s "Duplicated vs. shared
setup" section: a shared helper would require editing an already-verified
harness to source it, risking a regression for the sake of DRY. Confirmed by
`git diff --stat` showing no changes to any of the other three harnesses'
own files.

## Distinct disposable resource names (never collide with the other three harnesses)

| Resource | Stub (`../run.sh`) | Phase 1 (`../real-stack/`) | Phase 2 (`../graceful-reload/`) | Phase 3 (this harness) |
|---|---|---|---|---|
| Tapiz edge network | `tapiz-edge-test` | `tapiz-edge-real-test` | `tapiz-edge-reload-test` | `tapiz-edge-chaos-test` |
| Aura edge network | `aura-edge-test` | (unused placeholder) | (unused placeholder) | `aura-edge-chaos-test` |
| Tapiz hostname | `api.tapiz.test` | `api.tapiz-real.test` | `api.tapiz-reload.test` | `api.tapiz-chaos.test` |
| Aura hostname | `api.aura.test` | `api.aura-real.test` (unused) | `api.aura-reload.test` (unused) | `api.aura-chaos.test` |
| Gateway ports | `18080`/`18443` | `28080`/`28443` | `38080`/`38443` | `48080`/`48443` |
| Tapiz compose project | (n/a, stub compose) | `tapiz-lms-real-stack-test` | `tapiz-lms-reload-test` | `tapiz-lms-chaos-test` |
| Gateway compose project | `platform-gateway-test` | `platform-gateway-real-stack-test` | `platform-gateway-reload-test` | `platform-gateway-chaos-test` |
| Aura stub compose project | `gateway-test-aura-stub` (its own `name:` field) | (n/a) | (n/a) | `gateway-chaos-test-aura-stub` (`-p` override) |

All four could in principle coexist on one host without collision, though
they are not intended to run concurrently.

### Why the Aura stub gets its own `-p` project name

`../docker-compose.aura-stub.yml` declares `name: gateway-test-aura-stub`,
used unmodified by `../run.sh` (the fake-vs-fake harness). That harness is
never intended to run concurrently with this one, so reusing its project
name would carry no real collision risk in normal use. This harness still
picks an explicitly distinct project name (`gateway-chaos-test-aura-stub`,
via `docker compose -p`) anyway — a zero-cost extra safety margin so the two
harnesses' Aura stub containers can never collide even if both were run at
once by mistake. The compose file itself is referenced read-only via `-f`
and never edited.

## Running it

Requires a local `tapiz-lms` checkout, same override as the other two
real-stack-based harnesses. Defaults to `~/Desktop/tapiz/tapiz-lms`; override
with `TAPIZ_LMS_DIR` if different.

```sh
sh tests/integration/chaos/run.sh
# or, from a different tapiz-lms location:
TAPIZ_LMS_DIR=/path/to/tapiz-lms sh tests/integration/chaos/run.sh
```

Takes roughly 2-4 minutes end to end depending on whether the Tapiz images
are already built/cached from a prior run of any of the harnesses (they
share the same Dockerfile, but not the same image tag — this harness's
images are tagged `tapiz-lms-api-chaos-test:local`). Full teardown runs
automatically on exit, success or failure.

## Status: run on 2026-09-07 — 69/69 checks passed

Exit code `0`. Measured HTTP codes for every degraded/recovered assertion
(from an actual run):

| Scenario | Degraded-state assertion | Code | Recovered-state assertion | Code |
|---|---|---|---|---|
| 1. `auth-api-1` restart | login during restart (failover to `auth-api-2`) | `401` | 5/5 logins after recovery | `401` each |
| 1. `auth-api-1` restart | scan lane during restart (unaffected) | `401` | — | — |
| 2. scan lane stopped | scan request | `502` | scan request after restart | `401` |
| 2. scan lane stopped | login/general lane (unaffected) | `401` | — | — |
| 3. general lane stopped | general request | `502` | general request after restart | `401` |
| 3. general lane stopped | login/scan lane (unaffected) | `401` | — | — |
| 4. Aura stub stopped | Aura request | `502` | Aura request after restart | `200` |
| 4. Aura stub stopped | all 3 Tapiz lanes (unaffected) | `401` each | — | — |
| 5. entire Tapiz stack stopped | login/scan/general (all fail) | `503` each | login/scan/general after restart | `401` each |
| 5. entire Tapiz stack stopped | Aura (unaffected) | `200` | — | — |

Full pass list (69 checks): `caddy validate` + compose config; disposable
`.env`/networks generated; real Tapiz images built and stack containers
started (postgres, valkey, pgbouncer, 4 lanes, worker, scheduler); Aura stub
started; postgres/valkey/pgbouncer healthy; Drizzle schema pushed; all 4
lanes + worker healthy, scheduler healthy; gateway container started and
running; baseline login/scan/general/Aura all succeed; all 5 chaos scenarios'
degraded + recovered assertions (as tabulated above); no host port on any
real Tapiz container or the Aura stub; only the gateway container publishes
host ports (`48080`/`48443`).

## Real bugs found and fixed while building this harness

1. **Docker reporting a container `healthy` again does not mean Caddy's own
   active health check has already re-admitted it to the `reverse_proxy`
   pool.** The real `sites/tapiz.caddy` health check on each Tapiz lane uses
   `health_interval 10s`/`health_timeout 5s`; the Aura site's `reverse_proxy`
   blocks declare no `health_uri` at all, so Caddy only learns an Aura
   upstream is back via a passive/on-demand dial retry. A first run of this
   harness reproducibly hit three `503`/`502` failures asserting recovery on
   the very next request after `docker compose start`/`restart` reported the
   container healthy: general-api's own post-recovery check, the
   still-recovering general-api being incidentally re-checked one scenario
   later during the unrelated Aura-stop scenario (proving this is a genuine
   settle-time gap, not a one-off flake), and Aura's own post-recovery check.
   Fixed by adding a `wait_route_ok` helper that polls the expected HTTP code
   for up to 20-30s after any restart/restore, instead of asserting on a
   single request immediately after the container-level health check passes.
   This is not a gateway bug — it is Caddy's documented health-check
   interval/passive-failure behavior working as configured; the harness's own
   recovery assertions needed to account for it, the same way `real-stack`'s
   `wait_healthy` already accounts for container startup time.
2. No other new Docker/Compose/Caddy bugs distinct from the ones already
   documented in `../real-stack/README.md` and `../graceful-reload/README.md`
   were hit — this harness reuses the same real-stack bring-up pattern and
   therefore inherits those fixes (workspace-root `npm ci`, shadowed
   `node_modules` volumes to avoid `EROFS`, the `wait_healthy`/`assert`
   `set -e` pitfalls, the gateway `caddy` service's missing healthcheck, and
   PgBouncer's `pg_isready` fallback).

## What this harness does NOT prove

Same boundaries as `../real-stack/README.md` and `../graceful-reload/README.md`,
plus:

- Backup/restore or scheduler/worker coexistence under sustained load —
  explicitly out of scope for Phase 3 (later phases).
- Simultaneous/overlapping multi-container failures (e.g. two lanes down at
  once, or a lane failing mid-reload) — each scenario here is a single,
  controlled, sequential failure with full recovery verified before the next.
- Network-partition-style failures (e.g. iptables DROP, packet loss/latency
  injection) — every failure here is a container stop/restart, not a network
  fault; Caddy's behavior under a genuine network partition (as opposed to a
  closed listening socket) is not independently exercised.
- A real Aura stack — the Aura side of every scenario uses the existing,
  already-proven Node stub (echoes lane/path only, no business logic, no
  database), not the real `aura-beats` application.
