# Data source for  SDS jenkins-ptl-mi managed identity (prod only)
data "azurerm_user_assigned_identity" "jenkins_ptl_mi" {
  count               = var.env == "prod" ? 1 : 0
  provider            = azurerm.sharedservicesptl
  name                = "jenkins-ptl-mi"
  resource_group_name = "managed-identities-ptl-rg"
}


data "azurerm_subnet" "cft_ptl_aks_00" {
  provider             = azurerm.cftptl
  name                 = "aks-00"
  virtual_network_name = "cft-ptl-vnet"
  resource_group_name  = "cft-ptl-network-rg"
}

data "azurerm_subnet" "cft_ptl_aks_01" {
  provider             = azurerm.cftptl
  name                 = "aks-01"
  virtual_network_name = "cft-ptl-vnet"
  resource_group_name  = "cft-ptl-network-rg"
}

data "azurerm_subnet" "ss_ptl_aks_00" {
  provider             = azurerm.sharedservicesptl
  name                 = "aks-00"
  virtual_network_name = "ss-ptl-vnet"
  resource_group_name  = "ss-ptl-network-rg"
}

data "azurerm_subnet" "ss_ptl_aks_01" {
  provider             = azurerm.sharedservicesptl
  name                 = "aks-01"
  virtual_network_name = "ss-ptl-vnet"
  resource_group_name  = "ss-ptl-network-rg"
}
