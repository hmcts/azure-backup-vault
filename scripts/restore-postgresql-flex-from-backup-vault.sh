#!/usr/bin/env bash

set -euo pipefail

log() {
  echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] $*"
}

fail() {
  log "ERROR: $*"
  exit 1
}

require_env() {
  local key="$1"
  [[ -n "${!key:-}" ]] || fail "Missing required environment variable: ${key}"
}

find_instance_by_name() {
  local instances_json="$1"
  local instance_name="$2"
  echo "$instances_json" | jq -r --arg name "$instance_name" '.[] | select(.name == $name) | .name' | head -n1
}

find_instance_by_friendly_name() {
  local instances_json="$1"
  local friendly_name_filter="$2"
  local matches
  matches=$(echo "$instances_json" | jq -r --arg filter "$friendly_name_filter" '.[] | select((.properties.friendlyName // "") | test($filter; "i")) | .name')

  local count
  count=$(echo "$matches" | sed '/^$/d' | wc -l | tr -d ' ')

  if [[ "$count" -gt 1 ]]; then
    log "More than one backup instance matches filter '${friendly_name_filter}'."
    log "Please provide BACKUP_INSTANCE_NAME explicitly. Matching options:"
    echo "$instances_json" | jq -r --arg filter "$friendly_name_filter" '.[] | select((.properties.friendlyName // "") | test($filter; "i")) | "- \(.name) [\(.properties.friendlyName // "unknown")]"'
    exit 2
  fi

  echo "$matches" | head -n1
}

select_recovery_point() {
  local recovery_points_json="$1"
  local recovery_point_id="${2:-}"
  local recovery_point_time_utc="${3:-}"

  if [[ -n "$recovery_point_id" ]]; then
    echo "$recovery_points_json" | jq -r --arg rp "$recovery_point_id" '.[] | select(.name == $rp) | .name' | head -n1
    return
  fi

  if [[ -n "$recovery_point_time_utc" ]]; then
    echo "$recovery_points_json" | jq -r --arg ts "$recovery_point_time_utc" '
      map({name: .name, t: (.properties.recoveryPointTime | fromdateiso8601)})
      | map(select(.t <= ($ts | fromdateiso8601)))
      | sort_by(.t)
      | last
      | .name // empty
    '
    return
  fi

  echo "$recovery_points_json" | jq -r '
    map({name: .name, t: (.properties.recoveryPointTime | fromdateiso8601)})
    | sort_by(.t)
    | last
    | .name // empty
  '
}

discover_database_blob() {
  local blobs_json="$1"
  local db_name="$2"
  local file_prefix="${3:-}"

  echo "$blobs_json" | jq -r --arg db "$db_name" --arg prefix "$file_prefix" '
    map(select(
      ((.name | ascii_downcase) | endswith(("_database_" + ($db | ascii_downcase) + ".sql")))
      and (if $prefix != "" then (.name | startswith($prefix)) else true end)
    ))
    | sort_by(.properties.lastModified // "")
    | reverse
    | first
    | .name // empty
  '
}

discover_roles_blob() {
  local blobs_json="$1"
  local file_prefix="${2:-}"

  echo "$blobs_json" | jq -r --arg prefix "$file_prefix" '
    map(select(
      ((.name | ascii_downcase) | endswith("_roles.sql"))
      and (if $prefix != "" then (.name | startswith($prefix)) else true end)
    ))
    | sort_by(.properties.lastModified // "")
    | reverse
    | first
    | .name // empty
  '
}

main() {
  require_env "VAULT_RESOURCE_GROUP"
  require_env "VAULT_NAME"
  require_env "TARGET_STORAGE_ACCOUNT"
  require_env "TARGET_STORAGE_CONTAINER"
  require_env "RESTORE_LOCATION"

  local dry_run="${DRY_RUN:-true}"
  local backup_instance_name="${BACKUP_INSTANCE_NAME:-}"
  local backup_instance_friendly_name_filter="${BACKUP_INSTANCE_FRIENDLY_NAME_FILTER:-}"
  local recovery_point_id="${RECOVERY_POINT_ID:-}"
  local recovery_point_time_utc="${RECOVERY_POINT_TIME_UTC:-}"
  local target_file_prefix="${TARGET_FILE_PREFIX:-restore-${BUILD_BUILDID:-local}}"
  local restore_timeout_minutes="${RESTORE_TIMEOUT_MINUTES:-240}"
  local poll_seconds="${POLL_SECONDS:-30}"
  local run_database_restore="${RUN_DATABASE_RESTORE:-false}"
  local restore_roles="${RESTORE_ROLES:-true}"
  local postgres_port="${TARGET_POSTGRES_PORT:-5432}"

  mkdir -p restore-output
  local metrics_file="restore-output/restore-metrics.json"
  local request_file="restore-output/restore-request.json"
  local trigger_file="restore-output/restore-trigger.json"
  local target_container_uri="https://${TARGET_STORAGE_ACCOUNT}.blob.core.windows.net/${TARGET_STORAGE_CONTAINER}"
  local restore_target_file_name="${target_file_prefix}-$(date -u +"%Y%m%d%H%M%S")"

  if [[ "${dry_run,,}" == "true" ]]; then
    log "DRY_RUN=true: mutating Azure/PostgreSQL commands are disabled."
    log "Running read-only Azure discovery commands."

    if ! command -v az >/dev/null 2>&1; then
      fail "Azure CLI (az) is required for dry-run read-only discovery."
    fi

    local instances_json
    instances_json=$(az dataprotection backup-instance list -g "$VAULT_RESOURCE_GROUP" --vault-name "$VAULT_NAME" -o json)

    log "Available backup instances:"
    echo "$instances_json" | jq -r '.[] | "- \(.name) [\(.properties.friendlyName // "unknown")]"'

    local selected_instance_name=""
    if [[ -n "$backup_instance_name" ]]; then
      selected_instance_name=$(find_instance_by_name "$instances_json" "$backup_instance_name")
    elif [[ -n "$backup_instance_friendly_name_filter" ]]; then
      selected_instance_name=$(find_instance_by_friendly_name "$instances_json" "$backup_instance_friendly_name_filter")
    fi

    local selected_recovery_point_id=""
    if [[ -n "$selected_instance_name" ]]; then
      log "Selected backup instance: ${selected_instance_name}"
      local recovery_points_json
      recovery_points_json=$(az dataprotection recovery-point list \
        --backup-instance-name "$selected_instance_name" \
        -g "$VAULT_RESOURCE_GROUP" \
        --vault-name "$VAULT_NAME" \
        -o json)

      log "Available recovery points (UTC):"
      echo "$recovery_points_json" | jq -r '.[] | "- \(.name) @ \(.properties.recoveryPointTime)"'

      selected_recovery_point_id=$(select_recovery_point "$recovery_points_json" "$recovery_point_id" "$recovery_point_time_utc")
      if [[ -n "$selected_recovery_point_id" ]]; then
        log "Selected recovery point: ${selected_recovery_point_id}"
      else
        log "Could not resolve recovery point from provided inputs."
      fi
    else
      log "Backup instance not resolved from provided filters. Skipping recovery-point lookup."
    fi

    if [[ "${run_database_restore}" == "true" ]]; then
      local blobs_json
      blobs_json=$(az storage blob list \
        --account-name "$TARGET_STORAGE_ACCOUNT" \
        --container-name "$TARGET_STORAGE_CONTAINER" \
        --auth-mode login \
        -o json)

      log "Blob discovery (read-only):"
      local database_blob_name=""
      local roles_blob_name=""
      if [[ -n "${TARGET_POSTGRES_DATABASE:-}" ]]; then
        database_blob_name=$(discover_database_blob "$blobs_json" "$TARGET_POSTGRES_DATABASE" "$restore_target_file_name")
      fi
      roles_blob_name=$(discover_roles_blob "$blobs_json" "$restore_target_file_name")
      log "Selected database blob: ${database_blob_name:-<not found>}"
      log "Selected roles blob: ${roles_blob_name:-<not found>}"
    else
      log "RUN_DATABASE_RESTORE=false: DB restore phase discovery skipped."
    fi

    log "Planned mutating steps (preview only, not executed in DRY_RUN):"
    cat <<EOF
[DRY RUN PREVIEW] az dataprotection backup-instance restore initialize-for-data-recovery-as-files --datasource-type AzureDatabaseForPostgreSQLFlexibleServer --restore-location "${RESTORE_LOCATION}" --source-datastore VaultStore --target-blob-container-url "${target_container_uri}" --target-file-name "${restore_target_file_name}" --recovery-point-id "${selected_recovery_point_id:-<resolved-rp>}" > "${request_file}"
[DRY RUN PREVIEW] az dataprotection backup-instance restore trigger -g "${VAULT_RESOURCE_GROUP}" --vault-name "${VAULT_NAME}" --backup-instance-name "${selected_instance_name:-<resolved-instance>}" --restore-request-object "${request_file}" -o json > "${trigger_file}"
[DRY RUN PREVIEW] az dataprotection job show -g "${VAULT_RESOURCE_GROUP}" --vault-name "${VAULT_NAME}" --name "<restore-job-name>" -o json (polled every ${poll_seconds}s, timeout ${restore_timeout_minutes}m)
[DRY RUN PREVIEW] Write metrics to "${metrics_file}"
EOF

    log "Dry run complete. Only read-only Azure commands were executed. No restore was triggered and no remote state was changed."
    return
  fi

  log "Ensuring dataprotection extension is available"
  az extension add --name dataprotection --upgrade --only-show-errors >/dev/null

  log "Listing backup instances from vault ${VAULT_NAME}"
  local instances_json
  instances_json=$(az dataprotection backup-instance list -g "$VAULT_RESOURCE_GROUP" --vault-name "$VAULT_NAME" -o json)

  log "Available backup instances:"
  echo "$instances_json" | jq -r '.[] | "- \(.name) [\(.properties.friendlyName // "unknown")]"'

  local selected_instance_name=""
  if [[ -n "$backup_instance_name" ]]; then
    selected_instance_name=$(find_instance_by_name "$instances_json" "$backup_instance_name")
  elif [[ -n "$backup_instance_friendly_name_filter" ]]; then
    selected_instance_name=$(find_instance_by_friendly_name "$instances_json" "$backup_instance_friendly_name_filter")
  fi

  if [[ -z "$selected_instance_name" ]]; then
    fail "Unable to resolve backup instance. Set BACKUP_INSTANCE_NAME or BACKUP_INSTANCE_FRIENDLY_NAME_FILTER."
  fi

  log "Selected backup instance: ${selected_instance_name}"

  local recovery_points_json
  recovery_points_json=$(az dataprotection recovery-point list \
    --backup-instance-name "$selected_instance_name" \
    -g "$VAULT_RESOURCE_GROUP" \
    --vault-name "$VAULT_NAME" \
    -o json)

  log "Available recovery points (UTC):"
  echo "$recovery_points_json" | jq -r '.[] | "- \(.name) @ \(.properties.recoveryPointTime)"'

  local selected_recovery_point_id
  selected_recovery_point_id=$(select_recovery_point "$recovery_points_json" "$recovery_point_id" "$recovery_point_time_utc")

  [[ -n "$selected_recovery_point_id" ]] || fail "Could not determine recovery point from provided inputs."
  log "Selected recovery point: ${selected_recovery_point_id}"

  log "Preparing restore request"
  az dataprotection backup-instance restore initialize-for-data-recovery-as-files \
    --datasource-type AzureDatabaseForPostgreSQLFlexibleServer \
    --restore-location "$RESTORE_LOCATION" \
    --source-datastore VaultStore \
    --target-blob-container-url "$target_container_uri" \
    --target-file-name "$restore_target_file_name" \
    --recovery-point-id "$selected_recovery_point_id" \
    > "$request_file"

  local started_epoch
  started_epoch=$(date +%s)
  local started_utc
  started_utc=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  log "Triggering restore"
  az dataprotection backup-instance restore trigger \
    -g "$VAULT_RESOURCE_GROUP" \
    --vault-name "$VAULT_NAME" \
    --backup-instance-name "$selected_instance_name" \
    --restore-request-object "$request_file" \
    -o json > "$trigger_file"

  local restore_job_name
  restore_job_name=$(jq -r '.name // .jobId // (.id | split("/") | last) // empty' "$trigger_file")

  if [[ -z "$restore_job_name" ]]; then
    fail "Unable to resolve restore job name from trigger response"
  fi

  log "Restore job started: ${restore_job_name}"

  local deadline_epoch=$((started_epoch + (restore_timeout_minutes * 60)))
  local job_state="Unknown"
  local job_details_file="restore-output/restore-job-details.json"

  while true; do
    az dataprotection job show \
      -g "$VAULT_RESOURCE_GROUP" \
      --vault-name "$VAULT_NAME" \
      --name "$restore_job_name" \
      -o json > "$job_details_file"

    job_state=$(jq -r '.properties.status // .status // "Unknown"' "$job_details_file")
    log "Restore job status: ${job_state}"

    case "$job_state" in
      Completed|Succeeded|CompletedWithWarnings)
        break
        ;;
      Failed|Cancelled|Canceled)
        break
        ;;
    esac

    if [[ "$(date +%s)" -ge "$deadline_epoch" ]]; then
      fail "Restore job timed out after ${restore_timeout_minutes} minutes"
    fi

    sleep "$poll_seconds"
  done

  local ended_epoch
  ended_epoch=$(date +%s)
  local ended_utc
  ended_utc=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  local restore_duration_seconds=$((ended_epoch - started_epoch))

  jq -n \
    --arg vaultResourceGroup "$VAULT_RESOURCE_GROUP" \
    --arg vaultName "$VAULT_NAME" \
    --arg backupInstanceName "$selected_instance_name" \
    --arg recoveryPointId "$selected_recovery_point_id" \
    --arg restoreJobName "$restore_job_name" \
    --arg restoreJobStatus "$job_state" \
    --arg targetStorageAccount "$TARGET_STORAGE_ACCOUNT" \
    --arg targetStorageContainer "$TARGET_STORAGE_CONTAINER" \
    --arg restoreLocation "$RESTORE_LOCATION" \
    --arg restoreTargetFileName "$restore_target_file_name" \
    --arg startedAtUtc "$started_utc" \
    --arg endedAtUtc "$ended_utc" \
    --argjson restoreDurationSeconds "$restore_duration_seconds" \
    '{
      vaultResourceGroup: $vaultResourceGroup,
      vaultName: $vaultName,
      backupInstanceName: $backupInstanceName,
      recoveryPointId: $recoveryPointId,
      restoreJobName: $restoreJobName,
      restoreJobStatus: $restoreJobStatus,
      targetStorageAccount: $targetStorageAccount,
      targetStorageContainer: $targetStorageContainer,
      restoreLocation: $restoreLocation,
      restoreTargetFileName: $restoreTargetFileName,
      startedAtUtc: $startedAtUtc,
      endedAtUtc: $endedAtUtc,
      restoreDurationSeconds: $restoreDurationSeconds
    }' > "$metrics_file"

  if [[ "$job_state" != "Completed" && "$job_state" != "Succeeded" && "$job_state" != "CompletedWithWarnings" ]]; then
    fail "Restore job ended unsuccessfully with status: ${job_state}"
  fi

  if [[ "$run_database_restore" != "true" ]]; then
    log "Vault-to-storage restore completed. Database restore phase is skipped (RUN_DATABASE_RESTORE=false)."
    log "Metrics file: ${metrics_file}"
    return
  fi

  require_env "TARGET_POSTGRES_HOST"
  require_env "TARGET_POSTGRES_ADMIN_USER"
  require_env "TARGET_POSTGRES_ADMIN_PASSWORD"
  require_env "TARGET_POSTGRES_DATABASE"

  if ! command -v psql >/dev/null 2>&1 || ! command -v pg_restore >/dev/null 2>&1; then
    log "Installing PostgreSQL client tools"
    sudo apt-get update -y
    sudo apt-get install -y postgresql-client
  fi

  local blobs_json
  blobs_json=$(az storage blob list \
    --account-name "$TARGET_STORAGE_ACCOUNT" \
    --container-name "$TARGET_STORAGE_CONTAINER" \
    --auth-mode login \
    -o json)

  local database_blob_name
  database_blob_name=$(discover_database_blob "$blobs_json" "$TARGET_POSTGRES_DATABASE" "$restore_target_file_name")
  if [[ -z "$database_blob_name" ]]; then
    log "No blob matched with prefix '${restore_target_file_name}', retrying without prefix filter"
    database_blob_name=$(discover_database_blob "$blobs_json" "$TARGET_POSTGRES_DATABASE")
  fi
  [[ -n "$database_blob_name" ]] || fail "Could not find database blob ending with _database_${TARGET_POSTGRES_DATABASE}.sql"
  log "Selected database blob: ${database_blob_name}"

  local roles_blob_name=""
  if [[ "$restore_roles" == "true" ]]; then
    roles_blob_name=$(discover_roles_blob "$blobs_json" "$restore_target_file_name")
    if [[ -z "$roles_blob_name" ]]; then
      roles_blob_name=$(discover_roles_blob "$blobs_json")
    fi
    if [[ -z "$roles_blob_name" ]]; then
      log "No roles blob found. Continuing without roles restore."
    else
      log "Selected roles blob: ${roles_blob_name}"
    fi
  fi

  local db_file="restore-output/${database_blob_name##*/}"
  az storage blob download \
    --account-name "$TARGET_STORAGE_ACCOUNT" \
    --container-name "$TARGET_STORAGE_CONTAINER" \
    --name "$database_blob_name" \
    --file "$db_file" \
    --auth-mode login \
    -o none

  local roles_file=""
  if [[ -n "$roles_blob_name" ]]; then
    roles_file="restore-output/${roles_blob_name##*/}"
    az storage blob download \
      --account-name "$TARGET_STORAGE_ACCOUNT" \
      --container-name "$TARGET_STORAGE_CONTAINER" \
      --name "$roles_blob_name" \
      --file "$roles_file" \
      --auth-mode login \
      -o none
  fi

  export PGPASSWORD="$TARGET_POSTGRES_ADMIN_PASSWORD"

  local db_restore_started_epoch
  db_restore_started_epoch=$(date +%s)

  local database_exists
  database_exists=$(psql \
    "host=${TARGET_POSTGRES_HOST} port=${postgres_port} user=${TARGET_POSTGRES_ADMIN_USER} dbname=postgres sslmode=require" \
    -tAc "SELECT 1 FROM pg_database WHERE datname='${TARGET_POSTGRES_DATABASE}'" | tr -d '[:space:]')

  if [[ "$database_exists" != "1" ]]; then
    log "Creating target database ${TARGET_POSTGRES_DATABASE}"
    psql "host=${TARGET_POSTGRES_HOST} port=${postgres_port} user=${TARGET_POSTGRES_ADMIN_USER} dbname=postgres sslmode=require" \
      -c "CREATE DATABASE \"${TARGET_POSTGRES_DATABASE}\" WITH OWNER = \"${TARGET_POSTGRES_ADMIN_USER}\" ENCODING = 'UTF8' LC_COLLATE = 'en_GB.utf8' LC_CTYPE = 'en_GB.utf8' TEMPLATE = template0;"
  else
    log "Target database ${TARGET_POSTGRES_DATABASE} already exists"
  fi

  if [[ -n "$roles_file" ]]; then
    log "Restoring roles (non-fatal if service-managed roles fail)"
    set +e
    psql "host=${TARGET_POSTGRES_HOST} port=${postgres_port} user=${TARGET_POSTGRES_ADMIN_USER} dbname=postgres sslmode=require" -f "$roles_file"
    set -e
  fi

  local restore_mode="pg_restore"
  set +e
  pg_restore \
    -h "$TARGET_POSTGRES_HOST" \
    -p "$postgres_port" \
    -U "$TARGET_POSTGRES_ADMIN_USER" \
    -d "$TARGET_POSTGRES_DATABASE" \
    --no-owner \
    -v \
    "$db_file"
  local pg_restore_exit_code=$?
  set -e

  if [[ "$pg_restore_exit_code" -ne 0 ]]; then
    log "pg_restore failed, falling back to psql file restore"
    restore_mode="psql"
    psql "host=${TARGET_POSTGRES_HOST} port=${postgres_port} user=${TARGET_POSTGRES_ADMIN_USER} dbname=${TARGET_POSTGRES_DATABASE} sslmode=require" -f "$db_file"
  fi

  local db_restore_ended_epoch
  db_restore_ended_epoch=$(date +%s)
  local db_restore_duration_seconds=$((db_restore_ended_epoch - db_restore_started_epoch))

  jq \
    --arg restoreMode "$restore_mode" \
    --arg databaseBlob "$database_blob_name" \
    --arg rolesBlob "$roles_blob_name" \
    --arg targetPostgresHost "$TARGET_POSTGRES_HOST" \
    --arg targetPostgresDatabase "$TARGET_POSTGRES_DATABASE" \
    --argjson databaseRestoreDurationSeconds "$db_restore_duration_seconds" \
    '. + {
      databaseRestore: {
        restoreMode: $restoreMode,
        databaseBlob: $databaseBlob,
        rolesBlob: $rolesBlob,
        targetPostgresHost: $targetPostgresHost,
        targetPostgresDatabase: $targetPostgresDatabase,
        databaseRestoreDurationSeconds: $databaseRestoreDurationSeconds
      }
    }' "$metrics_file" > "${metrics_file}.tmp"
  mv "${metrics_file}.tmp" "$metrics_file"

  log "Database restore phase completed"
  log "Metrics file: ${metrics_file}"
}

main "$@"
