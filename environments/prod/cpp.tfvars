# CPP Production Backup Vault Configuration
# This configuration deploys the backup vault for CPP production workloads
# Uses the official HMCTS module: https://github.com/hmcts/module-terraform-azurerm-backup-vault

resource_group_name = "cpp-infra-prd-rg"
location            = "uksouth"

backup_vaults = {
  "cpp-backup-vault-pg" = {
    location                     = "uksouth"
    redundancy                   = "GeoRedundant"
    immutability                 = "Unlocked"
    cross_region_restore_enabled = true
    soft_delete                  = "On"
    retention_duration_in_days   = 30

    enable_postgresql_crit4_5_policy   = true
    enable_postgresql_test_policy      = false
    crit4_5_enable_extended_retention  = true
    crit4_5_weekly_retention_duration  = "P56D"
    crit4_5_monthly_retention_duration = "P2M"
    crit4_5_yearly_retention_duration  = "P1Y"

    role_assignments = {
      "reader-RG-PRD-CCM-01" = {
        scope                = "/subscriptions/9ab65d81-930d-4cc0-a93d-367e14676bc0/resourceGroups/RG-PRD-CCM-01"
        role_definition_name = "Reader"
      }
      "reader-RG-PRP-CCM-01" = {
        scope                = "/subscriptions/9ab65d81-930d-4cc0-a93d-367e14676bc0/resourceGroups/RG-PRP-CCM-01"
        role_definition_name = "Reader"
      }
      "reader-RG-PRX-CCM-01" = {
        scope                = "/subscriptions/9ab65d81-930d-4cc0-a93d-367e14676bc0/resourceGroups/RG-PRX-CCM-01"
        role_definition_name = "Reader"
      }
    }
  }
}

namespace   = "cpp"
application = "backup"
environment = "prd"
owner       = "platops"
costcode    = "10038"
type        = "backup"

tags = {
  "businessArea" = "Cross-Cutting"
  "builtFrom"    = "azure-backup-vault"
  "criticality"  = "High"
  "expiresAfter" = "3000-01-01"
}

