# Used for testing and development purposes only --- IGNORE ---
# Now sandbox vault will exist

# Azure Backup Vault Configuration - Sandbox Environment
# Backup vaults configuration with optional parameters
backup_vaults = {
  "cnp-backup-vault-test" = {
    location                          = "uksouth"
    redundancy                        = "GeoRedundant" # Cross-region DR capability
    immutability                      = "Unlocked"     # Start Unlocked, can lock after validation
    cross_region_restore_enabled      = true           # Regional outage DR
    enable_postgresql_crit4_5_policy  = true           # Critical database backup policy
    enable_postgresql_test_policy     = true           # Testing policy
    crit4_5_enable_extended_retention = false          # MOJ compliance retention
    soft_delete                       = "Off"          # Soft delete disabled for sandbox
  }
}
