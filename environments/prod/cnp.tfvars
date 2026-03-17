# Azure Backup Vault Configuration - CNP Production Environment

sharedservicesptl_subscription_id     = "6c4d2513-a873-41b4-afdd-b05a33206631"
sharedservicesptlsbox_subscription_id = "64b1c6d6-1481-44ad-b620-d8fe26a2c768"
cftptl_subscription_id                = "1baf5470-1c3e-40d3-a6f7-74bfbce4b348"
cftptlsbox_subscription_id            = "1497c3d7-ab6d-4bb7-8a10-b51d03189ee3"

# Backup vaults configuration with optional parameters
backup_vaults = {
  "cnp-backup-vault" = {
    location                           = "uksouth"
    redundancy                         = "GeoRedundant" # Cross-region DR capability
    immutability                       = "Unlocked"     # Start Unlocked, can lock after validation
    cross_region_restore_enabled       = true           # Regional outage DR
    enable_postgresql_crit4_5_policy   = true           # Critical database backup policy
    enable_postgresql_test_policy      = true           # Testing policy
    crit4_5_enable_extended_retention  = true           # MOJ compliance retention
    crit4_5_weekly_retention_duration  = "P56D"         # 8 weeks
    crit4_5_monthly_retention_duration = "P2M"          # 2 months
    crit4_5_yearly_retention_duration  = "P1Y"          # 1 year
  }
}

storage_accounts = {
  "cnpvaultrestorations" = {
    account_kind                  = "StorageV2"
    account_replication_type      = "LRS"
    backup_vault_key              = "cnp-backup-vault"
    public_network_access_enabled = true
  }
}
