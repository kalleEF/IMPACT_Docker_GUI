<#
.SYNOPSIS
    Run all IMPACT Docker GUI tests, from quick unit tests to full E2E.

    Usage:
        pwsh -File Run-AllTests.ps1                          # Unit + Integration (default)
        pwsh -File Run-AllTests.ps1 -Level E2E               # Up to E2E
        pwsh -File Run-AllTests.ps1 -Level All               # Everything
        pwsh -File Run-AllTests.ps1 -Level E2E -GitHubToken ghp_xxx  # E2E with SSH auth tests

    Levels (cumulative):
        Unit         - 65 pure-logic tests (~5s, no external deps)
        Integration  - + 25 mocked integration tests (~10s total)
        DockerSsh    - + SSH tests against SSHD container (~30s total, needs Docker)
        E2E          - + 16 full container lifecycle tests (~15-25 min, needs Docker + Internet)
        All          - Everything above

    Optional parameters:
        -GitHubToken     PAT with admin:public_key scope. Enables 2 SSH auth tests in E2E.
        -SkipBuild       Reuse existing E2E Docker image (saves ~15 min on repeat runs).
        -KeepArtifacts   Keep cloned repo + Docker image after E2E tests (for debugging).
#>
param(
    [ValidateSet('Unit','Integration','DockerSsh','E2E','All')]
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
    Unit        = @{ Path = './tests/Unit.Tests.ps1';        Tag = 'Unit';        Needs = $null }
    Integration = @{ Path = './tests/Integration.Tests.ps1'; Tag = 'Integration'; Needs = $null }
    DockerSsh   = @{ Path = './tests/DockerSsh.Tests.ps1';   Tag = 'DockerSsh';   Needs = 'Docker + SSHD container' }
    E2E         = @{ Path = './tests/E2E.Tests.ps1';         Tag = 'E2E';         Needs = 'Docker + Internet' }
}

$levelOrder = @('Unit','Integration','DockerSsh','E2E')
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
if ($suitesToRun -contains 'E2E') {
    if ($GitHubToken) {
        $env:IMPACT_E2E_GITHUB_TOKEN = $GitHubToken
        Write-Host '  GitHub token: provided (SSH auth tests ENABLED)' -ForegroundColor Green
    } elseif ($env:IMPACT_E2E_GITHUB_TOKEN) {
        Write-Host '  GitHub token: found in env (SSH auth tests ENABLED)' -ForegroundColor Green
    } else {
        Write-Host '  GitHub token: not set (2 SSH auth tests will be SKIPPED)' -ForegroundColor Yellow
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

    # ── E2E: check Docker is available ───────────────────────────────────
    if ($name -eq 'E2E') {
        $dockerOk = $false
        try { docker info 2>$null | Out-Null; $dockerOk = ($LASTEXITCODE -eq 0) } catch {}
        if (-not $dockerOk) {
            Write-Host "  SKIP  E2E - Docker is not running" -ForegroundColor Yellow
            continue
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

# ── Cleanup DockerSsh container ──────────────────────────────────────────────
if ($script:cleanupSshd) {
    Write-Host '  Cleaning up SSHD test container...' -ForegroundColor Cyan
    $savedCtx = $env:DOCKER_CONTEXT
    $env:DOCKER_CONTEXT = if ($script:cleanupSshdCtx) { $script:cleanupSshdCtx } else { 'desktop-linux' }
    docker stop sshd-test 2>$null | Out-Null
    docker rm sshd-test 2>$null | Out-Null
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
