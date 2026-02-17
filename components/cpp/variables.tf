# ---------------------------------------------------------------------------------------------------------------------
# REQUIRED VARIABLES
# These variables must be set when using this component.
# ---------------------------------------------------------------------------------------------------------------------

variable "resource_group_name" {
  type        = string
  description = "The name of the Resource Group where the Backup Vault should exist."
}

variable "location" {
  type        = string
  description = "The Azure Region where the Backup Vault should exist."
  default     = "uksouth"
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
    retention_duration_in_days   = optional(number, 14)

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

    # RBAC - Role assignments for the vault's managed identity
    role_assignments = optional(map(object({
      scope                = string
      role_definition_name = string
    })), {})
  }))
}

# ---------------------------------------------------------------------------------------------------------------------
# OPTIONAL VARIABLES - Tags
# ---------------------------------------------------------------------------------------------------------------------

variable "tags" {
  type        = map(string)
  description = "A mapping of tags to assign to the Backup Vault resource."
  default     = {}
}

# ---------------------------------------------------------------------------------------------------------------------
# OPTIONAL VARIABLES - Common HMCTS Tags
# ---------------------------------------------------------------------------------------------------------------------

variable "namespace" {
  type        = string
  description = "Namespace, which could be an organization name or abbreviation, e.g. 'hmcts' or 'cpp'"
  default     = "cpp"
}

variable "application" {
  type        = string
  description = "Application to which the resource relates"
  default     = "backup"
}

variable "environment" {
  type        = string
  description = "Environment into which resource is deployed (e.g., dev, stg, prd)"
  default     = ""
}

variable "owner" {
  type        = string
  description = "Name of the project or squad within the PDU which manages the resource."
  default     = "platops"
}

variable "costcode" {
  type        = string
  description = "Name of the DWP PRJ number (obtained from the project portfolio in TechNow)"
  default     = ""
}

variable "type" {
  type        = string
  description = "Name of service type"
  default     = "backup"
}
