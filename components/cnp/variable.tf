# General
variable "env" {}

variable "product" {}

variable "builtFrom" {}

variable "location" {
  default = "uksouth"
}

variable "expiresAfter" {
  default = "3000-01-01"
}

variable "backup_vaults" {
  description = "Map of backup vault configurations. See https://github.com/hmcts/module-terraform-azurerm-backup-vault for complete module documentation."
  default     = {}
  type = map(object({
    # Vault Configuration
    location                     = optional(string, "uksouth")
    redundancy                   = optional(string, "GeoRedundant")
    datastore_type               = optional(string, "VaultStore")
    immutability                 = optional(string, "Unlocked")
    cross_region_restore_enabled = optional(bool, true)
    soft_delete                  = optional(string, "On")
    retention_duration_in_days   = optional(number, 14) # Default retention for soft-deleted items

    # Identity Configuration
    enable_system_assigned_identity = optional(bool, true)
    user_assigned_identity_ids      = optional(list(string), [])

    # Backup Policy Flags
    enable_postgresql_crit4_5_policy = optional(bool, true)
    enable_postgresql_test_policy    = optional(bool, true)

    # Postgres Crit4/5 Policy Configuration
    crit4_5_backup_schedule            = optional(string, "R/2024-01-07T02:00:00+00:00/P1W")
    crit4_5_timezone                   = optional(string, "UTC")
    crit4_5_default_retention_duration = optional(string, "P56D")
    crit4_5_enable_extended_retention  = optional(bool, true)
    crit4_5_weekly_retention_duration  = optional(string, "P56D")
    crit4_5_monthly_retention_duration = optional(string, "P2M")
    crit4_5_yearly_retention_duration  = optional(string, "P1Y")
  }))
}
