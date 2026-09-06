# Phase 4 local PostgreSQL backup/restore drill

This is a **separate, later** harness than `../run.sh` (fake-stub),
`../real-stack/run.sh` (Phase 1), `../graceful-reload/run.sh` (Phase 2), and
`../chaos/run.sh` (Phase 3). It does not modify or depend on any of them, and
none of them are modified by it.

## What this proves, vs. the earlier harnesses

The other three harnesses prove routing, reload, and failure-isolation
behavior of the gateway in front of the real Tapiz stack. None of them touch
backup/restore. This harness does not start the gateway or the full API
stack (auth/scan/general lanes, worker, scheduler, PgBouncer) at all — that
routing/failover behavior is already proven elsewhere. Its scope is narrowly
**data integrity across a real `pg_dump`/`pg_restore` cycle**, mirroring the
spirit (not the exact commands — see below) of
`tapiz-lms/apps/api/ops/vps/BACKUP-RESTORE-RUNBOOK.md`'s real production
runbook, entirely on disposable local Docker Postgres:

1. Bring up ONE disposable source Postgres (the real Tapiz VPS compose
   file's own `postgres` service, referenced via `-f`, never copied) and
   apply the Drizzle schema (same one-shot schema-push pattern the other
   three harnesses use).
2. Seed a modest, real demo dataset via the product's own
   `apps/api/scripts/seed-demo.ts` (`npm run seed:demo`) — reused as-is,
   never reimplemented as ad hoc SQL. Record the table list, per-table row
   counts, and current sequence values.
3. Run a real `pg_dump` (custom format, `-Fc`) from inside the source
   Postgres container to a scratch file on the host.
4. Bring up a SECOND, entirely separate disposable Postgres (fresh empty
   volume, its own project/network — never reusing the source's) and
   `pg_restore` the dump into it.
5. Verify against the restored instance: same table list, same per-table row
   counts, same sequence values — actual numbers printed both times, not
   just a pass/fail boolean.
6. Bring up `general-api` pointed **directly** at the restored Postgres (no
   PgBouncer) and fire one real request through it (bogus-credentials login
   -> real `401`) as the API-smoke-test proof.
7. Full teardown of everything on exit, success or failure.

## Why this is not a literal re-run of the production runbook

`BACKUP-RESTORE-RUNBOOK.md` is an explicit plan for a real, two-pass
production cutover (AD Sistem Postgres -> new VPS), gated on Danijel's
approval and never executed by this or any other repository. This harness
does **not** touch AD Sistem, Aiven, or any real host — it mirrors the
runbook's underlying mechanics that generalize safely to a disposable local
drill (logical dump, restore into a fresh instance, verify table/row/sequence
counts before trusting the restore, smoke-test the app against the restored
data) without any of the runbook's production-specific concerns (two-pass
dump timing, write-freeze, external side-effect blocking, DNS cutover,
rollback window). Those remain exactly what the runbook says they are: a
separate, later, explicitly-approved production procedure, not something a
local Docker drill can or should stand in for.

## Seeding approach: seed-demo.ts, not manual INSERTs

`apps/api/scripts/seed-demo.ts` (`npm run seed:demo`) was used as-is rather
than writing manual SQL `INSERT`s, because it already produces a realistic,
idempotent, multi-table dataset with real FK chains (institution hierarchy,
2 assistants, 1 faculty manager, 24 students, 2 subjects, 48 enrollments, 10
sessions, 164 attendance rows, 2 score sheets with columns/rows/cells) — a
stronger proof that dump/restore preserves referential integrity across a
realistic schema than a handful of INSERTs into 2-3 tables would be. It is
also the product's own tool, so this drill exercises the same insert paths a
real developer/E2E run does, rather than a parallel implementation that could
drift from the real schema over time.

### Satisfying `checkSeedTarget` without weakening it

`seed-demo.ts`'s own guard (`apps/api/src/shared/seedTarget.ts`,
`checkSeedTarget`) is allow-list, not deny-list: it refuses to run unless
`NODE_ENV != production` **and** the `DB_HOST`/`DATABASE_URL` hostname it
sees matches `localhost|127.0.0.1|host.docker.internal` or a whole-word
`dev|development|staging|test`. The disposable `postgres` service's own
Docker-network hostname (`postgres`) matches neither pattern, so this harness
adds one **network alias** to it — `postgres-test` — via
`docker-compose.postgres-alias.yml`, and points the seed job's `DB_HOST` at
that alias instead of `postgres`. This satisfies the guard's `DEV_PATTERN`
legitimately (a real dev/test-named host) rather than weakening or bypassing
the guard itself, which stays completely untouched — exactly the same kind
of check `../real-stack/README.md` already confirmed the script has no other
guard around when it considered (and skipped) seeding for Phase 1.

## Smoke-test connectivity: container-to-container, not a loopback host port

The task's hard constraints permit a `127.0.0.1`-only loopback host port on
the smoke-test API container as a narrow exception, but this harness does
not use it: a throwaway `curlimages/curl:8.11.1` container attached to the
same `restored` private bridge network as `general-api-restored` reaches it
directly by its Compose-assigned DNS name (`general-api-restored:3001`), with
**zero** host ports published anywhere in this harness. This is strictly
narrower than the permitted loopback-bind exception, and no harder to set up
here since both containers already share the same private network — so the
narrower option was used instead of reaching for the permitted exception.

## Real bugs found and fixed while building this harness

1. **`postgres:18+` images require the data volume mounted at
   `/var/lib/postgresql`, not `/var/lib/postgresql/data`.** The first
   version of `docker-compose.restored-postgres.yml` mounted
   `postgres_restored_data:/var/lib/postgresql/data` (a natural-looking
   choice) and the container came up but never passed its healthcheck;
   `docker logs` showed the entrypoint refusing to start with "PostgreSQL
   data in: /var/lib/postgresql/data (unused mount/volume)" — Postgres 18's
   images use a `pg_ctlcluster`-compatible, major-version-specific
   subdirectory layout under a single parent mount. Fixed by mounting at
   `/var/lib/postgresql` instead, matching the real Tapiz compose file's own
   `postgres` service exactly (`apps/api/ops/vps/docker-compose.yml`:
   `postgres_data:/var/lib/postgresql`) — confirmed by direct reproduction
   (`docker logs` before and after the fix) rather than assumed from the
   real compose file alone.
2. **A `name=value` substring extraction collides when one table name is a
   substring of another.** An early version of this script accumulated row
   counts as a flat `name=count;` string and extracted a given table's count
   with `grep -o "$t=[0-9]*"`, with no word-boundary anchor. `student_subjects`
   contains the literal substring `subjects=`, so looking up `subjects` also
   matched the tail end of the `student_subjects=48` entry, producing a
   garbled `before=2\n48 after=2\n48` line and a false-positive
   row-count-mismatch failure on a restore that had actually succeeded
   perfectly (confirmed: the raw psql counts printed just above it were
   already correct and identical, 2 and 2 for `subjects`). Fixed by prefixing
   every accumulator entry with a leading `;` and extracting via
   `grep -oE ";$name=[0-9]+"` (anchored on the leading `;` as a whole-token
   boundary) through a small `row_count_of()` helper, reused for every
   before/after/summary lookup instead of three separate ad hoc `grep`
   one-liners.

No other new Docker/Compose bugs distinct from the ones already documented in
`../real-stack/README.md` (workspace-root `npm ci`, shadowed `node_modules`
volumes to avoid `EROFS`) were hit — this harness reuses that same
schema-push pattern and inherits those fixes.

## Running it

Requires a local `tapiz-lms` checkout, same override as the other three
harnesses. Defaults to `~/Desktop/tapiz/tapiz-lms`; override with
`TAPIZ_LMS_DIR` if different.

```sh
sh tests/integration/backup-restore/run.sh
# or, from a different tapiz-lms location:
TAPIZ_LMS_DIR=/path/to/tapiz-lms sh tests/integration/backup-restore/run.sh
```

Takes roughly 2-3 minutes end to end (schema push + seed's own `npm ci`
inside throwaway containers, plus one Docker image build for
`general-api-restored`, are the slowest steps). Full teardown runs
automatically on exit, success or failure.

## Status: run on 2026-09-07 — 29/29 checks passed

Exit code `0`. Full measured pre-dump vs. post-restore numbers from an actual
run:

| Table | Before (pre-dump) | After (post-restore) |
|---|---|---|
| `universities` | 1 | 1 |
| `faculties` | 1 | 1 |
| `departments` | 1 | 1 |
| `study_programs` | 1 | 1 |
| `assistants` | 2 | 2 |
| `students` | 24 | 24 |
| `faculty_managers` | 1 | 1 |
| `subjects` | 2 | 2 |
| `sessions` | 10 | 10 |
| `student_subjects` | 48 | 48 |
| `attendances` | 164 | 164 |
| `score_sheets` | 2 | 2 |
| `score_columns` | 8 | 8 |
| `score_rows` | 48 | 48 |
| `score_cells` | 144 | 144 |

Table count (public schema): 123 before, 123 after — table list byte-for-byte
identical. Sequence values: `students_id_seq` 24 -> 24, `subjects_id_seq` 2
-> 2, `attendances_id_seq` 164 -> 164. Dump file: 520,040 bytes (custom
format, `-Fc`). API smoke test: `POST /api/auth/login` with bogus credentials
against `general-api-restored` (pointed directly at the restored Postgres, no
PgBouncer) returned a real `401`.

Full pass list (29 checks): `caddy validate` sanity check; disposable `.env`
generated for the source Postgres; unused-but-required external
`tapiz_edge` network created (the real compose file declares it external;
never actually routed to in this phase); source Postgres started and
healthy; Drizzle schema pushed; `seed-demo.ts` populated the dataset; table
list/row counts/sequence values recorded pre-dump (with explicit nonzero
assertions for `students`/`subjects`/`attendances` and a sequence-advanced
assertion for `students_id_seq`); `pg_dump` ran and produced a nonempty dump
file; a second, separate disposable Postgres started and healthy; `pg_restore`
ran; restored table list matches byte-for-byte; every sampled table's row
count matches exactly; every sampled sequence's `last_value` matches exactly;
`general-api-restored` built, started, healthy, and returned a real `401`
proving real query execution against the restored data; no host port
published by either Postgres instance or `general-api-restored`.

## What this harness does NOT prove

Same boundaries as `../real-stack/README.md`, `../graceful-reload/README.md`,
and `../chaos/README.md`, plus:

- Anything about `BACKUP-RESTORE-RUNBOOK.md`'s actual production cutover —
  two-pass dump timing, write-freeze mechanics, external side-effect
  blocking (mail/billing/storage), DNS cutover, or the rollback window. This
  harness only proves the underlying dump/restore/verify mechanics work
  correctly on disposable local Postgres; the production runbook remains a
  separate, later, explicitly-approved procedure.
- Valkey backup/restore (RDB/AOF export) — the runbook's Pass 2 covers this
  for the real cutover; this harness never starts Valkey at all, since
  neither the schema push nor the seed script nor the smoke-tested
  `general-api-restored` route touches it (`DISABLE_BACKGROUND_WORKERS=true`
  keeps flush timers, the only Valkey-touching code path in this drill's
  scope, from ever running).
- PgBouncer-fronted connectivity to the restored database — the smoke test
  connects `general-api-restored` directly to `postgres-restored`, which is
  simpler and sufficient for a single-request proof of real query execution;
  PgBouncer's own behavior is already covered by the other three harnesses'
  real-stack bring-up.
- Backup/restore under concurrent write load, a much larger dataset, or
  `pg_dump`'s parallel-jobs mode — this is a correctness drill on a modest,
  realistic-shaped dataset (123 tables, low hundreds of rows), not a
  performance/scale test.
- Scheduler/worker coexistence under load — explicitly out of scope for
  Phase 4 (Phase 5, per the parent task's own instruction, not attempted
  here).
