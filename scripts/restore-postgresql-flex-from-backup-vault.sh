#!/usr/bin/env bash

set -euo pipefail

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
  grep -Ev 'role ".*" already exists|must be superuser to create role|must be superuser to alter role|permission denied to create role|permission denied to alter role|cannot execute CREATE ROLE in a read-only transaction|cannot execute ALTER ROLE in a read-only transaction' "$roles_errors_file" > "$roles_critical_file" || true

  if [[ -s "$roles_critical_file" ]]; then
    return 0
  fi

  return 1
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

    log "Restoring roles with managed-role error filtering"
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

  local db_results_json="[]"
  local total_db_restore_started_epoch
  total_db_restore_started_epoch=$(date +%s)

  for database_blob_name in "${all_db_blobs[@]}"; do
    local db_name
    db_name=$(db_name_from_blob "$database_blob_name")
    # Skip Azure-managed system databases. These are pre-created on every new
    # Flexible Server instance and contain Azure-internal extensions and objects
    # (pg_availability, azure, pgaadauth, cron schema from pg_cron) that cannot
    # be restored from a backup dump — Azure owns and manages them directly.
    # User application data must always live in named databases, not in these.
    if [[ "$db_name" == "azure_maintenance" || "$db_name" == "azure_sys" || "$db_name" == "postgres" ]]; then
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
    pg_restore \
      -h "$TARGET_POSTGRES_HOST" \
      -p "$postgres_port" \
      -U "$TARGET_POSTGRES_ADMIN_USER" \
      -d "$db_name" \
      --no-owner \
      --no-privileges \
      -v \
      "$db_file" 2>&1 | tee "$pg_restore_log"
    local pg_restore_exit_code=${PIPESTATUS[0]}
    set -e

    if [[ "$pg_restore_exit_code" -ne 0 ]]; then
      # If pg_restore loaded data for any tables before failing, a psql fallback
      # would cause a duplicate load. This is the dangerous case (especially for
      # plain-SQL dumps with no unique constraints). Abort instead.
      local data_loaded
      data_loaded=$(grep -c "^pg_restore: restoring data for table" "$pg_restore_log" 2>/dev/null || true)
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
        fail "pg_restore failed (exit ${pg_restore_exit_code}) for ${db_name} and file is not plain-text SQL. No fallback available. Review ${pg_restore_log}."
      fi
    fi

    local db_restore_ended_epoch
    db_restore_ended_epoch=$(date +%s)
    local db_restore_duration_seconds=$((db_restore_ended_epoch - db_restore_started_epoch))

    local db_entry
    db_entry=$(jq -n \
      --arg databaseBlob "$database_blob_name" \
      --arg databaseName "$db_name" \
      --arg dbRestoreTool "$db_restore_tool" \
      --argjson durationSeconds "$db_restore_duration_seconds" \
      '{
        databaseBlob: $databaseBlob,
        databaseName: $databaseName,
        restoreTool: $dbRestoreTool,
        durationSeconds: $durationSeconds
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

  if [[ "$restore_scope" == "database-only" ]]; then
    # No vault metrics exist yet — write a fresh metrics file for this scope
    jq -n \
      --arg restoreScope "$restore_scope" \
      --arg targetStorageAccount "$TARGET_STORAGE_ACCOUNT" \
      --arg targetStorageContainer "$TARGET_STORAGE_CONTAINER" \
      --arg rolesBlob "$roles_blob_name" \
      --arg targetPostgresHost "$TARGET_POSTGRES_HOST" \
      --argjson databaseRestores "$db_results_json" \
      --argjson totalDurationSeconds "$total_db_restore_duration_seconds" \
      '{
        restoreScope: $restoreScope,
        targetStorageAccount: $targetStorageAccount,
        targetStorageContainer: $targetStorageContainer,
        rolesBlob: $rolesBlob,
        targetPostgresHost: $targetPostgresHost,
        databaseRestores: $databaseRestores,
        totalDatabaseRestoreDurationSeconds: $totalDurationSeconds
      }' > "$metrics_file"
  else
    # Append DB restore details to the existing vault restore metrics
    jq \
      --arg rolesBlob "$roles_blob_name" \
      --arg targetPostgresHost "$TARGET_POSTGRES_HOST" \
      --argjson databaseRestores "$db_results_json" \
      --argjson totalDurationSeconds "$total_db_restore_duration_seconds" \
      '. + {
        rolesBlob: $rolesBlob,
        targetPostgresHost: $targetPostgresHost,
        databaseRestores: $databaseRestores,
        totalDatabaseRestoreDurationSeconds: $totalDurationSeconds
      }' "$metrics_file" > "${metrics_file}.tmp"
    mv "${metrics_file}.tmp" "$metrics_file"
  fi

  log "Database restore phase completed: ${#all_db_blobs[@]} database(s) restored in ${total_db_restore_duration_seconds}s"
  log "Metrics file: ${metrics_file}"
}

main "$@"
