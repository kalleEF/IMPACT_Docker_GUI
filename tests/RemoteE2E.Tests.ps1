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

    Prerequisites:
      - Docker daemon running (with Linux containers)
      - Internet access (clone repo + pull base image)
      - Optional: IMPACT_E2E_GITHUB_TOKEN for SSH auth tests

    Environment variables (set by Invoke-Tests.ps1 or CI):
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

    # Preflight state (NEVER throw in BeforeAll — use flags)
    $script:PreflightFailed = $false
    $script:PreflightMessages = @()

    # Constants
    $script:REPO_URL        = 'https://github.com/IMPACT-NCD-Modeling-Germany/IMPACT-NCD-Germany_Base.git'
    $script:REPO_NAME       = 'IMPACT-NCD-Germany_Base'
    $script:INNER_IMAGE     = 'impactncd_remote_e2e_test'
    $script:INNER_CONTAINER = 'impact_remote_e2e_inner'
    $script:INNER_PORT      = '28787'
    $script:TEST_PASSWORD   = 'RemoteE2ePass!'
    $script:REMOTE_REPO_DIR = "/home/$($script:SshUser)/e2e_repo/$($script:REPO_NAME)"

    # Track last SSH exit code (Where-Object can reset $LASTEXITCODE)
    $script:LastSshExitCode = 0

    # Helper: run a command on the workstation via SSH
    # Captures exit code BEFORE filtering to avoid $LASTEXITCODE being reset.
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
        $script:LastSshExitCode = $LASTEXITCODE
        # Filter known-host addition warnings that pollute output
        $filtered = $result | Where-Object { $_ -notmatch 'Permanently added .* to the list of known hosts' }
        return $filtered
    }
}

Describe 'RemoteE2E: Windows -> SSH -> Workstation -> Docker build/run' -Tag RemoteE2E {

    # ═════════════════════════════════════════════════════════════════════════
    #  Setup: clone repo on workstation, build + start container via SSH
    # ═════════════════════════════════════════════════════════════════════════
    BeforeAll {
        if ($script:SkipTests) { return }

        # ── 1. Verify SSH connectivity ──────────────────────────────────────
        Write-Host '[RemoteE2E] Verifying SSH to workstation ...' -ForegroundColor Cyan
        $echoOut = Invoke-WsSshCommand 'echo REMOTE_OK'
        if ($echoOut -notmatch 'REMOTE_OK') {
            $script:PreflightFailed = $true
            $script:PreflightMessages += "SSH connectivity failed: $($echoOut -join ' ')"
            Write-Host "[RemoteE2E][Preflight] SSH connectivity failed: $($echoOut -join ' ')" -ForegroundColor Red
            return
        }

        # ── 2. Verify Docker CLI works through the socket ───────────────────
        Write-Host '[RemoteE2E] Verifying Docker access on workstation ...' -ForegroundColor Cyan
        $dockerVer = Invoke-WsSshCommand 'docker --version'
        if ($script:LastSshExitCode -ne 0) {
            $script:PreflightFailed = $true
            $script:PreflightMessages += "Docker CLI not available on workstation: $($dockerVer -join ' ')"
            Write-Host "[RemoteE2E][Preflight] Docker CLI not available: $($dockerVer -join ' ')" -ForegroundColor Red
            return
        }
        Write-Host "[RemoteE2E] Workstation Docker: $dockerVer" -ForegroundColor DarkGray

        # ── 3. Clone the real IMPACT repo on the workstation ────────────────
        Write-Host '[RemoteE2E] Cloning repo on workstation ...' -ForegroundColor Cyan
        Invoke-WsSshCommand "rm -rf /home/$($script:SshUser)/e2e_repo" | Out-Null
        Invoke-WsSshCommand "mkdir -p /home/$($script:SshUser)/e2e_repo" | Out-Null
        $cloneOut = Invoke-WsSshCommand "git clone --depth 1 $($script:REPO_URL) $($script:REMOTE_REPO_DIR) 2>&1"
        Write-Host "[RemoteE2E] Clone output: $($cloneOut -join ' ')" -ForegroundColor DarkGray

        $checkClone = Invoke-WsSshCommand "test -f $($script:REMOTE_REPO_DIR)/global.R && echo CLONE_OK"
        if ($checkClone -notmatch 'CLONE_OK') {
            $script:PreflightFailed = $true
            $script:PreflightMessages += 'Repo clone failed on workstation'
            Write-Host "[RemoteE2E][Preflight] Repo clone failed: $($cloneOut -join ' ')" -ForegroundColor Red
            return
        }

        # ── 4. Create output/synthpop dirs ──────────────────────────────────
        Invoke-WsSshCommand "mkdir -p $($script:REMOTE_REPO_DIR)/outputs" | Out-Null
        Invoke-WsSshCommand "mkdir -p $($script:REMOTE_REPO_DIR)/inputs/synthpop" | Out-Null

        # ── 5. Generate SSH key pair on workstation for GitHub auth ──────────
        $script:remoteKeyPath = "/home/$($script:SshUser)/.ssh/id_ed25519_e2e"
        Invoke-WsSshCommand "rm -f $($script:remoteKeyPath) $($script:remoteKeyPath).pub" | Out-Null
        Invoke-WsSshCommand "ssh-keygen -t ed25519 -C 'remote_e2e' -f $($script:remoteKeyPath) -N '' -q" | Out-Null
        Invoke-WsSshCommand "ssh-keyscan -t ed25519 github.com >> /home/$($script:SshUser)/.ssh/known_hosts 2>/dev/null" | Out-Null

        # ── 6. Register SSH key with GitHub (optional) ──────────────────────
        $script:githubKeyId = $null
        if ($env:IMPACT_E2E_GITHUB_TOKEN) {
            Write-Host '[RemoteE2E] Registering SSH key with GitHub ...' -ForegroundColor Cyan
            $pubKey = (Invoke-WsSshCommand "cat $($script:remoteKeyPath).pub") -join ''
            $script:githubKeyId = Add-GitHubSshKey -Token $env:IMPACT_E2E_GITHUB_TOKEN `
                -Title "RemoteE2E-$([guid]::NewGuid().ToString('N').Substring(0,6))" `
                -PublicKey $pubKey.Trim()
        }

        # ── 7. Build Docker image via SSH ───────────────────────────────────
        $script:skipBuild = ($env:IMPACT_E2E_SKIP_BUILD -eq '1')
        if (-not $script:skipBuild) {
            Write-Host '[RemoteE2E] Building Docker image on workstation (this takes 10-30 min) ...' -ForegroundColor Cyan

            $dockerfilePath = "$($script:REMOTE_REPO_DIR)/docker_setup/Dockerfile.IMPACTncdGER"
            $buildCmd = "cd $($script:REMOTE_REPO_DIR) && docker build --build-arg REPO_NAME=$($script:REPO_NAME) -f $dockerfilePath -t $($script:INNER_IMAGE) . 2>&1"
            $buildOut = Invoke-WsSshCommand $buildCmd
            Write-Host "[RemoteE2E] Build output (last 5 lines): $(($buildOut | Select-Object -Last 5) -join "`n")" -ForegroundColor DarkGray

            # Check image exists
            $imgCheck = Invoke-WsSshCommand "docker image inspect $($script:INNER_IMAGE) --format '{{.Id}}' 2>/dev/null"
            if ($script:LastSshExitCode -ne 0 -or -not $imgCheck) {
                # Try prerequisite + retry
                Write-Host '[RemoteE2E] Trying prerequisite build ...' -ForegroundColor Yellow
                $prereqCmd = "cd $($script:REMOTE_REPO_DIR)/docker_setup && docker build -f Dockerfile.prerequisite.IMPACTncdGER -t $($script:INNER_IMAGE)-prerequisite . 2>&1"
                Invoke-WsSshCommand $prereqCmd | Out-Null

                # Tag the locally-built prerequisite image
                $prereqLocalTag = "$($script:INNER_IMAGE)-prerequisite"
                $expectedPrereqName = 'kalleef/prerequisite.impactncdger:latest'
                try {
                    Invoke-WsSshCommand "docker tag $prereqLocalTag $expectedPrereqName" | Out-Null
                } catch {
                    Write-Host "[RemoteE2E] Warning: failed to tag prerequisite image" -ForegroundColor Yellow
                }

                Invoke-WsSshCommand $buildCmd | Out-Null
                $imgCheck2 = Invoke-WsSshCommand "docker image inspect $($script:INNER_IMAGE) --format '{{.Id}}' 2>/dev/null"
                if (-not $imgCheck2) {
                    $script:PreflightFailed = $true
                    $script:PreflightMessages += 'Docker image build failed on workstation.'
                    Write-Host '[RemoteE2E][Preflight] Docker image build failed.' -ForegroundColor Red
                    return
                }
            }
            Write-Host '[RemoteE2E] Image built on workstation.' -ForegroundColor Green
        }

        # ── 8. Start IMPACT container on workstation ────────────────────────
        #
        # DooD (Docker-out-of-Docker) constraint:
        #   Volume mounts (-v) reference the Docker HOST filesystem, not the
        #   workstation container's filesystem.  Since our repo and SSH keys
        #   live inside the workstation container, we CANNOT use -v bind mounts.
        #
        # Strategy:
        #   a) Start the inner container WITHOUT bind-mounts.
        #   b) Use 'docker cp' (which reads from the CLI client's filesystem,
        #      i.e. the workstation container) to copy the repo + SSH key in.
        #   c) Fix ownership/permissions inside the running container.
        #
        Write-Host '[RemoteE2E] Starting IMPACT container on workstation ...' -ForegroundColor Cyan
        Invoke-WsSshCommand "docker stop $($script:INNER_CONTAINER) 2>/dev/null; docker rm $($script:INNER_CONTAINER) 2>/dev/null" | Out-Null

        $containerKeyTarget = '/home/rstudio/.ssh/id_ed25519_e2e'
        $gitSshCmd = "ssh -i $containerKeyTarget -o IdentitiesOnly=yes -o UserKnownHostsFile=/etc/ssh/ssh_known_hosts -o StrictHostKeyChecking=yes"

        # Start container WITHOUT -v mounts (DooD: host paths ≠ workstation paths)
        $runCmd = @(
            "docker run -d --name $($script:INNER_CONTAINER)",
            "-e PASSWORD=$($script:TEST_PASSWORD)",
            "-e DISABLE_AUTH=false",
            "-e USERID=1000 -e GROUPID=1000",
            "-e CONTAINER_REPO_NAME=$($script:REPO_NAME)",
            "-e SYNC_ENABLED=false",
            "-e 'GIT_SSH_COMMAND=$gitSshCmd'",
            "-p $($script:INNER_PORT):8787",
            "--workdir /home/rstudio/$($script:REPO_NAME)",
            $script:INNER_IMAGE
        ) -join ' '

        $runOut = Invoke-WsSshCommand $runCmd
        Write-Host "[RemoteE2E] Container started: $($runOut | Select-Object -First 1)" -ForegroundColor DarkGray

        # Verify container is running before proceeding with docker cp
        $stateCheck = Invoke-WsSshCommand "docker inspect $($script:INNER_CONTAINER) --format '{{.State.Running}}' 2>/dev/null"
        if (($stateCheck -join '') -notmatch 'true') {
            $earlyLogs = Invoke-WsSshCommand "docker logs $($script:INNER_CONTAINER) 2>&1 | tail -10"
            Write-Host "[RemoteE2E] Container not running. Logs:`n$($earlyLogs -join "`n")" -ForegroundColor Red
            $script:PreflightFailed = $true
            $script:PreflightMessages += "Inner container failed to start: $($earlyLogs -join ' ')"
            return
        }

        # ── 8b. Copy repo into container using docker cp ──────────────────
        #    docker cp reads from the CLI client's filesystem (workstation container)
        Write-Host '[RemoteE2E] Copying repository into inner container via docker cp ...' -ForegroundColor Cyan
        $cpRepoCmd = "docker cp $($script:REMOTE_REPO_DIR)/. $($script:INNER_CONTAINER):/home/rstudio/$($script:REPO_NAME)/"
        $cpRepoOut = Invoke-WsSshCommand $cpRepoCmd
        if ($script:LastSshExitCode -ne 0) {
            Write-Host "[RemoteE2E][Diag] docker cp repo failed (exit $($script:LastSshExitCode)): $($cpRepoOut -join ' ')" -ForegroundColor Red
            $script:PreflightFailed = $true
            $script:PreflightMessages += 'Failed to copy repo into inner container'
            return
        }

        # Ensure output/synthpop dirs exist inside the container
        Invoke-WsSshCommand "docker exec $($script:INNER_CONTAINER) mkdir -p /home/rstudio/$($script:REPO_NAME)/outputs /home/rstudio/$($script:REPO_NAME)/inputs/synthpop" | Out-Null

        # ── 8c. Copy SSH key into container ───────────────────────────────
        Write-Host '[RemoteE2E] Copying SSH key into inner container ...' -ForegroundColor Cyan
        # First create the target directory, then copy the key file
        Invoke-WsSshCommand "docker exec $($script:INNER_CONTAINER) mkdir -p /home/rstudio/.ssh" | Out-Null
        $cpKeyCmd = "docker cp $($script:remoteKeyPath) $($script:INNER_CONTAINER):$containerKeyTarget"
        $cpKeyOut = Invoke-WsSshCommand $cpKeyCmd
        if ($script:LastSshExitCode -ne 0) {
            Write-Host "[RemoteE2E][Diag] docker cp key failed (exit $($script:LastSshExitCode)): $($cpKeyOut -join ' ')" -ForegroundColor Red
        }

        # ── 8d. Fix ownership + set up SSH known hosts ────────────────────
        $fixCmd = @(
            "docker exec $($script:INNER_CONTAINER) sh -c '",
            "chown -R 1000:1000 /home/rstudio/$($script:REPO_NAME) &&",
            "chmod 600 $containerKeyTarget &&",
            "chown 1000:1000 $containerKeyTarget &&",
            "ssh-keyscan -t ed25519 github.com > /etc/ssh/ssh_known_hosts 2>/dev/null;",
            "cp /etc/ssh/ssh_known_hosts /home/rstudio/.ssh/known_hosts 2>/dev/null;",
            "chown -R 1000:1000 /home/rstudio/.ssh;",
            "echo KEY_FIXED'"
        ) -join ' '
        $fixOut = Invoke-WsSshCommand $fixCmd
        if (($fixOut -join '') -notmatch 'KEY_FIXED') {
            Write-Host "[RemoteE2E][Diag] SSH key/ownership fix may have failed: $($fixOut -join ' ')" -ForegroundColor Yellow
        } else {
            Write-Host '[RemoteE2E] Repo + SSH key copied and permissions fixed.' -ForegroundColor DarkGray
        }

        # ── 9. Wait for RStudio Server ──────────────────────────────────────
        #   DooD constraint: -p maps ports on the Docker HOST, not on the
        #   workstation container.  We need the inner container's IP to
        #   reach RStudio from inside the workstation.
        $innerIp = (Invoke-WsSshCommand "docker inspect $($script:INNER_CONTAINER) --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' 2>/dev/null") -join ''
        $innerIp = $innerIp.Trim()
        if (-not $innerIp) {
            Write-Host '[RemoteE2E][Diag] Could not determine inner container IP' -ForegroundColor Yellow
            $innerIp = 'localhost'    # fallback, may not work in DooD
        }
        $script:INNER_URL = "http://${innerIp}:8787"
        Write-Host "[RemoteE2E] Waiting for RStudio Server at $($script:INNER_URL) ..." -ForegroundColor Cyan

        $ready = $false
        for ($i = 0; $i -lt 60; $i++) {
            Start-Sleep -Seconds 2
            $curlOut = Invoke-WsSshCommand "curl -s -o /dev/null -w '%{http_code}' $($script:INNER_URL) 2>/dev/null"
            if ($curlOut -match '200|302|401|403') { $ready = $true; break }
        }
        if (-not $ready) {
            $logs = Invoke-WsSshCommand "docker logs $($script:INNER_CONTAINER) 2>&1 | tail -20"
            Write-Host "[RemoteE2E] Container logs:`n$($logs -join "`n")" -ForegroundColor Red
            # Also check if container is even running
            $runState = Invoke-WsSshCommand "docker inspect $($script:INNER_CONTAINER) --format '{{.State.Status}}' 2>/dev/null"
            Write-Host "[RemoteE2E] Container state: $($runState -join '')" -ForegroundColor Red
            $script:PreflightFailed = $true
            $script:PreflightMessages += 'RStudio Server did not start within 120s on workstation.'
            Write-Host '[RemoteE2E][Preflight] RStudio not ready within 120s.' -ForegroundColor Red
            return
        }
        Write-Host '[RemoteE2E] RStudio Server ready on workstation.' -ForegroundColor Green
    }

    AfterAll {
        if ($script:SkipTests) { return }

        # Artifact persistence is handled by Invoke-Tests.ps1 (only on failure/skip).
        Write-Host '[RemoteE2E] Cleaning up ...' -ForegroundColor Cyan
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

    # ═════════════════════════════════════════════════════════════════════════
    #  Preflight
    # ═════════════════════════════════════════════════════════════════════════
    It 'Preflight: required environment and connectivity' -Skip:$script:SkipTests {
        $script:PreflightFailed | Should -BeFalse -Because ($script:PreflightMessages -join '; ')
    }

    # ═════════════════════════════════════════════════════════════════════════
    #  SSH connectivity
    # ═════════════════════════════════════════════════════════════════════════
    It 'Can connect to workstation via SSH' -Skip:$script:SkipTests {
        if (-not (Assert-PreflightPassed)) { return }
        $out = Invoke-WsSshCommand 'echo HELLO'
        $out | Should -Contain 'HELLO'
    }

    # ═════════════════════════════════════════════════════════════════════════
    #  Module function: Get-RemoteHostString
    # ═════════════════════════════════════════════════════════════════════════
    It 'Get-RemoteHostString returns correct host string' -Skip:$script:SkipTests {
        if (-not (Assert-PreflightPassed)) { return }
        $state = New-TestSessionState -UserName $script:SshUser -Location "REMOTE@$($script:SshHost)"
        $state.RemoteHost = "$($script:SshUser)@$($script:SshHost)"
        $result = Get-RemoteHostString -State $state
        $result | Should -Be "$($script:SshUser)@$($script:SshHost)"
    }

    # ═════════════════════════════════════════════════════════════════════════
    #  Docker commands work via SSH
    # ═════════════════════════════════════════════════════════════════════════
    It 'Docker CLI is accessible through SSH tunnel' -Skip:$script:SkipTests {
        if (-not (Assert-PreflightPassed)) { return }
        $out = Invoke-WsSshCommand 'docker --version'
        $out | Should -Match 'Docker version'
    }

    It 'Can list running containers on workstation' -Skip:$script:SkipTests {
        if (-not (Assert-PreflightPassed)) { return }
        $out = Invoke-WsSshCommand "docker ps --filter name=$($script:INNER_CONTAINER) --format '{{.Names}}'"
        ($out -join '') | Should -Match $script:INNER_CONTAINER
    }

    # ═════════════════════════════════════════════════════════════════════════
    #  IMPACT container validation via SSH
    # ═════════════════════════════════════════════════════════════════════════
    It 'RStudio Server is accessible from workstation' -Skip:$script:SkipTests {
        if (-not (Assert-PreflightPassed)) { return }
        # Use container IP directly (DooD: port maps land on Docker host, not workstation)
        $out = Invoke-WsSshCommand "curl -s -o /dev/null -w '%{http_code}' $($script:INNER_URL)"
        if ($script:LastSshExitCode -ne 0) {
            Write-Host "[RemoteE2E][Diag] curl failed (exit $($script:LastSshExitCode)): $($out -join ' ')" -ForegroundColor Yellow
        }
        $out | Should -Match '200|302'
    }

    It 'Repository is mounted inside the IMPACT container' -Skip:$script:SkipTests {
        if (-not (Assert-PreflightPassed)) { return }
        $out = Invoke-WsSshCommand "docker exec $($script:INNER_CONTAINER) ls /home/rstudio/$($script:REPO_NAME)"
        ($out -join "`n") | Should -Match 'global\.R'
        ($out -join "`n") | Should -Match 'docker_setup'
    }

    It 'R is available in the IMPACT container' -Skip:$script:SkipTests {
        if (-not (Assert-PreflightPassed)) { return }
        $out = Invoke-WsSshCommand "docker exec $($script:INNER_CONTAINER) R --version 2>&1 | head -1"
        ($out -join '') | Should -Match 'R version'
    }

    It 'global.R can be sourced inside the IMPACT container' -Skip:$script:SkipTests {
        if (-not (Assert-PreflightPassed)) { return }

        # Use base64 encoding to safely pass the R script through
        # PowerShell -> SSH -> bash -> docker exec -> Rscript layers
        $rScript = @"
setwd("/home/rstudio/$($script:REPO_NAME)")
tryCatch({
    source("global.R")
    cat("GLOBAL_OK")
}, error = function(e) {
    cat(paste("GLOBAL_ERROR:", e`$message))
})
"@
        $b64 = ConvertTo-Base64Script -Script $rScript

        # Write the R script inside the inner container via SSH + docker exec
        $writeCmd = "docker exec $($script:INNER_CONTAINER) sh -c 'echo $b64 | base64 -d > /tmp/_e2e_global_test.R'"
        Invoke-WsSshCommand $writeCmd | Out-Null

        # Run the R script
        $runCmd = "docker exec --user rstudio $($script:INNER_CONTAINER) Rscript /tmp/_e2e_global_test.R"
        $out = Invoke-WsSshCommand $runCmd
        $joined = $out -join "`n"
        $joined | Should -Match 'GLOBAL_OK'
        $joined | Should -Not -Match 'GLOBAL_ERROR'
    }

    # ═════════════════════════════════════════════════════════════════════════
    #  GitHub SSH auth (requires token)
    # ═════════════════════════════════════════════════════════════════════════
    It 'Can authenticate to GitHub via SSH from inside the IMPACT container' -Skip:($script:SkipTests -or -not $env:IMPACT_E2E_GITHUB_TOKEN) {
        if (-not (Assert-PreflightPassed)) { return }
        $cmd = "docker exec --user rstudio $($script:INNER_CONTAINER) ssh -i /home/rstudio/.ssh/id_ed25519_e2e -o IdentitiesOnly=yes -o UserKnownHostsFile=/home/rstudio/.ssh/known_hosts -o StrictHostKeyChecking=yes -T git@github.com 2>&1"
        $out = Invoke-WsSshCommand $cmd
        ($out -join "`n") | Should -Match 'successfully authenticated'
    }

    It 'Can execute git pull from inside the IMPACT container' -Skip:($script:SkipTests -or -not $env:IMPACT_E2E_GITHUB_TOKEN) {
        if (-not (Assert-PreflightPassed)) { return }
        # Mark the copied repo as safe (ownership differs from rstudio user)
        Invoke-WsSshCommand "docker exec --user rstudio $($script:INNER_CONTAINER) git config --global --add safe.directory /home/rstudio/$($script:REPO_NAME)" | Out-Null

        $cmd = "docker exec --user rstudio --workdir /home/rstudio/$($script:REPO_NAME) $($script:INNER_CONTAINER) git pull 2>&1"
        $out = Invoke-WsSshCommand $cmd
        ($out -join "`n") | Should -Match 'Already up to date|Updating|Fast-forward|Merge made'
    }
}
