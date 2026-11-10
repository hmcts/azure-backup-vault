# ---------------------------------------------------------------------------------------------------------------------
# CPP BACKUP VAULT IMPLEMENTATION
# Uses the official HMCTS Terraform module for Azure Backup Vault
# Module source: https://github.com/hmcts/module-terraform-azurerm-backup-vault
# ---------------------------------------------------------------------------------------------------------------------

resource "azurerm_resource_group" "vaults" {
  name     = var.resource_group_name
  location = var.location
  tags     = merge(var.tags, local.common_tags)
}

module "backup_vaults" {
  for_each = var.backup_vaults

  source = "git::https://github.com/hmcts/module-terraform-azurerm-backup-vault.git?ref=main"

  name                = each.key
  resource_group_name = azurerm_resource_group.vaults.name
  location            = coalesce(each.value.location, var.location)

  redundancy                   = try(each.value.redundancy, "GeoRedundant")
  datastore_type               = try(each.value.datastore_type, "VaultStore")
  immutability                 = try(each.value.immutability, "Unlocked")
  cross_region_restore_enabled = try(each.value.cross_region_restore_enabled, true)
  soft_delete                  = try(each.value.soft_delete, "On")
  retention_duration_in_days   = try(each.value.retention_duration_in_days, 14)

  enable_system_assigned_identity = try(each.value.enable_system_assigned_identity, true)
  user_assigned_identity_ids      = try(each.value.user_assigned_identity_ids, [])

  enable_postgresql_crit4_5_policy = try(each.value.enable_postgresql_crit4_5_policy, true)
  enable_postgresql_test_policy    = try(each.value.enable_postgresql_test_policy, true)
  enable_adls_crit4_5_policy       = try(each.value.enable_adls_crit4_5_policy, false)
  enable_adls_test_policy          = try(each.value.enable_adls_test_policy, false)
  enable_blob_crit4_5_policy       = try(each.value.enable_blob_crit4_5_policy, false)
  enable_blob_test_policy          = try(each.value.enable_blob_test_policy, false)

  blob_crit4_5_backup_schedule = try(each.value.blob_crit4_5_backup_schedule, "R/2026-11-09T02:00:00+00:00/P1D")
  blob_test_backup_schedule    = try(each.value.blob_test_backup_schedule, "R/2026-11-09T03:00:00+00:00/P1D")

  crit4_5_backup_schedule            = try(each.value.crit4_5_backup_schedule, "R/2024-01-07T02:00:00+00:00/P1W")
  crit4_5_timezone                   = try(each.value.crit4_5_timezone, "UTC")
  crit4_5_default_retention_duration = try(each.value.crit4_5_default_retention_duration, "P56D")
  crit4_5_enable_extended_retention  = try(each.value.crit4_5_enable_extended_retention, true)
  crit4_5_weekly_retention_duration  = try(each.value.crit4_5_weekly_retention_duration, "P56D")
  crit4_5_monthly_retention_duration = try(each.value.crit4_5_monthly_retention_duration, "P2M")
  crit4_5_yearly_retention_duration  = try(each.value.crit4_5_yearly_retention_duration, "P1Y")

  adls_crit4_5_backup_schedule = try(each.value.adls_crit4_5_backup_schedule, "R/2026-11-09T02:00:00+00:00/P1D")
  adls_test_backup_schedule    = try(each.value.adls_test_backup_schedule, "R/2026-11-09T02:00:00+00:00/P1D")

  role_assignments = try(each.value.role_assignments, {})

  namespace   = var.namespace
  costcode    = var.costcode
  owner       = var.owner
  application = var.application
  environment = var.environment
  type        = var.type

  tags = merge(
    var.tags,
    local.common_tags,
    {
      name = each.key
    }
  )
}

module "restore_storage_account" {
  for_each = var.storage_accounts

  source = "git::https://github.com/hmcts/cpp-module-terraform-azurerm-storage-account.git?ref=main"

  storage_account_name          = substr(replace(lower("sa${each.key}${var.environment}"), "/[^a-z0-9]/", ""), 0, 24)
  location                      = var.location
  resource_group_name           = azurerm_resource_group.vaults.name
  account_kind                  = try(each.value.account_kind, "StorageV2")
  replication_type              = try(each.value.replication_type, "LRS")
  public_network_access_enabled = try(each.value.public_network_access_enabled, true)
  network_rules = {
    default_action             = try(each.value.default_action, "Deny")
    ip_rules                   = try(each.value.ip_rules, [])
    virtual_network_subnet_ids = try(local.storage_account_resolved_subnet_ids[each.key], [])
    bypass                     = try(each.value.bypass, ["AzureServices"])
  }

  private_link_access = {
    backup_vault = {
      endpoint_resource_id = module.backup_vaults[try(each.value.backup_vault_key, "cpp-backup-vault")].backup_vault_id
      endpoint_tenant_id   = try(each.value.endpoint_tenant_id, null)
    }
  }

  environment = var.environment
  tags        = merge(var.tags, local.common_tags)
}

# Grant each backup vault's managed identity Storage Blob Data Contributor on its
# associated restore storage account. The role assignment is managed here rather
# than via the storage account module's role_assignments input because that
# module keys its for_each on object_id, which is only known after apply.
# Using a static key here ("<sa_key>-blob-contributor") avoids that limitation.
resource "azurerm_role_assignment" "backup_vault_storage_blob_contributor" {
  for_each = var.storage_accounts

  scope                = module.restore_storage_account[each.key].storage_account_id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = module.backup_vaults[try(each.value.backup_vault_key, "cpp-backup-vault")].backup_vault_principal_id
}

resource "azurerm_role_assignment" "ado_service_connection_sa" {
  for_each = var.ado_service_connection_object_id != null ? var.storage_accounts : {}

  scope                = module.restore_storage_account[each.key].storage_account_id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = var.ado_service_connection_object_id
}

resource "azurerm_role_assignment" "ado_service_connection_bv" {
  for_each = var.ado_service_connection_object_id != null ? var.backup_vaults : {}

  scope                = module.backup_vaults[each.key].backup_vault_id
  role_definition_name = "Backup Operator"
  principal_id         = var.ado_service_connection_object_id
}

# Grant the backup vault's managed identity access to each onboarded storage
# account. Applies to every entry in the onboarding file, whether or not
# backup-enabled is set, so RBAC is in place before enrolment.
resource "azurerm_role_assignment" "backup_vault_storage_account_backup_contributor" {
  for_each = local.storage_backup_targets

  scope                = data.azurerm_storage_account.storage_backup_targets[each.key].id
  role_definition_name = "Storage Account Backup Contributor"
  principal_id         = module.backup_vaults["cpp-backup-vault"].backup_vault_principal_id
}

# Lists all containers for ADLS entries that use containers: ["*"].
data "azurerm_storage_containers" "adls_backup_all" {
  for_each = { for k, sa in local.adls_backup_instances : k => sa if contains(try(sa.containers, []), "*") }

  storage_account_id = data.azurerm_storage_account.storage_backup_targets[each.key].id
}

# Enrol ADLS storage accounts in cpp-backup-vault. Only entries with type adls and
# backup-enabled: true in the onboarding file are enrolled.
#
# The vault is immutable and locked, so enrolment is effectively permanent: backup
# instances can't be deleted while they have recovery points. prevent_destroy stops
# a plan from destroying or replacing an instance, for example if an entry is
# removed or set back to backup-enabled: false. To retire one, stop protection
# (retain data) and remove it from state with terraform state rm.
resource "azurerm_data_protection_backup_instance_data_lake_storage" "adls" {
  for_each = local.adls_backup_instances

  name                               = "${each.key}-adls-backup-instance"
  location                           = var.location
  data_protection_backup_vault_id    = module.backup_vaults["cpp-backup-vault"].backup_vault_id
  storage_account_id                 = data.azurerm_storage_account.storage_backup_targets[each.key].id
  backup_policy_data_lake_storage_id = local.adls_backup_policy_ids[each.value.policy]
  storage_container_names = (
    contains(each.value.containers, "*")
    ? [for c in data.azurerm_storage_containers.adls_backup_all[each.key].containers : c.name]
    : each.value.containers
  )

  # The vault needs Storage Account Backup Contributor on the account before
  # protection can be configured. Role assignments can take up to 30 minutes to take
  # effect, so assign the role in an earlier apply (backup-enabled: false) first.
  depends_on = [azurerm_role_assignment.backup_vault_storage_account_backup_contributor]

  lifecycle {
    prevent_destroy = true

    precondition {
      condition     = contains(keys(local.adls_backup_policy_ids), try(each.value.policy, ""))
      error_message = "${each.key}: policy must be one of the vault's ADLS policies (${join(", ", keys(local.adls_backup_policy_ids))})."
    }

    precondition {
      condition     = length(try(each.value.containers, [])) > 0
      error_message = "${each.key}: containers must list at least one container, or \"*\" for all."
    }
  }
}


