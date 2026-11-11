# ---------------------------------------------------------------------------------------------------------------------
# LOCAL VALUES
# Computed values used throughout the module
# ---------------------------------------------------------------------------------------------------------------------

locals {

  # Flatten all per-storage-account subnet references into a single map so they
  # can be resolved via a single for_each data lookup. Keys are unique across
  # all storage accounts: "<sa_key>--<subnet_name>--<vnet_name>".
  storage_account_subnet_refs = {
    for pair in flatten([
      for sa_key, sa in var.storage_accounts : [
        for subnet in try(sa.virtual_network_subnets, []) : {
          key                  = "${sa_key}_${subnet.name}_${subnet.virtual_network_name}"
          storage_account_key  = sa_key
          name                 = subnet.name
          virtual_network_name = subnet.virtual_network_name
          resource_group_name  = subnet.resource_group_name
        }
      ]
    ]) : pair.key => pair
  }

  # Reconstruct per-storage-account lists of resolved subnet IDs after the
  # data lookup. Merged with any IDs added directly to restore_storage_subnet_ids.
  storage_account_resolved_subnet_ids = {
    for sa_key in keys(var.storage_accounts) : sa_key => [
      for k, ref in local.storage_account_subnet_refs :
      data.azurerm_subnet.storage_account_subnets[k].id
      if ref.storage_account_key == sa_key
    ]
  }

  # Storage accounts onboarded to the backup vault, keyed by account name.
  # Empty when no onboarding file is configured for the environment.
  storage_backup_targets = var.storage_account_backup_onboarding_file == null ? {} : {
    for sa in yamldecode(file("${path.module}/${var.storage_account_backup_onboarding_file}")) : sa.name => sa
  }

  # ADLS accounts to enrol: type adls with backup-enabled set to true.
  adls_backup_instances = {
    for k, sa in local.storage_backup_targets : k => sa
    if try(sa.type, "") == "adls" && try(sa["backup-enabled"], false) == true
  }

  # ADLS backup policies in cpp-backup-vault, keyed by policy name (e.g. adls-test),
  # so entries in the onboarding file can refer to a policy by name.
  adls_backup_policy_ids = {
    for p in [
      [module.backup_vaults["cpp-backup-vault"].adls_crit4_5_policy_name, module.backup_vaults["cpp-backup-vault"].adls_crit4_5_policy_id],
      [module.backup_vaults["cpp-backup-vault"].adls_test_policy_name, module.backup_vaults["cpp-backup-vault"].adls_test_policy_id],
    ] : p[0] => p[1] if p[0] != null
  }

  # Blob accounts to enrol: type blob with backup-enabled set to true.
  blob_backup_instances = {
    for k, sa in local.storage_backup_targets : k => sa
    if try(sa.type, "") == "blob" && try(sa["backup-enabled"], false) == true
  }

  # Blob backup policies in cpp-backup-vault, keyed by policy name (e.g. blob-test).
  blob_backup_policy_ids = {
    for p in [
      [module.backup_vaults["cpp-backup-vault"].blob_crit4_5_policy_name, module.backup_vaults["cpp-backup-vault"].blob_crit4_5_policy_id],
      [module.backup_vaults["cpp-backup-vault"].blob_test_policy_name, module.backup_vaults["cpp-backup-vault"].blob_test_policy_id],
    ] : p[0] => p[1] if p[0] != null
  }

  # Common tags for HMCTS resources
  common_tags = {
    for k, v in {
      namespace   = var.namespace
      costcode    = var.costcode
      owner       = var.owner
      application = var.application
      environment = var.environment
      type        = var.type
    } : k => v if v != ""
  }
}
