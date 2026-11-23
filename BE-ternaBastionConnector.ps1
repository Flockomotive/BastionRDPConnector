<#
.SYNOPSIS
BE-ternaBastionConnector - connects to a D365 DevBox VM through Azure Bastion.
Credits to BTS-Team / Christian Flock.
.DESCRIPTION
Run on Windows with Windows PowerShell 5.1 or PowerShell 7 (STA).
Select the DevBox number; it sets the VM name (vm-D365-DevBox-NN) and the
Key Vault secret name (vm-D365-DevBox-NN-admin-password). Tenant, subscription,
resource groups, Bastion, Key Vault, username (devboxadmin), and local port
come from the selected customer and are shown under "Show advanced settings".
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
Customers are kept in %APPDATA%\BE-ternaBastionConnector\Customers\<Name>\settings.json
(one folder per customer). Nothing is preconfigured: on first start, add a customer.
"Add customer..." creates a new file from fields or pasted JSON, "Delete customer..."
removes the selected customer's file after confirmation, "Open settings file"
opens the selected customer's file, and saved edits load when the window is reactivated.
"Check status" shows power state, auto-shutdown schedule, and signed-in users (quser via
Run Command; needs Run Command permission and the VM to be running).
Install with Setup-BE-ternaBastionConnector.ps1. It installs the script and Azure CLI
for the current user, and creates Desktop and Start Menu shortcuts.
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

$VmNameFormat = 'vm-D365-DevBox-{0:D2}'
$SecretNameFormat = '{0}-admin-password'
$CliRoot = Join-Path $env:LOCALAPPDATA 'Programs\AzureCLI'
$CliUrl = 'https://aka.ms/installazurecliwindowszipx64'
$SettingsRoot = Join-Path $env:APPDATA 'BE-ternaBastionConnector'
$CustomersRoot = Join-Path $SettingsRoot 'Customers'
$AppStatePath = Join-Path $SettingsRoot 'app.json'

# Template for "Add customer"; also fills values that a customer file leaves out.
# Customer-specific values are blank on purpose and must be entered per customer.
$ProfileDefaults = [ordered]@{
    Name = ''
    TenantId = ''
    SubscriptionId = ''
    VmResourceGroup = ''
    BastionResourceGroup = ''
    BastionName = ''
    KeyVaultName = ''
    VmUsername = 'devboxadmin'
    LocalPort = 13389
    DevBoxNumber = 1
    VmNameFormat = $VmNameFormat
    SecretNameFormat = $SecretNameFormat
}

# Advanced-settings field label -> customer profile key.
$ProfileFieldMap = [ordered]@{
    'Tenant ID' = 'TenantId'
    'Subscription ID' = 'SubscriptionId'
    'VM Resource Group' = 'VmResourceGroup'
    'Bastion Resource Group' = 'BastionResourceGroup'
    'Bastion Name' = 'BastionName'
    'Key Vault Name' = 'KeyVaultName'
    'VM Username' = 'VmUsername'
    'Local Port' = 'LocalPort'
}

function ConvertTo-CustomerProfile {
    param($InputObject, [System.Collections.IDictionary]$Defaults)
    $result = [ordered]@{}
    foreach ($key in $Defaults.Keys) {
        $value = $null
        if ($InputObject -is [System.Collections.IDictionary]) { $value = $InputObject[$key] }
        elseif ($null -ne $InputObject -and $InputObject.PSObject.Properties[$key]) { $value = $InputObject.$key }
        $text = if ($null -eq $value) { '' } else { "$value".Trim() }
        if ($key -ne 'Name' -and $text -eq '') { $text = "$($Defaults[$key])" }
        $result[$key] = $text
    }
    $name = $result['Name']
    if (-not $name -or $name -match '[\r\n]') { throw 'Every customer in the settings file needs a single-line "Name".' }
    $number = 0
    if (-not [int]::TryParse($result['DevBoxNumber'], [ref]$number) -or $number -lt 1 -or $number -gt 99) {
        throw "Customer '$name': DevBoxNumber must be between 1 and 99."
    }
    $result['DevBoxNumber'] = $number
    $port = 0
    if (-not [int]::TryParse($result['LocalPort'], [ref]$port) -or $port -lt 1024 -or $port -gt 65535) {
        throw "Customer '$name': LocalPort must be between 1024 and 65535."
    }
    $result['LocalPort'] = $port
    foreach ($key in @('VmNameFormat', 'SecretNameFormat')) {
        try { [void]($result[$key] -f 1) }
        catch { throw "Customer '$name': $key is not a valid format string." }
    }
    $result
}

function Get-CustomerFolderName {
    param([string]$Name)
    $invalid = [regex]::Escape((-join [IO.Path]::GetInvalidFileNameChars()))
    $folder = ($Name -replace "[$invalid]", '_').Trim(' ', '.')
    if (-not $folder) { throw "Customer name '$Name' cannot be used as a folder name." }
    if ($folder -match '^(CON|PRN|AUX|NUL|COM\d|LPT\d)$') { $folder += '_' }
    $folder
}

function Write-JsonFile {
    param([string]$Path, $InputObject)
    $directory = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $directory)) { [void](New-Item -ItemType Directory -Path $directory -Force) }
    $temp = "$Path.tmp"
    [IO.File]::WriteAllText($temp, (ConvertTo-Json -InputObject $InputObject -Depth 5),
        (New-Object System.Text.UTF8Encoding $false))
    if (Test-Path -LiteralPath $Path) { [IO.File]::Replace($temp, $Path, $null) }
    else { [IO.File]::Move($temp, $Path) }
}

function Read-CustomerProfiles {
    param([string]$Root, [System.Collections.IDictionary]$Defaults)
    $customers = New-Object System.Collections.ArrayList
    $errors = New-Object System.Collections.ArrayList
    if (Test-Path -LiteralPath $Root) {
        foreach ($folder in @(Get-ChildItem -LiteralPath $Root -Directory | Sort-Object Name)) {
            $path = Join-Path $folder.FullName 'settings.json'
            if (-not (Test-Path -LiteralPath $path)) { continue }
            try {
                try { $data = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($path)) -ErrorAction Stop }
                catch { throw "not valid JSON: $($_.Exception.Message)" }
                if ($data -isnot [System.Management.Automation.PSCustomObject]) { throw 'expected one JSON object { ... }.' }
                if (-not "$($data.Name)".Trim()) {
                    $data | Add-Member -NotePropertyName Name -NotePropertyValue $folder.Name -Force
                }
                $customer = ConvertTo-CustomerProfile $data $Defaults
                if (@($customers | Where-Object { $_.Name -eq $customer.Name }).Count) {
                    throw "customer name '$($customer.Name)' is already used by another folder."
                }
                $customer['SettingsPath'] = $path
                [void]$customers.Add($customer)
            }
            catch { [void]$errors.Add("${path}: $($_.Exception.Message)") }
        }
    }
    [pscustomobject]@{ Customers = $customers; Errors = $errors }
}

function New-CustomerProfileFile {
    param([string]$Root, [System.Collections.IDictionary]$CustomerProfile, [object[]]$ExistingCustomers)
    if (@($ExistingCustomers | Where-Object { $_.Name -eq $CustomerProfile.Name }).Count) {
        throw "Customer '$($CustomerProfile.Name)' already exists."
    }
    $path = Join-Path (Join-Path $Root (Get-CustomerFolderName $CustomerProfile.Name)) 'settings.json'
    if (Test-Path -LiteralPath $path) { throw "$path already exists." }
    $content = [ordered]@{}
    foreach ($key in $CustomerProfile.Keys) { if ($key -ne 'SettingsPath') { $content[$key] = $CustomerProfile[$key] } }
    Write-JsonFile $path $content
    $path
}

function Remove-CustomerProfileFile {
    param([string]$Root, [System.Collections.IDictionary]$CustomerProfile)
    if (-not $CustomerProfile.Contains('SettingsPath')) { throw "Customer '$($CustomerProfile.Name)' has no settings file." }
    $path = [IO.Path]::GetFullPath($CustomerProfile.SettingsPath)
    $folder = [IO.Path]::GetDirectoryName($path)
    if ([IO.Path]::GetFileName($path) -ne 'settings.json' -or
        [IO.Path]::GetDirectoryName($folder).TrimEnd('\') -ne [IO.Path]::GetFullPath($Root).TrimEnd('\')) {
        throw "Refusing to delete $path; it is not a customer settings file under $Root."
    }
    Remove-Item -LiteralPath $path -Force -ErrorAction Stop
    # Keep the folder if the user put other files into it.
    if (-not @(Get-ChildItem -LiteralPath $folder -Force).Count) { Remove-Item -LiteralPath $folder -Force -ErrorAction Stop }
    $path
}

function Test-CustomerProfile {
    param([System.Collections.IDictionary]$CustomerProfile)
    $vmName = $CustomerProfile.VmNameFormat -f [int]$CustomerProfile.DevBoxNumber
    [void](Get-ConnectionSettings @{
        'Tenant ID' = "$($CustomerProfile.TenantId)"
        'Subscription ID' = "$($CustomerProfile.SubscriptionId)"
        'VM Resource Group' = "$($CustomerProfile.VmResourceGroup)"
        'VM Name' = $vmName
        'Bastion Resource Group' = "$($CustomerProfile.BastionResourceGroup)"
        'Bastion Name' = "$($CustomerProfile.BastionName)"
        'Key Vault Name' = "$($CustomerProfile.KeyVaultName)"
        'Password Secret Name' = $CustomerProfile.SecretNameFormat -f $vmName
        'VM Username' = "$($CustomerProfile.VmUsername)"
        'Local Port' = "$($CustomerProfile.LocalPort)"
    })
}

$form = New-Object System.Windows.Forms.Form
$AppTitle = 'BE-ternaBastionConnector'
$AppCredits = 'Credits to BTS-Team / Christian Flock'
$form.Text = $AppTitle
$form.Size = [System.Drawing.Size]::new(760, 520)
$form.StartPosition = 'CenterScreen'
$hostExe = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
if ([IO.Path]::GetFileName($hostExe) -notmatch '^(powershell|pwsh)(_ise)?\.exe$') {
    $form.Icon = [System.Drawing.Icon]::ExtractAssociatedIcon($hostExe)
}
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

$customerPanel = New-Object System.Windows.Forms.Panel
$customerPanel.Location = [System.Drawing.Point]::new(445, 14)
$customerPanel.Size = [System.Drawing.Size]::new(270, 46)
$customerPanel.BackColor = [System.Drawing.Color]::FromArgb(0, 84, 147)
$form.Controls.Add($customerPanel)

$customerCaption = New-Object System.Windows.Forms.Label
$customerCaption.Text = 'Customer'
$customerCaption.Location = [System.Drawing.Point]::new(8, 0)
$customerCaption.Size = [System.Drawing.Size]::new(84, 46)
$customerCaption.TextAlign = 'MiddleLeft'
$customerCaption.Font = [System.Drawing.Font]::new('Segoe UI', 11, [System.Drawing.FontStyle]::Bold)
$customerCaption.ForeColor = [System.Drawing.Color]::White
$customerPanel.Controls.Add($customerCaption)

$customerBox = New-Object System.Windows.Forms.ComboBox
$customerBox.DropDownStyle = 'DropDownList'
$customerBox.Location = [System.Drawing.Point]::new(94, 8)
$customerBox.Size = [System.Drawing.Size]::new(166, 30)
$customerBox.Font = [System.Drawing.Font]::new('Segoe UI', 12, [System.Drawing.FontStyle]::Bold)
$customerPanel.Controls.Add($customerBox)

$addCustomerLink = New-Object System.Windows.Forms.LinkLabel
$addCustomerLink.Text = 'Add customer...'
$addCustomerLink.Location = [System.Drawing.Point]::new(305, 152)
$addCustomerLink.Size = [System.Drawing.Size]::new(120, 20)
$addCustomerLink.TextAlign = 'MiddleRight'
$form.Controls.Add($addCustomerLink)

$deleteCustomerLink = New-Object System.Windows.Forms.LinkLabel
$deleteCustomerLink.Text = 'Delete customer...'
$deleteCustomerLink.Location = [System.Drawing.Point]::new(435, 152)
$deleteCustomerLink.Size = [System.Drawing.Size]::new(130, 20)
$deleteCustomerLink.TextAlign = 'MiddleRight'
$form.Controls.Add($deleteCustomerLink)

$settingsLink = New-Object System.Windows.Forms.LinkLabel
$settingsLink.Text = 'Open settings file'
$settingsLink.Location = [System.Drawing.Point]::new(575, 152)
$settingsLink.Size = [System.Drawing.Size]::new(140, 20)
$settingsLink.TextAlign = 'MiddleRight'
$form.Controls.Add($settingsLink)

$indexLabel = New-Object System.Windows.Forms.Label
$indexLabel.Text = 'DevBox Number'
$indexLabel.Location = [System.Drawing.Point]::new(20, 88)
$indexLabel.Size = [System.Drawing.Size]::new(110, 22)
$form.Controls.Add($indexLabel)

$devBoxNumber = New-Object System.Windows.Forms.NumericUpDown
$devBoxNumber.Minimum = 1
$devBoxNumber.Maximum = 99
$devBoxNumber.Value = $ProfileDefaults.DevBoxNumber
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
$startVmButton.Location = [System.Drawing.Point]::new(215, 85)
$startVmButton.Size = [System.Drawing.Size]::new(75, 26)
$form.Controls.Add($startVmButton)

$stopVmButton = New-Object System.Windows.Forms.Button
$stopVmButton.Text = 'Stop VM...'
$stopVmButton.Location = [System.Drawing.Point]::new(296, 85)
$stopVmButton.Size = [System.Drawing.Size]::new(75, 26)
$stopVmButton.ForeColor = [System.Drawing.Color]::DarkRed
$form.Controls.Add($stopVmButton)

$statusVmButton = New-Object System.Windows.Forms.Button
$statusVmButton.Text = 'Check status'
$statusVmButton.Location = [System.Drawing.Point]::new(377, 85)
$statusVmButton.Size = [System.Drawing.Size]::new(92, 26)
$form.Controls.Add($statusVmButton)

$disconnect = New-Object System.Windows.Forms.Button
$disconnect.Text = 'Cancel'
$disconnect.Location = [System.Drawing.Point]::new(479, 82)
$disconnect.Size = [System.Drawing.Size]::new(106, 32)
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
$advancedPanel.Size = [System.Drawing.Size]::new(735, 344)
$advancedPanel.Visible = $false
$form.Controls.Add($advancedPanel)

$fields = @(
    @('Tenant ID', ''),
    @('Subscription ID', ''),
    @('VM Resource Group', ''),
    @('VM Name', ''),
    @('Bastion Resource Group', ''),
    @('Bastion Name', ''),
    @('Key Vault Name', ''),
    @('Password Secret Name', ''),
    @('VM Username', $ProfileDefaults.VmUsername),
    @('Local Port', "$($ProfileDefaults.LocalPort)")
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

function Update-FormLayout {
    $top = if ($advancedToggle.Checked) { $advancedPanel.Bottom + 6 } else { 180 }
    $status.Location = [System.Drawing.Point]::new(20, $top)
    $log.Location = [System.Drawing.Point]::new(20, ($top + 28))
    $form.ClientSize = [System.Drawing.Size]::new($form.ClientSize.Width, ($log.Bottom + 15))
}

$devBoxNumber.Add_ValueChanged({ Update-TargetNames })
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

function Set-ProfileToForm {
    param([System.Collections.IDictionary]$CustomerProfile)
    $script:VmNameFormat = $CustomerProfile.VmNameFormat
    $script:SecretNameFormat = $CustomerProfile.SecretNameFormat
    foreach ($label in $ProfileFieldMap.Keys) {
        $textboxes[$label].Text = "$($CustomerProfile[$ProfileFieldMap[$label]])"
    }
    $devBoxNumber.Value = $CustomerProfile.DevBoxNumber
    Update-TargetNames
    $form.Text = "$AppTitle - $($CustomerProfile.Name)"
}

function Get-SelectedCustomer {
    if ($customerBox.SelectedIndex -lt 0 -or $customerBox.SelectedIndex -ge @($script:Customers).Count) { return $null }
    $script:Customers[$customerBox.SelectedIndex]
}

# Controls that need a customer stay disabled until one exists.
function Update-CustomerControls {
    $hasCustomer = $null -ne (Get-SelectedCustomer)
    foreach ($textbox in $textboxes.Values) { $textbox.Enabled = $hasCustomer }
    foreach ($control in @($devBoxNumber, $btn, $startVmButton, $stopVmButton, $statusVmButton,
            $customerBox, $deleteCustomerLink, $settingsLink)) { $control.Enabled = $hasCustomer }
    $addCustomerLink.Enabled = $true
}

function Update-CustomerList {
    param([string]$Select)
    $script:UpdatingCustomers = $true
    try {
        $customerBox.Items.Clear()
        foreach ($customer in $script:Customers) { [void]$customerBox.Items.Add($customer.Name) }
        if ($customerBox.Items.Count) {
            $customerBox.SelectedIndex = [Math]::Max(0, $customerBox.FindStringExact($Select))
        }
    }
    finally { $script:UpdatingCustomers = $false }
    $customer = Get-SelectedCustomer
    if ($customer) { Set-ProfileToForm $customer }
    else {
        foreach ($label in $ProfileFieldMap.Keys) { $textboxes[$label].Text = "$($ProfileDefaults[$ProfileFieldMap[$label]])" }
        $form.Text = "$AppTitle - no customer"
    }
    Update-CustomerControls
}

function Get-SettingsStamp {
    if (-not (Test-Path -LiteralPath $CustomersRoot)) { return '' }
    @(Get-ChildItem -LiteralPath $CustomersRoot -Directory | ForEach-Object {
        $file = Join-Path $_.FullName 'settings.json'
        if (Test-Path -LiteralPath $file) { "$file|$((Get-Item -LiteralPath $file).LastWriteTimeUtc.Ticks)" }
    }) -join ';'
}

function Save-CustomerSelection {
    try { Write-JsonFile $AppStatePath ([ordered]@{ SelectedCustomer = "$($customerBox.SelectedItem)" }) }
    catch { Write-Log "Could not remember the selected customer: $($_.Exception.Message)" ([System.Drawing.Color]::Orange) }
}

function Import-CustomerProfiles {
    param([string]$Select, [switch]$Reload)
    if (-not $Select -and $customerBox.SelectedItem) { $Select = "$($customerBox.SelectedItem)" }
    if (-not $Select -and (Test-Path -LiteralPath $AppStatePath)) {
        try { $Select = "$((ConvertFrom-Json ([IO.File]::ReadAllText($AppStatePath))).SelectedCustomer)" } catch { }
    }
    try {
        $loaded = Read-CustomerProfiles $CustomersRoot $ProfileDefaults
        foreach ($problem in $loaded.Errors) {
            Write-Log "Skipped customer settings $problem" ([System.Drawing.Color]::Orange)
        }
        $script:Customers = @($loaded.Customers)
        if ($Reload) { Write-Log 'Customer settings changed on disk; reloaded.' }
    }
    catch {
        Write-Log "Could not load customer settings: $($_.Exception.Message)" ([System.Drawing.Color]::Tomato)
    }
    if (-not $script:Customers) { $script:Customers = @() }
    $script:SettingsStamp = Get-SettingsStamp
    Update-CustomerList $Select
    if (-not $script:Customers.Count) {
        Write-Log "No customer configured yet. Click 'Add customer...' to create one (settings folder: $CustomersRoot)." ([System.Drawing.Color]::Gold)
    }
}

function Show-AddCustomerDialog {
    param([System.Collections.IDictionary]$Template)
    $dialog = New-Object System.Windows.Forms.Form
    $dialog.Text = 'Add customer'
    $dialog.ClientSize = [System.Drawing.Size]::new(540, 520)
    $dialog.FormBorderStyle = 'FixedDialog'
    $dialog.MaximizeBox = $false
    $dialog.MinimizeBox = $false
    $dialog.StartPosition = 'CenterParent'
    $dialog.Font = $form.Font

    $tabs = New-Object System.Windows.Forms.TabControl
    $tabs.Location = [System.Drawing.Point]::new(12, 12)
    $tabs.Size = [System.Drawing.Size]::new(516, 450)
    $dialog.Controls.Add($tabs)
    $fieldTab = New-Object System.Windows.Forms.TabPage 'Fill in fields'
    $jsonTab = New-Object System.Windows.Forms.TabPage 'Paste JSON'
    $tabs.TabPages.AddRange(@($fieldTab, $jsonTab))

    $templateValues = [ordered]@{}
    foreach ($key in $Template.Keys) { if ($key -ne 'SettingsPath') { $templateValues[$key] = $Template[$key] } }
    $templateValues['Name'] = ''
    $inputs = [ordered]@{}
    $y = 12
    foreach ($key in $templateValues.Keys) {
        $label = New-Object System.Windows.Forms.Label
        $label.Text = $key
        $label.Location = [System.Drawing.Point]::new(10, ($y + 4))
        $label.Size = [System.Drawing.Size]::new(150, 22)
        $fieldTab.Controls.Add($label)
        $input = New-Object System.Windows.Forms.TextBox
        $input.Text = "$($templateValues[$key])"
        $input.Location = [System.Drawing.Point]::new(165, $y)
        $input.Size = [System.Drawing.Size]::new(325, 24)
        $fieldTab.Controls.Add($input)
        $inputs[$key] = $input
        $y += 33
    }

    $jsonHint = New-Object System.Windows.Forms.Label
    $jsonHint.Text = 'Paste one JSON object. Values you leave out use the built-in defaults.'
    $jsonHint.Location = [System.Drawing.Point]::new(10, 10)
    $jsonHint.Size = [System.Drawing.Size]::new(480, 20)
    $jsonTab.Controls.Add($jsonHint)
    $jsonBox = New-Object System.Windows.Forms.TextBox
    $jsonBox.Multiline = $true
    $jsonBox.AcceptsReturn = $true
    $jsonBox.ScrollBars = 'Both'
    $jsonBox.WordWrap = $false
    $jsonBox.Font = [System.Drawing.Font]::new('Consolas', 9)
    $jsonBox.Location = [System.Drawing.Point]::new(10, 34)
    $jsonBox.Size = [System.Drawing.Size]::new(485, 375)
    $jsonBox.Text = (ConvertTo-Json -InputObject $templateValues) -replace "`r?`n", "`r`n"
    $jsonTab.Controls.Add($jsonBox)

    $create = New-Object System.Windows.Forms.Button
    $create.Text = 'Create customer'
    $create.Location = [System.Drawing.Point]::new(298, 476)
    $create.Size = [System.Drawing.Size]::new(120, 32)
    $dialog.Controls.Add($create)
    $cancel = New-Object System.Windows.Forms.Button
    $cancel.Text = 'Cancel'
    $cancel.DialogResult = 'Cancel'
    $cancel.Location = [System.Drawing.Point]::new(428, 476)
    $cancel.Size = [System.Drawing.Size]::new(100, 32)
    $dialog.Controls.Add($cancel)
    $dialog.CancelButton = $cancel

    $result = @{}
    $create.Add_Click({
        try {
            if ($tabs.SelectedTab -eq $jsonTab) {
                try { $source = ConvertFrom-Json -InputObject $jsonBox.Text -ErrorAction Stop }
                catch { throw "The JSON is not valid: $($_.Exception.Message)" }
                if ($source -isnot [System.Management.Automation.PSCustomObject]) { throw 'Paste one JSON object { ... }.' }
            }
            else {
                $source = @{}
                foreach ($key in $inputs.Keys) { $source[$key] = $inputs[$key].Text }
            }
            $candidate = ConvertTo-CustomerProfile $source $ProfileDefaults
            Test-CustomerProfile $candidate
            $result.Path = New-CustomerProfileFile $CustomersRoot $candidate $script:Customers
            $script:SettingsStamp = Get-SettingsStamp
            $result.Name = $candidate.Name
            $dialog.DialogResult = 'OK'
        }
        catch {
            [void][System.Windows.Forms.MessageBox]::Show($dialog, $_.Exception.Message, 'Add customer',
                'OK', 'Warning')
        }
    })
    try {
        if ($dialog.ShowDialog($form) -eq 'OK') { return [pscustomobject]$result }
    }
    finally { $dialog.Dispose() }
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

function ConvertTo-AzArgument {
    param([string]$Value)
    if ($Value -match '^[\w.:/=@-]+$') { return $Value }
    '"' + ($Value -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"'
}

function Invoke-AzRaw {
    param([string[]]$Arguments)
    # A hidden child process keeps the compiled no-console EXE from flashing console windows.
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = "$env:SystemRoot\System32\cmd.exe"
    $azArguments = ($Arguments | ForEach-Object { ConvertTo-AzArgument $_ }) -join ' '
    $startInfo.Arguments = "/d /s /c `"`"$script:AzCommand`" $azArguments`""
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.StandardOutputEncoding = [Text.Encoding]::UTF8
    $startInfo.StandardErrorEncoding = [Text.Encoding]::UTF8
    $startInfo.EnvironmentVariables['PYTHONIOENCODING'] = 'utf-8'
    $process = [Diagnostics.Process]::Start($startInfo)
    try {
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        while (-not $process.WaitForExit(100)) { [System.Windows.Forms.Application]::DoEvents() }
        $process.WaitForExit()
        $output = @($stdout.Result, $stderr.Result | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        [pscustomobject]@{
            ExitCode = $process.ExitCode
            Output = ($output | ForEach-Object { $_.TrimEnd() }) -join "`n"
        }
    }
    finally { $process.Dispose() }
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

function Get-AutoShutdownSchedule {
    param($Settings)
    $id = "/subscriptions/$($Settings.SubscriptionId)/resourceGroups/$($Settings.VmResourceGroup)" +
        "/providers/Microsoft.DevTestLab/schedules/shutdown-computevm-$($Settings.VmName)"
    $result = Invoke-AzRaw @('resource', 'show', '--ids', $id, '--only-show-errors', '--output', 'json')
    if ($result.ExitCode -ne 0) {
        if ($result.Output -match 'ResourceNotFound|NotFound|was not found|could not be found') { return $null }
        throw "Could not read the auto-shutdown schedule: $($result.Output)"
    }
    ConvertFrom-Json -InputObject $result.Output
}

function Format-AutoShutdown {
    param($Schedule, [DateTime]$UtcNow = [DateTime]::UtcNow)
    if (-not $Schedule) { return 'not configured' }
    $properties = $Schedule.properties
    $time = "$($properties.dailyRecurrence.time)"
    if ($time -notmatch '^(\d{2}):?(\d{2})$') { return "$($properties.status), time '$time' ($($properties.timeZoneId))" }
    $hours = [int]$Matches[1]
    $minutes = [int]$Matches[2]
    $text = "$($properties.status), daily at {0:D2}:{1:D2} ($($properties.timeZoneId))" -f $hours, $minutes
    if ($properties.status -eq 'Enabled') {
        try {
            $zone = [TimeZoneInfo]::FindSystemTimeZoneById($properties.timeZoneId)
            $now = [TimeZoneInfo]::ConvertTimeFromUtc($UtcNow, $zone)
            $next = $now.Date.AddHours($hours).AddMinutes($minutes)
            if ($next -le $now) { $next = $next.AddDays(1) }
            $left = $next - $now
            $text += " - next shutdown in $([int][Math]::Floor($left.TotalHours))h $($left.Minutes)m"
        }
        catch { }
    }
    if ($properties.notificationSettings.status -eq 'Enabled') {
        $text += ", notification $($properties.notificationSettings.timeInMinutes) min before"
    }
    $text
}

function ConvertFrom-QuserOutput {
    param([string]$Text)
    foreach ($line in ($Text -split "`r?`n")) {
        if ($line -match '^\s*>?(?<user>\S+)\s+(?:(?<session>\S+)\s+)?(?<id>\d+)\s+(?<state>\S+)\s+(?<idle>\S+)\s+(?<logon>\S.*?)\s*$') {
            [pscustomobject]@{
                User = $Matches.user
                State = $Matches.state
                Idle = if ($Matches.idle -in @('.', 'none', 'Kein', 'Keine')) { 'none' } else { $Matches.idle }
                LogonTime = $Matches.logon
            }
        }
    }
}

function Get-VmSignedInUsers {
    param($Settings)
    $message = Invoke-Az @('vm', 'run-command', 'invoke', '--resource-group', $Settings.VmResourceGroup,
        '--name', $Settings.VmName, '--subscription', $Settings.SubscriptionId,
        '--command-id', 'RunPowerShellScript', '--scripts', 'quser', '--query', 'value[0].message')
    @(ConvertFrom-QuserOutput "$message")
}

function Invoke-VmStatusCheck {
    $script:CancelRequested = $false
    Set-UiBusy $true
    try {
        $settings = Get-FormSettings
        Write-Log "Status check for $($settings.VmName)." ([System.Drawing.Color]::LightGreen)
        Initialize-AzureSession $settings
        $status.Text = 'Checking VM...'
        $vm = Invoke-Az (Get-VmInstanceArgs $settings)
        $state = (Get-VmPowerState $vm) -replace '^PowerState/', ''
        $running = $state -eq 'running'
        $stateColor = if ($running) { [System.Drawing.Color]::LightGreen } else { [System.Drawing.Color]::Gold }
        Write-Log "Power state: $state" $stateColor

        Assert-NotCancelled
        $status.Text = 'Reading auto-shutdown...'
        try { Write-Log "Auto-shutdown: $(Format-AutoShutdown (Get-AutoShutdownSchedule $settings))" }
        catch { Write-Log $_.Exception.Message ([System.Drawing.Color]::Orange) }

        Assert-NotCancelled
        if ($running) {
            $status.Text = 'Checking signed-in users (can take up to 1 minute)...'
            Write-Log 'Checking signed-in users on the VM (Run Command, can take up to 1 minute)...'
            try {
                $users = Get-VmSignedInUsers $settings
                if (-not $users.Count) {
                    Write-Log 'Nobody is signed in to the VM.' ([System.Drawing.Color]::LightGreen)
                }
                foreach ($user in $users) {
                    $userColor = if ($user.State -match '^(Active|Aktiv)') { [System.Drawing.Color]::Gold } else { [System.Drawing.Color]::Gainsboro }
                    Write-Log "Signed in: $($user.User) - $($user.State), idle $($user.Idle), since $($user.LogonTime)" $userColor
                }
                if (@($users | Where-Object { $_.State -match '^(Active|Aktiv)' }).Count) {
                    Write-Log 'Someone has an active session on this VM - check before stopping it.' ([System.Drawing.Color]::Gold)
                }
                elseif ($users.Count) {
                    Write-Log 'Only disconnected sessions - unsaved work may still be open.' ([System.Drawing.Color]::Gold)
                }
            }
            catch {
                Write-Log "Could not check signed-in users (needs Run Command permission on the VM): $($_.Exception.Message)" ([System.Drawing.Color]::Orange)
            }
        }
        else { Write-Log 'Nobody can be signed in while the VM is not running.' }
        $status.Text = 'Ready'
    }
    catch [OperationCanceledException] {
        $status.Text = 'Ready'
        Write-Log 'Status check cancelled.' ([System.Drawing.Color]::Gold)
    }
    catch {
        $status.Text = 'Error'
        Write-Log $_.Exception.Message ([System.Drawing.Color]::Salmon)
    }
    finally { Set-UiBusy $false }
}

function Set-UiBusy {
    param([bool]$Busy, [string]$CancelText = 'Cancel')
    foreach ($textbox in $textboxes.Values) { $textbox.Enabled = -not $Busy }
    foreach ($control in @($devBoxNumber, $btn, $startVmButton, $stopVmButton, $statusVmButton,
            $customerBox, $addCustomerLink, $deleteCustomerLink, $settingsLink)) { $control.Enabled = -not $Busy }
    $disconnect.Enabled = $Busy
    $disconnect.Text = if ($Busy) { $CancelText } else { 'Cancel' }
    if (-not $Busy) { Update-CustomerControls }
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
$statusVmButton.Add_Click({ Invoke-VmStatusCheck })

$customerBox.Add_SelectedIndexChanged({
    if ($script:UpdatingCustomers) { return }
    $customer = Get-SelectedCustomer
    if (-not $customer) { return }
    Set-ProfileToForm $customer
    Save-CustomerSelection
    Write-Log "Customer: $($customerBox.SelectedItem)"
})
function Invoke-AddCustomer {
    $template = Get-SelectedCustomer
    if (-not $template) { $template = $ProfileDefaults }
    $created = Show-AddCustomerDialog $template
    if ($created) {
        Write-Log "Created customer '$($created.Name)': $($created.Path)" ([System.Drawing.Color]::LightGreen)
        Import-CustomerProfiles -Select $created.Name
        Save-CustomerSelection
    }
}
$addCustomerLink.Add_LinkClicked({ Invoke-AddCustomer })
$deleteCustomerLink.Add_LinkClicked({
    $customer = Get-SelectedCustomer
    if (-not $customer) { return }
    if (-not $customer.Contains('SettingsPath')) {
        Write-Log 'This customer has no settings file to delete.' ([System.Drawing.Color]::Orange)
        return
    }
    $answer = [System.Windows.Forms.MessageBox]::Show($form,
        "Delete customer '$($customer.Name)'?`r`n`r`nThis permanently deletes:`r`n$($customer.SettingsPath)`r`n`r`nAzure resources are not affected.",
        'Delete customer', 'YesNo', 'Warning', 'Button2')
    if ($answer -ne 'Yes') { return }
    try {
        $removed = Remove-CustomerProfileFile $CustomersRoot $customer
        Write-Log "Deleted customer '$($customer.Name)': $removed" ([System.Drawing.Color]::LightGreen)
    }
    catch {
        Write-Log "Could not delete customer '$($customer.Name)': $($_.Exception.Message)" ([System.Drawing.Color]::Tomato)
        return
    }
    Import-CustomerProfiles
    Save-CustomerSelection
})
$settingsLink.Add_LinkClicked({
    $customer = Get-SelectedCustomer
    if (-not $customer) { return }
    if (-not $customer.Contains('SettingsPath')) {
        Write-Log 'This customer has no settings file (the settings folder could not be written).' ([System.Drawing.Color]::Orange)
        return
    }
    try { Start-Process -FilePath $customer.SettingsPath -ErrorAction Stop }
    catch { Start-Process -FilePath "$env:SystemRoot\System32\notepad.exe" -ArgumentList "`"$($customer.SettingsPath)`"" }
    Write-Log "Opened $($customer.SettingsPath). Saved changes are loaded when you return to this window."
})
# The add link is only disabled while an operation runs, so it doubles as the "not busy" flag.
$form.Add_Activated({
    if ($addCustomerLink.Enabled -and (Get-SettingsStamp) -ne $script:SettingsStamp) {
        $script:SettingsStamp = Get-SettingsStamp
        Import-CustomerProfiles -Reload
    }
})
$form.Add_Shown({ if (-not $script:Customers.Count) { Invoke-AddCustomer } })
Import-CustomerProfiles

try { [void]$form.ShowDialog() }
finally { $form.Dispose() }
