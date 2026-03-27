# Azure Backup Vault for PostgreSQL Flexible Server — Known Risks and Limitations

> **Source**: [Azure support matrix for PostgreSQL Flexible Server backup](https://learn.microsoft.com/en-us/azure/backup/backup-azure-database-postgresql-flex-support-matrix#limitation)
> Last reviewed: March 2026

This document captures the Azure-documented support limitations for vaulted backup of PostgreSQL Flexible Server and assesses the **risk to our restore automation solution** for each. It should be reviewed whenever the backup/restore pipeline is changed or onboarded to a new environment.

---

## Risk Summary

| # | Limitation | Severity | Status |
|---|---|---|---|
| R1 | 1 TB maximum server size for backup | 🔴 High | Unmitigated — needs operational monitoring |
| R2 | Maximum 1 restore per day (recommended) | 🟠 Medium | Partially mitigated — pipeline does not enforce |
| R3 | Only one weekly backup executes; subsequent jobs fail | 🟠 Medium | Unmitigated — no alerting in place |
| R4 | BYTEA column row size > 500 MB causes backup failure | 🟡 Low | Application-team awareness required |
| R5 | No item-level recovery (single database restore) | 🟡 Low | Architectural constraint, by design |
| R6 | Role creation errors during restore | ✅ Handled | Proactively cleaned + error filter safety net |
| R11 | Azure-generated `_tablespace.sql` / `_schema.sql` not restorable on Flexible Server | ✅ Handled | Detected and logged; not restored |
| R12 | Vault association is tracked by datasource ARM resource ID, not backup instance name | 🟠 Medium | Operational cleanup required before reusing a server name |
| R7 | Backup not supported on replicas | ✅ Not applicable | We configure backup on primary only |
| R8 | No archive tier support | ✅ Not applicable | We use standard vault tier |
| R9 | Full backups only (no incremental/differential) | ℹ️ Informational | Accepted — impacts RTO for large databases |
| R10 | PostgreSQL v11 EOL — restore server cannot be provisioned | 🔴 High | Manual intervention required; must restore to v14+ |

---

## Detailed Risk Assessments

### R1 — 1 TB Maximum Server Size for Backup 🔴

**Azure documentation:**
> *"Vaulted backups are supported for server size <= 1 TB. If backup is configured on server size larger than 1 TB, the backup operation fails."*

**Risk to our solution:**
This is a hard Azure platform limit. If any protected database server grows beyond 1 TB of total storage used, the vault backup job will **silently start failing**. There is no warning prior to hitting the threshold — the backup simply fails at the next scheduled run.

For current environments this is unlikely in the near term, but production databases with large file attachments, audit logs, or historical data may approach this limit over time.

**Impact:** Complete loss of backup coverage without any automatic notification. A subsequent restore attempt would find either no recovery point or a stale one.

**Mitigation recommendations:**
1. Implement an Azure Monitor alert on the `BackupHealthEvent` metric for the Backup Vault filtered to `BackupItemType = AzureDatabaseForPostgreSQL` with status `Unhealthy`.
2. Implement a storage utilisation alert on all protected PostgreSQL Flexible Servers at 80% of 1 TB (i.e., alert at ~820 GB used).
3. Add a pre-flight check to the restore pipeline that queries the most recent backup job status and warns if the last backup is older than 8 days (indicating likely backup failures).

---

### R2 — Maximum One Restore Per Day 🟠

**Azure documentation:**
> *"Recommended frequency for restore operations is once a day. Multiple restore operations triggered in a day can fail."*

**Risk to our solution:**
Our restore pipeline can be triggered manually and has no guard against being run multiple times in a single day against the same backup instance. In normal DR use this is unlikely to be an issue, but during:
- RTO testing (we may run the pipeline multiple times in a day to verify changes)
- Incident recovery where a first restore attempt fails part way through and is re-triggered
- Parallel restores for different databases that share the same vault

…a second restore on the same day may fail non-deterministically at the Azure vault layer (before our script even starts), producing a confusing failure with no clear error message.

**Impact:** Failed restore during an actual incident if a test ran earlier the same day. Difficult to diagnose because the failure occurs at the vault job submission step, not during `pg_restore`.

**Mitigation recommendations:**
1. Add a comment/warning to the pipeline YAML to document this constraint at the trigger configuration.
2. For RTO testing: space test runs across days where possible.
3. Consider adding a pipeline-level check that queries the vault for any restore jobs in the last 24 hours for the same backup instance and fails fast with a clear message if one is found.

---

### R3 — Only One Weekly Backup Executes; Subsequent Jobs Fail 🟠

**Azure documentation:**
> *"For vaulted backups, only one weekly backup is currently supported. If multiple vaulted backups are scheduled in a week, only the first backup operation of the week is executed, and the subsequent backup jobs in the same week fail."*

**Risk to our solution:**
Azure Backup Vault schedules weekly backups for PostgreSQL Flexible Server. If a backup policy is configured with multiple weekly triggers (e.g., Monday and Thursday), only the first weekly backup succeeds — subsequent ones fail. This means:
- The **recovery point availability** is at most weekly, not twice-weekly as the policy might suggest.
- The failed backup jobs generate noise in the vault job history that can mask genuine failures.
- Teams who configure a policy expecting twice-weekly backups have a **false sense of recovery point frequency**.

**Impact:** Wider RPO (Recovery Point Objective) than expected if policy is misconfigured. Potential for alert fatigue from repeated failed backup jobs obscuring real issues.

**Mitigation recommendations:**
1. Ensure all backup policies for PostgreSQL Flexible Server are configured with a **single weekly trigger only**.
2. Audit existing backup policies across all vaults to confirm this.
3. Add a note to the runbook documenting that weekly frequency is the maximum supported cadence.

---

### R4 — BYTEA Column Row Size > 500 MB Causes Backup Failure 🟡

**Azure documentation:**
> *"Vaulted backups don't support tables containing a row with BYTEA length exceeding 500 MB."*

**Risk to our solution:**
Any PostgreSQL database that stores large binary objects in `BYTEA` columns (e.g., file attachments, document blobs, media) where any single row's BYTEA value exceeds 500 MB will cause the vault backup to fail.

This is not a concern for standard transactional databases (plum, toffee recipes service, etc.) but could affect any service that uses PostgreSQL as a document/file store.

**Impact:** Silent backup failure for any database with oversized BYTEA rows. The database appears protected but has no recovery point.

**Mitigation recommendations:**
1. Application teams onboarding a new PostgreSQL database to vault backup should confirm no BYTEA columns exceed 500 MB per row.
2. If large binary storage is required, use Azure Blob Storage instead of BYTEA columns — this is best practice regardless of the backup limitation.

---

### R5 — No Item-Level Recovery (Whole Server Only) 🟡

**Azure documentation:**
> *"For restore operation, item level recovery (recovery of specific databases) isn't supported."*

**Risk to our solution:**
The vault backup captures the entire PostgreSQL Flexible Server (all databases). Restoring a single database is not possible directly — the full server blob is always restored to files, and then selective `pg_restore` can be applied manually.

Our current pipeline restores all databases found in the backup. There is no supported Azure mechanism to restore a single database from a vault backup without first restoring all blobs.

**Impact:** For a targeted recovery of a single database on a multi-database server, the full restore process always runs, which extends RTO beyond what would be needed for a single-database restore.

**Mitigation:** This is an architectural constraint of the Azure platform. It is accepted by design. Document it in the runbook so incident responders set expectations appropriately. The `pg_restore` step could be modified to target only a specific database if needed.

---

### R6 — Role Creation Errors During Restore ✅ Handled

**Azure documentation lists expected errors:**
- `role "azure_pg_admin" already exists`
- `role "azuresu" already exists`
- `must be superuser to create superusers`
- `permission denied granting privileges as role "azuresu"`
- `Only roles with the ADMIN option on role "pg_use_reserved_connections" may grant this role`

**Status:** Handled via a two-layer defence:

1. **Proactive `sed` cleanup** (ADR-010): Before `psql` runs, `roles.sql` is pre-processed to delete lines for Azure-internal roles and strip `NOSUPERUSER`/`NOBYPASSRLS` attributes from `ALTER ROLE` statements. This ensures each statement applies fully — without this, `ON_ERROR_STOP=0` causes the entire statement to be skipped, silently not applying valid attributes like `LOGIN` and `CREATEDB` on the same line.

2. **Error filter safety net**: The `roles_restore_has_unexpected_errors()` function catches any errors not covered by the `sed` pass, suppressing the known managed-environment errors listed above and failing only on genuinely unexpected errors.

The unmodified `roles.sql.raw` is preserved in `restore-output/` for post-restore audit comparison.

**Note:** The error filter was updated in March 2026 to also cover `azuresu` grant errors and `pg_use_reserved_connections` errors. The proactive sed cleanup was added at the same time.

---

### R12 — Vault Association Is Tracked by Datasource ARM Resource ID, Not Backup Instance Name 🟠

**Observed Azure behaviour:**
When a protected PostgreSQL Flexible Server is deleted, the backup instance can remain in `SoftDeleted` state inside the vault. If a new PostgreSQL Flexible Server is later created with the **same ARM resource ID** — which happens when the same subscription, resource group, resource type, and server name are reused — Azure Backup still treats it as the same datasource.

That means all of the following are **not** sufficient to break the association:
- Restoring from a different source server
- Restoring from a different recovery point
- Creating a new backup instance name such as `-v2`
- Deleting and recreating the PostgreSQL server if the server name stays the same

For PostgreSQL Flexible Server, the datasource identity the vault tracks is effectively the server ARM resource ID:

`/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.DBforPostgreSQL/flexibleServers/<server-name>`

If that ID is reused while the prior backup instance is still `SoftDeleted`, registration fails with errors such as:

> *"Datasource is already associated with the backup instance <name> in the Backup vault ... with the protection status as SoftDeleted."*

**Risk to our solution:**
This is easy to hit during restore testing and repeated sandbox rebuilds, because engineers naturally reuse the same restore target name. The failure is non-obvious from Terraform alone: changing `backup_instance_name` does not help because the vault is blocking the datasource association, not the friendly name.

**Impact:**
- Terraform backup-instance registration fails even though the Postgres server has been deleted and recreated successfully.
- Operators can lose time debugging RBAC, policy, or naming issues that are not actually the cause.
- Repeated test runs against the same restore target name require manual vault cleanup between runs.

**Mitigation recommendations:**
1. Before reusing a restore target server name, check whether the old backup instance is still `SoftDeleted` in the vault.
2. Purge or recover the soft-deleted backup instance before attempting to protect a recreated server with the same name.
3. For short-lived restore tests, prefer a unique server name per run to guarantee a new datasource ARM resource ID.
4. Document clearly that backup instance name changes alone do not avoid this issue.

---

### R7 — Backup Not Supported on Replicas ✅ Not Applicable

**Azure documentation:**
> *"Vaulted backup isn't supported on replicas; backup can be configured only on primary servers."*

We configure backup on primary servers only. No action required.

---

### R8 — No Archive Tier Support ✅ Not Applicable

**Azure documentation:**
> *"Vaulted backup doesn't support storage in archive tier."*

We use the standard vault tier. No action required.

---

### R10 — PostgreSQL v11 End-of-Life — Restore Server Cannot Be Provisioned 🔴

**Background:**
Azure retired PostgreSQL Flexible Server v11 in November 2023. No new v11 Flexible Server instances can be created.

**Risk to our solution:**
Our pipeline provisions the restore server by reading the version from the source server (`VERSION=$(echo "$SOURCE" | jq -r '.version')`) and passing it directly to `az postgres flexible-server create --version "${VERSION}"`. If the source server is v11, this command **fails immediately** — Azure rejects the creation request because v11 is end-of-life.

This means any v11 database that is currently protected by vault backup **cannot be restored using the automated pipeline without manual intervention**. The backup itself is valid; it's the restore path that is broken.

**Impact:** Full pipeline failure at Stage 1 for any v11 source server. No data is lost, but the automated RTO is unachievable — an engineer would need to manually create a v14+ server and run the pipeline in `database-only` mode.

**Mitigation recommendations:**
1. **Preferred — upgrade source servers**: Perform a major version upgrade of any v11 Flexible Servers to v14 or v16 using Azure's in-place major version upgrade. Reconfigure vault backup after upgrade.
2. **If upgrade is not immediately possible — document the manual restore path**:
   - Manually provision a v14+ Flexible Server in the target resource group
   - Run the restore pipeline in `database-only` mode using the existing recovery point
   - The v11 dump format is forward-compatible; `pg_restore` from a v14 client can read and restore v11 dumps without data loss
3. Add a pre-flight check to the pipeline that validates the source server version and fails fast with a clear error message if v11 is detected, rather than failing silently at the `az postgres flexible-server create` step.

**Currently affected versions:** v11 (EOL November 2023). v12 and v13 are also approaching EOL — check the [Azure PostgreSQL version support policy](https://learn.microsoft.com/en-us/azure/postgresql/flexible-server/concepts-version-policy) for current retirement dates.

---

### R9 — Full Backups Only (No Incremental/Differential) ℹ️ Informational

**Azure documentation:**
> *"Vaulted backups support full backups only; incremental or differential backups aren't supported."*

Every weekly backup is a full backup of the entire server. This directly drives the vault blob download time (Stage 2 of our pipeline) which is consistently ~2m 35s regardless of database size in our testing — this appears to be dominated by the Azure vault job overhead rather than data volume.

The full backup model also means that as databases grow, the vault restore blob size grows proportionally, which will eventually increase Stage 2 duration. This feeds into the RTO model documented in `restore-test-scenarios.md`.

---

### R11 — Azure-generated `_tablespace.sql` and `_schema.sql` files not restorable on Flexible Server ✅ Handled

**Background:**
Azure Backup generates four file types per restore operation in addition to per-database and roles SQL files: `_tablespace.sql` and `_schema.sql`. Neither can be applied to Azure Database for PostgreSQL Flexible Server:

- **`_tablespace.sql`**: Contains `CREATE TABLESPACE` statements. Azure Postgres Flexible Server does not support custom tablespaces — attempting to restore this file fails immediately.
- **`_schema.sql`**: Contains a schema-only dump of all databases. The schema is already embedded in each `_database_*.sql` dump file. Microsoft explicitly recommends not running this script because doing so produces `ERROR: relation already exists` for every object.

**Status:** The restore script detects both file types, logs them explicitly as intentionally not restored, and skips them. See ADR-013 for the full rationale.

---

## Review Checklist

When onboarding a new PostgreSQL Flexible Server to vault backup, confirm:

- [ ] Server total storage used is below 820 GB (80% of 1 TB limit)
- [ ] Server PostgreSQL version is v14 or higher (v11 is EOL; v12/v13 approaching EOL)
- [ ] Backup policy is configured with a **single** weekly trigger
- [ ] No application tables use `BYTEA` columns with rows exceeding 500 MB
- [ ] Azure Monitor alert exists on vault backup job health for this server
- [ ] If reusing a previous restore target name, confirm no soft-deleted backup instance still exists for that datasource in the vault
- [ ] The restore pipeline has been run at least once successfully against a recovery point from this server
