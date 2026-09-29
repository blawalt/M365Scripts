# m365scripts

Fun scripts for Intune and Microsoft 365 (fun?)

## Prerequisites

Most scripts use the Microsoft Graph PowerShell SDK:

```powershell
Install-Module Microsoft.Graph
```

Individual scripts may need extra modules or permissions, noted below. Review each script's `.SYNOPSIS` / header and any folder README before running.

## Scripts

| Script | Description |
| --- | --- |
| [`AddIntuneDeviceToGroupByUser/`](AddIntuneDeviceToGroupByUser) | Looks up a user's Intune-managed devices and adds them to an existing Entra ID device group. |
| [`BulkActionsByDeviceGroup/`](BulkActionsByDeviceGroup) | `Invoke-IntuneDeviceAction`: runs a bulk action (Retire, Wipe, Delete, Sync, Restart, FreshStart, RunRemediation) on devices from an Entra group or a CSV of device names. Supports `-WhatIf` and batching. |
| [`Entra/ClientSecretExpirationRunbook/`](Entra/ClientSecretExpirationRunbook) | Azure Automation runbook that finds app registration secrets and certificates expiring within 30 days and emails an alert via the Gmail API. |
| [`ForceWindowsUpdates/`](ForceWindowsUpdates) | Intune detection/remediation scripts that detect and trigger pending Windows updates (e.g. after Autopilot). Logs to the IntuneManagementExtension log folder. |
| [`OSDCloud/`](OSDCloud) | `OSDCloudWrapper.ps1`: launches a zero-touch OSDCloud deployment with preset OS, edition, and activation. |
| [`UpdateGroupTagViaList/`](UpdateGroupTagViaList) | Updates the Autopilot Group Tag for devices listed by serial number in a file. Supports `-WhatIf`. |
| [`Win32AzCopyGUI/`](Win32AzCopyGUI) | WinForms GUI for technicians to upload Win32 apps to Intune. Requires the `IntuneWin32App` module. |
| [`v143/`](v143) | `Get-Fido2Aaguid.ps1`: reads the AAGUID of a connected FIDO2 key via libfido2 (`fido2.dll`); includes prebuilt v143 dynamic/static libraries. |
| [`Get-DeviceIp.ps1`](Get-DeviceIp.ps1) | `Get-DeviceIP`: finds a device's IP by serial number using the Defender for Endpoint API (needs `MSAL.PS` and an app registration ID/tenant ID filled in). |
| [`UploadADMX.ps1`](UploadADMX.ps1) | Uploads an ADMX and its ADML file to Intune as a custom ADMX (set the file paths at the top of the script). |

## Notes

- Scripts with placeholders (`<AppId>`, `<TenantID>`, file paths, email addresses) must be edited before use.
- Test destructive actions (Wipe, Retire, Delete) with `-WhatIf` first.
