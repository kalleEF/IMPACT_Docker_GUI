<#
.SYNOPSIS
    Pester 5 unit tests for IMPACT Docker GUI pure-logic functions.
    These tests do NOT require Docker, SSH, or a network connection.

    Run:  pwsh -File tests/Invoke-Tests.ps1 -Tag Unit
#>

BeforeAll {
    # Many tests build temp paths from $env:TEMP, which exists on Windows only. On Linux
    # (CI containers, developer machines) it is empty, so Join-Path failed before the
    # test could check anything. Use the system temp folder there instead.
    if (-not $env:TEMP) { $env:TEMP = [System.IO.Path]::GetTempPath() }

    # Import the module under test
    $modulePath = Join-Path $PSScriptRoot '..' 'current_version' 'IMPACT_Docker_GUI.psm1'
    Import-Module $modulePath -Force -DisableNameChecking

    # Import test helpers
    . (Join-Path $PSScriptRoot 'Helpers' 'TestSessionState.ps1')
}

# ═══════════════════════════════════════════════════════════════════════════════
#  New-SessionState
# ═══════════════════════════════════════════════════════════════════════════════
Describe 'New-SessionState' -Tag Unit {
    It 'Returns a PSCustomObject with all expected top-level properties' {
        $state = New-SessionState
        $state | Should -Not -BeNullOrEmpty
        $state.PSObject.Properties.Name | Should -Contain 'UserName'
        $state.PSObject.Properties.Name | Should -Contain 'Password'
        $state.PSObject.Properties.Name | Should -Contain 'RemoteHost'
        $state.PSObject.Properties.Name | Should -Contain 'RemoteHostIp'
        $state.PSObject.Properties.Name | Should -Contain 'RemoteUser'
        $state.PSObject.Properties.Name | Should -Contain 'ContainerLocation'
        $state.PSObject.Properties.Name | Should -Contain 'SelectedRepo'
        $state.PSObject.Properties.Name | Should -Contain 'ContainerName'
        $state.PSObject.Properties.Name | Should -Contain 'Paths'
        $state.PSObject.Properties.Name | Should -Contain 'Flags'
        $state.PSObject.Properties.Name | Should -Contain 'Ports'
        $state.PSObject.Properties.Name | Should -Contain 'Metadata'
    }

    It 'Has correct default RemoteUser' {
        $state = New-SessionState
        $state.RemoteUser | Should -Be 'php-workstation'
    }

    It 'Has Paths hashtable with expected keys' {
        $state = New-SessionState
        $state.Paths.Keys | Should -Contain 'LocalRepo'
        $state.Paths.Keys | Should -Contain 'RemoteRepo'
        $state.Paths.Keys | Should -Contain 'OutputDir'
        $state.Paths.Keys | Should -Contain 'SynthpopDir'
        $state.Paths.Keys | Should -Contain 'SshPrivate'
        $state.Paths.Keys | Should -Contain 'SshPublic'
    }

    It 'Has Flags hashtable with expected keys' {
        $state = New-SessionState
        $state.Flags.Keys | Should -Contain 'Debug'
        $state.Flags.Keys | Should -Contain 'UseDirectSsh'
        $state.Flags.Keys | Should -Contain 'UseVolumes'
        $state.Flags.Keys | Should -Contain 'Rebuild'
        $state.Flags.Keys | Should -Contain 'HighComputeDemand'
        $state.Flags.Keys | Should -Contain 'PS7Requested'
    }

    It 'Sets Debug to false by default' {
        $state = New-SessionState
        $state.Flags.Debug | Should -BeFalse
    }

    It 'Records PS7Requested flag' {
        $state = New-SessionState -PS7Requested
        $state.Flags.PS7Requested | Should -BeTrue
    }
}

# ═══════════════════════════════════════════════════════════════════════════════
#  Convert-PathToDockerFormat
# ═══════════════════════════════════════════════════════════════════════════════
Describe 'Convert-PathToDockerFormat' -Tag Unit {
    It 'Converts a simple Windows path' {
        Convert-PathToDockerFormat -Path 'C:\Users\test\repo' | Should -Be '/c/Users/test/repo'
    }

    It 'Converts uppercase drive letter to lowercase' {
        Convert-PathToDockerFormat -Path 'D:\Data' | Should -Be '/d/Data'
    }

    It 'Handles trailing backslash' {
        Convert-PathToDockerFormat -Path 'C:\Users\test\' | Should -Be '/c/Users/test'
    }

    It 'Handles path without drive letter (POSIX-like)' {
        Convert-PathToDockerFormat -Path '/home/user/repo' | Should -Be '/home/user/repo'
    }

    It 'Replaces all backslashes with forward slashes' {
        Convert-PathToDockerFormat -Path 'relative\path\to\dir' | Should -Be 'relative/path/to/dir'
    }

    It 'Collapses multiple slashes' {
        Convert-PathToDockerFormat -Path 'C:\\Users\\test' | Should -Be '/c/Users/test'
    }

    It 'Handles single drive letter' {
        Convert-PathToDockerFormat -Path 'C:\' | Should -Be '/c'
    }
}

# ═══════════════════════════════════════════════════════════════════════════════
#  Get-RemoteHostString
# ═══════════════════════════════════════════════════════════════════════════════
Describe 'Get-RemoteHostString' -Tag Unit {
    It 'Returns RemoteHost when set' {
        $state = New-TestSessionState -Location 'REMOTE@10.0.0.1'
        $state.RemoteHost = 'php-workstation@10.0.0.1'
        Get-RemoteHostString -State $state | Should -Be 'php-workstation@10.0.0.1'
    }

    It 'Falls back to RemoteHostIp when RemoteHost is null' {
        $state = New-TestSessionState -Location 'REMOTE@10.0.0.2'
        $state.RemoteHost = $null
        $state.RemoteHostIp = '10.0.0.2'
        Get-RemoteHostString -State $state | Should -Be '10.0.0.2'
    }
}

# ═══════════════════════════════════════════════════════════════════════════════
#  Get-DockerContextArgs
# ═══════════════════════════════════════════════════════════════════════════════
Describe 'Get-DockerContextArgs' -Tag Unit {
    It 'Returns empty array for LOCAL without explicit context' {
        $state = New-TestSessionState -Location 'LOCAL'
        $result = Get-DockerContextArgs -State $state
        $result | Should -HaveCount 0
    }

    It 'Returns context args for LOCAL with explicit context' {
        $state = New-TestSessionState -Location 'LOCAL'
        $state.Metadata.LocalDockerContext = 'desktop-linux'
        $result = Get-DockerContextArgs -State $state
        $result | Should -HaveCount 2
        $result[0] | Should -Be '--context'
        $result[1] | Should -Be 'desktop-linux'
    }

    It 'Returns empty array for REMOTE with UseDirectSsh' {
        $state = New-TestSessionState -Location 'REMOTE@10.0.0.1'
        $state.Flags.UseDirectSsh = $true
        $result = Get-DockerContextArgs -State $state
        $result | Should -HaveCount 0
    }

    It 'Returns context args for REMOTE with named context' {
        $state = New-TestSessionState -Location 'REMOTE@10.0.0.1'
        $state.Metadata.RemoteDockerContext = 'remote-ctx'
        $result = Get-DockerContextArgs -State $state
        $result | Should -HaveCount 2
        $result[0] | Should -Be '--context'
        $result[1] | Should -Be 'remote-ctx'
    }
}

# ═══════════════════════════════════════════════════════════════════════════════
#  Remove-SshConfigHostBlock
# ═══════════════════════════════════════════════════════════════════════════════
Describe 'Remove-SshConfigHostBlock' -Tag Unit {
    BeforeEach {
        $testDir = Join-Path $env:TEMP "impact_sshconfig_test_$([guid]::NewGuid().ToString('N').Substring(0,8))"
        New-Item -ItemType Directory -Path $testDir -Force | Out-Null
        $configFile = Join-Path $testDir 'config'
    }

    AfterEach {
        Remove-Item -Recurse -Force -Path $testDir -ErrorAction SilentlyContinue
    }

    It 'Removes a matching Host block' {
        $content = @"
Host github.com
    User git

# IMPACT Docker GUI entry
Host 10.0.0.5
    User php-workstation
    IdentityFile ~/.ssh/id_ed25519_testuser

Host other.host
    User admin
"@
        Set-Content -Path $configFile -Value $content

        $result = Remove-SshConfigHostBlock -ConfigPath $configFile -HostPattern '10.0.0.5'
        $result | Should -BeTrue

        $remaining = Get-Content $configFile -Raw
        $remaining | Should -Not -Match 'Host 10\.0\.0\.5'
        $remaining | Should -Not -Match 'IMPACT Docker GUI'
        $remaining | Should -Match 'Host github.com'
        $remaining | Should -Match 'Host other.host'
    }

    It 'Returns false when no matching Host block found' {
        Set-Content -Path $configFile -Value "Host github.com`n    User git"
        $result = Remove-SshConfigHostBlock -ConfigPath $configFile -HostPattern '10.0.0.99'
        $result | Should -BeFalse
    }

    It 'Returns false when config file does not exist' {
        $result = Remove-SshConfigHostBlock -ConfigPath (Join-Path $testDir 'nonexistent') -HostPattern '10.0.0.1'
        $result | Should -BeFalse
    }

    It 'Preserves other Host blocks intact' {
        $content = @"
Host first.host
    User user1
    Port 22

Host target.host
    User targetuser
    IdentityFile ~/.ssh/id_key

Host last.host
    User user3
"@
        Set-Content -Path $configFile -Value $content

        Remove-SshConfigHostBlock -ConfigPath $configFile -HostPattern 'target.host'
        $remaining = Get-Content $configFile -Raw
        $remaining | Should -Match 'Host first.host'
        $remaining | Should -Match 'Host last.host'
        $remaining | Should -Not -Match 'Host target.host'
    }

    It 'Removes the IMPACT comment line preceding the Host block' {
        $content = @"
# Unrelated comment
Host keep.me
    User keepuser

# IMPACT Docker GUI — auto-generated entry
Host 192.168.1.100
    User php-workstation
    IdentityFile ~/.ssh/id_ed25519_user
"@
        Set-Content -Path $configFile -Value $content

        Remove-SshConfigHostBlock -ConfigPath $configFile -HostPattern '192.168.1.100'
        $remaining = Get-Content $configFile -Raw
        $remaining | Should -Not -Match 'IMPACT'
        $remaining | Should -Match 'Unrelated comment'
    }
}

# ═══════════════════════════════════════════════════════════════════════════════
#  Get-YamlPathValue — LOCAL mode (sim_design_local.yaml with Windows paths)
# ═══════════════════════════════════════════════════════════════════════════════
Describe 'Get-YamlPathValue (LOCAL / sim_design_local.yaml)' -Tag Unit {
    BeforeEach {
        $testDir = Join-Path $env:TEMP "impact_yaml_test_$([guid]::NewGuid().ToString('N').Substring(0,8))"
        New-Item -ItemType Directory -Path $testDir -Force | Out-Null
        # LOCAL containers use sim_design_local.yaml with Windows-friendly relative paths
        $yamlFile = Join-Path $testDir 'sim_design_local.yaml'
    }

    AfterEach {
        Remove-Item -Recurse -Force -Path $testDir -ErrorAction SilentlyContinue
    }

    It 'Reads output_dir from sim_design_local.yaml' {
        Set-Content -Path $yamlFile -Value "output_dir: ./outputs`nsynthpop_dir: ./inputs/synthpop"
        $state = New-TestSessionState -Location 'LOCAL'
        $result = Get-YamlPathValue -State $state -YamlPath $yamlFile -Key 'output_dir' -BaseDir ($testDir -replace '\\', '/')
        $result | Should -Match 'outputs$'
    }

    It 'Reads synthpop_dir from sim_design_local.yaml' {
        Set-Content -Path $yamlFile -Value "output_dir: ./outputs`nsynthpop_dir: ./inputs/synthpop"
        $state = New-TestSessionState -Location 'LOCAL'
        $result = Get-YamlPathValue -State $state -YamlPath $yamlFile -Key 'synthpop_dir' -BaseDir ($testDir -replace '\\', '/')
        $result | Should -Match 'inputs/synthpop$'
    }

    It 'Returns null for missing key' {
        Set-Content -Path $yamlFile -Value "output_dir: ./outputs`nsynthpop_dir: ./inputs/synthpop"
        $state = New-TestSessionState -Location 'LOCAL'
        $result = Get-YamlPathValue -State $state -YamlPath $yamlFile -Key 'nonexistent_key' -BaseDir ($testDir -replace '\\', '/')
        $result | Should -BeNullOrEmpty
    }

    It 'Returns null for missing file' {
        $state = New-TestSessionState -Location 'LOCAL'
        $result = Get-YamlPathValue -State $state -YamlPath (Join-Path $testDir 'nope.yaml') -Key 'output_dir' -BaseDir ($testDir -replace '\\', '/')
        $result | Should -BeNullOrEmpty
    }

    It 'Strips inline comments from value' {
        Set-Content -Path $yamlFile -Value "output_dir: ./outputs  # local output directory"
        $state = New-TestSessionState -Location 'LOCAL'
        $result = Get-YamlPathValue -State $state -YamlPath $yamlFile -Key 'output_dir' -BaseDir ($testDir -replace '\\', '/')
        $result | Should -Not -Match '#'
        $result | Should -Match 'outputs$'
    }

    It 'Resolves relative path against a Windows-style BaseDir' {
        Set-Content -Path $yamlFile -Value "output_dir: ./outputs`nsynthpop_dir: ./inputs/synthpop"
        $state = New-TestSessionState -Location 'LOCAL'
        # Windows BaseDir (forward-slashed) – result must NOT start with "/" so Test-AndCreateDirectory accepts it
        $baseDir = 'C:/Users/testuser/repos/IMPACTncd_Germany'
        $result = Get-YamlPathValue -State $state -YamlPath $yamlFile -Key 'synthpop_dir' -BaseDir $baseDir
        $result | Should -BeLike 'C:/Users/testuser/repos/IMPACTncd_Germany*inputs/synthpop'
        # Ensure it does NOT look like a POSIX absolute path (starting with /)
        $result | Should -Not -Match '^\/'
    }

    It 'Keeps a Windows absolute path as-is when specified in local YAML' {
        Set-Content -Path $yamlFile -Value "output_dir: C:/Users/testuser/Documents/IMPACTncd_Germany/outputs"
        $state = New-TestSessionState -Location 'LOCAL'
        $result = Get-YamlPathValue -State $state -YamlPath $yamlFile -Key 'output_dir' -BaseDir 'C:/Users/testuser/repos/IMPACTncd_Germany'
        $result | Should -Be 'C:/Users/testuser/Documents/IMPACTncd_Germany/outputs'
    }
}

# ═══════════════════════════════════════════════════════════════════════════════
#  Get-YamlPathValue — REMOTE mode (sim_design.yaml with POSIX paths)
#  SSH is mocked so the function reads YAML content without a real connection.
# ═══════════════════════════════════════════════════════════════════════════════
Describe 'Get-YamlPathValue (REMOTE / sim_design.yaml)' -Tag Unit {
    BeforeEach {
        $testDir = Join-Path $env:TEMP "impact_yaml_test_$([guid]::NewGuid().ToString('N').Substring(0,8))"
        New-Item -ItemType Directory -Path $testDir -Force | Out-Null
        # REMOTE containers use sim_design.yaml with POSIX paths
        $script:remoteYamlFile = Join-Path $testDir 'sim_design.yaml'
    }

    AfterEach {
        Remove-Item -Recurse -Force -Path $testDir -ErrorAction SilentlyContinue
    }

    It 'Returns absolute /mnt output_dir as-is from remote sim_design.yaml' {
        $yaml = "output_dir: /mnt/Storage_1/IMPACT_Storage/Base/outputs`nsynthpop_dir: /mnt/Storage_1/IMPACT_Storage/Base/inputs/synthpop"
        Set-Content -Path $script:remoteYamlFile -Value $yaml
        Mock ssh { "output_dir: /mnt/Storage_1/IMPACT_Storage/Base/outputs`nsynthpop_dir: /mnt/Storage_1/IMPACT_Storage/Base/inputs/synthpop" } -ModuleName 'IMPACT_Docker_GUI'

        $state = New-TestSessionState -Location 'REMOTE@10.152.14.124'
        $baseDir = '/home/php-workstation/Schreibtisch/Repositories/IMPACTncd_Germany'
        $result = Get-YamlPathValue -State $state -YamlPath $script:remoteYamlFile -Key 'output_dir' -BaseDir $baseDir
        # Absolute path — returned as-is, NOT joined with BaseDir
        $result | Should -Be '/mnt/Storage_1/IMPACT_Storage/Base/outputs'
    }

    It 'Returns absolute /mnt synthpop_dir as-is from remote sim_design.yaml' {
        $yaml = "output_dir: /mnt/Storage_1/IMPACT_Storage/Base/outputs`nsynthpop_dir: /mnt/Storage_1/IMPACT_Storage/Base/inputs/synthpop"
        Set-Content -Path $script:remoteYamlFile -Value $yaml
        Mock ssh { "output_dir: /mnt/Storage_1/IMPACT_Storage/Base/outputs`nsynthpop_dir: /mnt/Storage_1/IMPACT_Storage/Base/inputs/synthpop" } -ModuleName 'IMPACT_Docker_GUI'

        $state = New-TestSessionState -Location 'REMOTE@10.152.14.124'
        $baseDir = '/home/php-workstation/Schreibtisch/Repositories/IMPACTncd_Germany'
        $result = Get-YamlPathValue -State $state -YamlPath $script:remoteYamlFile -Key 'synthpop_dir' -BaseDir $baseDir
        $result | Should -Be '/mnt/Storage_1/IMPACT_Storage/Base/inputs/synthpop'
    }

    It 'Strips inline comment from remote YAML value' {
        $yaml = "output_dir: /mnt/Storage_1/IMPACT_Storage/Base/outputs  # main output mount"
        Set-Content -Path $script:remoteYamlFile -Value $yaml
        Mock ssh { "output_dir: /mnt/Storage_1/IMPACT_Storage/Base/outputs  # main output mount" } -ModuleName 'IMPACT_Docker_GUI'

        $state = New-TestSessionState -Location 'REMOTE@10.152.14.124'
        $baseDir = '/home/php-workstation/Schreibtisch/Repositories/IMPACTncd_Germany'
        $result = Get-YamlPathValue -State $state -YamlPath $script:remoteYamlFile -Key 'output_dir' -BaseDir $baseDir
        $result | Should -Not -Match '#'
        $result | Should -Be '/mnt/Storage_1/IMPACT_Storage/Base/outputs'
    }
}

# ═══════════════════════════════════════════════════════════════════════════════
#  Build-DockerRunCommand
# ═══════════════════════════════════════════════════════════════════════════════
Describe 'Build-DockerRunCommand' -Tag Unit {
    BeforeAll {
        $baseState = New-TestSessionState -UserName 'alice' -Password 'secret' -SelectedRepo 'IMPACTncd_Germany'
    }

    It 'Returns an array starting with "run"' {
        $args = Build-DockerRunCommand -State $baseState -ImageName 'test-image' `
            -ProjectRoot 'C:\repos\IMPACTncd_Germany' `
            -OutputDir 'C:\repos\IMPACTncd_Germany\outputs' `
            -SynthpopDir 'C:\repos\IMPACTncd_Germany\inputs\synthpop' `
            -SshKeyPath 'C:\Users\alice\.ssh\id_ed25519_alice'

        $args[0] | Should -Be 'run'
    }

    It 'Includes container name from state' {
        $args = Build-DockerRunCommand -State $baseState -ImageName 'test-image' `
            -ProjectRoot 'C:\repos\IMPACTncd_Germany' `
            -OutputDir 'C:\repos\IMPACTncd_Germany\outputs' `
            -SynthpopDir 'C:\repos\IMPACTncd_Germany\inputs\synthpop' `
            -SshKeyPath 'C:\Users\alice\.ssh\id_ed25519_alice'

        $args | Should -Contain $baseState.ContainerName
    }

    It 'Sets PASSWORD environment variable' {
        $args = Build-DockerRunCommand -State $baseState -ImageName 'test-image' `
            -ProjectRoot 'C:\repos\IMPACTncd_Germany' `
            -OutputDir 'C:\repos\IMPACTncd_Germany\outputs' `
            -SynthpopDir 'C:\repos\IMPACTncd_Germany\inputs\synthpop' `
            -SshKeyPath 'C:\Users\alice\.ssh\id_ed25519_alice'

        $args | Should -Contain 'PASSWORD=secret'
    }

    It 'Maps port correctly' {
        $args = Build-DockerRunCommand -State $baseState -Port '9090' -ImageName 'test-image' `
            -ProjectRoot 'C:\repos\IMPACTncd_Germany' `
            -OutputDir 'C:\repos\IMPACTncd_Germany\outputs' `
            -SynthpopDir 'C:\repos\IMPACTncd_Germany\inputs\synthpop' `
            -SshKeyPath 'C:\Users\alice\.ssh\id_ed25519_alice'

        # LOCAL containers are published on 127.0.0.1 only (F13)
        $args | Should -Contain '127.0.0.1:9090:8787'
    }

    It 'Appends high-compute flags only for remote mode' {
        $remoteState = New-TestSessionState -UserName 'alice' -Password 'secret' -Location 'REMOTE@10.152.14.124'
        $args = Build-DockerRunCommand -State $remoteState -HighCompute $true -ImageName 'test-image' `
            -ProjectRoot '/home/php-workstation/Schreibtisch/Repositories/IMPACTncd_Germany' `
            -OutputDir '/mnt/Storage_1/IMPACT_Storage/Base/outputs' `
            -SynthpopDir '/mnt/Storage_1/IMPACT_Storage/Base/inputs/synthpop' `
            -SshKeyPath '/home/php-workstation/.ssh/id_ed25519_alice'

        $args | Should -Contain '--cpus'
        $args | Should -Contain '32'
        $args | Should -Contain '-m'
        $args | Should -Contain '384g'
    }

    It 'Does NOT append high-compute flags for local mode' {
        $args = Build-DockerRunCommand -State $baseState -HighCompute $true -ImageName 'test-image' `
            -ProjectRoot 'C:\repos\IMPACTncd_Germany' `
            -OutputDir 'C:\repos\IMPACTncd_Germany\outputs' `
            -SynthpopDir 'C:\repos\IMPACTncd_Germany\inputs\synthpop' `
            -SshKeyPath 'C:\Users\alice\.ssh\id_ed25519_alice'

        $args | Should -Not -Contain '--cpus'
    }

    It 'Uses Docker volumes when UseVolumes is true' {
        $args = Build-DockerRunCommand -State $baseState -UseVolumes $true -ImageName 'test-image' `
            -ProjectRoot 'C:\repos\IMPACTncd_Germany' `
            -OutputDir 'C:\repos\IMPACTncd_Germany\outputs' `
            -SynthpopDir 'C:\repos\IMPACTncd_Germany\inputs\synthpop' `
            -SshKeyPath 'C:\Users\alice\.ssh\id_ed25519_alice'

        $joined = $args -join ' '
        # Volume names include the container name (repo + user), see Get-ImpactVolumeNames (F48)
        $joined | Should -Match "-v.*impactncd_output_$($baseState.ContainerName)"
        $joined | Should -Match "-v.*impactncd_synthpop_$($baseState.ContainerName)"
    }

    It 'Uses bind mounts when UseVolumes is false' {
        $args = Build-DockerRunCommand -State $baseState -UseVolumes $false -ImageName 'test-image' `
            -ProjectRoot 'C:\repos\IMPACTncd_Germany' `
            -OutputDir 'C:\repos\IMPACTncd_Germany\outputs' `
            -SynthpopDir 'C:\repos\IMPACTncd_Germany\inputs\synthpop' `
            -SshKeyPath 'C:\Users\alice\.ssh\id_ed25519_alice'

        $joined = $args -join ' '
        $joined | Should -Match 'type=bind.*outputs'
        $joined | Should -Match 'type=bind.*synthpop'
    }

    It 'Includes image name as last argument' {
        $args = Build-DockerRunCommand -State $baseState -ImageName 'my-image' `
            -ProjectRoot 'C:\repos\IMPACTncd_Germany' `
            -OutputDir 'C:\repos\IMPACTncd_Germany\outputs' `
            -SynthpopDir 'C:\repos\IMPACTncd_Germany\inputs\synthpop' `
            -SshKeyPath 'C:\Users\alice\.ssh\id_ed25519_alice'

        $args[-1] | Should -Be 'my-image'
    }

    It 'Splits custom params into individual arguments' {
        $args = Build-DockerRunCommand -State $baseState -CustomParams '--gpus all --shm-size 4g' -ImageName 'test-image' `
            -ProjectRoot 'C:\repos\IMPACTncd_Germany' `
            -OutputDir 'C:\repos\IMPACTncd_Germany\outputs' `
            -SynthpopDir 'C:\repos\IMPACTncd_Germany\inputs\synthpop' `
            -SshKeyPath 'C:\Users\alice\.ssh\id_ed25519_alice'

        $args | Should -Contain '--gpus'
        $args | Should -Contain 'all'
        $args | Should -Contain '--shm-size'
        $args | Should -Contain '4g'
    }

    It 'Does not bind-mount the host known_hosts file' {
        # Regression: the host known_hosts often lacks github.com, which made
        # git pull fail inside the container with "Host key verification failed".
        $args = Build-DockerRunCommand -State $baseState -ImageName 'test-image' `
            -ProjectRoot 'C:\repos\IMPACTncd_Germany' `
            -OutputDir 'C:\repos\IMPACTncd_Germany\outputs' `
            -SynthpopDir 'C:\repos\IMPACTncd_Germany\inputs\synthpop' `
            -SshKeyPath 'C:\Users\alice\.ssh\id_ed25519_alice'

        ($args -join ' ') | Should -Not -Match 'known_hosts,readonly'
    }

    It 'Sets GIT_SSH_COMMAND to the writable known_hosts in the rstudio home' {
        $args = Build-DockerRunCommand -State $baseState -ImageName 'test-image' `
            -ProjectRoot 'C:\repos\IMPACTncd_Germany' `
            -OutputDir 'C:\repos\IMPACTncd_Germany\outputs' `
            -SynthpopDir 'C:\repos\IMPACTncd_Germany\inputs\synthpop' `
            -SshKeyPath 'C:\Users\alice\.ssh\id_ed25519_alice'

        $args | Should -Contain "GIT_SSH_COMMAND=$(Get-ContainerGitSshCommand -UserName 'alice')"
    }
}

Describe 'Container SSH setup for git' -Tag Unit {
    It 'GIT_SSH_COMMAND uses the user key, rstudio known_hosts and accept-new' {
        $cmd = Get-ContainerGitSshCommand -UserName 'alice'
        $cmd | Should -Match '-i /home/rstudio/\.ssh/id_ed25519_alice'
        $cmd | Should -Match 'IdentitiesOnly=yes'
        $cmd | Should -Match 'UserKnownHostsFile=/home/rstudio/\.ssh/known_hosts'
        $cmd | Should -Match 'StrictHostKeyChecking=accept-new'
        $cmd | Should -Not -Match '/etc/ssh/ssh_known_hosts'
    }

    It 'Setup command scans github.com host keys inside the container' {
        $cmd = Get-ContainerSshSetupCommand -UserName 'alice'
        $cmd | Should -Match 'ssh-keyscan .*github\.com'
        $cmd | Should -Match '> /home/rstudio/\.ssh/known_hosts\.tmp'
    }

    It 'A failed keyscan does not abort the ownership fix' {
        $cmd = Get-ContainerSshSetupCommand -UserName 'alice'
        $cmd | Should -Match 'github\.com 2>/dev/null \|\| true'
    }

    It 'Copies the key with CR characters stripped and mode 600' {
        $cmd = Get-ContainerSshSetupCommand -UserName 'alice'
        $cmd | Should -Match "tr -d '\\r' < /keys/id_ed25519_alice > /home/rstudio/\.ssh/id_ed25519_alice"
        $cmd | Should -Match 'chmod 600 /home/rstudio/\.ssh/id_ed25519_alice'
    }

    It 'Chowns the .ssh directory to the given uid:gid and ends with KEY_FIXED' {
        $cmd = Get-ContainerSshSetupCommand -UserName 'alice' -ContainerUid '1001' -ContainerGid '1002'
        $cmd | Should -Match 'chown -R 1001:1002 /home/rstudio/\.ssh'
        $cmd | Should -Match 'echo KEY_FIXED$'
    }
}

# ═══════════════════════════════════════════════════════════════════════════════
#  Initialize-ThemePalette / Get-ThemePalette
# ═══════════════════════════════════════════════════════════════════════════════
Describe 'ThemePalette' -Tag Unit {
    BeforeAll {
        # Need System.Drawing for Color types
        try { Add-Type -AssemblyName System.Drawing -ErrorAction SilentlyContinue } catch { }
    }

    It 'Get-ThemePalette returns a hashtable with expected color keys' {
        $palette = Get-ThemePalette
        $palette | Should -Not -BeNullOrEmpty
        $palette.Keys | Should -Contain 'Back'
        $palette.Keys | Should -Contain 'Panel'
        $palette.Keys | Should -Contain 'Accent'
        $palette.Keys | Should -Contain 'Text'
        $palette.Keys | Should -Contain 'Muted'
        $palette.Keys | Should -Contain 'Danger'
        $palette.Keys | Should -Contain 'Success'
        $palette.Keys | Should -Contain 'Field'
    }

    It 'Color values are System.Drawing.Color instances' {
        $palette = Get-ThemePalette
        $palette.Back.GetType().FullName | Should -Be 'System.Drawing.Color'
    }
}

# ═══════════════════════════════════════════════════════════════════════════════
#  Non-interactive mode toggles
# ═══════════════════════════════════════════════════════════════════════════════
Describe 'NonInteractiveMode' -Tag Unit {
    AfterEach {
        # Always restore to off
        Disable-NonInteractiveMode
    }

    It 'Starts as disabled' {
        Disable-NonInteractiveMode
        Test-NonInteractiveMode | Should -BeFalse
    }

    It 'Can be enabled' {
        Enable-NonInteractiveMode
        Test-NonInteractiveMode | Should -BeTrue
    }

    It 'Can be disabled again' {
        Enable-NonInteractiveMode
        Disable-NonInteractiveMode
        Test-NonInteractiveMode | Should -BeFalse
    }
}

# ═══════════════════════════════════════════════════════════════════════════════
#  Get-BuildInfo
# ═══════════════════════════════════════════════════════════════════════════════
Describe 'Get-BuildInfo' -Tag Unit {
    It 'Returns an object with Version, Built, and Commit properties' {
        $bi = Get-BuildInfo
        $bi.PSObject.Properties.Name | Should -Contain 'Version'
        $bi.PSObject.Properties.Name | Should -Contain 'Built'
        $bi.PSObject.Properties.Name | Should -Contain 'Commit'
    }

    It 'Version is a valid semver string' {
        $bi = Get-BuildInfo
        $bi.Version | Should -Match '^\d+\.\d+\.\d+'
    }

    It 'Built is an ISO 8601 timestamp' {
        $bi = Get-BuildInfo
        $bi.Built | Should -Match '^\d{4}-\d{2}-\d{2}T'
    }
}

# ═══════════════════════════════════════════════════════════════════════════════
#  Set-DockerSSHEnvironment
# ═══════════════════════════════════════════════════════════════════════════════
Describe 'Set-DockerSSHEnvironment' -Tag Unit {
    AfterEach {
        $env:DOCKER_SSH_OPTS = $null
        $env:DOCKER_HOST = $null
    }

    It 'Clears env vars for LOCAL mode' {
        $env:DOCKER_SSH_OPTS = 'leftover'
        $env:DOCKER_HOST = 'leftover'
        $state = New-TestSessionState -Location 'LOCAL'
        Set-DockerSSHEnvironment -State $state
        $env:DOCKER_SSH_OPTS | Should -BeNullOrEmpty
        $env:DOCKER_HOST | Should -BeNullOrEmpty
    }

    It 'Sets DOCKER_SSH_OPTS for REMOTE mode' {
        $env:DOCKER_SSH_OPTS = $null
        $state = New-TestSessionState -Location 'REMOTE@10.0.0.1'
        Set-DockerSSHEnvironment -State $state
        $env:DOCKER_SSH_OPTS | Should -Not -BeNullOrEmpty
        $env:DOCKER_SSH_OPTS | Should -Match 'IdentitiesOnly'
    }

    It 'Sets DOCKER_HOST for UseDirectSsh' {
        $env:DOCKER_SSH_OPTS = $null
        $env:DOCKER_HOST = $null
        $state = New-TestSessionState -Location 'REMOTE@10.0.0.1'
        $state.Flags.UseDirectSsh = $true
        Set-DockerSSHEnvironment -State $state
        $env:DOCKER_HOST | Should -Match 'ssh://'
    }
}

# ═══════════════════════════════════════════════════════════════════════════════
#  Test-AndCreateDirectory (local only, no remote SSH)
# ═══════════════════════════════════════════════════════════════════════════════
Describe 'Test-AndCreateDirectory' -Tag Unit {
    It 'Returns true for an existing local directory' {
        $state = New-TestSessionState -Location 'LOCAL'
        $result = Test-AndCreateDirectory -State $state -Path $env:TEMP -PathKey 'test'
        $result | Should -BeTrue
    }

    It 'Returns false for a non-existent local directory' {
        $state = New-TestSessionState -Location 'LOCAL'
        $result = Test-AndCreateDirectory -State $state -Path (Join-Path $env:TEMP 'nonexistent_dir_12345') -PathKey 'test'
        $result | Should -BeFalse
    }

    It 'Returns false for null path' {
        $state = New-TestSessionState -Location 'LOCAL'
        $result = Test-AndCreateDirectory -State $state -Path $null -PathKey 'test'
        $result | Should -BeFalse
    }

    It 'Rejects POSIX absolute path in LOCAL mode' -Skip:(-not $IsWindows) {
        $state = New-TestSessionState -Location 'LOCAL'
        $result = Test-AndCreateDirectory -State $state -Path '/home/user/data' -PathKey 'test'
        $result | Should -BeFalse
    }

    It 'Does NOT reject POSIX path in REMOTE mode (handled via SSH)' {
        # In REMOTE mode the function shells out via SSH. We mock the ssh call
        # to simulate a directory that exists on the remote host.
        Mock ssh { return 'EXISTS' } -ModuleName 'IMPACT_Docker_GUI'

        $state = New-TestSessionState -Location 'REMOTE@10.0.0.5'
        $result = Test-AndCreateDirectory -State $state -Path '/home/php-workstation/Schreibtisch/Repositories/IMPACTncd_Germany/outputs' -PathKey 'output_dir'
        $result | Should -BeTrue
    }
}

# ═══════════════════════════════════════════════════════════════════════════════
#  Ensure-SshConfigEntry
# ═══════════════════════════════════════════════════════════════════════════════
Describe 'Ensure-SshConfigEntry' -Tag Unit {
    # (F108) These tests used to write to the developer's REAL ~/.ssh/config: PowerShell's
    # $HOME cannot be changed, so the function always used the real file. A crashed run
    # left a test entry behind, and the "replace the entry" cases were never tested.
    # Now every test works on a throw-away folder in the temp directory:
    #  - Join-Path is mocked for the one call inside the module that builds "$HOME/.ssh",
    #    so the module reads and writes <temp>/.ssh/config instead;
    #  - guard mocks make any write below the real ~/.ssh fail loudly (and do nothing)
    #    in case the module ever builds that path in another way.
    BeforeAll {
        $script:testIp = '198.51.100.99'  # RFC 5737 TEST-NET-3, won't collide with real entries
        $script:realSshDir = Join-Path $HOME '.ssh'

        # Reads the IdentityFile value(s) of the test host block. Quotes are allowed around
        # the value, so these tests keep working if the module starts quoting the path
        # (a path with spaces needs quotes in ~/.ssh/config).
        function Get-TestHostIdentityFiles {
            param([string]$ConfigPath, [string]$HostIp)
            $inBlock = $false
            foreach ($line in (Get-Content -LiteralPath $ConfigPath)) {
                if ($line -match '^\s*Host\s+(\S+)\s*$') { $inBlock = ($Matches[1] -eq $HostIp); continue }
                if ($inBlock -and $line -match '^\s*IdentityFile\s+"?([^"]+?)"?\s*$') { $Matches[1] }
            }
        }
    }

    BeforeEach {
        $script:fakeHome   = Join-Path ([System.IO.Path]::GetTempPath()) "impact_sshconfig_$([guid]::NewGuid().ToString('N').Substring(0,8))"
        $script:fakeSshDir = Join-Path $script:fakeHome '.ssh'
        $script:configPath = Join-Path $script:fakeSshDir 'config'
        New-Item -ItemType Directory -Path $script:fakeSshDir -Force | Out-Null

        # Two dummy key files, so the function does not treat them as "deleted".
        $keyDir = Join-Path $script:fakeHome 'keys'
        New-Item -ItemType Directory -Path $keyDir -Force | Out-Null
        $script:keyA = (Join-Path $keyDir 'id_ed25519_a') -replace '\\', '/'
        $script:keyB = (Join-Path $keyDir 'id_ed25519_b') -replace '\\', '/'
        Set-Content -LiteralPath $script:keyA -Value 'dummy-key-a'
        Set-Content -LiteralPath $script:keyB -Value 'dummy-key-b'

        # Redirect "$HOME/.ssh" inside the module to the temp folder. All other Join-Path
        # calls do not match the filter and run normally.
        Mock Join-Path -ModuleName 'IMPACT_Docker_GUI' -ParameterFilter { $Path -eq $HOME -and $ChildPath -eq '.ssh' } { $script:fakeSshDir }
        # Safety net: never touch the real ~/.ssh, whatever the module does.
        Mock Add-Content -ModuleName 'IMPACT_Docker_GUI' -ParameterFilter { "$Path" -like "$($script:realSshDir)*" } { throw "Test tried to write the real SSH folder: $Path" }
        Mock Set-Content -ModuleName 'IMPACT_Docker_GUI' -ParameterFilter { "$Path" -like "$($script:realSshDir)*" } { throw "Test tried to write the real SSH folder: $Path" }
        Mock New-Item    -ModuleName 'IMPACT_Docker_GUI' -ParameterFilter { "$Path" -like "$($script:realSshDir)*" } { throw "Test tried to create something in the real SSH folder: $Path" }
    }

    AfterEach {
        Remove-Item -Recurse -Force -LiteralPath $script:fakeHome -ErrorAction SilentlyContinue
    }

    It 'Creates an entry for a new host (in the temp folder, not in the real ~/.ssh)' {
        Ensure-SshConfigEntry -RemoteHostIp $script:testIp -RemoteUser 'php-workstation' -IdentityFile $script:keyA

        Test-Path -LiteralPath $script:configPath | Should -BeTrue -Because 'the redirected config file must have been written'
        $content = Get-Content -LiteralPath $script:configPath -Raw
        $content | Should -Match "(?m)^Host $([regex]::Escape($script:testIp))\s*$"
        $content | Should -Match '(?m)^\s+User php-workstation\s*$'
        $content | Should -Match '(?m)^\s+IdentitiesOnly yes\s*$'
        @(Get-TestHostIdentityFiles -ConfigPath $script:configPath -HostIp $script:testIp) | Should -Be @($script:keyA)
    }

    It 'Does not duplicate the entry on a second call with the same key' {
        Ensure-SshConfigEntry -RemoteHostIp $script:testIp -RemoteUser 'php-workstation' -IdentityFile $script:keyA
        Ensure-SshConfigEntry -RemoteHostIp $script:testIp -RemoteUser 'php-workstation' -IdentityFile $script:keyA

        $content = Get-Content -LiteralPath $script:configPath -Raw
        ([regex]::Matches($content, "(?m)^Host $([regex]::Escape($script:testIp))\s*$")).Count | Should -Be 1
    }

    # Windows only: the function turns '/' into '\' before checking that the key file
    # exists, so on Linux every existing entry looks like "deleted key" and is rewritten.
    # The GUI only runs on Windows, where an unchanged entry must be left alone.
    It 'Leaves a valid entry byte-for-byte unchanged' -Skip:(-not $IsWindows) {
        Ensure-SshConfigEntry -RemoteHostIp $script:testIp -RemoteUser 'php-workstation' -IdentityFile $script:keyA
        $before = Get-Content -LiteralPath $script:configPath -Raw
        Ensure-SshConfigEntry -RemoteHostIp $script:testIp -RemoteUser 'php-workstation' -IdentityFile $script:keyA
        Get-Content -LiteralPath $script:configPath -Raw | Should -BeExactly $before
    }

    It 'Keeps the entries of other hosts' {
        Set-Content -LiteralPath $script:configPath -Value @("Host github.com", "    User git", "", "Host other.example", "    User someone")
        Ensure-SshConfigEntry -RemoteHostIp $script:testIp -RemoteUser 'php-workstation' -IdentityFile $script:keyA

        $content = Get-Content -LiteralPath $script:configPath -Raw
        $content | Should -Match '(?m)^Host github\.com\s*$'
        $content | Should -Match '(?m)^Host other\.example\s*$'
        $content | Should -Match '(?m)^\s+User someone\s*$'
        @(Get-TestHostIdentityFiles -ConfigPath $script:configPath -HostIp $script:testIp) | Should -Be @($script:keyA)
    }

    It 'Replaces the entry when its key file was deleted' {
        $deletedKey = (Join-Path $script:fakeHome 'keys/id_ed25519_deleted') -replace '\\', '/'
        Set-Content -LiteralPath $script:configPath -Value @("Host $($script:testIp)", "    User php-workstation", "    IdentityFile $deletedKey")
        Ensure-SshConfigEntry -RemoteHostIp $script:testIp -RemoteUser 'php-workstation' -IdentityFile $script:keyA

        $content = Get-Content -LiteralPath $script:configPath -Raw
        ([regex]::Matches($content, "(?m)^Host $([regex]::Escape($script:testIp))\s*$")).Count | Should -Be 1
        @(Get-TestHostIdentityFiles -ConfigPath $script:configPath -HostIp $script:testIp) | Should -Be @($script:keyA)
    }

    It 'Replaces the entry when it points to a different key' {
        Set-Content -LiteralPath $script:configPath -Value @("Host $($script:testIp)", "    User php-workstation", "    IdentityFile $($script:keyB)")
        Ensure-SshConfigEntry -RemoteHostIp $script:testIp -RemoteUser 'php-workstation' -IdentityFile $script:keyA

        $content = Get-Content -LiteralPath $script:configPath -Raw
        ([regex]::Matches($content, "(?m)^Host $([regex]::Escape($script:testIp))\s*$")).Count | Should -Be 1
        @(Get-TestHostIdentityFiles -ConfigPath $script:configPath -HostIp $script:testIp) | Should -Be @($script:keyA)
    }

    It 'Rewrites an IdentityFile that uses backslashes with forward slashes' {
        $keyABackslash = $script:keyA -replace '/', '\'
        Set-Content -LiteralPath $script:configPath -Value @("Host $($script:testIp)", "    User php-workstation", "    IdentityFile $keyABackslash")
        Ensure-SshConfigEntry -RemoteHostIp $script:testIp -RemoteUser 'php-workstation' -IdentityFile $script:keyA

        $content = Get-Content -LiteralPath $script:configPath -Raw
        $content | Should -Not -Match ([regex]::Escape($keyABackslash))
        @(Get-TestHostIdentityFiles -ConfigPath $script:configPath -HostIp $script:testIp) | Should -Be @($script:keyA)
    }

    It 'Replaces a host block that has no IdentityFile line' {
        Set-Content -LiteralPath $script:configPath -Value @("Host $($script:testIp)", "    User someone-else")
        Ensure-SshConfigEntry -RemoteHostIp $script:testIp -RemoteUser 'php-workstation' -IdentityFile $script:keyA

        $content = Get-Content -LiteralPath $script:configPath -Raw
        ([regex]::Matches($content, "(?m)^Host $([regex]::Escape($script:testIp))\s*$")).Count | Should -Be 1
        $content | Should -Not -Match 'someone-else'
        @(Get-TestHostIdentityFiles -ConfigPath $script:configPath -HostIp $script:testIp) | Should -Be @($script:keyA)
    }
}

# ═══════════════════════════════════════════════════════════════════════════════
#  TestSessionState helper
# ═══════════════════════════════════════════════════════════════════════════════
Describe 'New-TestSessionState (helper)' -Tag Unit {
    It 'Creates a valid state with LOCAL location' {
        $state = New-TestSessionState -Location 'LOCAL'
        $state.ContainerLocation | Should -Be 'LOCAL'
        $state.UserName | Should -Be 'testuser'
    }

    It 'Creates a valid state with REMOTE location' {
        $state = New-TestSessionState -Location 'REMOTE@10.0.0.1'
        $state.ContainerLocation | Should -Be 'REMOTE@10.0.0.1'
        $state.RemoteHostIp | Should -Be '10.0.0.1'
    }

    It 'Sets SSH key paths in temp dir' {
        $state = New-TestSessionState
        $state.Paths.SshPrivate | Should -Match 'impact_test_ssh'
    }

    It 'New-DummySshKeyPair creates a usable (unencrypted) ed25519 keypair' {
        $kp = New-DummySshKeyPair -Label 'unit'
        Test-Path $kp.Private | Should -BeTrue
        Test-Path $kp.Public  | Should -BeTrue

        $pubOut = & ssh-keygen -y -f $kp.Private 2>$null
        $LASTEXITCODE | Should -Be 0 -Because 'New-DummySshKeyPair must create an unencrypted usable key'
        $pubOut | Should -Not -BeNullOrEmpty

        Remove-Item -Recurse -Force $kp.Dir -ErrorAction SilentlyContinue
    }
}

# ═══════════════════════════════════════════════════════════════════════════════
#  Get-NextAvailablePort
# ═══════════════════════════════════════════════════════════════════════════════
Describe 'Get-NextAvailablePort' -Tag Unit {
    It 'Returns 8787 when no ports are used' {
        Get-NextAvailablePort -UsedPorts @() | Should -Be '8787'
    }

    It 'Returns 8787 with default parameters' {
        Get-NextAvailablePort | Should -Be '8787'
    }

    It 'Skips used ports and returns the first available' {
        Get-NextAvailablePort -UsedPorts @('8787','8788') | Should -Be '8789'
    }

    It 'Returns the first gap in used ports' {
        Get-NextAvailablePort -UsedPorts @('8787','8789') | Should -Be '8788'
    }

    It 'Returns RangeStart when all ports are occupied' {
        $all = 8787..8799 | ForEach-Object { [string]$_ }
        Get-NextAvailablePort -UsedPorts $all | Should -Be '8787'
    }

    It 'Accepts custom range' {
        Get-NextAvailablePort -UsedPorts @('9000') -RangeStart 9000 -RangeEnd 9005 | Should -Be '9001'
    }

    It 'Returns a string' {
        $result = Get-NextAvailablePort -UsedPorts @()
        $result | Should -BeOfType [string]
    }
}

# ═══════════════════════════════════════════════════════════════════════════════
#  Test-PortValue
# ═══════════════════════════════════════════════════════════════════════════════
Describe 'Test-PortValue' -Tag Unit {
    It 'Accepts 8787 as valid' {
        $result = Test-PortValue -Port '8787'
        $result.Valid | Should -BeTrue
        $result.ErrorMessage | Should -BeNullOrEmpty
    }

    It 'Accepts 8799 as valid (upper bound)' {
        $result = Test-PortValue -Port '8799'
        $result.Valid | Should -BeTrue
    }

    It 'Rejects empty string' {
        $result = Test-PortValue -Port ''
        $result.Valid | Should -BeFalse
        $result.ErrorMessage | Should -Not -BeNullOrEmpty
    }

    It 'Rejects whitespace-only input' {
        $result = Test-PortValue -Port '   '
        $result.Valid | Should -BeFalse
    }

    It 'Rejects non-numeric input' {
        $result = Test-PortValue -Port 'abc'
        $result.Valid | Should -BeFalse
        $result.ErrorMessage | Should -Match 'number'
    }

    It 'Rejects mixed alphanumeric input' {
        $result = Test-PortValue -Port '87a87'
        $result.Valid | Should -BeFalse
        $result.ErrorMessage | Should -Match 'number'
    }

    It 'Rejects port below range' {
        $result = Test-PortValue -Port '8786'
        $result.Valid | Should -BeFalse
        $result.ErrorMessage | Should -Match '8787.*8799'
    }

    It 'Rejects port above range' {
        $result = Test-PortValue -Port '8800'
        $result.Valid | Should -BeFalse
        $result.ErrorMessage | Should -Match '8787.*8799'
    }

    It 'Accepts custom range' {
        $result = Test-PortValue -Port '9000' -RangeStart 9000 -RangeEnd 9010
        $result.Valid | Should -BeTrue
    }
}

# ═══════════════════════════════════════════════════════════════════════════════
#  Format-DockerError
# ═══════════════════════════════════════════════════════════════════════════════
Describe 'Format-DockerError' -Tag Unit {
    It 'Detects port-already-allocated errors' {
        $result = Format-DockerError -RawError 'Error response from daemon: Ports are not available: exposing port TCP 0.0.0.0:8787 -> 0.0.0.0:0: listen tcp4 0.0.0.0:8787: bind: address already in use'
        $result | Should -Match 'already in use'
        $result | Should -Match 'Choose a different port'
    }

    It 'Detects mount path errors' {
        $result = Format-DockerError -RawError 'Error response from daemon: invalid mount config for type "bind": bind source path does not exist: /nonexistent/path'
        $result | Should -Match 'mount path'
    }

    It 'Detects disk full errors' {
        $result = Format-DockerError -RawError 'no space left on device'
        $result | Should -Match 'Disk is full'
    }

    It 'Detects permission errors' {
        $result = Format-DockerError -RawError 'Got permission denied while trying to connect to the Docker daemon socket'
        $result | Should -Match 'Permission denied'
    }

    It 'Detects name conflict errors' {
        $result = Format-DockerError -RawError 'Conflict. The container name "/test" is already in use by container "abc123".'
        $result | Should -Match 'already exists'
    }

    It 'Detects image not found errors' {
        $result = Format-DockerError -RawError 'Unable to find image "myapp:latest" locally: no such image'
        $result | Should -Match 'image was not found'
    }

    It 'Returns default message for unknown errors' {
        $result = Format-DockerError -RawError 'some other error xyz'
        $result | Should -Match '^Docker error:'
        $result | Should -Match 'xyz'
    }

    It 'Handles empty input' {
        $result = Format-DockerError -RawError ''
        $result | Should -Match 'unknown failure'
    }
}

# (F111) A file-level AfterAll used to call Save-TestArtifacts here. It ran on EVERY
# run, before Pester had written the result XML, so it saved an old or missing XML and
# created an extra artifacts folder each time. tests/Invoke-Tests.ps1 already saves the
# artifacts after the suite, and only when tests failed or were skipped.

Describe 'Get-DockerCredentialsFromDotEnv' -Tag Unit {
    It 'Parses DOCKER_USERNAME / DOCKER_PASSWORD pair' {
        $env = @"
DOCKER_USERNAME=dockuser
DOCKER_PASSWORD=dockpass
"@
        $result = Get-DockerCredentialsFromDotEnv -EnvContent $env
        $result.Username | Should -Be 'dockuser'
        $result.Password | Should -Be 'dockpass'
        $result.Registry | Should -Be 'docker.io'
    }

    It 'Parses GHCR_USERNAME / GHCR_TOKEN pair with ghcr.io registry' {
        $env = @"
GHCR_USERNAME=ghuser
GHCR_TOKEN=ghp_abc123
"@
        $result = Get-DockerCredentialsFromDotEnv -EnvContent $env
        $result.Username | Should -Be 'ghuser'
        $result.Password | Should -Be 'ghp_abc123'
        $result.Registry | Should -Be 'ghcr.io'
    }

    It 'Prioritises DOCKERHUB over DOCKER_USERNAME' {
        $env = @"
DOCKERHUB_USERNAME=hubuser
DOCKERHUB_TOKEN=hubtoken
DOCKER_USERNAME=fallbackuser
DOCKER_PASSWORD=fallbackpass
"@
        $result = Get-DockerCredentialsFromDotEnv -EnvContent $env
        $result.Username | Should -Be 'hubuser'
    }

    It 'Strips single-quoted values' {
        $env = "DOCKERHUB_USERNAME='quoteduser'`nDOCKERHUB_TOKEN='quotedtoken'"
        $result = Get-DockerCredentialsFromDotEnv -EnvContent $env
        $result.Username | Should -Be 'quoteduser'
        $result.Password | Should -Be 'quotedtoken'
    }

    It 'Strips double-quoted values' {
        $env = "DOCKERHUB_USERNAME=`"dquser`"`nDOCKERHUB_TOKEN=`"dqtoken`""
        $result = Get-DockerCredentialsFromDotEnv -EnvContent $env
        $result.Username | Should -Be 'dquser'
        $result.Password | Should -Be 'dqtoken'
    }

    It 'Skips comment lines and blank lines' {
        $env = @"
# This is a comment
DOCKERHUB_USERNAME=myuser

# Another comment
DOCKERHUB_TOKEN=mytoken
"@
        $result = Get-DockerCredentialsFromDotEnv -EnvContent $env
        $result.Username | Should -Be 'myuser'
        $result.Password | Should -Be 'mytoken'
    }

    It 'Returns null when no matching credential pair exists' {
        $env = "SOME_OTHER_KEY=value"
        $result = Get-DockerCredentialsFromDotEnv -EnvContent $env
        $result | Should -BeNullOrEmpty
    }

    It 'Returns null for empty content' {
        $result = Get-DockerCredentialsFromDotEnv -EnvContent ''
        $result | Should -BeNullOrEmpty
    }

    It 'Returns null when EnvPath does not exist and no content given' {
        $result = Get-DockerCredentialsFromDotEnv -EnvPath (Join-Path $env:TEMP 'nonexistent.env')
        $result | Should -BeNullOrEmpty
    }

    It 'Reads from file when EnvPath is provided' {
        $testFile = Join-Path $env:TEMP "impact_test_env_$([guid]::NewGuid().ToString('N').Substring(0,6)).env"
        try {
            Set-Content -Path $testFile -Value "DOCKERHUB_USERNAME=fileuser`nDOCKERHUB_TOKEN=filetoken"
            $result = Get-DockerCredentialsFromDotEnv -EnvPath $testFile
            $result.Username | Should -Be 'fileuser'
            $result.Password | Should -Be 'filetoken'
        } finally {
            Remove-Item -Path $testFile -Force -ErrorAction SilentlyContinue
        }
    }

    It 'Returns null when only username is present (no password key)' {
        $env = "DOCKERHUB_USERNAME=orphanuser"
        $result = Get-DockerCredentialsFromDotEnv -EnvContent $env
        $result | Should -BeNullOrEmpty
    }

    It 'Handles values containing equals signs' {
        $env = "DOCKERHUB_USERNAME=user`nDOCKERHUB_TOKEN=tok=en=with=equals"
        $result = Get-DockerCredentialsFromDotEnv -EnvContent $env
        $result.Password | Should -Be 'tok=en=with=equals'
    }
}

# ═══════════════════════════════════════════════════════════════════════════════
#  Initialize-Logging — log directory creation & rotation
# ═══════════════════════════════════════════════════════════════════════════════
Describe 'Initialize-Logging' -Tag Unit {
    BeforeEach {
        # Reset the module's internal LogInit flag so each test starts fresh.
        # We re-import the module to reset module-scoped state.
        $modulePath = Join-Path $PSScriptRoot '..' 'current_version' 'IMPACT_Docker_GUI.psm1'
        Import-Module $modulePath -Force -DisableNameChecking

        $script:testLogDir = Join-Path $env:TEMP "impact_log_test_$([guid]::NewGuid().ToString('N').Substring(0,8))"
        $script:testLogFile = Join-Path $script:testLogDir 'impact.log'
    }

    AfterEach {
        # Clean environment override
        $env:IMPACT_LOG_FILE = $null
        $env:IMPACT_LOG_DISABLE = $null
        Remove-Item -Recurse -Force $script:testLogDir -ErrorAction SilentlyContinue
    }

    It 'Creates log directory and log file when they do not exist' {
        $env:IMPACT_LOG_FILE = $script:testLogFile
        Initialize-Logging
        Test-Path $script:testLogDir | Should -BeTrue
        Test-Path $script:testLogFile | Should -BeTrue
    }

    It 'Log file contains a header line with INFO and log start' {
        $env:IMPACT_LOG_FILE = $script:testLogFile
        Initialize-Logging
        $content = Get-Content $script:testLogFile -Raw
        $content | Should -Match '\[INFO\].*log start'
    }

    It 'Rotates log file when it exceeds 512KB' {
        $env:IMPACT_LOG_FILE = $script:testLogFile
        # Pre-create a log file larger than 512KB
        New-Item -ItemType Directory -Path $script:testLogDir -Force | Out-Null
        $bigContent = 'X' * (513 * 1024)
        Set-Content -Path $script:testLogFile -Value $bigContent

        Initialize-Logging

        # The old file should be rotated to .log.1
        Test-Path "$($script:testLogFile).1" | Should -BeTrue
    }

    It 'Does nothing when IMPACT_LOG_DISABLE is set' {
        $env:IMPACT_LOG_FILE = $script:testLogFile
        $env:IMPACT_LOG_DISABLE = '1'
        Initialize-Logging
        # Log file should NOT be created when logging is disabled
        Test-Path $script:testLogFile | Should -BeFalse
    }
}

# ═══════════════════════════════════════════════════════════════════════════════
#  Ensure-PowerShell7 — guard logic
# ═══════════════════════════════════════════════════════════════════════════════
Describe 'Ensure-PowerShell7' -Tag Unit {
    # (F109) These tests used to check only "does not throw", which also passes when the
    # function wrongly restarts PowerShell. Now they check the actual behaviour: on a
    # supported PowerShell (7.3 or newer) it returns nothing and never starts a new
    # process; on an older PowerShell 7 it refuses to run (throws) without restarting.
    BeforeAll {
        $script:psSupported = ($PSVersionTable.PSEdition -eq 'Core') -and
            ([version]('{0}.{1}' -f $PSVersionTable.PSVersion.Major, $PSVersionTable.PSVersion.Minor) -ge [version]'7.3')
    }

    BeforeEach {
        # A relaunch would start pwsh again; it must never happen in these tests.
        Mock Start-Process -ModuleName 'IMPACT_Docker_GUI' { throw 'Ensure-PowerShell7 tried to restart PowerShell' }
        Enable-NonInteractiveMode   # no message boxes if the version is too old
    }

    AfterEach {
        Disable-NonInteractiveMode
    }

    It 'Returns immediately (no output, no restart) on PowerShell 7.3 or newer, and refuses older versions' {
        if ($script:psSupported) {
            $result = Ensure-PowerShell7
            $result | Should -BeNullOrEmpty
        } else {
            { Ensure-PowerShell7 } | Should -Throw '*7.3*'
        }
        Should -Invoke Start-Process -ModuleName 'IMPACT_Docker_GUI' -Times 0 -Exactly
    }

    It 'Accepts the PS7RequestedFlag parameter and still never restarts' {
        if ($script:psSupported) {
            $result = Ensure-PowerShell7 -PS7RequestedFlag $true
            $result | Should -BeNullOrEmpty
        } else {
            { Ensure-PowerShell7 -PS7RequestedFlag $true } | Should -Throw '*7.3*'
        }
        Should -Invoke Start-Process -ModuleName 'IMPACT_Docker_GUI' -Times 0 -Exactly
    }
}

# ═══════════════════════════════════════════════════════════════════════════════
#  Test-GitHubUsername — GitHub API validation
# ═══════════════════════════════════════════════════════════════════════════════
Describe 'Test-GitHubUsername' -Tag Unit {
    It 'Returns true when GitHub API responds with 200 (user exists)' {
        Mock Invoke-RestMethod {
            return @{ login = 'octocat'; id = 1 }
        } -ModuleName 'IMPACT_Docker_GUI'

        $result = Test-GitHubUsername -UserName 'octocat'
        $result | Should -BeTrue
    }

    It 'Returns false when GitHub API responds with 404 (user not found)' {
        Mock Invoke-RestMethod {
            $resp = New-Object System.Net.Http.HttpResponseMessage
            $resp.StatusCode = [System.Net.HttpStatusCode]::NotFound
            $exception = [Microsoft.PowerShell.Commands.HttpResponseException]::new("Response status code does not indicate success: 404 (Not Found).", $resp)
            throw ([System.Management.Automation.ErrorRecord]::new(
                $exception, 'WebCmdletWebResponseException',
                [System.Management.Automation.ErrorCategory]::InvalidOperation, $null))
        } -ModuleName 'IMPACT_Docker_GUI'

        $result = Test-GitHubUsername -UserName 'nonexistent-user-xyz-12345'
        $result | Should -BeFalse
    }

    It 'Returns false when network error occurs' {
        Mock Invoke-RestMethod {
            throw [System.Net.WebException]::new('Unable to connect to the remote server')
        } -ModuleName 'IMPACT_Docker_GUI'

        $result = Test-GitHubUsername -UserName 'anyuser'
        $result | Should -BeFalse
    }

    It 'Passes the correct URL to Invoke-RestMethod' {
        Mock Invoke-RestMethod {
            return @{ login = 'testuser' }
        } -ModuleName 'IMPACT_Docker_GUI'

        Test-GitHubUsername -UserName 'myghuser'

        Should -Invoke Invoke-RestMethod -ModuleName 'IMPACT_Docker_GUI' -Times 1 -ParameterFilter {
            $Uri -eq 'https://api.github.com/users/myghuser'
        }
    }
}

# Artifact persistence is handled by Invoke-Tests.ps1 (only on failure/skip).

# =============================================================================
#  Batch B6a: startup, credentials and module export checks
# =============================================================================

Describe 'Test-GitHubUsername -Detailed (not found vs. could not check)' -Tag Unit {
    It 'Returns NotFound only for a real 404 answer from GitHub' {
        Mock Invoke-RestMethod {
            $resp = New-Object System.Net.Http.HttpResponseMessage
            $resp.StatusCode = [System.Net.HttpStatusCode]::NotFound
            $exception = [Microsoft.PowerShell.Commands.HttpResponseException]::new('Response status code does not indicate success: 404 (Not Found).', $resp)
            throw ([System.Management.Automation.ErrorRecord]::new(
                $exception, 'WebCmdletWebResponseException',
                [System.Management.Automation.ErrorCategory]::InvalidOperation, $null))
        } -ModuleName 'IMPACT_Docker_GUI'

        $r = Test-GitHubUsername -UserName 'nobody-xyz-12345' -Detailed
        $r.Status | Should -Be 'NotFound'
        $r.Message | Should -Match 'not found'
    }

    It 'Returns Unknown (not NotFound) when GitHub cannot be reached' {
        Mock Invoke-RestMethod {
            throw [System.Net.Http.HttpRequestException]::new('No such host is known.')
        } -ModuleName 'IMPACT_Docker_GUI'

        $r = Test-GitHubUsername -UserName 'anyuser' -Detailed
        $r.Status | Should -Be 'Unknown'
        $r.Message | Should -Match 'could not be reached'
        # The plain form keeps its old contract: only an existing user gives $true.
        Test-GitHubUsername -UserName 'anyuser' | Should -BeFalse
    }

    It 'Returns Unknown with a rate-limit hint for HTTP 403' {
        Mock Invoke-RestMethod {
            $resp = New-Object System.Net.Http.HttpResponseMessage
            $resp.StatusCode = [System.Net.HttpStatusCode]::Forbidden
            $exception = [Microsoft.PowerShell.Commands.HttpResponseException]::new('Response status code does not indicate success: 403 (rate limit exceeded).', $resp)
            throw ([System.Management.Automation.ErrorRecord]::new(
                $exception, 'WebCmdletWebResponseException',
                [System.Management.Automation.ErrorCategory]::InvalidOperation, $null))
        } -ModuleName 'IMPACT_Docker_GUI'

        $r = Test-GitHubUsername -UserName 'anyuser' -Detailed
        $r.Status | Should -Be 'Unknown'
        $r.Message | Should -Match 'too many checks'
    }

    It 'Returns Organization for an organisation account' {
        Mock Invoke-RestMethod {
            return [pscustomobject]@{ login = 'IMPACT-NCD'; type = 'Organization' }
        } -ModuleName 'IMPACT_Docker_GUI'

        (Test-GitHubUsername -UserName 'impact-ncd' -Detailed).Status | Should -Be 'Organization'
        Test-GitHubUsername -UserName 'impact-ncd' | Should -BeFalse
    }

    It 'Returns Exists for a personal account' {
        Mock Invoke-RestMethod {
            return [pscustomobject]@{ login = 'octocat'; type = 'User' }
        } -ModuleName 'IMPACT_Docker_GUI'

        (Test-GitHubUsername -UserName 'octocat' -Detailed).Status | Should -Be 'Exists'
    }

    It 'Escapes the username in the request address and sets a timeout' {
        Mock Invoke-RestMethod {
            return [pscustomobject]@{ login = 'foo'; type = 'User' }
        } -ModuleName 'IMPACT_Docker_GUI'

        Test-GitHubUsername -UserName 'foo?x' -Detailed | Out-Null

        # '?' must be sent as part of the name, not start a query string.
        Should -Invoke Invoke-RestMethod -ModuleName 'IMPACT_Docker_GUI' -Times 1 -ParameterFilter {
            ([uri]$Uri).AbsolutePath -eq '/users/foo%3Fx' -and
            ($PesterBoundParameters.ContainsKey('TimeoutSec') -or $PesterBoundParameters.ContainsKey('ConnectionTimeoutSeconds'))
        }
    }
}

Describe 'Resolve-GitHubUsernameInput (local username check)' -Tag Unit {
    It 'Lowercases and removes spaces' {
        InModuleScope 'IMPACT_Docker_GUI' {
            $r = Resolve-GitHubUsernameInput -InputText ' J Doe '
            $r.UserName | Should -Be 'jdoe'
            $r.Problem | Should -BeNullOrEmpty
        }
    }

    It 'Rejects an e-mail address with a specific hint' {
        InModuleScope 'IMPACT_Docker_GUI' {
            $r = Resolve-GitHubUsernameInput -InputText 'j.doe@institute.de'
            $r.UserName | Should -BeNullOrEmpty
            $r.Problem | Should -Match 'e-mail'
        }
    }

    It 'Accepts a pasted GitHub profile link and an @mention' {
        InModuleScope 'IMPACT_Docker_GUI' {
            (Resolve-GitHubUsernameInput -InputText 'https://github.com/JDoe?tab=repositories').UserName | Should -Be 'jdoe'
            (Resolve-GitHubUsernameInput -InputText '@JDoe').UserName | Should -Be 'jdoe'
        }
    }

    It 'Rejects <Text> (characters that would change the request or a shell command)' -ForEach @(
        @{ Text = 'foo?x' }
        @{ Text = 'foo#x' }
        @{ Text = 'foo/repos' }
        @{ Text = "foo'bar" }
        @{ Text = '-foo' }
    ) {
        InModuleScope 'IMPACT_Docker_GUI' -Parameters @{ Text = $Text } {
            param($Text)
            $r = Resolve-GitHubUsernameInput -InputText $Text
            $r.UserName | Should -BeNullOrEmpty
            $r.Problem | Should -Match 'not a valid GitHub username'
        }
    }

    It 'Rejects names longer than 39 characters and empty input' {
        InModuleScope 'IMPACT_Docker_GUI' {
            (Resolve-GitHubUsernameInput -InputText ('a' * 40)).Problem | Should -Not -BeNullOrEmpty
            (Resolve-GitHubUsernameInput -InputText '   ').Problem | Should -Match 'enter your GitHub username'
        }
    }
}

Describe 'Get-RStudioPasswordProblem (RStudio password rules)' -Tag Unit {
    It 'Accepts a reasonable password' {
        InModuleScope 'IMPACT_Docker_GUI' {
            Get-RStudioPasswordProblem -Password 'Sunny-Garden-42' -UserName 'jdoe' | Should -BeNullOrEmpty
        }
    }

    It 'Rejects passwords shorter than 8 characters' {
        InModuleScope 'IMPACT_Docker_GUI' {
            Get-RStudioPasswordProblem -Password '1234' -UserName 'jdoe' | Should -Match 'at least 8'
            Get-RStudioPasswordProblem -Password 'rstudio' -UserName 'jdoe' | Should -Match 'at least 8'
        }
    }

    It 'Rejects an empty password, the username, and very common passwords' {
        InModuleScope 'IMPACT_Docker_GUI' {
            Get-RStudioPasswordProblem -Password '' -UserName 'jdoe' | Should -Not -BeNullOrEmpty
            Get-RStudioPasswordProblem -Password 'JDoe1234' -UserName 'jdoe1234' | Should -Match 'same as your username'
            Get-RStudioPasswordProblem -Password 'Password' -UserName 'jdoe' | Should -Match 'too easy'
        }
    }
}

Describe 'Test-PowerShellVersionSupported (minimum PowerShell 7.3)' -Tag Unit {
    It 'Accepts <Edition> <Version> = <Expected>' -ForEach @(
        @{ Edition = 'Core';    Version = '7.4'; Expected = $true }
        @{ Edition = 'Core';    Version = '7.3'; Expected = $true }
        @{ Edition = 'Core';    Version = '7.2'; Expected = $false }
        @{ Edition = 'Core';    Version = '7.0'; Expected = $false }
        @{ Edition = 'Desktop'; Version = '5.1'; Expected = $false }
    ) {
        InModuleScope 'IMPACT_Docker_GUI' -Parameters @{ Edition = $Edition; Version = $Version; Expected = $Expected } {
            param($Edition, $Version, $Expected)
            Test-PowerShellVersionSupported -Edition $Edition -Version ([version]$Version) | Should -Be $Expected
        }
    }
}

Describe 'Test-PortValue edge cases' -Tag Unit {
    It 'Rejects a very long number without throwing' {
        { Test-PortValue -Port '99999999999999999999' } | Should -Not -Throw
        (Test-PortValue -Port '99999999999999999999').Valid | Should -BeFalse
    }

    It 'Rejects a leading zero (would bypass the port-in-use check)' {
        $r = Test-PortValue -Port '08787'
        $r.Valid | Should -BeFalse
        $r.ErrorMessage | Should -Match 'start with 0'
    }
}

Describe 'Format-DockerError port extraction' -Tag Unit {
    It 'Reports the bound port, not digits from the container ID, endpoint hash or user name' {
        $raw = "3f2a9c1e0b7d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f`ndocker: Error response from daemon: driver failed programming external connectivity on endpoint IMPACTncd_Germany_user2236 (5512a3be4c6d7e8f9a0b1c2d3e4f5a6b7c8d9e0f1a2b3c4d5e6f7a8b9c0d1e2f): Bind for 0.0.0.0:8788 failed: port is already allocated."
        Format-DockerError -RawError $raw | Should -Be 'Port 8788 is already in use. Choose a different port.'
    }

    It 'Treats a port reserved by Windows as a port problem, not a permission problem' {
        $raw = 'Error response from daemon: Ports are not available: exposing port TCP 0.0.0.0:8790 -> 0.0.0.0:0: listen tcp 0.0.0.0:8790: bind: An attempt was made to access a socket in a way forbidden by its access permissions.'
        $result = Format-DockerError -RawError $raw
        $result | Should -Match 'Port 8790 is blocked or reserved by Windows'
        $result | Should -Not -Match 'Permission denied'
    }

    It 'Recognises the Windows "Only one usage of each socket address" message' {
        $raw = 'Error response from daemon: Ports are not available: exposing port TCP 0.0.0.0:8791 -> 0.0.0.0:0: listen tcp 0.0.0.0:8791: bind: Only one usage of each socket address (protocol/network address/port) is normally permitted.'
        Format-DockerError -RawError $raw | Should -Be 'Port 8791 is already in use. Choose a different port.'
    }
}

Describe 'Get-DockerCredentialsFromDotEnv with native command output' -Tag Unit {
    It 'Parses an array of lines (the shape that ssh/cat output arrives in)' {
        $lines = @('# registry', 'DOCKERHUB_USERNAME=alice', 'DOCKERHUB_TOKEN=tok123')
        $result = Get-DockerCredentialsFromDotEnv -EnvContent $lines
        $result | Should -Not -BeNullOrEmpty
        $result.Username | Should -Be 'alice'
        $result.Password | Should -Be 'tok123'
    }
}

Describe 'Get-NextAvailablePort is defined only once' -Tag Unit {
    It 'Has exactly one definition in the module' {
        $modulePath = Join-Path $PSScriptRoot '..' 'current_version' 'IMPACT_Docker_GUI.psm1'
        $tokens = $null; $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($modulePath, [ref]$tokens, [ref]$errors)
        $defs = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-NextAvailablePort' }, $true)
        @($defs).Count | Should -Be 1
    }
}

Describe 'Set-DockerSSHEnvironment when the workstation or user changes' -Tag Unit {
    AfterEach {
        $env:DOCKER_SSH_OPTS = $null
        $env:DOCKER_HOST = $null
    }

    It 'Points DOCKER_HOST at the NEW workstation after switching' {
        $a = New-TestSessionState -Location 'REMOTE@10.0.0.1'
        $a.Flags.UseDirectSsh = $true
        Set-DockerSSHEnvironment -State $a
        $env:DOCKER_HOST | Should -Be 'ssh://php-workstation@10.0.0.1'

        $b = New-TestSessionState -Location 'REMOTE@10.0.0.2'
        $b.Flags.UseDirectSsh = $true
        Set-DockerSSHEnvironment -State $b
        $env:DOCKER_HOST | Should -Be 'ssh://php-workstation@10.0.0.2'
    }

    It 'Uses the key of the CURRENT user in DOCKER_SSH_OPTS' {
        $a = New-TestSessionState -UserName 'alice' -Location 'REMOTE@10.0.0.1'
        Set-DockerSSHEnvironment -State $a
        $env:DOCKER_SSH_OPTS | Should -Match 'id_ed25519_alice'

        $b = New-TestSessionState -UserName 'bob' -Location 'REMOTE@10.0.0.1'
        Set-DockerSSHEnvironment -State $b
        $env:DOCKER_SSH_OPTS | Should -Match 'id_ed25519_bob'
    }

    It 'Clears a leftover ssh:// DOCKER_HOST when a Docker context is used' {
        $env:DOCKER_HOST = 'ssh://php-workstation@10.0.0.1'
        $s = New-TestSessionState -Location 'REMOTE@10.0.0.2'
        $s.Flags.UseDirectSsh = $false
        Set-DockerSSHEnvironment -State $s
        $env:DOCKER_HOST | Should -BeNullOrEmpty
    }
}

Describe 'Module exports and manifest stay in sync' -Tag Unit {
    BeforeAll {
        $script:b6aRoot = Join-Path $PSScriptRoot '..' 'current_version'
        $script:b6aExported = @((Get-Module -Name 'IMPACT_Docker_GUI' | Select-Object -First 1).ExportedFunctions.Keys)
    }

    It 'The .psd1 FunctionsToExport lists exactly the functions the .psm1 exports' {
        $manifest = Import-PowerShellDataFile (Join-Path $script:b6aRoot 'IMPACT_Docker_GUI.psd1')
        $listed = @($manifest.FunctionsToExport)
        @($script:b6aExported | Where-Object { $listed -notcontains $_ }) | Should -BeNullOrEmpty -Because 'every function exported by the .psm1 must also be listed in the .psd1'
        @($listed | Where-Object { $script:b6aExported -notcontains $_ }) | Should -BeNullOrEmpty -Because 'the .psd1 must not list functions the .psm1 does not export'
    }

    It 'The .psd1 requires PowerShell 7.3 or newer' {
        $manifest = Import-PowerShellDataFile (Join-Path $script:b6aRoot 'IMPACT_Docker_GUI.psd1')
        [version]$manifest.PowerShellVersion | Should -BeGreaterOrEqual ([version]'7.3')
    }

    It 'Every module function called by the GUI script is exported' {
        # The GUI imports the .psm1 directly, so a module function that is called by the
        # GUI but missing from Export-ModuleMember fails at run time with
        # "command not found" (this happened to Ensure-RemoteDockerLogin).
        $tokens = $null; $errors = $null
        $guiAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $script:b6aRoot 'IMPACT_Docker_GUI_v2.ps1'), [ref]$tokens, [ref]$errors)
        $modAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $script:b6aRoot 'IMPACT_Docker_GUI.psm1'), [ref]$tokens, [ref]$errors)
        $isFunctionDef = { param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }
        $moduleFunctions = @($modAst.FindAll($isFunctionDef, $true) | ForEach-Object { $_.Name })
        $guiFunctions = @($guiAst.FindAll($isFunctionDef, $true) | ForEach-Object { $_.Name })
        $called = @($guiAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true) |
            ForEach-Object { $_.GetCommandName() } | Where-Object { $_ } | Sort-Object -Unique)
        $missing = @($called | Where-Object { $moduleFunctions -contains $_ -and $guiFunctions -notcontains $_ -and $script:b6aExported -notcontains $_ })
        $missing | Should -BeNullOrEmpty
    }
}

Describe 'Get-BuildInfo reads the version from the manifest' -Tag Unit {
    It 'Version equals ModuleVersion in the .psd1' {
        $manifest = Import-PowerShellDataFile (Join-Path $PSScriptRoot '..' 'current_version' 'IMPACT_Docker_GUI.psd1')
        (Get-BuildInfo).Version | Should -Be ([string]$manifest.ModuleVersion)
    }
}

# ═══════════════════════════════════════════════════════════════════════════════
#  ConvertTo-RemoteRepoList (remote repository picker)
# ═══════════════════════════════════════════════════════════════════════════════
Describe 'ConvertTo-RemoteRepoList' -Tag Unit {
    BeforeAll {
        # Helper: an ErrorRecord, which is how a stderr line arrives with 2>&1.
        function New-StderrLine([string]$Text) {
            [System.Management.Automation.ErrorRecord]::new(
                [System.Exception]::new($Text), 'NativeCommandError',
                [System.Management.Automation.ErrorCategory]::NotSpecified, $null)
        }
    }

    It 'Returns an array with Count 1 for a single repository (StrictMode safe)' {
        # With exactly one line PowerShell would hand back a plain string; .Count on
        # that throws under Set-StrictMode, which crashed the app before the fix.
        Set-StrictMode -Version Latest
        $list = @(ConvertTo-RemoteRepoList -Output 'IMPACTncd_Germany')
        $list.Count | Should -Be 1
        $list[0] | Should -Be 'IMPACTncd_Germany'
    }

    It 'Returns an empty array for no output' {
        Set-StrictMode -Version Latest
        @(ConvertTo-RemoteRepoList -Output $null).Count | Should -Be 0
        @(ConvertTo-RemoteRepoList -Output @()).Count | Should -Be 0
    }

    It 'Drops error lines (ErrorRecords) so they never appear as repositories' {
        $raw = @(
            (New-StderrLine 'basename: missing operand'),
            'IMPACTncd_Germany',
            (New-StderrLine 'Permission denied (publickey).')
        )
        $list = @(ConvertTo-RemoteRepoList -Output $raw)
        $list.Count | Should -Be 1
        $list[0] | Should -Be 'IMPACTncd_Germany'
    }

    It 'Keeps folder names with spaces whole, trims CR and blank lines, and sorts' {
        $raw = @("zeta`r", '', 'My Repo', '  ', 'alpha')
        $list = @(ConvertTo-RemoteRepoList -Output $raw)
        $list | Should -Be @('alpha', 'My Repo', 'zeta')
    }

    It 'Splits a single multi-line string into names' {
        $list = @(ConvertTo-RemoteRepoList -Output "b_repo`na_repo`n")
        $list | Should -Be @('a_repo', 'b_repo')
    }
}

# ═══════════════════════════════════════════════════════════════════════════════
#  Get-SshFailureKind (why did an ssh call fail?)
# ═══════════════════════════════════════════════════════════════════════════════
Describe 'Get-SshFailureKind' -Tag Unit {
    It 'Classifies <Text> as <Expected>' -ForEach @(
        @{ Text = 'ssh: connect to host 10.0.0.5 port 22: Connection timed out'; Expected = 'Unreachable' }
        @{ Text = 'ssh: connect to host 10.0.0.5 port 22: Connection refused'; Expected = 'Unreachable' }
        @{ Text = 'ssh: connect to host 10.0.0.5 port 22: No route to host'; Expected = 'Unreachable' }
        @{ Text = 'ssh: Could not resolve hostname wks: No such host is known.'; Expected = 'Unreachable' }
        @{ Text = 'Renci.SshNet.Common.SshOperationTimeoutException: Socket read operation has timed out'; Expected = 'Unreachable' }
        @{ Text = 'System.Net.Sockets.SocketException: Der angegebene Host ist unbekannt.'; Expected = 'Unreachable' }
        @{ Text = 'php-workstation@10.0.0.5: Permission denied (publickey,password).'; Expected = 'AuthFailed' }
        @{ Text = 'Renci.SshNet.Common.SshAuthenticationException: Permission denied (password).'; Expected = 'AuthFailed' }
        @{ Text = 'Host key verification failed.'; Expected = 'HostKeyChanged' }
        @{ Text = 'something completely different'; Expected = 'Unknown' }
    ) {
        Get-SshFailureKind -Output $Text | Should -Be $Expected
    }

    It 'Recognises a changed host key even though other lines are printed too' {
        $out = @(
            '@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@',
            '@    WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!     @',
            'Offending ECDSA key in C:\Users\jan/.ssh/known_hosts:3',
            'Host key verification failed.'
        )
        Get-SshFailureKind -Output $out | Should -Be 'HostKeyChanged'
    }

    It 'Reads ErrorRecords (stderr lines from 2>&1) as text' {
        $err = [System.Management.Automation.ErrorRecord]::new(
            [System.Exception]::new('ssh: connect to host 10.0.0.5 port 22: Network is unreachable'),
            'NativeCommandError', [System.Management.Automation.ErrorCategory]::NotSpecified, $null)
        Get-SshFailureKind -Output @($err) | Should -Be 'Unreachable'
    }

    It 'Returns Unknown for no output' {
        Get-SshFailureKind -Output $null | Should -Be 'Unknown'
    }
}

# ═══════════════════════════════════════════════════════════════════════════════
#  ConvertTo-DockerSafeRepoName: folder name -> name Docker accepts
#  (container name "<repo>_<user>", lower-cased image name, REPO_NAME build arg)
# ═══════════════════════════════════════════════════════════════════════════════
Describe 'ConvertTo-DockerSafeRepoName' -Tag Unit {
    BeforeAll {
        # Docker's rule for one part of an image name (checked on the lower-cased name)
        # and its rule for container names. Every non-empty result must pass both.
        $script:ImageNameRule     = '^[a-z0-9]+((\.|_|__|-+)[a-z0-9]+)*$'
        $script:ContainerNameRule = '^[a-zA-Z0-9][a-zA-Z0-9_.-]+$'
    }

    It 'Leaves an already valid name unchanged: <Name>' -TestCases @(
        @{ Name = 'IMPACTncd_Germany' }
        @{ Name = 'IMPACTncd_Germany-main' }
        @{ Name = 'model.v2' }
        @{ Name = 'a__b' }
        @{ Name = 'a--b' }
    ) {
        param($Name)
        ConvertTo-DockerSafeRepoName -Name $Name | Should -BeExactly $Name
    }

    It 'Turns "<Name>" into "<Expected>"' -TestCases @(
        @{ Name = 'IMPACTncd_Germany - Kopie';  Expected = 'IMPACTncd_Germany_Kopie' }
        @{ Name = 'IMPACTncd_Germany-main (1)'; Expected = 'IMPACTncd_Germany-main_1' }
        @{ Name = '[test] repo';                Expected = 'test_repo' }
        @{ Name = 'v1.2 (copy)';                Expected = 'v1.2_copy' }
        @{ Name = 'a___b';                      Expected = 'a_b' }
        @{ Name = 'a._b';                       Expected = 'a_b' }
        @{ Name = '.hidden';                    Expected = 'hidden' }
    ) {
        param($Name, $Expected)
        ConvertTo-DockerSafeRepoName -Name $Name | Should -BeExactly $Expected
    }

    It 'Replaces accented letters by plain letters (German umlauts and sharp s)' {
        # Written with char codes so the test does not depend on the file encoding:
        # U+00DC = U-umlaut, U+00F6 = o-umlaut, U+00DF = sharp s
        $name = "$([char]0x00DC)bung_Gr$([char]0x00F6)$([char]0x00DF)e"
        ConvertTo-DockerSafeRepoName -Name $name | Should -BeExactly 'Ubung_Grosse'
    }

    It 'Does not keep non-ASCII letters that lower-case to ASCII (Kelvin sign)' {
        $result = ConvertTo-DockerSafeRepoName -Name "x$([char]0x212A)y"
        $result | Should -MatchExactly '^[A-Za-z0-9._-]+$'
    }

    It 'Returns an empty string when nothing usable is left: "<Name>"' -TestCases @(
        @{ Name = '' }
        @{ Name = '   ' }
        @{ Name = '(((' }
        @{ Name = '---' }
    ) {
        param($Name)
        ConvertTo-DockerSafeRepoName -Name $Name | Should -BeExactly ''
    }

    It 'Returns an empty string for $null' {
        ConvertTo-DockerSafeRepoName -Name $null | Should -BeExactly ''
    }

    It 'Always produces a valid Docker image and container name: "<Name>"' -TestCases @(
        @{ Name = 'IMPACTncd_Germany - Kopie' }
        @{ Name = 'My Model (v2) [final]' }
        @{ Name = "Gr$([char]0x00F6)$([char]0x00DF)e Studie" }
        @{ Name = '_leading_and_trailing_' }
        @{ Name = 'x' }
    ) {
        param($Name)
        $result = ConvertTo-DockerSafeRepoName -Name $Name
        $result | Should -Not -BeNullOrEmpty
        $result.ToLowerInvariant() | Should -MatchExactly $script:ImageNameRule
        "$($result)_someuser" | Should -MatchExactly $script:ContainerNameRule
    }
}


# ═══════════════════════════════════════════════════════════════════════════════
#  Get-YamlPathValue: quoted values, empty values, '~' and unreadable files
#  (an empty or missing YAML used to throw under StrictMode instead of returning $null)
# ═══════════════════════════════════════════════════════════════════════════════
Describe 'Get-YamlPathValue (quotes, empty values, ~, unreadable YAML)' -Tag Unit {
    BeforeAll {
        # Pester can only mock a command that exists. On machines without an ssh client
        # (for example a Linux test box) we define a throw-away global 'ssh' function so the
        # REMOTE mocks below still work. It is removed again in AfterAll.
        $script:yamlSshStubAdded = $false
        if (-not (Get-Command ssh -ErrorAction SilentlyContinue)) {
            function global:ssh { throw 'ssh stub: this call should have been mocked' }
            $script:yamlSshStubAdded = $true
        }
    }

    AfterAll {
        # Note: 'Function:\ssh' (not 'function:global:ssh', which silently removes nothing).
        # The stub must really go, or later test files would see a fake ssh command.
        if ($script:yamlSshStubAdded) { Remove-Item -Path Function:\ssh -ErrorAction SilentlyContinue }
    }

    BeforeEach {
        $testDir = Join-Path ([System.IO.Path]::GetTempPath()) "impact_yaml_q_$([guid]::NewGuid().ToString('N').Substring(0,8))"
        New-Item -ItemType Directory -Path $testDir -Force | Out-Null
        $yamlFile = Join-Path $testDir 'sim_design.yaml'
        $baseDir = ($testDir -replace '\\', '/')
    }

    AfterEach {
        Remove-Item -Recurse -Force -Path $testDir -ErrorAction SilentlyContinue
    }

    It 'Strips double quotes from an absolute path (and ignores a trailing comment)' {
        Set-Content -Path $yamlFile -Value 'output_dir: "/data/impact/outputs"  # shared folder'
        $state = New-TestSessionState -Location 'LOCAL'
        $result = Get-YamlPathValue -State $state -YamlPath $yamlFile -Key 'output_dir' -BaseDir $baseDir
        $result | Should -Be '/data/impact/outputs'
    }

    It 'Strips single quotes and keeps a # that is inside the quotes' {
        Set-Content -Path $yamlFile -Value "output_dir: './out#1'"
        $state = New-TestSessionState -Location 'LOCAL'
        $result = Get-YamlPathValue -State $state -YamlPath $yamlFile -Key 'output_dir' -BaseDir $baseDir
        $result | Should -Be "$baseDir/./out#1"
    }

    It 'Unescapes doubled backslashes inside double quotes' {
        Set-Content -Path $yamlFile -Value 'output_dir: "C:\\IMPACT\\outputs"'
        $state = New-TestSessionState -Location 'LOCAL'
        $result = Get-YamlPathValue -State $state -YamlPath $yamlFile -Key 'output_dir' -BaseDir $baseDir
        # On Windows the path is absolute and returned as-is; elsewhere it is joined to BaseDir.
        # Either way the quotes are gone and \\ became one separator.
        $result | Should -BeLike '*C:/IMPACT/outputs'
        $result | Should -Not -Match '"'
    }

    It 'Returns null for an empty value instead of the repository folder' {
        Set-Content -Path $yamlFile -Value "output_dir:`nsynthpop_dir: ./inputs/synthpop"
        $state = New-TestSessionState -Location 'LOCAL'
        Get-YamlPathValue -State $state -YamlPath $yamlFile -Key 'output_dir' -BaseDir $baseDir | Should -BeNullOrEmpty
    }

    It 'Returns null for the YAML null marker ~' {
        Set-Content -Path $yamlFile -Value 'output_dir: ~'
        $state = New-TestSessionState -Location 'LOCAL'
        Get-YamlPathValue -State $state -YamlPath $yamlFile -Key 'output_dir' -BaseDir $baseDir | Should -BeNullOrEmpty
    }

    It 'Returns null (and does not throw) for an empty local YAML file' {
        [System.IO.File]::WriteAllText($yamlFile, '')
        $state = New-TestSessionState -Location 'LOCAL'
        { Get-YamlPathValue -State $state -YamlPath $yamlFile -Key 'output_dir' -BaseDir $baseDir } | Should -Not -Throw
        Get-YamlPathValue -State $state -YamlPath $yamlFile -Key 'output_dir' -BaseDir $baseDir | Should -BeNullOrEmpty
    }

    It 'Returns null (and does not throw) when SSH returns nothing' {
        Mock ssh { } -ModuleName 'IMPACT_Docker_GUI'
        $state = New-TestSessionState -Location 'REMOTE@10.0.0.7'
        { Get-YamlPathValue -State $state -YamlPath '/repo/inputs/nope.yaml' -Key 'output_dir' -BaseDir '/repo' } | Should -Not -Throw
        Get-YamlPathValue -State $state -YamlPath '/repo/inputs/nope.yaml' -Key 'output_dir' -BaseDir '/repo' | Should -BeNullOrEmpty
    }

    It 'Returns null when the remote YAML file does not exist' {
        Mock ssh { '__IMPACT_YAML_MISSING__' } -ModuleName 'IMPACT_Docker_GUI'
        $state = New-TestSessionState -Location 'REMOTE@10.0.0.7'
        Get-YamlPathValue -State $state -YamlPath '/repo/inputs/nope.yaml' -Key 'output_dir' -BaseDir '/repo' | Should -BeNullOrEmpty
    }

    It 'Expands ~/ to the remote user home folder in REMOTE mode' {
        Mock ssh { 'output_dir: ~/IMPACT/outputs' } -ModuleName 'IMPACT_Docker_GUI'
        $state = New-TestSessionState -Location 'REMOTE@10.0.0.7'
        $result = Get-YamlPathValue -State $state -YamlPath '/repo/inputs/sim_design.yaml' -Key 'output_dir' -BaseDir '/repo'
        $result | Should -Be "/home/$($state.RemoteUser)/IMPACT/outputs"
    }
}

# ═══════════════════════════════════════════════════════════════════════════════
#  Test-AndCreateDirectory: -Reason codes and -Create
# ═══════════════════════════════════════════════════════════════════════════════
Describe 'Test-AndCreateDirectory (-Reason and -Create)' -Tag Unit {
    BeforeAll {
        # Same ssh stub as above, for machines without an ssh client.
        $script:dirSshStubAdded = $false
        if (-not (Get-Command ssh -ErrorAction SilentlyContinue)) {
            function global:ssh { throw 'ssh stub: this call should have been mocked' }
            $script:dirSshStubAdded = $true
        }
    }

    AfterAll {
        if ($script:dirSshStubAdded) { Remove-Item -Path Function:\ssh -ErrorAction SilentlyContinue }
    }

    BeforeEach {
        $testDir = Join-Path ([System.IO.Path]::GetTempPath()) "impact_dir_test_$([guid]::NewGuid().ToString('N').Substring(0,8))"
        New-Item -ItemType Directory -Path $testDir -Force | Out-Null
    }

    AfterEach {
        Remove-Item -Recurse -Force -Path $testDir -ErrorAction SilentlyContinue
    }

    It 'Still works without -Reason (old callers)' {
        $state = New-TestSessionState -Location 'LOCAL'
        Test-AndCreateDirectory -State $state -Path $testDir -PathKey 'output_dir' | Should -BeTrue
        Test-AndCreateDirectory -State $state -Path (Join-Path $testDir 'missing') -PathKey 'output_dir' | Should -BeFalse
    }

    It 'Reports EmptyPath for a null path' {
        $state = New-TestSessionState -Location 'LOCAL'
        $why = $null
        Test-AndCreateDirectory -State $state -Path $null -PathKey 'output_dir' -Reason ([ref]$why) | Should -BeFalse
        $why | Should -Be 'EmptyPath'
    }

    It 'Reports Missing for a local folder that does not exist, and creates nothing' {
        $state = New-TestSessionState -Location 'LOCAL'
        $missing = Join-Path $testDir 'outputs'
        $why = $null
        Test-AndCreateDirectory -State $state -Path $missing -PathKey 'output_dir' -Reason ([ref]$why) | Should -BeFalse
        $why | Should -Be 'Missing'
        Test-Path $missing | Should -BeFalse
    }

    It 'Creates a missing local folder (including parents) with -Create' {
        $state = New-TestSessionState -Location 'LOCAL'
        $missing = Join-Path (Join-Path $testDir 'inputs') 'synthpop'
        $why = $null
        Test-AndCreateDirectory -State $state -Path $missing -PathKey 'synthpop_dir' -Create -Reason ([ref]$why) | Should -BeTrue
        Test-Path $missing -PathType Container | Should -BeTrue
        $why | Should -BeNullOrEmpty
    }

    It 'Reports PosixPathInLocalMode for a Linux-style path in LOCAL mode' -Skip:(-not $IsWindows) {
        $state = New-TestSessionState -Location 'LOCAL'
        $why = $null
        Test-AndCreateDirectory -State $state -Path '/home/user/data' -PathKey 'output_dir' -Reason ([ref]$why) | Should -BeFalse
        $why | Should -Be 'PosixPathInLocalMode'
    }

    It 'Reports Missing when the remote folder does not exist' {
        Mock ssh { 'MISSING' } -ModuleName 'IMPACT_Docker_GUI'
        $state = New-TestSessionState -Location 'REMOTE@10.0.0.5'
        $why = $null
        Test-AndCreateDirectory -State $state -Path '/repo/outputs' -PathKey 'output_dir' -Reason ([ref]$why) | Should -BeFalse
        $why | Should -Be 'Missing'
    }

    It 'Reports Unreachable when SSH returns nothing' {
        Mock ssh { } -ModuleName 'IMPACT_Docker_GUI'
        $state = New-TestSessionState -Location 'REMOTE@10.0.0.5'
        $why = $null
        Test-AndCreateDirectory -State $state -Path '/repo/outputs' -PathKey 'output_dir' -Reason ([ref]$why) | Should -BeFalse
        $why | Should -Be 'Unreachable'
    }

    It 'Creates a missing remote folder with mkdir -p when -Create is given' {
        Mock ssh { if ("$args" -match 'mkdir -p') { 'CREATED' } else { 'MISSING' } } -ModuleName 'IMPACT_Docker_GUI'
        $state = New-TestSessionState -Location 'REMOTE@10.0.0.5'
        Test-AndCreateDirectory -State $state -Path '/repo/outputs' -PathKey 'output_dir' -Create | Should -BeTrue
        Should -Invoke ssh -ModuleName 'IMPACT_Docker_GUI' -Times 2 -Exactly
    }

    It 'Reports CreateFailed when the remote mkdir does not succeed' {
        Mock ssh { if ("$args" -match 'mkdir -p') { } else { 'MISSING' } } -ModuleName 'IMPACT_Docker_GUI'
        $state = New-TestSessionState -Location 'REMOTE@10.0.0.5'
        $why = $null
        Test-AndCreateDirectory -State $state -Path '/repo/outputs' -PathKey 'output_dir' -Create -Reason ([ref]$why) | Should -BeFalse
        $why | Should -Be 'CreateFailed'
    }
}


# ═══════════════════════════════════════════════════════════════════════════════
#  Git commit flow helpers: shell quoting, git output text, push error hints
# ═══════════════════════════════════════════════════════════════════════════════
Describe 'ConvertTo-PosixShellLiteral' -Tag Unit {
    It 'Wraps plain text in single quotes' {
        InModuleScope 'IMPACT_Docker_GUI' { ConvertTo-PosixShellLiteral -Value 'my repo' } | Should -Be "'my repo'"
    }

    It 'Writes an apostrophe as close-quote, escaped quote, open-quote' {
        InModuleScope 'IMPACT_Docker_GUI' { ConvertTo-PosixShellLiteral -Value "Bob's repo" } | Should -Be "'Bob'\''s repo'"
    }

    It 'Leaves $, backticks and a trailing backslash as plain text inside the quotes' {
        $value = 'cost $100 `x` $(echo hi) \'
        $quoted = InModuleScope 'IMPACT_Docker_GUI' -Parameters @{ V = $value } { param($V) ConvertTo-PosixShellLiteral -Value $V }
        $quoted | Should -Be ("'" + $value + "'")
    }

    It 'Survives a real POSIX shell unchanged (when sh is available)' {
        # -First 1: PATH can list more than one sh (for example /usr/bin and /bin).
        $sh = Get-Command sh -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $sh) { Set-ItResult -Skipped -Because 'no POSIX sh on this machine'; return }
        $value = "O'Brien: cost `$5 ``x`` `$(echo INJECTED) `"q`" \"
        $quoted = InModuleScope 'IMPACT_Docker_GUI' -Parameters @{ V = $value } { param($V) ConvertTo-PosixShellLiteral -Value $V }
        $echoed = & $sh.Source -c "printf '%s' $quoted"
        $echoed | Should -BeExactly $value
    }
}

Describe 'ConvertTo-GitOutputText' -Tag Unit {
    It 'Joins stdout strings and stderr records, dropping the RemoteException placeholder of empty stderr lines' {
        $text = InModuleScope 'IMPACT_Docker_GUI' {
            $errLine  = [System.Management.Automation.ErrorRecord]::new([System.Management.Automation.RemoteException]::new('fatal: boom'), 'NativeCommandError', 'NotSpecified', $null)
            $errEmpty = [System.Management.Automation.ErrorRecord]::new([System.Management.Automation.RemoteException]::new(''), 'NativeCommandErrorMessage', 'NotSpecified', $null)
            ConvertTo-GitOutputText -Output @('To github.com:o/r.git', $errLine, $errEmpty)
        }
        $text | Should -Be "To github.com:o/r.git`nfatal: boom"
        $text | Should -Not -Match 'RemoteException'
    }

    It 'Returns an empty string for no output' {
        InModuleScope 'IMPACT_Docker_GUI' { ConvertTo-GitOutputText -Output $null } | Should -Be ''
    }
}

Describe 'Get-GitPushFailureHint' -Tag Unit {
    It 'Explains a key that GitHub does not accept' {
        $hint = InModuleScope 'IMPACT_Docker_GUI' { Get-GitPushFailureHint -Output 'git@github.com: Permission denied (publickey).' -KeyName 'KEYX' }
        $hint | Should -Match 'KEYX'
        $hint | Should -Match 'settings/keys'
    }

    It 'Explains that someone else pushed first (non-fast-forward)' {
        $out = " ! [rejected]        main -> main (fetch first)`nerror: failed to push some refs"
        $hint = InModuleScope 'IMPACT_Docker_GUI' -Parameters @{ O = $out } { param($O) Get-GitPushFailureHint -Output $O }
        $hint | Should -Match 'Someone else pushed'
    }

    It 'Explains missing write access' {
        $hint = InModuleScope 'IMPACT_Docker_GUI' { Get-GitPushFailureHint -Output 'ERROR: Permission to org/repo.git denied to bob.' }
        $hint | Should -Match 'write access'
    }

    It 'Explains a protected branch (remote rejected) rather than a non-fast-forward' {
        $hint = InModuleScope 'IMPACT_Docker_GUI' { Get-GitPushFailureHint -Output ' ! [remote rejected] main -> main (protected branch hook declined)' }
        $hint | Should -Match 'protected'
    }

    It 'Explains network problems' {
        $hint = InModuleScope 'IMPACT_Docker_GUI' { Get-GitPushFailureHint -Output 'ssh: Could not resolve hostname github.com: Name or service not known' }
        $hint | Should -Match 'could not be reached'
    }

    It 'Falls back to a generic sentence' {
        $hint = InModuleScope 'IMPACT_Docker_GUI' { Get-GitPushFailureHint -Output 'something unexpected' }
        $hint | Should -Match 'details are shown below'
    }
}


# ═══════════════════════════════════════════════════════════════════════════════
#  Docker volume names, custom params, container labels, port binding
#  (lifecycle / volume fixes: F13, F48, F102, F01/F04)
# ═══════════════════════════════════════════════════════════════════════════════
Describe 'Get-ImpactVolumeNames' -Tag Unit {
    It 'Includes the container name, so two repos of one user get different volumes' {
        $a = Get-ImpactVolumeNames -ContainerName 'IMPACTncd_Germany_alice'
        $b = Get-ImpactVolumeNames -ContainerName 'OtherRepo_alice'
        $a.Output   | Should -Be 'impactncd_output_IMPACTncd_Germany_alice'
        $a.Synthpop | Should -Be 'impactncd_synthpop_IMPACTncd_Germany_alice'
        $a.Output   | Should -Not -Be $b.Output
        $a.Synthpop | Should -Not -Be $b.Synthpop
    }

    It 'Replaces characters Docker does not allow, but keeps dash and dot' {
        $n = Get-ImpactVolumeNames -ContainerName 'my repo/x.y-z_al ice'
        $n.Output | Should -Be 'impactncd_output_my_repo_x.y-z_al_ice'
        $n.Output | Should -Match '^[a-zA-Z0-9][a-zA-Z0-9_.-]+$'
    }
}

Describe 'Split-DockerCustomParams' -Tag Unit {
    It 'Ignores leading, trailing and repeated spaces (no empty arguments)' {
        $t = @(Split-DockerCustomParams -Text '  --shm-size   2g  ')
        $t.Count | Should -Be 2
        $t[0] | Should -Be '--shm-size'
        $t[1] | Should -Be '2g'
    }

    It 'Keeps a quoted value with spaces together and removes the quotes' {
        $t = @(Split-DockerCustomParams -Text "-e `"TZ=Europe Berlin`" --label 'a b=c'")
        $t | Should -Be @('-e', 'TZ=Europe Berlin', '--label', 'a b=c')
    }

    It 'Keeps Windows backslashes unchanged' {
        $t = @(Split-DockerCustomParams -Text '-v C:\data\x:/data')
        $t | Should -Be @('-v', 'C:\data\x:/data')
    }

    It 'Returns nothing for empty or blank input' {
        @(Split-DockerCustomParams -Text '').Count    | Should -Be 0
        @(Split-DockerCustomParams -Text '   ').Count | Should -Be 0
    }

    It 'Treats a missing closing quote as running to the end' {
        $t = @(Split-DockerCustomParams -Text '-e "A=b c')
        $t | Should -Be @('-e', 'A=b c')
    }
}

Describe 'Get-ImpactContainerLabelArgs' -Tag Unit {
    It 'Records volume mode, result folders and volume names' {
        $l = Get-ImpactContainerLabelArgs -UseVolumes $true -OutputDir 'C:\o' -SynthpopDir '/s' -VolumeOutput 'vo' -VolumeSynthpop 'vs'
        $l | Should -Contain 'impact.use_volumes=true'
        $l | Should -Contain 'impact.output_dir=C:\o'
        $l | Should -Contain 'impact.synthpop_dir=/s'
        $l | Should -Contain 'impact.volume_output=vo'
        $l | Should -Contain 'impact.volume_synthpop=vs'
        # every value is preceded by --label
        for ($i = 0; $i -lt $l.Count; $i += 2) { $l[$i] | Should -Be '--label' }
    }

    It 'Records use_volumes=false and no volume names in bind mode' {
        $l = Get-ImpactContainerLabelArgs -UseVolumes $false -OutputDir '/o' -SynthpopDir '/s' -VolumeOutput 'vo' -VolumeSynthpop 'vs'
        $l | Should -Contain 'impact.use_volumes=false'
        ($l -join ' ') | Should -Not -Match 'impact.volume_'
    }

    It 'Leaves out empty folders' {
        $l = Get-ImpactContainerLabelArgs -UseVolumes $false -OutputDir '' -SynthpopDir '' -VolumeOutput '' -VolumeSynthpop ''
        $l | Should -Be @('--label', 'impact.use_volumes=false')
    }
}

Describe 'Build-DockerRunCommand port binding, labels and custom params' -Tag Unit {
    BeforeAll {
        $script:b3Local  = New-TestSessionState -UserName 'alice' -Password 'secret' -SelectedRepo 'IMPACTncd_Germany'
        $script:b3Remote = New-TestSessionState -UserName 'alice' -Password 'secret' -Location 'REMOTE@10.152.14.124'
        $script:b3Common = @{
            ImageName      = 'test-image'
            ProjectRoot    = 'C:\repos\IMPACTncd_Germany'
            OutputDir      = 'C:\repos\IMPACTncd_Germany\outputs'
            SynthpopDir    = 'C:\repos\IMPACTncd_Germany\inputs\synthpop'
            SshKeyPath     = 'C:\Users\alice\.ssh\id_ed25519_alice'
            KnownHostsPath = 'C:\Users\alice\.ssh\known_hosts'
        }
    }

    It 'Publishes LOCAL containers on 127.0.0.1 only' {
        $common = $script:b3Common
        $a = Build-DockerRunCommand -State $script:b3Local -Port '8790' @common
        $a | Should -Contain '127.0.0.1:8790:8787'
        $a | Should -Not -Contain '8790:8787'
    }

    It 'Publishes REMOTE containers on all interfaces' {
        $common = $script:b3Common
        $a = Build-DockerRunCommand -State $script:b3Remote -Port '8790' @common
        $a | Should -Contain '8790:8787'
        ($a -join ' ') | Should -Not -Match '127\.0\.0\.1'
    }

    It 'Adds labels before the image name' {
        $common = $script:b3Common
        $a = Build-DockerRunCommand -State $script:b3Local -UseVolumes $true @common
        $a | Should -Contain 'impact.use_volumes=true'
        $a | Should -Contain 'impact.output_dir=C:\repos\IMPACTncd_Germany\outputs'
        $a | Should -Contain "impact.volume_output=impactncd_output_$($script:b3Local.ContainerName)"
        $a[-1] | Should -Be 'test-image'
    }

    It 'Never produces empty arguments from custom params with extra spaces' {
        $common = $script:b3Common
        $a = Build-DockerRunCommand -State $script:b3Local -CustomParams '  --shm-size  2g  ' @common
        @($a | Where-Object { $_ -eq '' }).Count | Should -Be 0
        $a | Should -Contain '--shm-size'
        $a[-1] | Should -Be 'test-image'
    }
}
