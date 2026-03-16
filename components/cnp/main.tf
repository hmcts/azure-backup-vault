
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
  crit4_5_weekly_retention_duration  = try(each.value.crit4_5_weekly_retention_duration, "P56D")
  crit4_5_monthly_retention_duration = try(each.value.crit4_5_monthly_retention_duration, "P2M")
  crit4_5_yearly_retention_duration  = try(each.value.crit4_5_yearly_retention_duration, "P1Y")

  tags = merge(
    module.tags.common_tags,
    {
      name = each.key
    }
  )
}

# Role assignment for jenkins-ptl-mi on cnp-backup-vault (prod only)
resource "azurerm_role_assignment" "jenkins_ptl_mi_contributor_cnp_vault" {
  count                = var.env == "prod" ? 1 : 0
  scope                = module.backup_vaults["cnp-backup-vault"].backup_vault_id
  role_definition_name = "Contributor"
  principal_id         = data.azurerm_user_assigned_identity.jenkins_ptl_mi[0].principal_id
}

# Module call to create storage accounts for backup restoration
module "restore_storage_account" {
  for_each = local.storage_accounts

  source = "git::https://github.com/hmcts/cnp-module-storage-account.git?ref=feature/private-link-access"

  storage_account_name = substr(replace(lower("${each.key}${var.env}"), "/[^a-z0-9]/", ""), 0, 24)
  location             = var.location
  resource_group_name  = azurerm_resource_group.vaults.name

  env                           = lower(var.env)
  account_kind                  = each.value.account_kind
  account_replication_type      = each.value.account_replication_type
  common_tags                   = module.tags.common_tags
  public_network_access_enabled = each.value.public_network_access_enabled

  private_link_access = {
    backup_vault = {
      endpoint_resource_id = module.backup_vaults[try(each.value.backup_vault_key, "cnp-backup-vault")].backup_vault_id
      endpoint_tenant_id   = try(each.value.endpoint_tenant_id, null)
    }
  }

  sa_subnets = [
    data.azurerm_subnet.cft_ptl_aks_00.id,
    data.azurerm_subnet.cft_ptl_aks_01.id,
    data.azurerm_subnet.cft_ptlsbox_aks_00.id,
    data.azurerm_subnet.cft_ptlsbox_aks_01.id,
    data.azurerm_subnet.ss_ptl_aks_00.id,
    data.azurerm_subnet.ss_ptl_aks_01.id,
    data.azurerm_subnet.ss_ptlsbox_aks_00.id,
    data.azurerm_subnet.ss_ptlsbox_aks_01.id
  ]

  managed_identity_object_id = module.backup_vaults[try(each.value.backup_vault_key, "cnp-backup-vault")].backup_vault_principal_id
  role_assignments           = ["Storage Blob Data Contributor"]
}

