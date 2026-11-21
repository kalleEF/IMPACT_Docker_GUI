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

    It 'Existing test SSH private keys (if present) are usable (not passphrase-protected)' {
        # (F109) The keys are looked for where they really are:
        #  - the paths in IMPACT_TEST_SSH_KEY / IMPACT_REMOTE_E2E_SSH_KEY, which both
        #    Invoke-Tests.ps1 and the CI workflow set (CI keeps its keys in /tmp/test_ssh
        #    and /tmp/remote_e2e_ssh, which the old check never looked at, so it was
        #    always skipped in CI);
        #  - the folder Invoke-Tests.ps1 uses, [System.IO.Path]::GetTempPath()/impact_test_ssh
        #    (the old code built that path from $env:TEMP/$env:TMPDIR, which can differ).
        $sshDir = Join-Path ([System.IO.Path]::GetTempPath()) 'impact_test_ssh'
        $candidates = @(
            $env:IMPACT_TEST_SSH_KEY
            $env:IMPACT_REMOTE_E2E_SSH_KEY
            (Join-Path $sshDir 'id_test')
            (Join-Path $sshDir 'id_ws_test')
        ) | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -Unique
        if (-not $candidates) { Set-ItResult -Skipped -Because 'No test SSH private keys present'; return }

        foreach ($k in $candidates) {
            $pubOut = & ssh-keygen -y -f $k 2>$null
            $LASTEXITCODE | Should -Be 0 -Because "Private key $k is unusable or passphrase-protected"
        }
    }

    It 'Temporary filesystem is writable' {
        $tmpBase = if ($env:TEMP) { $env:TEMP } elseif ($env:TMPDIR) { $env:TMPDIR } else { '/tmp' }
        $testDir = Join-Path $tmpBase "preflight_test_$([guid]::NewGuid().ToString('N').Substring(0,6))"
        New-Item -ItemType Directory -Path $testDir -Force | Out-Null
        Test-Path $testDir | Should -BeTrue
        Remove-Item -Recurse -Force $testDir -ErrorAction SilentlyContinue
    }
}
