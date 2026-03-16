# Required Permissions

## ADO Service Principal

### Storage (restore storage account)

| Role | Scope | Modes | Purpose |
|---|---|---|---|
| `Contributor` or `Storage Account Contributor` | Restore storage account (or its resource group) | `all`, `vault-only` | Create the blob container that receives vault restore output |
| `Storage Blob Data Reader` | Restore storage account | `all`, `database-only` | List and download database/roles blobs for pg_restore |

> `Storage Blob Data Reader` is a **data-plane** role — must be assigned explicitly on the storage account. It is **not** inherited from management-plane `Contributor`.

### Postgres (source subscription)

| Role | Scope | Modes | Purpose |
|---|---|---|---|
| `Contributor` | Source resource group | `all`, `database-only` | Read source server config (SKU, version, subnet, DNS zone) and create the restored Postgres Flexible Server |
| `Network Contributor`¹ | Subnet/VNet resource group in networking subscription | `all`, `database-only` | Join the restored server to the delegated subnet |
| `Private DNS Zone Contributor`² | DNS zone resource group in DNS subscription | `all`, `database-only` | Link the restored server to the private DNS zone |

¹ Or a custom role with `Microsoft.Network/virtualNetworks/subnets/join/action`  
² Or a custom role with `privateDnsZones/join/action` + `virtualNetworkLinks/write`

> The subnet and DNS zone roles are in **different subscriptions** from the source server — they must be assigned separately.

### Backup Vault

| Role | Scope | Modes | Purpose |
|---|---|---|---|
| `Backup Contributor` | Backup vault (or vault resource group) | `all`, `vault-only` | List backup instances and recovery points, trigger the restore job, and poll job status |

> `Backup Contributor` is a superset of `Backup Reader` and covers all dataprotection list, trigger, and job-show operations.

---

## Backup Vault Managed Identity (separate from ADO SP)

Pre-existing Terraform-managed assignments — not set by the pipeline:

| Role | Scope | Purpose |
|---|---|---|
| `Storage Blob Data Contributor` | Restore storage account | Write backup blobs to the container during the vault-to-storage transfer |
| `PostgreSQL Flexible Server Long Term Retention Backup Role` | Source PostgreSQL Flexible Server | Read the source server's backup data to fulfil the restore job |

---

## Per-mode summary

| Mode | Storage | Source RG | Networking sub | DNS sub | Vault |
|---|---|---|---|---|---|
| `all` | Contributor + Blob Data Reader | Reader + Contributor | Network Contributor | DNS Zone Contributor | Backup Contributor |
| `vault-only` | Contributor | — | — | — | Backup Contributor |
| `database-only` | Blob Data Reader | Reader + Contributor | Network Contributor | DNS Zone Contributor | — |
