<#
.SYNOPSIS
    Pester 5 unit tests for IMPACT Docker GUI pure-logic functions.
    These tests do NOT require Docker, SSH, or a network connection.

    Run:  pwsh -File tests/Invoke-Tests.ps1 -Tag Unit
#>

BeforeAll {
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
            -SshKeyPath 'C:\Users\alice\.ssh\id_ed25519_alice' `
            -KnownHostsPath 'C:\Users\alice\.ssh\known_hosts'

        $args[0] | Should -Be 'run'
    }

    It 'Includes container name from state' {
        $args = Build-DockerRunCommand -State $baseState -ImageName 'test-image' `
            -ProjectRoot 'C:\repos\IMPACTncd_Germany' `
            -OutputDir 'C:\repos\IMPACTncd_Germany\outputs' `
            -SynthpopDir 'C:\repos\IMPACTncd_Germany\inputs\synthpop' `
            -SshKeyPath 'C:\Users\alice\.ssh\id_ed25519_alice' `
            -KnownHostsPath 'C:\Users\alice\.ssh\known_hosts'

        $args | Should -Contain $baseState.ContainerName
    }

    It 'Sets PASSWORD environment variable' {
        $args = Build-DockerRunCommand -State $baseState -ImageName 'test-image' `
            -ProjectRoot 'C:\repos\IMPACTncd_Germany' `
            -OutputDir 'C:\repos\IMPACTncd_Germany\outputs' `
            -SynthpopDir 'C:\repos\IMPACTncd_Germany\inputs\synthpop' `
            -SshKeyPath 'C:\Users\alice\.ssh\id_ed25519_alice' `
            -KnownHostsPath 'C:\Users\alice\.ssh\known_hosts'

        $args | Should -Contain 'PASSWORD=secret'
    }

    It 'Maps port correctly' {
        $args = Build-DockerRunCommand -State $baseState -Port '9090' -ImageName 'test-image' `
            -ProjectRoot 'C:\repos\IMPACTncd_Germany' `
            -OutputDir 'C:\repos\IMPACTncd_Germany\outputs' `
            -SynthpopDir 'C:\repos\IMPACTncd_Germany\inputs\synthpop' `
            -SshKeyPath 'C:\Users\alice\.ssh\id_ed25519_alice' `
            -KnownHostsPath 'C:\Users\alice\.ssh\known_hosts'

        $args | Should -Contain '9090:8787'
    }

    It 'Appends high-compute flags only for remote mode' {
        $remoteState = New-TestSessionState -UserName 'alice' -Password 'secret' -Location 'REMOTE@10.152.14.124'
        $args = Build-DockerRunCommand -State $remoteState -HighCompute $true -ImageName 'test-image' `
            -ProjectRoot '/home/php-workstation/Schreibtisch/Repositories/IMPACTncd_Germany' `
            -OutputDir '/mnt/Storage_1/IMPACT_Storage/Base/outputs' `
            -SynthpopDir '/mnt/Storage_1/IMPACT_Storage/Base/inputs/synthpop' `
            -SshKeyPath '/home/php-workstation/.ssh/id_ed25519_alice' `
            -KnownHostsPath '/home/php-workstation/.ssh/known_hosts'

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
            -SshKeyPath 'C:\Users\alice\.ssh\id_ed25519_alice' `
            -KnownHostsPath 'C:\Users\alice\.ssh\known_hosts'

        $args | Should -Not -Contain '--cpus'
    }

    It 'Uses Docker volumes when UseVolumes is true' {
        $args = Build-DockerRunCommand -State $baseState -UseVolumes $true -ImageName 'test-image' `
            -ProjectRoot 'C:\repos\IMPACTncd_Germany' `
            -OutputDir 'C:\repos\IMPACTncd_Germany\outputs' `
            -SynthpopDir 'C:\repos\IMPACTncd_Germany\inputs\synthpop' `
            -SshKeyPath 'C:\Users\alice\.ssh\id_ed25519_alice' `
            -KnownHostsPath 'C:\Users\alice\.ssh\known_hosts'

        $joined = $args -join ' '
        $joined | Should -Match '-v.*impactncd_germany_output_alice'
        $joined | Should -Match '-v.*impactncd_germany_synthpop_alice'
    }

    It 'Uses bind mounts when UseVolumes is false' {
        $args = Build-DockerRunCommand -State $baseState -UseVolumes $false -ImageName 'test-image' `
            -ProjectRoot 'C:\repos\IMPACTncd_Germany' `
            -OutputDir 'C:\repos\IMPACTncd_Germany\outputs' `
            -SynthpopDir 'C:\repos\IMPACTncd_Germany\inputs\synthpop' `
            -SshKeyPath 'C:\Users\alice\.ssh\id_ed25519_alice' `
            -KnownHostsPath 'C:\Users\alice\.ssh\known_hosts'

        $joined = $args -join ' '
        $joined | Should -Match 'type=bind.*outputs'
        $joined | Should -Match 'type=bind.*synthpop'
    }

    It 'Includes image name as last argument' {
        $args = Build-DockerRunCommand -State $baseState -ImageName 'my-image' `
            -ProjectRoot 'C:\repos\IMPACTncd_Germany' `
            -OutputDir 'C:\repos\IMPACTncd_Germany\outputs' `
            -SynthpopDir 'C:\repos\IMPACTncd_Germany\inputs\synthpop' `
            -SshKeyPath 'C:\Users\alice\.ssh\id_ed25519_alice' `
            -KnownHostsPath 'C:\Users\alice\.ssh\known_hosts'

        $args[-1] | Should -Be 'my-image'
    }

    It 'Splits custom params into individual arguments' {
        $args = Build-DockerRunCommand -State $baseState -CustomParams '--gpus all --shm-size 4g' -ImageName 'test-image' `
            -ProjectRoot 'C:\repos\IMPACTncd_Germany' `
            -OutputDir 'C:\repos\IMPACTncd_Germany\outputs' `
            -SynthpopDir 'C:\repos\IMPACTncd_Germany\inputs\synthpop' `
            -SshKeyPath 'C:\Users\alice\.ssh\id_ed25519_alice' `
            -KnownHostsPath 'C:\Users\alice\.ssh\known_hosts'

        $args | Should -Contain '--gpus'
        $args | Should -Contain 'all'
        $args | Should -Contain '--shm-size'
        $args | Should -Contain '4g'
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
    # NOTE: These tests write to the real $HOME/.ssh/config since PowerShell's $HOME
    # automatic variable cannot be overridden via $env:HOME on Windows.
    # We test idempotency and cleanup by targeting a unique IP that won't collide.

    BeforeAll {
        $script:testIp = '198.51.100.99'  # RFC 5737 TEST-NET-3, won't collide with real entries
        $script:configPath = Join-Path $HOME '.ssh' 'config'
    }

    AfterAll {
        # Cleanup: remove the test entry if it exists
        if (Test-Path $script:configPath) {
            Remove-SshConfigHostBlock -ConfigPath $script:configPath -HostPattern $script:testIp
        }
    }

    It 'Creates or appends SSH config entry for a new Host' {
        # Remove any leftover from previous runs
        if (Test-Path $script:configPath) {
            Remove-SshConfigHostBlock -ConfigPath $script:configPath -HostPattern $script:testIp
        }

        # Create a dummy key file so Ensure-SshConfigEntry doesn't consider it "missing"
        $dummyKeyDir = Join-Path $env:TEMP 'impact_sshconfig_test_key'
        New-Item -ItemType Directory -Path $dummyKeyDir -Force | Out-Null
        $dummyKey = Join-Path $dummyKeyDir 'id_ed25519_test'
        Set-Content -Path $dummyKey -Value 'dummy-key-content'

        Ensure-SshConfigEntry -RemoteHostIp $script:testIp -RemoteUser 'php-workstation' -IdentityFile ($dummyKey -replace '\\','/')

        Test-Path $script:configPath | Should -BeTrue
        $content = Get-Content $script:configPath -Raw
        $content | Should -Match ([regex]::Escape($script:testIp))

        Remove-Item -Recurse -Force $dummyKeyDir -ErrorAction SilentlyContinue
    }

    It 'Does not duplicate entry on second call with same key' {
        $dummyKeyDir = Join-Path $env:TEMP 'impact_sshconfig_test_key'
        New-Item -ItemType Directory -Path $dummyKeyDir -Force | Out-Null
        $dummyKey = Join-Path $dummyKeyDir 'id_ed25519_test'
        Set-Content -Path $dummyKey -Value 'dummy-key-content'

        Ensure-SshConfigEntry -RemoteHostIp $script:testIp -RemoteUser 'php-workstation' -IdentityFile ($dummyKey -replace '\\','/')
        Ensure-SshConfigEntry -RemoteHostIp $script:testIp -RemoteUser 'php-workstation' -IdentityFile ($dummyKey -replace '\\','/')

        $content = Get-Content $script:configPath -Raw
        $count = ([regex]::Matches($content, [regex]::Escape("Host $($script:testIp)"))).Count
        $count | Should -Be 1

        Remove-Item -Recurse -Force $dummyKeyDir -ErrorAction SilentlyContinue
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
}
