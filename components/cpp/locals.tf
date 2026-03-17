# ---------------------------------------------------------------------------------------------------------------------
# LOCAL VALUES
# Computed values used throughout the module
# ---------------------------------------------------------------------------------------------------------------------

locals {

  # Flatten all per-storage-account subnet references into a single map so they
  # can be resolved via a single for_each data lookup. Keys are unique across
  # all storage accounts: "<sa_key>--<subnet_name>--<vnet_name>".
  storage_account_subnet_refs = {
    for pair in flatten([
      for sa_key, sa in var.storage_accounts : [
        for subnet in try(sa.virtual_network_subnets, []) : {
          key                  = "${sa_key}_${subnet.name}_${subnet.virtual_network_name}"
          storage_account_key  = sa_key
          name                 = subnet.name
          virtual_network_name = subnet.virtual_network_name
          resource_group_name  = subnet.resource_group_name
        }
      ]
    ]) : pair.key => pair
  }

  # Reconstruct per-storage-account lists of resolved subnet IDs after the
  # data lookup. Merged with any IDs added directly to restore_storage_subnet_ids.
  storage_account_resolved_subnet_ids = {
    for sa_key in keys(var.storage_accounts) : sa_key => [
      for k, ref in local.storage_account_subnet_refs :
        data.azurerm_subnet.storage_account_subnets[k].id
      if ref.storage_account_key == sa_key
    ]
  }

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
