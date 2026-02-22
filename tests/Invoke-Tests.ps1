<#
.SYNOPSIS
    Pester test runner script.
    Usage:
        # All tests
        pwsh -File tests/Invoke-Tests.ps1

        # Unit tests only
        pwsh -File tests/Invoke-Tests.ps1 -Tag Unit

        # Integration tests only
        pwsh -File tests/Invoke-Tests.ps1 -Tag Integration

        # Real remote tests (requires VPN + reachable host)
        pwsh -File tests/Invoke-Tests.ps1 -Tag RealRemote

        # End-to-end tests (clones repo, builds image, starts container)
        pwsh -File tests/Invoke-Tests.ps1 -Tag E2E
#>
param(
    [string[]]$Tag,
    [string[]]$ExcludeTag,
    [switch]$CodeCoverage
)

$ErrorActionPreference = 'Stop'

# Ensure Pester 5+ is available
$mod = Get-Module Pester -ListAvailable | Sort-Object Version -Descending | Select-Object -First 1
if (-not $mod -or $mod.Version.Major -lt 5) {
    Write-Host 'Installing Pester 5...'
    Install-Module Pester -Force -Scope CurrentUser -MinimumVersion 5.0.0 -SkipPublisherCheck
}
Import-Module Pester -MinimumVersion 5.0.0

# Source test helpers (Save-TestArtifacts)
. (Join-Path $PSScriptRoot 'Helpers' 'TestSessionState.ps1')

# Load environment variables from repository root .env (if present)
function Load-DotEnv {
    param(
        [string]$EnvPath = (Join-Path (Join-Path $PSScriptRoot '..') '.env')
    )
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
        # Do not echo secrets
        if ($k -match 'TOKEN|KEY|SECRET') {
            $masked = if ($v.Length -gt 8) { "$($v.Substring(0,4))...$($v.Substring($v.Length-4))" } else { '***' }
            Write-Host "Loaded env: $k = $masked"
        } else {
            Write-Host "Loaded env: $k" -ForegroundColor DarkGray
        }
        $env:$k = $v
    }
}

Load-DotEnv

# Load base config
$configPath = Join-Path $PSScriptRoot '.pesterconfig.psd1'
$config = New-PesterConfiguration -Hashtable (Import-PowerShellDataFile $configPath)

if ($Tag)        { $config.Filter.Tag        = $Tag }
if ($ExcludeTag) { $config.Filter.ExcludeTag = $ExcludeTag }
if ($CodeCoverage) { $config.CodeCoverage.Enabled = $true }

# Run Preflight checks for Docker/SSH/image-validation scenarios so local runs
# fail fast with a clear test result and diagnostics (parity with CI).
$preflightTags = @('ImageValidation','RemoteE2E','DockerSsh')
$needsPreflight = $false
if (-not $Tag) { $needsPreflight = $true } else {
    foreach ($t in $Tag) { if ($preflightTags -contains $t) { $needsPreflight = $true; break } }
}
if ($needsPreflight) {
    Write-Host 'Running Preflight checks...' -ForegroundColor Cyan
    $preConfig = New-PesterConfiguration
    $preConfig.Run.Path = './tests/Preflight.Tests.ps1'
    $preConfig.Filter.Tag = @('Preflight')
    $preConfig.Output.Verbosity = 'Detailed'
    $preConfig.Run.Exit = $true
    $preConfig.TestResult.Enabled = $true
    $preConfig.TestResult.OutputFormat = 'NUnitXml'
    $preConfig.TestResult.OutputPath = './tests/TestResults-Preflight.xml'
    Invoke-Pester -Configuration $preConfig
}

Invoke-Pester -Configuration $config

# Persist any produced TestResults XML into the tests/artifacts folder for local runs
try {
    $resultFiles = Get-ChildItem -Path (Join-Path $PSScriptRoot 'TestResults*.xml') -ErrorAction SilentlyContinue
    foreach ($f in $resultFiles) {
        if ($f.BaseName -match '^TestResults-(.+)$') {
            $suiteName = $matches[1].ToLower()
        } elseif ($Tag) {
            $suiteName = ($Tag -join '-').ToLower()
        } else {
            $suiteName = 'general'
        }
        Save-TestArtifacts -Suite $suiteName -ExtraFiles @($f.FullName)
    }
} catch {
    Write-Warning "Failed to persist test results to artifacts: $($_.Exception.Message)"
}
