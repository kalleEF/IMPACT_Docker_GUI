<#
.SYNOPSIS
    Run all IMPACT Docker GUI tests, from quick unit tests to full E2E.

    Usage:
        pwsh -File Run-AllTests.ps1                                    # Unit + Integration (default)
        pwsh -File Run-AllTests.ps1 -Level DockerSsh                   # Up to DockerSsh
        pwsh -File Run-AllTests.ps1 -Level ImageValidation             # Up to ImageValidation
        pwsh -File Run-AllTests.ps1 -Level RemoteE2E                   # Full E2E
        pwsh -File Run-AllTests.ps1 -Level All                         # Everything
        pwsh -File Run-AllTests.ps1 -Level RemoteE2E -GitHubToken ghp_xxx

    Levels (cumulative):
        Unit             - 65 pure-logic tests (~5s, no external deps)
        Integration      - + 25 mocked integration tests (~10s total)
        DockerSsh        - + 6 SSH tests against SSHD container (~30s total, needs Docker)
        ImageValidation  - + ~14 image validation tests (~15-25 min, needs Docker + Internet)
        RemoteE2E        - + ~11 remote E2E tests (~20-40 min, needs Docker + Internet)
        All              - Everything above

    Optional parameters:
        -GitHubToken     PAT with SSH keys Read/Write permission. Enables SSH auth tests.
        -SkipBuild       Reuse existing Docker images (saves build time on repeat runs).
        -KeepArtifacts   Keep cloned repos + Docker images after tests (for debugging).
#>
param(
    [ValidateSet('Unit','Integration','DockerSsh','ImageValidation','RemoteE2E','All')]
    [string]$Level = 'Integration',

    [string]$GitHubToken,

    [switch]$SkipBuild,

    [switch]$KeepArtifacts
)

$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot

# ── Ensure Pester ────────────────────────────────────────────────────────────
$mod = Get-Module Pester -ListAvailable | Sort-Object Version -Descending | Select-Object -First 1
if (-not $mod -or $mod.Version.Major -lt 5) {
    Write-Host 'Installing Pester 5...' -ForegroundColor Yellow
    Install-Module Pester -Force -Scope CurrentUser -MinimumVersion 5.0.0 -SkipPublisherCheck
}
Import-Module Pester -MinimumVersion 5.0.0

# ── Determine which suites to run ────────────────────────────────────────────
$suites = [ordered]@{
    Unit            = @{ Path = './tests/Unit.Tests.ps1';            Tag = 'Unit';            Needs = $null }
    Integration     = @{ Path = './tests/Integration.Tests.ps1';     Tag = 'Integration';     Needs = $null }
    DockerSsh       = @{ Path = './tests/DockerSsh.Tests.ps1';       Tag = 'DockerSsh';       Needs = 'Docker + SSHD container' }
    ImageValidation = @{ Path = './tests/ImageValidation.Tests.ps1'; Tag = 'ImageValidation'; Needs = 'Docker + Internet' }
    RemoteE2E       = @{ Path = './tests/RemoteE2E.Tests.ps1';       Tag = 'RemoteE2E';       Needs = 'Docker + Internet + DooD workstation' }
}

$levelOrder = @('Unit','Integration','DockerSsh','ImageValidation','RemoteE2E')
if ($Level -eq 'All') {
    $runUpTo = $levelOrder.Count - 1
} else {
    $runUpTo = $levelOrder.IndexOf($Level)
}
$suitesToRun = $levelOrder[0..$runUpTo]

Write-Host ''
Write-Host '=============================================' -ForegroundColor Cyan
Write-Host '  IMPACT Docker GUI - Test Runner' -ForegroundColor Cyan
Write-Host '=============================================' -ForegroundColor Cyan
Write-Host "  Level: $Level  (running: $($suitesToRun -join ' + '))" -ForegroundColor White

# ── Set up optional E2E environment variables ────────────────────────────────
$needsE2E = ($suitesToRun -contains 'ImageValidation') -or ($suitesToRun -contains 'RemoteE2E')
if ($needsE2E) {
    if ($GitHubToken) {
        $env:IMPACT_E2E_GITHUB_TOKEN = $GitHubToken
        Write-Host '  GitHub token: provided (SSH auth tests ENABLED)' -ForegroundColor Green
    } elseif ($env:IMPACT_E2E_GITHUB_TOKEN) {
        Write-Host '  GitHub token: found in env (SSH auth tests ENABLED)' -ForegroundColor Green
    } else {
        Write-Host '  GitHub token: not set (SSH auth tests will be SKIPPED)' -ForegroundColor Yellow
        Write-Host '    Tip: pass -GitHubToken <PAT> to enable them' -ForegroundColor DarkGray
    }

    if ($SkipBuild) {
        $env:IMPACT_E2E_SKIP_BUILD = '1'
        Write-Host '  Docker build: SKIP (reusing existing image)' -ForegroundColor Yellow
    } else {
        $env:IMPACT_E2E_SKIP_BUILD = $null
        Write-Host '  Docker build: will build from scratch' -ForegroundColor White
    }

    if ($KeepArtifacts) {
        $env:IMPACT_E2E_KEEP_ARTIFACTS = '1'
        Write-Host '  Artifacts: KEEP after tests' -ForegroundColor Yellow
    } else {
        $env:IMPACT_E2E_KEEP_ARTIFACTS = $null
        Write-Host '  Artifacts: clean up after tests' -ForegroundColor White
    }
}
Write-Host ''

$totalPassed  = 0
$totalFailed  = 0
$totalSkipped = 0
$results      = @()

foreach ($name in $suitesToRun) {
    $suite = $suites[$name]
    $testFile = $suite.Path

    if (-not (Test-Path $testFile)) {
        Write-Host "  SKIP  $name - file not found: $testFile" -ForegroundColor Yellow
        continue
    }

    # ── DockerSsh: auto-setup SSHD container if not already running ──────
    if ($name -eq 'DockerSsh') {
        $dockerOk = $false
        try { docker info 2>$null | Out-Null; $dockerOk = ($LASTEXITCODE -eq 0) } catch {}
        if (-not $dockerOk) {
            Write-Host "  SKIP  DockerSsh - Docker is not running" -ForegroundColor Yellow
            continue
        }

        # Switch to local Docker context (SSHD container must run on localhost)
        $savedDockerContext = $env:DOCKER_CONTEXT
        $localCtx = 'desktop-linux'
        $ctxList = docker context ls --format "{{.Name}}" 2>$null
        if ($ctxList -notcontains $localCtx) { $localCtx = 'default' }
        $env:DOCKER_CONTEXT = $localCtx

        # Always ensure SSH key exists (may be deleted between runs)
        $sshDir  = Join-Path $env:TEMP 'impact_test_ssh'
        New-Item -ItemType Directory -Path $sshDir -Force | Out-Null
        $keyPath = Join-Path $sshDir 'id_test'
        if (-not (Test-Path $keyPath)) {
            ssh-keygen -t ed25519 -f $keyPath -N "" -q 2>$null
        }

        $containerRunning = docker ps --filter "name=sshd-test" --format "{{.Names}}" 2>$null
        $hasContainer = ($containerRunning | Where-Object { $_ -eq 'sshd-test' }) -ne $null
        if (-not $hasContainer) {
            Write-Host "  Setting up SSHD test container (context: $localCtx)..." -ForegroundColor Cyan

            Write-Host "    Building SSHD image..." -ForegroundColor DarkGray
            docker build -t impact-sshd-test -f tests/Helpers/SshdContainer.Dockerfile . 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) {
                Write-Host "  SKIP  DockerSsh - Docker image build failed" -ForegroundColor Yellow
                $env:DOCKER_CONTEXT = $savedDockerContext; continue
            }

            docker rm -f sshd-test 2>$null | Out-Null
            docker run -d -p 2222:22 --name sshd-test impact-sshd-test | Out-Null
            if ($LASTEXITCODE -ne 0) {
                Write-Host "  SKIP  DockerSsh - Container failed to start" -ForegroundColor Yellow
                $env:DOCKER_CONTEXT = $savedDockerContext; continue
            }

            Start-Sleep -Seconds 3
            docker cp "$keyPath.pub" sshd-test:/home/testuser/.ssh/authorized_keys
            docker exec sshd-test chown testuser:testuser /home/testuser/.ssh/authorized_keys
            docker exec sshd-test chmod 600 /home/testuser/.ssh/authorized_keys

            $script:cleanupSshd    = $true
            $script:cleanupSshdCtx = $localCtx
            Write-Host "  SSHD container ready." -ForegroundColor Green
        } else {
            Write-Host "  SSHD container already running." -ForegroundColor Green
            # Re-copy the key in case it was regenerated
            docker cp "$keyPath.pub" sshd-test:/home/testuser/.ssh/authorized_keys 2>$null | Out-Null
            docker exec sshd-test chown testuser:testuser /home/testuser/.ssh/authorized_keys 2>$null | Out-Null
            docker exec sshd-test chmod 600 /home/testuser/.ssh/authorized_keys 2>$null | Out-Null
        }

        # Restore Docker context
        $env:DOCKER_CONTEXT = $savedDockerContext

        # Set env vars for the test file
        $env:IMPACT_TEST_SSH_HOST = 'localhost'
        $env:IMPACT_TEST_SSH_PORT = '2222'
        $env:IMPACT_TEST_SSH_USER = 'testuser'
        $env:IMPACT_TEST_SSH_KEY  = $keyPath

        # Verify SSH connectivity before running tests
        Write-Host "    Verifying SSH connectivity..." -ForegroundColor DarkGray
        $sshOk = $false
        for ($attempt = 1; $attempt -le 10; $attempt++) {
            $testResult = ssh -p 2222 -i $keyPath -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes -o IdentitiesOnly=yes -o ConnectTimeout=2 testuser@localhost "echo OK" 2>$null
            if ($testResult -match 'OK') { $sshOk = $true; break }
            Start-Sleep -Seconds 1
        }
        if (-not $sshOk) {
            Write-Host "  WARN  SSH connectivity check failed after 10 attempts - tests may be skipped" -ForegroundColor Yellow
        } else {
            Write-Host "    SSH connected on attempt $attempt." -ForegroundColor DarkGray
        }
    }

    # ── ImageValidation: check Docker is available ─────────────────────
    if ($name -eq 'ImageValidation') {
        $dockerOk = $false
        try { docker info 2>$null | Out-Null; $dockerOk = ($LASTEXITCODE -eq 0) } catch {}
        if (-not $dockerOk) {
            Write-Host "  SKIP  ImageValidation - Docker is not running" -ForegroundColor Yellow
            continue
        }
    }

    # ── RemoteE2E: build workstation container with DooD ─────────────────
    if ($name -eq 'RemoteE2E') {
        $dockerOk = $false
        try { docker info 2>$null | Out-Null; $dockerOk = ($LASTEXITCODE -eq 0) } catch {}
        if (-not $dockerOk) {
            Write-Host "  SKIP  RemoteE2E - Docker is not running" -ForegroundColor Yellow
            continue
        }

        # Switch to local Docker context
        $savedDockerContext = $env:DOCKER_CONTEXT
        $localCtx = 'desktop-linux'
        $ctxList = docker context ls --format "{{.Name}}" 2>$null
        if ($ctxList -notcontains $localCtx) { $localCtx = 'default' }
        $env:DOCKER_CONTEXT = $localCtx

        # Ensure SSH key exists
        $sshDir  = Join-Path $env:TEMP 'impact_test_ssh'
        New-Item -ItemType Directory -Path $sshDir -Force | Out-Null
        $wsKeyPath = Join-Path $sshDir 'id_ws_test'
        if (-not (Test-Path $wsKeyPath)) {
            ssh-keygen -t ed25519 -f $wsKeyPath -N '""' -q 2>$null
        }

        $wsContainerRunning = docker ps --filter "name=workstation-test" --format "{{.Names}}" 2>$null
        $hasWsContainer = ($wsContainerRunning | Where-Object { $_ -eq 'workstation-test' }) -ne $null
        if (-not $hasWsContainer) {
            Write-Host "  Setting up Workstation test container (DooD, context: $localCtx)..." -ForegroundColor Cyan

            Write-Host "    Building Workstation image..." -ForegroundColor DarkGray
            docker build -t impact-workstation-test -f tests/Helpers/WorkstationContainer.Dockerfile . 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) {
                Write-Host "  SKIP  RemoteE2E - Workstation image build failed" -ForegroundColor Yellow
                $env:DOCKER_CONTEXT = $savedDockerContext; continue
            }

            docker rm -f workstation-test 2>$null | Out-Null

            # DooD: mount host Docker socket into workstation container
            $socketMount = '/var/run/docker.sock:/var/run/docker.sock'
            docker run -d -p 2223:22 -v $socketMount --name workstation-test impact-workstation-test | Out-Null
            if ($LASTEXITCODE -ne 0) {
                Write-Host "  SKIP  RemoteE2E - Workstation container failed to start" -ForegroundColor Yellow
                $env:DOCKER_CONTEXT = $savedDockerContext; continue
            }

            Start-Sleep -Seconds 3
            docker cp "$wsKeyPath.pub" workstation-test:/home/testuser/.ssh/authorized_keys
            docker exec workstation-test chown testuser:testuser /home/testuser/.ssh/authorized_keys
            docker exec workstation-test chmod 600 /home/testuser/.ssh/authorized_keys

            $script:cleanupWorkstation    = $true
            $script:cleanupWorkstationCtx = $localCtx
            Write-Host "    Workstation container ready." -ForegroundColor Green
        } else {
            Write-Host "  Workstation container already running." -ForegroundColor Green
            docker cp "$wsKeyPath.pub" workstation-test:/home/testuser/.ssh/authorized_keys 2>$null | Out-Null
            docker exec workstation-test chown testuser:testuser /home/testuser/.ssh/authorized_keys 2>$null | Out-Null
            docker exec workstation-test chmod 600 /home/testuser/.ssh/authorized_keys 2>$null | Out-Null
        }

        # Restore Docker context
        $env:DOCKER_CONTEXT = $savedDockerContext

        # Set env vars for RemoteE2E tests
        $env:IMPACT_REMOTE_E2E_SSH_HOST = 'localhost'
        $env:IMPACT_REMOTE_E2E_SSH_PORT = '2223'
        $env:IMPACT_REMOTE_E2E_SSH_USER = 'testuser'
        $env:IMPACT_REMOTE_E2E_SSH_KEY  = $wsKeyPath

        # Verify SSH connectivity to workstation
        Write-Host "    Verifying SSH to workstation..." -ForegroundColor DarkGray
        $sshOk = $false
        for ($attempt = 1; $attempt -le 10; $attempt++) {
            $testResult = ssh -p 2223 -i $wsKeyPath -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes -o IdentitiesOnly=yes -o ConnectTimeout=2 testuser@localhost "echo OK" 2>$null
            if ($testResult -match 'OK') { $sshOk = $true; break }
            Start-Sleep -Seconds 1
        }
        if (-not $sshOk) {
            Write-Host "  WARN  SSH to workstation failed after 10 attempts" -ForegroundColor Yellow
        } else {
            Write-Host "    SSH connected on attempt $attempt." -ForegroundColor DarkGray
        }

        # Verify Docker CLI is available through SSH (DooD sanity)
        Write-Host "    Verifying Docker through SSH (DooD)..." -ForegroundColor DarkGray
        $dockerViaSsh = ssh -p 2223 -i $wsKeyPath -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes -o IdentitiesOnly=yes -o ConnectTimeout=5 testuser@localhost "docker info --format '{{.ServerVersion}}'" 2>$null
        if ($dockerViaSsh) {
            Write-Host "    Docker via SSH OK (server $dockerViaSsh)." -ForegroundColor DarkGray
        } else {
            Write-Host "  WARN  Docker not accessible through SSH - RemoteE2E tests may fail" -ForegroundColor Yellow
        }
    }

    # ── Run the suite ────────────────────────────────────────────────────
    Write-Host "  RUN   $name ($testFile)" -ForegroundColor Cyan
    $sw = [System.Diagnostics.Stopwatch]::StartNew()

    $config = New-PesterConfiguration
    $config.Run.Path     = $testFile
    $config.Run.PassThru = $true
    $config.Output.Verbosity = 'Detailed'

    $r = Invoke-Pester -Configuration $config
    $sw.Stop()

    $totalPassed  += $r.PassedCount
    $totalFailed  += $r.FailedCount
    $totalSkipped += $r.SkippedCount
    $results += [PSCustomObject]@{
        Suite   = $name
        Passed  = $r.PassedCount
        Failed  = $r.FailedCount
        Skipped = $r.SkippedCount
        Time    = $sw.Elapsed.ToString('mm\:ss\.ff')
        Status  = if ($r.FailedCount -gt 0) { 'FAIL' } else { 'PASS' }
    }

    if ($r.FailedCount -gt 0) {
        Write-Host "  FAIL  $name - $($r.FailedCount) test(s) failed" -ForegroundColor Red
    } else {
        Write-Host "  PASS  $name - $($r.PassedCount) passed in $($sw.Elapsed.ToString('mm\:ss'))" -ForegroundColor Green
    }
    Write-Host ''
}

# ── Cleanup containers ───────────────────────────────────────────────────────
if ($script:cleanupSshd) {
    Write-Host '  Cleaning up SSHD test container...' -ForegroundColor Cyan
    $savedCtx = $env:DOCKER_CONTEXT
    $env:DOCKER_CONTEXT = if ($script:cleanupSshdCtx) { $script:cleanupSshdCtx } else { 'desktop-linux' }
    docker stop sshd-test 2>$null | Out-Null
    docker rm sshd-test 2>$null | Out-Null
    $env:DOCKER_CONTEXT = $savedCtx
}
if ($script:cleanupWorkstation) {
    Write-Host '  Cleaning up Workstation test container...' -ForegroundColor Cyan
    $savedCtx = $env:DOCKER_CONTEXT
    $env:DOCKER_CONTEXT = if ($script:cleanupWorkstationCtx) { $script:cleanupWorkstationCtx } else { 'desktop-linux' }
    docker stop workstation-test 2>$null | Out-Null
    docker rm workstation-test 2>$null | Out-Null
    $env:DOCKER_CONTEXT = $savedCtx
}

# ── Summary ──────────────────────────────────────────────────────────────────
Write-Host '=============================================' -ForegroundColor Cyan
Write-Host '  Summary' -ForegroundColor Cyan
Write-Host '=============================================' -ForegroundColor Cyan
$results | Format-Table -AutoSize
Write-Host "  Total: Passed=$totalPassed  Failed=$totalFailed  Skipped=$totalSkipped" -ForegroundColor $(if ($totalFailed -gt 0) { 'Red' } else { 'Green' })
Write-Host ''

if ($totalFailed -gt 0) { exit 1 }
