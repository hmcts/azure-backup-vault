# Azure Backup Vault Configuration - CNP Production Environment

# Backup vaults configuration with optional parameters
backup_vaults = {
  "cnp-backup-vault-pg" = {
    location                           = "uksouth"
    redundancy                         = "GeoRedundant" # Cross-region DR capability
    immutability                       = "Unlocked"     # Start Unlocked, can lock after validation
    cross_region_restore_enabled       = true           # Regional outage DR
    enable_postgresql_crit4_5_policy   = true           # Critical database backup policy
    enable_postgresql_test_policy      = true           # Testing policy
    crit4_5_enable_extended_retention  = true           # MOJ compliance retention
    crit4_5_weekly_retention_duration  = "P56D"         # 8 weeks
    crit4_5_monthly_retention_duration = "P1M"          # 1 month
    crit4_5_yearly_retention_duration  = "P1Y"          # 1 year
  }
}
