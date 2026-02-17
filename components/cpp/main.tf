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
  for_each = local.backup_vaults

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

  crit4_5_backup_schedule            = try(each.value.crit4_5_backup_schedule, "R/2024-01-07T02:00:00+00:00/P1W")
  crit4_5_timezone                   = try(each.value.crit4_5_timezone, "UTC")
  crit4_5_default_retention_duration = try(each.value.crit4_5_default_retention_duration, "P56D")
  crit4_5_enable_extended_retention  = try(each.value.crit4_5_enable_extended_retention, true)
  crit4_5_weekly_retention_duration  = try(each.value.crit4_5_weekly_retention_duration, "P56D")
  crit4_5_monthly_retention_duration = try(each.value.crit4_5_monthly_retention_duration, "P2M")
  crit4_5_yearly_retention_duration  = try(each.value.crit4_5_yearly_retention_duration, "P1Y")

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
