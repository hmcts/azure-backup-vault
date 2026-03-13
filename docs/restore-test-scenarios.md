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
> Container names follow the pattern `<serverslug><buildId><mhddmmyy>` (all lowercase alphanumeric, no separators), e.g. `plumv14flexiblesandbox12345637101326`.
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
| Log lists same number of database blobs as verified in 2.1 | Blob count matches | — |
| Roles blob identified | Roles blob name logged | — |
| No Postgres server created | No server provisioning in log | — |

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
| Restored Postgres server created | Server FQDN logged | — |
| Roles replayed once before loop | "Restoring roles" appears once in log | — |
| Each database blob downloaded and restored in sequence | One "Restoring database:" block per DB | — |
| Local dump files deleted after each restore | No `_database_*.sql` files in artifact | — |
| Stage 3: all user databases listed | Same databases as source | — |
| Stage 3: non-zero `total_tables` per database | Data present in each database | — |
| Stage 3: non-zero `total_estimated_rows` per database | Rows present in each database | — |
| `restore-metrics.json` has `databaseRestores` array | One entry per database with duration | — |

---

## Stage 4 — Full end-to-end (vault + server + all databases in one run)

### Scenario 4.1 — Dry run: full end-to-end preview

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

**Expected:** Full discovery preview — vault instances, recovery points, blob list (empty in dry run, expected). Confirms all parameters wired correctly before committing.

| Checkpoint | Expected | Status |
|---|---|---|
| Vault instance resolved | Instance name logged | — |
| Recovery point resolved | Recovery point ID logged | — |
| Dry run preview commands printed | `[DRY RUN PREVIEW]` lines in log | — |
| No container created | Storage account unchanged | — |
| No server created | No server provisioning in log | — |

---

### Scenario 4.2 — Live full restore

| Parameter | Value |
|---|---|
| `agentPool` | `<your-self-hosted-pool>` |
| `dryRun` | `false` |
| `restoreMode` | `all` |
| `sourceServerName` | `<your-source-server>` |
| `sourceResourceGroup` | `<rg>` |
| `sourceSubscription` | `'none'` (or subscription ID if cross-subscription) |
| `vaultResourceGroup` | `<vault-rg>` |
| `vaultName` | `<vault-name>` |
| `vaultSubscription` | `'none'` (or subscription ID if cross-subscription) |
| `recoveryPointTimeUtc` | `<ISO8601 timestamp e.g. 2026-03-11T02:00:00Z>` |

**Expected:** Full end-to-end — container created, vault restore triggered and polled, roles replayed, all databases restored in sequence, Stage 3 validates all databases.

| Checkpoint | Expected | Status |
|---|---|---|
| Container created with unique generated name | Container visible in storage account | — |
| Vault restore job completed | `restoreJobStatus: Completed` in metrics | — |
| Correct recovery point selected | Logged recovery point at or before requested time | — |
| Roles replayed once before loop | "Restoring roles" appears once | — |
| Each database restored in sequence | One "Restoring database:" block per DB | — |
| Local dump files deleted after each restore | No `_database_*.sql` files in artifact | — |
| Stage 3: all user databases present | Same set as source | — |
| Stage 3: non-zero `total_tables` per database | Data present in each database | — |
| Stage 3: non-zero `total_estimated_rows` per database | Rows present in each database | — |
| `restore-metrics.json` complete | Vault job details + `databaseRestores` array | — |
| `restore-output` artifact published | Artifact visible in pipeline summary | — |
