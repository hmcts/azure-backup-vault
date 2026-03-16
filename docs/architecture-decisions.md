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
Stage 3 runs only when `dryRun=false` (condition: `eq(parameters.dryRun, false)`).

> Note: the CNP pipeline previously used the string-comparison form `eq('${{ parameters.dryRun }}', 'false')`, which was functionally equivalent but inconsistent with the CPP pipeline and fragile under ADO boolean serialisation changes. Both pipelines now use `eq(parameters.dryRun, false)`.

**Rationale:**
- There is no meaningful validation to perform if no server was provisioned.
- Avoids a spurious connection failure polluting the pipeline run log.
