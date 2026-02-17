#Requires -Modules Pester

<#
.SYNOPSIS
    Tests that run against a live SSHD Docker container.
    These validate real SSH connectivity and remote-command execution
    using the functions from IMPACT_Docker_GUI.

.DESCRIPTION
    Requires environment variables set by CI or Run-AllTests.ps1:
        IMPACT_TEST_SSH_HOST  (default: localhost)
        IMPACT_TEST_SSH_PORT  (default: 2222)
        IMPACT_TEST_SSH_USER  (default: testuser)
        IMPACT_TEST_SSH_KEY   (path to private key)

    Tag: DockerSsh - skipped unless all env vars are set.
#>

# Skip logic MUST be in BeforeDiscovery so that -Skip: evaluates correctly
# (Pester 5 evaluates -Skip at discovery time, before BeforeAll runs)
BeforeDiscovery {
    $script:SshHost = $env:IMPACT_TEST_SSH_HOST
    $script:SshPort = if ($env:IMPACT_TEST_SSH_PORT) { $env:IMPACT_TEST_SSH_PORT } else { '2222' }
    $script:SshUser = if ($env:IMPACT_TEST_SSH_USER) { $env:IMPACT_TEST_SSH_USER } else { 'testuser' }
    $script:SshKey  = $env:IMPACT_TEST_SSH_KEY

    $script:SkipSshTests = -not ($script:SshHost -and $script:SshKey -and (Test-Path $script:SshKey -ErrorAction SilentlyContinue))

    if ($script:SkipSshTests) {
        Write-Warning "Docker SSH tests will be skipped - set IMPACT_TEST_SSH_HOST and IMPACT_TEST_SSH_KEY env vars."
    }
}

BeforeAll {
    $modulePath = Join-Path $PSScriptRoot '..' 'current_version' 'IMPACT_Docker_GUI.psm1'
    Import-Module $modulePath -Force -DisableNameChecking
    . (Join-Path $PSScriptRoot 'Helpers' 'TestSessionState.ps1')

    # Re-read env vars in run scope (BeforeDiscovery vars don't carry over)
    $script:SshHost = $env:IMPACT_TEST_SSH_HOST
    $script:SshPort = if ($env:IMPACT_TEST_SSH_PORT) { $env:IMPACT_TEST_SSH_PORT } else { '2222' }
    $script:SshUser = if ($env:IMPACT_TEST_SSH_USER) { $env:IMPACT_TEST_SSH_USER } else { 'testuser' }
    $script:SshKey  = $env:IMPACT_TEST_SSH_KEY

    # Helper: run a command on the SSHD container via SSH
    function Invoke-SshCommand {
        param([string]$Command)
        $sshArgs = @(
            '-p', $script:SshPort,
            '-i', $script:SshKey,
            '-o', 'StrictHostKeyChecking=no',
            '-o', 'UserKnownHostsFile=/dev/null',
            '-o', 'BatchMode=yes',
            '-o', 'IdentitiesOnly=yes',
            "$($script:SshUser)@$($script:SshHost)",
            $Command
        )
        $result = & ssh @sshArgs 2>&1
        return $result
    }
}

# -- SSH Connectivity ---------------------------------------------------------
Describe 'SSH Connectivity to SSHD Container' -Tag 'DockerSsh' {

    It 'Can connect via SSH and run a command' -Skip:$script:SkipSshTests {
        $output = Invoke-SshCommand 'echo HELLO_IMPACT'
        $output | Should -Contain 'HELLO_IMPACT'
    }

    It 'Can list the fake repository directory' -Skip:$script:SkipSshTests {
        $output = Invoke-SshCommand 'ls -a /home/testuser/Schreibtisch/Repositories/IMPACTncd_Germany'
        ($output -join "`n") | Should -Match '\.git'
    }
}

# -- Get-RemoteHostString -----------------------------------------------------
Describe 'Get-RemoteHostString against live container' -Tag 'DockerSsh' {

    It 'Returns RemoteHost when set' -Skip:$script:SkipSshTests {
        $state = New-TestSessionState -UserName $script:SshUser -Location "REMOTE@$($script:SshHost)"
        $state.RemoteHost = "$($script:SshUser)@$($script:SshHost)"
        $result = Get-RemoteHostString -State $state
        $result | Should -Be "$($script:SshUser)@$($script:SshHost)"
    }
}

# -- Remote Metadata Read/Write ----------------------------------------------
Describe 'Write-RemoteContainerMetadata via SSH' -Tag 'DockerSsh' {

    BeforeAll {
        $script:metaDir = "/tmp/impact_test_meta_$(Get-Random)"
    }

    It 'Can write and read a metadata file on the remote host' -Skip:$script:SkipSshTests {
        Invoke-SshCommand "mkdir -p $($script:metaDir)" | Out-Null

        $content = 'container_name=test123'
        Invoke-SshCommand "echo '$content' > $($script:metaDir)/metadata.txt" | Out-Null

        $readBack = Invoke-SshCommand "cat $($script:metaDir)/metadata.txt"
        $readBack | Should -Contain $content
    }

    AfterAll {
        # Save artifacts for DockerSsh tests
        try {
            $localPaths = @()
            $localPaths += $script:metaDir
            Save-TestArtifacts -Suite 'docker-ssh' -Paths $localPaths -ExtraFiles @('./tests/TestResults-DockerSsh.xml') -ContainerNames @()
        } catch {
            Write-Warning "Failed to save docker-ssh artifacts: $($_.Exception.Message)"
        }

        if (-not $script:SkipSshTests) {
            Invoke-SshCommand "rm -rf $($script:metaDir)" | Out-Null
        }
    }
}

# -- Set-DockerSSHEnvironment ------------------------------------------------
Describe 'Set-DockerSSHEnvironment unit validation' -Tag 'DockerSsh' {

    It 'Sets DOCKER_HOST for a REMOTE state with UseDirectSsh' -Skip:$script:SkipSshTests {
        $state = New-TestSessionState -UserName $script:SshUser -Location "REMOTE@$($script:SshHost)"
        $state.Flags.UseDirectSsh = $true

        # Clear any prior DOCKER_HOST so the function sets it fresh
        $savedDockerHost = $env:DOCKER_HOST
        $env:DOCKER_HOST = $null
        try {
            Set-DockerSSHEnvironment -State $state
            $env:DOCKER_HOST | Should -BeLike "ssh://*@$($script:SshHost)"
        } finally {
            $env:DOCKER_HOST = $savedDockerHost
        }
    }
}

# -- Test-AndCreateDirectory (local temp) ------------------------------------
Describe 'Test-AndCreateDirectory (local temp)' -Tag 'DockerSsh' {

    It 'Creates a temp directory successfully' -Skip:$script:SkipSshTests {
        $state = New-TestSessionState -Location 'LOCAL'
        $dir = Join-Path ([System.IO.Path]::GetTempPath()) "impact_ci_test_$(Get-Random)"
        try {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            $result = Test-AndCreateDirectory -State $state -Path $dir -PathKey 'test_dir'
            $result | Should -BeTrue
            Test-Path $dir | Should -BeTrue
        } finally {
            Remove-Item $dir -Force -Recurse -ErrorAction SilentlyContinue
        }
    }
}
