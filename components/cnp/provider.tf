terraform {
  required_version = ">= 1.14.4"

  backend "azurerm" {} # cconfiguration provided at pipeline level

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.54"
    }
  }
}

provider "azurerm" {
  features {}
  resource_provider_registrations = "none"
}

# Provider for DTS-SHAREDSERVICESPTL subscription
provider "azurerm" {
  features {}
  alias                           = "sharedservicesptl"
  subscription_id                 = var.sharedservicesptl_subscription_id
  resource_provider_registrations = "none"
}

# Provider for DTS-SHAREDSERVICESPTL-SBOX subscription
provider "azurerm" {
  features {}
  alias                           = "sharedservicesptlsbox"
  subscription_id                 = var.sharedservicesptlsbox_subscription_id
  resource_provider_registrations = "none"
}

# Provider for DTS-CFTPTL subscription
provider "azurerm" {
  features {}
  alias                           = "cftptl"
  subscription_id                 = var.cftptl_subscription_id
  resource_provider_registrations = "none"
}

# Provider for DTS-CFTSBOX-INTSVC subscription
provider "azurerm" {
  features {}
  alias                           = "cftptlsbox"
  subscription_id                 = var.cftptlsbox_subscription_id
  resource_provider_registrations = "none"
}
