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

Invoke-Pester -Configuration $config
