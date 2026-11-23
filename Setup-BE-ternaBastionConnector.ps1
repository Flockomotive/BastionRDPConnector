<#
.SYNOPSIS
Installs BE-ternaBastionConnector for the current user (no admin rights needed).
.DESCRIPTION
- Creates %APPDATA%\BE-ternaBastionConnector (app files) with a Customers subfolder (settings).
- Moves customers from the old %APPDATA%\BastionRDPConnector folder, if present.
- Installs Azure CLI for the current user if missing and adds the Bastion extension.
- Creates Desktop and Start Menu shortcuts to %APPDATA%\BE-ternaBastionConnector\BE-ternaBastionConnector.ps1.
- Opens the folder at the end: copy BE-ternaBastionConnector.ps1 (and the .ico) into it manually.
  Run setup again after copying the .ico to show it on the shortcuts.
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

function Wait-BeforeClose {
    try { Read-Host "`nPress Enter to close this window" | Out-Null }
    catch { }
}

function Write-Step([string]$Text) { Write-Host "==> $Text" -ForegroundColor Cyan }

try {
$AppName = 'BE-ternaBastionConnector'
$AppDataRoot = [Environment]::GetFolderPath([Environment+SpecialFolder]::ApplicationData)
if ([string]::IsNullOrWhiteSpace($AppDataRoot)) { $AppDataRoot = $env:APPDATA }
if ([string]::IsNullOrWhiteSpace($AppDataRoot) -and $env:USERPROFILE) {
    $AppDataRoot = Join-Path $env:USERPROFILE 'AppData\Roaming'
}
if ([string]::IsNullOrWhiteSpace($AppDataRoot)) { throw 'Could not determine the current user AppData folder.' }

$LocalAppDataRoot = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
if ([string]::IsNullOrWhiteSpace($LocalAppDataRoot)) { $LocalAppDataRoot = $env:LOCALAPPDATA }
if ([string]::IsNullOrWhiteSpace($LocalAppDataRoot) -and $env:USERPROFILE) {
    $LocalAppDataRoot = Join-Path $env:USERPROFILE 'AppData\Local'
}
if ([string]::IsNullOrWhiteSpace($LocalAppDataRoot)) { throw 'Could not determine the current user Local AppData folder.' }

$InstallRoot = Join-Path $AppDataRoot 'BE-ternaBastionConnector'
$LegacyRoot = Join-Path $AppDataRoot 'BastionRDPConnector'
$CliRoot = Join-Path $LocalAppDataRoot 'Programs\AzureCLI'
$CliUrl = 'https://aka.ms/installazurecliwindowszipx64'
$WindowsRoot = $env:SystemRoot
if ([string]::IsNullOrWhiteSpace($WindowsRoot)) { $WindowsRoot = $env:windir }
if ([string]::IsNullOrWhiteSpace($WindowsRoot)) { throw 'Could not determine the Windows folder.' }
$PowerShellExe = Join-Path $WindowsRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

$DesktopRoot = [Environment]::GetFolderPath([Environment+SpecialFolder]::DesktopDirectory)
if ([string]::IsNullOrWhiteSpace($DesktopRoot) -and $env:USERPROFILE) {
    $DesktopRoot = Join-Path $env:USERPROFILE 'Desktop'
}
$ProgramsRoot = [Environment]::GetFolderPath([Environment+SpecialFolder]::Programs)
if ([string]::IsNullOrWhiteSpace($ProgramsRoot)) {
    $ProgramsRoot = Join-Path $AppDataRoot 'Microsoft\Windows\Start Menu\Programs'
}
if ([string]::IsNullOrWhiteSpace($DesktopRoot)) { throw 'Could not determine the current user Desktop folder.' }

$Shortcuts = @(
    (Join-Path $DesktopRoot "$AppName.lnk"),
    (Join-Path $ProgramsRoot "$AppName.lnk")
)

if ($Uninstall) {
    foreach ($path in $Shortcuts) { if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force } }
    foreach ($file in @('BE-ternaBastionConnector.ps1', 'BE-ternaBastionConnector.ico')) {
        $path = Join-Path $InstallRoot $file
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
    }
    Write-Host "Removed shortcuts and app files. Customer settings were kept in $InstallRoot." -ForegroundColor Green
    Write-Host 'Azure CLI was not removed.'
} else {

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

$target = Join-Path $InstallRoot 'BE-ternaBastionConnector.ps1'
$icon = Join-Path $InstallRoot 'BE-ternaBastionConnector.ico'
if (-not (Test-Path -LiteralPath $icon)) { $icon = $null }

if (-not $SkipAzureCli) {
    Write-Step 'Checking Azure CLI'
    $az = Get-Command az.cmd -CommandType Application -All -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty Source
    if (-not $az -and (Test-Path -LiteralPath $CliRoot)) {
        $az = Get-ChildItem -LiteralPath $CliRoot -Filter az.cmd -Recurse | Select-Object -First 1 -ExpandProperty FullName
    }
    if (-not $az) {
        Write-Step "Installing Azure CLI to $CliRoot (download about 100 MB)"
        $tempRoot = [IO.Path]::GetTempPath()
        if ([string]::IsNullOrWhiteSpace($tempRoot)) { throw 'Could not determine a temporary folder for the Azure CLI download.' }
        $zip = Join-Path $tempRoot ("AzureCLI-$([guid]::NewGuid()).zip")
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

Write-Host "`nSetup finished. Copy BE-ternaBastionConnector.ps1 (and BE-ternaBastionConnector.ico) into the opened folder:" -ForegroundColor Green
Write-Host "    $InstallRoot" -ForegroundColor Green
Write-Host 'Then start it from the Desktop shortcut.' -ForegroundColor Green
Start-Process -FilePath (Join-Path $WindowsRoot 'explorer.exe') -ArgumentList "`"$InstallRoot`""
}
}
catch {
    Write-Host "`nSetup failed: $($_.Exception.Message)" -ForegroundColor Red
}
finally {
    Wait-BeforeClose
}
