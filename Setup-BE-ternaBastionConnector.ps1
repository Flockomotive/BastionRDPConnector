<#
.SYNOPSIS
Installs BE-ternaBastionConnector for the current user (no admin rights needed).
.DESCRIPTION
- Creates %APPDATA%\BE-ternaBastionConnector (app files) with a Customers subfolder (settings).
- Copies BE-ternaBastionConnector.ps1 and the icon from this folder into it.
- Moves customers from the old %APPDATA%\BastionRDPConnector folder, if present.
- Installs Azure CLI for the current user if missing and adds the Bastion extension.
- Creates Desktop and Start Menu shortcuts.
Run again to update; customers are kept.
Run with: powershell -NoProfile -ExecutionPolicy Bypass -File .\Setup-BE-ternaBastionConnector.ps1
Remove with: ... -File .\Setup-BE-ternaBastionConnector.ps1 -Uninstall
#>
[CmdletBinding()]
param(
    [switch]$SkipAzureCli,
    [switch]$Uninstall
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$AppName = 'BE-ternaBastionConnector'
$InstallRoot = Join-Path $env:APPDATA 'BE-ternaBastionConnector'
$LegacyRoot = Join-Path $env:APPDATA 'BastionRDPConnector'
$CliRoot = Join-Path $env:LOCALAPPDATA 'Programs\AzureCLI'
$CliUrl = 'https://aka.ms/installazurecliwindowszipx64'
$PowerShellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$Shortcuts = @(
    (Join-Path ([Environment]::GetFolderPath('Desktop')) "$AppName.lnk"),
    (Join-Path ([Environment]::GetFolderPath('Programs')) "$AppName.lnk")
)

function Write-Step([string]$Text) { Write-Host "==> $Text" -ForegroundColor Cyan }

if ($Uninstall) {
    foreach ($path in $Shortcuts) { if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force } }
    foreach ($file in @('BE-ternaBastionConnector.ps1', 'BE-ternaBastionConnector.ico')) {
        $path = Join-Path $InstallRoot $file
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
    }
    Write-Host "Removed shortcuts and app files. Customer settings were kept in $InstallRoot." -ForegroundColor Green
    Write-Host 'Azure CLI was not removed.'
    return
}

$source = Join-Path $PSScriptRoot 'BE-ternaBastionConnector.ps1'
if (-not (Test-Path -LiteralPath $source)) { throw "BE-ternaBastionConnector.ps1 was not found next to the setup script ($PSScriptRoot)." }

Write-Step "Creating $InstallRoot"
$customersRoot = Join-Path $InstallRoot 'Customers'
New-Item -ItemType Directory -Force -Path $customersRoot | Out-Null

$legacyCustomers = Join-Path $LegacyRoot 'Customers'
if ((Test-Path -LiteralPath $legacyCustomers) -and -not @(Get-ChildItem -LiteralPath $customersRoot -Directory).Count) {
    Write-Step "Moving customers from $LegacyRoot"
    Get-ChildItem -LiteralPath $legacyCustomers -Directory | Copy-Item -Destination $customersRoot -Recurse -Force
    $legacyState = Join-Path $LegacyRoot 'app.json'
    if (Test-Path -LiteralPath $legacyState) { Copy-Item -LiteralPath $legacyState -Destination $InstallRoot -Force }
    Remove-Item -LiteralPath $LegacyRoot -Recurse -Force
}

Write-Step 'Copying app files'
$target = Join-Path $InstallRoot 'BE-ternaBastionConnector.ps1'
Copy-Item -LiteralPath $source -Destination $target -Force
$icon = $null
$iconSource = Join-Path $PSScriptRoot 'BE-ternaBastionConnector.ico'
if (Test-Path -LiteralPath $iconSource) {
    $icon = Join-Path $InstallRoot 'BE-ternaBastionConnector.ico'
    Copy-Item -LiteralPath $iconSource -Destination $icon -Force
}
# Files from downloads or Teams carry a Mark of the Web that blocks execution.
Get-ChildItem -LiteralPath $InstallRoot -File | Unblock-File

if (-not $SkipAzureCli) {
    Write-Step 'Checking Azure CLI'
    $az = Get-Command az.cmd -CommandType Application -All -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty Source
    if (-not $az -and (Test-Path -LiteralPath $CliRoot)) {
        $az = Get-ChildItem -LiteralPath $CliRoot -Filter az.cmd -Recurse | Select-Object -First 1 -ExpandProperty FullName
    }
    if (-not $az) {
        Write-Step "Installing Azure CLI to $CliRoot (download about 100 MB)"
        $zip = Join-Path $env:TEMP ("AzureCLI-$([guid]::NewGuid()).zip")
        New-Item -ItemType Directory -Force -Path $CliRoot | Out-Null
        try {
            [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
            Invoke-WebRequest -Uri $CliUrl -OutFile $zip -UseBasicParsing
            Expand-Archive -LiteralPath $zip -DestinationPath $CliRoot -Force
        }
        finally {
            if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }
        }
        $az = Get-ChildItem -LiteralPath $CliRoot -Filter az.cmd -Recurse | Select-Object -First 1 -ExpandProperty FullName
        if (-not $az) { throw 'Azure CLI was downloaded, but az.cmd was not found.' }
    }
    Write-Host "    Azure CLI: $az"

    $extensions = (& $az extension list --only-show-errors -o json) -join "`n" | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0) { throw 'az extension list failed.' }
    if (-not ($extensions | Where-Object { $_.name -eq 'bastion' })) {
        Write-Step 'Installing Azure CLI Bastion extension'
        & $az extension add --name bastion --only-show-errors
        if ($LASTEXITCODE -ne 0) { throw 'Installing the Bastion extension failed.' }
    }
    else { Write-Host '    Bastion extension found.' }
}

Write-Step 'Creating Desktop and Start Menu shortcuts'
$shell = New-Object -ComObject WScript.Shell
foreach ($path in $Shortcuts) {
    $shortcut = $shell.CreateShortcut($path)
    $shortcut.TargetPath = $PowerShellExe
    $shortcut.Arguments = "-NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$target`""
    $shortcut.WorkingDirectory = $InstallRoot
    $shortcut.Description = 'Connects to D365 DevBox VMs through Azure Bastion'
    $shortcut.WindowStyle = 7
    if ($icon) { $shortcut.IconLocation = "$icon,0" }
    $shortcut.Save()
    Write-Host "    $path"
}

Write-Host "`n$AppName installed to $InstallRoot. Start it from the Desktop shortcut." -ForegroundColor Green
