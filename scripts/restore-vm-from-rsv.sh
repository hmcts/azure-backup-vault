#!/usr/bin/env bash

set -euo pipefail

# ------------------------------------------------------------------
# restore-vm-from-rsv.sh
#
# Self-service VM restore from Azure Recovery Services Vault (RSV).
# Supports four restore methods mapped to BCDR failure scenarios:
#
#   replace-existing  Replace Existing (OriginalLocation, in-place)   — S2: VM non-bootable
#   create-new-vm  Create New VM   (AlternateLocation)             — S3: VM deleted
#   restore-disks-only  Restore Managed Disks only (disk-only)          — S3, S4: DR drill
#   file-recovery  Item-Level Recovery (ILR / file recovery)       — S1, S5: file/data loss
#
# All inputs are provided as environment variables (passed from the pipeline).
# See azure-pipelines-restore-vm-cnp.yaml / azure-pipelines-restore-vm-cpp.yaml.
#
# Required environment variables (all methods):
#   VAULT_NAME                    RSV name
#   VAULT_RESOURCE_GROUP          RSV resource group
#   SOURCE_VM_NAME                Name of the VM to restore
#   SOURCE_RESOURCE_GROUP         Resource group of the source VM
#   RESTORE_METHOD                replace-existing | create-new-vm | restore-disks-only | file-recovery
#   STAGING_STORAGE_ACCOUNT       Pre-provisioned storage account for disk staging
#   STAGING_STORAGE_ACCOUNT_RG    Resource group of the staging storage account
#   DRY_RUN                       true | false (default: true)
#
# Optional environment variables:
#   VAULT_SUBSCRIPTION            RSV subscription; defaults to current CLI context
#   SOURCE_SUBSCRIPTION           VM subscription; defaults to current CLI context
#   RECOVERY_POINT_ID             Pin to exact RP name; default: latest available
#   RECOVERY_POINT_TIME_UTC       Pin to RP at or before this ISO-8601 UTC time
#   RESTORE_TIMEOUT_MINUTES       Job timeout; default 240
#   POLL_SECONDS                  Polling interval; default 30
#
# Method A only (Create New VM):
#   TARGET_RESOURCE_GROUP         Target RG for new VM; defaults to SOURCE_RESOURCE_GROUP
#   TARGET_SUBSCRIPTION           Target subscription for cross-sub restore
#   TARGET_VM_NAME                New VM name; default: auto-generated
#   TARGET_VNET_NAME              Target VNet name (required for create-new-vm)
#   TARGET_SUBNET_NAME            Target subnet name (required for create-new-vm)
#   TARGET_VNET_RESOURCE_GROUP    Target VNet resource group (required for create-new-vm)
#
# Method B only (Restore Managed Disks):
#   TARGET_RESOURCE_GROUP         Target RG for restored disks; defaults to SOURCE_RESOURCE_GROUP
#   TARGET_SUBSCRIPTION           Target subscription for cross-sub restore
#
# ------------------------------------------------------------------

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

# ---------------------------------------------------------------------------
# select_recovery_point
#
# Selects the appropriate recovery point name from a JSON list.
# Priority: explicit ID > latest at-or-before timestamp > most recent overall.
# ---------------------------------------------------------------------------
select_recovery_point() {
  local recovery_points_json="$1"
  local recovery_point_id="${2:-}"
  local recovery_point_time_utc="${3:-}"

  if [[ -n "$recovery_point_id" ]]; then
    echo "$recovery_points_json" | jq -r --arg rp "$recovery_point_id" \
      '.[] | select(.name == $rp) | .name' | head -n1
    return
  fi

  if [[ -n "$recovery_point_time_utc" ]]; then
    echo "$recovery_points_json" | jq -r --arg ts "$recovery_point_time_utc" '
      map({
        name: .name,
        t: (.properties.recoveryPointTime | gsub("\\.[0-9]+"; "") | gsub("\\+[0-9:]+$"; "Z") | fromdateiso8601)
      })
      | map(select(.t <= ($ts | gsub("\\.[0-9]+"; "") | gsub("\\+[0-9:]+$"; "Z") | fromdateiso8601)))
      | sort_by(.t)
      | last
      | .name // empty
    '
    return
  fi

  # Default: most recent recovery point
  echo "$recovery_points_json" | jq -r '
    map({
      name: .name,
      t: (.properties.recoveryPointTime | gsub("\\.[0-9]+"; "") | gsub("\\+[0-9:]+$"; "Z") | fromdateiso8601)
    })
    | sort_by(.t)
    | last
    | .name // empty
  '
}

# ---------------------------------------------------------------------------
# poll_job
#
# Polls an RSV backup job until it reaches a terminal state.
# Exits 1 if the job fails or times out.
# ---------------------------------------------------------------------------
poll_job() {
  local job_id="$1"
  local vault_name="$2"
  local vault_rg="$3"
  local vault_sub_flag="${4:-}"
  local timeout_minutes="${5:-240}"
  local poll_seconds="${6:-30}"

  local elapsed=0
  local max_seconds=$(( timeout_minutes * 60 ))
  local status=""

  log "Polling job ${job_id} (timeout: ${timeout_minutes} min, interval: ${poll_seconds}s)"

  while true; do
    # shellcheck disable=SC2086
    status=$(az backup job show \
      --vault-name "$vault_name" \
      -g "$vault_rg" \
      --name "$job_id" \
      $vault_sub_flag \
      --query "properties.status" -o tsv 2>/dev/null || echo "Unknown")

    log "  [${elapsed}s] Job status: ${status}"

    case "$status" in
      Completed)
        log "Job ${job_id} completed successfully."
        return 0
        ;;
      Failed|Cancelled)
        fail "Job ${job_id} ended with status: ${status}"
        ;;
    esac

    if [[ $elapsed -ge $max_seconds ]]; then
      fail "Job ${job_id} did not complete within ${timeout_minutes} minutes. Last status: ${status}"
    fi

    sleep "$poll_seconds" || true  # tolerate signal-interrupted sleep (e.g. SIGHUP)
    elapsed=$(( elapsed + poll_seconds ))
  done
}

# ---------------------------------------------------------------------------
# write_metrics
#
# Emits a restore-metrics.json file in restore-output/ for pipeline artifact.
# ---------------------------------------------------------------------------
write_metrics() {
  local method="$1"
  local source_vm="$2"
  local source_rg="$3"
  local recovery_point_id="$4"
  local recovery_point_time="$5"
  local job_id="$6"
  local job_status="$7"
  local start_time="$8"
  local end_time="$9"
  local dry_run="${10}"

  local duration_minutes="n/a"
  if [[ "$start_time" != "n/a" && "$end_time" != "n/a" ]]; then
    local start_epoch end_epoch
    start_epoch=$(date -u -d "$start_time" +%s 2>/dev/null || date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$start_time" +%s 2>/dev/null || echo 0)
    end_epoch=$(date -u -d "$end_time" +%s 2>/dev/null || date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$end_time" +%s 2>/dev/null || echo 0)
    if [[ "$start_epoch" -gt 0 && "$end_epoch" -gt 0 ]]; then
      duration_minutes=$(( (end_epoch - start_epoch) / 60 ))
    fi
  fi

  mkdir -p restore-output
  cat > restore-output/restore-metrics.json <<EOF
{
  "restoreMethod": "${method}",
  "sourceVmName": "${source_vm}",
  "sourceResourceGroup": "${source_rg}",
  "recoveryPointId": "${recovery_point_id}",
  "recoveryPointTimeUtc": "${recovery_point_time}",
  "restoreJobId": "${job_id}",
  "restoreJobStatus": "${job_status}",
  "startTimeUtc": "${start_time}",
  "endTimeUtc": "${end_time}",
  "durationMinutes": "${duration_minutes}",
  "dryRun": ${dry_run}
}
EOF
  log "Metrics written to restore-output/restore-metrics.json"
}

# ---------------------------------------------------------------------------
# restore_method_c
#
# Replace Existing (OriginalLocation / in-place).
# Stops the VM, replaces its disks from the recovery point, restarts.
# VM identity (NIC, IP, RBAC) is fully preserved.
# VM must exist and be in the same subscription as the vault.
#
# Post-restore: the original OS disk is retained in the RG and must be
# deleted manually once the restore is verified. See runbook.
# ---------------------------------------------------------------------------
restore_method_c() {
  local vault_name="$1"
  local vault_rg="$2"
  local vault_sub_flag="$3"
  local source_vm="$4"
  local source_rg="$5"
  local source_sub_flag="$6"
  local selected_rp="$7"
  local staging_sa="$8"
  local staging_sa_rg="$9"
  local dry_run="${10}"
  local timeout_minutes="${11}"
  local poll_seconds="${12}"

  local start_time job_id job_status end_time

  log "=== Method C: Replace Existing (OriginalLocation) ==="
  log "Source VM:         ${source_vm} in ${source_rg}"
  log "Recovery point:    ${selected_rp}"
  log "Staging account:   ${staging_sa} (${staging_sa_rg})"

  if [[ "${dry_run,,}" == "true" ]]; then
    log "[DRY RUN] Would execute:"
    log "  1. az vm stop      --name ${source_vm} -g ${source_rg} ${source_sub_flag}"
    log "  2. az vm deallocate --name ${source_vm} -g ${source_rg} ${source_sub_flag}"
    log "  3. az backup restore restore-disks \\"
    log "       --vault-name ${vault_name} -g ${vault_rg} ${vault_sub_flag} \\"
    log "       --container-name ${source_vm} --item-name ${source_vm} \\"
    log "       --rp-name ${selected_rp} \\"
    log "       --storage-account ${staging_sa} \\"
    log "       --storage-account-resource-group ${staging_sa_rg} \\"
    log "       --restore-mode OriginalLocation"
    log "  4. az vm start     --name ${source_vm} -g ${source_rg} ${source_sub_flag}"
    log "[DRY RUN] No changes made."
    write_metrics "replace-existing" "$source_vm" "$source_rg" "$selected_rp" "n/a" "n/a" "dry-run" "n/a" "n/a" "true"
    return 0
  fi

  # Safety trap: ensure VM is restarted even if the script exits unexpectedly
  # (e.g. poll_job interrupted). Cleared at end of function.
  # shellcheck disable=SC2064,SC2086
  trap "warn 'EXIT trap: attempting to restart ${source_vm}...'; az vm start --name '${source_vm}' -g '${source_rg}' ${source_sub_flag} --output none 2>/dev/null || true" EXIT

  log "Stopping VM ${source_vm} before in-place restore..."
  # shellcheck disable=SC2086
  az vm stop --name "$source_vm" -g "$source_rg" $source_sub_flag --output none
  # shellcheck disable=SC2086
  az vm deallocate --name "$source_vm" -g "$source_rg" $source_sub_flag --output none
  log "VM stopped and deallocated."

  start_time=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  log "Triggering OriginalLocation restore..."

  # shellcheck disable=SC2086
  local restore_output
  restore_output=$(az backup restore restore-disks \
    --vault-name "$vault_name" \
    -g "$vault_rg" \
    $vault_sub_flag \
    --container-name "$source_vm" \
    --item-name "$source_vm" \
    --rp-name "$selected_rp" \
    --storage-account "$staging_sa" \
    --storage-account-resource-group "$staging_sa_rg" \
    --restore-mode OriginalLocation \
    -o json)

  job_id=$(echo "$restore_output" | jq -r '.name // empty')
  [[ -n "$job_id" ]] || fail "Restore job ID not found in response."
  log "Restore job started: ${job_id}"
  echo "##vso[task.setvariable variable=restoreJobId]${job_id}"

  poll_job "$job_id" "$vault_name" "$vault_rg" "$vault_sub_flag" "$timeout_minutes" "$poll_seconds"
  job_status="Completed"
  end_time=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  log "Restore complete. Starting VM..."
  # shellcheck disable=SC2086
  az vm start --name "$source_vm" -g "$source_rg" $source_sub_flag --output none
  trap - EXIT  # VM is running; clear the safety trap
  log "VM ${source_vm} is running."

  warn "Post-restore: the original OS disk has been retained in ${source_rg}."
  warn "Verify the restore is correct, then delete the old disk manually."
  warn "Also check for any queued Run Commands — the VM agent replays the last one on boot."

  write_metrics "replace-existing" "$source_vm" "$source_rg" "$selected_rp" "n/a" "$job_id" "$job_status" "$start_time" "$end_time" "false"
}

# ---------------------------------------------------------------------------
# restore_method_a
#
# Create New VM (AlternateLocation).
# Restores disks and provisions a new VM from the ARM template generated by
# the restore job. The source VM is unaffected.
# New VM will have a dynamic IP — apply static IP / RBAC separately if needed.
# ---------------------------------------------------------------------------
restore_method_a() {
  local vault_name="$1"
  local vault_rg="$2"
  local vault_sub_flag="$3"
  local source_vm="$4"
  local source_rg="$5"
  local source_sub_flag="$6"
  local selected_rp="$7"
  local staging_sa="$8"
  local staging_sa_rg="$9"
  local target_rg="${10}"
  local target_sub_flag="${11}"
  local target_vm_name="${12}"
  local target_vnet_name="${13}"
  local target_subnet_name="${14}"
  local target_vnet_rg="${15}"
  local dry_run="${16}"
  local timeout_minutes="${17}"
  local poll_seconds="${18}"

  local start_time job_id job_status end_time

  log "=== Method A: Create New VM (AlternateLocation) ==="
  log "Source VM:         ${source_vm} in ${source_rg}"
  log "Recovery point:    ${selected_rp}"
  log "Target RG:         ${target_rg}"
  log "Target VM name:    ${target_vm_name}"
  log "Target VNet:       ${target_vnet_name} / ${target_subnet_name} (${target_vnet_rg})"
  log "Staging account:   ${staging_sa} (${staging_sa_rg})"

  if [[ "${dry_run,,}" == "true" ]]; then
    log "[DRY RUN] Would execute:"
    log "  az backup restore restore-disks \\"
    log "    --vault-name ${vault_name} -g ${vault_rg} ${vault_sub_flag} \\"
    log "    --container-name ${source_vm} --item-name ${source_vm} \\"
    log "    --rp-name ${selected_rp} \\"
    log "    --storage-account ${staging_sa} \\"
    log "    --storage-account-resource-group ${staging_sa_rg} \\"
    log "    --restore-to-staging-storage-account true \\"
    log "    --target-resource-group ${target_rg} ${target_sub_flag} \\"
    log "    --target-vm-name ${target_vm_name} \\"
    log "    --target-vnet-name ${target_vnet_name} \\"
    log "    --target-subnet-name ${target_subnet_name} \\"
    log "    --target-vnet-resource-group ${target_vnet_rg}"
    log "[DRY RUN] No changes made."
    write_metrics "create-new-vm" "$source_vm" "$source_rg" "$selected_rp" "n/a" "n/a" "dry-run" "n/a" "n/a" "true"
    return 0
  fi

  start_time=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  log "Triggering AlternateLocation restore..."

  # Build target subscription flag for the restore command
  local target_sub_id_flag=""
  if [[ -n "$target_sub_flag" ]]; then
    local target_sub_id
    target_sub_id=$(echo "$target_sub_flag" | awk '{print $2}')
    target_sub_id_flag="--target-subscription-id ${target_sub_id}"
  fi

  # shellcheck disable=SC2086
  local restore_output
  restore_output=$(az backup restore restore-disks \
    --vault-name "$vault_name" \
    -g "$vault_rg" \
    $vault_sub_flag \
    --container-name "$source_vm" \
    --item-name "$source_vm" \
    --rp-name "$selected_rp" \
    --storage-account "$staging_sa" \
    --storage-account-resource-group "$staging_sa_rg" \
    --restore-to-staging-storage-account true \
    --target-resource-group "$target_rg" \
    $target_sub_id_flag \
    --target-vm-name "$target_vm_name" \
    --target-vnet-name "$target_vnet_name" \
    --target-subnet-name "$target_subnet_name" \
    --target-vnet-resource-group "$target_vnet_rg" \
    -o json)

  job_id=$(echo "$restore_output" | jq -r '.name // empty')
  [[ -n "$job_id" ]] || fail "Restore job ID not found in response."
  log "Restore job started: ${job_id}"
  echo "##vso[task.setvariable variable=restoreJobId]${job_id}"

  poll_job "$job_id" "$vault_name" "$vault_rg" "$vault_sub_flag" "$timeout_minutes" "$poll_seconds"
  job_status="Completed"
  end_time=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  log "Restore complete. New VM '${target_vm_name}' should now exist in ${target_rg}."
  warn "New VM will have a dynamic IP — apply static IP and RBAC assignments manually if required."
  warn "Extensions installed on the source VM are not carried over — reinstall if needed."

  write_metrics "create-new-vm" "$source_vm" "$source_rg" "$selected_rp" "n/a" "$job_id" "$job_status" "$start_time" "$end_time" "false"
}

# ---------------------------------------------------------------------------
# restore_method_b
#
# Restore Managed Disks only (disk-only, no VM provisioned).
# Restores OS and data disks to the target resource group and generates an
# ARM template. Use this for DR drills and cross-subscription scenarios
# where networking constraints block full VM restore.
# ---------------------------------------------------------------------------
restore_method_b() {
  local vault_name="$1"
  local vault_rg="$2"
  local vault_sub_flag="$3"
  local source_vm="$4"
  local source_rg="$5"
  local source_sub_flag="$6"
  local selected_rp="$7"
  local staging_sa="$8"
  local staging_sa_rg="$9"
  local target_rg="${10}"
  local target_sub_flag="${11}"
  local dry_run="${12}"
  local timeout_minutes="${13}"
  local poll_seconds="${14}"

  local start_time job_id job_status end_time

  log "=== Method B: Restore Managed Disks only ==="
  log "Source VM:         ${source_vm} in ${source_rg}"
  log "Recovery point:    ${selected_rp}"
  log "Target RG:         ${target_rg}"
  log "Staging account:   ${staging_sa} (${staging_sa_rg})"

  if [[ "${dry_run,,}" == "true" ]]; then
    log "[DRY RUN] Would execute:"
    log "  az backup restore restore-disks \\"
    log "    --vault-name ${vault_name} -g ${vault_rg} ${vault_sub_flag} \\"
    log "    --container-name ${source_vm} --item-name ${source_vm} \\"
    log "    --rp-name ${selected_rp} \\"
    log "    --storage-account ${staging_sa} \\"
    log "    --storage-account-resource-group ${staging_sa_rg} \\"
    log "    --restore-to-staging-storage-account true \\"
    log "    --target-resource-group ${target_rg} ${target_sub_flag}"
    log "[DRY RUN] No changes made."
    write_metrics "restore-disks-only" "$source_vm" "$source_rg" "$selected_rp" "n/a" "n/a" "dry-run" "n/a" "n/a" "true"
    return 0
  fi

  # Build target subscription flag for the restore command
  local target_sub_id_flag=""
  if [[ -n "$target_sub_flag" ]]; then
    local target_sub_id
    target_sub_id=$(echo "$target_sub_flag" | awk '{print $2}')
    target_sub_id_flag="--target-subscription-id ${target_sub_id}"
  fi

  start_time=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  log "Triggering disk-only restore..."

  # shellcheck disable=SC2086
  local restore_output
  restore_output=$(az backup restore restore-disks \
    --vault-name "$vault_name" \
    -g "$vault_rg" \
    $vault_sub_flag \
    --container-name "$source_vm" \
    --item-name "$source_vm" \
    --rp-name "$selected_rp" \
    --storage-account "$staging_sa" \
    --storage-account-resource-group "$staging_sa_rg" \
    --restore-to-staging-storage-account true \
    --target-resource-group "$target_rg" \
    $target_sub_id_flag \
    -o json)

  job_id=$(echo "$restore_output" | jq -r '.name // empty')
  [[ -n "$job_id" ]] || fail "Restore job ID not found in response."
  log "Restore job started: ${job_id}"
  echo "##vso[task.setvariable variable=restoreJobId]${job_id}"

  poll_job "$job_id" "$vault_name" "$vault_rg" "$vault_sub_flag" "$timeout_minutes" "$poll_seconds"
  job_status="Completed"
  end_time=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  log "Restore complete. Managed disks now exist in ${target_rg}."
  log "An ARM template has been written to the staging storage account: ${staging_sa}"
  warn "Delete the restored disks from ${target_rg} once verified — do not leave them running."
  warn "Clean up staging storage account blobs after use."

  write_metrics "restore-disks-only" "$source_vm" "$source_rg" "$selected_rp" "n/a" "$job_id" "$job_status" "$start_time" "$end_time" "false"
}

# ---------------------------------------------------------------------------
# restore_method_d
#
# Item-Level Recovery (ILR / file recovery).
# Mounts the recovery point as an iSCSI target on a running recovery VM.
# The operator browses and copies individual files. Source VM is unaffected.
# Session limit: 12 hours. Python 2.7+ required on the recovery machine.
# ADE-encrypted VMs are not supported.
# ---------------------------------------------------------------------------
restore_method_d() {
  local vault_name="$1"
  local vault_rg="$2"
  local vault_sub_flag="$3"
  local source_vm="$4"
  local source_rg="$5"
  local selected_rp="$6"
  local dry_run="$7"

  log "=== Method D: Item-Level Recovery (ILR / File Recovery) ==="
  log "Source VM:         ${source_vm} in ${source_rg}"
  log "Recovery point:    ${selected_rp}"

  if [[ "${dry_run,,}" == "true" ]]; then
    log "[DRY RUN] Would execute:"
    log "  az backup restore files mount-rp \\"
    log "    --vault-name ${vault_name} -g ${vault_rg} ${vault_sub_flag} \\"
    log "    --container-name ${source_vm} --item-name ${source_vm} \\"
    log "    --rp-name ${selected_rp}"
    log "[DRY RUN] No changes made."
    write_metrics "file-recovery" "$source_vm" "$source_rg" "$selected_rp" "n/a" "n/a" "dry-run" "n/a" "n/a" "true"
    return 0
  fi

  log "Mounting recovery point for ILR..."
  # shellcheck disable=SC2086
  local mount_output
  mount_output=$(az backup restore files mount-rp \
    --vault-name "$vault_name" \
    -g "$vault_rg" \
    $vault_sub_flag \
    --container-name "$source_vm" \
    --item-name "$source_vm" \
    --rp-name "$selected_rp" \
    -o json)

  local script_content
  script_content=$(echo "$mount_output" | jq -r '.properties.scriptContent // empty')
  local script_path="restore-output/ilr-mount.sh"
  mkdir -p restore-output

  if [[ -n "$script_content" ]]; then
    echo "$script_content" > "$script_path"
    chmod +x "$script_path"
    log "ILR mount script written to: ${script_path}"
  fi

  log "============================================================"
  log " ILR session active. Next steps for the operator:"
  log "============================================================"
  log "1. Copy ${script_path} to the recovery machine."
  log "2. Run the script on the recovery machine as root/sudo."
  log "3. The recovery point will be mounted as a block device."
  log "4. Browse the mounted filesystem and copy required files."
  log "5. When done, unmount: az backup restore files unmount-rp \\"
  log "     --vault-name ${vault_name} -g ${vault_rg} ${vault_sub_flag} \\"
  log "     --container-name ${source_vm} --item-name ${source_vm} \\"
  log "     --rp-name ${selected_rp}"
  log "   Session expires automatically after 12 hours."
  log "============================================================"

  write_metrics "file-recovery" "$source_vm" "$source_rg" "$selected_rp" "n/a" "ilr-session" "MountedForILR" \
    "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" "n/a" "false"
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
main() {
  require_env "VAULT_NAME"
  require_env "VAULT_RESOURCE_GROUP"
  require_env "SOURCE_VM_NAME"
  require_env "SOURCE_RESOURCE_GROUP"
  require_env "RESTORE_METHOD"

  local dry_run="${DRY_RUN:-true}"
  local restore_method="${RESTORE_METHOD}"
  local vault_name="${VAULT_NAME}"
  local vault_rg="${VAULT_RESOURCE_GROUP}"
  local source_vm="${SOURCE_VM_NAME}"
  local source_rg="${SOURCE_RESOURCE_GROUP}"
  local timeout_minutes="${RESTORE_TIMEOUT_MINUTES:-240}"
  local poll_seconds="${POLL_SECONDS:-30}"

  # Normalise sentinel 'none' values from Azure Pipelines to empty strings
  local vault_subscription="${VAULT_SUBSCRIPTION:-}"
  [[ "$vault_subscription" == "none" ]] && vault_subscription=""
  local source_subscription="${SOURCE_SUBSCRIPTION:-}"
  [[ "$source_subscription" == "none" ]] && source_subscription=""
  local recovery_point_id="${RECOVERY_POINT_ID:-}"
  [[ "$recovery_point_id" == "none" ]] && recovery_point_id=""
  local recovery_point_time_utc="${RECOVERY_POINT_TIME_UTC:-}"
  [[ "$recovery_point_time_utc" == "none" ]] && recovery_point_time_utc=""
  local target_rg="${TARGET_RESOURCE_GROUP:-}"
  [[ "$target_rg" == "none" || -z "$target_rg" ]] && target_rg="$source_rg"
  local target_subscription="${TARGET_SUBSCRIPTION:-}"
  [[ "$target_subscription" == "none" ]] && target_subscription=""
  local target_vm_name="${TARGET_VM_NAME:-}"
  [[ "$target_vm_name" == "none" || -z "$target_vm_name" ]] && \
    target_vm_name="${source_vm}-restore-$(date -u +"%H%M%d%m%y")"
  local target_vnet_name="${TARGET_VNET_NAME:-}"
  [[ "$target_vnet_name" == "none" ]] && target_vnet_name=""
  local target_subnet_name="${TARGET_SUBNET_NAME:-}"
  [[ "$target_subnet_name" == "none" ]] && target_subnet_name=""
  local target_vnet_rg="${TARGET_VNET_RESOURCE_GROUP:-}"
  [[ "$target_vnet_rg" == "none" ]] && target_vnet_rg=""

  # Method D does not use a staging storage account
  local staging_sa="${STAGING_STORAGE_ACCOUNT:-}"
  local staging_sa_rg="${STAGING_STORAGE_ACCOUNT_RG:-}"
  if [[ "$restore_method" != "file-recovery" ]]; then
    [[ -n "$staging_sa" ]] || fail "STAGING_STORAGE_ACCOUNT is required for ${restore_method}"
    [[ -n "$staging_sa_rg" ]] || fail "STAGING_STORAGE_ACCOUNT_RG is required for ${restore_method}"
  fi

  # Build optional subscription flags
  local vault_sub_flag=""
  [[ -n "$vault_subscription" ]] && vault_sub_flag="--subscription ${vault_subscription}"
  local source_sub_flag=""
  [[ -n "$source_subscription" ]] && source_sub_flag="--subscription ${source_subscription}"
  local target_sub_flag=""
  [[ -n "$target_subscription" ]] && target_sub_flag="--subscription ${target_subscription}"

  mkdir -p restore-output

  log "============================================================"
  log " VM Restore from RSV"
  log "============================================================"
  log "restoreMethod:         ${restore_method}"
  log "dryRun:                ${dry_run}"
  log "sourceVmName:          ${source_vm}"
  log "sourceResourceGroup:   ${source_rg}"
  log "vaultName:             ${vault_name}"
  log "vaultResourceGroup:    ${vault_rg}"
  log "recoveryPointId:       ${recovery_point_id:-<latest>}"
  log "recoveryPointTimeUtc:  ${recovery_point_time_utc:-<not set>}"
  log "restoreTimeoutMinutes: ${timeout_minutes}"
  log "============================================================"

  # ------------------------------------------------------------------
  # Discover recovery points (all methods)
  # ------------------------------------------------------------------
  log "Listing available recovery points for VM: ${source_vm}..."

  # shellcheck disable=SC2086
  local recovery_points_json
  recovery_points_json=$(az backup recoverypoint list \
    --vault-name "$vault_name" \
    -g "$vault_rg" \
    --container-name "$source_vm" \
    --item-name "$source_vm" \
    --backup-management-type AzureIaasVM \
    --workload-type VM \
    $vault_sub_flag \
    -o json)

  log "Available recovery points (UTC):"
  echo "$recovery_points_json" | jq -r \
    '.[] | "- \(.name) @ \(.properties.recoveryPointTime) [\(.properties.recoveryPointTierDetails[0].type // "VaultStandard")]"'

  local selected_rp
  selected_rp=$(select_recovery_point "$recovery_points_json" "$recovery_point_id" "$recovery_point_time_utc")

  [[ -n "$selected_rp" ]] || fail "Could not resolve a recovery point from the provided inputs."

  local selected_rp_time
  selected_rp_time=$(echo "$recovery_points_json" | jq -r \
    --arg rp "$selected_rp" '.[] | select(.name == $rp) | .properties.recoveryPointTime')

  log "Selected recovery point: ${selected_rp} @ ${selected_rp_time}"
  echo "##vso[task.setvariable variable=selectedRecoveryPointId;isOutput=true]${selected_rp}"

  # ------------------------------------------------------------------
  # Dispatch to method-specific restore function
  # ------------------------------------------------------------------
  case "$restore_method" in
    replace-existing)
      restore_method_c \
        "$vault_name" "$vault_rg" "$vault_sub_flag" \
        "$source_vm" "$source_rg" "$source_sub_flag" \
        "$selected_rp" "$staging_sa" "$staging_sa_rg" \
        "$dry_run" "$timeout_minutes" "$poll_seconds"
      ;;

    create-new-vm)
      [[ -n "$target_vnet_name" ]]   || fail "TARGET_VNET_NAME is required for create-new-vm"
      [[ -n "$target_subnet_name" ]] || fail "TARGET_SUBNET_NAME is required for create-new-vm"
      [[ -n "$target_vnet_rg" ]]     || fail "TARGET_VNET_RESOURCE_GROUP is required for create-new-vm"
      restore_method_a \
        "$vault_name" "$vault_rg" "$vault_sub_flag" \
        "$source_vm" "$source_rg" "$source_sub_flag" \
        "$selected_rp" "$staging_sa" "$staging_sa_rg" \
        "$target_rg" "$target_sub_flag" "$target_vm_name" \
        "$target_vnet_name" "$target_subnet_name" "$target_vnet_rg" \
        "$dry_run" "$timeout_minutes" "$poll_seconds"
      ;;

    restore-disks-only)
      restore_method_b \
        "$vault_name" "$vault_rg" "$vault_sub_flag" \
        "$source_vm" "$source_rg" "$source_sub_flag" \
        "$selected_rp" "$staging_sa" "$staging_sa_rg" \
        "$target_rg" "$target_sub_flag" \
        "$dry_run" "$timeout_minutes" "$poll_seconds"
      ;;

    file-recovery)
      restore_method_d \
        "$vault_name" "$vault_rg" "$vault_sub_flag" \
        "$source_vm" "$source_rg" \
        "$selected_rp" "$dry_run"
      ;;

    *)
      fail "Unknown restore method '${restore_method}'. Valid values: create-new-vm, restore-disks-only, replace-existing, file-recovery"
      ;;
  esac

  log "Done."
}

main "$@"
