# Run with: Invoke-Pester .\BastionRDPConnector.Tests.ps1
# Only function definitions are loaded: no GUI, Azure login, or real secrets.
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile(
    (Join-Path $PSScriptRoot 'BastionRDPConnector.ps1'), [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw ($parseErrors.Message -join "`n") }
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Security
Add-Type -AssemblyName System.Windows.Forms
foreach ($definition in $ast.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst]
}, $false)) {
    . ([scriptblock]::Create($definition.Extent.Text))
}

Describe 'Connection input validation' {
    BeforeEach {
        $values = @{
            'Tenant ID' = '11111111-1111-1111-1111-111111111111'
            'Subscription ID' = '22222222-2222-2222-2222-222222222222'
            'VM Resource Group' = 'rg-vm'
            'VM Name' = 'vm-test'
            'Bastion Resource Group' = 'rg-network'
            'Bastion Name' = 'bas-test'
            'Key Vault Name' = 'kv-test'
            'Password Secret Name' = 'rdp-password'
            'VM Username' = 'DOMAIN\user'
            'Local Port' = '13389'
        }
    }

    It 'preserves separate resource groups and trims configuration' {
        $values['VM Name'] = ' vm-test '
        $settings = Get-ConnectionSettings $values
        $settings.VmName | Should Be 'vm-test'
        $settings.VmResourceGroup | Should Be 'rg-vm'
        $settings.BastionResourceGroup | Should Be 'rg-network'
    }

    It 'rejects missing fields, invalid identifiers, ports and injected RDP settings' {
        foreach ($case in @(
            @('VM Name', ''),
            @('Tenant ID', 'not-a-guid'),
            @('Subscription ID', '00000000-0000-0000-0000-000000000000'),
            @('Bastion Name', 'bas&command'),
            @('Key Vault Name', 'kv--test'),
            @('Password Secret Name', 'bad/secret'),
            @('VM Username', "user`r`nredirectdrives:i:1"),
            @('Local Port', '65536'),
            @('Local Port', '0'),
            @('Local Port', 'not-a-port')
        )) {
            $invalid = $values.Clone()
            $invalid[$case[0]] = $case[1]
            { Get-ConnectionSettings $invalid } | Should Throw
        }
    }
}

Describe 'Azure resource checks' {
    BeforeEach {
        $settings = [pscustomobject]@{
            BastionName = 'bas-test'
            BastionResourceGroup = 'rg-network'
            VmName = 'vm-test'
            VmResourceGroup = 'rg-vm'
            SubscriptionId = '22222222-2222-2222-2222-222222222222'
        }
        $script:bastion = [pscustomobject]@{
            provisioningState = 'Succeeded'
            sku = [pscustomobject]@{ name = 'Standard' }
            enableTunneling = $true
        }
        $script:vm = [pscustomobject]@{
            id = '/subscriptions/test/resourceGroups/rg-vm/providers/Microsoft.Compute/virtualMachines/vm-test'
            provisioningState = 'Succeeded'
            storageProfile = [pscustomobject]@{ osDisk = [pscustomobject]@{ osType = 'Windows' } }
            instanceView = [pscustomobject]@{
                statuses = @([pscustomobject]@{ code = 'PowerState/running' })
            }
        }
        $script:missingVm = $false
        $script:startSucceeds = $true
        $script:pollsUntilRunning = 0
        Mock Write-Log {}
        Mock Wait-WithUi {}
        Mock Invoke-Az {
            param($Arguments)
            if ($Arguments[0] -eq 'network') { return $script:bastion }
            if ($Arguments[1] -eq 'start') {
                if ($script:startSucceeds) {
                    $script:vm.instanceView.statuses = @([pscustomobject]@{ code = 'PowerState/starting' })
                    $script:pollsUntilRunning = 2
                }
                return
            }
            if ($script:missingVm) { throw 'ResourceNotFound: vm-test was not found in rg-vm.' }
            if ($script:pollsUntilRunning -gt 0) {
                $script:pollsUntilRunning--
                if ($script:pollsUntilRunning -eq 0) {
                    $script:vm.instanceView.statuses = @([pscustomobject]@{ code = 'PowerState/running' })
                }
            }
            return $script:vm
        }
    }

    It 'uses the VM ID from Azure without starting a running VM' {
        (Get-CheckedVm $settings).id | Should Be $script:vm.id
        Assert-MockCalled Invoke-Az -Times 1 -Exactly -Scope It -ParameterFilter {
            $Arguments[0] -eq 'network' -and $Arguments -contains 'rg-network'
        }
        Assert-MockCalled Invoke-Az -Times 1 -Exactly -Scope It -ParameterFilter {
            $Arguments[1] -eq 'get-instance-view' -and $Arguments -contains 'rg-vm'
        }
        Assert-MockCalled Invoke-Az -Times 0 -Exactly -Scope It -ParameterFilter { $Arguments[1] -eq 'start' }
    }

    It 'starts a deallocated VM without blocking and polls every interval until running' {
        $script:vm.instanceView.statuses[0].code = 'PowerState/deallocated'
        (Get-CheckedVm $settings).instanceView.statuses[0].code | Should Be 'PowerState/running'
        Assert-MockCalled Invoke-Az -Times 1 -Exactly -Scope It -ParameterFilter {
            $Arguments[1] -eq 'start' -and $Arguments -contains '--no-wait'
        }
        Assert-MockCalled Invoke-Az -Times 3 -Exactly -Scope It -ParameterFilter { $Arguments[1] -eq 'get-instance-view' }
        Assert-MockCalled Wait-WithUi -Times 2 -Exactly -Scope It -ParameterFilter { $Seconds -eq 10 }
        Assert-MockCalled Write-Log -Scope It -ParameterFilter { $Message -like 'Waiting for VM*starting*' }
    }

    It 'waits for an already starting VM without issuing another start' {
        $script:vm.instanceView.statuses[0].code = 'PowerState/starting'
        $script:pollsUntilRunning = 2
        (Get-CheckedVm $settings).instanceView.statuses[0].code | Should Be 'PowerState/running'
        Assert-MockCalled Invoke-Az -Times 0 -Exactly -Scope It -ParameterFilter { $Arguments[1] -eq 'start' }
    }

    It 'times out when the VM never reaches running' {
        $script:vm.instanceView.statuses[0].code = 'PowerState/stopped'
        $script:startSucceeds = $false
        Mock Wait-WithUi { Start-Sleep -Milliseconds 30 }
        { Get-CheckedVm $settings -PollSeconds 0 -StartTimeoutSeconds 0 } | Should Throw 'did not reach running'
    }

    It 'fails when the VM begins shutting down during startup' {
        $script:vm.instanceView.statuses[0].code = 'PowerState/starting'
        Mock Wait-WithUi { $script:vm.instanceView.statuses = @([pscustomobject]@{ code = 'PowerState/deallocating' }) }
        { Get-CheckedVm $settings } | Should Throw 'instead of completing start'
    }

    It 'only-start does not issue a start for an already running VM' {
        Start-VmAndWait -Settings $settings -Vm $script:vm | Should Be $script:vm
        Assert-MockCalled Invoke-Az -Times 0 -Exactly -Scope It
    }


    It 'stops when the specified VM does not exist' {
        $script:missingVm = $true
        { Get-CheckedVm $settings } | Should Throw 'ResourceNotFound'
        Assert-MockCalled Invoke-Az -Times 0 -Exactly -Scope It -ParameterFilter {
            $Arguments[1] -eq 'start' -or $Arguments[0] -eq 'keyvault' -or $Arguments[2] -eq 'tunnel'
        }
    }

    It 'rejects unsupported Bastion configurations before accessing the VM' {
        $script:bastion.sku.name = 'Basic'
        { Get-CheckedVm $settings } | Should Throw 'Standard/Premium'
        $script:bastion.sku.name = 'Premium'
        $script:bastion.enableTunneling = $false
        { Get-CheckedVm $settings } | Should Throw 'Native Client Support'
        $script:bastion.provisioningState = 'Updating'
        { Get-CheckedVm $settings } | Should Throw 'not provisioned'
        Assert-MockCalled Invoke-Az -Times 0 -Exactly -Scope It -ParameterFilter { $Arguments[0] -eq 'vm' }
    }

    It 'rejects Linux, unknown and transitioning VM states without starting them' {
        $script:vm.storageProfile.osDisk.osType = 'Linux'
        { Get-CheckedVm $settings } | Should Throw 'Windows'
        $script:vm.storageProfile.osDisk.osType = 'Windows'
        $script:vm.instanceView.statuses = @()
        { Get-CheckedVm $settings } | Should Throw 'power state'
        $script:vm.instanceView.statuses = @([pscustomobject]@{ code = 'PowerState/deallocating' })
        { Get-CheckedVm $settings } | Should Throw 'transitioning'
        Assert-MockCalled Invoke-Az -Times 0 -Exactly -Scope It -ParameterFilter { $Arguments[1] -eq 'start' }
    }
}

Describe 'VM shutdown safeguards' {
    BeforeEach {
        $settings = [pscustomobject]@{
            VmName = 'vm-test'; VmResourceGroup = 'rg-vm'
            SubscriptionId = '22222222-2222-2222-2222-222222222222'
        }
        $script:vm = [pscustomobject]@{
            instanceView = [pscustomobject]@{ statuses = @([pscustomobject]@{ code = 'PowerState/running' }) }
        }
        $script:pollsUntilDeallocated = 0
        Mock Write-Log {}
        Mock Wait-WithUi {}
        Mock Confirm-VmShutdown { $true }
        Mock Invoke-Az {
            param($Arguments)
            if ($Arguments[1] -eq 'deallocate') { $script:pollsUntilDeallocated = 2; return }
            if ($script:pollsUntilDeallocated -gt 0) {
                $script:pollsUntilDeallocated--
                $code = if ($script:pollsUntilDeallocated -eq 0) { 'PowerState/deallocated' } else { 'PowerState/deallocating' }
                $script:vm.instanceView.statuses = @([pscustomobject]@{ code = $code })
            }
            return $script:vm
        }
    }

    It 'does nothing to the VM when the confirmation is declined' {
        Mock Confirm-VmShutdown { $false }
        { Stop-VmAndWait -Settings $settings -Vm $script:vm } | Should Throw 'Shutdown cancelled'
        Assert-MockCalled Confirm-VmShutdown -Times 1 -Exactly -Scope It -ParameterFilter { $VmName -eq 'vm-test' }
        Assert-MockCalled Invoke-Az -Times 0 -Exactly -Scope It
    }

    It 'deallocates the confirmed VM and polls until it is deallocated' {
        $result = Stop-VmAndWait -Settings $settings -Vm $script:vm
        (Get-VmPowerState $result) | Should Be 'PowerState/deallocated'
        Assert-MockCalled Invoke-Az -Times 1 -Exactly -Scope It -ParameterFilter {
            $Arguments[1] -eq 'deallocate' -and $Arguments -contains '--no-wait' -and $Arguments -contains 'vm-test'
        }
        Assert-MockCalled Wait-WithUi -Times 2 -Exactly -Scope It -ParameterFilter { $Seconds -eq 10 }
    }

    It 'skips confirmation and Azure calls for an already deallocated VM' {
        $script:vm.instanceView.statuses[0].code = 'PowerState/deallocated'
        Stop-VmAndWait -Settings $settings -Vm $script:vm | Out-Null
        Assert-MockCalled Confirm-VmShutdown -Times 0 -Exactly -Scope It
        Assert-MockCalled Invoke-Az -Times 0 -Exactly -Scope It
    }

    It 'refuses transitioning VMs before asking for confirmation' {
        $script:vm.instanceView.statuses[0].code = 'PowerState/starting'
        { Stop-VmAndWait -Settings $settings -Vm $script:vm } | Should Throw 'transitioning'
        Assert-MockCalled Confirm-VmShutdown -Times 0 -Exactly -Scope It
    }

    It 'fails if someone starts the VM while it is shutting down' {
        Mock Wait-WithUi { $script:pollsUntilDeallocated = 0; $script:vm.instanceView.statuses = @([pscustomobject]@{ code = 'PowerState/starting' }) }
        { Stop-VmAndWait -Settings $settings -Vm $script:vm } | Should Throw 'instead of completing shut down'
    }
}

Describe 'Secret handling' {
    It 'stores the password as a session-only credential and removes it again' {
        $target = "TERMSRV/bastion-test-$([guid]::NewGuid())"
        try {
            Set-RdpCredential -Target $target -Username 'DOMAIN\test' -Password "synthetic-`"quote`"&%!"
            [BastionRdpCredential]::ReadUserName($target) | Should Be 'DOMAIN\test'
        }
        finally { Remove-RdpCredential $target }
        [BastionRdpCredential]::ReadUserName($target) | Should Be $null
        { Remove-RdpCredential $target } | Should Not Throw
    }

    It 'rejects empty passwords and does not expose sensitive failed CLI output' {
        { Set-RdpCredential -Target 'TERMSRV/unused' -Username 'test' -Password '' } | Should Throw 'empty'
        Mock Invoke-AzRaw { [pscustomobject]@{ ExitCode = 1; Output = 'synthetic-secret-value' } }
        try {
            Invoke-Az -Arguments @('keyvault', 'secret', 'show') -SensitiveOutput
            throw 'Expected a CLI failure.'
        }
        catch {
            $_.Exception.Message | Should Match 'Key Vault secret retrieval failed'
            $_.Exception.Message | Should Not Match 'synthetic-secret-value'
        }
    }

    It 'decodes JSON secret strings without stripping whitespace or interpreting shell characters' {
        Mock Invoke-AzRaw { [pscustomobject]@{ ExitCode = 0; Output = '" synthetic&password\\\" \r\n"' } }
        Invoke-Az -Arguments @('keyvault', 'secret', 'show') -SensitiveOutput |
            Should Be " synthetic&password\`" `r`n"
    }
}

Describe 'Local connection slots' {
    It 'detects a listening tunnel port and frees its own port probe' {
        $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
        $listener.Server.ExclusiveAddressUse = $true
        $listener.Start()
        $port = $listener.LocalEndpoint.Port
        try {
            Test-LocalPortFree '127.0.0.1' $port | Should Be $false
            Test-TunnelPort $port | Should Be $true
        }
        finally { $listener.Stop() }
        Test-TunnelPort $port | Should Be $false
        Test-LocalPortFree '127.0.0.1' $port | Should Be $true
    }

    It 'skips slots whose port is busy or whose credential is still in use' {
        $probe = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
        $probe.Start(); $base = $probe.LocalEndpoint.Port; $probe.Stop()
        $busy = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, $base)
        $busy.Start()
        try {
            Set-RdpCredential -Target 'TERMSRV/127.0.0.3' -Username 'test' -Password 'synthetic'
            $slot = Get-ConnectionSlot $base
            $slot.Address | Should Be '127.0.0.4'
            $slot.Port | Should Be ($base + 2)
            $slot.CredentialTarget | Should Be 'TERMSRV/127.0.0.4'
        }
        finally {
            $busy.Stop()
            Remove-RdpCredential 'TERMSRV/127.0.0.3'
        }
    }
}

Describe 'Detached connection helper' {
    It 'relays RDP traffic through its own loopback address and cleans up after RDP exits' {
        $probe = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
        $probe.Start(); $port = $probe.LocalEndpoint.Port; $probe.Stop()
        $address = '127.0.0.77'
        $target = "TERMSRV/bastion-test-$([guid]::NewGuid())"
        $resultFile = Join-Path $TestDrive 'rdp.result'
        $tunnelScript = Join-Path $TestDrive 'fake-tunnel.ps1'
        $rdpScript = Join-Path $TestDrive 'fake-rdp.ps1'
        Set-Content -LiteralPath $tunnelScript -Value (
            "`$l = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, $port); `$l.Start()`r`n" +
            "while (`$true) { `$c = `$l.AcceptTcpClient(); `$s = `$c.GetStream(); `$s.ReadTimeout = 2000; `$b = New-Object byte[] 64`r`n" +
            "  try { `$n = `$s.Read(`$b, 0, 64); if (`$n -gt 0) { `$s.Write(`$b, 0, `$n) } } catch { }; `$c.Close() }")
        Set-Content -LiteralPath (Join-Path $TestDrive 'az.cmd') -Value (
            "@echo off`r`npowershell -NoProfile -NonInteractive -File `"$tunnelScript`"")
        Set-Content -LiteralPath $rdpScript -Value (
            "`$c = [Net.Sockets.TcpClient]::new('$address', $port); `$s = `$c.GetStream(); `$s.ReadTimeout = 5000`r`n" +
            "`$s.Write([byte[]](112,105,110,103), 0, 4); `$b = New-Object byte[] 4; `$n = `$s.Read(`$b, 0, 4)`r`n" +
            "[Text.Encoding]::ASCII.GetString(`$b, 0, `$n) | Set-Content -LiteralPath '$resultFile'; `$c.Close(); Start-Sleep -Seconds 1")
        $statusFile = Join-Path $TestDrive 'helper.status'
        Set-RdpCredential -Target $target -Username 'test' -Password 'synthetic'
        $launcher = $null
        try {
            $launcher = Start-ConnectionLauncher @{
                StatusFile = $statusFile
                AzCommand = (Join-Path $TestDrive 'az.cmd')
                TunnelArgs = @('network', 'bastion', 'tunnel', '--port', "$port")
                Port = $port
                RdpAddress = $address
                CredentialTarget = $target
                RdpCommand = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
                RdpArguments = "-NoProfile -NonInteractive -File `"$rdpScript`""
            }
            Wait-ConnectionReady -Process $launcher -StatusFile $statusFile -TimeoutSeconds 60
            $launcher.WaitForExit(30000) | Should Be $true
            Get-Content -LiteralPath $resultFile | Should Be 'ping'
            [BastionRdpCredential]::ReadUserName($target) | Should Be $null
            Test-TunnelPort $port | Should Be $false
        }
        finally {
            if ($launcher -and -not $launcher.HasExited) { Stop-TunnelProcess $launcher }
            Remove-RdpCredential $target
        }
    }

    It 'reports helper errors back to the window' {
        $statusFile = Join-Path $TestDrive 'failed.status'
        $launcher = Start-ConnectionLauncher @{
            StatusFile = $statusFile
            AzCommand = (Join-Path $TestDrive 'missing-az.cmd')
            TunnelArgs = @()
            Port = 1
            RdpAddress = '127.0.0.78'
            CredentialTarget = "TERMSRV/bastion-test-$([guid]::NewGuid())"
            RdpCommand = 'unused.exe'
            RdpArguments = ''
        }
        try { { Wait-ConnectionReady -Process $launcher -StatusFile $statusFile -TimeoutSeconds 60 } | Should Throw 'exited before becoming ready' }
        finally { if (-not $launcher.HasExited) { Stop-TunnelProcess $launcher } }
    }
}

Describe 'Azure CLI discovery' {
    It 'returns one az.cmd path when PATH also contains the extensionless az script' {
        $bin = Join-Path $TestDrive 'wbin'
        New-Item -ItemType Directory -Path $bin | Out-Null
        Set-Content -Path (Join-Path $bin 'az') -Value '#!/bin/bash'
        Set-Content -Path (Join-Path $bin 'az.cmd') -Value '@echo off'
        $oldPath = $env:PATH
        try {
            $env:PATH = "$bin;$oldPath"
            $found = @(Find-AzCommand)
            $found.Count | Should Be 1
            $found[0] | Should Be (Join-Path $bin 'az.cmd')
        }
        finally { $env:PATH = $oldPath }
    }
}

Describe 'Tunnel process cleanup' {
    It 'stops the owned launcher and its child process without leaving an orphan' {
        $pidFile = Join-Path $TestDrive 'child.pid'
        $shell = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
        $childCode = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes('Start-Sleep -Seconds 60'))
        $parentCode = "`$child = Start-Process '$shell' -ArgumentList '-NoProfile -NonInteractive -EncodedCommand $childCode' -PassThru; `$child.Id | Set-Content '$pidFile'; Start-Sleep -Seconds 60"
        $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($parentCode))
        $parent = Start-Process $shell -ArgumentList "-NoProfile -NonInteractive -EncodedCommand $encoded" `
            -PassThru -WindowStyle Hidden
        $childId = $null
        try {
            $timer = [Diagnostics.Stopwatch]::StartNew()
            while ($timer.Elapsed.TotalSeconds -lt 10 -and -not (Test-Path $pidFile)) {
                Start-Sleep -Milliseconds 100
            }
            if (-not (Test-Path $pidFile)) { throw 'Test child did not start within 10 seconds.' }
            $childId = [int](Get-Content $pidFile)
            Get-Process -Id $childId -ErrorAction Stop | Should Not BeNullOrEmpty
            Stop-TunnelProcess $parent
            $parent.WaitForExit(5000) | Should Be $true
            Get-Process -Id $childId -ErrorAction SilentlyContinue | Should BeNullOrEmpty
        }
        finally {
            if (-not $parent.HasExited) { Stop-TunnelProcess $parent }
            if ($childId) {
                $child = Get-Process -Id $childId -ErrorAction SilentlyContinue
                if ($child) { Stop-Process -Id $childId -Force }
            }
        }
    }
}
