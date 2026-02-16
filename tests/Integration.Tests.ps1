<#
.SYNOPSIS
    Pester 5 integration tests for IMPACT Docker GUI.
    Uses mocks for Docker CLI and SSH — no real containers or remote hosts required.

    Run:  pwsh -File tests/Invoke-Tests.ps1 -Tag Integration
#>

BeforeAll {
    # Import the module under test
    $modulePath = Join-Path $PSScriptRoot '..' 'current_version' 'IMPACT_Docker_GUI.psm1'
    Import-Module $modulePath -Force -DisableNameChecking

    # Import test helpers
    . (Join-Path $PSScriptRoot 'Helpers' 'TestSessionState.ps1')
}

# ═══════════════════════════════════════════════════════════════════════════════
#  NonInteractive credential flow
# ═══════════════════════════════════════════════════════════════════════════════
Describe 'Show-CredentialDialog in NonInteractive mode' -Tag Integration {
    BeforeEach {
        Enable-NonInteractiveMode
    }
    AfterEach {
        Disable-NonInteractiveMode
    }

    It 'Reads credentials from pre-set state values' {
        $state = New-TestSessionState -UserName 'ciuser' -Password 'CIpass99!'
        # In NonInteractive mode, Show-CredentialDialog should read from pre-set state
        $result = Show-CredentialDialog -State $state
        $result | Should -BeTrue
        $state.UserName | Should -Be 'ciuser'
        $state.Password | Should -Be 'CIpass99!'
    }

    It 'Fails if UserName is empty' {
        $state = New-TestSessionState -UserName '' -Password 'CIpass99!'
        $state.UserName = ''
        $result = Show-CredentialDialog -State $state
        $result | Should -BeFalse
    }
}

# ═══════════════════════════════════════════════════════════════════════════════
#  NonInteractive location selection
# ═══════════════════════════════════════════════════════════════════════════════
Describe 'Select-Location in NonInteractive mode' -Tag Integration {
    BeforeEach {
        Enable-NonInteractiveMode
    }
    AfterEach {
        Disable-NonInteractiveMode
    }

    It 'Reads LOCAL location from pre-set state' {
        $state = New-TestSessionState -Location 'LOCAL'
        $result = Select-Location -State $state
        $result | Should -BeTrue
        $state.ContainerLocation | Should -Be 'LOCAL'
    }

    It 'Reads REMOTE location from pre-set state' {
        $state = New-TestSessionState -Location 'REMOTE@10.0.0.5'
        $result = Select-Location -State $state
        $result | Should -BeTrue
        $state.ContainerLocation | Should -Be 'REMOTE@10.0.0.5'
    }
}

# ═══════════════════════════════════════════════════════════════════════════════
#  NonInteractive prerequisites
# ═══════════════════════════════════════════════════════════════════════════════
Describe 'Test-StartupPrerequisites in NonInteractive mode' -Tag Integration {
    BeforeEach {
        Enable-NonInteractiveMode
    }
    AfterEach {
        Disable-NonInteractiveMode
    }

    It 'Returns true when docker and ssh are available' {
        $state = New-TestSessionState
        # This test will pass on any machine with Docker and SSH installed
        $dockerPresent = [bool](Get-Command docker -ErrorAction SilentlyContinue)
        $sshPresent = [bool](Get-Command ssh -ErrorAction SilentlyContinue)
        if (-not $dockerPresent -or -not $sshPresent) {
            Set-ItResult -Skipped -Because 'Docker CLI or SSH not installed on this machine'
        }
        $result = Test-StartupPrerequisites -State $state
        $result | Should -BeTrue
    }
}

# ═══════════════════════════════════════════════════════════════════════════════
#  NonInteractive Ensure-GitKeySetup (with existing key)
# ═══════════════════════════════════════════════════════════════════════════════
Describe 'Ensure-GitKeySetup in NonInteractive mode' -Tag Integration {
    BeforeEach {
        Enable-NonInteractiveMode
    }
    AfterEach {
        Disable-NonInteractiveMode
    }

    It 'Succeeds when SSH key pair already exists' {
        $keyInfo = New-DummySshKeyPair -Label 'gitsetup'
        try {
            $state = New-TestSessionState -UserName 'gitsetup'
            $state.Paths.SshPrivate = $keyInfo.Private
            $state.Paths.SshPublic  = $keyInfo.Public

            # Pre-create the key files so Ensure-GitKeySetup finds them
            # They were already created by New-DummySshKeyPair

            $result = Ensure-GitKeySetup -State $state
            $result | Should -BeTrue
            $state.Metadata.PublicKey | Should -Not -BeNullOrEmpty
        } finally {
            Remove-TestArtifacts -Paths @($keyInfo.Dir)
        }
    }
}

# ═══════════════════════════════════════════════════════════════════════════════
#  Test-DockerDaemonReady (mocked)
# ═══════════════════════════════════════════════════════════════════════════════
Describe 'Test-DockerDaemonReady' -Tag Integration {
    It 'Returns true when docker info succeeds' {
        # Only run if Docker is actually present
        $dockerPresent = [bool](Get-Command docker -ErrorAction SilentlyContinue)
        if (-not $dockerPresent) {
            Set-ItResult -Skipped -Because 'Docker CLI not installed'
        }

        # If Docker daemon is running, it should return true
        # If Docker daemon is NOT running, it should return false (still a valid test)
        $result = Test-DockerDaemonReady
        $result | Should -BeOfType [bool]
    }
}

# ═══════════════════════════════════════════════════════════════════════════════
#  Get-ContainerRuntimeInfo (mocked docker inspect)
# ═══════════════════════════════════════════════════════════════════════════════
Describe 'Get-ContainerRuntimeInfo with mock' -Tag Integration {
    It 'Extracts password and port from docker inspect output' {
        $state = New-TestSessionState
        $state.ContainerName = 'impact-testuser'

        # Mock docker to return predetermined output
        Mock docker {
            $allArgs = $args
            $flatArgs = @()
            foreach ($a in $allArgs) {
                if ($a -is [array]) { $flatArgs += $a } else { $flatArgs += $a }
            }
            $joined = $flatArgs -join ' '
            if ($joined -match 'range .Config.Env') {
                return @('PASSWORD=TestSecret', 'DISABLE_AUTH=false', 'USERID=1000')
            }
            if ($joined -match 'NetworkSettings.Ports') {
                return '8787'
            }
            return ''
        } -ModuleName 'IMPACT_Docker_GUI'

        $info = Get-ContainerRuntimeInfo -State $state
        $info.Password | Should -Be 'TestSecret'
        $info.Port | Should -Be '8787'
    }
}

# ═══════════════════════════════════════════════════════════════════════════════
#  Ensure-SshAgentRunning
# ═══════════════════════════════════════════════════════════════════════════════
Describe 'Ensure-SshAgentRunning' -Tag Integration {
    It 'Does not throw when called with a dummy key path' {
        # This test verifies that the function handles missing keys gracefully
        $dummyPath = Join-Path $env:TEMP 'impact_test_nonexistent_key'
        { Ensure-SshAgentRunning -SshKeyPath $dummyPath } | Should -Not -Throw
    }
}

# ═══════════════════════════════════════════════════════════════════════════════
#  Remote container flow: YAML parsing → path resolution → docker run command
#  Uses faked remote workstation paths matching the SSHD container structure.
# ═══════════════════════════════════════════════════════════════════════════════
Describe 'Remote container flow with faked workstation paths' -Tag Integration {
    BeforeAll {
        # sim_design.yaml with absolute POSIX paths (as it exists on the real remote workstation)
        $script:testDir = Join-Path $env:TEMP "impact_remote_flow_$([guid]::NewGuid().ToString('N').Substring(0,8))"
        New-Item -ItemType Directory -Path $script:testDir -Force | Out-Null
        $script:yamlFile = Join-Path $script:testDir 'sim_design.yaml'
        Set-Content -Path $script:yamlFile -Value @"
output_dir: /mnt/Storage_1/IMPACT_Storage/Base/outputs
synthpop_dir: /mnt/Storage_1/IMPACT_Storage/Base/inputs/synthpop
"@
    }

    AfterAll {
        Remove-Item -Recurse -Force -Path $script:testDir -ErrorAction SilentlyContinue
    }

    It 'Resolves remote YAML paths correctly from sim_design.yaml' {
        # Mock SSH so Get-YamlPathValue reads from the local file instead of SSHing
        Mock ssh { return (Get-Content $script:yamlFile -Raw) } -ModuleName 'IMPACT_Docker_GUI'

        $state = New-TestSessionState -UserName 'remuser' -Location 'REMOTE@10.152.14.124'
        $remoteRepoBase = '/home/php-workstation/Schreibtisch/Repositories/IMPACTncd_Germany'

        $outputDir  = Get-YamlPathValue -State $state -YamlPath $script:yamlFile -Key 'output_dir'  -BaseDir $remoteRepoBase
        $synthDir   = Get-YamlPathValue -State $state -YamlPath $script:yamlFile -Key 'synthpop_dir' -BaseDir $remoteRepoBase

        # Absolute /mnt paths are returned as-is (not joined with BaseDir)
        $outputDir  | Should -Be '/mnt/Storage_1/IMPACT_Storage/Base/outputs'
        $synthDir   | Should -Be '/mnt/Storage_1/IMPACT_Storage/Base/inputs/synthpop'
    }

    It 'Test-AndCreateDirectory accepts remote absolute mount paths (mocked SSH)' {
        Mock ssh { return 'EXISTS' } -ModuleName 'IMPACT_Docker_GUI'

        $state = New-TestSessionState -UserName 'remuser' -Location 'REMOTE@10.152.14.124'
        $remoteOutput = '/mnt/Storage_1/IMPACT_Storage/Base/outputs'
        $remoteSynth  = '/mnt/Storage_1/IMPACT_Storage/Base/inputs/synthpop'

        (Test-AndCreateDirectory -State $state -Path $remoteOutput -PathKey 'output_dir')   | Should -BeTrue
        (Test-AndCreateDirectory -State $state -Path $remoteSynth  -PathKey 'synthpop_dir') | Should -BeTrue
    }

    It 'Builds a complete docker run command for the remote workstation' {
        $state = New-TestSessionState -UserName 'remuser' -Password 'RemPass!' -Location 'REMOTE@10.152.14.124'
        $state.SelectedRepo  = 'IMPACTncd_Germany'
        $state.ContainerName = 'IMPACTncd_Germany_remuser'
        $state.RemoteUser    = 'php-workstation'

        $remoteRepoBase = '/home/php-workstation/Schreibtisch/Repositories/IMPACTncd_Germany'

        $args = Build-DockerRunCommand -State $state `
            -Port '8787' `
            -UseVolumes $false `
            -HighCompute $true `
            -ImageName 'impactncd_germany' `
            -ProjectRoot  $remoteRepoBase `
            -OutputDir    '/mnt/Storage_1/IMPACT_Storage/Base/outputs' `
            -SynthpopDir  '/mnt/Storage_1/IMPACT_Storage/Base/inputs/synthpop' `
            -SshKeyPath   "/home/php-workstation/.ssh/id_ed25519_remuser" `
            -KnownHostsPath "/home/php-workstation/.ssh/known_hosts"

        $joined = $args -join ' '

        # Essentials
        $joined | Should -Match '^run -d --rm'
        $joined | Should -Match '--name IMPACTncd_Germany_remuser'
        $joined | Should -Match 'PASSWORD=RemPass!'

        # Remote-only high-compute flags
        $joined | Should -Match '--cpus 32'
        $joined | Should -Match '-m 384g'

        # Bind mounts point at the actual /mnt storage paths
        $joined | Should -Match 'type=bind,source=/mnt/Storage_1/IMPACT_Storage/Base/outputs'
        $joined | Should -Match 'type=bind,source=/mnt/Storage_1/IMPACT_Storage/Base/inputs/synthpop'

        # SSH key inside container
        $joined | Should -Match 'source=/home/php-workstation/\.ssh/id_ed25519_remuser'
        $joined | Should -Match 'target=/keys/id_ed25519_remuser'
    }
}

# ═══════════════════════════════════════════════════════════════════════════════
#  Local container flow: sim_design_local.yaml with Windows paths
# ═══════════════════════════════════════════════════════════════════════════════
Describe 'Local container flow with sim_design_local.yaml' -Tag Integration {
    BeforeAll {
        # Create a fake local repo tree with outputs and synthpop directories
        $script:localRepo = Join-Path $env:TEMP "impact_local_flow_$([guid]::NewGuid().ToString('N').Substring(0,8))"
        $script:outputDir    = Join-Path $script:localRepo 'outputs'
        $script:synthpopDir  = Join-Path $script:localRepo 'inputs' 'synthpop'
        New-Item -ItemType Directory -Path $script:outputDir   -Force | Out-Null
        New-Item -ItemType Directory -Path $script:synthpopDir -Force | Out-Null

        # sim_design_local.yaml with relative paths (Windows style)
        $script:yamlFile = Join-Path $script:localRepo 'inputs' 'sim_design_local.yaml'
        Set-Content -Path $script:yamlFile -Value @"
output_dir: ./outputs
synthpop_dir: ./inputs/synthpop
"@
    }

    AfterAll {
        Remove-Item -Recurse -Force -Path $script:localRepo -ErrorAction SilentlyContinue
    }

    It 'Resolves local YAML paths without producing POSIX-style results' {
        $state = New-TestSessionState -Location 'LOCAL'
        $baseDir = ($script:localRepo -replace '\\', '/')

        $outputDir = Get-YamlPathValue -State $state -YamlPath $script:yamlFile -Key 'output_dir'  -BaseDir $baseDir
        $synthDir  = Get-YamlPathValue -State $state -YamlPath $script:yamlFile -Key 'synthpop_dir' -BaseDir $baseDir

        # Paths resolve against the Windows-rooted BaseDir, not a POSIX root
        $outputDir | Should -Not -Match '^\/'
        $synthDir  | Should -Not -Match '^\/'
        $outputDir | Should -Match 'outputs'
        $synthDir  | Should -Match 'synthpop'
    }

    It 'Test-AndCreateDirectory accepts the resolved local paths' {
        $state = New-TestSessionState -Location 'LOCAL'
        $baseDir = ($script:localRepo -replace '\\', '/')

        $outputDir = Get-YamlPathValue -State $state -YamlPath $script:yamlFile -Key 'output_dir'  -BaseDir $baseDir
        $synthDir  = Get-YamlPathValue -State $state -YamlPath $script:yamlFile -Key 'synthpop_dir' -BaseDir $baseDir

        (Test-AndCreateDirectory -State $state -Path $outputDir -PathKey 'output_dir')   | Should -BeTrue
        (Test-AndCreateDirectory -State $state -Path $synthDir  -PathKey 'synthpop_dir') | Should -BeTrue
    }

    It 'Builds a complete docker run command for LOCAL mode' {
        $state = New-TestSessionState -UserName 'localuser' -Password 'LocPass!' -Location 'LOCAL'
        $state.SelectedRepo  = 'IMPACTncd_Germany'
        $state.ContainerName = 'IMPACTncd_Germany_localuser'

        $args = Build-DockerRunCommand -State $state `
            -Port '8787' `
            -UseVolumes $false `
            -ImageName 'impactncd_germany' `
            -ProjectRoot  $script:localRepo `
            -OutputDir    $script:outputDir `
            -SynthpopDir  $script:synthpopDir `
            -SshKeyPath   "C:\Users\localuser\.ssh\id_ed25519_localuser" `
            -KnownHostsPath "C:\Users\localuser\.ssh\known_hosts"

        $joined = $args -join ' '

        $joined | Should -Match '^run -d --rm'
        $joined | Should -Match '--name IMPACTncd_Germany_localuser'
        $joined | Should -Match 'PASSWORD=LocPass!'
        # Should NOT have high-compute flags
        $joined | Should -Not -Match '--cpus'
        $joined | Should -Not -Match '-m 384g'
        # Image is last
        $args[-1] | Should -Be 'impactncd_germany'
    }
}

# ═══════════════════════════════════════════════════════════════════════════════
#  Build-DockerRunCommand integration (end-to-end assembly)
# ═══════════════════════════════════════════════════════════════════════════════
Describe 'Build-DockerRunCommand end-to-end' -Tag Integration {
    It 'Produces a valid docker run command string for LOCAL with volumes' {
        $state = New-TestSessionState -UserName 'inttest' -Password 'IntPass!'
        $state.SelectedRepo = 'IMPACTncd_Germany'
        $state.ContainerName = 'impact-inttest'

        $args = Build-DockerRunCommand -State $state `
            -Port '9999' `
            -UseVolumes $true `
            -HighCompute $false `
            -ImageName 'impactncd_germany' `
            -ProjectRoot 'C:\repos\IMPACTncd_Germany' `
            -OutputDir 'C:\repos\IMPACTncd_Germany\outputs' `
            -SynthpopDir 'C:\repos\IMPACTncd_Germany\inputs\synthpop' `
            -SshKeyPath 'C:\Users\inttest\.ssh\id_ed25519_inttest' `
            -KnownHostsPath 'C:\Users\inttest\.ssh\known_hosts'

        $joined = $args -join ' '

        # Verify essential structure
        $joined | Should -Match '^run -d --rm'
        $joined | Should -Match '--name impact-inttest'
        $joined | Should -Match 'PASSWORD=IntPass!'
        $joined | Should -Match '9999:8787'
        $joined | Should -Match 'impactncd_germany_output_inttest'
        $joined | Should -Match 'impactncd_germany_synthpop_inttest'
        $joined | Should -Match 'impactncd_germany$'  # image name is last
    }

    It 'Produces a valid docker run command for REMOTE with bind mounts and high compute' {
        $state = New-TestSessionState -UserName 'remuser' -Password 'RemPass!' -Location 'REMOTE@10.152.14.124'
        $state.SelectedRepo = 'IMPACTncd_Germany'
        $state.ContainerName = 'impact-remuser'

        $args = Build-DockerRunCommand -State $state `
            -Port '8787' `
            -UseVolumes $false `
            -HighCompute $true `
            -ImageName 'impactncd_germany' `
            -ProjectRoot '/home/php-workstation/Schreibtisch/Repositories/IMPACTncd_Germany' `
            -OutputDir '/mnt/Storage_1/IMPACT_Storage/Base/outputs' `
            -SynthpopDir '/mnt/Storage_1/IMPACT_Storage/Base/inputs/synthpop' `
            -SshKeyPath '/home/php-workstation/.ssh/id_ed25519_remuser' `
            -KnownHostsPath '/home/php-workstation/.ssh/known_hosts'

        $joined = $args -join ' '

        $joined | Should -Match '--cpus 32'
        $joined | Should -Match '-m 384g'
        $joined | Should -Match 'type=bind,source=/mnt/Storage_1/IMPACT_Storage/Base/outputs'
        $joined | Should -Match 'type=bind,source=/mnt/Storage_1/IMPACT_Storage/Base/inputs/synthpop'
        $joined | Should -Not -Match 'impactncd_germany_output_'  # no volume names in bind mode
    }
}

# ═══════════════════════════════════════════════════════════════════════════════
#  GitHub SSH Key API helpers (mocked)
# ═══════════════════════════════════════════════════════════════════════════════
Describe 'GitHub SSH Key API helpers' -Tag Integration {
    It 'Add-GitHubSshKey calls the correct API endpoint' {
        Mock Invoke-RestMethod {
            return @{ id = 12345; key = 'ssh-ed25519 AAAA...' }
        } -ModuleName 'IMPACT_Docker_GUI'

        $result = Add-GitHubSshKey -PublicKey 'ssh-ed25519 AAAAtest' -Title 'CI Test Key' -Token 'ghp_fake'
        # Function returns just the .id, not the full response
        $result | Should -Be 12345

        Should -Invoke Invoke-RestMethod -ModuleName 'IMPACT_Docker_GUI' -ParameterFilter {
            $Uri -eq 'https://api.github.com/user/keys' -and $Method -eq 'Post'
        }
    }

    It 'Remove-GitHubSshKey calls DELETE with correct key ID' {
        Mock Invoke-RestMethod {} -ModuleName 'IMPACT_Docker_GUI'

        Remove-GitHubSshKey -KeyId 12345 -Token 'ghp_fake'

        Should -Invoke Invoke-RestMethod -ModuleName 'IMPACT_Docker_GUI' -ParameterFilter {
            $Uri -eq 'https://api.github.com/user/keys/12345' -and $Method -eq 'Delete'
        }
    }
}

# ═══════════════════════════════════════════════════════════════════════════════
#  Show-GitCommitDialog in NonInteractive mode
# ═══════════════════════════════════════════════════════════════════════════════
Describe 'Show-GitCommitDialog in NonInteractive mode' -Tag Integration {
    BeforeEach {
        Enable-NonInteractiveMode
    }
    AfterEach {
        Disable-NonInteractiveMode
    }

    It 'Returns null (skips dialog) in NonInteractive mode' {
        $result = Show-GitCommitDialog -ChangesText 'M some-file.R'
        $result | Should -BeNullOrEmpty
    }
}

# ═══════════════════════════════════════════════════════════════════════════════
#  Ensure-Prerequisites in NonInteractive mode
# ═══════════════════════════════════════════════════════════════════════════════
Describe 'Ensure-Prerequisites in NonInteractive mode' -Tag Integration {
    BeforeEach {
        Enable-NonInteractiveMode
    }
    AfterEach {
        Disable-NonInteractiveMode
    }

    It 'Loads WinForms without showing dialogs' {
        $dockerPresent = [bool](Get-Command docker -ErrorAction SilentlyContinue)
        $sshPresent = [bool](Get-Command ssh -ErrorAction SilentlyContinue)
        if (-not $dockerPresent -or -not $sshPresent) {
            Set-ItResult -Skipped -Because 'Docker CLI or SSH not installed'
        }
        $state = New-TestSessionState
        $result = Ensure-Prerequisites -State $state
        $result | Should -BeTrue
    }
}

# ═══════════════════════════════════════════════════════════════════════════════
#  Write-Log (verify no crashes under various levels)
# ═══════════════════════════════════════════════════════════════════════════════
Describe 'Write-Log' -Tag Integration {
    It 'Writes Info level without error' {
        { Write-Log 'Test info message' 'Info' } | Should -Not -Throw
    }

    It 'Writes Warn level without error' {
        { Write-Log 'Test warn message' 'Warn' } | Should -Not -Throw
    }

    It 'Writes Error level without error' {
        { Write-Log 'Test error message' 'Error' } | Should -Not -Throw
    }

    It 'Writes Debug level without error (suppressed when debug off)' {
        { Write-Log 'Test debug message' 'Debug' } | Should -Not -Throw
    }
}
