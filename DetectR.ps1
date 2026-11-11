#Requires -Modules Microsoft.Graph.Authentication
<#
    DetectR
    Triggers an Intune remediation script package on demand against a list of devices
    and shows detection / remediation results per device.
#>

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

$Graph  = 'https://graph.microsoft.com/beta'
$Scopes = @(
    'DeviceManagementConfiguration.Read.All',                    # list remediation scripts + run states
    'DeviceManagementManagedDevices.Read.All',                   # resolve device names to IDs
    'DeviceManagementManagedDevices.PrivilegedOperations.All'    # trigger on-demand remediation
)

# Plain wording for the raw Graph states. Unknown values are shown as returned.
$DetectionText = @{
    success       = 'No issue'
    fail          = 'Issue found'
    scriptError   = 'Script error'
    pending       = 'Pending'
    notApplicable = 'Not applicable'
    unknown       = 'Unknown'
}
$RemediationText = @{
    success           = 'Fixed'
    remediationFailed = 'Fix failed'
    skipped           = 'Not needed'
    scriptError       = 'Script error'
    unknown           = 'Unknown'
}

$script:AllScripts  = @()
$script:RunScriptId = $null
$Rows = [System.Collections.ObjectModel.ObservableCollection[object]]::new()

#region XAML
[xml]$Xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="DetectR" Height="740" Width="1200"
        WindowStartupLocation="CenterScreen">
    <Grid Margin="10">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="140"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>

        <StackPanel Grid.Row="0" Orientation="Horizontal" Margin="0,0,0,8">
            <Button Name="ConnectButton" Content="Connect to Graph" Width="130" Height="26"/>
            <TextBlock Name="AccountText" Margin="10,0,0,0" VerticalAlignment="Center" Text="Not connected"/>
        </StackPanel>

        <Grid Grid.Row="1" Margin="0,0,0,8">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="Auto"/>
                <ColumnDefinition Width="220"/>
                <ColumnDefinition Width="Auto"/>
                <ColumnDefinition Width="*"/>
            </Grid.ColumnDefinitions>
            <TextBlock Grid.Column="0" Text="Search:" VerticalAlignment="Center" Margin="0,0,6,0"/>
            <TextBox   Grid.Column="1" Name="SearchBox" Height="24" VerticalContentAlignment="Center"/>
            <TextBlock Grid.Column="2" Text="Script:" VerticalAlignment="Center" Margin="12,0,6,0"/>
            <ComboBox  Grid.Column="3" Name="ScriptCombo" Height="24" DisplayMemberPath="displayName"/>
        </Grid>

        <Grid Grid.Row="2" Margin="0,0,0,8">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>
            <GroupBox Grid.Column="0" Header="Devices (one per line)">
                <TextBox Name="DeviceBox" AcceptsReturn="True" VerticalScrollBarVisibility="Auto"
                         FontFamily="Consolas" BorderThickness="0"/>
            </GroupBox>
            <StackPanel Grid.Column="1" Margin="8,8,0,0">
                <Button Name="ImportButton" Content="Import list..." Width="110" Height="26" Margin="0,0,0,6"/>
                <Button Name="ClearButton"  Content="Clear"          Width="110" Height="26"/>
            </StackPanel>
        </Grid>

        <StackPanel Grid.Row="3" Orientation="Horizontal" Margin="0,0,0,8">
            <Button Name="RunButton"     Content="Run on devices"  Width="130" Height="28" IsEnabled="False"/>
            <Button Name="RefreshButton" Content="Refresh results" Width="130" Height="28" Margin="8,0,0,0" IsEnabled="False"/>
            <CheckBox Name="AutoRefreshCheck" Content="Auto refresh every 30s" Margin="12,0,0,0"
                      VerticalAlignment="Center" IsChecked="True"/>
            <Button Name="ExportButton"  Content="Export CSV..."   Width="110" Height="28" Margin="12,0,0,0"/>
        </StackPanel>

        <DataGrid Grid.Row="4" Name="ResultGrid" AutoGenerateColumns="False" IsReadOnly="True"
                  CanUserAddRows="False" HeadersVisibility="Column" GridLinesVisibility="Horizontal">
            <DataGrid.Columns>
                <DataGridTextColumn Header="Device"        Binding="{Binding Device}"      Width="150"/>
                <DataGridTextColumn Header="Trigger"       Binding="{Binding Trigger}"     Width="170"/>
                <DataGridTextColumn Header="Detection"     Binding="{Binding Detection}"   Width="110"/>
                <DataGridTextColumn Header="Remediation"   Binding="{Binding Remediation}" Width="130"/>
                <DataGridTextColumn Header="Last update"   Binding="{Binding LastUpdate}"  Width="140"/>
                <DataGridTextColumn Header="From this run" Binding="{Binding Fresh}"       Width="110"/>
                <DataGridTextColumn Header="Output"        Binding="{Binding Output}"      Width="*"/>
                <DataGridTextColumn Header="Error"         Binding="{Binding Error}"       Width="200"/>
            </DataGrid.Columns>
        </DataGrid>

        <TextBlock Grid.Row="5" Name="StatusText" Margin="0,8,0,0" Text="Ready"/>
    </Grid>
</Window>
'@
#endregion

$Window = [Windows.Markup.XamlReader]::Load([System.Xml.XmlNodeReader]::new($Xaml))

# Create a PowerShell variable for every named control ($RunButton, $ResultGrid, etc.)
$Xaml.SelectNodes('//*[@Name]') | ForEach-Object {
    Set-Variable -Name $_.Name -Value $Window.FindName($_.Name)
}
$ResultGrid.ItemsSource = $Rows

#region Helper functions
function Set-Status {
    param([string]$Text)
    $StatusText.Text = $Text
    # Let WPF repaint while we are busy on the UI thread
    $Window.Dispatcher.Invoke([Action]{}, [System.Windows.Threading.DispatcherPriority]::Background)
}

function Invoke-GraphPaged {
    # Follows @odata.nextLink so we get every page, not just the first
    param([string]$Uri)
    $items = [System.Collections.Generic.List[object]]::new()
    while ($Uri) {
        $response = Invoke-MgGraphRequest -Method GET -Uri $Uri -OutputType PSObject
        if ($response.value) { $items.AddRange([object[]]$response.value) }
        $Uri = $response.'@odata.nextLink'
    }
    return $items
}

function Update-ScriptList {
    $filter = $SearchBox.Text.Trim()
    $matched = if ($filter) {
        $script:AllScripts | Where-Object { $_.displayName -like "*$filter*" }
    } else {
        $script:AllScripts
    }
    $ScriptCombo.ItemsSource = @($matched)
    if (@($matched).Count -gt 0) { $ScriptCombo.SelectedIndex = 0 }
    Set-Status "$(@($matched).Count) of $(@($script:AllScripts).Count) scripts shown"
}

function Get-DeviceNames {
    $DeviceBox.Text -split "`r?`n" |
        ForEach-Object { $_.Trim().Trim('"') } |
        Where-Object { $_ } |
        Select-Object -Unique
}

function Update-Results {
    if (-not $script:RunScriptId) { return }
    Set-Status 'Fetching results...'
    try {
        $uri    = "$Graph/deviceManagement/deviceHealthScripts/$($script:RunScriptId)/deviceRunStates?`$expand=managedDevice"
        $states = Invoke-GraphPaged -Uri $uri
    } catch {
        Set-Status "Result fetch failed: $($_.Exception.Message)"
        return
    }

    # Index run states by managed device ID for fast lookup
    $byId = @{}
    foreach ($s in $states) {
        if ($s.managedDevice.id) { $byId[$s.managedDevice.id] = $s }
    }

    foreach ($row in $Rows) {
        if (-not $row.ManagedDeviceId) { continue }
        $s = $byId[$row.ManagedDeviceId]
        if (-not $s) {
            $row.Detection = 'No result yet'
            continue
        }

        $d = [string]$s.detectionState
        $r = [string]$s.remediationState
        $row.Detection   = if ($DetectionText.ContainsKey($d))   { $DetectionText[$d] }   else { $d }
        $row.Remediation = if ($RemediationText.ContainsKey($r)) { $RemediationText[$r] } else { $r }

        $row.Output = (@($s.preRemediationDetectionScriptOutput, $s.postRemediationDetectionScriptOutput) |
                         Where-Object { $_ }) -join ' | '
        $row.Error  = (@($s.preRemediationDetectionScriptError, $s.remediationScriptError, $s.postRemediationDetectionScriptError) |
                         Where-Object { $_ }) -join ' | '
        try {
            $updatedUtc     = ([datetime]$s.lastStateUpdateDateTime).ToUniversalTime()
            $row.LastUpdate = $updatedUtc.ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss')
            $row.Fresh      = if ($row.TriggeredUtc -and $updatedUtc -ge $row.TriggeredUtc) { 'Yes' } else { 'No (older run)' }
        } catch {
            $row.LastUpdate = ''
            $row.Fresh      = 'Unknown'
        }
    }

    $ResultGrid.Items.Refresh()
    $done = @($Rows | Where-Object { $_.Fresh -eq 'Yes' }).Count
    Set-Status "Results refreshed $(Get-Date -Format 'HH:mm:ss'). $done of $($Rows.Count) devices have reported back from this run."
}
#endregion

#region Event handlers
$ConnectButton.Add_Click({
    try {
        Set-Status 'Connecting to Graph...'
        Connect-MgGraph -Scopes $Scopes -NoWelcome -ErrorAction Stop
        $AccountText.Text = "Connected as $((Get-MgContext).Account)"

        Set-Status 'Loading remediation scripts...'
        $script:AllScripts = Invoke-GraphPaged -Uri "$Graph/deviceManagement/deviceHealthScripts?`$select=id,displayName,publisher" |
            Sort-Object displayName
        Update-ScriptList
        $RunButton.IsEnabled = $true
    } catch {
        Set-Status "Connect failed: $($_.Exception.Message)"
    }
})

$SearchBox.Add_TextChanged({ Update-ScriptList })

$ImportButton.Add_Click({
    $dialog = [Microsoft.Win32.OpenFileDialog]::new()
    $dialog.Filter = 'Text or CSV (*.txt;*.csv)|*.txt;*.csv|All files (*.*)|*.*'
    if ($dialog.ShowDialog()) {
        # Takes the first column of each line and skips a header row if there is one
        $names = Get-Content -Path $dialog.FileName |
            ForEach-Object { ($_ -split ',')[0].Trim().Trim('"') } |
            Where-Object { $_ -and $_ -notin 'DeviceName', 'Name', 'Device', 'ComputerName' }
        $DeviceBox.Text = (@($DeviceBox.Text.Trim()) + $names | Where-Object { $_ }) -join "`r`n"
    }
})

$ClearButton.Add_Click({ $DeviceBox.Clear() })

$RunButton.Add_Click({
    $selected = $ScriptCombo.SelectedItem
    $names    = @(Get-DeviceNames)

    if (-not $selected)     { Set-Status 'Pick a script first.'; return }
    if ($names.Count -eq 0) { Set-Status 'Add at least one device.'; return }

    $answer = [System.Windows.MessageBox]::Show(
        "Run '$($selected.displayName)' on $($names.Count) device(s)?",
        'Confirm', 'YesNo', 'Warning')
    if ($answer -ne 'Yes') { return }

    $RunButton.IsEnabled = $false
    $script:RunScriptId  = $selected.id
    $Rows.Clear()

    $i = 0
    foreach ($name in $names) {
        $i++
        Set-Status "[$i/$($names.Count)] $name"

        $row = [pscustomobject]@{
            Device          = $name
            ManagedDeviceId = $null
            Trigger         = ''
            TriggeredUtc    = $null
            Detection       = ''
            Remediation     = ''
            LastUpdate      = ''
            Fresh           = ''
            Output          = ''
            Error           = ''
        }
        $Rows.Add($row)

        try {
            # Resolve name to managed device ID. Single quotes are doubled for OData.
            $safe    = $name.Replace("'", "''")
            $uri     = "$Graph/deviceManagement/managedDevices?`$filter=deviceName eq '$safe'&`$select=id,deviceName,lastSyncDateTime"
            $devices = @(Invoke-GraphPaged -Uri $uri)

            if ($devices.Count -eq 0) {
                $row.Trigger = 'Not found in Intune'
                continue
            }

            # Duplicate records happen. Use the one that synced most recently.
            $device = $devices | Sort-Object lastSyncDateTime -Descending | Select-Object -First 1
            $row.ManagedDeviceId = $device.id

            $body = @{ scriptPolicyId = $selected.id } | ConvertTo-Json
            Invoke-MgGraphRequest -Method POST `
                -Uri "$Graph/deviceManagement/managedDevices('$($device.id)')/initiateOnDemandProactiveRemediation" `
                -Body $body -ContentType 'application/json' | Out-Null

            $row.TriggeredUtc = (Get-Date).ToUniversalTime()
            $row.Trigger      = "Sent $(Get-Date -Format 'HH:mm:ss')"
            if ($devices.Count -gt 1) { $row.Trigger += " ($($devices.Count) records, used newest)" }
        } catch {
            $row.Trigger = 'Failed'
            $row.Error   = $_.Exception.Message
        }
    }

    $ResultGrid.Items.Refresh()
    $RunButton.IsEnabled     = $true
    $RefreshButton.IsEnabled = $true
    Set-Status 'Triggers sent. Devices need to be online to pick them up. Results usually take a few minutes.'
})

$RefreshButton.Add_Click({ Update-Results })

$ExportButton.Add_Click({
    if ($Rows.Count -eq 0) { Set-Status 'Nothing to export.'; return }
    $dialog = [Microsoft.Win32.SaveFileDialog]::new()
    $dialog.Filter   = 'CSV (*.csv)|*.csv'
    $dialog.FileName = "DetectR_Results_$(Get-Date -Format 'yyyyMMdd_HHmm').csv"
    if ($dialog.ShowDialog()) {
        $Rows | Select-Object Device, Trigger, Detection, Remediation, LastUpdate, Fresh, Output, Error |
            Export-Csv -Path $dialog.FileName -NoTypeInformation -Encoding UTF8
        Set-Status "Exported to $($dialog.FileName)"
    }
})

# Timer runs on the UI thread, so it can touch controls safely
$Timer = [System.Windows.Threading.DispatcherTimer]::new()
$Timer.Interval = [TimeSpan]::FromSeconds(30)
$Timer.Add_Tick({
    if ($AutoRefreshCheck.IsChecked -and $script:RunScriptId -and $Rows.Count -gt 0) { Update-Results }
})
$Timer.Start()

$Window.Add_Closed({ $Timer.Stop() })
#endregion

$Window.ShowDialog() | Out-Null
