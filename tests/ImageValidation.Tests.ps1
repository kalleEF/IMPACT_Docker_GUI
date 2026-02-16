#Requires -Modules Pester

<#
.SYNOPSIS
    Image validation tests for the IMPACT Docker container.
    Clones the real IMPACT-NCD-Germany_Base repo, pulls the pre-built
    prerequisite image, builds only the final layer, starts the container,
    and validates: RStudio, R packages, global.R, Git/SSH config.

    These tests validate the Docker IMAGE, not the PowerShell GUI script.
    They run on Ubuntu in CI (native Docker, reliable) and locally on any
    OS with Docker.

    Prerequisites:
      - Docker daemon running
      - Internet access (clone repo + pull base image)
      - Optional: IMPACT_E2E_GITHUB_TOKEN for SSH auth tests

    Run:
      pwsh -File tests/Invoke-Tests.ps1 -Tag ImageValidation
      # or:
      Invoke-Pester ./tests/ImageValidation.Tests.ps1 -Tag ImageValidation -Output Detailed

    Environment variables:
      IMPACT_E2E_GITHUB_TOKEN   - Fine-grained PAT with SSH keys Read/Write.
                                   Enables 2 SSH auth tests. If absent, skipped.
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
        # ── Constants (inside Describe scope for Pester 5 compatibility) ──
        $script:REPO_URL        = 'https://github.com/IMPACT-NCD-Modeling-Germany/IMPACT-NCD-Germany_Base.git'
        $script:REPO_NAME       = 'IMPACT-NCD-Germany_Base'
        $script:IMAGE_NAME      = 'impactncd_germany_imgval_test'
        $script:CONTAINER_NAME  = 'impact_imgval_test_container'
        $script:CONTAINER_PORT  = '18787'
        $script:TEST_USER       = 'imgvaltest'
        $script:TEST_PASSWORD   = 'ImgValTestPass!'

        # ── 0. Pre-flight ────────────────────────────────────────────────
        $dockerOk = $false
        try { docker info 2>$null | Out-Null; $dockerOk = ($LASTEXITCODE -eq 0) } catch {}
        if (-not $dockerOk) { throw 'Docker is not running.' }

        # ── 1. Clone repo ────────────────────────────────────────────────
        $tmpBase = if ($env:TEMP) { $env:TEMP } elseif ($env:TMPDIR) { $env:TMPDIR } else { '/tmp' }
        $script:cloneRoot = Join-Path $tmpBase "impact_imgval_$([guid]::NewGuid().ToString('N').Substring(0,8))"
        $script:repoDir   = Join-Path $script:cloneRoot $script:REPO_NAME

        Write-Host "[ImageVal] Cloning $($script:REPO_URL) ..." -ForegroundColor Cyan
        git clone --depth 1 $script:REPO_URL $script:repoDir 2>&1 | Write-Host
        if ($LASTEXITCODE -ne 0) { throw "git clone failed (exit $LASTEXITCODE)" }

        # ── 2. Create output & synthpop dirs ─────────────────────────────
        $script:outputDir   = Join-Path $script:repoDir 'outputs'
        $script:synthpopDir = Join-Path $script:repoDir 'inputs' 'synthpop'
        New-Item -ItemType Directory -Path $script:outputDir   -Force | Out-Null
        New-Item -ItemType Directory -Path $script:synthpopDir -Force | Out-Null

        # ── 3. Generate SSH key pair ─────────────────────────────────────
        $script:sshDir = Join-Path $tmpBase "impact_imgval_ssh_$([guid]::NewGuid().ToString('N').Substring(0,8))"
        New-Item -ItemType Directory -Path $script:sshDir -Force | Out-Null
        $script:sshKeyPath = Join-Path $script:sshDir "id_ed25519_$($script:TEST_USER)"
        ssh-keygen -t ed25519 -C "imgval_test" -f $script:sshKeyPath -N '""' -q 2>$null
        $script:knownHostsPath = Join-Path $script:sshDir 'known_hosts'
        ssh-keyscan -t ed25519 github.com 2>$null | Set-Content $script:knownHostsPath

        # ── 4. Build Docker image ────────────────────────────────────────
        $script:skipBuild = ($env:IMPACT_E2E_SKIP_BUILD -eq '1')
        if (-not $script:skipBuild) {
            Write-Host "[ImageVal] Building image '$($script:IMAGE_NAME)' ..." -ForegroundColor Cyan
            $dockerfilePath = Join-Path $script:repoDir 'docker_setup' 'Dockerfile.IMPACTncdGER'
            if (-not (Test-Path $dockerfilePath)) { throw "Dockerfile not found at $dockerfilePath" }

            Push-Location $script:repoDir
            try {
                docker build --build-arg "REPO_NAME=$($script:REPO_NAME)" `
                    -f $dockerfilePath -t $script:IMAGE_NAME --progress=plain . 2>&1 | Write-Host
                if ($LASTEXITCODE -ne 0) {
                    # Try prerequisite first
                    $prereqDockerfile = Join-Path $script:repoDir 'docker_setup' 'Dockerfile.prerequisite.IMPACTncdGER'
                    if (Test-Path $prereqDockerfile) {
                        Push-Location (Join-Path $script:repoDir 'docker_setup')
                        docker build -f $prereqDockerfile -t "$($script:IMAGE_NAME)-prerequisite" --progress=plain . 2>&1 | Write-Host
                        Pop-Location
                        docker build --build-arg "REPO_NAME=$($script:REPO_NAME)" `
                            -f $dockerfilePath -t $script:IMAGE_NAME --progress=plain . 2>&1 | Write-Host
                        if ($LASTEXITCODE -ne 0) { throw 'Docker build failed after prerequisite.' }
                    } else { throw 'Docker build failed.' }
                }
            } finally { Pop-Location }
            Write-Host "[ImageVal] Image built." -ForegroundColor Green
        } else {
            Write-Host "[ImageVal] Skipping build (reusing existing image)." -ForegroundColor Yellow
        }

        # ── 5. Register SSH key with GitHub (optional) ───────────────────
        $script:githubKeyId = $null
        if ($env:IMPACT_E2E_GITHUB_TOKEN) {
            Write-Host "[ImageVal] Registering SSH key with GitHub ..." -ForegroundColor Cyan
            $pubKey = Get-Content "$($script:sshKeyPath).pub" -Raw
            $script:githubKeyId = Add-GitHubSshKey -Token $env:IMPACT_E2E_GITHUB_TOKEN `
                -Title "ImgVal-$([guid]::NewGuid().ToString('N').Substring(0,6))" `
                -PublicKey $pubKey.Trim()
            Write-Host "[ImageVal] GitHub SSH key registered (id=$($script:githubKeyId))." -ForegroundColor Green
        }

        # ── 6. Start container ───────────────────────────────────────────
        docker stop $script:CONTAINER_NAME 2>$null | Out-Null
        docker rm   $script:CONTAINER_NAME 2>$null | Out-Null

        $containerKeyPath = "/home/rstudio/.ssh/id_ed25519_$($script:TEST_USER)"

        $dockerArgs = @(
            'run', '-d',
            '--name', $script:CONTAINER_NAME,
            '-e', "PASSWORD=$($script:TEST_PASSWORD)",
            '-e', 'DISABLE_AUTH=false',
            '-e', 'USERID=1000', '-e', 'GROUPID=1000',
            '-e', "GIT_SSH_COMMAND=ssh -i $containerKeyPath -o IdentitiesOnly=yes -o UserKnownHostsFile=/etc/ssh/ssh_known_hosts -o StrictHostKeyChecking=yes",
            '-v', "$($script:repoDir):/host-repo",
            '-v', "$($script:repoDir):/home/rstudio/$($script:REPO_NAME)",
            '-p', "$($script:CONTAINER_PORT):8787",
            '-v', "$($script:outputDir):/home/rstudio/$($script:REPO_NAME)/outputs",
            '-v', "$($script:synthpopDir):/home/rstudio/$($script:REPO_NAME)/inputs/synthpop",
            '-v', "$($script:sshKeyPath):/keys/id_ed25519_$($script:TEST_USER):ro",
            '-v', "$($script:knownHostsPath):/etc/ssh/ssh_known_hosts:ro",
            '--workdir', "/home/rstudio/$($script:REPO_NAME)",
            $script:IMAGE_NAME
        )

        Write-Host "[ImageVal] Starting container ..." -ForegroundColor Cyan
        docker @dockerArgs 2>&1 | Write-Host
        if ($LASTEXITCODE -ne 0) { throw 'Failed to start container.' }

        # ── 7. Fix SSH key permissions inside container ──────────────────
        Start-Sleep -Seconds 2
        $fixCmd = "mkdir -p /home/rstudio/.ssh && cp /keys/id_ed25519_$($script:TEST_USER) $containerKeyPath && chmod 600 $containerKeyPath && chown 1000:1000 $containerKeyPath && cp /etc/ssh/ssh_known_hosts /home/rstudio/.ssh/known_hosts 2>/dev/null; chmod 644 /home/rstudio/.ssh/known_hosts 2>/dev/null; chown 1000:1000 /home/rstudio/.ssh/known_hosts 2>/dev/null; echo KEY_FIXED"
        docker exec $script:CONTAINER_NAME sh -c $fixCmd 2>&1 | Out-Null

        # ── 8. Wait for RStudio Server ───────────────────────────────────
        Write-Host "[ImageVal] Waiting for RStudio Server ..." -ForegroundColor Cyan
        $ready = $false
        for ($i = 0; $i -lt 60; $i++) {
            Start-Sleep -Seconds 2
            try {
                $resp = Invoke-WebRequest -Uri "http://localhost:$($script:CONTAINER_PORT)" -UseBasicParsing -TimeoutSec 5 -ErrorAction SilentlyContinue
                if ($resp.StatusCode -eq 200 -or $resp.StatusCode -eq 302) { $ready = $true; break }
            } catch {}
        }
        if (-not $ready) {
            $logs = docker logs $script:CONTAINER_NAME 2>&1 | Select-Object -Last 30
            Write-Host "[ImageVal] Container logs:`n$($logs -join "`n")" -ForegroundColor Red
            throw 'RStudio Server did not start within 120s.'
        }
        Write-Host "[ImageVal] RStudio Server ready." -ForegroundColor Green
    }

    AfterAll {
        Write-Host "[ImageVal] Cleaning up ..." -ForegroundColor Cyan

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
    }

    # ═════════════════════════════════════════════════════════════════════
    #  RStudio Server
    # ═════════════════════════════════════════════════════════════════════
    It 'RStudio Server responds on the mapped port' {
        $resp = Invoke-WebRequest -Uri "http://localhost:$($script:CONTAINER_PORT)" -UseBasicParsing -TimeoutSec 10
        $resp.StatusCode | Should -BeIn @(200, 302)
        $resp.Content    | Should -Match 'rstudio|RStudio|sign-in|Sign In'
    }

    # ═════════════════════════════════════════════════════════════════════
    #  Repository mount
    # ═════════════════════════════════════════════════════════════════════
    It 'Repository is bind-mounted at /home/rstudio/<RepoName>' {
        $lsOut = docker exec $script:CONTAINER_NAME ls "/home/rstudio/$($script:REPO_NAME)" 2>&1
        $LASTEXITCODE | Should -Be 0
        $lsOut | Should -Contain 'global.R'
        $lsOut | Should -Contain 'docker_setup'
    }

    It 'The .Rproj file exists inside the container' {
        $out = docker exec $script:CONTAINER_NAME sh -c "ls /home/rstudio/$($script:REPO_NAME)/*.Rproj 2>/dev/null" 2>&1
        $LASTEXITCODE | Should -Be 0
        $out | Should -Match '\.Rproj$'
    }

    It 'Output directory is mounted and writable' {
        $out = docker exec --user rstudio $script:CONTAINER_NAME sh -c "touch /home/rstudio/$($script:REPO_NAME)/outputs/.imgval_test && echo WRITE_OK" 2>&1
        $out | Should -Match 'WRITE_OK'
        docker exec --user rstudio $script:CONTAINER_NAME rm -f "/home/rstudio/$($script:REPO_NAME)/outputs/.imgval_test" 2>$null
    }

    It 'Synthpop directory is mounted' {
        docker exec $script:CONTAINER_NAME test -d "/home/rstudio/$($script:REPO_NAME)/inputs/synthpop" 2>&1
        $LASTEXITCODE | Should -Be 0
    }

    # ═════════════════════════════════════════════════════════════════════
    #  R environment
    # ═════════════════════════════════════════════════════════════════════
    It 'R is available and reports a version' {
        $rVer = docker exec $script:CONTAINER_NAME R --version 2>&1 | Select-Object -First 1
        $LASTEXITCODE | Should -Be 0
        $rVer | Should -Match 'R version'
    }

    It 'The IMPACTncdGer R package is installed' {
        $out = docker exec --user rstudio $script:CONTAINER_NAME Rscript -e "cat(nzchar(system.file(package='IMPACTncdGer')))" 2>&1
        $out | Should -Match 'TRUE'
    }

    It 'CKutils R package is available' {
        $out = docker exec --user rstudio $script:CONTAINER_NAME Rscript -e "cat(nzchar(system.file(package='CKutils')))" 2>&1
        $out | Should -Match 'TRUE'
    }

    # ═════════════════════════════════════════════════════════════════════
    #  global.R
    # ═════════════════════════════════════════════════════════════════════
    It 'global.R can be sourced without errors' {
        $out = docker exec --user rstudio $script:CONTAINER_NAME `
            Rscript -e "setwd('/home/rstudio/$($script:REPO_NAME)'); tryCatch({ source('global.R'); cat('GLOBAL_OK') }, error = function(e) cat(paste('GLOBAL_ERROR:', e`$message)))" 2>&1
        $joined = $out -join "`n"
        $joined | Should -Match 'GLOBAL_OK'
        $joined | Should -Not -Match 'GLOBAL_ERROR'
    }

    # ═════════════════════════════════════════════════════════════════════
    #  Git / SSH configuration
    # ═════════════════════════════════════════════════════════════════════
    It 'Git is configured to use SSH for github.com' {
        $out = docker exec $script:CONTAINER_NAME git config --system --get 'url.git@github.com:.insteadof' 2>&1
        $LASTEXITCODE | Should -Be 0
        $out | Should -Match 'https://github.com/'
    }

    It 'SSH key is correctly placed inside the container' {
        $out = docker exec --user rstudio $script:CONTAINER_NAME sh -c "test -f /home/rstudio/.ssh/id_ed25519_$($script:TEST_USER) && stat -c '%a' /home/rstudio/.ssh/id_ed25519_$($script:TEST_USER)" 2>&1
        $LASTEXITCODE | Should -Be 0
        $out | Should -Be '600'
    }

    It 'Known hosts file contains github.com' {
        $out = docker exec --user rstudio $script:CONTAINER_NAME cat /home/rstudio/.ssh/known_hosts 2>&1
        $out | Should -Match 'github\.com'
    }

    It 'GIT_SSH_COMMAND environment variable is set correctly' {
        $out = docker exec $script:CONTAINER_NAME printenv GIT_SSH_COMMAND 2>&1
        $out | Should -Match "id_ed25519_$($script:TEST_USER)"
        $out | Should -Match 'IdentitiesOnly=yes'
    }

    # ═════════════════════════════════════════════════════════════════════
    #  GitHub SSH auth (requires token)
    # ═════════════════════════════════════════════════════════════════════
    It 'Can authenticate to GitHub via SSH from inside the container' -Skip:(-not $env:IMPACT_E2E_GITHUB_TOKEN) {
        $out = docker exec --user rstudio $script:CONTAINER_NAME `
            ssh -i "/home/rstudio/.ssh/id_ed25519_$($script:TEST_USER)" `
                -o IdentitiesOnly=yes `
                -o UserKnownHostsFile=/home/rstudio/.ssh/known_hosts `
                -o StrictHostKeyChecking=yes `
                -T git@github.com 2>&1
        ($out -join "`n") | Should -Match 'successfully authenticated'
    }

    It 'Can execute git pull from inside the container' -Skip:(-not $env:IMPACT_E2E_GITHUB_TOKEN) {
        $out = docker exec --user rstudio --workdir "/home/rstudio/$($script:REPO_NAME)" $script:CONTAINER_NAME `
            git pull 2>&1
        ($out -join "`n") | Should -Match 'Already up to date|Updating|Fast-forward'
    }
}
