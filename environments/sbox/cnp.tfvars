# Used for testing and development purposes only --- IGNORE ---
# Now sandbox vault will exist

<<<<<<< HEAD
sharedservicesptl_subscription_id     = "6c4d2513-a873-41b4-afdd-b05a33206631"
sharedservicesptlsbox_subscription_id = "64b1c6d6-1481-44ad-b620-d8fe26a2c768"
cftptl_subscription_id                = "1baf5470-1c3e-40d3-a6f7-74bfbce4b348"
cftptlsbox_subscription_id            = "1497c3d7-ab6d-4bb7-8a10-b51d03189ee3"
=======
sharedservicesptl_subscription_id = "64b1c6d6-1481-44ad-b620-d8fe26a2c768"
cftptl_subscription_id            = "1497c3d7-ab6d-4bb7-8a10-b51d03189ee3"
>>>>>>> master

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

storage_accounts = {
  "cnpvaultrestorations" = {
    account_kind                  = "StorageV2"
    account_replication_type      = "LRS"
    backup_vault_key              = "cnp-backup-vault-test"
    public_network_access_enabled = true
  }
}
