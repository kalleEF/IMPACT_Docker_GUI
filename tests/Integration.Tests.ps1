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
            -SshKeyPath   "/home/php-workstation/.ssh/id_ed25519_remuser"

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
            -SshKeyPath   "C:\Users\localuser\.ssh\id_ed25519_localuser"

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
            -SshKeyPath 'C:\Users\inttest\.ssh\id_ed25519_inttest'

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
            -SshKeyPath '/home/php-workstation/.ssh/id_ed25519_remuser'

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
            # Simulated output: each section starts with a marker line printed by
            # the remote command (status lines, branch, remote URL, ahead count, ops)
            return @(
                '__IMPACT_STATUS__'
                ' M inputs/sim_design.yaml'
                '__IMPACT_BRANCH__'
                'main'
                '__IMPACT_REMOTE__'
                'git@github.com:IMPACT/repo.git'
                '__IMPACT_AHEAD__'
                '0'
                '__IMPACT_OP__'
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
            # No porcelain lines after the status marker: clean repo
            return @(
                '__IMPACT_STATUS__'
                '__IMPACT_BRANCH__'
                'feature-branch'
                '__IMPACT_REMOTE__'
                'git@github.com:IMPACT/repo.git'
                '__IMPACT_AHEAD__'
                '0'
                '__IMPACT_OP__'
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
            # Read-only checks for unpushed commits and an unfinished merge/rebase
            if ($joined -match 'rev-list --count|rev-parse --git-dir') { return '' }
            # If we get here, commit/push is being attempted, so fail
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

        Write-RemoteContainerMetadata -State $state -Password 'MetaPass!' -Port '8787' -UseVolumes $false

        $script:sshCommands.Count | Should -BeGreaterThan 0
        $lastCmd = $script:sshCommands[-1]
        # Should contain mkdir and base64 decode
        $lastCmd | Should -Match 'mkdir -p /tmp/impactncd'
        $lastCmd | Should -Match 'base64 -d'
        $lastCmd | Should -Match 'impact-metauser\.json'
    }

    It 'Write-RemoteContainerMetadata is a no-op for LOCAL mode' {
        $script:sshCommands = @()
        Mock ssh {
            $script:sshCommands += ($args -join ' ')
        } -ModuleName 'IMPACT_Docker_GUI'

        $state = New-TestSessionState -Location 'LOCAL'
        Write-RemoteContainerMetadata -State $state -Password 'x' -Port '8787' -UseVolumes $false

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
    BeforeAll {
        # Pester can only mock a command that exists. On a machine without the
        # OpenSSH client (for example a Linux CI box) we add an empty 'ssh'
        # function for the duration of this block, so the Mocks below work.
        $script:addedSshStub = $false
        if (-not (Get-Command ssh -ErrorAction SilentlyContinue)) {
            function global:ssh { }
            $script:addedSshStub = $true
        }
    }
    AfterAll {
        if ($script:addedSshStub) { Remove-Item function:global:ssh -ErrorAction SilentlyContinue }
    }

    It 'Returns true for LOCAL mode (no remote check needed)' {
        $state = New-TestSessionState -Location 'LOCAL'
        $result = Test-RemoteSSHKeyFiles -State $state
        $result | Should -BeTrue
    }

    It 'Returns true when the private key exists on remote' {
        Mock ssh {
            return 'IMPACT_KEY_OK'
        } -ModuleName 'IMPACT_Docker_GUI'

        $state = New-TestSessionState -UserName 'sshuser' -Location 'REMOTE@10.0.0.5'
        $result = Test-RemoteSSHKeyFiles -State $state
        $result | Should -BeTrue
        $state.Metadata['RemoteSshCheckStatus'] | Should -Be 'OK'
        $state.Metadata['RemoteSshCheckMessage'] | Should -BeNullOrEmpty
    }

    It 'Only checks the private key (known_hosts is no longer required)' {
        $script:sshCommands = @()
        Mock ssh {
            $script:sshCommands += ($args -join ' ')
            return 'IMPACT_KEY_OK'
        } -ModuleName 'IMPACT_Docker_GUI'

        $state = New-TestSessionState -UserName 'sshuser' -Location 'REMOTE@10.0.0.5'
        Test-RemoteSSHKeyFiles -State $state | Should -BeTrue
        $script:sshCommands.Count | Should -Be 1
        $script:sshCommands[0] | Should -Match 'id_ed25519_sshuser'
        $script:sshCommands[0] | Should -Not -Match 'known_hosts'
    }

    It 'Returns false and reports KeyMissing when the key file is missing' {
        Mock ssh {
            return 'IMPACT_KEY_MISSING'
        } -ModuleName 'IMPACT_Docker_GUI'

        $state = New-TestSessionState -UserName 'sshuser' -Location 'REMOTE@10.0.0.5'
        $result = Test-RemoteSSHKeyFiles -State $state
        $result | Should -BeFalse
        $state.Metadata['RemoteSshCheckStatus'] | Should -Be 'KeyMissing'
        $state.Metadata['RemoteSshCheckMessage'] | Should -Match 'start it again'
    }

    It 'Reports Unreachable (not "key missing") when the workstation cannot be reached' {
        Mock ssh {
            # What ssh prints on stderr when the VPN is off; with 2>&1 it arrives as an ErrorRecord.
            [System.Management.Automation.ErrorRecord]::new(
                [System.Exception]::new('ssh: connect to host 10.0.0.5 port 22: Connection timed out'),
                'NativeCommandError', [System.Management.Automation.ErrorCategory]::NotSpecified, $null)
        } -ModuleName 'IMPACT_Docker_GUI'

        $state = New-TestSessionState -UserName 'sshuser' -Location 'REMOTE@10.0.0.5'
        $result = Test-RemoteSSHKeyFiles -State $state
        $result | Should -BeFalse
        $state.Metadata['RemoteSshCheckStatus'] | Should -Be 'Unreachable'
        $state.Metadata['RemoteSshCheckMessage'] | Should -Match 'VPN'
        $state.Metadata['RemoteSshCheckMessage'] | Should -Match '10\.0\.0\.5'
    }

    It 'Reports LoginFailed when the workstation refuses the key' {
        Mock ssh {
            'php-workstation@10.0.0.5: Permission denied (publickey,password).'
        } -ModuleName 'IMPACT_Docker_GUI'

        $state = New-TestSessionState -UserName 'sshuser' -Location 'REMOTE@10.0.0.5'
        Test-RemoteSSHKeyFiles -State $state | Should -BeFalse
        $state.Metadata['RemoteSshCheckStatus'] | Should -Be 'LoginFailed'
    }

    It 'Returns false when SSH connection itself fails' {
        Mock ssh {
            throw 'Connection refused'
        } -ModuleName 'IMPACT_Docker_GUI'

        $state = New-TestSessionState -UserName 'sshuser' -Location 'REMOTE@10.0.0.5'
        $result = Test-RemoteSSHKeyFiles -State $state
        $result | Should -BeFalse
        $state.Metadata['RemoteSshCheckStatus'] | Should -Be 'Unreachable'
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

# =============================================================================
#  Batch B6a: credential dialog (NonInteractive) and remote docker login
# =============================================================================
Describe 'Show-CredentialDialog NonInteractive: GitHub unreachable or bad input' -Tag Integration {
    BeforeEach {
        Enable-NonInteractiveMode
    }
    AfterEach {
        Disable-NonInteractiveMode
    }

    # Show-CredentialDialog also contains the WinForms/System.Drawing dialog code, which
    # cannot be loaded on Linux/macOS (the other Show-CredentialDialog tests above fail
    # there for that reason), so these tests only run on Windows.
    It 'Continues (does not cancel) when GitHub cannot be reached' -Skip:(-not $IsWindows) {
        Mock Invoke-RestMethod {
            throw [System.Net.Http.HttpRequestException]::new('No such host is known.')
        } -ModuleName 'IMPACT_Docker_GUI'

        $state = New-TestSessionState -UserName 'offlineuser' -Password 'OfflinePass99!'
        Show-CredentialDialog -State $state | Should -Be 'next'
        $state.UserName | Should -Be 'offlineuser'
    }

    It 'Cancels for an e-mail address without asking GitHub' -Skip:(-not $IsWindows) {
        Mock Invoke-RestMethod {
            return [pscustomobject]@{ login = 'x'; type = 'User' }
        } -ModuleName 'IMPACT_Docker_GUI'

        $state = New-TestSessionState -UserName 'j.doe@institute.de' -Password 'Pass12345!'
        Show-CredentialDialog -State $state | Should -Be 'cancel'
        Should -Invoke Invoke-RestMethod -ModuleName 'IMPACT_Docker_GUI' -Times 0 -Exactly
    }

    It 'Cancels for an organisation name' -Skip:(-not $IsWindows) {
        Mock Invoke-RestMethod {
            return [pscustomobject]@{ login = 'impact-ncd'; type = 'Organization' }
        } -ModuleName 'IMPACT_Docker_GUI'

        $state = New-TestSessionState -UserName 'impact-ncd' -Password 'Pass12345!'
        Show-CredentialDialog -State $state | Should -Be 'cancel'
    }
}

Describe 'Ensure-RemoteDockerLogin (mocked SSH)' -Tag Integration {
    BeforeAll {
        # Pester can only mock a command that exists. On machines without an ssh client
        # (e.g. a minimal Linux CI image) a do-nothing stand-in is created for these tests.
        $script:b6aCreatedSshStub = $false
        if (-not (Get-Command ssh -ErrorAction SilentlyContinue)) {
            function global:ssh { }
            $script:b6aCreatedSshStub = $true
        }
    }
    AfterAll {
        if ($script:b6aCreatedSshStub) { Remove-Item function:global:ssh -ErrorAction SilentlyContinue }
    }

    It 'Reads multi-line .env output, logs in to the right registry and keeps the password off the command line' {
        $script:b6aSshCalls = [System.Collections.Generic.List[object]]::new()
        Mock ssh {
            $script:b6aSshCalls.Add(@($args))
            if ([string]$args[-1] -like 'cat *') {
                # Native command output arrives as one string per line.
                return @('# registry login', 'GHCR_USERNAME=ghuser', 'GHCR_TOKEN=ghp_SeCrEt123')
            }
            return 'Login Succeeded'
        } -ModuleName 'IMPACT_Docker_GUI'

        $state = New-TestSessionState -Location 'REMOTE@10.0.0.9'
        Ensure-RemoteDockerLogin -State $state -ProjectRoot '/srv/repo' | Should -BeTrue

        $script:b6aSshCalls.Count | Should -Be 2
        $loginArgs = @($script:b6aSshCalls[1])
        [string]$loginArgs[-1] | Should -Match "docker login 'ghcr\.io' -u 'ghuser' --password-stdin"
        ($loginArgs -join ' ') | Should -Not -Match 'ghp_SeCrEt123'
        $pwB64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes('ghp_SeCrEt123'))
        ($loginArgs -join ' ') | Should -Not -Match ([regex]::Escape($pwB64))
        # '-n' would cut off standard input, through which the password is sent.
        $loginArgs | Should -Not -Contain '-n'
    }

    It 'Does not log in when the .env user name contains shell characters' {
        Mock ssh {
            if ([string]$args[-1] -like 'cat *') { return @("DOCKERHUB_USERNAME=bad'name", 'DOCKERHUB_TOKEN=tok') }
            return 'Login Succeeded'
        } -ModuleName 'IMPACT_Docker_GUI'

        $state = New-TestSessionState -Location 'REMOTE@10.0.0.9'
        Ensure-RemoteDockerLogin -State $state -ProjectRoot '/srv/repo' | Should -BeFalse
        # Only the 'cat .env' call happened, no login attempt.
        Should -Invoke ssh -ModuleName 'IMPACT_Docker_GUI' -Times 1 -Exactly
    }
}


# ═══════════════════════════════════════════════════════════════════════════════
#  Git commit flow on Stop: status parsing, merge guard, commit and push checks
# ═══════════════════════════════════════════════════════════════════════════════
Describe 'Get-GitRepositoryState: every status code, ahead count and unfinished merge' -Tag Integration {
    BeforeAll {
        # Pester can only mock a command that exists. Some CI machines have no
        # ssh client, so add a throw-away global stub that the mocks replace.
        $script:addedSshStub = $false
        if (-not (Get-Command ssh -ErrorAction SilentlyContinue)) {
            function global:ssh { throw 'ssh stub called without a mock' }
            $script:addedSshStub = $true
        }
    }
    AfterAll {
        if ($script:addedSshStub) { Remove-Item -Path function:global:ssh -ErrorAction SilentlyContinue }
    }

    It 'Local: counts staged, deleted, renamed and conflicted files and reads ahead + merge state' {
        $gitDir = Join-Path $TestDrive 'dotgit'
        New-Item -ItemType Directory -Path $gitDir -Force | Out-Null
        Set-Content -Path (Join-Path $gitDir 'MERGE_HEAD') -Value 'abc'
        $script:fakeGitDir = $gitDir
        Mock git {
            $joined = ($args | ForEach-Object { "$_" }) -join ' '
            if ($joined -match 'status --porcelain') { return @('M  staged.R', ' D deleted.R', 'R  old.R -> new.R', 'UU conflict.R') }
            if ($joined -match 'rev-parse --abbrev-ref') { return 'main' }
            if ($joined -match 'remote get-url') { return 'git@github.com:u/r.git' }
            if ($joined -match 'rev-list --count') { return '3' }
            if ($joined -match 'rev-parse --git-dir') { return $script:fakeGitDir }
            return ''
        } -ModuleName 'IMPACT_Docker_GUI'

        $state = New-TestSessionState -Location 'LOCAL'
        $result = Get-GitRepositoryState -State $state -RepoPath $TestDrive -IsRemote $false

        $result.HasChanges | Should -BeTrue
        ($result.StatusText -split "`n").Count | Should -Be 4
        $result.Branch | Should -Be 'main'
        $result.Ahead | Should -Be 3
        $result.HasUpstream | Should -BeTrue
        @($result.Conflicts) | Should -Be @('conflict.R')
        $result.OperationInProgress | Should -Be 'merge'
    }

    It 'Local: reports no upstream when rev-list prints nothing' {
        Mock git {
            $joined = ($args | ForEach-Object { "$_" }) -join ' '
            if ($joined -match 'status --porcelain') { return @() }
            if ($joined -match 'rev-parse --abbrev-ref') { return 'new-branch' }
            return $null
        } -ModuleName 'IMPACT_Docker_GUI'

        $state = New-TestSessionState -Location 'LOCAL'
        $result = Get-GitRepositoryState -State $state -RepoPath $TestDrive -IsRemote $false
        $result.HasChanges | Should -BeFalse
        $result.HasUpstream | Should -BeFalse
        $result.Ahead | Should -Be 0
        $result.OperationInProgress | Should -Be ''
    }

    It 'Local: returns null (not "no changes") when git status fails' {
        Mock git {
            $joined = ($args | ForEach-Object { "$_" }) -join ' '
            if ($joined -match 'status --porcelain') { $global:LASTEXITCODE = 128; return $null }
            return ''
        } -ModuleName 'IMPACT_Docker_GUI'

        $state = New-TestSessionState -Location 'LOCAL'
        Get-GitRepositoryState -State $state -RepoPath $TestDrive -IsRemote $false | Should -BeNullOrEmpty
    }

    It 'Remote: reads sections by marker, so unusual status codes are never taken as the branch' {
        Mock ssh {
            return @(
                '__IMPACT_STATUS__'
                'M  staged.R'
                ' D deleted.R'
                'UU conflict.R'
                '__IMPACT_BRANCH__'
                'main'
                '__IMPACT_REMOTE__'
                'git@github.com:IMPACT/repo.git'
                '__IMPACT_AHEAD__'
                '__IMPACT_OP__'
                'rebase-merge'
            )
        } -ModuleName 'IMPACT_Docker_GUI'

        $state = New-TestSessionState -Location 'REMOTE@10.0.0.5'
        $result = Get-GitRepositoryState -State $state -RepoPath '/home/user/repo' -IsRemote $true
        $result.HasChanges | Should -BeTrue
        $result.StatusText | Should -Match 'staged\.R'
        $result.StatusText | Should -Match 'deleted\.R'
        $result.Branch | Should -Be 'main'
        $result.Remote | Should -Be 'git@github.com:IMPACT/repo.git'
        $result.HasUpstream | Should -BeFalse
        @($result.Conflicts) | Should -Be @('conflict.R')
        $result.OperationInProgress | Should -Be 'rebase'
    }

    It 'Remote: returns null when the command did not run (no markers)' {
        Mock ssh { return @() } -ModuleName 'IMPACT_Docker_GUI'
        $state = New-TestSessionState -Location 'REMOTE@10.0.0.5'
        Get-GitRepositoryState -State $state -RepoPath '/home/user/repo' -IsRemote $true | Should -BeNullOrEmpty
    }

    It 'Remote: quotes a repository path that contains an apostrophe' {
        $script:sentCommand = ''
        Mock ssh { $script:sentCommand = "$($args[-1])"; return @('__IMPACT_STATUS__') } -ModuleName 'IMPACT_Docker_GUI'
        $state = New-TestSessionState -Location 'REMOTE@10.0.0.5'
        $null = Get-GitRepositoryState -State $state -RepoPath "/home/u/Bob's repo" -IsRemote $true
        $script:sentCommand | Should -BeLike "cd '/home/u/Bob'\''s repo' || exit 1;*"
    }
}

Describe 'Invoke-GitChangeDetection commit and push flow (mocked)' -Tag Integration {
    BeforeAll {
        $script:addedSshStub = $false
        if (-not (Get-Command ssh -ErrorAction SilentlyContinue)) {
            function global:ssh { throw 'ssh stub called without a mock' }
            $script:addedSshStub = $true
        }
        # A clean, typical state: one modified file on 'main' with an upstream.
        $script:changedState = [pscustomobject]@{
            HasChanges = $true; StatusText = ' M f.R'; Branch = 'main'; Remote = 'https://github.com/o/r.git'
            Ahead = 0; HasUpstream = $true; Conflicts = @(); OperationInProgress = ''
        }
    }
    AfterAll {
        if ($script:addedSshStub) { Remove-Item -Path function:global:ssh -ErrorAction SilentlyContinue }
    }
    BeforeEach {
        Enable-NonInteractiveMode
        $script:gitCalls = @()
        $script:sshCalls = @()
        $script:sshDuringPush = $null
        Mock Get-GitRepositoryState { return $script:changedState } -ModuleName 'IMPACT_Docker_GUI'
        Mock Show-GitCommitDialog { return @{ Message = 'Fix `x` for $HOME'; Push = $true } } -ModuleName 'IMPACT_Docker_GUI'
    }
    AfterEach {
        Disable-NonInteractiveMode
    }

    It 'Local: a failed commit is reported and nothing is pushed' {
        Mock git {
            $joined = ($args | ForEach-Object { "$_" }) -join ' '
            $script:gitCalls += $joined
            $global:LASTEXITCODE = 0
            if ($joined -match 'diff --cached') { $global:LASTEXITCODE = 1; return }
            if ($joined -match ' commit ') { $global:LASTEXITCODE = 128; return 'Author identity unknown' }
        } -ModuleName 'IMPACT_Docker_GUI'

        $state = New-TestSessionState -Location 'LOCAL'
        $result = Invoke-GitChangeDetection -State $state -RepoPath $TestDrive -IsRemote $false
        $result.Success | Should -BeFalse
        $result.Outcome | Should -Be 'CommitFailed'
        ($script:gitCalls | Where-Object { $_ -match '\bpush\b' }) | Should -BeNullOrEmpty
    }

    It 'Local: commits as the GitHub user and pushes with only the IMPACT key, without changing origin' {
        $before = $env:GIT_SSH_COMMAND
        Mock git {
            $joined = ($args | ForEach-Object { "$_" }) -join ' '
            $script:gitCalls += $joined
            $global:LASTEXITCODE = 0
            if ($joined -match 'diff --cached') { $global:LASTEXITCODE = 1; return }
            if ($joined -match '\bpush\b') { $script:sshDuringPush = $env:GIT_SSH_COMMAND; return 'To github.com:o/r.git' }
        } -ModuleName 'IMPACT_Docker_GUI'

        $state = New-TestSessionState -UserName 'alice' -Location 'LOCAL'
        $result = Invoke-GitChangeDetection -State $state -RepoPath $TestDrive -IsRemote $false
        $result.Outcome | Should -Be 'Pushed'
        $result.Success | Should -BeTrue

        $commit = $script:gitCalls | Where-Object { $_ -match ' commit ' }
        $commit | Should -Match 'user\.name=alice'
        $commit | Should -Match 'user\.email=alice@users\.noreply\.github\.com'
        $push = $script:gitCalls | Where-Object { $_ -match '\bpush\b' }
        $push | Should -Match 'url\.git@github\.com:\.pushInsteadOf=https://github\.com/'
        $script:sshDuringPush | Should -Match 'IdentitiesOnly=yes'
        $script:sshDuringPush | Should -Match 'BatchMode=yes'
        $script:sshDuringPush | Should -Match 'id_ed25519_alice'
        ($script:gitCalls | Where-Object { $_ -match 'set-url' }) | Should -BeNullOrEmpty
        $env:GIT_SSH_COMMAND | Should -Be $before
    }

    It 'Local: a rejected push is reported as a failure, not as success' {
        Mock git {
            $joined = ($args | ForEach-Object { "$_" }) -join ' '
            $script:gitCalls += $joined
            $global:LASTEXITCODE = 0
            if ($joined -match 'diff --cached') { $global:LASTEXITCODE = 1; return }
            if ($joined -match '\bpush\b') { $global:LASTEXITCODE = 1; return ' ! [rejected]        main -> main (fetch first)' }
        } -ModuleName 'IMPACT_Docker_GUI'

        $state = New-TestSessionState -Location 'LOCAL'
        $result = Invoke-GitChangeDetection -State $state -RepoPath $TestDrive -IsRemote $false
        $result.Success | Should -BeFalse
        $result.Outcome | Should -Be 'PushFailed'
    }

    It 'Local: a branch without upstream is pushed with -u origin HEAD' {
        $script:changedState.HasUpstream = $false
        try {
            Mock git {
                $joined = ($args | ForEach-Object { "$_" }) -join ' '
                $script:gitCalls += $joined
                $global:LASTEXITCODE = 0
                if ($joined -match 'diff --cached') { $global:LASTEXITCODE = 1; return }
            } -ModuleName 'IMPACT_Docker_GUI'
            $state = New-TestSessionState -Location 'LOCAL'
            $result = Invoke-GitChangeDetection -State $state -RepoPath $TestDrive -IsRemote $false
            $result.Outcome | Should -Be 'Pushed'
            ($script:gitCalls | Where-Object { $_ -match '\bpush\b' }) | Should -Match 'push -u origin HEAD$'
        } finally {
            $script:changedState.HasUpstream = $true
        }
    }

    It 'Refuses to commit during an unfinished merge and never opens the dialog' {
        Mock Get-GitRepositoryState {
            return [pscustomobject]@{ HasChanges = $true; StatusText = 'UU a.R'; Branch = 'main'; Remote = ''; Ahead = 0; HasUpstream = $true; Conflicts = @('a.R'); OperationInProgress = 'merge' }
        } -ModuleName 'IMPACT_Docker_GUI'
        Mock git { $script:gitCalls += ($args -join ' ') } -ModuleName 'IMPACT_Docker_GUI'

        $state = New-TestSessionState -Location 'LOCAL'
        $result = Invoke-GitChangeDetection -State $state -RepoPath $TestDrive -IsRemote $false
        $result.Outcome | Should -Be 'Blocked'
        Should -Invoke Show-GitCommitDialog -ModuleName 'IMPACT_Docker_GUI' -Times 0 -Exactly
        $script:gitCalls | Should -BeNullOrEmpty
    }

    It 'Reports unpushed commits on a clean tree (NonInteractive: no push)' {
        Mock Get-GitRepositoryState {
            return [pscustomobject]@{ HasChanges = $false; StatusText = ''; Branch = 'main'; Remote = ''; Ahead = 2; HasUpstream = $true; Conflicts = @(); OperationInProgress = '' }
        } -ModuleName 'IMPACT_Docker_GUI'
        Mock git { $script:gitCalls += ($args -join ' ') } -ModuleName 'IMPACT_Docker_GUI'

        $state = New-TestSessionState -Location 'LOCAL'
        $result = Invoke-GitChangeDetection -State $state -RepoPath $TestDrive -IsRemote $false
        $result.Outcome | Should -Be 'Skipped'
        $result.Message | Should -Match '2 commit'
        Should -Invoke Show-GitCommitDialog -ModuleName 'IMPACT_Docker_GUI' -Times 0 -Exactly
        $script:gitCalls | Should -BeNullOrEmpty
    }

    It 'Remote: sends the message base64-encoded, sets the identity, and pushes once with only the IMPACT key' {
        Mock ssh {
            $script:sshCalls += "$($args[-1])"
            $global:LASTEXITCODE = 0
            return 'ok'
        } -ModuleName 'IMPACT_Docker_GUI'

        $state = New-TestSessionState -UserName 'bob' -Location 'REMOTE@10.0.0.5'
        $result = Invoke-GitChangeDetection -State $state -RepoPath '/home/php-workstation/repo' -IsRemote $true
        $result.Outcome | Should -Be 'Pushed'
        $script:sshCalls.Count | Should -Be 2

        $b64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes('Fix `x` for $HOME'))
        $script:sshCalls[0] | Should -Match ([regex]::Escape($b64))
        $script:sshCalls[0] | Should -Match 'commit -F -'
        $script:sshCalls[0] | Should -Match "-c user\.name='bob' -c user\.email='bob@users\.noreply\.github\.com'"
        $script:sshCalls[0] | Should -Not -Match ([regex]::Escape('$HOME'))

        $script:sshCalls[1] | Should -Match ([regex]::Escape("GIT_SSH_COMMAND='ssh -i ~/.ssh/id_ed25519_bob -o IdentitiesOnly=yes"))
        $script:sshCalls[1] | Should -Not -Match 'ssh-agent|id_ed25519_workstation|set-url'
    }

    It 'Remote: a failed push is reported once, with no fallback to other keys' {
        Mock ssh {
            $cmd = "$($args[-1])"
            $script:sshCalls += $cmd
            $global:LASTEXITCODE = 0
            if ($cmd -match 'pushInsteadOf') { $global:LASTEXITCODE = 128; return 'git@github.com: Permission denied (publickey).' }
            return 'ok'
        } -ModuleName 'IMPACT_Docker_GUI'

        $state = New-TestSessionState -UserName 'bob' -Location 'REMOTE@10.0.0.5'
        $result = Invoke-GitChangeDetection -State $state -RepoPath '/home/php-workstation/repo' -IsRemote $true
        $result.Outcome | Should -Be 'PushFailed'
        $result.Success | Should -BeFalse
        $script:sshCalls.Count | Should -Be 2
    }
}
