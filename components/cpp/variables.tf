# ---------------------------------------------------------------------------------------------------------------------
# REQUIRED VARIABLES
# These variables must be set when using this component.
# ---------------------------------------------------------------------------------------------------------------------

variable "name" {
  type        = string
  description = "The name of the Backup Vault. Changing this forces a new resource to be created."
}

variable "resource_group_name" {
  type        = string
  description = "The name of the Resource Group where the Backup Vault should exist."
}

variable "location" {
  type        = string
  description = "The Azure Region where the Backup Vault should exist."
  default     = "uksouth"
}

variable "redundancy" {
  type        = string
  description = "Specifies the backup storage redundancy. Possible values are GeoRedundant, LocallyRedundant and ZoneRedundant."
  default     = "GeoRedundant"

  validation {
    condition     = contains(["GeoRedundant", "LocallyRedundant", "ZoneRedundant"], var.redundancy)
    error_message = "redundancy must be one of: GeoRedundant, LocallyRedundant, ZoneRedundant."
  }
}

variable "cross_region_restore_enabled" {
  type        = bool
  description = "Whether to enable cross-region restore for the Backup Vault. Only applicable when redundancy is GeoRedundant."
  default     = true
}

# ---------------------------------------------------------------------------------------------------------------------
# OPTIONAL VARIABLES - Module Configuration
# These variables control module behavior and have sensible defaults
# ---------------------------------------------------------------------------------------------------------------------

variable "retention_duration_in_days" {
  type        = number
  description = "The soft delete retention duration for this Backup Vault. Possible values are between 14 and 180. Defaults to 14. Required when soft_delete is On."
  default     = 14

  validation {
    condition     = var.retention_duration_in_days >= 14 && var.retention_duration_in_days <= 180
    error_message = "retention_duration_in_days must be between 14 and 180."
  }
}

variable "enable_system_assigned_identity" {
  type        = bool
  description = "Whether to enable a SystemAssigned Managed Identity for this Backup Vault. Required for backing up PostgreSQL Flexible Servers."
  default     = true
}

variable "user_assigned_identity_ids" {
  type        = list(string)
  description = "A list of User Assigned Managed Identity IDs to be assigned to this Backup Vault."
  default     = []
}

variable "enable_postgresql_crit4_5_policy" {
  type        = bool
  description = "Whether to create the crit4_5 backup policy for PostgreSQL Flexible Server. This policy is for Criticality 4 and 5 services with 8-week retention and extended long-term retention."
  default     = true
}

variable "enable_postgresql_test_policy" {
  type        = bool
  description = "Whether to create a test backup policy for PostgreSQL Flexible Server. This policy has minimal retention for testing purposes only."
  default     = true
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