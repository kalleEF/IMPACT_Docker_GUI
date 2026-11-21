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

function New-ImpactNotifiedException {
    <#
    .SYNOPSIS Builds the error that Ensure-PowerShell7 throws when it stops on purpose (B6a-R2).
    .NOTES    When -UserNotified is $true, the user has just seen a message box that explains
              the problem. The flag Data['ImpactUserNotified'] tells the launcher's fatal-error
              handler not to show a second, confusing "fatal error" box for the same problem.
              The message text is unchanged, so callers that look at the text still work.
    #>
    param([string]$Message, [bool]$UserNotified)
    $exception = [System.Exception]::new($Message)
    if ($UserNotified) { $exception.Data['ImpactUserNotified'] = $true }
    return $exception
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
        $boxShown = $false
        if (-not $script:NonInteractive) {
            try { Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue } catch { }
            try { [System.Windows.Forms.MessageBox]::Show($tooOldMsg,'PowerShell update required','OK','Error') | Out-Null; $boxShown = $true } catch { }
        }
        Write-Log "PowerShell $($PSVersionTable.PSVersion) is too old; 7.3 or newer is required." 'Error'
        throw (New-ImpactNotifiedException -Message "PowerShell 7.3 or newer is required (found $($PSVersionTable.PSVersion))." -UserNotified $boxShown)
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
            $boxShown = $false
            if (-not $script:NonInteractive) {
                try { Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue } catch { }
                try { [System.Windows.Forms.MessageBox]::Show($notFoundMsg,'IMPACT - please use IMPACT.bat','OK','Error') | Out-Null; $boxShown = $true } catch { }
            }
            Write-Log "Cannot relaunch under pwsh: launcher script not found at '$scriptPath'." 'Error'
            throw (New-ImpactNotifiedException -Message 'Unable to relaunch under pwsh (launcher script not found).' -UserNotified $boxShown)
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

    $boxShown = $false
    if (-not $script:NonInteractive) {
        try { Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue } catch { }
        try { [System.Windows.Forms.MessageBox]::Show("PowerShell 7 (version 7.3 or newer) is required. Please install it from https://aka.ms/powershell-release (or run: winget install Microsoft.PowerShell) and try again.",'PowerShell 7 required','OK','Error') | Out-Null; $boxShown = $true } catch { }
    }
    Write-Log 'PowerShell 7 (pwsh) is required but not installed.' 'Error'
    throw (New-ImpactNotifiedException -Message 'PowerShell 7 (pwsh) is required.' -UserNotified $boxShown)
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

<#
.SYNOPSIS Shell snippet that blanks the password in metadata files written by OLDER
          versions (B3-R6).
.DESCRIPTION Older versions stored the RStudio password in plain text in
             /tmp/impactncd/<container>.json. Everybody on the workstation shares one Unix
             account, so every colleague could read those files. This snippet finds every
             metadata file whose "password" entry is not empty and replaces only that value
             with "" (the "password" key and all other entries stay).
             The files are deliberately NOT deleted: a colleague who still runs an OLDER
             version may have a container running right now, and that version can only learn
             the port and the volume mode ("useVolumes") from this file (its containers have
             no impact.* labels). Without the file, its Stop would skip copying the results
             out of the Docker volumes, and its next Start would delete those volumes. With
             an empty password the older version simply reads the password from the running
             container instead (docker inspect), and the current version ignores an empty
             password anyway. The key is kept (not removed) because the older version reads
             '$meta.password' under StrictMode, which would throw if the key were missing.
             The sed pattern ("([^"\\]|\\.)*") also understands JSON escapes such as \" or
             \\ inside the password. A file that has been blanked no longer matches the
             grep, so the snippet does nothing the next time.
             It never fails (the final 'true'), so it can be appended to another command
             with '&&'. -Z / -0 keep file names with spaces intact.
#>
function Get-RemoteMetadataCleanupCommand {
    return '{ grep -lZE ''"password"[[:space:]]*:[[:space:]]*"[^"]'' /tmp/impactncd/*.json 2>/dev/null | xargs -0 -r sed -i -E ''s/("password"[[:space:]]*:[[:space:]]*)"([^"\\]|\\.)*"/\1""/''; true; }'
}

function Write-RemoteContainerMetadata {
    # The RStudio password is deliberately NOT stored here (F40). Everybody on the
    # workstation uses the same Unix account, so a file in /tmp is readable by all
    # colleagues. When the GUI is reopened, the password is read back from the
    # running container itself (Get-ContainerRuntimeInfo), so it is not needed here.
    # The file still gets a "password" key, but its value is always empty (''). This
    # stores no secret. The key is there only for OLDER IMPACT versions: they read
    # '$meta.password' under StrictMode, which throws when the key is missing, so an
    # older version that reconnected to a container started by this version used to
    # stop with a fatal error. With an empty value it reads the password from the
    # container instead. This version never reads the password from this file.
    param(
        [pscustomobject]$State,
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
        port      = $Port
        useVolumes= $UseVolumes
        timestamp = (Get-Date).ToString('s')
        # Always empty, see the comment at the top of this function. The clean-up below
        # only changes non-empty passwords, so it leaves this value alone.
        password  = ''
    } | ConvertTo-Json -Compress
    Write-Log ("Metadata payload: container={0} repo={1} port={2} useVolumes={3}" -f $State.ContainerName, $State.SelectedRepo, $Port, $UseVolumes) 'Debug'
    $b64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($payload))
    # The path is quoted with ConvertTo-PosixShellLiteral so a quote in the name can never
    # break (or change) the command the workstation's shell runs.
    $metaPathQ = ConvertTo-PosixShellLiteral -Value $metaPath
    try {
        # 'umask' now comes before 'mkdir' so the folder is also created private (it used to be
        # created with default permissions first).
        # The part after the write is a clean-up (B3-R6): files written by OLDER versions
        # still contain the RStudio password in plain text, readable by every colleague on
        # the shared account. In every such file only the password value is blanked; the
        # file itself is kept, because a colleague still on an older version needs its port
        # and volume mode (see Get-RemoteMetadataCleanupCommand). The '{ ...; true; }'
        # makes sure the clean-up can never make the whole command fail.
        $cleanup = Get-RemoteMetadataCleanupCommand
        & ssh -n -i $keyPath -o StrictHostKeyChecking=accept-new -o IdentitiesOnly=yes -o ConnectTimeout=10 -o BatchMode=yes $remoteHost "umask 077 && mkdir -p /tmp/impactncd && echo $b64 | base64 -d > $metaPathQ && $cleanup" 2>$null
        # Only claim success when ssh really succeeded (it used to log 'saved' even on failure).
        if ($LASTEXITCODE -eq 0) {
            Write-Log 'Remote metadata saved.' 'Info'
        } else {
            Write-Log "Remote metadata could not be saved (ssh exit $LASTEXITCODE). Not critical: the container itself stores the same details." 'Warn'
        }
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
    # Quoted safely for the remote shell; also blanks the password in old files of other
    # containers that still hold one, without deleting those files (see
    # Get-RemoteMetadataCleanupCommand, B3-R6).
    $metaPathQ = ConvertTo-PosixShellLiteral -Value $metaPath
    $cleanup = Get-RemoteMetadataCleanupCommand
    try { & ssh -n -i $keyPath -o StrictHostKeyChecking=accept-new -o IdentitiesOnly=yes -o ConnectTimeout=10 -o BatchMode=yes $remoteHost "rm -f $metaPathQ; $cleanup" 2>$null } catch {
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
        $json = & ssh -n -i $keyPath -o StrictHostKeyChecking=accept-new -o IdentitiesOnly=yes -o ConnectTimeout=10 -o BatchMode=yes $remoteHost "cat $(ConvertTo-PosixShellLiteral -Value $metaPath) 2>/dev/null" 2>$null
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
    # B6a-R5: the path comes from a folder name on the shared workstation. Plain '...'
    # quoting broke on a name with a single quote (the login then silently failed), and a
    # crafted folder name could even run commands on the shared account.
    # ConvertTo-PosixShellLiteral quotes it safely for the remote shell.
    $envPathQuoted = ConvertTo-PosixShellLiteral -Value $envPathRemote
    try {
        $envContent = & ssh -n -i $keyPath -o StrictHostKeyChecking=accept-new -o IdentitiesOnly=yes -o ConnectTimeout=15 -o BatchMode=yes $remoteHost "cat $envPathQuoted 2>/dev/null || true"
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
    # Besides password and port, this now also recovers how the container was started
    # (volume mode, result folders, volume names), so a session resumed after
    # reopening the GUI can still copy results back at Stop (F01/F04).
    # UseVolumes stays $null when it could not be found out (for example because
    # docker inspect failed), so callers can tell "unknown" apart from "no volumes".
    # RepoPath is the repository folder the container was started from (label
    # impact.repo_path, F84); it stays $null for containers started by older versions.
    $info = @{ Password = $null; Port = $null; UseVolumes = $null; OutputDir = $null; SynthpopDir = $null; VolumeOutput = $null; VolumeSynthpop = $null; RepoPath = $null }
    $cmdEnv = @('inspect','-f','{{range .Config.Env}}{{println .}}{{end}}',$State.ContainerName)
    $cmdPort= @('inspect','-f','{{range $p, $c := .NetworkSettings.Ports}}{{if eq $p "8787/tcp"}}{{range $c}}{{println .HostPort}}{{end}}{{end}}{{end}}',$State.ContainerName)
    # Labels and mounts in one call, separated by a TAB. A TAB can never appear inside
    # the JSON itself (JSON escapes it as \t), so splitting on it is safe.
    $cmdMeta= @('inspect','-f',('{{json .Config.Labels}}' + "`t" + '{{json .Mounts}}'),$State.ContainerName)
    $ctxArgs = Get-DockerContextArgs -State $State
    $cmdEnv = $ctxArgs + $cmdEnv
    $cmdPort= $ctxArgs + $cmdPort
    $cmdMeta= $ctxArgs + $cmdMeta
    Write-Log "Inspecting container $($State.ContainerName) for runtime info." 'Info'
    try {
        $envLines = & docker @cmdEnv 2>$null
        $portLine = & docker @cmdPort 2>$null
        # Log only the variable NAMES: the values include the RStudio password, and
        # Debug lines are always written to the log file on disk.
        $envNames = @($envLines -split "`n" | Where-Object { $_ -match '=' } | ForEach-Object { ($_ -split '=', 2)[0] })
        Write-Log "Inspect env variable names: $($envNames -join ',')" 'Debug'
        Write-Log "Inspect port output: $portLine" 'Debug'
        if ($envLines) {
            foreach ($line in ($envLines -split "`n")) { if ($line -like 'PASSWORD=*') { $info.Password = $line.Substring(9) } }
        }
        if ($portLine) {
            $info.Port = (($portLine -split "`n|`r") | Where-Object { $_ -match '\S' } | Select-Object -First 1).Trim()
        }

        $metaRaw = (@(& docker @cmdMeta 2>$null) -join '')
        if ($LASTEXITCODE -eq 0 -and $metaRaw -match "`t") {
            $metaParts = $metaRaw -split "`t", 2
            # -AsHashtable copes with image labels whose names differ only in case,
            # which would make the default ConvertFrom-Json throw.
            $labels = $metaParts[0] | ConvertFrom-Json -AsHashtable
            if (-not $labels) { $labels = @{} }
            $mounts = @($metaParts[1] | ConvertFrom-Json -AsHashtable)

            # 1) Look at the volumes that are really mounted. This also works for
            #    containers started by older versions of this tool, which had no labels.
            foreach ($mnt in $mounts) {
                if ($mnt -isnot [System.Collections.IDictionary]) { continue }
                if ($mnt['Type'] -ne 'volume' -or -not $mnt['Name']) { continue }
                $dest = [string]$mnt['Destination']
                if ($dest -like '*/outputs') { $info.VolumeOutput = [string]$mnt['Name'] }
                elseif ($dest -like '*/inputs/synthpop') { $info.VolumeSynthpop = [string]$mnt['Name'] }
            }

            # 2) Labels written by Get-ImpactContainerLabelArgs when the container was started.
            if ($labels['impact.use_volumes']) {
                $info.UseVolumes = ([string]$labels['impact.use_volumes'] -eq 'true')
            } else {
                $info.UseVolumes = [bool]($info.VolumeOutput -or $info.VolumeSynthpop)
            }
            if ($labels['impact.output_dir'])   { $info.OutputDir   = [string]$labels['impact.output_dir'] }
            if ($labels['impact.synthpop_dir']) { $info.SynthpopDir = [string]$labels['impact.synthpop_dir'] }
            if (-not $info.VolumeOutput -and $labels['impact.volume_output'])     { $info.VolumeOutput   = [string]$labels['impact.volume_output'] }
            if (-not $info.VolumeSynthpop -and $labels['impact.volume_synthpop']) { $info.VolumeSynthpop = [string]$labels['impact.volume_synthpop'] }
            if ($labels['impact.repo_path'])    { $info.RepoPath    = [string]$labels['impact.repo_path'] }
        }
        Write-Log "Recovered runtime info -> PasswordPresent=$([bool]$info.Password) Port=$($info.Port) UseVolumes=$($info.UseVolumes) OutputDir=$($info.OutputDir) SynthpopDir=$($info.SynthpopDir) Volumes=$($info.VolumeOutput),$($info.VolumeSynthpop) RepoPath=$($info.RepoPath)" 'Debug'
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
    # [0-9] instead of \d: in .NET, \d also matches non-ASCII digits such as full-width
    # digits (U+FF10 to U+FF19, typed with an IME or pasted), which then made the [int] conversion below
    # throw inside the Port box's TextChanged handler (B6a-R4).
    if ($Port -notmatch '^[0-9]+$') {
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
    # TryParse never throws; if the text somehow is not a valid number it is simply
    # reported as out of range instead of crashing the caller.
    $portInt = 0
    if (-not [int]::TryParse($Port, [ref]$portInt)) {
        return @{ Valid = $false; ErrorMessage = "Port must be between $RangeStart and $RangeEnd." }
    }
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
                # Accept any host address in front of the port: 0.0.0.0 and [::] (all
                # interfaces, used on the workstation) and 127.0.0.1 (LOCAL containers
                # are now published on this machine only, F13). Matches() also finds a
                # second mapping on the same line.
                foreach ($m in [regex]::Matches($line, ':(\d{4,5})->8787/tcp')) {
                    $port = $m.Groups[1].Value
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
        # ConvertTo-PosixShellLiteral quotes the path safely for the workstation's shell.
        # Plain '...' broke the command for a path that contains a quote (possible now that
        # YAML quoting is understood, for example '/mnt/it''s'), and the user then got a
        # misleading "could not reach the workstation" message (B4-R7).
        $yamlPathQ = ConvertTo-PosixShellLiteral -Value $YamlPath
        try {
            $content = & ssh -n -i $keyPath -o StrictHostKeyChecking=accept-new -o IdentitiesOnly=yes -o ConnectTimeout=30 -o BatchMode=yes $remoteHost "if [ -f $yamlPathQ ]; then cat $yamlPathQ; else echo $missingMarker; fi" 2>$null
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
        # -LiteralPath: a folder name such as 'IMPACTncd_Germany [v2]' contains [ ], which
        # -Path would read as a wildcard pattern, so the existing file was "not found" (B2-R3).
        if (-not (Test-Path -LiteralPath $YamlPath)) { return $null }
        $content = Get-Content -LiteralPath $YamlPath -Raw
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
        #   'NetworkPathInLocalMode' a network folder (\\server\share or a mapped network
        #                          drive) was used for a local run; Docker Desktop cannot mount it
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
        # Quote the path safely for the workstation's shell (a ' inside it broke the
        # command before, which then looked like "workstation unreachable", B4-R7).
        $pathQ = ConvertTo-PosixShellLiteral -Value $Path
        try {
            $check = & ssh -n -i $keyPath -o StrictHostKeyChecking=accept-new -o IdentitiesOnly=yes -o ConnectTimeout=15 -o BatchMode=yes $remoteHost "test -d $pathQ && echo EXISTS || echo MISSING" 2>$null
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
            $made = & ssh -n -i $keyPath -o StrictHostKeyChecking=accept-new -o IdentitiesOnly=yes -o ConnectTimeout=15 -o BatchMode=yes $remoteHost "mkdir -p $pathQ && echo CREATED" 2>$null
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

    # F36 / B4-R6: Docker Desktop cannot bind-mount network folders. A UNC path
    # (\\server\share\out, which Get-YamlPathValue has already turned into //server/share/out)
    # or a mapped network drive (for example H:\IMPACT\outputs) used to fail only at
    # 'docker run', after a possibly long image build, with a raw mount error. This check
    # comes BEFORE the Linux-path check below, because '//server/...' also starts with '/'
    # and the user would otherwise get the wrong advice ("use a Windows path").
    if ($State.ContainerLocation -eq 'LOCAL') {
        $isNetworkPath = $Path -match '^(?:\\\\|//)[^\\/]'
        if (-not $isNetworkPath -and $IsWindows -and $Path -match '^([A-Za-z]):') {
            # Asking Windows for the drive type never blocks the start: if it fails, we
            # simply treat the drive as local (Docker will then report any real problem).
            try { $isNetworkPath = ([System.IO.DriveInfo]::new($Matches[1]).DriveType -eq [System.IO.DriveType]::Network) } catch { $isNetworkPath = $false }
        }
        if ($isNetworkPath) {
            Write-Log "Network folder not supported in local mode for ${PathKey}: $Path" 'Error'
            Set-Reason 'NetworkPathInLocalMode'
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

    # -LiteralPath: brackets in a folder name ('IMPACTncd_Germany [v2]') are not wildcards (B2-R3).
    if (-not (Test-Path -LiteralPath $native -PathType Container)) {
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
function ConvertTo-PosixShellLiteral {
    <#
    .SYNOPSIS Wraps a value in single quotes so a Linux shell (bash/sh) reads it
              as plain text.
    .DESCRIPTION
        Commands that we send over ssh are run by the workstation's shell, and
        GIT_SSH_COMMAND is run by git through 'sh'. Inside single quotes the
        shell does not expand anything ($VAR, `backticks`, $(...), \ are all
        literal). The only character that needs special care is the single
        quote itself: we write it as '\'' (close the quote, add an escaped
        quote, open the quote again). Example: O'Brien -> 'O'\''Brien'
    #>
    param([AllowEmptyString()][string]$Value)
    return "'" + ($Value -replace "'", "'\''") + "'"
}

function ConvertTo-GitOutputText {
    <#
    .SYNOPSIS Turns what a native command printed (captured with 2>&1) into one
              trimmed text block with LF line breaks.
    .DESCRIPTION
        With 2>&1, each stderr line arrives as an ErrorRecord. For an EMPTY
        stderr line, "$record" gives the text "System.Management.Automation.
        RemoteException", which ended up in the error messages we show. The
        record's Exception.Message holds the real line (empty in that case).
    #>
    param([object[]]$Output)
    $lines = foreach ($item in @($Output)) {
        if ($item -is [System.Management.Automation.ErrorRecord]) { $item.Exception.Message } else { "$item" }
    }
    return ((@($lines) -join "`n").Trim())
}

function Get-GitPushFailureHint {
    <#
    .SYNOPSIS Turns the text printed by a failed 'git push' into one plain
              sentence that tells a non-expert what went wrong and what to do.
    .DESCRIPTION
        Pure text logic (no git, no ssh) so it can be unit tested. The order of
        the checks matters: the most specific causes are tested first.
    #>
    param(
        [AllowEmptyString()][string]$Output,
        [string]$KeyName = 'your IMPACT SSH key'
    )
    $o = [string]$Output
    if ($o -match 'Permission denied \(publickey') {
        return "GitHub did not accept $KeyName. Check that this key is listed at https://github.com/settings/keys (the IMPACT tool normally adds it when you log in)."
    }
    if ($o -match 'Host key verification failed|REMOTE HOST IDENTIFICATION HAS CHANGED') {
        return 'The identity of github.com could not be confirmed (SSH host key problem). Please ask the maintainer for help.'
    }
    if ($o -match 'Could not resolve hostname|Connection timed out|Operation timed out|Network is unreachable|Connection refused|ssh: connect to host') {
        return 'GitHub could not be reached. Check the network or VPN connection and try again.'
    }
    if ($o -match 'Permission to \S+ denied|Repository not found|ERROR: Permission|returned error: 403') {
        return 'Your GitHub account does not have write access to this repository. Ask the repository owner to add you as a collaborator.'
    }
    if ($o -match 'remote rejected|protected branch|hook declined') {
        return 'GitHub refused the push for this branch (for example, the branch is protected). Push to another branch and open a pull request instead.'
    }
    if ($o -match 'non-fast-forward|fetch first|\[rejected\]|Updates were rejected') {
        return 'Someone else pushed to this branch first. Start the container again, click Pull in the RStudio Git pane to merge their work, then click Push.'
    }
    if ($o -match 'could not read Username|terminal prompts disabled|Authentication failed') {
        return 'GitHub asked for a user name and password (HTTPS remote), which this tool cannot type in. Push from RStudio instead.'
    }
    if ($o -match 'not on a branch|detached HEAD') {
        # Advise CREATING a branch, not switching to one: switching away from a detached
        # HEAD leaves its commits behind (only reachable through the reflog), so for a
        # non-expert they would be lost. A new branch keeps them.
        return "You are not on a branch (detached HEAD), so there is nothing to push. Put your work on a new branch first: in the RStudio Git pane click 'New Branch' (or run 'git switch -c <new-branch-name>' in the RStudio Terminal), then push."
    }
    return 'Git reported an error. The details are shown below.'
}

function Get-GitRepositoryState {
    # Returns an object describing the repository:
    #   HasChanges / StatusText / Branch / Remote  (as before)
    #   Ahead               number of commits on this branch that are not on its
    #                       upstream (GitHub) branch yet; 0 when unknown. For a
    #                       branch that was never pushed (no upstream) it counts the
    #                       commits that are on no GitHub branch at all.
    #   HasUpstream         $false when the branch was never pushed (no upstream)
    #   Detached            $true when no branch is checked out ("detached HEAD")
    #   Conflicts           files git still marks as conflicted (UU, AA, ...)
    #   OperationInProgress '' or 'merge' / 'rebase' / 'cherry-pick' / 'revert'
    # Returns $null when the status could not be read at all.
    param(
        [pscustomobject]$State,
        [string]$RepoPath,
        [bool]$IsRemote,
        # Optional: when the function returns $null, this receives a short code saying
        # why, so the caller can tell the user what really happened:
        #   'GitMissing'   git is not installed on this computer (LOCAL mode only)
        #   'Unreachable'  the workstation could not be reached over SSH
        #   'ReadFailed'   git ran but could not read the status (not a repository,
        #                  "dubious ownership", folder missing, ...)
        # Usage: $why = $null; Get-GitRepositoryState ... -Reason ([ref]$why)
        [ref]$Reason
    )
    # Stores the reason code, but only if the caller asked for it (an unused [ref] is $null).
    $setReason = { param([string]$Code) if ($null -ne $Reason) { $Reason.Value = $Code } }
    if (-not $RepoPath) { return $null }
    Write-Log "Checking git status for repo at $RepoPath (remote=$IsRemote)" 'Info'

    # LOCAL mode needs git on THIS computer. Colleagues who only use GitHub Desktop
    # often have no git.exe on PATH. Before, the missing command was caught further
    # down and logged only at Debug level, so the commit dialog silently never
    # appeared and nobody knew why. Now it is a visible warning with what to do.
    # (REMOTE mode runs git on the workstation, so this PC does not need it.)
    if (-not $IsRemote -and -not (Get-Command git -ErrorAction SilentlyContinue)) {
        Write-Log "git was not found on this computer (it is not on PATH), so the changes in $RepoPath cannot be checked or committed when the container stops. Commit them in the RStudio Git pane or with GitHub Desktop, or install Git for Windows." 'Warn'
        & $setReason 'GitMissing'
        return $null
    }

    # Defaults, so every variable exists below even if a branch does not set it (StrictMode).
    $statusLines = @()
    $branch = ''
    $symRef = ''
    $remote = ''
    $aheadText = ''
    $localAheadText = ''
    $opNames = @()
    try {
        if ($IsRemote) {
            $remoteHost = Get-RemoteHostString -State $State
            $keyPath = $State.Paths.SshPrivate
            # Each piece of output is preceded by its own marker line (__IMPACT_STATUS__ ...).
            # The old code guessed "first line that is not a known status code = branch,
            # next line = remote URL". That broke for status codes it did not list, for
            # example 'M ' (file staged in RStudio), ' D' (file deleted) or 'UU' (merge
            # conflict): those files were taken as the branch name and HasChanges could
            # wrongly be $false, so the commit dialog never appeared.
            # Other details:
            #  - The path is single-quoted with ConvertTo-PosixShellLiteral, so an
            #    apostrophe in a folder name cannot break the command.
            #  - 'cd ... || exit 1' stops if the folder is missing (no markers are printed,
            #    and we report that instead of pretending there are no changes).
            #  - __IMPACT_GITFAIL__ is printed when 'git status' itself fails (not a repo,
            #    "dubious ownership", ...).
            #  - AHEAD: how many local commits are not on GitHub yet. This prints nothing
            #    when the branch has no upstream (it was never pushed).
            #  - OP: lists the files git creates while a merge / rebase / cherry-pick /
            #    revert is unfinished, so we can refuse to commit in that state.
            #  - core.quotePath=false: git prints file names with umlauts as they are,
            #    instead of as octal codes (a u-umlaut became "\303\274"), so the
            #    commit dialog shows names the colleague can recognise.
            #  - SYMREF: the branch name from 'git symbolic-ref'. It prints nothing when
            #    no branch is checked out (detached HEAD), see $detached below.
            #  - LOCALAHEAD: only for a branch WITHOUT upstream (never pushed): how many
            #    of its commits are on no GitHub branch at all, so they can be offered
            #    for pushing too.
            $repoQ = ConvertTo-PosixShellLiteral -Value $RepoPath
            $cmd = "cd $repoQ || exit 1; " +
                   "echo __IMPACT_STATUS__; git -c core.quotePath=false status --porcelain=v1 || echo __IMPACT_GITFAIL__; " +
                   "echo __IMPACT_BRANCH__; git rev-parse --abbrev-ref HEAD 2>/dev/null; " +
                   "echo __IMPACT_SYMREF__; git symbolic-ref -q --short HEAD 2>/dev/null; " +
                   "echo __IMPACT_REMOTE__; git remote get-url origin 2>/dev/null; " +
                   "echo __IMPACT_AHEAD__; git rev-list --count '@{u}..HEAD' 2>/dev/null; " +
                   "echo __IMPACT_LOCALAHEAD__; git rev-parse -q --verify '@{u}' >/dev/null 2>&1 || git rev-list --count HEAD --not --remotes 2>/dev/null; " +
                   "echo __IMPACT_OP__; gd=`$(git rev-parse --git-dir 2>/dev/null) && for p in MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD rebase-merge rebase-apply; do test -e `"`$gd/`$p`" && echo `$p; done; true"
            # Reset first: a mocked or failed call must not leave an old exit code behind.
            $global:LASTEXITCODE = 0
            $out = & ssh -n -i $keyPath -o StrictHostKeyChecking=accept-new -o IdentitiesOnly=yes -o ConnectTimeout=20 -o BatchMode=yes $remoteHost $cmd 2>$null
            $sshExit = $LASTEXITCODE
            $section = ''
            $gitFailed = $false
            $parts = @{ STATUS = @(); BRANCH = @(); SYMREF = @(); REMOTE = @(); AHEAD = @(); LOCALAHEAD = @(); OP = @() }
            foreach ($raw in @($out | ForEach-Object { "$_" -split "`n" })) {
                $line = $raw.TrimEnd("`r")
                if ($line -eq '__IMPACT_GITFAIL__') { $gitFailed = $true; continue }
                if ($line -match '^__IMPACT_(STATUS|BRANCH|SYMREF|REMOTE|AHEAD|LOCALAHEAD|OP)__$') { $section = $matches[1]; continue }
                if (-not $section -or -not $line.Trim()) { continue }
                $parts[$section] += $line
            }
            if (-not $section -or $gitFailed) {
                # No marker at all means ssh or 'cd' failed; GITFAIL means git status failed.
                # ssh itself exits with 255 when it cannot connect or log in; any other
                # code means the workstation answered but the folder or git failed.
                Write-Log "Could not read the git status of $RepoPath on the workstation (ssh exit=$sshExit). Skipping the commit check." 'Warn'
                & $setReason $(if (-not $section -and $sshExit -eq 255) { 'Unreachable' } else { 'ReadFailed' })
                return $null
            }
            # "$(...)" (not [string]) so an empty section gives '' instead of $null.
            $statusLines = @($parts.STATUS)
            $branch = "$(@($parts.BRANCH) | Select-Object -First 1)"
            $symRef = "$(@($parts.SYMREF) | Select-Object -First 1)"
            $remote = "$(@($parts.REMOTE) | Select-Object -First 1)"
            $aheadText = "$(@($parts.AHEAD) | Select-Object -First 1)"
            $localAheadText = "$(@($parts.LOCALAHEAD) | Select-Object -First 1)"
            $opNames = @($parts.OP)
        } else {
            # -LiteralPath: a folder name with [brackets] is not treated as a wildcard.
            # try/finally: we always return to the previous folder, even on an error.
            Push-Location -LiteralPath $RepoPath
            try {
                $global:LASTEXITCODE = 0
                # core.quotePath=false: show umlauts in file names as they are (see the
                # remote command above).
                $statusLines = @(git -c core.quotePath=false status --porcelain=v1 2>$null)
                if ($LASTEXITCODE -ne 0) {
                    # Not a repository, "dubious ownership", ...: say so instead of
                    # silently reporting "no changes".
                    Write-Log "Could not read the git status of $RepoPath (git exit=$LASTEXITCODE). Skipping the commit check." 'Warn'
                    & $setReason 'ReadFailed'
                    return $null
                }
                # "$(...)" (not [string]) so a command with no output gives '' instead of $null.
                $branch = "$(git rev-parse --abbrev-ref HEAD 2>$null)"
                # 'HEAD' is printed both when no branch is checked out (detached HEAD) and
                # in a brand-new repository without commits; only then do we ask
                # symbolic-ref, which tells the two apart (see $detached below).
                if ($branch.Trim() -eq 'HEAD') { $symRef = "$(git symbolic-ref -q --short HEAD 2>$null)" }
                $remote = "$(git remote get-url origin 2>$null)"
                # '@{u}' must be quoted: unquoted, PowerShell would read @{ as a hashtable.
                # Prints nothing (and fails) when the branch has no upstream.
                $aheadText = "$(git rev-list --count '@{u}..HEAD' 2>$null)"
                # A branch that was never pushed has no upstream, so the count above is
                # empty although its commits are not on GitHub. Count the commits that
                # are on no GitHub branch at all instead (only when there is a branch
                # and an origin to push to).
                if (-not $aheadText.Trim() -and $branch.Trim() -and $branch.Trim() -ne 'HEAD' -and $remote.Trim()) {
                    $localAheadText = "$(git rev-list --count HEAD --not --remotes 2>$null)"
                }
                # Look for the files git leaves behind while an operation is unfinished.
                $gitDir = "$(git rev-parse --git-dir 2>$null)"
                if ($gitDir) {
                    foreach ($p in 'MERGE_HEAD', 'CHERRY_PICK_HEAD', 'REVERT_HEAD', 'rebase-merge', 'rebase-apply') {
                        if (Test-Path -LiteralPath (Join-Path $gitDir $p)) { $opNames += $p }
                    }
                }
            } finally {
                Pop-Location
            }
        }

        # Every non-empty porcelain line is a change (same rule for local and remote).
        $statusLines = @($statusLines | ForEach-Object { "$_".TrimEnd("`r") } | Where-Object { $_.Trim() })
        # Porcelain codes for files that still have merge conflicts (see 'git help status').
        $conflicts = @($statusLines | Where-Object { $_ -match '^(DD|AU|UD|UA|DU|AA|UU) ' } | ForEach-Object { $_.Substring(3) })
        # Detached HEAD: rev-parse says 'HEAD' AND symbolic-ref names no branch. In a
        # brand-new repository (no commits yet) symbolic-ref does name the branch, so we
        # use that name instead of 'HEAD'.
        $branch = $branch.Trim()
        $symRef = $symRef.Trim()
        $detached = $false
        if ($branch -eq 'HEAD') {
            if ($symRef) { $branch = $symRef } else { $detached = $true }
        }
        $ahead = 0
        $hasUpstream = [int]::TryParse($aheadText.Trim(), [ref]$ahead)
        if (-not $hasUpstream -and -not $detached -and $branch -and $remote.Trim()) {
            # Never-pushed branch: use the count of commits that are on no GitHub branch.
            $localAhead = 0
            if ([int]::TryParse($localAheadText.Trim(), [ref]$localAhead)) { $ahead = $localAhead }
        }
        $operation = ''
        if ($opNames -contains 'rebase-merge' -or $opNames -contains 'rebase-apply') { $operation = 'rebase' }
        elseif ($opNames -contains 'MERGE_HEAD') { $operation = 'merge' }
        elseif ($opNames -contains 'CHERRY_PICK_HEAD') { $operation = 'cherry-pick' }
        elseif ($opNames -contains 'REVERT_HEAD') { $operation = 'revert' }

        Write-Log "Git status (remote=$IsRemote) lines: $([string]::Join(';', $statusLines)) branch=$branch detached=$detached remote=$remote ahead=$ahead upstream=$hasUpstream op=$operation" 'Debug'
        return [pscustomobject]@{
            HasChanges          = ($statusLines.Count -gt 0)
            StatusText          = ($statusLines -join "`n")
            Branch              = $branch
            Remote              = $remote.Trim()
            Ahead               = $ahead
            HasUpstream         = $hasUpstream
            Detached            = $detached
            Conflicts           = $conflicts
            OperationInProgress = $operation
        }
    } catch {
        # Warn (not Debug): Debug lines are easy to miss, and this means the colleague's
        # changes were NOT checked or committed.
        Write-Log "Git status retrieval failed: $($_.Exception.Message)" 'Warn'
        & $setReason 'ReadFailed'
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

    # Git gives us the file list with LF line breaks, but a WinForms TextBox only
    # starts a new line at CRLF. Without this conversion all files ran together on
    # one line and the user could not review what 'git add -A' will commit.
    # WordWrap off + horizontal scroll bar: one file per row even for long paths.
    $changesForDisplay = ([string]$ChangesText) -replace "`r?`n", "`r`n"
    $txtChanges = New-Object System.Windows.Forms.TextBox -Property @{ Location=New-Object System.Drawing.Point(14,40); Size=New-Object System.Drawing.Size(600,310); Multiline=$true; ScrollBars='Both'; WordWrap=$false; ReadOnly=$true; Font=New-Object System.Drawing.Font('Consolas',9); Text=$changesForDisplay }
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

function Invoke-GitPushWithImpactKey {
    <#
    .SYNOPSIS Pushes the current branch to GitHub with ONLY the colleague's IMPACT
              SSH key. Returns [pscustomobject]@{ Success; Output }.
    .DESCRIPTION
        One attempt, one identity. The old remote code tried up to four ways
        (ssh-agent, the IMPACT key, the workstation's own keys, then whatever
        default key the shared account has). That could publish a colleague's
        commit with somebody else's GitHub key, left an ssh-agent process
        running on the workstation after every push, and showed only the error
        of the LAST attempt (often a misleading "Permission denied").
        SSH options used for the connection to GitHub:
          -i <key> + IdentitiesOnly=yes   use the IMPACT key and nothing else
          BatchMode=yes                   never wait for a password or a yes/no
                                          question in a console nobody sees
          StrictHostKeyChecking=accept-new  first contact with github.com is
                                          accepted; a CHANGED key is still refused
          ConnectTimeout=15               do not hang forever on a bad network
        The origin URL is NOT changed. If origin is https://github.com/..., the
        git option url.<ssh>.pushInsteadOf makes only this one push go over SSH,
        so tools that use the HTTPS remote (GitHub Desktop, Git Credential
        Manager) keep working.
    #>
    param(
        [pscustomobject]$State,
        [string]$RepoPath,
        [bool]$IsRemote,
        [bool]$HasUpstream,
        [string]$Branch
    )
    # A branch that was never pushed has no "upstream". Plain 'git push' fails then,
    # so we push it under the same name and remember the link (-u), as RStudio does.
    # Without a branch (detached HEAD) there is nothing sensible to push.
    if (-not $HasUpstream -and (-not $Branch -or $Branch -eq 'HEAD')) {
        return [pscustomobject]@{ Success = $false; Output = 'fatal: You are not on a branch (detached HEAD), so there is nothing to push.' }
    }
    # @(...) keeps it an array even with one element, so the splat below is reliable.
    $pushArgs = @(if ($HasUpstream) { 'push' } else { 'push', '-u', 'origin', 'HEAD' })
    $insteadOf = 'url.git@github.com:.pushInsteadOf=https://github.com/'
    $sshOpts = '-o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15'

    if ($IsRemote) {
        # The user name becomes part of a file name in a shell command below, so we
        # only accept letters, digits, hyphens and underscores. This is the same rule
        # as the username check in the first dialog (Resolve-GitHubUsernameInput).
        # Underscores must be allowed here too: company-managed GitHub accounts
        # (for example 'jdoe_acme') use them, and before this change such a user
        # could log in, but every push from the workstation was refused here.
        # An underscore is not a special character for the shell, so the key path
        # '~/.ssh/id_ed25519_<user>' stays safe.
        $user = [string]$State.UserName
        if ($user -notmatch '^[A-Za-z0-9][A-Za-z0-9_-]*$') {
            return [pscustomobject]@{ Success = $false; Output = "fatal: '$user' is not a valid GitHub user name, so the IMPACT key cannot be found." }
        }
        # The key lives in the shared account's ~/.ssh on the workstation. The ssh
        # command is single-quoted for the workstation's shell; git later runs it
        # through 'sh', which expands the ~.
        $innerSsh = "ssh -i ~/.ssh/id_ed25519_$user $sshOpts"
        $cmd = "cd $(ConvertTo-PosixShellLiteral -Value $RepoPath) && GIT_SSH_COMMAND=$(ConvertTo-PosixShellLiteral -Value $innerSsh) GIT_TERMINAL_PROMPT=0 git -c $(ConvertTo-PosixShellLiteral -Value $insteadOf) $($pushArgs -join ' ')"
        $global:LASTEXITCODE = 0
        $out = & ssh -n -i $State.Paths.SshPrivate -o StrictHostKeyChecking=accept-new -o IdentitiesOnly=yes -o ConnectTimeout=15 -o BatchMode=yes (Get-RemoteHostString -State $State) $cmd 2>&1
        $code = $LASTEXITCODE
    } else {
        # Git for Windows runs GIT_SSH_COMMAND through its own 'sh', so the Windows
        # key path gets forward slashes and POSIX quoting (spaces or an apostrophe
        # in the user folder name would otherwise break it).
        $keyPosix = ([string]$State.Paths.SshPrivate) -replace '\\', '/'
        $oldSsh = $env:GIT_SSH_COMMAND
        $oldPrompt = $env:GIT_TERMINAL_PROMPT
        Push-Location -LiteralPath $RepoPath
        try {
            # Set only for this push and restored in 'finally', so nothing else in
            # this PowerShell session is affected. GIT_TERMINAL_PROMPT=0 stops git
            # from waiting for an HTTPS user name in the console window behind the
            # GUI, where nobody would notice the question (the GUI would freeze).
            $env:GIT_SSH_COMMAND = "ssh -i $(ConvertTo-PosixShellLiteral -Value $keyPosix) $sshOpts"
            $env:GIT_TERMINAL_PROMPT = '0'
            $global:LASTEXITCODE = 0
            $out = & git -c $insteadOf @pushArgs 2>&1
            $code = $LASTEXITCODE
        } finally {
            # Assigning $null removes the variable again if it was not set before.
            $env:GIT_SSH_COMMAND = $oldSsh
            $env:GIT_TERMINAL_PROMPT = $oldPrompt
            Pop-Location
        }
    }
    return [pscustomobject]@{ Success = ($code -eq 0); Output = (ConvertTo-GitOutputText -Output $out) }
}

function Invoke-GitChangeDetection {
    <#
    .SYNOPSIS Runs after a container stops: offers to commit (and push) changes,
              or to push commits that are not on GitHub yet.
    .OUTPUTS  [pscustomobject]@{ Success; Outcome; Message } so the caller can
              show an honest status line. Outcome is one of: NoChanges,
              Unavailable, Blocked, Skipped, Committed, Pushed, CommitFailed,
              PushFailed, Error.
    #>
    param(
        [pscustomobject]$State,
        [string]$RepoPath,
        [bool]$IsRemote
    )
    $newResult = { param([bool]$Ok, [string]$Outcome, [string]$Text) [pscustomobject]@{ Success = $Ok; Outcome = $Outcome; Message = $Text } }
    # Message boxes show only the last lines of git's output so they stay readable.
    $lastLines = { param([string]$Text) ((@($Text -split "`r?`n") | Select-Object -Last 15) -join "`r`n") }
    $where = if ($IsRemote) { 'in the repository on the workstation' } else { 'in the repository on this computer' }

    Write-Log "Detecting git changes at $RepoPath (remote=$IsRemote)" 'Info'
    $stateProblem = $null
    $gitState = Get-GitRepositoryState -State $State -RepoPath $RepoPath -IsRemote $IsRemote -Reason ([ref]$stateProblem)
    if (-not $gitState) {
        # Success is $false here: the colleague's changes were NOT checked, so the Stop
        # button must not report "All done" (it would suggest the work is on GitHub).
        # No message box, because this can repeat on every Stop (for example for
        # colleagues who always commit in RStudio and have no git on this PC); the
        # caller shows the message in the status line instead.
        $unavailableText = switch ($stateProblem) {
            'GitMissing'  { 'Your changes were NOT checked or committed: git is not installed on this computer. Commit them in the RStudio Git pane (or with GitHub Desktop), or install Git for Windows.' }
            'Unreachable' { 'Your changes were NOT checked or committed: the workstation could not be reached. They are still saved there; commit them in the RStudio Git pane next time.' }
            default       { 'Your changes were NOT checked or committed: git could not read the status of the repository (details are in the log). Commit them in the RStudio Git pane next time.' }
        }
        return (& $newResult $false 'Unavailable' $unavailableText)
    }

    # Refuse to commit while git is in the middle of a merge / rebase, or while files
    # still have conflicts. 'git add -A' would mark conflicted files as resolved and
    # the commit would publish files that still contain <<<<<<< markers.
    $conflicts = @($gitState.Conflicts)
    $operation = [string]$gitState.OperationInProgress
    if ($operation -or $conflicts.Count -gt 0) {
        $opName = if ($operation) { $operation } else { 'merge' }
        $why = "Nothing was committed or pushed, because git is in the middle of an unfinished $opName. Your files are unchanged."
        if ($conflicts.Count -gt 0) {
            $why += "`r`n`r`nThese files still have conflicts (sections between <<<<<<< and >>>>>>>):`r`n  " + ((@($conflicts) | Select-Object -First 15) -join "`r`n  ")
        }
        $how = switch ($opName) {
            'merge'  { "Start the container again, fix those sections in RStudio, then click Commit in the RStudio Git pane. To cancel the merge instead, run 'git merge --abort' in the RStudio Terminal." }
            'rebase' { "Start the container again and, in the RStudio Terminal, run 'git rebase --continue' after fixing conflicts, or 'git rebase --abort' to cancel." }
            default  { "Start the container again and, in the RStudio Terminal, run 'git $opName --continue' after fixing conflicts, or 'git $opName --abort' to cancel." }
        }
        $why += "`r`n`r`n$how"
        Write-Log $why 'Warn'
        if (-not $script:NonInteractive) { [System.Windows.Forms.MessageBox]::Show($why, "Git: unfinished $opName", 'OK', 'Warning') | Out-Null }
        return (& $newResult $false 'Blocked' "Not committed: unfinished git $opName.")
    }

    # Refuse to commit when no branch is checked out ("detached HEAD", for example after
    # checking out an older commit or a tag). A commit made there belongs to no branch:
    # the push would be refused anyway, and after switching to a branch the new commit
    # can only be found again through git's reflog, so for a non-expert it is lost.
    # PSObject.Properties: older callers and test doubles may not have this property,
    # and StrictMode throws when reading a missing one.
    $isDetached = [bool]($gitState.PSObject.Properties['Detached'] -and $gitState.Detached)
    if ($isDetached -and $gitState.HasChanges) {
        $why = "Nothing was committed or pushed, because no branch is checked out $where (git calls this a 'detached HEAD'). A commit made now would belong to no branch and would be easy to lose. Your files are unchanged.`r`n`r`nTo keep your changes: start the container again, click 'New Branch' in the RStudio Git pane and give the branch a name (your changes move with you), then commit and push there."
        Write-Log $why 'Warn'
        if (-not $script:NonInteractive) { [System.Windows.Forms.MessageBox]::Show($why, 'Git: not on a branch', 'OK', 'Warning') | Out-Null }
        return (& $newResult $false 'Blocked' 'Not committed: no branch is checked out (detached HEAD).')
    }

    $doCommit = $false
    $doPush = $false
    $msg = ''
    # Text for a successful push; changed below when only older commits are pushed.
    $pushedText = 'Changes are committed and pushed to GitHub.'
    if (-not $gitState.HasChanges) {
        if ($gitState.Ahead -le 0) { return (& $newResult $true 'NoChanges' 'No uncommitted changes.') }
        # Clean working tree, but commits made earlier (for example with Commit in
        # RStudio, without Push) are not on GitHub yet. Offer to push them.
        $n = $gitState.Ahead
        Write-Log "$n commit(s) on branch '$($gitState.Branch)' are not on GitHub yet." 'Warn'
        if ($script:NonInteractive) { return (& $newResult $true 'Skipped' "$n commit(s) are not on GitHub yet.") }
        $answer = [System.Windows.Forms.MessageBox]::Show("You have $n commit(s) saved $where that are not on GitHub yet.`r`n`r`nPush them to GitHub now?", 'Unpushed commits', 'YesNo', 'Question')
        if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) {
            Write-Log 'User chose not to push the unpushed commits.' 'Info'
            return (& $newResult $true 'Skipped' "$n commit(s) are still not on GitHub.")
        }
        $doPush = $true
        $pushedText = 'Your commits are pushed to GitHub.'
    } else {
        $dialogResult = Show-GitCommitDialog -ChangesText $gitState.StatusText
        if ($dialogResult) {
            $doCommit = $true
            $msg = [string]$dialogResult.Message
            $doPush = [bool]$dialogResult.Push
        } else {
            Write-Log 'User skipped git commit/push.' 'Info'
            # Skipping the new changes should not also hide commits that were made
            # earlier and are still not on GitHub: offer to push those on their own.
            # (Before, Skip returned straight away and they were never mentioned.)
            $n = $gitState.Ahead
            if ($n -le 0) { return (& $newResult $true 'Skipped' 'Changes were not committed.') }
            Write-Log "$n earlier commit(s) on branch '$($gitState.Branch)' are not on GitHub yet." 'Warn'
            if ($script:NonInteractive) { return (& $newResult $true 'Skipped' "Changes were not committed, and $n earlier commit(s) are not on GitHub yet.") }
            $answer = [System.Windows.Forms.MessageBox]::Show("Your new changes were not committed.`r`n`r`nBut you also have $n earlier commit(s) saved $where that are not on GitHub yet.`r`n`r`nPush those earlier commits to GitHub now? (The new, uncommitted changes stay on disk and are not uploaded.)", 'Unpushed commits', 'YesNo', 'Question')
            if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) {
                Write-Log 'User chose not to push the unpushed commits.' 'Info'
                return (& $newResult $true 'Skipped' "Changes were not committed, and $n earlier commit(s) are still not on GitHub.")
            }
            $doPush = $true
            $pushedText = 'Your earlier commits are pushed to GitHub; the new changes were not committed.'
        }
    }

    try {
        if ($doCommit) {
            # Commit as the colleague, with the same name and e-mail that the container
            # uses for commits made in RStudio. Without this, a remote commit used the
            # shared workstation account's identity (or failed with "Author identity
            # unknown"), and a local commit depended on Windows git being configured.
            # 'git -c' applies it to this one command and changes no config file.
            # We check the name before it goes into a command line: only letters,
            # digits, hyphens and underscores. This is the same rule as the username
            # check in the first dialog (Resolve-GitHubUsernameInput), which allows
            # underscores because company-managed GitHub accounts use them. With the
            # older rule (no underscores) such a user's commit silently lost the
            # IMPACT identity. An underscore is not a special character for the shell.
            $gitUser = [string]$State.UserName
            $useIdentity = $gitUser -match '^[A-Za-z0-9][A-Za-z0-9_-]*$'
            if (-not $useIdentity) { Write-Log "'$gitUser' is not a valid GitHub user name; committing with git's own identity settings." 'Warn' }
            $gitEmail = "$gitUser@users.noreply.github.com"
            $nothingToCommit = $false
            if ($IsRemote) {
                $idPart = if ($useIdentity) { "-c user.name=$(ConvertTo-PosixShellLiteral -Value $gitUser) -c user.email=$(ConvertTo-PosixShellLiteral -Value $gitEmail) " } else { '' }
                # The message is sent base64-encoded and decoded on the workstation
                # ('git commit -F -' reads it from the pipe). Base64 only contains
                # A-Z a-z 0-9 + / =, so backticks, $, quotes or a trailing \ in the
                # message can no longer run commands or break the quoting.
                # UTF-8 keeps umlauts intact.
                # 'git diff --cached --quiet' succeeds when nothing is staged; that is
                # how we spot "nothing to commit" without depending on git's (possibly
                # German) wording.
                $b64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($msg))
                $commitCmd = "cd $(ConvertTo-PosixShellLiteral -Value $RepoPath) && git add -A && if git diff --cached --quiet; then echo __IMPACT_NOTHING_TO_COMMIT__; else printf '%s' '$b64' | base64 -d | git ${idPart}commit -F -; fi"
                $global:LASTEXITCODE = 0
                $commitOut = & ssh -n -i $State.Paths.SshPrivate -o StrictHostKeyChecking=accept-new -o IdentitiesOnly=yes -o ConnectTimeout=15 -o BatchMode=yes (Get-RemoteHostString -State $State) $commitCmd 2>&1
                $commitCode = $LASTEXITCODE
                $commitText = ConvertTo-GitOutputText -Output $commitOut
                $nothingToCommit = ($commitCode -eq 0 -and $commitText -match '__IMPACT_NOTHING_TO_COMMIT__')
            } else {
                $idArgs = @(if ($useIdentity) { '-c', "user.name=$gitUser", '-c', "user.email=$gitEmail" })
                Push-Location -LiteralPath $RepoPath
                try {
                    # Each step's exit code is checked; before, failures were ignored
                    # and the log said "completed" anyway.
                    $global:LASTEXITCODE = 0
                    $commitOut = @(git add -A 2>&1)
                    $commitCode = $LASTEXITCODE
                    if ($commitCode -eq 0) {
                        $global:LASTEXITCODE = 0
                        $null = git diff --cached --quiet 2>&1
                        if ($LASTEXITCODE -eq 0) {
                            $nothingToCommit = $true
                        } else {
                            $global:LASTEXITCODE = 0
                            $commitOut = @(git @idArgs commit -m $msg 2>&1)
                            $commitCode = $LASTEXITCODE
                        }
                    }
                } finally {
                    Pop-Location
                }
                $commitText = ConvertTo-GitOutputText -Output $commitOut
            }
            Write-Log "Git commit exit=$commitCode output=$commitText" 'Debug'
            if ($commitCode -ne 0) {
                $why = "The commit failed, so nothing was committed or pushed. Your files are unchanged.`r`n`r`nGit said:`r`n$(& $lastLines $commitText)"
                Write-Log "Git commit failed (exit $commitCode): $commitText" 'Error'
                if (-not $script:NonInteractive) { [System.Windows.Forms.MessageBox]::Show($why, 'Git commit failed', 'OK', 'Error') | Out-Null }
                return (& $newResult $false 'CommitFailed' 'Git commit failed; nothing was committed or pushed.')
            }
            if ($nothingToCommit) { Write-Log 'Nothing new to commit after staging.' 'Info' }
            else { Write-Log "Git commit created $where." 'Info' }
        }

        if (-not $doPush) {
            return (& $newResult $true 'Committed' "Changes committed $where, but not pushed to GitHub.")
        }

        if (-not $gitState.HasUpstream) { Write-Log "Branch '$($gitState.Branch)' is not on GitHub yet; pushing it as a new branch." 'Info' }
        Write-Log 'Pushing to GitHub with your IMPACT SSH key...' 'Info'
        $push = Invoke-GitPushWithImpactKey -State $State -RepoPath $RepoPath -IsRemote $IsRemote -HasUpstream ([bool]$gitState.HasUpstream) -Branch ([string]$gitState.Branch)
        Write-Log "Git push success=$($push.Success) output=$($push.Output)" 'Debug'
        if (-not $push.Success) {
            # Say clearly that the commit exists but did NOT reach GitHub, why, and
            # what to do; then show git's own words for the details.
            $hint = Get-GitPushFailureHint -Output $push.Output -KeyName "your IMPACT SSH key (id_ed25519_$($State.UserName))"
            $why = "Your commit is saved $where, but it was NOT uploaded to GitHub.`r`n`r`n$hint`r`n`r`nGit said:`r`n$(& $lastLines $push.Output)"
            Write-Log "Git push failed: $hint Git output: $($push.Output)" 'Error'
            if (-not $script:NonInteractive) { [System.Windows.Forms.MessageBox]::Show($why, 'Git push failed', 'OK', 'Error') | Out-Null }
            return (& $newResult $false 'PushFailed' 'Committed, but the push to GitHub failed.')
        }
        Write-Log 'Git push to GitHub completed.' 'Info'
        return (& $newResult $true 'Pushed' $pushedText)
    } catch {
        Write-Log "Git commit/push error: $($_.Exception.Message)" 'Error'
        if (-not $script:NonInteractive) {
            [System.Windows.Forms.MessageBox]::Show("Git commit/push stopped with an error:`r`n$($_.Exception.Message)", 'Git error', 'OK', 'Error') | Out-Null
        }
        return (& $newResult $false 'Error' "Git commit/push error: $($_.Exception.Message)")
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
                        # B6a-R3: installing the capability does not add its folder to PATH,
                        # and on managed PCs the saved Machine PATH may not contain it. Check
                        # the built-in folder again, otherwise the user would get "SSH missing"
                        # right after a successful install.
                        if (-not (Get-Command ssh -ErrorAction SilentlyContinue) -and $builtinSshDir -and (Test-Path -LiteralPath (Join-Path $builtinSshDir 'ssh.exe'))) {
                            Write-Log "Adding the newly installed OpenSSH folder $builtinSshDir to PATH for this session." 'Info'
                            $env:PATH = "$builtinSshDir;$env:PATH"
                        }
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
        # The message names underscores too, because the check above accepts them.
        return [pscustomobject]@{ UserName = $null; Problem = "'$name' is not a valid GitHub username. GitHub usernames contain only letters, digits, hyphens and underscores (at most 39 characters)." }
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
function Test-SshAgentHasKey {
    <#
    .SYNOPSIS Is the key already loaded in the ssh-agent? (pure logic, unit tested)
    .PARAMETER AgentList   The output of 'ssh-add -l': one line per key, in the form
                           '<bits> <fingerprint> <comment> (<type>)'.
    .PARAMETER Fingerprint The fingerprint of the IMPACT key ('SHA256:...'), read from the
                           key file with 'ssh-keygen -l -f'. May be empty.
    .PARAMETER KeyPath     The private key file.
    .NOTES    The comment that 'ssh-add -l' shows is the comment stored IN the key. For an
              IMPACT key that is 'IMPACT_<user>', not the file path, so a test on the path
              alone never matched and the key was added again on every start. The
              fingerprint is the reliable test; the path tests are kept for keys whose
              comment really is the file path (older key formats).
    #>
    param([string[]]$AgentList, [string]$Fingerprint, [string]$KeyPath)
    $text = (@($AgentList) | ForEach-Object { "$_" }) -join "`n"
    if (-not $text) { return $false }
    if ($Fingerprint -and $text -match "(?m)^\s*\d+\s+$([regex]::Escape($Fingerprint))(\s|$)") { return $true }
    if ($KeyPath) {
        if ($text -match [regex]::Escape($KeyPath)) { return $true }
        if ($text -match [regex]::Escape((Split-Path $KeyPath -Leaf).Replace('.','_'))) { return $true }
    }
    return $false
}

function Ensure-SshAgentRunning {
    param([string]$SshKeyPath)
    # The ssh-agent is OPTIONAL for IMPACT: IMPACT's own ssh and git calls pass the key file
    # directly (-i <key> -o IdentitiesOnly=yes), and Docker over ssh (which starts a plain
    # 'ssh' without -i) gets the key from the IMPACT entry in ~/.ssh/config (see
    # Ensure-SshConfigEntry). The IMPACT key has no passphrase. So this function only helps
    # when the agent can be used without fuss, and it must never stop or delay the
    # workflow (F66).
    Write-Log 'Checking the optional ssh-agent service (IMPACT also works without it).' 'Debug'

    # Get-Service only exists on Windows. Without this check the function threw on other
    # systems (and in the Linux test run) instead of simply skipping the optional agent.
    if (-not (Get-Command Get-Service -ErrorAction SilentlyContinue)) {
        Write-Log 'Get-Service is not available on this system; skipping the optional ssh-agent step.' 'Debug'
        return
    }
    $sshAgentService = $null
    try { $sshAgentService = Get-Service ssh-agent -ErrorAction SilentlyContinue } catch { $sshAgentService = $null }
    if (-not $sshAgentService) {
        Write-Log 'ssh-agent service not found on this system; skipping it (not needed).' 'Debug'
        return
    }

    if ($sshAgentService.Status -ne 'Running') {
        # F66: only try a normal (non-elevated) start. The old code then restarted itself
        # with "Run as administrator", so colleagues without admin rights got an unexplained
        # Windows permission (UAC) prompt on every launch, for a service IMPACT does not need.
        # Windows installs this service as 'Disabled', and only an administrator can change
        # that, so a failed start is normal and is only logged.
        try {
            Start-Service ssh-agent -ErrorAction Stop
            Write-Log 'ssh-agent service started (no elevation needed).' 'Info'
        } catch {
            Write-Log "The optional ssh-agent service is not running and could not be started without administrator rights ($($_.Exception.Message)). This is fine: IMPACT does not need the agent (it gives ssh the key file directly or through its ~/.ssh/config entry). (An administrator can enable it with: Get-Service ssh-agent | Set-Service -StartupType Automatic; Start-Service ssh-agent)" 'Info'
            return
        }
    }

    # Stale key cleanup. Note: this only finds agent entries whose comment is a file path
    # (keys in older formats). IMPACT keys are listed as 'IMPACT_<user>', so a deleted
    # IMPACT key is not found here. That is harmless: IMPACT always names its key file
    # (IdentitiesOnly), so ssh never offers an unrelated key from the agent.
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
            # Join the lines first: '-notmatch' on an ARRAY filters it instead of returning
            # true/false, so with several keys loaded the old check always "re-added" the key.
            $loadedKeys = (@(& ssh-add -l 2>&1) | ForEach-Object { "$_" }) -join "`n"
            # 'ssh-add -l' shows the comment stored in the key ('IMPACT_<user>'), not the
            # file path, so the path test alone never matched. Compare the key's fingerprint
            # (the second field of 'ssh-keygen -l -f <key>.pub') instead; see
            # Test-SshAgentHasKey. If the fingerprint cannot be read, the key is simply
            # added again, which is harmless (ssh-add replaces the same key).
            $fingerprint = $null
            $fingerprintSource = if (Test-Path -LiteralPath "$SshKeyPath.pub") { "$SshKeyPath.pub" } else { $SshKeyPath }
            $fingerprintRead = Invoke-ImpactSshKeygen -Arguments @('-l', '-f', $fingerprintSource)
            if ($fingerprintRead.ExitCode -eq 0) {
                $fingerprintLine = @($fingerprintRead.Output | Where-Object { $_ -match '^\s*\d+\s+\S+:\S+' }) | Select-Object -First 1
                if ($fingerprintLine) { $fingerprint = (([string]$fingerprintLine).Trim() -split '\s+')[1] }
            }
            if (-not (Test-SshAgentHasKey -AgentList $loadedKeys -Fingerprint $fingerprint -KeyPath $SshKeyPath)) {
                # Empty input on stdin: if ssh-add ever asked a question, it gets "no answer"
                # and stops instead of waiting for input in a hidden console. The exit code is
                # checked so a failure is not reported as success (F66).
                $addOut = @('' | & ssh-add $SshKeyPath 2>&1)
                if ($LASTEXITCODE -eq 0) {
                    Write-Log "SSH key added to ssh-agent: $SshKeyPath" 'Info'
                } else {
                    Write-Log "ssh-add could not add the key (exit $LASTEXITCODE): $((@($addOut) | ForEach-Object { "$_" }) -join ' '). Not a problem: IMPACT does not need the agent." 'Debug'
                }
            } else {
                Write-Log 'SSH key already loaded in ssh-agent.' 'Debug'
            }
        } catch { Write-Log "ssh-add failed: $($_.Exception.Message)" 'Debug' }
    } else {
        Write-Log 'ssh-agent service is not running; skipping ssh-add (not needed).' 'Debug'
    }
}

function Remove-SshConfigHostBlock {
    param(
        [string]$ConfigPath,
        [string]$HostPattern
    )
    Write-Log "Remove-SshConfigHostBlock called for HostPattern='$HostPattern' ConfigPath='$ConfigPath'" 'Debug'
    if (-not (Test-Path -LiteralPath $ConfigPath)) { return $false }

    # @(...): a config with a single line would otherwise be one string, and $lines[$i]
    # would then return single characters instead of lines.
    $lines = @(Get-Content -LiteralPath $ConfigPath -ErrorAction SilentlyContinue)
    if ($lines.Count -eq 0) { return $false }

    $resultLines = [System.Collections.Generic.List[string]]::new()
    # Blank and comment lines seen inside the block whose fate is not decided yet (F99).
    $pendingLines = [System.Collections.Generic.List[string]]::new()
    $inBlock = $false
    $removed = $false
    $hostEscaped = [regex]::Escape($HostPattern)

    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = [string]$lines[$i]

        if ($line -match "^\s*Host\s+$hostEscaped\s*`$") {
            $inBlock = $true
            $removed = $true
            $pendingLines.Clear()
            while ($resultLines.Count -gt 0 -and (
                $resultLines[$resultLines.Count - 1] -match '^\s*#.*IMPACT' -or
                [string]::IsNullOrWhiteSpace($resultLines[$resultLines.Count - 1])
            )) {
                $resultLines.RemoveAt($resultLines.Count - 1)
            }
            continue
        }

        if ($inBlock) {
            # F99: in ssh_config a Host block also ends at a 'Match' line, and an 'Include'
            # line written after our block is meant for the user's own settings. The old
            # code removed everything up to the next 'Host' line, so a user's Match section
            # or Include line placed after the IMPACT entry silently disappeared.
            if ($line -match '^\s*(Host|Match|Include)(\s|=)') {
                $inBlock = $false
                # Blank lines and comments directly in front of the next section belong to
                # that section (for example '# my GitHub settings' above 'Host github.com'),
                # so they are kept.
                foreach ($pl in $pendingLines) { $resultLines.Add($pl) }
                $pendingLines.Clear()
                $resultLines.Add($line)
            } elseif ([string]::IsNullOrWhiteSpace($line) -or $line -match '^\s*#') {
                $pendingLines.Add($line)
            } else {
                # A setting of the removed block: drop it, and with it any comment that
                # stood between its settings.
                $pendingLines.Clear()
            }
            continue
        }

        $resultLines.Add($line)
    }
    # Comments after the removed block at the end of the file are the user's; keep them.
    foreach ($pl in $pendingLines) { if (-not [string]::IsNullOrWhiteSpace($pl)) { $resultLines.Add($pl) } }

    if ($removed) {
        Set-Content -LiteralPath $ConfigPath -Value $resultLines -Encoding UTF8
        Write-Log "Removed SSH config Host block for '$HostPattern' from $ConfigPath" 'Info'
    } else {
        Write-Log "No matching Host block found for '$HostPattern'." 'Debug'
    }

    return $removed
}

function Backup-SshConfigFile {
    <#
    .SYNOPSIS Saves a copy of the ssh config before IMPACT changes lines the user wrote.
    .OUTPUTS  The path of the copy, or $null when no copy could be made.
    .NOTES    First choice is next to the file (config.impact-backup-<time>). If that fails
              (for example the .ssh folder does not allow new files), the copy goes to
              ~/.impact_gui/ssh-config-backups, the folder IMPACT also uses for its logs.
              A number is added when a copy with the same time already exists, so two
              changes in the same second never overwrite the first copy.
    #>
    param([Parameter(Mandatory)][string]$ConfigPath)
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $leaf = Split-Path -Leaf $ConfigPath
    $folders = @(
        (Split-Path -Parent $ConfigPath),
        (Join-Path (Join-Path $HOME '.impact_gui') 'ssh-config-backups')
    )
    foreach ($folder in $folders) {
        try {
            if (-not (Test-Path -LiteralPath $folder)) { New-Item -ItemType Directory -Path $folder -Force -ErrorAction Stop | Out-Null }
            $destination = Join-Path $folder "$leaf.impact-backup-$stamp"
            $n = 2
            while (Test-Path -LiteralPath $destination) { $destination = Join-Path $folder "$leaf.impact-backup-$stamp-$n"; $n++ }
            Copy-Item -LiteralPath $ConfigPath -Destination $destination -ErrorAction Stop
            return $destination
        } catch {
            Write-Log "Could not save a copy of $ConfigPath in $folder ($($_.Exception.Message))." 'Debug'
        }
    }
    return $null
}

function Repair-SshConfigIdentityFileQuoting {
    <#
    .SYNOPSIS Puts double quotes around every unquoted IdentityFile path in the ssh config
              that contains a space, in ALL sections of the file.
    .OUTPUTS  [int] the number of lines that were repaired.
    .NOTES    One unquoted path with a space (older IMPACT versions wrote
              'IdentityFile C:/Users/Max Mustermann/.ssh/...') makes OpenSSH reject the
              WHOLE file ("garbage at end of line"), so every ssh call fails: remote Docker,
              the GitHub key check and git push. Ensure-SshConfigEntry only looks at the
              section of the workstation that is being connected to, so an old entry for
              another IP (an earlier or mistyped address) stayed broken. This helper is
              called at the start of Ensure-SshConfigEntry and from Ensure-GitKeySetup, so
              it also runs for colleagues who only use LOCAL mode.
              - Sections written by IMPACT (marker comment '# IMPACT Docker GUI' above the
                Host line) are repaired directly. If a line the user wrote is repaired, a
                copy of the file is saved first; if no copy can be made, only IMPACT's own
                lines are repaired and the user is told how to fix the others.
              - Values that contain a quote, a '#' or a backslash before a space are left
                alone: newer OpenSSH versions read those as written (comment or escaped
                space), and adding quotes would change their meaning.
              - Never throws: the caller's workflow must not stop because of this repair.
    #>
    param([string]$ConfigPath)
    try {
        if (-not $ConfigPath) { $ConfigPath = Join-Path (Join-Path $HOME '.ssh') 'config' }
        if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) { return 0 }
        # @(...): a single-line file would otherwise be one string (see Remove-SshConfigHostBlock).
        $lines = @(Get-Content -LiteralPath $ConfigPath -ErrorAction SilentlyContinue)
        if ($lines.Count -eq 0) { return 0 }

        $repairs = [System.Collections.Generic.List[object]]::new()
        $inImpactSection = $false
        $lastNonEmptyLine = ''
        for ($i = 0; $i -lt $lines.Count; $i++) {
            $line = [string]$lines[$i]
            if ($line -match '^\s*(Host|Match)(\s|=)') {
                # Same rule as Ensure-SshConfigEntry: the section is IMPACT's when the
                # marker comment is the last non-empty line above its Host line.
                $inImpactSection = ($lastNonEmptyLine -match '^\s*#.*IMPACT Docker GUI')
            } elseif ($line -match '^\s*Include(\s|=)') {
                $inImpactSection = $false
            } elseif ($line -match '^(\s*IdentityFile(?:\s*=\s*|\s+))(.*?)\s*$') {
                $prefix = $Matches[1]
                $value = $Matches[2]
                if ($value -match '\s') {
                    if ($value -match '["#]' -or $value -match '\\\s') {
                        Write-Log "Line $($i + 1) of $ConfigPath has an IdentityFile value with a space that IMPACT does not change automatically: $value" 'Debug'
                    } else {
                        $repairs.Add([pscustomobject]@{ Index = $i; NewLine = "$prefix`"$value`""; Ours = $inImpactSection; Value = $value })
                    }
                }
            }
            if (-not [string]::IsNullOrWhiteSpace($line)) { $lastNonEmptyLine = $line }
        }
        if ($repairs.Count -eq 0) { return 0 }

        $userRepairs = @($repairs | Where-Object { -not $_.Ours })
        if ($userRepairs.Count -gt 0) {
            $backupPath = Backup-SshConfigFile -ConfigPath $ConfigPath
            if ($backupPath) {
                Write-Log "Your ssh config $ConfigPath has IdentityFile paths with a space but without quotes, which makes ssh reject the whole file. IMPACT adds the quotes; a copy of the previous file was saved as $backupPath." 'Warn'
            } else {
                foreach ($r in $userRepairs) {
                    Write-Log "Line $($r.Index + 1) of $ConfigPath ('IdentityFile $($r.Value)') needs double quotes around the path, otherwise ssh rejects the whole file and remote Docker and git fail. IMPACT could not save a copy of the file, so it does not change your line. Please open the file in a text editor and change the line to: IdentityFile `"$($r.Value)`"" 'Error'
                }
                $repairs = [System.Collections.Generic.List[object]]::new([object[]]@($repairs | Where-Object { $_.Ours }))
                if ($repairs.Count -eq 0) { return 0 }
            }
        }

        foreach ($r in $repairs) { $lines[$r.Index] = $r.NewLine }
        Set-Content -LiteralPath $ConfigPath -Value $lines -Encoding UTF8 -ErrorAction Stop
        foreach ($r in $repairs) {
            Write-Log "Added quotes around the IdentityFile path on line $($r.Index + 1) of $ConfigPath ($($r.Value)); without them ssh rejects the whole file." 'Warn'
        }
        return $repairs.Count
    } catch {
        Write-Log "Could not check or repair the IdentityFile lines in the ssh config ($($_.Exception.Message))." 'Warn'
        return 0
    }
}

function Ensure-SshConfigEntry {
    param(
        [string]$RemoteHostIp,
        [string]$RemoteUser,
        [string]$IdentityFile,
        # The ssh config file to update. Normally empty, which means the user's own
        # ~/.ssh/config. Tests pass a temporary file here so they never touch the real one.
        [string]$ConfigPath
    )

    if (-not $RemoteHostIp -or -not $RemoteUser -or -not $IdentityFile) {
        Write-Log 'Ensure-SshConfigEntry: missing parameters, skipping.' 'Debug'
        return
    }

    # Note: PowerShell variable names ignore case, so $ConfigPath and $configPath below
    # are the same variable.
    if (-not $ConfigPath) { $ConfigPath = Join-Path (Join-Path $HOME '.ssh') 'config' }
    $sshDir = Split-Path -Parent $ConfigPath
    Write-Log "Ensure-SshConfigEntry: sshDir='$sshDir' configPath='$configPath' RemoteHostIp='$RemoteHostIp'" 'Debug'
    Write-Log "Ensuring SSH config entry for $RemoteHostIp in $configPath" 'Info'

    if (-not (Test-Path -LiteralPath $sshDir)) {
        New-Item -Path $sshDir -ItemType Directory -Force | Out-Null
    }

    # First repair unquoted IdentityFile paths with a space in EVERY section of the file,
    # not only in the section for this IP: a single broken line (for example from an old
    # entry for another workstation address) makes ssh reject the whole file, including the
    # entry written below. '$null =' keeps the returned count out of this function's output.
    $null = Repair-SshConfigIdentityFileQuoting -ConfigPath $configPath

    $identityNorm = $IdentityFile -replace '\\','/'

    if (Test-Path -LiteralPath $configPath) {
        $existingConfig = Get-Content -LiteralPath $configPath -Raw -ErrorAction SilentlyContinue
        if ($existingConfig -match "(?mi)^\s*Host\s+$([regex]::Escape($RemoteHostIp))\s*`$") {
            $configLines = $existingConfig -split "`n"
            $inBlock = $false
            $existingIdentityRaw = $null
            # F67: remember whether IMPACT wrote this block (its marker comment is the last
            # non-empty line above the Host line) or whether the user or an admin wrote it.
            $blockIsOurs = $false
            $lastLineBeforeBlock = ''
            foreach ($cl in $configLines) {
                $cl = $cl.TrimEnd("`r")
                if ($cl -match "^\s*Host\s+$([regex]::Escape($RemoteHostIp))\s*`$") {
                    $inBlock = $true
                    $blockIsOurs = ($lastLineBeforeBlock -match '^\s*#.*IMPACT Docker GUI')
                    continue
                }
                if ($inBlock) {
                    # Same block-end rule as Remove-SshConfigHostBlock (F99).
                    if ($cl -match '^\s*(Host|Match|Include)(\s|=)') { break }
                    # 'IdentityFile=value' is also valid ssh_config syntax.
                    if ($cl -match '^\s*IdentityFile(?:\s*=\s*|\s+)(.+)$') { $existingIdentityRaw = $Matches[1].Trim() }
                } elseif (-not [string]::IsNullOrWhiteSpace($cl)) {
                    $lastLineBeforeBlock = $cl
                }
            }
            $needsUpdate = $false
            if ($existingIdentityRaw) {
                # F06 / B4-R1: IMPACT now writes the path in double quotes (see below), so
                # remove one pair of quotes before using the value. Without this, a quoted
                # path would never be found on disk and the entry would be rewritten on
                # every start.
                $isQuoted = ($existingIdentityRaw.Length -ge 2 -and $existingIdentityRaw.StartsWith('"') -and $existingIdentityRaw.EndsWith('"'))
                $existingIdentityFile = if ($isQuoted) { $existingIdentityRaw.Substring(1, $existingIdentityRaw.Length - 2) } else { $existingIdentityRaw }
                $existingNorm = $existingIdentityFile -replace '\\','/'
                # Expand '~' and '%d' (both mean the home folder in ssh_config), so an entry
                # written as ~/.ssh/id_ed25519_<user> (the form shown in the user guide) is
                # recognised as the same key instead of being rewritten on every start.
                $homeNorm = ($HOME -replace '\\','/').TrimEnd('/')
                if ($existingNorm -match '^~(/|$)') { $existingNorm = $homeNorm + $existingNorm.Substring(1) }
                elseif ($existingNorm -match '^%d(/|$)') { $existingNorm = $homeNorm + $existingNorm.Substring(2) }
                if (-not $isQuoted -and $existingIdentityFile -match '\s') {
                    # An unquoted path with a space (for example C:/Users/Max Mustermann/...)
                    # makes OpenSSH reject the WHOLE config file, so every ssh call fails.
                    # Earlier IMPACT versions wrote exactly that; repair it.
                    Write-Log "SSH config for $RemoteHostIp has an unquoted IdentityFile path with a space ($existingIdentityFile) - rewriting it with quotes." 'Warn'
                    $needsUpdate = $true
                } elseif (-not $existingNorm -or -not (Test-Path -LiteralPath $existingNorm)) {
                    Write-Log "SSH config for $RemoteHostIp points to deleted key: $existingIdentityFile - replacing entry." 'Warn'
                    $needsUpdate = $true
                } elseif ($existingNorm -ne $identityNorm) {
                    Write-Log "SSH config for $RemoteHostIp references different key ($existingIdentityFile vs $identityNorm) - updating." 'Info'
                    $needsUpdate = $true
                } elseif ($existingIdentityFile -match '\\') {
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
            if (-not $blockIsOurs) {
                # F67: this Host block was written by the user or an admin and may hold
                # settings IMPACT does not know about (Port, ProxyJump, ...). Keep a copy of
                # the whole file before the block is replaced, and say where it is
                # (Backup-SshConfigFile also tries a second folder). If no copy can be made,
                # the user's block is left alone. IMPACT's own ssh and git calls pass the key
                # directly, but Docker over ssh starts a plain 'ssh' and gets the IMPACT key
                # ONLY from this entry, so remote Docker can then fail: say so clearly and
                # explain the manual fix.
                $backupPath = Backup-SshConfigFile -ConfigPath $configPath
                if ($backupPath) {
                    Write-Log "Your own 'Host $RemoteHostIp' entry in $configPath is replaced by the IMPACT entry. A copy of the previous file was saved as $backupPath." 'Warn'
                } else {
                    Write-Log "Could not save a copy of $configPath, so IMPACT leaves your own 'Host $RemoteHostIp' entry unchanged. Remote Docker may fail, because Docker finds the IMPACT key only through this entry. To fix it, open $configPath in a text editor and make the 'Host $RemoteHostIp' section contain these lines (or delete the section and start IMPACT again): User $RemoteUser / IdentityFile `"$identityNorm`" / IdentitiesOnly yes" 'Error'
                    return
                }
            }
            # F38: '$null =' because Remove-SshConfigHostBlock returns $true/$false. Without
            # it that value became part of THIS function's output and then of the caller's
            # return value, so a cancelled remote preparation counted as success.
            $null = Remove-SshConfigHostBlock -ConfigPath $configPath -HostPattern $RemoteHostIp
        }
    }

    # F06 / B4-R1: the key path is written in double quotes. It is built from the Windows
    # profile folder, which can contain a space (C:/Users/Max Mustermann/...); unquoted,
    # OpenSSH stops reading the config ("garbage at end of line") and EVERY ssh call fails.
    $entry = @"

# IMPACT Docker GUI - auto-generated entry for remote workstation
Host $RemoteHostIp
    User $RemoteUser
    IdentityFile "$identityNorm"
    IdentitiesOnly yes
    StrictHostKeyChecking accept-new
    ConnectTimeout 10
"@

    try {
        Add-Content -LiteralPath $configPath -Value $entry -Encoding UTF8 -ErrorAction Stop
        Write-Log "SSH config entry added for Host $RemoteHostIp" 'Info'
    } catch { Write-Log "Failed to write SSH config: $($_.Exception.Message)" 'Warn' }
}

# ══════════════════════════════════════════════════════════════════════════════
#  Git key setup
# ══════════════════════════════════════════════════════════════════════════════
function Invoke-ImpactSshKeygen {
    <#
    .SYNOPSIS Runs ssh-keygen and returns [pscustomobject] @{ ExitCode; Output } (Output =
              the text lines ssh-keygen printed, errors included).
    .NOTES    - 'Standard' argument passing makes sure an EMPTY argument (the empty
                passphrase in -N '' or -P '') really reaches ssh-keygen. The old "Legacy"
                mode dropped it, so ssh-keygen took the next argument ('-q') as passphrase.
              - An empty line is sent on stdin. If ssh-keygen ever asks a question (for
                example "Overwrite (y/n)?"), it reads that empty line as "no" and stops,
                instead of waiting forever in a console window nobody looks at (F65).
              - All output is captured here, so it can never leak into the return value of
                the caller (which must be a plain $true/$false), and it can be shown to the
                user when something goes wrong.
              - ExitCode is -1 when ssh-keygen could not be started at all.
    #>
    param([string[]]$Arguments)
    $lines = @()
    $exitCode = -1
    try {
        $raw = @(& {
            $PSNativeCommandArgumentPassing = 'Standard'
            '' | & ssh-keygen @Arguments 2>&1
        })
        $exitCode = $LASTEXITCODE
        $lines = @($raw | ForEach-Object { "$_".TrimEnd() } | Where-Object { $_ })
    } catch {
        $lines = @("ssh-keygen could not be run: $($_.Exception.Message)")
        $exitCode = -1
    }
    return [pscustomobject]@{ ExitCode = $exitCode; Output = $lines }
}

function Initialize-ImpactSshKeyPair {
    <#
    .SYNOPSIS Makes sure the IMPACT key pair (<KeyPath> and <KeyPath>.pub) is complete and
              that the private key works WITHOUT a passphrase. Creates a new pair only when
              there is no private key. No dialogs, so it can be unit tested; the caller
              shows Message to the user when Success is $false.
    .OUTPUTS  [pscustomobject] @{ Success; Generated; Status; Message; Details }
              Status is one of:
                'Ready'             the existing pair is fine,
                'PublicKeyRebuilt'  the .pub file was missing and was rebuilt from the key,
                'PassphraseRemoved' an old key had the accidental passphrase '-q'; removed,
                'Unverified'        the pair exists but ssh-keygen could not check it,
                'Generated'         a new pair was created,
                'Encrypted'         the key has a passphrase IMPACT does not know (fails),
                'Unreadable'        the .pub is missing and cannot be rebuilt (fails),
                'GenerateFailed'    a new key could not be created (fails).
    #>
    param(
        [Parameter(Mandatory)][string]$KeyPath,
        [string]$Comment
    )
    $pubPath = "$KeyPath.pub"
    $keyDir  = Split-Path -Parent $KeyPath
    $keyLeaf = Split-Path -Leaf $KeyPath
    $newResult = {
        param([bool]$Ok, [bool]$Generated, [string]$Status, [string]$Message, [string]$Details)
        [pscustomobject]@{ Success = $Ok; Generated = $Generated; Status = $Status; Message = $Message; Details = $Details }
    }
    $newKeyAdvice = "IMPACT then creates a new key, which you must add to GitHub (https://github.com/settings/keys). For the remote workstation you will be asked for its password once."
    $encryptedMessage = "Your IMPACT SSH key is protected by a passphrase, so IMPACT cannot use it.`n`nKey file: $KeyPath`n`nHow to fix it (choose one):`n`n1. Remove the passphrase. The key itself stays the same, so nothing changes on GitHub. Open a terminal and run:`n     ssh-keygen -p -f `"$KeyPath`"`n   Type the current passphrase, then press Enter twice (empty new passphrase).`n`n2. Or rename or delete the two files $keyLeaf and $keyLeaf.pub in the folder $keyDir. $newKeyAdvice`n`nThen start IMPACT again."

    $privateExists = Test-Path -LiteralPath $KeyPath -PathType Leaf
    $publicExists  = Test-Path -LiteralPath $pubPath -PathType Leaf

    if ($privateExists) {
        # Read the public key back out of the private key. '-P ""' means: try the empty
        # passphrase only and never ask. This fails for a passphrase-protected key, which
        # would otherwise make ssh and ssh-add wait for a passphrase nobody can type in.
        $read = Invoke-ImpactSshKeygen -Arguments @('-y', '-P', '', '-f', $KeyPath)
        $status = 'Ready'
        if ($read.ExitCode -ne 0 -and ((@($read.Output) -join ' ') -match 'passphrase')) {
            # F14 leftover / B6a-R1: IMPACT versions run with PowerShell 7.0-7.2 created keys
            # with the passphrase '-q' by mistake (the empty -N '' argument was dropped).
            # Removing exactly that passphrase keeps the same key, so the copy on GitHub and
            # in the workstation's authorized_keys stays valid. A passphrase the user chose
            # is not touched (this command then simply fails).
            $fix = Invoke-ImpactSshKeygen -Arguments @('-p', '-P', '-q', '-N', '', '-f', $KeyPath)
            if ($fix.ExitCode -eq 0) {
                Write-Log "Removed the accidental passphrase ('-q', created by an older IMPACT version) from $KeyPath. The key itself is unchanged." 'Warn'
                $status = 'PassphraseRemoved'
                $read = Invoke-ImpactSshKeygen -Arguments @('-y', '-P', '', '-f', $KeyPath)
            }
        }
        $readText = (@($read.Output) -join ' ')
        if ($read.ExitCode -ne 0 -and $readText -match 'passphrase') {
            Write-Log "SSH key $KeyPath is protected by a passphrase: $readText" 'Error'
            return (& $newResult $false $false 'Encrypted' $encryptedMessage $readText)
        }
        $derivedPublicKey = @($read.Output | Where-Object { $_ -match '^(ssh-|ecdsa-|sk-)\S+\s+\S+' }) | Select-Object -First 1
        if ($publicExists) {
            if ($read.ExitCode -ne 0) {
                # Not a passphrase problem (ssh-keygen missing, unusual file permissions, ...).
                # Keep the previous behaviour and use the pair, but leave a trace in the log.
                Write-Log "Could not check the SSH key $KeyPath with ssh-keygen (exit $($read.ExitCode)): $readText. Using it anyway." 'Warn'
                $status = 'Unverified'
            }
            return (& $newResult $true $false $status '' $readText)
        }
        # F65: the private key exists but its .pub file is missing. Do NOT create a new key
        # (ssh-keygen would ask "Overwrite (y/n)?" in a hidden console, and a new key would
        # invalidate the one already registered on GitHub and on the workstation). Rebuild
        # the .pub from the private key instead.
        if ($read.ExitCode -ne 0 -or -not $derivedPublicKey) {
            Write-Log "Public key $pubPath is missing and could not be rebuilt: $readText" 'Error'
            $msg = "The IMPACT SSH key $KeyPath exists, but its public part ($keyLeaf.pub) is missing and could not be rebuilt from it.`n`nDetails: $readText`n`nTo fix it, rename or delete the file $keyLeaf in the folder $keyDir and start IMPACT again. $newKeyAdvice"
            return (& $newResult $false $false 'Unreadable' $msg $readText)
        }
        $publicLine = [string]$derivedPublicKey
        # Older ssh-keygen versions print the key without its comment; add it back so the
        # key is recognisable (IMPACT_<user>) on GitHub and in authorized_keys.
        if ($Comment -and @($publicLine -split '\s+').Count -lt 3) { $publicLine = "$publicLine $Comment" }
        try {
            Set-Content -LiteralPath $pubPath -Value $publicLine -Encoding ascii -ErrorAction Stop
        } catch {
            $msg = "The public part of your IMPACT SSH key ($pubPath) is missing and could not be written: $($_.Exception.Message)"
            return (& $newResult $false $false 'Unreadable' $msg $_.Exception.Message)
        }
        Write-Log "Rebuilt the missing public key $pubPath from the existing private key." 'Warn'
        if ($status -eq 'Ready') { $status = 'PublicKeyRebuilt' }
        return (& $newResult $true $false $status '' '')
    }

    # No private key: create a new pair.
    if ($publicExists) {
        # F65: a .pub file without its private key cannot be used; remove it so the new
        # pair is consistent.
        Write-Log "Removing $pubPath because its private key is missing; a new key pair will be created." 'Warn'
        Remove-Item -LiteralPath $pubPath -Force -ErrorAction SilentlyContinue
    }
    if ($keyDir -and -not (Test-Path -LiteralPath $keyDir)) {
        New-Item -Path $keyDir -ItemType Directory -Force | Out-Null
        Write-Log "Created .ssh directory at $keyDir" 'Info'
    }
    Write-Log "Generating SSH key at $KeyPath (comment=$Comment)" 'Info'
    $gen = Invoke-ImpactSshKeygen -Arguments @('-t', 'ed25519', '-C', $Comment, '-f', $KeyPath, '-N', '', '-q')
    $genText = (@($gen.Output) -join ' ')
    if ($gen.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $pubPath -PathType Leaf)) {
        Write-Log "SSH key generation failed (exit $($gen.ExitCode)): $genText" 'Error'
        $msg = "IMPACT could not create your SSH key at $KeyPath.`n`nDetails: $genText`n`nPlease check that you can create files in the folder $keyDir, then start IMPACT again."
        return (& $newResult $false $false 'GenerateFailed' $msg $genText)
    }
    # B6a-R1: make sure the new key really has no passphrase (see the PowerShell version
    # note in Test-PowerShellVersionSupported).
    $check = Invoke-ImpactSshKeygen -Arguments @('-y', '-P', '', '-f', $KeyPath)
    if ($check.ExitCode -ne 0) {
        $checkText = (@($check.Output) -join ' ')
        Write-Log "The new SSH key $KeyPath cannot be read without a passphrase: $checkText" 'Error'
        $msg = "IMPACT created a new SSH key at $KeyPath, but it cannot be used without a passphrase.`n`nDetails: $checkText`n`nPlease delete the two files $keyLeaf and $keyLeaf.pub in the folder $keyDir and start IMPACT again. If this happens again, please contact the IMPACT maintainer."
        return (& $newResult $false $true 'GenerateFailed' $msg $checkText)
    }
    return (& $newResult $true $true 'Generated' '' $genText)
}

function Get-GitHubSshAuthStatus {
    <#
    .SYNOPSIS Reads the answer of 'ssh -T git@github.com' (pure logic, unit tested).
    .OUTPUTS  [pscustomobject] @{ Status; Account } where Status is
                'Authenticated'  GitHub accepted the key (Account = the GitHub name of the
                                 account the key belongs to),
                'KeyUnusable'    ssh could not use the key file itself (for example "bad
                                 permissions" or "invalid format"), so GitHub never saw it,
                'NotRegistered'  GitHub refused the key: it is not added to a GitHub account,
                'HostKeyProblem' the github.com host key stored on this PC does not match,
                'Unreachable'    github.com could not be reached (offline, VPN, firewall),
                'Unknown'        anything else (for example a broken ~/.ssh/config).
    .PARAMETER KeyPath  Optional: the key that was tested. When given, 'KeyUnusable' is only
              reported when ssh's complaint names THIS key file, not another key that the
              user's own ~/.ssh/config adds (that one does not matter for IMPACT).
    .NOTES    GitHub never opens a shell, so even a SUCCESSFUL login ends with exit code 1
              and the text "Hi <name>! You've successfully authenticated, but GitHub does
              not provide shell access." Exit code 1 together with that text means "OK".
    #>
    param([string[]]$Output, [int]$ExitCode, [string]$KeyPath)
    $text = (@($Output) | ForEach-Object { "$_" }) -join "`n"
    $account = $null
    if ($text -match 'Hi ([^!\s]+)!') { $account = $Matches[1] }

    # When ssh cannot load the key file (on Windows mostly because other users may read it:
    # "UNPROTECTED PRIVATE KEY FILE!" / 'Load key "...": bad permissions'), it still ends
    # with "Permission denied (publickey)". Telling the user to add the key to GitHub would
    # then be wrong, and 'Check again' could never succeed. ssh names the file in
    # 'Load key "<file>": <reason>' and in "Permissions for '<file>' are too open".
    $keyUnusable = $false
    $keyLeaf = if ($KeyPath) { [System.IO.Path]::GetFileName(($KeyPath -replace '\\+', '/')) } else { $null }
    foreach ($m in [regex]::Matches($text, 'Load key "([^"]+)"\s*:|Permissions (?:\S+ )?for ''([^'']+)'' are too open')) {
        $complainedFile = if ($m.Groups[1].Success) { $m.Groups[1].Value } else { $m.Groups[2].Value }
        $complainedLeaf = [System.IO.Path]::GetFileName(($complainedFile -replace '\\+', '/'))
        if (-not $keyLeaf -or $complainedLeaf -eq $keyLeaf) { $keyUnusable = $true }
    }

    $status = 'Unknown'
    if (($ExitCode -eq 1 -or $ExitCode -eq 0) -and $text -match 'successfully authenticated') {
        $status = 'Authenticated'
    } elseif ($keyUnusable) {
        $status = 'KeyUnusable'
    } elseif ($text -match 'Permission denied \(publickey') {
        $status = 'NotRegistered'
    } elseif ($text -match 'REMOTE HOST IDENTIFICATION HAS CHANGED|Host key verification failed') {
        $status = 'HostKeyProblem'
    } elseif ($text -match 'Could not resolve hostname|timed out|Connection refused|No route to host|Network is unreachable|Connection closed|Connection reset|kex_exchange_identification|connect to host') {
        $status = 'Unreachable'
    }
    return [pscustomobject]@{ Status = $status; Account = $account }
}

function Test-GitHubSshKeyAuth {
    <#
    .SYNOPSIS Asks GitHub whether it accepts the given private key (ssh -T git@github.com).
    .OUTPUTS  [pscustomobject] @{ Status; Account; Output; ExitCode } (Status: see
              Get-GitHubSshAuthStatus).
    .NOTES    Only this one key is offered (-i plus IdentitiesOnly=yes), as inside the
              container. BatchMode=yes: never ask for anything. accept-new: trust github.com
              on first contact, but refuse a host key that differs from a stored one.
              ConnectTimeout=10: do not hang when port 22 is blocked.
    #>
    param([Parameter(Mandatory)][string]$KeyPath)
    $sshArgs = @(
        '-T', '-n',
        '-i', $KeyPath,
        '-o', 'BatchMode=yes',
        '-o', 'IdentitiesOnly=yes',
        '-o', 'StrictHostKeyChecking=accept-new',
        '-o', 'ConnectTimeout=10',
        'git@github.com'
    )
    $out = @()
    $exitCode = -1
    try {
        $out = @(& ssh @sshArgs 2>&1 | ForEach-Object { "$_" })
        $exitCode = $LASTEXITCODE
    } catch {
        $out = @("ssh could not be run: $($_.Exception.Message)")
        $exitCode = -1
    }
    $parsed = Get-GitHubSshAuthStatus -Output $out -ExitCode $exitCode -KeyPath $KeyPath
    return [pscustomobject]@{ Status = $parsed.Status; Account = $parsed.Account; Output = $out; ExitCode = $exitCode }
}

function Show-GitHubKeyRegistrationDialog {
    <#
    .SYNOPSIS F68: explains that GitHub does not accept the IMPACT key yet, shows the public
              key and where to add it, and asks whether to check again or to continue.
    .OUTPUTS  'retry' or 'continue'.
    #>
    param([string]$PublicKey, [string]$UserName)
    $settingsUrl = 'https://github.com/settings/keys'
    try { $PublicKey | Set-Clipboard } catch { Write-Log 'Could not copy key to clipboard.' 'Debug' }

    $formRegister = New-Object System.Windows.Forms.Form -Property @{
        Text = 'Add your SSH key to GitHub'
        Size = New-Object System.Drawing.Size(820,470)
        FormBorderStyle = 'FixedDialog'
        MaximizeBox = $false
        MinimizeBox = $false
    }
    Set-FormCenterOnCurrentScreen -Form $formRegister
    Apply-ThemeToForm -Form $formRegister

    $labelRegisterTitle = New-Object System.Windows.Forms.Label -Property @{ Text = 'GitHub does not accept your IMPACT SSH key yet'; Location = New-Object System.Drawing.Point(24,16); Size = New-Object System.Drawing.Size(770,30) }
    Style-Label -Label $labelRegisterTitle -Style ([System.Drawing.FontStyle]::Bold)
    $formRegister.Controls.Add($labelRegisterTitle)

    $accountText = if ($UserName) { " as $UserName" } else { '' }
    $labelRegisterSteps = New-Object System.Windows.Forms.Label -Property @{
        Text = "Without it, git pull and push do not work (neither in RStudio's Git pane nor when IMPACT offers to commit after you stop a container).`n`n1. Click 'Open GitHub' (or open $settingsUrl in your browser) and sign in$accountText.`n2. Click 'New SSH key', paste the key shown below (it is already copied) and click 'Add SSH key'.`n3. Come back here and click 'Check again'."
        Location = New-Object System.Drawing.Point(24,52)
        Size = New-Object System.Drawing.Size(770,140)
    }
    Style-Label -Label $labelRegisterSteps
    $formRegister.Controls.Add($labelRegisterSteps)

    $textBoxRegisterKey = New-Object System.Windows.Forms.TextBox -Property @{
        Location = New-Object System.Drawing.Point(24,200)
        Size = New-Object System.Drawing.Size(770,150)
        Multiline = $true
        ScrollBars = 'Vertical'
        ReadOnly = $true
        Text = $PublicKey
        WordWrap = $true
    }
    Style-TextBox -TextBox $textBoxRegisterKey
    $textBoxRegisterKey.BackColor = $script:ThemePalette.Panel
    $textBoxRegisterKey.Font = New-Object System.Drawing.Font('Consolas', 10, [System.Drawing.FontStyle]::Regular)
    $formRegister.Controls.Add($textBoxRegisterKey)

    $buttonRegisterCopy = New-Object System.Windows.Forms.Button -Property @{ Text = 'Copy key'; Location = New-Object System.Drawing.Point(24,370); Size = New-Object System.Drawing.Size(120,36) }
    Style-Button -Button $buttonRegisterCopy -Variant 'secondary'
    $formRegister.Controls.Add($buttonRegisterCopy)
    $buttonRegisterCopy.Add_Click({
        try { $PublicKey | Set-Clipboard; $buttonRegisterCopy.Text = 'Copied!' } catch {
            [System.Windows.Forms.MessageBox]::Show('Could not copy the key. Please select the text and press Ctrl+C.', 'Copy failed', 'OK', 'Warning') | Out-Null
        }
    })

    $buttonRegisterOpen = New-Object System.Windows.Forms.Button -Property @{ Text = 'Open GitHub'; Location = New-Object System.Drawing.Point(154,370); Size = New-Object System.Drawing.Size(140,36) }
    Style-Button -Button $buttonRegisterOpen -Variant 'secondary'
    $formRegister.Controls.Add($buttonRegisterOpen)
    $buttonRegisterOpen.Add_Click({
        try { Start-Process $settingsUrl } catch {
            [System.Windows.Forms.MessageBox]::Show("Could not open the web browser. Please open this address yourself:`n`n$settingsUrl", 'Open GitHub', 'OK', 'Information') | Out-Null
        }
    })

    $buttonRegisterRetry = New-Object System.Windows.Forms.Button -Property @{ Text = 'Check again'; Location = New-Object System.Drawing.Point(474,370); Size = New-Object System.Drawing.Size(140,36); DialogResult = [System.Windows.Forms.DialogResult]::Retry }
    Style-Button -Button $buttonRegisterRetry -Variant 'primary'
    $formRegister.Controls.Add($buttonRegisterRetry)

    $buttonRegisterContinue = New-Object System.Windows.Forms.Button -Property @{ Text = 'Continue anyway'; Location = New-Object System.Drawing.Point(624,370); Size = New-Object System.Drawing.Size(170,36); DialogResult = [System.Windows.Forms.DialogResult]::Ignore }
    Style-Button -Button $buttonRegisterContinue -Variant 'secondary'
    $formRegister.Controls.Add($buttonRegisterContinue)

    $formRegister.AcceptButton = $buttonRegisterRetry
    $formRegister.CancelButton = $buttonRegisterContinue
    $dialogResult = $formRegister.ShowDialog()
    $formRegister.Dispose()
    if ($dialogResult -eq [System.Windows.Forms.DialogResult]::Retry) { return 'retry' }
    return 'continue'
}

function Confirm-GitHubKeyRegistered {
    <#
    .SYNOPSIS F68: checks that GitHub accepts the IMPACT key. When GitHub answers that the
              key is not registered, the user sees the key and where to add it, and can
              check again or continue. Never blocks the workflow: when GitHub cannot be
              reached (offline, port 22 blocked), the result is only written to the log.
    .OUTPUTS  The last status ('Authenticated', 'NotRegistered', 'KeyUnusable',
              'Unreachable', 'HostKeyProblem', 'Unknown'), or 'Skipped' in NonInteractive
              mode.
    .NOTES    The result is remembered for the session in $State.Metadata['GitHubKeyCheck']
              (key path + status). 'Back' in the location dialog runs the key setup again;
              without this memory every Back repeated the check (up to about 10 seconds
              when port 22 is blocked) and showed the key dialog again to a user who had
              already chosen 'Continue anyway'. A different key (another GitHub user name
              entered after Back) is checked again.
    #>
    param([pscustomobject]$State, [string]$KeyPath, [string]$PublicKey)
    if ($script:NonInteractive) {
        Write-Log 'NonInteractive: skipping the GitHub SSH key check.' 'Debug'
        return 'Skipped'
    }
    # Read the session memory carefully: under StrictMode, reading a property or key that
    # does not exist with dot notation throws (tests also pass a State without Metadata).
    $sessionMemory = $null
    if ($State -and $State.PSObject.Properties['Metadata'] -and $State.Metadata -is [System.Collections.IDictionary]) {
        $sessionMemory = $State.Metadata
        $previous = if ($sessionMemory.Contains('GitHubKeyCheck')) { $sessionMemory['GitHubKeyCheck'] } else { $null }
        if ($previous -is [System.Collections.IDictionary] -and $previous['KeyPath'] -eq $KeyPath -and $previous['Status']) {
            Write-Log "The GitHub SSH key check was already done in this session (result: $($previous['Status'])); not repeating it." 'Info'
            return [string]$previous['Status']
        }
    }
    while ($true) {
        Write-Host 'Checking that GitHub accepts your IMPACT SSH key...'
        $check = Test-GitHubSshKeyAuth -KeyPath $KeyPath
        $details = (@($check.Output) | Select-Object -Last 5) -join ' '
        if ($check.Status -eq 'Authenticated') {
            if ($check.Account -and $State.UserName -and $check.Account -ne $State.UserName) {
                # The key works, but it was added to another GitHub account than the one
                # entered in IMPACT. Pushing then works only if that account has access.
                Write-Log "GitHub accepts the IMPACT SSH key, but for the GitHub account '$($check.Account)', not '$($State.UserName)'." 'Warn'
            } else {
                Write-Log 'GitHub accepts the IMPACT SSH key.' 'Info'
            }
            if ($null -ne $sessionMemory) { $sessionMemory['GitHubKeyCheck'] = @{ KeyPath = $KeyPath; Status = 'Authenticated' } }
            return 'Authenticated'
        }
        if ($check.Status -ne 'NotRegistered') {
            # No dialog here: a blocked port 22 or a missing internet connection says
            # nothing about the key, and nagging on every start would only confuse.
            # 'if': Split-Path throws on an empty path, and this check must never stop the workflow.
            $keyLeaf = if ($KeyPath) { Split-Path -Leaf $KeyPath } else { 'the key file' }
            $userForIcacls = if ($env:USERNAME) { $env:USERNAME } else { '<your Windows user name>' }
            $hint = switch ($check.Status) {
                'Unreachable'    { 'github.com could not be reached on port 22 (no internet, VPN or firewall).' }
                'HostKeyProblem' { "The github.com host key stored on this PC does not match. If GitHub really changed its key, run 'ssh-keygen -R github.com' once." }
                # The key file itself cannot be used (see Get-GitHubSshAuthStatus). Adding it
                # to GitHub would not help, so the registration dialog is not shown.
                'KeyUnusable'    { "ssh could not use the key file $KeyPath itself, so GitHub never saw the key (adding it to GitHub does not help). On Windows this usually means that other users may read the file ('bad permissions'). To fix it, run in PowerShell: icacls `"$KeyPath`" /inheritance:r /grant:r `"$($userForIcacls):F`"  Or rename both files $keyLeaf and $keyLeaf.pub and start IMPACT again: it then creates a new key, which you add to GitHub (and the workstation asks for its password once)." }
                default          { 'Unexpected answer.' }
            }
            Write-Log "Could not check whether GitHub accepts the IMPACT SSH key: $hint Details: $details" 'Warn'
            if ($null -ne $sessionMemory) { $sessionMemory['GitHubKeyCheck'] = @{ KeyPath = $KeyPath; Status = [string]$check.Status } }
            return $check.Status
        }
        Write-Log "GitHub does not accept the IMPACT SSH key yet ($details)." 'Warn'
        $choice = Show-GitHubKeyRegistrationDialog -PublicKey $PublicKey -UserName $State.UserName
        if ($choice -ne 'retry') {
            Write-Log 'Continuing without the SSH key on GitHub: git pull and push will fail until the key is added at https://github.com/settings/keys.' 'Warn'
            # Remembered, so the dialog does not come back after 'Back' in this session.
            if ($null -ne $sessionMemory) { $sessionMemory['GitHubKeyCheck'] = @{ KeyPath = $KeyPath; Status = 'NotRegistered' } }
            return 'NotRegistered'
        }
    }
}

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

    $privateKeyExists = Test-Path -LiteralPath $sshKeyPath
    $publicKeyExists = Test-Path -LiteralPath $sshPublicKeyPath
    Write-Log "Existing SSH key? private=$privateKeyExists, public=$publicKeyExists" 'Debug'

    # F65 / F14 / B6a-R1: one helper makes sure the pair is complete and usable without a
    # passphrase. It rebuilds a missing .pub file from the private key (instead of making
    # ssh-keygen ask "Overwrite?" in a hidden console), removes the accidental '-q'
    # passphrase of keys made by older versions, or creates a new pair. It captures all
    # ssh-keygen output, so nothing can hang or end up in this function's return value.
    $keyResult = Initialize-ImpactSshKeyPair -KeyPath $sshKeyPath -Comment "IMPACT_$($State.UserName)"
    if (-not $keyResult.Success) {
        Write-Log "SSH key setup failed ($($keyResult.Status)): $($keyResult.Details)" 'Error'
        # Without a message the app used to just close here (exit code 0, no explanation).
        if (-not $script:NonInteractive) {
            [System.Windows.Forms.MessageBox]::Show($keyResult.Message, 'SSH key problem', 'OK', 'Error') | Out-Null
        }
        return $false
    }

    # Repair unquoted IdentityFile paths with a space in ~/.ssh/config (written by older
    # IMPACT versions). One such line makes ssh reject the whole file, which breaks the
    # GitHub check below and the local git push. Done here (and not only in the remote
    # preparation) so it also runs for colleagues who only use LOCAL mode.
    $null = Repair-SshConfigIdentityFileQuoting

    if (-not $keyResult.Generated) {
        Write-Log "Using existing SSH key at $sshKeyPath" 'Info'
        $publicKey = Get-Content -LiteralPath $sshPublicKeyPath -ErrorAction Stop
        $State.Metadata.PublicKey = ($publicKey -join "`n")

        Write-Host "The following Public Key will be used:"
        Write-Host "----------------------------------------"
        Write-Host $publicKey
        Write-Host "----------------------------------------"
        Write-Host "If you cannot authenticate with GitHub, add this key in GitHub -> Settings -> SSH and GPG keys"

        # '$null =': only $true/$false may leave this function (the caller tests it).
        $null = Ensure-SshAgentRunning -SshKeyPath $sshKeyPath
        # F68: check that GitHub really accepts the key; offer help if it does not.
        $null = Confirm-GitHubKeyRegistered -State $State -KeyPath $sshKeyPath -PublicKey ($publicKey -join "`n")
        return $true
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

    $null = Ensure-SshAgentRunning -SshKeyPath $sshKeyPath
    # F68: the new key only works for git once it is added to GitHub. Check that now, so a
    # colleague who closed the key window without adding it is told so right away instead
    # of getting "Permission denied (publickey)" much later in RStudio.
    $null = Confirm-GitHubKeyRegistered -State $State -KeyPath $sshKeyPath -PublicKey ($publicKey -join "`n")
    return $true
}

# ══════════════════════════════════════════════════════════════════════════════
#  Location selection
# ══════════════════════════════════════════════════════════════════════════════
function Test-WorkstationIpAddress {
    <#
    .SYNOPSIS F23: is the text a normal IPv4 address: four numbers from 0 to 255 separated
              by dots (for example 192.168.1.100)? Pure logic, unit tested.
    .NOTES    [IPAddress]::TryParse alone is not enough: it also accepts '10.1' (read as
              10.0.0.1). Leading zeros ('010') are refused as well, because ssh reads such
              a number as octal (010 = 8) and would connect to a different machine.
              [0-9] instead of \d: in .NET, \d also matches non-ASCII digits.
    #>
    param([string]$Address)
    if ([string]::IsNullOrWhiteSpace($Address)) { return $false }
    $octet = '(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])'
    return ($Address -match "^$octet\.$octet\.$octet\.$octet\z")
}

function Get-DotEnvValue {
    <#
    .SYNOPSIS F100: returns the value of one NAME=value line from the lines of a .env file,
              or $null when the name is not there. Pure logic, unit tested.
    .NOTES    Understands 'export NAME=value', a value in "..." or '...', and a comment
              after the value ('WORKSTATION_IP=10.0.0.5  # lab PC'). As in other .env
              readers, '#' starts a comment only at the start of an unquoted value or
              after a space.
    #>
    param([string[]]$Lines, [string]$Name)
    $namePattern = [regex]::Escape($Name)
    foreach ($line in @($Lines)) {
        if ("$line" -match "^\s*(?:export\s+)?$namePattern\s*=(.*)$") {
            $value = $Matches[1].Trim()
            if ($value -match '^"([^"]*)"' -or $value -match "^'([^']*)'") { return $Matches[1].Trim() }
            return ($value -replace '(^|\s+)#.*$', '').Trim()
        }
    }
    return $null
}

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
    # F95: apply the theme to the box FIRST. Style-InfoBox sets one font for ALL text in
    # the box; when it ran after the text had been added (as before), it wiped out the
    # bold parts. The fonts below use the theme's Segoe UI (same as the credential dialog).
    Style-InfoBox -Box $rtbConnectionInstruction
    $rtbConnectionInstruction.SelectionFont = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
    $rtbConnectionInstruction.AppendText('Please choose whether you want to work locally')
    $rtbConnectionInstruction.SelectionFont = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Regular)
    $rtbConnectionInstruction.AppendText(' (e.g. for testing) ')
    $rtbConnectionInstruction.SelectionFont = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
    $rtbConnectionInstruction.AppendText('or remotely on the workstation')
    $rtbConnectionInstruction.SelectionFont = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Regular)
    $rtbConnectionInstruction.AppendText(' (e.g. running simulations for output)!')
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
        if ($ep -and (Test-Path -LiteralPath $ep)) {
            # F100: Get-DotEnvValue also removes a comment after the value
            # ('WORKSTATION_IP=10.0.0.5  # lab PC'), which used to end up in the IP box and
            # then failed the IP check.
            $envValue = Get-DotEnvValue -Lines @(Get-Content -LiteralPath $ep -ErrorAction SilentlyContinue) -Name 'WORKSTATION_IP'
            if ($envValue) {
                $defaultIP = $envValue
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
        # F23: the old pattern only checked the shape, so '999.1.2.3' was accepted and only
        # failed later as an unreachable workstation. Test-WorkstationIpAddress also checks
        # that each number is 0-255.
        if (-not (Test-WorkstationIpAddress -Address $userProvidedIP)) {
            [System.Windows.Forms.MessageBox]::Show("'$userProvidedIP' is not a valid IP address.`n`nPlease enter four numbers from 0 to 255, separated by dots and without leading zeros (for example 192.168.1.100).", 'Invalid IP Format', 'OK', 'Error') | Out-Null
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
.SYNOPSIS Reads the base image name from the first FROM line of a Dockerfile.
.DESCRIPTION The "Image build failed" fallback in the Start handler builds the
             prerequisite image locally. 'docker build' only uses that local image
             for the main build if it has exactly the name that the main
             Dockerfile names in its FROM line. This function finds that name, so
             IMPACT does not depend on a name written into its own code.
             Rules (a simplified version of Docker's own reading of the file):
             - empty lines and lines starting with '#' (comments and parser
               directives such as '# syntax=...') are skipped;
             - 'ARG' lines before the first FROM are skipped (they set build
               variables, they do not name an image);
             - options such as '--platform=linux/amd64' after FROM are skipped;
             - 'AS <stage>' after the image name is ignored.
             Returns $null when there is no FROM line, when the image name uses a
             build variable (for example FROM ${BASE}), which cannot be resolved
             here, or when it is 'scratch' (Docker's empty image).
.PARAMETER Content The Dockerfile text: one string with line breaks, or an array
             of lines as returned by Get-Content or by ssh.
.OUTPUTS [string] the image name, e.g. 'kalleef/prerequisite.impactncdger:latest', or $null.
.EXAMPLE Get-DockerfileBaseImage -Content (Get-Content -LiteralPath $dockerfilePath)
#>
function Get-DockerfileBaseImage {
    param(
        # AllowNull/AllowEmptyCollection: a missing or empty file should give $null,
        # not a parameter-binding error.
        [AllowNull()][AllowEmptyCollection()][string[]]$Content
    )
    if (-not $Content) { return $null }
    # Join and split again, so one string with line breaks and an array of lines are
    # handled the same way. '\r?\n' also handles Windows line endings (CRLF).
    $lines = ($Content -join "`n") -split "\r?\n"
    foreach ($line in $lines) {
        $trimmed = $line.Trim()
        if ($trimmed -eq '' -or $trimmed.StartsWith('#')) { continue }
        # PowerShell's -match ignores upper/lower case, so 'from' and 'FROM' both match.
        if ($trimmed -match '^ARG\s') { continue }
        if ($trimmed -match '^FROM\s+(.+)$') {
            # Split the rest of the line into words and drop options that start with '--'.
            $words = @($matches[1].Trim() -split '\s+' | Where-Object { $_ -and -not $_.StartsWith('--') })
            if ($words.Count -eq 0) { return $null }
            $image = $words[0]
            # A '$' means a build variable (FROM $BASE or FROM ${BASE}); we cannot know its value.
            if ($image.Contains('$') -or $image -eq 'scratch') { return $null }
            return $image
        }
        # The first instruction that is neither a comment, ARG nor FROM means the file
        # does not start with FROM, which Docker would reject anyway.
        return $null
    }
    return $null
}

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
    # Same port rule as the GUI's Start handler (F13): LOCAL containers are only
    # reachable from this computer (127.0.0.1); on the workstation RStudio must stay
    # reachable from the colleague's PC, so it is published on all interfaces.
    $publishSpec = if ($State.ContainerLocation -eq 'LOCAL') { "127.0.0.1:${Port}:8787" } else { "${Port}:8787" }

    $dockerArgs = @('run','-d','--rm','--name',$State.ContainerName,
        '-e',"PASSWORD=$($State.Password)",
        '-e','DISABLE_AUTH=false',
        '-e',"USERID=$ContainerUid",'-e',"GROUPID=$ContainerGid",
        '-e',"CONTAINER_REPO_NAME=$($State.SelectedRepo)",
        '-e','SYNC_ENABLED=false',
        '-e',"GIT_SSH_COMMAND=$(Get-ContainerGitSshCommand -UserName $State.UserName)",
        '--mount',"type=bind,source=$repoMountSource,target=/home/rstudio/$($State.SelectedRepo)",
        '-p',$publishSpec
    )

    # Tokenise like a shell (quotes keep a value with spaces together, no empty
    # arguments), see Split-DockerCustomParams (F102).
    if ($CustomParams) { $dockerArgs += @(Split-DockerCustomParams -Text $CustomParams) }

    $volOut = ''
    $volSyn = ''
    if ($UseVolumes) {
        # Volume names include the container name (repo + user), so two repos of the
        # same user no longer share one volume (F48).
        $volNames = Get-ImpactVolumeNames -ContainerName $State.ContainerName
        $volOut = $volNames.Output
        $volSyn = $volNames.Synthpop
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

    # Labels that let a reopened GUI find out how this container was started (F01/F04).
    # RepoPath records which repository folder is mounted (F84), same as the GUI does.
    $dockerArgs += @(Get-ImpactContainerLabelArgs -UseVolumes $UseVolumes -OutputDir $OutputDir -SynthpopDir $SynthpopDir -VolumeOutput $volOut -VolumeSynthpop $volSyn -RepoPath $ProjectRoot)

    # Only the private key is mounted from the host. The github.com host key is
    # written inside the container by Get-ContainerSshSetupCommand, so the
    # container does not depend on the host's known_hosts file.
    $dockerArgs += @('--mount',"type=bind,source=$SshKeyPath,target=/keys/id_ed25519_$($State.UserName),readonly",
                     '--workdir',"/home/rstudio/$($State.SelectedRepo)",
                     $ImageName)

    return $dockerArgs
}

# ══════════════════════════════════════════════════════════════════════════════
#  Docker volume helpers (used by the Start and Stop buttons of the GUI)
# ══════════════════════════════════════════════════════════════════════════════

<#
.SYNOPSIS Names of the two Docker volumes used in 'Use Docker Volumes' mode.
.DESCRIPTION The names contain the container name, which is "<repo>_<user>". Older
             versions used only the user name, so two repositories of the same user
             shared (and mixed) one pair of volumes (F48). Characters Docker does not
             allow in volume names are replaced by '_'.
#>
function Get-ImpactVolumeNames {
    param([string]$ContainerName)
    $safe = $ContainerName -replace '[^a-zA-Z0-9_.-]','_'
    return [pscustomobject]@{
        Output   = "impactncd_output_$safe"
        Synthpop = "impactncd_synthpop_$safe"
    }
}

<#
.SYNOPSIS Splits the 'Custom Params' text box into separate docker arguments.
.DESCRIPTION Works like a simple shell: whitespace separates arguments, and text in
             single or double quotes stays together (the quotes are removed). Empty
             arguments are never produced. Backslashes are kept as they are, so
             Windows paths survive. Splitting on spaces alone (the old behaviour)
             produced empty arguments, which docker then took as the image name, and
             cut quoted values in half (F102).
#>
function Split-DockerCustomParams {
    param([string]$Text)
    $tokens = New-Object System.Collections.Generic.List[string]
    if ([string]::IsNullOrWhiteSpace($Text)) { return }
    $current = New-Object System.Text.StringBuilder
    $inToken = $false
    $quote = [char]0
    foreach ($ch in $Text.ToCharArray()) {
        if ($quote -ne [char]0) {
            # Inside quotes: everything up to the matching quote belongs to the token.
            if ($ch -eq $quote) { $quote = [char]0 } else { [void]$current.Append($ch) }
            continue
        }
        if ($ch -eq [char]'"' -or $ch -eq [char]"'") { $quote = $ch; $inToken = $true; continue }
        if ([char]::IsWhiteSpace($ch)) {
            if ($inToken) { $tokens.Add($current.ToString()); [void]$current.Clear(); $inToken = $false }
            continue
        }
        [void]$current.Append($ch)
        $inToken = $true
    }
    # A missing closing quote is forgiven: the rest of the text becomes the last token.
    if ($inToken) { $tokens.Add($current.ToString()) }
    return $tokens.ToArray()
}

<#
.SYNOPSIS The '--label' arguments that record how a container was started.
.DESCRIPTION Docker keeps labels with the container, so they can be read back with
             'docker inspect' after the GUI was closed and reopened, both for LOCAL
             and REMOTE containers. Get-ContainerRuntimeInfo reads them. Without them
             a resumed session did not know where to copy results back to, and Stop
             deleted the volumes anyway (F01/F04).
             impact.repo_path records the repository folder that is mounted into the
             container (F84). A running container is found by NAME only, so a second
             clone with the same folder name elsewhere looked like the same repository,
             and Stop then checked git changes in the wrong folder. With this label the
             GUI can tell the two apart when it reconnects to a running container.
#>
function Get-ImpactContainerLabelArgs {
    param(
        [bool]$UseVolumes,
        [string]$OutputDir,
        [string]$SynthpopDir,
        [string]$VolumeOutput,
        [string]$VolumeSynthpop,
        # Optional: the repository folder mounted into the container (F84).
        [string]$RepoPath
    )
    $labelArgs = @('--label', ("impact.use_volumes=" + $(if ($UseVolumes) { 'true' } else { 'false' })))
    if ($RepoPath)    { $labelArgs += @('--label', "impact.repo_path=$RepoPath") }
    if ($OutputDir)   { $labelArgs += @('--label', "impact.output_dir=$OutputDir") }
    if ($SynthpopDir) { $labelArgs += @('--label', "impact.synthpop_dir=$SynthpopDir") }
    if ($UseVolumes -and $VolumeOutput)   { $labelArgs += @('--label', "impact.volume_output=$VolumeOutput") }
    if ($UseVolumes -and $VolumeSynthpop) { $labelArgs += @('--label', "impact.volume_synthpop=$VolumeSynthpop") }
    return $labelArgs
}

<#
.SYNOPSIS Looks up one Docker volume.
.OUTPUTS  Object with Exists ($true, $false, or $null when Docker could not be asked),
          TargetDir (host folder recorded when the volume was created, may be $null),
          UsedBy (names of containers, running or stopped, that still use it) and Error.
#>
function Get-ImpactVolumeInfo {
    param([pscustomobject]$State, [string]$VolumeName)
    $result = [pscustomobject]@{ Name = $VolumeName; Exists = $null; TargetDir = $null; UsedBy = @(); Error = '' }
    $ctx = Get-DockerContextArgs -State $State
    try {
        $out = & docker @ctx @('volume','inspect','--format','{{json .Labels}}',$VolumeName) 2>&1
        $code = $LASTEXITCODE
        $text = (@($out) | ForEach-Object { "$_" }) -join ' '
        if ($code -ne 0) {
            # "No such volume" is the normal answer for a volume that does not exist.
            # Anything else (Docker not running, ssh dropped) means we do not know.
            if ($text -match '(?i)no such volume') { $result.Exists = $false }
            else { $result.Error = $text }
            return $result
        }
        $result.Exists = $true
        $json = (@($out) | Where-Object { $_ -is [string] }) -join ''
        if ($json -and $json.Trim() -ne 'null') {
            $labels = $json | ConvertFrom-Json -AsHashtable
            if ($labels -and $labels['impact.target_dir']) { $result.TargetDir = [string]$labels['impact.target_dir'] }
        }
        $users = & docker @ctx @('ps','-a','--filter',"volume=$VolumeName",'--format','{{.Names}}') 2>$null
        $result.UsedBy = @($users | Where-Object { $_ -match '\S' } | ForEach-Object { "$_".Trim() })
    } catch {
        $result.Exists = $null
        $result.Error = $_.Exception.Message
    }
    return $result
}

<#
.SYNOPSIS Makes sure the small 'rsync-alpine' helper image exists (builds it if not).
.DESCRIPTION The image is used to copy results out of the Docker volumes. Returns
             $true only when the image really exists afterwards: the old code never
             checked the build, so a failed download only showed up hours later at
             Stop (F17). The Dockerfile is passed on stdin with '-' as build context,
             so no local folder is uploaded (over ssh in remote mode).
#>
function Initialize-RsyncHelperImage {
    param([pscustomobject]$State)
    $ctx = Get-DockerContextArgs -State $State
    & docker @ctx @('image','inspect','rsync-alpine') 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) { return $true }
    Write-Log 'rsync-alpine helper image not found; building it (needs internet access to Docker Hub).' 'Info'
    $dockerfileInline = "FROM alpine:latest`nRUN apk add --no-cache rsync"
    try {
        $buildOut = $dockerfileInline | & docker @ctx @('build','-t','rsync-alpine','-') 2>&1
        Write-Log ("rsync-alpine build finished (exit {0}): {1}" -f $LASTEXITCODE, ((@($buildOut) | Select-Object -Last 5) -join ' | ')) 'Debug'
    } catch {
        Write-Log "rsync-alpine build failed: $($_.Exception.Message)" 'Warn'
    }
    # Check again instead of trusting the build's exit code alone.
    & docker @ctx @('image','inspect','rsync-alpine') 2>$null | Out-Null
    return ($LASTEXITCODE -eq 0)
}

<#
.SYNOPSIS Copies the contents of one Docker volume into a host folder with rsync.
.DESCRIPTION Returns an object with Success, Missing (the volume does not exist, so
             there was nothing to copy) and Message. It never deletes anything; the
             caller removes a volume only after Success is $true for it (F01). An empty
             target folder is refused, because docker would otherwise get an invalid
             mount like ':/backup' (this is what happened in resumed sessions).
             A target folder that does not exist (renamed, moved, a drive that is not
             connected) is refused too, so the caller keeps the volume (B3-R4).
.PARAMETER KeepNewerOnHost
             Do not overwrite a file in the target folder that is NEWER than the copy in
             the volume (rsync --update). Used when copying volumes left over from an
             earlier session: since then, newer results may have been written straight
             into the folder, and the old volume copy must not replace them (B3-R1).
#>
function Sync-ImpactVolumeToHost {
    param([pscustomobject]$State, [string]$VolumeName, [string]$HostDir, [switch]$KeepNewerOnHost)
    $result = [pscustomobject]@{ Success = $false; Missing = $false; Message = '' }
    if ([string]::IsNullOrWhiteSpace($VolumeName) -or [string]::IsNullOrWhiteSpace($HostDir)) {
        $result.Message = "Cannot copy volume '$VolumeName': the folder to copy it to is unknown."
        return $result
    }
    $vol = Get-ImpactVolumeInfo -State $State -VolumeName $VolumeName
    if ($vol.Exists -eq $false) {
        $result.Success = $true
        $result.Missing = $true
        $result.Message = "Volume '$VolumeName' does not exist; nothing to copy."
        return $result
    }
    if ($null -eq $vol.Exists) {
        $result.Message = "Could not check volume '$VolumeName': $($vol.Error)"
        return $result
    }
    if (-not (Initialize-RsyncHelperImage -State $State)) {
        $result.Message = "The rsync-alpine helper image is missing and could not be built (no internet access to Docker Hub?)."
        return $result
    }
    $ctx = Get-DockerContextArgs -State $State
    $backup = if ($State.ContainerLocation -eq 'LOCAL') { Convert-PathToDockerFormat -Path $HostDir } else { $HostDir }
    Write-Log "Copying volume $VolumeName back to $backup" 'Info'
    # Same rsync options as before; only '-v' was dropped to keep the log small.
    $rsyncArgs = @('rsync','-ac','--no-owner','--no-group','--no-times','--no-perms','--chmod=ugo=rwX')
    if ($KeepNewerOnHost) { $rsyncArgs += '--update' }
    $rsyncArgs += @('/volume/','/backup/')
    try {
        # The target folder is mounted with '--mount' instead of '-v' (B3-R4): for '-v'
        # Docker silently CREATES a missing host folder (on the workstation even owned by
        # root), so a copy to a folder that no longer exists "succeeded" into a new, empty
        # folder and the caller then deleted the volume. '--mount' refuses a missing folder.
        $out = & docker @ctx (@('run','--rm','-v',"$($VolumeName):/volume",'--mount',"type=bind,source=$backup,target=/backup",'rsync-alpine') + $rsyncArgs) 2>&1
        $code = $LASTEXITCODE
    } catch {
        $out = $_.Exception.Message
        $code = -1
    }
    if ($code -eq 0) {
        $result.Success = $true
        $result.Message = "Copied volume '$VolumeName' to $HostDir."
    } else {
        $tail = (@($out) | ForEach-Object { "$_" } | Select-Object -Last 5) -join ' '
        if ($tail -match 'bind source path does not exist') {
            # Plain-language version of Docker's mount error (see '--mount' above).
            $result.Message = "The folder '$HostDir' does not exist (it may have been renamed or moved, or it is on a drive that is not connected), so volume '$VolumeName' was not copied."
        } else {
            $result.Message = "Copying volume '$VolumeName' to $HostDir failed (exit $code): $tail"
        }
        Write-Log "$($result.Message) Docker said: $tail" 'Error'
    }
    return $result
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
        $accountLogin = $null
        if ($response -is [System.Collections.IDictionary]) {
            if ($response.Contains('type')) { $accountType = [string]$response['type'] }
            if ($response.Contains('login')) { $accountLogin = [string]$response['login'] }
        } elseif ($null -ne $response -and $response.PSObject.Properties['type']) {
            $accountType = [string]$response.type
        }
        if ($null -ne $response -and $response -isnot [System.Collections.IDictionary] -and $response.PSObject.Properties['login']) {
            $accountLogin = [string]$response.login
        }
        if (-not $accountLogin) {
            # B6a-R6: a real GitHub answer for an account always has 'login'. A proxy, a
            # firewall or a Wi-Fi login page can answer with HTTP 200 and an HTML page
            # instead; that must not count as "the user exists", or every typo would be
            # accepted without the "could not check" question.
            $status = 'Unknown'
            $message = 'GitHub returned an unexpected answer (a proxy or firewall may be blocking github.com).'
            Write-Log "GitHub username check for '$UserName' got an answer without a 'login' field; treating it as unknown." 'Warn'
        } elseif ($accountType -eq 'Organization') {
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
    # Safe quoting of paths inside commands run by the workstation's shell (the GUI's
    # Start button uses it for its remote YAML check and remote image build).
    'ConvertTo-PosixShellLiteral'
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
    'Get-DockerfileBaseImage'
    'Get-ContainerGitSshCommand'
    'Get-ContainerSshSetupCommand'
    # Docker volume helpers
    'Get-ImpactVolumeNames'
    'Split-DockerCustomParams'
    'Get-ImpactContainerLabelArgs'
    'Get-ImpactVolumeInfo'
    'Initialize-RsyncHelperImage'
    'Sync-ImpactVolumeToHost'
    'Test-DockerDaemonReady'
    'Start-DockerDesktopIfNeeded'
    # GitHub SSH key API
    'Add-GitHubSshKey'
    'Remove-GitHubSshKey'
    # GitHub username validation
    'Test-GitHubUsername'
)
