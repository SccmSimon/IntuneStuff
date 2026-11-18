# ExpediteCU

Expedites the latest Windows cumulative update (CU) on Intune-managed Windows 10 and Windows 11 devices. It scans Windows Update directly, falls back to the Microsoft Update Catalog when needed, and tells the user what is happening through toast notifications styled like Windows Update.

Built to be deployed as an Intune remediation running as SYSTEM in 64-bit PowerShell.

## Features

- Clears the `DoNotConnectToWindowsUpdateInternetLocations` policy block (optional) and restarts the WU agent without a reboot.
- Stops before showing any toast if the block is re-applied by GPO or MDM.
- Scans Windows Update directly (`ServerSelection = 2`), bypassing WSUS/SUP.
- Excludes optional preview, .NET, Dynamic and Hotpatch updates.
- Falls back to the Microsoft Update Catalog via [MSCatalogLTS](https://www.powershellgallery.com/packages/MSCatalogLTS) when Windows Update offers nothing.
- Installs multi-file Catalog updates (checkpoint CU plus LCU on 24H2 and later) in the correct order with `Add-WindowsPackage`.
- Windows 10: only uses the Catalog if the device has an active ESU licence, or is Enterprise LTSC 2021.
- Three toasts in the user's session: **Updates are required**, **Installing updates**, **Restart required** (with a 4-hour snooze and a Restart now button).
- Logs to the Intune Management Extension log folder and the Windows Application event log.

## Repository contents

| File | Purpose |
|------|---------|
| `Install-LatestCU.ps1` | Remediation script. Scans, downloads, installs and notifies. |
| `Detect-LatestCU.ps1` | Detection script. Decides whether remediation should run. |
| `docs/ExpediteCU-Process-and-Implementation-Guide.docx` | Full process and implementation guide. |

## Requirements

- Windows 10 22H2 / LTSC 2021 or Windows 11 (client SKUs only; servers are skipped).
- Runs as SYSTEM, 64-bit PowerShell 5.1.
- Outbound access to Windows Update and, for the fallback, `catalog.update.microsoft.com`, `*.download.windowsupdate.com` and the PowerShell Gallery (unless MSCatalogLTS is pre-staged).
- Windows 10 Catalog fallback needs an active ESU licence (except LTSC 2021).

## Configuration

Settings are at the top of `Install-LatestCU.ps1`.

| Variable | Default | Description |
|----------|---------|-------------|
| `$ClearWUBlock` | `$true` | Remove the WU internet-location block before scanning. |
| `$UseCatalogFallback` | `$true` | Use the Microsoft Update Catalog when WUA offers no CU. |
| `$MSCatalogLTSVersion` | `''` | Pin the MSCatalogLTS version. **Set this before production.** |
| `$DeferMin` | `240` | Restart toast snooze in minutes. |
| `$Root` | `C:\ProgramData\ExpediteCU` | Working folder for helper scripts and downloads. |
| `$EventSource` | `ExpediteCU` | Event log source name. |
| `$Protocol` | `wsupdate` | Custom URL protocol used by the Restart now button. |

In `Detect-LatestCU.ps1`, `$MaxAgeDays` (default `35`) controls how old the newest installed update can be before remediation runs.

## Deployment (Intune remediation)

1. **Devices > Scripts and remediations > Remediations > Create**.
2. Detection script: `Detect-LatestCU.ps1`. Remediation script: `Install-LatestCU.ps1`.
3. Run this script using the logged-on credentials: **No**.
4. Enforce script signature check: **No** (or sign both scripts).
5. Run script in 64-bit PowerShell: **Yes**.
6. Assign to a pilot group first, with a daily schedule.

> Intune remediations have a script timeout. On slow connections a CU download and install can exceed it. If you see runs end with no final log entry, run `Install-LatestCU.ps1` from a SYSTEM scheduled task instead.

## Logging

- File: `C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\ExpediteCU.log` (collected by Intune diagnostics).
- Event log: **Application**, source **ExpediteCU**.

| Event ID | Meaning |
|----------|---------|
| 1000 | Run started / general information |
| 1001 | Target update identified |
| 1002 | Download result |
| 1003 | Install result |
| 1010 | Nothing pending / already installed / not applicable |
| 1050 | WU block cleared |
| 1060 | Catalog fallback used |
| 1100 | User chose an option on the restart toast |
| 2000 | Skipped: WU block still present |
| 2001 | No interactive user, or toast failed |
| 2002 | Skipped: Windows 10 not ESU-active |
| 2003 | Skipped: server OS |
| 2004 | Warning: MSCatalogLTS version not pinned |
| 3000 | Failure |

Quick query:

```powershell
Get-WinEvent -FilterHashtable @{ LogName = 'Application'; ProviderName = 'ExpediteCU' } -MaxEvents 50 |
    Format-Table TimeCreated, Id, LevelDisplayName, Message -AutoSize -Wrap
```

## Exit codes

| Code | Meaning |
|------|---------|
| 0 | Installed, nothing to do, or skipped by a gate |
| 1 | Download or install failed, or an unhandled error |

## Notes

- The toasts use the Windows Update app ID (`Windows.SystemToast.WindowsUpdate.MoNotification2`). Record this in your change so security teams can identify them.
- The restart toast has no deadline. If restarts must be enforced, pair this with an Intune update ring restart deadline.
- The restart handler only restarts when Windows reports a restart pending, so the `wsupdate:` protocol cannot be used to force a reboot.
- If GPO or MDM re-applies the WU block, the script exits without notifying anyone. Fix the policy source rather than relying on this script to clear it.

## Validate before use

```powershell
$errs = $null
$null = [System.Management.Automation.Language.Parser]::ParseFile("$PWD\Install-LatestCU.ps1", [ref]$null, [ref]$errs)
$errs
```

Test on a pilot device for each OS and release you support, including at least one Windows 11 24H2 or later device where the Catalog path downloads a checkpoint CU.

Endpoint PowerShell Scripts

PowerShell scripts for endpoint vulnerability remediation and reporting with Microsoft Intune, Microsoft Graph, Microsoft Defender and Qualys VMDR.

Author: Simon Diaz

Contents
Folder	Files	Purpose
App-Removal	Uninstall-NotepadPlusPlus.ps1	Remove every Notepad++ install, machine and per-user, including logged-off profiles
Chrome	Detect-ChromeVersion.ps1, Remediate-ChromeForceUpdate.ps1	Force Chrome to a minimum version and keep auto-update enabled
DotNet	Detect-DotNetRuntimeDependency.ps1	Find an EOL .NET runtime, the apps that depend on it, and which architecture roots can be removed
Graph-Reporting	Get-DeviceUpdateRingGroups.ps1 (+ sample CSV)	Find devices in more than one Windows Update ring group
Graph-Reporting	Test-IntuneDevices.ps1	Check a device list against Intune, with last contact date, to CSV
Intune-Remediations/ASR-Block-Events	Detect-AsrBlockEvents.ps1	Report Defender ASR blocks and audits in the Remediations report
Intune-Remediations/BitLocker-Escrow	BitLockerEscrow-Remediate.ps1	Back up BitLocker recovery keys to Entra ID (Intune or task sequence)
Intune-Remediations/Company-Portal	Detect/Remediate-CompanyPortal.ps1	Install Company Portal via winget as SYSTEM
Intune-Remediations/Edge-Latest-Version	Detect/Remediate-EdgeLatestVersion.ps1	Keep Edge Stable on the latest release
Intune-Remediations/Firefox-Usage	Detect-FirefoxUsage.ps1, FirefoxCompliance.json	Flag devices where Firefox is in use (Remediation or custom compliance)
Intune-Remediations/No-Op	Detect/Remediate-NoOp.ps1	Do-nothing pair for testing the Remediations pipeline
Intune-Remediations/Stale-Profile-Apps	Remove-StaleProfileApps-Detection/Remediation.ps1	Remove per-user Zoom, classic Teams and Chrome from dormant profiles, keeping the profile
Intune-Remediations/Stale-User-Profiles	Remove-StaleUserProfiles-Detection/Remediation.ps1	Delete user profiles unused for 90+ days
Intune-Tools/DetectR	DetectR.ps1	WPF tool to run a Remediations package on demand against a device list and watch results
Intune-Tools/IntuneRemediationsExplorer	IntuneRemediationsExplorer.ps1	Read-only WinForms browser and exporter for all Remediations packages
Office	Detect-OfficeUpdate.ps1, Remediate-OfficeUpdateDiag.ps1	Force a Microsoft 365 Apps security build with user popups
Office	Test-M365MonthlyEnterpriseChannel.ps1	Check a device can reach the Monthly Enterprise Channel CDN
Qualys	Get-QualysKEVReport.ps1	CISA KEV findings on Windows 11 ranked by device count, with per-device detail
Qualys	Get-QualysTop10Threats.ps1	Top 10 QIDs on Windows 10/11 by affected host count
Qualys	Test-QualysKEVAccess.ps1	Connectivity, auth and KEV/RTI availability check

Each script has a matching .md or a folder README.md covering what it does, settings and deployment.

Conventions
- Endpoint scripts target Windows PowerShell 5.1.
- Intune Remediations: exit 0 = compliant / success, exit 1 = non-compliant / failure. A short Write-Output line appears in the report columns (2048 character limit).
- Run endpoint scripts as SYSTEM in 64-bit PowerShell unless the README says otherwise.
- Logs go to %ProgramData%\Microsoft\IntuneManagementExtension\Logs where noted, so Intune "Collect diagnostics" picks them up.

Before you use them
- Test on a pilot group first.
- Version numbers, QIDs and build numbers in the Office and Chrome scripts reflect the advisory they were written for. Update them for your own case.
- No organisation-specific data is included. Supply your own tenant, platform URLs and credentials.

Licence
MIT
