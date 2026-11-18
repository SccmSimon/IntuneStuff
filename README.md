# Endpoint PowerShell Scripts

PowerShell scripts for endpoint vulnerability remediation and reporting across Microsoft Intune, Microsoft Graph, Microsoft Defender and Qualys VMDR. Built from real remediation work on a large Windows 10/11 estate, then made generic so they can be used in any tenant.

**27 scripts** in 9 areas. Each script has a summary `.md` or folder `README.md` covering what it does, settings and how to deploy it.

## What's included

### Intune Remediations (detection and remediation pairs)
| Folder | Scripts | Purpose |
|---|---|---|
| `Intune-Remediations/ASR-Block-Events` | `Detect-AsrBlockEvents.ps1` | Report Defender Attack Surface Reduction blocks and audits in the Remediations report |
| `Intune-Remediations/BitLocker-Escrow` | `BitLockerEscrow-Remediate.ps1` | Back up BitLocker recovery keys to Entra ID (Intune or task sequence) |
| `Intune-Remediations/Company-Portal` | `Detect-` / `Remediate-CompanyPortal.ps1` | Install Company Portal through winget as SYSTEM |
| `Intune-Remediations/Edge-Latest-Version` | `Detect-` / `Remediate-EdgeLatestVersion.ps1` | Keep Edge Stable on the latest release, with SHA256 check of the MSI |
| `Intune-Remediations/Firefox-Usage` | `Detect-FirefoxUsage.ps1`, `FirefoxCompliance.json` | Flag devices where Firefox is in use (Remediation or custom compliance) |
| `Intune-Remediations/No-Op` | `Detect-` / `Remediate-NoOp.ps1` | Do-nothing pair for testing the Remediations pipeline |
| `Intune-Remediations/Stale-Profile-Apps` | `Remove-StaleProfileApps-Detection` / `-Remediation.ps1` | Remove per-user Zoom, classic Teams and Chrome from dormant profiles without deleting the profile |
| `Intune-Remediations/Stale-User-Profiles` | `Remove-StaleUserProfiles-Detection` / `-Remediation.ps1` | Delete user profiles unused for 90+ days, with safety guards and full per-profile logging |

### Application and runtime remediation
| Folder | Scripts | Purpose |
|---|---|---|
| `App-Removal` | `Uninstall-NotepadPlusPlus.ps1` | Remove every Notepad++ install, machine-wide and per-user, including logged-off profiles |
| `Chrome` | `Detect-ChromeVersion.ps1`, `Remediate-ChromeForceUpdate.ps1` | Force Chrome to a minimum version and keep auto-update enabled |
| `DotNet` | `Detect-DotNetRuntimeDependency.ps1` | Find an end-of-life .NET runtime, the apps that depend on it, and which x86/x64 roots are safe to remove |
| `Office` | `Detect-OfficeUpdate.ps1`, `Remediate-OfficeUpdateDiag.ps1` | Force a Microsoft 365 Apps security build with user prompts |
| `Office` | `Test-M365MonthlyEnterpriseChannel.ps1` | Check a device can reach the Monthly Enterprise Channel CDN |

### Intune tools (GUI)
| Folder | Script | Purpose |
|---|---|---|
| `Intune-Tools/DetectR` | `DetectR.ps1` | WPF tool to run a Remediations package on demand against a list of devices and watch the results live |
| `Intune-Tools/IntuneRemediationsExplorer` | `IntuneRemediationsExplorer.ps1` | Read-only WinForms tool to browse every Remediations package, its scripts, assignments and device results, with CSV/JSON/.ps1 export |

### Microsoft Graph reporting
| Folder | Script | Purpose |
|---|---|---|
| `Graph-Reporting` | `Get-DeviceUpdateRingGroups.ps1` (+ sample CSV) | Find devices in more than one Windows Update ring group, including nested membership |
| `Graph-Reporting` | `Test-IntuneDevices.ps1` | Check a device list against Intune and export enrolment, compliance and last contact date to CSV |

### Qualys VMDR
| Folder | Script | Purpose |
|---|---|---|
| `Qualys` | `Test-QualysKEVAccess.ps1` | Connectivity, authentication and KEV/RTI availability check |
| `Qualys` | `Get-QualysKEVReport.ps1` | CISA KEV findings on Windows 11 ranked by affected device count, with per-device detail and CSV export |
| `Qualys` | `Get-QualysTop10Threats.ps1` | Top 10 QIDs on Windows 10/11 by affected host count |

## Conventions
- Endpoint scripts target **Windows PowerShell 5.1** and are ASCII only, so they parse cleanly when delivered by Intune.
- Intune Remediations use **exit 0** for compliant or success and **exit 1** for non-compliant or failure. A short `Write-Output` line appears in the report columns (2048 character limit).
- Endpoint scripts run as **SYSTEM in 64-bit PowerShell** unless the README says otherwise.
- Logs go to `%ProgramData%\Microsoft\IntuneManagementExtension\Logs` where noted, so Intune **Collect diagnostics** picks them up.
- Graph tools use delegated sign-in with read scopes, except DetectR, which needs `DeviceManagementManagedDevices.PrivilegedOperations.All` to trigger remediations.

## Requirements
- Windows PowerShell 5.1 or PowerShell 7
- `Microsoft.Graph.Authentication` or `Microsoft.Graph.DeviceManagement` for the Graph scripts and tools
- A Qualys API account (not SSO/SAML) for the Qualys scripts
- An Intune role as well as Graph scopes for anything reading managed devices

## Before you use them
- Test on a pilot group first.
- Version numbers, QIDs and build numbers in the Office and Chrome scripts reflect the advisory they were written for. Update them for your own case.
- No organisation-specific data is included. Supply your own tenant, platform URLs and credentials.
- Exports from the Graph and Qualys scripts contain tenant data. Keep them inside your environment.

## Licence
MIT
