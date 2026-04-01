# Architecture Decisions

This document records significant design decisions made during the development of the Azure Backup Vault restore automation. Each entry includes the context, the decision, and the rationale so it can be revisited if requirements change.

---

## ADR-001: High Availability disabled on restored Postgres server

**Date:** 2026-03-11
**Status:** Accepted

**Context:**
The source Postgres Flexible Server uses ZoneRedundant HA, which provisions a standby replica in a secondary availability zone.

**Decision:**
The restored server is created with `--high-availability Disabled`.

**Rationale:**
- The restored server is a DR artefact used for validation and point-in-time recovery, not a production workload.
- ZoneRedundant HA approximately doubles the compute cost and extends provisioning time.
- HA can be re-enabled on the restored server manually post-creation if a long-lived production-grade environment is required.

---

## ADR-002: Restore storage account hardcoded in pipeline variables

**Date:** 2026-03-11
**Status:** Accepted

**Context:**
Earlier pipeline versions accepted `targetStorageAccount` as a user-supplied parameter, allowing any storage account to be targeted.

**Decision:**
The restore storage account name is hardcoded as a `variables:` entry (`cnpRestoreStorageAccount` / `cppRestoreStorageAccount`) in each pipeline file. Users cannot override it at queue time.

**Rationale:**
- Restricts blob restore output to the pre-provisioned, access-controlled storage account created by the Terraform module.
- Prevents accidental (or malicious) redirection of restore output to an uncontrolled account.
- Aligns with audit requirements: all restores are traceable to a single known location.

---

## ADR-003: Restore container name auto-generated, not user-supplied

**Date:** 2026-03-11
**Status:** Accepted

**Context:**
Earlier pipeline versions accepted `targetStorageContainer` as a user-supplied parameter, risking name collisions between concurrent runs and requiring manual coordination.

**Decision:**
The container name is generated in Stage 1 as `<serverSlug><timestamp><buildId>` (e.g. `plumv14flexiblesandbox104881520260313`) and passed to Stage 2 via a pipeline output variable. Separators are omitted because Azure Storage container names may only contain lowercase letters, digits, and hyphens — slugified server names already contain no hyphens, so concatenation is safe without post-processing.

**Rationale:**
- Guarantees uniqueness across concurrent pipeline runs (build ID is unique per run).
- Provides traceability: the container name encodes the source server, time, and build of restore.
- Removes a potential operator error vector.
- Separator-free format avoids Azure Storage character-set edge cases.

---

## ADR-004: Restored server placed in same resource group as source

**Date:** 2026-03-11
**Status:** Accepted

**Context:**
The pipeline could create the restored server in a separate resource group, but this requires additional parameters and permissions.

**Decision:**
The restored server is created in the same resource group as the source server (`sourceResourceGroup`).

**Rationale:**
- Reuses existing VNet/subnet delegation and private DNS zone permissions that are already in scope for that resource group.
- Minimises the number of pipeline parameters required.
- If isolation is needed in future, a `restoredServerResourceGroup` parameter can be added.

---

## ADR-005: restoreMode parameter controls restore scope

**Date:** 2026-03-11
**Updated:** 2026-03-12
**Status:** Accepted

**Context:**
The restore pipelines need to support partial runs: vault-to-storage only (without triggering a DB restore), database-only (re-running the DB restore from an existing blob container without re-triggering vault restore), and the default full end-to-end restore.

**Decision:**
Both pipelines expose a `restoreMode` string parameter with three values:

| Value | Vault restore | DB restore | Stage 3 validate |
|-------|--------------|------------|-----------------|
| `all` (default) | ✅ | ✅ | ✅ |
| `vault-only` | ✅ | ❌ | ❌ |
| `database-only` | ❌ | ✅ | ✅ |

- `vault-only` skips `createPostgresServer` (Stage 1), skips the DB restore phase (Stage 2 script early-returns), and skips Stage 3 entirely.
- `database-only` requires `existingRestoreContainer` to be supplied; Stage 1 passes it through directly instead of creating a new container. The vault restore phase in the script is skipped. Metrics are written without vault fields.
- `dryRun` is orthogonal to `restoreMode`; it gates all mutations regardless of scope.

The script reads `RESTORE_MODE` (default `all`) as `restore_scope` and gates vault/DB sections accordingly.

**Rationale:**
- Enables re-running just the DB restore step after a vault restore completes (e.g. to retry with different parameters or after a Postgres server issue).
- Enables smoke-testing the vault restore path without provisioning a Postgres server.
- Keeps a single script and single pipeline parameter surface rather than separate pipelines.

---

## ADR-006: No teardown of restored server or container

**Date:** 2026-03-11
**Status:** Accepted

**Context:**
In a test-only scenario a teardown stage (delete server + container) would be appropriate.

**Decision:**
No teardown stage is included in the pipeline.

**Rationale:**
- The restored server is a DR artefact intended for post-restore inspection and sign-off.
- The restore container is retained for audit/evidence purposes.
- Automated teardown of database servers carries significant risk and should be a deliberate manual action.

---

## ADR-007: Validate stage skipped on dry run

**Date:** 2026-03-11
**Status:** Accepted

**Context:**
The `dryRun` parameter gates all mutating operations in Stages 1 and 2. Stage 3 (Validate) connects to the restored server to query its content. If `dryRun=true`, no server is created so there is nothing to validate.

**Decision:**
Stage 3 runs only when `dryRun=false`. Both pipelines use the compile-time expansion form `eq('${{ parameters.dryRun }}', 'false')` because `condition:` expressions are evaluated at runtime by the ADO agent, which has no access to the `parameters` context — that context only exists during YAML template expansion.

**Rationale:**
- There is no meaningful validation to perform if no server was provisioned.
- Avoids a spurious connection failure polluting the pipeline run log.

---

## ADR-008: Azure-managed system databases skipped during restore

**Date:** 2026-03-17
**Status:** Accepted

**Context:**
Azure Backup Vault produces dump files for every database on the source PostgreSQL Flexible Server, including `postgres`, `azure_maintenance`, and `azure_sys`. These are Azure-internal system databases pre-created on every new Flexible Server instance.

Attempting to restore them fails with errors such as:
- `extension "pg_availability" is not available` — Azure-internal extension, not user-installable
- `extension "azure" is not allow-listed` — restricted to Azure service internals
- `extension "pgaadauth" is not allow-listed` — Azure AD auth extension, managed by Azure
- `schema "cron" does not exist` — `pg_cron`'s schema is auto-created by Azure on server start when `shared_preload_libraries` includes `pg_cron`; it cannot be manually imported

**Decision:**
The restore script unconditionally skips `postgres`, `azure_maintenance`, and `azure_sys` database blobs. These databases are not restored from dump files.

**Rationale:**
- Azure recreates all three system databases (and their internal extensions) automatically on every new Flexible Server instance.
- Restoration would fail regardless — the extensions are allow-listed only for Azure's own service account (`azuresu`), not for `azure_pg_admin` users.
- User application data must always reside in named databases, not in these system databases.
- `cron.job` entries (pg_cron scheduled jobs) from the source server are not restored. These are operational configuration, not application data, and must be recreated manually post-restore if required.

---

## ADR-009: `shared_preload_libraries` propagated from source to restored server

**Date:** 2026-03-17
**Status:** Accepted

**Context:**
Several PostgreSQL extensions require entries in `shared_preload_libraries` to activate, including `pg_stat_statements`, `pg_cron`, `pgaudit`, and `pg_buffercache`. This is a server-level parameter set via `az postgres flexible-server parameter set` and requires a server restart to take effect.

A newly provisioned Flexible Server has a default `shared_preload_libraries` value which may differ from the source server. Without propagation, extensions dependent on preloading would be silently absent on the restored instance, causing application failures.

The HMCTS estate uses at least the following `shared_preload_libraries` combinations across its servers:
- `PG_BUFFERCACHE,PG_STAT_STATEMENTS,PG_CRON`
- `pg_stat_statements,pg_cron,pgaudit`
- `PG_BUFFERCACHE,PG_STAT_STATEMENTS,PG_CRON,PGAUDIT,PGCRYPTO`

**Decision:**
Stage 1 (`createPostgresServer`) reads `shared_preload_libraries` from the source server immediately after the restored server is created (or confirmed to exist on retry). If the value differs from the restored server's current setting, it is applied and the restored server is restarted. If it already matches (e.g. on a pipeline retry), no restart is performed.

**Rationale:**
- Ensures the restored server is operationally equivalent to the source with respect to extension availability.
- The check-before-set pattern avoids unnecessary restarts on retries.
- A server restart adds approximately 1–5 minutes but is mandatory for `shared_preload_libraries` changes to take effect — there is no way to defer this.
- Extensions that do not require preloading (`pgcrypto`, `uuid-ossp`, etc.) are restored normally via `pg_restore` from the per-database dump files and are unaffected by this step.

---

## ADR-010: Proactive `roles.sql` cleanup via `sed` before psql restore

**Date:** 2026-03-25
**Status:** Accepted

**Context:**
Azure Backup's `pg_dumpall` output includes superuser-only attributes (`NOSUPERUSER`, `NOBYPASSRLS`) in `ALTER ROLE` statements, and lines for Azure-internal roles (`azure_superuser`, `azure_pg_admin`, `azuresu`, `replication`). Azure Postgres Flexible Server has no superuser, so `ALTER ROLE` statements containing these attributes fail.

The previous approach ran `psql` with `ON_ERROR_STOP=0` and relied on the `roles_restore_has_unexpected_errors()` error filter to suppress known errors. However, `ON_ERROR_STOP=0` causes the **entire failed statement** to be skipped — not just the offending attribute. An `ALTER ROLE myapp NOSUPERUSER NOCREATEROLE CREATEDB LOGIN;` statement fails in its entirety, meaning `CREATEDB` and `LOGIN` are also silently not applied. The role exists but does not function correctly.

**Decision:**
A `sed` pass is applied to the downloaded `roles.sql` before `psql` is run:
- Delete lines matching `azure_superuser`, `azure_pg_admin`, `azuresu`
- Delete `CREATE ROLE replication` and `ALTER ROLE replication` lines
- Strip `NOSUPERUSER` and `NOBYPASSRLS` tokens from remaining `ALTER ROLE` lines

The unmodified file is preserved as `roles.sql.raw` in `restore-output/` for audit comparison. The `roles_restore_has_unexpected_errors()` error filter is retained as a safety net for any errors the `sed` pass does not cover.

**Rationale:**
- Proactive cleanup ensures each `ALTER ROLE` statement applies fully — `LOGIN`, `CREATEDB`, `INHERIT` and other valid attributes are correctly set even when they co-occur with superuser-only attributes on the same line.
- Mirrors the `sed` command recommended in the [Microsoft restore guide](https://learn.microsoft.com/en-us/azure/backup/restore-azure-database-postgresql-flex).
- Defence-in-depth: `sed` handles the structural issue; the error filter catches any residual unexpected errors.

---

## ADR-011: `synchronous_commit=off` for `pg_restore` connections

**Date:** 2026-03-25
**Status:** Accepted

**Context:**
`pg_restore` on IOPS-constrained Azure Flexible Server storage (P6 = 240 IOPS, P10 = 500 IOPS) is heavily bottlenecked by WAL write latency when `synchronous_commit=on` (the default). Each COPY and index-build transaction must wait for WAL to be flushed to disk before returning, causing each write to block on disk I/O.

**Decision:**
`synchronous_commit=off` is set via `PGOPTIONS` for the `pg_restore` session. This is a session-level GUC — it does not affect other connections or the server's running configuration. With this setting, WAL records are written to the OS buffer and flushed asynchronously. If the agent is terminated before the OS flushes buffered WAL, transactions committed within the last ~0.6 seconds may be lost.

**Rationale:**
- Restores are idempotent — if interrupted, the restore job is re-run from scratch against the same recovery point. The ~0.6s data loss window is operationally irrelevant.
- Reduces WAL write amplification by 20–40% on IOPS-constrained storage, meaningfully reducing restore time for large databases.
- The durability tradeoff that makes `synchronous_commit=off` risky for production workloads does not apply to a fire-and-forget restore job.
- The risk of using this on a live production server is avoided because the setting is scoped to the `pg_restore` session only via `PGOPTIONS`.

---

## ADR-012: Dynamic `maintenance_work_mem` derived from server RAM

**Date:** 2026-03-25
**Status:** Accepted

**Context:**
`maintenance_work_mem` controls the RAM each parallel worker uses for index-build sort operations during `pg_restore`. The PostgreSQL default of 64 MB forces excessive temp-file I/O for large-table B-tree index sorts. A higher value allows the sort to run in memory, reducing index build time by 30–70%.

A fixed high value is unsafe: with `-j 3` workers running simultaneously, peak consumption is `3 × maintenance_work_mem`. On a B1ms (2 GB RAM, ~512 MB `shared_buffers`), setting 512 MB would require 1.5 GB for maintenance alone — exceeding available RAM and risking OOM. The correct value depends entirely on the SKU of the restore target, which varies by environment.

**Decision:**
`maintenance_work_mem` is calculated at runtime by querying `shared_buffers` from the target server immediately after Postgres accepts connections:

```sql
SELECT setting::int * 8 / 1024 FROM pg_settings WHERE name = 'shared_buffers'
```

Azure automatically sets `shared_buffers` to 25% of server RAM. The result is divided by the parallel worker count, then clamped to a floor of 64 MB and a ceiling of 1,024 MB. The value is applied as a session-level GUC via `PGOPTIONS`.

| SKU | RAM | `shared_buffers` | ÷ 3 workers | → used |
|-----|-----|----------|---------|--------|
| B1ms | 2 GB | 512 MB | 170 MB | **170 MB** |
| GP D2ds_v4 | 8 GB | 2,048 MB | 682 MB | **682 MB** |
| GP D4ds_v4 | 16 GB | 4,096 MB | 1,365 MB | **1,024 MB** (cap) |
| MO E8ds_v4 | 64 GB | 16,384 MB | 5,461 MB | **1,024 MB** (cap) |

Falls back to 128 MB if the server query fails, ensuring the restore still proceeds.

**Rationale:**
- Automatically scales to any SKU without pipeline parameter changes or hardcoded lookup tables.
- Prevents OOM on small SKUs where fixed high values would be unsafe.
- Maximises index-build performance on larger SKUs proportionally.
- The server query runs against an already-confirmed live Postgres instance (after the connection wait loop), so failure is unlikely and the fallback is safe.

---

## ADR-013: Azure-generated `_tablespace.sql` and `_schema.sql` blobs intentionally not restored

**Date:** 2026-03-25
**Status:** Accepted

**Context:**
Azure Backup generates four file types per restore operation (per the [Microsoft restore documentation](https://learn.microsoft.com/en-us/azure/backup/restore-azure-database-postgresql-flex)):

| File | Contents |
|------|----------|
| `*_database_<name>.sql` | Per-database data and schema dump |
| `*_roles.sql` | Server-level role definitions |
| `*_tablespace.sql` | Custom tablespace definitions |
| `*_schema.sql` | Schema-only dump for all databases |

**Decision:**
Only `*_database_*.sql` and `*_roles.sql` blobs are restored. `*_tablespace.sql` and `*_schema.sql` blobs are detected, logged as intentionally skipped, and not processed.

**Rationale for `_tablespace.sql`:**
Azure Database for PostgreSQL Flexible Server does not support custom tablespaces. Attempting to restore tablespace definitions fails immediately with errors such as `unacceptable encoding` or permission failures. These blobs are always present in the restore output but contain no restorable content on Flexible Server.

**Rationale for `_schema.sql`:**
Schema is already fully embedded in each `*_database_*.sql` dump. Microsoft explicitly states in the restore documentation: *"We recommend you not to run this script on the PostgreSQL Flexible server because the schema is already part of the `database.sql` script."* Running it produces `ERROR: relation already exists` for every object.

**Rationale for logging rather than silently skipping:**
Explicit log output (`NOTE: Azure Backup generated file(s) present in container but intentionally NOT restored`) prevents the presence of these blobs from appearing as a defect or omission during post-restore review of pipeline logs.

---

## ADR-014: Restore pipeline agent resources can be increased to improve restore speed and stability

**Date:** 2026-03-31
**Status:** Accepted

**Context:**
The database restore phase runs from the Azure DevOps agent pod, not from the PostgreSQL server itself. The agent is responsible for downloading blobs, maintaining the client connection, running `pg_restore -j 3`, streaming verbose output, and sustaining the restore session for long-running COPY and index-build phases.

With low agent limits, the restore client can become the bottleneck or fail independently of the target server. Memory pressure increases with parallel `pg_restore` workers, while low CPU increases client-side contention, throttling, and longer wall-clock execution. These effects are most visible on long restores where the job must stay healthy for tens of minutes or hours.

Empirical testing showed that increasing the agent from a lower resource profile (`1` vCPU / `2Gi` memory) to a higher one (`2` vCPU / `4Gi` memory) materially improved restore reliability and contributed to faster end-to-end restore times when combined with the existing server-side tuning.

**Decision:**
Agent CPU and memory are treated as tunable restore controls. Where restore duration or client-side stability becomes a concern, the Azure DevOps agent resources can be increased to give `pg_restore` more headroom for parallel workers, blob download, connection handling, and long-running execution.

This is an operational scaling lever rather than a hard requirement for every restore. The appropriate agent profile depends on restore size, restore duration, and the degree of parallelism used.

**Rationale:**
- `pg_restore -j 3` creates concurrent client-side worker processes. Increasing agent memory reduces the risk of OOM kills or unstable behavior during large restores.
- More agent CPU reduces client-side throttling during blob download, TLS/network processing, worker coordination, and verbose log streaming.
- Long-running restore jobs are sensitive to resource starvation. Extra headroom improves operational stability even when the dominant bottleneck is server-side index rebuild time.
- Agent sizing and server sizing solve different problems: the PostgreSQL server SKU determines how quickly data and indexes are written, while the agent size determines whether the restore client can sustain parallel restore work safely and efficiently.
- Observed improvements after increasing agent resources support documenting this as a deliberate tuning option rather than incidental behavior.

**Consequences:**
- Restore documentation should explicitly state that agent resources can be increased to improve both restore throughput and stability when needed.
- Future performance tuning must consider both dimensions separately: agent capacity for safe client execution, and server SKU / storage IOPS for database-side throughput.
- Any future increase in `pg_restore` parallelism must be evaluated against agent memory and CPU limits before adoption.
