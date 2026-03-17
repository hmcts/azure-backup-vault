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

---

## Replace deprecated `--high-availability` flag in server create

**Priority:** Medium — action required before May 2026  
**Context:** During the Scenario 4.2 live run (2026-03-17), `az postgres flexible-server create`
emitted:

```
WARNING: Argument '--high-availability' has been deprecated and will be removed in next breaking
change release(2.86.0) scheduled for May 2026. Use '--zonal-resiliency' instead.
```

**Proposed improvement:**  
Replace `--high-availability Disabled` with `--zonal-resiliency Disabled` in both the live
server create command and the dry-run preview echo in `azure-pipelines-restore-cnp.yaml` before
Azure CLI 2.86.0 is rolled out to the ADO agent pools (expected May 2026). Verify the new flag
name and accepted values in the CLI release notes before the change.
