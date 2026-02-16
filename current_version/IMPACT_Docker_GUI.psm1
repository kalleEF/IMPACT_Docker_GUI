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
    $version = '2.0.0'
    $built = (Get-Date).ToString('s')
    $commit = $null
    $dirty = $false

    try {
        $git = Get-Command git -ErrorAction SilentlyContinue
        if ($git) {
            $scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { $PWD.Path }
            if ($scriptDir) { Push-Location $scriptDir }
            try {
                $commit = git rev-parse --short HEAD 2>$null
                $status = git status --porcelain 2>$null
                if ($status) { $dirty = $true }
            } catch { }
            if ($scriptDir) { Pop-Location }
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
function Ensure-PowerShell7 {
    param([bool]$PS7RequestedFlag = $false)

    $isCore = $PSVersionTable.PSEdition -eq 'Core'
    $isSevenPlus = $isCore -and $PSVersionTable.PSVersion.Major -ge 7
    if ($isSevenPlus) { return }

    $pwsh = Get-Command pwsh -ErrorAction SilentlyContinue
    if ($pwsh) {
        Write-Log 'PowerShell 7 is required. Restarting under pwsh...' 'Warn'
        $invokedPath = $null
        try { $invokedPath = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName } catch { }
        if (-not $invokedPath) { $invokedPath = $MyInvocation.MyCommand.Path }
        if (-not $invokedPath) {
            $candidate = [Environment]::GetCommandLineArgs() | Select-Object -First 1
            if ($candidate -and $candidate -notmatch '\r|\n') { $invokedPath = $candidate }
        }
        if (-not $invokedPath) {
            $candidate = $MyInvocation.MyCommand.Definition
            if ($candidate -and $candidate -notmatch '\r|\n') { $invokedPath = $candidate }
        }
        if ($invokedPath) { try { $invokedPath = [System.IO.Path]::GetFullPath($invokedPath) } catch { Write-Log "Could not normalize invoked path: $invokedPath" 'Warn' } }

        # $PSCommandPath inside a .psm1 module points to the module file itself,
        # NOT the calling launcher script. Skip it if it ends in .psm1.
        $scriptPath = $PSCommandPath
        if ($scriptPath -and $scriptPath -match '\.psm1$') {
            Write-Log "Ignoring PSCommandPath ($scriptPath) because it points to the module, not the launcher." 'Debug'
            $scriptPath = $null
        }
        if (-not $scriptPath -and $invokedPath -match '\.exe$') {
            $candidate = [System.IO.Path]::ChangeExtension($invokedPath, '.ps1')
            if (Test-Path $candidate) { $scriptPath = $candidate }
        }
        if (-not $scriptPath -and $invokedPath) {
            $exeDir = Split-Path -Parent $invokedPath
            $fallback = Join-Path $exeDir 'IMPACT_Docker_GUI_v2.ps1'
            if (Test-Path $fallback) { $scriptPath = $fallback }
        }
        if ($scriptPath) { try { $scriptPath = [System.IO.Path]::GetFullPath($scriptPath) } catch { Write-Log "Could not normalize script path: $scriptPath" 'Warn' } }

        if (-not $invokedPath -and -not $scriptPath) {
            Write-Log 'Cannot determine executable or script path; aborting PS7 relaunch.' 'Error'
            throw 'Unable to relaunch under pwsh (no path).'
        }

        $args = @('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass')
        if ($scriptPath -and (Test-Path $scriptPath)) {
            $args += '-File'
            $args += "`"$scriptPath`""
            Write-Log "Relaunching under pwsh with script: $scriptPath" 'Info'
        } else {
            $args += '-Command'
            $args += "& '" + $invokedPath + "'"
            Write-Log "Relaunching under pwsh by invoking: $invokedPath" 'Info'
        }

        if (-not $PS7RequestedFlag) { $args += '-PS7Requested' }

        Start-Process -FilePath $pwsh.Source -ArgumentList $args -WorkingDirectory $PWD.Path -NoNewWindow -Wait | Out-Null
        exit
    }

    if (-not $script:NonInteractive) {
        try { Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue } catch { }
        try { [System.Windows.Forms.MessageBox]::Show('PowerShell 7 (pwsh) is required. Please install PowerShell 7 and try again.','PowerShell 7 required','OK','Error') | Out-Null } catch { }
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
        if (-not $env:DOCKER_SSH_OPTS -or [string]::IsNullOrEmpty($env:DOCKER_SSH_OPTS)) {
            $keyPath = $State.Paths.SshPrivate
            if (-not $keyPath) { $keyPath = "$HOME/.ssh/id_ed25519_$($State.UserName)" }
            $env:DOCKER_SSH_OPTS = "-i `"$keyPath`" -o IdentitiesOnly=yes -o ConnectTimeout=30"
            Write-Log "Prepared DOCKER_SSH_OPTS for remote Docker access." 'Info'
        }
        if ($State.Flags.UseDirectSsh) {
            $remoteHost = Get-RemoteHostString -State $State
            if (-not $env:DOCKER_HOST -or $env:DOCKER_HOST -notmatch 'ssh://') {
                $env:DOCKER_HOST = "ssh://$remoteHost"
                Write-Log "Using direct SSH Docker host at $remoteHost" 'Info'
            }
            Write-Log "Direct SSH Docker mode active; DOCKER_HOST=$env:DOCKER_HOST" 'Debug'
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
    param([pscustomobject]$State)
    if ($State.ContainerLocation -notlike 'REMOTE@*') { return $true }
    $remoteHost = Get-RemoteHostString -State $State
    Write-Log "Checking remote SSH key and known_hosts on $remoteHost" 'Info'
    $localKeyPath = $State.Paths.SshPrivate
    $remoteKeyPath = "/home/$($State.RemoteUser)/.ssh/id_ed25519_$($State.UserName)"
    $knownHosts = "/home/$($State.RemoteUser)/.ssh/known_hosts"
    try {
        $keyCheck = & ssh -i $localKeyPath -o IdentitiesOnly=yes -o ConnectTimeout=10 -o BatchMode=yes $remoteHost "[ -f '$remoteKeyPath' ] && echo OK" 2>$null
        $khCheck  = & ssh -i $localKeyPath -o IdentitiesOnly=yes -o ConnectTimeout=10 -o BatchMode=yes $remoteHost "[ -f '$knownHosts' ] && echo OK" 2>$null
        $present = ($keyCheck -match 'OK' -and $khCheck -match 'OK')
        Write-Log "Remote SSH check raw outputs -> key:'$keyCheck' kh:'$khCheck'" 'Debug'
        Write-Log ("Remote SSH prerequisites present: key={0} known_hosts={1}" -f ($keyCheck -match 'OK'), ($khCheck -match 'OK')) 'Info'
        return $present
    } catch {
        Write-Log "Remote SSH prerequisite check failed: $($_.Exception.Message)" 'Debug'
        return $false
    }
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
        & ssh -i $keyPath -o IdentitiesOnly=yes -o ConnectTimeout=10 -o BatchMode=yes $remoteHost "mkdir -p /tmp/impactncd && umask 177 && echo $b64 | base64 -d > '$metaPath'" 2>$null
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
    try { & ssh -i $keyPath -o IdentitiesOnly=yes -o ConnectTimeout=10 -o BatchMode=yes $remoteHost "rm -f '$metaPath'" 2>$null } catch {
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
        $json = & ssh -i $keyPath -o IdentitiesOnly=yes -o ConnectTimeout=10 -o BatchMode=yes $remoteHost "cat '$metaPath' 2>/dev/null" 2>$null
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
        try {
            $content = & ssh -i $keyPath -o IdentitiesOnly=yes -o ConnectTimeout=30 -o BatchMode=yes $remoteHost "cat '$YamlPath'" 2>$null
        } catch { return $null }
    } else {
        if (-not (Test-Path $YamlPath)) { return $null }
        $content = Get-Content -Path $YamlPath -Raw
    }

    Write-Log ("Fetched YAML content length: {0}" -f ($content.Length)) 'Debug'
    if (-not $content) { Write-Log 'YAML content empty; aborting parse.' 'Debug'; return $null }
    $line = ($content -split "`n") | Where-Object { $_ -match "^$Key\s*:" } | Select-Object -First 1
    if (-not $line) { Write-Log "YAML key '$Key' not found." 'Debug'; return $null }
    $value = ($line -split ":\s*",2)[1].Split('#')[0].Trim()
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
        [string]$PathKey
    )
    if (-not $Path) { return $false }

    Write-Log "Ensuring directory for ${PathKey}: $Path" 'Info'

    if ($State.ContainerLocation -like 'REMOTE@*') {
        $remoteHost = Get-RemoteHostString -State $State
        $keyPath = $State.Paths.SshPrivate
        try {
            $check = & ssh -i $keyPath -o IdentitiesOnly=yes -o ConnectTimeout=15 -o BatchMode=yes $remoteHost "test -d '$Path' && echo EXISTS || echo MISSING" 2>$null
            if ($check -notmatch 'EXISTS') {
                Write-Log "Remote path missing (no auto-create): $Path" 'Error'
                return $false
            }
            Write-Log "Remote path verified for ${PathKey}: $Path" 'Debug'
            return $true
        } catch {
            Write-Log "Failed to validate remote directory ${Path}: $($_.Exception.Message)" 'Debug'
            return $false
        }
    }

    if ($State.ContainerLocation -eq 'LOCAL' -and $Path -match '^(?:/|~)') {
        Write-Log "POSIX-style path not allowed in local mode for ${PathKey}: $Path" 'Error'
        return $false
    }

    if ($State.ContainerLocation -eq 'LOCAL') {
        try {
            $resolved = Resolve-Path -LiteralPath $Path -ErrorAction Stop
            $native = $resolved.Path
        } catch {
            Write-Log "Local path missing or not a directory (no auto-create): $Path" 'Error'
            return $false
        }
    } else {
        $native = $Path
    }

    if (-not (Test-Path $native -PathType Container)) {
        Write-Log "Local path missing or not a directory (no auto-create): $native" 'Error'
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
            $out = & ssh -i $keyPath -o IdentitiesOnly=yes -o ConnectTimeout=20 -o BatchMode=yes $remoteHost $cmd 2>$null
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
            $remoteUrl = & ssh -i $keyPath -o IdentitiesOnly=yes -o BatchMode=yes $remoteHost "cd '$RepoPath' && git remote get-url origin" 2>$null
            if ($remoteUrl -and $remoteUrl -match '^https://github.com/(.+)$') {
                $sshUrl = "git@github.com:$($matches[1])"
                & ssh -i $keyPath -o IdentitiesOnly=yes -o BatchMode=yes $remoteHost "cd '$RepoPath' && git remote set-url origin '$sshUrl'" 2>$null
            }
            $commitCmd = "cd '$RepoPath' && git add -A && git commit -m `"$safeMsg`""
            $commitOut = & ssh -i $keyPath -o IdentitiesOnly=yes -o BatchMode=yes $remoteHost $commitCmd 2>&1
            Write-Log "Remote git commit exit=$LASTEXITCODE output=$commitOut" 'Debug'
            if ($LASTEXITCODE -ne 0 -and $commitOut -notmatch 'nothing to commit') {
                if (-not $script:NonInteractive) { [System.Windows.Forms.MessageBox]::Show("Git commit failed on remote: $commitOut",'Git commit failed','OK','Error') | Out-Null }
                return
            }
            if ($LASTEXITCODE -eq 0) { Write-Log 'Git commit completed on remote.' 'Info' }
            if ($doPush) {
                $remoteKey = "~/.ssh/id_ed25519_$($State.UserName)"
                $pushAgent = "cd '$RepoPath' && eval `$(ssh-agent -s) && ssh-add $remoteKey 2>/dev/null && GIT_SSH_COMMAND='ssh -i $remoteKey -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new' git push"
                $pushOut = & ssh -i $keyPath -o IdentitiesOnly=yes -o BatchMode=yes $remoteHost $pushAgent 2>&1
                Write-Log "Remote git push (agent) exit=$LASTEXITCODE output=$pushOut" 'Debug'
                if ($LASTEXITCODE -ne 0) {
                    $pushDirect = "cd '$RepoPath' && GIT_SSH_COMMAND='ssh -i $remoteKey -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new' git push"
                    $pushOut = & ssh -i $keyPath -o IdentitiesOnly=yes -o BatchMode=yes $remoteHost $pushDirect 2>&1
                    Write-Log "Remote git push (direct) exit=$LASTEXITCODE output=$pushOut" 'Debug'
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
            [System.Windows.Forms.MessageBox]::Show('Docker CLI not found.`n`nInstall Docker Desktop (Windows) and ensure "docker" is on PATH, then retry.','Docker missing','OK','Error') | Out-Null
        }
        return $false
    }
    Write-Log "Docker CLI found at $($dockerCmd.Source)." 'Debug'

    $sshCmd = Get-Command ssh -ErrorAction SilentlyContinue
    if (-not $sshCmd) {
        Write-Log 'OpenSSH client not found on PATH. Attempting auto-install.' 'Warn'
        $installAttempted = $false
        try {
            $cap = Get-WindowsCapability -Online -Name 'OpenSSH.Client*' -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($cap -and $cap.State -ne 'Installed' -and -not $script:NonInteractive) {
                $installChoice = [System.Windows.Forms.MessageBox]::Show(
                    "The OpenSSH Client is not installed on this machine.`n`nThe tool needs ssh, ssh-keygen, and ssh-agent to function.`n`nInstall it now? (requires Administrator - a UAC prompt will appear)",
                    'Install OpenSSH Client?',
                    [System.Windows.Forms.MessageBoxButtons]::YesNo,
                    [System.Windows.Forms.MessageBoxIcon]::Question)
                if ($installChoice -eq [System.Windows.Forms.DialogResult]::Yes) {
                    Write-Log 'User agreed to install OpenSSH Client. Launching elevated install.' 'Info'
                    $capName = $cap.Name
                    $elevatedCmd = "Add-WindowsCapability -Online -Name '$capName' -ErrorAction Stop"
                    $pwshPath = if (Get-Command pwsh -ErrorAction SilentlyContinue) { 'pwsh' } else { 'powershell' }
                    $proc = Start-Process $pwshPath -ArgumentList '-NoProfile','-NoLogo','-Command',$elevatedCmd -Verb RunAs -Wait -PassThru -ErrorAction Stop
                    $installAttempted = $true
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
            Write-Log "OpenSSH auto-install failed: $($_.Exception.Message)" 'Warn'
        }

        $sshCmd = Get-Command ssh -ErrorAction SilentlyContinue
        if (-not $sshCmd) {
            $manualMsg = "OpenSSH Client (ssh) is required but not installed."
            Write-Log 'OpenSSH client still not found after install attempt.' 'Error'
            if (-not $script:NonInteractive) {
                $fullMsg = $manualMsg + "`n`nTo install manually, run this in an Administrator PowerShell:`n`n  Add-WindowsCapability -Online -Name OpenSSH.Client~~~~0.0.1.0`n`nThen restart this tool."
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

    return $true
}

# ══════════════════════════════════════════════════════════════════════════════
#  Credential Dialog
# ══════════════════════════════════════════════════════════════════════════════
function Show-CredentialDialog {
    param([pscustomobject]$State)

    # NonInteractive: expect UserName and Password to be pre-set on State
    if ($script:NonInteractive) {
        Write-Log 'NonInteractive: using pre-set credentials from State.' 'Info'
        if (-not $State.UserName -or -not $State.Password) {
            Write-Log 'NonInteractive: UserName/Password not pre-set on state.' 'Error'
            return $false
        }
        $State.UserName = ($State.UserName -replace '\s+', '').ToLower()
        return $true
    }

    Write-Log 'Collecting credentials - opening dialog.' 'Info'

    $form = New-Object System.Windows.Forms.Form -Property @{
        Text = 'Remote Access - IMPACT NCD Germany'
        Size = New-Object System.Drawing.Size(540,320)
        StartPosition = 'CenterScreen'
        FormBorderStyle = 'FixedDialog'
        MaximizeBox = $false
    }
    Set-FormCenterOnCurrentScreen -Form $form
    Apply-ThemeToForm -Form $form

    $rtbInstruction = New-Object System.Windows.Forms.RichTextBox -Property @{
        Location = New-Object System.Drawing.Point(14,12)
        Size = New-Object System.Drawing.Size(500,130)
        Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Regular)
        ReadOnly = $true
        BorderStyle = 'None'
        BackColor = $form.BackColor
        ScrollBars = 'None'
    }
    $rtbInstruction.SelectionFont = New-Object System.Drawing.Font('Microsoft Sans Serif', 9, [System.Drawing.FontStyle]::Bold)
    $rtbInstruction.AppendText('Please enter a username and a password!')
    $rtbInstruction.AppendText("`n`n")
    $rtbInstruction.SelectionFont = New-Object System.Drawing.Font('Microsoft Sans Serif', 9, [System.Drawing.FontStyle]::Bold)
    $rtbInstruction.SelectionColor = [System.Drawing.Color]::DarkRed
    $rtbInstruction.AppendText('Important:')
    $rtbInstruction.SelectionColor = [System.Drawing.Color]::Black
    $rtbInstruction.SelectionFont = New-Object System.Drawing.Font('Microsoft Sans Serif', 9, [System.Drawing.FontStyle]::Regular)
    $rtbInstruction.AppendText("`nThe username will be used for an SSH key and for container management.`nThe password will be used to login to your RStudio Server session.`n`n")
    $rtbInstruction.SelectionFont = New-Object System.Drawing.Font('Microsoft Sans Serif', 8, [System.Drawing.FontStyle]::Regular)
    $rtbInstruction.SelectionColor = [System.Drawing.Color]::DarkGray
    $rtbInstruction.AppendText('(Username will be normalized: spaces removed, lowercase)')
    Style-InfoBox -Box $rtbInstruction
    $form.Controls.Add($rtbInstruction)

    $labelUser = New-Object System.Windows.Forms.Label -Property @{ Text = 'Username'; Location = New-Object System.Drawing.Point(14,150); Size = New-Object System.Drawing.Size(100,22) }
    Style-Label -Label $labelUser -Style ([System.Drawing.FontStyle]::Bold)
    $form.Controls.Add($labelUser)
    $textUser = New-Object System.Windows.Forms.TextBox -Property @{ Location = New-Object System.Drawing.Point(120,148); Size = New-Object System.Drawing.Size(360,26) }
    Style-TextBox -TextBox $textUser
    $form.Controls.Add($textUser)

    $labelPass = New-Object System.Windows.Forms.Label -Property @{ Text = 'Password'; Location = New-Object System.Drawing.Point(14,185); Size = New-Object System.Drawing.Size(100,22) }
    Style-Label -Label $labelPass -Style ([System.Drawing.FontStyle]::Bold)
    $form.Controls.Add($labelPass)
    $textPass = New-Object System.Windows.Forms.TextBox -Property @{ Location = New-Object System.Drawing.Point(120,183); Size = New-Object System.Drawing.Size(360,26); UseSystemPasswordChar = $true }
    Style-TextBox -TextBox $textPass
    $form.Controls.Add($textPass)

    $buttonOK = New-Object System.Windows.Forms.Button -Property @{ Text = 'Continue'; Location = New-Object System.Drawing.Point(120,228); Size = New-Object System.Drawing.Size(110,34) }
    Style-Button -Button $buttonOK -Variant 'primary'
    $form.Controls.Add($buttonOK)

    $buttonCancel = New-Object System.Windows.Forms.Button -Property @{ Text = 'Cancel'; Location = New-Object System.Drawing.Point(240,228); Size = New-Object System.Drawing.Size(110,34); DialogResult = [System.Windows.Forms.DialogResult]::Cancel }
    Style-Button -Button $buttonCancel -Variant 'secondary'
    $form.Controls.Add($buttonCancel)

    $form.AcceptButton = $buttonOK
    $form.CancelButton = $buttonCancel
    $form.Add_Shown({ $textUser.Focus() })

    $buttonOK.Add_Click({
        if ([string]::IsNullOrWhiteSpace($textUser.Text)) {
            [System.Windows.Forms.MessageBox]::Show('Please enter a username.', 'Error', 'OK', 'Error') | Out-Null
            $textUser.Focus()
            return
        }
        if ([string]::IsNullOrWhiteSpace($textPass.Text)) {
            [System.Windows.Forms.MessageBox]::Show('Please enter a password.', 'Error', 'OK', 'Error') | Out-Null
            $textPass.Focus()
            return
        }
        $form.DialogResult = [System.Windows.Forms.DialogResult]::OK
        $form.Close()
    })

    $result = $form.ShowDialog()
    Write-Log "Credential dialog result: $result" 'Debug'
    if ($result -ne [System.Windows.Forms.DialogResult]::OK) {
        Write-Log 'User cancelled the credential dialog.' 'Warn'
        return $false
    }

    $originalUsername = $textUser.Text.Trim()
    $normalizedUsername = ($originalUsername -replace '\s+', '').ToLower()
    if ([string]::IsNullOrWhiteSpace($normalizedUsername)) {
        [System.Windows.Forms.MessageBox]::Show('Username cannot be empty after removing spaces.', 'Invalid Username', 'OK', 'Error') | Out-Null
        Write-Log 'Username empty after normalization; aborting.' 'Error'
        return $false
    }

    $State.UserName = $normalizedUsername
    $State.Password = $textPass.Text

    Write-Log "Credentials collected for user $($State.UserName)" 'Info'
    return $true
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
        & ssh-keygen @sshKeyGenArgs
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
            return $false
        }
        if ($State.ContainerLocation -like 'REMOTE@*') {
            if (-not $State.RemoteHostIp) {
                Write-Log 'NonInteractive: RemoteHostIp not pre-set for remote mode.' 'Error'
                return $false
            }
            $State.RemoteHost = "$($State.RemoteUser)@$($State.RemoteHostIp)"
            $State.RemoteRepoBase = if ($State.RemoteRepoBase) { $State.RemoteRepoBase } else { "/home/$($State.RemoteUser)/Schreibtisch/Repositories" }
        } else {
            $State.RemoteRepoBase = "/home/$($State.RemoteUser)/Schreibtisch/Repositories"
        }
        return $true
    }

    Write-Log 'Opening container location selection dialog.' 'Info'

    $formConnection = New-Object System.Windows.Forms.Form -Property @{
        Text = 'Container Location - IMPACT NCD Germany'
        Size = New-Object System.Drawing.Size(480,260)
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
        return $true
    }

    Write-Log 'No container location selected.' 'Warn'
    return $false
}

# ══════════════════════════════════════════════════════════════════════════════
#  Container lifecycle - EXTRACTED from Show-ContainerManager event handlers
# ══════════════════════════════════════════════════════════════════════════════

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
        [string]$KnownHostsPath
    )

    $repoMountSource = if ($State.ContainerLocation -eq 'LOCAL') { Convert-PathToDockerFormat -Path $ProjectRoot } else { $ProjectRoot }
    $containerKeyPath = "/home/rstudio/.ssh/id_ed25519_$($State.UserName)"

    $dockerArgs = @('run','-d','--rm','--name',$State.ContainerName,
        '-e',"PASSWORD=$($State.Password)",
        '-e','DISABLE_AUTH=false',
        '-e','USERID=1000','-e','GROUPID=1000',
        '-e',"GIT_SSH_COMMAND=ssh -i $containerKeyPath -o IdentitiesOnly=yes -o UserKnownHostsFile=/etc/ssh/ssh_known_hosts -o StrictHostKeyChecking=yes",
        '--mount',"type=bind,source=$repoMountSource,target=/host-repo",
        '--mount',"type=bind,source=$repoMountSource,target=/home/rstudio/$($State.SelectedRepo)",
        '-e','REPO_SYNC_PATH=/host-repo','-e','SYNC_ENABLED=true',
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

    $dockerArgs += @('--mount',"type=bind,source=$SshKeyPath,target=/keys/id_ed25519_$($State.UserName),readonly",
                     '--mount',"type=bind,source=$KnownHostsPath,target=/etc/ssh/ssh_known_hosts,readonly",
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
    'Convert-PathToDockerFormat'
    # Remote SSH
    'Test-RemoteSSHKeyFiles'
    'Write-RemoteContainerMetadata'
    'Remove-RemoteContainerMetadata'
    'Read-RemoteContainerMetadata'
    'Get-ContainerRuntimeInfo'
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
    'Build-DockerRunCommand'
    'Test-DockerDaemonReady'
    'Start-DockerDesktopIfNeeded'
    # GitHub SSH key API
    'Add-GitHubSshKey'
    'Remove-GitHubSshKey'
)
