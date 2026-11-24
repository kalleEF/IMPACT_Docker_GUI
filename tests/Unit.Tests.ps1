<#
.SYNOPSIS
    Pester unit tests for IMPACT Docker GUI pure-logic functions.
    These tests do NOT require Docker, SSH, or a network connection.
    Many tests use mocks: a mock is a stand-in for a command during a test (Pester's
    'Mock' command replaces the command with a small piece of test code).

    Run:  pwsh -File tests/Invoke-Tests.ps1 -Tag Unit
#>

BeforeAll {
    # Many tests build temp paths from $env:TEMP, which exists on Windows only. On Linux
    # (CI containers, developer machines) it is empty, so Join-Path failed before the
    # test could check anything. Use the system temp folder there instead.
    if (-not $env:TEMP) { $env:TEMP = [System.IO.Path]::GetTempPath() }

    # Point the IMPACT log at a temp file for this whole test file (TS-1). Without this,
    # every Write-Log call in the tests was appended to the developer's REAL log file
    # (~/.impact_gui/logs/impact.log, the file users send to the maintainer), and once
    # that file was larger than 512 KB, Initialize-Logging rotated it and replaced the
    # real impact.log.1. The old values are saved here and put back in AfterAll below.
    # It is set before Import-Module, so even the very first log line goes to the temp
    # file (the module reads IMPACT_LOG_FILE when it writes its first log line). CI calls
    # Invoke-Pester directly, so this is done here in the test file and not only in the
    # runner (Invoke-Tests.ps1).
    $script:savedImpactLogFile = $env:IMPACT_LOG_FILE
    $script:savedImpactLogDisable = $env:IMPACT_LOG_DISABLE
    $script:testRunLogFile = Join-Path ([System.IO.Path]::GetTempPath()) "impact_unit_tests_$([guid]::NewGuid().ToString('N').Substring(0,8)).log"
    $env:IMPACT_LOG_FILE = $script:testRunLogFile

    # Import the module under test
    $modulePath = Join-Path $PSScriptRoot '..' 'current_version' 'IMPACT_Docker_GUI.psm1'
    Import-Module $modulePath -Force -DisableNameChecking

    # Import test helpers
    . (Join-Path $PSScriptRoot 'Helpers' 'TestSessionState.ps1')
}

AfterAll {
    # Put the IMPACT log settings back as they were before this test file (TS-1), and
    # remove the temp log file (and its rotated copy, if a test made one).
    $env:IMPACT_LOG_FILE = $script:savedImpactLogFile
    $env:IMPACT_LOG_DISABLE = $script:savedImpactLogDisable
    Remove-Item -LiteralPath $script:testRunLogFile -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath "$($script:testRunLogFile).1" -Force -ErrorAction SilentlyContinue
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

# IMPACT Docker GUI - auto-generated entry
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
#  Get-YamlPathValue - LOCAL mode (sim_design_local.yaml with Windows paths)
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
        # Windows BaseDir (forward-slashed) - result must NOT start with "/" so Test-AndCreateDirectory accepts it
        $baseDir = 'C:/Users/testuser/repos/IMPACTncd_Germany'
        $result = Get-YamlPathValue -State $state -YamlPath $yamlFile -Key 'synthpop_dir' -BaseDir $baseDir
        $result | Should -BeLike 'C:/Users/testuser/repos/IMPACTncd_Germany*inputs/synthpop'
        # Ensure it does NOT look like a POSIX absolute path (starting with /)
        $result | Should -Not -Match '^\/'
    }

    # Windows only (TS-6): 'C:/...' is an absolute path only under Windows path rules. On
    # Linux [System.IO.Path]::IsPathRooted('C:/...') is false, so the function joins it to
    # BaseDir there, which is correct for Linux but not what this test checks.
    It 'Keeps a Windows absolute path as-is when specified in local YAML' -Skip:(-not $IsWindows) {
        Set-Content -Path $yamlFile -Value "output_dir: C:/Users/testuser/Documents/IMPACTncd_Germany/outputs"
        $state = New-TestSessionState -Location 'LOCAL'
        $result = Get-YamlPathValue -State $state -YamlPath $yamlFile -Key 'output_dir' -BaseDir 'C:/Users/testuser/repos/IMPACTncd_Germany'
        $result | Should -Be 'C:/Users/testuser/Documents/IMPACTncd_Germany/outputs'
    }
}

# ═══════════════════════════════════════════════════════════════════════════════
#  Get-YamlPathValue - REMOTE mode (sim_design.yaml with POSIX paths)
#  SSH is mocked so the function reads YAML content without a real connection.
# ═══════════════════════════════════════════════════════════════════════════════
Describe 'Get-YamlPathValue (REMOTE / sim_design.yaml)' -Tag Unit {
    BeforeAll {
        # Pester can only mock commands that exist (TS-6). On a machine without OpenSSH
        # (for example a Linux test box) we define a throw-away global 'ssh' function so
        # the 'Mock ssh' calls below work. It is removed again in AfterAll.
        $script:remoteYamlSshStubAdded = $false
        if (-not (Get-Command ssh -ErrorAction SilentlyContinue)) {
            function global:ssh { throw 'ssh stub: this call should have been mocked' }
            $script:remoteYamlSshStubAdded = $true
        }
    }

    AfterAll {
        # 'Function:\ssh' really removes the global stub, so later tests see no fake ssh.
        if ($script:remoteYamlSshStubAdded) { Remove-Item -Path Function:\ssh -ErrorAction SilentlyContinue }
    }

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
        # Absolute path - returned as-is, NOT joined with BaseDir
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
    BeforeAll {
        # Pester can only mock commands that exist (TS-6): the REMOTE test below uses
        # 'Mock ssh'. Without OpenSSH a throw-away global 'ssh' function stands in for it;
        # it is removed again in AfterAll.
        $script:dirSshStubAdded = $false
        if (-not (Get-Command ssh -ErrorAction SilentlyContinue)) {
            function global:ssh { throw 'ssh stub: this call should have been mocked' }
            $script:dirSshStubAdded = $true
        }
    }

    AfterAll {
        if ($script:dirSshStubAdded) { Remove-Item -Path Function:\ssh -ErrorAction SilentlyContinue }
    }

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
    #    in case the module ever builds that path in another way;
    #  - default mocks pass every other call of these commands on to the real command.
    BeforeAll {
        $script:testIp = '198.51.100.99'  # RFC 5737 TEST-NET-3, won't collide with real entries
        $script:realSshDir = Join-Path $HOME '.ssh'
        # The same folder written with '/' only. The safety nets below turn every '\'
        # into '/' before they compare paths, so they also catch a path that mixes the
        # two, such as "$HOME/.ssh/config" on Windows (C:\Users\me/.ssh/config).
        $script:realSshDirSlash = $script:realSshDir -replace '\\', '/'

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

        # Default mocks: every call of these commands that none of the mocks with a
        # -ParameterFilter below accepts goes on to the real command, with the same
        # parameters (see Invoke-RealCommand in Helpers/TestSessionState.ps1). Without
        # them Pester stops such a call with "No mock for command ... matched the call",
        # and the module would lose, for example, the Join-Path that builds
        # <temp>/.ssh/config, or its log lines (Write-Log ignores errors of Add-Content).
        Mock Join-Path   -ModuleName 'IMPACT_Docker_GUI' { Invoke-RealCommand -Name 'Join-Path'   -Parameters $PesterBoundParameters }
        Mock Add-Content -ModuleName 'IMPACT_Docker_GUI' { Invoke-RealCommand -Name 'Add-Content' -Parameters $PesterBoundParameters }
        Mock Set-Content -ModuleName 'IMPACT_Docker_GUI' { Invoke-RealCommand -Name 'Set-Content' -Parameters $PesterBoundParameters }
        Mock New-Item    -ModuleName 'IMPACT_Docker_GUI' { Invoke-RealCommand -Name 'New-Item'    -Parameters $PesterBoundParameters }
        Mock Copy-Item   -ModuleName 'IMPACT_Docker_GUI' { Invoke-RealCommand -Name 'Copy-Item'   -Parameters $PesterBoundParameters }
        Mock Remove-Item -ModuleName 'IMPACT_Docker_GUI' { Invoke-RealCommand -Name 'Remove-Item' -Parameters $PesterBoundParameters }

        # Redirect "$HOME/.ssh" inside the module to the temp folder. All other Join-Path
        # calls go to the default mock above and run normally.
        Mock Join-Path -ModuleName 'IMPACT_Docker_GUI' -ParameterFilter { $Path -eq $HOME -and $ChildPath -eq '.ssh' } { $script:fakeSshDir }
        # Safety net: never touch the real ~/.ssh, whatever the module does.
        # The filters look at "$Path$LiteralPath" (TS-2): the module writes the ssh config
        # with -LiteralPath, and a filter on $Path alone never saw those calls, so the
        # safety net did not fire for exactly the writes it is meant to catch. Only one of
        # the two parameters is ever given, so joining them gives the path that was used.
        # Copy-Item (the config backup) is checked on its -Destination, and Remove-Item
        # (a stray .pub file is deleted) is guarded too. Both paths are compared with '/'
        # only (see $script:realSshDirSlash in BeforeAll).
        Mock Add-Content -ModuleName 'IMPACT_Docker_GUI' -ParameterFilter { ("$Path$LiteralPath" -replace '\\', '/') -like "$($script:realSshDirSlash)*" } { throw "Test tried to write the real SSH folder: $Path$LiteralPath" }
        Mock Set-Content -ModuleName 'IMPACT_Docker_GUI' -ParameterFilter { ("$Path$LiteralPath" -replace '\\', '/') -like "$($script:realSshDirSlash)*" } { throw "Test tried to write the real SSH folder: $Path$LiteralPath" }
        Mock New-Item    -ModuleName 'IMPACT_Docker_GUI' -ParameterFilter { ("$Path" -replace '\\', '/') -like "$($script:realSshDirSlash)*" } { throw "Test tried to create something in the real SSH folder: $Path" }
        Mock Copy-Item   -ModuleName 'IMPACT_Docker_GUI' -ParameterFilter { ("$Destination" -replace '\\', '/') -like "$($script:realSshDirSlash)*" } { throw "Test tried to copy a file into the real SSH folder: $Destination" }
        Mock Remove-Item -ModuleName 'IMPACT_Docker_GUI' -ParameterFilter { ("$Path$LiteralPath" -replace '\\', '/') -like "$($script:realSshDirSlash)*" } { throw "Test tried to delete something in the real SSH folder: $Path$LiteralPath" }
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

    # Runs on every platform (X-4): Ensure-SshConfigEntry turns '\' into '/' before it
    # checks that the key file exists, which works on Linux too. (This test used to be
    # skipped outside Windows because of an older version of that check.)
    It 'Leaves a valid entry byte-for-byte unchanged' {
        Ensure-SshConfigEntry -RemoteHostIp $script:testIp -RemoteUser 'php-workstation' -IdentityFile $script:keyA
        # Without this check the test would also pass when no config file is written at
        # all: both reads below would then give $null.
        Test-Path -LiteralPath $script:configPath | Should -BeTrue -Because 'the redirected config file must have been written'
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

    # Needs the real ssh-keygen program (TS-6), so it is skipped where OpenSSH is missing.
    It 'New-DummySshKeyPair creates a usable (unencrypted) ed25519 keypair' -Skip:(-not (Get-Command ssh-keygen -ErrorAction SilentlyContinue)) {
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
#  Initialize-Logging - log directory creation & rotation
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
        # Undo the environment override of each test. The values go back to what the
        # top-level BeforeAll of this file set (the temp log file, and the developer's
        # own IMPACT_LOG_DISABLE). Setting them to $null here sent the log lines of later
        # tests to the real ~/.impact_gui/logs/impact.log and cleared a value that the
        # developer had set (TS-1).
        $env:IMPACT_LOG_FILE = $script:testRunLogFile
        $env:IMPACT_LOG_DISABLE = $script:savedImpactLogDisable
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
#  Ensure-PowerShell7 - guard logic
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
#  Test-GitHubUsername - GitHub API validation
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

Describe 'Get-GitPushFailureHint for a detached HEAD' -Tag Unit {
    It 'Advises creating a new branch (switching away would leave the commits behind)' {
        $hint = InModuleScope 'IMPACT_Docker_GUI' { Get-GitPushFailureHint -Output 'fatal: You are not on a branch (detached HEAD), so there is nothing to push.' }
        $hint | Should -Match 'New Branch'
        $hint | Should -Match 'git switch -c'
        $hint | Should -Not -Match 'Switch to a branch'
    }
}

# ═══════════════════════════════════════════════════════════════════════════════
#  C2: port box input, repository label, network folders, safe shell quoting
# ═══════════════════════════════════════════════════════════════════════════════
Describe 'Test-PortValue with non-ASCII digits (B6a-R4)' -Tag Unit {
    It 'Rejects full-width digits without throwing' {
        # U+FF18 U+FF17 U+FF18 U+FF17 = full-width '8787', as typed with an IME.
        $fullWidth = -join ([char[]](0xFF18, 0xFF17, 0xFF18, 0xFF17))
        { Test-PortValue -Port $fullWidth } | Should -Not -Throw
        $r = Test-PortValue -Port $fullWidth
        $r.Valid | Should -BeFalse
        $r.ErrorMessage | Should -Be 'Port must be a number.'
    }

    It 'Rejects Arabic-Indic digits without throwing' {
        $arabic = -join ([char[]](0x0668, 0x0667, 0x0668, 0x0667))
        { Test-PortValue -Port $arabic } | Should -Not -Throw
        (Test-PortValue -Port $arabic).Valid | Should -BeFalse
    }

    It 'Still accepts a normal port in the range' {
        (Test-PortValue -Port '8790').Valid | Should -BeTrue
    }
}

Describe 'Repository folder label impact.repo_path (F84)' -Tag Unit {
    It 'Get-ImpactContainerLabelArgs adds the label when -RepoPath is given' {
        $l = Get-ImpactContainerLabelArgs -UseVolumes $false -OutputDir '/o' -SynthpopDir '/s' -RepoPath 'C:\Users\Max Mustermann\IMPACTncd_Germany'
        $l | Should -Contain 'impact.repo_path=C:\Users\Max Mustermann\IMPACTncd_Germany'
        # every value is still preceded by --label
        for ($i = 0; $i -lt $l.Count; $i += 2) { $l[$i] | Should -Be '--label' }
    }

    It 'Get-ImpactContainerLabelArgs leaves the label out without -RepoPath (older callers)' {
        $l = Get-ImpactContainerLabelArgs -UseVolumes $false
        ($l -join ' ') | Should -Not -Match 'impact\.repo_path'
    }

    It 'Build-DockerRunCommand records the project root and keeps the image name last' {
        $state = New-TestSessionState -UserName 'alice'
        $a = Build-DockerRunCommand -State $state -ImageName 'img' -ProjectRoot 'C:\r\IMPACTncd_Germany' -OutputDir 'C:\r\o' -SynthpopDir 'C:\r\s' -SshKeyPath 'C:\k'
        $a | Should -Contain 'impact.repo_path=C:\r\IMPACTncd_Germany'
        $a[-1] | Should -Be 'img'
    }
}

Describe 'Test-AndCreateDirectory: network folders and remote quoting (F36, B4-R6, B4-R7)' -Tag Unit {
    BeforeAll {
        # Same ssh stub as in the other Test-AndCreateDirectory tests, for machines without ssh.
        $script:c2DirSshStubAdded = $false
        if (-not (Get-Command ssh -ErrorAction SilentlyContinue)) {
            function global:ssh { throw 'ssh stub: this call should have been mocked' }
            $script:c2DirSshStubAdded = $true
        }
    }

    AfterAll {
        if ($script:c2DirSshStubAdded) { Remove-Item -Path Function:\ssh -ErrorAction SilentlyContinue }
    }

    It 'Reports NetworkPathInLocalMode for a UNC path in the //server/share form Get-YamlPathValue returns' {
        $why = $null
        Test-AndCreateDirectory -State (New-TestSessionState -Location 'LOCAL') -Path '//fileserver/share/outputs' -PathKey 'output_dir' -Reason ([ref]$why) | Should -BeFalse
        # Not 'PosixPathInLocalMode': that message would wrongly advise a Windows path.
        $why | Should -Be 'NetworkPathInLocalMode'
    }

    It 'Reports NetworkPathInLocalMode for a UNC path with backslashes' {
        $why = $null
        Test-AndCreateDirectory -State (New-TestSessionState -Location 'LOCAL') -Path '\\fileserver\share\outputs' -PathKey 'output_dir' -Reason ([ref]$why) | Should -BeFalse
        $why | Should -Be 'NetworkPathInLocalMode'
    }

    It 'Accepts a normal local folder, also one with [ ] in its name' {
        $dir = Join-Path ([System.IO.Path]::GetTempPath()) "impact_c2 [v2] $([guid]::NewGuid().ToString('N').Substring(0,6))"
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        try {
            Test-AndCreateDirectory -State (New-TestSessionState -Location 'LOCAL') -Path $dir -PathKey 'output_dir' | Should -BeTrue
        } finally {
            Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'Does not apply the network check in REMOTE mode' {
        Mock ssh { 'EXISTS' } -ModuleName 'IMPACT_Docker_GUI'
        Test-AndCreateDirectory -State (New-TestSessionState -Location 'REMOTE@10.0.0.5') -Path '//data/outputs' -PathKey 'output_dir' | Should -BeTrue
    }

    It 'Quotes a remote path that contains a single quote safely for the shell' {
        $script:c2LastSshCmd = $null
        Mock ssh { $script:c2LastSshCmd = $args[-1]; 'EXISTS' } -ModuleName 'IMPACT_Docker_GUI'
        Test-AndCreateDirectory -State (New-TestSessionState -Location 'REMOTE@10.0.0.5') -Path "/mnt/it's/out" -PathKey 'output_dir' | Should -BeTrue
        $script:c2LastSshCmd | Should -BeExactly "test -d '/mnt/it'\''s/out' && echo EXISTS || echo MISSING"
    }
}

Describe 'Get-YamlPathValue: brackets and quotes in paths (B2-R3, B4-R7)' -Tag Unit {
    BeforeAll {
        $script:c2YamlSshStubAdded = $false
        if (-not (Get-Command ssh -ErrorAction SilentlyContinue)) {
            function global:ssh { throw 'ssh stub: this call should have been mocked' }
            $script:c2YamlSshStubAdded = $true
        }
    }

    AfterAll {
        if ($script:c2YamlSshStubAdded) { Remove-Item -Path Function:\ssh -ErrorAction SilentlyContinue }
    }

    It 'Reads a local YAML file in a folder whose name contains [ ]' {
        $dir = Join-Path ([System.IO.Path]::GetTempPath()) "impact_c2 [v2] $([guid]::NewGuid().ToString('N').Substring(0,6))"
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        try {
            $yaml = Join-Path $dir 'sim_design_local.yaml'
            Set-Content -LiteralPath $yaml -Value "output_dir: ./outputs`nsynthpop_dir: ./inputs/synthpop"
            $v = Get-YamlPathValue -State (New-TestSessionState -Location 'LOCAL') -YamlPath $yaml -Key 'synthpop_dir' -BaseDir ($dir -replace '\\', '/')
            $v | Should -Not -BeNullOrEmpty
            $v | Should -BeLike '*inputs/synthpop'
        } finally {
            Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'Quotes a remote YAML path that contains a single quote safely for the shell' {
        $script:c2YamlCmd = $null
        Mock ssh { $script:c2YamlCmd = $args[-1]; return 'output_dir: /mnt/out' } -ModuleName 'IMPACT_Docker_GUI'
        $v = Get-YamlPathValue -State (New-TestSessionState -Location 'REMOTE@10.0.0.1') -YamlPath "/home/u/it's/sim_design.yaml" -Key 'output_dir' -BaseDir '/home/u'
        $v | Should -Be '/mnt/out'
        $script:c2YamlCmd | Should -BeExactly "if [ -f '/home/u/it'\''s/sim_design.yaml' ]; then cat '/home/u/it'\''s/sim_design.yaml'; else echo __IMPACT_YAML_MISSING__; fi"
    }
}

# ═══════════════════════════════════════════════════════════════════════════════
#  C3: Remove-SshConfigHostBlock keeps the user's Match/Include sections and comments
#  (F99: the old code deleted everything up to the next 'Host' line)
# ═══════════════════════════════════════════════════════════════════════════════
Describe 'Remove-SshConfigHostBlock (Match, Include and comments after the block)' -Tag Unit {
    BeforeEach {
        $c3Dir = Join-Path ([System.IO.Path]::GetTempPath()) "impact_c3_rm_$([guid]::NewGuid().ToString('N').Substring(0,8))"
        New-Item -ItemType Directory -Path $c3Dir -Force | Out-Null
        $c3Config = Join-Path $c3Dir 'config'
    }

    AfterEach {
        Remove-Item -Recurse -Force -Path $c3Dir -ErrorAction SilentlyContinue
    }

    It 'Stops at a Match line and keeps the Match section' {
        Set-Content -Path $c3Config -Value @(
            '# IMPACT Docker GUI - auto-generated entry for remote workstation'
            'Host 10.0.0.5'
            '    User php-workstation'
            '    IdentityFile "C:/Users/x/.ssh/id_ed25519_x"'
            'Match host *.example.org'
            '    User admin'
        )
        Remove-SshConfigHostBlock -ConfigPath $c3Config -HostPattern '10.0.0.5' | Should -BeTrue
        $text = Get-Content -Path $c3Config -Raw
        $text | Should -Not -Match 'Host 10\.0\.0\.5'
        $text | Should -Not -Match 'id_ed25519_x'
        $text | Should -Match 'Match host \*\.example\.org'
        $text | Should -Match 'User admin'
    }

    It 'Stops at an Include line and keeps it' {
        Set-Content -Path $c3Config -Value @(
            'Host 10.0.0.5'
            '    User php-workstation'
            'Include ~/.ssh/config.d/*'
        )
        Remove-SshConfigHostBlock -ConfigPath $c3Config -HostPattern '10.0.0.5' | Should -BeTrue
        (Get-Content -Path $c3Config -Raw) | Should -Match 'Include ~/\.ssh/config\.d/\*'
    }

    It 'Keeps a comment that introduces the next Host block' {
        Set-Content -Path $c3Config -Value @(
            'Host 10.0.0.5'
            '    User php-workstation'
            ''
            '# my GitHub settings'
            'Host github.com'
            '    User git'
        )
        Remove-SshConfigHostBlock -ConfigPath $c3Config -HostPattern '10.0.0.5' | Should -BeTrue
        $text = Get-Content -Path $c3Config -Raw
        $text | Should -Match '# my GitHub settings'
        $text | Should -Match 'Host github\.com'
        $text | Should -Not -Match 'php-workstation'
    }

    It 'Handles a config file that has only one line' {
        Set-Content -Path $c3Config -Value 'Host 10.0.0.5'
        Remove-SshConfigHostBlock -ConfigPath $c3Config -HostPattern '10.0.0.5' | Should -BeTrue
        (Get-Content -Path $c3Config -Raw) | Should -Not -Match 'Host'
    }
}

# ═══════════════════════════════════════════════════════════════════════════════
#  C3: Ensure-SshConfigEntry quotes the key path, backs up user-written entries and
#  returns nothing (F06 / B4-R1, F67, F38). Uses -ConfigPath with a temporary file,
#  so the developer's real ~/.ssh/config is never touched.
# ═══════════════════════════════════════════════════════════════════════════════
Describe 'Ensure-SshConfigEntry (quoted IdentityFile, backup, no output)' -Tag Unit {
    BeforeEach {
        $c3Dir = Join-Path ([System.IO.Path]::GetTempPath()) "impact_c3_cfg_$([guid]::NewGuid().ToString('N').Substring(0,8))"
        # A folder name with a space, like the profile folder 'C:\Users\Max Mustermann'.
        $c3KeyDir = Join-Path $c3Dir 'Max Mustermann'
        New-Item -ItemType Directory -Path $c3KeyDir -Force | Out-Null
        $c3Key = Join-Path $c3KeyDir 'id_ed25519_max'
        Set-Content -Path $c3Key -Value 'dummy-key-content'
        $c3KeyNorm = $c3Key -replace '\\', '/'
        $c3Config = Join-Path $c3Dir 'config'
        $c3Ip = '198.51.100.77'
    }

    AfterEach {
        Remove-Item -Recurse -Force -Path $c3Dir -ErrorAction SilentlyContinue
    }

    It 'Writes the IdentityFile path in double quotes' {
        Ensure-SshConfigEntry -RemoteHostIp $c3Ip -RemoteUser 'php-workstation' -IdentityFile $c3Key -ConfigPath $c3Config
        $lines = @(Get-Content -Path $c3Config)
        $lines | Should -Contain "    IdentityFile `"$c3KeyNorm`""
    }

    It 'Reads its own quoted entry back and does not rewrite it on the next call' {
        Ensure-SshConfigEntry -RemoteHostIp $c3Ip -RemoteUser 'php-workstation' -IdentityFile $c3Key -ConfigPath $c3Config
        $before = Get-Content -Path $c3Config -Raw
        Ensure-SshConfigEntry -RemoteHostIp $c3Ip -RemoteUser 'php-workstation' -IdentityFile $c3Key -ConfigPath $c3Config
        (Get-Content -Path $c3Config -Raw) | Should -BeExactly $before
        @(Get-ChildItem -Path $c3Dir -Filter 'config.impact-backup-*').Count | Should -Be 0
    }

    It 'Repairs an unquoted path with a space written by an older version, without a backup' {
        Set-Content -Path $c3Config -Value @(
            '# IMPACT Docker GUI - auto-generated entry for remote workstation'
            "Host $c3Ip"
            '    User php-workstation'
            "    IdentityFile $c3KeyNorm"
        )
        Ensure-SshConfigEntry -RemoteHostIp $c3Ip -RemoteUser 'php-workstation' -IdentityFile $c3Key -ConfigPath $c3Config
        $lines = @(Get-Content -Path $c3Config)
        $lines | Should -Contain "    IdentityFile `"$c3KeyNorm`""
        $lines | Should -Not -Contain "    IdentityFile $c3KeyNorm"
        @($lines | Where-Object { $_ -match "^Host $([regex]::Escape($c3Ip))$" }).Count | Should -Be 1
        @(Get-ChildItem -Path $c3Dir -Filter 'config.impact-backup-*').Count | Should -Be 0
    }

    It 'Returns nothing when it repairs an entry (F38: no $true leaking into the caller)' {
        Set-Content -Path $c3Config -Value @(
            '# IMPACT Docker GUI - auto-generated entry for remote workstation'
            "Host $c3Ip"
            '    User php-workstation'
            '    IdentityFile /does/not/exist/id_old'
        )
        $out = @(Ensure-SshConfigEntry -RemoteHostIp $c3Ip -RemoteUser 'php-workstation' -IdentityFile $c3Key -ConfigPath $c3Config)
        $out.Count | Should -Be 0
    }

    It 'Backs up the file before replacing a Host block the user wrote' {
        Set-Content -Path $c3Config -Value @(
            "Host $c3Ip"
            '    User php-workstation'
            '    ProxyJump jumphost.example.org'
            '    IdentityFile /does/not/exist/id_other'
        )
        Ensure-SshConfigEntry -RemoteHostIp $c3Ip -RemoteUser 'php-workstation' -IdentityFile $c3Key -ConfigPath $c3Config
        $backups = @(Get-ChildItem -Path $c3Dir -Filter 'config.impact-backup-*')
        $backups.Count | Should -Be 1
        (Get-Content -LiteralPath $backups[0].FullName -Raw) | Should -Match 'ProxyJump jumphost\.example\.org'
        (Get-Content -Path $c3Config -Raw) | Should -Match ([regex]::Escape("IdentityFile `"$c3KeyNorm`""))
    }
}

# ═══════════════════════════════════════════════════════════════════════════════
#  C3: Initialize-ImpactSshKeyPair (F65 half-present pair, F14 / B6a-R1 encrypted key)
#  ssh-keygen itself is replaced by a mock of Invoke-ImpactSshKeygen, so these tests
#  also run where no ssh-keygen exists.
# ═══════════════════════════════════════════════════════════════════════════════
Describe 'Initialize-ImpactSshKeyPair' -Tag Unit {
    BeforeEach {
        $c3Dir = Join-Path ([System.IO.Path]::GetTempPath()) "impact_c3_key_$([guid]::NewGuid().ToString('N').Substring(0,8))"
        New-Item -ItemType Directory -Path $c3Dir -Force | Out-Null
        $c3Key = Join-Path $c3Dir 'id_ed25519_jdoe'
        $global:C3KeygenCalls = [System.Collections.Generic.List[string]]::new()
    }

    AfterEach {
        Remove-Item -Recurse -Force -Path $c3Dir -ErrorAction SilentlyContinue
        Remove-Variable -Name C3KeygenCalls -Scope Global -ErrorAction SilentlyContinue
    }

    It 'Uses a complete, unencrypted pair as it is' {
        Set-Content -Path $c3Key -Value 'private'
        Set-Content -Path "$c3Key.pub" -Value 'ssh-ed25519 AAAAC3Nza IMPACT_jdoe'
        Mock Invoke-ImpactSshKeygen {
            $global:C3KeygenCalls.Add(($Arguments -join ' '))
            [pscustomobject]@{ ExitCode = 0; Output = @('ssh-ed25519 AAAAC3Nza IMPACT_jdoe') }
        } -ModuleName 'IMPACT_Docker_GUI'
        $r = InModuleScope 'IMPACT_Docker_GUI' -Parameters @{ K = $c3Key } { param($K) Initialize-ImpactSshKeyPair -KeyPath $K -Comment 'IMPACT_jdoe' }
        $r.Success | Should -BeTrue
        $r.Generated | Should -BeFalse
        $r.Status | Should -Be 'Ready'
        @($global:C3KeygenCalls | Where-Object { $_ -match '^-t ' }).Count | Should -Be 0
    }

    It 'Rebuilds a missing .pub from the private key instead of creating a new key (F65)' {
        Set-Content -Path $c3Key -Value 'private'
        Mock Invoke-ImpactSshKeygen {
            $global:C3KeygenCalls.Add(($Arguments -join ' '))
            [pscustomobject]@{ ExitCode = 0; Output = @('ssh-ed25519 AAAAC3NzaREBUILT') }
        } -ModuleName 'IMPACT_Docker_GUI'
        $r = InModuleScope 'IMPACT_Docker_GUI' -Parameters @{ K = $c3Key } { param($K) Initialize-ImpactSshKeyPair -KeyPath $K -Comment 'IMPACT_jdoe' }
        $r.Success | Should -BeTrue
        $r.Generated | Should -BeFalse
        $r.Status | Should -Be 'PublicKeyRebuilt'
        (Get-Content -Path "$c3Key.pub" -Raw).Trim() | Should -Be 'ssh-ed25519 AAAAC3NzaREBUILT IMPACT_jdoe'
        @($global:C3KeygenCalls | Where-Object { $_ -match '^-t ' }).Count | Should -Be 0
        # The check passes an empty passphrase, so ssh-keygen never asks for one.
        $global:C3KeygenCalls[0] | Should -Match '^-y -P\s+-f '
    }

    It "Removes the accidental '-q' passphrase of keys made by older versions (F14)" {
        Set-Content -Path $c3Key -Value 'private'
        Set-Content -Path "$c3Key.pub" -Value 'ssh-ed25519 AAAAC3Nza IMPACT_jdoe'
        $global:C3Fixed = $false
        Mock Invoke-ImpactSshKeygen {
            $global:C3KeygenCalls.Add(($Arguments -join ' '))
            if ($Arguments[0] -eq '-p') { $global:C3Fixed = $true; return [pscustomobject]@{ ExitCode = 0; Output = @('Your identification has been saved with the new passphrase.') } }
            if ($global:C3Fixed) { return [pscustomobject]@{ ExitCode = 0; Output = @('ssh-ed25519 AAAAC3Nza IMPACT_jdoe') } }
            [pscustomobject]@{ ExitCode = 255; Output = @('Load key "x": incorrect passphrase supplied to decrypt private key') }
        } -ModuleName 'IMPACT_Docker_GUI'
        try {
            $r = InModuleScope 'IMPACT_Docker_GUI' -Parameters @{ K = $c3Key } { param($K) Initialize-ImpactSshKeyPair -KeyPath $K -Comment 'IMPACT_jdoe' }
        } finally { Remove-Variable -Name C3Fixed -Scope Global -ErrorAction SilentlyContinue }
        $r.Success | Should -BeTrue
        $r.Status | Should -Be 'PassphraseRemoved'
        @($global:C3KeygenCalls | Where-Object { $_ -match '^-p -P -q -N\s+-f ' }).Count | Should -Be 1
    }

    It 'Stops with an explanation when the key has a passphrase IMPACT does not know' {
        Set-Content -Path $c3Key -Value 'private'
        Set-Content -Path "$c3Key.pub" -Value 'ssh-ed25519 AAAAC3Nza IMPACT_jdoe'
        Mock Invoke-ImpactSshKeygen {
            [pscustomobject]@{ ExitCode = 255; Output = @('Load key "x": incorrect passphrase supplied to decrypt private key') }
        } -ModuleName 'IMPACT_Docker_GUI'
        $r = InModuleScope 'IMPACT_Docker_GUI' -Parameters @{ K = $c3Key } { param($K) Initialize-ImpactSshKeyPair -KeyPath $K -Comment 'IMPACT_jdoe' }
        $r.Success | Should -BeFalse
        $r.Status | Should -Be 'Encrypted'
        $r.Message | Should -Match 'passphrase'
        $r.Message | Should -Match ([regex]::Escape('ssh-keygen -p -f'))
        # The user's files are left alone.
        Test-Path -LiteralPath $c3Key | Should -BeTrue
        Test-Path -LiteralPath "$c3Key.pub" | Should -BeTrue
    }

    It 'Creates a new pair when only a stale .pub file exists (F65)' {
        Set-Content -Path "$c3Key.pub" -Value 'ssh-ed25519 STALE IMPACT_jdoe'
        Mock Invoke-ImpactSshKeygen {
            $global:C3KeygenCalls.Add(($Arguments -join ' '))
            if ($Arguments[0] -eq '-t') {
                $f = $Arguments[[array]::IndexOf($Arguments, '-f') + 1]
                Set-Content -Path $f -Value 'private'
                Set-Content -Path "$f.pub" -Value 'ssh-ed25519 AAAANEW IMPACT_jdoe'
            }
            [pscustomobject]@{ ExitCode = 0; Output = @('ssh-ed25519 AAAANEW IMPACT_jdoe') }
        } -ModuleName 'IMPACT_Docker_GUI'
        $r = InModuleScope 'IMPACT_Docker_GUI' -Parameters @{ K = $c3Key } { param($K) Initialize-ImpactSshKeyPair -KeyPath $K -Comment 'IMPACT_jdoe' }
        $r.Success | Should -BeTrue
        $r.Generated | Should -BeTrue
        $r.Status | Should -Be 'Generated'
        (Get-Content -Path "$c3Key.pub" -Raw) | Should -Match 'AAAANEW'
        # The new key is created without a passphrase and checked afterwards.
        $global:C3KeygenCalls[0] | Should -Match '^-t ed25519 -C IMPACT_jdoe -f .+ -N\s+-q$'
        $global:C3KeygenCalls[1] | Should -Match '^-y -P\s+-f '
    }

    It 'Reports a failed key generation with the ssh-keygen output' {
        Mock Invoke-ImpactSshKeygen {
            [pscustomobject]@{ ExitCode = 1; Output = @('Saving key failed: Permission denied') }
        } -ModuleName 'IMPACT_Docker_GUI'
        $r = InModuleScope 'IMPACT_Docker_GUI' -Parameters @{ K = $c3Key } { param($K) Initialize-ImpactSshKeyPair -KeyPath $K -Comment 'IMPACT_jdoe' }
        $r.Success | Should -BeFalse
        $r.Status | Should -Be 'GenerateFailed'
        $r.Message | Should -Match 'Permission denied'
    }

    It 'Invoke-ImpactSshKeygen returns exit code -1 and a message when ssh-keygen cannot be run' {
        $r = InModuleScope 'IMPACT_Docker_GUI' {
            # An alias that points to a command that does not exist makes '& ssh-keygen' fail
            # the same way as a missing ssh-keygen, also on machines that have one.
            Set-Alias -Name ssh-keygen -Value 'impact-c3-no-such-command' -Scope Script
            try { Invoke-ImpactSshKeygen -Arguments @('-y', '-P', '', '-f', 'nothing') }
            finally { Remove-Item -Path Alias:\ssh-keygen -ErrorAction SilentlyContinue }
        }
        $r.ExitCode | Should -Be -1
        @($r.Output).Count | Should -BeGreaterThan 0
    }
}

# ═══════════════════════════════════════════════════════════════════════════════
#  C3: GitHub SSH key check (F68)
# ═══════════════════════════════════════════════════════════════════════════════
Describe 'Get-GitHubSshAuthStatus' -Tag Unit {
    It 'Treats exit code 1 with "successfully authenticated" as OK and reads the account' {
        $r = InModuleScope 'IMPACT_Docker_GUI' { Get-GitHubSshAuthStatus -Output @("Hi jdoe! You've successfully authenticated, but GitHub does not provide shell access.") -ExitCode 1 }
        $r.Status | Should -Be 'Authenticated'
        $r.Account | Should -Be 'jdoe'
    }

    It 'Does not treat the success text as OK when ssh failed (exit 255)' {
        $r = InModuleScope 'IMPACT_Docker_GUI' { Get-GitHubSshAuthStatus -Output @('successfully authenticated') -ExitCode 255 }
        $r.Status | Should -Not -Be 'Authenticated'
    }

    It 'Recognises a key that is not registered' {
        $r = InModuleScope 'IMPACT_Docker_GUI' { Get-GitHubSshAuthStatus -Output @('git@github.com: Permission denied (publickey).') -ExitCode 255 }
        $r.Status | Should -Be 'NotRegistered'
    }

    It 'Recognises network problems' {
        InModuleScope 'IMPACT_Docker_GUI' {
            (Get-GitHubSshAuthStatus -Output @('ssh: connect to host github.com port 22: Connection timed out') -ExitCode 255).Status | Should -Be 'Unreachable'
            (Get-GitHubSshAuthStatus -Output @('ssh: Could not resolve hostname github.com: No such host is known.') -ExitCode 255).Status | Should -Be 'Unreachable'
        }
    }

    It 'Recognises a host key problem and falls back to Unknown otherwise' {
        InModuleScope 'IMPACT_Docker_GUI' {
            (Get-GitHubSshAuthStatus -Output @('Host key verification failed.') -ExitCode 255).Status | Should -Be 'HostKeyProblem'
            (Get-GitHubSshAuthStatus -Output @('/home/x/.ssh/config line 3: garbage at end of line') -ExitCode 255).Status | Should -Be 'Unknown'
        }
    }
}

Describe 'Test-GitHubSshKeyAuth and Confirm-GitHubKeyRegistered' -Tag Unit {
    BeforeAll {
        # Pester can only mock a command that exists; see the YAML tests above.
        $script:c3SshStubAdded = $false
        if (-not (Get-Command ssh -ErrorAction SilentlyContinue)) {
            function global:ssh { throw 'ssh stub: this call should have been mocked' }
            $script:c3SshStubAdded = $true
        }
    }

    AfterAll {
        if ($script:c3SshStubAdded) { Remove-Item -Path Function:\ssh -ErrorAction SilentlyContinue }
        Disable-NonInteractiveMode
    }

    AfterEach {
        Remove-Variable -Name C3AuthCalls -Scope Global -ErrorAction SilentlyContinue
    }

    It 'Offers only the IMPACT key, never asks, and does not hang (ssh options)' {
        Mock ssh {
            $global:LASTEXITCODE = 1
            "Hi jdoe! You've successfully authenticated, but GitHub does not provide shell access."
        } -ModuleName 'IMPACT_Docker_GUI'
        $r = InModuleScope 'IMPACT_Docker_GUI' { Test-GitHubSshKeyAuth -KeyPath 'C:/Users/Max Mustermann/.ssh/id_ed25519_jdoe' }
        $r.Status | Should -Be 'Authenticated'
        Should -Invoke ssh -ModuleName 'IMPACT_Docker_GUI' -Times 1 -ParameterFilter {
            $a = @($args)
            ($a -contains 'git@github.com') -and ($a -contains 'BatchMode=yes') -and ($a -contains 'IdentitiesOnly=yes') -and
            ($a -contains 'StrictHostKeyChecking=accept-new') -and ($a -contains 'ConnectTimeout=10') -and
            ($a -contains 'C:/Users/Max Mustermann/.ssh/id_ed25519_jdoe')
        }
    }

    It 'Skips the check in NonInteractive mode' {
        Enable-NonInteractiveMode
        try {
            Mock Test-GitHubSshKeyAuth { throw 'must not be called' } -ModuleName 'IMPACT_Docker_GUI'
            $r = InModuleScope 'IMPACT_Docker_GUI' { Confirm-GitHubKeyRegistered -State ([pscustomobject]@{ UserName = 'jdoe' }) -KeyPath 'k' -PublicKey 'ssh-ed25519 AAAA' }
            $r | Should -Be 'Skipped'
        } finally { Disable-NonInteractiveMode }
    }

    It 'Shows the key dialog when GitHub refuses the key, and checks again on Retry' {
        Disable-NonInteractiveMode
        $global:C3AuthCalls = 0
        Mock Test-GitHubSshKeyAuth {
            $global:C3AuthCalls++
            if ($global:C3AuthCalls -eq 1) { return [pscustomobject]@{ Status = 'NotRegistered'; Account = $null; Output = @('Permission denied (publickey).'); ExitCode = 255 } }
            [pscustomobject]@{ Status = 'Authenticated'; Account = 'jdoe'; Output = @('Hi jdoe!'); ExitCode = 1 }
        } -ModuleName 'IMPACT_Docker_GUI'
        Mock Show-GitHubKeyRegistrationDialog { 'retry' } -ModuleName 'IMPACT_Docker_GUI'
        $r = InModuleScope 'IMPACT_Docker_GUI' { Confirm-GitHubKeyRegistered -State ([pscustomobject]@{ UserName = 'jdoe' }) -KeyPath 'k' -PublicKey 'ssh-ed25519 AAAA' }
        $r | Should -Be 'Authenticated'
        Should -Invoke Show-GitHubKeyRegistrationDialog -ModuleName 'IMPACT_Docker_GUI' -Times 1 -Exactly
        $global:C3AuthCalls | Should -Be 2
    }

    It 'Continues without nagging when GitHub cannot be reached' {
        Disable-NonInteractiveMode
        Mock Test-GitHubSshKeyAuth { [pscustomobject]@{ Status = 'Unreachable'; Account = $null; Output = @('Connection timed out'); ExitCode = 255 } } -ModuleName 'IMPACT_Docker_GUI'
        Mock Show-GitHubKeyRegistrationDialog { 'retry' } -ModuleName 'IMPACT_Docker_GUI'
        $r = InModuleScope 'IMPACT_Docker_GUI' { Confirm-GitHubKeyRegistered -State ([pscustomobject]@{ UserName = 'jdoe' }) -KeyPath 'k' -PublicKey 'ssh-ed25519 AAAA' }
        $r | Should -Be 'Unreachable'
        Should -Invoke Show-GitHubKeyRegistrationDialog -ModuleName 'IMPACT_Docker_GUI' -Times 0 -Exactly
    }

    It 'Returns NotRegistered when the user chooses Continue' {
        Disable-NonInteractiveMode
        Mock Test-GitHubSshKeyAuth { [pscustomobject]@{ Status = 'NotRegistered'; Account = $null; Output = @('Permission denied (publickey).'); ExitCode = 255 } } -ModuleName 'IMPACT_Docker_GUI'
        Mock Show-GitHubKeyRegistrationDialog { 'continue' } -ModuleName 'IMPACT_Docker_GUI'
        $r = InModuleScope 'IMPACT_Docker_GUI' { Confirm-GitHubKeyRegistered -State ([pscustomobject]@{ UserName = 'jdoe' }) -KeyPath 'k' -PublicKey 'ssh-ed25519 AAAA' }
        $r | Should -Be 'NotRegistered'
    }
}

# ═══════════════════════════════════════════════════════════════════════════════
#  C3: workstation IP check (F23) and .env pre-fill (F100)
# ═══════════════════════════════════════════════════════════════════════════════
Describe 'Test-WorkstationIpAddress and Get-DotEnvValue' -Tag Unit {
    It 'Accepts normal IPv4 addresses' {
        InModuleScope 'IMPACT_Docker_GUI' {
            Test-WorkstationIpAddress -Address '192.168.1.100' | Should -BeTrue
            Test-WorkstationIpAddress -Address '10.152.14.124' | Should -BeTrue
            Test-WorkstationIpAddress -Address '0.0.0.0' | Should -BeTrue
            Test-WorkstationIpAddress -Address '255.255.255.255' | Should -BeTrue
        }
    }

    It 'Rejects numbers above 255, short forms, leading zeros and other text' {
        InModuleScope 'IMPACT_Docker_GUI' {
            foreach ($bad in @('999.1.2.3', '1.2.3.256', '10.1', '010.0.0.1', '1.2.3', '1.2.3.4.5', 'a.b.c.d', '', ' ', '10.0.0.5 # lab')) {
                Test-WorkstationIpAddress -Address $bad | Should -BeFalse -Because "'$bad' is not a valid address"
            }
        }
    }

    It 'Reads WORKSTATION_IP and removes a comment after it' {
        InModuleScope 'IMPACT_Docker_GUI' {
            Get-DotEnvValue -Lines @('# settings', 'WORKSTATION_IP=10.0.0.5   # lab PC') -Name 'WORKSTATION_IP' | Should -Be '10.0.0.5'
            Get-DotEnvValue -Lines @('export WORKSTATION_IP="10.0.0.6" # quoted') -Name 'WORKSTATION_IP' | Should -Be '10.0.0.6'
            Get-DotEnvValue -Lines @("WORKSTATION_IP = '10.0.0.7'") -Name 'WORKSTATION_IP' | Should -Be '10.0.0.7'
            Get-DotEnvValue -Lines 'WORKSTATION_IP=10.0.0.8' -Name 'WORKSTATION_IP' | Should -Be '10.0.0.8'
        }
    }

    It 'Returns null when the name is not in the file' {
        InModuleScope 'IMPACT_Docker_GUI' {
            Get-DotEnvValue -Lines @('OTHER=1') -Name 'WORKSTATION_IP' | Should -BeNullOrEmpty
        }
    }
}

# ═══════════════════════════════════════════════════════════════════════════════
#  C3: ssh-agent never elevates (F66), GitHub answer must be an account (B6a-R6),
#  deliberate PowerShell-version stops are marked as already explained (B6a-R2)
# ═══════════════════════════════════════════════════════════════════════════════
Describe 'C3 module startup and GitHub checks' -Tag Unit {
    It 'Ensure-SshAgentRunning never asks for administrator rights' {
        $modulePath = Join-Path $PSScriptRoot '..' 'current_version' 'IMPACT_Docker_GUI.psm1'
        $ast = [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path $modulePath), [ref]$null, [ref]$null)
        $fn = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Ensure-SshAgentRunning' }, $true) | Select-Object -First 1
        $fn | Should -Not -BeNullOrEmpty
        $fn.Extent.Text | Should -Not -Match 'RunAs'
    }

    It 'Ensure-SshAgentRunning returns nothing and does not throw' {
        $out = @(Ensure-SshAgentRunning -SshKeyPath (Join-Path ([System.IO.Path]::GetTempPath()) 'impact_c3_no_key'))
        $out.Count | Should -Be 0
    }

    It 'Test-GitHubUsername does not accept an HTML page (proxy or login page) as an existing user' {
        Mock Invoke-RestMethod { '<html><body>Please log in to the network</body></html>' } -ModuleName 'IMPACT_Docker_GUI'
        $r = Test-GitHubUsername -UserName 'typo-user' -Detailed
        $r.Status | Should -Be 'Unknown'
        $r.Message | Should -Match 'unexpected answer'
        Test-GitHubUsername -UserName 'typo-user' | Should -BeFalse
    }

    It 'Marks the PowerShell-version errors that the user has already seen' {
        InModuleScope 'IMPACT_Docker_GUI' {
            $e = New-ImpactNotifiedException -Message 'PowerShell 7.3 or newer is required (found 7.2.0).' -UserNotified $true
            $e.Message | Should -Be 'PowerShell 7.3 or newer is required (found 7.2.0).'
            $e.Data['ImpactUserNotified'] | Should -BeTrue
            (New-ImpactNotifiedException -Message 'x' -UserNotified $false).Data.Contains('ImpactUserNotified') | Should -BeFalse
        }
    }
}

# ═══════════════════════════════════════════════════════════════════════════════
#  C3 review R1: unquoted IdentityFile paths with a space are repaired in EVERY section
#  of the ssh config, not only in the section of the IP being connected to. All tests
#  use a temporary config file, never the developer's real ~/.ssh/config.
# ═══════════════════════════════════════════════════════════════════════════════
Describe 'Repair-SshConfigIdentityFileQuoting (all sections of the ssh config)' -Tag Unit {
    BeforeEach {
        $c3rDir = Join-Path ([System.IO.Path]::GetTempPath()) "impact_c3r_cfg_$([guid]::NewGuid().ToString('N').Substring(0,8))"
        $c3rKeyDir = Join-Path $c3rDir 'Max Mustermann'
        New-Item -ItemType Directory -Path $c3rKeyDir -Force | Out-Null
        $c3rKey = Join-Path $c3rKeyDir 'id_ed25519_max'
        Set-Content -Path $c3rKey -Value 'dummy-key-content'
        $c3rKeyNorm = $c3rKey -replace '\\', '/'
        $c3rConfig = Join-Path $c3rDir 'config'
    }

    AfterEach {
        Remove-Item -Recurse -Force -Path $c3rDir -ErrorAction SilentlyContinue
    }

    It 'Repairs the broken IMPACT entry of ANOTHER workstation IP when connecting to a new one' {
        # Two IMPACT entries: an old, broken one for 10.0.0.5 (unquoted path with a space,
        # as older versions wrote it) and a correct one for 10.0.0.9, which is the one
        # being connected to now.
        Set-Content -Path $c3rConfig -Value @(
            '# IMPACT Docker GUI - auto-generated entry for remote workstation'
            'Host 10.0.0.5'
            '    User php-workstation'
            "    IdentityFile $c3rKeyNorm"
            '    IdentitiesOnly yes'
            ''
            '# IMPACT Docker GUI - auto-generated entry for remote workstation'
            'Host 10.0.0.9'
            '    User php-workstation'
            "    IdentityFile `"$c3rKeyNorm`""
            '    IdentitiesOnly yes'
        )
        Ensure-SshConfigEntry -RemoteHostIp '10.0.0.9' -RemoteUser 'php-workstation' -IdentityFile $c3rKey -ConfigPath $c3rConfig
        $lines = @(Get-Content -Path $c3rConfig)
        $lines | Should -Not -Contain "    IdentityFile $c3rKeyNorm"
        @($lines | Where-Object { $_ -eq "    IdentityFile `"$c3rKeyNorm`"" }).Count | Should -Be 2
        @($lines | Where-Object { $_ -match '^Host 10\.0\.0\.5$' }).Count | Should -Be 1
        @($lines | Where-Object { $_ -match '^Host 10\.0\.0\.9$' }).Count | Should -Be 1
        # Only IMPACT's own lines were changed, so no backup copy is needed.
        @(Get-ChildItem -Path $c3rDir -Filter 'config.impact-backup-*').Count | Should -Be 0
    }

    It 'Saves a copy of the file before quoting a line in a section the user wrote' {
        Set-Content -Path $c3rConfig -Value @(
            'Host myserver'
            '    HostName myserver.example.org'
            "    IdentityFile=$c3rKeyNorm"
        )
        $count = InModuleScope 'IMPACT_Docker_GUI' -Parameters @{ C = $c3rConfig } { param($C) Repair-SshConfigIdentityFileQuoting -ConfigPath $C }
        $count | Should -Be 1
        (Get-Content -Path $c3rConfig) | Should -Contain "    IdentityFile=`"$c3rKeyNorm`""
        $backups = @(Get-ChildItem -Path $c3rDir -Filter 'config.impact-backup-*')
        $backups.Count | Should -Be 1
        (Get-Content -LiteralPath $backups[0].FullName) | Should -Contain "    IdentityFile=$c3rKeyNorm"
    }

    It 'Repairs only IMPACT lines when no copy of the file can be made' {
        Set-Content -Path $c3rConfig -Value @(
            'Host myserver'
            "    IdentityFile $c3rKeyNorm"
            ''
            '# IMPACT Docker GUI - auto-generated entry for remote workstation'
            'Host 10.0.0.5'
            "    IdentityFile $c3rKeyNorm"
        )
        Mock Backup-SshConfigFile { $null } -ModuleName 'IMPACT_Docker_GUI'
        $count = InModuleScope 'IMPACT_Docker_GUI' -Parameters @{ C = $c3rConfig } { param($C) Repair-SshConfigIdentityFileQuoting -ConfigPath $C }
        $count | Should -Be 1
        $lines = @(Get-Content -Path $c3rConfig)
        $lines[1] | Should -Be "    IdentityFile $c3rKeyNorm"
        $lines[5] | Should -Be "    IdentityFile `"$c3rKeyNorm`""
    }

    It 'Leaves quoted values, comments and escaped spaces alone' {
        $original = @(
            'Host a'
            "    IdentityFile `"$c3rKeyNorm`""
            'Host b'
            '    IdentityFile ~/.ssh/id_b # my comment'
            'Host c'
            '    IdentityFile C:/Users/Max\ Mustermann/.ssh/id_c'
            'Host d'
            '    IdentityFile ~/.ssh/id_d'
        )
        Set-Content -Path $c3rConfig -Value $original
        $count = InModuleScope 'IMPACT_Docker_GUI' -Parameters @{ C = $c3rConfig } { param($C) Repair-SshConfigIdentityFileQuoting -ConfigPath $C }
        $count | Should -Be 0
        (Get-Content -Path $c3rConfig) | Should -Be $original
        @(Get-ChildItem -Path $c3rDir -Filter 'config.impact-backup-*').Count | Should -Be 0
    }

    It 'Returns 0 for a missing config file' {
        InModuleScope 'IMPACT_Docker_GUI' -Parameters @{ C = (Join-Path $c3rDir 'no-such-config') } { param($C) Repair-SshConfigIdentityFileQuoting -ConfigPath $C } | Should -Be 0
    }

    It 'Backup-SshConfigFile never overwrites an earlier copy made in the same second' {
        Set-Content -Path $c3rConfig -Value 'Host x'
        $first, $second = InModuleScope 'IMPACT_Docker_GUI' -Parameters @{ C = $c3rConfig } {
            param($C)
            Backup-SshConfigFile -ConfigPath $C
            Backup-SshConfigFile -ConfigPath $C
        }
        $first | Should -Not -BeNullOrEmpty
        $second | Should -Not -BeNullOrEmpty
        $second | Should -Not -Be $first
        @(Get-ChildItem -Path $c3rDir -Filter 'config.impact-backup-*').Count | Should -Be 2
    }

    It 'Ensure-GitKeySetup calls the repair before every GitHub check (source check, runs everywhere)' {
        $modulePath = Join-Path $PSScriptRoot '..' 'current_version' 'IMPACT_Docker_GUI.psm1'
        $ast = [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path $modulePath), [ref]$null, [ref]$null)
        $fn = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Ensure-GitKeySetup' }, $true) | Select-Object -First 1
        $calls = @($fn.Body.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true))
        $repair = @($calls | Where-Object { $_.GetCommandName() -eq 'Repair-SshConfigIdentityFileQuoting' })
        $github = @($calls | Where-Object { $_.GetCommandName() -eq 'Confirm-GitHubKeyRegistered' })
        $repair.Count | Should -Be 1
        $github.Count | Should -BeGreaterThan 0
        foreach ($g in $github) { $g.Extent.StartOffset | Should -BeGreaterThan $repair[0].Extent.StartOffset }
    }

    It 'Ensure-GitKeySetup runs the repair before the GitHub check (so LOCAL mode gets it too)' {
        # Ensure-GitKeySetup contains WinForms code. Where System.Drawing is missing (Linux),
        # PowerShell cannot even start the function, so this behaviour test runs on Windows only.
        if (-not $IsWindows) { Set-ItResult -Skipped -Because 'Ensure-GitKeySetup needs WinForms / System.Drawing (Windows only)'; return }
        $global:C3rOrder = [System.Collections.Generic.List[string]]::new()
        $c3rUser = "c3rtest$([guid]::NewGuid().ToString('N').Substring(0,6))"
        Mock Initialize-ImpactSshKeyPair { [pscustomobject]@{ Success = $true; Generated = $false; Status = 'Ready'; Message = ''; Details = '' } } -ModuleName 'IMPACT_Docker_GUI'
        # Only the test user's public key file is faked; any other Get-Content call goes to
        # the default mock and reads the real file (see Invoke-RealCommand).
        Mock Get-Content { Invoke-RealCommand -Name 'Get-Content' -Parameters $PesterBoundParameters } -ModuleName 'IMPACT_Docker_GUI'
        Mock Get-Content { 'ssh-ed25519 AAAAC3NzaTEST IMPACT_c3r' } -ModuleName 'IMPACT_Docker_GUI' -ParameterFilter { "$LiteralPath$Path" -like '*id_ed25519_c3rtest*.pub' }
        Mock Repair-SshConfigIdentityFileQuoting { $global:C3rOrder.Add('repair'); 0 } -ModuleName 'IMPACT_Docker_GUI'
        Mock Ensure-SshAgentRunning { } -ModuleName 'IMPACT_Docker_GUI'
        Mock Confirm-GitHubKeyRegistered { $global:C3rOrder.Add('github'); 'Authenticated' } -ModuleName 'IMPACT_Docker_GUI'
        try {
            $state = New-SessionState
            $state.UserName = $c3rUser
            $state.ContainerLocation = 'LOCAL'
            Ensure-GitKeySetup -State $state | Should -BeTrue
            Should -Invoke Repair-SshConfigIdentityFileQuoting -ModuleName 'IMPACT_Docker_GUI' -Times 1 -Exactly
            ($global:C3rOrder -join ',') | Should -Be 'repair,github'
        } finally { Remove-Variable -Name C3rOrder -Scope Global -ErrorAction SilentlyContinue }
    }
}

# ═══════════════════════════════════════════════════════════════════════════════
#  C3 review R2 + R3: a key file ssh cannot use is not reported as "not on GitHub", and
#  the GitHub key check runs once per key and session (Back must not repeat it).
# ═══════════════════════════════════════════════════════════════════════════════
Describe 'GitHub SSH key check: unusable key file and session memory' -Tag Unit {
    BeforeAll {
        $script:c3rBadPerms = @(
            '@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@'
            '@         WARNING: UNPROTECTED PRIVATE KEY FILE!          @'
            '@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@'
            "Permissions for 'C:\\Users\\Max Mustermann\\.ssh\\id_ed25519_jdoe' are too open."
            'It is required that your private key files are NOT accessible by others.'
            'This private key will be ignored.'
            'Load key "C:\\Users\\Max Mustermann\\.ssh\\id_ed25519_jdoe": bad permissions'
            'git@github.com: Permission denied (publickey).'
        )
    }

    AfterEach {
        Remove-Variable -Name C3rAuthCalls -Scope Global -ErrorAction SilentlyContinue
        Disable-NonInteractiveMode
    }

    It 'Reports KeyUnusable (not NotRegistered) when ssh cannot load the IMPACT key file' {
        InModuleScope 'IMPACT_Docker_GUI' -Parameters @{ O = $script:c3rBadPerms } {
            param($O)
            (Get-GitHubSshAuthStatus -Output $O -ExitCode 255 -KeyPath 'C:/Users/Max Mustermann/.ssh/id_ed25519_jdoe').Status | Should -Be 'KeyUnusable'
            (Get-GitHubSshAuthStatus -Output $O -ExitCode 255).Status | Should -Be 'KeyUnusable'
            (Get-GitHubSshAuthStatus -Output @('Load key "/home/x/.ssh/id_ed25519_jdoe": invalid format', 'git@github.com: Permission denied (publickey).') -ExitCode 255 -KeyPath '/home/x/.ssh/id_ed25519_jdoe').Status | Should -Be 'KeyUnusable'
        }
    }

    It 'Still reports NotRegistered when ssh only complains about ANOTHER key from the user''s config' {
        InModuleScope 'IMPACT_Docker_GUI' {
            $o = @('Load key "C:\\Users\\x\\.ssh\\id_rsa_old": bad permissions', 'git@github.com: Permission denied (publickey).')
            (Get-GitHubSshAuthStatus -Output $o -ExitCode 255 -KeyPath 'C:/Users/x/.ssh/id_ed25519_jdoe').Status | Should -Be 'NotRegistered'
        }
    }

    It 'Does not show the registration dialog for an unusable key file' {
        Mock Test-GitHubSshKeyAuth { [pscustomobject]@{ Status = 'KeyUnusable'; Account = $null; Output = @('Load key "k": bad permissions'); ExitCode = 255 } } -ModuleName 'IMPACT_Docker_GUI'
        Mock Show-GitHubKeyRegistrationDialog { 'retry' } -ModuleName 'IMPACT_Docker_GUI'
        $r = InModuleScope 'IMPACT_Docker_GUI' { Confirm-GitHubKeyRegistered -State ([pscustomobject]@{ UserName = 'jdoe' }) -KeyPath 'C:/Users/x/.ssh/id_ed25519_jdoe' -PublicKey 'ssh-ed25519 AAAA' }
        $r | Should -Be 'KeyUnusable'
        Should -Invoke Show-GitHubKeyRegistrationDialog -ModuleName 'IMPACT_Docker_GUI' -Times 0 -Exactly
    }

    It 'Does not ask again after Continue anyway when the key setup runs again (Back)' {
        $global:C3rAuthCalls = 0
        Mock Test-GitHubSshKeyAuth { $global:C3rAuthCalls++; [pscustomobject]@{ Status = 'NotRegistered'; Account = $null; Output = @('Permission denied (publickey).'); ExitCode = 255 } } -ModuleName 'IMPACT_Docker_GUI'
        Mock Show-GitHubKeyRegistrationDialog { 'continue' } -ModuleName 'IMPACT_Docker_GUI'
        $state = [pscustomobject]@{ UserName = 'jdoe'; Metadata = @{} }
        $first = InModuleScope 'IMPACT_Docker_GUI' -Parameters @{ S = $state } { param($S) Confirm-GitHubKeyRegistered -State $S -KeyPath 'k1' -PublicKey 'ssh-ed25519 AAAA' }
        $second = InModuleScope 'IMPACT_Docker_GUI' -Parameters @{ S = $state } { param($S) Confirm-GitHubKeyRegistered -State $S -KeyPath 'k1' -PublicKey 'ssh-ed25519 AAAA' }
        $first | Should -Be 'NotRegistered'
        $second | Should -Be 'NotRegistered'
        $global:C3rAuthCalls | Should -Be 1
        Should -Invoke Show-GitHubKeyRegistrationDialog -ModuleName 'IMPACT_Docker_GUI' -Times 1 -Exactly
    }

    It 'Remembers a successful check, but checks a different key (another user name) again' {
        $global:C3rAuthCalls = 0
        Mock Test-GitHubSshKeyAuth { $global:C3rAuthCalls++; [pscustomobject]@{ Status = 'Authenticated'; Account = 'jdoe'; Output = @('Hi jdoe!'); ExitCode = 1 } } -ModuleName 'IMPACT_Docker_GUI'
        $state = [pscustomobject]@{ UserName = 'jdoe'; Metadata = @{} }
        InModuleScope 'IMPACT_Docker_GUI' -Parameters @{ S = $state } {
            param($S)
            Confirm-GitHubKeyRegistered -State $S -KeyPath 'k1' -PublicKey 'x' | Should -Be 'Authenticated'
            Confirm-GitHubKeyRegistered -State $S -KeyPath 'k1' -PublicKey 'x' | Should -Be 'Authenticated'
            Confirm-GitHubKeyRegistered -State $S -KeyPath 'k2' -PublicKey 'x' | Should -Be 'Authenticated'
        }
        $global:C3rAuthCalls | Should -Be 2
        $state.Metadata['GitHubKeyCheck']['KeyPath'] | Should -Be 'k2'
    }
}

# ═══════════════════════════════════════════════════════════════════════════════
#  C3 review R5: the ssh-agent check compares fingerprints, because 'ssh-add -l' shows
#  the key's comment (IMPACT_<user>), not its file path.
# ═══════════════════════════════════════════════════════════════════════════════
Describe 'Ensure-SshAgentRunning finds an already loaded key by its fingerprint' -Tag Unit {
    BeforeAll {
        # Get-Service, Start-Service and ssh-add do not exist on Linux, and Pester can only
        # mock commands that exist, so add small stand-ins where they are missing.
        $script:c3rStubs = @()
        if (-not (Get-Command Get-Service -ErrorAction SilentlyContinue)) {
            function global:Get-Service { [CmdletBinding()] param([Parameter(Position = 0)][string[]]$Name) }
            $script:c3rStubs += 'Get-Service'
        }
        if (-not (Get-Command Start-Service -ErrorAction SilentlyContinue)) {
            function global:Start-Service { [CmdletBinding()] param([Parameter(Position = 0)][string[]]$Name) }
            $script:c3rStubs += 'Start-Service'
        }
        if (-not (Get-Command ssh-add -ErrorAction SilentlyContinue)) {
            function global:ssh-add { throw 'ssh-add stub: this call should have been mocked' }
            $script:c3rStubs += 'ssh-add'
        }
        $script:c3rKey = Join-Path ([System.IO.Path]::GetTempPath()) 'impact_c3r_agent_no_such_key'
    }

    AfterAll {
        foreach ($s in $script:c3rStubs) { Remove-Item -Path "Function:\$s" -ErrorAction SilentlyContinue }
    }

    AfterEach {
        Remove-Variable -Name C3rAgentList, C3rAdds -Scope Global -ErrorAction SilentlyContinue
    }

    It 'Test-SshAgentHasKey matches the fingerprint, not the comment' {
        InModuleScope 'IMPACT_Docker_GUI' {
            $list = @('256 SHA256:abcDEF123+/xyz IMPACT_jdoe (ED25519)', '3072 SHA256:other0000 me@laptop (RSA)')
            Test-SshAgentHasKey -AgentList $list -Fingerprint 'SHA256:abcDEF123+/xyz' -KeyPath 'C:/Users/x/.ssh/id_ed25519_jdoe' | Should -BeTrue
            Test-SshAgentHasKey -AgentList $list -Fingerprint 'SHA256:notloaded' -KeyPath 'C:/Users/x/.ssh/id_ed25519_jdoe' | Should -BeFalse
            # Without a fingerprint the old path test still works for keys listed by path.
            Test-SshAgentHasKey -AgentList @('256 SHA256:zzz C:/Users/x/.ssh/id_ed25519_jdoe (ED25519)') -Fingerprint $null -KeyPath 'C:/Users/x/.ssh/id_ed25519_jdoe' | Should -BeTrue
            Test-SshAgentHasKey -AgentList @('The agent has no identities.') -Fingerprint 'SHA256:abc' -KeyPath 'k' | Should -BeFalse
            Test-SshAgentHasKey -AgentList @() -Fingerprint 'SHA256:abc' -KeyPath 'k' | Should -BeFalse
        }
    }

    It 'Does not add the key again when the agent already holds it' {
        $global:C3rAgentList = @('256 SHA256:abcDEF123+/xyz IMPACT_jdoe (ED25519)')
        $global:C3rAdds = 0
        Mock Get-Service { [pscustomobject]@{ Status = 'Running' } } -ModuleName 'IMPACT_Docker_GUI'
        Mock Invoke-ImpactSshKeygen { [pscustomobject]@{ ExitCode = 0; Output = @('256 SHA256:abcDEF123+/xyz IMPACT_jdoe (ED25519)') } } -ModuleName 'IMPACT_Docker_GUI'
        Mock ssh-add {
            $global:LASTEXITCODE = 0
            if (@($args) -contains '-l') { return $global:C3rAgentList }
            $global:C3rAdds++
            'Identity added'
        } -ModuleName 'IMPACT_Docker_GUI'
        Ensure-SshAgentRunning -SshKeyPath $script:c3rKey
        $global:C3rAdds | Should -Be 0
    }

    It 'Adds the key when the agent holds only other keys' {
        $global:C3rAgentList = @('3072 SHA256:other0000 me@laptop (RSA)')
        $global:C3rAdds = 0
        Mock Get-Service { [pscustomobject]@{ Status = 'Running' } } -ModuleName 'IMPACT_Docker_GUI'
        Mock Invoke-ImpactSshKeygen { [pscustomobject]@{ ExitCode = 0; Output = @('256 SHA256:abcDEF123+/xyz IMPACT_jdoe (ED25519)') } } -ModuleName 'IMPACT_Docker_GUI'
        Mock ssh-add {
            $global:LASTEXITCODE = 0
            if (@($args) -contains '-l') { return $global:C3rAgentList }
            $global:C3rAdds++
            'Identity added'
        } -ModuleName 'IMPACT_Docker_GUI'
        Ensure-SshAgentRunning -SshKeyPath $script:c3rKey
        $global:C3rAdds | Should -Be 1
    }
}

# ═══════════════════════════════════════════════════════════════════════════════
#  C3 review R4: when no copy of the ssh config can be made, the user's own Host block
#  is kept and the user is told that remote Docker may fail (Docker over ssh gets the
#  IMPACT key only from this entry). The copy first tries a second folder.
# ═══════════════════════════════════════════════════════════════════════════════
Describe 'Ensure-SshConfigEntry when the ssh config cannot be backed up' -Tag Unit {
    BeforeEach {
        $c3rDir = Join-Path ([System.IO.Path]::GetTempPath()) "impact_c3r_bak_$([guid]::NewGuid().ToString('N').Substring(0,8))"
        New-Item -ItemType Directory -Path $c3rDir -Force | Out-Null
        $c3rKey = Join-Path $c3rDir 'id_ed25519_max'
        Set-Content -Path $c3rKey -Value 'dummy-key-content'
        $c3rConfig = Join-Path $c3rDir 'config'
    }

    AfterEach {
        Remove-Item -Recurse -Force -Path $c3rDir -ErrorAction SilentlyContinue
        Remove-Variable -Name C3rCopyTargets -Scope Global -ErrorAction SilentlyContinue
    }

    It 'Keeps the user''s Host block and logs an error that explains the manual fix' {
        $original = @(
            'Host 198.51.100.77'
            '    User php-workstation'
            '    ProxyJump jumphost.example.org'
            '    IdentityFile /does/not/exist/id_other'
        )
        Set-Content -Path $c3rConfig -Value $original
        Mock Backup-SshConfigFile { $null } -ModuleName 'IMPACT_Docker_GUI'
        Mock Write-Log { } -ModuleName 'IMPACT_Docker_GUI'
        $out = @(Ensure-SshConfigEntry -RemoteHostIp '198.51.100.77' -RemoteUser 'php-workstation' -IdentityFile $c3rKey -ConfigPath $c3rConfig)
        $out.Count | Should -Be 0
        (Get-Content -Path $c3rConfig) | Should -Be $original
        Should -Invoke Write-Log -ModuleName 'IMPACT_Docker_GUI' -Times 1 -ParameterFilter { $Level -eq 'Error' -and $Message -match 'Remote Docker may fail' -and $Message -match 'IdentitiesOnly yes' }
    }

    It 'Backup-SshConfigFile tries ~/.impact_gui/ssh-config-backups when the .ssh folder refuses the copy' {
        Set-Content -Path $c3rConfig -Value 'Host x'
        $global:C3rCopyTargets = [System.Collections.Generic.List[string]]::new()
        # The second folder is in the real home folder, so creating it and copying there are
        # only recorded, never done. Any other New-Item call goes to the default mock and
        # runs normally (see Invoke-RealCommand). The two Copy-Item filters together accept
        # every possible call, so Copy-Item needs no default mock.
        Mock New-Item { Invoke-RealCommand -Name 'New-Item' -Parameters $PesterBoundParameters } -ModuleName 'IMPACT_Docker_GUI'
        Mock New-Item { } -ModuleName 'IMPACT_Docker_GUI' -ParameterFilter { "$Path" -like '*ssh-config-backups*' }
        Mock Copy-Item { $global:C3rCopyTargets.Add("$Destination"); throw 'Access to the path is denied.' } -ModuleName 'IMPACT_Docker_GUI' -ParameterFilter { "$Destination" -notlike '*ssh-config-backups*' }
        Mock Copy-Item { $global:C3rCopyTargets.Add("$Destination") } -ModuleName 'IMPACT_Docker_GUI' -ParameterFilter { "$Destination" -like '*ssh-config-backups*' }
        $r = InModuleScope 'IMPACT_Docker_GUI' -Parameters @{ C = $c3rConfig } { param($C) Backup-SshConfigFile -ConfigPath $C }
        $global:C3rCopyTargets.Count | Should -Be 2
        $global:C3rCopyTargets[0] | Should -BeLike "$c3rDir*config.impact-backup-*"
        $r | Should -Be $global:C3rCopyTargets[1]
        $r | Should -BeLike '*.impact_gui*ssh-config-backups*config.impact-backup-*'
    }
}

# ═══════════════════════════════════════════════════════════════════════════════
#  Get-DockerfileBaseImage: the prerequisite fallback build must be tagged with
#  the name in the main Dockerfile's FROM line, or the second main build would not
#  use the image that was just built.
# ═══════════════════════════════════════════════════════════════════════════════
Describe 'Get-DockerfileBaseImage' -Tag Unit {
    It 'Returns the image of a plain FROM line' {
        Get-DockerfileBaseImage -Content @('FROM kalleef/prerequisite.impactncdger:latest', 'RUN echo hi') |
            Should -BeExactly 'kalleef/prerequisite.impactncdger:latest'
    }

    It 'Skips comments, a syntax directive, blank lines and ARG lines before FROM' {
        $text = "# syntax=docker/dockerfile:1`r`n`r`n# base image`r`nARG R_VERSION=4.4`r`nFROM rocker/rstudio:4.4.1`r`nRUN true"
        Get-DockerfileBaseImage -Content $text | Should -BeExactly 'rocker/rstudio:4.4.1'
    }

    It 'Ignores options such as --platform and a stage name after AS' {
        Get-DockerfileBaseImage -Content @('from --platform=linux/amd64 kalleef/base:1.0 AS builder') |
            Should -BeExactly 'kalleef/base:1.0'
    }

    It 'Returns $null when the image name uses a build variable' {
        Get-DockerfileBaseImage -Content @('ARG BASE=x', 'FROM ${BASE}') | Should -BeNullOrEmpty
        Get-DockerfileBaseImage -Content @('FROM $BASE') | Should -BeNullOrEmpty
    }

    It 'Returns $null for scratch, an empty file and no input' {
        Get-DockerfileBaseImage -Content @('FROM scratch') | Should -BeNullOrEmpty
        Get-DockerfileBaseImage -Content @() | Should -BeNullOrEmpty
        Get-DockerfileBaseImage -Content $null | Should -BeNullOrEmpty
    }

    It 'Returns $null when the first instruction is not FROM' {
        Get-DockerfileBaseImage -Content @('RUN echo hi', 'FROM later/image:1') | Should -BeNullOrEmpty
    }
}

# ═══════════════════════════════════════════════════════════════════════════════
#  LOCAL start arguments: stored reference
#
#  WHAT THIS IS
#  When the user clicks Start, IMPACT runs 'docker run' with a long list of
#  arguments. Build-DockerRunCommand returns that list. The tests below call it with
#  fixed inputs and compare the COMPLETE list, argument by argument and in order,
#  with a list that is written out here ("stored reference").
#
#  WHY
#  These references pin the LOCAL behaviour of commit 4a8b260 (the state before the
#  redesign). If a later change alters one argument, changes the order, or adds or
#  drops an argument, a test here fails and names the position. The references may
#  only be changed deliberately: when a change of the LOCAL start command is really
#  wanted, and after the new list was read and checked by a person.
#
#  HOW THE LISTS WERE MADE
#  By running the unchanged function of commit 4a8b260 with these inputs, reading
#  the result, and pasting it here as fixed text. Nothing in an expected list is
#  computed by the test.
#
#  WINDOWS AND LINUX
#  All inputs are fixed texts, also the Windows paths such as 'C:\repos\...'. The
#  function only works on these texts (it never looks at the disk), so the result is
#  the same on Windows (where CI runs) and on Linux.
#
#  THE INPUTS LOOK LIKE THE REAL ONES
#  -ProjectRoot is the folder as the folder picker returns it (backslashes).
#  -OutputDir and -SynthpopDir look the way Get-YamlPathValue returns them on Windows
#  for the usual YAML lines 'output_dir: ./outputs' and 'synthpop_dir:
#  ./inputs/synthpop': forward slashes, and the './' is kept.
# ═══════════════════════════════════════════════════════════════════════════════
Describe 'LOCAL start arguments: stored reference' -Tag Unit {
    BeforeAll {
        # A session state with fixed values, filled in the same way the GUI fills it.
        # New-TestSessionState is not used here on purpose: it puts a temp folder of
        # this computer into the state, and these tests must not depend on the computer.
        function New-ReferenceState {
            param(
                [string]$Location = 'LOCAL',
                [string]$UserName = 'alice',
                [string]$Repo     = 'IMPACTncd_Germany'
            )
            $state = New-SessionState
            $state.UserName          = $UserName
            $state.Password          = 'Secret-pw1'
            $state.ContainerLocation = $Location
            $state.SelectedRepo      = $Repo
            # The GUI names the container "<repository>_<user>".
            $state.ContainerName     = "${Repo}_$UserName"
            return $state
        }

        # Compares the list the function returned with the stored reference, one
        # argument at a time and in order. 'Should -BeExactly' is used on purpose: it
        # also notices a difference between upper and lower case ('Should -Be' would
        # accept '/C/repos' where '/c/repos' is expected). When something differs, the
        # message names the position, so the changed argument is easy to find.
        function Assert-MatchesStoredReference {
            param(
                [object[]]$Actual,     # what Build-DockerRunCommand returned
                [string[]]$Expected    # the stored reference written out in the test
            )
            $shared = [Math]::Min($Actual.Count, $Expected.Count)
            for ($i = 0; $i -lt $shared; $i++) {
                $position = "argument number $($i + 1) of 'docker run'"
                # Every argument must be a text. A number or a nested list would be
                # handed to docker in another form.
                $Actual[$i] | Should -BeOfType ([string]) -Because "$position must be a text"
                $Actual[$i] | Should -BeExactly $Expected[$i] -Because "$position must stay exactly as in the stored reference"
            }
            # Checked last: when an argument was added or dropped in the middle, the loop
            # above has already named the first position that differs.
            $Actual.Count | Should -Be $Expected.Count -Because 'the list must have exactly as many arguments as the stored reference'
        }

        # The usual LOCAL inputs (user alice, repository in C:\repos).
        $script:refLocalInputs = @{
            ImageName   = 'impactncd_germany'
            ProjectRoot = 'C:\repos\IMPACTncd_Germany'
            OutputDir   = 'C:/repos/IMPACTncd_Germany/./outputs'
            SynthpopDir = 'C:/repos/IMPACTncd_Germany/./inputs/synthpop'
            SshKeyPath  = 'C:\Users\alice\.ssh\id_ed25519_alice'
        }
    }

    It 'a) bind mounts and the default port 8787' {
        $inputs = $script:refLocalInputs
        $expected = @(
            'run', '-d', '--rm',
            '--name', 'IMPACTncd_Germany_alice',
            '-e', 'PASSWORD=Secret-pw1',
            '-e', 'DISABLE_AUTH=false',
            '-e', 'USERID=1000',
            '-e', 'GROUPID=1000',
            '-e', 'CONTAINER_REPO_NAME=IMPACTncd_Germany',
            '-e', 'SYNC_ENABLED=false',
            '-e', 'GIT_SSH_COMMAND=ssh -i /home/rstudio/.ssh/id_ed25519_alice -o IdentitiesOnly=yes -o UserKnownHostsFile=/home/rstudio/.ssh/known_hosts -o StrictHostKeyChecking=accept-new',
            '--mount', 'type=bind,source=/c/repos/IMPACTncd_Germany,target=/home/rstudio/IMPACTncd_Germany',
            '-p', '127.0.0.1:8787:8787',
            '--mount', 'type=bind,source=/c/repos/IMPACTncd_Germany/./outputs,target=/home/rstudio/IMPACTncd_Germany/outputs',
            '--mount', 'type=bind,source=/c/repos/IMPACTncd_Germany/./inputs/synthpop,target=/home/rstudio/IMPACTncd_Germany/inputs/synthpop',
            '--label', 'impact.use_volumes=false',
            '--label', 'impact.repo_path=C:\repos\IMPACTncd_Germany',
            '--label', 'impact.output_dir=C:/repos/IMPACTncd_Germany/./outputs',
            '--label', 'impact.synthpop_dir=C:/repos/IMPACTncd_Germany/./inputs/synthpop',
            '--mount', 'type=bind,source=C:\Users\alice\.ssh\id_ed25519_alice,target=/keys/id_ed25519_alice,readonly',
            '--workdir', '/home/rstudio/IMPACTncd_Germany',
            'impactncd_germany'
        )

        # 1. No option given at all: the defaults of the function apply.
        $actual = Build-DockerRunCommand -State (New-ReferenceState) @inputs
        Assert-MatchesStoredReference -Actual $actual -Expected $expected

        # 2. The same default values, given explicitly, must give the same list.
        $actual = Build-DockerRunCommand -State (New-ReferenceState) -Port '8787' -UseVolumes $false -HighCompute $false `
            -CustomParams '' -ContainerUid '1000' -ContainerGid '1000' @inputs
        Assert-MatchesStoredReference -Actual $actual -Expected $expected
    }

    It 'b) another port (8790): only the -p argument changes' {
        $inputs = $script:refLocalInputs
        $expected = @(
            'run', '-d', '--rm',
            '--name', 'IMPACTncd_Germany_alice',
            '-e', 'PASSWORD=Secret-pw1',
            '-e', 'DISABLE_AUTH=false',
            '-e', 'USERID=1000',
            '-e', 'GROUPID=1000',
            '-e', 'CONTAINER_REPO_NAME=IMPACTncd_Germany',
            '-e', 'SYNC_ENABLED=false',
            '-e', 'GIT_SSH_COMMAND=ssh -i /home/rstudio/.ssh/id_ed25519_alice -o IdentitiesOnly=yes -o UserKnownHostsFile=/home/rstudio/.ssh/known_hosts -o StrictHostKeyChecking=accept-new',
            '--mount', 'type=bind,source=/c/repos/IMPACTncd_Germany,target=/home/rstudio/IMPACTncd_Germany',
            '-p', '127.0.0.1:8790:8787',
            '--mount', 'type=bind,source=/c/repos/IMPACTncd_Germany/./outputs,target=/home/rstudio/IMPACTncd_Germany/outputs',
            '--mount', 'type=bind,source=/c/repos/IMPACTncd_Germany/./inputs/synthpop,target=/home/rstudio/IMPACTncd_Germany/inputs/synthpop',
            '--label', 'impact.use_volumes=false',
            '--label', 'impact.repo_path=C:\repos\IMPACTncd_Germany',
            '--label', 'impact.output_dir=C:/repos/IMPACTncd_Germany/./outputs',
            '--label', 'impact.synthpop_dir=C:/repos/IMPACTncd_Germany/./inputs/synthpop',
            '--mount', 'type=bind,source=C:\Users\alice\.ssh\id_ed25519_alice,target=/keys/id_ed25519_alice,readonly',
            '--workdir', '/home/rstudio/IMPACTncd_Germany',
            'impactncd_germany'
        )

        $actual = Build-DockerRunCommand -State (New-ReferenceState) -Port '8790' @inputs
        Assert-MatchesStoredReference -Actual $actual -Expected $expected
    }

    It 'c) "Use Docker Volumes" ticked: two -v arguments and two more labels' {
        $inputs = $script:refLocalInputs
        $expected = @(
            'run', '-d', '--rm',
            '--name', 'IMPACTncd_Germany_alice',
            '-e', 'PASSWORD=Secret-pw1',
            '-e', 'DISABLE_AUTH=false',
            '-e', 'USERID=1000',
            '-e', 'GROUPID=1000',
            '-e', 'CONTAINER_REPO_NAME=IMPACTncd_Germany',
            '-e', 'SYNC_ENABLED=false',
            '-e', 'GIT_SSH_COMMAND=ssh -i /home/rstudio/.ssh/id_ed25519_alice -o IdentitiesOnly=yes -o UserKnownHostsFile=/home/rstudio/.ssh/known_hosts -o StrictHostKeyChecking=accept-new',
            '--mount', 'type=bind,source=/c/repos/IMPACTncd_Germany,target=/home/rstudio/IMPACTncd_Germany',
            '-p', '127.0.0.1:8787:8787',
            '-v', 'impactncd_output_IMPACTncd_Germany_alice:/home/rstudio/IMPACTncd_Germany/outputs',
            '-v', 'impactncd_synthpop_IMPACTncd_Germany_alice:/home/rstudio/IMPACTncd_Germany/inputs/synthpop',
            '--label', 'impact.use_volumes=true',
            '--label', 'impact.repo_path=C:\repos\IMPACTncd_Germany',
            '--label', 'impact.output_dir=C:/repos/IMPACTncd_Germany/./outputs',
            '--label', 'impact.synthpop_dir=C:/repos/IMPACTncd_Germany/./inputs/synthpop',
            '--label', 'impact.volume_output=impactncd_output_IMPACTncd_Germany_alice',
            '--label', 'impact.volume_synthpop=impactncd_synthpop_IMPACTncd_Germany_alice',
            '--mount', 'type=bind,source=C:\Users\alice\.ssh\id_ed25519_alice,target=/keys/id_ed25519_alice,readonly',
            '--workdir', '/home/rstudio/IMPACTncd_Germany',
            'impactncd_germany'
        )

        $actual = Build-DockerRunCommand -State (New-ReferenceState) -UseVolumes $true @inputs
        Assert-MatchesStoredReference -Actual $actual -Expected $expected
    }

    It 'd) "High compute" ticked: nothing changes in LOCAL mode (same list as a)' {
        # The limits '--cpus 32 -m 384g' are for the workstation only. In LOCAL mode
        # the tick box must have no effect at all.
        $inputs = $script:refLocalInputs
        $expected = @(
            'run', '-d', '--rm',
            '--name', 'IMPACTncd_Germany_alice',
            '-e', 'PASSWORD=Secret-pw1',
            '-e', 'DISABLE_AUTH=false',
            '-e', 'USERID=1000',
            '-e', 'GROUPID=1000',
            '-e', 'CONTAINER_REPO_NAME=IMPACTncd_Germany',
            '-e', 'SYNC_ENABLED=false',
            '-e', 'GIT_SSH_COMMAND=ssh -i /home/rstudio/.ssh/id_ed25519_alice -o IdentitiesOnly=yes -o UserKnownHostsFile=/home/rstudio/.ssh/known_hosts -o StrictHostKeyChecking=accept-new',
            '--mount', 'type=bind,source=/c/repos/IMPACTncd_Germany,target=/home/rstudio/IMPACTncd_Germany',
            '-p', '127.0.0.1:8787:8787',
            '--mount', 'type=bind,source=/c/repos/IMPACTncd_Germany/./outputs,target=/home/rstudio/IMPACTncd_Germany/outputs',
            '--mount', 'type=bind,source=/c/repos/IMPACTncd_Germany/./inputs/synthpop,target=/home/rstudio/IMPACTncd_Germany/inputs/synthpop',
            '--label', 'impact.use_volumes=false',
            '--label', 'impact.repo_path=C:\repos\IMPACTncd_Germany',
            '--label', 'impact.output_dir=C:/repos/IMPACTncd_Germany/./outputs',
            '--label', 'impact.synthpop_dir=C:/repos/IMPACTncd_Germany/./inputs/synthpop',
            '--mount', 'type=bind,source=C:\Users\alice\.ssh\id_ed25519_alice,target=/keys/id_ed25519_alice,readonly',
            '--workdir', '/home/rstudio/IMPACTncd_Germany',
            'impactncd_germany'
        )

        $actual = Build-DockerRunCommand -State (New-ReferenceState) -HighCompute $true @inputs
        Assert-MatchesStoredReference -Actual $actual -Expected $expected
    }

    It 'e) custom params: a quoted value with a space stays ONE argument, right after -p' {
        # Text as typed into the 'Custom Params' box:
        #   --shm-size 2g -e "R_NOTE=two words" --label 'team=public health'
        # The quotes are removed, and each quoted value stays one argument.
        $customParams = '--shm-size 2g -e "R_NOTE=two words" --label ' + "'team=public health'"
        $inputs = $script:refLocalInputs
        $expected = @(
            'run', '-d', '--rm',
            '--name', 'IMPACTncd_Germany_alice',
            '-e', 'PASSWORD=Secret-pw1',
            '-e', 'DISABLE_AUTH=false',
            '-e', 'USERID=1000',
            '-e', 'GROUPID=1000',
            '-e', 'CONTAINER_REPO_NAME=IMPACTncd_Germany',
            '-e', 'SYNC_ENABLED=false',
            '-e', 'GIT_SSH_COMMAND=ssh -i /home/rstudio/.ssh/id_ed25519_alice -o IdentitiesOnly=yes -o UserKnownHostsFile=/home/rstudio/.ssh/known_hosts -o StrictHostKeyChecking=accept-new',
            '--mount', 'type=bind,source=/c/repos/IMPACTncd_Germany,target=/home/rstudio/IMPACTncd_Germany',
            '-p', '127.0.0.1:8787:8787',
            '--shm-size', '2g',
            '-e', 'R_NOTE=two words',
            '--label', 'team=public health',
            '--mount', 'type=bind,source=/c/repos/IMPACTncd_Germany/./outputs,target=/home/rstudio/IMPACTncd_Germany/outputs',
            '--mount', 'type=bind,source=/c/repos/IMPACTncd_Germany/./inputs/synthpop,target=/home/rstudio/IMPACTncd_Germany/inputs/synthpop',
            '--label', 'impact.use_volumes=false',
            '--label', 'impact.repo_path=C:\repos\IMPACTncd_Germany',
            '--label', 'impact.output_dir=C:/repos/IMPACTncd_Germany/./outputs',
            '--label', 'impact.synthpop_dir=C:/repos/IMPACTncd_Germany/./inputs/synthpop',
            '--mount', 'type=bind,source=C:\Users\alice\.ssh\id_ed25519_alice,target=/keys/id_ed25519_alice,readonly',
            '--workdir', '/home/rstudio/IMPACTncd_Germany',
            'impactncd_germany'
        )

        $actual = Build-DockerRunCommand -State (New-ReferenceState) -CustomParams $customParams @inputs
        Assert-MatchesStoredReference -Actual $actual -Expected $expected
    }

    It 'f) folders with spaces on drives D: and E: (drive letter becomes /d and /e)' {
        # A copy of the repository in a folder with spaces, results on another drive.
        # What this pins:
        #  - 'D:\...' becomes '/d/...' in the mount sources (lower-case drive letter,
        #    forward slashes); the spaces stay as they are, inside ONE argument;
        #  - the labels keep the paths exactly as they were given;
        #  - the SSH key path is passed on unchanged (Windows form, with the space).
        # The repository name inside the container has no space: the GUI makes a safe
        # name from the folder name (ConvertTo-DockerSafeRepoName) before it gets here.
        $state = New-ReferenceState -UserName 'maxm' -Repo 'IMPACTncd_Germany_Kopie'
        $expected = @(
            'run', '-d', '--rm',
            '--name', 'IMPACTncd_Germany_Kopie_maxm',
            '-e', 'PASSWORD=Secret-pw1',
            '-e', 'DISABLE_AUTH=false',
            '-e', 'USERID=1000',
            '-e', 'GROUPID=1000',
            '-e', 'CONTAINER_REPO_NAME=IMPACTncd_Germany_Kopie',
            '-e', 'SYNC_ENABLED=false',
            '-e', 'GIT_SSH_COMMAND=ssh -i /home/rstudio/.ssh/id_ed25519_maxm -o IdentitiesOnly=yes -o UserKnownHostsFile=/home/rstudio/.ssh/known_hosts -o StrictHostKeyChecking=accept-new',
            '--mount', 'type=bind,source=/d/Max Mustermann/IMPACT Modelle/IMPACTncd_Germany - Kopie,target=/home/rstudio/IMPACTncd_Germany_Kopie',
            '-p', '127.0.0.1:8787:8787',
            '--mount', 'type=bind,source=/d/Max Mustermann/IMPACT Modelle/IMPACTncd_Germany - Kopie/./outputs,target=/home/rstudio/IMPACTncd_Germany_Kopie/outputs',
            '--mount', 'type=bind,source=/e/IMPACT Daten/synthpop,target=/home/rstudio/IMPACTncd_Germany_Kopie/inputs/synthpop',
            '--label', 'impact.use_volumes=false',
            '--label', 'impact.repo_path=D:\Max Mustermann\IMPACT Modelle\IMPACTncd_Germany - Kopie',
            '--label', 'impact.output_dir=D:/Max Mustermann/IMPACT Modelle/IMPACTncd_Germany - Kopie/./outputs',
            '--label', 'impact.synthpop_dir=E:/IMPACT Daten/synthpop',
            '--mount', 'type=bind,source=C:\Users\Max Mustermann\.ssh\id_ed25519_maxm,target=/keys/id_ed25519_maxm,readonly',
            '--workdir', '/home/rstudio/IMPACTncd_Germany_Kopie',
            'impactncd_germany_kopie'
        )

        $actual = Build-DockerRunCommand -State $state -ImageName 'impactncd_germany_kopie' `
            -ProjectRoot 'D:\Max Mustermann\IMPACT Modelle\IMPACTncd_Germany - Kopie' `
            -OutputDir   'D:/Max Mustermann/IMPACT Modelle/IMPACTncd_Germany - Kopie/./outputs' `
            -SynthpopDir 'E:/IMPACT Daten/synthpop' `
            -SshKeyPath  'C:\Users\Max Mustermann\.ssh\id_ed25519_maxm'
        Assert-MatchesStoredReference -Actual $actual -Expected $expected
    }

    It 'REMOTE as it is today (bind mounts, port 8788, high compute, uid 1003 and gid 1004)' {
        # This one reference is for the workstation (REMOTE) as it works TODAY. The
        # redesign will change the REMOTE start command on purpose. When that happens,
        # this reference is replaced deliberately, in the same change. Until then it
        # shows that work on other parts did not alter REMOTE by accident.
        # Differences to LOCAL that are pinned here: the port is published on all
        # network interfaces (no '127.0.0.1:'), paths are used unchanged, the uid and
        # gid of the workstation user are passed on, and '--cpus 32 -m 384g' is added
        # for "High compute".
        $state = New-ReferenceState -Location 'REMOTE@192.0.2.10'
        $expected = @(
            'run', '-d', '--rm',
            '--name', 'IMPACTncd_Germany_alice',
            '-e', 'PASSWORD=Secret-pw1',
            '-e', 'DISABLE_AUTH=false',
            '-e', 'USERID=1003',
            '-e', 'GROUPID=1004',
            '-e', 'CONTAINER_REPO_NAME=IMPACTncd_Germany',
            '-e', 'SYNC_ENABLED=false',
            '-e', 'GIT_SSH_COMMAND=ssh -i /home/rstudio/.ssh/id_ed25519_alice -o IdentitiesOnly=yes -o UserKnownHostsFile=/home/rstudio/.ssh/known_hosts -o StrictHostKeyChecking=accept-new',
            '--mount', 'type=bind,source=/home/shared-account/Repositories/IMPACTncd_Germany,target=/home/rstudio/IMPACTncd_Germany',
            '-p', '8788:8787',
            '--mount', 'type=bind,source=/mnt/disk_a/shared/Base/outputs,target=/home/rstudio/IMPACTncd_Germany/outputs',
            '--mount', 'type=bind,source=/mnt/disk_a/shared/Base/inputs/synthpop,target=/home/rstudio/IMPACTncd_Germany/inputs/synthpop',
            '--cpus', '32',
            '-m', '384g',
            '--label', 'impact.use_volumes=false',
            '--label', 'impact.repo_path=/home/shared-account/Repositories/IMPACTncd_Germany',
            '--label', 'impact.output_dir=/mnt/disk_a/shared/Base/outputs',
            '--label', 'impact.synthpop_dir=/mnt/disk_a/shared/Base/inputs/synthpop',
            '--mount', 'type=bind,source=/home/shared-account/.ssh/id_ed25519_alice,target=/keys/id_ed25519_alice,readonly',
            '--workdir', '/home/rstudio/IMPACTncd_Germany',
            'impactncd_germany'
        )

        $actual = Build-DockerRunCommand -State $state -Port '8788' -HighCompute $true `
            -ContainerUid '1003' -ContainerGid '1004' -ImageName 'impactncd_germany' `
            -ProjectRoot '/home/shared-account/Repositories/IMPACTncd_Germany' `
            -OutputDir   '/mnt/disk_a/shared/Base/outputs' `
            -SynthpopDir '/mnt/disk_a/shared/Base/inputs/synthpop' `
            -SshKeyPath  '/home/shared-account/.ssh/id_ed25519_alice'
        Assert-MatchesStoredReference -Actual $actual -Expected $expected
    }
}

# ═══════════════════════════════════════════════════════════════════════════════
#  Guard: the Start button must take its 'docker run' arguments from
#  Build-DockerRunCommand
#
#  WHY
#  The stored references above test the function Build-DockerRunCommand. They only
#  protect users if the Start button of the GUI really uses that function. For a
#  long time the launcher (IMPACT_Docker_GUI_v2.ps1) built the same list a second
#  time on its own, so a test of the function said nothing about what users ran.
#  The tests below fail when such a second copy comes back, or when the Start button
#  stops handing all its values to the function.
#
#  They also pin the WIRING between the Start button and the function: which value
#  goes to which input (for example the result folder to -OutputDir and not the
#  synthpop folder), where each of these values is set, and that the finished list
#  reaches docker unchanged. Without this, a mix-up in the launcher would change
#  what users run while every stored reference still passes.
#
#  HOW
#  The launcher is only READ here, with the PowerShell parser (the same way as in
#  'Module exports and manifest stay in sync' above). The parser turns the file into
#  a tree of its parts (commands, lists, assignments), which can be searched. No line
#  of the launcher is run, so these tests need no Windows, no window and no Docker.
#
#  WHEN ONE OF THESE TESTS FAILS AFTER A CHANGE THAT WAS WANTED
#  Several tests compare lines of the launcher with texts stored here. When such a
#  line is changed on purpose, read the message of the failed test, check that the
#  new line does what you want, and then update the stored text in the same change.
# ═══════════════════════════════════════════════════════════════════════════════
Describe 'Start button uses Build-DockerRunCommand (guard for the stored references)' -Tag Unit {
    BeforeAll {
        $launcherPath = Join-Path $PSScriptRoot '..' 'current_version' 'IMPACT_Docker_GUI_v2.ps1'
        $tokens = $null; $errors = $null
        $script:guardLauncherAst = [System.Management.Automation.Language.Parser]::ParseFile($launcherPath, [ref]$tokens, [ref]$errors)
        $script:guardParseErrors = if ($errors) { @($errors) } else { @() }

        # The reason shown when one of the tests below fails.
        $script:guardReason = "the 'docker run' arguments for the IMPACT container must come from Build-DockerRunCommand in the module. Only then do the tests 'LOCAL start arguments: stored reference' check what users really run"

        # Every place in the launcher where Build-DockerRunCommand is called.
        $script:guardCalls = @($script:guardLauncherAst.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Build-DockerRunCommand'
        }, $true))

        # ---- Small helpers for the tests below ------------------------------------
        # In all of them, $Scope is a part of the tree the parser made: the whole
        # launcher, or one script block { ... } of it.

        # Returns a piece of code as text without any white space (blanks, tabs, line
        # breaks). Two pieces of code that differ only in their layout then count as
        # equal, so re-indenting the launcher does not fail a test.
        function Get-GuardCompactText {
            param([string]$Text)
            return ($Text -replace '\s', '')
        }

        # Returns every place inside $Scope where the variable $Name occurs, whether
        # it is set there or only read.
        function Get-GuardVariableUses {
            param($Scope, [string]$Name)
            return @($Scope.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.VariableExpressionAst] -and
                    $node.VariablePath.UserPath -eq $Name
            }, $true))
        }

        # Returns every assignment inside $Scope whose left side names the variable
        # $Name. All forms count:  $x = 1   $x += 1   $x[3] = 1   $x.Name = 1
        function Get-GuardAssignments {
            param($Scope, [string]$Name)
            return @($Scope.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
                    @(Get-GuardVariableUses -Scope $node.Left -Name $Name).Count -gt 0
            }, $true))
        }

        # Returns the assignment ($x = ...) that a part of the code belongs to, or
        # nothing when it does not sit inside an assignment. The walk goes upwards and
        # stops at the end of the surrounding script block, so an assignment further
        # out (one that only CONTAINS a whole block of code) is not taken.
        function Get-GuardEnclosingAssignment {
            param($Node)
            $current = $Node.Parent
            while ($current -and $current -isnot [System.Management.Automation.Language.ScriptBlockAst]) {
                if ($current -is [System.Management.Automation.Language.AssignmentStatementAst]) { return $current }
                $current = $current.Parent
            }
            return $null
        }

        # Returns the script block { ... } that directly surrounds a part of the code.
        # For the call of Build-DockerRunCommand this is the code of the Start button.
        function Get-GuardEnclosingScriptBlock {
            param($Node)
            $current = $Node.Parent
            while ($current -and $current -isnot [System.Management.Automation.Language.ScriptBlockAst]) {
                $current = $current.Parent
            }
            return $current
        }
    }

    It 'The launcher can be read by the PowerShell parser (no syntax error)' {
        # If this fails, the other tests in this block cannot say anything useful.
        $script:guardParseErrors.Count | Should -Be 0
    }

    It 'The launcher has no argument list of its own for starting the container' {
        # The words that mark "this starts the IMPACT container": the container runs in
        # the background ('-d', long form '--detach') and gets a name ('--name'). The
        # short helper containers the launcher starts for the volumes ('run --rm ...
        # alpine ...') have none of these, so they are not reported.
        $startWords = @('-d', '--detach', '--name')

        # 1. A written-out list whose first entry is 'run', for example
        #    @('run','-d','--rm','--name',$State.ContainerName, ...)
        $lists = @($script:guardLauncherAst.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.ArrayLiteralAst]
        }, $true))
        $ownLists = @($lists | Where-Object {
            $first = $_.Elements[0]
            $texts = @($_.Elements |
                Where-Object { $_ -is [System.Management.Automation.Language.StringConstantExpressionAst] } |
                ForEach-Object { $_.Value })
            ($first -is [System.Management.Automation.Language.StringConstantExpressionAst]) -and
                ($first.Value -eq 'run') -and
                (@($texts | Where-Object { $startWords -contains $_ }).Count -gt 0)
        })

        # 2. The same written directly behind the docker command, for example
        #    & docker run -d --rm --name ...
        $dockerCommands = @($script:guardLauncherAst.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.CommandAst] -and $node.GetCommandName() -in @('docker', 'docker.exe')
        }, $true))
        $ownCommands = @($dockerCommands | Where-Object {
            $words = @($_.CommandElements | ForEach-Object { $_.Extent.Text })
            ($words -contains 'run') -and (@($words | Where-Object { $startWords -contains $_ }).Count -gt 0)
        })

        $found = @($ownLists) + @($ownCommands)
        $where = ($found | ForEach-Object { "line $($_.Extent.StartLineNumber)" }) -join ', '
        $found.Count | Should -Be 0 -Because "the launcher has its own 'docker run' list in: $where. Background: $($script:guardReason)"
    }

    It 'The Start button calls Build-DockerRunCommand' {
        $script:guardCalls.Count | Should -BeGreaterThan 0 -Because $script:guardReason
    }

    It 'Nothing is added to the list after Build-DockerRunCommand has built it' {
        # The launcher stores the result in a variable (today: $dockerArgs) and hands it
        # to docker a few lines further down. Anything that changed the list on this
        # way would again create arguments that the stored references never see, for
        # example a line such as  $dockerArgs += @('--cpus','32') . So this test follows
        # the list from the call to docker, in four steps.
        $script:guardCalls.Count | Should -BeGreaterThan 0 -Because $script:guardReason
        foreach ($call in $script:guardCalls) {
            $line = $call.Extent.StartLineNumber

            # Step 1: the result is stored in a plain variable, and the right side of
            # the '=' is the call alone. Allowed are
            #     $x = Build-DockerRunCommand ...     and     $x = @(Build-DockerRunCommand ...)
            # Not allowed is anything around the call, such as
            #     @(Build-DockerRunCommand ...) + @('--privileged')
            #     @(Build-DockerRunCommand ... | ForEach-Object { ... })
            $assignment = Get-GuardEnclosingAssignment -Node $call
            $assignment | Should -BeOfType ([System.Management.Automation.Language.AssignmentStatementAst]) -Because "the result of Build-DockerRunCommand (line $line of the launcher) must be stored in a variable"
            $assignment.Left | Should -BeOfType ([System.Management.Automation.Language.VariableExpressionAst]) -Because "the result of Build-DockerRunCommand (line $line of the launcher) must be stored in a plain variable"
            $assignment.Operator | Should -Be ([System.Management.Automation.Language.TokenKind]::Equals) -Because "the result of Build-DockerRunCommand (line $line of the launcher) must be stored with a plain '=', not added to an existing list. Background: $($script:guardReason)"
            $variableName = $assignment.Left.VariablePath.UserPath
            $callText  = Get-GuardCompactText $call.Extent.Text
            $rightText = Get-GuardCompactText $assignment.Right.Extent.Text
            $rightText | Should -BeIn @($callText, "@($callText)") -Because "in line $line of the launcher the right side of '`$$variableName =' must be the call of Build-DockerRunCommand alone (also allowed: inside @( )). Anything added around the call changes the list after the function has built it. Background: $($script:guardReason)"

            # Step 2: no other line of the launcher sets or changes the variable. This
            # also finds a change of one single argument, such as  $dockerArgs[18] = ...
            $otherAssignments = @(Get-GuardAssignments -Scope $script:guardLauncherAst -Name $variableName | Where-Object { $_ -ne $assignment })
            $where = ($otherAssignments | ForEach-Object { "line $($_.Extent.StartLineNumber)" }) -join ', '
            $otherAssignments.Count | Should -Be 0 -Because "`$$variableName may only be set by the call of Build-DockerRunCommand, but the launcher also sets or changes it in: $where. Background: $($script:guardReason)"

            # Step 3: apart from the line that stores it, the list is used in exactly ONE
            # place. That place is the line that puts the Docker context in front of it
            # (the context tells docker which Docker to talk to: the one on this PC or the
            # one on the workstation). The line is compared with the stored text below.
            $otherUses = @(Get-GuardVariableUses -Scope $script:guardLauncherAst -Name $variableName | Where-Object { $_ -ne $assignment.Left })
            $where = if ($otherUses.Count -gt 0) { ($otherUses | ForEach-Object { "line $($_.Extent.StartLineNumber)" }) -join ', ' } else { 'no place at all' }
            $otherUses.Count | Should -Be 1 -Because "`$$variableName must be used in exactly one place after the call (the line that hands it to docker), but it is used in: $where. Background: $($script:guardReason)"
            $handOver = Get-GuardEnclosingAssignment -Node $otherUses[0]
            $handOver | Should -Not -BeNullOrEmpty -Because "the line that uses `$$variableName (line $($otherUses[0].Extent.StartLineNumber) of the launcher) must be the assignment that builds `$runCmd"
            $handOver.Extent.StartOffset | Should -BeGreaterThan $assignment.Extent.EndOffset -Because "`$$variableName must be handed on AFTER Build-DockerRunCommand has built it"
            $expectedHandOver = '$runCmd = (Get-DockerContextArgs -State $State) + $' + $variableName
            (Get-GuardCompactText $handOver.Extent.Text) | Should -BeExactly (Get-GuardCompactText $expectedHandOver) -Because "line $($handOver.Extent.StartLineNumber) of the launcher must stay  $expectedHandOver  (the Docker context first, then the unchanged list). Background: $($script:guardReason)"

            # Step 4: the combined list ($runCmd) reaches docker unchanged. Inside the code
            # of the Start button $runCmd is set only by the line of step 3, and the next
            # docker command after that line is exactly  & docker $runCmd  (an addition
            # such as  & docker $runCmd --privileged  would fail here).
            $startCode = Get-GuardEnclosingScriptBlock -Node $call
            [object]::ReferenceEquals((Get-GuardEnclosingScriptBlock -Node $handOver), $startCode) | Should -BeTrue -Because "the call of Build-DockerRunCommand and the line that builds `$runCmd must both be in the code of the Start button"
            $runCmdAssignments = @(Get-GuardAssignments -Scope $startCode -Name 'runCmd')
            $where = ($runCmdAssignments | ForEach-Object { "line $($_.Extent.StartLineNumber)" }) -join ', '
            $runCmdAssignments.Count | Should -Be 1 -Because "inside the code of the Start button `$runCmd may only be set once, by the line of step 3, but it is set or changed in: $where. Background: $($script:guardReason)"
            $dockerCallsAfter = @($startCode.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.CommandAst] -and
                    $node.GetCommandName() -in @('docker', 'docker.exe') -and
                    $node.Extent.StartOffset -gt $handOver.Extent.EndOffset
            }, $true) | Sort-Object { $_.Extent.StartOffset })
            $dockerCallsAfter.Count | Should -BeGreaterThan 0 -Because "the Start button must hand `$runCmd to docker after line $($handOver.Extent.StartLineNumber) of the launcher"
            # The words of that docker command, without the '&' in front and without a
            # redirection such as '2>&1' behind it (the parser keeps those apart).
            $words = @($dockerCallsAfter[0].CommandElements | ForEach-Object { $_.Extent.Text }) -join ' '
            $words | Should -BeExactly 'docker $runCmd' -Because "the first docker command after line $($handOver.Extent.StartLineNumber) of the launcher (it is in line $($dockerCallsAfter[0].Extent.StartLineNumber)) must be  & docker `$runCmd  with nothing added. Background: $($script:guardReason)"
        }
    }

    It 'The Start button hands every input of Build-DockerRunCommand to it, by name' {
        # Why: an input that is left out silently takes its default value. For example
        # without ContainerUid the container on the workstation would run with user id
        # 1000, whatever the real id is. And a name with a typing mistake is silently
        # ignored by PowerShell for this kind of function, with the same effect.
        #
        # If a new input is added to the function on purpose, and the Start button
        # should use its default, add its name here (with a comment why).
        $mayBeLeftOut = @()

        # The inputs the function has (its parameters), read from the loaded module.
        # (PowerShell adds some inputs of its own to certain functions, such as -Verbose.
        # They are left out here.)
        $common = @([System.Management.Automation.Cmdlet]::CommonParameters) + @([System.Management.Automation.Cmdlet]::OptionalCommonParameters)
        $wanted = @((Get-Command Build-DockerRunCommand).Parameters.Keys | Where-Object { $common -notcontains $_ })
        $wanted.Count | Should -BeGreaterThan 0

        $script:guardCalls.Count | Should -BeGreaterThan 0 -Because $script:guardReason
        foreach ($call in $script:guardCalls) {
            # Names written directly at the call, such as  -Port $hostPort
            $given = @($call.CommandElements |
                Where-Object { $_ -is [System.Management.Automation.Language.CommandParameterAst] } |
                ForEach-Object { $_.ParameterName })

            # Names handed over as a table ("splatting"), such as  @startInputs  where
            # $startInputs = @{ Port = $hostPort; ... }  was filled before the call.
            $splatted = @($call.CommandElements | Where-Object {
                $_ -is [System.Management.Automation.Language.VariableExpressionAst] -and $_.Splatted
            })
            foreach ($splat in $splatted) {
                $tableName = $splat.VariablePath.UserPath
                $tableAssignments = @($script:guardLauncherAst.FindAll({
                    param($node)
                    $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
                        $node.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and
                        $node.Left.VariablePath.UserPath -eq $tableName
                }, $true))
                $tableAssignments.Count | Should -Be 1 -Because "the table `$$tableName must be filled in exactly one place, so this test can read which inputs it contains"
                $table = $tableAssignments[0].Right.Find({
                    param($node)
                    $node -is [System.Management.Automation.Language.HashtableAst]
                }, $true)
                $table | Should -Not -BeNullOrEmpty -Because "`$$tableName must be written as a table @{ Name = value; ... }"
                $given += @($table.KeyValuePairs | ForEach-Object { $_.Item1.Extent.Text.Trim("'", '"') })
            }

            $line = $call.Extent.StartLineNumber
            $missing = @($wanted | Where-Object { $given -notcontains $_ -and $mayBeLeftOut -notcontains $_ })
            $unknown = @($given | Where-Object { $wanted -notcontains $_ })
            ($missing -join ', ') | Should -BeNullOrEmpty -Because "the call in line $line of the launcher must hand over every input of Build-DockerRunCommand (an input that is left out silently takes its default value)"
            ($unknown -join ', ') | Should -BeNullOrEmpty -Because "the call in line $line of the launcher uses a name that is not an input of Build-DockerRunCommand (such a value would be ignored)"
        }
    }

    It 'The Start button hands the RIGHT value to each input of Build-DockerRunCommand' {
        # Why: the test above only checks the NAMES of the inputs. A mix-up of the
        # values would pass it, and it would pass the stored references too, because
        # they call the function directly. Examples of such a mix-up:
        #     OutputDir = $synthDir        the synthpop folder is mounted as the result folder
        #     ImageName = $State.SelectedRepo    the image name is no longer in lower case
        # So the value of every input is compared here with a stored text.
        #
        # Left: the input of the function. Right: the variable of the Start button that
        # must be handed to it, written exactly as in the launcher.
        $expectedValues = [ordered]@{
            State        = '$State'
            Port         = '$hostPort'
            UseVolumes   = '$useVolumes'
            HighCompute  = '$highComp'
            CustomParams = '$customParams'
            ImageName    = '$imageName'
            ProjectRoot  = '$projectRoot'
            OutputDir    = '$outputDir'
            SynthpopDir  = '$synthDir'
            SshKeyPath   = '$sshKeyPath'
            ContainerUid = '$containerUid'
            ContainerGid = '$containerGid'
        }

        $script:guardCalls.Count | Should -BeGreaterThan 0 -Because $script:guardReason
        foreach ($call in $script:guardCalls) {
            $line = $call.Extent.StartLineNumber

            # The call must have the form  Build-DockerRunCommand @table : the name of
            # the function and ONE table with all inputs ("splatting"). This test reads
            # the values from that table.
            $callWords = @($call.CommandElements)
            $isOneTable = ($callWords.Count -eq 2) -and
                ($callWords[1] -is [System.Management.Automation.Language.VariableExpressionAst]) -and
                $callWords[1].Splatted
            $isOneTable | Should -BeTrue -Because "the call in line $line of the launcher must be written as  Build-DockerRunCommand @table  (one table with all inputs), so that this test can read which value goes to which input. It is written as: $($call.Extent.Text)"
            $tableName = $callWords[1].VariablePath.UserPath

            # The table occurs in exactly two places: where it is filled and where it is
            # handed to the function. A third place could change an entry after the table
            # was filled, for example  $startInputs.HighCompute = $true .
            $tableUses = @(Get-GuardVariableUses -Scope $script:guardLauncherAst -Name $tableName)
            $where = ($tableUses | ForEach-Object { "line $($_.Extent.StartLineNumber)" }) -join ', '
            $tableUses.Count | Should -Be 2 -Because "the table `$$tableName may occur in exactly two places of the launcher (where it is filled, and at the call of Build-DockerRunCommand), but it occurs in: $where"

            # The place where the table is filled:  $table = @{ Name = value ... }
            $tableAssignments = @(Get-GuardAssignments -Scope $script:guardLauncherAst -Name $tableName)
            $tableAssignments.Count | Should -Be 1 -Because "the table `$$tableName must be filled in exactly one place"
            $tableAssignment = $tableAssignments[0]
            $tableAssignment.Extent.EndOffset | Should -BeLessThan $call.Extent.StartOffset -Because "the table `$$tableName must be filled BEFORE it is handed to Build-DockerRunCommand in line $line of the launcher"
            $tableAssignment.Operator | Should -Be ([System.Management.Automation.Language.TokenKind]::Equals) -Because "the table `$$tableName must be filled with a plain '='"
            $right = $tableAssignment.Right
            $isPlainTable = ($right -is [System.Management.Automation.Language.CommandExpressionAst]) -and
                ($right.Expression -is [System.Management.Automation.Language.HashtableAst])
            $isPlainTable | Should -BeTrue -Because "`$$tableName must be written as one table @{ Name = value ... } and nothing else (line $($tableAssignment.Extent.StartLineNumber) of the launcher)"

            # Read the table: name of the input -> text of the value, as written.
            $actualValues = [ordered]@{}
            foreach ($pair in $right.Expression.KeyValuePairs) {
                $name = $pair.Item1.Extent.Text.Trim("'", '"')
                $actualValues[$name] = $pair.Item2.Extent.Text.Trim()
            }

            # Compare, input by input. 'Should -BeExactly' also notices a difference
            # between upper and lower case.
            foreach ($name in $expectedValues.Keys) {
                $actualValues[$name] | Should -BeExactly $expectedValues[$name] -Because "in the table `$$tableName of the launcher (line $($tableAssignment.Extent.StartLineNumber) and following) the input '$name' must get the value $($expectedValues[$name]). Another value changes what users run, and the stored references cannot see it"
            }
            # An input that is in the table but has no stored text yet (a new input of
            # the function): add it to $expectedValues above.
            $notStored = @($actualValues.Keys | Where-Object { $expectedValues.Keys -notcontains $_ })
            ($notStored -join ', ') | Should -BeNullOrEmpty -Because "these inputs are in the table `$$tableName of the launcher but have no stored value in this test yet"
        }
    }

    It 'The values handed to Build-DockerRunCommand are set in the expected places of the Start button' {
        # Why: the test above pins WHICH variable goes to which input. This test pins
        # where these variables get their content, one step back. Examples of what it
        # notices:
        #     $imageName = $State.SelectedRepo          (lower case lost)
        #     $customParams += ' --privileged'          (an extra line that changes a value)
        #     $sshKeyPath = ...                         (another key file in LOCAL mode)
        #
        # Left: the variable. Right: EVERY line in the code of the Start button that
        # sets it, in the order of the file. White space is ignored in the comparison.
        # ('' inside a text in single quotes stands for one single quote.)
        $expectedSources = [ordered]@{
            # The four boxes of the window that end up in the 'docker run' list.
            useVolumes   = @('$useVolumes = $chkVolumes.Checked')
            highComp     = @('$highComp = $chkHigh.Checked')
            customParams = @('$customParams = $txtParams.Text.Trim()')
            portOverride = @('$portOverride = $txtPort.Text.Trim()')
            # The port: the text of the Port box (the '8787' is only a safety net, see
            # the comment at this line in the launcher).
            hostPort     = @('$hostPort = if ($portOverride) { $portOverride } else { ''8787'' }')
            # The image name is the repository name in lower case.
            imageName    = @('$imageName = $State.SelectedRepo.ToLowerInvariant()')
            # The repository folder, and the two folders named in the YAML file.
            projectRoot  = @('$projectRoot = if ($State.ContainerLocation -eq ''LOCAL'') { $State.Paths.LocalRepo } else { $State.Paths.RemoteRepo }')
            outputDir    = @('$outputDir = Get-YamlPathValue -State $State -YamlPath $simDesign -Key ''output_dir'' -BaseDir $baseDirForYaml')
            synthDir     = @('$synthDir = Get-YamlPathValue -State $State -YamlPath $simDesign -Key ''synthpop_dir'' -BaseDir $baseDirForYaml')
            # The key file: first line LOCAL, second line REMOTE (see the next check).
            sshKeyPath   = @('$sshKeyPath = $State.Paths.SshPrivate',
                             '$sshKeyPath = "/home/$($State.RemoteUser)/.ssh/id_ed25519_$($State.UserName)"')
            # User id and group id: 1000 to begin with; on the workstation they are
            # replaced by the ids of the workstation user.
            containerUid = @('$containerUid = ''1000''', '$containerUid = $uidOut.Trim()')
            containerGid = @('$containerGid = ''1000''', '$containerGid = $gidOut.Trim()')
        }

        # One complete statement that must be in the code of the Start button exactly
        # once: it decides WHICH of the two key files is used. LOCAL must take the key
        # file on this PC.
        $expectedKeyChoice = 'if ($State.ContainerLocation -eq ''LOCAL'') { $sshKeyPath = $State.Paths.SshPrivate } else { $sshKeyPath = "/home/$($State.RemoteUser)/.ssh/id_ed25519_$($State.UserName)" }'

        $script:guardCalls.Count | Should -BeGreaterThan 0 -Because $script:guardReason
        foreach ($call in $script:guardCalls) {
            # The code of the Start button: the script block around the call.
            $startCode = Get-GuardEnclosingScriptBlock -Node $call
            $startCode | Should -Not -BeNullOrEmpty

            foreach ($name in $expectedSources.Keys) {
                $expected = @($expectedSources[$name] | ForEach-Object { Get-GuardCompactText $_ })
                $found = @(Get-GuardAssignments -Scope $startCode -Name $name | Sort-Object { $_.Extent.StartOffset })
                $actual = @($found | ForEach-Object { Get-GuardCompactText $_.Extent.Text })
                $where = ($found | ForEach-Object { "line $($_.Extent.StartLineNumber): $($_.Extent.Text)" }) -join '  |  '
                $hint = "the code of the Start button must set `$$name exactly in these lines: $($expectedSources[$name] -join '  |  '). It sets it in: $where. If this change is wanted, check what it means for the 'docker run' list and then update the stored lines in this test"
                $actual.Count | Should -Be $expected.Count -Because $hint
                for ($i = 0; $i -lt $expected.Count; $i++) {
                    $actual[$i] | Should -BeExactly $expected[$i] -Because $hint
                }
            }

            $ifStatements = @($startCode.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.IfStatementAst]
            }, $true))
            $keyChoice = @($ifStatements | Where-Object { (Get-GuardCompactText $_.Extent.Text) -ceq (Get-GuardCompactText $expectedKeyChoice) })
            $keyChoice.Count | Should -Be 1 -Because "the code of the Start button must contain this statement exactly once, unchanged: $expectedKeyChoice  (it makes LOCAL use the key file on this PC)"
        }
    }
}
