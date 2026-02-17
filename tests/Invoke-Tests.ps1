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
