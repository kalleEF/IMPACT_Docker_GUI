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
        # Artifact persistence is handled by Invoke-Tests.ps1 (only on failure/skip).
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

# -- Container SSH setup in a real container (F74) ----------------------------
# Runs on every push/PR in the docker-ssh CI job (and with Invoke-Tests -Tag DockerSsh).
# Before, the command that prepares git over SSH inside the RStudio container
# (Get-ContainerSshSetupCommand) was only checked by text matching on push; it ran in
# a real container only in the weekly ImageValidation/RemoteE2E jobs, so a quoting
# mistake could ship. Here the exact command from the module runs as root in a small
# container made from the SSHD test image (Ubuntu with the OpenSSH client), and the
# result is checked. No GitHub token is needed: GitHub checks its host key before it
# looks at the user's key, so 'Permission denied (publickey)' together with
# StrictHostKeyChecking=yes proves that the setup stored github.com's host key.
Describe 'Container SSH setup command in a real container (no token needed)' -Tag 'DockerSsh' {

    BeforeAll {
        $script:SetupImage      = 'impact-sshd-test'
        $script:SetupContainer  = $null
        $script:SetupKeyDir     = $null
        $script:SetupUser       = 'ci'
        $script:SetupSkipReason = $null

        # Same condition as the -Skip switches (BeforeDiscovery values are not available
        # while the tests run, so it is checked again here).
        if (-not ($env:IMPACT_TEST_SSH_HOST -and $env:IMPACT_TEST_SSH_KEY -and (Test-Path $env:IMPACT_TEST_SSH_KEY -ErrorAction SilentlyContinue))) {
            $script:SetupSkipReason = 'IMPACT_TEST_SSH_HOST / IMPACT_TEST_SSH_KEY are not set'
            return
        }
        if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
            $script:SetupSkipReason = 'docker CLI not found'
        } elseif (-not (Get-Command ssh-keygen -ErrorAction SilentlyContinue)) {
            $script:SetupSkipReason = 'ssh-keygen not found'
        } else {
            & docker image inspect $script:SetupImage *> $null
            if ($LASTEXITCODE -ne 0) { $script:SetupSkipReason = "image '$($script:SetupImage)' is not built (CI and Invoke-Tests.ps1 build it)" }
        }
        if ($script:SetupSkipReason) { return }

        # A throw-away key pair that is NOT registered on GitHub. 'Standard' argument
        # passing makes sure the empty passphrase really reaches ssh-keygen.
        $script:SetupKeyDir = Join-Path ([System.IO.Path]::GetTempPath()) "impact_sshsetup_$([guid]::NewGuid().ToString('N').Substring(0,6))"
        New-Item -ItemType Directory -Path $script:SetupKeyDir -Force | Out-Null
        $script:SetupKey = Join-Path $script:SetupKeyDir "id_ed25519_$($script:SetupUser)"
        & { $PSNativeCommandArgumentPassing = 'Standard'; & ssh-keygen -t ed25519 -C 'impact_sshsetup_ci' -f $script:SetupKey -N '' -q } 2>$null | Out-Null
        if (-not (Test-Path -LiteralPath $script:SetupKey)) { $script:SetupSkipReason = 'could not create a test key with ssh-keygen'; return }

        # Same read-only mount as production (/keys/id_ed25519_<user>). The container only
        # sleeps; the commands below run inside it with 'docker exec'.
        $script:SetupContainer = "impact_sshsetup_test_$([guid]::NewGuid().ToString('N').Substring(0,6))"
        $runOut = & docker run -d --rm --name $script:SetupContainer `
            --mount "type=bind,source=$($script:SetupKey),target=/keys/id_ed25519_$($script:SetupUser),readonly" `
            $script:SetupImage sleep 600 2>&1
        if ($LASTEXITCODE -ne 0) { $script:SetupSkipReason = "test container did not start: $runOut"; return }

        # The exact production command, run as root like the GUI does.
        $setupCmd = Get-ContainerSshSetupCommand -UserName $script:SetupUser
        $script:SetupOutput = (& docker exec --user root $script:SetupContainer sh -c $setupCmd 2>&1 | ForEach-Object { "$_" }) -join "`n"
        $script:SetupExit = $LASTEXITCODE
    }

    AfterAll {
        if ($script:SetupContainer) { & docker rm -f $script:SetupContainer *> $null }
        if ($script:SetupKeyDir) { Remove-Item -Recurse -Force -LiteralPath $script:SetupKeyDir -ErrorAction SilentlyContinue }
    }

    It 'Runs to the end and prints KEY_FIXED' -Skip:$script:SkipSshTests {
        if ($script:SetupSkipReason) { Set-ItResult -Skipped -Because $script:SetupSkipReason; return }
        $script:SetupExit | Should -Be 0 -Because "the setup command failed: $($script:SetupOutput)"
        $script:SetupOutput | Should -Match 'KEY_FIXED'
    }

    It 'Copies the key with mode 600, owned by 1000:1000' -Skip:$script:SkipSshTests {
        if ($script:SetupSkipReason) { Set-ItResult -Skipped -Because $script:SetupSkipReason; return }
        $out = & docker exec $script:SetupContainer stat -c '%u:%g %a' "/home/rstudio/.ssh/id_ed25519_$($script:SetupUser)" 2>&1
        "$out".Trim() | Should -Be '1000:1000 600'
    }

    It 'Stores github.com host keys in /home/rstudio/.ssh/known_hosts' -Skip:$script:SkipSshTests {
        if ($script:SetupSkipReason) { Set-ItResult -Skipped -Because $script:SetupSkipReason; return }
        & docker exec $script:SetupContainer ssh-keygen -F github.com -f /home/rstudio/.ssh/known_hosts *> $null
        $found = ($LASTEXITCODE -eq 0)
        if (-not $found) {
            # Tell "the setup is broken" apart from "this machine cannot reach GitHub".
            $probe = & docker exec $script:SetupContainer ssh-keyscan -T 10 github.com 2>$null
            if (-not $probe) { Set-ItResult -Skipped -Because 'github.com is not reachable from this machine, so the host key scan cannot be tested'; return }
        }
        $found | Should -BeTrue -Because 'the setup command must write github.com host keys (ssh-keyscan inside the container)'
    }

    It 'Lets ssh verify github.com with StrictHostKeyChecking=yes (reaches the publickey step)' -Skip:$script:SkipSshTests {
        if ($script:SetupSkipReason) { Set-ItResult -Skipped -Because $script:SetupSkipReason; return }
        # Run as uid 1000, the owner of the copied key (the rstudio user in the real image).
        $out = & docker exec --user 1000:1000 $script:SetupContainer ssh -i "/home/rstudio/.ssh/id_ed25519_$($script:SetupUser)" `
            -o IdentitiesOnly=yes -o UserKnownHostsFile=/home/rstudio/.ssh/known_hosts -o StrictHostKeyChecking=yes `
            -o BatchMode=yes -o ConnectTimeout=15 -T git@github.com 2>&1
        $text = ($out | ForEach-Object { "$_" }) -join "`n"
        if ($text -match 'Could not resolve hostname|Connection timed out|Network is unreachable|ssh: connect to host') {
            Set-ItResult -Skipped -Because "github.com is not reachable from this machine: $text"; return
        }
        $text | Should -Not -Match 'Host key verification failed|REMOTE HOST IDENTIFICATION HAS CHANGED'
        $text | Should -Match 'Permission denied \(publickey\)|successfully authenticated'
    }
}
