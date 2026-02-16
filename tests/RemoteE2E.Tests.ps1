#Requires -Modules Pester

<#
.SYNOPSIS
    Remote End-to-End tests: simulates the full Windows -> SSH -> Linux
    workstation -> Docker build/run flow.

    Uses a "workstation" container (Ubuntu + Docker CLI + SSHD) with the
    Docker socket mounted (Docker-out-of-Docker). The test script connects
    via SSH, clones the real IMPACT repo, builds the Docker image through
    the SSH tunnel, starts the IMPACT container, and validates the full
    lifecycle.

    This mirrors exactly what the IMPACT Docker GUI does when a user
    connects to a remote Linux workstation.

    Prerequisites:
      - Docker daemon running (with Linux containers)
      - Internet access (clone repo + pull base image)
      - Optional: IMPACT_E2E_GITHUB_TOKEN for SSH auth tests inside the
        inner container

    Environment variables (set by Run-AllTests.ps1 or CI):
      IMPACT_REMOTE_E2E_SSH_HOST  - default: localhost
      IMPACT_REMOTE_E2E_SSH_PORT  - default: 2222
      IMPACT_REMOTE_E2E_SSH_USER  - default: testuser
      IMPACT_REMOTE_E2E_SSH_KEY   - path to private key

    Tag: RemoteE2E
#>

BeforeDiscovery {
    $script:SshHost = if ($env:IMPACT_REMOTE_E2E_SSH_HOST) { $env:IMPACT_REMOTE_E2E_SSH_HOST } else { 'localhost' }
    $script:SshPort = if ($env:IMPACT_REMOTE_E2E_SSH_PORT) { $env:IMPACT_REMOTE_E2E_SSH_PORT } else { '2222' }
    $script:SshUser = if ($env:IMPACT_REMOTE_E2E_SSH_USER) { $env:IMPACT_REMOTE_E2E_SSH_USER } else { 'testuser' }
    $script:SshKey  = $env:IMPACT_REMOTE_E2E_SSH_KEY

    $script:SkipTests = -not ($script:SshHost -and $script:SshKey -and (Test-Path $script:SshKey -ErrorAction SilentlyContinue))

    if ($script:SkipTests) {
        Write-Warning "RemoteE2E tests will be skipped - set IMPACT_REMOTE_E2E_SSH_KEY env var."
    }
}

BeforeAll {
    $modulePath = Join-Path $PSScriptRoot '..' 'current_version' 'IMPACT_Docker_GUI.psm1'
    Import-Module $modulePath -Force -DisableNameChecking
    . (Join-Path $PSScriptRoot 'Helpers' 'TestSessionState.ps1')

    # Re-read env vars in run scope
    $script:SshHost = if ($env:IMPACT_REMOTE_E2E_SSH_HOST) { $env:IMPACT_REMOTE_E2E_SSH_HOST } else { 'localhost' }
    $script:SshPort = if ($env:IMPACT_REMOTE_E2E_SSH_PORT) { $env:IMPACT_REMOTE_E2E_SSH_PORT } else { '2222' }
    $script:SshUser = if ($env:IMPACT_REMOTE_E2E_SSH_USER) { $env:IMPACT_REMOTE_E2E_SSH_USER } else { 'testuser' }
    $script:SshKey  = $env:IMPACT_REMOTE_E2E_SSH_KEY

    # Constants
    $script:REPO_URL        = 'https://github.com/IMPACT-NCD-Modeling-Germany/IMPACT-NCD-Germany_Base.git'
    $script:REPO_NAME       = 'IMPACT-NCD-Germany_Base'
    $script:INNER_IMAGE     = 'impactncd_remote_e2e_test'
    $script:INNER_CONTAINER = 'impact_remote_e2e_inner'
    $script:INNER_PORT      = '28787'
    $script:TEST_PASSWORD   = 'RemoteE2ePass!'
    $script:REMOTE_REPO_DIR = "/home/$($script:SshUser)/e2e_repo/$($script:REPO_NAME)"

    # Helper: run a command on the workstation via SSH
    function Invoke-WsSshCommand {
        param([string]$Command)
        $sshArgs = @(
            '-p', $script:SshPort,
            '-i', $script:SshKey,
            '-o', 'StrictHostKeyChecking=no',
            '-o', 'UserKnownHostsFile=/dev/null',
            '-o', 'BatchMode=yes',
            '-o', 'IdentitiesOnly=yes',
            '-o', 'ConnectTimeout=10',
            "$($script:SshUser)@$($script:SshHost)",
            $Command
        )
        $result = & ssh @sshArgs 2>&1
        return $result
    }
}

Describe 'RemoteE2E: Windows -> SSH -> Workstation -> Docker build/run' -Tag RemoteE2E {

    # ═════════════════════════════════════════════════════════════════════
    #  Setup: clone repo on workstation, build + start container via SSH
    # ═════════════════════════════════════════════════════════════════════
    BeforeAll {
        if ($script:SkipTests) { return }

        # ── 1. Verify SSH connectivity ───────────────────────────────────
        Write-Host "[RemoteE2E] Verifying SSH to workstation ..." -ForegroundColor Cyan
        $echoOut = Invoke-WsSshCommand 'echo REMOTE_OK'
        if ($echoOut -notmatch 'REMOTE_OK') {
            throw "SSH connectivity failed: $echoOut"
        }

        # ── 2. Verify Docker CLI works through the socket ────────────────
        Write-Host "[RemoteE2E] Verifying Docker access on workstation ..." -ForegroundColor Cyan
        $dockerVer = Invoke-WsSshCommand 'docker --version'
        if ($LASTEXITCODE -ne 0) { throw "Docker CLI not available on workstation: $dockerVer" }
        Write-Host "[RemoteE2E] Workstation Docker: $dockerVer" -ForegroundColor DarkGray

        # ── 3. Clone the real IMPACT repo on the workstation ─────────────
        Write-Host "[RemoteE2E] Cloning repo on workstation ..." -ForegroundColor Cyan
        Invoke-WsSshCommand "rm -rf /home/$($script:SshUser)/e2e_repo" | Out-Null
        Invoke-WsSshCommand "mkdir -p /home/$($script:SshUser)/e2e_repo" | Out-Null
        $cloneOut = Invoke-WsSshCommand "git clone --depth 1 $($script:REPO_URL) $($script:REMOTE_REPO_DIR) 2>&1"
        Write-Host "[RemoteE2E] Clone output: $($cloneOut -join ' ')" -ForegroundColor DarkGray

        # Verify clone succeeded
        $checkClone = Invoke-WsSshCommand "test -f $($script:REMOTE_REPO_DIR)/global.R && echo CLONE_OK"
        if ($checkClone -notmatch 'CLONE_OK') {
            throw "Repo clone failed on workstation: $($cloneOut -join "`n")"
        }

        # ── 4. Create output/synthpop dirs ───────────────────────────────
        Invoke-WsSshCommand "mkdir -p $($script:REMOTE_REPO_DIR)/outputs" | Out-Null
        Invoke-WsSshCommand "mkdir -p $($script:REMOTE_REPO_DIR)/inputs/synthpop" | Out-Null

        # ── 5. Generate SSH key pair on workstation for GitHub auth ──────
        $script:remoteKeyPath = "/home/$($script:SshUser)/.ssh/id_ed25519_e2e"
        Invoke-WsSshCommand "rm -f $($script:remoteKeyPath) $($script:remoteKeyPath).pub" | Out-Null
        Invoke-WsSshCommand "ssh-keygen -t ed25519 -C 'remote_e2e' -f $($script:remoteKeyPath) -N '' -q" | Out-Null
        Invoke-WsSshCommand "ssh-keyscan -t ed25519 github.com >> /home/$($script:SshUser)/.ssh/known_hosts 2>/dev/null" | Out-Null

        # ── 6. Register SSH key with GitHub (optional) ───────────────────
        $script:githubKeyId = $null
        if ($env:IMPACT_E2E_GITHUB_TOKEN) {
            Write-Host "[RemoteE2E] Registering SSH key with GitHub ..." -ForegroundColor Cyan
            $pubKey = (Invoke-WsSshCommand "cat $($script:remoteKeyPath).pub") -join ''
            $script:githubKeyId = Add-GitHubSshKey -Token $env:IMPACT_E2E_GITHUB_TOKEN `
                -Title "RemoteE2E-$([guid]::NewGuid().ToString('N').Substring(0,6))" `
                -PublicKey $pubKey.Trim()
        }

        # ── 7. Build Docker image via SSH ────────────────────────────────
        $script:skipBuild = ($env:IMPACT_E2E_SKIP_BUILD -eq '1')
        if (-not $script:skipBuild) {
            Write-Host "[RemoteE2E] Building Docker image on workstation (this takes 10-30 min) ..." -ForegroundColor Cyan

            $dockerfilePath = "$($script:REMOTE_REPO_DIR)/docker_setup/Dockerfile.IMPACTncdGER"
            $buildCmd = "cd $($script:REMOTE_REPO_DIR) && docker build --build-arg REPO_NAME=$($script:REPO_NAME) -f $dockerfilePath -t $($script:INNER_IMAGE) --progress=plain . 2>&1"
            $buildOut = Invoke-WsSshCommand $buildCmd
            Write-Host "[RemoteE2E] Build output (last 5 lines): $(($buildOut | Select-Object -Last 5) -join "`n")" -ForegroundColor DarkGray

            # Check image exists
            $imgCheck = Invoke-WsSshCommand "docker image inspect $($script:INNER_IMAGE) --format '{{.Id}}' 2>/dev/null"
            if ($LASTEXITCODE -ne 0 -or -not $imgCheck) {
                # Try prerequisite + retry
                Write-Host "[RemoteE2E] Trying prerequisite build ..." -ForegroundColor Yellow
                $prereqCmd = "cd $($script:REMOTE_REPO_DIR)/docker_setup && docker build -f Dockerfile.prerequisite.IMPACTncdGER -t $($script:INNER_IMAGE)-prerequisite --progress=plain . 2>&1"
                Invoke-WsSshCommand $prereqCmd | Out-Null
                Invoke-WsSshCommand $buildCmd | Out-Null
                $imgCheck2 = Invoke-WsSshCommand "docker image inspect $($script:INNER_IMAGE) --format '{{.Id}}' 2>/dev/null"
                if (-not $imgCheck2) { throw 'Docker image build failed on workstation.' }
            }
            Write-Host "[RemoteE2E] Image built on workstation." -ForegroundColor Green
        }

        # ── 8. Start IMPACT container on workstation ─────────────────────
        Write-Host "[RemoteE2E] Starting IMPACT container on workstation ..." -ForegroundColor Cyan
        Invoke-WsSshCommand "docker stop $($script:INNER_CONTAINER) 2>/dev/null; docker rm $($script:INNER_CONTAINER) 2>/dev/null" | Out-Null

        $containerKeyTarget = "/home/rstudio/.ssh/id_ed25519_e2e"
        $runCmd = @(
            "docker run -d --name $($script:INNER_CONTAINER)",
            "-e PASSWORD=$($script:TEST_PASSWORD)",
            "-e DISABLE_AUTH=false",
            "-e USERID=1000 -e GROUPID=1000",
            "-e `"GIT_SSH_COMMAND=ssh -i $containerKeyTarget -o IdentitiesOnly=yes -o UserKnownHostsFile=/etc/ssh/ssh_known_hosts -o StrictHostKeyChecking=yes`"",
            "-v $($script:REMOTE_REPO_DIR):/host-repo",
            "-v $($script:REMOTE_REPO_DIR):/home/rstudio/$($script:REPO_NAME)",
            "-p $($script:INNER_PORT):8787",
            "-v $($script:REMOTE_REPO_DIR)/outputs:/home/rstudio/$($script:REPO_NAME)/outputs",
            "-v $($script:REMOTE_REPO_DIR)/inputs/synthpop:/home/rstudio/$($script:REPO_NAME)/inputs/synthpop",
            "-v $($script:remoteKeyPath):/keys/id_ed25519_e2e:ro",
            "--workdir /home/rstudio/$($script:REPO_NAME)",
            $script:INNER_IMAGE
        ) -join ' '

        $runOut = Invoke-WsSshCommand $runCmd
        Write-Host "[RemoteE2E] Container started: $($runOut | Select-Object -First 1)" -ForegroundColor DarkGray

        # Fix SSH key inside inner container
        $fixCmd = "docker exec $($script:INNER_CONTAINER) sh -c 'mkdir -p /home/rstudio/.ssh && cp /keys/id_ed25519_e2e $containerKeyTarget && chmod 600 $containerKeyTarget && chown 1000:1000 $containerKeyTarget && ssh-keyscan -t ed25519 github.com > /etc/ssh/ssh_known_hosts 2>/dev/null && cp /etc/ssh/ssh_known_hosts /home/rstudio/.ssh/known_hosts 2>/dev/null; chown 1000:1000 /home/rstudio/.ssh/known_hosts 2>/dev/null; echo KEY_FIXED'"
        Invoke-WsSshCommand $fixCmd | Out-Null

        # ── 9. Wait for RStudio Server ───────────────────────────────────
        Write-Host "[RemoteE2E] Waiting for RStudio Server on port $($script:INNER_PORT) ..." -ForegroundColor Cyan
        $ready = $false
        for ($i = 0; $i -lt 60; $i++) {
            Start-Sleep -Seconds 2
            # curl from inside the workstation to check RStudio
            $curlOut = Invoke-WsSshCommand "curl -s -o /dev/null -w '%{http_code}' http://localhost:$($script:INNER_PORT) 2>/dev/null"
            if ($curlOut -match '200|302') { $ready = $true; break }
        }
        if (-not $ready) {
            $logs = Invoke-WsSshCommand "docker logs $($script:INNER_CONTAINER) 2>&1 | tail -20"
            Write-Host "[RemoteE2E] Container logs:`n$($logs -join "`n")" -ForegroundColor Red
            throw 'RStudio Server did not start within 120s on workstation.'
        }
        Write-Host "[RemoteE2E] RStudio Server ready on workstation." -ForegroundColor Green
    }

    AfterAll {
        if ($script:SkipTests) { return }

        Write-Host "[RemoteE2E] Cleaning up ..." -ForegroundColor Cyan
        Invoke-WsSshCommand "docker stop $($script:INNER_CONTAINER) 2>/dev/null; docker rm $($script:INNER_CONTAINER) 2>/dev/null" | Out-Null

        if ($script:githubKeyId -and $env:IMPACT_E2E_GITHUB_TOKEN) {
            try { Remove-GitHubSshKey -Token $env:IMPACT_E2E_GITHUB_TOKEN -KeyId $script:githubKeyId } catch {}
        }

        if ($env:IMPACT_E2E_KEEP_ARTIFACTS -ne '1') {
            Invoke-WsSshCommand "docker rmi $($script:INNER_IMAGE) 2>/dev/null" | Out-Null
            Invoke-WsSshCommand "rm -rf /home/$($script:SshUser)/e2e_repo" | Out-Null
            Invoke-WsSshCommand "rm -f $($script:remoteKeyPath) $($script:remoteKeyPath).pub" | Out-Null
        }
    }

    # ═════════════════════════════════════════════════════════════════════
    #  SSH connectivity
    # ═════════════════════════════════════════════════════════════════════
    It 'Can connect to workstation via SSH' -Skip:$script:SkipTests {
        $out = Invoke-WsSshCommand 'echo HELLO'
        $out | Should -Contain 'HELLO'
    }

    # ═════════════════════════════════════════════════════════════════════
    #  Module function: Get-RemoteHostString
    # ═════════════════════════════════════════════════════════════════════
    It 'Get-RemoteHostString returns correct host string' -Skip:$script:SkipTests {
        $state = New-TestSessionState -UserName $script:SshUser -Location "REMOTE@$($script:SshHost)"
        $state.RemoteHost = "$($script:SshUser)@$($script:SshHost)"
        $result = Get-RemoteHostString -State $state
        $result | Should -Be "$($script:SshUser)@$($script:SshHost)"
    }

    # ═════════════════════════════════════════════════════════════════════
    #  Docker commands work via SSH
    # ═════════════════════════════════════════════════════════════════════
    It 'Docker CLI is accessible through SSH tunnel' -Skip:$script:SkipTests {
        $out = Invoke-WsSshCommand 'docker --version'
        $out | Should -Match 'Docker version'
    }

    It 'Can list running containers on workstation' -Skip:$script:SkipTests {
        $out = Invoke-WsSshCommand "docker ps --filter name=$($script:INNER_CONTAINER) --format '{{.Names}}'"
        ($out -join '') | Should -Match $script:INNER_CONTAINER
    }

    # ═════════════════════════════════════════════════════════════════════
    #  IMPACT container validation via SSH
    # ═════════════════════════════════════════════════════════════════════
    It 'RStudio Server is accessible from workstation' -Skip:$script:SkipTests {
        $out = Invoke-WsSshCommand "curl -s -o /dev/null -w '%{http_code}' http://localhost:$($script:INNER_PORT)"
        $out | Should -Match '200|302'
    }

    It 'Repository is mounted inside the IMPACT container' -Skip:$script:SkipTests {
        $out = Invoke-WsSshCommand "docker exec $($script:INNER_CONTAINER) ls /home/rstudio/$($script:REPO_NAME)"
        ($out -join "`n") | Should -Match 'global\.R'
        ($out -join "`n") | Should -Match 'docker_setup'
    }

    It 'R is available in the IMPACT container' -Skip:$script:SkipTests {
        $out = Invoke-WsSshCommand "docker exec $($script:INNER_CONTAINER) R --version 2>&1 | head -1"
        ($out -join '') | Should -Match 'R version'
    }

    It 'global.R can be sourced inside the IMPACT container' -Skip:$script:SkipTests {
        $cmd = "docker exec --user rstudio $($script:INNER_CONTAINER) Rscript -e `"setwd('/home/rstudio/$($script:REPO_NAME)'); tryCatch({ source('global.R'); cat('GLOBAL_OK') }, error = function(e) cat(paste('GLOBAL_ERROR:', e\`\$message)))`""
        $out = Invoke-WsSshCommand $cmd
        $joined = $out -join "`n"
        $joined | Should -Match 'GLOBAL_OK'
        $joined | Should -Not -Match 'GLOBAL_ERROR'
    }

    # ═════════════════════════════════════════════════════════════════════
    #  GitHub SSH auth (requires token)
    # ═════════════════════════════════════════════════════════════════════
    It 'Can authenticate to GitHub via SSH from inside the IMPACT container' -Skip:($script:SkipTests -or -not $env:IMPACT_E2E_GITHUB_TOKEN) {
        $cmd = "docker exec --user rstudio $($script:INNER_CONTAINER) ssh -i /home/rstudio/.ssh/id_ed25519_e2e -o IdentitiesOnly=yes -o UserKnownHostsFile=/home/rstudio/.ssh/known_hosts -o StrictHostKeyChecking=yes -T git@github.com 2>&1"
        $out = Invoke-WsSshCommand $cmd
        ($out -join "`n") | Should -Match 'successfully authenticated'
    }

    It 'Can execute git pull from inside the IMPACT container' -Skip:($script:SkipTests -or -not $env:IMPACT_E2E_GITHUB_TOKEN) {
        $cmd = "docker exec --user rstudio --workdir /home/rstudio/$($script:REPO_NAME) $($script:INNER_CONTAINER) git pull 2>&1"
        $out = Invoke-WsSshCommand $cmd
        ($out -join "`n") | Should -Match 'Already up to date|Updating|Fast-forward|Merge made'
    }
}
