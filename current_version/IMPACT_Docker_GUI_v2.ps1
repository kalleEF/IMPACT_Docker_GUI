<# IMPACT Docker GUI v2 #>

[CmdletBinding()]
param(
    [switch]$ElevatedRestart,
    [switch]$PS7Requested
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:GlobalDebugFlag = $false
$script:ThemePalette = $null
$script:LogFile = $null
$script:LogInit = $false

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

function Get-BuildInfo {
    $version = '2.0.0'
    $built = (Get-Date).ToString('s')
    $commit = $null
    $dirty = $false

    try {
        $git = Get-Command git -ErrorAction SilentlyContinue
        if ($git) {
            $scriptDir = Split-Path -Parent $PSCommandPath
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
    return [pscustomobject]@{ Version=$version; Built=$built; Commit=$commitTag }
}

# Global/session state container; pass this object between steps.
function New-SessionState {
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

    Write-Log 'Initialized session state.' 'Info'
    Write-Log "State defaults -> RemoteUser=$($state.RemoteUser), PS7Requested=$($state.Flags.PS7Requested), Debug=$($state.Flags.Debug)" 'Debug'
    return $state
}

# Lightweight logging helper; expand to file later.
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

# Ensure the host is PowerShell 7+; restart under pwsh when available, else fail fast.
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
        if (-not $invokedPath) {
            $invokedPath = $MyInvocation.MyCommand.Path
        }
        if (-not $invokedPath) {
            $candidate = [Environment]::GetCommandLineArgs() | Select-Object -First 1
            if ($candidate -and $candidate -notmatch '\r|\n') { $invokedPath = $candidate }
        }
        if (-not $invokedPath) {
            $candidate = $MyInvocation.MyCommand.Definition
            if ($candidate -and $candidate -notmatch '\r|\n') { $invokedPath = $candidate }
        }
        if ($invokedPath) { try { $invokedPath = [System.IO.Path]::GetFullPath($invokedPath) } catch { Write-Log "Could not normalize invoked path: $invokedPath" 'Warn' } }

        $scriptPath = $PSCommandPath
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

        # Stay in the same window to show logs and block until pwsh returns.
        Start-Process -FilePath $pwsh.Source -ArgumentList $args -WorkingDirectory $PWD.Path -NoNewWindow -Wait | Out-Null
        exit
    }

    try { Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue } catch { }
    try { [System.Windows.Forms.MessageBox]::Show('PowerShell 7 (pwsh) is required. Please install PowerShell 7 and try again.','PowerShell 7 required','OK','Error') | Out-Null } catch { }
    Write-Log 'PowerShell 7 (pwsh) is required but not installed.' 'Error'
    throw 'PowerShell 7 (pwsh) is required.'
}

# Build ssh:// target from state
function Get-RemoteHostString {
    param([pscustomobject]$State)
    Write-Log 'Resolving remote host target.' 'Info'
    if ($State.RemoteHost) { return $State.RemoteHost }
    return $State.RemoteHostIp
}

# Ensure Docker SSH opts are populated when targeting remote
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

# Helper to standardize docker context/host arguments based on connection mode
function Get-DockerContextArgs {
    param([pscustomobject]$State)
    Write-Log "Selecting Docker context arguments for $($State.ContainerLocation)" 'Info'
    $result = @()
    if ($State.ContainerLocation -like 'REMOTE@*') {
        if ($State.Flags.UseDirectSsh) {
            $result = @()
        } elseif ($State.Metadata.RemoteDockerContext) {
            $result = @('--context',$State.Metadata.RemoteDockerContext)
        }
    } elseif ($State.ContainerLocation -eq 'LOCAL' -and $State.Metadata.LocalDockerContext) {
        $result = @('--context',$State.Metadata.LocalDockerContext)
    }
    Write-Log "Docker context args: $([string]::Join(' ', $result))" 'Debug'
    return $result
}

# Convert Windows path to Docker/WSL style
function Convert-PathToDockerFormat {
    param([string]$Path)
    Write-Log "Converting path to Docker format: $Path" 'Info'
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

# Verify remote SSH key and known_hosts exist (fast check)
function Test-RemoteSSHKeyFiles {
    param(
        [pscustomobject]$State
    )
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

# Remote container metadata helpers
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
    } catch { }
}

function Remove-RemoteContainerMetadata {
    param([pscustomobject]$State)
    if ($State.ContainerLocation -notlike 'REMOTE@*') { return }
    $remoteHost = Get-RemoteHostString -State $State
    $keyPath = $State.Paths.SshPrivate
    $metaPath = "/tmp/impactncd/$($State.ContainerName).json"
    Write-Log "Removing remote metadata at $metaPath on $remoteHost" 'Info'
    try { & ssh -i $keyPath -o IdentitiesOnly=yes -o ConnectTimeout=10 -o BatchMode=yes $remoteHost "rm -f '$metaPath'" 2>$null } catch { }
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
            # In case multiple bindings are present (e.g., IPv4/IPv6), take the first non-empty entry
            $info.Port = (($portLine -split "`n|`r") | Where-Object { $_ -match '\S' } | Select-Object -First 1).Trim()
        }
        Write-Log "Recovered runtime info -> PasswordPresent=$([bool]$info.Password) Port=$($info.Port)" 'Debug'
    } catch {
        Write-Log "Failed to inspect container runtime info: $($_.Exception.Message)" 'Debug'
    }
    return $info
}

# Read a YAML key value (simple single-line `key: value`) optionally over SSH
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
        } catch {
            return $null
        }
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

# Ensure directory exists locally or remotely
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
            Write-Log "Remote path exists." 'Debug'
            return $true
        } catch {
            Write-Log "Failed to validate remote directory ${Path}: $($_.Exception.Message)" 'Debug'
            return $false
        }
    }

    # In local mode, block POSIX-style absolute paths (likely remote/Linux paths) to avoid fake mounts.
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

# Capture git status and branch info (local or remote)
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

# Show commit dialog and return commit message + push preference
function Show-GitCommitDialog {
    param(
        [string]$ChangesText
    )
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

# Detect changes and optionally commit/push
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
            # Ensure remote origin uses SSH (convert GitHub HTTPS to SSH if needed)
            $remoteUrl = & ssh -i $keyPath -o IdentitiesOnly=yes -o BatchMode=yes $remoteHost "cd '$RepoPath' && git remote get-url origin" 2>$null
            if ($remoteUrl -and $remoteUrl -match '^https://github.com/(.+)$') {
                $sshUrl = "git@github.com:$($matches[1])"
                & ssh -i $keyPath -o IdentitiesOnly=yes -o BatchMode=yes $remoteHost "cd '$RepoPath' && git remote set-url origin '$sshUrl'" 2>$null
            }

            $commitCmd = "cd '$RepoPath' && git add -A && git commit -m `"$safeMsg`""
            $commitOut = & ssh -i $keyPath -o IdentitiesOnly=yes -o BatchMode=yes $remoteHost $commitCmd 2>&1
            Write-Log "Remote git commit exit=$LASTEXITCODE output=$commitOut" 'Debug'
            if ($LASTEXITCODE -ne 0 -and $commitOut -notmatch 'nothing to commit') { [System.Windows.Forms.MessageBox]::Show("Git commit failed on remote: $commitOut",'Git commit failed','OK','Error') | Out-Null; return }
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
                if ($LASTEXITCODE -ne 0) { [System.Windows.Forms.MessageBox]::Show("Git push failed on remote: $pushOut",'Git push failed','OK','Error') | Out-Null }
                else { Write-Log 'Git push completed on remote.' 'Info' }
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
        [System.Windows.Forms.MessageBox]::Show('Git commit/push encountered an error. See console for details.','Git error','OK','Error') | Out-Null
    }
}

# Center a WinForms dialog on the monitor with the current cursor.
function Set-FormCenterOnCurrentScreen {
    param(
        [System.Windows.Forms.Form]$Form
    )
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

# Lightweight theming helpers to keep a consistent visual language across dialogs.
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

function Test-StartupPrerequisites {
    param([pscustomobject]$State)

    $dockerCmd = Get-Command docker -ErrorAction SilentlyContinue
    if (-not $dockerCmd) {
        Write-Log 'Docker CLI not found. Install Docker Desktop (Windows) or ensure docker is on PATH.' 'Error'
        [System.Windows.Forms.MessageBox]::Show('Docker CLI not found.`n`nInstall Docker Desktop (Windows) and ensure "docker" is on PATH, then retry.','Docker missing','OK','Error') | Out-Null
        return $false
    }

    $dockerVersion = $null
    try { $dockerVersion = (& docker version --format '{{.Server.Version}}' 2>$null) } catch { $dockerVersion = $null }
    if (-not $dockerVersion) {
        Write-Log 'Docker daemon is not reachable. Start Docker Desktop (Windows) and retry.' 'Error'
        [System.Windows.Forms.MessageBox]::Show('Docker daemon is not reachable.`n`nStart Docker Desktop and retry. The local Docker daemon is required for context management.','Docker not running','OK','Error') | Out-Null
        return $false
    }

    $sshCmd = Get-Command ssh -ErrorAction SilentlyContinue
    if (-not $sshCmd) {
        Write-Log 'OpenSSH client not found on PATH. Attempting auto-install.' 'Warn'

        # Try to auto-install the OpenSSH Client Windows capability
        $installAttempted = $false
        try {
            $cap = Get-WindowsCapability -Online -Name 'OpenSSH.Client*' -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($cap -and $cap.State -ne 'Installed') {
                $installChoice = [System.Windows.Forms.MessageBox]::Show(
                    "The OpenSSH Client is not installed on this machine.`n`nThe tool needs ssh, ssh-keygen, and ssh-agent to function.`n`nInstall it now? (requires Administrator — a UAC prompt will appear)",
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
                        # Refresh PATH to pick up newly installed ssh
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

        # Re-check after install attempt
        $sshCmd = Get-Command ssh -ErrorAction SilentlyContinue
        if (-not $sshCmd) {
            $manualMsg = "OpenSSH Client (ssh) is required but not installed.`n`n" +
                         "To install manually, run this in an Administrator PowerShell:`n`n" +
                         "  Add-WindowsCapability -Online -Name OpenSSH.Client~~~~0.0.1.0`n`n" +
                         "Then restart this tool."
            Write-Log 'OpenSSH client still not found after install attempt.' 'Error'
            [System.Windows.Forms.MessageBox]::Show($manualMsg, 'SSH missing', 'OK', 'Error') | Out-Null
            return $false
        }
    }

    Write-Log "Prereq check passed (Docker=$dockerVersion, ssh present)." 'Info'
    return $true
}

# 0. Environment prep (PowerShell version, elevation, colors, WinForms load)
function Ensure-Prerequisites {
    param([pscustomobject]$State)
    Write-Log 'Checking PowerShell version and elevation' 'Info'

    Write-Log 'Loading UI dependencies (WinForms, Drawing).' 'Debug'
    # Load WinForms early for dialogs used below
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    [System.Windows.Forms.Application]::EnableVisualStyles()

    Write-Log "Detected PowerShell $($PSVersionTable.PSVersion) (Major=$($PSVersionTable.PSVersion.Major))" 'Debug'

    if (-not (Test-StartupPrerequisites -State $State)) { return }

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

}

# 1. Credential dialog
function Show-CredentialDialog {
    param([pscustomobject]$State)
    Write-Log 'Collecting credentials' 'Info'

    Write-Log 'Opening credential dialog for username/password input.' 'Debug'

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

    $labelUser = New-Object System.Windows.Forms.Label -Property @{
        Text = 'Username'
        Location = New-Object System.Drawing.Point(14,150)
        Size = New-Object System.Drawing.Size(100,22)
    }
    Style-Label -Label $labelUser -Style ([System.Drawing.FontStyle]::Bold)
    $form.Controls.Add($labelUser)
    $textUser = New-Object System.Windows.Forms.TextBox -Property @{
        Location = New-Object System.Drawing.Point(120,148)
        Size = New-Object System.Drawing.Size(360,26)
    }
    Style-TextBox -TextBox $textUser
    $form.Controls.Add($textUser)

    $labelPass = New-Object System.Windows.Forms.Label -Property @{
        Text = 'Password'
        Location = New-Object System.Drawing.Point(14,185)
        Size = New-Object System.Drawing.Size(100,22)
    }
    Style-Label -Label $labelPass -Style ([System.Drawing.FontStyle]::Bold)
    $form.Controls.Add($labelPass)
    $textPass = New-Object System.Windows.Forms.TextBox -Property @{
        Location = New-Object System.Drawing.Point(120,183)
        Size = New-Object System.Drawing.Size(360,26)
        UseSystemPasswordChar = $true
    }
    Style-TextBox -TextBox $textPass
    $form.Controls.Add($textPass)

    $buttonOK = New-Object System.Windows.Forms.Button -Property @{
        Text = 'Continue'
        Location = New-Object System.Drawing.Point(120,228)
        Size = New-Object System.Drawing.Size(110,34)
    }
    Style-Button -Button $buttonOK -Variant 'primary'
    $form.Controls.Add($buttonOK)

    $buttonCancel = New-Object System.Windows.Forms.Button -Property @{
        Text = 'Cancel'
        Location = New-Object System.Drawing.Point(240,228)
        Size = New-Object System.Drawing.Size(110,34)
        DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    }
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

# Helper: ensure ssh-agent Windows service is running and add the user's key
function Ensure-SshAgentRunning {
    param([string]$SshKeyPath)

    Write-Log 'Ensuring ssh-agent service is running and key is loaded.' 'Info'

    $sshAgentService = Get-Service ssh-agent -ErrorAction SilentlyContinue
    if (-not $sshAgentService) {
        Write-Log 'ssh-agent service not found on this system.' 'Warn'
        return
    }

    if ($sshAgentService.Status -ne 'Running') {
        # First attempt: try starting directly (works if startup type is Manual or Automatic)
        $started = $false
        try {
            Start-Service ssh-agent -ErrorAction Stop
            $started = $true
            Write-Log 'ssh-agent service started (no elevation needed).' 'Info'
        } catch {
            Write-Log "Direct Start-Service ssh-agent failed: $($_.Exception.Message). Attempting elevated start." 'Info'
        }

        if (-not $started) {
            # Targeted elevation: set startup type to Automatic and start the service
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

    # Add the key to the agent (only if the service is running)
    $sshAgentService = Get-Service ssh-agent -ErrorAction SilentlyContinue
    if ($sshAgentService -and $sshAgentService.Status -eq 'Running') {
        try {
            # Check if key is already loaded
            $loadedKeys = & ssh-add -l 2>&1
            if ($loadedKeys -notmatch [regex]::Escape($SshKeyPath) -and $loadedKeys -notmatch [regex]::Escape((Split-Path $SshKeyPath -Leaf).Replace('.','_'))) {
                & ssh-add $SshKeyPath 2>&1 | Out-Null
                Write-Log "SSH key added to ssh-agent: $SshKeyPath" 'Info'
            } else {
                Write-Log 'SSH key already loaded in ssh-agent.' 'Debug'
            }
        } catch {
            Write-Log "ssh-add failed: $($_.Exception.Message)" 'Warn'
        }
    } else {
        Write-Log 'ssh-agent service is not running; skipping ssh-add.' 'Warn'
    }
}

# Helper: ensure ~/.ssh/config has an entry for the remote workstation
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

    Write-Log "Ensuring SSH config entry for $RemoteHostIp in $configPath" 'Info'

    # Ensure .ssh directory exists
    if (-not (Test-Path $sshDir)) {
        New-Item -Path $sshDir -ItemType Directory -Force | Out-Null
    }

    # Normalize the identity file path to use forward-slash notation for SSH config
    $identityNorm = $IdentityFile -replace '\\','/'

    # Check if config file already contains an entry for this host
    if (Test-Path $configPath) {
        $existingConfig = Get-Content $configPath -Raw -ErrorAction SilentlyContinue
        if ($existingConfig -match "(?mi)^\s*Host\s+$([regex]::Escape($RemoteHostIp))\s*$") {
            Write-Log "SSH config already contains entry for Host $RemoteHostIp — skipping." 'Debug'
            return
        }
    }

    # Append a new Host entry (do NOT include BatchMode — it would break the first-time password bootstrap)
    $entry = @"

# IMPACT Docker GUI — auto-generated entry for remote workstation
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
    } catch {
        Write-Log "Failed to write SSH config: $($_.Exception.Message)" 'Warn'
    }
}

# 2. GitHub SSH key setup
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

        # Ensure ssh-agent is running and key is loaded (even for existing keys)
        Ensure-SshAgentRunning -SshKeyPath $sshKeyPath
        return $true
    }

    # Ensure .ssh directory exists
    if (-not (Test-Path $sshDir)) {
        New-Item -Path $sshDir -ItemType Directory -Force | Out-Null
        Write-Log "Created .ssh directory at $sshDir" 'Info'
    }

    Write-Host "Generating SSH key..."
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

    $publicKey = Get-Content $sshPublicKeyPath -ErrorAction Stop
    $State.Metadata.PublicKey = ($publicKey -join "`n")

    # Copy to clipboard (best-effort)
    try { $publicKey | Set-Clipboard | Out-Null } catch { Write-Log 'Could not copy key to clipboard.' 'Warn' }

    $message = "A new SSH public key has been generated.`n`n" +
               "Path: $sshPublicKeyPath`n`n" +
               "Add this key to GitHub: Settings -> SSH and GPG keys -> New SSH key."
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

    $labelTitle = New-Object System.Windows.Forms.Label -Property @{
        Text = 'SSH Public Key Generated'
        Location = New-Object System.Drawing.Point(24,16)
        Size = New-Object System.Drawing.Size(780,36)
        TextAlign = 'MiddleCenter'
    }
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

    $formKeyDisplay.Add_Shown({
        $textBoxKey.SelectAll()
        $textBoxKey.Focus()
    })

    $buttonCopyKey = New-Object System.Windows.Forms.Button -Property @{
        Text = 'Copy to Clipboard'
        Location = New-Object System.Drawing.Point(520,412)
        Size = New-Object System.Drawing.Size(140,36)
    }
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
                    if ($buttonCopyKey -and -not $buttonCopyKey.IsDisposed) {
                        $buttonCopyKey.Text = 'Copy to Clipboard'
                        $buttonCopyKey.BackColor = [System.Drawing.Color]::LightGreen
                        $buttonCopyKey.Enabled = $true
                    }
                    if ($script:CopyTimer -and -not $script:CopyTimer.Disposed) {
                        $script:CopyTimer.Stop(); $script:CopyTimer.Dispose(); $script:CopyTimer = $null
                    }
                } catch {
                    if ($script:CopyTimer) { try { $script:CopyTimer.Dispose() } catch { }; $script:CopyTimer = $null }
                }
            })
            $script:CopyTimer.Start()
        } catch {
            [System.Windows.Forms.MessageBox]::Show('Failed to copy to clipboard. Please select all text and copy manually using Ctrl+C.', 'Copy Failed', 'OK', 'Warning') | Out-Null
        }
    })

    $buttonCloseKey = New-Object System.Windows.Forms.Button -Property @{
        Text = 'Close'
        Location = New-Object System.Drawing.Point(670,412)
        Size = New-Object System.Drawing.Size(120,36)
        DialogResult = [System.Windows.Forms.DialogResult]::OK
    }
    Style-Button -Button $buttonCloseKey -Variant 'secondary'
    $formKeyDisplay.Controls.Add($buttonCloseKey)
    $buttonCloseKey.Add_Click({ $formKeyDisplay.DialogResult = [System.Windows.Forms.DialogResult]::OK; $formKeyDisplay.Close() })
    $formKeyDisplay.AcceptButton = $buttonCloseKey
    $formKeyDisplay.CancelButton = $buttonCloseKey
    $null = $formKeyDisplay.ShowDialog()

    Write-Host "Public Key (copy this to GitHub):"
    Write-Host "----------------------------------------"
    Write-Host $publicKey
    Write-Host "----------------------------------------"

    # Ensure ssh-agent is running and key is loaded
    Ensure-SshAgentRunning -SshKeyPath $sshKeyPath

    return $true
}

# 3. Location selection (local vs remote)
function Select-Location {
    param([pscustomobject]$State)
    Write-Log 'Container location selection' 'Info'

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

    $buttonLocal = New-Object System.Windows.Forms.Button -Property @{
        Text = 'Local Container'
        Location = New-Object System.Drawing.Point(20,72)
        Size = New-Object System.Drawing.Size(150,42)
    }
    Style-Button -Button $buttonLocal -Variant 'primary'
    $formConnection.Controls.Add($buttonLocal)

    $buttonRemote = New-Object System.Windows.Forms.Button -Property @{
        Text = 'Remote Container'
        Location = New-Object System.Drawing.Point(20,122)
        Size = New-Object System.Drawing.Size(150,42)
    }
    Style-Button -Button $buttonRemote -Variant 'secondary'
    $formConnection.Controls.Add($buttonRemote)

    $labelRemoteIP = New-Object System.Windows.Forms.Label -Property @{
        Text = 'Remote IP Address'
        Location = New-Object System.Drawing.Point(190,126)
        Size = New-Object System.Drawing.Size(140,22)
    }
    Style-Label -Label $labelRemoteIP
    $formConnection.Controls.Add($labelRemoteIP)

    # Load default IP from .env file (WORKSTATION_IP=...) if present
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

    $textRemoteIP = New-Object System.Windows.Forms.TextBox -Property @{
        Location = New-Object System.Drawing.Point(330,124)
        Size = New-Object System.Drawing.Size(120,24)
        Text = $defaultIP
    }
    Style-TextBox -TextBox $textRemoteIP
    $formConnection.Controls.Add($textRemoteIP)

    $checkBoxDebug = New-Object System.Windows.Forms.CheckBox -Property @{
        Text = 'Enable Debug Mode (show detailed progress messages)'
        Location = New-Object System.Drawing.Point(20,180)
        Size = New-Object System.Drawing.Size(380,22)
        Checked = $false
    }
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

# 4a. Remote prep: ensure SSH user, authorized_keys, repo list, docker context
function Ensure-RemotePreparation {
    param([pscustomobject]$State)
    Write-Log 'Remote flow: authorize key, pick repo, configure Docker context' 'Info'

    if (-not $State.RemoteHost -or -not $State.RemoteHostIp) {
        Write-Log 'Remote host not set; cannot continue remote preparation.' 'Error'
        return $false
    }
    if (-not (Test-Path $State.Paths.SshPrivate)) {
        Write-Log "SSH private key missing at $($State.Paths.SshPrivate)" 'Error'
        return $false
    }
    if (-not (Test-Path $State.Paths.SshPublic)) {
        Write-Log "SSH public key missing at $($State.Paths.SshPublic)" 'Error'
        return $false
    }

    $remoteUser = $State.RemoteUser
    $remoteHost = $State.RemoteHost
    $remoteIp   = $State.RemoteHostIp
    $remoteRepoBase = if ($State.RemoteRepoBase) { $State.RemoteRepoBase } else { "/home/$remoteUser/Schreibtisch/Repositories" }
    $State.RemoteRepoBase = $remoteRepoBase

    $sshArgs = @(
        '-i', $State.Paths.SshPrivate,
        '-o', 'IdentitiesOnly=yes',
        '-o', 'BatchMode=yes',
        '-o', 'StrictHostKeyChecking=accept-new',
        '-o', 'ConnectTimeout=10',
        $remoteHost
    )

    $sshKeyPath = $State.Paths.SshPrivate

    # Quick probe to see if key auth already works to avoid prompting for password unnecessarily
    $keyAuthorized = $false
    try {
        $probeOut = & ssh @sshArgs "echo KEY_AUTH_OK" 2>&1
        if ($LASTEXITCODE -eq 0 -and $probeOut -match 'KEY_AUTH_OK') { $keyAuthorized = $true }
        Write-Log "Key auth probe output: $probeOut (exit=$LASTEXITCODE)" 'Debug'
    } catch { $keyAuthorized = $false }

    # 4.1.1: Ensure authorized_keys contains our public key and permissions are set
    Write-Log 'Authorizing SSH key on remote host...' 'Info'
        $publicKeyContent = (Get-Content $State.Paths.SshPublic -Raw).Trim()

        # Build the remote bootstrap script using format placeholders to avoid PowerShell $(...) expansion
        $remoteScript = @'
set -eu
umask 077
ACTUAL_USER="$(whoami)"
HOME_DIR="$(eval echo ~{0})"
USER_SSH_DIR="$HOME_DIR/.ssh"
AUTH_KEYS="$USER_SSH_DIR/authorized_keys"
KEY_TARGET_PUB="$USER_SSH_DIR/id_ed25519_{1}.pub"

mkdir -p "$HOME_DIR" && chmod 755 "$HOME_DIR"
mkdir -p "$USER_SSH_DIR" && chmod 700 "$USER_SSH_DIR"
touch "$AUTH_KEYS" && chmod 600 "$AUTH_KEYS"

echo "{2}" > "$KEY_TARGET_PUB"
chown {0}:{0} "$KEY_TARGET_PUB"
chmod 644 "$KEY_TARGET_PUB"

if ! grep -qxF "{2}" "$AUTH_KEYS"; then
    echo "{2}" >> "$AUTH_KEYS"
fi
chown {0}:{0} "$AUTH_KEYS"
echo 'SSH_KEY_COPIED'
'@ -f $remoteUser, $State.UserName, $publicKeyContent

    if (-not $keyAuthorized) {
        try {
            # Escape single quotes for safe bash -lc wrapping (turn ' into '\'' )
            $escaped = $remoteScript.Replace("'", "'\\''")
            $cmdOut = & ssh @sshArgs "bash -lc '$escaped'" 2>&1
            if ($LASTEXITCODE -eq 0 -and $cmdOut -match 'SSH_KEY_COPIED') { $keyAuthorized = $true }
        } catch { $keyAuthorized = $false }
    }

    if (-not $keyAuthorized) {
        Write-Log 'Key-based auth failed; prompting for password bootstrap (one-time).' 'Warn'

        $pwForm = New-Object System.Windows.Forms.Form -Property @{ Text='Enter remote password'; Size=New-Object System.Drawing.Size(380,190); FormBorderStyle='FixedDialog'; MaximizeBox=$false }
        Set-FormCenterOnCurrentScreen -Form $pwForm
        Apply-ThemeToForm -Form $pwForm
        $lbl = New-Object System.Windows.Forms.Label -Property @{ Text="Password for $($remoteUser)@$($remoteIp):"; Location=New-Object System.Drawing.Point(18,22); Size=New-Object System.Drawing.Size(330,24) }
        Style-Label -Label $lbl
        $pwForm.Controls.Add($lbl)
        $txt = New-Object System.Windows.Forms.TextBox -Property @{ Location=New-Object System.Drawing.Point(18,52); Size=New-Object System.Drawing.Size(330,26); UseSystemPasswordChar=$true }
        Style-TextBox -TextBox $txt
        $pwForm.Controls.Add($txt)
        $btnOk = New-Object System.Windows.Forms.Button -Property @{ Text='OK'; Location=New-Object System.Drawing.Point(178,100); Size=New-Object System.Drawing.Size(80,32) }
        $btnCancel = New-Object System.Windows.Forms.Button -Property @{ Text='Cancel'; Location=New-Object System.Drawing.Point(268,100); Size=New-Object System.Drawing.Size(80,32); DialogResult=[System.Windows.Forms.DialogResult]::Cancel }
        Style-Button -Button $btnOk -Variant 'primary'
        Style-Button -Button $btnCancel -Variant 'secondary'
        $btnOk.Add_Click({ if (-not $txt.Text) { return } $pwForm.DialogResult=[System.Windows.Forms.DialogResult]::OK; $pwForm.Close() })
        $pwForm.AcceptButton=$btnOk; $pwForm.CancelButton=$btnCancel; $pwForm.Controls.Add($btnOk); $pwForm.Controls.Add($btnCancel)
        $pwForm.Add_Shown({ $txt.Focus() })
        $pwResult = $pwForm.ShowDialog()
        if ($pwResult -ne [System.Windows.Forms.DialogResult]::OK) {
            Write-Log 'Password bootstrap cancelled.' 'Error'
            return $false
        }
        $plainPw = $txt.Text

        # Try Posh-SSH first (mirrors the legacy flow: create temp file remotely, then run install script)
        $poshSshUsed = $false
        $sshSession = $null
        $remoteTemp = "/tmp/ssh_key_temp_$($State.UserName)_$(Get-Date -Format 'HHmmss').pub"
        try {
            $poshSsh = Get-Module -ListAvailable -Name 'Posh-SSH' | Select-Object -First 1
            if (-not $poshSsh) {
                Write-Log 'Posh-SSH not found; prompting user to install (CurrentUser scope).' 'Info'
                try {
                    $installChoice = [System.Windows.Forms.MessageBox]::Show(
                        'The Posh-SSH module is required to copy your key using password auth. Install it now (CurrentUser scope)?',
                        'Install Posh-SSH?',
                        [System.Windows.Forms.MessageBoxButtons]::YesNo,
                        [System.Windows.Forms.MessageBoxIcon]::Question
                    )
                    if ($installChoice -eq [System.Windows.Forms.DialogResult]::Yes) {
                        try {
                            Install-Module -Name Posh-SSH -Scope CurrentUser -Force -AllowClobber -Confirm:$false -ErrorAction Stop | Out-Null
                            Write-Log 'Posh-SSH installed successfully (CurrentUser).' 'Info'
                        } catch {
                            Write-Log "Posh-SSH install failed: $($_.Exception.Message)" 'Error'
                        }
                    } else {
                        Write-Log 'User declined Posh-SSH installation.' 'Warn'
                    }
                } catch {
                    Write-Log "Posh-SSH install prompt failed: $($_.Exception.Message)" 'Warn'
                }
                $poshSsh = Get-Module -ListAvailable -Name 'Posh-SSH' | Select-Object -First 1
            }

            if ($poshSsh) {
                Import-Module Posh-SSH -ErrorAction Stop
                $poshSshUsed = $true

                $tempKeyFile = New-TemporaryFile
                Set-Content -Path $tempKeyFile -Value $publicKeyContent -NoNewline -Encoding ASCII
                $size = (Get-Item $tempKeyFile).Length
                Write-Log "Temp key file created ($size bytes) at $tempKeyFile" 'Debug'

                $secPw = ConvertTo-SecureString $plainPw -AsPlainText -Force
                $cred = New-Object System.Management.Automation.PSCredential ($remoteUser, $secPw)
                $sshSession = New-SSHSession -ComputerName $remoteIp -Credential $cred -AcceptKey -ConnectionTimeout 15 -ErrorAction Stop

                $keyEscaped = (Get-Content $tempKeyFile -Raw) -replace "'", "'\''"
                $createFileCmd = "echo '$keyEscaped' > $remoteTemp && chmod 600 $remoteTemp && echo FILE_CREATED"
                $createResult = Invoke-SSHCommand -SessionId $sshSession.SessionId -Command $createFileCmd -TimeOut 30 -ErrorAction Stop
                Write-Log "Posh-SSH create temp exit=$($createResult.ExitStatus); output=$($createResult.Output)" 'Debug'
                if ($createResult.Output -notmatch 'FILE_CREATED') { throw "Remote temp file creation failed: $($createResult.Output)" }

                                $remoteInstallScript = @'
set -eu
umask 077
ACTUAL_USER="$(whoami)"
HOME_DIR="$(eval echo ~${ACTUAL_USER})"
USER_SSH_DIR="$HOME_DIR/.ssh"
AUTH_KEYS="$USER_SSH_DIR/authorized_keys"
KEY_TARGET_PUB="$USER_SSH_DIR/id_ed25519___USERNAME___.pub"
REMOTE_TEMP="__REMOTE_TEMP__"

mkdir -p "$HOME_DIR" && chmod 755 "$HOME_DIR"
mkdir -p "$USER_SSH_DIR" && chmod 700 "$USER_SSH_DIR"
touch "$AUTH_KEYS" && chmod 600 "$AUTH_KEYS"

if [ ! -f "$REMOTE_TEMP" ]; then
    echo "Temp file missing: $REMOTE_TEMP"
    exit 1
fi

cp "$REMOTE_TEMP" "$KEY_TARGET_PUB"
chown ${ACTUAL_USER}:${ACTUAL_USER} "$KEY_TARGET_PUB"
chmod 644 "$KEY_TARGET_PUB"

NEW_KEY=$(cat "$KEY_TARGET_PUB")
if ! grep -qxF "$NEW_KEY" "$AUTH_KEYS"; then
    echo "$NEW_KEY" >> "$AUTH_KEYS"
    echo KEY_ADDED
else
    echo KEY_ALREADY_EXISTS
fi

chmod 755 "$HOME_DIR"
chmod 700 "$USER_SSH_DIR"
chmod 600 "$AUTH_KEYS"
chmod 644 "$KEY_TARGET_PUB"
chown ${ACTUAL_USER}:${ACTUAL_USER} "$HOME_DIR"
chown -R ${ACTUAL_USER}:${ACTUAL_USER} "$USER_SSH_DIR"

rm -f "$REMOTE_TEMP"
echo SSH_KEY_COPIED
'@
                                $remoteInstallScript = $remoteInstallScript.Replace('__USERNAME__', $State.UserName).Replace('__REMOTE_TEMP__', $remoteTemp)
                                $remoteInstallScript = $remoteInstallScript -replace "`r`n","`n" -replace "`r","`n"
                $cmdResult = Invoke-SSHCommand -SessionId $sshSession.SessionId -Command $remoteInstallScript -TimeOut 60 -ErrorAction Stop
                Write-Log "Posh-SSH install exit=$($cmdResult.ExitStatus); output length=$($cmdResult.Output.Length)" 'Debug'
                if ($cmdResult.Output -match 'SSH_KEY_COPIED') { $keyAuthorized = $true }
            }
        } catch {
            Write-Log "Posh-SSH bootstrap failed: $($_.Exception.Message)" 'Warn'
        } finally {
            if ($sshSession) { try { Remove-SSHSession -SessionId $sshSession.SessionId -ErrorAction SilentlyContinue | Out-Null } catch { } }
            if (Get-Variable tempKeyFile -Scope 0 -ErrorAction SilentlyContinue) { try { Remove-Item $tempKeyFile -Force -ErrorAction SilentlyContinue } catch { } }
        }

        if (-not $keyAuthorized) {
            $plink = Get-Command plink.exe -ErrorAction SilentlyContinue
            if (-not $plink) {
                $puttyPath = "${env:ProgramFiles}\PuTTY\plink.exe"
                if (Test-Path $puttyPath) { $plink = Get-Command $puttyPath -ErrorAction SilentlyContinue }
            }

            if ($plink) {
                $tmpScript = New-TemporaryFile
                Set-Content -Path $tmpScript -Value $remoteScript -NoNewline
                $plinkArgs = @('-batch','-ssh','-pw',$plainPw,$remoteHost,'bash -s')
                $p = Start-Process -FilePath $plink.Source -ArgumentList $plinkArgs -RedirectStandardInput $tmpScript -NoNewWindow -PassThru -Wait
                Remove-Item $tmpScript -Force -ErrorAction SilentlyContinue
                Write-Log "plink bootstrap exit=$($p.ExitCode)" 'Debug'
                if ($p.ExitCode -eq 0) { $keyAuthorized = $true }
            } else {
                $msg = 'Password bootstrap failed because plink.exe is not available. Install PuTTY (plink) or ensure the Posh-SSH module is installed so password-based key setup can proceed.'
                [System.Windows.Forms.MessageBox]::Show($msg,'Password bootstrap unavailable','OK','Error') | Out-Null
                Write-Log $msg 'Error'
                return $false
            }
        }

        if (-not $keyAuthorized) {
            Write-Log 'Password-based bootstrap did not succeed.' 'Error'
            return $false
        }
    }

    Write-Log 'SSH key present on remote host.' 'Info'

    # Ensure local SSH config has an entry for this remote workstation
    Ensure-SshConfigEntry -RemoteHostIp $remoteIp -RemoteUser $remoteUser -IdentityFile $sshKeyPath

    # Sync SSH private key and known_hosts onto remote for Git inside container
    Write-Log 'Syncing SSH private key and known_hosts to remote host.' 'Info'

    if (Test-Path $sshKeyPath) {
        $pkContent = Get-Content $sshKeyPath -Raw
        $pkB64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($pkContent))
        $copyPrivateCmd = "mkdir -p ~/.ssh && chmod 700 ~/.ssh && rm -f ~/.ssh/id_ed25519_$($State.UserName) && echo '$pkB64' | base64 -d > ~/.ssh/id_ed25519_$($State.UserName) && chmod 600 ~/.ssh/id_ed25519_$($State.UserName) && chown ${remoteUser}:${remoteUser} ~/.ssh/id_ed25519_$($State.UserName) && echo PRIVATE_KEY_COPIED"
        $pkOut = & ssh @sshArgs $copyPrivateCmd 2>&1
        if ($pkOut -notmatch 'PRIVATE_KEY_COPIED') { Write-Log "Remote private key copy may have failed: $pkOut" 'Warn' }
    } else {
        Write-Log "Local private key not found at $sshKeyPath; skipping remote copy." 'Warn'
    }

    $knownHostsPath = Join-Path $HOME '.ssh/known_hosts'
    if (Test-Path $knownHostsPath) {
        $khContent = Get-Content $knownHostsPath -Raw
        $khB64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($khContent))
        $copyKhCmd = "mkdir -p ~/.ssh && chmod 700 ~/.ssh && rm -f ~/.ssh/known_hosts && echo '$khB64' | base64 -d > ~/.ssh/known_hosts && chmod 644 ~/.ssh/known_hosts && chown ${remoteUser}:${remoteUser} ~/.ssh/known_hosts && echo KNOWN_HOSTS_COPIED"
        $khOut = & ssh @sshArgs $copyKhCmd 2>&1
        if ($khOut -notmatch 'KNOWN_HOSTS_COPIED') { Write-Log "Remote known_hosts copy may have failed: $khOut" 'Warn' }
    } else {
        $createKhCmd = "mkdir -p ~/.ssh && chmod 700 ~/.ssh && rm -f ~/.ssh/known_hosts && touch ~/.ssh/known_hosts && chmod 644 ~/.ssh/known_hosts && chown ${remoteUser}:${remoteUser} ~/.ssh/known_hosts && echo KNOWN_HOSTS_EMPTY"
        & ssh @sshArgs $createKhCmd 2>&1 | Out-Null
    }

    # 4.1.2: Scan remote repo list
    Write-Log "Scanning remote repositories at $remoteRepoBase" 'Info'
    $listScript = "ls -1d $remoteRepoBase/*/ 2>/dev/null | xargs -n1 basename"
    try {
        $repoList = (& ssh @sshArgs $listScript 2>&1) -split "`n" | Where-Object { $_ -and ($_ -notmatch 'No such file') }
    } catch {
        Write-Log "Repo scan failed: $($_.Exception.Message)" 'Error'
        return $false
    }

    Write-Log "Remote repo count discovered: $($repoList.Count)" 'Debug'

    if (-not $repoList -or $repoList.Count -eq 0) {
        Write-Log "No repositories found under $remoteRepoBase" 'Error'
        return $false
    }

    # 4.1.3: Repo selection dialog
    $formRepo = New-Object System.Windows.Forms.Form -Property @{
        Text = 'Select Remote Repository'
        Size = New-Object System.Drawing.Size(430,340)
        FormBorderStyle = 'FixedDialog'
        MaximizeBox = $false
    }
    Set-FormCenterOnCurrentScreen -Form $formRepo
    Apply-ThemeToForm -Form $formRepo

    $labelRepo = New-Object System.Windows.Forms.Label -Property @{
        Text = "Choose a repository to work with (remote: $remoteHost)"
        Location = New-Object System.Drawing.Point(14,14)
        Size = New-Object System.Drawing.Size(390,30)
    }
    Style-Label -Label $labelRepo
    $formRepo.Controls.Add($labelRepo)

    $listBox = New-Object System.Windows.Forms.ListBox -Property @{
        Location = New-Object System.Drawing.Point(14,50)
        Size = New-Object System.Drawing.Size(390,190)
        SelectionMode = 'One'
        BorderStyle = 'FixedSingle'
    }
    $listBox.BackColor = $script:ThemePalette.Panel
    $listBox.ForeColor = $script:ThemePalette.Text
    $listBox.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Regular)
    $listBox.Items.AddRange($repoList)
    $formRepo.Controls.Add($listBox)

    $buttonOk = New-Object System.Windows.Forms.Button -Property @{
        Text = 'Select'
        Location = New-Object System.Drawing.Point(216,260)
        Size = New-Object System.Drawing.Size(90,32)
    }
    Style-Button -Button $buttonOk -Variant 'primary'
    $formRepo.Controls.Add($buttonOk)

    $buttonCancel = New-Object System.Windows.Forms.Button -Property @{
        Text = 'Cancel'
        Location = New-Object System.Drawing.Point(320,260)
        Size = New-Object System.Drawing.Size(90,32)
        DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    }
    Style-Button -Button $buttonCancel -Variant 'secondary'
    $formRepo.Controls.Add($buttonCancel)

    $buttonOk.Add_Click({
        if (-not $listBox.SelectedItem) {
            [System.Windows.Forms.MessageBox]::Show('Please select a repository.', 'Repo required', 'OK', 'Warning') | Out-Null
            return
        }
        $formRepo.DialogResult = [System.Windows.Forms.DialogResult]::OK
        $formRepo.Close()
    })
    $formRepo.AcceptButton = $buttonOk
    $formRepo.CancelButton = $buttonCancel

    $repoResult = $formRepo.ShowDialog()
    if ($repoResult -ne [System.Windows.Forms.DialogResult]::OK) {
        Write-Log 'Repository selection cancelled.' 'Warn'
        return $false
    }

    $selectedRepo = $listBox.SelectedItem
    $State.SelectedRepo = $selectedRepo
    $State.Paths.RemoteRepo = "$remoteRepoBase/$selectedRepo"
    $State.ContainerName = "${selectedRepo}_$($State.UserName)"
    Write-Log "Selected remote repo: $($State.Paths.RemoteRepo)" 'Info'

    # 4.1.4: Configure Docker context over SSH (primary path) with direct-SSH fallback
    $contextName = "remote-$remoteIp"
    $State.Metadata.RemoteDockerContext = $contextName

    Write-Log "Ensuring Docker context $contextName exists (ssh://$remoteHost)" 'Info'
    $ctxExists = (& docker context ls --format '{{.Name}}' 2>$null) -contains $contextName
    if (-not $ctxExists) {
        try {
            & docker context create $contextName --docker "host=ssh://$remoteHost" | Out-Null
            Write-Log "Docker context $contextName created." 'Debug'
        } catch {
            Write-Log "Failed to create docker context, will attempt direct DOCKER_HOST fallback." 'Warn'
        }
    }

    $contextActive = $false
    if ((& docker context ls --format '{{.Name}}' 2>$null) -contains $contextName) {
        try { & docker context use $contextName | Out-Null; $contextActive = $true } catch { $contextActive = $false }
    }

    if (-not $contextActive) {
        Write-Log 'Falling back to direct SSH via DOCKER_HOST.' 'Warn'
        $State.Flags.UseDirectSsh = $true
        Set-DockerSSHEnvironment -State $State
    } else {
        $State.Flags.UseDirectSsh = $false
        Write-Log "Docker context set to $contextName" 'Info'
    }

    # 4.1.5: Verify Docker Engine is installed and running on the remote host
    Write-Log 'Checking remote Docker Engine availability...' 'Info'
    $remoteDockerOk = $false
    $remoteDockerCliExists = $false
    try {
        $sshCheckArgs = @('-i', $State.Paths.SshPrivate, '-o', 'IdentitiesOnly=yes', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=15', $remoteHost)
        $dockerVer = & ssh @sshCheckArgs 'docker version --format "{{.Server.Version}}"' 2>&1
        if ($LASTEXITCODE -eq 0 -and $dockerVer -and $dockerVer -notmatch 'Cannot connect') {
            $remoteDockerOk = $true
            $remoteDockerCliExists = $true
            Write-Log "Remote Docker Engine running (Server version: $dockerVer)" 'Info'
        } else {
            # Check if CLI exists but daemon is not running
            $whichDocker = & ssh @sshCheckArgs 'which docker 2>/dev/null || echo NOT_FOUND' 2>&1
            if ($whichDocker -and $whichDocker -notmatch 'NOT_FOUND') {
                $remoteDockerCliExists = $true
                Write-Log 'Remote Docker CLI found but daemon is not running.' 'Warn'
            } else {
                Write-Log 'Remote Docker CLI not found.' 'Error'
            }
        }
    } catch {
        Write-Log "Remote Docker check failed: $($_.Exception.Message)" 'Warn'
    }

    if (-not $remoteDockerCliExists) {
        [System.Windows.Forms.MessageBox]::Show(
            "Docker Engine is not installed on the remote workstation ($remoteIp).`n`nInstall it on the remote host with:`n  sudo apt-get update`n  sudo apt-get install docker-ce docker-ce-cli containerd.io`n`nSee https://docs.docker.com/engine/install/ for details.",
            'Docker Engine Missing (Remote)', 'OK', 'Error') | Out-Null
        return $false
    }

    # 4.1.6: Attempt to start Docker daemon if not running
    if (-not $remoteDockerOk) {
        $startChoice = [System.Windows.Forms.MessageBox]::Show(
            "Docker daemon is not running on the remote workstation ($remoteIp).`n`nAttempt to start it? You will be prompted for the sudo password in the console.",
            'Docker Daemon Not Running (Remote)', 'YesNo', 'Warning')

        if ($startChoice -eq [System.Windows.Forms.DialogResult]::Yes) {
            Write-Log 'Attempting to start remote Docker daemon via sudo systemctl...' 'Info'
            Write-Host ''
            Write-Host '--- Enter the sudo password on the remote host when prompted ---' -ForegroundColor Yellow
            try {
                $startArgs = @('-i', $State.Paths.SshPrivate, '-o', 'IdentitiesOnly=yes', '-o', 'ConnectTimeout=30', '-t', $remoteHost, 'sudo systemctl start docker')
                $p = Start-Process -FilePath 'ssh' -ArgumentList $startArgs -Wait -PassThru -NoNewWindow
                if ($p.ExitCode -eq 0) {
                    Write-Log 'sudo systemctl start docker completed.' 'Info'
                    # Wait briefly for the daemon socket to become available
                    Start-Sleep -Seconds 3
                    # Re-check
                    $sshCheckArgs2 = @('-i', $State.Paths.SshPrivate, '-o', 'IdentitiesOnly=yes', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=15', $remoteHost)
                    $dockerVer2 = & ssh @sshCheckArgs2 'docker version --format "{{.Server.Version}}"' 2>&1
                    if ($LASTEXITCODE -eq 0 -and $dockerVer2 -and $dockerVer2 -notmatch 'Cannot connect') {
                        $remoteDockerOk = $true
                        Write-Log "Remote Docker Engine started successfully (Server version: $dockerVer2)" 'Info'
                    }
                } else {
                    Write-Log "sudo systemctl start docker exited with code $($p.ExitCode)" 'Warn'
                }
            } catch {
                Write-Log "Failed to start remote Docker: $($_.Exception.Message)" 'Warn'
            }
            Write-Host '--- End of remote sudo session ---' -ForegroundColor Yellow
            Write-Host ''
        }

        if (-not $remoteDockerOk) {
            [System.Windows.Forms.MessageBox]::Show(
                "Docker daemon could not be started on the remote workstation ($remoteIp).`n`nStart it manually on the remote host:`n  sudo systemctl start docker`n  sudo systemctl enable docker",
                'Docker Daemon Start Failed', 'OK', 'Error') | Out-Null
            return $false
        }
    }

    # 4.1.7: Check docker group membership for the remote user
    Write-Log 'Checking remote user docker group membership...' 'Info'
    try {
        $sshGroupArgs = @('-i', $State.Paths.SshPrivate, '-o', 'IdentitiesOnly=yes', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=15', $remoteHost)
        $groupsOutput = & ssh @sshGroupArgs 'groups' 2>&1
        if ($LASTEXITCODE -eq 0 -and $groupsOutput) {
            $groupList = $groupsOutput -split '\s+'
            if ($groupList -contains 'docker') {
                Write-Log "Remote user '$remoteUser' is in the docker group." 'Info'
            } else {
                Write-Log "Remote user '$remoteUser' is NOT in the docker group. Groups: $groupsOutput" 'Warn'
                [System.Windows.Forms.MessageBox]::Show(
                    "The remote user '$remoteUser' is not in the 'docker' group.`n`nDocker commands may fail with permission errors.`n`nFix this on the remote host:`n  sudo usermod -aG docker $remoteUser`n`nThen log out and back in (or reboot) for it to take effect.",
                    'Docker Group Warning', 'OK', 'Warning') | Out-Null
            }
        }
    } catch {
        Write-Log "Could not check docker group membership: $($_.Exception.Message)" 'Debug'
    }

    return $true
}

# 4b. Local prep: folder selection and docker context
function Ensure-LocalPreparation {
    param([pscustomobject]$State)
    Write-Log 'Local flow: selecting repository folder' 'Info'

    $folderBrowser = New-Object System.Windows.Forms.FolderBrowserDialog -Property @{
        Description = 'Select the local folder containing your simulation model and its GitHub repository:'
        RootFolder = [System.Environment+SpecialFolder]::MyComputer
        ShowNewFolderButton = $false
    }

    $documentsPath = [System.Environment]::GetFolderPath([System.Environment+SpecialFolder]::MyDocuments)
    if (Test-Path $documentsPath) {
        $folderBrowser.SelectedPath = $documentsPath
    }

    $folderResult = $folderBrowser.ShowDialog()
    if ($folderResult -ne [System.Windows.Forms.DialogResult]::OK) {
        Write-Log 'Folder selection cancelled.' 'Warn'
        [System.Windows.Forms.MessageBox]::Show('Folder selection is required to continue.', 'Selection Cancelled', 'OK', 'Warning') | Out-Null
        return $false
    }

    $selectedPath = $folderBrowser.SelectedPath
    if ([string]::IsNullOrWhiteSpace($selectedPath) -or -not (Test-Path $selectedPath)) {
        Write-Log 'Invalid folder selection.' 'Error'
        [System.Windows.Forms.MessageBox]::Show('Please select a valid folder containing your repository.', 'Invalid Selection', 'OK', 'Error') | Out-Null
        return $false
    }

    $State.Paths.LocalRepo = $selectedPath
    $State.SelectedRepo = Split-Path $selectedPath -Leaf
    $State.ContainerName = "$($State.SelectedRepo)_$($State.UserName)"
    Write-Log "Local repository path: $($State.Paths.LocalRepo)" 'Info'
    Write-Log "Repository name: $($State.SelectedRepo)" 'Info'

    $gitPath = Join-Path $selectedPath '.git'
    if (-not (Test-Path $gitPath)) {
        Write-Log 'No .git directory found in selected folder.' 'Warn'
        $continueResult = [System.Windows.Forms.MessageBox]::Show(
            "The selected folder does not appear to be a Git repository.`n`nDo you want to continue anyway?",
            'No Git Repository Found',
            'YesNo',
            'Question'
        )

        if ($continueResult -eq [System.Windows.Forms.DialogResult]::No) {
            Write-Log 'User chose not to continue without Git repository.' 'Warn'
            return $false
        }
        Write-Log 'User chose to continue without Git repository.' 'Info'
    } else {
        Write-Log 'Git repository detected in selected folder.' 'Info'
    }

    Write-Log 'Checking local Docker availability and context' 'Info'

    try {
        $dockerVersion = & docker --version 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Log 'Docker is not available locally.' 'Error'
            [System.Windows.Forms.MessageBox]::Show('Docker is not available on this system.`n`nPlease ensure Docker Desktop is installed and running on your Windows machine.', 'Docker Not Available', 'OK', 'Error') | Out-Null
            return $false
        }
        Write-Log "Docker detected: $dockerVersion" 'Info'
    } catch {
        Write-Log "Could not check Docker availability: $($_.Exception.Message)" 'Error'
        [System.Windows.Forms.MessageBox]::Show('Could not verify Docker availability.`n`nPlease ensure Docker Desktop is installed and running on your Windows machine.', 'Docker Check Failed', 'OK', 'Error') | Out-Null
        return $false
    }

    $dockerRunning = $false
    try {
        $quickCheck = & docker version --format "{{.Server.Version}}" 2>$null
        if ($LASTEXITCODE -eq 0 -and $quickCheck) {
            $dockerRunning = $true
            Write-Log "Docker engine is running (Server version: $quickCheck)" 'Info'
        }
    } catch {
        Write-Log "Quick Docker version check failed: $($_.Exception.Message)" 'Debug'
    }

    if (-not $dockerRunning) {
        Write-Log 'Docker engine is not running; attempting to start Docker Desktop.' 'Warn'
        try {
            $dockerDesktopPath = "${env:ProgramFiles}\Docker\Docker\Docker Desktop.exe"
            if (Test-Path $dockerDesktopPath) {
                Write-Log "Attempting to start Docker Desktop via ProgramFiles path: $dockerDesktopPath" 'Debug'
                Start-Process -FilePath $dockerDesktopPath -WindowStyle Hidden
            } else {
                $dockerDesktopAlt = "${env:LOCALAPPDATA}\Programs\Docker\Docker\Docker Desktop.exe"
                if (Test-Path $dockerDesktopAlt) {
                    Write-Log "Attempting to start Docker Desktop via LocalAppData path: $dockerDesktopAlt" 'Debug'
                    Start-Process -FilePath $dockerDesktopAlt -WindowStyle Hidden
                } else {
                    Write-Log 'Docker Desktop executable not found; trying service startup.' 'Warn'
                    Start-Service -Name 'com.docker.service' -ErrorAction SilentlyContinue
                }
            }

            $maxAttempts = 30
            $attempt = 0
            do {
                Start-Sleep -Seconds 1
                $attempt++
                $checkJob = Start-Job -ScriptBlock { & docker info 2>&1 | Out-Null; $LASTEXITCODE }
                $checkResult = Wait-Job $checkJob -Timeout 5
                if ($checkResult) {
                    $checkExitCode = Receive-Job $checkJob
                    Remove-Job $checkJob
                    Write-Log "Docker start check attempt $attempt exit=$checkExitCode" 'Debug'
                    if ($checkExitCode -eq 0) { $dockerRunning = $true; break }
                } else {
                    Stop-Job $checkJob -ErrorAction SilentlyContinue
                    Remove-Job $checkJob -ErrorAction SilentlyContinue
                }
                if ($attempt -eq 10 -or $attempt -eq 20) {
                    Write-Log 'Docker is still starting up...' 'Info'
                }
            } while ($attempt -lt $maxAttempts)

            $finalJob = Start-Job -ScriptBlock { & docker info 2>&1 | Out-Null; $LASTEXITCODE }
            $finalResult = Wait-Job $finalJob -Timeout 5
            if ($finalResult) {
                $finalExitCode = Receive-Job $finalJob
                Remove-Job $finalJob
                $dockerRunning = ($finalExitCode -eq 0)
                Write-Log "Final docker start check exit=$finalExitCode" 'Debug'
            } else {
                Stop-Job $finalJob -ErrorAction SilentlyContinue
                Remove-Job $finalJob -ErrorAction SilentlyContinue
            }

            if (-not $dockerRunning) {
                Write-Log 'Docker engine did not start within the expected time.' 'Warn'
                $choice = [System.Windows.Forms.MessageBox]::Show(
                    "Docker engine could not be started automatically.`n`nWould you like to:`n- Click 'Yes' to wait and try again`n- Click 'No' to continue anyway (may cause errors)`n- Click 'Cancel' to exit",
                    'Docker Startup Issue',
                    'YesNoCancel',
                    'Warning'
                )

                if ($choice -eq [System.Windows.Forms.DialogResult]::Yes) {
                    [System.Windows.Forms.MessageBox]::Show(
                        'Please start Docker Desktop manually and wait for it to be ready, then click OK to continue.`n`nOr click Cancel to skip Docker checks and continue anyway.',
                        'Manual Start Required',
                        'OKCancel',
                        'Information'
                    ) | Out-Null
                } elseif ($choice -eq [System.Windows.Forms.DialogResult]::Cancel) {
                    Write-Log 'User chose to exit after Docker startup failure.' 'Warn'
                    return $false
                }
            }
        } catch {
            Write-Log "Failed to start Docker Desktop: $($_.Exception.Message)" 'Error'
        }
    }

    if (-not $dockerRunning) {
        Write-Log 'Docker engine may still be unavailable; continuing with caution.' 'Warn'
    } else {
        Write-Log 'Docker engine is running.' 'Info'
    }

    $LocalContextName = 'local'
    $onWindows = ($PSVersionTable.PSEdition -eq 'Desktop' -or $env:OS -like '*Windows*')
    if ($onWindows) {
        $dockerHost = 'npipe:////./pipe/docker_engine'
    } else {
        $dockerHost = 'unix:///var/run/docker.sock'
    }
    Write-Log "Configuring Docker context '$LocalContextName' for host $dockerHost" 'Info'

    $exists = (& docker context ls --format '{{.Name}}' 2>$null) -contains $LocalContextName
    if (-not $exists) {
        & docker context create $LocalContextName --description 'Local Docker engine' --docker "host=$dockerHost" | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Write-Log 'Docker context created successfully.' 'Info'
        } else {
            Write-Log 'Failed to create Docker context.' 'Error'
        }
    } else {
        Write-Log "Context '$LocalContextName' already exists." 'Debug'
    }

    & docker context use $LocalContextName *> $null
    if ($LASTEXITCODE -eq 0) {
        Write-Log "Switched to Docker context '$LocalContextName'." 'Info'
    } else {
        Write-Log "Failed to switch to Docker context '$LocalContextName'." 'Warn'
    }

    & docker --context $LocalContextName version 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-Log 'Docker connection test passed.' 'Info'
    } else {
        Write-Log 'Docker connection test failed.' 'Warn'
    }

    $State.Metadata.LocalDockerContext = $LocalContextName
    Write-Log 'Local Docker environment is ready.' 'Info'
    return $true
}

# 5. Container status detection
function Get-ContainerStatus {
    param([pscustomobject]$State)
    Write-Log 'Container status check' 'Info'

    Set-DockerSSHEnvironment -State $State
    $ctxArgs = Get-DockerContextArgs -State $State

    $portUsers = @()
    try {
        $psCmd = $ctxArgs + @('ps','--format','{{.Names}}\t{{.Ports}}')
        $all = & docker @psCmd 2>$null
        if ($LASTEXITCODE -eq 0 -and $all) {
            foreach ($line in ($all -split "`n")) {
                if ($line -match '0\.0\.0\.0:(\d{4})->8787/tcp') {
                    $port = $matches[1]
                    if ($portUsers -notcontains $port) { $portUsers += $port }
                }
            }
        }
    } catch {
        Write-Log "Port scan failed: $($_.Exception.Message)" 'Warn'
    }
    Write-Log "Discovered in-use ports: $([string]::Join(',', $portUsers))" 'Debug'
    $State.Ports.Used = $portUsers

    # Collect containers for this user
    $pattern = "_$($State.UserName)"
    # Use raw format (no table header/padding) so parsing stays reliable
    $psAll = $ctxArgs + @('ps','-a','--filter',"name=$pattern",'--format','{{.Names}}\t{{.Status}}\t{{.Ports}}\t{{.Image}}')

    $State.Metadata.ExistingContainers = @()
    try {
        $out = & docker @psAll 2>$null
        if ($LASTEXITCODE -eq 0 -and $out) {
            $lines = ($out -split "`n") | Where-Object { $_ }
            foreach ($l in $lines) {
                $parts = $l -split "`t"
                if ($parts.Count -ge 2) {
                    $State.Metadata.ExistingContainers += [pscustomobject]@{
                        Name   = $parts[0]
                        Status = $parts[1]
                        Ports  = if ($parts.Count -ge 3) { $parts[2] } else { '' }
                        Image  = if ($parts.Count -ge 4) { $parts[3] } else { '' }
                    }
                }
            }
            Write-Log "Existing containers parsed: $($State.Metadata.ExistingContainers.Count)" 'Debug'
        }
    } catch {
        Write-Log "Container list failed: $($_.Exception.Message)" 'Warn'
    }

    # Detect if target container is running
    $isRunning = $false
    try {
        $psRunning = $ctxArgs + @('ps','--filter',"name=^$($State.ContainerName)$",'--format','{{.Names}}')
        $name = & docker @psRunning 2>$null
        if ($LASTEXITCODE -eq 0 -and $name -and $name.Trim() -eq $State.ContainerName) { $isRunning = $true }
    } catch {
        Write-Log "Running check failed: $($_.Exception.Message)" 'Warn'
    }
    $State.Metadata.ContainerRunning = $isRunning

    # If running, attempt to recover connection details
    if ($isRunning) {
        # Pre-seed recovered fields so strict mode does not throw on missing properties
        $State.Metadata.Recovered = @{ Password = $null; Port = $null; UseVolumes = $false }
        if ($State.ContainerLocation -like 'REMOTE@*') {
            $meta = Read-RemoteContainerMetadata -State $State
            if ($meta) {
                $State.Metadata.Recovered.Password = $meta.password
                $State.Metadata.Recovered.Port = $meta.port
                $State.Metadata.Recovered.UseVolumes = $meta.useVolumes
            }
        }
        if (-not $State.Metadata.Recovered.Password -or -not $State.Metadata.Recovered.Port) {
            $runtime = Get-ContainerRuntimeInfo -State $State
            if ($runtime.Password) { $State.Metadata.Recovered.Password = $runtime.Password }
            if ($runtime.Port) { $State.Metadata.Recovered.Port = $runtime.Port }
        }
    }
    return $State
}

# 6. Container management UI
function Show-ContainerManager {
    param([pscustomobject]$State)
    if (-not $State.Metadata.ContainsKey('Recovered') -or -not $State.Metadata.Recovered) {
        $State.Metadata.Recovered = @{ UseVolumes = $false; Password = $null; Port = $null }
    }
    if (-not $State.Metadata.ContainsKey('ActivePort')) { $State.Metadata.ActivePort = $null }
    if (-not $State.Metadata.ContainsKey('ActiveUseVolumes')) { $State.Metadata.ActiveUseVolumes = $false }
    if (-not $State.Metadata.ContainsKey('ActiveRepoPath')) { $State.Metadata.ActiveRepoPath = $null }
    if (-not $State.Metadata.ContainsKey('ActiveIsRemote')) { $State.Metadata.ActiveIsRemote = $false }
    Write-Log 'Opening container manager UI.' 'Info'
    $isRunning = $State.Metadata.ContainerRunning
    if ($isRunning) {
        $portDisplay = if ($State.Metadata.Recovered.Port) { ($State.Metadata.Recovered.Port -split '\s+')[0] } else { '8787' }
        $passDisplay = if ($State.Metadata.Recovered.Password) { $State.Metadata.Recovered.Password } else { $State.Password }
        $hostDisplay = if ($State.ContainerLocation -eq 'LOCAL') { "http://localhost:$portDisplay" } else { "http://$($State.RemoteHostIp):$portDisplay" }
        [System.Windows.Forms.MessageBox]::Show("Container '$($State.ContainerName)' already running.`n`nURL: $hostDisplay`nUser: rstudio`nPassword: $passDisplay","Container already running",'OK','Information') | Out-Null
        Write-Log "Resumed existing container $($State.ContainerName) at $hostDisplay" 'Info'
        $State.Metadata.ActiveRepoPath = if ($State.ContainerLocation -eq 'LOCAL') { $State.Paths.LocalRepo } else { $State.Paths.RemoteRepo }
        $State.Metadata.ActiveIsRemote = ($State.ContainerLocation -like 'REMOTE@*')
        $State.Metadata.ActiveUseVolumes = $State.Metadata.Recovered.UseVolumes
        $State.Metadata.ActivePort = $portDisplay
        if ($State.Metadata.Recovered.UseVolumes) {
            # Ensure expected volume names are populated for recovered sessions
            $State.Metadata.VolumeOutput = "impactncd_germany_output_$($State.UserName)" -replace '[^a-zA-Z0-9_]','_'
            $State.Metadata.VolumeSynthpop = "impactncd_germany_synthpop_$($State.UserName)" -replace '[^a-zA-Z0-9_]','_'
        }
    }

    $form = New-Object System.Windows.Forms.Form -Property @{
        Text = 'Container Management - IMPACT NCD Germany'
        Size = New-Object System.Drawing.Size(540,500)
        FormBorderStyle = 'FixedDialog'
        MaximizeBox = $false
    }
    Set-FormCenterOnCurrentScreen -Form $form
    Apply-ThemeToForm -Form $form

    $info = New-Object System.Windows.Forms.RichTextBox -Property @{
        Location = New-Object System.Drawing.Point(12,12)
        Size = New-Object System.Drawing.Size(500,148)
        ReadOnly = $true
        BorderStyle = 'None'
        BackColor = $form.BackColor
    }
    Style-InfoBox -Box $info
    $form.Controls.Add($info)

    $btnStart = New-Object System.Windows.Forms.Button -Property @{ Text='Start Container'; Location=New-Object System.Drawing.Point(90,170); Size=New-Object System.Drawing.Size(150,42); Enabled = -not $isRunning }
    $btnStop  = New-Object System.Windows.Forms.Button -Property @{ Text='Stop Container';  Location=New-Object System.Drawing.Point(280,170); Size=New-Object System.Drawing.Size(150,42); Enabled = $isRunning }
    Style-Button -Button $btnStart -Variant 'primary'
    Style-Button -Button $btnStop -Variant 'danger'
    $form.Controls.Add($btnStart)
    $form.Controls.Add($btnStop)

    $labelAdv = New-Object System.Windows.Forms.Label -Property @{ Text='Advanced Options'; Location=New-Object System.Drawing.Point(12,220); Size=New-Object System.Drawing.Size(300,22) }
    Style-Label -Label $labelAdv -Style ([System.Drawing.FontStyle]::Bold)
    $form.Controls.Add($labelAdv)

    $chkVolumes = New-Object System.Windows.Forms.CheckBox -Property @{ Text='Use Docker Volumes'; Location=New-Object System.Drawing.Point(20,246); Size=New-Object System.Drawing.Size(200,22); Checked = [bool]$State.Metadata.Recovered.UseVolumes }
    $chkRebuild = New-Object System.Windows.Forms.CheckBox -Property @{ Text='Rebuild image'; Location=New-Object System.Drawing.Point(240,246); Size=New-Object System.Drawing.Size(150,22) }
    $chkHigh    = New-Object System.Windows.Forms.CheckBox -Property @{ Text='High computational demand'; Location=New-Object System.Drawing.Point(20,272); Size=New-Object System.Drawing.Size(240,22) }
    Style-CheckBox -CheckBox $chkVolumes
    Style-CheckBox -CheckBox $chkRebuild
    Style-CheckBox -CheckBox $chkHigh
    $form.Controls.Add($chkVolumes)
    $form.Controls.Add($chkRebuild)
    $form.Controls.Add($chkHigh)

    $lblPort = New-Object System.Windows.Forms.Label -Property @{ Text='Port Override'; Location=New-Object System.Drawing.Point(20,304); Size=New-Object System.Drawing.Size(110,22) }
    $defaultPort = if ($State.Metadata.Recovered.Port) { $State.Metadata.Recovered.Port } else { '8787' }
    $txtPort = New-Object System.Windows.Forms.TextBox -Property @{ Location=New-Object System.Drawing.Point(136,302); Size=New-Object System.Drawing.Size(90,24); Text=$defaultPort }
    Style-Label -Label $lblPort
    Style-TextBox -TextBox $txtPort
    $form.Controls.Add($lblPort); $form.Controls.Add($txtPort)

    $isLocal = ($State.ContainerLocation -eq 'LOCAL')
    if ($isLocal) {
        $txtPort.Enabled = $false
        $chkHigh.Enabled = $false
    }

    $lblParams = New-Object System.Windows.Forms.Label -Property @{ Text='Custom Params'; Location=New-Object System.Drawing.Point(238,304); Size=New-Object System.Drawing.Size(110,22) }
    $txtParams = New-Object System.Windows.Forms.TextBox -Property @{ Location=New-Object System.Drawing.Point(354,302); Size=New-Object System.Drawing.Size(150,24) }
    Style-Label -Label $lblParams
    Style-TextBox -TextBox $txtParams
    $form.Controls.Add($lblParams); $form.Controls.Add($txtParams)

    $lblYaml = New-Object System.Windows.Forms.Label -Property @{ Text='sim_design.yaml'; Location=New-Object System.Drawing.Point(20,336); Size=New-Object System.Drawing.Size(130,22) }
    $txtYaml = New-Object System.Windows.Forms.TextBox -Property @{ Location=New-Object System.Drawing.Point(152,334); Size=New-Object System.Drawing.Size(352,24); Text='.\inputs\sim_design.yaml' }
    Style-Label -Label $lblYaml
    Style-TextBox -TextBox $txtYaml
    $form.Controls.Add($lblYaml); $form.Controls.Add($txtYaml)

    $lblStatus = New-Object System.Windows.Forms.Label -Property @{ Text=''; Location=New-Object System.Drawing.Point(20,410); Size=New-Object System.Drawing.Size(460,26) }
    Style-Label -Label $lblStatus
    $lblStatus.ForeColor = [System.Drawing.Color]::LightGreen
    $form.Controls.Add($lblStatus)

    $buildInfo = $State.Metadata.BuildInfo
    $footerText = if ($buildInfo) { "Build: $($buildInfo.Version) | Commit: $($buildInfo.Commit) | Built: $($buildInfo.Built)" } else { 'Build: unknown' }
    $lblFooter = New-Object System.Windows.Forms.Label -Property @{ Text=$footerText; Location=New-Object System.Drawing.Point(20,440); Size=New-Object System.Drawing.Size(460,22) }
    Style-Label -Label $lblFooter -Muted:$true
    $form.Controls.Add($lblFooter)

    $btnClose = New-Object System.Windows.Forms.Button -Property @{ Text='Close'; Location=New-Object System.Drawing.Point(414,374); Size=New-Object System.Drawing.Size(90,34) }
    Style-Button -Button $btnClose -Variant 'secondary'
    $form.Controls.Add($btnClose)
    $form.AcceptButton = $btnClose
    $form.CancelButton = $btnClose

    $form.Add_FormClosing({
        if ($State.Metadata.ContainerRunning) {
            $answer = [System.Windows.Forms.MessageBox]::Show('A container is still running. Close without stopping?','Container running','YesNo','Warning')
            if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { $_.Cancel = $true }
        }
    })

    function Update-InfoBox {
        param($Status)
        $info.Clear()
        $info.SelectionFont = New-Object System.Drawing.Font('Segoe UI Semibold',10,[System.Drawing.FontStyle]::Bold)

        $passDisplay = if ($State.Metadata.Recovered.Password) { $State.Metadata.Recovered.Password } else { $State.Password }
        $portDisplay = if ($State.Metadata.ActivePort) { $State.Metadata.ActivePort } elseif ($State.Metadata.Recovered.Port) { ($State.Metadata.Recovered.Port -split '\s+')[0] } else { '8787' }
        $hostDisplay = if ($State.ContainerLocation -eq 'LOCAL') { "http://localhost:$portDisplay" } else { "http://$($State.RemoteHostIp):$portDisplay" }

        # Status line with emphasis
        $info.SelectionColor = if ($Status -eq 'RUNNING') { [System.Drawing.Color]::LightGreen } else { [System.Drawing.Color]::Orange }
        $info.AppendText("Status: $Status`n")

        $info.SelectionColor = $form.ForeColor
        $info.SelectionFont = New-Object System.Drawing.Font('Segoe UI',9,[System.Drawing.FontStyle]::Regular)
        $info.AppendText("URL: $hostDisplay`n")
        $info.AppendText("RStudio login: rstudio (Password: $passDisplay)`n")
        $info.AppendText("Repo: $($State.SelectedRepo)`n")
        $info.AppendText("Container: $($State.ContainerName)`n")
        $info.AppendText("Location: $($State.ContainerLocation)`n")
    }
    Update-InfoBox -Status ($(if($isRunning){'RUNNING'}else{'STOPPED'}))
    $lblStatus.Text = ''

    $btnStart.Add_Click({
        $useVolumes = $chkVolumes.Checked
        $rebuild    = $chkRebuild.Checked
        $highComp   = $chkHigh.Checked
        $portOverride = $txtPort.Text.Trim()
        if ($State.ContainerLocation -eq 'LOCAL') { $portOverride = '8787' }
        $customParams = $txtParams.Text.Trim()
        $simDesign = $txtYaml.Text.Trim()

        Write-Log ("Start clicked with options -> volumes={0} rebuild={1} highComp={2} port={3} params='{4}' yaml='{5}'" -f $useVolumes,$rebuild,$highComp,$portOverride,$customParams,$simDesign) 'Debug'

        Set-DockerSSHEnvironment -State $State

        if ($State.Metadata.ContainerRunning) {
            [System.Windows.Forms.MessageBox]::Show('Container already running; stop it first or close to reuse.','Already running','OK','Information') | Out-Null
            return
        }

        if ($portOverride -and $State.Ports.Used -contains $portOverride) {
            [System.Windows.Forms.MessageBox]::Show("Port $portOverride is already in use. Choose another.", 'Port conflict', 'OK', 'Error') | Out-Null
            return
        }

        if ($State.ContainerLocation -like 'REMOTE@*') {
            if (-not (Test-RemoteSSHKeyFiles -State $State)) {
                [System.Windows.Forms.MessageBox]::Show('Remote SSH key or known_hosts missing. Re-run key setup.', 'SSH missing', 'OK', 'Error') | Out-Null
                return
            }
        }

        $otherRunning = $State.Metadata.ExistingContainers | Where-Object { $_.Name -ne $State.ContainerName -and $_.Status -match '^Up' }
        if ($otherRunning -and $otherRunning.Count -gt 0) {
            $names = ($otherRunning | ForEach-Object { $_.Name }) -join ', '
            $choice = [System.Windows.Forms.MessageBox]::Show("Other containers are running: $names`nContinue starting another?",'Other containers running','YesNo','Warning')
            if ($choice -ne [System.Windows.Forms.DialogResult]::Yes) { return }
        }

        $projectRoot = if ($State.ContainerLocation -eq 'LOCAL') { $State.Paths.LocalRepo } else { $State.Paths.RemoteRepo }
        if (-not $projectRoot) { [System.Windows.Forms.MessageBox]::Show('Repository path missing; restart and select again.','Missing path','OK','Error') | Out-Null; return }
        $dockerSetup = if ($State.ContainerLocation -eq 'LOCAL') { Join-Path $projectRoot 'docker_setup' } else { "$projectRoot/docker_setup" }
        if ($State.ContainerLocation -eq 'LOCAL' -and -not (Test-Path $dockerSetup)) {
            [System.Windows.Forms.MessageBox]::Show("docker_setup folder not found at $dockerSetup","Missing docker_setup",'OK','Error') | Out-Null; return
        }

        # resolve sim_design.yaml
        if (-not [System.IO.Path]::IsPathRooted($simDesign)) {
            $simDesign = ($projectRoot.TrimEnd('/','\') + '/' + ($simDesign -replace '\\','/')) -replace '/+','/'
            if ($State.ContainerLocation -eq 'LOCAL') {
                $resolved = Resolve-Path -Path $simDesign -ErrorAction SilentlyContinue
                if ($resolved) { $simDesign = $resolved.Path }
            }
        }
        if ($State.ContainerLocation -eq 'LOCAL' -and -not (Test-Path $simDesign)) {
            [System.Windows.Forms.MessageBox]::Show("YAML file not found at $simDesign",'Missing YAML','OK','Error') | Out-Null; return
        }

        # Build image name
        $imageName = $State.SelectedRepo.ToLower()

        # Check image exists unless rebuild
        $imageExists = $false
        if (-not $rebuild) {
            $imgCmd = (Get-DockerContextArgs -State $State) + @('images','--format','{{.Repository}}')
            try {
                $imgs = & docker @imgCmd 2>$null | Where-Object { $_ -eq $imageName }
                $imageExists = [bool]$imgs
            } catch { $imageExists = $false }
        }

        $dockerfileMain = if ($State.ContainerLocation -eq 'LOCAL') { Join-Path $dockerSetup 'Dockerfile.IMPACTncdGER' } else { "$dockerSetup/Dockerfile.IMPACTncdGER" }
        $dockerContext  = $projectRoot
        if (-not $dockerContext) {
            [System.Windows.Forms.MessageBox]::Show('Repository path missing; cannot build image.','Missing path','OK','Error') | Out-Null
            return
        }

        if (-not $imageExists) {
            Write-Log "Building image $imageName (streaming output)..." 'Info'
            # Build args as single string with quoted paths to survive spaces (parity with v1 streaming)
            $buildArgsString = "build --build-arg REPO_NAME=$($State.SelectedRepo) -f `"$dockerfileMain`" -t $imageName --no-cache --progress=plain `".`""
            $buildSucceeded = $false
            $buildStart = Get-Date
            try {
                if ($State.ContainerLocation -eq 'LOCAL') {
                    # Stream docker build output directly to console (parity with v1)
                    Push-Location $dockerContext
                    try {
                        $p = Start-Process -FilePath 'docker' -ArgumentList $buildArgsString -Wait -PassThru -NoNewWindow
                        $buildSucceeded = ($p.ExitCode -eq 0)
                    } finally { Pop-Location }
                } else {
                    $remoteHost = Get-RemoteHostString -State $State
                    $sshKey = $State.Paths.SshPrivate
                    $cmd = "cd '$dockerContext' && docker build --build-arg REPO_NAME=$($State.SelectedRepo) -f '$dockerfileMain' -t '$imageName' --no-cache ."
                    $sshArgs = @('-o','ConnectTimeout=30','-o','BatchMode=yes','-o','PasswordAuthentication=no','-o','PubkeyAuthentication=yes','-o','IdentitiesOnly=yes','-i',"$sshKey",$remoteHost,$cmd)
                    $p = Start-Process -FilePath 'ssh' -ArgumentList $sshArgs -Wait -NoNewWindow -PassThru
                    $buildSucceeded = ($p.ExitCode -eq 0)
                }
            } catch {
                $buildSucceeded = $false
            }

            if (-not $buildSucceeded) {
                Write-Log 'Main image build failed; attempting prerequisite build fallback.' 'Warn'
                $prereqDockerfile = if ($State.ContainerLocation -eq 'LOCAL') { Join-Path $dockerSetup 'Dockerfile.prerequisite.IMPACTncdGER' } else { "$dockerSetup/Dockerfile.prerequisite.IMPACTncdGER" }
                $prereqContext = if ($State.ContainerLocation -eq 'LOCAL') { Join-Path $dockerSetup '.' } else { "$dockerSetup" }
                $prereqArgsString = "build -f `"$prereqDockerfile`" -t $imageName-prerequisite --no-cache --progress=plain `".`""
                $preSuccess = $false
                try {
                    if ($State.ContainerLocation -eq 'LOCAL') {
                        Push-Location $prereqContext
                        try {
                            $p2 = Start-Process -FilePath 'docker' -ArgumentList $prereqArgsString -Wait -PassThru -NoNewWindow
                            $preSuccess = ($p2.ExitCode -eq 0)
                        } finally { Pop-Location }
                    } else {
                        $remoteHost = Get-RemoteHostString -State $State
                        $sshKey = $State.Paths.SshPrivate
                        $cmd2 = "cd '$prereqContext' && docker build -f '$prereqDockerfile' -t '$imageName-prerequisite' --no-cache ."
                        $sshArgs2 = @('-o','ConnectTimeout=30','-o','BatchMode=yes','-o','PasswordAuthentication=no','-o','PubkeyAuthentication=yes','-o','IdentitiesOnly=yes','-i',"$sshKey",$remoteHost,$cmd2)
                        $p2 = Start-Process -FilePath 'ssh' -ArgumentList $sshArgs2 -Wait -NoNewWindow -PassThru
                        $preSuccess = ($p2.ExitCode -eq 0)
                    }
                } catch { $preSuccess = $false }

                if (-not $preSuccess) {
                    [System.Windows.Forms.MessageBox]::Show('Docker build failed (including prerequisite fallback).','Build failed','OK','Error') | Out-Null
                    return
                }

                # Retry main build after prerequisite
                try {
                    if ($State.ContainerLocation -eq 'LOCAL') {
                        Push-Location $dockerContext
                        try {
                            $p3 = Start-Process -FilePath 'docker' -ArgumentList $buildArgsString -Wait -PassThru -NoNewWindow
                            $buildSucceeded = ($p3.ExitCode -eq 0)
                        } finally { Pop-Location }
                    } else {
                        $remoteHost = Get-RemoteHostString -State $State
                        $sshKey = $State.Paths.SshPrivate
                        $cmd3 = "cd '$dockerContext' && docker build --build-arg REPO_NAME=$($State.SelectedRepo) -f '$dockerfileMain' -t '$imageName' --no-cache ."
                        $sshArgs3 = @('-o','ConnectTimeout=30','-o','BatchMode=yes','-o','PasswordAuthentication=no','-o','PubkeyAuthentication=yes','-o','IdentitiesOnly=yes','-i',"$sshKey",$remoteHost,$cmd3)
                        $p3 = Start-Process -FilePath 'ssh' -ArgumentList $sshArgs3 -Wait -NoNewWindow -PassThru
                        $buildSucceeded = ($p3.ExitCode -eq 0)
                    }
                } catch { $buildSucceeded = $false }
            }

            $elapsed = (Get-Date) - $buildStart
            Write-Log "Docker build duration: $([int]$elapsed.TotalSeconds)s" 'Info'
            Write-Log "Docker build success=$buildSucceeded" 'Debug'
            if (-not $buildSucceeded) {
                [System.Windows.Forms.MessageBox]::Show('Docker build failed. See console output for details.','Build failed','OK','Error') | Out-Null
                return
            }
        }

        # Capture git baseline best-effort
        $State.Metadata.GitBaseline = $null
        try {
            if ($State.ContainerLocation -eq 'LOCAL') {
                Push-Location $projectRoot
                $hash = git rev-parse HEAD 2>$null
                $status = git status --porcelain 2>$null
                Pop-Location
                $State.Metadata.GitBaseline = @{ Repo=$projectRoot; Commit=$hash; Status=$status; Timestamp=Get-Date }
            } else {
                $remoteHost = Get-RemoteHostString -State $State
                $keyPath = $State.Paths.SshPrivate
                $hash = & ssh -i $keyPath -o IdentitiesOnly=yes -o ConnectTimeout=15 -o BatchMode=yes $remoteHost "cd '$projectRoot' && git rev-parse HEAD" 2>$null
                $status = & ssh -i $keyPath -o IdentitiesOnly=yes -o ConnectTimeout=15 -o BatchMode=yes $remoteHost "cd '$projectRoot' && git status --porcelain" 2>$null
                $State.Metadata.GitBaseline = @{ Repo=$projectRoot; Commit=$hash; Status=$status; Timestamp=Get-Date }
            }
        } catch { $State.Metadata.GitBaseline = $null }

        # Resolve output/synthpop from sim_design
        $baseDirForYaml = ($projectRoot -replace '\\','/')
        $outputDir = Get-YamlPathValue -State $State -YamlPath $simDesign -Key 'output_dir' -BaseDir $baseDirForYaml
        $synthDir  = Get-YamlPathValue -State $State -YamlPath $simDesign -Key 'synthpop_dir' -BaseDir $baseDirForYaml
        if (-not (Test-AndCreateDirectory -State $State -Path $outputDir -PathKey 'output_dir')) { [System.Windows.Forms.MessageBox]::Show('Failed to ensure output_dir.','Path error','OK','Error') | Out-Null; return }
        if (-not (Test-AndCreateDirectory -State $State -Path $synthDir -PathKey 'synthpop_dir')) { [System.Windows.Forms.MessageBox]::Show('Failed to ensure synthpop_dir.','Path error','OK','Error') | Out-Null; return }

        $State.Paths.OutputDir = $outputDir
        $State.Paths.SynthpopDir = $synthDir

        $repoMountSource = if ($State.ContainerLocation -eq 'LOCAL') { Convert-PathToDockerFormat -Path $projectRoot } else { $projectRoot }

        $dockerArgs = @('run','-d','--rm','--name',$State.ContainerName,
            '-e',"PASSWORD=$($State.Password)",
            '-e','DISABLE_AUTH=false',
            '-e','USERID=1000','-e','GROUPID=1000',
            '-e',"GIT_SSH_COMMAND=ssh -i /keys/id_ed25519_$($State.UserName) -o IdentitiesOnly=yes -o UserKnownHostsFile=/etc/ssh/ssh_known_hosts -o StrictHostKeyChecking=yes",
            '--mount',"type=bind,source=$repoMountSource,target=/host-repo",
            '--mount',"type=bind,source=$repoMountSource,target=/home/rstudio/$($State.SelectedRepo)",
            '-e','REPO_SYNC_PATH=/host-repo','-e','SYNC_ENABLED=true',
            '-p',($(if($portOverride){$portOverride}else{'8787'}) + ':8787')
        )

        if ($customParams) {
            $dockerArgs += ($customParams -split '\s+')
        }

        if ($State.ContainerLocation -eq 'LOCAL') {
            $sshKeyPath = $State.Paths.SshPrivate
            $knownHostsPath = "$HOME/.ssh/known_hosts"
        } else {
            $sshKeyPath = "/home/$($State.RemoteUser)/.ssh/id_ed25519_$($State.UserName)"
            $knownHostsPath = "/home/$($State.RemoteUser)/.ssh/known_hosts"
        }

        if ($useVolumes) {
            $volOut = "impactncd_germany_output_$($State.UserName)" -replace '[^a-zA-Z0-9_]','_'
            $volSyn = "impactncd_germany_synthpop_$($State.UserName)" -replace '[^a-zA-Z0-9_]','_'
            $State.Metadata.VolumeOutput = $volOut
            $State.Metadata.VolumeSynthpop = $volSyn

            $ctxPrefix = Get-DockerContextArgs -State $State

            # Ensure rsync-alpine exists (for later sync)
            & docker @ctxPrefix @('image','inspect','rsync-alpine') 2>$null
            if ($LASTEXITCODE -ne 0) {
                $dockerfileInline = "FROM alpine:latest`nRUN apk add --no-cache rsync"
                if ($State.ContainerLocation -like 'REMOTE@*') {
                    $dockerfileInline | & docker @ctxPrefix @('build','-t','rsync-alpine','-f','-','.')
                } else {
                    $dockerfileInline | & docker build -t rsync-alpine -f - .
                }
            }

            & docker @ctxPrefix @('volume','rm',$volOut,'-f') 2>$null
            & docker @ctxPrefix @('volume','rm',$volSyn,'-f') 2>$null
            & docker @ctxPrefix @('volume','create',$volOut) | Out-Null
            & docker @ctxPrefix @('volume','create',$volSyn) | Out-Null

            # Fix ownership
            & docker @ctxPrefix @('run','--rm','-v',"${volOut}:/volume",'alpine','sh','-c',"chown 1000:1000 /volume") 2>$null
            & docker @ctxPrefix @('run','--rm','-v',"${volSyn}:/volume",'alpine','sh','-c',"chown 1000:1000 /volume") 2>$null

            # Pre-populate volumes from host dirs
            $dockerOutputSource = if ($State.ContainerLocation -eq 'LOCAL') { Convert-PathToDockerFormat -Path $outputDir } else { $outputDir }
            $dockerSynthSource  = if ($State.ContainerLocation -eq 'LOCAL') { Convert-PathToDockerFormat -Path $synthDir } else { $synthDir }
            & docker @ctxPrefix @('run','--rm','--user','1000:1000','-v',"${dockerOutputSource}:/source",'-v',"${volOut}:/volume",'alpine','sh','-c','cp -r /source/. /volume/ 2>/dev/null || cp -a /source/. /volume/ 2>/dev/null || true') 2>$null
            & docker @ctxPrefix @('run','--rm','--user','1000:1000','-v',"${dockerSynthSource}:/source",'-v',"${volSyn}:/volume",'alpine','sh','-c','cp -r /source/. /volume/ 2>/dev/null || cp -a /source/. /volume/ 2>/dev/null || true') 2>$null

            $dockerArgs += @('-v',"$($volOut):/home/rstudio/$($State.SelectedRepo)/outputs",
                             '-v',"$($volSyn):/home/rstudio/$($State.SelectedRepo)/inputs/synthpop")
        } else {
            $outDocker = if ($State.ContainerLocation -eq 'LOCAL') { Convert-PathToDockerFormat -Path $outputDir } else { $outputDir }
            $synDocker = if ($State.ContainerLocation -eq 'LOCAL') { Convert-PathToDockerFormat -Path $synthDir } else { $synthDir }
            # repo already mounted above; only bind outputs and synthpop to avoid duplicate mount targets
            $dockerArgs += @('--mount',"type=bind,source=$outDocker,target=/home/rstudio/$($State.SelectedRepo)/outputs",
                             '--mount',"type=bind,source=$synDocker,target=/home/rstudio/$($State.SelectedRepo)/inputs/synthpop")
        }

        if ($highComp -and $State.ContainerLocation -like 'REMOTE@*') {
            $dockerArgs += @('--cpus','32','-m','384g')
        }

        $dockerArgs += @('--mount',"type=bind,source=$sshKeyPath,target=/keys/id_ed25519_$($State.UserName),readonly",
                         '--mount',"type=bind,source=$knownHostsPath,target=/etc/ssh/ssh_known_hosts,readonly",
                         '--workdir',"/home/rstudio/$($State.SelectedRepo)",
                         $imageName)

        $runCmd = (Get-DockerContextArgs -State $State) + $dockerArgs

        $rc = & docker $runCmd 2>&1
        if ($LASTEXITCODE -ne 0) {
            [System.Windows.Forms.MessageBox]::Show("Failed to start container: $rc",'Container start failed','OK','Error') | Out-Null
            return
        }

        if ($State.ContainerLocation -like 'REMOTE@*') {
            $portStore = if ($portOverride) { $portOverride } else { '8787' }
            Write-RemoteContainerMetadata -State $State -Password $State.Password -Port $portStore -UseVolumes $useVolumes
        }

        $State.Metadata.ContainerRunning = $true
        $State.Metadata.ActiveUseVolumes = $useVolumes
        $State.Metadata.ActiveRepoPath = $projectRoot
        $State.Metadata.ActiveIsRemote = ($State.ContainerLocation -like 'REMOTE@*')
        $State.Metadata.ActivePort = if ($portOverride) { $portOverride } else { '8787' }

        $btnStart.Enabled = $false
        $btnStop.Enabled = $true
        $lblStatus.Text = ''
        Update-InfoBox -Status 'RUNNING'
        Write-Log "Container $($State.ContainerName) started." 'Info'

        $hostDisplay = if ($State.ContainerLocation -eq 'LOCAL') { "http://localhost:$($State.Metadata.ActivePort)" } else { "http://$($State.RemoteHostIp):$($State.Metadata.ActivePort)" }
        Write-Host "Container ready: $hostDisplay (user: rstudio, password: $($State.Password))" -ForegroundColor Green
    })

    $btnStop.Add_Click({
        $ctxArgs = Get-DockerContextArgs -State $State
        $runCmd = $ctxArgs + @('ps','--filter',"name=^$($State.ContainerName)$",'--format','{{.Names}}')
        $exists = & docker $runCmd 2>$null
        if (-not $exists) { Update-InfoBox -Status 'STOPPED'; $btnStart.Enabled=$true; $btnStop.Enabled=$false; return }

        $stopCmd = $ctxArgs + @('stop',$State.ContainerName)
        Write-Log "Stopping container $($State.ContainerName)" 'Info'
        & docker $stopCmd 2>$null
        if ($LASTEXITCODE -ne 0) {
            [System.Windows.Forms.MessageBox]::Show('Failed to stop container; check Docker.','Stop failed','OK','Error') | Out-Null
            return
        }

        # Sync volumes back if used
        $useVolumesForStop = if ($State.Metadata.ActiveUseVolumes -ne $null) { $State.Metadata.ActiveUseVolumes } else { $chkVolumes.Checked }
        Write-Log "Stop clicked; volumesUsed=$useVolumesForStop" 'Debug'
        if ($useVolumesForStop) {
            $ctxPrefix = Get-DockerContextArgs -State $State
            if (-not $State.Metadata.VolumeOutput) {
                $State.Metadata.VolumeOutput = "impactncd_germany_output_$($State.UserName)" -replace '[^a-zA-Z0-9_]','_'
            }
            if (-not $State.Metadata.VolumeSynthpop) {
                $State.Metadata.VolumeSynthpop = "impactncd_germany_synthpop_$($State.UserName)" -replace '[^a-zA-Z0-9_]','_'
            }

            $volOut = $State.Metadata.VolumeOutput
            $volSyn = $State.Metadata.VolumeSynthpop
            if ($volOut -and $volSyn) {
                $outBackup = if ($State.ContainerLocation -eq 'LOCAL') { Convert-PathToDockerFormat -Path $State.Paths.OutputDir } else { $State.Paths.OutputDir }
                $synBackup = if ($State.ContainerLocation -eq 'LOCAL') { Convert-PathToDockerFormat -Path $State.Paths.SynthpopDir } else { $State.Paths.SynthpopDir }
                Write-Log "Syncing volumes back -> outVol=$volOut to $outBackup; synVol=$volSyn to $synBackup" 'Debug'
                & docker @ctxPrefix @('run','--rm','-v',"$($volOut):/volume",'-v',"$($outBackup):/backup",'rsync-alpine','rsync','-avc','--no-owner','--no-group','--no-times','--no-perms','--chmod=ugo=rwX','/volume/','/backup/') 2>$null
                & docker @ctxPrefix @('run','--rm','-v',"$($volSyn):/volume",'-v',"$($synBackup):/backup",'rsync-alpine','rsync','-avc','--no-owner','--no-group','--no-times','--no-perms','--chmod=ugo=rwX','/volume/','/backup/') 2>$null
                & docker @ctxPrefix @('volume','rm',$volOut,$volSyn,'-f') 2>$null
            }
        }

        $State.Metadata.ContainerRunning = $false

        if ($State.ContainerLocation -like 'REMOTE@*') { Remove-RemoteContainerMetadata -State $State }

        Update-InfoBox -Status 'STOPPED'
        $btnStart.Enabled = $true
        $btnStop.Enabled  = $false
        Write-Log "Container $($State.ContainerName) stopped." 'Info'

        if ($State.Metadata.ActiveRepoPath) {
            Invoke-GitChangeDetection -State $State -RepoPath $State.Metadata.ActiveRepoPath -IsRemote $State.Metadata.ActiveIsRemote
        }

        $lblStatus.Text = 'All done. You can close this window or start another container.'
        Write-Host "All done. You can close this window or start another container." -ForegroundColor Green
    })

    $btnClose.Add_Click({ $form.Close() })

    $null = $form.ShowDialog()
}

# Coordinator: orchestrates all steps with clear sequencing and early validation.
function Invoke-ImpactGui {
    Write-Log 'Starting IMPACT Docker GUI workflow.' 'Info'
    Ensure-PowerShell7 -PS7RequestedFlag:$PS7Requested.IsPresent
    $state = New-SessionState

    $state.Metadata.BuildInfo = Get-BuildInfo
    $bi = $state.Metadata.BuildInfo
    Write-Log ("Build info -> Version={0} Commit={1} Built={2}" -f $bi.Version, $bi.Commit, $bi.Built) 'Info'

    Ensure-Prerequisites -State $state
    if (-not (Show-CredentialDialog -State $state)) { return }
    if (-not (Ensure-GitKeySetup -State $state)) { return }
    if (-not (Select-Location -State $state)) { return }

    if ($state.ContainerLocation -like 'REMOTE@*') {
           if (-not (Ensure-RemotePreparation -State $state)) { return }
    } elseif ($state.ContainerLocation -eq 'LOCAL') {
        if (-not (Ensure-LocalPreparation -State $state)) { return }
    } else {
        Write-Log "No container location selected; exiting." 'Warn'
        return
    }

    Get-ContainerStatus -State $state
    Show-ContainerManager -State $state
}

Invoke-ImpactGui
