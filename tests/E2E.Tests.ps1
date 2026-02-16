<#
.SYNOPSIS
    End-to-end tests for the IMPACT Docker GUI.

    These tests clone the real IMPACT-NCD-Germany_Base repository, build the
    Docker image from it, start a container exactly as a real user would via
    the GUI, then validate:
      1. RStudio Server is accessible on the mapped port
      2. The repo is correctly mounted and visible inside the container
      3. global.R can be sourced (R environment + package build)
      4. GitHub SSH authentication works from inside the container (git pull)

    Prerequisites:
      - Docker Desktop / Engine running
      - Internet access (to clone repo + pull base image)
      - Optional: IMPACT_E2E_GITHUB_TOKEN secret for SSH auth test

    Run:
      pwsh -File tests/Invoke-Tests.ps1 -Tag E2E
      # or directly:
      Invoke-Pester ./tests/E2E.Tests.ps1 -Tag E2E -Output Detailed

    Environment variables:
      IMPACT_E2E_GITHUB_TOKEN  – Personal Access Token with admin:public_key scope.
                                  Required for the SSH auth test. If absent, that
                                  test is skipped.
      IMPACT_E2E_SKIP_BUILD    – Set to '1' to skip image build (reuse existing).
      IMPACT_E2E_KEEP_ARTIFACTS – Set to '1' to keep repo clone + image after tests.

    Tag: E2E  (excluded from normal CI runs; triggered manually or on schedule)
#>

# ═══════════════════════════════════════════════════════════════════════════════
#  Bootstrap
# ═══════════════════════════════════════════════════════════════════════════════
BeforeDiscovery {
    $modulePath = Join-Path $PSScriptRoot '..' 'current_version' 'IMPACT_Docker_GUI.psm1'
    if (-not (Get-Module -Name 'IMPACT_Docker_GUI')) {
        Import-Module $modulePath -Force -DisableNameChecking
    }
    . (Join-Path $PSScriptRoot 'Helpers' 'TestSessionState.ps1')
}

# ═══════════════════════════════════════════════════════════════════════════════
#  Constants
# ═══════════════════════════════════════════════════════════════════════════════
$script:REPO_URL        = 'https://github.com/IMPACT-NCD-Modeling-Germany/IMPACT-NCD-Germany_Base.git'
$script:REPO_NAME       = 'IMPACT-NCD-Germany_Base'
$script:IMAGE_NAME      = 'impactncd_germany_e2e_test'
$script:CONTAINER_NAME  = 'impact_e2e_test_container'
$script:CONTAINER_PORT  = '18787'   # non-standard port to avoid conflicts
$script:TEST_USER       = 'e2etest'
$script:TEST_PASSWORD   = 'E2eTestPass!'

# ═══════════════════════════════════════════════════════════════════════════════
#  Clone repo + build image (shared across all E2E tests)
# ═══════════════════════════════════════════════════════════════════════════════
Describe 'E2E: Docker container lifecycle with real IMPACT repo' -Tag E2E {

    BeforeAll {
        # ── 0. Pre-flight checks ──────────────────────────────────────────
        $dockerOk = $false
        try {
            docker info 2>$null | Out-Null
            $dockerOk = ($LASTEXITCODE -eq 0)
        } catch {}
        if (-not $dockerOk) {
            throw 'Docker is not running. E2E tests require a working Docker daemon.'
        }

        # ── 1. Clone the repository ──────────────────────────────────────
        $script:cloneRoot = Join-Path $env:TEMP "impact_e2e_$([guid]::NewGuid().ToString('N').Substring(0,8))"
        $script:repoDir   = Join-Path $script:cloneRoot $script:REPO_NAME

        Write-Host "[E2E] Cloning $($script:REPO_URL) into $($script:cloneRoot) ..." -ForegroundColor Cyan
        git clone --depth 1 $script:REPO_URL $script:repoDir 2>&1 | Write-Host
        if ($LASTEXITCODE -ne 0) {
            throw "git clone failed with exit code $LASTEXITCODE"
        }
        Write-Host "[E2E] Clone complete." -ForegroundColor Green

        # ── 2. Create output & synthpop dirs (sim_design.yaml uses relative paths for E2E) ──
        $script:outputDir   = Join-Path $script:repoDir 'outputs'
        $script:synthpopDir = Join-Path $script:repoDir 'inputs' 'synthpop'
        New-Item -ItemType Directory -Path $script:outputDir   -Force | Out-Null
        New-Item -ItemType Directory -Path $script:synthpopDir -Force | Out-Null

        # Create a sim_design_local.yaml with relative paths for local mode
        $script:simDesignPath = Join-Path $script:repoDir 'inputs' 'sim_design_local.yaml'
        if (-not (Test-Path $script:simDesignPath)) {
            Set-Content -Path $script:simDesignPath -Value @"
output_dir: ./outputs
synthpop_dir: ./inputs/synthpop
"@
        }

        # ── 3. Generate SSH key pair for the test ────────────────────────
        $script:sshDir = Join-Path $env:TEMP "impact_e2e_ssh_$([guid]::NewGuid().ToString('N').Substring(0,8))"
        New-Item -ItemType Directory -Path $script:sshDir -Force | Out-Null
        $script:sshKeyPath = Join-Path $script:sshDir "id_ed25519_$($script:TEST_USER)"
        if (-not (Test-Path $script:sshKeyPath)) {
            ssh-keygen -t ed25519 -C "e2e_test" -f $script:sshKeyPath -N '""' -q 2>$null
        }
        # Ensure known_hosts exists
        $script:knownHostsPath = Join-Path $script:sshDir 'known_hosts'
        if (-not (Test-Path $script:knownHostsPath)) {
            ssh-keyscan -t ed25519 github.com 2>$null | Set-Content $script:knownHostsPath
        }

        # ── 4. Build the Docker image ────────────────────────────────────
        $script:skipBuild = ($env:IMPACT_E2E_SKIP_BUILD -eq '1')
        if (-not $script:skipBuild) {
            Write-Host "[E2E] Building Docker image '$($script:IMAGE_NAME)' from $($script:repoDir) ..." -ForegroundColor Cyan
            Write-Host "[E2E] This may take 10-20 minutes on first build." -ForegroundColor Yellow

            $dockerfilePath = Join-Path $script:repoDir 'docker_setup' 'Dockerfile.IMPACTncdGER'
            if (-not (Test-Path $dockerfilePath)) {
                throw "Dockerfile not found at $dockerfilePath"
            }

            # Build exactly as the GUI does: from repo root with --build-arg REPO_NAME
            Push-Location $script:repoDir
            try {
                $buildArgs = "build --build-arg REPO_NAME=$($script:REPO_NAME) -f `"$dockerfilePath`" -t $($script:IMAGE_NAME) --progress=plain `".`""
                $proc = Start-Process -FilePath 'docker' -ArgumentList $buildArgs -Wait -PassThru -NoNewWindow
                if ($proc.ExitCode -ne 0) {
                    # Fallback: try prerequisite build first
                    Write-Host "[E2E] Main build failed, trying prerequisite build..." -ForegroundColor Yellow
                    $prereqDockerfile = Join-Path $script:repoDir 'docker_setup' 'Dockerfile.prerequisite.IMPACTncdGER'
                    if (Test-Path $prereqDockerfile) {
                        Push-Location (Join-Path $script:repoDir 'docker_setup')
                        $prereqArgs = "build -f `"$prereqDockerfile`" -t $($script:IMAGE_NAME)-prerequisite --progress=plain `".`""
                        $proc2 = Start-Process -FilePath 'docker' -ArgumentList $prereqArgs -Wait -PassThru -NoNewWindow
                        Pop-Location
                        if ($proc2.ExitCode -eq 0) {
                            # Retry main build
                            $proc3 = Start-Process -FilePath 'docker' -ArgumentList $buildArgs -Wait -PassThru -NoNewWindow
                            if ($proc3.ExitCode -ne 0) {
                                throw 'Docker image build failed even after prerequisite build.'
                            }
                        } else {
                            throw 'Prerequisite image build failed.'
                        }
                    } else {
                        throw 'Main Docker image build failed and no prerequisite Dockerfile found.'
                    }
                }
            } finally {
                Pop-Location
            }
            Write-Host "[E2E] Image built successfully." -ForegroundColor Green
        } else {
            Write-Host "[E2E] Skipping build (IMPACT_E2E_SKIP_BUILD=1); reusing existing image." -ForegroundColor Yellow
        }

        # ── 5. Optionally register SSH key with GitHub ───────────────────
        $script:githubKeyId = $null
        if ($env:IMPACT_E2E_GITHUB_TOKEN) {
            Write-Host "[E2E] Registering SSH key with GitHub for auth test..." -ForegroundColor Cyan
            $pubKey = Get-Content "$($script:sshKeyPath).pub" -Raw
            $script:githubKeyId = Add-GitHubSshKey -Token $env:IMPACT_E2E_GITHUB_TOKEN `
                                       -Title "E2E-Test-$([guid]::NewGuid().ToString('N').Substring(0,6))" `
                                       -PublicKey $pubKey.Trim()
            Write-Host "[E2E] GitHub SSH key registered (id=$($script:githubKeyId))." -ForegroundColor Green
        } else {
            Write-Host "[E2E] IMPACT_E2E_GITHUB_TOKEN not set; SSH auth test will be skipped." -ForegroundColor Yellow
        }

        # ── 6. Start the container ───────────────────────────────────────
        # Stop / remove any leftover from a previous run
        docker stop $script:CONTAINER_NAME 2>$null | Out-Null
        docker rm   $script:CONTAINER_NAME 2>$null | Out-Null

        # Convert paths for Docker on Windows
        $repoMountSource = Convert-PathToDockerFormat -Path $script:repoDir
        $outputMount     = Convert-PathToDockerFormat -Path $script:outputDir
        $synthpopMount   = Convert-PathToDockerFormat -Path $script:synthpopDir
        $sshKeyMount     = Convert-PathToDockerFormat -Path $script:sshKeyPath
        $knownHostsMount = Convert-PathToDockerFormat -Path $script:knownHostsPath

        $containerKeyPath = "/home/rstudio/.ssh/id_ed25519_$($script:TEST_USER)"

        $dockerArgs = @(
            'run', '-d', '--rm',
            '--name', $script:CONTAINER_NAME,
            '-e', "PASSWORD=$($script:TEST_PASSWORD)",
            '-e', 'DISABLE_AUTH=false',
            '-e', 'USERID=1000', '-e', 'GROUPID=1000',
            '-e', "GIT_SSH_COMMAND=ssh -i $containerKeyPath -o IdentitiesOnly=yes -o UserKnownHostsFile=/etc/ssh/ssh_known_hosts -o StrictHostKeyChecking=yes",
            '--mount', "type=bind,source=$repoMountSource,target=/host-repo",
            '--mount', "type=bind,source=$repoMountSource,target=/home/rstudio/$($script:REPO_NAME)",
            '-e', 'REPO_SYNC_PATH=/host-repo', '-e', 'SYNC_ENABLED=true',
            '-p', "$($script:CONTAINER_PORT):8787",
            '--mount', "type=bind,source=$outputMount,target=/home/rstudio/$($script:REPO_NAME)/outputs",
            '--mount', "type=bind,source=$synthpopMount,target=/home/rstudio/$($script:REPO_NAME)/inputs/synthpop",
            '--mount', "type=bind,source=$sshKeyMount,target=/keys/id_ed25519_$($script:TEST_USER),readonly",
            '--mount', "type=bind,source=$knownHostsMount,target=/etc/ssh/ssh_known_hosts,readonly",
            '--workdir', "/home/rstudio/$($script:REPO_NAME)",
            $script:IMAGE_NAME
        )

        Write-Host "[E2E] Starting container: docker $($dockerArgs -join ' ')" -ForegroundColor Cyan
        $rc = docker @dockerArgs 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to start container: $rc"
        }
        Write-Host "[E2E] Container started: $rc" -ForegroundColor Green

        # ── 7. Fix SSH key permissions inside container ──────────────────
        $fixKeyCmd = "mkdir -p /home/rstudio/.ssh && cp /keys/id_ed25519_$($script:TEST_USER) $containerKeyPath && chmod 600 $containerKeyPath && chown 1000:1000 $containerKeyPath && cp /etc/ssh/ssh_known_hosts /home/rstudio/.ssh/known_hosts 2>/dev/null; chmod 644 /home/rstudio/.ssh/known_hosts 2>/dev/null; chown 1000:1000 /home/rstudio/.ssh/known_hosts 2>/dev/null; echo KEY_FIXED"
        $fixOut = docker exec $script:CONTAINER_NAME sh -c $fixKeyCmd 2>&1
        if ($fixOut -notmatch 'KEY_FIXED') {
            Write-Host "[E2E] WARNING: SSH key fix may have failed: $fixOut" -ForegroundColor Yellow
        }

        # ── 8. Wait for RStudio Server to be ready ───────────────────────
        Write-Host "[E2E] Waiting for RStudio Server on port $($script:CONTAINER_PORT)..." -ForegroundColor Cyan
        $ready = $false
        for ($i = 0; $i -lt 60; $i++) {
            Start-Sleep -Seconds 2
            try {
                $resp = Invoke-WebRequest -Uri "http://localhost:$($script:CONTAINER_PORT)" -UseBasicParsing -TimeoutSec 5 -ErrorAction SilentlyContinue
                if ($resp.StatusCode -eq 200 -or $resp.StatusCode -eq 302) {
                    $ready = $true
                    break
                }
            } catch {
                # Not ready yet
            }
        }
        if (-not $ready) {
            $logs = docker logs $script:CONTAINER_NAME 2>&1 | Select-Object -Last 30
            Write-Host "[E2E] Container logs:`n$($logs -join "`n")" -ForegroundColor Red
            throw 'RStudio Server did not become ready within 120 seconds.'
        }
        Write-Host "[E2E] RStudio Server is ready." -ForegroundColor Green
    }

    AfterAll {
        Write-Host "[E2E] Cleaning up..." -ForegroundColor Cyan

        # Stop container
        docker stop $script:CONTAINER_NAME 2>$null | Out-Null
        docker rm   $script:CONTAINER_NAME 2>$null | Out-Null

        # Remove GitHub SSH key if we added one
        if ($script:githubKeyId -and $env:IMPACT_E2E_GITHUB_TOKEN) {
            try {
                Remove-GitHubSshKey -Token $env:IMPACT_E2E_GITHUB_TOKEN -KeyId $script:githubKeyId
                Write-Host "[E2E] GitHub SSH key removed." -ForegroundColor Green
            } catch {
                Write-Host "[E2E] Failed to remove GitHub SSH key: $_" -ForegroundColor Yellow
            }
        }

        # Remove image + clone unless KEEP_ARTIFACTS is set
        if ($env:IMPACT_E2E_KEEP_ARTIFACTS -ne '1') {
            docker rmi $script:IMAGE_NAME 2>$null | Out-Null
            Remove-Item -Recurse -Force -Path $script:cloneRoot -ErrorAction SilentlyContinue
            Remove-Item -Recurse -Force -Path $script:sshDir    -ErrorAction SilentlyContinue
            Write-Host "[E2E] Artifacts cleaned up." -ForegroundColor Green
        } else {
            Write-Host "[E2E] Keeping artifacts (IMPACT_E2E_KEEP_ARTIFACTS=1)." -ForegroundColor Yellow
            Write-Host "[E2E]   Repo:  $($script:cloneRoot)" -ForegroundColor Yellow
            Write-Host "[E2E]   Image: $($script:IMAGE_NAME)" -ForegroundColor Yellow
        }
    }

    # ═══════════════════════════════════════════════════════════════════════
    #  Test: RStudio Server accessible
    # ═══════════════════════════════════════════════════════════════════════
    It 'RStudio Server responds on the mapped port' {
        $resp = Invoke-WebRequest -Uri "http://localhost:$($script:CONTAINER_PORT)" `
                    -UseBasicParsing -TimeoutSec 10
        # RStudio login page returns 200 and contains "RStudio" or sign-in form
        $resp.StatusCode | Should -BeIn @(200, 302)
        $resp.Content    | Should -Match 'rstudio|RStudio|sign-in|Sign In'
    }

    # ═══════════════════════════════════════════════════════════════════════
    #  Test: Repository is mounted correctly
    # ═══════════════════════════════════════════════════════════════════════
    It 'Repository is bind-mounted at /home/rstudio/<RepoName>' {
        $lsOut = docker exec $script:CONTAINER_NAME ls /home/rstudio/$($script:REPO_NAME) 2>&1
        $LASTEXITCODE | Should -Be 0
        # Expect key files from the repo
        $lsOut | Should -Contain 'global.R'
        $lsOut | Should -Contain 'docker_setup'
    }

    It 'The .Rproj file exists inside the container' {
        $rprojOut = docker exec $script:CONTAINER_NAME sh -c "ls /home/rstudio/$($script:REPO_NAME)/*.Rproj 2>/dev/null" 2>&1
        $LASTEXITCODE | Should -Be 0
        $rprojOut | Should -Match '\.Rproj$'
    }

    It 'Output directory is mounted and writable' {
        $touchOut = docker exec --user rstudio $script:CONTAINER_NAME sh -c "touch /home/rstudio/$($script:REPO_NAME)/outputs/.e2e_test_write && echo WRITE_OK" 2>&1
        $touchOut | Should -Match 'WRITE_OK'
        # Clean up
        docker exec --user rstudio $script:CONTAINER_NAME rm -f "/home/rstudio/$($script:REPO_NAME)/outputs/.e2e_test_write" 2>$null
    }

    It 'Synthpop directory is mounted' {
        $dirOut = docker exec $script:CONTAINER_NAME test -d "/home/rstudio/$($script:REPO_NAME)/inputs/synthpop" 2>&1
        $LASTEXITCODE | Should -Be 0
    }

    # ═══════════════════════════════════════════════════════════════════════
    #  Test: R environment is functional
    # ═══════════════════════════════════════════════════════════════════════
    It 'R is available and the correct version' {
        $rVer = docker exec $script:CONTAINER_NAME R --version 2>&1 | Select-Object -First 1
        $LASTEXITCODE | Should -Be 0
        $rVer | Should -Match 'R version'
    }

    It 'The IMPACTncdGer R package is installed' {
        # The Dockerfile builds and installs the package at image build time
        $pkgCheck = docker exec --user rstudio $script:CONTAINER_NAME Rscript -e "cat(nzchar(system.file(package='IMPACTncdGer')))" 2>&1
        $pkgCheck | Should -Match 'TRUE'
    }

    It 'CKutils R package is available' {
        $pkgCheck = docker exec --user rstudio $script:CONTAINER_NAME Rscript -e "cat(nzchar(system.file(package='CKutils')))" 2>&1
        $pkgCheck | Should -Match 'TRUE'
    }

    # ═══════════════════════════════════════════════════════════════════════
    #  Test: global.R can be sourced (core initialization)
    # ═══════════════════════════════════════════════════════════════════════
    It 'global.R can be sourced without errors' {
        # global.R does: library(CKutils), dependencies(), library(IMPACTncdGer)
        # Run in non-interactive mode to skip the interactive package build logic
        $globalOut = docker exec --user rstudio $script:CONTAINER_NAME `
            Rscript -e "setwd('/home/rstudio/$($script:REPO_NAME)'); tryCatch({ source('global.R'); cat('GLOBAL_OK') }, error = function(e) cat(paste('GLOBAL_ERROR:', e`$message)))" 2>&1
        $globalJoined = $globalOut -join "`n"
        $globalJoined | Should -Match 'GLOBAL_OK'
        $globalJoined | Should -Not -Match 'GLOBAL_ERROR'
    }

    # ═══════════════════════════════════════════════════════════════════════
    #  Test: Git configuration inside the container
    # ═══════════════════════════════════════════════════════════════════════
    It 'Git is configured to use SSH for github.com' {
        # The Dockerfile sets: git config --system url."git@github.com:".insteadOf "https://github.com/"
        $gitConfig = docker exec $script:CONTAINER_NAME git config --system --get 'url.git@github.com:.insteadof' 2>&1
        $LASTEXITCODE | Should -Be 0
        $gitConfig | Should -Match 'https://github.com/'
    }

    It 'SSH key is correctly placed inside the container' {
        $keyCheck = docker exec --user rstudio $script:CONTAINER_NAME sh -c "test -f /home/rstudio/.ssh/id_ed25519_$($script:TEST_USER) && stat -c '%a' /home/rstudio/.ssh/id_ed25519_$($script:TEST_USER)" 2>&1
        $LASTEXITCODE | Should -Be 0
        $keyCheck | Should -Be '600'
    }

    It 'Known hosts file contains github.com' {
        $knownHosts = docker exec --user rstudio $script:CONTAINER_NAME cat /home/rstudio/.ssh/known_hosts 2>&1
        $knownHosts | Should -Match 'github\.com'
    }

    It 'GIT_SSH_COMMAND environment variable is set correctly' {
        $gitSshCmd = docker exec $script:CONTAINER_NAME printenv GIT_SSH_COMMAND 2>&1
        $gitSshCmd | Should -Match "id_ed25519_$($script:TEST_USER)"
        $gitSshCmd | Should -Match 'IdentitiesOnly=yes'
    }

    # ═══════════════════════════════════════════════════════════════════════
    #  Test: GitHub SSH authentication (requires IMPACT_E2E_GITHUB_TOKEN)
    # ═══════════════════════════════════════════════════════════════════════
    It 'Can authenticate to GitHub via SSH from inside the container' -Skip:(-not $env:IMPACT_E2E_GITHUB_TOKEN) {
        # ssh -T git@github.com exits with code 1 on success (prints "Hi <user>!")
        # and exits with 255 on auth failure
        $sshAuth = docker exec --user rstudio $script:CONTAINER_NAME `
            ssh -i "/home/rstudio/.ssh/id_ed25519_$($script:TEST_USER)" `
                -o IdentitiesOnly=yes `
                -o UserKnownHostsFile=/home/rstudio/.ssh/known_hosts `
                -o StrictHostKeyChecking=yes `
                -T git@github.com 2>&1
        $authJoined = $sshAuth -join "`n"
        # GitHub says "Hi <user>! You've successfully authenticated" even with exit code 1
        $authJoined | Should -Match 'successfully authenticated'
    }

    It 'Can execute git pull from inside the container' -Skip:(-not $env:IMPACT_E2E_GITHUB_TOKEN) {
        # git pull should succeed (or say "Already up to date")
        $pullOut = docker exec --user rstudio --workdir "/home/rstudio/$($script:REPO_NAME)" $script:CONTAINER_NAME `
            git pull 2>&1
        $pullJoined = $pullOut -join "`n"
        # Should either pull successfully or already be up to date
        $pullJoined | Should -Match 'Already up to date|Updating|Fast-forward'
    }

    # ═══════════════════════════════════════════════════════════════════════
    #  Test: Build-DockerRunCommand produces args matching what we used
    # ═══════════════════════════════════════════════════════════════════════
    It 'Build-DockerRunCommand output is consistent with the actual container args' {
        $state = New-TestSessionState -UserName $script:TEST_USER -Password $script:TEST_PASSWORD -Location 'LOCAL'
        $state.SelectedRepo  = $script:REPO_NAME
        $state.ContainerName = $script:CONTAINER_NAME

        $args = Build-DockerRunCommand -State $state `
            -Port $script:CONTAINER_PORT `
            -UseVolumes $false `
            -ImageName $script:IMAGE_NAME `
            -ProjectRoot (Convert-PathToDockerFormat -Path $script:repoDir) `
            -OutputDir (Convert-PathToDockerFormat -Path $script:outputDir) `
            -SynthpopDir (Convert-PathToDockerFormat -Path $script:synthpopDir) `
            -SshKeyPath $script:sshKeyPath `
            -KnownHostsPath $script:knownHostsPath

        $joined = $args -join ' '

        # Verify essential parts match what we actually started
        $joined | Should -Match '^run -d --rm'
        $joined | Should -Match "--name $($script:CONTAINER_NAME)"
        $joined | Should -Match "PASSWORD=$($script:TEST_PASSWORD)"
        $joined | Should -Match "$($script:CONTAINER_PORT):8787"
        $joined | Should -Match "type=bind.*outputs"
        $joined | Should -Match "type=bind.*synthpop"
        $joined | Should -Match "$($script:IMAGE_NAME)$"
    }
}
