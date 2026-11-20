<#
.SYNOPSIS
BE-terna Bastion RDP Connector - connects to a D365 DevBox VM through Azure Bastion.
Credits to BTS-Team / Christian Flock.
.DESCRIPTION
Run on Windows with Windows PowerShell 5.1 or PowerShell 7 (STA).
Select the DevBox number; it sets the VM name (vm-D365-DevBox-NN) and the
Key Vault secret name (vm-D365-DevBox-NN-admin-password). Tenant, subscription,
resource groups, Bastion, Key Vault, username (devboxadmin), and local port
have defaults under "Show advanced settings".
Stopped VMs are started automatically. "Start VM" / "Stop VM..." only change
the power state; stopping deallocates the VM after a second confirmation click.
Missing CLI components require consent.
Bastion must be Standard/Premium with native client support enabled.
The signed-in user needs read access to VM/NIC/Bastion, permission to start
the VM if needed, and permission to read the Key Vault secret.
Each connection gets its own loopback address (127.0.0.2, 127.0.0.3, ...) and port,
relayed to the az Bastion tunnel, so several DevBoxes can be connected at once.
A hidden helper process owns tunnel and RDP; the tool can be closed after connecting
and the tunnel ends when the Remote Desktop window is closed.
The password is held in a session-only Windows credential (TERMSRV/127.0.0.N)
while RDP runs and removed afterwards; it is never logged, written to disk,
or passed on a command line. mstsc is started with /v instead of an .rdp file
so the April 2026 RDP-file security prompt (clipboard off) does not appear;
clipboard and other redirections follow the user's default RDP settings.
RDP policy can still require an interactive credential prompt.
Checks do not prove that NSG rules, guest RDP configuration, or credentials
allow sign-in. VM startup can incur cost; the VM is not stopped on disconnect.
#>
#Requires -Version 5.1

$ErrorActionPreference = 'Stop'
if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
    throw 'This connector requires Windows and the Remote Desktop client.'
}
if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {
    throw 'Run this script with powershell.exe -STA -File or pwsh.exe -STA -File.'
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Security
[System.Windows.Forms.Application]::EnableVisualStyles()

$TenantId = '1a20a8f3-6bfe-4ac9-a97a-2d66b666ba45'
$SubscriptionId = '46c6050a-3fa4-4b9c-af8e-975f5de4a736'
$DefaultRG = 'rg_D365-DevboxShared-01'
$DefaultBastion = 'Bas_D365-DevboxShared-01'
$DefaultKeyVault = 'kv-D365-DevboxShared'
$DefaultUsername = 'devboxadmin'
$CustomerName = 'PromoCell'
$DefaultDevBoxNumber = 3
$VmNameFormat = 'vm-D365-DevBox-{0:D2}'
$SecretNameFormat = '{0}-admin-password'
$CliRoot = Join-Path $env:LOCALAPPDATA 'Programs\AzureCLI'
$CliUrl = 'https://aka.ms/installazurecliwindowszipx64'

$form = New-Object System.Windows.Forms.Form
$AppTitle = 'BE-terna Bastion RDP Connector'
$AppCredits = 'Credits to BTS-Team / Christian Flock'
$form.Text = "$AppTitle - $CustomerName"
$form.Size = [System.Drawing.Size]::new(760, 520)
$form.StartPosition = 'CenterScreen'
$form.Font = [System.Drawing.Font]::new('Segoe UI', 9)
$form.AutoScroll = $true

$titleLabel = New-Object System.Windows.Forms.Label
$titleLabel.Text = $AppTitle
$titleLabel.Location = [System.Drawing.Point]::new(18, 12)
$titleLabel.Size = [System.Drawing.Size]::new(420, 30)
$titleLabel.Font = [System.Drawing.Font]::new('Segoe UI', 15, [System.Drawing.FontStyle]::Bold)
$form.Controls.Add($titleLabel)

$creditsLabel = New-Object System.Windows.Forms.Label
$creditsLabel.Text = $AppCredits
$creditsLabel.Location = [System.Drawing.Point]::new(20, 44)
$creditsLabel.Size = [System.Drawing.Size]::new(420, 20)
$creditsLabel.Font = [System.Drawing.Font]::new('Segoe UI', 9, [System.Drawing.FontStyle]::Italic)
$creditsLabel.ForeColor = [System.Drawing.Color]::DimGray
$form.Controls.Add($creditsLabel)

$customerLabel = New-Object System.Windows.Forms.Label
$customerLabel.Text = "Customer: $CustomerName"
$customerLabel.Location = [System.Drawing.Point]::new(445, 14)
$customerLabel.Size = [System.Drawing.Size]::new(270, 46)
$customerLabel.TextAlign = 'MiddleCenter'
$customerLabel.Font = [System.Drawing.Font]::new('Segoe UI', 14, [System.Drawing.FontStyle]::Bold)
$customerLabel.BackColor = [System.Drawing.Color]::FromArgb(0, 84, 147)
$customerLabel.ForeColor = [System.Drawing.Color]::White
$form.Controls.Add($customerLabel)

$indexLabel = New-Object System.Windows.Forms.Label
$indexLabel.Text = 'DevBox Number'
$indexLabel.Location = [System.Drawing.Point]::new(20, 88)
$indexLabel.Size = [System.Drawing.Size]::new(110, 22)
$form.Controls.Add($indexLabel)

$devBoxNumber = New-Object System.Windows.Forms.NumericUpDown
$devBoxNumber.Minimum = 1
$devBoxNumber.Maximum = 99
$devBoxNumber.Value = $DefaultDevBoxNumber
$devBoxNumber.Location = [System.Drawing.Point]::new(135, 84)
$devBoxNumber.Size = [System.Drawing.Size]::new(70, 24)
$devBoxNumber.Font = [System.Drawing.Font]::new('Segoe UI', 11)
$form.Controls.Add($devBoxNumber)

$btn = New-Object System.Windows.Forms.Button
$btn.Text = 'Connect'
$btn.Location = [System.Drawing.Point]::new(595, 82)
$btn.Size = [System.Drawing.Size]::new(120, 32)
$form.Controls.Add($btn)
$form.AcceptButton = $btn

$startVmButton = New-Object System.Windows.Forms.Button
$startVmButton.Text = 'Start VM'
$startVmButton.Location = [System.Drawing.Point]::new(225, 85)
$startVmButton.Size = [System.Drawing.Size]::new(80, 26)
$form.Controls.Add($startVmButton)

$stopVmButton = New-Object System.Windows.Forms.Button
$stopVmButton.Text = 'Stop VM...'
$stopVmButton.Location = [System.Drawing.Point]::new(313, 85)
$stopVmButton.Size = [System.Drawing.Size]::new(80, 26)
$stopVmButton.ForeColor = [System.Drawing.Color]::DarkRed
$form.Controls.Add($stopVmButton)

$disconnect = New-Object System.Windows.Forms.Button
$disconnect.Text = 'Cancel'
$disconnect.Location = [System.Drawing.Point]::new(465, 82)
$disconnect.Size = [System.Drawing.Size]::new(120, 32)
$disconnect.Enabled = $false
$form.Controls.Add($disconnect)

$targetLabel = New-Object System.Windows.Forms.Label
$targetLabel.Location = [System.Drawing.Point]::new(20, 124)
$targetLabel.Size = [System.Drawing.Size]::new(695, 22)
$targetLabel.ForeColor = [System.Drawing.Color]::DimGray
$form.Controls.Add($targetLabel)

$advancedToggle = New-Object System.Windows.Forms.CheckBox
$advancedToggle.Text = 'Show advanced settings'
$advancedToggle.Location = [System.Drawing.Point]::new(20, 150)
$advancedToggle.Size = [System.Drawing.Size]::new(250, 22)
$form.Controls.Add($advancedToggle)

$advancedPanel = New-Object System.Windows.Forms.Panel
$advancedPanel.Location = [System.Drawing.Point]::new(0, 178)
$advancedPanel.Size = [System.Drawing.Size]::new(735, 378)
$advancedPanel.Visible = $false
$form.Controls.Add($advancedPanel)

$fields = @(
    @('Customer', $CustomerName),
    @('Tenant ID', $TenantId),
    @('Subscription ID', $SubscriptionId),
    @('VM Resource Group', $DefaultRG),
    @('VM Name', ''),
    @('Bastion Resource Group', $DefaultRG),
    @('Bastion Name', $DefaultBastion),
    @('Key Vault Name', $DefaultKeyVault),
    @('Password Secret Name', ''),
    @('VM Username', $DefaultUsername),
    @('Local Port', '13389')
)

$textboxes = @{}
$y = 0
foreach ($f in $fields) {
    $label = New-Object System.Windows.Forms.Label
    $label.Text = $f[0]
    $label.Location = [System.Drawing.Point]::new(20, ($y + 4))
    $label.Size = [System.Drawing.Size]::new(170, 22)
    $advancedPanel.Controls.Add($label)

    $textbox = New-Object System.Windows.Forms.TextBox
    $textbox.Text = $f[1]
    $textbox.Location = [System.Drawing.Point]::new(195, $y)
    $textbox.Size = [System.Drawing.Size]::new(520, 24)
    $advancedPanel.Controls.Add($textbox)
    $textboxes[$f[0]] = $textbox
    $y += 34
}

$status = New-Object System.Windows.Forms.Label
$status.Text = 'Ready'
$status.Size = [System.Drawing.Size]::new(695, 22)
$form.Controls.Add($status)

function Update-TargetNames {
    $vmName = $VmNameFormat -f [int]$devBoxNumber.Value
    $textboxes['VM Name'].Text = $vmName
    $textboxes['Password Secret Name'].Text = $SecretNameFormat -f $vmName
}

function Update-TargetLabel {
    $targetLabel.Text = "VM: $($textboxes['VM Name'].Text)    Secret: $($textboxes['Password Secret Name'].Text)"
}

function Update-CustomerName {
    $name = $textboxes['Customer'].Text.Trim()
    $customerLabel.Text = "Customer: $name"
    $form.Text = if ($name) { "$AppTitle - $name" } else { $AppTitle }
}

function Update-FormLayout {
    $top = if ($advancedToggle.Checked) { $advancedPanel.Bottom + 6 } else { 180 }
    $status.Location = [System.Drawing.Point]::new(20, $top)
    $log.Location = [System.Drawing.Point]::new(20, ($top + 28))
    $form.ClientSize = [System.Drawing.Size]::new($form.ClientSize.Width, ($log.Bottom + 15))
}

$devBoxNumber.Add_ValueChanged({ Update-TargetNames })
$textboxes['Customer'].Add_TextChanged({ Update-CustomerName })
$textboxes['VM Name'].Add_TextChanged({ Update-TargetLabel })
$textboxes['Password Secret Name'].Add_TextChanged({ Update-TargetLabel })
$advancedToggle.Add_CheckedChanged({
    $advancedPanel.Visible = $advancedToggle.Checked
    Update-FormLayout
})
$script:CancelRequested = $false
$disconnect.Add_Click({ $script:CancelRequested = $true })
$form.Add_FormClosing({
    param($sender, $eventArgs)
    if (-not $btn.Enabled) {
        $eventArgs.Cancel = $true
        $script:CancelRequested = $true
        $status.Text = 'Cancelling; close again after cleanup.'
    }
})

$log = New-Object System.Windows.Forms.RichTextBox
$log.Size = [System.Drawing.Size]::new(695, 280)
$log.ReadOnly = $true
$log.BackColor = [System.Drawing.Color]::FromArgb(30, 30, 30)
$log.ForeColor = [System.Drawing.Color]::Gainsboro
$log.Font = [System.Drawing.Font]::new('Consolas', 9)
$form.Controls.Add($log)
Update-TargetNames
Update-TargetLabel
Update-FormLayout

function Write-Log {
    param(
        [string]$Message,
        [System.Drawing.Color]$Color = [System.Drawing.Color]::Gainsboro
    )
    $log.SelectionStart = $log.TextLength
    $log.SelectionColor = $Color
    $log.AppendText("[$(Get-Date -Format 'HH:mm:ss')] $Message`r`n")
    $log.ScrollToCaret()
    [System.Windows.Forms.Application]::DoEvents()
}

function Find-AzCommand {
    # PATH can contain both az.cmd and an extensionless bash script named az.
    $command = Get-Command az.cmd -CommandType Application -All -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($command) { return $command.Source }
    if (Test-Path $CliRoot) {
        $found = Get-ChildItem -Path $CliRoot -Filter az.cmd -Recurse | Select-Object -First 1
        if ($found) { return $found.FullName }
    }
    return $null
}

function Invoke-AzRaw {
    param([string[]]$Arguments)
    # Windows PowerShell maps native stderr to ErrorRecords, even for CLI warnings.
    $ErrorActionPreference = 'Continue'
    $output = @(& $script:AzCommand @Arguments 2>&1)
    [pscustomobject]@{
        ExitCode = $LASTEXITCODE
        Output = ($output | ForEach-Object { "$_" }) -join "`n"
    }
}

function Invoke-Az {
    param([string[]]$Arguments, [switch]$SensitiveOutput)
    $result = Invoke-AzRaw -Arguments ($Arguments + @('--only-show-errors', '--output', 'json'))
    if ($result.ExitCode -ne 0) {
        if ($SensitiveOutput) {
            throw "Key Vault secret retrieval failed (CLI exit $($result.ExitCode)). Check vault/secret names, secret read permission, and vault network access."
        }
        throw "Azure CLI failed (exit $($result.ExitCode)): $($result.Output)"
    }
    if (-not [string]::IsNullOrWhiteSpace($result.Output)) {
        try { return ConvertFrom-Json -InputObject $result.Output -ErrorAction Stop }
        catch { throw 'Azure CLI returned invalid JSON; check the CLI installation.' }
    }
}

function Get-ConnectionSettings {
    param([hashtable]$Values)
    foreach ($name in @('Tenant ID', 'Subscription ID', 'VM Resource Group', 'VM Name',
        'Bastion Resource Group', 'Bastion Name', 'Key Vault Name', 'Password Secret Name',
        'VM Username', 'Local Port')) {
        if ([string]::IsNullOrWhiteSpace($Values[$name])) { throw "Please fill in '$name'." }
        $Values[$name] = $Values[$name].Trim()
    }
    foreach ($name in @('Tenant ID', 'Subscription ID')) {
        $id = [guid]::Empty
        if (-not [guid]::TryParse($Values[$name], [ref]$id) -or $id -eq [guid]::Empty) {
            throw "'$name' must be a nonempty GUID."
        }
        $Values[$name] = $id.ToString()
    }
    foreach ($name in @('VM Resource Group', 'Bastion Resource Group', 'VM Name', 'Bastion Name')) {
        if ($Values[$name] -notmatch '^[\p{L}\p{N}_.()-]+$' -or $Values[$name].EndsWith('.')) {
            throw "'$name' contains unsupported Azure resource-name characters."
        }
    }
    if ($Values['Key Vault Name'] -notmatch '^[a-zA-Z][a-zA-Z0-9-]{1,22}[a-zA-Z0-9]$' -or
        $Values['Key Vault Name'].Contains('--')) { throw 'Invalid Key Vault name.' }
    if ($Values['Password Secret Name'] -notmatch '^[a-zA-Z0-9-]{1,127}$') { throw 'Invalid secret name.' }
    if ($Values['VM Username'] -match '[\r\n\x00]') { throw 'VM username must be a single line.' }
    $port = 0
    if (-not [int]::TryParse($Values['Local Port'], [ref]$port) -or $port -lt 1024 -or $port -gt 65535) {
        throw 'Local port must be an integer between 1024 and 65535.'
    }
    [pscustomobject]@{
        TenantId = $Values['Tenant ID']
        SubscriptionId = $Values['Subscription ID']
        VmResourceGroup = $Values['VM Resource Group']
        VmName = $Values['VM Name']
        BastionResourceGroup = $Values['Bastion Resource Group']
        BastionName = $Values['Bastion Name']
        VaultName = $Values['Key Vault Name']
        SecretName = $Values['Password Secret Name']
        Username = $Values['VM Username']
        LocalPort = $port
    }
}

function Test-LocalPortFree {
    param([string]$Address, [int]$Port)
    $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Parse($Address), $Port)
    try {
        $listener.Server.ExclusiveAddressUse = $true
        $listener.Start()
        return $true
    }
    catch [Net.Sockets.SocketException] { return $false }
    finally { $listener.Stop() }
}

function Get-ConnectionSlot {
    param([int]$BasePort, [int]$MaxSlots = 50)
    # mstsc stores credentials per host (TERMSRV/<host>, without port), so every parallel
    # connection gets its own loopback address; a remaining credential marks the slot as in use.
    Initialize-CredentialApi
    for ($i = 0; $i -lt $MaxSlots -and ($BasePort + $i) -le 65535; $i++) {
        $address = "127.0.0.$($i + 2)"
        $port = $BasePort + $i
        $target = "TERMSRV/$address"
        if ($null -ne [BastionRdpCredential]::ReadUserName($target)) { continue }
        if (-not (Test-LocalPortFree '127.0.0.1' $port) -or -not (Test-LocalPortFree $address $port)) { continue }
        return [pscustomobject]@{ Address = $address; Port = $port; CredentialTarget = $target }
    }
    throw "No free local connection slot found (ports $BasePort-$($BasePort + $MaxSlots - 1)). Close other connections or change the local port."
}

function Test-TunnelPort {
    param([int]$Port)
    $client = [Net.Sockets.TcpClient]::new()
    try {
        $pending = $client.BeginConnect('127.0.0.1', $Port, $null, $null)
        try {
            if (-not $pending.AsyncWaitHandle.WaitOne(200)) { return $false }
            $client.EndConnect($pending)
            return $true
        }
        finally { $pending.AsyncWaitHandle.Close() }
    }
    catch [Net.Sockets.SocketException] { return $false }
    finally { $client.Close() }
}

function Assert-NotCancelled {
    [System.Windows.Forms.Application]::DoEvents()
    if ($script:CancelRequested) { throw [OperationCanceledException]::new('Operation cancelled.') }
}

function Wait-WithUi {
    param([int]$Seconds)
    $timer = [Diagnostics.Stopwatch]::StartNew()
    while ($timer.Elapsed.TotalSeconds -lt $Seconds) {
        Assert-NotCancelled
        Start-Sleep -Milliseconds 200
    }
}

function Get-VmPowerState {
    param($Vm)
    $state = @($Vm.instanceView.statuses | Where-Object { $_.code -like 'PowerState/*' } |
        Select-Object -ExpandProperty code)
    if ($state.Count -ne 1) { throw 'Could not determine the VM power state.' }
    return $state[0]
}

function Get-VmInstanceArgs {
    param($Settings)
    @('vm', 'get-instance-view', '--resource-group', $Settings.VmResourceGroup,
        '--name', $Settings.VmName, '--subscription', $Settings.SubscriptionId)
}

function Assert-BastionReady {
    param($Settings)
    $bastion = Invoke-Az @('network', 'bastion', 'show', '--name', $Settings.BastionName,
        '--resource-group', $Settings.BastionResourceGroup, '--subscription', $Settings.SubscriptionId)
    if ($bastion.provisioningState -ne 'Succeeded') { throw 'Bastion is not provisioned successfully.' }
    if ($bastion.sku.name -notin @('Standard', 'Premium') -or $bastion.enableTunneling -ne $true) {
        throw 'Bastion requires Standard/Premium SKU and Native Client Support enabled.'
    }
    Write-Log 'Bastion is ready and supports native client tunneling.'
}

function Get-VmInstance {
    param($Settings)
    $vm = Invoke-Az (Get-VmInstanceArgs $Settings)
    if ($vm.storageProfile.osDisk.osType -ne 'Windows') { throw 'The target VM must run Windows for this RDP workflow.' }
    if ($vm.provisioningState -ne 'Succeeded') { throw 'VM provisioning has not succeeded.' }
    if ([string]::IsNullOrWhiteSpace($vm.id)) { throw 'Azure returned no VM resource ID.' }
    Write-Log "VM state: $(Get-VmPowerState $vm)"
    return $vm
}

function Wait-VmPowerState {
    param($Settings, [string]$Target, [string[]]$FailStates, [string]$Action,
        [int]$PollSeconds, [int]$TimeoutSeconds)
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $state = 'unknown'
    while ($true) {
        if ($timer.Elapsed.TotalSeconds -ge $TimeoutSeconds) {
            $targetName = $Target -replace '^PowerState/', ''
            throw "VM did not reach $targetName state within $([int]($TimeoutSeconds / 60)) minutes (last state: $state)."
        }
        Wait-WithUi $PollSeconds
        $vm = Invoke-Az (Get-VmInstanceArgs $Settings)
        $state = Get-VmPowerState $vm
        Write-Log "Waiting for VM to $Action... $([int]$timer.Elapsed.TotalSeconds)s elapsed, state: $state"
        if ($state -eq $Target) { return $vm }
        if ($state -in $FailStates) { throw "VM changed to $state instead of completing $Action." }
    }
}

function Start-VmAndWait {
    param($Settings, $Vm, [int]$PollSeconds = 10, [int]$TimeoutSeconds = 600)
    $state = Get-VmPowerState $Vm
    if ($state -eq 'PowerState/running') {
        Write-Log 'VM is already running.' ([System.Drawing.Color]::LightGreen)
        return $Vm
    }
    if ($state -in @('PowerState/stopped', 'PowerState/deallocated')) {
        Write-Log 'Starting the VM (it will remain running after disconnect)...' ([System.Drawing.Color]::Gold)
        Invoke-Az @('vm', 'start', '--no-wait', '--resource-group', $Settings.VmResourceGroup,
            '--name', $Settings.VmName, '--subscription', $Settings.SubscriptionId) | Out-Null
    }
    elseif ($state -ne 'PowerState/starting') {
        throw "VM is transitioning ($state). Retry when it is running or stopped."
    }
    # Directly after a --no-wait start, Azure may still briefly report stopped/deallocated.
    $Vm = Wait-VmPowerState -Settings $Settings -Target 'PowerState/running' `
        -FailStates @('PowerState/stopping', 'PowerState/deallocating') -Action 'start' `
        -PollSeconds $PollSeconds -TimeoutSeconds $TimeoutSeconds
    Write-Log 'VM is running.' ([System.Drawing.Color]::LightGreen)
    Write-Log 'Note: the VM was just started. Windows may need about 1 minute before Remote Desktop accepts the connection; if RDP fails, wait a moment and connect again.' ([System.Drawing.Color]::Gold)
    $Vm | Add-Member -NotePropertyName JustStarted -NotePropertyValue $true -Force
    return $Vm
}

function Confirm-VmShutdown {
    param([string]$VmName, [string]$State)
    $dialog = New-Object System.Windows.Forms.Form
    $dialog.Text = 'Confirm VM shutdown'
    $dialog.FormBorderStyle = 'FixedDialog'
    $dialog.StartPosition = 'CenterParent'
    $dialog.MinimizeBox = $false
    $dialog.MaximizeBox = $false
    $dialog.ShowInTaskbar = $false
    $dialog.Font = $form.Font
    $dialog.ClientSize = [System.Drawing.Size]::new(480, 230)

    $vmLabel = New-Object System.Windows.Forms.Label
    $vmLabel.Text = "Shut down ${VmName}?   (current state: $($State -replace '^PowerState/', ''))"
    $vmLabel.Location = [System.Drawing.Point]::new(16, 14)
    $vmLabel.Size = [System.Drawing.Size]::new(448, 24)
    $vmLabel.Font = [System.Drawing.Font]::new('Segoe UI', 11, [System.Drawing.FontStyle]::Bold)
    $dialog.Controls.Add($vmLabel)

    $warningPanel = New-Object System.Windows.Forms.Panel
    $warningPanel.Location = [System.Drawing.Point]::new(16, 48)
    $warningPanel.Size = [System.Drawing.Size]::new(448, 116)
    $warningPanel.BackColor = [System.Drawing.Color]::FromArgb(255, 235, 235)
    $warningPanel.BorderStyle = 'FixedSingle'
    $dialog.Controls.Add($warningPanel)

    $warningTitle = New-Object System.Windows.Forms.Label
    $warningTitle.Text = 'All unsaved work on this VM will be lost!'
    $warningTitle.Location = [System.Drawing.Point]::new(10, 8)
    $warningTitle.Size = [System.Drawing.Size]::new(426, 22)
    $warningTitle.Font = [System.Drawing.Font]::new('Segoe UI', 10.5, [System.Drawing.FontStyle]::Bold)
    $warningTitle.ForeColor = [System.Drawing.Color]::DarkRed
    $warningPanel.Controls.Add($warningTitle)

    $warning = New-Object System.Windows.Forms.Label
    $warning.Text = "- Everyone connected to this VM is disconnected immediately.`r`n" +
        "- Running processes (builds, DB syncs, deployments) are aborted.`r`n" +
        '- Contents of the temporary disk are cleared.'
    $warning.Location = [System.Drawing.Point]::new(10, 36)
    $warning.Size = [System.Drawing.Size]::new(426, 70)
    $warning.ForeColor = [System.Drawing.Color]::DarkRed
    $warningPanel.Controls.Add($warning)

    $okButton = New-Object System.Windows.Forms.Button
    $okButton.Text = 'Shut down VM'
    $okButton.Location = [System.Drawing.Point]::new(224, 182)
    $okButton.Size = [System.Drawing.Size]::new(120, 32)
    $okButton.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $okButton.BackColor = [System.Drawing.Color]::Firebrick
    $okButton.ForeColor = [System.Drawing.Color]::White
    $okButton.FlatStyle = 'Flat'
    $dialog.Controls.Add($okButton)

    $cancelButton = New-Object System.Windows.Forms.Button
    $cancelButton.Text = 'Cancel'
    $cancelButton.Location = [System.Drawing.Point]::new(354, 182)
    $cancelButton.Size = [System.Drawing.Size]::new(110, 32)
    $cancelButton.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $dialog.Controls.Add($cancelButton)
    $dialog.CancelButton = $cancelButton
    # Cancel has focus so an accidental Enter does not shut the VM down.
    $dialog.ActiveControl = $cancelButton

    try { return ($dialog.ShowDialog($form) -eq [System.Windows.Forms.DialogResult]::OK) }
    finally { $dialog.Dispose() }
}

function Stop-VmAndWait {
    param($Settings, $Vm, [int]$PollSeconds = 10, [int]$TimeoutSeconds = 900)
    $state = Get-VmPowerState $Vm
    if ($state -eq 'PowerState/deallocated') {
        Write-Log 'VM is already stopped (deallocated); nothing to do.' ([System.Drawing.Color]::LightGreen)
        return $Vm
    }
    if ($state -notin @('PowerState/running', 'PowerState/stopped')) {
        throw "VM is transitioning ($state). Retry when it is running or stopped."
    }
    if (-not (Confirm-VmShutdown -VmName $Settings.VmName -State $state)) {
        throw [OperationCanceledException]::new('Shutdown cancelled by user; the VM was not changed.')
    }
    Write-Log "Shutting down and deallocating $($Settings.VmName)..." ([System.Drawing.Color]::Gold)
    Invoke-Az @('vm', 'deallocate', '--no-wait', '--resource-group', $Settings.VmResourceGroup,
        '--name', $Settings.VmName, '--subscription', $Settings.SubscriptionId) | Out-Null
    # Azure may briefly still report running directly after a --no-wait deallocate.
    $Vm = Wait-VmPowerState -Settings $Settings -Target 'PowerState/deallocated' `
        -FailStates @('PowerState/starting') -Action 'shut down' `
        -PollSeconds $PollSeconds -TimeoutSeconds $TimeoutSeconds
    Write-Log 'VM is stopped (deallocated); compute is no longer billed.' ([System.Drawing.Color]::LightGreen)
    return $Vm
}

function Get-CheckedVm {
    param($Settings, [int]$PollSeconds = 10, [int]$StartTimeoutSeconds = 600)
    Assert-BastionReady $Settings
    $vm = Get-VmInstance $Settings
    return Start-VmAndWait -Settings $Settings -Vm $vm -PollSeconds $PollSeconds -TimeoutSeconds $StartTimeoutSeconds
}

function Initialize-AzureSession {
    param($Settings, [switch]$RequireBastionExtension)
    $status.Text = 'Preparing Azure CLI...'
    $script:AzCommand = Find-AzCommand
    if (-not $script:AzCommand) {
        $consent = [System.Windows.Forms.MessageBox]::Show($form,
            'Azure CLI is missing. Download and install it for the current user?',
            'Install Azure CLI', 'YesNo', 'Question')
        if ($consent -ne [System.Windows.Forms.DialogResult]::Yes) { throw 'Azure CLI installation declined.' }
        Write-Log 'Azure CLI not found. Installing for current user...' ([System.Drawing.Color]::Gold)
        $CliZip = Join-Path $env:TEMP ("AzureCLI-$([guid]::NewGuid()).zip")
        New-Item -ItemType Directory -Force -Path $CliRoot | Out-Null
        try {
            Invoke-WebRequest -Uri $CliUrl -OutFile $CliZip -UseBasicParsing
            Expand-Archive -Path $CliZip -DestinationPath $CliRoot -Force
        }
        finally {
            if (Test-Path -LiteralPath $CliZip) { Remove-Item -LiteralPath $CliZip -Force }
        }
        $script:AzCommand = Find-AzCommand
        if (-not $script:AzCommand) { throw 'Azure CLI installation completed, but az.cmd was not found.' }
    }
    Write-Log "Azure CLI: $script:AzCommand" ([System.Drawing.Color]::LightGreen)

    $version = Invoke-Az @('version')
    if ([version]$version.'azure-cli' -lt [version]'2.32.0') { throw 'Azure CLI 2.32.0 or later is required. Update Azure CLI.' }
    if ($RequireBastionExtension) {
        $extensions = @(Invoke-Az @('extension', 'list'))
        if (-not ($extensions | Where-Object { $_.name -eq 'bastion' })) {
            $consent = [System.Windows.Forms.MessageBox]::Show($form,
                'The Bastion CLI extension is missing. Install it for the current user?',
                'Install Bastion extension', 'YesNo', 'Question')
            if ($consent -ne [System.Windows.Forms.DialogResult]::Yes) { throw 'Bastion extension installation declined.' }
            $status.Text = 'Installing Bastion extension...'
            Invoke-Az @('extension','add','--name','bastion','--allow-preview','false') | Out-Null
        } else {
            Write-Log 'Bastion extension found.' ([System.Drawing.Color]::LightGreen)
        }
    }

    $status.Text = 'Authenticating...'
    Assert-NotCancelled
    $accountResult = Invoke-AzRaw @('account', 'show', '--only-show-errors', '-o', 'json')
    $account = $null
    if ($accountResult.ExitCode -eq 0) { $account = ConvertFrom-Json $accountResult.Output }
    $token = Invoke-AzRaw @('account', 'get-access-token', '--tenant', $Settings.TenantId,
        '--query', 'expiresOn', '--only-show-errors', '-o', 'json')
    if (-not $account -or $account.tenantId -ne $Settings.TenantId -or $token.ExitCode -ne 0) {
        Write-Log 'Interactive Azure sign-in required.' ([System.Drawing.Color]::Gold)
        Invoke-Az @('login','--tenant',$Settings.TenantId) | Out-Null
    } else {
        Write-Log 'Existing Azure login is valid.' ([System.Drawing.Color]::LightGreen)
    }
    Invoke-Az @('account','set','--subscription',$Settings.SubscriptionId) | Out-Null
    $account = Invoke-Az @('account', 'show', '--subscription', $Settings.SubscriptionId)
    if ($account.tenantId -ne $Settings.TenantId -or $account.id -ne $Settings.SubscriptionId -or
        $account.state -ne 'Enabled') { throw 'The selected subscription is not enabled in the requested tenant.' }
    Write-Log "Authenticated to subscription $($account.name)."
}

function Set-UiBusy {
    param([bool]$Busy, [string]$CancelText = 'Cancel')
    foreach ($textbox in $textboxes.Values) { $textbox.Enabled = -not $Busy }
    foreach ($control in @($devBoxNumber, $btn, $startVmButton, $stopVmButton)) { $control.Enabled = -not $Busy }
    $disconnect.Enabled = $Busy
    $disconnect.Text = if ($Busy) { $CancelText } else { 'Cancel' }
}

function Get-FormSettings {
    $values = @{}
    foreach ($name in $textboxes.Keys) { $values[$name] = $textboxes[$name].Text }
    return Get-ConnectionSettings $values
}

function Invoke-VmPowerOperation {
    param([ValidateSet('Start', 'Stop')][string]$Operation)
    $script:CancelRequested = $false
    Set-UiBusy $true 'Cancel wait'
    try {
        $settings = Get-FormSettings
        Write-Log "$Operation VM requested for $($settings.VmName)." ([System.Drawing.Color]::LightGreen)
        Initialize-AzureSession $settings
        $status.Text = 'Checking VM...'
        Assert-NotCancelled
        $vm = Get-VmInstance $settings
        if ($Operation -eq 'Start') {
            $status.Text = 'Starting VM...'
            Start-VmAndWait -Settings $settings -Vm $vm | Out-Null
        } else {
            $status.Text = 'Waiting for shutdown confirmation...'
            Stop-VmAndWait -Settings $settings -Vm $vm | Out-Null
        }
        $status.Text = 'Ready'
    }
    catch [OperationCanceledException] {
        $status.Text = 'Ready'
        if ($_.Exception.Message -like 'Shutdown cancelled*') {
            Write-Log $_.Exception.Message ([System.Drawing.Color]::Gold)
        } else {
            Write-Log 'Stopped waiting. A start/stop request already sent to Azure continues in the background.' ([System.Drawing.Color]::Gold)
        }
    }
    catch {
        $status.Text = 'Error'
        Write-Log $_.Exception.Message ([System.Drawing.Color]::Salmon)
    }
    finally { Set-UiBusy $false }
}

function Initialize-CredentialApi {
    if ('BastionRdpCredential' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;

public static class BastionRdpCredential
{
    const int CredTypeGeneric = 1;
    const int CredPersistSession = 1;
    const int ErrorNotFound = 1168;

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct CREDENTIAL
    {
        public int Flags;
        public int Type;
        public string TargetName;
        public string Comment;
        public System.Runtime.InteropServices.ComTypes.FILETIME LastWritten;
        public int CredentialBlobSize;
        public IntPtr CredentialBlob;
        public int Persist;
        public int AttributeCount;
        public IntPtr Attributes;
        public string TargetAlias;
        public string UserName;
    }

    [DllImport("advapi32.dll", EntryPoint = "CredWriteW", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern bool CredWrite(ref CREDENTIAL credential, int flags);

    [DllImport("advapi32.dll", EntryPoint = "CredReadW", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern bool CredRead(string target, int type, int flags, out IntPtr credential);

    [DllImport("advapi32.dll", EntryPoint = "CredDeleteW", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern bool CredDelete(string target, int type, int flags);

    [DllImport("advapi32.dll")]
    static extern void CredFree(IntPtr buffer);

    public static void Write(string target, string userName, string password)
    {
        IntPtr blob = Marshal.StringToCoTaskMemUni(password);
        try
        {
            var credential = new CREDENTIAL
            {
                Type = CredTypeGeneric,
                TargetName = target,
                UserName = userName,
                CredentialBlob = blob,
                CredentialBlobSize = password.Length * 2,
                Persist = CredPersistSession
            };
            if (!CredWrite(ref credential, 0)) throw new Win32Exception(Marshal.GetLastWin32Error());
        }
        finally { Marshal.ZeroFreeCoTaskMemUnicode(blob); }
    }

    public static string ReadUserName(string target)
    {
        IntPtr buffer;
        if (!CredRead(target, CredTypeGeneric, 0, out buffer))
        {
            int error = Marshal.GetLastWin32Error();
            if (error == ErrorNotFound) return null;
            throw new Win32Exception(error);
        }
        try { return ((CREDENTIAL)Marshal.PtrToStructure(buffer, typeof(CREDENTIAL))).UserName; }
        finally { CredFree(buffer); }
    }

    public static void Delete(string target)
    {
        if (!CredDelete(target, CredTypeGeneric, 0))
        {
            int error = Marshal.GetLastWin32Error();
            if (error != ErrorNotFound) throw new Win32Exception(error);
        }
    }
}
'@
}

function Set-RdpCredential {
    param([string]$Target, [string]$Username, [string]$Password)
    if ([string]::IsNullOrWhiteSpace($Password)) { throw 'The Key Vault password secret is empty.' }
    if ($Username -match '[\r\n\x00]') { throw 'VM username must be a single line.' }
    Initialize-CredentialApi
    # Session-only persistence: never written to disk and gone at Windows sign-out.
    [BastionRdpCredential]::Write($Target, $Username, $Password)
}

function Remove-RdpCredential {
    param([string]$Target)
    Initialize-CredentialApi
    [BastionRdpCredential]::Delete($Target)
}

function Stop-TunnelProcess {
    param([System.Diagnostics.Process]$Process)
    if ($Process.HasExited) { return }
    # az.cmd spawns cmd/python; stopping only its launcher leaves the tunnel alive.
    $children = @(Get-CimInstance Win32_Process -Filter "ParentProcessId = $($Process.Id)")
    foreach ($child in $children) {
        $childProcess = Get-Process -Id $child.ProcessId -ErrorAction SilentlyContinue
        if ($childProcess) { Stop-TunnelProcess $childProcess }
    }
    if (-not $Process.HasExited) { Stop-Process -Id $Process.Id -Force -ErrorAction Stop }
}

function Initialize-LoopbackRelay {
    if ('BastionLoopbackRelay' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System.Net;
using System.Net.Sockets;
using System.Threading;
using System.Threading.Tasks;

public static class BastionLoopbackRelay
{
    public static TcpListener Start(string address, int port, int targetPort)
    {
        var listener = new TcpListener(IPAddress.Parse(address), port);
        listener.ExclusiveAddressUse = true;
        listener.Start();
        var thread = new Thread(() =>
        {
            try
            {
                while (true)
                {
                    TcpClient client = listener.AcceptTcpClient();
                    ThreadPool.QueueUserWorkItem(_ => Pipe(client, targetPort));
                }
            }
            catch (SocketException) { }
            catch (System.ObjectDisposedException) { }
        });
        thread.IsBackground = true;
        thread.Start();
        return listener;
    }

    static void Pipe(TcpClient client, int targetPort)
    {
        using (client)
        using (var target = new TcpClient())
        {
            try
            {
                client.NoDelay = true;
                target.NoDelay = true;
                target.Connect(IPAddress.Loopback, targetPort);
                NetworkStream a = client.GetStream();
                NetworkStream b = target.GetStream();
                Task up = a.CopyToAsync(b).ContinueWith(_ => { try { target.Client.Shutdown(SocketShutdown.Send); } catch { } });
                Task down = b.CopyToAsync(a).ContinueWith(_ => { try { client.Client.Shutdown(SocketShutdown.Send); } catch { } });
                Task.WaitAll(up, down);
            }
            catch { }
        }
    }
}
'@
}

function New-ConnectionLauncherScript {
    param([hashtable]$Config)
    $functions = foreach ($name in @('Initialize-CredentialApi', 'Remove-RdpCredential', 'Stop-TunnelProcess',
            'Test-TunnelPort', 'Initialize-LoopbackRelay')) {
        "function $name {$((Get-Item "function:$name").ScriptBlock)}"
    }
    $json = $Config | ConvertTo-Json -Compress
    $body = @'
$ErrorActionPreference = 'Stop'
Remove-Item -LiteralPath $PSCommandPath -Force -ErrorAction SilentlyContinue
function Write-Status([string]$Text) { Add-Content -LiteralPath $config.StatusFile -Value $Text -Encoding UTF8 }
$tunnel = $null
$relay = $null
$tunnelLog = [IO.Path]::ChangeExtension($config.StatusFile, '.out.log')
$tunnelError = [IO.Path]::ChangeExtension($config.StatusFile, '.err.log')
try {
    # An encoded PowerShell command preserves argument boundaries for az.cmd.
    $quoted = @($config.AzCommand) + @($config.TunnelArgs) | ForEach-Object { "'" + $_.Replace("'", "''") + "'" }
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes('& ' + ($quoted -join ' ') + '; exit $LASTEXITCODE'))
    $tunnel = Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
        -ArgumentList @('-NoProfile', '-NonInteractive', '-EncodedCommand', $encoded) `
        -RedirectStandardOutput $tunnelLog -RedirectStandardError $tunnelError -PassThru -WindowStyle Hidden
    $timer = [Diagnostics.Stopwatch]::StartNew()
    while (-not (Test-TunnelPort $config.Port)) {
        if ($tunnel.HasExited) { throw 'Bastion tunnel process exited before becoming ready.' }
        if ($timer.Elapsed.TotalSeconds -ge 60) { throw 'Bastion tunnel did not become ready within 60 seconds.' }
        Start-Sleep -Milliseconds 200
    }
    Initialize-LoopbackRelay
    $relay = [BastionLoopbackRelay]::Start($config.RdpAddress, $config.Port, $config.Port)
    $rdp = Start-Process -FilePath $config.RdpCommand -ArgumentList $config.RdpArguments -PassThru
    Write-Status 'READY'
    $rdp.WaitForExit()
}
catch {
    Write-Status "ERROR: $($_.Exception.Message)"
    if (Test-Path -LiteralPath $tunnelError) {
        Get-Content -LiteralPath $tunnelError -Tail 15 | Where-Object { $_ } | ForEach-Object { Write-Status "ERROR: $_" }
    }
}
finally {
    if ($relay) { $relay.Stop() }
    if ($tunnel) { try { Stop-TunnelProcess $tunnel } catch { } }
    try { Remove-RdpCredential $config.CredentialTarget } catch { }
    foreach ($file in @($tunnelLog, $tunnelError)) { Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue }
}
'@
    return ($functions -join "`r`n") + "`r`n`$config = ConvertFrom-Json @'`r`n$json`r`n'@`r`n" + $body
}

function Start-ConnectionLauncher {
    param([hashtable]$Config)
    $launcherFile = [IO.Path]::ChangeExtension($Config.StatusFile, '.ps1')
    Set-Content -LiteralPath $launcherFile -Value (New-ConnectionLauncherScript $Config) -Encoding UTF8
    # Runs independently of this window: it owns tunnel, relay, mstsc and credential cleanup.
    Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
        -ArgumentList @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', "`"$launcherFile`"") `
        -WindowStyle Hidden -PassThru
}

function Wait-ConnectionReady {
    param([System.Diagnostics.Process]$Process, [string]$StatusFile, [int]$TimeoutSeconds = 120)
    $timer = [Diagnostics.Stopwatch]::StartNew()
    while ($true) {
        Assert-NotCancelled
        $exited = $Process.HasExited
        $lines = @()
        if (Test-Path -LiteralPath $StatusFile) {
            try { $lines = @(Get-Content -LiteralPath $StatusFile -ErrorAction Stop) } catch { }
        }
        if ($lines -contains 'READY') { return }
        if ($exited) {
            $errors = @($lines | Where-Object { $_ -like 'ERROR: *' } | ForEach-Object { $_.Substring(7) })
            if ($errors.Count) { throw ($errors -join "`r`n") }
            throw 'The connection helper exited unexpectedly.'
        }
        if ($timer.Elapsed.TotalSeconds -ge $TimeoutSeconds) { throw "The connection was not ready within $TimeoutSeconds seconds." }
        Start-Sleep -Milliseconds 200
    }
}

$btn.Add_Click({
    $script:CancelRequested = $false
    Set-UiBusy $true
    $Password = $null
    $slot = $null
    $launcher = $null
    $statusFile = $null
    $handedOver = $false

    try {
        $settings = Get-FormSettings
        if (-not (Get-Command mstsc.exe -CommandType Application -ErrorAction SilentlyContinue)) {
            throw 'Windows Remote Desktop (mstsc.exe) was not found.'
        }

        Write-Log "Starting connection workflow for $($settings.VmName)..." ([System.Drawing.Color]::LightGreen)
        Initialize-AzureSession $settings -RequireBastionExtension

        $status.Text = 'Checking Bastion and VM...'
        Assert-NotCancelled
        $checkedVm = Get-CheckedVm $settings
        $slot = Get-ConnectionSlot $settings.LocalPort

        $status.Text = 'Reading Key Vault secret...'
        Assert-NotCancelled
        Write-Log 'Reading password from Key Vault. Secret value will not be logged.'
        $Password = Invoke-Az -Arguments @('keyvault', 'secret', 'show', '--vault-name', $settings.VaultName,
            '--name', $settings.SecretName, '--subscription', $settings.SubscriptionId, '--query', 'value') -SensitiveOutput
        if ($Password -isnot [string] -or [string]::IsNullOrWhiteSpace($Password)) {
            throw 'Key Vault returned an empty or invalid password secret.'
        }
        Set-RdpCredential -Target $slot.CredentialTarget -Username $settings.Username -Password $Password
        $Password = $null

        Assert-NotCancelled
        $status.Text = 'Opening Bastion tunnel...'
        Write-Log "Opening Bastion tunnel and Remote Desktop on $($slot.Address):$($slot.Port)..."
        $statusFile = Join-Path $env:TEMP ("Bastion-$([guid]::NewGuid()).status")
        $launcher = Start-ConnectionLauncher @{
            StatusFile = $statusFile
            AzCommand = $script:AzCommand
            TunnelArgs = @('network', 'bastion', 'tunnel', '--name', $settings.BastionName,
                '--resource-group', $settings.BastionResourceGroup, '--subscription', $settings.SubscriptionId,
                '--target-resource-id', $checkedVm.id, '--resource-port', '3389', '--port', "$($slot.Port)", '--only-show-errors')
            Port = $slot.Port
            RdpAddress = $slot.Address
            CredentialTarget = $slot.CredentialTarget
            RdpCommand = 'mstsc.exe'
            # mstsc /v instead of an .rdp file: opened .rdp files get a security prompt with clipboard off by default.
            RdpArguments = "/v:$($slot.Address):$($slot.Port) /f"
        }
        Wait-ConnectionReady -Process $launcher -StatusFile $statusFile
        $handedOver = $true

        Write-Log "Remote Desktop to $($settings.VmName) started ($($slot.Address):$($slot.Port))." ([System.Drawing.Color]::LightGreen)
        Write-Log 'The tunnel closes automatically with the Remote Desktop window. You can close this tool or connect another DevBox.' ([System.Drawing.Color]::LightGreen)
        if ($checkedVm.JustStarted) {
            Write-Log 'The VM was just started: the Remote Desktop sign-in may take about 1 minute.' ([System.Drawing.Color]::Gold)
        }
        $status.Text = "Connected to $($settings.VmName) - ready for another connection"
    }
    catch [OperationCanceledException] {
        $status.Text = 'Ready'
        Write-Log 'Connection cancelled.' ([System.Drawing.Color]::Gold)
    }
    catch {
        $status.Text = 'Error'
        Write-Log $_.Exception.Message ([System.Drawing.Color]::Salmon)
    }
    finally {
        $Password = $null
        if (-not $handedOver) {
            if ($launcher -and -not $launcher.HasExited) {
                try { Stop-TunnelProcess $launcher }
                catch { Write-Log "Tunnel cleanup failed: $($_.Exception.Message)" ([System.Drawing.Color]::Salmon) }
            }
            if ($slot) {
                try { Remove-RdpCredential $slot.CredentialTarget }
                catch { Write-Log "Saved credential cleanup failed: $($_.Exception.Message)" ([System.Drawing.Color]::Salmon) }
            }
        }
        if ($statusFile) {
            foreach ($file in @($statusFile, [IO.Path]::ChangeExtension($statusFile, '.ps1'))) {
                Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
            }
        }
        Set-UiBusy $false
    }
})


$startVmButton.Add_Click({ Invoke-VmPowerOperation -Operation 'Start' })
$stopVmButton.Add_Click({ Invoke-VmPowerOperation -Operation 'Stop' })

try { [void]$form.ShowDialog() }
finally { $form.Dispose() }
