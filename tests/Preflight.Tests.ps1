#Requires -Modules Pester

<#
.SYNOPSIS
  Lightweight environment checks that E2E/image-validation depend on.

.Description
  These tests are intended to fail fast and provide clear diagnostics when
  required runtime dependencies (Docker, git, ssh-keygen, writable /tmp)
  are not available. They are run by `Invoke-Tests.ps1` before E2E suites
  and can be executed standalone with `-Tag Preflight`.
#>

Describe 'Preflight: environment checks' -Tag Preflight {

    It 'Docker CLI present and daemon reachable' {
        (Get-Command docker -ErrorAction SilentlyContinue) | Should -Not -BeNullOrEmpty -Because 'Docker CLI must be installed'

        $dockerInfo = docker info 2>&1
        $LASTEXITCODE | Should -Be 0 -Because "Docker daemon must be running (`docker info` should succeed). Output: $($dockerInfo -join ' ')"
    }

    It 'git CLI present and IMPACT repo reachable' {
        (Get-Command git -ErrorAction SilentlyContinue) | Should -Not -BeNullOrEmpty -Because 'git CLI must be installed'

        $ls = git ls-remote --heads https://github.com/IMPACT-NCD-Modeling-Germany/IMPACT-NCD-Germany_Base.git HEAD 2>&1
        $LASTEXITCODE | Should -Be 0 -Because "Network/connectivity to GitHub required. Output: $($ls -join ' ')"
    }

    It 'ssh-keygen available' {
        (Get-Command ssh-keygen -ErrorAction SilentlyContinue) | Should -Not -BeNullOrEmpty -Because 'ssh-keygen required for test key generation'
    }

    It 'Temporary filesystem is writable' {
        $tmpBase = if ($env:TEMP) { $env:TEMP } elseif ($env:TMPDIR) { $env:TMPDIR } else { '/tmp' }
        $testDir = Join-Path $tmpBase "preflight_test_$([guid]::NewGuid().ToString('N').Substring(0,6))"
        New-Item -ItemType Directory -Path $testDir -Force | Out-Null
        Test-Path $testDir | Should -BeTrue
        Remove-Item -Recurse -Force $testDir -ErrorAction SilentlyContinue
    }
}
