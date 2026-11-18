#Requires -RunAsAdministrator
<#
    Install-LatestCU.ps1  -  runs as SYSTEM (Intune remediation / scheduled task), 64-bit.

    Flow:
      0) Optionally clear "Do not connect to any Windows Update Internet locations",
         restart the WU agent so it re-reads policy (no reboot).
      GATE) If the block is still present (never set, or re-applied by GPO/MDM), stop
            before any toast so users are not notified about updates that cannot install.
            Server SKUs are also skipped.
      1) Direct WUA scan (ServerSelection = 2) for the latest OS cumulative, from Microsoft.
         Optional/preview (BrowseOnly), .NET, Dynamic and Hotpatch titles are excluded.
      2) If WUA offers no OS cumulative, fall back to the Microsoft Update Catalog via
         MSCatalogLTS (SYSTEM-safe HTML parsing):
           - Windows 11: newest security LCU for the release + architecture.
           - Windows 10: newest security CU (published under 21H2 OR 22H2 label),
             only if the device is ESU-active or is Enterprise LTSC 2021 (build 19044).
         All downloaded .msu files (checkpoint + LCU on 24H2 and later) are installed
         together with Add-WindowsPackage so DISM resolves the install order.
      3) Show three Windows-Update-branded toasts (required / installing / restart) in the
         active user's session via a temporary scheduled task. Restart toast offers a native
         4-hour defer plus a Restart now button. The toast has no restart deadline: pair
         this with an Intune update ring restart deadline if restarts must be enforced.

    Runtime : Intune remediations have a script timeout (check the current limit). A slow
              download plus install can exceed it; if that happens, run this script from a
              SYSTEM scheduled task instead.
    Branding: toasts use the Windows Update app ID. Record this in the change so security
              teams can identify them.

    Logging : Intune Management Extension log folder + Windows event log (source 'ExpediteCU').
    Event IDs: 1000 start 1001 target 1002 download 1003 install 1010 nothing pending
               1050 WU block cleared 1060 catalog fallback used 1100 user chose restart
               2000 skipped: block still present 2001 no interactive user
               2002 skipped: Win10 not ESU-active   2003 skipped: server OS
               2004 warning: module version not pinned   3000 failure
#>

$ErrorActionPreference = 'Stop'
$Root         = 'C:\ProgramData\ExpediteCU'
$HelperPath   = Join-Path $Root 'Show-UpdateToast.ps1'
$HandlerPath  = Join-Path $Root 'Handle-RebootAction.ps1'
$MsuDir       = Join-Path $Root 'msu'
$LogDir       = Join-Path $env:ProgramData 'Microsoft\IntuneManagementExtension\Logs'
$LogFile      = Join-Path $LogDir 'ExpediteCU.log'
$EventLogName = 'Application'
$EventSource  = 'ExpediteCU'
$Protocol     = 'wsupdate'
$DeferMin     = 240                 # 4 hours

$ClearWUBlock       = $true         # remove the DoNotConnect block + restart WU agent before scanning
$UseCatalogFallback = $true         # use the Catalog (via MSCatalogLTS) when WUA offers no CU

# Pin MSCatalogLTS to a version you have tested, e.g. '1.0.6'. Leave empty to allow the
# latest from PSGallery (logged as a warning). Pre-staging the module on devices is better still.
$MSCatalogLTSVersion = ''

$WUKey        = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
$WUBlockName  = 'DoNotConnectToWindowsUpdateInternetLocations'

# CBS HRESULT for "package not applicable to this computer".
$CBS_E_NOT_APPLICABLE = 0x800F081E

foreach ($d in @($Root,$LogDir,$MsuDir)) { if (-not (Test-Path $d)) { New-Item $d -ItemType Directory -Force | Out-Null } }
try { if (-not [System.Diagnostics.EventLog]::SourceExists($EventSource)) { New-EventLog -LogName $EventLogName -Source $EventSource } } catch {}

function Write-Log {
    param([string]$Message,[ValidateSet('Information','Warning','Error')][string]$Level='Information',[int]$EventId=1000)
    Add-Content -Path $LogFile -Value ("{0:u}  [{1}]  {2}" -f (Get-Date),$Level,$Message)
    try { Write-EventLog -LogName $EventLogName -Source $EventSource -EntryType $Level -EventId $EventId -Message $Message } catch {}
    Write-Output $Message
}
function Test-WUBlock {
    $v = (Get-ItemProperty -Path $WUKey -Name $WUBlockName -ErrorAction SilentlyContinue).$WUBlockName
    return ($v -eq 1)
}

# ESU-active check for Windows 10: the CU only applies to an entitled device.
# Authoritative signal is a Licensed ESU licensing product (LicenseStatus = 1).
function Test-ESUActive {
    $esu = Get-CimInstance SoftwareLicensingProduct -Filter "Name like '%ESU%'" -ErrorAction SilentlyContinue |
           Where-Object { $_.LicenseStatus -eq 1 }
    if ($esu) { return $true }
    # Subscription-based entitlement (Windows 365 / cloud) signal.
    if ((Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SoftwareProtectionPlatform\ESU' `
          -Name 'EnableESUSubscriptionCheck' -ErrorAction SilentlyContinue).EnableESUSubscriptionCheck -eq 1) { return $true }
    return $false
}

# Catalog dates may come back as DateTime or as a US-format string. Parse with the
# invariant culture so en-GB systems do not read 11/9/2026 as 11 September.
function ConvertTo-CatalogDate {
    param($Value)
    if ($Value -is [datetime]) { return $Value }
    $formats = 'M/d/yyyy','MM/dd/yyyy','M/d/yyyy h:mm:ss tt','yyyy-MM-dd','yyyy-MM-ddTHH:mm:ss'
    $parsed  = [datetime]::MinValue
    if ([datetime]::TryParseExact([string]$Value, [string[]]$formats, [Globalization.CultureInfo]::InvariantCulture,
                                  [Globalization.DateTimeStyles]::None, [ref]$parsed)) { return $parsed }
    return [datetime]::MinValue
}

Write-Log "Expedite CU run started." 'Information' 1000

# ------------------------------------------------------------------ #
# Device facts (used for gating, scan filtering and the Catalog).    #
# ------------------------------------------------------------------ #
$cvKey     = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
$osInfo    = Get-CimInstance Win32_OperatingSystem
$Build     = [int]$cvKey.CurrentBuild
$WinGen    = if ($Build -ge 22000) { '11' } else { '10' }
$Release   = $cvKey.DisplayVersion                              # e.g. "25H2" / "22H2"
$EditionId = $cvKey.EditionID                                   # e.g. "Enterprise", "EnterpriseS"
$IsLTSC2021 = ($WinGen -eq '10') -and ($EditionId -match 'EnterpriseS$') -and ($Build -eq 19044)
$Arch      = switch ($env:PROCESSOR_ARCHITECTURE) { 'AMD64' {'x64'} 'ARM64' {'arm64'} 'x86' {'x86'} default {'x64'} }
Write-Log "Device: Windows $WinGen $Release $EditionId $Arch, build $Build.$($cvKey.UBR)." 'Information' 1000

# ProductType 1 = workstation. Server SKUs need different Catalog titles; skip them.
if ($osInfo.ProductType -ne 1) {
    Write-Log "Skipped: server operating system ($($osInfo.Caption)) is out of scope." 'Warning' 2003
    exit 0
}

# ------------------------------------------------------------------ #
# 0) Optionally clear the WU internet-location block, then let the   #
#    WU agent re-read policy. No reboot required.                     #
# ------------------------------------------------------------------ #
if ($ClearWUBlock -and (Test-WUBlock)) {
    try {
        Remove-ItemProperty -Path $WUKey -Name $WUBlockName -Force -ErrorAction Stop
        Restart-Service wuauserv -Force
        try { Restart-Service usosvc -Force } catch {}
        Start-Sleep -Seconds 5
        Write-Log "Cleared '$WUBlockName' and restarted the WU agent so it re-reads policy." 'Information' 1050
    }
    catch { Write-Log "Failed to clear '$WUBlockName': $($_.Exception.Message)" 'Error' 3000 }
}

# ------------------------------------------------------------------ #
# GATE: if the block is still present, stop before any user toast.   #
# ------------------------------------------------------------------ #
if (Test-WUBlock) {
    Write-Log "Skipped: '$WUBlockName' is still enabled (likely re-applied by GPO/MDM); a direct Microsoft scan/download cannot succeed. No user notification shown." 'Warning' 2000
    exit 0
}

# ------------------------------------------------------------------ #
# Catalog selector via MSCatalogLTS (SYSTEM-safe HTML parsing).      #
#   Win11: newest security LCU (exclude Dynamic, Hotpatch, .NET).   #
#   Win10: newest security CU (21H2 OR 22H2 label; exclude Dynamic).#
# ------------------------------------------------------------------ #
function Get-CatalogCU {
    param([string]$Gen,[string]$Rel,[string]$Architecture,[bool]$LTSC2021)

    $haveModule = if ($MSCatalogLTSVersion) {
        Get-Module -ListAvailable MSCatalogLTS | Where-Object { $_.Version -eq [version]$MSCatalogLTSVersion }
    } else { Get-Module -ListAvailable MSCatalogLTS }

    if (-not $haveModule) {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        try { Install-PackageProvider -Name NuGet -Force -Scope AllUsers -ErrorAction Stop | Out-Null } catch {}
        if ($MSCatalogLTSVersion) {
            Install-Module MSCatalogLTS -RequiredVersion $MSCatalogLTSVersion -Scope AllUsers -Force -ErrorAction Stop
        } else {
            Write-Log "MSCatalogLTS version is not pinned; installing the latest from PSGallery." 'Warning' 2004
            Install-Module MSCatalogLTS -Scope AllUsers -Force -ErrorAction Stop
        }
    }
    if ($MSCatalogLTSVersion) { Import-Module MSCatalogLTS -RequiredVersion $MSCatalogLTSVersion -ErrorAction Stop }
    else                      { Import-Module MSCatalogLTS -ErrorAction Stop }

    if ($Gen -eq '10') {
        # Win10 security CU is a plain "Cumulative Update", published under BOTH 21H2 and
        # 22H2 labels. LTSC 2021 (21H2) searches 21H2 first; everything else 22H2 first.
        $labels = if ($LTSC2021) { '21H2','22H2' } else { '22H2','21H2' }
        $rows = $null
        foreach ($l in $labels) {
            $rows = Get-MSCatalogUpdate -Search "Cumulative Update for Windows 10 Version $l for $Architecture-based Systems" -ExcludeFramework
            if ($rows) { break }
        }
        $rows |
            Where-Object {
                $_.Title -match [regex]::Escape("$Architecture-based") -and
                $_.Title -match 'Cumulative Update' -and
                $_.Title -notmatch 'Dynamic' -and
                $_.Title -notmatch 'Preview' -and
                $_.Title -notmatch '\.NET' -and $_.Title -notmatch 'NET Framework' -and
                $_.Classification -match 'Security'
            } |
            Sort-Object { ConvertTo-CatalogDate $_.LastUpdated } -Descending | Select-Object -First 1
    }
    else {
        # Win11: standard monthly security LCU, exclude Dynamic, Hotpatch, Preview and .NET.
        $search = "Cumulative Update for Windows $Gen Version $Rel for $Architecture"
        Get-MSCatalogUpdate -Search $search -Strict -ExcludeFramework |
            Where-Object {
                $_.Title -match [regex]::Escape("$Architecture-based") -and
                $_.Title -notmatch 'Dynamic' -and
                $_.Title -notmatch 'Hotpatch' -and
                $_.Title -notmatch 'Preview' -and
                $_.Classification -match 'Security'
            } |
            Sort-Object { ConvertTo-CatalogDate $_.LastUpdated } -Descending | Select-Object -First 1
    }
}

# ------------------------------------------------------------------ #
# 1) Stage the user-context helper + restart handler (idempotent).   #
# ------------------------------------------------------------------ #
$HelperContent = @'
param(
    [ValidateSet('Required','Installing','Reboot')][string]$Phase,
    [int]$DeferMinutes = 240,
    [string]$RestartArg = 'wsupdate:restart'
)
$AppId = 'Windows.SystemToast.WindowsUpdate.MoNotification2'    # genuine Windows Update branding
$null = [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
$null = [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime]

switch ($Phase) {
  'Required' {
    $xml = @"
<toast>
  <visual><binding template="ToastGeneric">
    <text>Updates are required</text>
    <text>Your device needs important security updates. They will download and install shortly. You can keep working.</text>
  </binding></visual>
  <audio src="ms-winsoundevent:Notification.Default"/>
</toast>
"@
  }
  'Installing' {
    $xml = @"
<toast>
  <visual><binding template="ToastGeneric">
    <text>Installing updates</text>
    <text>Security updates are installing in the background. Please leave your device switched on. You can keep working.</text>
  </binding></visual>
  <audio silent="true"/>
</toast>
"@
  }
  'Reboot' {
    $xml = @"
<toast scenario="reminder">
  <visual><binding template="ToastGeneric">
    <text>Restart required</text>
    <text>Updates are installed. Please restart to finish. You can postpone this for 4 hours.</text>
  </binding></visual>
  <actions>
    <input id="snoozeTime" type="selection" defaultInput="$DeferMinutes">
      <selection id="$DeferMinutes" content="4 hours"/>
    </input>
    <action activationType="system"   arguments="snooze" hint-inputId="snoozeTime" content="Remind me later"/>
    <action activationType="protocol" arguments="$RestartArg" content="Restart now"/>
  </actions>
  <audio src="ms-winsoundevent:Notification.Reminder"/>
</toast>
"@
  }
}
$doc = New-Object Windows.Data.Xml.Dom.XmlDocument
$doc.LoadXml($xml)
[Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($AppId).Show($doc)
'@

# The handler only restarts when Windows actually has a restart pending, so a stray
# wsupdate:restart link (for example from a web page) cannot force a reboot.
$HandlerContent = @'
param([string]$Arg)                 # e.g. "wsupdate:restart"
$action = ($Arg -split ':',2)[-1].Trim('/')
try { Write-EventLog -LogName Application -Source 'ExpediteCU' -EntryType Information -EventId 1100 -Message "User selected '$action' on the restart toast." } catch {}
if ($action -ne 'restart') { return }

$pending = (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') -or
           (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired')
if ($pending) {
    Start-Process shutdown.exe -ArgumentList '/r','/t','60','/c','Restarting to finish installing updates.' -WindowStyle Hidden
}
'@

Set-Content -Path $HelperPath  -Value $HelperContent  -Encoding UTF8 -Force
Set-Content -Path $HandlerPath -Value $HandlerContent -Encoding UTF8 -Force

# On Windows 11, conhost --headless stops the brief console flash that
# -WindowStyle Hidden still shows. Windows 10 falls back to hidden PowerShell.
$PsExe      = Join-Path $PSHOME 'powershell.exe'
$ConhostExe = Join-Path $env:SystemRoot 'System32\conhost.exe'
$UseHeadless = ($WinGen -eq '11') -and (Test-Path $ConhostExe)

$psArgsHandler = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$HandlerPath`" `"%1`""
$handlerCmd = if ($UseHeadless) { "`"$ConhostExe`" --headless `"$PsExe`" $psArgsHandler" }
              else              { "`"$PsExe`" $psArgsHandler" }

$base = "HKLM:\SOFTWARE\Classes\$Protocol"
New-Item "$base\shell\open\command" -Force | Out-Null
Set-ItemProperty $base -Name '(Default)'    -Value "URL:$Protocol protocol"
Set-ItemProperty $base -Name 'URL Protocol' -Value ''
Set-ItemProperty "$base\shell\open\command" -Name '(Default)' -Value $handlerCmd
Write-Log "Staged helper, handler and '$Protocol' protocol." 'Information' 1000

# ------------------------------------------------------------------ #
# 2) Show a toast in the active user's session (from SYSTEM).        #
# ------------------------------------------------------------------ #
function Get-ActiveUser {
    # Console session user first (correct on shared devices), then fall back to an explorer owner.
    $u = (Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue).UserName
    if ($u) { return $u }
    $exp = Get-CimInstance Win32_Process -Filter "Name='explorer.exe'" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($exp) {
        $o = Invoke-CimMethod -InputObject $exp -MethodName GetOwner
        if ($o.User) { return "$($o.Domain)\$($o.User)" }
    }
    return $null
}

function Invoke-ToastAsUser {
    param([ValidateSet('Required','Installing','Reboot')][string]$Phase)
    $user = Get-ActiveUser
    if (-not $user) { Write-Log "No interactive user; '$Phase' toast skipped." 'Warning' 2001; return }

    # Resolve to a SID; this is more reliable than DOMAIN\user for Entra ID (AzureAD\) accounts.
    $principalId = $user
    try { $principalId = ([Security.Principal.NTAccount]$user).Translate([Security.Principal.SecurityIdentifier]).Value } catch {}

    $tn     = 'ExpediteCU_Toast'
    $psArgs = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$HelperPath`" -Phase $Phase -DeferMinutes $DeferMin -RestartArg `"$Protocol`:restart`""
    $act = if ($UseHeadless) { New-ScheduledTaskAction -Execute $ConhostExe -Argument "--headless `"$PsExe`" $psArgs" }
           else              { New-ScheduledTaskAction -Execute $PsExe      -Argument $psArgs }
    $prc = New-ScheduledTaskPrincipal -UserId $principalId -LogonType Interactive -RunLevel Limited
    try {
        Register-ScheduledTask -TaskName $tn -Action $act -Principal $prc -Force | Out-Null
        Start-ScheduledTask -TaskName $tn
        Start-Sleep -Seconds 5
        Write-Log "Displayed '$Phase' toast as $user." 'Information' 1000
    }
    catch { Write-Log "Failed to display '$Phase' toast as ${user}: $($_.Exception.Message)" 'Warning' 2001 }
    finally { try { Unregister-ScheduledTask -TaskName $tn -Confirm:$false -ErrorAction SilentlyContinue } catch {} }
}

try {
    # ------------------------------------------------------------------ #
    # 1) Direct WUA scan first (OS cumulative only, from Microsoft).     #
    #    BrowseOnly=0 drops optional/preview releases. Title filters     #
    #    stop .NET, Dynamic, Hotpatch and Preview short-circuiting it.   #
    # ------------------------------------------------------------------ #
    $session  = New-Object -ComObject Microsoft.Update.Session
    $searcher = $session.CreateUpdateSearcher()
    $searcher.Online = $true
    $searcher.ServerSelection = 2      # ssWindowsUpdate: bypass WSUS/SUP
    Write-Log "Scanning Windows Update directly for the latest cumulative update." 'Information' 1000
    $found = $searcher.Search("IsInstalled=0 AND IsHidden=0 AND Type='Software' AND BrowseOnly=0")
    $cu = @($found.Updates | Where-Object {
        $_.Title -match 'Cumulative Update' -and
        $_.Title -notmatch 'Preview' -and
        $_.Title -notmatch 'Dynamic' -and
        $_.Title -notmatch 'Hotpatch' -and
        $_.Title -notmatch '\.NET' -and $_.Title -notmatch 'NET Framework'
    })

    if ($cu.Count -gt 0) {
        # ---- normal path: install via WUA ----
        Write-Log ("Target (WUA): {0}" -f (($cu | ForEach-Object Title) -join '; ')) 'Information' 1001
        Invoke-ToastAsUser -Phase Required
        $coll = New-Object -ComObject Microsoft.Update.UpdateColl
        foreach ($u in $cu) { if (-not $u.EulaAccepted) { try { $u.AcceptEula() } catch {} }; $null = $coll.Add($u) }
        $dl = $session.CreateUpdateDownloader(); $dl.Updates = $coll; $dlr = $dl.Download()
        Write-Log "Download result code: $($dlr.ResultCode)." 'Information' 1002
        $inst = New-Object -ComObject Microsoft.Update.UpdateColl
        foreach ($u in $cu) { if ($u.IsDownloaded) { $null = $inst.Add($u) } }
        if ($inst.Count -eq 0) { Write-Log "Download failed; nothing to install." 'Error' 3000; exit 1 }

        Invoke-ToastAsUser -Phase Installing      # only once the download has actually succeeded
        $installer = $session.CreateUpdateInstaller(); $installer.Updates = $inst; $ir = $installer.Install()
        Write-Log "Install result code: $($ir.ResultCode); RebootRequired: $($ir.RebootRequired)." 'Information' 1003
        if ($ir.ResultCode -in 2,3) {
            if ($ir.RebootRequired) { Invoke-ToastAsUser -Phase Reboot }
            exit 0
        }
        Write-Log "Install did not report success." 'Error' 3000; exit 1
    }

    if (-not $UseCatalogFallback) { Write-Log "No OS cumulative offered by WUA; Catalog fallback disabled. No notification." 'Information' 1010; exit 0 }

    # ------------------------------------------------------------------ #
    # 2) Catalog fallback.                                              #
    #    Win10: only proceed if ESU-active or Enterprise LTSC 2021.     #
    # ------------------------------------------------------------------ #
    if ($WinGen -eq '10' -and -not $IsLTSC2021 -and -not (Test-ESUActive)) {
        Write-Log "Skipped: Windows 10 device is not ESU-active, so the monthly cumulative is not applicable. No notification shown." 'Warning' 2002
        exit 0
    }

    Write-Log "WUA offered no OS cumulative; querying the Catalog for Windows $WinGen $Release $Arch." 'Information' 1060
    $pick = Get-CatalogCU -Gen $WinGen -Rel $Release -Architecture $Arch -LTSC2021 $IsLTSC2021
    if (-not $pick) { Write-Log "Catalog returned no matching cumulative. No notification." 'Information' 1010; exit 0 }
    Write-Log ("Target (Catalog): {0}" -f $pick.Title) 'Information' 1001

    # The Catalog always returns the newest CU, even if it is already installed. Check the
    # KB first so users are not shown a "required" toast for an update they already have.
    if ($pick.Title -match '\b(KB\d{6,8})\b') {
        $kb = $Matches[1]
        if (Get-HotFix -Id $kb -ErrorAction SilentlyContinue) {
            Write-Log "Catalog target $kb is already installed. No notification." 'Information' 1010
            exit 0
        }
    }

    Invoke-ToastAsUser -Phase Required

    # Clear previous downloads, then fetch every file in the Catalog entry. On 24H2 and
    # later this can be a checkpoint CU plus the LCU; both are needed.
    Get-ChildItem $MsuDir -Include *.msu,*.cab -Recurse -ErrorAction SilentlyContinue | Remove-Item -Force
    $saveParams = @{ Update = $pick; Destination = $MsuDir; ErrorAction = 'Stop' }
    if ((Get-Command Save-MSCatalogUpdate).Parameters.ContainsKey('DownloadAll')) { $saveParams.DownloadAll = $true }
    Save-MSCatalogUpdate @saveParams

    $msus = @(Get-ChildItem $MsuDir -Filter *.msu)
    if ($msus.Count -eq 0) { Write-Log "Catalog download produced no .msu." 'Error' 3000; exit 1 }
    Write-Log ("Downloaded {0} package(s): {1}" -f $msus.Count, (($msus | ForEach-Object Name) -join ', ')) 'Information' 1002

    Invoke-ToastAsUser -Phase Installing      # only once the download has actually succeeded

    # Pointing DISM at the folder lets it install the checkpoint and LCU in the right order.
    Write-Log "Installing package(s) from $MsuDir via Add-WindowsPackage." 'Information' 1003
    try {
        $res = Add-WindowsPackage -Online -PackagePath $MsuDir -NoRestart -ErrorAction Stop
    }
    catch {
        $hr = $_.Exception.HResult
        if ($hr -eq [int]$CBS_E_NOT_APPLICABLE -or $_.Exception.Message -match 'not applicable') {
            Write-Log "Package is not applicable to this device (already installed or superseded)." 'Information' 1010
            exit 0
        }
        Write-Log ("Add-WindowsPackage failed (0x{0:X8}): {1}" -f $hr, $_.Exception.Message) 'Error' 3000
        exit 1
    }

    $rebootNeeded = [bool]($res | Where-Object { $_.RestartNeeded }) -or
                    (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending')
    Write-Log "Catalog install completed; RestartNeeded: $rebootNeeded." 'Information' 1003
    if ($rebootNeeded) { Invoke-ToastAsUser -Phase Reboot }
    exit 0
}
catch {
    Write-Log "Unhandled error: $($_.Exception.Message)" 'Error' 3000
    exit 1
}
