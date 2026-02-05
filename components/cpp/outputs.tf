# ---------------------------------------------------------------------------------------------------------------------
# BACKUP VAULT OUTPUTS
# Outputs for consumers (e.g., PostgreSQL modules) to reference when creating backup instances
# ---------------------------------------------------------------------------------------------------------------------

output "backup_vault_id" {
  description = "The ID of the Azure Backup Vault. Use this when creating backup instances in consumer modules."
  value       = module.backup_vault.backup_vault_id
}

output "backup_vault_name" {
  description = "The name of the Azure Backup Vault."
  value       = module.backup_vault.backup_vault_name
}

output "backup_vault_principal_id" {
  description = "The Principal ID of the SystemAssigned Managed Identity for the Backup Vault. Use this for RBAC assignments to allow the vault to backup PostgreSQL instances."
  value       = module.backup_vault.backup_vault_principal_id
}

output "backup_vault_tenant_id" {
  description = "The Tenant ID of the SystemAssigned Managed Identity for the Backup Vault."
  value       = module.backup_vault.backup_vault_tenant_id
}

# ---------------------------------------------------------------------------------------------------------------------
# BACKUP POLICY OUTPUTS
# Policy IDs for use when creating backup instances
# ---------------------------------------------------------------------------------------------------------------------

output "postgresql_crit4_5_policy_id" {
  description = "The ID of the crit4_5 backup policy for PostgreSQL Flexible Server. Use this policy ID when onboarding criticality 4 or 5 databases to the backup vault."
  value       = module.backup_vault.postgresql_crit4_5_policy_id
}

output "postgresql_crit4_5_policy_name" {
  description = "The name of the crit4_5 backup policy for PostgreSQL Flexible Server."
  value       = module.backup_vault.postgresql_crit4_5_policy_name
}

output "postgresql_test_policy_id" {
  description = "The ID of the test backup policy for PostgreSQL Flexible Server. Use this policy ID when testing backup functionality with non-production databases."
  value       = module.backup_vault.postgresql_test_policy_id
}

output "postgresql_test_policy_name" {
  description = "The name of the test backup policy for PostgreSQL Flexible Server."
  value       = module.backup_vault.postgresql_test_policy_name
}

# ---------------------------------------------------------------------------------------------------------------------
# CONVENIENCE OUTPUTS
# Map outputs for easy consumption
# ---------------------------------------------------------------------------------------------------------------------

output "postgresql_policy_ids" {
  description = "Map of all PostgreSQL backup policy names to their IDs. Use this for dynamic policy selection based on criticality."
  value       = module.backup_vault.postgresql_policy_ids
}

output "vault_configuration" {
  description = "Summary of the backup vault configuration for documentation and validation purposes."
  value       = module.backup_vault.vault_configuration
}