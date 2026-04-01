# Future Improvements

## Backup Vault Monitoring and Alerting

**Priority:** High
**Context:** The current Terraform deployment provisions backup vaults and policies but does not
configure any Azure Monitor alerts. If a scheduled backup job fails, if the backup policy is
not assigned to a new server instance, or if the vault managed identity loses the required
permissions, there is no automated notification — the failure is only discovered on the next
restore attempt or via manual review.

**Proposed improvement:**
Add Terraform resources (or a dedicated monitoring module) to configure:

- An Azure Monitor alert rule on `Microsoft.DataProtection/backupVaults` scoped to each vault,
  firing when any backup job transitions to `Failed` or `CompletedWithWarnings`.
- An alert for backup instance `ProtectionStopped` state (indicates a server was deleted or
  assignment was removed).
- A weekly digest alert for RPO breach: last successful backup older than the policy schedule
  window plus a configurable tolerance.
- Routing to the existing HMCTS PlatOps alerting endpoint (Slack / PagerDuty / email action group).

This should be implemented alongside the next planned vault configuration change to avoid a
separate deployment cycle.

---

## Replace deprecated `--high-availability` flag in server create

**Priority:** Medium — action required before May 2026
**Context:** During the Scenario 4.2 live run (2026-03-17), `az postgres flexible-server create`
emitted:

```
WARNING: Argument '--high-availability' has been deprecated and will be removed in next breaking
change release(2.86.0) scheduled for May 2026. Use '--zonal-resiliency' instead.
```

**Proposed improvement:**
Replace `--high-availability Disabled` with `--zonal-resiliency Disabled` in both the live
server create command and the dry-run preview echo in `azure-pipelines-restore-cnp.yaml` before
Azure CLI 2.86.0 is rolled out to the ADO agent pools (expected May 2026). Verify the new flag
name and accepted values in the CLI release notes before the change.

---

## Known limitation: WAL accumulation during pg_restore of large single-table databases

**Priority:** Low — does not affect production restores; relevant for large synthetic test datasets only
**Discovered:** 2026-03-23 during pgbench scale-factor testing

**Context:**
`pg_restore` without `--single-transaction` issues each table's data as a separate `COPY` command,
with each `COPY` committed as its own transaction. For a typical production database this is
correct behaviour — data is spread across many tables, so individual `COPY` transactions are
small, WAL from each is checkpointed and recycled before the next table starts, and peak disk
pressure is manageable.

However, PostgreSQL cannot recycle WAL segments while any transaction that generated them is
still open. For a database containing a single extremely large table (e.g. a pgbench
`pgbench_accounts` table at scale factor 2500, which holds ~250 million rows in a single table),
the `COPY` for that table is one continuous transaction writing ~35 GB of data. WAL accumulates
alongside the data being written throughout the entire duration of that `COPY` — since the
transaction is still open, none of the WAL can be recycled until the `COPY` completes. Peak disk
consumption is therefore approximately **2× the table size**: the data itself plus the accumulated
WAL for the open transaction.

For the 64 GB Premium SSD used in sandbox testing: 35 GB data + 35 GB WAL ≈ 70 GB, exceeding
the 64 GB disk. Azure storage auto-grow mitigates gradual growth but cannot react quickly enough
to a bulk COPY loading tens of gigabytes in a single transaction — auto-grow triggers at 95%
utilisation and can take 1–2 minutes to allocate, while the COPY fills the remaining 5% in
seconds.

This is a characteristic of synthetic single-table bulk loads only. Real production databases
distribute data across many tables; no single `COPY` transaction ever approaches the total
database size, so this issue does not arise in practice.

**Potential mitigation — enable `wal_compression` before restore:**
PostgreSQL's `wal_compression` parameter (available since PG 9.5; `lz4` and `zstd` modes
available from PG 15) reduces WAL volume by compressing full-page images. For sequential bulk
inserts, compression ratios of 3–5× are typical, which would bring the WAL footprint of a 35 GB
COPY down to approximately 7–12 GB — well within safe margins.

A future improvement to the restore script would be to enable `wal_compression` on the restored
server immediately after provisioning:

```bash
az postgres flexible-server parameter set \
  --resource-group "$TARGET_RESOURCE_GROUP" \
  --server-name "$TARGET_POSTGRES_SERVER" \
  --name wal_compression \
  --value on
```

Because `wal_compression` does not require a server restart on Azure Flexible Server, this can be
applied between the server provisioning step and the first `pg_restore` call without adding
significant pipeline time. It would reduce disk pressure during restore for all databases —
production and synthetic alike.

**Note:** `wal_compression` affects only the restored server during the restore window; it has no
impact on the source server or on the vault backup artefacts.

---

## Script Refactoring to Modular Architecture

**Priority:** High
**Context:** The restore script (`restore-postgresql-flex-from-backup-vault.sh`) has grown to 1043 lines and now includes WAL tuning logic, dynamic worker calculation, metrics JSON building, and role restoration. The monolithic structure makes it difficult to test, debug, and extend individual components. This refactoring was identified during WAL tuning implementation (ADR-016).

**Proposed improvement:**
Extract into library modules in a `lib/` subdirectory:
- `lib/common.sh` — Shared helper functions, logging, validation, error handling (~100 lines)
- `lib/azure-discovery.sh` — Vault instance and recovery-point discovery (~150 lines)
- `lib/database-restore.sh` — Core database restoration loop and pg_restore orchestration (~200 lines)
- `lib/metrics.sh` — Metrics JSON building and output (~100 lines)
- `lib/wal-tuning.sh` — WAL setting get/set functions and toggle logic (~80 lines, reusable)
- `lib/roles-restore.sh` — Role and permission restoration (~80 lines)

**Benefits:**
- Each module 80-200 lines, independently testable
- Enables cleaner implementation of phased restore feature (see next item)
- Reduces cognitive load for future maintainers
- Allows reuse of `wal-tuning.sh` functions in other restore scenarios

**Timing:** After WAL tuning performance is validated on real 600GB+ restores; implement before adding phased restore capability.

---

## Phased Restore Capability (`--section` parameter)

**Priority:** High (planned for next sprint after refactoring)
**Context:** Currently, if a restore fails during the indexing phase (post-data) after 5+ hours of data loading, the entire operation must restart. For large databases (600GB+), this is costly.

**Proposed improvement:**
Add support for PostgreSQL's `--section` parameter in `pg_restore` to enable separate restoration of:
- `pre-data` — schema (tables, sequences, functions, types) without data
- `data` — COPY statements for table data only
- `post-data` — indexes, constraints, triggers, views

Allow pipeline parameter `RESTORE_SECTION=data|post-data|all` (default: `all`) to:
1. Run `pg_restore --section pre-data` once
2. Run `pg_restore --section data` once (5+ hours for large databases)
3. Run `pg_restore --section post-data` independently if needed (can retry without reloading data)

If the post-data phase fails due to index build timeout or constraint violation, retry only that section (~1-2 hours) instead of restarting from scratch.

**Benefits:**
- 1-1.5 hour savings if indexing fails on large restores
- Enables faster iteration for debugging constraint/trigger issues
- Cleaner separation of concerns (schema → data → indexes)

**Requires:** Refactored script structure (modular) to cleanly separate section-specific logic. Implement only after script refactoring is complete. Will require a separate ADR detailing failure scenarios and retry logic.
