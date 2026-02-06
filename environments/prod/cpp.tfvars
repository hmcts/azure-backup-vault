# CPP Production Backup Vault Configuration
# This configuration deploys the backup vault for CPP production workloads

# Required variables for CPP production
name                = "cpp-backup-vault"
resource_group_name = "cpp-infra-prd-rg"
location            = "uksouth"

# Vault configuration optimized for production
redundancy                   = "GeoRedundant"
datastore_type              = "VaultStore"
cross_region_restore_enabled = true
immutability                = "Unlocked"
soft_delete                 = "On"
retention_duration_in_days  = 14

# Enable both policies
enable_postgresql_crit4_5_policy = true
enable_postgresql_test_policy    = false  # Disabled for production

# HMCTS common tags for CPP
namespace   = "cpp"
costcode    = "10038"
owner       = "cpp-platform-ops"
application = "backup-vault"
environment = "prd"
type        = "backup"

# Additional production tags
tags = {
  "Business Area"       = "Cross Cutting"
  "Application"         = "CPP Backup Vault"
  "Environment"         = "Production"
  "Critical"            = "Yes"
  "Data Classification" = "Internal"
}