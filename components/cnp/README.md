# Azure Backup Vault Component

This component creates Azure Backup Vaults using the [cpp-module-terraform-azurerm-backup-vault](https://github.com/hmcts/cpp-module-terraform-azurerm-backup-vault) module.

## Requirements

| Name | Version |
|------|---------|
| terraform | >= 1.7.5 |
| azurerm | ~> 4.54 |

## Providers

| Name | Version |
|------|---------|
| azurerm | ~> 4.54 |

## Modules

| Name | Source | Version |
|------|--------|---------|
| backup_vaults | git::https://github.com/hmcts/cpp-module-terraform-azurerm-backup-vault.git | main |
| tags | git::https://github.com/hmcts/terraform-module-common-tags.git | master |

## Inputs

| Name | Description | Type | Required |
|------|-------------|------|:--------:|
| backup_vaults | Map of backup vault configurations | `map(object({ location = string }))` | no |
| env | Environment name | `string` | no |
| product | Product name | `string` | no |
| resource_group_name | Resource group name for backup vault | `string` | no |

## Outputs

| Name | Description |
|------|-------------|
| backup_vaults | Map of created backup vaults with id and name |

## Usage

Define your backup vaults in the environment tfvars file:

```hcl
backup_vaults = {
  "cnp-backup-vault" = {
    location = "uksouth"
  }
}
```
