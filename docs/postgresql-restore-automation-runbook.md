# PostgreSQL UK South Restore Automation Runbook

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

## Workflow implemented

1. Resolve the backup instance from Backup Vault:
   - explicit instance name (`backupInstanceName`)
   - or friendly-name filter (`backupInstanceFriendlyNameFilter`)
2. List available recovery points and select one of:
   - explicit recovery point id (`recoveryPointId`)
   - nearest point at/before UTC timestamp (`recoveryPointTimeUtc`)
   - latest recovery point (default)
3. Trigger restore-to-files into a target storage container in UK South.
4. Poll restore job status until completion/failure/timeout.
5. Record metrics into `restore-output/restore-metrics.json`.
6. Optional: restore database files into target PostgreSQL flexible server using `pg_restore` (fallback to `psql`), including optional role restoration.

## Required permissions

For the **Backup Vault managed identity**:

- `PostgreSQL Flexible Server Long Term Retention Backup Role` on source/target server scope (as required)
- `Reader` on source resource group
- `Storage Blob Data Contributor` on target storage account

For the **ADO service principal / workload identity** used by pipeline:

- Read backup instances/recovery points
- Trigger restore jobs
- Read backup job status
- Blob read/write in target storage account (if executing db restore phase)
- (Optional db restore phase) network and authentication access to target PostgreSQL

## Variable and secret setup

Create or reuse a variable group per project containing:

- `targetPostgresAdminPassword` (secret)

Recommended non-secret runtime parameters:

- `vaultResourceGroup`
- `vaultName`
- `backupInstanceName` or `backupInstanceFriendlyNameFilter`
- `recoveryPointId` or `recoveryPointTimeUtc`
- `targetStorageAccount`
- `targetStorageContainer`
- `runDatabaseRestore`
- `targetPostgresHost`, `targetPostgresAdminUser`, `targetPostgresDatabase`

## Parallel restore testing

The design supports parallel runs by:

- no shared lock/state in scripts
- unique output directory per run
- unique restore target filename prefix (`restore-$(Build.BuildId)` by default)

For parallel test evidence, run two or more pipeline executions simultaneously with different database targets and collect each run's `restore-metrics.json` artifact.

## RTO measurement

`restore-output/restore-metrics.json` contains:

- `restoreDurationSeconds`: backup-vault restore (trigger to job completion)
- `databaseRestore.databaseRestoreDurationSeconds`: optional storage-to-database restore duration

Use total observed RTO as:

`restoreDurationSeconds + databaseRestoreDurationSeconds` (when database phase enabled).

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
- `roles.sql` can include service-managed roles that error on replay; script treats this as non-fatal.
- Recovery point frequency and restore availability depend on backup policy execution.

## Evidence checklist for ticket acceptance

For each test case (Plum, Peach, large clone):

- pipeline run id
- selected backup instance
- selected recovery point
- restore job id and final status
- RTO metrics JSON artifact
- validation output for restored DB (row count/sample checksum/smoke query)
