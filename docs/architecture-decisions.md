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
