# Builds BastionRDPConnector.exe from BastionRDPConnector.ps1 with PS2EXE.
# Run with: powershell -NoProfile -ExecutionPolicy Bypass -File .\Build-Exe.ps1
[CmdletBinding()]
param([string]$Version = '1.0.0.0')

$ErrorActionPreference = 'Stop'
if (-not (Get-Module -ListAvailable ps2exe)) {
    Install-Module ps2exe -Scope CurrentUser -Force
}
Import-Module ps2exe

$source = Join-Path $PSScriptRoot 'BastionRDPConnector.ps1'
$icon = Join-Path $PSScriptRoot 'BastionRDPConnector.ico'

# One EXE per customer: the name comes from $CustomerName in the script defaults.
$customerMatch = Select-String -Path $source -Pattern "^\`$CustomerName\s*=\s*'([^']*)'" | Select-Object -First 1
if (-not $customerMatch) { throw "Could not find `$CustomerName = '...' in $source." }
$customer = $customerMatch.Matches[0].Groups[1].Value
$safeCustomer = ($customer -replace '[^\w.-]', '_').Trim('_')
$exeName = if ($safeCustomer) { "BastionRDPConnector-$safeCustomer.exe" } else { 'BastionRDPConnector.exe' }
$output = Join-Path $PSScriptRoot $exeName

if (-not (Test-Path $icon)) {
    Add-Type -AssemblyName System.Drawing
    $bitmap = New-Object System.Drawing.Bitmap 64, 64
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    $graphics.SmoothingMode = 'AntiAlias'
    $graphics.TextRenderingHint = 'AntiAliasGridFit'
    $graphics.Clear([System.Drawing.Color]::Transparent)
    $brush = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(0, 84, 147))
    $graphics.FillRectangle($brush, 2, 2, 60, 60)
    $font = New-Object System.Drawing.Font 'Segoe UI', 17, ([System.Drawing.FontStyle]::Bold), ([System.Drawing.GraphicsUnit]::Pixel)
    $format = New-Object System.Drawing.StringFormat
    $format.Alignment = 'Center'
    $format.LineAlignment = 'Center'
    $graphics.DrawString('RDP', $font, [System.Drawing.Brushes]::White, (New-Object System.Drawing.RectangleF 0, 0, 64, 64), $format)
    $graphics.Dispose()
    $png = New-Object System.IO.MemoryStream
    $bitmap.Save($png, [System.Drawing.Imaging.ImageFormat]::Png)
    $bitmap.Dispose()
    # ICO container holding one 64x64 PNG image.
    $file = [System.IO.File]::Create($icon)
    $writer = New-Object System.IO.BinaryWriter $file
    $writer.Write([uint16]0); $writer.Write([uint16]1); $writer.Write([uint16]1)
    $writer.Write([byte]64); $writer.Write([byte]64); $writer.Write([byte]0); $writer.Write([byte]0)
    $writer.Write([uint16]1); $writer.Write([uint16]32)
    $writer.Write([uint32]$png.Length); $writer.Write([uint32]22)
    $writer.Write($png.ToArray())
    $writer.Dispose()
    $png.Dispose()
}

Invoke-PS2EXE -inputFile $source -outputFile $output -iconFile $icon `
    -noConsole -STA -x64 -DPIAware `
    -title 'BE-terna Bastion RDP Connector' -description 'Connects to D365 DevBox VMs through Azure Bastion' `
    -company 'BE-terna' -product "Bastion RDP Connector - $customer" -version $Version
if (-not (Test-Path $output)) { throw 'PS2EXE did not create the EXE.' }
Get-Item $output
