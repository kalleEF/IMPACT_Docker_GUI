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
        [string]$SshKeyDir    = $null              # defaults to $env:TEMP
    )

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
    $keyDir = if ($SshKeyDir) { $SshKeyDir } else { Join-Path $env:TEMP 'impact_test_ssh' }
    if (-not (Test-Path $keyDir)) { New-Item -ItemType Directory -Path $keyDir -Force | Out-Null }
    $state.Paths.SshPrivate = Join-Path $keyDir "id_ed25519_$UserName"
    $state.Paths.SshPublic  = "$($state.Paths.SshPrivate).pub"

    # Repo paths for LOCAL mode
    if ($state.ContainerLocation -eq 'LOCAL') {
        $state.Paths.LocalRepo = Join-Path $env:TEMP "impact_test_repo/$SelectedRepo"
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

    $dir = Join-Path $env:TEMP "impact_test_ssh_$([guid]::NewGuid().ToString('N').Substring(0,8))"
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $keyPath = Join-Path $dir "id_ed25519_$Label"

    & ssh-keygen -t ed25519 -C "test_$Label" -f $keyPath -N '""' -q 2>$null

    return @{
        Private = $keyPath
        Public  = "$keyPath.pub"
        Dir     = $dir
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
