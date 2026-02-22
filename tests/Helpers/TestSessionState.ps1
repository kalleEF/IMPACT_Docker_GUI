<#
.SYNOPSIS
    Test helper: creates a pre-populated session state for headless testing.
    Import this from any Pester test file.
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
    .PARAMETER Suite
        Logical suite name (e.g. 'image-validation').
    .PARAMETER Paths
        Array of filesystem paths to copy (files or directories).
    .PARAMETER ExtraFiles
        Additional files to copy (e.g. TestResults XML).
    .PARAMETER ContainerNames
        Docker container names to collect logs/inspect for (if docker available).
    #>
    param(
        [string]$Suite,
        [string[]]$Paths = @(),
        [string[]]$ExtraFiles = @(),
        [string[]]$ContainerNames = @()
    )

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
        }
        $envInfoArray = $envInfo.GetEnumerator() | ForEach-Object { "{0} = {1}" -f $_.Key, $_.Value }
        $envInfoString = [string]::Join("`n", $envInfoArray)
        $envInfoString | Out-File -FilePath (Join-Path $runDir 'environment.txt') -Encoding utf8 -Force

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
