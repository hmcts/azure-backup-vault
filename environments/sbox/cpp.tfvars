# CPP Sandbox Backup Vault Configuration
# Used for testing and development purposes only

resource_group_name = "cpp-infra-sbox-rg"
location            = "uksouth"

backup_vaults = {
  "cpp-backup-vault" = {
    location                     = "uksouth"
    redundancy                   = "GeoRedundant"
    immutability                 = "Unlocked"
    cross_region_restore_enabled = true
    soft_delete                  = "Off"
    retention_duration_in_days   = 14

    enable_postgresql_crit4_5_policy   = true
    enable_postgresql_test_policy      = false
    crit4_5_enable_extended_retention  = true
    crit4_5_weekly_retention_duration  = "P56D"
    crit4_5_monthly_retention_duration = "P2M"
    crit4_5_yearly_retention_duration  = "P1Y"
    # Reader role assignment for resource group containing Postgresql instances that need to be protected.
    role_assignments = {
    "reader-RG-NFT-CCM-01" = {
      scope                = "/subscriptions/e6b5053b-4c38-4475-a835-a025aeb3d8c7/resourceGroups/RG-NFT-CCM-01"
      role_definition_name = "Reader"
    }
    "reader-RG-SIT-CCM-01" = {
      scope                = "/subscriptions/e6b5053b-4c38-4475-a835-a025aeb3d8c7/resourceGroups/RG-SIT-CCM-01"
      role_definition_name = "Reader"
    }
    "reader-RG-DEV-CCM-01" = {
      scope                = "/subscriptions/e6b5053b-4c38-4475-a835-a025aeb3d8c7/resourceGroups/RG-DEV-CCM-01"
      role_definition_name = "Reader"
    }
  }
  }

}

ado_agent_vnet = "VN-MDV-SBZ-01"
ado_agent_rg   = "RG-MDV-SBZ-01"

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
        name                 = "SN-MDV-SBZ-ADO-CISLAVE-01"
        virtual_network_name = "VN-MDV-SBZ-01"
        resource_group_name  = "RG-MDV-SBZ-01"
      }
    ]

  }
}

namespace   = "cpp"
application = "backup"
environment = "mdv"
owner       = "platops"
costcode    = "10038"
type        = "backup"

tags = {
  "businessArea" = "Cross-Cutting"
  "builtFrom"    = "azure-backup-vault"
  "criticality"  = "Low"
  "expiresAfter" = "3000-01-01"
}
