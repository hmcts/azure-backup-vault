# ---------------------------------------------------------------------------------------------------------------------
# LOCAL VALUES
# Computed values used throughout the module
# ---------------------------------------------------------------------------------------------------------------------

locals {
  backup_vaults = var.backup_vaults

  # Common tags for HMCTS resources
  common_tags = {
    for k, v in {
      namespace   = var.namespace
      costcode    = var.costcode
      owner       = var.owner
      application = var.application
      environment = var.environment
      type        = var.type
    } : k => v if v != ""
  }
}
