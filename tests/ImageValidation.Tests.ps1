#Requires -Modules Pester

<#
.SYNOPSIS
    Image validation tests for the IMPACT Docker container.
    Clones the real IMPACT-NCD-Germany_Base repo, builds the Docker image,
    starts a container, and validates: RStudio, R packages, global.R, Git/SSH.

    These tests validate the Docker IMAGE, not the PowerShell GUI script.
    They run on Ubuntu in CI (native Docker) and locally on any OS with Docker.

    Prerequisites:
      - Docker daemon running
      - Internet access (clone repo + pull base image)
      - Optional: IMPACT_E2E_GITHUB_TOKEN for SSH auth tests

    Run:
      pwsh tests/Invoke-Tests.ps1 -Tag ImageValidation
      # or:
      Invoke-Pester ./tests/ImageValidation.Tests.ps1 -Tag ImageValidation -Output Detailed

    Environment variables:
      IMPACT_E2E_GITHUB_TOKEN   - Fine-grained PAT with SSH keys Read/Write.
      IMPACT_E2E_SKIP_BUILD     - Set to '1' to skip image build (reuse existing).
      IMPACT_E2E_KEEP_ARTIFACTS - Set to '1' to keep repo clone + image after tests.

    Tag: ImageValidation
#>

BeforeDiscovery {
    $modulePath = Join-Path $PSScriptRoot '..' 'current_version' 'IMPACT_Docker_GUI.psm1'
    if (-not (Get-Module -Name 'IMPACT_Docker_GUI')) {
        Import-Module $modulePath -Force -DisableNameChecking
    }
}

Describe 'ImageValidation: IMPACT Docker container from real repo' -Tag ImageValidation {

    BeforeAll {
        # Load helpers (Assert-PreflightPassed, Wait-ForRStudioReady, etc.)
        . (Join-Path $PSScriptRoot 'Helpers' 'TestSessionState.ps1')

        # ── Constants ───────────────────────────────────────────────────────
        $script:REPO_URL        = 'https://github.com/IMPACT-NCD-Modeling-Germany/IMPACT-NCD-Germany_Base.git'
        $script:REPO_NAME       = 'IMPACT-NCD-Germany_Base'
        $script:IMAGE_NAME      = 'impactncd_germany_imgval_test'
        $script:CONTAINER_NAME  = 'impact_imgval_test_container'
        $script:CONTAINER_PORT  = '18787'
        $script:TEST_USER       = 'imgvaltest'
        $script:TEST_PASSWORD   = 'ImgValTestPass!'

        # ── Preflight state (NEVER throw in BeforeAll — use flags) ──────────
        $script:PreflightFailed = $false
        $script:PreflightMessages = @()

        # ── 0. Switch to local Docker context ──────────────────────────────
        #   ImageValidation needs to bind-mount local host paths into the
        #   container.  This only works when Docker runs locally (Desktop or
        #   default context), not on a remote SSH context.
        $script:SavedDockerContext = $env:DOCKER_CONTEXT
        $ctxList = docker context ls --format "{{.Name}}" 2>$null
        $localCtx = 'desktop-linux'
        if ($ctxList -notcontains $localCtx) { $localCtx = 'default' }
        $env:DOCKER_CONTEXT = $localCtx
        Write-Host "[ImageVal] Using Docker context: $localCtx" -ForegroundColor DarkGray

        # ── 0b. Docker check ────────────────────────────────────────────────
        $dockerOk = $false
        try { docker info 2>$null | Out-Null; $dockerOk = ($LASTEXITCODE -eq 0) } catch {}
        if (-not $dockerOk) {
            $script:PreflightFailed = $true
            $script:PreflightMessages += 'Docker is not running (local context).'
            Write-Host '[ImageVal][Preflight] Docker check failed.' -ForegroundColor Red
            return
        }

        # ── 1. Clone repo ──────────────────────────────────────────────────
        $tmpBase = [System.IO.Path]::GetTempPath()
        $script:cloneRoot = Join-Path $tmpBase "impact_imgval_$([guid]::NewGuid().ToString('N').Substring(0,8))"
        $script:repoDir   = Join-Path $script:cloneRoot $script:REPO_NAME

        Write-Host "[ImageVal] Cloning $($script:REPO_URL) ..." -ForegroundColor Cyan
        git clone --depth 1 $script:REPO_URL $script:repoDir 2>&1 | Write-Host
        if ($LASTEXITCODE -ne 0) {
            $script:PreflightFailed = $true
            $script:PreflightMessages += "git clone failed (exit $LASTEXITCODE)"
            Write-Host "[ImageVal][Preflight] git clone failed (exit $LASTEXITCODE)" -ForegroundColor Red
            return
        }

        # ── 2. Create output & synthpop dirs ────────────────────────────────
        $script:outputDir   = Join-Path $script:repoDir 'outputs'
        $script:synthpopDir = Join-Path $script:repoDir 'inputs' 'synthpop'
        New-Item -ItemType Directory -Path $script:outputDir   -Force | Out-Null
        New-Item -ItemType Directory -Path $script:synthpopDir -Force | Out-Null

        # ── 3. Generate SSH key pair ────────────────────────────────────────
        $script:sshDir = Join-Path $tmpBase "impact_imgval_ssh_$([guid]::NewGuid().ToString('N').Substring(0,8))"
        New-Item -ItemType Directory -Path $script:sshDir -Force | Out-Null
        $script:sshKeyPath = Join-Path $script:sshDir "id_ed25519_$($script:TEST_USER)"
        ssh-keygen -t ed25519 -C "imgval_test" -f $script:sshKeyPath -N "" -q 2>$null
        $script:knownHostsPath = Join-Path $script:sshDir 'known_hosts'
        ssh-keyscan -t ed25519 github.com 2>$null | Set-Content $script:knownHostsPath

        # ── 4. Build Docker image ───────────────────────────────────────────
        $script:skipBuild = ($env:IMPACT_E2E_SKIP_BUILD -eq '1')
        if (-not $script:skipBuild) {
            Write-Host "[ImageVal] Building image '$($script:IMAGE_NAME)' ..." -ForegroundColor Cyan
            $dockerfilePath = Join-Path $script:repoDir 'docker_setup' 'Dockerfile.IMPACTncdGER'
            if (-not (Test-Path $dockerfilePath)) {
                $script:PreflightFailed = $true
                $script:PreflightMessages += "Dockerfile not found at $dockerfilePath"
                Write-Host "[ImageVal][Preflight] Dockerfile not found" -ForegroundColor Red
                return
            }

            $originalDir = (Get-Location).Path
            try {
                Set-Location $script:repoDir
                docker build --build-arg "REPO_NAME=$($script:REPO_NAME)" `
                    -f $dockerfilePath -t $script:IMAGE_NAME --progress=plain . 2>&1 | Write-Host
                if ($LASTEXITCODE -ne 0) {
                    # Try prerequisite first, then retry
                    $prereqDockerfile = Join-Path $script:repoDir 'docker_setup' 'Dockerfile.prerequisite.IMPACTncdGER'
                    if (Test-Path $prereqDockerfile) {
                        Write-Host '[ImageVal] Trying prerequisite build ...' -ForegroundColor Yellow
                        Set-Location (Join-Path $script:repoDir 'docker_setup')
                        docker build -f $prereqDockerfile -t "$($script:IMAGE_NAME)-prerequisite" --progress=plain . 2>&1 | Write-Host
                        Set-Location $script:repoDir
                        docker build --build-arg "REPO_NAME=$($script:REPO_NAME)" `
                            -f $dockerfilePath -t $script:IMAGE_NAME --progress=plain . 2>&1 | Write-Host
                        if ($LASTEXITCODE -ne 0) {
                            $script:PreflightFailed = $true
                            $script:PreflightMessages += 'Docker build failed after prerequisite build.'
                            Write-Host '[ImageVal][Preflight] Docker build failed after prerequisite.' -ForegroundColor Red
                            return
                        }
                    } else {
                        $script:PreflightFailed = $true
                        $script:PreflightMessages += 'Docker build failed (no prerequisite Dockerfile).'
                        Write-Host '[ImageVal][Preflight] Docker build failed.' -ForegroundColor Red
                        return
                    }
                }
            } finally {
                Set-Location $originalDir
            }
            Write-Host '[ImageVal] Image built.' -ForegroundColor Green
        } else {
            Write-Host '[ImageVal] Skipping build (reusing existing image).' -ForegroundColor Yellow
        }

        # ── 5. Register SSH key with GitHub (optional) ──────────────────────
        $script:githubKeyId = $null
        if ($env:IMPACT_E2E_GITHUB_TOKEN) {
            Write-Host '[ImageVal] Registering SSH key with GitHub ...' -ForegroundColor Cyan
            $pubKey = Get-Content "$($script:sshKeyPath).pub" -Raw
            $script:githubKeyId = Add-GitHubSshKey -Token $env:IMPACT_E2E_GITHUB_TOKEN `
                -Title "ImgVal-$([guid]::NewGuid().ToString('N').Substring(0,6))" `
                -PublicKey $pubKey.Trim()
            Write-Host "[ImageVal] GitHub SSH key registered (id=$($script:githubKeyId))." -ForegroundColor Green
        }

        # ── 6. Start container ──────────────────────────────────────────────
        docker stop $script:CONTAINER_NAME 2>$null | Out-Null
        docker rm   $script:CONTAINER_NAME 2>$null | Out-Null

        $containerKeyPath = "/home/rstudio/.ssh/id_ed25519_$($script:TEST_USER)"

        $dockerArgs = @(
            'run', '-d',
            '--name', $script:CONTAINER_NAME,
            '-e', "PASSWORD=$($script:TEST_PASSWORD)",
            '-e', 'DISABLE_AUTH=false',
            '-e', 'USERID=1000', '-e', 'GROUPID=1000',
            '-e', "CONTAINER_REPO_NAME=$($script:REPO_NAME)",
            '-e', 'SYNC_ENABLED=false',
            '-e', "GIT_SSH_COMMAND=ssh -i $containerKeyPath -o IdentitiesOnly=yes -o UserKnownHostsFile=/etc/ssh/ssh_known_hosts -o StrictHostKeyChecking=yes",
            '-v', "$($script:repoDir):/home/rstudio/$($script:REPO_NAME)",
            '-p', "$($script:CONTAINER_PORT):8787",
            '-v', "$($script:outputDir):/home/rstudio/$($script:REPO_NAME)/outputs",
            '-v', "$($script:synthpopDir):/home/rstudio/$($script:REPO_NAME)/inputs/synthpop",
            '-v', "$($script:sshKeyPath):/keys/id_ed25519_$($script:TEST_USER):ro",
            '-v', "$($script:knownHostsPath):/etc/ssh/ssh_known_hosts:ro",
            '--workdir', "/home/rstudio/$($script:REPO_NAME)",
            $script:IMAGE_NAME
        )

        Write-Host '[ImageVal] Starting container ...' -ForegroundColor Cyan
        docker @dockerArgs 2>&1 | Write-Host
        if ($LASTEXITCODE -ne 0) {
            $script:PreflightFailed = $true
            $script:PreflightMessages += "Container start failed (exit $LASTEXITCODE)"
            Write-Host "[ImageVal][Preflight] Container start failed." -ForegroundColor Red
            return
        }

        # ── 7. Fix SSH key permissions inside container ─────────────────────
        Start-Sleep -Seconds 2
        $fixCmd = "mkdir -p /home/rstudio/.ssh && cp /keys/id_ed25519_$($script:TEST_USER) $containerKeyPath && chmod 600 $containerKeyPath && chown 1000:1000 $containerKeyPath && cp /etc/ssh/ssh_known_hosts /home/rstudio/.ssh/known_hosts 2>/dev/null; chmod 644 /home/rstudio/.ssh/known_hosts 2>/dev/null; chown 1000:1000 /home/rstudio/.ssh/known_hosts 2>/dev/null; echo KEY_FIXED"
        $fixArgs = @('exec', $script:CONTAINER_NAME, 'sh', '-c', $fixCmd)
        $fixOut = docker @fixArgs 2>&1
        if (($fixOut -join '') -notmatch 'KEY_FIXED') {
            Write-Host "[ImageVal][Diag] SSH key fix may have failed: $($fixOut -join ' ')" -ForegroundColor Yellow
        }

        # ── 8. Wait for RStudio Server ──────────────────────────────────────
        Write-Host '[ImageVal] Waiting for RStudio Server ...' -ForegroundColor Cyan
        $ready = Wait-ForRStudioReady -Url "http://localhost:$($script:CONTAINER_PORT)" -TimeoutSeconds 120
        if (-not $ready) {
            $logs = docker logs $script:CONTAINER_NAME 2>&1 | Select-Object -Last 30
            Write-Host "[ImageVal] Container logs:`n$($logs -join "`n")" -ForegroundColor Red
            $script:PreflightFailed = $true
            $script:PreflightMessages += 'RStudio Server did not become ready within 120s.'
            Write-Host '[ImageVal][Preflight] RStudio not ready within 120s.' -ForegroundColor Red
            return
        }
        Write-Host '[ImageVal] RStudio Server ready.' -ForegroundColor Green
    }

    AfterAll {
        # Save artifacts
        try {
            if (-not (Get-Command -Name Save-TestArtifacts -ErrorAction SilentlyContinue)) {
                . (Join-Path $PSScriptRoot 'Helpers' 'TestSessionState.ps1')
            }
            $localPaths = @()
            if ($script:cloneRoot -and (Test-Path $script:cloneRoot)) { $localPaths += $script:cloneRoot }
            if ($script:sshDir   -and (Test-Path $script:sshDir))    { $localPaths += $script:sshDir }
            Save-TestArtifacts -Suite 'image-validation' -Paths $localPaths `
                -ExtraFiles @("$PSScriptRoot/TestResults-ImageValidation.xml") `
                -ContainerNames @($script:CONTAINER_NAME)
        } catch {
            Write-Warning "Failed to save image-validation artifacts: $($_.Exception.Message)"
        }

        Write-Host '[ImageVal] Cleaning up ...' -ForegroundColor Cyan
        docker stop $script:CONTAINER_NAME 2>$null | Out-Null
        docker rm   $script:CONTAINER_NAME 2>$null | Out-Null

        if ($script:githubKeyId -and $env:IMPACT_E2E_GITHUB_TOKEN) {
            try { Remove-GitHubSshKey -Token $env:IMPACT_E2E_GITHUB_TOKEN -KeyId $script:githubKeyId } catch {}
        }

        if ($env:IMPACT_E2E_KEEP_ARTIFACTS -ne '1') {
            docker rmi $script:IMAGE_NAME 2>$null | Out-Null
            Remove-Item -Recurse -Force -Path $script:cloneRoot -ErrorAction SilentlyContinue
            Remove-Item -Recurse -Force -Path $script:sshDir    -ErrorAction SilentlyContinue
        }

        # Restore original Docker context
        $env:DOCKER_CONTEXT = $script:SavedDockerContext
    }

    # ═════════════════════════════════════════════════════════════════════════
    #  Preflight
    # ═════════════════════════════════════════════════════════════════════════
    It 'Preflight: environment is ready' {
        $script:PreflightFailed | Should -BeFalse -Because ($script:PreflightMessages -join '; ')
    }

    # ═════════════════════════════════════════════════════════════════════════
    #  RStudio Server
    # ═════════════════════════════════════════════════════════════════════════
    It 'RStudio Server responds on the mapped port' {
        if (-not (Assert-PreflightPassed)) { return }
        $resp = Invoke-WebRequest -Uri "http://localhost:$($script:CONTAINER_PORT)" -UseBasicParsing -TimeoutSec 10
        $resp.StatusCode | Should -BeIn @(200, 302)
        $resp.Content    | Should -Match 'rstudio|RStudio|sign-in|Sign In'
    }

    # ═════════════════════════════════════════════════════════════════════════
    #  Repository mount
    # ═════════════════════════════════════════════════════════════════════════
    It 'Repository is bind-mounted at /home/rstudio/<RepoName>' {
        if (-not (Assert-PreflightPassed)) { return }
        $r = Invoke-DockerExecSafe -ContainerName $script:CONTAINER_NAME `
            -Command @('ls', "/home/rstudio/$($script:REPO_NAME)")
        $r.ExitCode | Should -Be 0
        $r.Output | Should -Contain 'global.R'
        $r.Output | Should -Contain 'docker_setup'
    }

    It 'The .Rproj file exists inside the container' {
        if (-not (Assert-PreflightPassed)) { return }
        $r = Invoke-DockerExecSafe -ContainerName $script:CONTAINER_NAME `
            -Command @('sh', '-c', "ls /home/rstudio/$($script:REPO_NAME)/*.Rproj 2>/dev/null")
        $r.ExitCode | Should -Be 0
        ($r.Output -join "`n") | Should -Match '\.Rproj$'
    }

    It 'Output directory is mounted and writable' {
        if (-not (Assert-PreflightPassed)) { return }
        $r = Invoke-DockerExecSafe -ContainerName $script:CONTAINER_NAME -User 'rstudio' `
            -Command @('sh', '-c', "touch /home/rstudio/$($script:REPO_NAME)/outputs/.imgval_test && echo WRITE_OK")
        ($r.Output -join '') | Should -Match 'WRITE_OK'
        Invoke-DockerExecSafe -ContainerName $script:CONTAINER_NAME -User 'rstudio' `
            -Command @('rm', '-f', "/home/rstudio/$($script:REPO_NAME)/outputs/.imgval_test") | Out-Null
    }

    It 'Synthpop directory is mounted' {
        if (-not (Assert-PreflightPassed)) { return }
        $r = Invoke-DockerExecSafe -ContainerName $script:CONTAINER_NAME `
            -Command @('test', '-d', "/home/rstudio/$($script:REPO_NAME)/inputs/synthpop")
        $r.ExitCode | Should -Be 0
    }

    # ═════════════════════════════════════════════════════════════════════════
    #  R environment
    # ═════════════════════════════════════════════════════════════════════════
    It 'R is available and reports a version' {
        if (-not (Assert-PreflightPassed)) { return }
        $r = Invoke-DockerExecSafe -ContainerName $script:CONTAINER_NAME -Command @('R', '--version')
        $r.ExitCode | Should -Be 0
        ($r.Output | Select-Object -First 1) | Should -Match 'R version'
    }

    It 'The IMPACTncdGer R package is installed' {
        if (-not (Assert-PreflightPassed)) { return }
        $r = Invoke-DockerExecSafe -ContainerName $script:CONTAINER_NAME -User 'rstudio' `
            -Command @('Rscript', '-e', "cat(nzchar(system.file(package='IMPACTncdGer')))")
        ($r.Output -join '') | Should -Match 'TRUE'
    }

    It 'CKutils R package is available' {
        if (-not (Assert-PreflightPassed)) { return }
        $r = Invoke-DockerExecSafe -ContainerName $script:CONTAINER_NAME -User 'rstudio' `
            -Command @('Rscript', '-e', "cat(nzchar(system.file(package='CKutils')))")
        ($r.Output -join '') | Should -Match 'TRUE'
    }

    # ═════════════════════════════════════════════════════════════════════════
    #  global.R
    # ═════════════════════════════════════════════════════════════════════════
    It 'global.R can be sourced without errors' {
        if (-not (Assert-PreflightPassed)) { return }

        # Use base64 encoding to safely pass the R script through shell layers
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
        $decodeCmd = "echo $b64 | base64 -d > /tmp/_imgval_global_test.R"
        Invoke-DockerExecSafe -ContainerName $script:CONTAINER_NAME `
            -Command @('sh', '-c', $decodeCmd) | Out-Null

        $r = Invoke-DockerExecSafe -ContainerName $script:CONTAINER_NAME -User 'rstudio' `
            -Command @('Rscript', '/tmp/_imgval_global_test.R')
        $joined = $r.Output -join "`n"
        $joined | Should -Match 'GLOBAL_OK'
        $joined | Should -Not -Match 'GLOBAL_ERROR'
    }

    # ═════════════════════════════════════════════════════════════════════════
    #  Git / SSH configuration
    # ═════════════════════════════════════════════════════════════════════════
    It 'Git is configured to use SSH for github.com' {
        if (-not (Assert-PreflightPassed)) { return }
        $r = Invoke-DockerExecSafe -ContainerName $script:CONTAINER_NAME `
            -Command @('git', 'config', '--system', '--get', 'url.git@github.com:.insteadof')
        $r.ExitCode | Should -Be 0
        ($r.Output -join '') | Should -Match 'https://github.com/'
    }

    It 'SSH key is correctly placed inside the container' {
        if (-not (Assert-PreflightPassed)) { return }
        $r = Invoke-DockerExecSafe -ContainerName $script:CONTAINER_NAME -User 'rstudio' `
            -Command @('sh', '-c', "test -f /home/rstudio/.ssh/id_ed25519_$($script:TEST_USER) && stat -c '%a' /home/rstudio/.ssh/id_ed25519_$($script:TEST_USER)")
        $r.ExitCode | Should -Be 0
        ($r.Output -join '').Trim() | Should -Be '600'
    }

    It 'Known hosts file contains github.com' {
        if (-not (Assert-PreflightPassed)) { return }
        $r = Invoke-DockerExecSafe -ContainerName $script:CONTAINER_NAME -User 'rstudio' `
            -Command @('cat', '/home/rstudio/.ssh/known_hosts')
        ($r.Output -join "`n") | Should -Match 'github\.com'
    }

    It 'GIT_SSH_COMMAND environment variable is set correctly' {
        if (-not (Assert-PreflightPassed)) { return }
        $r = Invoke-DockerExecSafe -ContainerName $script:CONTAINER_NAME `
            -Command @('printenv', 'GIT_SSH_COMMAND')
        ($r.Output -join '') | Should -Match "id_ed25519_$($script:TEST_USER)"
        ($r.Output -join '') | Should -Match 'IdentitiesOnly=yes'
    }

    # ═════════════════════════════════════════════════════════════════════════
    #  GitHub SSH auth (requires token)
    # ═════════════════════════════════════════════════════════════════════════
    It 'Can authenticate to GitHub via SSH from inside the container' -Skip:(-not $env:IMPACT_E2E_GITHUB_TOKEN) {
        if (-not (Assert-PreflightPassed)) { return }
        $r = Invoke-DockerExecSafe -ContainerName $script:CONTAINER_NAME -User 'rstudio' `
            -Command @('ssh',
                '-i', "/home/rstudio/.ssh/id_ed25519_$($script:TEST_USER)",
                '-o', 'IdentitiesOnly=yes',
                '-o', 'UserKnownHostsFile=/home/rstudio/.ssh/known_hosts',
                '-o', 'StrictHostKeyChecking=yes',
                '-T', 'git@github.com')
        ($r.Output -join "`n") | Should -Match 'successfully authenticated'
    }

    It 'Can execute git pull from inside the container' -Skip:(-not $env:IMPACT_E2E_GITHUB_TOKEN) {
        if (-not (Assert-PreflightPassed)) { return }
        # Bind-mounted repos have different host/container ownership — mark as safe
        Invoke-DockerExecSafe -ContainerName $script:CONTAINER_NAME -User 'rstudio' `
            -Command @('git', 'config', '--global', '--add', 'safe.directory',
                        "/home/rstudio/$($script:REPO_NAME)") | Out-Null
        $r = Invoke-DockerExecSafe -ContainerName $script:CONTAINER_NAME -User 'rstudio' `
            -WorkDir "/home/rstudio/$($script:REPO_NAME)" `
            -Command @('git', 'pull')
        ($r.Output -join "`n") | Should -Match 'Already up to date|Updating|Fast-forward|Merge made'
    }
}
