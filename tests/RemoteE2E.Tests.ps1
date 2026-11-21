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
        # The key has the same name the GUI uses on the workstation:
        # ~/.ssh/id_ed25519_<user>, with <user> = 'e2e' in this suite.
        $script:E2E_USER = 'e2e'
        $script:remoteKeyPath = "/home/$($script:SshUser)/.ssh/id_ed25519_$($script:E2E_USER)"
        Invoke-WsSshCommand "rm -f $($script:remoteKeyPath) $($script:remoteKeyPath).pub" | Out-Null
        Invoke-WsSshCommand "ssh-keygen -t ed25519 -C 'remote_e2e' -f $($script:remoteKeyPath) -N '' -q" | Out-Null
        # (F70) No ssh-keyscan of github.com here any more. It pre-filled host keys that
        # the production code never writes for the container, so a broken in-container
        # known_hosts setup could not be noticed. The container's known_hosts now comes
        # only from Get-ContainerSshSetupCommand (step 8d), exactly as in production.

        # The GUI starts the container with the uid/gid of the workstation account
        # (USERID/GROUPID), so the rstudio user owns the bind-mounted files. Do the same.
        $script:ContainerUid = "$((Invoke-WsSshCommand 'id -u') | Select-Object -First 1)".Trim()
        $script:ContainerGid = "$((Invoke-WsSshCommand 'id -g') | Select-Object -First 1)".Trim()
        if ($script:ContainerUid -notmatch '^\d+$' -or $script:ContainerGid -notmatch '^\d+$') {
            Write-Host "[RemoteE2E][Diag] Could not read uid/gid on the workstation ('$($script:ContainerUid)'/'$($script:ContainerGid)'); using 1000:1000" -ForegroundColor Yellow
            $script:ContainerUid = '1000'
            $script:ContainerGid = '1000'
        }

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

        # (F70) GIT_SSH_COMMAND is the exact value the GUI uses in production
        # (Get-ContainerGitSshCommand). It used to be a test-only command with
        # /etc/ssh/ssh_known_hosts and StrictHostKeyChecking=yes, so the weekly run never
        # tested what users get. The value contains no single quote, so it can be wrapped
        # in '...' for the workstation's shell; the check below makes sure of that.
        $gitSshCmd = Get-ContainerGitSshCommand -UserName $script:E2E_USER
        if ($gitSshCmd.Contains("'")) { throw "GIT_SSH_COMMAND contains a single quote and cannot be quoted for the remote shell: $gitSshCmd" }

        # Start container WITHOUT -v mounts (DooD: host paths differ from workstation paths)
        $runCmd = @(
            "docker run -d --name $($script:INNER_CONTAINER)",
            "-e PASSWORD=$($script:TEST_PASSWORD)",
            "-e DISABLE_AUTH=false",
            "-e USERID=$($script:ContainerUid) -e GROUPID=$($script:ContainerGid)",
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
        # In production the key is bind-mounted read-only at /keys/id_ed25519_<user>,
        # and Get-ContainerSshSetupCommand copies it from there into ~rstudio/.ssh.
        # DooD cannot bind-mount it, so 'docker cp' puts it at the same /keys path.
        Write-Host '[RemoteE2E] Copying SSH key into inner container ...' -ForegroundColor Cyan
        Invoke-WsSshCommand "docker exec --user root $($script:INNER_CONTAINER) mkdir -p /keys" | Out-Null
        $cpKeyCmd = "docker cp $($script:remoteKeyPath) $($script:INNER_CONTAINER):/keys/id_ed25519_$($script:E2E_USER)"
        $cpKeyOut = Invoke-WsSshCommand $cpKeyCmd
        if ($script:LastSshExitCode -ne 0) {
            Write-Host "[RemoteE2E][Diag] docker cp key failed (exit $($script:LastSshExitCode)): $($cpKeyOut -join ' ')" -ForegroundColor Red
        }

        # ── 8d. Fix repo ownership + run the PRODUCTION SSH setup ─────────
        # The repo chown is only needed because DooD copies the repo in with 'docker cp'
        # (production bind-mounts it). The SSH part is exactly the command the GUI runs:
        # key copy, github.com host keys via ssh-keyscan inside the container, chown to
        # the account's uid/gid, then KEY_FIXED. It contains single quotes, so it is sent
        # base64-encoded through the PowerShell -> ssh -> sh -> docker exec layers.
        $setupCmd = "chown -R $($script:ContainerUid):$($script:ContainerGid) /home/rstudio/$($script:REPO_NAME) && " +
            (Get-ContainerSshSetupCommand -UserName $script:E2E_USER -ContainerUid $script:ContainerUid -ContainerGid $script:ContainerGid)
        $setupB64 = ConvertTo-Base64Script -Script $setupCmd
        $fixCmd = "docker exec --user root $($script:INNER_CONTAINER) sh -c 'echo $setupB64 | base64 -d | sh'"
        $script:KeySetupOutput = (Invoke-WsSshCommand $fixCmd) -join "`n"
        if ($script:KeySetupOutput -notmatch 'KEY_FIXED') {
            # Reported by its own test below, so the remaining tests still run.
            Write-Host "[RemoteE2E][Diag] Production SSH setup did not print KEY_FIXED: $($script:KeySetupOutput)" -ForegroundColor Yellow
        } else {
            Write-Host '[RemoteE2E] Repo copied; production SSH setup finished (KEY_FIXED).' -ForegroundColor DarkGray
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
    #  Production SSH setup inside the container (no token needed, F70)
    # ═════════════════════════════════════════════════════════════════════════
    It 'The production SSH setup command finished inside the container (KEY_FIXED)' -Skip:$script:SkipTests {
        if (-not (Assert-PreflightPassed)) { return }
        $script:KeySetupOutput | Should -Match 'KEY_FIXED' -Because 'Get-ContainerSshSetupCommand must run to the end inside the container'
    }

    It 'The setup wrote github.com host keys to the rstudio known_hosts file' -Skip:$script:SkipTests {
        if (-not (Assert-PreflightPassed)) { return }
        $out = Invoke-WsSshCommand "docker exec $($script:INNER_CONTAINER) ssh-keygen -F github.com -f /home/rstudio/.ssh/known_hosts >/dev/null 2>&1 && echo GITHUB_KNOWN"
        ($out -join '') | Should -Match 'GITHUB_KNOWN'
    }

    It 'The private key belongs to the container user and has mode 600' -Skip:$script:SkipTests {
        if (-not (Assert-PreflightPassed)) { return }
        $out = Invoke-WsSshCommand "docker exec $($script:INNER_CONTAINER) stat -c '%u:%g %a' /home/rstudio/.ssh/id_ed25519_$($script:E2E_USER)"
        ($out -join '').Trim() | Should -Be "$($script:ContainerUid):$($script:ContainerGid) 600"
    }

    # No token needed: GitHub checks its host key before the user's key. With
    # StrictHostKeyChecking=yes (stricter than the accept-new in GIT_SSH_COMMAND) ssh only
    # gets to "Permission denied (publickey)" or "successfully authenticated" if the
    # production setup really stored github.com's host key.
    It 'github.com host key is verified before authentication (no token needed)' -Skip:$script:SkipTests {
        if (-not (Assert-PreflightPassed)) { return }
        $cmd = "docker exec --user rstudio $($script:INNER_CONTAINER) ssh -i /home/rstudio/.ssh/id_ed25519_$($script:E2E_USER) -o IdentitiesOnly=yes -o UserKnownHostsFile=/home/rstudio/.ssh/known_hosts -o StrictHostKeyChecking=yes -o BatchMode=yes -o ConnectTimeout=15 -T git@github.com 2>&1"
        $text = (Invoke-WsSshCommand $cmd) -join "`n"
        $text | Should -Not -Match 'Host key verification failed|REMOTE HOST IDENTIFICATION HAS CHANGED'
        $text | Should -Match 'Permission denied \(publickey\)|successfully authenticated'
    }

    It 'GIT_SSH_COMMAND in the container is the production value' -Skip:$script:SkipTests {
        if (-not (Assert-PreflightPassed)) { return }
        $out = Invoke-WsSshCommand "docker exec $($script:INNER_CONTAINER) printenv GIT_SSH_COMMAND"
        ($out -join '').Trim() | Should -Be (Get-ContainerGitSshCommand -UserName $script:E2E_USER)
    }

    # ═════════════════════════════════════════════════════════════════════════
    #  GitHub SSH auth (requires token)
    # ═════════════════════════════════════════════════════════════════════════
    It 'Can authenticate to GitHub via SSH from inside the IMPACT container' -Skip:($script:SkipTests -or -not $env:IMPACT_E2E_GITHUB_TOKEN) {
        if (-not (Assert-PreflightPassed)) { return }
        # (F70) Uses the container's own $GIT_SSH_COMMAND (the production value) instead
        # of a hand-written ssh command. BatchMode=yes: fail instead of asking anything.
        # The single quotes keep the workstation's shell from expanding the variable;
        # the shell inside the container expands it from the container environment.
        $cmd = "docker exec --user rstudio $($script:INNER_CONTAINER) sh -c '`$GIT_SSH_COMMAND -o BatchMode=yes -T git@github.com 2>&1'"
        $out = Invoke-WsSshCommand $cmd
        ($out -join "`n") | Should -Match 'successfully authenticated'
    }

    It 'Can execute git pull over SSH from inside the IMPACT container' -Skip:($script:SkipTests -or -not $env:IMPACT_E2E_GITHUB_TOKEN) {
        if (-not (Assert-PreflightPassed)) { return }
        # Mark the copied repo as safe (ownership differs from rstudio user)
        Invoke-WsSshCommand "docker exec --user rstudio $($script:INNER_CONTAINER) git config --global --add safe.directory /home/rstudio/$($script:REPO_NAME)" | Out-Null

        # The repo was cloned over HTTPS. 'insteadOf' makes this pull go over SSH, so it
        # really uses GIT_SSH_COMMAND, the key and known_hosts (a plain HTTPS pull of
        # this public repo would pass even with a broken SSH setup).
        $cmd = "docker exec --user rstudio --workdir /home/rstudio/$($script:REPO_NAME) $($script:INNER_CONTAINER) git -c url.git@github.com:.insteadOf=https://github.com/ pull 2>&1"
        $out = Invoke-WsSshCommand $cmd
        ($out -join "`n") | Should -Match 'Already up to date|Updating|Fast-forward|Merge made'
    }
}
