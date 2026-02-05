# ---------------------------------------------------------------------------------------------------------------------
# LOCAL VALUES
# Computed values used throughout the module
# ---------------------------------------------------------------------------------------------------------------------

locals {
  # Determine the identity type based on inputs
  identity_type = var.enable_system_assigned_identity && length(var.user_assigned_identity_ids) > 0 ? "SystemAssigned, UserAssigned" : (
    var.enable_system_assigned_identity ? "SystemAssigned" : (
      length(var.user_assigned_identity_ids) > 0 ? "UserAssigned" : null
    )
  )

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