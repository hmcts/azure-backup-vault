# CPP Production Backup Vault Configuration
# This configuration deploys the backup vault for CPP production workloads
# Uses the official HMCTS module: https://github.com/hmcts/module-terraform-azurerm-backup-vault

resource_group_name = "cpp-infra-prd"
location            = "uksouth"

backup_vaults = {
  "cpp-backup-vault" = {
    location                     = "uksouth"
    redundancy                   = "GeoRedundant"
    immutability                 = "Locked"
    cross_region_restore_enabled = false
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

ado_service_connection_object_id = "9fd14845-2c97-4710-89f1-808ca78d373c"

storage_accounts = {
  "cppvaultrestore" = {
    account_kind                  = "StorageV2"
    replication_type              = "LRS"
    public_network_access_enabled = true
    default_action                = "Deny"
    bypass                        = ["AzureServices"]
    backup_vault_key              = "cpp-backup-vault"
    virtual_network_subnets = [
      {
        name                 = "SN-MPD-SBZ-ADO-CISLAVE-01"
        virtual_network_name = "VN-MPD-INT-01"
        resource_group_name  = "RG-MPD-INT-01"
      }
    ]
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
