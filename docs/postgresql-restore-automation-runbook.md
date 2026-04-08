# PostgreSQL UK South Restore Automation Runbook

**Quick Reference for Operators**

> **Lessons from Large Restores (600GB+)**
>
> **Key findings from recent large-scale restores:**
>
> - **Increase both server SKU and agent resources:** For datasets above ~200GB, especially 600GB+, increase the PostgreSQL server SKU (CPU/RAM/IOPS) and the Azure DevOps agent size (CPU/memory) to avoid bottlenecks and ensure restore stability. See ADR-014 for rationale.
> - **WAL tuning is critical:** The restore script temporarily disables `fsync` and `full_page_writes` during the restore phase, then restores them. This improves throughput by 25–35% on IOPS-constrained storage. See ADR-015 for details and risk analysis.
> - **Index rebuild dominates RTO:** For very large tables, index (primary key) rebuild time is the main factor in total restore duration, not the data COPY phase. Higher IOPS SKUs reduce this bottleneck.
> - **Script robustness:** All Bash variables are now initialized and error handling is hardened to prevent runtime failures (e.g., unbound variables). Always use the latest script version.
> - **Evidence:** The 600GB restore completed successfully after scaling up both server and agent, with WAL tuning enabled. RTO improved by 25–35% compared to untuned runs.
>
> **References:**
> - [ADR-014: Agent Resource Scaling](architecture-decisions.md#adr-014-restore-pipeline-agent-resources-can-be-increased-to-improve-restore-speed-and-stability)
> - [ADR-015: WAL Tuning](architecture-decisions.md#adr-015-wal-tuning-for-restore-performance-optimization)
> - [restore-test-scenarios.md](restore-test-scenarios.md)

This runbook documents the automated restore workflow for Azure Database for PostgreSQL Flexible Server backups managed via Azure Backup Vault.

It covers:

- CNP and CPP Azure DevOps pipeline entry points
- Backup instance and recovery point selection
- Restore initiation and job tracking
- Optional database-level restore (from storage to target PostgreSQL)
- RTO capture and evidence collection

## Pipelines

- CNP: `azure-pipelines-restore-cnp.yaml`
- CPP: `azure-pipelines-restore-cpp.yaml`

Both are manual pipelines (no CI trigger) and support concurrent runs.
Both expose a `dryRun` pipeline parameter (default `true`) so you can safely validate selection logic before running a real restore.

## Pipeline parameters

Both pipelines expose identical parameters. The CNP pipeline registers against `DCD-CNP-Prod`; the CPP pipeline against `ado_live_workload_identity`.

> **Always start with `dryRun=true`** to confirm instance and recovery point resolution before committing to a live run.

### Required parameters (no default — must always be supplied)

| Parameter | Description |
|---|---|
| `sourceServerName` | Name of the source PostgreSQL Flexible Server (e.g. `crumble-v14-flexible-sandbox`). Used to look up the source server configuration and to auto-match the vault backup instance. |
| `sourceResourceGroup` | Resource group containing `sourceServerName`. Used to read the source server SKU, version, network config, and to create the restored server in the same resource group. |
| `vaultResourceGroup` | Resource group containing the Azure Backup Vault. Ignored when `restoreMode=database-only` but must still be supplied. |
| `vaultName` | Name of the Azure Backup Vault. Ignored when `restoreMode=database-only` but must still be supplied. |

### `restoredServerName`

| Value | Behaviour |
|---|---|
| `auto` (default) | Restored server is named `${sourceServerName}-restore-<mhddmmyy>`. Ignored when `restoreMode=vault-only` (no server is created). |
| Any explicit name | Uses that name for the restored server. |

> `auto` works for `all` and `database-only` modes. In both modes the server is created from source server config if it does not already exist, or reused if it does.

### `restoreMode`

| Value | What runs |
|---|---|
| `all` (default) | Stage 1: create blob container + create Postgres server (if not exists). Stage 2: vault restore → blob storage → all databases. Stage 3: validate. |
| `vault-only` | Stage 1: create blob container only (no server). Stage 2: vault restore to blob storage only. Stage 3: skipped. |
| `database-only` | Stage 1: create Postgres server (if not exists, using source server config). Stage 2: restore all database blobs from `existingRestoreContainer` to Postgres. Stage 3: validate. |

**Two-phase restore workflow** (`vault-only` then `database-only`): run `vault-only` first to move backup files from the vault into blob storage, then run `database-only` supplying `existingRestoreContainer` (the container created in the first run). The server will be created automatically in the `database-only` run if it does not already exist. Useful when you want to inspect the blob contents before loading into Postgres, or need to re-run the database restore independently.

### `dryRun`

| Value | Behaviour |
|---|---|
| `true` (default) | Read-only. Discovers vault instances, recovery points, and/or blobs depending on `restoreMode`. Prints a preview of all mutating commands. No Azure resources or databases are changed. |
| `false` | Live run. Executes all stages for the selected `restoreMode`. |

### `existingRestoreContainer`

| Value | Behaviour |
|---|---|
| `none` (default) | Ignored for `all` and `vault-only` — a new container is created automatically. |
| Any container name | **Required when `restoreMode=database-only`** (including `dryRun=true`). Must be the exact name of the blob storage container created by a prior `vault-only` or `all` run. |

### Backup instance selection (`backupInstanceName` / `backupInstanceFriendlyNameFilter`)

Azure Backup Vault tracks each protected PostgreSQL Flexible Server as a "backup instance". The instance name follows the convention `${serverName}-backup-instance`. To look up the name:

```bash
az dataprotection backup-instance list \
  -g <vaultResourceGroup> --vault-name <vaultName> -o table
```

Or in the portal: **Backup vault → Backup instances** (left nav) — the **Name** column.

| Scenario | What to supply |
|---|---|
| Default (recommended) | Leave both as `none`. The script automatically uses `sourceServerName` as a substring match against the instance `friendlyName`. |
| Auto-match is ambiguous (multiple instances match) | Set `backupInstanceName` to the exact full instance name (e.g. `crumble-v14-flexible-sandbox-backup-instance`). |
| Custom match pattern needed | Set `backupInstanceFriendlyNameFilter` to a regex or substring; matched case-insensitively against `friendlyName`. |
| `restoreMode=database-only` | Both parameters are ignored — the vault is not queried. |

If both `backupInstanceName` and `backupInstanceFriendlyNameFilter` are set, `backupInstanceName` takes precedence.

### Important: Datasource Identity and Soft-Deleted Backup Instances

Azure Backup does **not** treat a recreated PostgreSQL Flexible Server with the same name as a brand-new datasource. The vault tracks the protected datasource by the PostgreSQL server ARM resource ID:

`/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.DBforPostgreSQL/flexibleServers/<server-name>`

If a server is deleted and recreated with the same subscription, resource group, and server name, the ARM resource ID is reused. If the previous backup instance for that datasource is still `SoftDeleted` in the vault, a new registration attempt fails even if:
- the restore came from a different source server
- a different recovery point was used
- a different backup instance name was supplied

Typical vault error:

> `Datasource is already associated with the backup instance <name> ... with the protection status as SoftDeleted.`

Operational guidance:
1. Before protecting a recreated restore target, check the vault for a soft-deleted backup instance for the same server name.
2. Purge or recover that soft-deleted backup instance before retrying protection.
3. For repeated test runs, prefer a unique restore target server name each time to avoid reusing the same datasource ARM resource ID.

### Recovery point selection (`recoveryPointId` / `recoveryPointTimeUtc`)

| Scenario | What to supply |
|---|---|
| Default (recommended) | Leave both as `none`. The most recent available recovery point is selected automatically. |
| Restore to a specific point in time | Set `recoveryPointTimeUtc` to an ISO-8601 UTC timestamp (e.g. `2026-03-10T02:00:00Z`). The script selects the latest recovery point **at or before** that time. |
| Pin to a specific recovery point | Set `recoveryPointId` to the exact vault recovery point identifier. |
| `restoreMode=database-only` | Both parameters are ignored — the vault is not queried. |

Do not set both; `recoveryPointId` takes precedence if both are provided.

### Remaining parameters

| Parameter | Default | Description |
|---|---|---|
| `serviceConnection` | CNP: `DCD-CNP-Prod` / CPP: `ado_live_workload_identity` | Azure DevOps service connection for all Azure CLI calls. |
| `agentPool` | CNP: `ubuntu-latest` / CPP: `MPD-ADO-AGENTS-01` | Agent pool for all pipeline jobs. |
| `restoreLocation` | `uksouth` | Azure region passed to the vault restore request. Must match the vault's region. |
| `restoreTimeoutMinutes` | `240` | Minutes to wait for the vault restore job before failing. |
| `pollSeconds` | `30` | Seconds between vault restore job status polls. |
| `restoreRoles` | `true` | Restores the `_roles.sql` blob before the per-database loop, replaying server-level roles. Known managed-PostgreSQL errors (e.g. "already exists", "must be superuser") are filtered as warnings; unexpected errors fail the restore. |
| `targetPostgresPort` | `5432` | Port for all `psql` / `pg_restore` connections to the restored server. |

### Variable groups (secrets)

Each pipeline reads credentials from a pre-configured ADO variable group:

| Platform | Variable group | Variables |
|---|---|---|
| CNP | `cnp-backup-vault-restore-secrets` | `targetPostgresAdminUser` (plain text), `targetPostgresAdminPassword` (secret) |
| CPP | `cpp-backup-vault-restore-secrets` | `targetPostgresAdminUser` (plain text), `targetPostgresAdminPassword` (secret) |

These credentials are used to create the restored Postgres server (Stage 1) and to connect to it for the database restore and validation stages (Stages 2 and 3).


## WAL Tuning for Restore Performance

During the database restore phase, the script temporarily disables PostgreSQL settings `fsync` and `full_page_writes` to improve throughput by 25–35% on IOPS-constrained storage. These settings are automatically restored after the restore completes (even if interrupted), ensuring no risk to subsequent workloads.

**Why it’s safe:**
- The restore is a one-shot, idempotent operation with no other clients connected.
- If the restore is interrupted, simply re-run the job; no production data is at risk.
- The script uses a Bash trap to guarantee settings are restored even on failure.

**Do not use this tuning for production workloads.** It is only safe for isolated restore jobs.

See [ADR-015](architecture-decisions.md#adr-015-wal-tuning-for-restore-performance-optimization) for full rationale, risk analysis, and implementation details.

## Workflow implemented

1. Resolve the backup instance from Backup Vault:
   - auto-match on `sourceServerName` (default)
   - or explicit instance name (`backupInstanceName`)
   - or friendly-name filter (`backupInstanceFriendlyNameFilter`)
2. List available recovery points and select one of:
   - latest recovery point (default)
   - nearest point at or before UTC timestamp (`recoveryPointTimeUtc`)
   - explicit recovery point id (`recoveryPointId`)
3. Trigger restore-to-files into a target storage container.
4. Poll restore job status until completion/failure/timeout.
5. Record metrics into `restore-output/restore-metrics.json`.
6. Restore all database blobs from storage onto the target PostgreSQL Flexible Server using `pg_restore` (fallback to `psql`), including optional role restoration.

## Required permissions

No new Service Principal is required. The existing ADO service connections (`DCD-CNP-Prod` for CNP, `ado_live_workload_identity` for CPP) can be used, but require specific role assignments in addition to any broad `Contributor` access they already hold.

### ADO service principal / workload identity

Creating a PostgreSQL Flexible Server with private networking spans **three subscriptions** — the source server's subscription, the VNet/subnet subscription, and the private DNS zone subscription. The SP requires roles in all three.

For CNP sandbox the confirmed resource locations are:

| Resource | Subscription |
|---|---|
| Source Postgres server + resource group | `sourceSubscription` (e.g. `8999dec3-...`) |
| Delegated subnet (`cft-sbox-network-rg / cft-sbox-vnet / postgres-expanded`) | `b72ab7b7-723f-4b18-b6f6-03b0f2c6a1bb` |
| Private DNS zone (`private.postgres.database.azure.com` in `core-infra-intsvc-rg`) | `1baf5470-1c3e-40d3-a6f7-74bfbce4b348` |

The pipeline performs the following Azure operations and requires the corresponding roles:

| Operation | Stage | Restore modes | Required role | Scope |
|---|---|---|---|---|
| `az storage container create --auth-mode login` | 1 | `all`, `vault-only` | `Contributor` (or `Storage Account Contributor`) | Restore storage account (or its resource group) |
| `az storage blob list --auth-mode login` | 2 | `all`, `database-only` | `Storage Blob Data Reader` | Restore storage account |
| `az storage blob download --auth-mode login` | 2 | `all`, `database-only` | `Storage Blob Data Reader` | Restore storage account |
| `az postgres flexible-server show` (read source config) | 1 | `all`, `database-only` | `Reader` | Source resource group |
| `az postgres flexible-server create` | 1 | `all`, `database-only` | `Contributor` | Source resource group |
| `--subnet` join on new server | 1 | `all`, `database-only` | `Network Contributor` (or custom with `Microsoft.Network/virtualNetworks/subnets/join/action`) | Subnet / VNet resource group in networking subscription |
| `--private-dns-zone` link on new server | 1 | `all`, `database-only` | `Private DNS Zone Contributor` (or custom with `privateDnsZones/join/action` + `virtualNetworkLinks/write`) | DNS zone resource group in DNS subscription |
| `az dataprotection backup-instance list/restore trigger` | 2 | `all`, `vault-only` | `Backup Contributor` | Backup vault (or vault resource group) |
| `az dataprotection recovery-point list` | 2 | `all`, `vault-only` | `Backup Reader` | Backup vault (or vault resource group) |
| `az dataprotection job show` | 2 | `Backup Reader` | Backup vault (or vault resource group) |

`az storage container create --auth-mode login` hits the blob service data-plane endpoint with an OAuth token, but Azure Storage authorises **container-level** operations against the management-plane RBAC action `Microsoft.Storage/storageAccounts/blobServices/containers/write`, which is included in `Contributor` and `Storage Account Contributor`. `Storage Blob Data Contributor` is **not** required for container creation.

`Storage Blob Data Reader` is sufficient for blob listing and downloading (Stage 2 script operations). Container creation (Stage 1) is skipped in `database-only` mode, so `database-only` runs only need `Storage Blob Data Reader` on the restore storage account for blob operations. However `database-only` now also provisions the Postgres server (if absent), so it requires the same source-resource-group roles as `all` mode.

> **Note:** `Storage Blob Data Reader` and `Storage Blob Data Contributor` are data-plane roles that must be assigned explicitly on the restore storage account — they are **not** inherited from subscription or resource group `Contributor`. The management-plane `Contributor` role does **not** grant blob read/write data-plane access.

`Backup Contributor` covers all dataprotection read and write actions including triggering restores. `Backup Reader` is a subset; assign `Backup Contributor` and both are satisfied.

`Contributor` on the source resource group covers both reading the source server config and creating the restored server. The subnet and DNS zone roles must be assigned separately in their respective subscriptions — `Contributor` on the source resource group does not extend to resources in other subscriptions.

### Backup Vault managed identity

This is a separate identity from the ADO SP — it is the identity that performs the actual vault-to-blob-storage transfer when a restore job is triggered. It requires:

| Role | Scope |
|---|---|
| `Storage Blob Data Contributor` | Restore storage account |
| `PostgreSQL Flexible Server Long Term Retention Backup Role` | Source PostgreSQL Flexible Server |

These assignments should already be configured by the Terraform module that provisioned the vault. If they are missing, the restore job will be triggered successfully but will fail with an authorisation error during execution.

## Artifacts and failure handling

The pipelines publish the `restore-output` artifact using `condition: always()`, so logs/metrics are retained for both successful and failed runs.

## Parallel restore testing

The design supports parallel runs by:

- no shared lock/state in scripts
- unique output directory per run
- unique restore target filename prefix (`restore-$(Build.BuildId)` by default)

For parallel test evidence, run two or more pipeline executions simultaneously with different database targets and collect each run's `restore-metrics.json` artifact.

## RTO measurement

`restore-output/restore-metrics.json` contains:

- `restoreDurationSeconds`: backup-vault restore (trigger to job completion)
- `totalDatabaseRestoreDurationSeconds`: total wall-clock time for all database restores combined (present when database phase ran)

Use total observed RTO as:

`restoreDurationSeconds + totalDatabaseRestoreDurationSeconds` (when database phase enabled).

## Immutability lock sequencing

Use **Unlocked** immutability for test execution, metrics collection, and cleanup.

After test completion and sign-off:

1. Confirm test evidence is retained.
2. Confirm no further backup policy changes are needed.
3. Lock immutability in Terraform configuration and apply via standard infra pipeline.

> Locking is intentionally not automated in restore pipeline to avoid accidental irreversible changes.

## Known caveats

- Restore for PostgreSQL Flexible Server is a **restore-to-files first** flow.
- Azure may prepend UUID-style prefixes to restored files.
- `roles.sql` can include service-managed roles that error on replay; script now filters known managed-role errors and fails on unexpected role errors.
- Recovery point frequency and restore availability depend on backup policy execution.

## Role restore hardening and logs

When `restoreRoles=true` and a roles file is present, the script performs a hardened role replay process:

1. Replays `roles.sql` and captures full output to `restore-output/roles-restore.log`.
2. Extracts all `ERROR`/`FATAL` lines to `restore-output/roles-restore-errors.log`.
3. Filters known managed-service role limitations; any remaining lines are written to `restore-output/roles-restore-critical.log`.

Behavior:

- If `psql` returns a non-zero exit code, the restore fails.
- If `roles-restore-critical.log` contains lines, the restore fails.
- If only known managed-role warnings are present, the restore continues and logs a warning.

## Evidence checklist for ticket acceptance

For each test case (Plum, Peach, large clone):

- pipeline run id
- selected backup instance
- selected recovery point
- restore job id and final status
- RTO metrics JSON artifact
- validation output for restored DB (row count/sample checksum/smoke query)
