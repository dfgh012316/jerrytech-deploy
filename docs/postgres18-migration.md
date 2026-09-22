# PostgreSQL 15 → 18 and `shared` namespace

During cutover, use a new StatefulSet and PVC in `shared` and keep the original
`postgres` namespace and PVC intact. The manifest in `bootstrap/postgres/postgres.yaml`
creates the destination. Applying it alone does not migrate data or switch apps.

## Verified outcome (2026-09-23, Asia/Taipei)

- Upgraded the live ARM64 server from PG15.10 to PG18.6 (`18.6-bookworm`).
- `shared/postgres` serves both apps via `postgres.shared.svc`. Both
  `common-config` ConfigMaps and app Secret connection URLs were switched.
- After stopping writers, final restore verification matched all 2 `popo` tables
  and 6 `slipbox` tables by row count and content hash, plus sequences and database
  ACLs. Both app credentials work and cross-database CONNECT remains denied.
- Both app deployments became Ready; direct Service `/readyz` checks returned
  `{"checks":{"db":"ok"},"status":"ok"}`. PG18 showed each app's expected role.
- The old StatefulSet and PVC were initially retained after cutover. After a
  subsequent health check and operator-approved cleanup, the old StatefulSet,
  PVC, PV and its 71MiB directory were deleted. The old PV's policy was changed
  to `Delete` so local-path-provisioner removed the directory when the PVC was
  deleted; directory absence was verified. The `shared` PV remains `Retain`.
  The old `postgres` namespace's Service and Secret remain; no old DB pod or
  volume remains.
- Reconcile scheduling and the Actions runner were restored after validation.
- Final dumps remain in `~/postgres18-migration/final` on the Pi, with cutover
  configuration snapshots in its protected parent directory. An authorized copy
  is stored at `/tmp/jerrytech-postgres18-backup/final.tar.gz` on the operator
  workstation (directory `0700`, archive `0600`). `/tmp` is temporary storage,
  not the long-term backup destination.

The first image pull timed out over IPv6; the Pi's automatic retry succeeded.
No host network settings were changed. Ignore terminal `Succeeded`/`Failed`
historical Job pods when waiting for writers to stop: old reconcile pods share
the app label but cannot write. Separately verify no active Jobs or DB sessions.

## Before cutover

1. Check the live server version, databases, extensions, roles, locale, data size,
   free disk and memory. Both old and new servers must fit on the same Pi.
2. Create `shared` and copy `postgres-secrets` through the Kubernetes API without
   displaying its data or committing it. Create only the new manifest's resources.
3. Wait for PG18 readiness, then set its bound PV reclaim policy to `Retain`.
4. In a directory with mode `0700` and files with mode `0600`, save
   `pg_dumpall --globals-only` and `pg_dump -Fc --create` for each business database.
   The globals dump contains password hashes and must be treated as a secret.
5. Restore globals with `psql -X -v ON_ERROR_STOP=1`; omit only the existing
   `CREATE ROLE postgres;` statement, retaining its `ALTER ROLE` settings.
   Restore each database with `pg_restore --exit-on-error --create -d postgres`.
   Dump clients must not be older than the source server; the target-major client
   is preferred. PG15 logical dumps can be restored by PG18.
6. Run `vacuumdb --analyze-in-stages`. Compare table counts and content, sequences,
   database owners and ACLs. Test the apps' actual credentials against the new
   server, including rejection of access to the other app's database.

The business databases are `popo` (`popo_app`) and `slipbox` (`slipkit_app`).
Both use UTF8 and `en_US.utf8` and have only the built-in `plpgsql` extension
(verified on the source during this migration). Recheck before future upgrades.

## Cutover during the agreed maintenance window

1. Save the current app replica counts, CronJob suspend state, ConfigMaps and
   Secrets to the protected backup directory. Suspend deployment automation for
   the maintenance window so it cannot restart writers unexpectedly.
2. Suspend `popo/popofinder-reconcile`; ensure no reconcile Job is active.
   Scale `popo/popofinder` and `slipkit/slipkit` to zero and wait for their pods to
   terminate. Verify the old database has no remaining application sessions or
   other writers before taking the final dump.
3. Take fresh final dumps, including globals. Preserve these separately from the
   rehearsal and copy a backup off the Pi to an explicitly authorized destination.
   Replace only the destination's rehearsal
   business databases, restore the final dumps, analyze and rerun comparisons.
4. Update `DB_HOST` in each app namespace's `common-config` to
   `postgres.shared.svc`. Also inspect app Secrets for `DATABASE_URL` and `DB_HOST`:
   Secret values can override the ConfigMap and migration init containers use
   `DATABASE_URL` directly. Preserve the URL's credentials, database and query
   parameters, including `sslmode=disable`.
5. Restore app replica counts. Verify migrations complete, pods become Ready,
   `/readyz` succeeds, and PG18 sees connections from each app's expected role.
   Restore the CronJob's original suspend state and deployment automation.
6. Scale the old PG15 StatefulSet to zero. Keep its namespace, PVC and retained PV
   until the retention decision is made; do not delete them as part of cutover.
7. Change `bootstrap/common-config/common-config.yaml` and its README to the new
   hostname only when cutover is performed, and record the verified outcome.

## Rollback boundary

Before production writes reach PG18, the old PG15 database is the rollback source:
restore the saved connection settings and original app/CronJob states, using only
the old database. Never run both databases as active writers for the same app.

Once PG18 accepts production writes, simply switching back loses those writes.
Stop writers and plan data reconciliation/recovery before any rollback. Keep
backups and the old PVC even after readiness checks pass.

Retire the old PVC only after an explicit cleanup decision, renewed application
health checks, and verification of retained backups. For this migration, SHA-256
hashes of all three final dump files matched between the Pi and the authorized
workstation archive before cleanup. Deleting only a `Retain` PV object would
leave its local directory behind; verify the storage directory is actually gone.

## References

- [PostgreSQL major upgrades](https://www.postgresql.org/docs/18/upgrading.html)
- [Official image storage layout](https://hub.docker.com/_/postgres)
