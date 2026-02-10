# Azure Backup Vault

A Terraform-based infrastructure-as-code solution for deploying and managing Azure Backup Vaults across HMCTS environments.

## Overview

This repository contains Terraform configurations for provisioning Azure Recovery Services Vaults that enable centralized backup and disaster recovery capabilities for critical HMCTS platform services. The solution implements best practices for backup redundancy, immutability, and retention policies to ensure compliance with Ministry of Justice (MOJ) requirements.

## Project Structure

```
azure-backup-vault/
├── components/
│   ├── cnp/                    # CNP platform backup vault component
│   └── cpp/                    # CPP platform backup vault component
│       ├── main.tf             # Resource definitions
│       ├── variable.tf         # Variable declarations
│       ├── output.tf           # Terraform outputs
│       ├── local.tf            # Local value definitions
│       ├── provider.tf         # Provider configuration
│       └── README.md           # Component documentation
├── environments/
│   ├── prod/                   # Production environment (cnp.tfvars, cpp.tfvars)
│   └── sbox/                   # CNP sandbox environment (cnp.tfvars)
├── azure-pipelines.yaml        # CNP pipeline (hmcts/PlatformOperations)
├── azure-pipelines-cpp.yaml    # CPP pipeline (hmcts-cpp org)
├── .terraform-version          # Terraform version constraint
├── CODEOWNERS                  # Code ownership rules
└── README.md                   # This file
```

## Components

### CNP (Cloud Native Platform)

The CNP component creates Azure Recovery Services Vaults configured for the CNP platform. It includes:

- **Backup Vault Creation**: Provisions Azure Recovery Services Vaults with configurable redundancy and immutability settings
- **Backup Policies**: Enables optional PostgreSQL-specific backup policies (CRIT4/5 and test environments)
- **Disaster Recovery**: Supports cross-region restore for regional outage scenarios
- **Compliance**: Integrates extended retention policies for MOJ compliance requirements
- **Resource Tagging**: Applies common HMCTS tags for cost allocation and asset tracking

**Module Reference**: [module-terraform-azurerm-backup-vault](https://github.com/hmcts/module-terraform-azurerm-backup-vault)

## Environments

### CPP Production (`environments/prod/`)

The CPP production environment contains the CPP backup vault configuration:

- **Immutability**: Unlocked for initial deployment, can be locked after validation
- **Cross-Region Restore**: Enabled for business continuity
- **Backup Policies**: CRIT4/5 enabled; test policy disabled
- **Extended Retention**: P56D/P1M/P1Y
- **Redundancy**: GeoRedundant for cross-region disaster recovery

**Configuration File**: `environments/prod/cpp.tfvars`

### CNP Production (`environments/prod/`)

The CNP production environment contains fully hardened backup vault configurations:

- **Immutability**: Unlocked for initial deployment, can be locked after validation
- **Cross-Region Restore**: Enabled for business continuity  
- **Backup Policies**: All PostgreSQL policies enabled (CRIT4/5 and test)
- **Extended Retention**: Enabled for MOJ compliance (P56D/P1M/P1Y)
- **Redundancy**: GeoRedundant for cross-region disaster recovery

**Configuration File**: `environments/prod/cnp.tfvars`

### CNP Sandbox (`environments/sbox/`)

The CNP sandbox environment is used for testing and validation in non-production:

- **Purpose**: Testing vault creation, policy configuration, and restore procedures
- **Simplified Configuration**: Reduced policy requirements for rapid testing
- **Soft Delete**: Disabled to allow immediate cleanup during testing

**Configuration File**: `environments/sbox/cnp.tfvars`

## Deployment

Deployments are carried out via Azure DevOps pipelines from this repo.

- **CNP Pipeline**: https://dev.azure.com/hmcts/PlatformOperations/_build?definitionId=1181&_a=summary ([source](./azure-pipelines.yaml))
- **CPP Pipeline**: To be registered in `https://dev.azure.com/hmcts-cpp/` ([source](./azure-pipelines-cpp.yaml))

### Adding a New Backup Vault

To add a new backup vault configuration:

1. Update the appropriate environment's `cnp.tfvars` file
2. Add a new entry to the `backup_vaults` map with desired configuration
3. Example:
   ```hcl
   backup_vaults = {
     "cnp-backup-vault" = {
       location                          = "uksouth"
       redundancy                        = "GeoRedundant"
       immutability                      = "Unlocked"
       cross_region_restore_enabled      = true
       enable_postgresql_crit4_5_policy  = true
       enable_postgresql_test_policy     = true
       crit4_5_enable_extended_retention = true
     }
   }
   ```

## Configuration Variables

### Required Variables

| Variable | Description | Example |
|----------|-------------|---------|
| `env` | Environment name (prod) | `prod` |
| `product` | Product identifier | `cnp-vault` |
| `builtFrom` | Repository and branch reference | `hmcts/azure-backup-vault` |

### Optional Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `location` | `uksouth` | Azure region for resources |
| `expiresAfter` | `3000-01-01` | Resource expiration date for cost management |

### Backup Vault Configuration Options

All options are nested within the `backup_vaults` map:

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `location` | string | `uksouth` | Azure region for the vault |
| `redundancy` | string | `GeoRedundant` | Backup redundancy: `LocallyRedundant` or `GeoRedundant` |
| `immutability` | string | `Unlocked` | Vault immutability: `Locked` or `Unlocked` |
| `cross_region_restore_enabled` | bool | `true` | Enable cross-region restore capability |
| `enable_postgresql_crit4_5_policy` | bool | `true` | Enable CRIT4/5 PostgreSQL backup policy |
| `enable_postgresql_test_policy` | bool | `true` | Enable test environment PostgreSQL backup policy |
| `crit4_5_enable_extended_retention` | bool | `true` | Enable MOJ compliance extended retention |
| `soft_delete` | string | `On` | Enable soft delete for vault items |

## Outputs

The module provides the following outputs:

- **Vault ID**: Azure Resource Manager ID of the created vault
- **Vault Name**: Name of the created backup vault
- **Resource Group**: Name of the resource group containing the vault

See [components/cnp/output.tf](components/cnp/output.tf) for complete output definitions.

## CI/CD Pipelines

This repo uses **two separate pipelines** because the CNP and CPP platforms run in different Azure DevOps organisations:

### CNP Pipeline (`azure-pipelines.yaml`)

- **ADO Org**: `https://dev.azure.com/hmcts/PlatformOperations`
- **Template**: `cnp-azuredevops-libraries`
- **Environments**: CNP production and sandbox
- **Plan/Apply Options**: Override action parameter for different deployment strategies

### CPP Pipeline (`azure-pipelines-cpp.yaml`)

- **ADO Org**: `https://dev.azure.com/hmcts-cpp/`
- **Template**: Uses custom inline terraform steps (CPP templates not compatible with component structure)
- **Environments**: CPP production
- **Resources**: Uses CPP-specific agent pools (`MPD-ADO-AGENTS-01`), service connections (`ado_live_workload_identity`), variable groups (`cpp-live-vault-admin`), and secure files (`cpp-nonlive-ca.pem`, `cp-cjs-hmcts-net-ca.pem`) that only exist in the hmcts-cpp org
- **Action Parameter**: Set `action=apply` to apply changes, defaults to `plan`

> **Note**: The CPP pipeline must be registered as a build definition in the `hmcts-cpp` ADO org. It cannot run in PlatformOperations.

## Resource Naming Convention

All resources follow the HMCTS naming convention:

```text
{product}-{resource-type}-{environment}
```

Example: `cnp-vault-prod` (Backup Vault for CNP in Production)

## Tagging Strategy

All resources are automatically tagged with the following tags via the common tags module:

- `Environment`: Environment name (prod)
- `Product`: Product identifier (cnp-vault)
- `Managed-By`: Terraform
- `Source`: Repository and commit reference

## Disaster Recovery & Backup Policies

### Production Backup Policies

- **CRIT4/5 PostgreSQL Policy**: Extended retention for critical production databases
- **Test Environment Policy**: Backup policy for non-production PostgreSQL instances
- **Cross-Region Restore**: Enabled for regional outage scenarios
- **Redundancy**: GeoRedundant for multi-region resilience

### Testing Considerations

CNP sandbox policies are simplified to support rapid testing and development without incurring unnecessary backup costs.

## Troubleshooting

### Common Issues

**State Lock Errors**
- Ensure `-lock=false` is used during testing to prevent state lock contention
- For production, state locking is enabled by default

**Module Access Issues**
- Verify GitHub SSH access or configure credentials for private module repositories
- Check that Terraform has been authenticated with Azure

**Vault Creation Failures**
- Ensure the resource group location matches vault location
- Verify Azure subscription limits have not been reached
- Check that backup policies are supported in the target region

## Related Documentation

- [Azure Recovery Services Vault Documentation](https://docs.microsoft.com/en-us/azure/backup/backup-vault-overview)
- [HMCTS Terraform Module - Backup Vault](https://github.com/hmcts/module-terraform-azurerm-backup-vault)
- [Common Tags Module](https://github.com/hmcts/terraform-module-common-tags)

## Support

For issues or questions regarding this repository:

1. Check the [CODEOWNERS](CODEOWNERS) file for code review requirements
2. Review the [components/cnp/README.md](components/cnp/README.md) for component-specific details
3. Consult HMCTS platform team documentation for broader context

## License

See [LICENSE](LICENSE) file for licensing information.
