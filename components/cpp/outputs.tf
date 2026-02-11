output "backup_vaults" {
  description = "Map of created backup vaults and key policy identifiers."
  value = {
    for key, vault in module.backup_vaults : key => {
      id                        = vault.backup_vault_id
      name                      = vault.backup_vault_name
      principal_id              = vault.backup_vault_principal_id
      tenant_id                 = vault.backup_vault_tenant_id
      postgresql_policy_ids     = vault.postgresql_policy_ids
      postgresql_crit4_5_policy = vault.postgresql_crit4_5_policy_id
      postgresql_test_policy    = vault.postgresql_test_policy_id
      vault_configuration       = vault.vault_configuration
    }
  }
}

output "backup_vault_id" {
  description = "Legacy: ID of the first configured Backup Vault."
  value       = local.primary_vault_key == null ? null : module.backup_vaults[local.primary_vault_key].backup_vault_id
}

output "backup_vault_name" {
  description = "Legacy: name of the first configured Backup Vault."
  value       = local.primary_vault_key == null ? null : module.backup_vaults[local.primary_vault_key].backup_vault_name
}

output "backup_vault_principal_id" {
  description = "Legacy: principal ID of the first configured Backup Vault."
  value       = local.primary_vault_key == null ? null : module.backup_vaults[local.primary_vault_key].backup_vault_principal_id
}

output "backup_vault_tenant_id" {
  description = "Legacy: tenant ID of the first configured Backup Vault."
  value       = local.primary_vault_key == null ? null : module.backup_vaults[local.primary_vault_key].backup_vault_tenant_id
}

output "postgresql_crit4_5_policy_id" {
  description = "Legacy: ID of the crit4_5 policy for the first configured Backup Vault."
  value       = local.primary_vault_key == null ? null : module.backup_vaults[local.primary_vault_key].postgresql_crit4_5_policy_id
}

output "postgresql_crit4_5_policy_name" {
  description = "Legacy: name of the crit4_5 policy for the first configured Backup Vault."
  value       = local.primary_vault_key == null ? null : module.backup_vaults[local.primary_vault_key].postgresql_crit4_5_policy_name
}

output "postgresql_test_policy_id" {
  description = "Legacy: ID of the test policy for the first configured Backup Vault."
  value       = local.primary_vault_key == null ? null : module.backup_vaults[local.primary_vault_key].postgresql_test_policy_id
}

output "postgresql_test_policy_name" {
  description = "Legacy: name of the test policy for the first configured Backup Vault."
  value       = local.primary_vault_key == null ? null : module.backup_vaults[local.primary_vault_key].postgresql_test_policy_name
}

output "postgresql_policy_ids" {
  description = "Legacy: map of PostgreSQL policy names to IDs for the first configured Backup Vault."
  value       = local.primary_vault_key == null ? null : module.backup_vaults[local.primary_vault_key].postgresql_policy_ids
}

output "vault_configuration" {
  description = "Legacy: vault configuration summary for the first configured Backup Vault."
  value       = local.primary_vault_key == null ? null : module.backup_vaults[local.primary_vault_key].vault_configuration
}
