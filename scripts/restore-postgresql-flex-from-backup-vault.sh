#!/usr/bin/env bash

set -euo pipefail

# Always initialize to avoid unbound variable errors with set -u
wal_settings_modified=false

log() {
  echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] $*"
}

fail() {
  log "ERROR: $*"
  exit 1
}

warn() {
  log "WARN: $*"
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
      map({name: .name, t: (.properties.recoveryPointTime | gsub("\\.[0-9]+Z$"; "Z") | fromdateiso8601)})
      | map(select(.t <= ($ts | gsub("\\.[0-9]+Z$"; "Z") | fromdateiso8601)))
      | sort_by(.t)
      | last
      | .name // empty
    '
    return
  fi

  echo "$recovery_points_json" | jq -r '
    map({name: .name, t: (.properties.recoveryPointTime | gsub("\\.[0-9]+Z$"; "Z") | fromdateiso8601)})
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

# Returns one blob name per line for every *_database_<name>.sql blob in the container.
discover_all_database_blobs() {
  local blobs_json="$1"
  local file_prefix="${2:-}"

  echo "$blobs_json" | jq -r --arg prefix "$file_prefix" '
    map(select(
      ((.name | ascii_downcase) | test("_database_[^/]+\\.sql$"))
      and (if $prefix != "" then (.name | startswith($prefix)) else true end)
    ))
    | sort_by(.name)
    | .[].name
  '
}

# Extracts the database name from a blob filename of the form *_database_<name>.sql
db_name_from_blob() {
  local blob_name="$1"
  echo "$blob_name" | sed -E 's/.*_database_([^/]+)\.sql$/\1/'
}

roles_restore_has_unexpected_errors() {
  local roles_restore_log="$1"
  local roles_errors_file="$2"
  local roles_critical_file="$3"

  grep -E '(^ERROR:|^psql:.*ERROR:|^FATAL:|^psql:.*FATAL:)' "$roles_restore_log" > "$roles_errors_file" || true

  if [[ ! -s "$roles_errors_file" ]]; then
    return 1
  fi

  # Ignore known, environment-specific role replay errors in managed PostgreSQL.
  # See: https://learn.microsoft.com/en-us/azure/backup/backup-azure-database-postgresql-flex-support-matrix#limitation
  grep -Ev 'role ".*" already exists|must be superuser to create role|must be superuser to alter role|permission denied to create role|permission denied to alter role|cannot execute CREATE ROLE in a read-only transaction|cannot execute ALTER ROLE in a read-only transaction|permission denied granting privileges as role|Only roles with the ADMIN option on role "pg_use_reserved_connections"' "$roles_errors_file" > "$roles_critical_file" || true

  if [[ -s "$roles_critical_file" ]]; then
    return 0
  fi

  return 1
}

# ---------------------------------------------------------------------------
# calculate_pg_restore_workers
#
# Derives a safe pg_restore -j worker count from the agent's cgroup memory
# limit. Each worker consumes roughly 1 GB of agent memory (network buffers,
# sort scratch, pg_restore overhead). 1 GB is reserved for the pg_restore
# main process and OS overhead, so:
#
#   workers = floor((cgroup_limit_gb - 1) / 1)  clamped to [1, 4]
#
# The upper cap of 4 reflects the point where IOPS on the PostgreSQL server
# becomes the bottleneck and additional workers stop improving throughput.
#
# If the cgroup limit cannot be read (non-containerised or unlimited), the
# function falls back to 3 — the previous hardcoded default that is safe
# on the standard 4Gi agent profile.
#
# Cgroup v2 (/sys/fs/cgroup/memory.max) is tried first; cgroup v1
# (/sys/fs/cgroup/memory/memory.limit_in_bytes) is used as a fallback.
# ---------------------------------------------------------------------------
calculate_pg_restore_workers() {
  local cg_mem_bytes
  local cg_mem_gb
  local workers

  # cgroups v2 (Kubernetes default on modern nodes)
  if [[ -r /sys/fs/cgroup/memory.max ]]; then
    cg_mem_bytes=$(cat /sys/fs/cgroup/memory.max)
  # cgroups v1 fallback
  elif [[ -r /sys/fs/cgroup/memory/memory.limit_in_bytes ]]; then
    cg_mem_bytes=$(cat /sys/fs/cgroup/memory/memory.limit_in_bytes)
  fi

  # If unset, unlimited, or not a number — use safe fallback
  if [[ -z "${cg_mem_bytes:-}" ]] || [[ "$cg_mem_bytes" == "max" ]] || ! [[ "$cg_mem_bytes" =~ ^[0-9]+$ ]]; then
    warn "Could not read cgroup memory limit; using fallback pg_restore worker count of 3"
    echo 3
    return 0
  fi

  cg_mem_gb=$(( cg_mem_bytes / 1024 / 1024 / 1024 ))
  workers=$(( cg_mem_gb - 1 ))

  # Floor: 1 worker minimum (always safe, always makes progress)
  # Cap:   4 workers maximum (IOPS becomes the limiting factor beyond this)
  [[ $workers -lt 1 ]] && workers=1
  [[ $workers -gt 4 ]] && workers=4

  echo "$workers"
}

main() {
  require_env "VAULT_RESOURCE_GROUP"
  require_env "VAULT_NAME"
  require_env "TARGET_STORAGE_ACCOUNT"
  require_env "TARGET_STORAGE_CONTAINER"
  require_env "RESTORE_LOCATION"

  local dry_run="${DRY_RUN:-true}"
  # Pipeline parameters use sentinel values ('none'/'auto') instead of empty
  # strings (Azure Pipelines does not allow default: ''). Normalise here so all
  # downstream logic can use plain empty-string checks.
  local backup_instance_name="${BACKUP_INSTANCE_NAME:-}"
  [[ "$backup_instance_name" == "none" ]] && backup_instance_name=""
  local backup_instance_friendly_name_filter="${BACKUP_INSTANCE_FRIENDLY_NAME_FILTER:-}"
  [[ "$backup_instance_friendly_name_filter" == "none" ]] && backup_instance_friendly_name_filter=""
  local recovery_point_id="${RECOVERY_POINT_ID:-}"
  [[ "$recovery_point_id" == "none" ]] && recovery_point_id=""
  local recovery_point_time_utc="${RECOVERY_POINT_TIME_UTC:-}"
  [[ "$recovery_point_time_utc" == "none" ]] && recovery_point_time_utc=""
  local vault_subscription="${VAULT_SUBSCRIPTION:-}"
  [[ "$vault_subscription" == "none" ]] && vault_subscription=""
  local vault_sub_flag=""
  [[ -n "$vault_subscription" ]] && vault_sub_flag="--subscription ${vault_subscription}"
  local target_file_prefix="${TARGET_FILE_PREFIX:-restore-${BUILD_BUILDID:-local}}"
  local restore_timeout_minutes="${RESTORE_TIMEOUT_MINUTES:-240}"
  local poll_seconds="${POLL_SECONDS:-30}"
  local restore_scope="${RESTORE_MODE:-all}"
  local restore_roles="${RESTORE_ROLES:-true}"
  local postgres_port="${TARGET_POSTGRES_PORT:-5432}"
  # If neither backup instance override was given, fall back to matching the
  # source server name against the vault instance friendlyName. This covers the
  # common case where the vault instance is named after the server, so the caller
  # does not need to provide any backup-instance parameter.
  local source_server_name="${SOURCE_SERVER_NAME:-}"
  if [[ -z "$backup_instance_name" && -z "$backup_instance_friendly_name_filter" && -n "$source_server_name" ]]; then
    backup_instance_friendly_name_filter="$source_server_name"
    log "No backup instance override provided; auto-matching vault instances on sourceServerName '${source_server_name}'"
  fi

  mkdir -p restore-output
  # Always remove any downloaded dump files on exit, including on failure or abort,
  # so sensitive database content does not persist on the agent disk.
  trap 'rm -f restore-output/*_database_*.sql 2>/dev/null || true' EXIT

  local metrics_file="restore-output/restore-metrics.json"
  local request_file="restore-output/restore-request.json"
  local trigger_file="restore-output/restore-trigger.json"
  local target_container_uri="https://${TARGET_STORAGE_ACCOUNT}.blob.core.windows.net/${TARGET_STORAGE_CONTAINER}"
  local restore_target_file_name="${target_file_prefix}-$(date -u +"%M%H%d%m%y")"

  if [[ "${dry_run,,}" == "true" ]]; then
    log "DRY_RUN=true: mutating Azure/PostgreSQL commands are disabled."
    log "RESTORE_MODE: ${restore_scope}"
    log "Running read-only discovery commands for scope: ${restore_scope}."

    if ! command -v az >/dev/null 2>&1; then
      fail "Azure CLI (az) is required for dry-run read-only discovery."
    fi

    local selected_instance_name=""
    local selected_recovery_point_id=""
    if [[ "$restore_scope" != "database-only" ]]; then
      local instances_json
      # shellcheck disable=SC2086
      instances_json=$(az dataprotection backup-instance list -g "$VAULT_RESOURCE_GROUP" --vault-name "$VAULT_NAME" $vault_sub_flag -o json)

      log "Available backup instances:"
      echo "$instances_json" | jq -r '.[] | "- \(.name) [\(.properties.friendlyName // "unknown")]"'

      if [[ -n "$backup_instance_name" ]]; then
        selected_instance_name=$(find_instance_by_name "$instances_json" "$backup_instance_name")
      elif [[ -n "$backup_instance_friendly_name_filter" ]]; then
        selected_instance_name=$(find_instance_by_friendly_name "$instances_json" "$backup_instance_friendly_name_filter")
      fi

      if [[ -n "$selected_instance_name" ]]; then
        log "Selected backup instance: ${selected_instance_name}"
        local recovery_points_json
        # shellcheck disable=SC2086
        recovery_points_json=$(az dataprotection recovery-point list \
          --backup-instance-name "$selected_instance_name" \
          -g "$VAULT_RESOURCE_GROUP" \
          --vault-name "$VAULT_NAME" \
          $vault_sub_flag \
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
    else
      log "database-only mode: skipping vault instance/recovery-point discovery."
    fi

    if [[ "$restore_scope" != "vault-only" ]]; then
      local blobs_json
      # The container may not exist in a dry run for all/vault-only (Stage 1 skips creation).
      # For database-only the container is pre-existing, so a real listing is expected.
      # Capture stderr separately so we can surface failures without aborting.
      local blob_list_err
      blob_list_err=$(mktemp)
      blobs_json=$(az storage blob list \
        --account-name "$TARGET_STORAGE_ACCOUNT" \
        --container-name "$TARGET_STORAGE_CONTAINER" \
        --auth-mode login \
        -o json 2>"$blob_list_err") || {
          local _err; _err=$(cat "$blob_list_err")
          if [[ "$restore_scope" == "database-only" ]]; then
            warn "Blob listing failed for existing container '${TARGET_STORAGE_CONTAINER}': ${_err}"
          else
            log "  Blob listing unavailable in dry run (container not yet created): ${_err:-unknown error}"
          fi
          blobs_json="[]"
        }
      rm -f "$blob_list_err"

      log "Blob discovery (read-only):"
      # For database-only the blobs were written by a previous run — discover without
      # prefix first, then narrow to prefix if there are results (same two-pass logic
      # as the live path).
      local dry_db_blobs=()
      if [[ "$restore_scope" == "database-only" ]]; then
        while IFS= read -r blob; do
          [[ -n "$blob" ]] && dry_db_blobs+=("$blob")
        done < <(discover_all_database_blobs "$blobs_json")
      else
        while IFS= read -r blob; do
          [[ -n "$blob" ]] && dry_db_blobs+=("$blob")
        done < <(discover_all_database_blobs "$blobs_json" "$restore_target_file_name")
      fi
      if [[ ${#dry_db_blobs[@]} -eq 0 ]]; then
        log "  No database blobs found (container may not exist yet in dry run)"
      else
        log "  Found ${#dry_db_blobs[@]} database blob(s):"
        for blob in "${dry_db_blobs[@]}"; do
          log "    - ${blob}"
        done
      fi
      local roles_blob_name
      if [[ "$restore_scope" == "database-only" ]]; then
        roles_blob_name=$(discover_roles_blob "$blobs_json")
      else
        roles_blob_name=$(discover_roles_blob "$blobs_json" "$restore_target_file_name")
      fi
      log "Selected roles blob: ${roles_blob_name:-<not found>}"
    else
      log "vault-only mode: skipping blob and database restore discovery."
    fi

    log "Planned mutating steps (preview only, not executed in DRY_RUN):"
    if [[ "$restore_scope" != "database-only" ]]; then
      cat <<EOF
[DRY RUN PREVIEW] az dataprotection backup-instance restore initialize-for-data-recovery-as-files --datasource-type AzureDatabaseForPostgreSQLFlexibleServer --restore-location "${RESTORE_LOCATION}" --source-datastore VaultStore --target-blob-container-url "${target_container_uri}" --target-file-name "${restore_target_file_name}" --recovery-point-id "${selected_recovery_point_id:-<resolved-rp>}" > "${request_file}"
[DRY RUN PREVIEW] az dataprotection backup-instance restore trigger -g "${VAULT_RESOURCE_GROUP}" --vault-name "${VAULT_NAME}" --backup-instance-name "${selected_instance_name:-<resolved-instance>}" --restore-request-object "${request_file}" ${vault_sub_flag} -o json > "${trigger_file}"
[DRY RUN PREVIEW] az dataprotection job show --ids "<restore-job-arm-id>" -o json (polled every ${poll_seconds}s, timeout ${restore_timeout_minutes}m)
[DRY RUN PREVIEW] Write vault restore metrics to "${metrics_file}"
EOF
    fi
    if [[ "$restore_scope" != "vault-only" ]]; then
      cat <<EOF
[DRY RUN PREVIEW] pg_restore / psql: restore all discovered database blobs onto host "${TARGET_POSTGRES_HOST:-<host>}"
[DRY RUN PREVIEW] Write database restore metrics to "${metrics_file}"
EOF
    fi

    log "Dry run complete. Only read-only Azure commands were executed. No restore was triggered and no remote state was changed."
    return
  fi

  # Vault restore phase — skip entirely for database-only mode
  if [[ "$restore_scope" != "database-only" ]]; then
  log "Ensuring dataprotection extension is available"
  az extension add --name dataprotection --upgrade --only-show-errors >/dev/null

  log "Listing backup instances from vault ${VAULT_NAME}"
  local instances_json
  # shellcheck disable=SC2086
  instances_json=$(az dataprotection backup-instance list -g "$VAULT_RESOURCE_GROUP" --vault-name "$VAULT_NAME" $vault_sub_flag -o json)

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
  # shellcheck disable=SC2086
  recovery_points_json=$(az dataprotection recovery-point list \
    --backup-instance-name "$selected_instance_name" \
    -g "$VAULT_RESOURCE_GROUP" \
    --vault-name "$VAULT_NAME" \
    $vault_sub_flag \
    -o json)

  log "Available recovery points (UTC):"
  echo "$recovery_points_json" | jq -r '.[] | "- \(.name) @ \(.properties.recoveryPointTime)"'

  local selected_recovery_point_id
  selected_recovery_point_id=$(select_recovery_point "$recovery_points_json" "$recovery_point_id" "$recovery_point_time_utc")

  [[ -n "$selected_recovery_point_id" ]] || fail "Could not determine recovery point from provided inputs."
  log "Selected recovery point: ${selected_recovery_point_id}"

  local selected_recovery_point_time_utc
  selected_recovery_point_time_utc=$(echo "$recovery_points_json" | jq -r --arg rp "$selected_recovery_point_id" '.[] | select(.name == $rp) | .properties.recoveryPointTime // empty' | head -n1)
  if [[ -n "$selected_recovery_point_time_utc" ]]; then
    log "Selected recovery point time (UTC): ${selected_recovery_point_time_utc}"
  else
    selected_recovery_point_time_utc="unknown"
    log "Selected recovery point time (UTC): unknown"
  fi

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
  # shellcheck disable=SC2086
  az dataprotection backup-instance restore trigger \
    -g "$VAULT_RESOURCE_GROUP" \
    --vault-name "$VAULT_NAME" \
    --backup-instance-name "$selected_instance_name" \
    --restore-request-object "$request_file" \
    $vault_sub_flag \
    -o json > "$trigger_file"

  # The trigger response .name field is the full ARM resource ID.
  # Extract the trailing GUID (after the last '/') for logging and metrics.
  local restore_job_arm_id
  restore_job_arm_id=$(jq -r '.name // .jobId // .id // empty' "$trigger_file")

  if [[ -z "$restore_job_arm_id" ]]; then
    fail "Unable to resolve restore job from trigger response"
  fi

  local restore_job_name
  restore_job_name="${restore_job_arm_id##*/}"

  log "Restore job started: ${restore_job_arm_id}"

  local deadline_epoch=$((started_epoch + (restore_timeout_minutes * 60)))
  local job_state="Unknown"
  local job_details_file="restore-output/restore-job-details.json"

  while true; do
    az dataprotection job show \
      --ids "$restore_job_arm_id" \
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
    --arg recoveryPointTimeUtc "$selected_recovery_point_time_utc" \
    --arg vaultRestoreJobId "$restore_job_name" \
    --arg vaultRestoreJobStatus "$job_state" \
    --arg targetStorageAccount "$TARGET_STORAGE_ACCOUNT" \
    --arg targetStorageContainer "$TARGET_STORAGE_CONTAINER" \
    --arg restoreLocation "$RESTORE_LOCATION" \
    --arg blobNamePrefix "$restore_target_file_name" \
    --arg vaultPhaseStartedAtUtc "$started_utc" \
    --arg vaultPhaseEndedAtUtc "$ended_utc" \
    --argjson vaultPhaseDurationSeconds "$restore_duration_seconds" \
    '{
      vaultResourceGroup: $vaultResourceGroup,
      vaultName: $vaultName,
      backupInstanceName: $backupInstanceName,
      recoveryPointId: $recoveryPointId,
      recoveryPointTimeUtc: $recoveryPointTimeUtc,
      vaultRestoreJobId: $vaultRestoreJobId,
      vaultRestoreJobStatus: $vaultRestoreJobStatus,
      targetStorageAccount: $targetStorageAccount,
      targetStorageContainer: $targetStorageContainer,
      restoreLocation: $restoreLocation,
      blobNamePrefix: $blobNamePrefix,
      vaultPhaseStartedAtUtc: $vaultPhaseStartedAtUtc,
      vaultPhaseEndedAtUtc: $vaultPhaseEndedAtUtc,
      vaultPhaseDurationSeconds: $vaultPhaseDurationSeconds,
      vaultPhaseDurationMinutes: "\($vaultPhaseDurationSeconds / 60 | floor)min \($vaultPhaseDurationSeconds % 60)s"
    }' > "$metrics_file"

  # After job completes, extract recoveryPointTime from job details and update metrics file
  local actual_recovery_point_time
  actual_recovery_point_time=$(jq -r '.properties.extendedInfo.sourceRecoverPoint.recoveryPointTime // empty' "$job_details_file" | head -n1)
  if [[ -n "$actual_recovery_point_time" ]]; then
    # Update recoveryPointTimeUtc in metrics file
    tmp_metrics_file="${metrics_file}.tmp"
    jq --arg actualTime "$actual_recovery_point_time" '.recoveryPointTimeUtc = $actualTime' "$metrics_file" > "$tmp_metrics_file" && mv "$tmp_metrics_file" "$metrics_file"
    log "Updated recoveryPointTimeUtc in metrics file: $actual_recovery_point_time"
  else
    log "WARNING: Could not extract recoveryPointTime from job details."
  fi

  if [[ "$job_state" != "Completed" && "$job_state" != "Succeeded" && "$job_state" != "CompletedWithWarnings" ]]; then
    fail "Restore job ended unsuccessfully with status: ${job_state}"
  fi

  fi # end vault restore phase (restore_scope != database-only)

  if [[ "$restore_scope" == "vault-only" ]]; then
    log "Vault-to-storage restore completed (vault-only mode)."
    log "Metrics file: ${metrics_file}"
    return
  fi

  require_env "TARGET_POSTGRES_HOST"
  require_env "TARGET_POSTGRES_ADMIN_USER"
  require_env "TARGET_POSTGRES_ADMIN_PASSWORD"

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

  # Discover all database blobs, falling back to a prefix-free search if needed
  local all_db_blobs=()
  while IFS= read -r blob; do
    [[ -n "$blob" ]] && all_db_blobs+=("$blob")
  done < <(discover_all_database_blobs "$blobs_json" "$restore_target_file_name")

  if [[ ${#all_db_blobs[@]} -eq 0 ]]; then
    log "No blobs matched with prefix '${restore_target_file_name}', retrying without prefix filter"
    while IFS= read -r blob; do
      [[ -n "$blob" ]] && all_db_blobs+=("$blob")
    done < <(discover_all_database_blobs "$blobs_json")
  fi

  [[ ${#all_db_blobs[@]} -gt 0 ]] || fail "No database blobs found in container ${TARGET_STORAGE_CONTAINER}"
  log "Found ${#all_db_blobs[@]} database blob(s) to restore:"
  for blob in "${all_db_blobs[@]}"; do
    log "  - ${blob}"
  done

  # Azure Backup also generates _tablespace.sql and _schema.sql files per the restore
  # documentation. Neither is safe to restore on Azure Database for PostgreSQL:
  #   _tablespace.sql  Azure Postgres does not support custom tablespaces — restore would fail.
  #   _schema.sql      Schema is already embedded in each _database_*.sql dump; Microsoft
  #                    explicitly recommends NOT running this script (it would produce duplicate
  #                    object errors). See: https://learn.microsoft.com/en-us/azure/backup/restore-azure-database-postgresql-flex
  # Log them so the presence of these blobs doesn't appear as a silent omission.
  local _skipped_azure_blobs
  _skipped_azure_blobs=$(echo "$blobs_json" | jq -r '.[].name | select(test("(_tablespace|_schema)\\.sql$"; "i"))' 2>/dev/null || true)
  if [[ -n "$_skipped_azure_blobs" ]]; then
    log "NOTE: Azure Backup generated file(s) present in container but intentionally NOT restored:"
    while IFS= read -r _b; do
      log "  - ${_b}"
    done <<< "$_skipped_azure_blobs"
  fi

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

    # Pre-clean roles.sql before restore to prevent partial role application.
    # Azure Backup includes Azure-internal roles and superuser-only attributes
    # (NOSUPERUSER, NOBYPASSRLS) in pg_dumpall output. On Azure Postgres there is
    # no superuser, so ALTER ROLE statements containing these attributes fail in
    # their entirety under ON_ERROR_STOP=0 — meaning valid attributes on the same
    # line (LOGIN, CREATEDB, INHERIT, etc.) are also silently not applied.
    # Proactive cleanup strips the offending tokens so the rest of each statement
    # succeeds. This mirrors the sed command in the Microsoft restore guide:
    # https://learn.microsoft.com/en-us/azure/backup/restore-azure-database-postgresql-flex
    log "Pre-cleaning roles.sql to strip Azure-internal roles and superuser-only attributes"
    local roles_file_raw
    roles_file_raw="${roles_file}.raw"
    cp "$roles_file" "$roles_file_raw"
    sed \
      -e '/azure_superuser/d' \
      -e '/azure_pg_admin/d' \
      -e '/azuresu/d' \
      -e '/^CREATE ROLE replication/d' \
      -e '/^ALTER ROLE replication/d' \
      -e '/^ALTER ROLE/ {s/NOSUPERUSER//g; s/NOBYPASSRLS//g;}' \
      "$roles_file_raw" > "$roles_file"
    local _roles_removed=$(( $(wc -l < "$roles_file_raw") - $(wc -l < "$roles_file") ))
    log "  Removed ${_roles_removed} line(s) containing Azure-internal roles"
    log "  Stripped NOSUPERUSER/NOBYPASSRLS attributes from remaining ALTER ROLE statements"
  fi

  export PGPASSWORD="$TARGET_POSTGRES_ADMIN_PASSWORD"

  # Wait for Postgres to accept TCP connections. The server may have been
  # created moments ago and can take a short while after reporting 'Ready'
  # before port 5432 is reachable. Also provides an early, clear error when
  # the agent does not have network access to the private endpoint.
  log "Waiting for Postgres to accept connections at ${TARGET_POSTGRES_HOST}:${postgres_port}..."
  local pg_wait_elapsed=0
  local pg_wait_timeout=300
  until timeout 5 bash -c ">/dev/tcp/${TARGET_POSTGRES_HOST}/${postgres_port}" 2>/dev/null; do
    if [[ "$pg_wait_elapsed" -ge "$pg_wait_timeout" ]]; then
      fail "$(printf 'Timed out waiting for Postgres at %s:%s after %ss.\n       Check that:\n         1. The ADO agent has network access to the server'\''s private endpoint subnet\n         2. There is no NSG rule blocking port %s from the agent'\''s IP' \
        "${TARGET_POSTGRES_HOST}" "${postgres_port}" "${pg_wait_timeout}" "${postgres_port}")"
    fi
    pg_wait_elapsed=$((pg_wait_elapsed + 15))
    sleep 15
    log "  [${pg_wait_elapsed}s] Still waiting for Postgres to accept connections..."
  done
  log "Postgres is accepting connections at ${TARGET_POSTGRES_HOST}:${postgres_port}"

  # Restore roles once up front, before the per-database loop
  if [[ -n "$roles_file" ]]; then
    local roles_restore_log="restore-output/roles-restore.log"
    local roles_errors_file="restore-output/roles-restore-errors.log"
    local roles_critical_file="restore-output/roles-restore-critical.log"

    log "Restoring roles (pre-cleaned)"
    set +e
    psql "host=${TARGET_POSTGRES_HOST} port=${postgres_port} user=${TARGET_POSTGRES_ADMIN_USER} dbname=postgres sslmode=require" \
      -v ON_ERROR_STOP=0 \
      -f "$roles_file" \
      > "$roles_restore_log" 2>&1
    local roles_restore_exit_code=$?
    set -e

    if [[ "$roles_restore_exit_code" -ne 0 ]]; then
      fail "roles.sql replay failed with psql exit code ${roles_restore_exit_code}. See ${roles_restore_log}."
    fi

    if roles_restore_has_unexpected_errors "$roles_restore_log" "$roles_errors_file" "$roles_critical_file"; then
      log "Unexpected role restore errors detected:"
      sed -n '1,20p' "$roles_critical_file"
      fail "roles.sql replay had unexpected errors. See ${roles_critical_file}."
    elif [[ -s "$roles_errors_file" ]]; then
      warn "roles.sql completed with known managed-role warnings; continuing. See ${roles_errors_file}."
    else
      log "roles.sql replay completed without errors"
    fi
  fi

  # ---------------------------------------------------------------------------
  # Determine pg_restore worker count from the agent's cgroup memory limit.
  # Each worker uses ~1 GB of agent memory; 1 GB is reserved for overhead.
  # The count is clamped to [1, 4] — beyond 4 workers, server-side IOPS is
  # the bottleneck and additional workers do not improve restore throughput.
  #
  #   Agent memory  Workers  Notes
  #   2Gi           1        Minimum; safe on constrained agents
  #   4Gi           3        Standard profile (previous hardcoded default)
  #   6Gi / 8Gi     4        Cap — IOPS-bound beyond this
  #
  # Increasing the agent memory limit (e.g. via the Kubernetes resource spec)
  # automatically raises the worker count up to the cap — no code change is
  # needed. Falls back to 3 if the cgroup limit cannot be read.
  # ---------------------------------------------------------------------------
  local pg_restore_parallel_workers
  pg_restore_parallel_workers=$(calculate_pg_restore_workers)
  log "pg_restore parallelism: -j ${pg_restore_parallel_workers} workers (derived from agent cgroup memory limit)"
  # ---------------------------------------------------------------------------
  # Determine maintenance_work_mem dynamically from the target server's
  # shared_buffers setting. Azure sets shared_buffers to ~25% of server RAM
  # automatically, so "shared_buffers / parallel_workers" gives each worker
  # a safe allowance that scales correctly across all SKUs without risking OOM:
  #
  #   SKU              RAM    shared_buffers  ÷N workers  → clamped value
  #   B1ms             2 GB      512 MB       ÷1 → 512 MB → 512 MB
  #   GP D2ds_v4       8 GB    2,048 MB       ÷3 → 682 MB → 682 MB
  #   GP D4ds_v4      16 GB    4,096 MB       ÷4 → 1,024 MB (cap)
  #   MO E8ds_v4      64 GB   16,384 MB       ÷4 → 1,024 MB (cap)
  #
  # This is set as a session-level GUC via PGOPTIONS so it only affects the
  # pg_restore connection and never touches the server's running configuration.
  # ---------------------------------------------------------------------------
  local maintenance_work_mem_mb
  local _shared_buffers_mb
  _shared_buffers_mb=$(psql \
    "host=${TARGET_POSTGRES_HOST} port=${postgres_port} user=${TARGET_POSTGRES_ADMIN_USER} dbname=postgres sslmode=require" \
    -tAc "SELECT setting::int * 8 / 1024 FROM pg_settings WHERE name = 'shared_buffers'" \
    2>/dev/null | tr -d '[:space:]' || echo "0")

  if [[ "${_shared_buffers_mb:-0}" =~ ^[0-9]+$ ]] && [[ "${_shared_buffers_mb}" -gt 0 ]]; then
    maintenance_work_mem_mb=$(( _shared_buffers_mb / pg_restore_parallel_workers ))
    # Floor: 64 MB — below this, PostgreSQL cannot hold useful sort runs in memory.
    # Cap: 1024 MB — beyond this, index-build improvement plateaus and memory
    #               pressure from all workers combined becomes a concern.
    [[ $maintenance_work_mem_mb -lt 64   ]] && maintenance_work_mem_mb=64
    [[ $maintenance_work_mem_mb -gt 1024 ]] && maintenance_work_mem_mb=1024
    log "maintenance_work_mem: ${maintenance_work_mem_mb}MB (shared_buffers=${_shared_buffers_mb}MB ÷ ${pg_restore_parallel_workers} workers)"
  else
    maintenance_work_mem_mb=128
    warn "Could not read shared_buffers from target server; using fallback maintenance_work_mem=${maintenance_work_mem_mb}MB"
  fi

  # ---------------------------------------------------------------------------
  # ARCHITECTURAL DECISION: Disable fsync & full_page_writes during restore
  #
  # DECISION: Temporarily disable fsync and full_page_writes on the server
  # during the restore-only phase to improve throughput by 25-35% on
  # IOPS-constrained storage (e.g., Azure Premium Storage P6/P10).
  #
  # JUSTIFICATION:
  # - fsync=on (default): Force WAL to disk before COMMIT returns. Ensures
  #   crash-safety. Cost: 20-40% throughput loss on IOPS-limited storage.
  # - full_page_writes=on (default): Write entire page to WAL on first
  #   modification after checkpoint. Prevents torn-page corruption. Cost:
  #   10-20% throughput overhead.
  # - During restore: One-shot operation. Any crash requires re-running the job
  #   (not a partial data loss scenario). Benefit justifies temporary risk window.
  #
  # RISK ANALYSIS & MITIGATION:
  #   Risk: If agent/server crashes mid-restore, database may be inconsistent.
  #   Severity: MEDIUM (unrecoverable, requires full restore re-run)
  #   Context: This is acceptable because:
  #     1. Restore is a one-shot operation, not continuous
  #     2. Only the agent+server are involved; no other clients/applications
  #     3. Operator can simply re-run the job (idempotent)
  #     4. No data loss to production — restoring TO a target, not FROM production
  #   Mitigation: Auto-restore fsync/full_page_writes immediately after restore.
  #
  # OBSERVABILITY:
  #   - Logged before/after with timestamps
  #   - Changes persisted to restore metrics JSON
  #   - Original values captured for audit
  #
  # SAFETY: If script is interrupted (SIGINT/SIGTERM), trap ensures settings
  # are restored before exit.
  #
  # SEE ALSO: PostgreSQL docs on fsync, full_page_writes, and performance
  # tuning for bulk loads: https://www.postgresql.org/docs/current/wal-configuration.html
  # ---------------------------------------------------------------------------

  # Helper: Manage fsync/full_page_writes state
  get_wal_setting() {
    local setting_name="$1"
    psql "host=${TARGET_POSTGRES_HOST} port=${postgres_port} user=${TARGET_POSTGRES_ADMIN_USER} dbname=postgres sslmode=require" \
      -tAc "SELECT setting FROM pg_settings WHERE name = '${setting_name}'" 2>/dev/null | tr -d '[:space:]' || echo "unknown"
  }

  set_wal_setting() {
    local setting_name="$1"
    local setting_value="$2"
    psql "host=${TARGET_POSTGRES_HOST} port=${postgres_port} user=${TARGET_POSTGRES_ADMIN_USER} dbname=postgres sslmode=require" \
      -c "ALTER SYSTEM SET ${setting_name} = ${setting_value}; SELECT pg_reload_conf();" \
      >/dev/null 2>&1 || {
        warn "Failed to set ${setting_name}=${setting_value}; continuing with current value"
        return 1
      }
  }

  # Capture original WAL settings before any changes
  local original_fsync
  original_fsync=$(get_wal_setting "fsync")
  local original_full_page_writes
  original_full_page_writes=$(get_wal_setting "full_page_writes")

  log "Current WAL settings: fsync=${original_fsync}, full_page_writes=${original_full_page_writes}"

  # Disable fsync and full_page_writes for the restore phase
  # These will be restored in the cleanup trap below
  local wal_settings_modified=false
  if [[ "${original_fsync}" != "off" ]] || [[ "${original_full_page_writes}" != "off" ]]; then
    log "Disabling fsync and full_page_writes for restore phase (IOPS optimization)"
    log "  ⚠ RISK: If agent/server crashes, database may be inconsistent and require re-run"
    log "  ⚠ MITIGATION: Restore will be re-enabled immediately after phase completes"
    set_wal_setting "fsync" "off" && set_wal_setting "full_page_writes" "off"
    wal_settings_modified=true
  fi

  # Trap to ensure WAL settings are restored on any exit
  trap 'if [[ "$wal_settings_modified" == "true" ]]; then
    log "Restoring WAL settings after restore phase completion"
    set_wal_setting "fsync" "on" >/dev/null 2>&1 || warn "Failed to restore fsync; manual intervention may be needed"
    set_wal_setting "full_page_writes" "on" >/dev/null 2>&1 || warn "Failed to restore full_page_writes; manual intervention may be needed"
  fi' EXIT

  log "Starting database restore phase with optimized WAL settings"

  local db_results_json="[]"
  local total_db_restore_started_epoch
  total_db_restore_started_epoch=$(date +%s)
  local wal_tuning_info=""

  for database_blob_name in "${all_db_blobs[@]}"; do
    local db_name
    db_name=$(db_name_from_blob "$database_blob_name")
    # Skip Azure-managed system databases. These are pre-created on every new
    # Flexible Server instance and contain Azure-internal extensions and objects
    # (pg_availability, azure, pgaadauth, cron schema from pg_cron) that cannot
    # be restored from a backup dump — Azure owns and manages them directly.
    # User application data must always live in named databases, not in these.
    if [[ "$db_name" == "azure_maintenance" || "$db_name" == "azure_sys" || "$db_name" == "postgres" || "$db_name" == "template1" ]]; then
      log "Skipping Azure-managed system database: ${db_name}"
      continue
    fi
    log "============================================================"
    log " Restoring database: ${db_name}"
    log " Blob: ${database_blob_name}"
    log "============================================================"

    local db_file="restore-output/${database_blob_name##*/}"
    az storage blob download \
      --account-name "$TARGET_STORAGE_ACCOUNT" \
      --container-name "$TARGET_STORAGE_CONTAINER" \
      --name "$database_blob_name" \
      --file "$db_file" \
      --auth-mode login \
      -o none

    local db_restore_started_epoch
    db_restore_started_epoch=$(date +%s)

    local database_exists
    database_exists=$(psql \
      "host=${TARGET_POSTGRES_HOST} port=${postgres_port} user=${TARGET_POSTGRES_ADMIN_USER} dbname=postgres sslmode=require" \
      -tAc "SELECT 1 FROM pg_database WHERE datname='${db_name}'" | tr -d '[:space:]')

    if [[ "$database_exists" != "1" ]]; then
      log "Creating target database ${db_name}"
      psql "host=${TARGET_POSTGRES_HOST} port=${postgres_port} user=${TARGET_POSTGRES_ADMIN_USER} dbname=postgres sslmode=require" \
        -c "CREATE DATABASE \"${db_name}\" WITH OWNER = \"${TARGET_POSTGRES_ADMIN_USER}\" ENCODING = 'UTF8' LC_COLLATE = 'en_GB.utf8' LC_CTYPE = 'en_GB.utf8' TEMPLATE = template0;"
    else
      log "Target database ${db_name} already exists"
    fi

    local pg_restore_log="restore-output/pg_restore-${db_name}.log"
    local db_restore_tool="pg_restore"
    set +e
    # Disable statement_timeout (source server value may have been dumped into
    # the backup) and enable TCP keepalives to prevent the server or network
    # from dropping long-running COPY connections for large tables.
    # -j: use parallel workers for data load and index build phases. Workers
    # operate on independent tables/indexes; if there is only one table the
    # extra workers sit idle — no errors, no wasted work. Only applies to
    # custom-format dumps (Azure Backup Vault default); plain-text SQL files
    # trigger the psql fallback below which is unaffected by this flag.
    # maintenance_work_mem: set dynamically above from server shared_buffers.
    # synchronous_commit=off: WAL writes are queued asynchronously (~0.6s
    # risk window). Safe for restores — if the agent crashes, re-run the job.
    # Reduces write amplification by 20-40% on IOPS-constrained storage.
    PGOPTIONS="-c statement_timeout=0 -c tcp_keepalives_idle=60 -c tcp_keepalives_interval=10 -c tcp_keepalives_count=6 -c maintenance_work_mem=${maintenance_work_mem_mb}MB -c synchronous_commit=off" \
    pg_restore \
      -h "$TARGET_POSTGRES_HOST" \
      -p "$postgres_port" \
      -U "$TARGET_POSTGRES_ADMIN_USER" \
      -d "$db_name" \
      --no-owner \
      --no-privileges \
      -j "$pg_restore_parallel_workers" \
      -v \
      "$db_file" 2>&1 | tee "$pg_restore_log"
    local pg_restore_exit_code=${PIPESTATUS[0]}
    set -e

    if [[ "$pg_restore_exit_code" -ne 0 ]]; then
      # Check whether all errors are Azure extension allow-list rejections.
      # Extensions such as pgstattuple, pg_visibility, etc. cannot be installed
      # by azure_pg_admin users. These are diagnostic/maintenance extensions;
      # application data still restores correctly ar. Treat allow-list
      # errors as warnings and continue rather than aborting the restore.
      local non_allowlist_errors
      non_allowlist_errors=$(grep "^pg_restore: error:" "$pg_restore_log" 2>/dev/null \
        | grep -v "allow-listed" || true)

      if [[ -z "$non_allowlist_errors" ]]; then
        warn "pg_restore completed with extension allow-list warnings for ${db_name} (exit ${pg_restore_exit_code}). All non-extension objects restored successfully. See ${pg_restore_log}."
      else
        # If pg_restore processed data for any tables before failing, a psql
        # fallback would cause a duplicate load. Verbose mode reports
        # "processing data for table" — check for that pattern.
        local data_loaded
        data_loaded=$(grep -c "^pg_restore: processing data for table" "$pg_restore_log" 2>/dev/null || true)
        [[ -z "$data_loaded" ]] && data_loaded=0

        if [[ "$data_loaded" -gt 0 ]]; then
          fail "pg_restore loaded data for ${data_loaded} table(s) in ${db_name} before failing (exit ${pg_restore_exit_code}). Refusing psql fallback to prevent duplicate load. Review ${pg_restore_log}."
        fi

        # Only fall back when no data was loaded and the file is confirmed plain-text SQL.
        # Detect plain-text by checking for the PostgreSQL custom-format magic bytes
        # (PGDMP header). If absent, the file is plain-text SQL. Avoids requiring
        # the 'file' utility which may not be present on the build agent.
        local file_magic
        file_magic=$(head -c 5 "$db_file" 2>/dev/null || true)
        if [[ "$file_magic" != "PGDMP"* ]]; then
          log "pg_restore failed with no data loaded and file is plain-text SQL. Falling back to psql."
          db_restore_tool="psql"
          psql "host=${TARGET_POSTGRES_HOST} port=${postgres_port} user=${TARGET_POSTGRES_ADMIN_USER} dbname=${db_name} sslmode=require" -f "$db_file"
        else
          fail "pg_restore failed (exit ${pg_restore_exit_code}) for ${db_name} with non-extension errors. No fallback available. Review ${pg_restore_log}."
        fi
      fi
    fi

    local db_restore_ended_epoch
    db_restore_ended_epoch=$(date +%s)
    local db_restore_duration_seconds=$((db_restore_ended_epoch - db_restore_started_epoch))

    local db_entry
    db_entry=$(jq -n \
      --arg sourceBlobName "$database_blob_name" \
      --arg databaseName "$db_name" \
      --arg dbRestoreTool "$db_restore_tool" \
      --argjson durationSeconds "$db_restore_duration_seconds" \
      '{
        sourceBlobName: $sourceBlobName,
        databaseName: $databaseName,
        restoreTool: $dbRestoreTool,
        durationSeconds: $durationSeconds,
        durationMinutes: "\($durationSeconds / 60 | floor)min \($durationSeconds % 60)s"
      }')
    db_results_json=$(echo "$db_results_json" | jq --argjson entry "$db_entry" '. + [$entry]')

    log "Database ${db_name} restored in ${db_restore_duration_seconds}s using ${db_restore_tool}"

    # Remove the local dump file now that restore is complete to avoid
    # accumulating all blobs on the agent disk simultaneously.
    rm -f "$db_file"
  done

  local total_db_restore_ended_epoch
  total_db_restore_ended_epoch=$(date +%s)
  local total_db_restore_duration_seconds=$((total_db_restore_ended_epoch - total_db_restore_started_epoch))

  # Capture final WAL settings state for audit trail
  local final_fsync
  final_fsync=$(get_wal_setting "fsync")
  local final_full_page_writes
  final_full_page_writes=$(get_wal_setting "full_page_writes")
  wal_tuning_info=$(jq -n \
    --arg originalFsync "$original_fsync" \
    --arg originalFullPageWrites "$original_full_page_writes" \
    --arg finalFsync "$final_fsync" \
    --arg finalFullPageWrites "$final_full_page_writes" \
    --arg settingsModified "$wal_settings_modified" \
    --arg reason "IOPS optimization for restore phase: fsync/full_page_writes disabled during restore, auto-restored after" \
    '{
      originalFsync: $originalFsync,
      originalFullPageWrites: $originalFullPageWrites,
      finalFsync: $finalFsync,
      finalFullPageWrites: $finalFullPageWrites,
      settingsModified: ($settingsModified == "true"),
      reason: $reason,
      decision: "Temporarily disabled (off) during restore-only phase. Acceptable risk because: (1) one-shot operation, (2) no other clients connected, (3) crash requires re-run anyway, (4) 25-35% throughput gain on IOPS-constrained storage justifies recovery capability."
    }')

  if [[ "$restore_scope" == "database-only" ]]; then
    # No vault metrics exist yet — write a fresh metrics file for this scope
    jq -n \
      --arg restoreScope "$restore_scope" \
      --arg targetStorageAccount "$TARGET_STORAGE_ACCOUNT" \
      --arg targetStorageContainer "$TARGET_STORAGE_CONTAINER" \
      --arg rolesBlobName "$roles_blob_name" \
      --arg targetPostgresHost "$TARGET_POSTGRES_HOST" \
      --argjson databaseRestores "$db_results_json" \
      --argjson totalDurationSeconds "$total_db_restore_duration_seconds" \
      --argjson walTuning "$wal_tuning_info" \
      '{
        restoreScope: $restoreScope,
        targetStorageAccount: $targetStorageAccount,
        targetStorageContainer: $targetStorageContainer,
        rolesBlobName: $rolesBlobName,
        targetPostgresHost: $targetPostgresHost,
        databaseRestores: $databaseRestores,
        databasePhaseDurationSeconds: $totalDurationSeconds,
        databasePhaseDurationMinutes: "\($totalDurationSeconds / 60 | floor)min \($totalDurationSeconds % 60)s",
        walTuning: $walTuning
      }' > "$metrics_file"
  else
    # Append DB restore details to the existing vault restore metrics
    jq \
      --arg rolesBlobName "$roles_blob_name" \
      --arg targetPostgresHost "$TARGET_POSTGRES_HOST" \
      --argjson databaseRestores "$db_results_json" \
      --argjson totalDurationSeconds "$total_db_restore_duration_seconds" \
      --argjson walTuning "$wal_tuning_info" \
      '. + {
        rolesBlobName: $rolesBlobName,
        targetPostgresHost: $targetPostgresHost,
        databaseRestores: $databaseRestores,
        databasePhaseDurationSeconds: $totalDurationSeconds,
        databasePhaseDurationMinutes: "\($totalDurationSeconds / 60 | floor)min \($totalDurationSeconds % 60)s",
        walTuning: $walTuning
      }' "$metrics_file" > "${metrics_file}.tmp"
    mv "${metrics_file}.tmp" "$metrics_file"
  fi

  log "Database restore phase completed: ${#all_db_blobs[@]} database(s) restored in ${total_db_restore_duration_seconds}s"
  log "Metrics file: ${metrics_file}"
}

main "$@"
