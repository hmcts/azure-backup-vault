# Restore Pipeline Test Scenarios

Run in order. Verify each checkpoint before proceeding to the next scenario.

---

## Prerequisites

| Parameter | Notes |
|---|---|
| `agentPool` | Required (no default for CNP pipeline). Must be a self-hosted pool whose VNet subnet is permitted on the restore storage account and can reach private Postgres endpoints. |
| `sourceSubscription` | Optional (default `'none'`). Set to the subscription ID or name of the source Postgres server only when it differs from the service connection's default subscription. The service connection SP must have at least `Reader` on that subscription. |
| `vaultSubscription` | Optional (default `'none'`). Set to the subscription ID or name of the backup vault only when it differs from the service connection's default subscription. The service connection SP must have at least `Backup Reader` on that subscription. |
| `serviceConnection` | Defaults to `DCD-CNP-Prod` (CNP) / `ado_live_workload_identity` (CPP). Override if running against a different environment. |

---

## Stage 1 — Discovery only (no Azure mutations)

### Scenario 1.1 — Dry run: discover vault instances and recovery points

| Parameter | Value |
|---|---|
| `agentPool` | `<your-self-hosted-pool>` |
| `dryRun` | `true` |
| `restoreMode` | `all` |
| `sourceServerName` | `<your-source-server>` |
| `sourceResourceGroup` | `<rg>` |
| `sourceSubscription` | `'none'` (or subscription ID if cross-subscription) |
| `vaultResourceGroup` | `<vault-rg>` |
| `vaultName` | `<vault-name>` |
| `vaultSubscription` | `'none'` (or subscription ID if cross-subscription) |

**Expected:** Lists all backup instances in the vault, resolves the matching instance, lists all available recovery points with timestamps. No container created, no server created.

| Checkpoint | Expected | Status |
|---|---|---|
| Log shows expected instance name | Instance name matches source server | ✅ `plum-v14-flexible-sandbox-backup-instance` selected from 3 instances |
| At least one recovery point listed | Recovery points with UTC timestamps | ✅ `fc0ae7fc1e944a8d8fa3e6ac612cd62f @ 2026-03-12T11:53:35.0886002Z` |
| No container created in storage account | Storage account unchanged | ✅ Dry run — no mutations executed |

---

### Scenario 1.2 — Dry run: vault-only scoping

| Parameter | Value |
|---|---|
| `agentPool` | `<your-self-hosted-pool>` |
| `dryRun` | `true` |
| `restoreMode` | `vault-only` |
| `sourceServerName` | `<your-source-server>` |
| `sourceResourceGroup` | `<rg>` |
| `sourceSubscription` | `'none'` (or subscription ID if cross-subscription) |
| `vaultResourceGroup` | `<vault-rg>` |
| `vaultName` | `<vault-name>` |
| `vaultSubscription` | `'none'` (or subscription ID if cross-subscription) |

**Expected:** Vault and recovery-point discovery runs. Blob discovery is skipped entirely.

| Checkpoint | Expected | Status |
|---|---|---|
| Log contains "vault-only mode: skipping blob and database restore discovery" | Scoping gate confirmed | ✅ Message present |
| No blob listing attempted | No storage account calls in log | ✅ Confirmed — no storage calls |

---

## Stage 2 — Vault restore to blob storage (no DB changes)

### Scenario 2.1 — Live vault-only restore

> Note the container name from the pipeline logs — required for Scenario 3.1 and 3.2.
> Container names follow the pattern `<serverslug><mhddmmyy><buildId>` (all lowercase alphanumeric, no separators), e.g. `plumv14flexiblesandbox371013032612345`.
> Look for the `Created container:` log line in the Stage 1 **Create restore storage container** step.

| Parameter | Value |
|---|---|
| `agentPool` | `<your-self-hosted-pool>` |
| `dryRun` | `false` |
| `restoreMode` | `vault-only` |
| `sourceServerName` | `<your-source-server>` |
| `sourceResourceGroup` | `<rg>` |
| `sourceSubscription` | `'none'` (or subscription ID if cross-subscription) |
| `vaultResourceGroup` | `<vault-rg>` |
| `vaultName` | `<vault-name>` |
| `vaultSubscription` | `'none'` (or subscription ID if cross-subscription) |

**Expected:** Blob container created. Vault restore job triggered and polled to completion. Stage 3 (Validate) is skipped.

| Checkpoint | Expected | Status |
|---|---|---|
| Container visible in storage account | Container exists with generated name | ✅ Container created |
| `*_database_*.sql` blobs present | One blob per source database | ✅ Blobs present |
| `*_roles.sql` blob present | Single roles blob | ✅ Roles blob present |
| Blob count matches source database count + 1 | e.g. 3 databases → 4 blobs | ✅ Confirmed |
| Stage 3 skipped | Validate stage not executed | ✅ vault-only mode — no DB stage |
| `restore-metrics.json` artifact contains vault job details | `restoreJobStatus: Completed` | ✅ `acef2018-de2b-4e03-874c-3974a6fbb36e` → `Completed` (~2.5 min) |

---

## Stage 3 — Database restore only (reusing container from Stage 2)

### Scenario 3.1 — Dry run: database-only blob discovery

| Parameter | Value |
|---|---|
| `agentPool` | `<your-self-hosted-pool>` |
| `dryRun` | `true` |
| `restoreMode` | `database-only` |
| `existingRestoreContainer` | `<container-name-from-scenario-2.1>` |
| `sourceServerName` | `<your-source-server>` |
| `sourceResourceGroup` | `<rg>` |
| `restoredServerName` | `'auto'` (derives `<sourceServerName>-restore-<mhddmmyy>`) or an explicit name if the server was created with a custom name |

**Expected:** Lists all `_database_*.sql` blobs and the roles blob in the existing container. No server provisioned, no DB changes.

| Checkpoint | Expected | Status |
|---|---|---|
| Log lists same number of database blobs as verified in 2.1 | Blob count matches | ✅ 6 blobs: `azure_maintenance`, `azure_sys`, `plum`, `postgres`, `rhubarb`, `template1` |
| Roles blob identified | Roles blob name logged | ✅ `fbbb9707-..._roles.sql` |
| No Postgres server created | No server provisioning in log | ✅ Confirmed — dry run only |

---

### Scenario 3.2 — Live database-only restore

| Parameter | Value |
|---|---|
| `agentPool` | `<your-self-hosted-pool>` |
| `dryRun` | `false` |
| `restoreMode` | `database-only` |
| `existingRestoreContainer` | `<container-name-from-scenario-2.1>` |
| `sourceServerName` | `<your-source-server>` |
| `sourceResourceGroup` | `<rg>` |
| `restoredServerName` | `'auto'` (derives `<sourceServerName>-restore-<mhddmmyy>`) or an explicit name if the server was created with a custom name |

**Expected:** Provisions the restored Postgres server, replays roles once, then loops over every database blob — creating each DB and restoring it. Stage 3 validates all user databases.

| Checkpoint | Expected | Status |
|---|---|---|
| Restored Postgres server created | Server FQDN logged | ✅ Confirmed |
| Roles replayed once before loop | "Restoring roles" appears once in log | ✅ Confirmed |
| Each database blob downloaded and restored in sequence | One "Restoring database:" block per DB | ✅ `plum`, `rhubarb` restored; 4 system DBs skipped |
| `pg_restore` allow-list extension errors treated as warnings | WARN logged, restore continues | ✅ `pgstattuple` rejected by Azure — logged as WARN, not fatal |
| Local dump files deleted after each restore | No `_database_*.sql` files in artifact | ✅ Confirmed |
| Stage 3: all user databases listed | Same databases as source | ✅ `plum`, `rhubarb` |
| Stage 3: `total_tables` correct per database | Matches source schema | ✅ `plum` → 0 tables (empty DB, expected); `rhubarb` → 7 tables |
| Stage 3: `total_estimated_rows` correct per database | Reflects backup point-in-time state | ✅ `plum` → 0 rows; `rhubarb` → 19 rows |
| `restore-metrics.json` has `databaseRestores` array | One entry per database with duration | ✅ Confirmed |

**Manual data integrity verification (post-restore):**

Connected to source server `plum-v14-flexible-sandbox` as `pgadmin` and to restored server `plum-v14-flexible-sandbox-restore-4411170326` as `hmctsAdmin`, and compared:

| Database | Source tables | Restored tables | Source rows (`recipe`) | Restored rows (`recipe`) |
|---|---|---|---|---|
| `plum` | 0 (empty) | 0 | — | — |
| `rhubarb` | 7 | 7 | 0 (`recipe`) | 0 (`recipe`) |

Schema (tables) is faithfully restored. The `recipe` table is empty on both source and restored server. However, the full-run (Scenario 4.2) confirmed `rhubarb` has **19 total estimated rows** across all 7 tables — the data lives in `dh_test`, `dh_test_audit`, `dh_testing_constraints*`, and `flyway_schema_history`. Point-in-time recovery is working correctly.

---

## Stage 4 — Full end-to-end (vault + server + all databases in one run)

### Scenario 4.1 — Dry run: full end-to-end preview

| Parameter | Value |
|---|---|
| `agentPool` | `<your-self-hosted-pool>` |
| `dryRun` | `true` |
| `restoreMode` | `all` |
| `sourceServerName` | `plum-v14-flexible-sandbox` |
| `sourceResourceGroup` | `plum-v14-flexible-data-sandbox` |
| `sourceSubscription` | `'none'` |
| `vaultResourceGroup` | `mgmt-infra-prod-rg` |
| `vaultName` | `cnp-backup-vault` |
| `vaultSubscription` | `'none'` |

**Expected:** Full discovery preview — vault instances, recovery points, blob list (empty in dry run, expected). Confirms all parameters wired correctly before committing.

| Checkpoint | Expected | Status |
|---|---|---|
| Source server config logged | SKU, version, storage, location, subnet logged | ✅ `Standard_B1ms`, v16, 64GB, `uksouth` |
| Restored server name derived correctly | `<source>-restore-<ddmmyy>` | ✅ `plum-v14-flexible-sandbox-restore-3412170326` |
| Server create preview printed | `[DRY RUN] Would create Postgres server:` in log | ✅ Confirmed with full `az postgres flexible-server create` preview |
| Container name preview printed | `[DRY RUN] Would create container:` in log | ✅ `plumv14flexiblesandbox34121703261051769` in `cnpvaultrestorationsprod` |
| Vault instance resolved | Instance name logged | ✅ `plum-v14-flexible-sandbox-backup-instance` |
| Recovery point resolved | Recovery point ID logged | ✅ `fc0ae7fc1e944a8d8fa3e6ac612cd62f @ 2026-03-12T11:53:35Z` |
| Blob listing gracefully skipped | Container-not-found handled as expected in dry run | ✅ Logged as info, not error |
| Dry run preview commands printed | `[DRY RUN PREVIEW]` lines for restore trigger, poll, and DB restore | ✅ Confirmed |
| No container created | Storage account unchanged | ✅ Dry run — no mutations executed |
| No server created | No server provisioning in log | ✅ Dry run — no mutations executed |
| Stage 3 (Validate) skipped | Not executed in dry run | ✅ Skipped |

---

### Scenario 4.2 — Live full restore

| Parameter | Value |
|---|---|
| `agentPool` | `hmcts-sandbox-agent-pool` |
| `dryRun` | `false` |
| `restoreMode` | `all` |
| `sourceServerName` | `plum-v14-flexible-sandbox` |
| `sourceResourceGroup` | `plum-v14-flexible-data-sandbox` |
| `sourceSubscription` | `'none'` |
| `vaultResourceGroup` | `mgmt-infra-prod-rg` |
| `vaultName` | `cnp-backup-vault` |
| `vaultSubscription` | `'none'` |
| `recoveryPointTimeUtc` | `'none'` (latest) |

**Expected:** Full end-to-end — container created, vault restore triggered and polled, roles replayed, all databases restored in sequence, Stage 3 validates all databases.

| Checkpoint | Expected | Status |
|---|---|---|
| Container created with unique generated name | Container visible in storage account | ✅ `plumv14flexiblesandbox53131703261051881` |
| Source server config logged | SKU, version, storage, location, subnet | ✅ `Standard_B1ms`, v16, 64GB, `uksouth` |
| Restored server created | Server provisioned and reaches `Ready` state | ✅ `plum-v14-flexible-sandbox-restore-5313170326` — Ready at ~330s |
| `shared_preload_libraries` propagated | Source libraries applied to restored server | ✅ `pg_cron,pg_stat_statements` — already matched, no restart needed |
| Vault restore job completed | `restoreJobStatus: Completed` in metrics | ✅ Confirmed (Stage 2) |
| Roles replayed once before loop | "Restoring roles" appears once | ✅ Confirmed |
| `plum` restored (empty DB) | No errors, no data | ✅ Confirmed |
| `rhubarb` restored with allow-list warning | `pgstattuple` rejected, WARN logged, restore continues | ✅ WARN logged — all non-extension objects restored |
| System databases skipped | `azure_maintenance`, `azure_sys`, `postgres`, `template1` skipped | ✅ `template1` skip logged; others skipped silently |
| Local dump files deleted after each restore | No `_database_*.sql` files in artifact | ✅ `6 database(s) restored in 4s` |
| Stage 3: all user databases listed | `plum`, `rhubarb` | ✅ Confirmed |
| Stage 3: `rhubarb` — 7 user tables in `public` schema | All tables restored | ✅ `dh_test`, `dh_test_audit`, `dh_testing_constraints`, `dh_testing_constraints_table1`, `dh_testing_constraints_table2`, `flyway_schema_history`, `recipe` |
| Stage 3: `rhubarb` — row counts | Non-zero across tables | ✅ Total 19 estimated rows across 7 tables (`dh_test_audit`: 9, `dh_test`: 3, constraints tables: 2 each, `flyway_schema_history`: 1, `recipe`: 0) |
| Stage 3: `rhubarb` totals | `total_tables=7`, `total_estimated_rows=19` | ✅ Confirmed |
| `restore-metrics.json` complete | Vault job details + `databaseRestores` array | ✅ Confirmed |
| `restore-output` artifact published | Artifact visible in pipeline summary | ✅ Confirmed |

**Note on `--high-availability` deprecation warning:** The `az postgres flexible-server create` flag `--high-availability` is deprecated in favour of `--zonal-resiliency`, scheduled for removal in CLI 2.86.0 (May 2026). The pipeline should be updated before that release. See [future-improvements.md](future-improvements.md).

---

### Scenario 4.3 — Live full restore (parallel run, different source server)

Run concurrently with Scenario 4.2 to verify the pipeline handles simultaneous restores correctly and that the prefix-fallback blob discovery works when the vault writes files with a UUID prefix rather than the pipeline-generated prefix.

| Parameter | Value |
|---|---|
| `sourceServerName` | `crumble-v14-flexible-sandbox` |
| `restoreMode` | `all` |
| `dryRun` | `false` |

| Checkpoint | Expected | Status |
|---|---|---|
| Vault restore job completed | `restoreJobStatus: Completed` | ✅ Completed (~2m) |
| Prefix fallback triggered | Blobs found after retrying without prefix filter | ✅ "No blobs matched with prefix 'restore-1051880-0014170326', retrying without prefix filter" — 6 blobs found via fallback |
| System databases skipped | `azure_maintenance`, `azure_sys`, `postgres`, `template1` skipped | ✅ All 4 skipped |
| `plum` restored (empty DB) | Schema only, no tables | ✅ Confirmed |
| `rhubarb` restored (slimmer schema) | 2 tables: `flyway_schema_history`, `recipe` | ✅ Confirmed — no `pgstattuple` extension on this server |
| Stage 3: `rhubarb` totals | `total_tables=2`, `total_estimated_rows=1` | ✅ `flyway_schema_history`: 1 row, `recipe`: 0 rows |
| Pipeline completed successfully | All 3 stages passed | ✅ Confirmed |

**Notes:**
- This `rhubarb` instance has a simpler schema (2 tables vs 7 on `plum-v14-flexible-sandbox`) — confirms the restore is faithful to the specific source server's schema, not a fixed template.
- No `pgstattuple` extension present on this server — clean `pg_restore` exit, no allow-list warnings.
- The prefix fallback is working as designed: Azure Backup Vault writes blobs with a UUID prefix; the pipeline falls back gracefully when the generated prefix doesn't match.

---

## Stage 5 — CPP pipeline (database-only restore)

Tests the CPP-specific pipeline (`azure-pipelines-restore-cpp.yaml`) against CPP infrastructure, using an existing vault-to-blob restore container and restoring onto a pre-provisioned Postgres server.

### Scenario 5.1 — CPP live database-only restore

**Pipeline:** `azure-pipelines-restore-cpp.yaml`
**Date:** 2026-03-19
**Environment:** nonlive (MDV)

| Parameter | Value |
|---|---|
| `environment` | `nonlive` |
| `restoreStorageAccount` | `sacppvaultrestoremdv` |
| `sourceServerName` | `psf-dev-ccm08-peach` |
| `sourceResourceGroup` | `RG-DEV-CCM-01` |
| `vaultResourceGroup` | `cpp-infra-sbox-rg` |
| `vaultName` | `cpp-backup-vault` |
| `restoreMode` | `database-only` |
| `existingRestoreContainer` | `psfdevccm08peach0016190326502952` |
| `dryRun` | `false` |

**Stage 1 — Provision**

| Checkpoint | Expected | Status |
|---|---|---|
| Storage container resolved | Existing container accepted for `database-only` mode | ✅ `psfdevccm08peach0016190326502952` |
| Postgres server created | `Standard_D2s_v3`, version 11, 32GB, private subnet | ✅ `psf-dev-ccm08-peach-restore-0016190326` ready in ~270s |
| `shared_preload_libraries` propagated | Source libraries applied to restored server | ✅ `pg_cron,pg_stat_statements` — already matched, no restart needed |

**Stage 2 — Restore (from `restore-metrics.json`)**

| Checkpoint | Expected | Status |
|---|---|---|
| Vault restore job | `restoreJobStatus: Completed` | ✅ Completed (~155s) |
| Target storage account | `sacppvaultrestoremdv` | ✅ Confirmed |
| Prefix fallback triggered | Blobs found after retrying without prefix filter | ✅ "No blobs matched with prefix 'restore-502947-4615190326', retrying without prefix filter" — 7 blobs found via fallback |
| System databases skipped | `azure_maintenance`, `azure_sys`, `postgres`, `template1` skipped | ✅ All 4 skipped |
| `peopleeventstore` restored | Schema + data via `pg_restore` | ✅ 1s — `pg_stat_statements` allow-list WARN, all application objects restored |
| `peoplesystem` restored | Schema + data via `pg_restore` | ✅ 1s |
| `peopleviewstore` restored | Schema + data via `pg_restore` | ✅ 1s — `pg_stat_statements` allow-list WARN |
| Total database restore duration | All DBs restored | ✅ 5s (3 databases) |

**Stage 3 — Validation**

| Checkpoint | Expected | Status |
|---|---|---|
| User tables present | Application schema restored | ✅ 9 tables: `databasechangelog`, `databasechangeloglock`, `person`, `processed_event`, `stream_buffer`, `stream_error`, `stream_error_hash`, `stream_status`, `stream_metrics` (materialised view) |
| `databasechangelog` row count | Schema migrations present | ✅ 30 rows |
| Totals | `total_tables=9`, `total_estimated_rows=31` | ✅ Confirmed |
| Pipeline completed successfully | All 3 stages passed | ✅ Confirmed |

**Notes:**
- `pg_stat_statements` allow-list warnings are benign — the extension is managed by Azure and does not affect application data. The script correctly detects these as non-fatal and logs a WARN rather than failing.
- Dev server (`psf-dev-ccm08-peach`) has sparse data — 0 rows in most tables is expected for a dev environment; `databasechangelog` row count confirms Liquibase migrations applied successfully on the source.
- `stream_metrics` appears as a materialised view and is counted in `pg_stat_user_tables`, contributing 1 row to the total.
