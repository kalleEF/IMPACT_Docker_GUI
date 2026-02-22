<#
.SYNOPSIS
    Unified test runner for the IMPACT Docker GUI.

    Supports two modes:
      -Tag   : Run a specific test suite directly (e.g. -Tag Unit)
      -Level : Run suites cumulatively up to a given level (e.g. -Level DockerSsh
               runs Unit + Integration + DockerSsh)

    If neither -Tag nor -Level is specified, defaults to Unit + Integration.

    Usage:
        pwsh tests/Invoke-Tests.ps1                              # Unit + Integration
        pwsh tests/Invoke-Tests.ps1 -Tag Unit                    # Unit only
        pwsh tests/Invoke-Tests.ps1 -Tag Integration             # Integration only
        pwsh tests/Invoke-Tests.ps1 -Tag DockerSsh               # DockerSsh (auto-setups container)
        pwsh tests/Invoke-Tests.ps1 -Tag ImageValidation         # ImageValidation
        pwsh tests/Invoke-Tests.ps1 -Tag RemoteE2E               # RemoteE2E (auto-setups workstation)
        pwsh tests/Invoke-Tests.ps1 -Level All                   # All suites sequentially
        pwsh tests/Invoke-Tests.ps1 -Level RemoteE2E             # Unit -> ... -> RemoteE2E
        pwsh tests/Invoke-Tests.ps1 -Level All -GitHubToken ghp_xxx
        pwsh tests/Invoke-Tests.ps1 -Tag ImageValidation -SkipBuild -KeepArtifacts
#>
param(
    [string[]]$Tag,

    [ValidateSet('Unit','Integration','DockerSsh','ImageValidation','RemoteE2E','All')]
    [string]$Level,

    [string[]]$ExcludeTag,
    [string]$GitHubToken,
    [switch]$SkipBuild,
    [switch]$KeepArtifacts,
    [switch]$CodeCoverage
)

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path

# ── Ensure Pester 5+ ─────────────────────────────────────────────────────────
$mod = Get-Module Pester -ListAvailable | Sort-Object Version -Descending | Select-Object -First 1
if (-not $mod -or $mod.Version.Major -lt 5) {
    Write-Host 'Installing Pester 5...' -ForegroundColor Yellow
    Install-Module Pester -Force -Scope CurrentUser -MinimumVersion 5.0.0 -SkipPublisherCheck
}
Import-Module Pester -MinimumVersion 5.0.0

# Source test helpers
. (Join-Path $PSScriptRoot 'Helpers' 'TestSessionState.ps1')

# ── Load .env ─────────────────────────────────────────────────────────────────
function Load-DotEnv {
    param([string]$EnvPath = (Join-Path $repoRoot '.env'))
    if (-not (Test-Path $EnvPath)) { return }
    $lines = Get-Content $EnvPath -ErrorAction SilentlyContinue | ForEach-Object { $_.Trim() }
    foreach ($ln in $lines) {
        if (-not $ln -or $ln.StartsWith('#') -or $ln.StartsWith(';')) { continue }
        if ($ln -notmatch '=') { continue }
        $kv = $ln -split '=', 2
        $k = $kv[0].Trim()
        $v = $kv[1].Trim()
        if ($v.StartsWith('"') -and $v.EndsWith('"')) { $v = $v.Trim('"') }
        if ($v.StartsWith("'") -and $v.EndsWith("'")) { $v = $v.Trim("'") }
        if ($k -match 'TOKEN|KEY|SECRET') {
            $masked = if ($v.Length -gt 8) { "$($v.Substring(0,4))...$($v.Substring($v.Length-4))" } else { '***' }
            Write-Host "  Loaded env: $k = $masked"
        } else {
            Write-Host "  Loaded env: $k" -ForegroundColor DarkGray
        }
        Set-Item -Path "env:$k" -Value $v
    }
}
Load-DotEnv

# ── Suite definitions ─────────────────────────────────────────────────────────
$suites = [ordered]@{
    Unit            = @{ Path = "$PSScriptRoot/Unit.Tests.ps1";            Tag = 'Unit';            Needs = $null }
    Integration     = @{ Path = "$PSScriptRoot/Integration.Tests.ps1";     Tag = 'Integration';     Needs = $null }
    DockerSsh       = @{ Path = "$PSScriptRoot/DockerSsh.Tests.ps1";       Tag = 'DockerSsh';       Needs = 'Docker + SSHD container' }
    ImageValidation = @{ Path = "$PSScriptRoot/ImageValidation.Tests.ps1"; Tag = 'ImageValidation'; Needs = 'Docker + Internet' }
    RemoteE2E       = @{ Path = "$PSScriptRoot/RemoteE2E.Tests.ps1";       Tag = 'RemoteE2E';       Needs = 'Docker + Internet + DooD workstation' }
}
$levelOrder = @('Unit','Integration','DockerSsh','ImageValidation','RemoteE2E')

# ── Determine which suites to run ─────────────────────────────────────────────
if ($Tag -and $Level) {
    Write-Host 'ERROR: -Tag and -Level are mutually exclusive.' -ForegroundColor Red
    exit 1
}

if ($Tag) {
    # -Tag mode: run exactly the specified tag(s) directly
    $suitesToRun = @($Tag)
} elseif ($Level) {
    # -Level mode: cumulative from Unit up to $Level
    if ($Level -eq 'All') {
        $runUpTo = $levelOrder.Count - 1
    } else {
        $runUpTo = $levelOrder.IndexOf($Level)
    }
    $suitesToRun = $levelOrder[0..$runUpTo]
} else {
    # Default: Unit + Integration
    $suitesToRun = @('Unit','Integration')
}

# ── Banner ────────────────────────────────────────────────────────────────────
Write-Host ''
Write-Host '=============================================' -ForegroundColor Cyan
Write-Host '  IMPACT Docker GUI - Test Runner' -ForegroundColor Cyan
Write-Host '=============================================' -ForegroundColor Cyan
Write-Host "  Suites: $($suitesToRun -join ' + ')" -ForegroundColor White

# ── Set up E2E environment variables ──────────────────────────────────────────
$needsE2E = ($suitesToRun -contains 'ImageValidation') -or ($suitesToRun -contains 'RemoteE2E')
if ($needsE2E) {
    if ($GitHubToken) {
        $env:IMPACT_E2E_GITHUB_TOKEN = $GitHubToken
        Write-Host '  GitHub token: provided (SSH auth tests ENABLED)' -ForegroundColor Green
    } elseif ($env:IMPACT_E2E_GITHUB_TOKEN) {
        Write-Host '  GitHub token: found in env (SSH auth tests ENABLED)' -ForegroundColor Green
    } else {
        Write-Host '  GitHub token: not set (SSH auth tests will be SKIPPED)' -ForegroundColor Yellow
    }
    if ($SkipBuild) {
        $env:IMPACT_E2E_SKIP_BUILD = '1'
        Write-Host '  Docker build: SKIP (reusing existing image)' -ForegroundColor Yellow
    } else {
        $env:IMPACT_E2E_SKIP_BUILD = $null
    }
    if ($KeepArtifacts) {
        $env:IMPACT_E2E_KEEP_ARTIFACTS = '1'
        Write-Host '  Artifacts: KEEP after tests' -ForegroundColor Yellow
    } else {
        $env:IMPACT_E2E_KEEP_ARTIFACTS = $null
    }
}
Write-Host ''

# ── Helper: detect local Docker context ───────────────────────────────────────
function Get-LocalDockerContext {
    $ctxList = docker context ls --format "{{.Name}}" 2>$null
    $localCtx = 'desktop-linux'
    if ($ctxList -notcontains $localCtx) { $localCtx = 'default' }
    return $localCtx
}

# ── Helper: ensure SSHD container for DockerSsh ──────────────────────────────
function Ensure-SshdContainer {
    $dockerOk = $false
    try { docker info 2>$null | Out-Null; $dockerOk = ($LASTEXITCODE -eq 0) } catch {}
    if (-not $dockerOk) {
        Write-Host '  SKIP DockerSsh - Docker not running' -ForegroundColor Yellow
        return $false
    }

    $savedDockerContext = $env:DOCKER_CONTEXT
    $localCtx = Get-LocalDockerContext
    $env:DOCKER_CONTEXT = $localCtx

    # Ensure SSH key
    $sshDir = Join-Path ([System.IO.Path]::GetTempPath()) 'impact_test_ssh'
    New-Item -ItemType Directory -Path $sshDir -Force | Out-Null
    $keyPath = Join-Path $sshDir 'id_test'
    if (-not (Test-Path $keyPath)) {
        ssh-keygen -t ed25519 -f $keyPath -N "" -q 2>$null
    }

    $containerRunning = docker ps --filter "name=sshd-test" --format "{{.Names}}" 2>$null
    $hasContainer = ($containerRunning | Where-Object { $_ -eq 'sshd-test' }) -ne $null
    if (-not $hasContainer) {
        Write-Host "  Setting up SSHD test container (context: $localCtx)..." -ForegroundColor Cyan
        docker build -t impact-sshd-test -f "$PSScriptRoot/Helpers/SshdContainer.Dockerfile" $repoRoot 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Host '  SKIP DockerSsh - image build failed' -ForegroundColor Yellow
            $env:DOCKER_CONTEXT = $savedDockerContext; return $false
        }
        docker rm -f sshd-test 2>$null | Out-Null
        docker run -d -p 2222:22 --name sshd-test impact-sshd-test | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Host '  SKIP DockerSsh - container failed to start' -ForegroundColor Yellow
            $env:DOCKER_CONTEXT = $savedDockerContext; return $false
        }
        Start-Sleep -Seconds 3
        $script:cleanupSshd = $true
        $script:cleanupSshdCtx = $localCtx
    }

    # Copy key (always, in case it was regenerated)
    docker cp "$keyPath.pub" sshd-test:/home/testuser/.ssh/authorized_keys 2>$null | Out-Null
    docker exec sshd-test chown testuser:testuser /home/testuser/.ssh/authorized_keys 2>$null | Out-Null
    docker exec sshd-test chmod 600 /home/testuser/.ssh/authorized_keys 2>$null | Out-Null

    $env:DOCKER_CONTEXT = $savedDockerContext

    # Set env vars for tests
    $env:IMPACT_TEST_SSH_HOST = 'localhost'
    $env:IMPACT_TEST_SSH_PORT = '2222'
    $env:IMPACT_TEST_SSH_USER = 'testuser'
    $env:IMPACT_TEST_SSH_KEY  = $keyPath

    # Verify SSH connectivity
    Write-Host '    Verifying SSH connectivity...' -ForegroundColor DarkGray
    $sshOk = $false
    for ($attempt = 1; $attempt -le 10; $attempt++) {
        $testResult = ssh -p 2222 -i $keyPath -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes -o IdentitiesOnly=yes -o ConnectTimeout=2 testuser@localhost "echo OK" 2>$null
        if ($testResult -match 'OK') { $sshOk = $true; break }
        Start-Sleep -Seconds 1
    }
    if (-not $sshOk) {
        Write-Host '  WARN SSH connectivity check failed after 10 attempts' -ForegroundColor Yellow
    } else {
        Write-Host "    SSH connected on attempt $attempt." -ForegroundColor DarkGray
    }

    Write-Host '  SSHD container ready.' -ForegroundColor Green
    return $true
}

# ── Helper: ensure Workstation container for RemoteE2E ────────────────────────
function Ensure-WorkstationContainer {
    $dockerOk = $false
    try { docker info 2>$null | Out-Null; $dockerOk = ($LASTEXITCODE -eq 0) } catch {}
    if (-not $dockerOk) {
        Write-Host '  SKIP RemoteE2E - Docker not running' -ForegroundColor Yellow
        return $false
    }

    $savedDockerContext = $env:DOCKER_CONTEXT
    $localCtx = Get-LocalDockerContext
    $env:DOCKER_CONTEXT = $localCtx

    # Ensure SSH key
    $sshDir = Join-Path ([System.IO.Path]::GetTempPath()) 'impact_test_ssh'
    New-Item -ItemType Directory -Path $sshDir -Force | Out-Null
    $wsKeyPath = Join-Path $sshDir 'id_ws_test'
    $keyOk = $false
    if (Test-Path $wsKeyPath) {
        $pubOut = & ssh-keygen -y -f $wsKeyPath 2>$null
        if ($LASTEXITCODE -eq 0 -and $pubOut) { $keyOk = $true }
    }
    if (-not $keyOk) {
        Remove-Item -Force "$wsKeyPath", "$($wsKeyPath).pub" -ErrorAction SilentlyContinue
        ssh-keygen -t ed25519 -f $wsKeyPath -N "" -q 2>$null
        $pubOut = & ssh-keygen -y -f $wsKeyPath 2>$null
        if ($LASTEXITCODE -ne 0 -or -not $pubOut) {
            Write-Host "  SKIP RemoteE2E - failed to generate usable SSH key" -ForegroundColor Yellow
            $env:DOCKER_CONTEXT = $savedDockerContext; return $false
        }
    }

    $wsContainerRunning = docker ps --filter "name=workstation-test" --format "{{.Names}}" 2>$null
    $hasWsContainer = ($wsContainerRunning | Where-Object { $_ -eq 'workstation-test' }) -ne $null
    if (-not $hasWsContainer) {
        Write-Host "  Setting up Workstation container (DooD, context: $localCtx)..." -ForegroundColor Cyan
        docker build -t impact-workstation-test -f "$PSScriptRoot/Helpers/WorkstationContainer.Dockerfile" $repoRoot 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Host '  SKIP RemoteE2E - workstation image build failed' -ForegroundColor Yellow
            $env:DOCKER_CONTEXT = $savedDockerContext; return $false
        }
        docker rm -f workstation-test 2>$null | Out-Null
        $socketMount = '/var/run/docker.sock:/var/run/docker.sock'
        docker run -d -p 2223:22 -v $socketMount --name workstation-test impact-workstation-test | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Host '  SKIP RemoteE2E - workstation container failed to start' -ForegroundColor Yellow
            $env:DOCKER_CONTEXT = $savedDockerContext; return $false
        }
        Start-Sleep -Seconds 3
        $script:cleanupWorkstation = $true
        $script:cleanupWorkstationCtx = $localCtx
    }

    # Copy key (always)
    docker cp "$wsKeyPath.pub" workstation-test:/home/testuser/.ssh/authorized_keys 2>$null | Out-Null
    docker exec workstation-test chown testuser:testuser /home/testuser/.ssh/authorized_keys 2>$null | Out-Null
    docker exec workstation-test chmod 600 /home/testuser/.ssh/authorized_keys 2>$null | Out-Null

    $env:DOCKER_CONTEXT = $savedDockerContext

    # Set env vars for tests
    $env:IMPACT_REMOTE_E2E_SSH_HOST = 'localhost'
    $env:IMPACT_REMOTE_E2E_SSH_PORT = '2223'
    $env:IMPACT_REMOTE_E2E_SSH_USER = 'testuser'
    $env:IMPACT_REMOTE_E2E_SSH_KEY  = $wsKeyPath

    # Verify SSH connectivity
    Write-Host '    Verifying SSH to workstation...' -ForegroundColor DarkGray
    $sshOk = $false
    for ($attempt = 1; $attempt -le 10; $attempt++) {
        $testResult = ssh -p 2223 -i $wsKeyPath -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes -o IdentitiesOnly=yes -o ConnectTimeout=2 testuser@localhost "echo OK" 2>$null
        if ($testResult -match 'OK') { $sshOk = $true; break }
        Start-Sleep -Seconds 1
    }
    if (-not $sshOk) {
        Write-Host '  WARN SSH to workstation failed after 10 attempts' -ForegroundColor Yellow
    } else {
        Write-Host "    SSH connected on attempt $attempt." -ForegroundColor DarkGray
    }

    # Verify Docker CLI through SSH (DooD)
    Write-Host '    Verifying Docker through SSH (DooD)...' -ForegroundColor DarkGray
    $dockerViaSsh = ssh -p 2223 -i $wsKeyPath -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes -o IdentitiesOnly=yes -o ConnectTimeout=5 testuser@localhost "docker info --format '{{.ServerVersion}}'" 2>$null
    if ($dockerViaSsh) {
        Write-Host "    Docker via SSH OK (server $dockerViaSsh)." -ForegroundColor DarkGray
    } else {
        Write-Host '  WARN Docker not accessible through SSH - tests may fail' -ForegroundColor Yellow
    }

    Write-Host '  Workstation container ready.' -ForegroundColor Green
    return $true
}

# ── Run suites ────────────────────────────────────────────────────────────────
$totalPassed  = 0
$totalFailed  = 0
$totalSkipped = 0
$results      = @()

foreach ($name in $suitesToRun) {
    $suite = $suites[$name]
    if (-not $suite) {
        Write-Host "  SKIP $name - unknown suite" -ForegroundColor Yellow
        continue
    }

    $testFile = $suite.Path
    if (-not (Test-Path $testFile)) {
        Write-Host "  SKIP $name - file not found: $testFile" -ForegroundColor Yellow
        continue
    }

    # ── Pre-suite setup ───────────────────────────────────────────────────
    if ($name -eq 'DockerSsh') {
        $ok = Ensure-SshdContainer
        if (-not $ok) { continue }
    }

    if ($name -eq 'ImageValidation') {
        $dockerOk = $false
        try { docker info 2>$null | Out-Null; $dockerOk = ($LASTEXITCODE -eq 0) } catch {}
        if (-not $dockerOk) {
            Write-Host '  SKIP ImageValidation - Docker not running' -ForegroundColor Yellow
            continue
        }
    }

    if ($name -eq 'RemoteE2E') {
        $ok = Ensure-WorkstationContainer
        if (-not $ok) { continue }
    }

    # ── Run preflight for E2E suites ──────────────────────────────────────
    $preflightSuites = @('ImageValidation','RemoteE2E','DockerSsh')
    if ($preflightSuites -contains $name) {
        Write-Host "  Preflight checks for $name ..." -ForegroundColor Cyan
        $preConfig = New-PesterConfiguration
        $preConfig.Run.Path = "$PSScriptRoot/Preflight.Tests.ps1"
        $preConfig.Filter.Tag = @('Preflight')
        $preConfig.Output.Verbosity = 'Detailed'
        $preConfig.Run.Exit = $false
        $preConfig.Run.PassThru = $true
        $preResult = Invoke-Pester -Configuration $preConfig
        if ($preResult.FailedCount -gt 0) {
            Write-Host "  SKIP $name - preflight checks failed" -ForegroundColor Yellow
            continue
        }
    }

    # ── Run the suite ─────────────────────────────────────────────────────
    Write-Host "  RUN   $name ($testFile)" -ForegroundColor Cyan
    $sw = [System.Diagnostics.Stopwatch]::StartNew()

    $config = New-PesterConfiguration
    $config.Run.Path     = $testFile
    $config.Run.PassThru = $true
    $config.Output.Verbosity = 'Detailed'
    $config.TestResult.Enabled      = $true
    $config.TestResult.OutputFormat  = 'NUnitXml'
    $config.TestResult.OutputPath    = "$PSScriptRoot/TestResults-$name.xml"
    if ($ExcludeTag) { $config.Filter.ExcludeTag = $ExcludeTag }
    if ($CodeCoverage) { $config.CodeCoverage.Enabled = $true }

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

# ── Cleanup containers ────────────────────────────────────────────────────────
if ($script:cleanupSshd) {
    Write-Host '  Cleaning up SSHD test container...' -ForegroundColor Cyan
    $savedCtx = $env:DOCKER_CONTEXT
    $env:DOCKER_CONTEXT = if ($script:cleanupSshdCtx) { $script:cleanupSshdCtx } else { 'default' }
    docker stop sshd-test 2>$null | Out-Null
    docker rm sshd-test 2>$null | Out-Null
    $env:DOCKER_CONTEXT = $savedCtx
}
if ($script:cleanupWorkstation) {
    Write-Host '  Cleaning up Workstation test container...' -ForegroundColor Cyan
    $savedCtx = $env:DOCKER_CONTEXT
    $env:DOCKER_CONTEXT = if ($script:cleanupWorkstationCtx) { $script:cleanupWorkstationCtx } else { 'default' }
    docker stop workstation-test 2>$null | Out-Null
    docker rm workstation-test 2>$null | Out-Null
    $env:DOCKER_CONTEXT = $savedCtx
}

# ── Persist test artifacts ────────────────────────────────────────────────────
try {
    $resultFiles = Get-ChildItem -Path "$PSScriptRoot/TestResults*.xml" -ErrorAction SilentlyContinue
    foreach ($f in $resultFiles) {
        if ($f.BaseName -match '^TestResults-(.+)$') {
            $suiteName = $matches[1].ToLower()
        } else {
            $suiteName = 'general'
        }
        Save-TestArtifacts -Suite $suiteName -ExtraFiles @($f.FullName)
    }
} catch {
    Write-Warning "Failed to persist test results: $($_.Exception.Message)"
}

# ── Summary ───────────────────────────────────────────────────────────────────
Write-Host '=============================================' -ForegroundColor Cyan
Write-Host '  Summary' -ForegroundColor Cyan
Write-Host '=============================================' -ForegroundColor Cyan
$results | Format-Table -AutoSize
Write-Host "  Total: Passed=$totalPassed  Failed=$totalFailed  Skipped=$totalSkipped" -ForegroundColor $(if ($totalFailed -gt 0) { 'Red' } else { 'Green' })
Write-Host ''

if ($totalFailed -gt 0) { exit 1 }
