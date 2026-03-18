# Resolves all subnet references declared in the storage_accounts variable.
# The flat map is built in locals.tf from the per-account virtual_network_subnets lists.
data "azurerm_subnet" "storage_account_subnets" {
  for_each = local.storage_account_subnet_refs

  name                 = each.value.name
  virtual_network_name = each.value.virtual_network_name
  resource_group_name  = each.value.resource_group_name
}
