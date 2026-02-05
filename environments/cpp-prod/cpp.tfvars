# CPP Production Backup Vault Configuration
# This configuration deploys the backup vault for CPP production workloads
# Uses the official HMCTS module: https://github.com/hmcts/module-terraform-azurerm-backup-vault

# Required variables for CPP production
name                = "cpp-backup-vault"
resource_group_name = "cpp-infra-prd-rg" 
location            = "uksouth"

# Production configuration - module defaults to optimal settings
redundancy                   = "GeoRedundant"
cross_region_restore_enabled = true
retention_duration_in_days = 30  # Extended for production compliance

# Enable policies for CPP systems
enable_postgresql_crit4_5_policy = true
enable_postgresql_test_policy    = false  # Disabled for production

# HMCTS common tags for CPP
namespace    = "cpp"
application  = "backup"
environment  = "production"
owner        = "platops"

# Additional production tags
tags = {
  "businessArea"        = "Cross-Cutting"
  "builtFrom"           = "azure-backup-vault"
  "criticality"         = "High"
  "expiresAfter"        = "3000-01-01"
}