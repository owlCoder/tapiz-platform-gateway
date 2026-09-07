# Tapiz Platform Gateway

One Caddy instance owns public ports 80/443 for every product hosted on the
same VPS. It is independent of the Aura Beats and Tapiz LMS Compose projects.
It provides TLS, host/path routing, health checks and JSON access logs; it does
not contain application authorization, database access or business logic.

## Network boundary

The gateway joins one small external edge network per product:

```text
platform-gateway/caddy ── tapiz-edge  ── Tapiz public API lanes only
                       ├─ aura-edge   ── Aura API + media delivery only
                       └─ boards-edge ── Boards app container only
```

Tapiz PostgreSQL, Valkey, PgBouncer, worker and scheduler stay on Tapiz's
private network. Aura PostgreSQL and workers stay on Aura's private network.
Boards PostgreSQL stays on Boards' own private `boards_internal` network.
Products do not join each other's edge networks.

## Product integration contract

Before a product is attached, its Compose configuration must:

1. Create or join its named external edge network.
2. Attach only HTTP upstreams that the gateway needs.
3. Give them stable, product-prefixed aliases. This gateway expects:
   - Tapiz: `tapiz-auth-api-1`, `tapiz-auth-api-2`, `tapiz-scan-api`,
     `tapiz-general-api`.
   - Aura: `aura-api`, `aura-media-delivery`.
   - Boards: `boards-app` (single upstream, no lane split).
4. Remove all product-level host bindings for ports 80/443.

Never use Docker container IP addresses. Product private databases and queues
must not be attached to an edge network merely for convenience.

## Adding or removing a product

To add a product, create its external edge network, attach the gateway and its
public HTTP containers, then add one `sites/<product>.caddy` fragment. Validate
and reload Caddy before exposing its DNS record.

To remove a product, remove its fragment and reload Caddy, then stop/remove
that product's Compose stack. Other sites remain served. If a product is merely
down while its fragment remains, only that product's hostname returns an
upstream failure; it cannot take down Tapiz or Aura.

## Local validation

```sh
cp .env.example .env
./tests/validate.sh
```

The validation command checks Compose interpolation and parses the full Caddy
configuration. It does not create Docker networks, bind ports, contact a VPS or
issue certificates.

## Local integration test (disposable, network-isolated)

`tests/integration/` proves — against this repository's real, unmodified
`Caddyfile`/`sites/*.caddy`/`snippets/common.caddy`/`docker-compose.yml` —
that this gateway can independently route Tapiz and Aura over their own
external edge networks, using minimal Node HTTP stub upstreams instead of the
real applications or any database. It creates its own disposable
`tapiz-edge-test`/`aura-edge-test` networks (never the real `tapiz-edge`/
`aura-edge` names), binds the gateway only to local test ports 18080/18443
(never 80/443), and tears down every container/volume/network it created on
exit, success or failure.

```sh
sh tests/integration/run.sh
```

### Status: run on 2026-09-06 — 20/20 checks passed

- **`api.tapiz.test` routing**: `POST /api/auth/login` reached the auth lane
  (`tapiz-auth-api-1`/`tapiz-auth-api-2`, round-robin observed across runs);
  `POST /api/attendance/scan` and `/api/attendance/scan-student` reached
  `tapiz-scan-api`; every other path (`GET /api/subjects`, and `GET
  /api/auth/login` — right path, wrong method — as a specific
  path-vs-method-match check) fell through to `tapiz-general-api`.
- **`api.aura.test` routing**: `/hls/*` (tested with both a manifest path and
  a segment path) reached `aura-media-delivery`; everything else
  (`/api/tracks`) reached `aura-api`.
- **Cross-product independence, both directions, actually exercised**:
  stopping the Aura stub stack entirely left every Tapiz route working
  unchanged (general and auth lanes both re-verified) while `api.aura.test`
  itself started failing (measured: Caddy returned `502`, since Aura's own
  upstream was gone but Tapiz's routing/health/certs were never touched).
  Restarting Aura and then stopping Tapiz entirely produced the mirror
  result: Aura's api and media lanes kept working, `api.tapiz.test` started
  failing (measured: `503`, no upstream available), Aura was never affected.
- **No public ports on any application stub**: verified directly via `docker
  ps`/`docker port` — every stub container (auth/scan/general lanes, aura-api,
  aura-media-delivery) publishes zero host ports in every state tested; only
  the gateway `caddy` container has host bindings (the test's own 18080/18443
  stand-ins for real 80/443).
- **`caddy validate` and Compose config**: both pass from a cold state with no
  prior containers/networks/volumes present, and the harness's own teardown
  removes every disposable network, container, and volume it created,
  confirmed by direct inspection after each run (`docker network ls`, `docker
  ps -a`, `docker volume ls`, and a host-port `lsof` check all clean
  afterward).

### Real bugs found and fixed while building this harness (not pre-existing gateway bugs — see below)

Two of the fixes below live only in `tests/integration/` and never touch this
repository's real `Caddyfile`/`docker-compose.yml`; one fix (`.env.example`
already matches this) confirmed the real config was already correct. Listed so
a future harness change doesn't have to rediscover the same failure modes:

1. **Compose `ports:`/`volumes:` merge across `-f` files is additive, not a
   replace, unless tagged `!override`.** The first working attempt at
   overriding the gateway's `80:80`/`443:443` to test-only `18080`/`18443`
   silently bound **both** — confirmed directly via `docker port` showing
   `0.0.0.0:80` and `0.0.0.0:18080` on the same container simultaneously,
   which would have violated the no-public-ports constraint on a real
   machine. `tests/integration/docker-compose.gateway-test-ports.yml` now
   uses `!override` for both keys.
2. **Compose resolves every merged `-f` file's relative paths against the
   *first* file's directory, not each file's own directory.** A `./stubs/...`
   reference inside `tests/integration/docker-compose.gateway-test-ports.yml`
   resolved to the wrong, nonexistent `vps-gateway/stubs/...` instead of
   `vps-gateway/tests/integration/stubs/...` — confirmed via `docker compose
   config`'s resolved `source:` paths. Fixed by writing every relative path in
   that file relative to the repo root (where `docker-compose.yml` lives),
   not to the override file's own location.
3. **A Caddyfile global options block cannot be delivered via `import` from a
   subdirectory — it must be the first thing in the actual entry file.** The
   real `Caddyfile`'s production ACME issuance cannot succeed for `.test`
   hostnames (a reserved, non-issuable TLD, confirmed by Caddy's own log:
   `contact email has invalid domain: Domain name does not end with a valid
   public suffix`), so the harness needs `local_certs` (Caddy's internal-CA
   mode) for its own run only. Putting that directive in an extra
   `snippets/*.caddy` file made Caddy fail every config reload with `server
   block without any key is global configuration, and if used, it must be
   first`, which crash-looped the container silently (curl only ever saw
   connection failures, not an error message). Fixed with a whole substitute
   entry file, `tests/integration/stubs/Caddyfile.test` — its only content is
   the `local_certs` block plus the exact same two `import` lines the real
   `Caddyfile` has; it changes no routing and duplicates no site/snippet
   logic.
4. **A bare failing test expression immediately before a helper call aborts
   the whole script under `set -e`, before the helper ever runs.** Early
   harness versions wrote `[ "$code" = "200" ] && [ "$lane" = "..." ]` directly
   followed by `check "..." $?` — this works only as long as the test is
   true; the first time it legitimately evaluated false (a real, intentional
   "this must now fail" assertion), the script exited immediately at the
   bare `[ ]`, before `check` could log anything, silently truncating the
   rest of the run. Fixed with an `assert` helper (`tests/integration/run.sh`)
   that evaluates the expression inside an `if`, so both true and false
   results reach `check` and get reported.

### What this harness does NOT prove

- Real DNS, TLS/ACME certificate issuance against public domains, or anything
  about the real `tapiz-edge`/`aura-edge` network names — this test
  deliberately uses distinct `-test`-suffixed names and `local_certs` so it
  can never collide with or be mistaken for a real activation.
- The real Tapiz/Aura applications' actual behavior — the stub upstreams only
  echo which lane answered a request; they run no business logic, no
  database, and are not the real `tapiz-lms`/`aura-beats` images.
- Anything about running this gateway and the real product stacks
  side-by-side on one host, multi-host behavior, or real production traffic
  volume — this is a routing/independence proof on one machine with synthetic
  stub upstreams, not a load test.
- Real GitHub Actions, VPS provisioning, DNS cutover, or any production
  secret — none of those are touched by this repository or this harness.

## Local integration test (disposable, real Tapiz LMS VPS stack)

`tests/integration/real-stack/` is a separate, later harness than the stub
harness above. Instead of fake Node stub upstreams, it brings up the **real**
Tapiz LMS VPS stack (real Postgres, real Valkey, real PgBouncer, the real
traffic-isolated `auth-api-1`/`auth-api-2`/`scan-api`/`general-api` lanes,
the real `worker`, the real `scheduler` — `apps/api/ops/vps/docker-compose.yml`,
referenced from a local `tapiz-lms` checkout, never copied) behind this same
repository's real, unmodified gateway config. See
`tests/integration/real-stack/README.md` for what it proves, exact run
commands, measured results, and the real bugs found and fixed while building
it.

```sh
sh tests/integration/real-stack/run.sh
```

## Local integration test (disposable, graceful reload proof)

`tests/integration/graceful-reload/` is a third, separate harness — later
than both the stub harness and the real-stack harness above. It reuses the
same real Tapiz LMS VPS stack bring-up as `tests/integration/real-stack/`
(with its own distinct disposable resource names, network
`tapiz-edge-reload-test`, ports `38080`/`38443`) behind this repository's
real gateway Caddy config, then proves that a live gateway serving continuous
real login + scan traffic:

1. Rejects a deliberately broken Caddy config via `caddy validate` in a
   throwaway container, before it ever reaches the running gateway process.
2. Keeps serving the currently-active config unaffected when a bad config is
   never given the chance to load.
3. Accepts a real, valid, harmless config change via `caddy reload` as a
   same-process operation (same container ID/`StartedAt`, never restarted),
   with zero dropped/failed requests across the whole reload window.
4. Never restarts any of the four real API lane containers as a side effect
   of the gateway-only reload.

See `tests/integration/graceful-reload/README.md` for the full design
rationale, exact commands, and measured results.

```sh
sh tests/integration/graceful-reload/run.sh
```

## Local integration test (disposable, failure isolation / chaos)

`tests/integration/chaos/` is a fourth, separate harness — later than the
stub, real-stack, and graceful-reload harnesses above. It reuses the same
real Tapiz LMS VPS stack bring-up as `tests/integration/real-stack/` (with
its own distinct disposable resource names, network `tapiz-edge-chaos-test`,
ports `48080`/`48443`), running alongside the existing fake Aura stub
(`tests/integration/docker-compose.aura-stub.yml`, read-only reference,
never copied or modified), both behind this repository's real gateway Caddy
config. It proves that Caddy's own existing `lb_policy round_robin` +
active health checks absorb a single auth replica restarting, and that
stopping the scan lane, the general lane, the Aura stub, or the entire Tapiz
stack each fails only that specific route (a clean `502`/`503`, never a
hang) while every unaffected lane/product keeps working normally, with full
recovery verified after each scenario. See
`tests/integration/chaos/README.md` for the full design rationale, exact
commands, and measured results.

```sh
sh tests/integration/chaos/run.sh
```

## Local integration test (disposable, scheduler/worker coexistence)

`tests/integration/scheduler-worker/` is a fifth, separate harness — later
than the stub, real-stack, graceful-reload, chaos, and backup-restore
harnesses above, and the final phase of this test suite. It reuses the same
real Tapiz LMS VPS stack bring-up as `tests/integration/real-stack/` (with
its own distinct disposable resource names, network
`tapiz-edge-scheduler-test`, ports `58080`/`58443`), seeded with a real demo
dataset via the product's own `seed-demo.ts` (same technique as
`tests/integration/backup-restore/`), then proves that the real `worker`
(background attendance/quiz flush timers) and the real `scheduler`
(authenticated cron-route caller) coexist correctly with sustained real
login/scan/general traffic: the scheduler's own job route
(`POST /api/attendance/flush`, `Authorization: Bearer $CRON_SECRET`) is
triggered directly and succeeds more than once while traffic and the worker
are both active, with measured PgBouncer/Postgres connection state and
Valkey memory/eviction numbers recorded before and after, and zero
starvation of the auth/scan lanes throughout. See
`tests/integration/scheduler-worker/README.md` for the exact trigger/
measurement mechanisms chosen and why, full measured results, and a real bug
found and fixed while building it.

```sh
sh tests/integration/scheduler-worker/run.sh
```

## Local integration test (disposable, real Boards VPS stack + independence)

`tests/integration/boards-real-stack/` is a sixth, separate harness — later
than the stub, real-stack, graceful-reload, chaos, backup-restore, and
scheduler-worker harnesses above, and the first to bring a third product
(Tapiz Boards) behind this gateway. It brings up the **real** Boards VPS
stack (`tapiz-boards/ops/vps/docker-compose.yml`, referenced from a local
`tapiz-boards` checkout, never copied — real PostgreSQL, the real migration
script, and the real production Next.js image built from the product's own
multi-stage `Dockerfile`) behind this repository's real, unmodified gateway
config (now including the new `sites/boards.caddy`), with the existing fake
Tapiz and Aura stubs (`../docker-compose.tapiz-stub.yml` /
`../docker-compose.aura-stub.yml`, read-only reference, never copied or
modified) running alongside it to prove independence in both directions.

Three tiers, kept explicit and never blurred:

- **(a) Proven by this local harness**: Boards' real app + real Postgres +
  real migration come up correctly behind this gateway's real, unmodified
  Caddy config; `GET /api/health` returns a real `200` through the gateway's
  test hostname; stopping Boards entirely leaves Tapiz+Aura (stub) routing
  unaffected; stopping Tapiz+Aura (stub) entirely leaves Boards unaffected;
  Boards publishes zero host ports at any point; a live `caddy reload`
  preserves the Boards route and leaves the gateway container's own process
  untouched.
- **(b) Requires a real test VPS, not proven here**: real DNS for a Boards
  hostname, real ACME/TLS issuance, multi-host behavior, Boards' actual
  production data or domain, and any real burst/load test of the Boards
  route through this shared gateway.
- **(c) Production-only, explicitly out of scope**: the real
  `tapiz-boards.vercel.app` Vercel deployment, the legacy Aiven MySQL
  rollback database, and any real cutover of Boards traffic. This harness
  never contacts any of these.

```sh
sh tests/integration/boards-real-stack/run.sh
# or, from a different tapiz-boards location:
BOARDS_DIR=/path/to/tapiz-boards sh tests/integration/boards-real-stack/run.sh
```

See `tests/integration/boards-real-stack/README.md` for the exact resource
names and full design rationale.

### Status: run on 2026-09-07 — 46/46 checks passed

Exit code `0`. Measured HTTP codes from an actual run:

| Check | Code |
|---|---|
| Baseline `GET /api/health` through the gateway (real Boards app) | `200` |
| Baseline Tapiz stub / Aura stub routing | `200` / `200` |
| Boards stopped: `api.boards-real.test` | `502` |
| Boards stopped: Tapiz stub / Aura stub (unaffected) | `200` / `200` |
| Boards recovered: `GET /api/health` | `200` |
| Tapiz+Aura stubs stopped: their own routes | `502` / `502` |
| Tapiz+Aura stubs stopped: Boards (unaffected) | `200` |
| Tapiz+Aura stubs recovered | `200` / `200` |
| Pre-reload Boards route | `200` |
| `caddy reload` (live gateway, config incl. `sites/boards.caddy`) | exit `0` |
| Post-reload Boards route, gateway container ID/`StartedAt` | `200`, unchanged |

Full pass list (46 checks): `caddy validate` + gateway compose config with 3
sites parse cleanly; disposable `.env.boards-real-stack` generated with
random-only local secrets; disposable `boards_edge`/Tapiz-stub/Aura-stub
networks created; real Boards Postgres healthy; real `npm run db:migrate`
applied the schema; real Boards app image built from the real, unmodified
multi-stage `Dockerfile` and reports healthy; Tapiz + Aura stubs started;
baseline routing for all three products; both independence directions
(Boards down / Tapiz+Aura down) with full recovery verified after each;
graceful reload preserves the Boards route and the gateway process identity;
no host port on any Boards/stub container at any point; only the gateway
container publishes host ports (`61080`/`61443`).

### Real bugs found and fixed while building this harness

1. **The real, unmodified `tapiz-boards/ops/vps/docker-compose.yml` joins
   `app` to `boards_edge` using the plain list form
   (`networks: [boards_internal, boards_edge]`), which gives it Compose's
   default network alias — the service name, `app` — not the
   product-prefixed `boards-app` alias this gateway's own "Product
   integration contract" (and `sites/boards.caddy`) expect.** A first run
   reproducibly got a real `503` from Caddy on every request to the Boards
   route, even long after the container itself reported Docker-healthy —
   confirmed via Caddy's own active health-check log line
   (`Get "http://boards-app:3004/api/health"` failing outright, since that
   hostname was never resolvable). Not a gateway config bug — the contract
   and `sites/boards.caddy` correctly anticipate a `boards-app` alias the
   same way Tapiz/Aura's real compose files already provide one, and this
   harness may not edit the real Boards compose file (read-only, per hard
   constraint). Fixed harness-side only, in
   `tests/integration/boards-real-stack/docker-compose.boards-harness-overrides.yml`,
   by re-declaring `app`'s `boards_edge` membership with an explicit
   `aliases: [boards-app]` via a `-f` override — Compose merges network
   attachments per-network-key, so this adds the alias without touching any
   other part of the real service definition.
2. **The real `tapiz-boards/ops/vps/docker-compose.yml` hardcodes
   `name: boards_edge` on its external network, with no
   `${BOARDS_EDGE_NETWORK:-...}`-style env var indirection at all** (unlike
   Tapiz's `${TAPIZ_EDGE_NETWORK:-tapiz-edge}` pattern every other
   real-stack-based harness's own disposable network name relies on) —
   confirmed by direct inspection. A disposable name like
   `boards-edge-real-test` would therefore never actually be read by
   Boards' own compose file. Fixed by using the literal `boards_edge` name
   for this harness's own disposable network too (still fully torn down by
   the `cleanup` trap every run, verified clean via `docker network ls`
   before and after) — documented as a deviation from every other harness's
   "always a distinct disposable name" convention, forced by the real
   product file rather than a choice.
3. **Docker rejects host ports above 65535** (`invalid hostPort: 68080`) —
   an early draft picked `68080`/`68443` to extend the existing port-pair
   pattern (`18080`, `28080`, `38080`, `48080`, `58080`, ...); `68080`
   exceeds the valid TCP port range. Fixed by using `61080`/`61443`
   instead — still distinct from every other harness's pair, still a valid
   port.
4. No other new Docker/Compose/Caddy bugs distinct from the ones already
   documented in the other harnesses' own READMEs were hit — this harness
   reuses the same disposable-`.env`/`assert`/`!override`/`local_certs`
   patterns and inherits those fixes.

## Future VPS activation

This repository is configuration only. Actual VPS activation requires a
separate approved change, in this order:

1. Create the two real edge networks (`tapiz-edge`, `aura-edge`) on the VPS
   host — external, not managed by any product's or this gateway's Compose
   file.
2. Confirm Tapiz's `apps/api/ops/vps/docker-compose.yml` and Aura's
   `ops/production/docker-compose.yml` are both already prepared for this
   (they are, as of Tapiz `dev` and Aura `main` at the commits this harness
   was verified against — each product's four/two HTTP lanes already declare
   the external edge network + product-prefixed aliases this gateway's
   `sites/*.caddy` expects, and each product's own Caddy container is already
   behind a `standalone-ingress` profile, not started by default).
3. Bring up each product's stack (its real lanes join the real edge networks
   at this point) without its own `standalone-ingress` Caddy profile.
4. Start this gateway (`docker compose up -d` from this repository, real
   `.env` with real `TAPIZ_API_DOMAIN`/`AURA_API_DOMAIN` values, real
   `CADDY_EMAIL`) — this is the point real ACME issuance is first attempted,
   against real public DNS records that must already resolve to this host.
5. Validate each public hostname end-to-end (login, QR scan, general API for
   Tapiz; API and HLS delivery for Aura) before treating either as cut over.
6. Only after both are confirmed working through this gateway, decommission
   any product-level Caddy container/DNS record that previously served that
   traffic directly.

**What remains before this can safely happen, beyond what this harness
proved**: real DNS records for both hostnames pointed at the target VPS;
real ACME reachability confirmed from that host (port 80/443 outbound and
inbound firewall rules); confirmation that no other process on the target
host already binds 80/443 (this repository's own README already states the
single-shared-ingress constraint); a real burst/load test of Tapiz's login
lane through this gateway specifically (the existing `apps/api/ops/vps/
loadtest/` harness measured the login-lane CPU ceiling against Tapiz's own
product-level Caddy, not through this shared gateway — the path is
architecturally identical, but has not itself been re-measured through this
gateway's specific process/config); and Danijel's explicit approval, per the
standing rule that no real VPS/DNS/production change happens without it. Do
not perform the numbered steps above against a real host merely by following
this document.
