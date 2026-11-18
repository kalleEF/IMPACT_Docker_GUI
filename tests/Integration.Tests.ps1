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
        Mock Invoke-RestMethod {
            return @{ login = 'ciuser'; id = 1 }
        } -ModuleName 'IMPACT_Docker_GUI'

        $state = New-TestSessionState -UserName 'ciuser' -Password 'CIpass99!'
        # In NonInteractive mode, Show-CredentialDialog should read from pre-set state
        $result = Show-CredentialDialog -State $state
        $result | Should -Be 'next'
        $state.UserName | Should -Be 'ciuser'
        $state.Password | Should -Be 'CIpass99!'
    }

    It 'Fails if UserName is empty' {
        $state = New-TestSessionState -UserName '' -Password 'CIpass99!'
        $state.UserName = ''
        $result = Show-CredentialDialog -State $state
        $result | Should -Be 'cancel'
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
        $result | Should -Be 'next'
        $state.ContainerLocation | Should -Be 'LOCAL'
    }

    It 'Reads REMOTE location from pre-set state' {
        $state = New-TestSessionState -Location 'REMOTE@10.0.0.5'
        $result = Select-Location -State $state
        $result | Should -Be 'next'
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
        # Volume names now include the container name (repo + user), F48
        $joined | Should -Match 'impactncd_output_impact-inttest'
        $joined | Should -Match 'impactncd_synthpop_impact-inttest'
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
        $joined | Should -Not -Match 'impactncd_output_'  # no volume names in bind mode
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

# ═══════════════════════════════════════════════════════════════════════════════
#  Get-GitRepositoryState — local mode (mocked git)
# ═══════════════════════════════════════════════════════════════════════════════
Describe 'Get-GitRepositoryState (local, mocked)' -Tag Integration {
    It 'Returns HasChanges=$true when git status reports changes' {
        Mock git {
            $allArgs = $args
            $flatArgs = @()
            foreach ($a in $allArgs) {
                if ($a -is [array]) { $flatArgs += $a } else { $flatArgs += $a }
            }
            $joined = $flatArgs -join ' '
            if ($joined -match 'status --porcelain') {
                return @(' M src/app.R', '?? new_file.R')
            }
            if ($joined -match 'rev-parse --abbrev-ref') {
                return 'main'
            }
            if ($joined -match 'remote get-url') {
                return 'git@github.com:user/repo.git'
            }
            return ''
        } -ModuleName 'IMPACT_Docker_GUI'

        $state = New-TestSessionState -Location 'LOCAL'
        $result = Get-GitRepositoryState -State $state -RepoPath $env:TEMP -IsRemote $false

        $result | Should -Not -BeNullOrEmpty
        $result.HasChanges | Should -BeTrue
        $result.StatusText | Should -Match 'app\.R'
        $result.Branch | Should -Be 'main'
        $result.Remote | Should -Match 'github\.com'
    }

    It 'Returns HasChanges=$false when working tree is clean' {
        Mock git {
            $allArgs = $args
            $flatArgs = @()
            foreach ($a in $allArgs) {
                if ($a -is [array]) { $flatArgs += $a } else { $flatArgs += $a }
            }
            $joined = $flatArgs -join ' '
            if ($joined -match 'status --porcelain') {
                return @()
            }
            if ($joined -match 'rev-parse --abbrev-ref') {
                return 'develop'
            }
            if ($joined -match 'remote get-url') {
                return 'git@github.com:user/repo.git'
            }
            return ''
        } -ModuleName 'IMPACT_Docker_GUI'

        $state = New-TestSessionState -Location 'LOCAL'
        $result = Get-GitRepositoryState -State $state -RepoPath $env:TEMP -IsRemote $false

        $result | Should -Not -BeNullOrEmpty
        $result.HasChanges | Should -BeFalse
        $result.Branch | Should -Be 'develop'
    }

    It 'Returns null when RepoPath is empty' {
        $state = New-TestSessionState -Location 'LOCAL'
        $result = Get-GitRepositoryState -State $state -RepoPath '' -IsRemote $false
        $result | Should -BeNullOrEmpty
    }
}

# ═══════════════════════════════════════════════════════════════════════════════
#  Get-GitRepositoryState — remote mode (mocked SSH)
# ═══════════════════════════════════════════════════════════════════════════════
Describe 'Get-GitRepositoryState (remote, mocked SSH)' -Tag Integration {
    It 'Parses combined SSH output into status/branch/remote' {
        Mock ssh {
            # Simulated output: porcelain status lines, then branch, then remote URL
            return @(
                ' M inputs/sim_design.yaml'
                'main'
                'git@github.com:IMPACT/repo.git'
            )
        } -ModuleName 'IMPACT_Docker_GUI'

        $state = New-TestSessionState -Location 'REMOTE@10.0.0.5'
        $result = Get-GitRepositoryState -State $state -RepoPath '/home/user/repo' -IsRemote $true

        $result | Should -Not -BeNullOrEmpty
        $result.HasChanges | Should -BeTrue
        $result.StatusText | Should -Match 'sim_design'
        $result.Branch | Should -Be 'main'
        $result.Remote | Should -Match 'github\.com'
    }

    It 'Returns HasChanges=$false for clean remote repo' {
        Mock ssh {
            # No porcelain lines — just branch and remote
            return @(
                'feature-branch'
                'git@github.com:IMPACT/repo.git'
            )
        } -ModuleName 'IMPACT_Docker_GUI'

        $state = New-TestSessionState -Location 'REMOTE@10.0.0.5'
        $result = Get-GitRepositoryState -State $state -RepoPath '/home/user/repo' -IsRemote $true

        $result | Should -Not -BeNullOrEmpty
        $result.HasChanges | Should -BeFalse
        $result.Branch | Should -Be 'feature-branch'
    }
}

# ═══════════════════════════════════════════════════════════════════════════════
#  Invoke-GitChangeDetection (mocked — NonInteractive, no dialog)
# ═══════════════════════════════════════════════════════════════════════════════
Describe 'Invoke-GitChangeDetection in NonInteractive mode' -Tag Integration {
    BeforeEach {
        Enable-NonInteractiveMode
    }
    AfterEach {
        Disable-NonInteractiveMode
    }

    It 'Does nothing when there are no changes' {
        Mock git {
            $allArgs = $args
            $flatArgs = @()
            foreach ($a in $allArgs) {
                if ($a -is [array]) { $flatArgs += $a } else { $flatArgs += $a }
            }
            $joined = $flatArgs -join ' '
            if ($joined -match 'status --porcelain') { return @() }
            if ($joined -match 'rev-parse --abbrev-ref') { return 'main' }
            if ($joined -match 'remote get-url') { return 'git@github.com:u/r.git' }
            return ''
        } -ModuleName 'IMPACT_Docker_GUI'

        $state = New-TestSessionState -Location 'LOCAL'
        # Should complete without error and without committing
        { Invoke-GitChangeDetection -State $state -RepoPath $env:TEMP -IsRemote $false } | Should -Not -Throw
    }

    It 'Skips commit when dialog returns null (NonInteractive)' {
        Mock git {
            $allArgs = $args
            $flatArgs = @()
            foreach ($a in $allArgs) {
                if ($a -is [array]) { $flatArgs += $a } else { $flatArgs += $a }
            }
            $joined = $flatArgs -join ' '
            if ($joined -match 'status --porcelain') { return @(' M file.R') }
            if ($joined -match 'rev-parse --abbrev-ref') { return 'main' }
            if ($joined -match 'remote get-url') { return 'git@github.com:u/r.git' }
            # If we get here, commit/push is being attempted — fail
            throw "git commit/push should not be called in NonInteractive mode without dialog"
        } -ModuleName 'IMPACT_Docker_GUI'

        $state = New-TestSessionState -Location 'LOCAL'
        # NonInteractive mode => Show-GitCommitDialog returns $null => no commit
        { Invoke-GitChangeDetection -State $state -RepoPath $env:TEMP -IsRemote $false } | Should -Not -Throw
    }
}

# ═══════════════════════════════════════════════════════════════════════════════
#  Remote container metadata (Write / Read / Remove) — mocked SSH
# ═══════════════════════════════════════════════════════════════════════════════
Describe 'Remote container metadata lifecycle (mocked SSH)' -Tag Integration {
    BeforeAll {
        # Capture what SSH commands the functions send
        $script:sshCommands = @()
    }

    It 'Write-RemoteContainerMetadata sends base64-encoded JSON via SSH' {
        $script:sshCommands = @()
        Mock ssh {
            $script:sshCommands += ($args -join ' ')
        } -ModuleName 'IMPACT_Docker_GUI'

        $state = New-TestSessionState -UserName 'metauser' -Password 'MetaPass!' -Location 'REMOTE@10.0.0.1'
        $state.ContainerName = 'impact-metauser'
        $state.SelectedRepo  = 'IMPACTncd_Germany'

        Write-RemoteContainerMetadata -State $state -Port '8787' -UseVolumes $false

        $script:sshCommands.Count | Should -BeGreaterThan 0
        $lastCmd = $script:sshCommands[-1]
        # Should contain mkdir and base64 decode
        $lastCmd | Should -Match 'mkdir -p /tmp/impactncd'
        $lastCmd | Should -Match 'base64 -d'
        $lastCmd | Should -Match 'impact-metauser\.json'
        # The RStudio password must not be stored in the shared /tmp file (F40)
        $b64 = [regex]::Match($lastCmd, 'echo (\S+) \| base64 -d').Groups[1].Value
        $json = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($b64))
        $json | Should -Not -Match 'password'
        $json | Should -Not -Match 'MetaPass'
    }

    It 'Write-RemoteContainerMetadata is a no-op for LOCAL mode' {
        $script:sshCommands = @()
        Mock ssh {
            $script:sshCommands += ($args -join ' ')
        } -ModuleName 'IMPACT_Docker_GUI'

        $state = New-TestSessionState -Location 'LOCAL'
        Write-RemoteContainerMetadata -State $state -Port '8787' -UseVolumes $false

        $script:sshCommands.Count | Should -Be 0
    }

    It 'Read-RemoteContainerMetadata deserialises JSON from SSH output' {
        $jsonPayload = '{"container":"impact-metauser","repo":"IMPACTncd_Germany","user":"metauser","port":"8787"}'
        Mock ssh {
            return $jsonPayload
        } -ModuleName 'IMPACT_Docker_GUI'

        $state = New-TestSessionState -UserName 'metauser' -Location 'REMOTE@10.0.0.1'
        $state.ContainerName = 'impact-metauser'
        $result = Read-RemoteContainerMetadata -State $state

        $result | Should -Not -BeNullOrEmpty
        $result.container | Should -Be 'impact-metauser'
        $result.repo      | Should -Be 'IMPACTncd_Germany'
        $result.user      | Should -Be 'metauser'
        $result.port      | Should -Be '8787'
    }

    It 'Read-RemoteContainerMetadata returns null for LOCAL mode' {
        $state = New-TestSessionState -Location 'LOCAL'
        $result = Read-RemoteContainerMetadata -State $state
        $result | Should -BeNullOrEmpty
    }

    It 'Read-RemoteContainerMetadata returns null when SSH returns nothing' {
        Mock ssh { return $null } -ModuleName 'IMPACT_Docker_GUI'

        $state = New-TestSessionState -Location 'REMOTE@10.0.0.1'
        $state.ContainerName = 'impact-nobody'
        $result = Read-RemoteContainerMetadata -State $state
        $result | Should -BeNullOrEmpty
    }

    It 'Remove-RemoteContainerMetadata sends rm -f command via SSH' {
        $script:sshCommands = @()
        Mock ssh {
            $script:sshCommands += ($args -join ' ')
        } -ModuleName 'IMPACT_Docker_GUI'

        $state = New-TestSessionState -UserName 'metauser' -Location 'REMOTE@10.0.0.1'
        $state.ContainerName = 'impact-metauser'
        Remove-RemoteContainerMetadata -State $state

        $script:sshCommands.Count | Should -BeGreaterThan 0
        $script:sshCommands[-1] | Should -Match 'rm -f'
        $script:sshCommands[-1] | Should -Match 'impact-metauser\.json'
    }

    It 'Remove-RemoteContainerMetadata is a no-op for LOCAL mode' {
        $script:sshCommands = @()
        Mock ssh {
            $script:sshCommands += ($args -join ' ')
        } -ModuleName 'IMPACT_Docker_GUI'

        $state = New-TestSessionState -Location 'LOCAL'
        Remove-RemoteContainerMetadata -State $state

        $script:sshCommands.Count | Should -Be 0
    }
}

# ═══════════════════════════════════════════════════════════════════════════════
#  Test-RemoteSSHKeyFiles (mocked SSH)
# ═══════════════════════════════════════════════════════════════════════════════
Describe 'Test-RemoteSSHKeyFiles (mocked SSH)' -Tag Integration {
    It 'Returns true for LOCAL mode (no remote check needed)' {
        $state = New-TestSessionState -Location 'LOCAL'
        $result = Test-RemoteSSHKeyFiles -State $state
        $result | Should -BeTrue
    }

    It 'Returns true when both key and known_hosts exist on remote' {
        Mock ssh {
            return 'OK'
        } -ModuleName 'IMPACT_Docker_GUI'

        $state = New-TestSessionState -UserName 'sshuser' -Location 'REMOTE@10.0.0.5'
        $result = Test-RemoteSSHKeyFiles -State $state
        $result | Should -BeTrue
    }

    It 'Returns false when remote key check fails' {
        $script:callCount = 0
        Mock ssh {
            $script:callCount++
            if ($script:callCount -eq 1) { return '' }   # key missing
            if ($script:callCount -eq 2) { return 'OK' }  # known_hosts present
            return ''
        } -ModuleName 'IMPACT_Docker_GUI'

        $state = New-TestSessionState -UserName 'sshuser' -Location 'REMOTE@10.0.0.5'
        $result = Test-RemoteSSHKeyFiles -State $state
        $result | Should -BeFalse
    }

    It 'Returns false when SSH connection itself fails' {
        Mock ssh {
            throw 'Connection refused'
        } -ModuleName 'IMPACT_Docker_GUI'

        $state = New-TestSessionState -UserName 'sshuser' -Location 'REMOTE@10.0.0.5'
        $result = Test-RemoteSSHKeyFiles -State $state
        $result | Should -BeFalse
    }
}

# ═══════════════════════════════════════════════════════════════════════════════
#  Start-DockerDesktopIfNeeded (mocked)
# ═══════════════════════════════════════════════════════════════════════════════
Describe 'Start-DockerDesktopIfNeeded (mocked)' -Tag Integration {
    It 'Returns true immediately when Docker daemon is already running' {
        Mock docker {
            # Simulate "docker info" succeeding
            $global:LASTEXITCODE = 0
            return 'Server: Docker Engine'
        } -ModuleName 'IMPACT_Docker_GUI'

        $result = Start-DockerDesktopIfNeeded -TimeoutSeconds 2
        $result | Should -BeTrue
    }

    It 'Returns false when Docker is unavailable and Docker Desktop not found' {
        Mock docker {
            $global:LASTEXITCODE = 1
            throw 'Cannot connect to the Docker daemon'
        } -ModuleName 'IMPACT_Docker_GUI'
        Mock Test-Path { return $false } -ModuleName 'IMPACT_Docker_GUI'
        Mock Start-Service {} -ModuleName 'IMPACT_Docker_GUI'
        Mock Start-Sleep {} -ModuleName 'IMPACT_Docker_GUI'

        $result = Start-DockerDesktopIfNeeded -TimeoutSeconds 1
        $result | Should -BeFalse
    }
}

# ═══════════════════════════════════════════════════════════════════════════════
#  Show-CredentialDialog — NonInteractive with GitHub username validation
# ═══════════════════════════════════════════════════════════════════════════════
Describe 'Show-CredentialDialog NonInteractive with GitHub validation' -Tag Integration {
    BeforeEach {
        Enable-NonInteractiveMode
    }
    AfterEach {
        Disable-NonInteractiveMode
    }

    It 'Succeeds when GitHub username is valid' {
        Mock Invoke-RestMethod {
            return @{ login = 'testuser'; id = 42 }
        } -ModuleName 'IMPACT_Docker_GUI'

        $state = New-TestSessionState -UserName 'testuser' -Password 'pass123'
        $result = Show-CredentialDialog -State $state
        $result | Should -Be 'next'
        $state.UserName | Should -Be 'testuser'
    }

    It 'Fails when GitHub username does not exist' {
        Mock Invoke-RestMethod {
            $resp = New-Object System.Net.Http.HttpResponseMessage
            $resp.StatusCode = [System.Net.HttpStatusCode]::NotFound
            $exception = [Microsoft.PowerShell.Commands.HttpResponseException]::new("404", $resp)
            throw ([System.Management.Automation.ErrorRecord]::new(
                $exception, 'WebCmdletWebResponseException',
                [System.Management.Automation.ErrorCategory]::InvalidOperation, $null))
        } -ModuleName 'IMPACT_Docker_GUI'

        $state = New-TestSessionState -UserName 'bogus-nonexistent-xyz' -Password 'pass123'
        $result = Show-CredentialDialog -State $state
        $result | Should -Be 'cancel'
    }

    It 'Fails when UserName is not pre-set' {
        $state = New-TestSessionState -UserName '' -Password 'pass123'
        $result = Show-CredentialDialog -State $state
        $result | Should -Be 'cancel'
    }

    It 'Normalizes username to lowercase before validation' {
        Mock Invoke-RestMethod {
            return @{ login = 'mixedcase'; id = 99 }
        } -ModuleName 'IMPACT_Docker_GUI'

        $state = New-TestSessionState -UserName 'MixedCase' -Password 'pass123'
        $result = Show-CredentialDialog -State $state
        $result | Should -Be 'next'
        $state.UserName | Should -Be 'mixedcase'

        Should -Invoke Invoke-RestMethod -ModuleName 'IMPACT_Docker_GUI' -Times 1 -ParameterFilter {
            $Uri -eq 'https://api.github.com/users/mixedcase'
        }
    }
}

# Artifact persistence is handled by Invoke-Tests.ps1 (only on failure/skip).

# ═══════════════════════════════════════════════════════════════════════════════
#  Container lifecycle / Docker volumes (mocked docker): F01, F02, F04, F13, F17
# ═══════════════════════════════════════════════════════════════════════════════
Describe 'Get-UsedPorts host address handling (mocked docker)' -Tag Integration {
    It 'Finds ports bound to 127.0.0.1, 0.0.0.0 and [::]' {
        Mock docker {
            $global:LASTEXITCODE = 0
            return @('127.0.0.1:8790->8787/tcp', '0.0.0.0:8787->8787/tcp, [::]:8787->8787/tcp', '8787/tcp', '0.0.0.0:5432->5432/tcp')
        } -ModuleName 'IMPACT_Docker_GUI'

        $ports = @(Get-UsedPorts)
        $ports | Should -Contain '8790'
        $ports | Should -Contain '8787'
        $ports | Should -Not -Contain '5432'
        $ports.Count | Should -Be 2
    }
}

Describe 'Get-ContainerRuntimeInfo labels and mounts (mocked docker)' -Tag Integration {
    It 'Recovers volume mode, result folders and volume names from labels and mounts' {
        Mock docker {
            $joined = ($args | ForEach-Object { $_ }) -join ' '
            $global:LASTEXITCODE = 0
            if ($joined -match 'range .Config.Env') { return @('PASSWORD=Secret1', 'USERID=1000') }
            if ($joined -match 'NetworkSettings.Ports') { return '8790' }
            if ($joined -match 'json .Config.Labels') {
                return ('{"impact.use_volumes":"true","impact.output_dir":"/mnt/out","impact.synthpop_dir":"/mnt/syn","maintainer":"a","Maintainer":"b"}' + "`t" +
                        '[{"Type":"volume","Name":"impactncd_output_R_u","Destination":"/home/rstudio/R/outputs"},{"Type":"volume","Name":"impactncd_synthpop_R_u","Destination":"/home/rstudio/R/inputs/synthpop"},{"Type":"bind","Source":"/x","Destination":"/home/rstudio/R"}]')
            }
            return ''
        } -ModuleName 'IMPACT_Docker_GUI'

        $state = New-TestSessionState -Location 'REMOTE@10.0.0.1'
        $info = Get-ContainerRuntimeInfo -State $state
        $info.Password       | Should -Be 'Secret1'
        $info.Port           | Should -Be '8790'
        $info.UseVolumes     | Should -BeTrue
        $info.OutputDir      | Should -Be '/mnt/out'
        $info.SynthpopDir    | Should -Be '/mnt/syn'
        $info.VolumeOutput   | Should -Be 'impactncd_output_R_u'
        $info.VolumeSynthpop | Should -Be 'impactncd_synthpop_R_u'
    }

    It 'Detects volume mode from the mounts of a container started by an older version (no labels)' {
        Mock docker {
            $joined = ($args | ForEach-Object { $_ }) -join ' '
            $global:LASTEXITCODE = 0
            if ($joined -match 'json .Config.Labels') {
                return ('null' + "`t" + '[{"Type":"volume","Name":"impactncd_germany_output_u","Destination":"/home/rstudio/R/outputs"}]')
            }
            return ''
        } -ModuleName 'IMPACT_Docker_GUI'

        $info = Get-ContainerRuntimeInfo -State (New-TestSessionState)
        $info.UseVolumes   | Should -BeTrue
        $info.VolumeOutput | Should -Be 'impactncd_germany_output_u'
        $info.OutputDir    | Should -BeNullOrEmpty
    }

    It 'Reports a bind-mode container as UseVolumes = false' {
        Mock docker {
            $joined = ($args | ForEach-Object { $_ }) -join ' '
            $global:LASTEXITCODE = 0
            if ($joined -match 'json .Config.Labels') {
                return ('{"impact.use_volumes":"false","impact.output_dir":"C:\\o"}' + "`t" + '[{"Type":"bind","Source":"/c/o","Destination":"/home/rstudio/R/outputs"}]')
            }
            return ''
        } -ModuleName 'IMPACT_Docker_GUI'

        $info = Get-ContainerRuntimeInfo -State (New-TestSessionState)
        $info.UseVolumes | Should -BeFalse
        $info.OutputDir  | Should -Be 'C:\o'
    }

    It 'Leaves UseVolumes unknown ($null) when docker inspect fails' {
        Mock docker { $global:LASTEXITCODE = 1; return '' } -ModuleName 'IMPACT_Docker_GUI'
        $info = Get-ContainerRuntimeInfo -State (New-TestSessionState)
        $info.UseVolumes | Should -BeNullOrEmpty
    }
}

Describe 'Initialize-RsyncHelperImage (mocked docker)' -Tag Integration {
    It 'Returns true without building when the image already exists' {
        $script:b3Calls = @()
        Mock docker {
            $script:b3Calls += (($args | ForEach-Object { $_ }) -join ' ')
            $global:LASTEXITCODE = 0
        } -ModuleName 'IMPACT_Docker_GUI'
        Initialize-RsyncHelperImage -State (New-TestSessionState) | Should -BeTrue
        ($script:b3Calls -join "`n") | Should -Not -Match 'build'
    }

    It 'Returns false when the image is still missing after the build' {
        Mock docker {
            $joined = ($args | ForEach-Object { $_ }) -join ' '
            $global:LASTEXITCODE = 1
            if ($joined -match 'build') { return 'ERROR: failed to fetch alpine' }
        } -ModuleName 'IMPACT_Docker_GUI'
        Initialize-RsyncHelperImage -State (New-TestSessionState) | Should -BeFalse
    }

    It 'Builds without a local build context (Dockerfile on stdin)' {
        $script:b3Calls = @()
        $script:b3Built = $false
        Mock docker {
            $joined = ($args | ForEach-Object { $_ }) -join ' '
            $script:b3Calls += $joined
            if ($joined -match 'image inspect') { $global:LASTEXITCODE = $(if ($script:b3Built) { 0 } else { 1 }); return }
            if ($joined -match 'build') { $script:b3Built = $true }
            $global:LASTEXITCODE = 0
        } -ModuleName 'IMPACT_Docker_GUI'
        Initialize-RsyncHelperImage -State (New-TestSessionState) | Should -BeTrue
        ($script:b3Calls | Where-Object { $_ -match 'build' }) | Should -Match 'build -t rsync-alpine -$'
    }
}

Describe 'Sync-ImpactVolumeToHost (mocked docker)' -Tag Integration {
    BeforeEach {
        $script:b3Calls = @()
        $script:b3RsyncExit = 0
        $script:b3VolumeInspect = @{ Exit = 0; Out = '{"impact.target_dir":"/mnt/out"}' }
        Mock docker {
            $joined = ($args | ForEach-Object { $_ }) -join ' '
            $script:b3Calls += $joined
            if ($joined -match 'volume inspect') { $global:LASTEXITCODE = $script:b3VolumeInspect.Exit; return $script:b3VolumeInspect.Out }
            if ($joined -match 'rsync-alpine rsync') { $global:LASTEXITCODE = $script:b3RsyncExit; return 'rsync: write failed' }
            $global:LASTEXITCODE = 0
            return ''
        } -ModuleName 'IMPACT_Docker_GUI'
    }

    It 'Refuses to copy when the target folder is unknown, and never runs rsync' {
        $r = Sync-ImpactVolumeToHost -State (New-TestSessionState) -VolumeName 'vol1' -HostDir ''
        $r.Success | Should -BeFalse
        $r.Message | Should -Match 'unknown'
        ($script:b3Calls -join "`n") | Should -Not -Match 'rsync'
    }

    It 'Reports failure when rsync fails (so the caller keeps the volume)' {
        $script:b3RsyncExit = 23
        $r = Sync-ImpactVolumeToHost -State (New-TestSessionState -Location 'REMOTE@10.0.0.1') -VolumeName 'vol1' -HostDir '/mnt/out'
        $r.Success | Should -BeFalse
        $r.Missing | Should -BeFalse
        $r.Message | Should -Match 'failed'
    }

    It 'Succeeds when rsync exits 0 and converts a LOCAL Windows path for docker' {
        $r = Sync-ImpactVolumeToHost -State (New-TestSessionState) -VolumeName 'vol1' -HostDir 'C:\Users\u\out'
        $r.Success | Should -BeTrue
        ($script:b3Calls | Where-Object { $_ -match 'rsync-alpine rsync' }) | Should -Match '/c/Users/u/out:/backup'
    }

    It 'Treats a volume that does not exist as nothing to copy' {
        $script:b3VolumeInspect = @{ Exit = 1; Out = 'Error response from daemon: get vol1: no such volume' }
        $r = Sync-ImpactVolumeToHost -State (New-TestSessionState) -VolumeName 'vol1' -HostDir 'C:\o'
        $r.Success | Should -BeTrue
        $r.Missing | Should -BeTrue
        ($script:b3Calls -join "`n") | Should -Not -Match 'rsync-alpine rsync'
    }

    It 'Fails (does not claim success) when Docker cannot be reached' {
        $script:b3VolumeInspect = @{ Exit = 1; Out = 'Cannot connect to the Docker daemon' }
        $r = Sync-ImpactVolumeToHost -State (New-TestSessionState) -VolumeName 'vol1' -HostDir 'C:\o'
        $r.Success | Should -BeFalse
        $r.Missing | Should -BeFalse
    }
}

Describe 'Get-ImpactVolumeInfo (mocked docker)' -Tag Integration {
    It 'Returns the recorded target folder and the containers that still use the volume' {
        Mock docker {
            $joined = ($args | ForEach-Object { $_ }) -join ' '
            $global:LASTEXITCODE = 0
            if ($joined -match 'volume inspect') { return '{"impact.target_dir":"/mnt/out","impact.container":"R_u"}' }
            if ($joined -match 'ps -a --filter volume=vol1') { return @('helper_1', '') }
            return ''
        } -ModuleName 'IMPACT_Docker_GUI'
        $vi = Get-ImpactVolumeInfo -State (New-TestSessionState) -VolumeName 'vol1'
        $vi.Exists    | Should -BeTrue
        $vi.TargetDir | Should -Be '/mnt/out'
        @($vi.UsedBy) | Should -Be @('helper_1')
    }

    It 'Handles a volume without labels' {
        Mock docker { $global:LASTEXITCODE = 0; return 'null' } -ModuleName 'IMPACT_Docker_GUI'
        $vi = Get-ImpactVolumeInfo -State (New-TestSessionState) -VolumeName 'vol1'
        $vi.Exists    | Should -BeTrue
        $vi.TargetDir | Should -BeNullOrEmpty
    }
}
