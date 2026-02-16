#Requires -Modules Pester

<#
.SYNOPSIS
    Tests that run against a live SSHD Docker container.
    These validate real SSH connectivity and remote-command execution
    using the functions from IMPACT_Docker_GUI.

.DESCRIPTION
    Requires environment variables set by CI or the user:
        IMPACT_TEST_SSH_HOST  (default: localhost)
        IMPACT_TEST_SSH_PORT  (default: 2222)
        IMPACT_TEST_SSH_USER  (default: testuser)
        IMPACT_TEST_SSH_KEY   (path to private key)

    Tag: DockerSsh   — skipped unless all env vars are set.
#>

BeforeAll {
    $modulePath = Join-Path $PSScriptRoot '..' 'current_version' 'IMPACT_Docker_GUI.psm1'
    Import-Module $modulePath -Force

    # Read test parameters from environment
    $script:SshHost = $env:IMPACT_TEST_SSH_HOST
    $script:SshPort = $env:IMPACT_TEST_SSH_PORT ?? '2222'
    $script:SshUser = $env:IMPACT_TEST_SSH_USER ?? 'testuser'
    $script:SshKey  = $env:IMPACT_TEST_SSH_KEY

    $script:SkipSshTests = -not ($script:SshHost -and $script:SshKey -and (Test-Path $script:SshKey -ErrorAction SilentlyContinue))

    if ($script:SkipSshTests) {
        Write-Warning "Docker SSH tests will be skipped — set IMPACT_TEST_SSH_HOST and IMPACT_TEST_SSH_KEY env vars."
    }
}

# ── SSH Connectivity ────────────────────────────────────────────────────────
Describe 'SSH Connectivity to SSHD Container' -Tag 'DockerSsh' {

    It 'Can connect via SSH and run a command' -Skip:$script:SkipSshTests {
        $output = ssh -p $script:SshPort `
            -i $script:SshKey `
            -o StrictHostKeyChecking=no `
            -o UserKnownHostsFile=/dev/null `
            -o BatchMode=yes `
            "$($script:SshUser)@$($script:SshHost)" `
            "echo HELLO_IMPACT" 2>&1

        $output | Should -Contain 'HELLO_IMPACT'
    }

    It 'Can list the fake repository directory' -Skip:$script:SkipSshTests {
        $output = ssh -p $script:SshPort `
            -i $script:SshKey `
            -o StrictHostKeyChecking=no `
            -o UserKnownHostsFile=/dev/null `
            -o BatchMode=yes `
            "$($script:SshUser)@$($script:SshHost)" `
            "ls /home/testuser/Schreibtisch/Repositories/IMPACTncd_Germany" 2>&1

        # The Dockerfile initialises a git repo there, so .git should exist
        ($output -join "`n") | Should -Match '\.git'
    }
}

# ── Get-RemoteHostString ────────────────────────────────────────────────────
Describe 'Get-RemoteHostString against live container' -Tag 'DockerSsh' {

    It 'Returns user@host format correctly' -Skip:$script:SkipSshTests {
        $state = @{ UserName = $script:SshUser; RemoteHost = $script:SshHost }
        $result = Get-RemoteHostString -State $state
        $result | Should -Be "$($script:SshUser)@$($script:SshHost)"
    }
}

# ── Remote Metadata Read/Write ──────────────────────────────────────────────
Describe 'Write-RemoteContainerMetadata via SSH' -Tag 'DockerSsh' {

    BeforeAll {
        $script:metaDir = "/tmp/impact_test_meta_$(Get-Random)"
    }

    It 'Can write metadata file to remote host' -Skip:$script:SkipSshTests {
        # Create the directory on the remote
        ssh -p $script:SshPort `
            -i $script:SshKey `
            -o StrictHostKeyChecking=no `
            -o UserKnownHostsFile=/dev/null `
            -o BatchMode=yes `
            "$($script:SshUser)@$($script:SshHost)" `
            "mkdir -p $($script:metaDir)" 2>&1 | Out-Null

        # Write a test file
        $content = "container_name=test123"
        ssh -p $script:SshPort `
            -i $script:SshKey `
            -o StrictHostKeyChecking=no `
            -o UserKnownHostsFile=/dev/null `
            -o BatchMode=yes `
            "$($script:SshUser)@$($script:SshHost)" `
            "echo '$content' > $($script:metaDir)/metadata.txt" 2>&1 | Out-Null

        # Read it back
        $readBack = ssh -p $script:SshPort `
            -i $script:SshKey `
            -o StrictHostKeyChecking=no `
            -o UserKnownHostsFile=/dev/null `
            -o BatchMode=yes `
            "$($script:SshUser)@$($script:SshHost)" `
            "cat $($script:metaDir)/metadata.txt" 2>&1

        $readBack | Should -Contain $content
    }

    AfterAll {
        if (-not $script:SkipSshTests) {
            ssh -p $script:SshPort `
                -i $script:SshKey `
                -o StrictHostKeyChecking=no `
                -o UserKnownHostsFile=/dev/null `
                -o BatchMode=yes `
                "$($script:SshUser)@$($script:SshHost)" `
                "rm -rf $($script:metaDir)" 2>&1 | Out-Null
        }
    }
}

# ── Set-DockerSSHEnvironment ────────────────────────────────────────────────
Describe 'Set-DockerSSHEnvironment unit validation' -Tag 'DockerSsh' {

    It 'Sets DOCKER_HOST in the state object' -Skip:$script:SkipSshTests {
        $state = @{
            UserName   = $script:SshUser
            RemoteHost = $script:SshHost
        }
        Set-DockerSSHEnvironment -State $state
        $state.DockerHost | Should -BeLike "ssh://$($script:SshUser)@$($script:SshHost)"
    }
}

# ── Test-AndCreateDirectory via SSH ─────────────────────────────────────────
Describe 'Test-AndCreateDirectory (local temp)' -Tag 'DockerSsh' {

    It 'Creates a temp directory successfully' -Skip:$script:SkipSshTests {
        $dir = Join-Path ([System.IO.Path]::GetTempPath()) "impact_ci_test_$(Get-Random)"
        try {
            $result = Test-AndCreateDirectory -Path $dir
            Test-Path $dir | Should -BeTrue
        }
        finally {
            Remove-Item $dir -Force -Recurse -ErrorAction SilentlyContinue
        }
    }
}
