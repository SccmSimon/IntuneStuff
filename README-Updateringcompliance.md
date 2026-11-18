# Update Ring Compliance Report

Two scripts that show whether Windows devices installed each monthly cumulative update inside their Intune update ring's window, with failed attempts and Windows Update error codes. Nothing in either script is specific to one organisation.

| Script | Runs on | Does |
|---|---|---|
| `Detect-WUInstallHistory.ps1` (v1.4) | Each device, as an Intune Remediations detection script | Writes one line of Windows Update history to the detection output: install date, download date, failed attempts, last error code per month |
| `Get-UpdateRingComplianceReport.ps1` (v2.0) | Your admin machine | Reads rings, groups, devices and the detection output through Graph, then builds the Excel report |

## 1. Deploy the device script (once)

Intune admin center > Devices > Scripts and remediations > Remediations > Create.

| Setting | Value |
|---|---|
| Name | Anything containing `WUInstallHistory`, for example `Detect-WUInstallHistory` |
| Detection script | `Detect-WUInstallHistory.ps1` |
| Remediation script | None |
| Run this script using the logged-on credentials | No |
| Enforce script signature check | No (or sign it) |
| Run script in 64-bit PowerShell | Yes |
| Assignment | The devices you want in the report. Schedule: Daily |

The script only reads data and always exits 0, so devices show "Without issues". Data arrives after each device's first run, usually within a day.

**One check after the first run:** pick one device and compare an install time (`I:` in the output, UTC) with Settings > Windows Update > Update history on that device. They should differ only by your UTC offset. If they're off by an extra hour in summer, set `$HistoryDatesAreUtc = $false` at the top of the script.

## 2. Run the report

Prerequisites, once per machine:

```powershell
Install-Module Microsoft.Graph.Authentication -Scope CurrentUser
Install-Module ImportExcel -Scope CurrentUser
```

Graph permissions (delegated, an admin consents once): `DeviceManagementConfiguration.Read.All`, `DeviceManagementManagedDevices.Read.All`, `Group.Read.All`, `Device.Read.All`. Everything is read only.

```powershell
# Every Windows device in Intune
.\Get-UpdateRingComplianceReport.ps1

# Only the devices in a list (CSV with a DeviceName, Device, Asset Name or Name column, or a .txt with one name per line)
.\Get-UpdateRingComplianceReport.ps1 -DeviceListPath .\Devices.csv -OutputPath C:\Reports\RingCompliance.xlsx

# Only some rings on their own sheets
.\Get-UpdateRingComplianceReport.ps1 -RingNameFilter 'Ring-*'

# Unattended, with an app registration and certificate (application permissions, same names as above)
.\Get-UpdateRingComplianceReport.ps1 -TenantId contoso.onmicrosoft.com -ClientId <appId> -CertificateThumbprint <thumbprint>
```

| Parameter | Default | Purpose |
|---|---|---|
| `-RemediationName` | `WUInstallHistory` | Text in the Remediations package name. If several packages match, the newest result per device is used |
| `-DeviceListPath` | none (all Windows devices) | Limit the report to listed devices. Names not found in Intune are listed on the Summary sheet |
| `-MonthsToCheck` | 3 | Monthly updates to check, newest first. The newest drives the percentages |
| `-LiveDays` | 30 | Only devices that checked in within this many days are counted |
| `-RingNameFilter` | `*` | Which rings get their own sheet. All rings still count for the "more than one ring" check |
| `-OutputPath` | `UpdateRingCompliance_<date>.xlsx` in the current folder | Where to save the workbook |
| `-SkipErrorLookup` | off | Don't download error text from MS Learn (for offline runs) |

## How compliance is worked out

- **Release date**: Patch Tuesday (second Tuesday) of the update month.
- **Deferral ends**: release date + ring quality update deferral.
- **Deadline**: deferral end + ring quality update deadline + grace period.
- **Green**: installed on or after the deferral end and on or before the deadline. Also green when a later cumulative was installed before this month's deadline.
- **Red**: installed early or late, not installed after the deadline, Windows Update managed by ConfigMgr (co-management workload), device in more than one ring, or broken WMI.
- **Grey**: not due yet, no deadline set on the ring, or no data from the device yet.

Error descriptions come from two MS Learn pages: the Windows Update error reference and the common Windows Update errors page, which has the mitigations. They're cached for 30 days in `%LOCALAPPDATA%\UpdateRingCompliance`.

## Limits

- Assignment filters on rings are shown next to the group name but not evaluated.
- Rings assigned to user groups are matched to devices through the device's primary user.
- The Offered date is only there while the device's WindowsUpdateClient event log still holds event 44.
- Device script versions below 1.2 can't report error codes. The Summary sheet shows how many devices need the newer script.

## Changes from the previous version (1.5)

- No tenant names, group names, file names or paths in the code. All are parameters or read from the tenant.
- The device list is optional. Without one, every Windows device in Intune is reported.
- Column guide sheet fixed (it previously wrote zeros).
- Graph paging and throttling retries for large tenants.
- Device script 1.4 fixes install, failure and scan times that were an hour early during summer time.
