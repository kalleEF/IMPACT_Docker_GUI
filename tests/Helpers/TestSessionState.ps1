<#
.SYNOPSIS
    Test helpers for IMPACT Docker GUI Pester tests.
    Import this from any Pester test file:
        . (Join-Path $PSScriptRoot 'Helpers' 'TestSessionState.ps1')
#>

function New-TestSessionState {
    <#
    .SYNOPSIS Returns a session state pre-filled with dummy values for
              headless / CI testing.  All fields that interactive dialogs
              would populate are seeded here so that NonInteractive mode
              can proceed without user input.
    #>
    param(
        [string]$UserName     = 'testuser',
        [string]$Password     = 'TestPass123!',
        [string]$Location     = 'LOCAL',          # 'LOCAL' or 'REMOTE@<ip>'
        [string]$RemoteHostIp = $null,
        [string]$SelectedRepo = 'IMPACTncd_Germany',
        [string]$SshKeyDir    = $null              # defaults to system temp
    )

    # Cross-platform temp directory ($env:TEMP is null on Linux)
    $TempDir = [System.IO.Path]::GetTempPath()

    # Import the module if not already loaded
    $modulePath = Join-Path $PSScriptRoot '..' 'current_version' 'IMPACT_Docker_GUI.psm1'
    if (-not (Get-Module -Name 'IMPACT_Docker_GUI')) {
        Import-Module $modulePath -Force -DisableNameChecking
    }

    $state = New-SessionState

    $state.UserName  = $UserName
    $state.Password  = $Password

    if ($Location -like 'REMOTE@*') {
        $ip = $Location -replace '^REMOTE@', ''
        $state.ContainerLocation = $Location
        $state.RemoteHostIp      = if ($RemoteHostIp) { $RemoteHostIp } else { $ip }
        $state.RemoteHost        = "$($state.RemoteUser)@$($state.RemoteHostIp)"
    } else {
        $state.ContainerLocation = 'LOCAL'
    }

    $state.SelectedRepo  = $SelectedRepo
    $state.ContainerName = "impact-$UserName"

    # Seed SSH key paths (use temp dir so tests don't touch real keys)
    $keyDir = if ($SshKeyDir) { $SshKeyDir } else { Join-Path $TempDir 'impact_test_ssh' }
    if (-not (Test-Path $keyDir)) { New-Item -ItemType Directory -Path $keyDir -Force | Out-Null }
    $state.Paths.SshPrivate = Join-Path $keyDir "id_ed25519_$UserName"
    $state.Paths.SshPublic  = "$($state.Paths.SshPrivate).pub"

    # Repo paths for LOCAL mode
    if ($state.ContainerLocation -eq 'LOCAL') {
        $state.Paths.LocalRepo = Join-Path $TempDir "impact_test_repo/$SelectedRepo"
    } else {
        $state.RemoteRepoBase = "/home/$($state.RemoteUser)/Schreibtisch/Repositories"
        $state.Paths.RemoteRepo = "$($state.RemoteRepoBase)/$SelectedRepo"
    }

    return $state
}

function Invoke-RealCommand {
    <#
    .SYNOPSIS Runs the real PowerShell command behind a mock, inside the IMPACT module.
    .DESCRIPTION
              A mock is a stand-in for a command during a test: Pester's 'Mock' command
              replaces the command with a small piece of test code. A mock with a
              -ParameterFilter only handles the calls that its filter accepts. Pester
              stops every other call with the error "No mock for command ... matched the
              call", so such a mock needs a second mock without a filter, the "default
              mock", for all other calls. The default mocks in these tests call this
              helper, so those calls do exactly what they would do without any mock:

                  Mock Join-Path -ModuleName 'IMPACT_Docker_GUI' { Invoke-RealCommand -Name 'Join-Path' -Parameters $PesterBoundParameters }

              Pester fills $PesterBoundParameters inside every mock with the parameters of
              the call that the mock replaced. The mocks with a filter (for example the
              safety nets that stop writes to the real ~/.ssh) still get their calls
              first: Pester uses a default mock only when no filter accepts the call.

              The real command is looked up as a cmdlet, the built-in kind of command, so
              a mock with the same name is never picked by mistake. It runs inside the
              module, the place the replaced call came from. That matters for
              Get-Command: it only finds the module's own functions when it is asked from
              inside the module.

              Each call is passed on as one call of its own. The module never sends
              pipeline input to the commands that are mocked this way. If it starts to,
              check those tests: Set-Content would then keep only the last item.
    .PARAMETER Name
        Name of the built-in cmdlet, for example 'Join-Path' or 'Set-Content'.
    .PARAMETER Parameters
        The parameters to pass on, normally $PesterBoundParameters.
    .PARAMETER ModuleName
        The module that made the call. Default: IMPACT_Docker_GUI.
    #>
    param(
        [Parameter(Mandatory)][string]$Name,
        [hashtable]$Parameters = @{},
        [string]$ModuleName = 'IMPACT_Docker_GUI'
    )

    $realCommand = Get-Command -Name $Name -CommandType Cmdlet -ErrorAction Stop
    $module = @(Get-Module -Name $ModuleName)
    if ($module.Count -ne 1) {
        throw "Invoke-RealCommand: the module '$ModuleName' must be loaded exactly once, but $($module.Count) copies are loaded."
    }
    # '& <module> { ... }' runs the script block inside that module.
    & $module[0] { param($Command, $CommandParameters) & $Command @CommandParameters } $realCommand $Parameters
}

function New-DummySshKeyPair {
    <#
    .SYNOPSIS Creates a throwaway ed25519 key pair in a temp directory.
              Returns @{ Private; Public } paths.
    #>
    param([string]$Label = 'test')

    $dir = Join-Path ([System.IO.Path]::GetTempPath()) "impact_test_ssh_$([guid]::NewGuid().ToString('N').Substring(0,8))"
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $keyPath = Join-Path $dir "id_ed25519_$Label"

    & ssh-keygen -t ed25519 -C "test_$Label" -f $keyPath -N "" -q 2>$null

    return @{
        Private = $keyPath
        Public  = "$keyPath.pub"
        Dir     = $dir
    }
}

function Test-IsSshKeyUsable {
    <#
    .SYNOPSIS Returns $true when the given private SSH key is usable (not passphrase-protected).
    .PARAMETER PrivateKeyPath
        Path to an SSH private key file.
    #>
    param([string]$PrivateKeyPath)

    if (-not $PrivateKeyPath -or -not (Test-Path $PrivateKeyPath)) { return $false }

    # Try to extract the public key from the private key. ssh-keygen -y exits non-zero for
    # passphrase-protected or otherwise unusable private keys.
    $pubOut = & ssh-keygen -y -f $PrivateKeyPath 2>$null
    return ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($pubOut))
}

function Save-TestArtifacts {
    <#
    .SYNOPSIS  Save test-related artifacts to `tests/artifacts/<suite>/<timestamp>/`.
               By default, only saves when tests failed or were skipped.
    .PARAMETER Suite
        Logical suite name (e.g. 'image-validation').
    .PARAMETER Paths
        Array of filesystem paths to copy (files or directories).
    .PARAMETER ExtraFiles
        Additional files to copy (e.g. TestResults XML).
    .PARAMETER ContainerNames
        Docker container names to collect logs/inspect for (if docker available).
    .PARAMETER FailedCount
        Number of failed tests.  When both FailedCount and SkippedCount are 0,
        artifacts are NOT saved (clean run).  Omit or set -1 to always save.
    .PARAMETER SkippedCount
        Number of skipped tests.  See FailedCount.
    #>
    param(
        [string]$Suite,
        [string[]]$Paths = @(),
        [string[]]$ExtraFiles = @(),
        [string[]]$ContainerNames = @(),
        [int]$FailedCount  = -1,
        [int]$SkippedCount = -1
    )

    # If explicit counts were provided and everything passed, skip saving.
    if ($FailedCount -ge 0 -and $SkippedCount -ge 0 -and $FailedCount -eq 0 -and $SkippedCount -eq 0) {
        Write-Host "  Artifacts skipped for '$Suite' (all tests passed)." -ForegroundColor DarkGray
        return $null
    }

    try {
        $artifactRoot = Join-Path $PSScriptRoot '..' 'artifacts'
        $suiteDir     = Join-Path $artifactRoot $Suite
        $ts           = Get-Date -Format 'yyyyMMdd-HHmmss'
        $runDir       = Join-Path $suiteDir $ts
        New-Item -ItemType Directory -Path $runDir -Force | Out-Null

        foreach ($p in $Paths) {
            if ($p -and (Test-Path $p)) {
                $dest = Join-Path $runDir (Split-Path $p -Leaf)
                Copy-Item -Path $p -Destination $dest -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        foreach ($f in $ExtraFiles) {
            if ($f -and (Test-Path $f)) {
                Copy-Item -Path $f -Destination $runDir -Force -ErrorAction SilentlyContinue
            }
        }

        foreach ($c in $ContainerNames) {
            try {
                if (Get-Command docker -ErrorAction SilentlyContinue) {
                    $logs = docker logs $c 2>&1
                    $logs | Out-File -FilePath (Join-Path $runDir "$c.logs.txt") -Encoding utf8 -Force
                    docker inspect $c 2>&1 | Out-File -FilePath (Join-Path $runDir "$c.inspect.json") -Encoding utf8 -Force
                }
            } catch {
                # non-fatal
            }
        }

        # capture some environment/context information
        $envInfo = @{
            Date       = (Get-Date).ToString('o')
            User       = $env:USERNAME
            Machine    = $env:COMPUTERNAME
            PWD        = (Get-Location).Path
            PowerShell = $PSVersionTable.PSVersion.ToString()
            Failed     = if ($FailedCount -ge 0) { $FailedCount } else { 'n/a' }
            Skipped    = if ($SkippedCount -ge 0) { $SkippedCount } else { 'n/a' }
        }
        $envInfoArray = $envInfo.GetEnumerator() | ForEach-Object { "{0} = {1}" -f $_.Key, $_.Value }
        $envInfoString = [string]::Join("`n", $envInfoArray)
        $envInfoString | Out-File -FilePath (Join-Path $runDir 'environment.txt') -Encoding utf8 -Force

        Write-Host "  Artifacts saved for '$Suite' to $runDir" -ForegroundColor Yellow
        return $runDir
    } catch {
        Write-Warning "Save-TestArtifacts failed: $($_.Exception.Message)"
    }
}

function Remove-TestArtifacts {
    <#
    .SYNOPSIS Cleans up temp directories created during testing.
    #>
    param([string[]]$Paths)
    foreach ($p in $Paths) {
        if ($p -and (Test-Path $p)) {
            Remove-Item -Recurse -Force -Path $p -ErrorAction SilentlyContinue
        }
    }
}

# ═══════════════════════════════════════════════════════════════════════════════
#  E2E / ImageValidation helpers
# ═══════════════════════════════════════════════════════════════════════════════

function Assert-PreflightPassed {
    <#
    .SYNOPSIS  Guard for It blocks in E2E tests.  When $script:PreflightFailed
               is $true (set during BeforeAll), marks the current test as
               Skipped with the collected diagnostic messages.
    .DESCRIPTION
               Call at the very top of each It block:
                   if (-not (Assert-PreflightPassed)) { return }
               Returns $true when setup succeeded, $false (and skips) otherwise.
    #>
    if ($script:PreflightFailed) {
        $reason = if ($script:PreflightMessages -and $script:PreflightMessages.Count -gt 0) {
            $script:PreflightMessages -join '; '
        } else {
            'Setup failed (see BeforeAll output)'
        }
        Set-ItResult -Skipped -Because $reason
        return $false
    }
    return $true
}

function Wait-ForRStudioReady {
    <#
    .SYNOPSIS  Polls an HTTP endpoint until RStudio Server responds.
    .PARAMETER Url
        The URL to poll (e.g. http://localhost:18787).
    .PARAMETER TimeoutSeconds
        Total seconds to wait before giving up. Default 120.
    .PARAMETER IntervalSeconds
        Seconds between polling attempts. Default 2.
    .OUTPUTS   [bool] $true if RStudio is ready, $false on timeout.
    #>
    param(
        [string]$Url,
        [int]$TimeoutSeconds = 120,
        [int]$IntervalSeconds = 2
    )

    $maxAttempts = [math]::Ceiling($TimeoutSeconds / $IntervalSeconds)
    for ($i = 0; $i -lt $maxAttempts; $i++) {
        Start-Sleep -Seconds $IntervalSeconds
        try {
            $resp = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop
            if ($resp.StatusCode -in @(200, 302)) { return $true }
        } catch {
            # (F109) The old code only looked at the status code inside
            # 'catch [System.Net.WebException]'. PowerShell 7 never throws that type for an
            # HTTP error answer: it throws HttpResponseException, whose Response is an
            # HttpResponseMessage. So a 401/403 answer (server running, login required)
            # was treated like "not ready yet". Both response types have a StatusCode, so
            # read it from whatever exception arrived.
            $webResp = $null
            if ($_.Exception.PSObject.Properties['Response']) { $webResp = $_.Exception.Response }
            if ($webResp) {
                try {
                    $httpCode = [int]$webResp.StatusCode
                    # 401/403 means the server IS running (auth required)
                    if ($httpCode -in @(200, 302, 401, 403)) { return $true }
                } catch {}
            }
            # No HTTP answer at all (connection refused, timeout, DNS): keep waiting
        }
    }
    return $false
}

function Invoke-DockerExecSafe {
    <#
    .SYNOPSIS  Runs 'docker exec' with array splatting and reliable exit-code capture.
    .PARAMETER ContainerName
        Name of the running container.
    .PARAMETER Command
        Array of command tokens (e.g. @('ls', '/home/rstudio')).
    .PARAMETER User
        Optional --user argument (e.g. 'rstudio').
    .PARAMETER WorkDir
        Optional --workdir argument.
    .OUTPUTS   Hashtable @{ Output = [string[]]; ExitCode = [int] }
    #>
    param(
        [string]$ContainerName,
        [string[]]$Command,
        [string]$User = $null,
        [string]$WorkDir = $null
    )

    $args_ = @('exec')
    if ($User)    { $args_ += '--user';    $args_ += $User }
    if ($WorkDir) { $args_ += '--workdir'; $args_ += $WorkDir }
    $args_ += $ContainerName
    $args_ += $Command

    $output = docker @args_ 2>&1
    $exitCode = $LASTEXITCODE

    return @{
        Output   = $output
        ExitCode = $exitCode
    }
}

function ConvertTo-Base64Script {
    <#
    .SYNOPSIS  Base64-encodes a script string for safe transport through
               multiple shell layers (PowerShell -> SSH -> bash -> docker exec).
    .PARAMETER Script
        The script content to encode.
    .OUTPUTS   [string] Base64-encoded representation.
    #>
    param([string]$Script)
    return [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($Script))
}
