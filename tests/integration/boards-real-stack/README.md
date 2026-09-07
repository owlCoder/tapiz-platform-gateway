# Sixth integration harness — real Boards VPS stack + independence

This is a **separate, later** harness than `../run.sh` (stub), `../real-stack/`
(Phase 1), `../graceful-reload/` (Phase 2), `../chaos/` (Phase 3),
`../backup-restore/`, and `../scheduler-worker/`. It does not modify or
depend on any of them, and none of them are modified by it. It is the first
harness to bring a **third product** (Tapiz Boards) behind this gateway.

## What this proves

Against this repository's real, unmodified `Caddyfile`/`sites/*.caddy`
(including the new `sites/boards.caddy` this task adds)/`snippets/*.caddy`/
`docker-compose.yml` (now with a third `boards_edge` network):

1. The real Boards VPS stack (`tapiz-boards/ops/vps/docker-compose.yml`,
   referenced from a local `tapiz-boards` checkout, never copied — real
   PostgreSQL, the real `npm run db:migrate` migration, the real production
   Next.js image built from the product's own multi-stage `Dockerfile`)
   comes up healthy behind the real central gateway.
2. `GET /api/health` reaches the real Boards app through the gateway's test
   hostname with a real `200`.
3. Stopping Boards entirely leaves Tapiz and Aura routing/health completely
   unaffected (using the existing fake stubs for both, not the full real
   Tapiz stack — Tapiz/Aura independence from each other is already proven
   by the first five harnesses; this harness's job is proving **Boards'**
   independence specifically, so fast fake stubs for the other two products
   are sufficient here).
4. Stopping Tapiz + Aura (stubs) entirely leaves Boards routing/health
   completely unaffected.
5. Boards publishes zero host ports at any point in the stack's lifecycle.
6. A live `caddy reload` (the same `docker compose exec caddy caddy reload
   --config /etc/caddy/Caddyfile --adapter caddyfile` mechanism
   `../graceful-reload/run.sh` already proved works generically) preserves
   the Boards route and leaves the gateway container's own ID/`StartedAt`
   unchanged — this harness does not re-prove the full reload-safety
   mechanism (background traffic continuity, bad-config rejection), only
   that Boards' specific route survives a reload too.

## Three tiers — proven / real-VPS-required / production-only (never blurred)

- **(a) Proven by this local harness**: everything in "What this proves"
  above — all on local Docker, disposable resources only.
- **(b) Requires a real test VPS, not proven here**: real DNS for a Boards
  hostname, real ACME/TLS certificate issuance, multi-host behavior, Boards'
  actual production data or domain, and any real burst/load test of the
  Boards route specifically through this shared gateway.
- **(c) Production-only, explicitly out of scope**: the real
  `tapiz-boards.vercel.app` Vercel deployment, the legacy Aiven MySQL
  rollback database, and any real cutover of Boards traffic to this gateway.
  This harness never contacts any of these — Boards' own `.env`/`.env.vercel`
  are never read; only `.env.test`/`.env.example` are used as references for
  which keys exist, and every secret in the generated `.env.boards-real-stack`
  is freshly randomized via `/dev/urandom`.

## Why fake Tapiz/Aura stubs, not the full real Tapiz stack

`../chaos/run.sh` already proves Tapiz's own real stack fails/recovers
independently of a stub Aura. Bringing up the full real Tapiz stack again
here (Postgres/Valkey/PgBouncer/4 lanes/worker/scheduler, several more
minutes of build+wait time) would add cost without adding proof: this
harness's actual claim is that **Boards** is independent of its neighbors,
which the existing `docker-compose.tapiz-stub.yml` (4 lanes) and
`docker-compose.aura-stub.yml` (2 lanes) — both read-only references, never
copied or modified — already exercise correctly as "some other product is
up/down" fixtures.

## Why a dedicated `docker-compose.boards-harness-overrides.yml`, not the real repo's own `docker-compose.test.yml`

`tapiz-boards/ops/vps/docker-compose.test.yml` bundles the `migrate`/`smoke`
one-shot services together with an `app.ports` override
(`127.0.0.1:13004:3004`, loopback-only). This task's hard constraint is that
Boards never publishes **any** host port, not even loopback-only, so that
file cannot be used as-is via `-f` (it would publish `app`'s port
regardless of whether `smoke`/`migrate` are even invoked, since Compose
merges all services declared in every `-f` file). This harness's own
`docker-compose.boards-harness-overrides.yml` duplicates only the `migrate`
service definition (identical `build`/`command`/`environment`/`networks`
shape) with no `app` port override anywhere. It no longer carries any
network-alias override — the real Boards compose file now declares
`boards-app` as an explicit alias itself (see "History: bugs found and
fixed at the source" below).

## Why no `<PRODUCT>_ENV_FILE` export is needed here (checked, not assumed)

Every real-stack-based Tapiz harness (`real-stack`, `graceful-reload`,
`chaos`, `scheduler-worker`) must `export TAPIZ_ENV_FILE="$<disposable-env>"`
before calling `docker compose`, because the real Tapiz LMS compose file
declares `env_file: ${TAPIZ_ENV_FILE:-.env}` on its services — and
`--env-file` only controls Compose's own variable interpolation, not which
file a service's own `env_file:` key loads (see `../real-stack/run.sh`'s own
comment on this, commit `cf56c78`).

`tapiz-boards/ops/vps/docker-compose.yml` was checked directly and declares
**no `env_file:` key anywhere** — every service only uses `environment:`
blocks with `${VAR}` interpolation, which Compose's own `--env-file`
resolves directly. This harness therefore only needs `--env-file
"$BOARDS_ENV"` on every `docker compose` invocation; no extra export is
required or added. Documented here so a future harness change doesn't have
to re-verify this from scratch.

## Distinct disposable resource names (never collide with any other harness)

| Resource | This harness |
|---|---|
| Boards edge network | `boards-edge-real-stack-test` |
| Tapiz stub edge network | `tapiz-edge-boards-test` |
| Aura stub edge network | `aura-edge-boards-test` |
| Boards hostname | `api.boards-real.test` |
| Tapiz stub hostname | `api.tapiz-boards-test.test` |
| Aura stub hostname | `api.aura-boards-test.test` |
| Gateway ports | `61080`/`61443` (never used by any other harness: stub `18080`/`18443`, real-stack `28080`/`28443`, graceful-reload `38080`/`38443`, chaos `48080`/`48443`, scheduler-worker `58080`/`58443`) |
| Boards compose project | `tapiz-boards-real-stack-test` |
| Gateway compose project | `platform-gateway-boards-test` |
| Tapiz stub compose project | `gateway-boards-test-tapiz-stub` |
| Aura stub compose project | `gateway-boards-test-aura-stub` |

## Files

- `run.sh` — the harness script.
- `docker-compose.gateway-boards-test-ports.yml` — overrides the gateway's
  real `docker-compose.yml` `caddy` service's `ports:`/`volumes:` to bind
  `61080`/`61443` and load a test-only Caddyfile entry point, using
  `!override` for both keys and repo-root-relative paths (same two lessons
  every prior harness already documented, reused rather than rediscovered).
- `Caddyfile.boards-real-stack.test` — a whole substitute Caddy entry file
  (not an extra `snippets/*.caddy` file), whose only content beyond the real
  `import` lines is a `local_certs` global option — `.test` is a reserved,
  non-issuable TLD.
- `docker-compose.boards-harness-overrides.yml` — a one-shot `migrate`
  service (profile `migrate`) added to the real Boards compose file via
  `-f`; see "Why a dedicated docker-compose.boards-harness-overrides.yml"
  above.

## Running it

Requires a local `tapiz-boards` checkout. Defaults to
`~/Desktop/tapiz/tapiz-boards` (this machine's actual layout); override with
`BOARDS_DIR` if different.

```sh
sh tests/integration/boards-real-stack/run.sh
# or, from a different tapiz-boards location:
BOARDS_DIR=/path/to/tapiz-boards sh tests/integration/boards-real-stack/run.sh
```

Full teardown runs automatically on exit, success or failure.

## Status

See the repository root `README.md`'s Boards section for exact pass/fail
counts, measured HTTP codes, and the full real-bugs writeup from an actual
run — kept there rather than duplicated in two places, since the root
README already distinguishes the three proof tiers for Boards. Summary: 46
checks passed on 2026-09-07 (exit code `0`).

## History: bugs found and fixed at the source

Full detail (including the exact reproduction) lives in the repository root
`README.md`'s Boards section. Summary:

1. The real Boards compose file originally gave `app` Compose's default
   network alias (`app`) on `boards_edge`, not the product-prefixed
   `boards-app` alias `sites/boards.caddy` expects. Originally worked around
   with a harness-side `-f` override; **fixed at the source** in
   `tapiz-boards/ops/vps/docker-compose.yml`, which now declares
   `aliases: [boards-app]` on `app`'s `boards_edge` network entry directly.
   The harness-side override no longer exists.
2. The real Boards compose file originally hardcoded `name: boards_edge`
   with no env var override, forcing this harness's own disposable network
   to also be named literally `boards_edge` (a documented deviation from the
   "always-distinct-name" convention every other harness follows). **Fixed
   at the source**: the real compose file now declares
   `name: ${BOARDS_EDGE_NETWORK:-boards_edge}`, so this harness passes its
   own genuinely distinct `boards-edge-real-stack-test` name via the
   generated `$BOARDS_ENV` file, with the real default preserved for
   production use when the var is unset.
3. `68080`/`68443` (an early port-pair choice extending the existing
   pattern) exceeds the valid TCP port range — fixed by using `61080`/`61443`.
   This one remains a harness-only quirk, not a real-repo issue.

## What this harness does NOT prove

Same boundaries as every other real-stack-based harness in this repository,
plus:

- Real DNS, TLS/ACME issuance, or multi-host behavior. The Boards edge
  network is now a genuinely distinct, disposable name
  (`boards-edge-real-stack-test`, see "Distinct disposable resource names"
  above) like every other resource this harness creates — no exception to
  the naming convention remains (see "History: bugs found and fixed at the
  source" above).
- The real `tapiz-boards.vercel.app` deployment, the Aiven MySQL rollback
  database, or any real cutover — never touched by this harness.
- Full reload-safety mechanics (background traffic continuity across a
  reload window, rejection of a deliberately broken config) — already
  proven generically by `../graceful-reload/run.sh`; this harness only
  confirms Boards' specific route survives a reload too.
- Backup/restore or scheduler/worker-style background-job coexistence —
  Boards has no scheduler/worker process of its own; not applicable.
- Any load/burst behavior against the Boards route through this gateway.
