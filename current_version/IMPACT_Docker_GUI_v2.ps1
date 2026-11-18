<# IMPACT Docker GUI v2 #>
<# This is the launcher script. Core functions live in IMPACT_Docker_GUI.psm1 #>

[CmdletBinding()]
param(
    [switch]$ElevatedRestart,
    [switch]$PS7Requested
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Determine the directory where this script lives.
if ($PSScriptRoot -and (Test-Path $PSScriptRoot)) {
    $script:ScriptDir = $PSScriptRoot
} else {
    # Fallback: use the process executable's directory
    $script:ScriptDir = Split-Path -Parent ([System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)
}

# Import the companion module (same directory as this script)
$modulePath = Join-Path $script:ScriptDir 'IMPACT_Docker_GUI.psm1'
if (Test-Path $modulePath) {
    Import-Module $modulePath -Force -DisableNameChecking
} else {
    Write-Host "ERROR: Module not found at $modulePath" -ForegroundColor Red
    Write-Host "The file 'IMPACT_Docker_GUI.psm1' must be in the same folder as this script." -ForegroundColor Red
    Write-Host ""
    try { Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue; [System.Windows.Forms.MessageBox]::Show("IMPACT cannot start because 'IMPACT_Docker_GUI.psm1' is missing from the application folder.`nPlease place the module next to the script and retry.", 'IMPACT - Module missing', 'OK', 'Error') | Out-Null } catch {}
    Write-Host "Press any key to exit..." -ForegroundColor Yellow
    $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
    exit 1
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
        '-n',
        '-i', $State.Paths.SshPrivate,
        '-o', 'IdentitiesOnly=yes',
        '-o', 'BatchMode=yes',
        '-o', 'StrictHostKeyChecking=accept-new',
        '-o', 'ConnectTimeout=10',
        $remoteHost
    )

    $sshKeyPath = $State.Paths.SshPrivate

    # Validate/repair SSH config entry BEFORE any SSH operations.
    # If a previous session wrote a config entry pointing to a key that was later deleted,
    # SSH (and Docker over SSH) will fail because IdentitiesOnly=yes prevents fallback.
    Ensure-SshConfigEntry -RemoteHostIp $remoteIp -RemoteUser $remoteUser -IdentityFile $sshKeyPath

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

# Clean up stale pub files left by previous bug (extra underscore before .pub)
STALE_PUB="$USER_SSH_DIR/id_ed25519_{1}_.pub"
[ -f "$STALE_PUB" ] && rm -f "$STALE_PUB"

# Remove any previous keys for this IMPACT user (comment marker: IMPACT_{1})
sed -i '/IMPACT_{1}/d' "$AUTH_KEYS" 2>/dev/null || true
# Also remove stale markers with trailing underscore from old bug
sed -i '/IMPACT_{1}_/d' "$AUTH_KEYS" 2>/dev/null || true

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
KEY_TARGET_PUB="$USER_SSH_DIR/id_ed25519_%%USERNAME%%.pub"
REMOTE_TEMP="%%REMOTE_TEMP%%"

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

# Remove any previous keys for this IMPACT user (comment marker: IMPACT_%%USERNAME%%)
sed -i '/IMPACT_%%USERNAME%%/d' "$AUTH_KEYS" 2>/dev/null || true

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

# Clean up stale pub files left by previous bug (extra underscore before .pub)
STALE_PUB="$USER_SSH_DIR/id_ed25519_%%USERNAME%%_.pub"
[ -f "$STALE_PUB" ] && rm -f "$STALE_PUB"

rm -f "$REMOTE_TEMP"
echo SSH_KEY_COPIED
'@
                                $remoteInstallScript = $remoteInstallScript.Replace('%%USERNAME%%', $State.UserName).Replace('%%REMOTE_TEMP%%', $remoteTemp)
                                $remoteInstallScript = $remoteInstallScript -replace "`r`n","`n" -replace "`r","`n"
                $cmdResult = Invoke-SSHCommand -SessionId $sshSession.SessionId -Command $remoteInstallScript -TimeOut 60 -ErrorAction Stop
                Write-Log "Posh-SSH install exit=$($cmdResult.ExitStatus); output length=$($cmdResult.Output.Length)" 'Debug'
                if ($cmdResult.Output -match 'SSH_KEY_COPIED') { $keyAuthorized = $true }
            }
        } catch {
            Write-Log "Posh-SSH bootstrap failed: $($_.Exception.Message)" 'Warn'
        } finally {
            if ($sshSession) { try { Remove-SSHSession -SessionId $sshSession.SessionId -ErrorAction SilentlyContinue | Out-Null } catch { } }
            if (Get-Variable tempKeyFile -Scope 0 -ErrorAction SilentlyContinue) { try { Remove-Item $tempKeyFile -Force -ErrorAction SilentlyContinue; Write-Log 'Removed temporary key file.' 'Debug' } catch { } }
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

    Write-Log "SSH key authorized on remote host for user $($State.UserName)." 'Info'

    # SSH config was already validated/created at the top of this function.

    # Sync SSH private key and known_hosts onto remote for Git inside container
    Write-Log 'Syncing SSH private key and known_hosts to remote host.' 'Info'

    if (Test-Path $sshKeyPath) {
        $pkContent = Get-Content $sshKeyPath -Raw
        $pkB64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($pkContent))
        $copyPrivateCmd = "mkdir -p ~/.ssh && chmod 700 ~/.ssh && rm -f ~/.ssh/id_ed25519_$($State.UserName) && echo '$pkB64' | base64 -d | tr -d '\r' > ~/.ssh/id_ed25519_$($State.UserName) && chmod 600 ~/.ssh/id_ed25519_$($State.UserName) && chown ${remoteUser}:${remoteUser} ~/.ssh/id_ed25519_$($State.UserName) && echo PRIVATE_KEY_COPIED"
        $pkOut = & ssh @sshArgs $copyPrivateCmd 2>&1
        if ($pkOut -notmatch 'PRIVATE_KEY_COPIED') { Write-Log "Remote private key copy may have failed: $pkOut" 'Warn' }
    } else {
        Write-Log "Local private key not found at $sshKeyPath; skipping remote copy." 'Warn'
    }

    $knownHostsPath = Join-Path $HOME '.ssh/known_hosts'
    if (Test-Path $knownHostsPath) {
        $khContent = Get-Content $knownHostsPath -Raw
        $khB64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($khContent))
        $copyKhCmd = "mkdir -p ~/.ssh && chmod 700 ~/.ssh && rm -f ~/.ssh/known_hosts && echo '$khB64' | base64 -d | tr -d '\r' > ~/.ssh/known_hosts && chmod 644 ~/.ssh/known_hosts && chown ${remoteUser}:${remoteUser} ~/.ssh/known_hosts && echo KNOWN_HOSTS_COPIED"
        $khOut = & ssh @sshArgs $copyKhCmd 2>&1
        if ($khOut -notmatch 'KNOWN_HOSTS_COPIED') { Write-Log "Remote known_hosts copy may have failed: $khOut" 'Warn' }
    } else {
        $createKhCmd = "mkdir -p ~/.ssh && chmod 700 ~/.ssh && rm -f ~/.ssh/known_hosts && touch ~/.ssh/known_hosts && chmod 644 ~/.ssh/known_hosts && chown ${remoteUser}:${remoteUser} ~/.ssh/known_hosts && echo KNOWN_HOSTS_EMPTY"
        & ssh @sshArgs $createKhCmd 2>&1 | Out-Null
        Write-Log 'Created empty known_hosts on remote host.' 'Debug'
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
    $palette = Get-ThemePalette
    $listBox.BackColor = $palette.Panel
    $listBox.ForeColor = $palette.Text
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
        $sshCheckArgs = @('-n', '-i', $State.Paths.SshPrivate, '-o', 'IdentitiesOnly=yes', '-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=accept-new', '-o', 'ConnectTimeout=15', $remoteHost)
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
                $startArgs = @('-i', $State.Paths.SshPrivate, '-o', 'IdentitiesOnly=yes', '-o', 'StrictHostKeyChecking=accept-new', '-o', 'ConnectTimeout=30', '-t', $remoteHost, 'sudo systemctl start docker')
                $p = Start-Process -FilePath 'ssh' -ArgumentList $startArgs -Wait -PassThru -NoNewWindow
                if ($p.ExitCode -eq 0) {
                    Write-Log 'sudo systemctl start docker completed.' 'Info'
                    # Wait briefly for the daemon socket to become available
                    Start-Sleep -Seconds 3
                    # Re-check
                    $sshCheckArgs2 = @('-n', '-i', $State.Paths.SshPrivate, '-o', 'IdentitiesOnly=yes', '-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=accept-new', '-o', 'ConnectTimeout=15', $remoteHost)
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
        $sshGroupArgs = @('-n', '-i', $State.Paths.SshPrivate, '-o', 'IdentitiesOnly=yes', '-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=accept-new', '-o', 'ConnectTimeout=15', $remoteHost)
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

    Write-Log 'Checking local Docker availability and context.' 'Info'

    try {
        $dockerVersion = & docker --version 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Log "Docker CLI returned non-zero exit code (exit=$LASTEXITCODE). Output: $dockerVersion" 'Error'
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
        Write-Log "Docker engine is running (version: $quickCheck)." 'Info'
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
    Write-Log "Checking status of container '$($State.ContainerName)' on $($State.ContainerLocation)." 'Info'

    Set-DockerSSHEnvironment -State $State
    $ctxArgs = Get-DockerContextArgs -State $State

    $portUsers = @()
    try {
        $psCmd = $ctxArgs + @('ps','--format','{{.Names}}\t{{.Ports}}')
        $all = & docker @psCmd 2>$null
        if ($LASTEXITCODE -eq 0 -and $all) {
            foreach ($line in ($all -split "`n")) {
                # Any host address (0.0.0.0, [::], or 127.0.0.1 for LOCAL containers, F13);
                # same pattern as Get-UsedPorts in the module.
                foreach ($m in [regex]::Matches($line, ':(\d{4,5})->8787/tcp')) {
                    $port = $m.Groups[1].Value
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
    if ($isRunning) {
        Write-Log "Container '$($State.ContainerName)' is currently running." 'Debug'
    } else {
        Write-Log "Container '$($State.ContainerName)' is not running." 'Debug'
    }

    # Always start from empty recovered details (F32). They used to be reset only when
    # the container was running, so after Stop + Back the old password, port and
    # volume flag of a previous container were shown again for a new one.
    $State.Metadata.Recovered = @{ Password = $null; Port = $null; UseVolumes = $false; OutputDir = $null; SynthpopDir = $null; VolumeOutput = $null; VolumeSynthpop = $null }

    # If running, attempt to recover connection details
    if ($isRunning) {
        $metaUseVolumes = $null
        if ($State.ContainerLocation -like 'REMOTE@*') {
            $meta = Read-RemoteContainerMetadata -State $State
            if ($meta) {
                # Check each property before reading it: StrictMode throws on missing
                # properties, and newer metadata files no longer contain the password (F40).
                if ($meta.PSObject.Properties['password'] -and $meta.password) { $State.Metadata.Recovered.Password = $meta.password }
                if ($meta.PSObject.Properties['port'] -and $meta.port) { $State.Metadata.Recovered.Port = $meta.port }
                if ($meta.PSObject.Properties['useVolumes'] -and $null -ne $meta.useVolumes) { $metaUseVolumes = [bool]$meta.useVolumes }
            }
        }
        # Always inspect the container itself: it is the most reliable source and, through
        # its labels and mounts, the only one that also works for LOCAL containers (F04).
        $runtime = Get-ContainerRuntimeInfo -State $State
        if ($runtime.Password) { $State.Metadata.Recovered.Password = $runtime.Password }
        if ($runtime.Port) { $State.Metadata.Recovered.Port = $runtime.Port }
        if ($null -ne $runtime.UseVolumes) {
            $State.Metadata.Recovered.UseVolumes = [bool]$runtime.UseVolumes
        } elseif ($null -ne $metaUseVolumes) {
            $State.Metadata.Recovered.UseVolumes = $metaUseVolumes
        }
        # Where results must be copied back to at Stop, and which volumes hold them.
        $State.Metadata.Recovered.OutputDir = $runtime.OutputDir
        $State.Metadata.Recovered.SynthpopDir = $runtime.SynthpopDir
        $State.Metadata.Recovered.VolumeOutput = $runtime.VolumeOutput
        $State.Metadata.Recovered.VolumeSynthpop = $runtime.VolumeSynthpop
    }
    return $State
}

# 6. Container management UI
function Show-ContainerManager {
    param([pscustomobject]$State)
    if (-not $State.Metadata.ContainsKey('Recovered') -or -not $State.Metadata.Recovered) {
        $State.Metadata.Recovered = @{ UseVolumes = $false; Password = $null; Port = $null; OutputDir = $null; SynthpopDir = $null; VolumeOutput = $null; VolumeSynthpop = $null }
    }
    if (-not $State.Metadata.ContainsKey('ActivePort')) { $State.Metadata.ActivePort = $null }
    if (-not $State.Metadata.ContainsKey('ActiveUseVolumes')) { $State.Metadata.ActiveUseVolumes = $false }
    if (-not $State.Metadata.ContainsKey('ActiveRepoPath')) { $State.Metadata.ActiveRepoPath = $null }
    if (-not $State.Metadata.ContainsKey('ActiveIsRemote')) { $State.Metadata.ActiveIsRemote = $false }
    Write-Log 'Opening container manager UI.' 'Info'
    $isRunning = $State.Metadata.ContainerRunning
    if (-not $isRunning) {
        # Nothing is running for this repo, so forget the port and volume mode of a
        # container from earlier in this session (for example after Stop and Back),
        # otherwise the info box would show a stale port (F32).
        $State.Metadata.ActivePort = $null
        $State.Metadata.ActiveUseVolumes = $false
    }
    if ($isRunning) {
        $portDisplay = if ($State.Metadata.Recovered.Port) { ($State.Metadata.Recovered.Port -split '\s+')[0] } else { '8787' }
        $passDisplay = if ($State.Metadata.Recovered.Password) { $State.Metadata.Recovered.Password } else { $State.Password }
        $hostDisplay = if ($State.ContainerLocation -eq 'LOCAL') { "http://localhost:$portDisplay" } else { "http://$($State.RemoteHostIp):$portDisplay" }
        $maskedPass = [string]::new([char]0x2022, [Math]::Max($passDisplay.Length, 6))
        [System.Windows.Forms.MessageBox]::Show("Container '$($State.ContainerName)' already running.`n`nURL: $hostDisplay`nUser: rstudio`nPassword: $maskedPass","Container already running",'OK','Information') | Out-Null
        Write-Log "Resumed existing container $($State.ContainerName) at $hostDisplay" 'Info'
        $State.Metadata.ActiveRepoPath = if ($State.ContainerLocation -eq 'LOCAL') { $State.Paths.LocalRepo } else { $State.Paths.RemoteRepo }
        $State.Metadata.ActiveIsRemote = ($State.ContainerLocation -like 'REMOTE@*')
        $State.Metadata.ActiveUseVolumes = [bool]$State.Metadata.Recovered.UseVolumes
        $State.Metadata.ActivePort = $portDisplay
        # Restore the result folders recorded on the container (labels). Without them
        # Stop cannot copy results out of the volumes (F01). They stay $null for
        # containers started by older versions; Stop then keeps the volumes and says so.
        $State.Paths.OutputDir = $State.Metadata.Recovered.OutputDir
        $State.Paths.SynthpopDir = $State.Metadata.Recovered.SynthpopDir
        if ($State.Metadata.Recovered.UseVolumes) {
            # Prefer the volume names the container really mounts (read with docker inspect),
            # so containers started by an older version (other naming) are handled too.
            # The computed names are only a fallback.
            $fallbackNames = Get-ImpactVolumeNames -ContainerName $State.ContainerName
            $State.Metadata.VolumeOutput = if ($State.Metadata.Recovered.VolumeOutput) { $State.Metadata.Recovered.VolumeOutput } else { $fallbackNames.Output }
            $State.Metadata.VolumeSynthpop = if ($State.Metadata.Recovered.VolumeSynthpop) { $State.Metadata.Recovered.VolumeSynthpop } else { $fallbackNames.Synthpop }
        }
    }

    $form = New-Object System.Windows.Forms.Form -Property @{
        Text = 'Container Management - IMPACT NCD Germany'
        Size = New-Object System.Drawing.Size(540,510)
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

    # F85: the password in the info box is hidden by default, so it is not exposed when
    # the screen is shared. This box reveals it when the user needs to read it.
    # $uiState is a hashtable so the event handlers below can change it (a plain
    # variable assigned inside a handler would only change a local copy).
    $uiState = @{ ShowPassword = $false; Status = 'STOPPED' }
    $chkShowPass = New-Object System.Windows.Forms.CheckBox -Property @{ Text='Show password'; Location=New-Object System.Drawing.Point(300,272); Size=New-Object System.Drawing.Size(200,22) }
    Style-CheckBox -CheckBox $chkShowPass
    $form.Controls.Add($chkShowPass)

    $lblPort = New-Object System.Windows.Forms.Label -Property @{ Text='Port (8787-8799)'; Location=New-Object System.Drawing.Point(20,304); Size=New-Object System.Drawing.Size(110,22) }
    $defaultPort = if ($State.Metadata.Recovered.Port) { $State.Metadata.Recovered.Port } else { Get-NextAvailablePort -UsedPorts $State.Ports.Used }
    $txtPort = New-Object System.Windows.Forms.TextBox -Property @{ Location=New-Object System.Drawing.Point(136,302); Size=New-Object System.Drawing.Size(90,24); Text=$defaultPort }
    Style-Label -Label $lblPort
    Style-TextBox -TextBox $txtPort
    $toolTip = New-Object System.Windows.Forms.ToolTip
    $toolTip.SetToolTip($txtPort, 'RStudio Server port. Valid range: 8787-8799.')
    $lblPortError = New-Object System.Windows.Forms.Label -Property @{ Text=''; Location=New-Object System.Drawing.Point(136,326); Size=New-Object System.Drawing.Size(200,14) }
    $lblPortError.ForeColor = [System.Drawing.Color]::FromArgb(200,70,70)
    $lblPortError.Font = New-Object System.Drawing.Font('Segoe UI',8,[System.Drawing.FontStyle]::Regular)
    $form.Controls.Add($lblPort); $form.Controls.Add($txtPort); $form.Controls.Add($lblPortError)
    $txtPort.Add_TextChanged({
        $result = Test-PortValue -Port $txtPort.Text.Trim()
        if ($result.Valid) {
            $lblPortError.Text = ''
            $txtPort.BackColor = (Get-ThemePalette).Field
        } else {
            $lblPortError.Text = $result.ErrorMessage
            $txtPort.BackColor = [System.Drawing.Color]::FromArgb(60,30,30)
        }
    })

    $isLocal = ($State.ContainerLocation -eq 'LOCAL')
    if ($isLocal) {
        $chkHigh.Enabled = $false
    }

    $lblParams = New-Object System.Windows.Forms.Label -Property @{ Text='Custom Params'; Location=New-Object System.Drawing.Point(238,304); Size=New-Object System.Drawing.Size(110,22) }
    $txtParams = New-Object System.Windows.Forms.TextBox -Property @{ Location=New-Object System.Drawing.Point(354,302); Size=New-Object System.Drawing.Size(150,24) }
    Style-Label -Label $lblParams
    Style-TextBox -TextBox $txtParams
    $form.Controls.Add($lblParams); $form.Controls.Add($txtParams)

    $defaultYaml = if ($isLocal) { '.\inputs\sim_design_local.yaml' } else { '.\inputs\sim_design.yaml' }
    $lblYaml = New-Object System.Windows.Forms.Label -Property @{ Text='sim_design.yaml'; Location=New-Object System.Drawing.Point(20,344); Size=New-Object System.Drawing.Size(130,22) }
    $txtYaml = New-Object System.Windows.Forms.TextBox -Property @{ Location=New-Object System.Drawing.Point(152,342); Size=New-Object System.Drawing.Size(352,24); Text=$defaultYaml }
    Style-Label -Label $lblYaml
    Style-TextBox -TextBox $txtYaml
    $form.Controls.Add($lblYaml); $form.Controls.Add($txtYaml)

    $lblStatus = New-Object System.Windows.Forms.Label -Property @{ Text=''; Location=New-Object System.Drawing.Point(20,418); Size=New-Object System.Drawing.Size(460,26) }
    Style-Label -Label $lblStatus
    $lblStatus.ForeColor = [System.Drawing.Color]::LightGreen
    $form.Controls.Add($lblStatus)

    $buildInfo = $State.Metadata.BuildInfo
    $footerText = if ($buildInfo) { "Build: $($buildInfo.Version) | Commit: $($buildInfo.Commit) | Built: $($buildInfo.Built)" } else { 'Build: unknown' }
    $lblFooter = New-Object System.Windows.Forms.Label -Property @{ Text=$footerText; Location=New-Object System.Drawing.Point(20,448); Size=New-Object System.Drawing.Size(460,22) }
    Style-Label -Label $lblFooter -Muted:$true
    $form.Controls.Add($lblFooter)

    $btnBack = New-Object System.Windows.Forms.Button -Property @{ Text=[char]0x2190 + ' Back'; Location=New-Object System.Drawing.Point(12,382); Size=New-Object System.Drawing.Size(100,34) }
    Style-Button -Button $btnBack -Variant 'secondary'
    $form.Controls.Add($btnBack)

    $btnClose = New-Object System.Windows.Forms.Button -Property @{ Text='Close'; Location=New-Object System.Drawing.Point(414,382); Size=New-Object System.Drawing.Size(90,34) }
    Style-Button -Button $btnClose -Variant 'secondary'
    $form.Controls.Add($btnClose)
    $form.CancelButton = $btnClose

    $btnBack.Add_Click({
        if ($State.Metadata.ContainerRunning) {
            # F18: if the container already ended on its own, Stop now detects that, copies
            # results out of any Docker volumes and resets this flag, so point the user there.
            [System.Windows.Forms.MessageBox]::Show("Please click 'Stop Container' before going back.`n`n(If the container already ended on its own, Stop tidies up and copies any results back.)",'Container running','OK','Warning') | Out-Null
            return
        }
        $form.Tag = 'back'
        $form.Close()
    })

    $form.Add_FormClosing({
        if ($State.Metadata.ContainerRunning) {
            if ($form.Tag -ne 'back') {
                $answer = [System.Windows.Forms.MessageBox]::Show('A container is still running. Close without stopping?','Container running','YesNo','Warning')
                if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { $_.Cancel = $true }
            }
        }
    })

    function Update-InfoBox {
        param($Status)
        $info.Clear()
        $palette = Get-ThemePalette
        # Remember the status so the 'Show password' box can redraw the same view.
        $uiState.Status = $Status

        $passDisplay = if ($State.Metadata.Recovered.Password) { $State.Metadata.Recovered.Password } else { $State.Password }
        if (-not $uiState.ShowPassword) {
            # Fixed number of dots, so not even the password length is shown.
            $passDisplay = ([string]::new([char]0x2022, 8)) + "   (tick 'Show password' to see it)"
        }
        $portDisplay = if ($State.Metadata.ActivePort) { $State.Metadata.ActivePort } elseif ($State.Metadata.Recovered.Port) { ($State.Metadata.Recovered.Port -split '\s+')[0] } else { '8787' }
        $hostDisplay = if ($State.ContainerLocation -eq 'LOCAL') { "http://localhost:$portDisplay" } else { "http://$($State.RemoteHostIp):$portDisplay" }

        # Status indicator — large and prominent
        $info.SelectionFont = New-Object System.Drawing.Font('Segoe UI Semibold',11,[System.Drawing.FontStyle]::Bold)
        if ($Status -eq 'RUNNING') {
            $info.SelectionColor = $palette.Success
            $info.AppendText("$([char]0x25CF)  RUNNING`n")
        } else {
            $info.SelectionColor = $palette.AccentAlt
            $info.AppendText("$([char]0x25CB)  STOPPED`n")
        }

        # Section separator
        $info.SelectionFont = New-Object System.Drawing.Font('Segoe UI',4,[System.Drawing.FontStyle]::Regular)
        $info.AppendText("`n")

        # Reusable fonts
        $labelFont = New-Object System.Drawing.Font('Segoe UI',9,[System.Drawing.FontStyle]::Regular)
        $bodyFont  = New-Object System.Drawing.Font('Segoe UI',9,[System.Drawing.FontStyle]::Regular)

        # Connection info
        $info.SelectionFont = $labelFont; $info.SelectionColor = $palette.Accent
        $info.AppendText("  URL          ")
        $info.SelectionFont = $bodyFont;  $info.SelectionColor = $palette.Text
        $info.AppendText("$hostDisplay`n")

        $info.SelectionFont = $labelFont; $info.SelectionColor = $palette.Accent
        $info.AppendText("  Login        ")
        $info.SelectionFont = $bodyFont;  $info.SelectionColor = $palette.Text
        $info.AppendText("rstudio`n")

        $info.SelectionFont = $labelFont; $info.SelectionColor = $palette.Accent
        $info.AppendText("  Password     ")
        $info.SelectionFont = $bodyFont;  $info.SelectionColor = $palette.Text
        $info.AppendText("$passDisplay`n")

        # Section separator
        $info.SelectionFont = New-Object System.Drawing.Font('Segoe UI',4,[System.Drawing.FontStyle]::Regular)
        $info.AppendText("`n")

        # Project info
        $info.SelectionFont = $labelFont; $info.SelectionColor = $palette.Accent
        $info.AppendText("  Repository   ")
        $info.SelectionFont = $bodyFont;  $info.SelectionColor = $palette.Text
        $info.AppendText("$($State.SelectedRepo)`n")

        $info.SelectionFont = $labelFont; $info.SelectionColor = $palette.Muted
        $info.AppendText("  Container    ")
        $info.SelectionFont = $bodyFont;  $info.SelectionColor = $palette.Muted
        $info.AppendText("$($State.ContainerName)`n")

        $info.SelectionFont = $labelFont; $info.SelectionColor = $palette.Accent
        $info.AppendText("  Location     ")
        $info.SelectionFont = $bodyFont;  $info.SelectionColor = $palette.Text
        $info.AppendText("$($State.ContainerLocation)`n")
    }
    Update-InfoBox -Status ($(if($isRunning){'RUNNING'}else{'STOPPED'}))
    $lblStatus.Text = ''

    $chkShowPass.Add_CheckedChanged({
        $uiState.ShowPassword = $chkShowPass.Checked
        Update-InfoBox -Status $uiState.Status
    })

    $btnStart.Add_Click({
        $useVolumes = $chkVolumes.Checked
        $rebuild    = $chkRebuild.Checked
        $highComp   = $chkHigh.Checked
        $portOverride = $txtPort.Text.Trim()
        $customParams = $txtParams.Text.Trim()
        $simDesign = $txtYaml.Text.Trim()

        Write-Log ("Start clicked with options -> volumes={0} rebuild={1} highComp={2} port={3} params='{4}' yaml='{5}'" -f $useVolumes,$rebuild,$highComp,$portOverride,$customParams,$simDesign) 'Debug'

        Set-DockerSSHEnvironment -State $State

        if ($State.Metadata.ContainerRunning) {
            [System.Windows.Forms.MessageBox]::Show('Container already running; stop it first or close to reuse.','Already running','OK','Information') | Out-Null
            return
        }

        # Validate port format and range
        $portCheck = Test-PortValue -Port $portOverride
        if (-not $portCheck.Valid) {
            [System.Windows.Forms.MessageBox]::Show($portCheck.ErrorMessage, 'Invalid port', 'OK', 'Error') | Out-Null
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
                    $sshArgs = @('-o','StrictHostKeyChecking=accept-new','-o','ConnectTimeout=30','-o','BatchMode=yes','-o','PasswordAuthentication=no','-o','PubkeyAuthentication=yes','-o','IdentitiesOnly=yes','-i',"$sshKey",$remoteHost,$cmd)
                    $p = Start-Process -FilePath 'ssh' -ArgumentList $sshArgs -Wait -NoNewWindow -PassThru
                    $buildSucceeded = ($p.ExitCode -eq 0)
                }
            } catch {
                $buildSucceeded = $false
            }

            if (-not $buildSucceeded) {
                # If this was a REMOTE build, attempt automatic docker login using the repo .env and retry once
                if ($State.ContainerLocation -like 'REMOTE@*' -and -not $State.Metadata.RemoteLoginAttempted) {
                    Write-Log 'Remote build failed — attempting automatic remote docker login from repo .env and retrying build.' 'Info'
                    $State.Metadata.RemoteLoginAttempted = $true
                    try {
                        if (Ensure-RemoteDockerLogin -State $State -ProjectRoot $projectRoot) {
                            Write-Log 'Remote docker login from .env succeeded — retrying build.' 'Info'
                            $remoteHost = Get-RemoteHostString -State $State
                            $sshKey = $State.Paths.SshPrivate
                            $cmdRetry = "cd '$dockerContext' && docker build --build-arg REPO_NAME=$($State.SelectedRepo) -f '$dockerfileMain' -t '$imageName' --no-cache ."
                            $sshArgsRetry = @('-o','StrictHostKeyChecking=accept-new','-o','ConnectTimeout=30','-o','BatchMode=yes','-o','PasswordAuthentication=no','-o','PubkeyAuthentication=yes','-o','IdentitiesOnly=yes','-i',"$sshKey",$remoteHost,$cmdRetry)
                            $pRetry = Start-Process -FilePath 'ssh' -ArgumentList $sshArgsRetry -Wait -NoNewWindow -PassThru
                            $buildSucceeded = ($pRetry.ExitCode -eq 0)
                            if ($buildSucceeded) { Write-Log 'Remote build succeeded after login; continuing.' 'Info' }
                        } else {
                            Write-Log 'Automatic remote docker login from .env did not provide credentials or failed.' 'Debug'
                        }
                    } catch { Write-Log "Remote login attempt failed: $($_.Exception.Message)" 'Warn' }
                }

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
                        $sshArgs2 = @('-o','StrictHostKeyChecking=accept-new','-o','ConnectTimeout=30','-o','BatchMode=yes','-o','PasswordAuthentication=no','-o','PubkeyAuthentication=yes','-o','IdentitiesOnly=yes','-i',"$sshKey",$remoteHost,$cmd2)
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
                        $sshArgs3 = @('-o','StrictHostKeyChecking=accept-new','-o','ConnectTimeout=30','-o','BatchMode=yes','-o','PasswordAuthentication=no','-o','PubkeyAuthentication=yes','-o','IdentitiesOnly=yes','-i',"$sshKey",$remoteHost,$cmd3)
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
                $hash = & ssh -n -i $keyPath -o StrictHostKeyChecking=accept-new -o IdentitiesOnly=yes -o ConnectTimeout=15 -o BatchMode=yes $remoteHost "cd '$projectRoot' && git rev-parse HEAD" 2>$null
                $status = & ssh -n -i $keyPath -o StrictHostKeyChecking=accept-new -o IdentitiesOnly=yes -o ConnectTimeout=15 -o BatchMode=yes $remoteHost "cd '$projectRoot' && git status --porcelain" 2>$null
                $State.Metadata.GitBaseline = @{ Repo=$projectRoot; Commit=$hash; Status=$status; Timestamp=Get-Date }
            }
            Write-Log "Captured git baseline: commit=$hash" 'Debug'
        } catch {
            Write-Log "Git baseline capture failed: $($_.Exception.Message)" 'Debug'
            $State.Metadata.GitBaseline = $null
        }

        # Resolve output/synthpop from sim_design
        $baseDirForYaml = ($projectRoot -replace '\\','/')
        $outputDir = Get-YamlPathValue -State $State -YamlPath $simDesign -Key 'output_dir' -BaseDir $baseDirForYaml
        $synthDir  = Get-YamlPathValue -State $State -YamlPath $simDesign -Key 'synthpop_dir' -BaseDir $baseDirForYaml
        if (-not (Test-AndCreateDirectory -State $State -Path $outputDir -PathKey 'output_dir')) { [System.Windows.Forms.MessageBox]::Show("Failed to ensure output_dir path:`n$outputDir`n`nCheck your sim_design YAML file.",'Path error','OK','Error') | Out-Null; return }
        if (-not (Test-AndCreateDirectory -State $State -Path $synthDir -PathKey 'synthpop_dir')) { [System.Windows.Forms.MessageBox]::Show("Failed to ensure synthpop_dir path:`n$synthDir`n`nCheck your sim_design YAML file.",'Path error','OK','Error') | Out-Null; return }

        $State.Paths.OutputDir = $outputDir
        $State.Paths.SynthpopDir = $synthDir

        $repoMountSource = if ($State.ContainerLocation -eq 'LOCAL') { Convert-PathToDockerFormat -Path $projectRoot } else { $projectRoot }

        # F12 (partial): warn when another running container already uses this repository
        # folder. On the shared workstation all colleagues work in the SAME checkout, so two
        # containers on one folder mix their edits, git pulls and results, and a commit at
        # Stop would include the other person's changes. We only warn; the user decides.
        # (The 'Other containers are running' check above only sees this user's containers.)
        try {
            $ctxShared = Get-DockerContextArgs -State $State
            $runningIds = @(& docker @ctxShared @('ps','-q') 2>$null | Where-Object { $_ -match '\S' })
            if ($LASTEXITCODE -eq 0 -and $runningIds.Count -gt 0) {
                $mountLines = & docker @ctxShared (@('inspect','-f','{{.Name}}{{range .Mounts}}{{if eq .Type "bind"}}|{{.Source}}{{end}}{{end}}') + $runningIds) 2>$null
                $target = $repoMountSource.TrimEnd('/')
                $sharing = @()
                foreach ($ml in @($mountLines)) {
                    $parts = "$ml" -split '\|'
                    $otherName = $parts[0].Trim().TrimStart('/')
                    if (-not $otherName -or $otherName -eq $State.ContainerName) { continue }
                    foreach ($src in ($parts | Select-Object -Skip 1)) {
                        $s = $src.Trim().TrimEnd('/')
                        # Docker Desktop may report a LOCAL source with a prefix such as
                        # /run/desktop/mnt/host/c/..., so for LOCAL compare the end of the path.
                        $same = if ($State.ContainerLocation -eq 'LOCAL') { $s.EndsWith($target, [System.StringComparison]::OrdinalIgnoreCase) } else { $s -ceq $target }
                        if ($same) { $sharing += $otherName; break }
                    }
                }
                if ($sharing.Count -gt 0) {
                    $msgShared = "Another running container is already using this repository folder:`n`n  $($sharing -join ', ')`n`n$projectRoot`n`nIf you both work in it at the same time, your edits, git pulls and results will mix, and a commit at Stop may include the other person's changes.`n`nStart anyway?"
                    $answerShared = [System.Windows.Forms.MessageBox]::Show($msgShared, 'Repository already in use', [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Warning, [System.Windows.Forms.MessageBoxDefaultButton]::Button2)
                    if ($answerShared -ne [System.Windows.Forms.DialogResult]::Yes) { return }
                }
            }
        } catch {
            Write-Log "Shared repository check failed (continuing): $($_.Exception.Message)" 'Debug'
        }

        # Resolve the actual uid/gid of the host user so the container's rstudio
        # user matches.  This prevents the container from changing ownership of
        # bind-mounted files (especially .git) to a different uid.  The Rocker
        # image remaps rstudio to the USERID/GROUPID we pass.  On Windows/local
        # Docker Desktop, 1000:1000 is fine (Linux VM layer).  On a remote Linux
        # workstation we query the real ids of the SSH user.
        $containerUid = '1000'
        $containerGid = '1000'
        if ($State.ContainerLocation -like 'REMOTE@*') {
            try {
                $remoteHost = Get-RemoteHostString -State $State
                $sshKey = $State.Paths.SshPrivate
                $idSshArgs = @('-n', '-i', $sshKey, '-o', 'IdentitiesOnly=yes', '-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=accept-new', '-o', 'ConnectTimeout=15', $remoteHost)
                $uidOut = (& ssh @idSshArgs 'id -u' 2>$null)
                $gidOut = (& ssh @idSshArgs 'id -g' 2>$null)
                if ($LASTEXITCODE -eq 0 -and $uidOut -match '^\d+$') {
                    $containerUid = $uidOut.Trim()
                    $containerGid = $gidOut.Trim()
                    Write-Log "Remote host user uid=$containerUid gid=$containerGid" 'Info'
                }
            } catch {
                Write-Log "Could not detect remote uid/gid, defaulting to 1000:1000: $($_.Exception.Message)" 'Warn'
            }
        }

        # F13: in LOCAL mode publish RStudio on 127.0.0.1 only, so nobody else on the same
        # Wi-Fi or network can reach the login page (and, after a login, the GitHub key).
        # The GUI shows http://localhost:<port>, which keeps working. On the workstation the
        # colleague's PC must reach the port, so REMOTE stays on all interfaces.
        $hostPort = if ($portOverride) { $portOverride } else { '8787' }
        $publishSpec = if ($State.ContainerLocation -eq 'LOCAL') { "127.0.0.1:${hostPort}:8787" } else { "${hostPort}:8787" }

        # Use a writable path for the SSH key inside the container so permissions can be fixed for the rstudio user
        $containerKeyPath = "/home/rstudio/.ssh/id_ed25519_$($State.UserName)"
        $dockerArgs = @('run','-d','--rm','--name',$State.ContainerName,
            '-e',"PASSWORD=$($State.Password)",
            '-e','DISABLE_AUTH=false',
            '-e',"USERID=$containerUid",'-e',"GROUPID=$containerGid",
            '-e',"CONTAINER_REPO_NAME=$($State.SelectedRepo)",
            '-e','SYNC_ENABLED=false',
            '-e',"GIT_SSH_COMMAND=ssh -i $containerKeyPath -o IdentitiesOnly=yes -o UserKnownHostsFile=/etc/ssh/ssh_known_hosts -o StrictHostKeyChecking=yes",
            '--mount',"type=bind,source=$repoMountSource,target=/home/rstudio/$($State.SelectedRepo)",
            '-p',$publishSpec
        )

        if ($customParams) {
            # F102: split like a shell, so a quoted value with spaces stays one argument.
            $dockerArgs += @(Split-DockerCustomParams -Text $customParams)
        }

        if ($State.ContainerLocation -eq 'LOCAL') {
            $sshKeyPath = $State.Paths.SshPrivate
            $knownHostsPath = "$HOME/.ssh/known_hosts"
        } else {
            $sshKeyPath = "/home/$($State.RemoteUser)/.ssh/id_ed25519_$($State.UserName)"
            $knownHostsPath = "/home/$($State.RemoteUser)/.ssh/known_hosts"
        }

        # Removes the volumes created by THIS click when the start fails further down.
        # That is safe: at that point they only hold copies of host files made a moment
        # ago (volumes left over from an earlier session were dealt with before creating them).
        $removeFreshVolumes = {
            if ($useVolumes -and $State.Metadata.VolumeOutput -and $State.Metadata.VolumeSynthpop) {
                & docker @(Get-DockerContextArgs -State $State) @('volume','rm','-f',$State.Metadata.VolumeOutput,$State.Metadata.VolumeSynthpop) 2>$null | Out-Null
            }
        }

        if ($useVolumes) {
            # F48: names include the container name (repo + user), so two repos no longer share volumes.
            $volNames = Get-ImpactVolumeNames -ContainerName $State.ContainerName
            $volOut = $volNames.Output
            $volSyn = $volNames.Synthpop
            # Not yet recorded in the state: $removeFreshVolumes must not touch these volumes
            # before they were really created by this click.
            $State.Metadata.VolumeOutput = $null
            $State.Metadata.VolumeSynthpop = $null

            $ctxPrefix = Get-DockerContextArgs -State $State

            # F17: the rsync-alpine helper is needed to copy results back at Stop. Check that it
            # really exists BEFORE any volume is created; the old code ignored a failed build,
            # so the problem only appeared hours later when Stop could not copy the results.
            Write-Log 'Checking/building rsync-alpine helper image.' 'Debug'
            if (-not (Initialize-RsyncHelperImage -State $State)) {
                [System.Windows.Forms.MessageBox]::Show("The helper image needed for 'Use Docker Volumes' (rsync-alpine) could not be prepared. Usually Docker could not download the small Alpine Linux image (no internet access, a proxy, or a Docker Hub download limit).`n`nUntick 'Use Docker Volumes' to start without volumes, or check the network and try again.",'Volume helper missing','OK','Error') | Out-Null
                return
            }

            # F02: volumes with these names may be left over from an earlier session that was
            # never copied back (crash, reboot, Docker restart, or a failed Stop). They may hold
            # the ONLY copy of results, so never delete them silently: copy them out first, or
            # ask the user.
            $volPairs = @(
                @{ Name = $volOut; HostDir = $outputDir },
                @{ Name = $volSyn; HostDir = $synthDir }
            )
            $leftovers = @()
            foreach ($vp in $volPairs) {
                $vi = Get-ImpactVolumeInfo -State $State -VolumeName $vp.Name
                if ($null -eq $vi.Exists) {
                    [System.Windows.Forms.MessageBox]::Show("Could not check the Docker volume '$($vp.Name)':`n$($vi.Error)`n`nCheck that Docker is running and try again.",'Volume check failed','OK','Error') | Out-Null
                    return
                }
                if ($vi.Exists) {
                    if ($vi.UsedBy.Count -gt 0) {
                        [System.Windows.Forms.MessageBox]::Show("The Docker volume '$($vp.Name)' is still used by: $($vi.UsedBy -join ', ').`n`nStop or remove that container first.",'Volume in use','OK','Error') | Out-Null
                        return
                    }
                    # Prefer the folder recorded when the volume was created: the YAML may point
                    # somewhere else now.
                    $target = if ($vi.TargetDir) { $vi.TargetDir } else { $vp.HostDir }
                    $leftovers += [pscustomobject]@{ Name = $vp.Name; Target = $target }
                }
            }
            if ($leftovers.Count -gt 0) {
                $leftList = ($leftovers | ForEach-Object { "  - $($_.Name)`n      -> $($_.Target)" }) -join "`n"
                $leftMsg = "Docker volumes from an earlier session of '$($State.ContainerName)' still exist:`n`n$leftList`n`nThey may contain results that were never copied back (for example after a crash, a reboot or a failed Stop).`n`nYes: copy their contents into the folders shown above, then start (recommended).`nNo: delete them WITHOUT copying, then start.`nCancel: do nothing."
                $leftChoice = [System.Windows.Forms.MessageBox]::Show($leftMsg, 'Earlier results found', [System.Windows.Forms.MessageBoxButtons]::YesNoCancel, [System.Windows.Forms.MessageBoxIcon]::Warning, [System.Windows.Forms.MessageBoxDefaultButton]::Button1)
                if ($leftChoice -eq [System.Windows.Forms.DialogResult]::Yes) {
                    foreach ($lo in $leftovers) {
                        $lblStatus.Text = "Copying earlier results from $($lo.Name)..."
                        $form.Refresh()
                        $syncLeft = Sync-ImpactVolumeToHost -State $State -VolumeName $lo.Name -HostDir $lo.Target
                        if (-not $syncLeft.Success) {
                            $lblStatus.Text = ''
                            [System.Windows.Forms.MessageBox]::Show("$($syncLeft.Message)`n`nNothing was deleted: the volume still holds the data. The container was not started.",'Copy failed','OK','Error') | Out-Null
                            return
                        }
                    }
                    $lblStatus.Text = ''
                } elseif ($leftChoice -eq [System.Windows.Forms.DialogResult]::No) {
                    $confirmDiscard = [System.Windows.Forms.MessageBox]::Show("Really delete these volumes and everything in them? This cannot be undone.`n`n$leftList", 'Delete earlier results?', [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Warning, [System.Windows.Forms.MessageBoxDefaultButton]::Button2)
                    if ($confirmDiscard -ne [System.Windows.Forms.DialogResult]::Yes) { return }
                } else {
                    return
                }
                # Only reached when the copy succeeded or the user explicitly chose to discard.
                $rmLeftOut = & docker @ctxPrefix (@('volume','rm') + @($leftovers | ForEach-Object { $_.Name })) 2>&1
                if ($LASTEXITCODE -ne 0) {
                    [System.Windows.Forms.MessageBox]::Show("Could not remove the old Docker volumes:`n$rmLeftOut",'Volume error','OK','Error') | Out-Null
                    return
                }
                Write-Log "Removed earlier volumes: $(($leftovers | ForEach-Object { $_.Name }) -join ', ')" 'Info'
            }

            # Create the volumes. The label records the host folder each one belongs to, so a
            # later Start can copy leftovers to the right place even if the YAML changed.
            Write-Log "Creating Docker volumes: $volOut, $volSyn" 'Debug'
            foreach ($vp in $volPairs) {
                $createOut = & docker @ctxPrefix @('volume','create','--label',"impact.target_dir=$($vp.HostDir)",'--label',"impact.container=$($State.ContainerName)",$vp.Name) 2>&1
                if ($LASTEXITCODE -ne 0) {
                    & docker @ctxPrefix @('volume','rm','-f',$volOut,$volSyn) 2>$null | Out-Null
                    [System.Windows.Forms.MessageBox]::Show("Could not create the Docker volume '$($vp.Name)':`n$createOut",'Volume error','OK','Error') | Out-Null
                    return
                }
            }
            $State.Metadata.VolumeOutput = $volOut
            $State.Metadata.VolumeSynthpop = $volSyn

            # Fix ownership (checked now: a failure used to be ignored)
            Write-Log "Setting volume ownership (chown ${containerUid}:${containerGid})." 'Debug'
            foreach ($vn in @($volOut, $volSyn)) {
                $chownOut = & docker @ctxPrefix @('run','--rm','-v',"${vn}:/volume",'alpine','sh','-c',"chown ${containerUid}:${containerGid} /volume") 2>&1
                if ($LASTEXITCODE -ne 0) {
                    Write-Log "Setting ownership of volume $vn failed: $chownOut" 'Error'
                    & $removeFreshVolumes
                    [System.Windows.Forms.MessageBox]::Show("Preparing the Docker volume '$vn' failed (could not set its owner):`n$chownOut",'Volume error','OK','Error') | Out-Null
                    return
                }
            }

            # Pre-populate volumes from host dirs. One plain 'cp -r' whose result is checked
            # (it used to end in '|| true', which hid every error). One unreadable file should
            # not block the start, so on errors the user can still continue.
            Write-Log 'Pre-populating volumes from host directories.' 'Debug'
            $dockerOutputSource = if ($State.ContainerLocation -eq 'LOCAL') { Convert-PathToDockerFormat -Path $outputDir } else { $outputDir }
            $dockerSynthSource  = if ($State.ContainerLocation -eq 'LOCAL') { Convert-PathToDockerFormat -Path $synthDir } else { $synthDir }
            $prepopErrors = @()
            foreach ($pp in @(@{ Src = $dockerOutputSource; Vol = $volOut }, @{ Src = $dockerSynthSource; Vol = $volSyn })) {
                $cpOut = & docker @ctxPrefix @('run','--rm','--user',"${containerUid}:${containerGid}",'-v',"$($pp.Src):/source",'-v',"$($pp.Vol):/volume",'alpine','sh','-c','cp -r /source/. /volume/') 2>&1
                if ($LASTEXITCODE -ne 0) {
                    $prepopErrors += "$($pp.Vol): $((@($cpOut) | ForEach-Object { "$_" } | Select-Object -Last 3) -join ' ')"
                }
            }
            if ($prepopErrors.Count -gt 0) {
                Write-Log "Pre-populating volumes reported errors: $($prepopErrors -join ' / ')" 'Warn'
                $prepopAnswer = [System.Windows.Forms.MessageBox]::Show("Copying your existing files into the Docker volumes reported errors:`n`n$($prepopErrors -join "`n")`n`nSome existing files may be missing inside the container (the files on disk are not affected).`n`nStart anyway?", 'Volume copy problem', [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Warning, [System.Windows.Forms.MessageBoxDefaultButton]::Button2)
                if ($prepopAnswer -ne [System.Windows.Forms.DialogResult]::Yes) {
                    & $removeFreshVolumes
                    return
                }
            }

            $dockerArgs += @('-v',"$($volOut):/home/rstudio/$($State.SelectedRepo)/outputs",
                             '-v',"$($volSyn):/home/rstudio/$($State.SelectedRepo)/inputs/synthpop")
        } else {
            # Bind mode: make sure no volume names from an earlier start linger in the state.
            $State.Metadata.VolumeOutput = $null
            $State.Metadata.VolumeSynthpop = $null
            $outDocker = if ($State.ContainerLocation -eq 'LOCAL') { Convert-PathToDockerFormat -Path $outputDir } else { $outputDir }
            $synDocker = if ($State.ContainerLocation -eq 'LOCAL') { Convert-PathToDockerFormat -Path $synthDir } else { $synthDir }
            # repo already mounted above; only bind outputs and synthpop to avoid duplicate mount targets
            $dockerArgs += @('--mount',"type=bind,source=$outDocker,target=/home/rstudio/$($State.SelectedRepo)/outputs",
                             '--mount',"type=bind,source=$synDocker,target=/home/rstudio/$($State.SelectedRepo)/inputs/synthpop")
        }

        if ($highComp -and $State.ContainerLocation -like 'REMOTE@*') {
            $dockerArgs += @('--cpus','32','-m','384g')
        }

        # F01/F04: record how this container is started (volume mode, result folders,
        # volume names) as Docker labels. A GUI that is closed and reopened reads them back
        # (Get-ContainerRuntimeInfo), for LOCAL and REMOTE alike, so Stop can still copy the
        # results to the right folders.
        $dockerArgs += @(Get-ImpactContainerLabelArgs -UseVolumes $useVolumes -OutputDir $outputDir -SynthpopDir $synthDir -VolumeOutput $State.Metadata.VolumeOutput -VolumeSynthpop $State.Metadata.VolumeSynthpop)

        $dockerArgs += @('--mount',"type=bind,source=$sshKeyPath,target=/keys/id_ed25519_$($State.UserName),readonly",
                         '--mount',"type=bind,source=$knownHostsPath,target=/etc/ssh/ssh_known_hosts,readonly",
                         '--workdir',"/home/rstudio/$($State.SelectedRepo)",
                         $imageName)

        # Refresh port scan immediately before docker run to catch races
        $freshUsedPorts = Get-UsedPorts -ContextArgs (Get-DockerContextArgs -State $State)
        $chosenPort = if ($portOverride) { $portOverride } else { '8787' }
        if ($freshUsedPorts -contains $chosenPort) {
            & $removeFreshVolumes
            [System.Windows.Forms.MessageBox]::Show("Port $chosenPort was just taken by another container. Choose a different port.", 'Port conflict', 'OK', 'Error') | Out-Null
            return
        }

        $runCmd = (Get-DockerContextArgs -State $State) + $dockerArgs
        # Hide the password: Debug lines always go to the log file on disk (F85).
        $runCmdForLog = $runCmd | ForEach-Object { if ("$_" -like 'PASSWORD=*') { 'PASSWORD=***' } else { $_ } }
        Write-Log "Starting container with: docker $($runCmdForLog -join ' ')" 'Debug'

        $rc = & docker $runCmd 2>&1
        if ($LASTEXITCODE -ne 0) {
            $runExit = $LASTEXITCODE
            $friendlyError = Format-DockerError -RawError ([string]$rc)
            Write-Log "Docker run failed (exit=$runExit): $rc" 'Error'
            & $removeFreshVolumes
            [System.Windows.Forms.MessageBox]::Show($friendlyError, 'Container start failed', 'OK', 'Error') | Out-Null
            return
        }

        # Copy the SSH key from the readonly bind mount to a writable location with correct ownership.
        # The bind mount preserves host-side ownership (e.g. php-workstation), but inside the container
        # the rstudio user needs to own the private key for SSH to accept it.
        # KEY_FIXED is now printed only when the key steps really succeeded: before, a ';'
        # in the chain meant 'echo KEY_FIXED' ran even when copying the key had failed, so
        # the check below could never notice a failure (F49). The known_hosts copy stays
        # best-effort (git uses the mounted /etc/ssh/ssh_known_hosts anyway).
        $fixKeyCmd = "mkdir -p /home/rstudio/.ssh && cp /keys/id_ed25519_$($State.UserName) $containerKeyPath && chmod 600 $containerKeyPath && chown ${containerUid}:${containerGid} $containerKeyPath && echo KEY_FIXED; cp /etc/ssh/ssh_known_hosts /home/rstudio/.ssh/known_hosts 2>/dev/null; chmod 644 /home/rstudio/.ssh/known_hosts 2>/dev/null; chown ${containerUid}:${containerGid} /home/rstudio/.ssh/known_hosts 2>/dev/null; true"
        # F88: run as root explicitly. Copying into /home/rstudio and chown need root, and
        # the image's default user could change in the future.
        $fixCtx = (Get-DockerContextArgs -State $State) + @('exec', '--user', 'root', $State.ContainerName, 'sh', '-c', $fixKeyCmd)
        # Retry a few times: right after 'docker run' the container may still be setting
        # itself up (for example remapping the rstudio user to USERID/GROUPID).
        $keyFixed = $false
        for ($attempt = 1; $attempt -le 3 -and -not $keyFixed; $attempt++) {
            try {
                $fixOut = & docker $fixCtx 2>&1
                if ($fixOut -match 'KEY_FIXED') {
                    $keyFixed = $true
                    Write-Log 'SSH key permissions fixed inside container.' 'Info'
                } else {
                    Write-Log "SSH key permission fix attempt $attempt failed: $fixOut" 'Warn'
                }
            } catch {
                Write-Log "SSH key permission fix attempt $attempt failed: $($_.Exception.Message)" 'Warn'
            }
            if (-not $keyFixed -and $attempt -lt 3) { Start-Sleep -Seconds 2 }
        }

        # Configure git inside the container for the rstudio user.
        # 1. Set user.name and user.email so that git commit works out of the box.
        #    The username is the user's GitHub handle; email uses GitHub's noreply
        #    address so commits are attributed correctly without exposing real email.
        # 2. The Docker image's system gitconfig ships pull.ff=only which aborts when
        #    fast-forward isn't possible. We override at global level so git pull
        #    works like GitKraken / vanilla-git (merge when not fast-forwardable).
        # 3. safe.directory='*' is a safety net for any remaining ownership edge cases.
        $gitCfgCmd = "git config --global user.name '$($State.UserName)' && git config --global user.email '$($State.UserName)@users.noreply.github.com' && git config --global pull.ff true && git config --global pull.rebase false && git config --global --add safe.directory '*' && echo GIT_CONFIGURED"
        $gitCfgCtx = (Get-DockerContextArgs -State $State) + @('exec', '--user', 'rstudio', $State.ContainerName, 'sh', '-c', $gitCfgCmd)
        $gitConfigured = $false
        for ($attempt = 1; $attempt -le 3 -and -not $gitConfigured; $attempt++) {
            try {
                $gitCfgOut = & docker $gitCfgCtx 2>&1
                if ($gitCfgOut -match 'GIT_CONFIGURED') {
                    $gitConfigured = $true
                    Write-Log 'Git pull strategy (merge) configured inside container.' 'Info'
                } else {
                    Write-Log "Git config inside container attempt $attempt failed: $gitCfgOut" 'Warn'
                }
            } catch {
                Write-Log "Git config inside container attempt $attempt failed: $($_.Exception.Message)" 'Warn'
            }
            if (-not $gitConfigured -and $attempt -lt 3) { Start-Sleep -Seconds 2 }
        }

        # F49: 'docker run -d' only says the container was started, not that it is still
        # running. If its start-up script fails, it stops at once and '--rm' deletes it,
        # so check that it is still there before reporting RUNNING.
        $psAfterStart = (Get-DockerContextArgs -State $State) + @('ps','--filter',"name=^$($State.ContainerName)$",'--format','{{.Names}}')
        $psAfterOut = & docker @psAfterStart 2>$null
        $psAfterExit = $LASTEXITCODE
        if ($psAfterExit -eq 0 -and -not (@($psAfterOut) | Where-Object { "$_".Trim() -eq $State.ContainerName })) {
            Write-Log "Container $($State.ContainerName) stopped right after starting." 'Error'
            # The fresh volumes only hold copies of host files, so they can go.
            & $removeFreshVolumes
            [System.Windows.Forms.MessageBox]::Show("The container stopped right after it was started, so RStudio is not available.`n`nCheck the console window and the log file (~/.impact_gui/logs/impact.log) for details. Ticking 'Rebuild image' and starting again often helps.",'Container stopped','OK','Error') | Out-Null
            return
        } elseif ($psAfterExit -ne 0) {
            # Docker could not be asked (for example a short network problem); carry on as before.
            Write-Log 'Could not confirm that the container is still running (docker ps failed).' 'Warn'
        }

        if (-not $keyFixed -or -not $gitConfigured) {
            # The container runs, so do not stop it, but tell the user clearly instead of
            # only writing a console warning that nobody reads.
            $setupProblems = @()
            if (-not $keyFixed) { $setupProblems += "- Your GitHub SSH key could not be set up inside the container: git pull / push from RStudio will not work." }
            if (-not $gitConfigured) { $setupProblems += "- Your git name and e-mail could not be set inside the container: git commit in RStudio may fail ('Please tell me who you are')." }
            [System.Windows.Forms.MessageBox]::Show("The container is running, but part of its setup failed:`n`n$($setupProblems -join "`n")`n`nDetails are in the console window and the log file. Stopping and starting the container again often fixes this.",'Container setup incomplete','OK','Warning') | Out-Null
        }

        if ($State.ContainerLocation -like 'REMOTE@*') {
            $portStore = if ($portOverride) { $portOverride } else { '8787' }
            # No password in the metadata any more (F40): every colleague can read /tmp.
            Write-RemoteContainerMetadata -State $State -Port $portStore -UseVolumes $useVolumes
        }

        # F32: the recovered password/port/volume details belonged to the previous container.
        # Forget them so the info box shows the password this container really uses.
        $State.Metadata.Recovered = @{ Password = $null; Port = $null; UseVolumes = $false; OutputDir = $null; SynthpopDir = $null; VolumeOutput = $null; VolumeSynthpop = $null }

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
        # F85: never print the password to the console (it stays visible during screen-sharing).
        Write-Host "Container ready: $hostDisplay (user: rstudio, password: the one you entered at login)" -ForegroundColor Green
    })

    $btnStop.Add_Click({
        $ctxArgs = Get-DockerContextArgs -State $State
        $runCmd = $ctxArgs + @('ps','--filter',"name=^$($State.ContainerName)$",'--format','{{.Names}}')
        $exists = & docker $runCmd 2>$null
        # F18: a non-zero exit code means Docker (or the ssh connection to the workstation)
        # could not be reached, so we do NOT know whether the container still runs. Say so,
        # and leave state and buttons unchanged so the user can simply try again. (Before,
        # this looked the same as "container gone" and the UI wrongly showed STOPPED.)
        if ($LASTEXITCODE -ne 0) {
            $where = if ($State.ContainerLocation -eq 'LOCAL') { 'Check that Docker Desktop is running.' } else { 'Check your network / VPN connection to the workstation.' }
            [System.Windows.Forms.MessageBox]::Show("Could not reach Docker, so it is unknown whether the container is still running.`n`n$where Then click Stop again.",'Docker not reachable','OK','Warning') | Out-Null
            return
        }
        # Docker answered but the container is not listed: it already ended on its own
        # (crash, reboot, Docker restart, or stopped outside this tool). We still run the
        # clean-up below: the Docker volumes survive the container and hold its results,
        # and the state flags must be reset so Start and Back work again (F18).
        $alreadyGone = -not (@($exists) | Where-Object { "$_".Trim() -eq $State.ContainerName })

        if ($alreadyGone) {
            Write-Log "Container $($State.ContainerName) is no longer running; cleaning up." 'Warn'
        } else {
            # F51: stopping ends every R session at once and the container is deleted
            # (--rm), so ask first. 'No' is the default button, so a stray Enter is harmless.
            $stopMsg = "Stop the container '$($State.ContainerName)' now?`n`n" +
                       "- Any simulation that is still running will be killed.`n" +
                       "- Unsaved changes in RStudio editor tabs will be lost.`n`n" +
                       "Files you saved in the repository and your output folders are kept.`n`n" +
                       "Tip: save your files in RStudio and let simulations finish first."
            $stopAnswer = [System.Windows.Forms.MessageBox]::Show($stopMsg, 'Stop container?', [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Warning, [System.Windows.Forms.MessageBoxDefaultButton]::Button2)
            if ($stopAnswer -ne [System.Windows.Forms.DialogResult]::Yes) { return }

            $stopCmd = $ctxArgs + @('stop',$State.ContainerName)
            Write-Log "Stopping container $($State.ContainerName)" 'Info'
            & docker $stopCmd 2>$null
            Write-Log "docker stop exit=$LASTEXITCODE" 'Debug'
            if ($LASTEXITCODE -ne 0) {
                [System.Windows.Forms.MessageBox]::Show('Failed to stop container; check Docker.','Stop failed','OK','Error') | Out-Null
                return
            }
        }

        # Copy results out of the volumes, if volumes were used. The checkbox is NOT used as a
        # fallback any more: it describes the next start, not the container being stopped.
        $useVolumesForStop = [bool]$State.Metadata.ActiveUseVolumes
        Write-Log "Stop clicked; volumesUsed=$useVolumesForStop" 'Debug'
        $volumeProblem = $null
        if ($useVolumesForStop) {
            $volOut = $State.Metadata.VolumeOutput
            $volSyn = $State.Metadata.VolumeSynthpop
            # F01: the volumes are deleted ONLY when both copies succeeded. Before, they were
            # always deleted, even when the copy failed or the target folder was unknown
            # (a resumed session), which lost all results of the run.
            if (-not $volOut -or -not $volSyn) {
                $volumeProblem = 'The names of the Docker volumes are unknown.'
            } elseif (-not $State.Paths.OutputDir -or -not $State.Paths.SynthpopDir) {
                $volumeProblem = 'The folders to copy the results back to are unknown (the container was probably started by an older version of this tool).'
            } else {
                $lblStatus.Text = 'Copying results from the Docker volumes back to your folders...'
                $form.Refresh()
                $syncOut = Sync-ImpactVolumeToHost -State $State -VolumeName $volOut -HostDir $State.Paths.OutputDir
                $syncSyn = Sync-ImpactVolumeToHost -State $State -VolumeName $volSyn -HostDir $State.Paths.SynthpopDir
                if ($syncOut.Success -and $syncSyn.Success) {
                    $toRemove = @()
                    if (-not $syncOut.Missing) { $toRemove += $volOut }
                    if (-not $syncSyn.Missing) { $toRemove += $volSyn }
                    if ($toRemove.Count -gt 0) {
                        # Retry briefly: '--rm' may still be removing the stopped container,
                        # and a volume cannot be removed while a container uses it.
                        # '-f' only ignores volumes that are already gone.
                        $removed = $false
                        $rmOut = $null
                        for ($i = 1; $i -le 5 -and -not $removed; $i++) {
                            $rmOut = & docker @ctxArgs (@('volume','rm','-f') + $toRemove) 2>&1
                            if ($LASTEXITCODE -eq 0) { $removed = $true } else { Start-Sleep -Seconds 1 }
                        }
                        if ($removed) {
                            Write-Log "Removed volumes $($toRemove -join ', ') after a successful copy." 'Info'
                        } else {
                            # Not a data loss: everything was copied. The volumes only use disk space.
                            Write-Log "Results were copied, but volumes $($toRemove -join ', ') could not be removed: $rmOut" 'Warn'
                        }
                    }
                } else {
                    $volumeProblem = (@($syncOut, $syncSyn) | Where-Object { -not $_.Success } | ForEach-Object { $_.Message }) -join "`n"
                }
            }
        }

        $State.Metadata.ContainerRunning = $false
        $State.Metadata.ActiveUseVolumes = $false

        if ($State.ContainerLocation -like 'REMOTE@*') { Remove-RemoteContainerMetadata -State $State }

        # F32: the recovered details belonged to the container that is now gone.
        $State.Metadata.Recovered = @{ Password = $null; Port = $null; UseVolumes = $false; OutputDir = $null; SynthpopDir = $null; VolumeOutput = $null; VolumeSynthpop = $null }
        # F39: refresh the list of used ports, so starting again on the port that was just
        # freed is not rejected as 'already in use'.
        $State.Ports.Used = @(Get-UsedPorts -ContextArgs $ctxArgs)

        Update-InfoBox -Status 'STOPPED'
        $btnStart.Enabled = $true
        $btnStop.Enabled  = $false
        Write-Log "Container $($State.ContainerName) stopped." 'Info'

        if ($volumeProblem) {
            # Shown before the git dialog because it is about possible data loss.
            $volList = (@($State.Metadata.VolumeOutput, $State.Metadata.VolumeSynthpop) | Where-Object { $_ }) -join ', '
            Write-Log "Results were NOT copied back; volumes kept: $volList. Reason: $volumeProblem" 'Error'
            # The next Start only recognises volumes named the current way; volumes of a
            # container started by an older version need manual help.
            $expectedNames = Get-ImpactVolumeNames -ContainerName $State.ContainerName
            $nextStep = if ($State.Metadata.VolumeOutput -eq $expectedNames.Output -and $State.Metadata.VolumeSynthpop -eq $expectedNames.Synthpop) {
                "The next time you click Start with 'Use Docker Volumes' ticked, the tool offers to copy them into your folders. If that does not work, ask the maintainer for help and quote the volume names above."
            } else {
                "Please do not delete them. Ask the maintainer to copy them for you and quote the volume names above."
            }
            [System.Windows.Forms.MessageBox]::Show("Your results were NOT copied back to your folders, so the Docker volumes were kept (nothing was deleted):`n`n  $volList`n`nReason:`n$volumeProblem`n`n$nextStep",'Results still in Docker volumes','OK','Error') | Out-Null
        }

        if ($State.Metadata.ActiveRepoPath) {
            Invoke-GitChangeDetection -State $State -RepoPath $State.Metadata.ActiveRepoPath -IsRemote $State.Metadata.ActiveIsRemote
        }

        if ($volumeProblem) {
            $lblStatus.Text = 'Stopped. Results are still in Docker volumes (see the message).'
            Write-Host "Stopped, but results are still in Docker volumes: $volumeProblem" -ForegroundColor Yellow
        } else {
            $lblStatus.Text = 'All done. You can close this window or start another container.'
            Write-Host "All done. You can close this window or start another container." -ForegroundColor Green
        }
    })

    $btnClose.Add_Click({ $form.Close() })

    $null = $form.ShowDialog()
    if ($form.Tag -eq 'back') {
        Write-Log 'User navigated back from container manager.' 'Info'
        return 'back'
    }
    return 'close'
}

# Coordinator: orchestrates all steps with clear sequencing and early validation.
function Invoke-ImpactGui {
    Write-Log 'Starting IMPACT Docker GUI workflow.' 'Info'
    Ensure-PowerShell7 -PS7RequestedFlag:$PS7Requested.IsPresent
    $state = New-SessionState

    $state.Metadata.BuildInfo = Get-BuildInfo
    $bi = $state.Metadata.BuildInfo
    Write-Log ("Build info -> Version={0} Commit={1} Built={2}" -f $bi.Version, $bi.Commit, $bi.Built) 'Info'

    # Step-based wizard loop: allows Back navigation between dialogs
    $step = 1
    while ($step -le 6) {
        switch ($step) {
            1 { # Prerequisites (automated — no back)
                if (-not (Ensure-Prerequisites -State $state)) { return }
                $step++
            }
            2 { # Credentials dialog
                $r = Show-CredentialDialog -State $state
                if ($r -eq 'next') { $step++ }
                else { return } # cancel or failure — exit
            }
            3 { # SSH key setup (automated — no back)
                if (-not (Ensure-GitKeySetup -State $state)) { return }
                $step++
            }
            4 { # Location selection dialog
                $r = Select-Location -State $state
                if ($r -eq 'next') { $step++ }
                elseif ($r -eq 'back') { $step = 2 } # back to credentials
                else { return } # cancel — exit
            }
            5 { # Preparation (local/remote)
                $prepOk = $false
                if ($state.ContainerLocation -like 'REMOTE@*') {
                    $prepOk = Ensure-RemotePreparation -State $state
                } elseif ($state.ContainerLocation -eq 'LOCAL') {
                    $prepOk = Ensure-LocalPreparation -State $state
                } else {
                    Write-Log "No container location selected; exiting." 'Warn'
                    return
                }
                if ($prepOk) { $step++ }
                else { $step = 4 } # cancelled/failed — back to location
            }
            6 { # Container manager
                # F83: discard the returned state object. Uncaptured, PowerShell printed the
                # whole session state to the console, including the password in plain text.
                $null = Get-ContainerStatus -State $state
                $mgr = Show-ContainerManager -State $state
                if ($mgr -eq 'back') { $step = 4 } # back to location selection
                else { $step++ } # close — exit loop
            }
        }
    }
}

try {
    Invoke-ImpactGui
} catch {
    # Top-level catch to prevent the EXE from closing immediately and to surface diagnostics.
    $ex = $_.Exception
    Write-Log ("Unhandled exception: {0}`n{1}" -f $ex.Message, $ex.StackTrace) 'Error'
    Write-Host "A fatal error occurred: $($ex.Message)" -ForegroundColor Red
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
        [System.Windows.Forms.MessageBox]::Show("IMPACT encountered a fatal error:\n$($ex.Message)\nSee the log (~/.impact_gui/logs/impact.log) for details.", 'IMPACT - Fatal error', 'OK', 'Error') | Out-Null
    } catch { }
    Write-Host "`nPress Enter to exit..." -ForegroundColor Yellow
    Read-Host | Out-Null
    exit 1
}
