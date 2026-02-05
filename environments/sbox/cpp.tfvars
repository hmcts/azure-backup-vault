# CPP Sandbox Backup Vault Configuration
# This configuration deploys the backup vault for CPP sandbox/testing workloads

# Required variables for CPP sandbox
name                = "cpp-backup-vault-sbox"
resource_group_name = "cpp-infra-sbox-rg"
location            = "uksouth"

# Vault configuration for testing (less redundant, lower cost)
redundancy                   = "LocallyRedundant"  # Lower cost for testing
datastore_type              = "VaultStore"
cross_region_restore_enabled = false              # Not needed for sandbox
immutability                = "Unlocked"
soft_delete                 = "On"
retention_duration_in_days  = 14

# Enable both policies for testing
enable_postgresql_crit4_5_policy = true
enable_postgresql_test_policy    = true

# HMCTS common tags for CPP
namespace   = "cpp"
costcode    = "10038"
owner       = "cpp-platform-ops"
application = "backup-vault"
environment = "sbox"
type        = "backup"

# Additional sandbox tags
tags = {
  "Business Area"       = "Cross Cutting"
  "Application"         = "CPP Backup Vault"
  "Environment"         = "Sandbox"
  "Critical"            = "No"
  "Data Classification" = "Internal"
}