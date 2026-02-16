# CPP Backup Vault Component

This component provisions Azure Data Protection Backup Vaults for CPP (Common Platform Programme) workloads with optimized retention policies for cost-effectiveness and forensic audit capabilities.

## Features

- **Immutable backups** with configurable immutability settings
- **Cross-region restore** capability for disaster recovery
- **Optimized retention policies** balancing cost with forensic audit requirements:
  - **Default retention**: 8 weeks (P56D)
  - **Weekly retention**: 8 weeks (P56D)
  - **Monthly retention**: 2 months (P2M)
  - **Yearly retention**: 1 year (P1Y)
- **Flexible policy configuration** with crit4_5 and test policies
- **HMCTS standard tagging** with CPP-specific defaults

## Retention Strategy

The retention configuration has been optimized based on team discussions:

### Crit4_5 Policy (Production Services)
- **RPO**: 7 days (weekly backups)
- **Default retention**: 8 weeks (P56D)
- **Weekly retention**: 8 weeks (P56D)
- **Monthly retention**: 2 months (P2M)
- **Yearly retention**: 1 year (P1Y)

### Test Policy
- **RPO**: 7 days (weekly backups)
- **Retention**: 1 week (minimal cost for testing)

## Usage

Deploy to production:
```bash
terraform apply -var-file="../../environments/prod/cpp.tfvars"
```

## Outputs

- `backup_vaults`: Map of configured vaults and policy IDs
- `backup_vault_id` (legacy): Use when creating backup instances
- `backup_vault_principal_id` (legacy): Use for RBAC assignments
- `postgresql_policy_ids` (legacy): Map of policy names to IDs

## MOJ Compliance

This configuration meets MOJ System Backup Standard requirements:
- 8 weeks retention for high-impact services
- Regular backup schedule (weekly)
- Immutable storage with soft delete protection
- Proper tagging and documentation

Reference: https://security-guidance.service.justice.gov.uk/system-backup-standard/
