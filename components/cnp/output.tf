output "backup_vaults" {
  description = "Map of created backup vaults"
  value = {
    for key, vault in module.backup_vaults : key => {
      id = vault.vault_configuration
    }
  }
}
