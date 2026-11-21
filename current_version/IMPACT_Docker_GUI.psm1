<# IMPACT Docker GUI v2 - Module #>
# All core functions for IMPACT Docker GUI. Imported by the launcher script and by Pester tests.

Set-StrictMode -Version Latest

# ── Module-scope state ───────────────────────────────────────────────────────
$script:GlobalDebugFlag  = $false
$script:ThemePalette     = $null
$script:LogFile          = $null
$script:LogInit          = $false
$script:NonInteractive   = $false   # set via Enable-NonInteractiveMode

# ══════════════════════════════════════════════════════════════════════════════
#  Non-interactive mode toggle
# ══════════════════════════════════════════════════════════════════════════════
function Enable-NonInteractiveMode {
    <#
    .SYNOPSIS Enables headless / CI mode. All dialogs are suppressed;
              values must be pre-populated on the session state.
    #>
    $script:NonInteractive = $true
}

function Disable-NonInteractiveMode {
    $script:NonInteractive = $false
}

function Test-NonInteractiveMode {
    return $script:NonInteractive
}

# ══════════════════════════════════════════════════════════════════════════════
#  Logging
# ══════════════════════════════════════════════════════════════════════════════
function Initialize-Logging {
    if ($script:LogInit) { return }
    $script:LogInit = $true

    $disable = $env:IMPACT_LOG_DISABLE
    if ($disable -and $disable -match '^(1|true|yes)$') { return }

    $logPath = if ($env:IMPACT_LOG_FILE) { $env:IMPACT_LOG_FILE } else { Join-Path $HOME '.impact_gui/logs/impact.log' }
    try {
        $logDir = Split-Path -Parent $logPath
        if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
        if (Test-Path $logPath) {
            $info = Get-Item $logPath -ErrorAction SilentlyContinue
            if ($info -and $info.Length -gt 512KB) {
                Move-Item -Force -Path $logPath -Destination "$logPath.1" -ErrorAction SilentlyContinue
            }
        }
        $script:LogFile = $logPath
        $header = "[{0}] [INFO] log start (pid={1})" -f (Get-Date -Format 's'), $PID
        Add-Content -Path $logPath -Value $header -Encoding UTF8 -ErrorAction SilentlyContinue
    } catch { }
}

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet('Info','Warn','Error','Debug')][string]$Level = 'Info'
    )
    Initialize-Logging
    if ($Level -ne 'Debug' -or $script:GlobalDebugFlag) {
        switch ($Level) {
            'Info'  { Write-Host "[INFO]  $Message" -ForegroundColor Cyan }
            'Warn'  { Write-Host "[WARN]  $Message" -ForegroundColor Yellow }
            'Error' { Write-Host "[ERROR] $Message" -ForegroundColor Red }
            'Debug' { Write-Host "[DEBUG] $Message" -ForegroundColor DarkGray }
        }
    }

    if ($script:LogFile) {
        try {
            $stamp = Get-Date -Format 's'
            Add-Content -Path $script:LogFile -Value "[$stamp] [$Level] $Message" -Encoding UTF8 -ErrorAction SilentlyContinue
        } catch { }
    }
}

# ══════════════════════════════════════════════════════════════════════════════
#  Build / version info
# ══════════════════════════════════════════════════════════════════════════════
function Get-BuildInfo {
    # The footer shows these values so that a screenshot identifies which copy of the
    # tool a colleague is running. They must therefore describe THIS copy of the tool,
    # not the moment it was started or some other git repository around it.
    $version = '2.0.0'
    $built = $null
    $commit = $null
    $dirty = $false
    $moduleDir = $PSScriptRoot

    # Version: read it from the module manifest (.psd1) next to this file, so it only
    # has to be changed in one place. Falls back to the default above.
    try {
        $manifestPath = if ($moduleDir) { Join-Path $moduleDir 'IMPACT_Docker_GUI.psd1' } else { $null }
        if ($manifestPath -and (Test-Path -LiteralPath $manifestPath)) {
            $manifest = Import-PowerShellDataFile -LiteralPath $manifestPath -ErrorAction Stop
            if ($manifest.ContainsKey('ModuleVersion') -and $manifest.ModuleVersion) { $version = [string]$manifest.ModuleVersion }
        }
    } catch { }

    # Built: the last time the module file was changed (when this release was built or
    # copied). Previously this was Get-Date, i.e. simply the time the tool was launched.
    try {
        $moduleFile = if ($moduleDir) { Join-Path $moduleDir 'IMPACT_Docker_GUI.psm1' } else { $null }
        if ($moduleFile -and (Test-Path -LiteralPath $moduleFile)) {
            $built = (Get-Item -LiteralPath $moduleFile -ErrorAction Stop).LastWriteTime.ToString('s')
        }
    } catch { }
    if (-not $built) { $built = (Get-Date).ToString('s') }

    try {
        $git = Get-Command git -ErrorAction SilentlyContinue
        if ($git -and $moduleDir) {
            # Only report a commit if the module file is tracked by the git repository it
            # sits in. If the tool folder was copied into some unrelated repository, that
            # repository's commit says nothing about this tool. 'git -C' avoids changing
            # the current location (no Push-/Pop-Location to clean up on errors).
            & git -C $moduleDir ls-files --error-unmatch 'IMPACT_Docker_GUI.psm1' 2>$null | Out-Null
            if ($LASTEXITCODE -eq 0) {
                $commit = & git -C $moduleDir rev-parse --short HEAD 2>$null
                $status = & git -C $moduleDir status --porcelain -- . 2>$null
                if ($status) { $dirty = $true }
            }
        }
    } catch { $commit = $null }

    $commitTag = if ($commit) { $commit + $(if($dirty){'*'}) } else { 'unknown' }
    Write-Log "Build info resolved: commit=$commitTag dirty=$dirty" 'Debug'
    return [pscustomobject]@{ Version=$version; Built=$built; Commit=$commitTag }
}

# ══════════════════════════════════════════════════════════════════════════════
#  Session state factory
# ══════════════════════════════════════════════════════════════════════════════
function New-SessionState {
    param(
        [switch]$PS7Requested
    )
    $state = [PSCustomObject]@{
        UserName          = $null
        Password          = $null
        RemoteHost        = $null
        RemoteHostIp      = $null
        RemoteUser        = 'php-workstation'
        RemoteRepoBase    = $null
        ContainerLocation = $null  # "LOCAL" or "REMOTE@<ip>"
        SelectedRepo      = $null
        ContainerName     = $null
        Paths             = @{
            LocalRepo   = $null
            RemoteRepo  = $null
            OutputDir   = $null
            SynthpopDir = $null
            SshPrivate  = $null
            SshPublic   = $null
        }
        Flags             = @{
            Debug            = $false
            UseDirectSsh     = $false
            UseVolumes       = $false
            Rebuild          = $false
            HighComputeDemand= $false
            PS7Requested     = $PS7Requested.IsPresent
        }
        Ports             = @{
            Requested = $null
            Assigned  = $null
            Used      = @()
        }
        Metadata          = @{}
    }

    Write-Log "Initialized session state (PID=$PID)." 'Info'
    Write-Log "State defaults -> RemoteUser=$($state.RemoteUser), PS7Requested=$($state.Flags.PS7Requested), Debug=$($state.Flags.Debug)" 'Debug'
    return $state
}

# ══════════════════════════════════════════════════════════════════════════════
#  PowerShell 7 guard
# ══════════════════════════════════════════════════════════════════════════════
function Test-PowerShellVersionSupported {
    <#
    .SYNOPSIS Pure helper for Ensure-PowerShell7: is this PowerShell edition/version new enough?
    .NOTES    PowerShell 7.3 is the minimum because older versions pass arguments to
              native programs in the "legacy" way: an empty argument such as the empty
              passphrase in 'ssh-keygen -N ""' is silently dropped, so ssh-keygen took
              the next argument ('-q') as the passphrase and created an encrypted key.
              Embedded double quotes (docker inspect templates) were also mangled.
    #>
    param(
        [string]$Edition,
        [version]$Version
    )
    if ($Edition -ne 'Core' -or -not $Version) { return $false }
    return ($Version -ge [version]'7.3')
}

function Ensure-PowerShell7 {
    param([bool]$PS7RequestedFlag = $false)

    # $PSVersionTable.PSVersion is a SemanticVersion in PowerShell 7 and cannot be
    # compared with [version] directly, so build a plain Major.Minor version first.
    $currentVersion = [version]('{0}.{1}' -f $PSVersionTable.PSVersion.Major, $PSVersionTable.PSVersion.Minor)
    $isCore = $PSVersionTable.PSEdition -eq 'Core'
    if (Test-PowerShellVersionSupported -Edition $PSVersionTable.PSEdition -Version $currentVersion) { return }

    if ($isCore) {
        # We ARE in PowerShell 7, but an old one (7.0 - 7.2). Do not try to restart:
        # the 'pwsh' found on PATH is almost certainly this same old version, which
        # would restart itself again and again. Ask the user to update instead.
        $tooOldMsg = "Your PowerShell version ($($PSVersionTable.PSVersion)) is too old. IMPACT needs PowerShell 7.3 or newer.`n`nTo update, open a terminal and run:`n`n    winget upgrade Microsoft.PowerShell`n`nor install the latest version from https://aka.ms/powershell-release`n`nThen start IMPACT again."
        if (-not $script:NonInteractive) {
            try { Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue } catch { }
            try { [System.Windows.Forms.MessageBox]::Show($tooOldMsg,'PowerShell update required','OK','Error') | Out-Null } catch { }
        }
        Write-Log "PowerShell $($PSVersionTable.PSVersion) is too old; 7.3 or newer is required." 'Error'
        throw "PowerShell 7.3 or newer is required (found $($PSVersionTable.PSVersion))."
    }

    # Below here we run in Windows PowerShell 5.1 (Desktop edition).
    $pwsh = Get-Command pwsh -ErrorAction SilentlyContinue
    if ($pwsh -and -not $PS7RequestedFlag) {
        Write-Log 'PowerShell 7 is required. Restarting under pwsh...' 'Warn'

        # Find the launcher script. Inside a module, $PSCommandPath is the .psm1 itself
        # and the process path is powershell.exe, so neither can be used (the old code
        # ended up restarting powershell.exe instead of the GUI). The launcher always
        # imports this module from its own folder, so the script sits next to it.
        $scriptPath = $null
        if ($PSScriptRoot) { $scriptPath = Join-Path $PSScriptRoot 'IMPACT_Docker_GUI_v2.ps1' }
        if (-not $scriptPath -or -not (Test-Path -LiteralPath $scriptPath)) {
            $notFoundMsg = "IMPACT could not restart itself in PowerShell 7 because the file 'IMPACT_Docker_GUI_v2.ps1' was not found next to the module.`n`nPlease start IMPACT by double-clicking IMPACT.bat in the IMPACT folder."
            if (-not $script:NonInteractive) {
                try { Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue } catch { }
                try { [System.Windows.Forms.MessageBox]::Show($notFoundMsg,'IMPACT - please use IMPACT.bat','OK','Error') | Out-Null } catch { }
            }
            Write-Log "Cannot relaunch under pwsh: launcher script not found at '$scriptPath'." 'Error'
            throw 'Unable to relaunch under pwsh (launcher script not found).'
        }
        try { $scriptPath = [System.IO.Path]::GetFullPath($scriptPath) } catch { Write-Log "Could not normalize script path: $scriptPath" 'Warn' }

        # Always relaunch with -File. The path is wrapped in double quotes by hand because
        # Windows PowerShell's Start-Process joins the arguments with plain spaces, and
        # user folders such as 'C:\Users\Max Mustermann' contain spaces.
        # -PS7Requested tells the new process that it was started by this relaunch.
        $pwshArgs = @('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$scriptPath`"",'-PS7Requested')
        Write-Log "Relaunching under pwsh with script: $scriptPath" 'Info'

        $proc = Start-Process -FilePath $pwsh.Source -ArgumentList $pwshArgs -WorkingDirectory $PWD.Path -NoNewWindow -Wait -PassThru
        # Pass the exit code of the PowerShell 7 process on, so IMPACT.bat can see failures.
        $exitCode = 0
        if ($proc) { $exitCode = $proc.ExitCode }
        exit $exitCode
    }

    if (-not $script:NonInteractive) {
        try { Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue } catch { }
        try { [System.Windows.Forms.MessageBox]::Show("PowerShell 7 (version 7.3 or newer) is required. Please install it from https://aka.ms/powershell-release (or run: winget install Microsoft.PowerShell) and try again.",'PowerShell 7 required','OK','Error') | Out-Null } catch { }
    }
    Write-Log 'PowerShell 7 (pwsh) is required but not installed.' 'Error'
    throw 'PowerShell 7 (pwsh) is required.'
}

# ══════════════════════════════════════════════════════════════════════════════
#  SSH / Docker helpers
# ══════════════════════════════════════════════════════════════════════════════
function Get-RemoteHostString {
    param([pscustomobject]$State)
    Write-Log "Resolving remote host target (RemoteHost=$($State.RemoteHost), IP=$($State.RemoteHostIp))." 'Debug'
    if ($State.RemoteHost) { return $State.RemoteHost }
    return $State.RemoteHostIp
}

function Set-DockerSSHEnvironment {
    param([pscustomobject]$State)
    if ($State.ContainerLocation -like 'REMOTE@*') {
        # Always rebuild DOCKER_SSH_OPTS and DOCKER_HOST from the CURRENT state. They used
        # to be set only once per session, so after going Back and choosing another
        # workstation (or user), docker kept talking to the OLD host with the old key
        # while the ssh calls already went to the new one.
        $keyPath = $State.Paths.SshPrivate
        if (-not $keyPath) { $keyPath = "$HOME/.ssh/id_ed25519_$($State.UserName)" }
        $env:DOCKER_SSH_OPTS = "-i `"$keyPath`" -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new -o BatchMode=yes -o ConnectTimeout=30"
        Write-Log "Prepared DOCKER_SSH_OPTS for remote Docker access." 'Debug'
        if ($State.Flags.UseDirectSsh) {
            $remoteHost = Get-RemoteHostString -State $State
            $wantedDockerHost = "ssh://$remoteHost"
            if ($env:DOCKER_HOST -ne $wantedDockerHost) {
                $env:DOCKER_HOST = $wantedDockerHost
                Write-Log "Using direct SSH Docker host at $remoteHost" 'Info'
            }
            Write-Log "Direct SSH Docker mode active; DOCKER_HOST=$env:DOCKER_HOST" 'Debug'
        } elseif ($env:DOCKER_HOST -and $env:DOCKER_HOST -match '^ssh://') {
            # A Docker context is used for this workstation now. Remove the ssh:// value
            # left over from an earlier direct-SSH fallback, otherwise docker commands
            # without an explicit --context would still go to that earlier host.
            $env:DOCKER_HOST = $null
            Write-Log 'Cleared leftover ssh:// DOCKER_HOST because a Docker context is in use.' 'Debug'
        }
    } else {
        Write-Log 'Using local Docker engine (no remote SSH context).' 'Info'
        Write-Log 'Clearing DOCKER_HOST/DOCKER_SSH_OPTS for local mode.' 'Debug'
        $env:DOCKER_SSH_OPTS = $null
        $env:DOCKER_HOST = $null
    }
}

function Get-DockerContextArgs {
    param([pscustomobject]$State)
    Write-Log "Selecting Docker context arguments for $($State.ContainerLocation)" 'Debug'
    $result = @()
    if ($State.ContainerLocation -like 'REMOTE@*') {
        if ($State.Flags.UseDirectSsh) {
            $result = @()
        } elseif ($State.Metadata.ContainsKey('RemoteDockerContext') -and $State.Metadata.RemoteDockerContext) {
            $result = @('--context',$State.Metadata.RemoteDockerContext)
        }
    } elseif ($State.ContainerLocation -eq 'LOCAL' -and $State.Metadata.ContainsKey('LocalDockerContext') -and $State.Metadata.LocalDockerContext) {
        $result = @('--context',$State.Metadata.LocalDockerContext)
    }
    Write-Log "Docker context args: $([string]::Join(' ', $result))" 'Debug'
    return $result
}

function Convert-PathToDockerFormat {
    param([string]$Path)
    Write-Log "Converting path to Docker format: $Path" 'Debug'
    if ($Path -match '^([A-Za-z]):\\?(.*)$') {
        $drive = $matches[1].ToLower()
        $rest = $matches[2] -replace '\\','/'
        $converted = "/$drive/$rest" -replace '/{2,}','/' -replace '/$',''
        Write-Log "Converted path: $converted" 'Debug'
        return $converted
    }
    $converted = $Path -replace '\\','/'
    Write-Log "Converted path: $converted" 'Debug'
    return $converted
}

# ══════════════════════════════════════════════════════════════════════════════
#  Remote SSH key / metadata helpers
# ══════════════════════════════════════════════════════════════════════════════
function Test-RemoteSSHKeyFiles {
    <#
    .SYNOPSIS Checks, just before a remote container starts, that the user's
              private SSH key is on the workstation (the container mounts it).
    .DESCRIPTION Returns $true when the key file exists there, otherwise $false.
                 Only the key is required. known_hosts is no longer checked:
                 IMPACT stopped copying this PC's known_hosts over the shared
                 workstation account's file, so it is not ours to require.
                 The function also records WHY the check failed, so the GUI can
                 say "check your VPN" instead of always "files missing":
                   $State.Metadata['RemoteSshCheckStatus']  = 'OK', 'KeyMissing',
                       'Unreachable', 'HostKeyChanged' or 'LoginFailed'
                   $State.Metadata['RemoteSshCheckMessage'] = text for the user
                       ($null when everything is fine)
    #>
    param([pscustomobject]$State)
    if ($State.ContainerLocation -notlike 'REMOTE@*') { return $true }
    $remoteHost = Get-RemoteHostString -State $State
    Write-Log "Checking remote SSH key on $remoteHost" 'Info'
    $localKeyPath = $State.Paths.SshPrivate
    $remoteKeyPath = "/home/$($State.RemoteUser)/.ssh/id_ed25519_$($State.UserName)"
    $remoteIp = if ($State.RemoteHostIp) { $State.RemoteHostIp } else { $remoteHost }

    # One ssh call whose remote command ALWAYS prints a marker once it runs on
    # the workstation. If neither marker comes back, ssh itself failed (network,
    # VPN, login), which is a different problem from "the key file is missing".
    $checkCmd = "if [ -f '$remoteKeyPath' ]; then echo IMPACT_KEY_OK; else echo IMPACT_KEY_MISSING; fi"
    $checkOut = $null
    try {
        # 2>&1 keeps ssh's own error text, so we can tell the user what went wrong.
        $checkOut = & ssh -n -i $localKeyPath -o StrictHostKeyChecking=accept-new -o IdentitiesOnly=yes -o ConnectTimeout=10 -o BatchMode=yes $remoteHost $checkCmd 2>&1
    } catch {
        $checkOut = $_.Exception.Message
    }
    $checkText = (@($checkOut) | ForEach-Object { "$_" }) -join ' | '
    Write-Log "Remote SSH check raw output: '$checkText'" 'Debug'

    if ($checkText -match 'IMPACT_KEY_OK') {
        $status = 'OK'
    } elseif ($checkText -match 'IMPACT_KEY_MISSING') {
        $status = 'KeyMissing'
    } else {
        $status = switch (Get-SshFailureKind -Output $checkOut) {
            'Unreachable'    { 'Unreachable' }
            'HostKeyChanged' { 'HostKeyChanged' }
            default          { 'LoginFailed' }
        }
    }

    # Plain-language text for the GUI. The GUI cannot re-run the key setup by
    # itself; the remote setup step runs when IMPACT starts, so "start IMPACT
    # again" is the way to repair a missing or no longer accepted key.
    $message = switch ($status) {
        'OK'             { $null }
        'KeyMissing'     { "Your SSH key was not found on the workstation ($remoteIp).`n`nClose IMPACT and start it again. The remote setup step copies your key to the workstation." }
        'Unreachable'    { "IMPACT cannot reach the workstation ($remoteIp).`n`nPlease check that you are connected to the institute network (or the VPN when working from home) and that the workstation is switched on, then press Start again." }
        'HostKeyChanged' { "The workstation ($remoteIp) identified itself with a different SSH host key than the one this PC remembers. This is expected after the workstation was reinstalled, but it can also mean that the connection is being intercepted.`n`nAsk the workstation admin whether it was reinstalled. If it was, run this command in PowerShell and then start IMPACT again:`n  ssh-keygen -R $remoteIp" }
        default          { "IMPACT could not log in to the workstation ($remoteIp) with your SSH key.`n`nClose IMPACT and start it again. The remote setup step will ask for the workstation password and set up your key again." }
    }

    Write-Log "Remote SSH key check result: $status" $(if ($status -eq 'OK') { 'Info' } else { 'Warn' })
    if ($State.PSObject.Properties['Metadata'] -and $State.Metadata -is [hashtable]) {
        $State.Metadata['RemoteSshCheckStatus']  = $status
        $State.Metadata['RemoteSshCheckMessage'] = $message
    }
    return ($status -eq 'OK')
}

<#
.SYNOPSIS Sorts the error text of a failed ssh (or Posh-SSH) call into a few
          plain categories, so the GUI can tell the user what to do next.
.DESCRIPTION Returns one of:
               'HostKeyChanged' the workstation's SSH host key differs from the
                                stored one (reinstalled machine, or interception)
               'Unreachable'    no network connection to the workstation
                                (VPN off, machine off, wrong IP, name not found)
               'AuthFailed'     the workstation answered but refused the login
                                (key not authorised yet, or wrong password)
               'Unknown'        anything else, including no output at all
             The patterns are OpenSSH's own messages (OpenSSH does not translate
             them, and "connect to host ... port ..." is its prefix for every
             network error) plus the .NET exception names Posh-SSH throws, so the
             result does not depend on the Windows display language.
.PARAMETER Output Whatever the call produced: strings, ErrorRecords from 2>&1,
                  or an exception message. $null is allowed.
#>
function Get-SshFailureKind {
    param([AllowNull()][object]$Output)
    $text = (@($Output) | ForEach-Object { "$_" }) -join "`n"
    # Checked first: when a host key changed, OpenSSH also prints other lines.
    if ($text -match 'REMOTE HOST IDENTIFICATION HAS CHANGED|Host key verification failed|Offending \S+ key') { return 'HostKeyChanged' }
    if ($text -match 'connect to host \S+ port \d+|Could not resolve hostname|timed out|No route to host|Network is unreachable|Connection refused|kex_exchange_identification|SocketException|SshOperationTimeoutException') { return 'Unreachable' }
    if ($text -match 'Permission denied|Too many authentication failures|SshAuthenticationException') { return 'AuthFailed' }
    return 'Unknown'
}

<#
.SYNOPSIS Turns the output of the remote "list repository folders" command into
          a clean list of folder names.
.DESCRIPTION Only normal output lines (strings) are kept. Error lines printed by
             ssh or by the remote command arrive as ErrorRecord objects when the
             call uses 2>&1; they are dropped, so messages such as "Permission
             denied" can never show up as a repository to pick. Blank lines are
             removed, stray carriage returns are trimmed and the names are sorted.
             Callers should wrap the call in @(...): with exactly one repository
             PowerShell would otherwise hand back a plain string, and under
             Set-StrictMode reading .Count on that throws.
#>
function ConvertTo-RemoteRepoList {
    param([AllowNull()][object]$Output)
    @($Output) |
        Where-Object { $_ -is [string] } |
        ForEach-Object { $_ -split "`r?`n" } |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ } |
        Sort-Object -Unique
}

function Write-RemoteContainerMetadata {
    param(
        [pscustomobject]$State,
        [string]$Password,
        [string]$Port,
        [bool]$UseVolumes
    )
    if ($State.ContainerLocation -notlike 'REMOTE@*') { return }
    $remoteHost = Get-RemoteHostString -State $State
    $keyPath = $State.Paths.SshPrivate
    $metaPath = "/tmp/impactncd/$($State.ContainerName).json"
    Write-Log "Writing remote container metadata to $metaPath on $remoteHost" 'Info'
    $payload = [ordered]@{
        container = $State.ContainerName
        repo      = $State.SelectedRepo
        user      = $State.UserName
        password  = $Password
        port      = $Port
        useVolumes= $UseVolumes
        timestamp = (Get-Date).ToString('s')
    } | ConvertTo-Json -Compress
    Write-Log ("Metadata payload (masked): container={0} repo={1} port={2} useVolumes={3}" -f $State.ContainerName, $State.SelectedRepo, $Port, $UseVolumes) 'Debug'
    $b64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($payload))
    try {
        & ssh -n -i $keyPath -o StrictHostKeyChecking=accept-new -o IdentitiesOnly=yes -o ConnectTimeout=10 -o BatchMode=yes $remoteHost "mkdir -p /tmp/impactncd && umask 177 && echo $b64 | base64 -d > '$metaPath'" 2>$null
        Write-Log 'Remote metadata saved.' 'Info'
    } catch {
        Write-Log "Remote metadata SSH write failed: $($_.Exception.Message)" 'Warn'
    }
}

function Remove-RemoteContainerMetadata {
    param([pscustomobject]$State)
    if ($State.ContainerLocation -notlike 'REMOTE@*') { return }
    $remoteHost = Get-RemoteHostString -State $State
    $keyPath = $State.Paths.SshPrivate
    $metaPath = "/tmp/impactncd/$($State.ContainerName).json"
    Write-Log "Removing remote metadata at $metaPath on $remoteHost" 'Info'
    try { & ssh -n -i $keyPath -o StrictHostKeyChecking=accept-new -o IdentitiesOnly=yes -o ConnectTimeout=10 -o BatchMode=yes $remoteHost "rm -f '$metaPath'" 2>$null } catch {
        Write-Log "Remote metadata removal failed: $($_.Exception.Message)" 'Warn'
    }
}

function Read-RemoteContainerMetadata {
    param([pscustomobject]$State)
    if ($State.ContainerLocation -notlike 'REMOTE@*') { return $null }
    $remoteHost = Get-RemoteHostString -State $State
    $keyPath = $State.Paths.SshPrivate
    $metaPath = "/tmp/impactncd/$($State.ContainerName).json"
    Write-Log "Attempting to read remote metadata from $metaPath on $remoteHost" 'Info'
    try {
        $json = & ssh -n -i $keyPath -o StrictHostKeyChecking=accept-new -o IdentitiesOnly=yes -o ConnectTimeout=10 -o BatchMode=yes $remoteHost "cat '$metaPath' 2>/dev/null" 2>$null
        if ($json) {
            Write-Log 'Remote metadata read successfully.' 'Info'
            return $json | ConvertFrom-Json -ErrorAction Stop
        }
        Write-Log 'Remote metadata not found or empty.' 'Debug'
    } catch {
        Write-Log "Failed to read remote metadata: $($_.Exception.Message)" 'Debug'
    }
    return $null
}

# -----------------------------------------------------------------------------
# Docker credentials and remote-login helpers
# -----------------------------------------------------------------------------
function Get-DockerCredentialsFromDotEnv {
    param(
        [string]$EnvPath,
        # [string[]] instead of [string]: output of a native command such as 'ssh cat'
        # arrives as one string per line. A [string] parameter would glue those lines
        # together with SPACES, so the key=value pairs could no longer be found.
        [string[]]$EnvContent
    )

    if (-not $EnvContent) {
        if ($EnvPath -and (Test-Path $EnvPath)) {
            try { $EnvContent = Get-Content -Path $EnvPath -Raw -ErrorAction Stop } catch { return $null }
        } else { return $null }
    }

    # Join the lines with real line breaks before splitting them again below.
    $envText = $EnvContent -join "`n"

    $map = @{}
    foreach ($line in ($envText -split "`n")) {
        $l = $line.Trim()
        if (-not $l -or $l.StartsWith('#')) { continue }
        if ($l -notmatch '=') { continue }
        $parts = $l -split '=',2
        $k = $parts[0].Trim()
        $v = $parts[1].Trim()
        if (($v.StartsWith("'") -and $v.EndsWith("'")) -or ($v.StartsWith('"') -and $v.EndsWith('"'))) { $v = $v.Substring(1,$v.Length-2) }
        $map[$k] = $v
    }

    # Common key pairs (priority order)
    $candidates = @(
        @{ user = 'DOCKERHUB_USERNAME'; pass = 'DOCKERHUB_TOKEN'; registry = 'docker.io' },
        @{ user = 'DOCKER_USERNAME';     pass = 'DOCKER_PASSWORD';  registry = 'docker.io' },
        @{ user = 'DOCKER_USER';         pass = 'DOCKER_PASS';      registry = 'docker.io' },
        @{ user = 'REGISTRY_USERNAME';   pass = 'REGISTRY_TOKEN';   registry = $(if ($map.ContainsKey('REGISTRY_HOST') -and $map['REGISTRY_HOST']) { $map['REGISTRY_HOST'] } else { 'docker.io' }) },
        @{ user = 'GHCR_USERNAME';       pass = 'GHCR_TOKEN';       registry = 'ghcr.io' }
    )

    foreach ($cand in $candidates) {
        $uKey = $cand.user; $pKey = $cand.pass
        if ($map.ContainsKey($uKey) -and $map.ContainsKey($pKey) -and $map[$uKey] -and $map[$pKey]) {
            return [pscustomobject]@{ Username = $map[$uKey]; Password = $map[$pKey]; Registry = $cand.registry; Source = 'dotenv' }
        }
    }

    return $null
}

function Ensure-RemoteDockerLogin {
    param(
        [pscustomobject]$State,
        [string]$ProjectRoot
    )

    if ($State.ContainerLocation -notlike 'REMOTE@*') { return $false }
    $remoteHost = Get-RemoteHostString -State $State
    $keyPath = $State.Paths.SshPrivate

    $envPathRemote = if ($ProjectRoot) { "$ProjectRoot/docker_setup/.env" } else { 'docker_setup/.env' }
    Write-Log "Attempting to read repo .env at $envPathRemote on $remoteHost" 'Debug'

    $envContent = $null
    try {
        $envContent = & ssh -n -i $keyPath -o StrictHostKeyChecking=accept-new -o IdentitiesOnly=yes -o ConnectTimeout=15 -o BatchMode=yes $remoteHost "cat '$envPathRemote' 2>/dev/null || true"
    } catch {
        Write-Log "Failed to read remote .env: $($_.Exception.Message)" 'Debug'
        return $false
    }
    if (-not $envContent) { Write-Log 'No .env content found on remote.' 'Debug'; return $false }

    # ssh returns one string per line; join them with line breaks so every
    # KEY=value line is parsed on its own (see Get-DockerCredentialsFromDotEnv).
    $creds = Get-DockerCredentialsFromDotEnv -EnvContent ($envContent -join "`n")
    if (-not $creds) { Write-Log 'No Docker credentials found in repo .env.' 'Info'; return $false }

    if (-not $creds.Username -or -not $creds.Password) { Write-Log 'Incomplete credentials in .env; cannot login.' 'Debug'; return $false }

    $user = $creds.Username; $pw = $creds.Password; $registry = $creds.Registry

    # The user name and registry come from a file in the repository and are placed
    # inside a command that the remote shell runs. Only allow plain characters so a
    # quote or '$(...)' in the file cannot change that command.
    if ($user -notmatch '^[A-Za-z0-9._@+-]+$' -or ($registry -and $registry -notmatch '^[A-Za-z0-9.:/-]+$')) {
        Write-Log 'Docker user name or registry in repo .env contains unsupported characters; skipping automatic login.' 'Warn'
        return $false
    }

    # Without a server name, 'docker login' always logs in to Docker Hub. For GHCR or a
    # custom registry the server must be given, otherwise that token is sent to Docker Hub.
    $registryArg = ''
    if ($registry -and $registry -notin @('docker.io','index.docker.io','registry-1.docker.io')) { $registryArg = " '$registry'" }
    Write-Log ("Attempting remote docker login using .env (user={0} registry={1})" -f $user, $registry) 'Info'

    try {
        # The password is sent through ssh's standard input (piped below) instead of being
        # part of the remote command line. Command lines are visible to every user of the
        # workstation (ps, /proc), and the old base64 encoding there was no protection.
        # Note: no '-n' here, because '-n' would cut off that standard input.
        $cmd = "docker login$registryArg -u '$user' --password-stdin 2>&1"
        $sshArgs = @('-o','StrictHostKeyChecking=accept-new','-o','ConnectTimeout=15','-o','BatchMode=yes','-o','IdentitiesOnly=yes','-i',"$keyPath",$remoteHost,$cmd)
        $out = $pw | & ssh @sshArgs 2>&1
        $outText = if ($out -is [System.Array]) { ($out -join "`n") } else { [string]$out }
        if ($outText -match 'Login Succeeded') { Write-Log 'Remote docker login succeeded (masked).' 'Info'; return $true }
        Write-Log ("Remote docker login output (masked): {0}" -f ($outText -replace [regex]::Escape($pw),'***')) 'Debug'
    } catch {
        Write-Log "Remote docker login attempt failed: $($_.Exception.Message)" 'Warn'
    }

    return $false
}

function Get-ContainerRuntimeInfo {
    param([pscustomobject]$State)
    $info = @{ Password = $null; Port = $null }
    $cmdEnv = @('inspect','-f','{{range .Config.Env}}{{println .}}{{end}}',$State.ContainerName)
    $cmdPort= @('inspect','-f','{{range $p, $c := .NetworkSettings.Ports}}{{if eq $p "8787/tcp"}}{{range $c}}{{println .HostPort}}{{end}}{{end}}{{end}}',$State.ContainerName)
    $ctxArgs = Get-DockerContextArgs -State $State
    $cmdEnv = $ctxArgs + $cmdEnv
    $cmdPort= $ctxArgs + $cmdPort
    Write-Log "Inspecting container $($State.ContainerName) for runtime info." 'Info'
    try {
        $envLines = & docker @cmdEnv 2>$null
        $portLine = & docker @cmdPort 2>$null
        Write-Log "Inspect env output: $envLines" 'Debug'
        Write-Log "Inspect port output: $portLine" 'Debug'
        if ($envLines) {
            foreach ($line in ($envLines -split "`n")) { if ($line -like 'PASSWORD=*') { $info.Password = $line.Substring(9) } }
        }
        if ($portLine) {
            $info.Port = (($portLine -split "`n|`r") | Where-Object { $_ -match '\S' } | Select-Object -First 1).Trim()
        }
        Write-Log "Recovered runtime info -> PasswordPresent=$([bool]$info.Password) Port=$($info.Port)" 'Debug'
    } catch {
        Write-Log "Failed to inspect container runtime info: $($_.Exception.Message)" 'Debug'
    }
    return $info
}

# ══════════════════════════════════════════════════════════════════════════════
#  Port helpers
# ══════════════════════════════════════════════════════════════════════════════
# (Get-NextAvailablePort used to be defined twice in this file; the second copy
# silently replaced the first. Only this one copy is kept.)
function Get-NextAvailablePort {
    param(
        [string[]]$UsedPorts = @(),
        [int]$RangeStart = 8787,
        [int]$RangeEnd   = 8799
    )
    for ($p = $RangeStart; $p -le $RangeEnd; $p++) {
        if ($UsedPorts -notcontains [string]$p) {
            return [string]$p
        }
    }
    # Every port in the range is taken. Still return the first port (callers expect a
    # value for the Port box; the start-time conflict check then reports the clash),
    # but say clearly in the console/log WHY no free port was suggested.
    Write-Log "All ports $RangeStart-$RangeEnd are already in use. Stop another container first, then try again." 'Warn'
    return [string]$RangeStart
}

function Test-PortValue {
    <#
    .SYNOPSIS Validates a port string for the IMPACT port range.
    .OUTPUTS  Hashtable @{ Valid = [bool]; ErrorMessage = [string] }
    #>
    param(
        [string]$Port,
        [int]$RangeStart = 8787,
        [int]$RangeEnd   = 8799
    )
    if ([string]::IsNullOrWhiteSpace($Port)) {
        return @{ Valid = $false; ErrorMessage = 'Port cannot be empty.' }
    }
    if ($Port -notmatch '^\d+$') {
        return @{ Valid = $false; ErrorMessage = 'Port must be a number.' }
    }
    # More than 5 digits can never be a valid port. Checking this BEFORE the [int]
    # conversion matters: a very long number would overflow [int] and throw an
    # exception inside the Port box's TextChanged handler.
    if ($Port.Length -gt 5) {
        return @{ Valid = $false; ErrorMessage = "Port must be between $RangeStart and $RangeEnd." }
    }
    # A leading zero ('08787') would be read as 8787 here, but the "port already in
    # use" checks compare the TEXT, so '08787' would slip past them.
    if ($Port.Length -gt 1 -and $Port.StartsWith('0')) {
        return @{ Valid = $false; ErrorMessage = 'Port must not start with 0.' }
    }
    $portInt = [int]$Port
    if ($portInt -lt $RangeStart -or $portInt -gt $RangeEnd) {
        return @{ Valid = $false; ErrorMessage = "Port must be between $RangeStart and $RangeEnd." }
    }
    return @{ Valid = $true; ErrorMessage = '' }
}

function Get-UsedPorts {
    <#
    .SYNOPSIS Scans docker ps for ports mapped to 8787/tcp.
              Lightweight alternative to full Get-ContainerStatus.
    .PARAMETER ContextArgs Docker context arguments (from Get-DockerContextArgs).
    .OUTPUTS   String array of port numbers currently in use.
    #>
    param(
        [string[]]$ContextArgs = @()
    )
    $portUsers = @()
    try {
        $psCmd = $ContextArgs + @('ps', '--format', '{{.Ports}}')
        $all = & docker @psCmd 2>$null
        if ($LASTEXITCODE -eq 0 -and $all) {
            foreach ($line in ($all -split "`n")) {
                if ($line -match '0\.0\.0\.0:(\d{4,5})->8787/tcp') {
                    $port = $matches[1]
                    if ($portUsers -notcontains $port) { $portUsers += $port }
                }
            }
        }
    } catch {
        Write-Log "Quick port scan failed: $($_.Exception.Message)" 'Warn'
    }
    return $portUsers
}

# ══════════════════════════════════════════════════════════════════════════════
#  Docker error helpers
# ══════════════════════════════════════════════════════════════════════════════
function Format-DockerError {
    <#
    .SYNOPSIS Translates raw Docker error output into user-friendly messages.
    .PARAMETER RawError The raw stderr/stdout from a failed docker run.
    .OUTPUTS   A user-friendly error string.
    #>
    param([string]$RawError)

    if ([string]::IsNullOrWhiteSpace($RawError)) {
        return 'Docker error: unknown failure (no output captured).'
    }

    $lower = $RawError.ToLower()

    # Port problems. The port number is taken from right after the bind address
    # ("0.0.0.0:8788", "127.0.0.1:8788" or "[::]:8788"). The old pattern took the first
    # 4-5 digit number ANYWHERE in the text, which was usually part of the container ID
    # or the endpoint hash printed before it, or digits in the user name.
    $portPattern = '(?:0\.0\.0\.0|127\.0\.0\.1|\[::\]):(\d{2,5})\b'
    # Docker Desktop on Windows reports a port that Windows has reserved (Hyper-V/WSL)
    # as "forbidden by its access permissions". Without this check it fell into the
    # 'permission' branch below and wrongly blamed Docker permissions.
    if ($lower -match 'forbidden by its access permissions') {
        if ($RawError -match $portPattern) {
            return "Port $($matches[1]) is blocked or reserved by Windows. Choose a different port."
        }
        return 'The selected port is blocked or reserved by Windows. Choose a different port.'
    }
    if ($lower -match 'port is already allocated' -or $lower -match 'address already in use' -or $lower -match 'only one usage of each socket address') {
        if ($RawError -match $portPattern) {
            return "Port $($matches[1]) is already in use. Choose a different port."
        }
        return 'The selected port is already in use. Choose a different port.'
    }

    if ($lower -match 'no such file or directory' -or $lower -match 'mount path' -or $lower -match 'invalid mount config') {
        return "A mount path does not exist or is invalid. Check your repository and YAML paths.`n`nDocker details: $RawError"
    }

    if ($lower -match 'no space left on device') {
        return 'Disk is full. Free up space and try again.'
    }

    if ($lower -match 'denied' -or $lower -match 'permission') {
        return "Permission denied. Check Docker permissions and ensure your user can run Docker.`n`nDocker details: $RawError"
    }

    if ($lower -match 'conflict.*name.*already in use') {
        return "A container with this name already exists. Stop it first or use a different name.`n`nDocker details: $RawError"
    }

    if ($lower -match 'image.*not found' -or $lower -match 'no such image') {
        return "The Docker image was not found. Ensure the image has been built.`n`nDocker details: $RawError"
    }

    return "Docker error: $RawError"
}

# ══════════════════════════════════════════════════════════════════════════════
#  YAML / path helpers
# ══════════════════════════════════════════════════════════════════════════════
function Get-YamlPathValue {
    param(
        [pscustomobject]$State,
        [string]$YamlPath,
        [string]$Key,
        [string]$BaseDir
    )

    Write-Log "Reading YAML key '$Key' from $YamlPath" 'Info'
    $content = $null
    if ($State.ContainerLocation -like 'REMOTE@*') {
        Set-DockerSSHEnvironment -State $State
        $remoteHost = Get-RemoteHostString -State $State
        $keyPath = $State.Paths.SshPrivate
        # When the file does not exist we print a marker word instead of its content. Without it a
        # missing file and a failed SSH connection would both just give empty output, and the log
        # could not say which of the two happened.
        $missingMarker = '__IMPACT_YAML_MISSING__'
        try {
            $content = & ssh -n -i $keyPath -o StrictHostKeyChecking=accept-new -o IdentitiesOnly=yes -o ConnectTimeout=30 -o BatchMode=yes $remoteHost "if [ -f '$YamlPath' ]; then cat '$YamlPath'; else echo $missingMarker; fi" 2>$null
        } catch { return $null }
        if ("$content" -match $missingMarker) {
            Write-Log "YAML file not found on the workstation: $YamlPath" 'Warn'
            return $null
        }
        if (-not $content) {
            Write-Log "Could not read YAML file over SSH (connection problem or empty file): $YamlPath" 'Warn'
            return $null
        }
    } else {
        if (-not (Test-Path $YamlPath)) { return $null }
        $content = Get-Content -Path $YamlPath -Raw
    }

    # Check for "no content" BEFORE reading .Length. Under StrictMode, reading .Length of $null
    # throws ("The property 'Length' cannot be found"), so an empty file used to crash the Start
    # button with a raw error instead of returning $null.
    if (-not $content) { Write-Log 'YAML content empty; aborting parse.' 'Debug'; return $null }
    Write-Log ("Fetched YAML content length: {0}" -f ($content.Length)) 'Debug'
    $line = ($content -split "`n") | Where-Object { $_ -match "^$Key\s*:" } | Select-Object -First 1
    if (-not $line) { Write-Log "YAML key '$Key' not found." 'Debug'; return $null }
    $value = ($line -split ":\s*",2)[1].Trim()
    # YAML allows a value to be written in quotes ("..." or '...'), and R reads it without them.
    # We must strip the quotes too: otherwise a quoted absolute path such as "/mnt/data/outputs"
    # is not recognised as absolute and gets glued onto the repository path. Anything after the
    # closing quote (for example a comment) is ignored.
    if ($value -match '^"((?:[^"\\]|\\.)*)"') {
        # Double quotes: backslash escapes are allowed, so \\ means \ and \" means "
        $value = $Matches[1] -replace '\\(["\\])', '$1'
    } elseif ($value -match "^'((?:[^']|'')*)'") {
        # Single quotes: the only escape is '' for a literal '
        $value = $Matches[1] -replace "''", "'"
    } else {
        # Unquoted value: as before, everything after '#' is a comment
        $value = $value.Split('#')[0].Trim()
        # In YAML an unquoted ~ or null means "no value"
        if ($value -eq '~' -or $value -eq 'null') { $value = '' }
    }
    # An empty value means the setting is not filled in. Without this check an empty value
    # would silently resolve to the repository folder itself.
    if (-not $value) { Write-Log "YAML key '$Key' has no value." 'Warn'; return $null }
    # '~/...' means "the user's home folder". Docker and our SSH folder checks do not expand '~'
    # (they would look for a folder literally named '~' inside the repository), so on the
    # workstation we replace it with the SSH user's home, /home/<RemoteUser>. The same home
    # folder layout is assumed elsewhere in this tool. Local mode is left unchanged on purpose:
    # Test-AndCreateDirectory rejects such Linux-style paths there with a clear message.
    if ($State.ContainerLocation -like 'REMOTE@*' -and $State.RemoteUser -and $value -match '^~/') {
        $value = "/home/$($State.RemoteUser)" + $value.Substring(1)
    }
    Write-Log "Raw YAML value for '$Key': $value" 'Debug'

    if ([System.IO.Path]::IsPathRooted($value) -or $value.StartsWith('/')) {
        return ($value -replace '\\','/')
    }
    $joined = "$BaseDir/$($value -replace '\\','/')"
    $resolved = ($joined -replace '(?<!:)/{2,}','/')
    Write-Log "Resolved YAML key '$Key' to $resolved" 'Info'
    return $resolved
}

function Test-AndCreateDirectory {
    param(
        [pscustomobject]$State,
        [string]$Path,
        [string]$PathKey,
        # Optional: create the folder if it is missing. Without this switch nothing is ever
        # created. The GUI only passes it after the user said Yes in a dialog that shows the
        # path, so a mistyped path never silently gets a new empty folder.
        [switch]$Create,
        # Optional: when the function returns $false, this receives a short code saying why, so
        # the caller can show a precise message instead of one generic error:
        #   'EmptyPath'            no path was given (for example the YAML key is missing)
        #   'Missing'              the folder does not exist (or is a file, not a folder)
        #   'PosixPathInLocalMode' a Linux-style path (/... or ~...) was used for a local run
        #   'Unreachable'          the workstation could not be reached over SSH to check it
        #   'CreateFailed'         -Create was given but the folder could not be created
        # Usage: $why = $null; Test-AndCreateDirectory ... -Reason ([ref]$why)
        [ref]$Reason
    )
    # Stores the reason code, but only if the caller asked for it (an unused [ref] is $null).
    function Set-Reason([string]$Code) { if ($null -ne $Reason) { $Reason.Value = $Code } }

    if (-not $Path) { Set-Reason 'EmptyPath'; return $false }

    Write-Log "Ensuring directory for ${PathKey}: $Path" 'Info'

    if ($State.ContainerLocation -like 'REMOTE@*') {
        $remoteHost = Get-RemoteHostString -State $State
        $keyPath = $State.Paths.SshPrivate
        try {
            $check = & ssh -n -i $keyPath -o StrictHostKeyChecking=accept-new -o IdentitiesOnly=yes -o ConnectTimeout=15 -o BatchMode=yes $remoteHost "test -d '$Path' && echo EXISTS || echo MISSING" 2>$null
            if ("$check" -match 'EXISTS') {
                Write-Log "Remote path verified for ${PathKey}: $Path" 'Debug'
                return $true
            }
            if ("$check" -notmatch 'MISSING') {
                # Neither word came back, so the SSH command itself failed (network, VPN, key,
                # workstation switched off). That is not the same as "folder missing".
                Write-Log "Could not check remote path for ${PathKey} (SSH failed): $Path" 'Error'
                Set-Reason 'Unreachable'
                return $false
            }
            if (-not $Create) {
                Write-Log "Remote path missing (no auto-create): $Path" 'Error'
                Set-Reason 'Missing'
                return $false
            }
            # mkdir runs as the SSH user, so the new folder belongs to the same user whose
            # uid/gid the container later uses for its bind mounts.
            $made = & ssh -n -i $keyPath -o StrictHostKeyChecking=accept-new -o IdentitiesOnly=yes -o ConnectTimeout=15 -o BatchMode=yes $remoteHost "mkdir -p '$Path' && echo CREATED" 2>$null
            if ("$made" -match 'CREATED') {
                Write-Log "Created remote directory for ${PathKey}: $Path" 'Info'
                return $true
            }
            Write-Log "Could not create remote directory for ${PathKey}: $Path" 'Error'
            Set-Reason 'CreateFailed'
            return $false
        } catch {
            Write-Log "Failed to validate remote directory ${Path}: $($_.Exception.Message)" 'Debug'
            Set-Reason 'Unreachable'
            return $false
        }
    }

    if ($IsWindows -and $State.ContainerLocation -eq 'LOCAL' -and $Path -match '^(?:/|~)') {
        Write-Log "POSIX-style path not allowed in local mode for ${PathKey}: $Path" 'Error'
        Set-Reason 'PosixPathInLocalMode'
        return $false
    }

    if ($State.ContainerLocation -eq 'LOCAL') {
        if ($Create -and -not (Test-Path -LiteralPath $Path)) {
            # Only reached when the caller explicitly asked to create the folder (see -Create).
            # -Force also creates missing parent folders.
            try {
                New-Item -ItemType Directory -Path $Path -Force -ErrorAction Stop | Out-Null
                Write-Log "Created local directory for ${PathKey}: $Path" 'Info'
            } catch {
                Write-Log "Could not create local directory ${Path}: $($_.Exception.Message)" 'Error'
                Set-Reason 'CreateFailed'
                return $false
            }
        }
        try {
            $resolved = Resolve-Path -LiteralPath $Path -ErrorAction Stop
            $native = $resolved.Path
        } catch {
            Write-Log "Local path missing or not a directory (no auto-create): $Path" 'Error'
            Set-Reason 'Missing'
            return $false
        }
    } else {
        $native = $Path
    }

    if (-not (Test-Path $native -PathType Container)) {
        Write-Log "Local path missing or not a directory (no auto-create): $native" 'Error'
        Set-Reason 'Missing'
        return $false
    }
    Write-Log "Local directory exists for ${PathKey}: $native" 'Debug'
    return $true
}

# ══════════════════════════════════════════════════════════════════════════════
#  Git helpers
# ══════════════════════════════════════════════════════════════════════════════
function Get-GitRepositoryState {
    param(
        [pscustomobject]$State,
        [string]$RepoPath,
        [bool]$IsRemote
    )
    if (-not $RepoPath) { return $null }
    Write-Log "Checking git status for repo at $RepoPath (remote=$IsRemote)" 'Info'
    try {
        if ($IsRemote) {
            $remoteHost = Get-RemoteHostString -State $State
            $keyPath = $State.Paths.SshPrivate
            $cmd = "cd '$RepoPath' && git status --porcelain=v1 && git rev-parse --abbrev-ref HEAD && git remote get-url origin"
            $out = & ssh -n -i $keyPath -o StrictHostKeyChecking=accept-new -o IdentitiesOnly=yes -o ConnectTimeout=20 -o BatchMode=yes $remoteHost $cmd 2>$null
            $lines = ($out -split "`n")
            $statusLines = @()
            $branch = ''
            $remote = ''
            foreach ($line in $lines) {
                if ($line -match '^(\?\?| M|A |D )') { $statusLines += $line; continue }
                if (-not $branch) { $branch = $line; continue }
                if (-not $remote) { $remote = $line }
            }
            Write-Log "Git status (remote) lines: $([string]::Join(';', $statusLines)) branch=$branch remote=$remote" 'Debug'
            return [pscustomobject]@{ HasChanges = [bool]$statusLines; StatusText = ($statusLines -join "`n"); Branch=$branch; Remote=$remote }
        } else {
            Push-Location $RepoPath
            $lines = @(git status --porcelain=v1 2>$null)
            if (-not $lines) { $lines = @() }
            $branch = (git rev-parse --abbrev-ref HEAD 2>$null)
            $remote = git remote get-url origin 2>$null
            Pop-Location
            Write-Log "Git status (local) lines: $([string]::Join(';', $lines)) branch=$branch remote=$remote" 'Debug'
            return [pscustomobject]@{ HasChanges = [bool]$lines; StatusText = ($lines -join "`n"); Branch=$branch; Remote=$remote }
        }
    } catch {
        Write-Log "Git status retrieval failed: $($_.Exception.Message)" 'Debug'
        return $null
    }
}

function Show-GitCommitDialog {
    param([string]$ChangesText)
    if ($script:NonInteractive) {
        Write-Log 'NonInteractive: skipping git commit dialog.' 'Info'
        return $null
    }
    Write-Log 'Prompting user to commit/push git changes.' 'Info'
    $form = New-Object System.Windows.Forms.Form -Property @{ Text='Git Changes Detected'; Size=New-Object System.Drawing.Size(640,540); FormBorderStyle='FixedDialog'; MaximizeBox=$false }
    Set-FormCenterOnCurrentScreen -Form $form
    Apply-ThemeToForm -Form $form

    $lbl = New-Object System.Windows.Forms.Label -Property @{ Text='Uncommitted changes detected. Review and commit?'; Location=New-Object System.Drawing.Point(14,12); Size=New-Object System.Drawing.Size(600,22) }
    Style-Label -Label $lbl -Style ([System.Drawing.FontStyle]::Bold)
    $form.Controls.Add($lbl)

    $txtChanges = New-Object System.Windows.Forms.TextBox -Property @{ Location=New-Object System.Drawing.Point(14,40); Size=New-Object System.Drawing.Size(600,310); Multiline=$true; ScrollBars='Vertical'; ReadOnly=$true; Font=New-Object System.Drawing.Font('Consolas',9); Text=$ChangesText }
    Style-TextBox -TextBox $txtChanges
    $txtChanges.BackColor = $script:ThemePalette.Panel
    $txtChanges.Font = New-Object System.Drawing.Font('Consolas',9,[System.Drawing.FontStyle]::Regular)
    $form.Controls.Add($txtChanges)

    $lblMsg = New-Object System.Windows.Forms.Label -Property @{ Text='Commit message:'; Location=New-Object System.Drawing.Point(14,360); Size=New-Object System.Drawing.Size(200,22) }
    Style-Label -Label $lblMsg
    $form.Controls.Add($lblMsg)

    $txtMsg = New-Object System.Windows.Forms.TextBox -Property @{ Location=New-Object System.Drawing.Point(14,385); Size=New-Object System.Drawing.Size(600,26) }
    Style-TextBox -TextBox $txtMsg
    $form.Controls.Add($txtMsg)

    $chkPush = New-Object System.Windows.Forms.CheckBox -Property @{ Text='Push to origin after commit'; Location=New-Object System.Drawing.Point(14,420); Size=New-Object System.Drawing.Size(280,24); Checked=$true }
    Style-CheckBox -CheckBox $chkPush
    $form.Controls.Add($chkPush)

    $btnOk = New-Object System.Windows.Forms.Button -Property @{ Text='Commit'; Location=New-Object System.Drawing.Point(360,460); Size=New-Object System.Drawing.Size(110,36) }
    $btnCancel = New-Object System.Windows.Forms.Button -Property @{ Text='Skip'; Location=New-Object System.Drawing.Point(504,460); Size=New-Object System.Drawing.Size(110,36); DialogResult=[System.Windows.Forms.DialogResult]::Cancel }
    Style-Button -Button $btnOk -Variant 'primary'
    Style-Button -Button $btnCancel -Variant 'secondary'
    $btnOk.Add_Click({ if (-not $txtMsg.Text.Trim()) { [System.Windows.Forms.MessageBox]::Show('Enter a commit message.','Message required','OK','Warning') | Out-Null; return }; $form.DialogResult=[System.Windows.Forms.DialogResult]::OK; $form.Close() })
    $form.AcceptButton=$btnOk; $form.CancelButton=$btnCancel; $form.Controls.Add($btnOk); $form.Controls.Add($btnCancel)
    $result = $form.ShowDialog()
    if ($result -ne [System.Windows.Forms.DialogResult]::OK) { return $null }
    return @{ Message=$txtMsg.Text.Trim(); Push=$chkPush.Checked }
}

function Invoke-GitChangeDetection {
    param(
        [pscustomobject]$State,
        [string]$RepoPath,
        [bool]$IsRemote
    )
    Write-Log "Detecting git changes at $RepoPath (remote=$IsRemote)" 'Info'
    $gitState = Get-GitRepositoryState -State $State -RepoPath $RepoPath -IsRemote $IsRemote
    if (-not $gitState -or -not $gitState.HasChanges) { return }
    $dialogResult = Show-GitCommitDialog -ChangesText $gitState.StatusText
    if (-not $dialogResult) { Write-Log 'User skipped git commit/push.' 'Info'; return }

    $msg = $dialogResult.Message
    $doPush = $dialogResult.Push
    $safeMsg = $msg.Replace('"','\"')

    try {
        if ($IsRemote) {
            $remoteHost = Get-RemoteHostString -State $State
            $keyPath = $State.Paths.SshPrivate
            $remoteUrl = & ssh -n -i $keyPath -o StrictHostKeyChecking=accept-new -o IdentitiesOnly=yes -o ConnectTimeout=15 -o BatchMode=yes $remoteHost "cd '$RepoPath' && git remote get-url origin" 2>$null
            if ($remoteUrl -and $remoteUrl -match '^https://github.com/(.+)$') {
                $sshUrl = "git@github.com:$($matches[1])"
                & ssh -n -i $keyPath -o StrictHostKeyChecking=accept-new -o IdentitiesOnly=yes -o ConnectTimeout=15 -o BatchMode=yes $remoteHost "cd '$RepoPath' && git remote set-url origin '$sshUrl'" 2>$null
            }
            $commitCmd = "cd '$RepoPath' && git add -A && git commit -m `"$safeMsg`""
            $commitOut = & ssh -n -i $keyPath -o StrictHostKeyChecking=accept-new -o IdentitiesOnly=yes -o ConnectTimeout=15 -o BatchMode=yes $remoteHost $commitCmd 2>&1
            Write-Log "Remote git commit exit=$LASTEXITCODE output=$commitOut" 'Debug'
            if ($LASTEXITCODE -ne 0 -and $commitOut -notmatch 'nothing to commit') {
                if (-not $script:NonInteractive) { [System.Windows.Forms.MessageBox]::Show("Git commit failed on remote: $commitOut",'Git commit failed','OK','Error') | Out-Null }
                return
            }
            if ($LASTEXITCODE -eq 0) { Write-Log 'Git commit completed on remote.' 'Info' }
            if ($doPush) {
                $remoteKey = "~/.ssh/id_ed25519_$($State.UserName)"
                # Try 1: IMPACT-specific key via ssh-agent
                $pushAgent = "cd '$RepoPath' && eval `$(ssh-agent -s) && ssh-add $remoteKey 2>/dev/null && GIT_SSH_COMMAND='ssh -i $remoteKey -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new' git push"
                $pushOut = & ssh -n -i $keyPath -o StrictHostKeyChecking=accept-new -o IdentitiesOnly=yes -o ConnectTimeout=15 -o BatchMode=yes $remoteHost $pushAgent 2>&1
                Write-Log "Remote git push (agent) exit=$LASTEXITCODE output=$pushOut" 'Debug'
                if ($LASTEXITCODE -ne 0) {
                    # Try 2: IMPACT-specific key directly (no agent)
                    $pushDirect = "cd '$RepoPath' && GIT_SSH_COMMAND='ssh -i $remoteKey -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new' git push"
                    $pushOut = & ssh -n -i $keyPath -o StrictHostKeyChecking=accept-new -o IdentitiesOnly=yes -o ConnectTimeout=15 -o BatchMode=yes $remoteHost $pushDirect 2>&1
                    Write-Log "Remote git push (direct) exit=$LASTEXITCODE output=$pushOut" 'Debug'
                }
                if ($LASTEXITCODE -ne 0) {
                    # Try 3: workstation's own key (commonly named id_ed25519_workstation)
                    Write-Log 'IMPACT key push failed; trying workstation SSH keys.' 'Warn'
                    $pushWs = "cd '$RepoPath' && for k in ~/.ssh/id_ed25519_workstation ~/.ssh/id_ed25519 ~/.ssh/id_rsa; do [ -f `"`$k`" ] && GIT_SSH_COMMAND='ssh -i `$k -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new' git push && exit 0; done; exit 1"
                    $pushOut = & ssh -n -i $keyPath -o StrictHostKeyChecking=accept-new -o IdentitiesOnly=yes -o ConnectTimeout=15 -o BatchMode=yes $remoteHost $pushWs 2>&1
                    Write-Log "Remote git push (workstation keys) exit=$LASTEXITCODE output=$pushOut" 'Debug'
                }
                if ($LASTEXITCODE -ne 0) {
                    # Try 4: let the workstation's SSH config / agent decide
                    Write-Log 'Explicit key push failed; falling back to default SSH identity.' 'Warn'
                    $pushDefault = "cd '$RepoPath' && git push"
                    $pushOut = & ssh -n -i $keyPath -o StrictHostKeyChecking=accept-new -o IdentitiesOnly=yes -o ConnectTimeout=15 -o BatchMode=yes $remoteHost $pushDefault 2>&1
                    Write-Log "Remote git push (default SSH) exit=$LASTEXITCODE output=$pushOut" 'Debug'
                }
                if ($LASTEXITCODE -ne 0) {
                    if (-not $script:NonInteractive) { [System.Windows.Forms.MessageBox]::Show("Git push failed on remote: $pushOut",'Git push failed','OK','Error') | Out-Null }
                } else { Write-Log 'Git push completed on remote.' 'Info' }
            }
        } else {
            Push-Location $RepoPath
            $url = git remote get-url origin 2>$null
            if ($url -and $url -match '^https://github.com/(.+)$') {
                $sshUrl = "git@github.com:$($matches[1])"
                git remote set-url origin $sshUrl 2>$null
            }
            git add -A | Out-Null
            $commitLocal = git commit -m $msg 2>&1
            Write-Log "Local git commit output: $commitLocal" 'Debug'
            Write-Log 'Git commit completed locally.' 'Info'
            if ($doPush) {
                $pushLocal = git push 2>&1
                Write-Log "Local git push output: $pushLocal" 'Debug'
                Write-Log 'Git push completed locally.' 'Info'
            }
            Pop-Location
        }
    } catch {
        Write-Log "Git change detection error: $($_.Exception.Message)" 'Warn'
        if (-not $script:NonInteractive) {
            [System.Windows.Forms.MessageBox]::Show('Git commit/push encountered an error. See console for details.','Git error','OK','Error') | Out-Null
        }
    }
}

# ══════════════════════════════════════════════════════════════════════════════
#  UI / theming helpers
# ══════════════════════════════════════════════════════════════════════════════
function Set-FormCenterOnCurrentScreen {
    param([System.Windows.Forms.Form]$Form)
    try {
        if (-not ('Win32' -as [type])) {
            Add-Type -TypeDefinition @"
        using System;
        using System.Runtime.InteropServices;
        using System.Drawing;
        public struct POINT { public int X; public int Y; }
        public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }
        public class Win32 {
            [DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT lpPoint);
            [DllImport("user32.dll")] public static extern IntPtr MonitorFromPoint(POINT pt, uint dwFlags);
            [DllImport("user32.dll")] public static extern bool GetMonitorInfo(IntPtr hMonitor, ref MONITORINFO lpmi);
        }
        [StructLayout(LayoutKind.Sequential)]
        public struct MONITORINFO { public uint cbSize; public RECT rcMonitor; public RECT rcWork; public uint dwFlags; }
"@
        }
        $cursorPos = New-Object POINT
        [Win32]::GetCursorPos([ref]$cursorPos) | Out-Null
        $monitor = [Win32]::MonitorFromPoint($cursorPos, 2)
        $monitorInfo = New-Object MONITORINFO
        $monitorInfo.cbSize = [System.Runtime.InteropServices.Marshal]::SizeOf($monitorInfo)
        [Win32]::GetMonitorInfo($monitor, [ref]$monitorInfo) | Out-Null
        $screenWidth = $monitorInfo.rcWork.Right - $monitorInfo.rcWork.Left
        $screenHeight = $monitorInfo.rcWork.Bottom - $monitorInfo.rcWork.Top
        $screenLeft = $monitorInfo.rcWork.Left
        $screenTop = $monitorInfo.rcWork.Top
        $centerX = $screenLeft + (($screenWidth - $Form.Width) / 2)
        $centerY = $screenTop + (($screenHeight - $Form.Height) / 2)
        $Form.StartPosition = 'Manual'
        $Form.Location = New-Object System.Drawing.Point([int]$centerX, [int]$centerY)
    } catch {
        Write-Log "Failed to center form on current screen: $($_.Exception.Message)" 'Debug'
        $Form.StartPosition = 'CenterScreen'
    }
}

function Get-ThemePalette {
    Initialize-ThemePalette
    return $script:ThemePalette
}

function Initialize-ThemePalette {
    if ($script:ThemePalette) { return }
    $script:ThemePalette = @{
        Back      = [System.Drawing.Color]::FromArgb(12,15,25)
        Panel     = [System.Drawing.Color]::FromArgb(23,28,44)
        Accent    = [System.Drawing.Color]::FromArgb(31,122,140)
        AccentAlt = [System.Drawing.Color]::FromArgb(240,180,60)
        Text      = [System.Drawing.Color]::FromArgb(229,233,240)
        Muted     = [System.Drawing.Color]::FromArgb(157,165,180)
        Danger    = [System.Drawing.Color]::FromArgb(200,70,70)
        Success   = [System.Drawing.Color]::FromArgb(76,161,115)
        Field     = [System.Drawing.Color]::FromArgb(28,34,52)
    }
}

function Apply-ThemeToForm {
    param([System.Windows.Forms.Form]$Form)
    Initialize-ThemePalette
    $Form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::Dpi
    $Form.BackColor = $script:ThemePalette.Back
    $Form.ForeColor = $script:ThemePalette.Text
    $Form.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Regular)
}

function Style-Label {
    param([System.Windows.Forms.Label]$Label,[bool]$Muted=$false,[System.Drawing.FontStyle]$Style=[System.Drawing.FontStyle]::Regular)
    Initialize-ThemePalette
    $Label.ForeColor = if ($Muted) { $script:ThemePalette.Muted } else { $script:ThemePalette.Text }
    if ($Label.Font) {
        $Label.Font = New-Object System.Drawing.Font('Segoe UI', $Label.Font.Size, $Style)
    } else {
        $Label.Font = New-Object System.Drawing.Font('Segoe UI', 10, $Style)
    }
}

function Style-TextBox {
    param([System.Windows.Forms.TextBox]$TextBox)
    Initialize-ThemePalette
    $TextBox.BorderStyle = 'FixedSingle'
    $TextBox.BackColor = $script:ThemePalette.Field
    $TextBox.ForeColor = $script:ThemePalette.Text
    $TextBox.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Regular)
}

function Style-CheckBox {
    param([System.Windows.Forms.CheckBox]$CheckBox)
    Initialize-ThemePalette
    $CheckBox.ForeColor = $script:ThemePalette.Text
    if ($CheckBox.Font) {
        $CheckBox.Font = New-Object System.Drawing.Font('Segoe UI', $CheckBox.Font.Size, [System.Drawing.FontStyle]::Regular)
    }
}

function Style-Button {
    param([System.Windows.Forms.Button]$Button,[ValidateSet('primary','secondary','danger','ghost')]$Variant='primary')
    Initialize-ThemePalette
    $Button.FlatStyle = 'Flat'
    $Button.FlatAppearance.BorderSize = 0
    $Button.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 10, [System.Drawing.FontStyle]::Bold)
    switch ($Variant) {
        'primary'   { $Button.BackColor = $script:ThemePalette.Accent;    $Button.ForeColor = $script:ThemePalette.Text }
        'secondary' { $Button.BackColor = $script:ThemePalette.Panel;     $Button.ForeColor = $script:ThemePalette.Text }
        'danger'    { $Button.BackColor = $script:ThemePalette.Danger;    $Button.ForeColor = $script:ThemePalette.Text }
        'ghost'     { $Button.BackColor = $script:ThemePalette.Field;     $Button.ForeColor = $script:ThemePalette.Text }
    }
}

function Style-InfoBox {
    param([System.Windows.Forms.RichTextBox]$Box)
    Initialize-ThemePalette
    $Box.BorderStyle = 'None'
    $Box.BackColor = $script:ThemePalette.Back
    $Box.ForeColor = $script:ThemePalette.Text
    $Box.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Regular)
    $Box.ReadOnly = $true
}

# ══════════════════════════════════════════════════════════════════════════════
#  Startup Prerequisites
# ══════════════════════════════════════════════════════════════════════════════
function Test-StartupPrerequisites {
    param([pscustomobject]$State)

    $dockerCmd = Get-Command docker -ErrorAction SilentlyContinue
    if (-not $dockerCmd) {
        Write-Log 'Docker CLI not found. Install Docker Desktop (Windows) or ensure docker is on PATH.' 'Error'
        if (-not $script:NonInteractive) {
            # Double quotes are required here: inside single quotes PowerShell shows `n
            # literally instead of starting a new line.
            # Docker Desktop (admin rights + licence) is only needed to run containers on
            # this PC; for the remote workstation the docker command-line tool is enough.
            $dockerMsg = "The Docker command-line tool (docker) was not found on this computer.`n`n" +
                "- To run containers on THIS computer: install Docker Desktop.`n" +
                "- To work ONLY on the remote workstation: Docker Desktop is not needed. The Docker command-line tool (docker.exe) in a folder on your PATH is enough.`n`n" +
                "Then start IMPACT again."
            [System.Windows.Forms.MessageBox]::Show($dockerMsg,'Docker missing','OK','Error') | Out-Null
        }
        return $false
    }
    Write-Log "Docker CLI found at $($dockerCmd.Source)." 'Debug'

    $sshCmd = Get-Command ssh -ErrorAction SilentlyContinue
    if (-not $sshCmd) {
        # On many (managed) PCs the Windows OpenSSH client IS installed, only its folder
        # is missing from PATH. Using it directly needs no admin rights at all.
        $builtinSshDir = $null
        if ($env:WINDIR) { $builtinSshDir = Join-Path $env:WINDIR 'System32\OpenSSH' }
        if ($builtinSshDir -and (Test-Path -LiteralPath (Join-Path $builtinSshDir 'ssh.exe'))) {
            Write-Log "OpenSSH client found at $builtinSshDir but that folder is not on PATH; adding it for this session." 'Warn'
            $env:PATH = "$builtinSshDir;$env:PATH"
            $sshCmd = Get-Command ssh -ErrorAction SilentlyContinue
        }
    }
    if (-not $sshCmd) {
        Write-Log 'OpenSSH client not found on PATH. Offering to install it.' 'Warn'
        try {
            # Ask FIRST, then check and install inside the elevated process.
            # The old code first ran Get-WindowsCapability here, without admin rights. That
            # command needs admin rights, so it returned nothing and the install offer
            # never appeared.
            if (-not $script:NonInteractive) {
                $installChoice = [System.Windows.Forms.MessageBox]::Show(
                    "The OpenSSH Client is not installed on this machine.`n`nThe tool needs ssh, ssh-keygen, and ssh-agent to function.`n`nInstall it now? (requires Administrator rights - a Windows permission (UAC) prompt will appear)",
                    'Install OpenSSH Client?',
                    [System.Windows.Forms.MessageBoxButtons]::YesNo,
                    [System.Windows.Forms.MessageBoxIcon]::Question)
                if ($installChoice -eq [System.Windows.Forms.DialogResult]::Yes) {
                    Write-Log 'User agreed to install OpenSSH Client. Launching elevated install.' 'Info'
                    $elevatedCmd = "try { Get-WindowsCapability -Online -Name 'OpenSSH.Client*' -ErrorAction Stop | Where-Object { `$_.State -ne 'Installed' } | Add-WindowsCapability -Online -ErrorAction Stop | Out-Null; exit 0 } catch { Write-Error `$_; exit 1 }"
                    # -EncodedCommand avoids any quoting problems when the command is handed
                    # to the elevated process.
                    $encodedCmd = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($elevatedCmd))
                    # Windows PowerShell is used for this step because the Windows capability
                    # (DISM) commands are always built into it on Windows 10/11.
                    $installShell = if (Get-Command powershell.exe -ErrorAction SilentlyContinue) { 'powershell.exe' } else { 'pwsh' }
                    # Start-Process -Verb RunAs throws if the UAC prompt is cancelled or the
                    # user has no admin rights; that is handled in the catch below.
                    $proc = Start-Process $installShell -ArgumentList '-NoProfile','-NoLogo','-NonInteractive','-EncodedCommand',$encodedCmd -Verb RunAs -Wait -PassThru -ErrorAction Stop
                    if ($proc.ExitCode -eq 0) {
                        Write-Log 'OpenSSH Client installed successfully via elevated process.' 'Info'
                        $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
                        $userPath    = [Environment]::GetEnvironmentVariable('Path', 'User')
                        $env:PATH = "$machinePath;$userPath"
                    } else {
                        Write-Log "Elevated OpenSSH install exited with code $($proc.ExitCode)" 'Warn'
                    }
                } else {
                    Write-Log 'User declined OpenSSH Client install.' 'Warn'
                }
            }
        } catch {
            Write-Log "OpenSSH install could not be run (permission prompt cancelled or no administrator rights?): $($_.Exception.Message)" 'Warn'
        }

        $sshCmd = Get-Command ssh -ErrorAction SilentlyContinue
        if (-not $sshCmd) {
            $manualMsg = "OpenSSH Client (ssh) is required but not installed."
            Write-Log 'OpenSSH client still not found after install attempt.' 'Error'
            if (-not $script:NonInteractive) {
                $fullMsg = $manualMsg + "`n`nInstalling it needs administrator rights. If you do not have them, please ask your IT department to install the Windows feature 'OpenSSH Client'.`n`nWith administrator rights, run this in an Administrator PowerShell:`n`n  Add-WindowsCapability -Online -Name OpenSSH.Client~~~~0.0.1.0`n`nThen restart this tool."
                [System.Windows.Forms.MessageBox]::Show($fullMsg, 'SSH missing', 'OK', 'Error') | Out-Null
            }
            return $false
        }
    }

    Write-Log "Prereq check passed (Docker CLI at $($dockerCmd.Source), ssh present)." 'Info'
    return $true
}

function Ensure-Prerequisites {
    param([pscustomobject]$State)
    Write-Log 'Checking PowerShell version and elevation' 'Info'

    if (-not $script:NonInteractive) {
        Write-Log 'Loading UI dependencies (WinForms, Drawing).' 'Debug'
        Add-Type -AssemblyName System.Windows.Forms
        Add-Type -AssemblyName System.Drawing
        [System.Windows.Forms.Application]::EnableVisualStyles()
    }

    Write-Log "Detected PowerShell $($PSVersionTable.PSVersion) (Major=$($PSVersionTable.PSVersion.Major))" 'Debug'

    # docker, ssh and git print their text as UTF-8. PowerShell decodes the output of
    # such programs with [Console]::OutputEncoding, which on Windows defaults to the old
    # DOS code page (e.g. 850 on German PCs). Umlauts in passwords or repository names
    # read back from docker/ssh were therefore shown as pairs of garbage characters.
    # Switch this process to UTF-8 (without a byte-order mark).
    try {
        [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
    } catch {
        Write-Log "Could not switch console output encoding to UTF-8: $($_.Exception.Message)" 'Debug'
    }

    if (-not (Test-StartupPrerequisites -State $State)) { return $false }

    $isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] 'Administrator')
    Write-Log "Administrative privileges: $isAdmin" 'Debug'
    if (-not $isAdmin) {
        Write-Log 'Administrator privileges not present; continuing without elevation.' 'Warn'
    }

    try {
        $raw = $Host.UI.RawUI
        $raw.BackgroundColor = 'Black'
        $raw.ForegroundColor = 'White'
        $raw.WindowTitle = 'IMPACT NCD Germany - Docker GUI'
        Clear-Host
        Write-Log 'Console cleared; prerequisites complete.' 'Debug'
    } catch {
        Write-Log 'Could not adjust console colors.' 'Debug'
    }

    # git on this PC is optional (only LOCAL mode uses it, to offer commit/push when a
    # container is stopped), so a missing git must not block the tool. But without this
    # note the commit dialog would simply never appear and nobody would know why.
    # The check runs after Clear-Host so the warning stays visible in the console.
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        Write-Log 'Git was not found on this computer (it is not on PATH). In LOCAL mode IMPACT therefore cannot offer to commit/push your changes when you stop the container. Commit from the Git tab in RStudio instead, or install Git for Windows (https://git-scm.com/download/win).' 'Warn'
    }

    return $true
}

# ══════════════════════════════════════════════════════════════════════════════
#  Credential Dialog
# ══════════════════════════════════════════════════════════════════════════════
function Resolve-GitHubUsernameInput {
    <#
    .SYNOPSIS Cleans up the text typed into the "GitHub username" box and checks its
              format locally, before GitHub is asked. Pure logic (no UI, no network),
              so it can be unit tested.
    .OUTPUTS  [pscustomobject] @{ UserName = <cleaned lowercase name or $null>;
                                  Problem  = <message for the user or $null> }
    #>
    param([string]$InputText)

    $name = if ($null -ne $InputText) { $InputText } else { '' }
    # Remove all spaces and use lowercase. GitHub names are not case sensitive, and the
    # tool uses the name in file names and container names.
    $name = ($name -replace '\s+', '').ToLowerInvariant()
    # Accept a pasted profile link such as 'https://github.com/jdoe?tab=repositories'
    # by keeping only the part right after 'github.com/'.
    if ($name -match '^(?:https?://)?(?:www\.)?github\.com/([^/?#]+)') { $name = $matches[1] }
    # Accept the '@jdoe' form that GitHub uses for mentions.
    $name = $name.TrimStart('@')

    if (-not $name) {
        return [pscustomobject]@{ UserName = $null; Problem = 'Please enter your GitHub username.' }
    }
    # Many people log in to github.com with their e-mail address, so they type it here.
    if ($name.Contains('@')) {
        return [pscustomobject]@{ UserName = $null; Problem = "'$name' looks like an e-mail address. Please enter your GitHub USERNAME instead.`n`nTo find it, log in to github.com and click your profile picture (top right): the name shown there is your username. It is also the last part of your profile address github.com/<username>." }
    }
    # GitHub usernames contain only letters, digits and hyphens (at most 39 characters).
    # Underscores are allowed too, because company-managed GitHub accounts use them.
    # This check also keeps characters such as ? # / $ or quotes out of the file paths,
    # container names and shell commands that are built from the username later on.
    if ($name -notmatch '^[a-z0-9][a-z0-9_-]{0,38}$') {
        return [pscustomobject]@{ UserName = $null; Problem = "'$name' is not a valid GitHub username. GitHub usernames contain only letters, digits and hyphens (at most 39 characters)." }
    }
    return [pscustomobject]@{ UserName = $name; Problem = $null }
}

function Get-RStudioPasswordProblem {
    <#
    .SYNOPSIS Checks the password chosen for RStudio Server. Returns $null when it is
              acceptable, otherwise a message for the user. Pure logic (unit tested).
    .NOTES    This password is the ONLY protection of the RStudio web page, which can be
              reached over the network and holds the user's GitHub SSH key. Before, any
              non-empty text (even '1') was accepted.
    #>
    param(
        [string]$Password,
        [string]$UserName
    )
    $minLength = 8
    if ([string]::IsNullOrWhiteSpace($Password)) {
        return 'Please choose a password for RStudio.'
    }
    if ($Password.Length -lt $minLength) {
        return "The RStudio password must be at least $minLength characters long."
    }
    if ($UserName -and $Password -ieq $UserName) {
        return 'The RStudio password must not be the same as your username.'
    }
    # A few passwords that attackers always try first (-contains ignores upper/lower case).
    $tooCommon = @('password','passwort','12345678','123456789','1234567890','87654321','11111111','00000000','qwertyui','qwertzui','abcdefgh','iloveyou','rstudio1','rstudio123')
    if ($tooCommon -contains $Password) {
        return 'This password is too easy to guess. Please choose another one.'
    }
    return $null
}

function Show-CredentialDialog {
    param([pscustomobject]$State)

    # NonInteractive: expect UserName and Password to be pre-set on State
    if ($script:NonInteractive) {
        Write-Log 'NonInteractive: using pre-set credentials from State.' 'Info'
        if (-not $State.UserName -or -not $State.Password) {
            Write-Log 'NonInteractive: UserName/Password not pre-set on state.' 'Error'
            return 'cancel'
        }
        # Same clean-up and format check as in the interactive dialog below.
        $nameCheck = Resolve-GitHubUsernameInput -InputText $State.UserName
        if ($nameCheck.Problem) {
            Write-Log "NonInteractive: '$($State.UserName)' is not a valid GitHub username: $($nameCheck.Problem)" 'Error'
            return 'cancel'
        }
        $State.UserName = $nameCheck.UserName
        # Headless/CI runs only get a warning for a weak password, so automated tests with
        # fixed test passwords keep working. Real users always go through the dialog.
        $pwProblem = Get-RStudioPasswordProblem -Password $State.Password -UserName $State.UserName
        if ($pwProblem) { Write-Log "NonInteractive: weak RStudio password: $pwProblem" 'Warn' }
        $ghCheck = Test-GitHubUsername -UserName $State.UserName -Detailed
        if ($ghCheck.Status -eq 'Exists') { return 'next' }
        if ($ghCheck.Status -eq 'Unknown') {
            # GitHub could not be asked (offline, proxy, rate limit). That says nothing
            # about the username itself, so do not block the run; just record it.
            Write-Log "NonInteractive: could not verify GitHub username '$($State.UserName)'; continuing. $($ghCheck.Message)" 'Warn'
            return 'next'
        }
        Write-Log "NonInteractive: '$($State.UserName)' is not a valid GitHub username. $($ghCheck.Message)" 'Error'
        return 'cancel'
    }

    Write-Log 'Collecting credentials - opening dialog.' 'Info'

    # When the user comes back here with "Back" from the location step, the state already
    # holds credentials that were checked before. They are shown again (pre-filled), and
    # Cancel then keeps them instead of closing the whole application.
    $hadPreviousCredentials = [bool]($State.UserName -and $State.Password)

    $form = New-Object System.Windows.Forms.Form -Property @{
        Text = 'Remote Access - IMPACT NCD Germany'
        Size = New-Object System.Drawing.Size(540,390)
        StartPosition = 'CenterScreen'
        FormBorderStyle = 'FixedDialog'
        MaximizeBox = $false
    }
    Set-FormCenterOnCurrentScreen -Form $form
    Apply-ThemeToForm -Form $form

    $rtbInstruction = New-Object System.Windows.Forms.RichTextBox -Property @{
        Location = New-Object System.Drawing.Point(14,12)
        Size = New-Object System.Drawing.Size(500,200)
        Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Regular)
        ReadOnly = $true
        BorderStyle = 'None'
        BackColor = $form.BackColor
        ScrollBars = 'None'
    }
    # Apply the theme to the box FIRST. Style-InfoBox sets one font and colour for ALL
    # text in the box; when it ran after the text had been added (as before), it wiped
    # out the bold and coloured parts. The colours now come from the dark theme palette,
    # because the old Black and DarkRed text was hard to read on the dark background.
    # The box is also taller than before so that the last line is no longer cut off.
    Style-InfoBox -Box $rtbInstruction
    $palette = Get-ThemePalette
    $fontHeading = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
    $fontBold    = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
    $fontRegular = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Regular)
    $fontSmall   = New-Object System.Drawing.Font('Segoe UI', 8, [System.Drawing.FontStyle]::Regular)

    # The wording makes clear that the password is a NEW one for RStudio and NOT the
    # GitHub password. People typed their GitHub password here, and this password can be
    # read by colleagues (docker inspect, files of the shared workstation account).
    $rtbInstruction.SelectionFont = $fontHeading
    $rtbInstruction.SelectionColor = $palette.Text
    $rtbInstruction.AppendText("Enter your GitHub username and choose a NEW password for RStudio.`n`n")
    $rtbInstruction.SelectionFont = $fontBold
    $rtbInstruction.SelectionColor = $palette.AccentAlt
    $rtbInstruction.AppendText('GitHub username: ')
    $rtbInstruction.SelectionFont = $fontRegular
    $rtbInstruction.SelectionColor = $palette.Text
    $rtbInstruction.AppendText("your GitHub username (not your e-mail address). It is used for your SSH key, your git identity and your container name.`n")
    $rtbInstruction.SelectionFont = $fontBold
    $rtbInstruction.SelectionColor = $palette.AccentAlt
    $rtbInstruction.AppendText('RStudio password: ')
    $rtbInstruction.SelectionFont = $fontRegular
    $rtbInstruction.SelectionColor = $palette.Text
    $rtbInstruction.AppendText("a NEW password of at least 8 characters. You will use it to log in to RStudio Server in your web browser.`n")
    $rtbInstruction.SelectionFont = $fontBold
    $rtbInstruction.SelectionColor = $palette.Danger
    $rtbInstruction.AppendText("Do NOT use your GitHub password (or any password you use elsewhere): colleagues with access to the workstation can read this password.`n")
    $rtbInstruction.SelectionFont = $fontSmall
    $rtbInstruction.SelectionColor = $palette.Muted
    $rtbInstruction.AppendText('(The username is checked on github.com and converted to lowercase.)')
    $form.Controls.Add($rtbInstruction)

    # Labels are wider than before (150 px) so 'RStudio password' fits; the text boxes
    # moved right and down accordingly.
    $labelUser = New-Object System.Windows.Forms.Label -Property @{ Text = 'GitHub username'; Location = New-Object System.Drawing.Point(14,220); Size = New-Object System.Drawing.Size(150,22) }
    Style-Label -Label $labelUser -Style ([System.Drawing.FontStyle]::Bold)
    $form.Controls.Add($labelUser)
    $textUser = New-Object System.Windows.Forms.TextBox -Property @{ Location = New-Object System.Drawing.Point(170,218); Size = New-Object System.Drawing.Size(330,26) }
    Style-TextBox -TextBox $textUser
    # Pre-fill with what was entered earlier (when coming back with "Back").
    if ($State.UserName) { $textUser.Text = [string]$State.UserName }
    $form.Controls.Add($textUser)

    $labelPass = New-Object System.Windows.Forms.Label -Property @{ Text = 'RStudio password'; Location = New-Object System.Drawing.Point(14,255); Size = New-Object System.Drawing.Size(150,22) }
    Style-Label -Label $labelPass -Style ([System.Drawing.FontStyle]::Bold)
    $form.Controls.Add($labelPass)
    $textPass = New-Object System.Windows.Forms.TextBox -Property @{ Location = New-Object System.Drawing.Point(170,253); Size = New-Object System.Drawing.Size(330,26); UseSystemPasswordChar = $true }
    Style-TextBox -TextBox $textPass
    if ($State.Password) { $textPass.Text = [string]$State.Password }
    $form.Controls.Add($textPass)

    $buttonOK = New-Object System.Windows.Forms.Button -Property @{ Text = 'Continue'; Location = New-Object System.Drawing.Point(170,298); Size = New-Object System.Drawing.Size(110,34) }
    Style-Button -Button $buttonOK -Variant 'primary'
    $form.Controls.Add($buttonOK)

    $buttonCancel = New-Object System.Windows.Forms.Button -Property @{ Text = 'Cancel'; Location = New-Object System.Drawing.Point(290,298); Size = New-Object System.Drawing.Size(110,34); DialogResult = [System.Windows.Forms.DialogResult]::Cancel }
    Style-Button -Button $buttonCancel -Variant 'secondary'
    $form.Controls.Add($buttonCancel)

    $form.AcceptButton = $buttonOK
    $form.CancelButton = $buttonCancel
    $form.Add_Shown({ $textUser.Focus() })

    # Filled by the Continue handler once everything is valid. A hashtable is used
    # because the handler runs in its own scope: a plain variable assigned there would
    # not be visible here after the dialog closes.
    $accepted = @{ UserName = $null }

    $buttonOK.Add_Click({
        # 1) Quick local checks (no network needed).
        $nameCheck = Resolve-GitHubUsernameInput -InputText $textUser.Text
        if ($nameCheck.Problem) {
            [System.Windows.Forms.MessageBox]::Show($nameCheck.Problem, 'Check your GitHub username', 'OK', 'Warning') | Out-Null
            [void]$textUser.Focus(); $textUser.SelectAll()
            return
        }
        $pwProblem = Get-RStudioPasswordProblem -Password $textPass.Text -UserName $nameCheck.UserName
        if ($pwProblem) {
            [System.Windows.Forms.MessageBox]::Show($pwProblem, 'Choose another RStudio password', 'OK', 'Warning') | Out-Null
            [void]$textPass.Focus(); $textPass.SelectAll()
            return
        }

        # 2) Ask GitHub whether this user exists. This now happens while the dialog is
        #    still open, so a typo can simply be corrected here. Before, the check ran
        #    after the dialog had closed, and any failure closed the whole application.
        $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
        $buttonOK.Enabled = $false
        try {
            $ghCheck = Test-GitHubUsername -UserName $nameCheck.UserName -Detailed
        } finally {
            $form.Cursor = [System.Windows.Forms.Cursors]::Default
            $buttonOK.Enabled = $true
        }

        if ($ghCheck.Status -eq 'Unknown') {
            # GitHub could not be asked (no network, proxy, too many checks from this
            # network). That does not mean the name is wrong, so let the user decide
            # instead of claiming the username does not exist.
            $answer = [System.Windows.Forms.MessageBox]::Show(
                "IMPACT could not check the username '$($nameCheck.UserName)' on GitHub:`n`n$($ghCheck.Message)`n`nContinue anyway with '$($nameCheck.UserName)'?`n`nChoose 'No' to correct the username or to try the check again.",
                'GitHub check not possible', 'YesNo', 'Warning')
            if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) {
                [void]$textUser.Focus()
                return
            }
            Write-Log "GitHub username '$($nameCheck.UserName)' could not be verified; user chose to continue." 'Warn'
        } elseif ($ghCheck.Status -ne 'Exists') {
            # NotFound or Organization: explain and keep the dialog open for a correction.
            [System.Windows.Forms.MessageBox]::Show($ghCheck.Message, 'Check your GitHub username', 'OK', 'Warning') | Out-Null
            [void]$textUser.Focus(); $textUser.SelectAll()
            return
        }

        $accepted.UserName = $nameCheck.UserName
        $form.DialogResult = [System.Windows.Forms.DialogResult]::OK
        $form.Close()
    })

    $result = $form.ShowDialog()
    Write-Log "Credential dialog result: $result" 'Debug'
    if ($result -ne [System.Windows.Forms.DialogResult]::OK -or -not $accepted.UserName) {
        if ($hadPreviousCredentials) {
            # Reached via "Back": keep the credentials that were already checked and
            # continue, which brings the user back to the location step.
            Write-Log 'Credential dialog closed without changes; keeping the previously entered credentials.' 'Info'
            return 'next'
        }
        Write-Log 'User cancelled the credential dialog.' 'Warn'
        return 'cancel'
    }

    $State.UserName = $accepted.UserName
    $State.Password = $textPass.Text

    Write-Log "Credentials collected for user $($State.UserName)" 'Info'
    return 'next'
}

# ══════════════════════════════════════════════════════════════════════════════
#  SSH agent + config helpers
# ══════════════════════════════════════════════════════════════════════════════
function Ensure-SshAgentRunning {
    param([string]$SshKeyPath)
    Write-Log 'Ensuring ssh-agent service is running and key is loaded.' 'Info'

    $sshAgentService = Get-Service ssh-agent -ErrorAction SilentlyContinue
    if (-not $sshAgentService) {
        Write-Log 'ssh-agent service not found on this system.' 'Warn'
        return
    }

    if ($sshAgentService.Status -ne 'Running') {
        $started = $false
        try {
            Start-Service ssh-agent -ErrorAction Stop
            $started = $true
            Write-Log 'ssh-agent service started (no elevation needed).' 'Info'
        } catch {
            Write-Log "Direct Start-Service ssh-agent failed: $($_.Exception.Message). Attempting elevated start." 'Warn'
        }
        if (-not $started) {
            try {
                $elevatedCmd = "Set-Service ssh-agent -StartupType Automatic -ErrorAction Stop; Start-Service ssh-agent -ErrorAction Stop"
                $pwshPath = if (Get-Command pwsh -ErrorAction SilentlyContinue) { 'pwsh' } else { 'powershell' }
                $proc = Start-Process $pwshPath -ArgumentList '-NoProfile','-NoLogo','-Command',$elevatedCmd -Verb RunAs -Wait -PassThru -ErrorAction Stop
                if ($proc.ExitCode -eq 0) {
                    Write-Log 'ssh-agent service started via elevated process.' 'Info'
                    $started = $true
                } else {
                    Write-Log "Elevated ssh-agent start exited with code $($proc.ExitCode)" 'Warn'
                }
            } catch {
                Write-Log "Elevated ssh-agent start failed: $($_.Exception.Message)" 'Warn'
                Write-Log 'To fix manually, run in an admin PowerShell: Set-Service ssh-agent -StartupType Automatic; Start-Service ssh-agent' 'Warn'
            }
        }
    }

    # Stale key cleanup
    $sshAgentService = Get-Service ssh-agent -ErrorAction SilentlyContinue
    if ($sshAgentService -and $sshAgentService.Status -eq 'Running') {
        try {
            $loadedRaw = & ssh-add -l 2>&1
            if ($LASTEXITCODE -eq 0 -and $loadedRaw -notmatch 'no identities') {
                foreach ($kl in ($loadedRaw -split "`n")) {
                    $kl = $kl.Trim()
                    if (-not $kl) { continue }
                    if ($kl -match '^\d+\s+\S+\s+(.+?)\s+\(\S+\)$') {
                        $keyRef = $Matches[1].Trim()
                        $nativePath = $keyRef -replace '/', '\'
                        if ($nativePath.StartsWith('~')) { $nativePath = Join-Path $HOME $nativePath.Substring(2) }
                        if (($keyRef -match '^(/|[A-Za-z]:\\|~[/\\])') -and -not (Test-Path $nativePath)) {
                            Write-Log "Stale key in ssh-agent (file deleted): $keyRef" 'Warn'
                            $pubPath = "${nativePath}.pub"
                            if (Test-Path $pubPath) {
                                try { & ssh-add -d $pubPath 2>&1 | Out-Null; Write-Log "Removed stale key from agent: $keyRef" 'Info' } catch { }
                            } else {
                                Write-Log "Cannot auto-remove agent key (pub file also missing): $keyRef - consider running 'ssh-add -D' to clear all agent keys." 'Debug'
                            }
                        }
                    }
                }
            }
        } catch { Write-Log "Agent stale-key check failed: $($_.Exception.Message)" 'Debug' }
    }

    # Add key
    $sshAgentService = Get-Service ssh-agent -ErrorAction SilentlyContinue
    if ($sshAgentService -and $sshAgentService.Status -eq 'Running') {
        try {
            $loadedKeys = & ssh-add -l 2>&1
            if ($loadedKeys -notmatch [regex]::Escape($SshKeyPath) -and $loadedKeys -notmatch [regex]::Escape((Split-Path $SshKeyPath -Leaf).Replace('.','_'))) {
                & ssh-add $SshKeyPath 2>&1 | Out-Null
                Write-Log "SSH key added to ssh-agent: $SshKeyPath" 'Info'
            } else {
                Write-Log 'SSH key already loaded in ssh-agent.' 'Debug'
            }
        } catch { Write-Log "ssh-add failed: $($_.Exception.Message)" 'Warn' }
    } else {
        Write-Log 'ssh-agent service is not running; skipping ssh-add.' 'Warn'
    }
}

function Remove-SshConfigHostBlock {
    param(
        [string]$ConfigPath,
        [string]$HostPattern
    )
    Write-Log "Remove-SshConfigHostBlock called for HostPattern='$HostPattern' ConfigPath='$ConfigPath'" 'Debug'
    if (-not (Test-Path $ConfigPath)) { return $false }

    $lines = Get-Content $ConfigPath -ErrorAction SilentlyContinue
    if (-not $lines) { return $false }

    $resultLines = [System.Collections.Generic.List[string]]::new()
    $inBlock = $false
    $removed = $false
    $hostEscaped = [regex]::Escape($HostPattern)

    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]

        if ($line -match "^\s*Host\s+$hostEscaped\s*`$") {
            $inBlock = $true
            $removed = $true
            while ($resultLines.Count -gt 0 -and (
                $resultLines[$resultLines.Count - 1] -match '^\s*#.*IMPACT' -or
                [string]::IsNullOrWhiteSpace($resultLines[$resultLines.Count - 1])
            )) {
                $resultLines.RemoveAt($resultLines.Count - 1)
            }
            continue
        }

        if ($inBlock) {
            if ($line -match '^\s*Host\s+') {
                $inBlock = $false
                $resultLines.Add($line)
            }
            continue
        }

        $resultLines.Add($line)
    }

    if ($removed) {
        Set-Content -Path $ConfigPath -Value $resultLines -Encoding UTF8
        Write-Log "Removed SSH config Host block for '$HostPattern' from $ConfigPath" 'Info'
    } else {
        Write-Log "No matching Host block found for '$HostPattern'." 'Debug'
    }

    return $removed
}

function Ensure-SshConfigEntry {
    param(
        [string]$RemoteHostIp,
        [string]$RemoteUser,
        [string]$IdentityFile
    )

    if (-not $RemoteHostIp -or -not $RemoteUser -or -not $IdentityFile) {
        Write-Log 'Ensure-SshConfigEntry: missing parameters, skipping.' 'Debug'
        return
    }

    $sshDir = Join-Path $HOME '.ssh'
    $configPath = Join-Path $sshDir 'config'
    Write-Log "Ensure-SshConfigEntry: sshDir='$sshDir' configPath='$configPath' RemoteHostIp='$RemoteHostIp'" 'Debug'
    Write-Log "Ensuring SSH config entry for $RemoteHostIp in $configPath" 'Info'

    if (-not (Test-Path $sshDir)) {
        New-Item -Path $sshDir -ItemType Directory -Force | Out-Null
    }

    $identityNorm = $IdentityFile -replace '\\','/'

    if (Test-Path $configPath) {
        $existingConfig = Get-Content $configPath -Raw -ErrorAction SilentlyContinue
        if ($existingConfig -match "(?mi)^\s*Host\s+$([regex]::Escape($RemoteHostIp))\s*`$") {
            $configLines = $existingConfig -split "`n"
            $inBlock = $false
            $existingIdentityFile = $null
            foreach ($cl in $configLines) {
                $cl = $cl.TrimEnd("`r")
                if ($cl -match "^\s*Host\s+$([regex]::Escape($RemoteHostIp))\s*`$") { $inBlock = $true; continue }
                if ($inBlock) {
                    if ($cl -match '^\s*Host\s+') { break }
                    if ($cl -match '^\s*IdentityFile\s+(.+)$') { $existingIdentityFile = $Matches[1].Trim() }
                }
            }
            $needsUpdate = $false
            if ($existingIdentityFile) {
                $existingNorm = $existingIdentityFile -replace '\\','/'
                $checkPath = $existingIdentityFile -replace '/','\'
                if ($checkPath.StartsWith('~')) { $checkPath = Join-Path $HOME $checkPath.Substring(2) }
                if (-not (Test-Path $checkPath)) {
                    Write-Log "SSH config for $RemoteHostIp points to deleted key: $existingIdentityFile - replacing entry." 'Warn'
                    $needsUpdate = $true
                } elseif ($existingNorm -ne $identityNorm) {
                    Write-Log "SSH config for $RemoteHostIp references different key ($existingIdentityFile vs $identityNorm) - updating." 'Info'
                    $needsUpdate = $true
                } elseif ($existingIdentityFile -ne $identityNorm) {
                    Write-Log "SSH config for $RemoteHostIp has backslashes in IdentityFile - fixing slash direction." 'Warn'
                    $needsUpdate = $true
                }
            } else {
                Write-Log "SSH config entry for $RemoteHostIp has no IdentityFile - replacing." 'Warn'
                $needsUpdate = $true
            }
            if (-not $needsUpdate) {
                Write-Log "SSH config already contains valid entry for Host $RemoteHostIp - skipping." 'Debug'
                return
            }
            Remove-SshConfigHostBlock -ConfigPath $configPath -HostPattern $RemoteHostIp
        }
    }

    $entry = @"

# IMPACT Docker GUI - auto-generated entry for remote workstation
Host $RemoteHostIp
    User $RemoteUser
    IdentityFile $identityNorm
    IdentitiesOnly yes
    StrictHostKeyChecking accept-new
    ConnectTimeout 10
"@

    try {
        Add-Content -Path $configPath -Value $entry -Encoding UTF8 -ErrorAction Stop
        Write-Log "SSH config entry added for Host $RemoteHostIp" 'Info'
    } catch { Write-Log "Failed to write SSH config: $($_.Exception.Message)" 'Warn' }
}

# ══════════════════════════════════════════════════════════════════════════════
#  Git key setup
# ══════════════════════════════════════════════════════════════════════════════
function Ensure-GitKeySetup {
    param([pscustomobject]$State)
    Write-Log 'Preparing SSH keys for GitHub integration' 'Info'

    if (-not $State.UserName) {
        Write-Log 'Username missing before SSH key setup.' 'Error'
        return $false
    }

    $sshDir = Join-Path $HOME '.ssh'
    $sshKeyPath = Join-Path $sshDir "id_ed25519_$($State.UserName)"
    $sshPublicKeyPath = "$sshKeyPath.pub"

    $State.Paths.SshPrivate = $sshKeyPath
    $State.Paths.SshPublic = $sshPublicKeyPath

    $privateKeyExists = Test-Path $sshKeyPath
    $publicKeyExists = Test-Path $sshPublicKeyPath
    Write-Log "Existing SSH key? private=$privateKeyExists, public=$publicKeyExists" 'Debug'

    if ($privateKeyExists -and $publicKeyExists) {
        Write-Log "Using existing SSH key at $sshKeyPath" 'Info'
        $publicKey = Get-Content $sshPublicKeyPath -ErrorAction Stop
        $State.Metadata.PublicKey = ($publicKey -join "`n")

        Write-Host "The following Public Key will be used:"
        Write-Host "----------------------------------------"
        Write-Host $publicKey
        Write-Host "----------------------------------------"
        Write-Host "If you cannot authenticate with GitHub, add this key in GitHub -> Settings -> SSH and GPG keys"

        Ensure-SshAgentRunning -SshKeyPath $sshKeyPath
        return $true
    }

    if (-not (Test-Path $sshDir)) {
        New-Item -Path $sshDir -ItemType Directory -Force | Out-Null
        Write-Log "Created .ssh directory at $sshDir" 'Info'
    }

    Write-Log "Generating SSH key at $sshKeyPath (comment=IMPACT_$($State.UserName))" 'Info'
    $sshKeyGenArgs = @(
        '-t', 'ed25519',
        '-C', "IMPACT_$($State.UserName)",
        '-f', $sshKeyPath,
        '-N', '',
        '-q'
    )

    try {
        & { $PSNativeCommandArgumentPassing = 'Standard'; & ssh-keygen @sshKeyGenArgs }  # 'Standard' passes the empty -N '' passphrase through even if a profile switched to 'Legacy' (which drops it, so '-q' became the passphrase)
        $keyGenResult = $LASTEXITCODE
    } catch {
        Write-Log "ssh-keygen failed: $($_.Exception.Message)" 'Error'
        return $false
    }

    $publicKeyGenerated = Test-Path $sshPublicKeyPath
    if (($keyGenResult -ne 0) -or -not $publicKeyGenerated) {
        Write-Log "SSH key generation failed (exit $keyGenResult)" 'Error'
        return $false
    }

    Write-Log "SSH key generated successfully at $sshKeyPath" 'Info'
    $publicKey = Get-Content $sshPublicKeyPath -ErrorAction Stop
    $State.Metadata.PublicKey = ($publicKey -join "`n")

    try { $publicKey | Set-Clipboard | Out-Null } catch { Write-Log 'Could not copy key to clipboard.' 'Warn' }

    if (-not $script:NonInteractive) {
        $message = "A new SSH public key has been generated.`n`nPath: $sshPublicKeyPath`n`nAdd this key to GitHub: Settings -> SSH and GPG keys -> New SSH key."
        [System.Windows.Forms.MessageBox]::Show($message, 'SSH Key Setup', 'OK', 'Information') | Out-Null

        $formKeyDisplay = New-Object System.Windows.Forms.Form -Property @{
            Text = 'SSH Public Key - GitHub Integration'
            Size = New-Object System.Drawing.Size(820,520)
            FormBorderStyle = 'FixedDialog'
            MaximizeBox = $false
            MinimizeBox = $false
        }
        Set-FormCenterOnCurrentScreen -Form $formKeyDisplay
        Apply-ThemeToForm -Form $formKeyDisplay

        $labelTitle = New-Object System.Windows.Forms.Label -Property @{ Text = 'SSH Public Key Generated'; Location = New-Object System.Drawing.Point(24,16); Size = New-Object System.Drawing.Size(780,36); TextAlign = 'MiddleCenter' }
        Style-Label -Label $labelTitle -Style ([System.Drawing.FontStyle]::Bold)
        $formKeyDisplay.Controls.Add($labelTitle)

        $labelKeyInstruction = New-Object System.Windows.Forms.Label -Property @{
            Text = "To enable GitHub integration, copy this SSH public key to your GitHub account:`n`nGitHub > Settings > SSH and GPG keys > New SSH key"
            Location = New-Object System.Drawing.Point(24,58)
            Size = New-Object System.Drawing.Size(780,64)
        }
        Style-Label -Label $labelKeyInstruction
        $formKeyDisplay.Controls.Add($labelKeyInstruction)

        $textBoxKey = New-Object System.Windows.Forms.TextBox -Property @{
            Location = New-Object System.Drawing.Point(24,132)
            Size = New-Object System.Drawing.Size(780,260)
            Multiline = $true
            ScrollBars = 'Vertical'
            ReadOnly = $true
            Font = New-Object System.Drawing.Font('Consolas', 10, [System.Drawing.FontStyle]::Regular)
            Text = $publicKey
            WordWrap = $false
            BorderStyle = 'FixedSingle'
        }
        Style-TextBox -TextBox $textBoxKey
        $textBoxKey.BackColor = $script:ThemePalette.Panel
        $textBoxKey.Font = New-Object System.Drawing.Font('Consolas', 10, [System.Drawing.FontStyle]::Regular)
        $formKeyDisplay.Controls.Add($textBoxKey)

        $formKeyDisplay.Add_Shown({ $textBoxKey.SelectAll(); $textBoxKey.Focus() })

        $buttonCopyKey = New-Object System.Windows.Forms.Button -Property @{ Text = 'Copy to Clipboard'; Location = New-Object System.Drawing.Point(520,412); Size = New-Object System.Drawing.Size(140,36) }
        Style-Button -Button $buttonCopyKey -Variant 'primary'
        $formKeyDisplay.Controls.Add($buttonCopyKey)
        $buttonCopyKey.Add_Click({
            try {
                $publicKey | Set-Clipboard | Out-Null
                $buttonCopyKey.Text = 'Copied!'
                $buttonCopyKey.BackColor = [System.Drawing.Color]::LightBlue
                $buttonCopyKey.Enabled = $false
                $script:CopyTimer = New-Object System.Windows.Forms.Timer
                $script:CopyTimer.Interval = 2000
                $script:CopyTimer.Add_Tick({
                    try {
                        if ($buttonCopyKey -and -not $buttonCopyKey.IsDisposed) { $buttonCopyKey.Text = 'Copy to Clipboard'; $buttonCopyKey.BackColor = [System.Drawing.Color]::LightGreen; $buttonCopyKey.Enabled = $true }
                        if ($script:CopyTimer -and -not $script:CopyTimer.Disposed) { $script:CopyTimer.Stop(); $script:CopyTimer.Dispose(); $script:CopyTimer = $null }
                    } catch { if ($script:CopyTimer) { try { $script:CopyTimer.Dispose() } catch { }; $script:CopyTimer = $null } }
                })
                $script:CopyTimer.Start()
            } catch {
                [System.Windows.Forms.MessageBox]::Show('Failed to copy to clipboard. Please select all text and copy manually using Ctrl+C.', 'Copy Failed', 'OK', 'Warning') | Out-Null
            }
        })

        $buttonCloseKey = New-Object System.Windows.Forms.Button -Property @{ Text = 'Close'; Location = New-Object System.Drawing.Point(670,412); Size = New-Object System.Drawing.Size(120,36); DialogResult = [System.Windows.Forms.DialogResult]::OK }
        Style-Button -Button $buttonCloseKey -Variant 'secondary'
        $formKeyDisplay.Controls.Add($buttonCloseKey)
        $buttonCloseKey.Add_Click({ $formKeyDisplay.DialogResult = [System.Windows.Forms.DialogResult]::OK; $formKeyDisplay.Close() })
        $formKeyDisplay.AcceptButton = $buttonCloseKey
        $formKeyDisplay.CancelButton = $buttonCloseKey
        $null = $formKeyDisplay.ShowDialog()
    }

    Write-Host "Public Key (copy this to GitHub):"
    Write-Host "----------------------------------------"
    Write-Host $publicKey
    Write-Host "----------------------------------------"

    Ensure-SshAgentRunning -SshKeyPath $sshKeyPath
    return $true
}

# ══════════════════════════════════════════════════════════════════════════════
#  Location selection
# ══════════════════════════════════════════════════════════════════════════════
function Select-Location {
    param([pscustomobject]$State)

    if ($script:NonInteractive) {
        Write-Log 'NonInteractive: using pre-set ContainerLocation from State.' 'Info'
        if (-not $State.ContainerLocation) {
            Write-Log 'NonInteractive: ContainerLocation not pre-set on state.' 'Error'
            return 'cancel'
        }
        if ($State.ContainerLocation -like 'REMOTE@*') {
            if (-not $State.RemoteHostIp) {
                Write-Log 'NonInteractive: RemoteHostIp not pre-set for remote mode.' 'Error'
                return 'cancel'
            }
            $State.RemoteHost = "$($State.RemoteUser)@$($State.RemoteHostIp)"
            $State.RemoteRepoBase = if ($State.RemoteRepoBase) { $State.RemoteRepoBase } else { "/home/$($State.RemoteUser)/Schreibtisch/Repositories" }
        } else {
            $State.RemoteRepoBase = "/home/$($State.RemoteUser)/Schreibtisch/Repositories"
        }
        return 'next'
    }

    Write-Log 'Opening container location selection dialog.' 'Info'

    $formConnection = New-Object System.Windows.Forms.Form -Property @{
        Text = 'Container Location - IMPACT NCD Germany'
        Size = New-Object System.Drawing.Size(480,300)
        Location = New-Object System.Drawing.Point(400,300)
        FormBorderStyle = 'FixedDialog'
        MaximizeBox = $false
    }
    Set-FormCenterOnCurrentScreen -Form $formConnection
    Apply-ThemeToForm -Form $formConnection

    $rtbConnectionInstruction = New-Object System.Windows.Forms.RichTextBox -Property @{
        Location = New-Object System.Drawing.Point(20,12)
        Size = New-Object System.Drawing.Size(430,58)
        Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Regular)
        ReadOnly = $true
        BorderStyle = 'None'
        BackColor = $formConnection.BackColor
        ScrollBars = 'None'
    }
    $rtbConnectionInstruction.SelectionFont = New-Object System.Drawing.Font('Microsoft Sans Serif', 9, [System.Drawing.FontStyle]::Bold)
    $rtbConnectionInstruction.AppendText('Please choose whether you want to work locally')
    $rtbConnectionInstruction.SelectionFont = New-Object System.Drawing.Font('Microsoft Sans Serif', 9, [System.Drawing.FontStyle]::Regular)
    $rtbConnectionInstruction.AppendText(' (e.g. for testing) ')
    $rtbConnectionInstruction.SelectionFont = New-Object System.Drawing.Font('Microsoft Sans Serif', 9, [System.Drawing.FontStyle]::Bold)
    $rtbConnectionInstruction.AppendText('or remotely on the workstation')
    $rtbConnectionInstruction.SelectionFont = New-Object System.Drawing.Font('Microsoft Sans Serif', 9, [System.Drawing.FontStyle]::Regular)
    $rtbConnectionInstruction.AppendText(' (e.g. running simulations for output)!')
    Style-InfoBox -Box $rtbConnectionInstruction
    $formConnection.Controls.Add($rtbConnectionInstruction)

    $buttonLocal = New-Object System.Windows.Forms.Button -Property @{ Text = 'Local Container'; Location = New-Object System.Drawing.Point(20,72); Size = New-Object System.Drawing.Size(150,42) }
    Style-Button -Button $buttonLocal -Variant 'primary'
    $formConnection.Controls.Add($buttonLocal)

    $buttonRemote = New-Object System.Windows.Forms.Button -Property @{ Text = 'Remote Container'; Location = New-Object System.Drawing.Point(20,122); Size = New-Object System.Drawing.Size(150,42) }
    Style-Button -Button $buttonRemote -Variant 'secondary'
    $formConnection.Controls.Add($buttonRemote)

    $labelRemoteIP = New-Object System.Windows.Forms.Label -Property @{ Text = 'Remote IP Address'; Location = New-Object System.Drawing.Point(190,126); Size = New-Object System.Drawing.Size(140,22) }
    Style-Label -Label $labelRemoteIP
    $formConnection.Controls.Add($labelRemoteIP)

    $defaultIP = ''
    $envPaths = @(
        (Join-Path $PSScriptRoot '.env'),
        (Join-Path (Split-Path $PSScriptRoot -Parent) '.env')
    )
    foreach ($ep in $envPaths) {
        if ($ep -and (Test-Path $ep)) {
            $envLine = (Get-Content $ep -ErrorAction SilentlyContinue) | Where-Object { $_ -match '^\s*WORKSTATION_IP\s*=' } | Select-Object -First 1
            if ($envLine) {
                $defaultIP = ($envLine -split '=',2)[1].Trim().Trim('"').Trim("'")
                Write-Log "Loaded WORKSTATION_IP from $ep" 'Debug'
                break
            }
        }
    }

    $textRemoteIP = New-Object System.Windows.Forms.TextBox -Property @{ Location = New-Object System.Drawing.Point(330,124); Size = New-Object System.Drawing.Size(120,24); Text = $defaultIP }
    Style-TextBox -TextBox $textRemoteIP
    $formConnection.Controls.Add($textRemoteIP)

    $checkBoxDebug = New-Object System.Windows.Forms.CheckBox -Property @{ Text = 'Enable Debug Mode (show detailed progress messages)'; Location = New-Object System.Drawing.Point(20,180); Size = New-Object System.Drawing.Size(380,22); Checked = $false }
    Style-CheckBox -CheckBox $checkBoxDebug
    $formConnection.Controls.Add($checkBoxDebug)

    $buttonBack = New-Object System.Windows.Forms.Button -Property @{ Text = [char]0x2190 + ' Back'; Location = New-Object System.Drawing.Point(20,218); Size = New-Object System.Drawing.Size(100,32) }
    Style-Button -Button $buttonBack -Variant 'secondary'
    $formConnection.Controls.Add($buttonBack)

    $buttonBack.Add_Click({
        $formConnection.Tag = 'back'
        $formConnection.DialogResult = [System.Windows.Forms.DialogResult]::Abort
        $formConnection.Close()
    })

    $State.ContainerLocation = $null

    $buttonLocal.Add_Click({
        $State.Flags.Debug = $checkBoxDebug.Checked
        $script:GlobalDebugFlag = $State.Flags.Debug
        $State.ContainerLocation = 'LOCAL'
        $State.RemoteHost = $null
        $State.RemoteHostIp = $null
        $State.RemoteRepoBase = "/home/$($State.RemoteUser)/Schreibtisch/Repositories"
        Write-Log 'User selected LOCAL container location.' 'Info'
        $formConnection.DialogResult = [System.Windows.Forms.DialogResult]::Yes
        $formConnection.Close()
    })

    $buttonRemote.Add_Click({
        $State.Flags.Debug = $checkBoxDebug.Checked
        $script:GlobalDebugFlag = $State.Flags.Debug
        $userProvidedIP = $textRemoteIP.Text.Trim()
        if ([string]::IsNullOrWhiteSpace($userProvidedIP)) {
            [System.Windows.Forms.MessageBox]::Show('Please enter a valid IP address for the remote host.', 'Invalid IP Address', 'OK', 'Error') | Out-Null
            return
        }
        if ($userProvidedIP -notmatch '^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$') {
            [System.Windows.Forms.MessageBox]::Show('Please enter a valid IP address format (e.g., 192.168.1.100).', 'Invalid IP Format', 'OK', 'Error') | Out-Null
            return
        }
        $State.RemoteHostIp = $userProvidedIP
        $State.RemoteHost = "$($State.RemoteUser)@$userProvidedIP"
        $State.RemoteRepoBase = "/home/$($State.RemoteUser)/Schreibtisch/Repositories"
        $State.ContainerLocation = "REMOTE@$userProvidedIP"
        Write-Log "User selected REMOTE container location at IP=$userProvidedIP." 'Info'
        $formConnection.DialogResult = [System.Windows.Forms.DialogResult]::No
        $formConnection.Close()
    })

    $result = $formConnection.ShowDialog()
    if ($result -eq [System.Windows.Forms.DialogResult]::Yes -or $result -eq [System.Windows.Forms.DialogResult]::No) {
        return 'next'
    }
    if ($formConnection.Tag -eq 'back') {
        Write-Log 'User navigated back from location dialog.' 'Info'
        return 'back'
    }

    Write-Log 'No container location selected.' 'Warn'
    return 'cancel'
}

# ══════════════════════════════════════════════════════════════════════════════
#  Container lifecycle - EXTRACTED from Show-ContainerManager event handlers
# ══════════════════════════════════════════════════════════════════════════════

<#
.SYNOPSIS Value for GIT_SSH_COMMAND inside the IMPACT container.
.DESCRIPTION Git (also when started from the RStudio Git pane) uses this command
             to reach GitHub. It points at the user's private key and at a
             known_hosts file in the rstudio user's home directory, which
             Get-ContainerSshSetupCommand fills with github.com's host key.
             StrictHostKeyChecking=accept-new trusts github.com on first contact
             if that pre-fill failed (e.g. no network at container start), and
             still refuses a host key that differs from a stored one.
#>
function Get-ContainerGitSshCommand {
    param([Parameter(Mandatory)][string]$UserName)
    $keyPath   = "/home/rstudio/.ssh/id_ed25519_$UserName"
    $knownHost = '/home/rstudio/.ssh/known_hosts'
    return "ssh -i $keyPath -o IdentitiesOnly=yes -o UserKnownHostsFile=$knownHost -o StrictHostKeyChecking=accept-new"
}

<#
.SYNOPSIS Shell command (run as root via 'docker exec') that prepares SSH for git.
.DESCRIPTION 1. Copies the read-only mounted private key to ~rstudio/.ssh, strips
                Windows CR characters, sets mode 600 and rstudio ownership.
             2. Writes github.com's host keys to ~rstudio/.ssh/known_hosts with
                ssh-keyscan, run inside the container. The host's own known_hosts
                is not used: on many Windows machines it has no github.com entry
                (or is missing entirely), which made 'git pull' fail with
                "Host key verification failed".
             Prints KEY_FIXED at the end so the caller can confirm it ran.
#>
function Get-ContainerSshSetupCommand {
    param(
        [Parameter(Mandatory)][string]$UserName,
        [string]$ContainerUid = '1000',
        [string]$ContainerGid = '1000'
    )
    $sshDir    = '/home/rstudio/.ssh'
    $keySource = "/keys/id_ed25519_$UserName"
    $keyTarget = "$sshDir/id_ed25519_$UserName"
    $knownHost = "$sshDir/known_hosts"
    $owner     = "${ContainerUid}:${ContainerGid}"

    $steps = @(
        "mkdir -p $sshDir",
        "chmod 700 $sshDir",
        "tr -d '\r' < $keySource > $keyTarget",
        "chmod 600 $keyTarget",
        "touch $knownHost",
        # Keep existing lines except old github.com entries, then add fresh ones.
        # '|| true' keeps a failed scan (e.g. no network yet) from aborting the
        # chain, so the ownership fix below still runs; accept-new in
        # GIT_SSH_COMMAND then records github.com on the first pull.
        "{ grep -v '^github.com ' $knownHost 2>/dev/null; ssh-keyscan -T 10 -t ed25519,ecdsa,rsa github.com 2>/dev/null || true; } > $knownHost.tmp",
        "mv $knownHost.tmp $knownHost",
        "chmod 644 $knownHost",
        "chown -R $owner $sshDir",
        "echo KEY_FIXED"
    )
    return ($steps -join ' && ')
}

<#
.SYNOPSIS Turn a repository folder name into a name Docker accepts (pure logic).
.DESCRIPTION The repository folder name is reused in several Docker places: the
             container name ("<repo>_<user>"), the image name (lower-cased), the
             REPO_NAME build argument and the folder inside the container
             (/home/rstudio/<repo>). Docker only accepts plain letters, digits and
             single '.', '_' or '-' between them. A folder such as
             'IMPACTncd_Germany - Kopie' or 'IMPACTncd_Germany-main (1)' therefore
             made Start fail with a generic "Docker build failed" message.
             Names that are already valid are returned UNCHANGED, so normal users
             keep exactly the container and image names they had before.
             Otherwise: accents are removed (a-umlaut becomes a), every run of other
             characters becomes one '_', and separators at the start/end are dropped.
.PARAMETER Name The folder name (leaf only, not a full path).
.OUTPUTS   [string] The safe name, or '' when nothing usable is left (for example a
           name made only of symbols). The caller must handle the empty case.
#>
function ConvertTo-DockerSafeRepoName {
    param([string]$Name)

    if ([string]::IsNullOrWhiteSpace($Name)) { return '' }

    # Already valid? Docker's image-name rule (checked on the lower-cased name) is the
    # stricter of the two rules; a name that passes it is also a valid container name.
    # The first test makes sure the ORIGINAL name is plain ASCII: some non-ASCII letters
    # (for example the Kelvin sign) turn into ASCII letters when lower-cased.
    # -cmatch (case-sensitive) is used on purpose: with case-insensitive matching .NET
    # lets some non-ASCII letters match [a-z].
    if ($Name -cmatch '^[A-Za-z0-9._-]+$' -and
        $Name.ToLowerInvariant() -cmatch '^[a-z0-9]+((\.|_|__|-+)[a-z0-9]+)*$') { return $Name }

    # Replace accented letters by their plain letter (e-acute -> e, o-umlaut -> o):
    # FormD splits a letter from its accent, then we drop the accent marks.
    # Sharp s has no plain form, so it is mapped by hand.
    $decomposed = $Name.Replace([string][char]0x00DF, 'ss').Normalize([System.Text.NormalizationForm]::FormD)
    $plain = -join ($decomposed.ToCharArray() | Where-Object {
        [System.Globalization.CharUnicodeInfo]::GetUnicodeCategory($_) -ne [System.Globalization.UnicodeCategory]::NonSpacingMark
    })

    # Every run of characters that are not plain ASCII letters/digits becomes ONE separator.
    # A lone '.', '_' or '-' is kept as it is (so 'IMPACTncd_Germany-main' style names stay
    # readable); anything else (spaces, brackets, several separators in a row) becomes '_'.
    # -creplace/-cmatch: case-sensitive for the same reason as above.
    $safe = $plain -creplace '[^A-Za-z0-9]+', {
        if ($_.Value -cmatch '^[._-]$') { $_.Value } else { '_' }
    }

    # Docker names must start (and image names must end) with a letter or digit.
    return $safe.Trim('.', '_', '-')
}

<#
.SYNOPSIS Build the docker run command-line arguments (pure logic, no execution).
.DESCRIPTION Given the session state and options, returns the string array to pass
             to 'docker run'. This makes the command testable without touching Docker.
#>
function Build-DockerRunCommand {
    param(
        [pscustomobject]$State,
        [string]$Port          = '8787',
        [bool]$UseVolumes      = $false,
        [bool]$HighCompute     = $false,
        [string]$CustomParams  = '',
        [string]$ImageName,
        [string]$ProjectRoot,
        [string]$OutputDir,
        [string]$SynthpopDir,
        [string]$SshKeyPath,
        [string]$ContainerUid  = '1000',
        [string]$ContainerGid  = '1000'
    )

    $repoMountSource = if ($State.ContainerLocation -eq 'LOCAL') { Convert-PathToDockerFormat -Path $ProjectRoot } else { $ProjectRoot }
    $containerKeyPath = "/home/rstudio/.ssh/id_ed25519_$($State.UserName)"

    $dockerArgs = @('run','-d','--rm','--name',$State.ContainerName,
        '-e',"PASSWORD=$($State.Password)",
        '-e','DISABLE_AUTH=false',
        '-e',"USERID=$ContainerUid",'-e',"GROUPID=$ContainerGid",
        '-e',"CONTAINER_REPO_NAME=$($State.SelectedRepo)",
        '-e','SYNC_ENABLED=false',
        '-e',"GIT_SSH_COMMAND=$(Get-ContainerGitSshCommand -UserName $State.UserName)",
        '--mount',"type=bind,source=$repoMountSource,target=/home/rstudio/$($State.SelectedRepo)",
        '-p',"${Port}:8787"
    )

    if ($CustomParams) { $dockerArgs += ($CustomParams -split '\s+') }

    if ($UseVolumes) {
        $volOut = "impactncd_germany_output_$($State.UserName)" -replace '[^a-zA-Z0-9_]','_'
        $volSyn = "impactncd_germany_synthpop_$($State.UserName)" -replace '[^a-zA-Z0-9_]','_'
        $dockerArgs += @('-v',"$($volOut):/home/rstudio/$($State.SelectedRepo)/outputs",
                         '-v',"$($volSyn):/home/rstudio/$($State.SelectedRepo)/inputs/synthpop")
    } else {
        $outDocker = if ($State.ContainerLocation -eq 'LOCAL') { Convert-PathToDockerFormat -Path $OutputDir } else { $OutputDir }
        $synDocker = if ($State.ContainerLocation -eq 'LOCAL') { Convert-PathToDockerFormat -Path $SynthpopDir } else { $SynthpopDir }
        $dockerArgs += @('--mount',"type=bind,source=$outDocker,target=/home/rstudio/$($State.SelectedRepo)/outputs",
                         '--mount',"type=bind,source=$synDocker,target=/home/rstudio/$($State.SelectedRepo)/inputs/synthpop")
    }

    if ($HighCompute -and $State.ContainerLocation -like 'REMOTE@*') {
        $dockerArgs += @('--cpus','32','-m','384g')
    }

    # Only the private key is mounted from the host. The github.com host key is
    # written inside the container by Get-ContainerSshSetupCommand, so the
    # container does not depend on the host's known_hosts file.
    $dockerArgs += @('--mount',"type=bind,source=$SshKeyPath,target=/keys/id_ed25519_$($State.UserName),readonly",
                     '--workdir',"/home/rstudio/$($State.SelectedRepo)",
                     $ImageName)

    return $dockerArgs
}

<#
.SYNOPSIS Test if Docker daemon is reachable.
#>
function Test-DockerDaemonReady {
    try {
        $out = & docker info 2>&1
        return ($LASTEXITCODE -eq 0)
    } catch { return $false }
}

<#
.SYNOPSIS Start Docker Desktop if not running, with polling.
.OUTPUTS $true if Docker daemon became reachable, $false on timeout.
#>
function Start-DockerDesktopIfNeeded {
    param([int]$TimeoutSeconds = 30)

    if (Test-DockerDaemonReady) { return $true }

    Write-Log 'Docker engine is not running; attempting to start Docker Desktop.' 'Warn'
    try {
        $dockerDesktopPath = "${env:ProgramFiles}\Docker\Docker\Docker Desktop.exe"
        if (Test-Path $dockerDesktopPath) {
            Start-Process -FilePath $dockerDesktopPath -WindowStyle Hidden
        } else {
            $dockerDesktopAlt = "${env:LOCALAPPDATA}\Programs\Docker\Docker\Docker Desktop.exe"
            if (Test-Path $dockerDesktopAlt) {
                Start-Process -FilePath $dockerDesktopAlt -WindowStyle Hidden
            } else {
                Start-Service -Name 'com.docker.service' -ErrorAction SilentlyContinue
            }
        }

        $attempt = 0
        do {
            Start-Sleep -Seconds 1
            $attempt++
            if (Test-DockerDaemonReady) { return $true }
            if ($attempt % 10 -eq 0) { Write-Log 'Docker is still starting up...' 'Info' }
        } while ($attempt -lt $TimeoutSeconds)
    } catch {
        Write-Log "Failed to start Docker Desktop: $($_.Exception.Message)" 'Error'
    }

    return (Test-DockerDaemonReady)
}

# ══════════════════════════════════════════════════════════════════════════════
#  GitHub SSH key API helpers (for CI testing)
# ══════════════════════════════════════════════════════════════════════════════

<#
.SYNOPSIS Add an SSH public key to a GitHub account using the REST API.
.PARAMETER PublicKey The full public key string (e.g. "ssh-ed25519 AAAA... comment")
.PARAMETER Title     The title for the key in GitHub.
.PARAMETER Token     GitHub PAT with admin:public_key scope.
.OUTPUTS   The numeric key ID (for later deletion).
#>
function Add-GitHubSshKey {
    param(
        [Parameter(Mandatory)][string]$PublicKey,
        [string]$Title = "IMPACT-CI-$(Get-Date -Format 'yyyyMMdd-HHmmss')",
        [Parameter(Mandatory)][string]$Token
    )
    Write-Log "Adding SSH key to GitHub with title '$Title'" 'Info'
    $body = @{ title = $Title; key = $PublicKey } | ConvertTo-Json
    $headers = @{ Authorization = "Bearer $Token"; Accept = 'application/vnd.github+json'; 'X-GitHub-Api-Version' = '2022-11-28' }
    $response = Invoke-RestMethod -Uri 'https://api.github.com/user/keys' -Method Post -Headers $headers -Body $body -ContentType 'application/json'
    Write-Log "GitHub SSH key added: id=$($response.id)" 'Info'
    return $response.id
}

<#
.SYNOPSIS Remove an SSH key from a GitHub account.
.PARAMETER KeyId The numeric key ID returned by Add-GitHubSshKey.
.PARAMETER Token GitHub PAT with admin:public_key scope.
#>
function Remove-GitHubSshKey {
    param(
        [Parameter(Mandatory)][int]$KeyId,
        [Parameter(Mandatory)][string]$Token
    )
    Write-Log "Removing GitHub SSH key id=$KeyId" 'Info'
    $headers = @{ Authorization = "Bearer $Token"; Accept = 'application/vnd.github+json'; 'X-GitHub-Api-Version' = '2022-11-28' }
    Invoke-RestMethod -Uri "https://api.github.com/user/keys/$KeyId" -Method Delete -Headers $headers
    Write-Log "GitHub SSH key id=$KeyId removed." 'Info'
}

<#
.SYNOPSIS  Check whether a GitHub username exists via the public API.
.PARAMETER UserName  The GitHub username to validate.
.PARAMETER Detailed  Return an object that says WHY the check failed, instead of a
                     plain $true/$false. A plain $false cannot tell "this user does not
                     exist" apart from "GitHub could not be reached", and treating both
                     as "not found" locked out colleagues who were offline, behind a
                     proxy, or over GitHub's limit of 60 anonymous checks per hour (which
                     a whole institute behind one internet address shares).
.OUTPUTS   Without -Detailed: $true if the GitHub user exists, $false otherwise.
           With -Detailed: [pscustomobject] @{ Status; Message } where Status is
             'Exists'       the personal account exists,
             'NotFound'     GitHub answered 404: there is no such account (typo?),
             'Organization' the name belongs to an organisation, not a person,
             'Unknown'      GitHub could not be asked (offline, proxy, rate limit, ...).
           Message is a text for the user (empty for 'Exists').
#>
function Test-GitHubUsername {
    param(
        [Parameter(Mandatory)][string]$UserName,
        [switch]$Detailed
    )
    Write-Log "Validating GitHub username '$UserName'" 'Info'
    $status = 'Unknown'
    $message = ''
    try {
        $headers = @{ Accept = 'application/vnd.github+json'; 'X-GitHub-Api-Version' = '2022-11-28' }
        # EscapeDataString: characters such as ? # / must stay part of the name (and then
        # give "not found") instead of changing the address that is asked; 'jdoe?x' used
        # to be checked as 'jdoe'.
        $uri = 'https://api.github.com/users/' + [uri]::EscapeDataString($UserName)
        # -TimeoutSec: do not hang for minutes when the network is broken.
        $response = Invoke-RestMethod -Uri $uri -Method Get -Headers $headers -TimeoutSec 15 -ErrorAction Stop
        # The same address also answers for organisations, which are not personal
        # accounts. Read 'type' carefully: StrictMode throws on a missing property.
        $accountType = $null
        if ($response -is [System.Collections.IDictionary]) {
            if ($response.Contains('type')) { $accountType = [string]$response['type'] }
        } elseif ($null -ne $response -and $response.PSObject.Properties['type']) {
            $accountType = [string]$response.type
        }
        if ($accountType -eq 'Organization') {
            $status = 'Organization'
            $message = "'$UserName' is a GitHub organisation, not a personal account. Please enter your own GitHub username."
            Write-Log "GitHub name '$UserName' belongs to an organisation, not a user." 'Warn'
        } else {
            $status = 'Exists'
            Write-Log "GitHub username '$UserName' validated successfully." 'Info'
        }
    } catch {
        $statusCode = $null
        try { $statusCode = [int]$_.Exception.Response.StatusCode } catch { }
        $errorText = $_.Exception.Message
        if ($statusCode -eq 404) {
            # Only a real 404 answer from GitHub means "this user does not exist".
            $status = 'NotFound'
            $message = "The username '$UserName' was not found on GitHub. Please check the spelling.`n`nTo find your username, log in to github.com and click your profile picture (top right): the name shown there is your username. It is also the last part of your profile address github.com/<username>."
            Write-Log "GitHub username '$UserName' does not exist (404)." 'Warn'
        } else {
            # Everything else says nothing about the username itself.
            $status = 'Unknown'
            if ($statusCode -eq 403 -or $statusCode -eq 429) {
                $message = "GitHub refused the check (HTTP $statusCode). This usually means that too many checks were made from your network within the last hour (GitHub's limit for anonymous checks). Try again later, or continue if you are sure the username is right."
            } elseif ($statusCode -eq 407) {
                $message = 'Your network proxy requires a login (HTTP 407), so GitHub could not be reached.'
            } elseif ($statusCode) {
                $message = "GitHub answered with an error (HTTP $statusCode). Details: $errorText"
            } else {
                $message = "github.com could not be reached (no internet connection, proxy or firewall?). Details: $errorText"
            }
            Write-Log "GitHub username validation failed (status=$statusCode): $errorText" 'Warn'
        }
    }

    if ($Detailed) {
        return [pscustomobject]@{ Status = $status; Message = $message }
    }
    return ($status -eq 'Exists')
}

# ══════════════════════════════════════════════════════════════════════════════
#  Remaining orchestration functions (Ensure-RemotePreparation,
#  Ensure-LocalPreparation, Get-ContainerStatus, Show-ContainerManager,
#  Invoke-ImpactGui) are kept in the main .ps1 launcher because they contain
#  deeply interleaved UI + side-effect logic that will be refactored
#  incrementally. They call the extracted functions above.
# ══════════════════════════════════════════════════════════════════════════════

# ── Module exports ────────────────────────────────────────────────────────────
Export-ModuleMember -Function @(
    # Non-interactive mode
    'Enable-NonInteractiveMode'
    'Disable-NonInteractiveMode'
    'Test-NonInteractiveMode'
    # Logging
    'Initialize-Logging'
    'Write-Log'
    # Build info
    'Get-BuildInfo'
    # State
    'New-SessionState'
    # PS7
    'Ensure-PowerShell7'
    # SSH / Docker helpers
    'Get-RemoteHostString'
    'Set-DockerSSHEnvironment'
    'Get-DockerContextArgs'
    'Get-DockerCredentialsFromDotEnv'
    # Called by the GUI's remote build retry; it was missing here, so that call always
    # failed with "command not found" (the GUI imports this .psm1, not the .psd1).
    'Ensure-RemoteDockerLogin'
    'Convert-PathToDockerFormat'
    # Remote SSH
    'Test-RemoteSSHKeyFiles'
    'Get-SshFailureKind'
    'ConvertTo-RemoteRepoList'
    'Write-RemoteContainerMetadata'
    'Remove-RemoteContainerMetadata'
    'Read-RemoteContainerMetadata'
    'Get-ContainerRuntimeInfo'
    # Port helpers
    'Get-NextAvailablePort'
    'Test-PortValue'
    'Get-UsedPorts'
    # Docker error helpers
    'Format-DockerError'
    # YAML / paths
    'Get-YamlPathValue'
    'Test-AndCreateDirectory'
    # Git
    'Get-GitRepositoryState'
    'Show-GitCommitDialog'
    'Invoke-GitChangeDetection'
    # UI / theme
    'Set-FormCenterOnCurrentScreen'
    'Initialize-ThemePalette'
    'Get-ThemePalette'
    'Apply-ThemeToForm'
    'Style-Label'
    'Style-TextBox'
    'Style-CheckBox'
    'Style-Button'
    'Style-InfoBox'
    # Startup
    'Test-StartupPrerequisites'
    'Ensure-Prerequisites'
    'Show-CredentialDialog'
    # SSH agent / config
    'Ensure-SshAgentRunning'
    'Remove-SshConfigHostBlock'
    'Ensure-SshConfigEntry'
    # Git keys
    'Ensure-GitKeySetup'
    # Location
    'Select-Location'
    # Container lifecycle (extracted)
    'ConvertTo-DockerSafeRepoName'
    'Build-DockerRunCommand'
    'Get-ContainerGitSshCommand'
    'Get-ContainerSshSetupCommand'
    'Test-DockerDaemonReady'
    'Start-DockerDesktopIfNeeded'
    # GitHub SSH key API
    'Add-GitHubSshKey'
    'Remove-GitHubSshKey'
    # GitHub username validation
    'Test-GitHubUsername'
)
