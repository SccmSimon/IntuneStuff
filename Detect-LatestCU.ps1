<#
    Detect-LatestCU.ps1  -  Intune remediation detection script (SYSTEM, 64-bit).

    Exit 1 (remediation needed) when:
      - the "Do not connect to any Windows Update Internet locations" block is set, or
      - Windows Update offers an OS cumulative update directly, or
      - the newest installed update is older than $MaxAgeDays (lets the Catalog fallback run).
    Exit 0 otherwise. Server SKUs always exit 0.
#>

$MaxAgeDays  = 35
$WUKey       = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
$WUBlockName = 'DoNotConnectToWindowsUpdateInternetLocations'

try {
    if ((Get-CimInstance Win32_OperatingSystem).ProductType -ne 1) { Write-Output "Server OS: out of scope."; exit 0 }

    if ((Get-ItemProperty -Path $WUKey -Name $WUBlockName -ErrorAction SilentlyContinue).$WUBlockName -eq 1) {
        Write-Output "WU internet-location block is set."
        exit 1
    }

    $searcher = (New-Object -ComObject Microsoft.Update.Session).CreateUpdateSearcher()
    $searcher.Online = $true
    $searcher.ServerSelection = 2
    $found = $searcher.Search("IsInstalled=0 AND IsHidden=0 AND Type='Software' AND BrowseOnly=0")
    $cu = @($found.Updates | Where-Object {
        $_.Title -match 'Cumulative Update' -and
        $_.Title -notmatch 'Preview|Dynamic|Hotpatch|\.NET|NET Framework'
    })
    if ($cu.Count -gt 0) { Write-Output ("Pending: {0}" -f $cu[0].Title); exit 1 }

    $latest = Get-HotFix -ErrorAction SilentlyContinue |
              Where-Object { $_.InstalledOn } |
              Sort-Object InstalledOn -Descending | Select-Object -First 1
    if (-not $latest -or $latest.InstalledOn -lt (Get-Date).AddDays(-$MaxAgeDays)) {
        Write-Output ("Newest update is older than {0} days ({1})." -f $MaxAgeDays, $latest.HotFixID)
        exit 1
    }

    Write-Output ("Up to date. Newest update: {0} on {1:yyyy-MM-dd}." -f $latest.HotFixID, $latest.InstalledOn)
    exit 0
}
catch {
    Write-Output "Detection error: $($_.Exception.Message)"
    exit 1
}
