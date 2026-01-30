
# Create resource group for backup vaults
resource "azurerm_resource_group" "vaults" {
  name     = "${var.product}-infra-${var.env}-rg"
  location = var.location
}

# Common tags module
module "tags" {
  source       = "git::https://github.com/hmcts/terraform-module-common-tags.git?ref=master"
  environment  = lower(var.env)
  product      = var.product
  builtFrom    = var.builtFrom
  expiresAfter = var.expiresAfter
}

# Module call to create backup vaults
module "backup_vaults" {
  for_each = local.backup_vaults

  source = "git::https://github.com/hmcts/module-terraform-azurerm-backup-vault.git?ref=main"

  name                = each.key
  location            = coalesce(each.value.location, var.location)
  resource_group_name = azurerm_resource_group.vaults.name

  # Optional parameters with defaults
  redundancy                         = try(each.value.redundancy, "GeoRedundant")
  immutability                       = try(each.value.immutability, "Unlocked")
  cross_region_restore_enabled       = try(each.value.cross_region_restore_enabled, true)
  enable_postgresql_crit4_5_policy   = try(each.value.enable_postgresql_crit4_5_policy, true)
  enable_postgresql_test_policy      = try(each.value.enable_postgresql_test_policy, true)
  crit4_5_enable_extended_retention  = try(each.value.crit4_5_enable_extended_retention, true)
  soft_delete                        = try(each.value.soft_delete, "On")
  crit4_5_weekly_retention_duration  = try(each.value.crit4_5_weekly_retention_duration, "P8W")
  crit4_5_monthly_retention_duration = try(each.value.crit4_5_monthly_retention_duration, "P2M")
  crit4_5_yearly_retention_duration  = try(each.value.crit4_5_yearly_retention_duration, "P1Y")

  tags = merge(
    module.tags.common_tags,
    {
      name = each.key
    }
  )
}
