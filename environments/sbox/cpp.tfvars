# CPP Sandbox Backup Vault Configuration
# Used for testing and development purposes only

resource_group_name = "cpp-infra-sbox-rg"
location            = "uksouth"

backup_vaults = {
  "cpp-backup-vault-pg" = {
    location                     = "uksouth"
    redundancy                   = "GeoRedundant"
    immutability                 = "Unlocked"
    cross_region_restore_enabled = true
    soft_delete                  = "Off"
    retention_duration_in_days   = 14

    enable_postgresql_crit4_5_policy  = true
    enable_postgresql_test_policy     = true
    crit4_5_enable_extended_retention = false
  }
}

namespace   = "cpp"
application = "backup"
environment = "sandbox"
owner       = "platops"
costcode    = "10038"
type        = "backup"

tags = {
  "businessArea" = "Cross-Cutting"
  "builtFrom"    = "azure-backup-vault"
  "criticality"  = "Low"
  "expiresAfter" = "3000-01-01"
}
