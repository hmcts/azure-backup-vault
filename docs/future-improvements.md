# Future Improvements

## Backup Vault Monitoring and Alerting

**Priority:** High  
**Context:** The current Terraform deployment provisions backup vaults and policies but does not
configure any Azure Monitor alerts. If a scheduled backup job fails, if the backup policy is
not assigned to a new server instance, or if the vault managed identity loses the required
permissions, there is no automated notification — the failure is only discovered on the next
restore attempt or via manual review.

**Proposed improvement:**  
Add Terraform resources (or a dedicated monitoring module) to configure:

- An Azure Monitor alert rule on `Microsoft.DataProtection/backupVaults` scoped to each vault,
  firing when any backup job transitions to `Failed` or `CompletedWithWarnings`.
- An alert for backup instance `ProtectionStopped` state (indicates a server was deleted or
  assignment was removed).
- A weekly digest alert for RPO breach: last successful backup older than the policy schedule
  window plus a configurable tolerance.
- Routing to the existing HMCTS PlatOps alerting endpoint (Slack / PagerDuty / email action group).

This should be implemented alongside the next planned vault configuration change to avoid a
separate deployment cycle.
