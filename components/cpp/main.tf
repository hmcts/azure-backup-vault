# ---------------------------------------------------------------------------------------------------------------------
# CPP BACKUP VAULT IMPLEMENTATION
# Uses the official HMCTS Terraform module for Azure Backup Vault
# Module source: https://github.com/hmcts/module-terraform-azurerm-backup-vault
# ---------------------------------------------------------------------------------------------------------------------

module "backup_vault" {
  source = "git::https://github.com/hmcts/module-terraform-azurerm-backup-vault.git?ref=main"

  name                = var.name
  resource_group_name = var.resource_group_name
  location            = var.location
  redundancy          = var.redundancy
  cross_region_restore_enabled = var.cross_region_restore_enabled
  
  # Production configuration for CPP
  retention_duration_in_days = var.retention_duration_in_days
  
  # Enable system-assigned managed identity
  enable_system_assigned_identity = var.enable_system_assigned_identity
  
  # Enable PostgreSQL policies for CPP systems
  enable_postgresql_crit4_5_policy = var.enable_postgresql_crit4_5_policy
  enable_postgresql_test_policy    = var.enable_postgresql_test_policy
  
  # HMCTS standard tags using module's common tag structure
  namespace    = var.namespace
  application  = var.application
  environment  = var.environment
  owner        = var.owner
  
  # Additional custom tags
  tags = var.tags
}